// SPDX-License-Identifier: Apache-2.0

//
//  FileServerKeyURLRoundTripTests.swift
//  ConduckTests
//
//  The step between "Conduck accepted this name" and "Conduck fetched this
//  file": `FileServerClient.build*Request` turns a storedKey into a WebDAV URL
//  with `URL.appending(path:)`, and until a name could carry anything but
//  `[A-Za-z0-9._-]` that step was trusted by assertion rather than measured.
//
//  It stopped being obvious the moment the outbox gate began admitting graphic
//  Unicode and the ASCII space. A space needs encoding. `%` is the encoding
//  introducer itself, so a name containing one has to survive being encoded
//  without being read as an escape already there. `#` and `?` are URL SYNTAX:
//  encoded wrongly they do not corrupt the path, they TRUNCATE it — everything
//  after them becomes a fragment or a query, and the GET goes to a shorter path
//  that may well be a different real file. And NFC and NFD are two byte
//  sequences Swift considers EQUAL, while the server's filesystem does not, so
//  the request has to carry back exactly the bytes the listing handed over.
//
//  Every case therefore asserts two things: the encoded URL is the intended one
//  (no query, no fragment, the separator still a separator), and decoding its
//  path returns the key BYTE-identically — `==` on String is canonical
//  equivalence and would call the two spellings of `réport.pdf` a match, so the
//  comparison runs on UTF-8.
//
//  Privacy: synthetic hosts and names only; nothing is logged.
//

import XCTest
@testable import Conduck

final class FileServerKeyURLRoundTripTests: XCTestCase {

    private func snapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.example.test/dav")!,
            username: "conduck",
            credential: "secret",
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }

    private let outboxKey = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789/out-\(String(repeating: "a", count: 32))"

    /// The property every case below shares: build the request, then read the
    /// URL back as a path and compare BYTES.
    private func assertRoundTrips(
        _ storedKey: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let url = FileServerClient.buildDownloadRequest(
            snapshot: snapshot(), storedKey: storedKey
        ).url
        guard let url else { return XCTFail("no URL was built", file: file, line: line) }

        XCTAssertNil(url.query,
                     "a filename must never become a query — that shortens the path silently",
                     file: file, line: line)
        XCTAssertNil(url.fragment,
                     "nor a fragment, for the same reason", file: file, line: line)

        let decodedPath = url.absoluteURL.path(percentEncoded: false)
        XCTAssertEqual(Array(decodedPath.utf8), Array("/dav/\(storedKey)".utf8),
                       "the path decodes back to the exact bytes of the key, under the base",
                       file: file, line: line)

        // And the listing parser's own reading — split the ENCODED path, then
        // decode each component — recovers the leaf whole. That is the reading
        // that decides whether an entry is a direct child, so a name that
        // survives here but not there would be fetched and never delivered.
        let components = url.absoluteURL.path(percentEncoded: true)
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }
        XCTAssertEqual(components.last.map { Array($0.utf8) },
                       storedKey.utf8.split(separator: UInt8(ascii: "/")).last.map(Array.init),
                       "split-then-decode recovers the leaf, separators intact",
                       file: file, line: line)
    }

    // MARK: - The shapes the widened gate admits

    /// A SPACE is the whole reason this file exists: it is the commonest
    /// character in a real filename outside the ASCII word set, and it is the
    /// one `validatedOutboxEntryName` now admits by name.
    func testASpaceEncodesAndDecodesBack() {
        assertRoundTrips("\(outboxKey)/the blue whale.MD")
        XCTAssertEqual(
            FileServerClient.buildDownloadRequest(
                snapshot: snapshot(), storedKey: "\(outboxKey)/my report.pdf"
            ).url?.absoluteString.hasSuffix("/my%20report.pdf"),
            true,
            "a space rides as %20, not as a literal that would break the request line")
    }

    /// NFC AND NFD ARE DIFFERENT FILES to the server and the SAME string to
    /// Swift. Whichever spelling the listing handed over is the one the GET has
    /// to carry, so the round trip is asserted on bytes and the two spellings are
    /// asserted to produce DIFFERENT URLs.
    func testBothUnicodeSpellingsSurviveAsThemselves() {
        let nfc = "\(outboxKey)/r\u{00E9}port.pdf"
        let nfd = "\(outboxKey)/re\u{0301}port.pdf"
        XCTAssertEqual(nfc, nfd,
                       "the premise: Swift considers these equal, so `==` cannot police this")
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8),
                          "and the bytes — the only thing the server sees — differ")

        assertRoundTrips(nfc)
        assertRoundTrips(nfd)

        let nfcURL = FileServerClient.buildDownloadRequest(snapshot: snapshot(), storedKey: nfc).url
        let nfdURL = FileServerClient.buildDownloadRequest(snapshot: snapshot(), storedKey: nfd).url
        XCTAssertNotEqual(nfcURL?.absoluteString, nfdURL?.absoluteString,
                          "the builder must not normalise one spelling into the other — that would "
                          + "fetch a file the user's server does not have")
        XCTAssertEqual(nfcURL?.absoluteString.hasSuffix("/r%C3%A9port.pdf"), true)
        XCTAssertEqual(nfdURL?.absoluteString.hasSuffix("/re%CC%81port.pdf"), true)
    }

    /// `%` IS THE ESCAPE INTRODUCER. A name containing one must be encoded to
    /// `%25` — encoded once, not read as an escape that was already there, and
    /// not double-decoded on the way back.
    func testAPercentInTheNameIsEscapedRatherThanInterpreted() {
        assertRoundTrips("\(outboxKey)/100% done.md")
        assertRoundTrips("\(outboxKey)/already%20encoded.md")
        XCTAssertEqual(
            FileServerClient.buildDownloadRequest(
                snapshot: snapshot(), storedKey: "\(outboxKey)/already%20encoded.md"
            ).url?.absoluteString.hasSuffix("/already%2520encoded.md"),
            true,
            "a literal `%20` in a filename is `%2520` on the wire — the file is named "
            + "`already%20encoded.md`, not `already encoded.md`")
    }

    /// `#` AND `?` TRUNCATE. These are the two characters where a missed
    /// encoding does not corrupt the path but CUTS it, sending the GET to a
    /// shorter path that may be a different real file — and both are ordinary
    /// punctuation the widened gate admits.
    func testFragmentAndQueryIntroducersStayInsideThePath() {
        for name in ["draft #3.md", "what now?.md", "a#b?c.md"] {
            assertRoundTrips("\(outboxKey)/\(name)")
        }
        let url = FileServerClient.buildDownloadRequest(
            snapshot: snapshot(), storedKey: "\(outboxKey)/a#b?c.md"
        ).url
        XCTAssertEqual(url?.absoluteString.hasSuffix("/a%23b%3Fc.md"), true,
                       "both introducers ride percent-encoded, so the path ends where the name does")
    }

    /// The names the gate exists to deliver, end to end.
    func testNonASCIINamesRoundTrip() {
        for name in [
            "Übersicht.md",
            "报告.pdf",
            "گزارش\u{200C}ها.pdf",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.png",
            "Peter's notes.md",
            "report (final); v2.pdf",
        ] {
            XCTAssertEqual(FileServerClient.validatedOutboxEntryName(name), name,
                           "the premise: \(name.debugDescription) is a name Conduck delivers")
            assertRoundTrips("\(outboxKey)/\(name)")
        }
    }

    /// The FLAT key shape — no folder — takes the same path through the builder,
    /// so it is measured too rather than assumed to follow.
    func testAFlatKeyRoundTripsIdentically() {
        assertRoundTrips("a1b2c3d4__my report.pdf")
        assertRoundTrips("a1b2c3d4__report.pdf")
    }

    /// The separator itself stays a separator: `appending(path:)` leaves `/`
    /// unescaped, which is what makes a nested key address a nested file instead
    /// of a single oddly-named one at the root.
    func testTheFolderSeparatorIsNotEscaped() {
        let url = FileServerClient.buildDownloadRequest(
            snapshot: snapshot(), storedKey: "\(outboxKey)/my report.pdf"
        ).url
        XCTAssertEqual(url?.absoluteString.contains("%2F"), false,
                       "an escaped separator would make the whole key one filename")
        XCTAssertEqual(url?.absoluteURL.path(percentEncoded: true)
            .split(separator: "/", omittingEmptySubsequences: true).count, 4,
                       "dav · conversation · out-box · leaf")
    }

    /// The PROBE builder shares the URL construction with the download builder,
    /// and the two must address the same file — a probe that says "exists" about
    /// a different path than the download fetches is worse than no probe.
    func testTheProbeAndTheDownloadAddressTheSameFile() {
        for name in ["my report.pdf", "报告.pdf", "100% done.md", "a#b?c.md"] {
            let key = "\(outboxKey)/\(name)"
            XCTAssertEqual(
                FileServerClient.buildProbeRequest(snapshot: snapshot(), storedKey: key).url,
                FileServerClient.buildDownloadRequest(snapshot: snapshot(), storedKey: key).url,
                "\(name.debugDescription) must resolve to one URL, whichever builder asks")
        }
    }
}

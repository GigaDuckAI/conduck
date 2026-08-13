// SPDX-License-Identifier: Apache-2.0

//
//  FileServerListingTests.swift
//  ConduckTests
//
//  Coverage for `FileServerClient.parseListing` — the STRICT directory listing
//  that is the sole authority on what an agent produced for one reply.
//
//  What every case here is really testing is a single property: the three
//  verdicts stay distinct, and `.entries` is reachable ONLY from a bounded,
//  complete, well-formed `207` whose rows are direct children of the exact
//  collection that was requested. Anything else is `.unusable` (nothing was
//  learned) or `.absent` (the folder is not there) — never an empty folder,
//  because "the agent produced nothing" is the one conclusion that CLOSES a turn.
//
//  The tolerant `parsePropfindBody` is a different function with a different
//  contract (`FileServerPropfindTests`); it may not back a delivery decision.
//
//  Privacy: synthetic fixtures only; nothing is logged.
//

import XCTest
@testable import Conduck

final class FileServerListingTests: XCTestCase {

    // MARK: - Fixtures

    private let conversationID = "11111111-2222-3333-4444-555555555555"
    private let boxKey = "11111111-2222-3333-4444-555555555555/out-0123456789abcdef"

    private func makeSnapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://fileserver.example.test")!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }

    /// The URL the PROPFIND targeted — the same value the request builder uses,
    /// which is what the href resolver must agree with.
    private func requestedURL(_ collectionKey: String? = nil) -> URL {
        FileServerClient.listingCollectionURL(
            snapshot: makeSnapshot(), collectionKey: collectionKey ?? boxKey)
    }

    private var boxPath: String { "/" + boxKey }

    /// Wrap `<D:response>` fragments in a multistatus envelope.
    private func multistatus(_ responses: String...) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(responses.joined(separator: "\n"))
        </D:multistatus>
        """
    }

    /// A normal file row: 2xx propstat, empty resourcetype, a length.
    private func fileResponse(href: String, length: Int = 1024) -> String {
        """
        <D:response>
          <D:href>\(href)</D:href>
          <D:propstat>
            <D:prop>
              <D:getcontentlength>\(length)</D:getcontentlength>
              <D:resourcetype/>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        """
    }

    /// The collection's own row — every `Depth: 1` of a non-root collection
    /// emits one.
    private func collectionResponse(href: String) -> String {
        """
        <D:response>
          <D:href>\(href)</D:href>
          <D:propstat>
            <D:prop>
              <D:resourcetype><D:collection/></D:resourcetype>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        """
    }

    private func parse(
        _ body: String,
        status: Int = 207,
        collectionKey: String? = nil
    ) -> FileServerListingVerdict {
        FileServerClient.parseListing(
            status: status,
            body: Data(body.utf8),
            requestedURL: requestedURL(collectionKey))
    }

    private func names(_ verdict: FileServerListingVerdict) -> [String] {
        guard case let .entries(entries) = verdict else { return [] }
        return entries.map(\.name)
    }

    // MARK: - The happy path, and what it must NOT include

    func testListingYieldsFilesAndSuppressesTheCollectionSelfEntry() {
        let verdict = parse(multistatus(
            collectionResponse(href: boxPath + "/"),
            fileResponse(href: boxPath + "/report.pdf", length: 2048),
            fileResponse(href: boxPath + "/notes.md", length: 17)
        ))

        XCTAssertEqual(names(verdict), ["report.pdf", "notes.md"],
                       "a Depth:1 listing yields its direct file children, in body order")
        guard case let .entries(entries) = verdict else { return XCTFail("expected entries") }
        XCTAssertEqual(entries.first?.byteSize, 2048, "getcontentlength populates byteSize")
        XCTAssertFalse(entries.contains { $0.name.hasPrefix("out-") },
                       "the collection's own row must never appear as one of its children")
    }

    /// The self-entry suppression must not depend on the trailing slash: servers
    /// differ, and the tolerant parser's name-emptiness guard catches only the
    /// ROOT collection's own row, which is the shape its own tests exercise.
    func testSelfEntryIsSuppressedWithAndWithoutATrailingSlash() {
        for selfHref in [boxPath, boxPath + "/"] {
            let verdict = parse(multistatus(
                collectionResponse(href: selfHref),
                fileResponse(href: boxPath + "/report.pdf")
            ))
            XCTAssertEqual(names(verdict), ["report.pdf"],
                           "self href \(selfHref) must be suppressed, not emitted")
        }
    }

    /// A root listing suppresses its own row too — the case the shipped parser
    /// DID handle, kept so the general rule cannot regress it.
    func testRootCollectionSuppressesItsOwnEntry() {
        let verdict = parse(multistatus(
            collectionResponse(href: "/"),
            fileResponse(href: "/report.pdf")
        ), collectionKey: "")
        XCTAssertEqual(names(verdict), ["report.pdf"])
    }

    /// RFC 4918 hrefs are normally absolute paths, but a relative reference
    /// resolves against the COLLECTION (with its trailing slash), not against its
    /// parent — otherwise every relative href would read as a sibling escape.
    func testRelativeHrefResolvesInsideTheCollection() {
        let verdict = parse(multistatus(fileResponse(href: "report.pdf")))
        XCTAssertEqual(names(verdict), ["report.pdf"])
    }

    // MARK: - The three verdicts are distinct

    func testEmptyCollectionIsEntriesNotAbsentAndNotUnusable() {
        let verdict = parse(multistatus(collectionResponse(href: boxPath + "/")))
        XCTAssertEqual(verdict, .entries([]),
                       "a readable folder holding nothing is a POSITIVE fact, not a failure")
    }

    /// A `207` whose multistatus carries no rows at all reads as an empty folder
    /// rather than as a refusal. A conformant `Depth: 1` always emits the
    /// collection's own row, so this shape is odd — but the backstop for the one
    /// server that would abuse it (a catch-all answering `207`-with-nothing to
    /// every path) is the negative control, which gets the same answer for a
    /// sibling that cannot exist and disqualifies the lane. Refusing here instead
    /// would only cost a real server that trims its own row.
    func testMultistatusWithNoRowsIsAnEmptyFolder() {
        XCTAssertEqual(parse(multistatus()), .entries([]))
    }

    func testTheThreeVerdictsNeverCompareEqual() {
        let empty = FileServerListingVerdict.entries([])
        XCTAssertNotEqual(empty, .absent,
                          "an empty folder and a missing folder are different facts")
        XCTAssertNotEqual(empty, .unusable(.notMultiStatus),
                          "an empty folder and an unreadable server are different facts")
        XCTAssertNotEqual(FileServerListingVerdict.absent, .unusable(.transport))
    }

    func testFourOhFourIsAbsentNotUnusableAndNotEmpty() {
        XCTAssertEqual(parse("", status: 404), .absent,
                       "the box Conduck minted is gone — its own verdict, and its own UI row")
    }

    /// Every non-`207` is a refusal. `200` is the one that matters most: a
    /// uniform-200 SSO wall answers every path with its own HTML, and requiring
    /// `207` is precisely what it cannot fake.
    func testNonMultiStatusStatusesAreRefusalsNotEmptyListings() {
        let body = multistatus(fileResponse(href: boxPath + "/report.pdf"))
        for status in [200, 201, 204, 301, 302, 405, 418] {
            XCTAssertEqual(parse(body, status: status), .unusable(.notMultiStatus),
                           "HTTP \(status) is not a listing")
        }
        XCTAssertEqual(parse(body, status: 401), .unusable(.unauthorized))
        XCTAssertEqual(parse(body, status: 403), .unusable(.unauthorized))
        XCTAssertEqual(parse(body, status: 500), .unusable(.serverError))
        XCTAssertEqual(parse(body, status: 503), .unusable(.serverError))
        // The whole 5xx range, including a `501` from a server with no PROPFIND
        // at all: the split between refusals exists to name the fault, and every
        // one of them leads to the same place — the turn stays open.
        XCTAssertEqual(parse(body, status: 501), .unusable(.serverError))
    }

    // MARK: - Completeness: the parse Bool decides

    /// THE regression this whole path exists for. The body below carries one
    /// COMPLETE response and then stops mid-document. A tolerant parser keeps the
    /// completed row and reports a listing that looks real; a truncated listing is
    /// indistinguishable from a short one, and the difference is a file silently
    /// missing from the user's device.
    func testMalformedXMLIsUnusableEvenWhenAResponseCompletedFirst() {
        let truncated = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(fileResponse(href: boxPath + "/report.pdf"))
        <D:response><D:href>\(boxPath)/notes.md
        """
        let verdict = parse(truncated)
        XCTAssertEqual(verdict, .unusable(.malformedBody),
                       "a body that faults mid-document teaches nothing about the folder")
        if case .entries = verdict {
            XCTFail("entries completed before a parse fault must never be reported as a listing")
        }
    }

    func testHTMLBodyUnderATwoOhSevenIsUnusable() {
        XCTAssertEqual(
            parse("<html><body>Sign in to continue</body></html>"),
            .unusable(.malformedBody),
            "a login page is not a multistatus document, whatever status it wears")
    }

    func testEmptyAndGarbageBodiesAreUnusable() {
        XCTAssertEqual(parse(""), .unusable(.malformedBody))
        XCTAssertEqual(
            FileServerClient.parseListing(
                status: 207, body: Data([0x00, 0xFF, 0x10, 0x42]), requestedURL: requestedURL()),
            .unusable(.malformedBody))
    }

    func testNonMultistatusRootElementIsUnusable() {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:error xmlns:D="DAV:"><D:response><D:href>\(boxPath)/report.pdf</D:href></D:response></D:error>
        """
        XCTAssertEqual(parse(body), .unusable(.malformedBody))
    }

    /// A response Conduck cannot understand IN FULL refuses the whole listing
    /// rather than being skipped — a skipped row is an entry that vanished
    /// without anyone deciding it should.
    func testResponseWithNoHrefOrTwoHrefsRefusesTheListing() {
        let noHref = """
        <D:response>
          <D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        """
        XCTAssertEqual(parse(multistatus(noHref)), .unusable(.malformedBody))

        let twoHrefs = """
        <D:response>
          <D:href>\(boxPath)/report.pdf</D:href>
          <D:href>\(boxPath)/other.pdf</D:href>
          <D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        """
        XCTAssertEqual(parse(multistatus(twoHrefs)), .unusable(.malformedBody))
    }

    // MARK: - Provenance: same origin, exact direct parent

    func testGrandchildHrefRefusesTheListing() {
        XCTAssertEqual(
            parse(multistatus(fileResponse(href: boxPath + "/sub/deep.pdf"))),
            .unusable(.entryOutsideCollection),
            "a Depth:1 listing of one box may not carry a file from a nested folder")
    }

    func testParentEscapeHrefRefusesTheListing() {
        for href in ["/\(conversationID)/other.pdf", "/elsewhere/report.pdf", "/report.pdf"] {
            XCTAssertEqual(
                parse(multistatus(fileResponse(href: href))),
                .unusable(.entryOutsideCollection),
                "\(href) is not a direct child of the collection that was asked for")
        }
    }

    /// Dot segments resolve away during RFC 3986 reference resolution, so this
    /// lands outside the base and is refused by the direct-child test rather than
    /// by a string check that could be spelled around.
    func testDotSegmentTraversalHrefRefusesTheListing() {
        XCTAssertEqual(
            parse(multistatus(fileResponse(href: boxPath + "/../../etc/passwd"))),
            .unusable(.entryOutsideCollection))
    }

    func testForeignOriginHrefRefusesTheListing() {
        for href in [
            "https://evil.example.test\(boxPath)/report.pdf",
            "http://fileserver.example.test\(boxPath)/report.pdf",
            "https://fileserver.example.test:8443\(boxPath)/report.pdf",
        ] {
            XCTAssertEqual(
                parse(multistatus(fileResponse(href: href))),
                .unusable(.entryOutsideCollection),
                "\(href) is not the file server the user configured")
        }
    }

    /// The same origin spelled with its default port explicitly IS the same
    /// origin — refusing it would break real servers for no safety gain.
    func testExplicitDefaultPortIsTheSameOrigin() {
        let verdict = parse(multistatus(
            fileResponse(href: "https://fileserver.example.test:443\(boxPath)/report.pdf")))
        XCTAssertEqual(names(verdict), ["report.pdf"])
    }

    /// THE decode-order bug, pinned. `%2E%2E%2F` survives reference resolution
    /// intact, so only splitting the path BEFORE decoding each component catches
    /// it; decoding first yields a single entry named `../../etc/passwd`, and
    /// `URL.appending(path:)` does not normalise dot segments back out.
    func testPercentEncodedSeparatorsAndTraversalRefuseTheListing() {
        for encodedName in [
            "%2E%2E%2F%2E%2E%2Fetc%2Fpasswd",
            "%2Fetc%2Fpasswd",
            "sub%2Fdeep.pdf",
            "%2E%2E",
            "%00",
            "report%00.pdf",
            "back%5Cslash.pdf",
        ] {
            XCTAssertEqual(
                parse(multistatus(fileResponse(href: "\(boxPath)/\(encodedName)"))),
                .unusable(.entryOutsideCollection),
                "\(encodedName) decodes to something that is not a single path component")
        }
    }

    // MARK: - Per-resource status

    /// RFC 4918 lets a `207` carry not-found rows. Emitting one as an ordinary
    /// entry mints a download chip for a file the server has just said it does
    /// not have.
    func testNotFoundPropstatRowIsDropped() {
        let notFound = """
        <D:response>
          <D:href>\(boxPath)/ghost.pdf</D:href>
          <D:propstat>
            <D:prop><D:getcontentlength/><D:resourcetype/></D:prop>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:propstat>
        </D:response>
        """
        let verdict = parse(multistatus(notFound, fileResponse(href: boxPath + "/report.pdf")))
        XCTAssertEqual(names(verdict), ["report.pdf"],
                       "a row whose only propstat failed is not evidence of a file")
    }

    func testResponseLevelNonSuccessStatusIsDropped() {
        let forbidden = """
        <D:response>
          <D:href>\(boxPath)/secret.pdf</D:href>
          <D:status>HTTP/1.1 403 Forbidden</D:status>
        </D:response>
        """
        XCTAssertEqual(names(parse(multistatus(forbidden, fileResponse(href: boxPath + "/report.pdf")))),
                       ["report.pdf"])
    }

    /// Properties are read only out of a 2xx propstat, so a length inside a
    /// failed one cannot describe the file.
    func testPropertiesFromAFailedPropstatAreIgnored() {
        let mixed = """
        <D:response>
          <D:href>\(boxPath)/report.pdf</D:href>
          <D:propstat>
            <D:prop><D:getcontentlength>999999</D:getcontentlength></D:prop>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:propstat>
          <D:propstat>
            <D:prop><D:resourcetype/></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        """
        guard case let .entries(entries) = parse(multistatus(mixed)) else {
            return XCTFail("expected entries")
        }
        XCTAssertEqual(entries.map(\.name), ["report.pdf"])
        XCTAssertEqual(entries.first?.byteSize, 0,
                       "a length the server reported as not-found is no length at all")
    }

    func testDirectoriesInsideTheBoxAreDropped() {
        let verdict = parse(multistatus(
            collectionResponse(href: boxPath + "/"),
            collectionResponse(href: boxPath + "/nested"),
            fileResponse(href: boxPath + "/report.pdf")
        ))
        XCTAssertEqual(names(verdict), ["report.pdf"], "a nested folder is not a deliverable")
    }

    // MARK: - Bounds

    func testEntryCapRefusesRatherThanTruncating() {
        let rows = (0..<(FileServerClient.listingMaxEntries + 1)).map {
            fileResponse(href: "\(boxPath)/file\($0).txt")
        }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(rows.joined(separator: "\n"))
        </D:multistatus>
        """
        XCTAssertEqual(parse(body), .unusable(.tooManyEntries),
                       "a silently truncated listing looks exactly like a complete short one")
    }

    func testEntryCapAdmitsExactlyTheCap() {
        let rows = (0..<FileServerClient.listingMaxEntries).map {
            fileResponse(href: "\(boxPath)/file\($0).txt")
        }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(rows.joined(separator: "\n"))
        </D:multistatus>
        """
        guard case let .entries(entries) = parse(body) else { return XCTFail("expected entries") }
        XCTAssertEqual(entries.count, FileServerClient.listingMaxEntries)
    }

    func testOversizedBodyIsRefusedBeforeItIsParsed() {
        XCTAssertEqual(
            FileServerClient.parseListing(
                status: 207,
                body: Data(count: FileServerClient.listingMaxBytes + 1),
                requestedURL: requestedURL()),
            .unusable(.bodyTooLarge))
    }

    func testDuplicateNamesRefuseTheListing() {
        XCTAssertEqual(
            parse(multistatus(
                fileResponse(href: boxPath + "/report.pdf"),
                fileResponse(href: boxPath + "/report.pdf")
            )),
            .unusable(.duplicateEntry),
            "one real collection cannot hold two entries of one name")
    }

    // MARK: - Property parsing details

    func testGarbageContentLengthReadsAsNoSizeRatherThanAWrongOne() {
        for raw in ["not-a-number", "-1", "+5", "12.5", "99999999999999999999999999"] {
            let row = """
            <D:response>
              <D:href>\(boxPath)/report.pdf</D:href>
              <D:propstat>
                <D:prop><D:getcontentlength>\(raw)</D:getcontentlength><D:resourcetype/></D:prop>
                <D:status>HTTP/1.1 200 OK</D:status>
              </D:propstat>
            </D:response>
            """
            guard case let .entries(entries) = parse(multistatus(row)) else {
                return XCTFail("expected entries for length \(raw)")
            }
            XCTAssertEqual(entries.first?.byteSize, 0,
                           "\(raw) is not a byte count; no size beats a wrong one")
        }
    }

    func testLowercaseNamespacePrefixParsesIdentically() {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>\(boxPath)/data.csv</d:href>
            <d:propstat>
              <d:prop><d:getcontentlength>512</d:getcontentlength><d:resourcetype/></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        guard case let .entries(entries) = parse(body) else { return XCTFail("expected entries") }
        XCTAssertEqual(entries.map(\.name), ["data.csv"])
        XCTAssertEqual(entries.first?.byteSize, 512)
    }

    /// The listing answers "is this a direct child", the validator answers "is
    /// this a name I will mint a key for". Keeping them separate is what lets the
    /// listing stay a statement about the SERVER while the name policy stays a
    /// statement about the CLIENT.
    func testPercentEncodedNameIsDecodedHereAndRejectedByTheNameValidator() {
        let verdict = parse(multistatus(fileResponse(href: boxPath + "/my%20report.pdf")))
        XCTAssertEqual(names(verdict), ["my report.pdf"],
                       "a legitimate encoded name decodes to one component")
        XCTAssertNil(FileServerClient.validatedOutboxEntryName("my report.pdf"),
                     "and the name gate is where a space is refused, not the listing")
    }

    // MARK: - A path-stripping reverse proxy

    /// The snapshot for a server mounted under a proxy path, plus the URL a
    /// listing of the box against it targets.
    private func mountedRequestedURL() -> URL {
        FileServerClient.listingCollectionURL(
            snapshot: SettingsManager.FileTransferSnapshot(
                baseURL: URL(string: "https://fileserver.example.test/files")!,
                username: Constants.fileServerUsername,
                credential: "deadbeefdeadbeefdeadbeefdeadbeef",
                certFingerprintHex: nil,
                available: true,
                folderCapable: true),
            collectionKey: boxKey)
    }

    private func parseMounted(_ body: String) -> FileServerListingVerdict {
        FileServerClient.parseListing(
            status: 207, body: Data(body.utf8), requestedURL: mountedRequestedURL())
    }

    /// Caddy's `handle_path /files/*` and an nginx `proxy_pass` with a trailing
    /// slash both STRIP the mount point before the WebDAV server sees the
    /// request, so the server builds its hrefs in the shortened path space it
    /// lives in. Requiring the requested URL's full prefix refused every row of a
    /// perfectly good listing, and the user got a permanent "Couldn't read your
    /// file server" with nothing to fix.
    func testPathStrippingProxyHrefsStillListTheBox() {
        let strippedBox = "/" + boxKey
        let verdict = parseMounted("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(collectionResponse(href: strippedBox + "/"))
        \(fileResponse(href: strippedBox + "/report.pdf", length: 2048))
        </D:multistatus>
        """)

        XCTAssertEqual(names(verdict), ["report.pdf"],
                       "a proxy that strips its own mount point still describes the box we asked for")
        guard case let .entries(entries) = verdict else { return XCTFail("expected entries") }
        XCTAssertEqual(entries.first?.byteSize, 2048)
    }

    /// The unstripped spelling of the same listing keeps working — the match is
    /// anchored at the END of the path, so the full prefix is simply the longest
    /// tail there is.
    func testUnstrippedHrefsUnderAMountedBaseStillListTheBox() {
        let fullBox = "/files/" + boxKey
        XCTAssertEqual(
            names(parseMounted("""
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
            \(collectionResponse(href: fullBox + "/"))
            \(fileResponse(href: fullBox + "/report.pdf"))
            </D:multistatus>
            """)),
            ["report.pdf"])
    }

    /// What the relaxation must NOT buy. Every one of these tail-matches the box
    /// by fewer components than it needs, or by the wrong ones — a listing of the
    /// served root, of the conversation folder, or of a look-alike box — and each
    /// still refuses the whole body. The shortest accepted parent is the box's own
    /// `out-<32 hex>` component, so an accepted row's immediate parent is always
    /// pinned to this dispatch's entropy.
    func testStrippedMatchingStillRefusesAnythingButTheBox() {
        for href in [
            "/report.pdf",                                   // the served root
            "/\(conversationID)/report.pdf",                 // the conversation folder
            "/out-ffffffffffffffff/report.pdf",              // a different box
            "/\(conversationID)/out-0123456789abcdef/sub/report.pdf", // a grandchild
        ] {
            XCTAssertEqual(
                parseMounted("""
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:">
                \(fileResponse(href: href))
                </D:multistatus>
                """),
                .unusable(.entryOutsideCollection),
                "\(href) is not a direct child of the box, stripped prefix or not")
        }
    }

    // MARK: - A response Conduck did not understand refuses the body

    /// A `<response>` nested below anything other than `<multistatus>` REFUSES
    /// the listing. Dropping it silently produced `.entries([])` — the "read and
    /// empty" verdict — which past the grace window stamps the turn done
    /// permanently: no row, no chip, and no way back to a file that is sitting on
    /// the server.
    func testResponseNestedBelowMultistatusRefusesTheBody() {
        let wrapped = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:sync>
        \(fileResponse(href: boxPath + "/report.pdf"))
          </D:sync>
        </D:multistatus>
        """
        let verdict = parse(wrapped)
        XCTAssertEqual(verdict, .unusable(.malformedBody),
                       "an unrecognised structure means the answer was not understood")
        XCTAssertNotEqual(verdict, .entries([]),
                          "and it must never read as a folder that was read and found empty")
    }

    /// The same rule for a `<response>` inside a `<response>` — the other way a
    /// row can hide from a direct-child walk.
    func testResponseNestedInsideAnotherResponseRefusesTheBody() {
        let nested = """
        <D:response>
          <D:href>\(boxPath)/outer.pdf</D:href>
          <D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        \(fileResponse(href: boxPath + "/inner.pdf"))
        </D:response>
        """
        XCTAssertEqual(parse(multistatus(nested)), .unusable(.malformedBody))
    }
}

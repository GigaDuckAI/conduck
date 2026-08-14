// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileServerProbeCleanupTests.swift
//
// Locks that the nested folder-capability probe leaves NOTHING behind on the
// user's file server, and that trying to clean up can never change what the
// probe reports.
//
// Why this matters more than tidiness: the served root IS the agent's own
// working directory. A directory the Test Connection creates and abandons is
// litter in a folder the user works in, and every `ls` the agent runs shows it.
//
// The two halves of the contract pull in opposite directions and both are
// asserted here:
//   - REMOVE what this call created — on every exit past the MKCOL, not just
//     the happy one.
//   - REMOVE NOTHING ELSE — the collection is named with this RUN'S entropy, so
//     a `201` is proof of creation rather than a guess. That matters because
//     rclone, the documented happy path, re-answers `201` for a MKCOL of a
//     collection that already exists: under a shared name two overlapping probes
//     both believed they owned the directory, and the first to finish took the
//     other's in-flight file with it. Anything but a `201` still removes
//     nothing, and a server that refuses the DELETE outright must still get its
//     real verdict.
//
// Deterministic + headless: `MockURLProtocol` transport, no network, no
// Keychain.
//
// Privacy: synthetic fixtures only; no real credentials / URLs / filenames.

import XCTest
@testable import Conduck

final class FileServerProbeCleanupTests: XCTestCase {

    private var session: URLSession!

    /// The request-URI tail a collection DELETE must carry. RFC 4918 §9.6 makes
    /// a collection DELETE a `Depth: infinity` operation, and servers that key
    /// on the trailing slash (nginx `dav_methods DELETE`) answer `409` without
    /// it and delete nothing.
    ///
    /// Matched by SHAPE rather than by a literal name: the collection is minted
    /// per run (`__conduck_probe_<8hex>__`), which is the whole ownership proof
    /// this file exists to lock. The flat probe file at the root ends `.txt`, so
    /// the two are still unambiguous.
    private static let collectionTail = "__/"

    /// Every request the probe issued, in order — the whole subject of this file.
    private final class Recorder: @unchecked Sendable {
        /// `(method, absolute URL)` pairs. The probe awaits each request before
        /// issuing the next, so plain vars captured by the handler are race-free.
        var calls: [(method: String, url: String)] = []

        var collectionDeletes: [Int] {
            calls.enumerated().compactMap { index, call in
                call.method == "DELETE" && call.url.hasSuffix(FileServerProbeCleanupTests.collectionTail) ? index : nil
            }
        }

        var fileDeletes: [Int] {
            calls.enumerated().compactMap { index, call in
                call.method == "DELETE" && call.url.hasSuffix(".txt") ? index : nil
            }
        }
    }

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - What the probe created, the probe removes

    func testAProbeThatCreatedTheCollectionRemovesItAfterTheFile() async {
        let recorder = install(mkcolStatus: 201)

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        XCTAssertEqual(outcome, .capable)
        XCTAssertEqual(recorder.collectionDeletes.count, 1,
                       "A collection this call created must be removed exactly once — the served root is the agent's own working directory, so an abandoned probe folder is litter the user sees.")
        XCTAssertEqual(recorder.fileDeletes.count, 1)
        XCTAssertLessThan(recorder.fileDeletes[0], recorder.collectionDeletes[0],
                          "File first, then the collection: a server that refuses to delete a NON-EMPTY collection would otherwise keep both.")
    }

    func testTheCollectionDeleteCarriesTheTrailingSlash() async {
        let recorder = install(mkcolStatus: 201)

        _ = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        let collectionDelete = recorder.calls[recorder.collectionDeletes[0]]
        XCTAssertTrue(collectionDelete.url.hasSuffix(Self.collectionTail),
                      "A collection DELETE without the trailing slash is a 409 on several DAV servers, which silently cleans nothing.")
    }

    func testTheCollectionIsRemovedWhenTheNestedWriteIsRejected() async {
        // A definitive folder rejection is still an exit past the MKCOL, so it
        // still owns the directory it made.
        let recorder = install(mkcolStatus: 201, nestedPutStatus: 403)

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        XCTAssertEqual(outcome, .rejected, "403 after a conclusive MKCOL is the definitive folder rejection.")
        XCTAssertEqual(recorder.collectionDeletes.count, 1,
                       "Cleanup runs on the failure exits too — a rejected probe litters exactly as much as a passing one.")
    }

    func testTheCollectionIsRemovedWhenTheNestedWriteFailsInTransport() async {
        let recorder = Recorder()
        MockURLProtocol.requestHandler = { request in
            recorder.calls.append((request.httpMethod ?? "", request.url?.absoluteString ?? ""))
            if request.httpMethod == "PUT" { throw URLError(.timedOut) }
            return (Self.http(request, request.httpMethod == "MKCOL" ? 201 : 204), Data())
        }

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        XCTAssertEqual(outcome, .indeterminate)
        XCTAssertEqual(recorder.collectionDeletes.count, 1,
                       "A transport failure mid-probe leaves the created directory behind unless cleanup runs on that exit too.")
    }

    // MARK: - What the probe did NOT create, it must not touch

    func testAPreexistingCollectionIsNeverDeleted() async {
        // `405` is RFC 4918's "already exists": another device, an older build,
        // or a probe running right now owns it. Deleting it recursively on that
        // evidence is a destructive act against the user's workspace on a guess.
        let recorder = install(mkcolStatus: 405)

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        XCTAssertEqual(outcome, .capable, "A 405 MKCOL is a normal, conclusive outcome — it changes nothing about the verdict.")
        XCTAssertTrue(recorder.collectionDeletes.isEmpty,
                      "Only a 201 proves THIS call minted the collection. Historic litter is left alone rather than swept blind.")
        XCTAssertEqual(recorder.fileDeletes.count, 1,
                       "The probe's OWN file is still cleaned up — that one it certainly wrote.")
    }

    func testAnAmbientMkcolFailureNeverDeletesTheCollection() async {
        // No status at all (transport failure): the probe does not know whether
        // a collection exists, let alone who made it.
        let recorder = Recorder()
        MockURLProtocol.requestHandler = { request in
            recorder.calls.append((request.httpMethod ?? "", request.url?.absoluteString ?? ""))
            if request.httpMethod == "MKCOL" { throw URLError(.networkConnectionLost) }
            if request.httpMethod == "PUT" { return (Self.http(request, 409), Data()) }
            return (Self.http(request, 204), Data())
        }

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        XCTAssertEqual(outcome, .indeterminate,
                       "A 409 after an INCONCLUSIVE MKCOL is explained by the missing parent, not by a folder-rejecting server.")
        XCTAssertTrue(recorder.collectionDeletes.isEmpty)
    }

    // MARK: - Cleanup may never decide the verdict

    func testARefusedCollectionDeleteLeavesTheVerdictUntouched() async {
        // Read-only-ish servers that take a file DELETE and refuse a collection
        // one are real. A test that failed because cleanup failed would be worse
        // than the litter it was cleaning.
        let recorder = Recorder()
        MockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            recorder.calls.append((request.httpMethod ?? "", url))
            switch request.httpMethod {
            case "MKCOL": return (Self.http(request, 201), Data())
            case "PUT": return (Self.http(request, 201), Data())
            case "GET": return (Self.http(request, 200), Data("conduck-nested-probe".utf8))
            case "DELETE":
                return (Self.http(request, url.hasSuffix(Self.collectionTail) ? 403 : 204), Data())
            default: return (Self.http(request, 204), Data())
            }
        }

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        XCTAssertEqual(outcome, .capable,
                       "The nested write landed and echoed. A server that will not remove the folder afterwards is still folder-capable.")
        XCTAssertEqual(recorder.collectionDeletes.count, 1, "It tried exactly once and swallowed the refusal.")
    }

    func testACollectionDeleteThatFailsInTransportLeavesTheVerdictUntouched() async {
        let recorder = Recorder()
        MockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            recorder.calls.append((request.httpMethod ?? "", url))
            if request.httpMethod == "DELETE" && url.hasSuffix(Self.collectionTail) {
                throw URLError(.cannotConnectToHost)
            }
            switch request.httpMethod {
            case "GET": return (Self.http(request, 200), Data("conduck-nested-probe".utf8))
            default: return (Self.http(request, 201), Data())
            }
        }

        let outcome = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        XCTAssertEqual(outcome, .capable,
                       "Cleanup is best-effort in the strongest sense: a transport failure on the DELETE is not a fact about folders.")
    }

    // MARK: - Ownership is provable, not guessed

    /// THE REPAIR. Under a shared collection name a `201` was not proof of
    /// creation — rclone, the documented happy path, re-answers `201` for a
    /// MKCOL of a directory that is already there — so two concurrent probes
    /// (two devices, or a Diagnostics sweep and a Settings tap) both believed
    /// they owned it, and the first to finish fired an RFC 4918 `Depth:
    /// infinity` DELETE through the other's in-flight file.
    func testEachRunOwnsItsOwnCollection() async {
        let first = install(mkcolStatus: 201)
        _ = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })
        let second = install(mkcolStatus: 201)
        _ = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        let firstCollection = first.calls[first.collectionDeletes[0]].url
        let secondCollection = second.calls[second.collectionDeletes[0]].url
        XCTAssertNotEqual(firstCollection, secondCollection,
                          "Two runs must never name the same collection, or a 201 cannot mean 'I created this'.")
        XCTAssertTrue(firstCollection.contains("/__conduck_probe_"),
                      "Still obviously Conduck's in an `ls` of the agent's own working directory.")
        for call in second.calls where call.method == "DELETE" {
            XCTAssertFalse(call.url == firstCollection,
                           "A run's recursive DELETE may only ever reach the directory that run created.")
        }
    }

    /// Every request one run issues stays inside that run's own collection, so
    /// there is no path by which a concurrent probe's file could be observed,
    /// overwritten, or removed.
    func testEveryNestedRequestStaysInsideThisRunsCollection() async {
        let recorder = install(mkcolStatus: 201)

        _ = await FileServerClient.probeFolderCapability(
            snapshot: makeSnapshot(), session: session, signals: { .empty })

        guard let collection = recorder.calls.first(where: { $0.method == "MKCOL" })?.url else {
            return XCTFail("the probe must MKCOL its own collection before writing into it")
        }
        for call in recorder.calls where call.method != "MKCOL" {
            XCTAssertTrue(call.url.hasPrefix(collection),
                          "Nothing outside the collection this run minted may be touched.")
        }
    }

    // MARK: - Fixtures

    /// A healthy rclone-shaped server whose MKCOL answers `mkcolStatus` and whose
    /// nested PUT answers `nestedPutStatus`; GET echoes the nested probe payload
    /// (the byte-echo the probe requires) and every DELETE succeeds.
    @discardableResult
    private func install(mkcolStatus: Int, nestedPutStatus: Int = 201) -> Recorder {
        let recorder = Recorder()
        MockURLProtocol.requestHandler = { request in
            recorder.calls.append((request.httpMethod ?? "", request.url?.absoluteString ?? ""))
            switch request.httpMethod {
            case "MKCOL": return (Self.http(request, mkcolStatus), Data())
            case "PUT": return (Self.http(request, nestedPutStatus), Data())
            case "GET": return (Self.http(request, 200), Data("conduck-nested-probe".utf8))
            default: return (Self.http(request, 204), Data())
            }
        }
        return recorder
    }

    private func makeSnapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://fileserver.example.test")!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: nil,
            available: true,
            folderCapable: false
        )
    }

    private static func http(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

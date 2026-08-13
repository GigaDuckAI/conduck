// SPDX-License-Identifier: Apache-2.0

//
//  OutboxNegativeControlTests.swift
//  ConduckTests
//
//  Coverage for `BackgroundFileTransfer.listCollection` — the network half of the
//  strict listing, driven through a `MockURLProtocol` session so the real
//  two-request sequence (the collection, then the negative control) runs without
//  a live file-server.
//
//  THE PROPERTY UNDER TEST: a listing is believed only on a lane that has just
//  DEMONSTRATED it can say no. A `207` for a sibling collection that cannot exist
//  means the server answers everything, so its `207` for the real box carries no
//  information — and a control that never ran proves nothing, so a transport
//  failure disqualifies rather than permits. That polarity is the opposite of
//  `folderCapable`, whose getter answers `true` when unset because it describes a
//  capability the app NARROWS on proof; this describes a proof the app REQUIRES.
//
//  Privacy: synthetic fixtures only; no real credentials/URLs/filenames logged.
//

import XCTest
@testable import Conduck

final class OutboxNegativeControlTests: XCTestCase {

    private let conversationID = "11111111-2222-3333-4444-555555555555"
    private let boxKey = "11111111-2222-3333-4444-555555555555/out-0123456789abcdef"
    private static let controlMarker = "__conduck_absent_"

    private var session: URLSession!

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

    // MARK: - Fixtures

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

    private func isControl(_ request: URLRequest) -> Bool {
        (request.url?.absoluteString ?? "").contains(Self.controlMarker)
    }

    private func listingBody() -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/\(boxKey)/</D:href>
            <D:propstat>
              <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/\(boxKey)/report.pdf</D:href>
            <D:propstat>
              <D:prop><D:getcontentlength>2048</D:getcontentlength><D:resourcetype/></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """.utf8)
    }

    private func http(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    /// Script the box's own PROPFIND and the control's independently.
    private func script(
        listing: (status: Int, body: Data),
        control: Int?,
        recorder: FileLaneRequestRecorder
    ) {
        MockURLProtocol.requestHandler = { [self] request in
            let url = request.url!
            recorder.record(method: request.httpMethod ?? "", url: url)
            if isControl(request) {
                guard let control else { throw URLError(.timedOut) }
                return (http(url, control), Data())
            }
            return (http(url, listing.status), listing.body)
        }
    }

    private func list(_ collectionKey: String? = nil) async -> FileServerListingVerdict {
        await BackgroundFileTransfer.listCollection(
            snapshot: makeSnapshot(),
            collectionKey: collectionKey ?? boxKey,
            session: session,
            evaluator: nil)
    }

    // MARK: - The control decides

    func testDefiniteMissOnTheControlPermitsTheListing() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()), control: 404, recorder: recorder)

        let verdict = await list()

        XCTAssertEqual(verdict, .entries([
            FileServerEntry(name: "report.pdf", isDirectory: false, byteSize: 2048)
        ]))
        XCTAssertEqual(recorder.calls.count, 2, "one listing, then one control")
        XCTAssertTrue(recorder.calls.allSatisfy { $0.method == "PROPFIND" },
                      "the control takes the SAME method as the thing it vouches for — a server "
                      + "that routes on the verb must be asked the same way")
    }

    func testAServerThatAnswersEverythingDisqualifiesTheListing() async {
        for controlStatus in [207, 200, 206, 301, 403, 500] {
            let recorder = FileLaneRequestRecorder()
            script(listing: (207, listingBody()), control: controlStatus, recorder: recorder)

            let verdict = await list()

            XCTAssertEqual(verdict, .unusable(.namespaceAnswersEverything),
                           "a control answered \(controlStatus) proves this lane cannot say no")
        }
    }

    /// FAILS CLOSED. A control that never got an answer proved nothing, so the
    /// listing it was supposed to vouch for stays unbelieved.
    func testTransportFailureOnTheControlDisqualifiesTheListing() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()), control: nil, recorder: recorder)

        let verdict = await list()
        XCTAssertEqual(verdict, .unusable(.transport))
        XCTAssertEqual(recorder.calls.count, 2, "the control was attempted and its failure kept")
    }

    func testTransportFailureOnTheListingItselfIsUnusable() async {
        let recorder = FileLaneRequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.record(method: request.httpMethod ?? "", url: request.url!)
            throw URLError(.cannotConnectToHost)
        }

        let verdict = await list()
        XCTAssertEqual(verdict, .unusable(.transport))
        XCTAssertEqual(recorder.calls.count, 1, "a failed listing spends no control request")
    }

    // MARK: - What the control is, and where it points

    /// A SIBLING collection under the same parent — not the root-relative file
    /// key `negativeControlKey` mints. Servers route on the prefix as well as the
    /// verb, so a control that lands somewhere else answers a question nobody
    /// asked.
    func testTheControlIsASiblingCollectionOfTheBox() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()), control: 404, recorder: recorder)
        _ = await list()

        guard let control = recorder.calls.last?.url else { return XCTFail("no control request") }
        let path = control.path()
        XCTAssertTrue(path.hasPrefix("/\(conversationID)/"),
                      "the control sits under the box's own parent")
        XCTAssertFalse(path.contains("/out-"), "the control is not the box")
        XCTAssertEqual(path.split(separator: "/").count, 2,
                       "sibling, not a deeper path")
        XCTAssertTrue(path.split(separator: "/").last?.hasPrefix(Self.controlMarker) == true)
    }

    /// Per-listing and never cached: two listings mint two different control
    /// keys. A stored verdict is a verdict about a server that has since changed,
    /// and there is deliberately no persisted key for one to live in.
    func testEachListingMintsItsOwnControlKey() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()), control: 404, recorder: recorder)

        _ = await list()
        _ = await list()

        let controls = recorder.calls.filter { $0.url.absoluteString.contains(Self.controlMarker) }
        XCTAssertEqual(controls.count, 2, "every listing runs its own control — none is reused")
        XCTAssertNotEqual(controls[0].url, controls[1].url,
                          "and each control key is minted fresh")
    }

    func testControlKeyForARootCollectionStaysAtTheRoot() {
        let key = FileServerClient.negativeControlCollectionKey(siblingOf: "out-0123456789abcdef")
        XCTAssertFalse(key.contains("/"), "a root-level box has a root-level sibling")
        XCTAssertTrue(key.hasPrefix(Self.controlMarker))
    }

    // MARK: - Verdicts that need no control

    /// `.absent` skips the control on purpose: a `404` for the box IS the server
    /// saying no, and absence mints nothing, so there is no positive verdict for
    /// a control to corroborate.
    func testAbsentBoxSpendsNoControlRequest() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (404, Data()), control: 404, recorder: recorder)

        let verdict = await list()
        XCTAssertEqual(verdict, .absent)
        XCTAssertEqual(recorder.calls.count, 1, "no control is needed to believe an absence")
    }

    func testRefusedListingSpendsNoControlRequest() async {
        for status in [200, 401, 500] {
            let recorder = FileLaneRequestRecorder()
            script(listing: (status, Data("<html>sign in</html>".utf8)), control: 404, recorder: recorder)

            let verdict = await list()
            if case .unusable = verdict {} else { XCTFail("HTTP \(status) must be unusable") }
            XCTAssertEqual(recorder.calls.count, 1,
                           "a listing that already failed closed needs no corroboration")
        }
    }

    /// An empty box is still a POSITIVE reading — the folder was read — so it
    /// runs the control like any other.
    func testEmptyListingStillRunsTheControl() async {
        let empty = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/\(boxKey)/</D:href>
            <D:propstat>
              <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """.utf8)

        let recorder = FileLaneRequestRecorder()
        script(listing: (207, empty), control: 404, recorder: recorder)
        let permitted = await list()
        XCTAssertEqual(permitted, .entries([]))
        XCTAssertEqual(recorder.calls.count, 2)

        let disqualified = FileLaneRequestRecorder()
        script(listing: (207, empty), control: 207, recorder: disqualified)
        let refused = await list()
        XCTAssertEqual(refused, .unusable(.namespaceAnswersEverything),
                       "an empty listing closes a turn, so it needs the same proof a full one does")
    }

    // MARK: - Bounded read

    /// There is no bound on what a server may return for a PROPFIND, and
    /// buffering it whole on a listing the user never asked for is a jetsam risk.
    /// Past the cap the answer is refused, never parsed as a truncated prefix.
    func testOversizedListingBodyIsRefusedNotTruncated() async {
        let padding = String(repeating: "<!-- pad -->", count: 40_000)
        let huge = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        \(padding)
        </D:multistatus>
        """.utf8)
        XCTAssertGreaterThan(huge.count, FileServerClient.listingMaxBytes)

        let recorder = FileLaneRequestRecorder()
        script(listing: (207, huge), control: 404, recorder: recorder)

        let verdict = await list()
        XCTAssertEqual(verdict, .unusable(.bodyTooLarge))
        XCTAssertEqual(recorder.calls.count, 1, "an over-cap body is refused before any control")
    }

    func testBoundedReadStopsAtTheCap() async {
        let body = Data(repeating: 0x41, count: 4096)
        MockURLProtocol.requestHandler = { [self] request in
            (http(request.url!, 207), body)
        }
        let request = FileServerClient.buildPropfindRequest(
            snapshot: makeSnapshot(), collectionKey: boxKey, depth: 1)

        let capped = try? await BackgroundFileTransfer.boundedListingResponse(
            session: session, request: request, maxBytes: 100)
        XCTAssertEqual(capped?.status, 207, "the status survives the cap — it is what decides")
        XCTAssertEqual(capped?.exceededCap, true)
        XCTAssertEqual(capped?.body.count, 100, "never one byte past the cap")

        let whole = try? await BackgroundFileTransfer.boundedListingResponse(
            session: session, request: request, maxBytes: 8192)
        XCTAssertEqual(whole?.exceededCap, false)
        XCTAssertEqual(whole?.body.count, 4096)
    }

    // MARK: - The request the listing actually issues

    func testTheListingTargetsTheBoxAndNotTheServedRoot() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()), control: 404, recorder: recorder)
        _ = await list()

        guard let first = recorder.calls.first else { return XCTFail("no request") }
        XCTAssertEqual(first.method, "PROPFIND")
        XCTAssertEqual(first.url.absoluteString, "https://fileserver.example.test/" + boxKey,
                       "a listing aimed at the served root would answer with every file every "
                       + "conversation ever uploaded")
    }
}

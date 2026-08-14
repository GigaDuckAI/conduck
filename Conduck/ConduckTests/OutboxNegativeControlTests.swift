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
//  DEMONSTRATED it can say no. A sibling collection that cannot exist, reported
//  as present, means the server answers everything, so its `207` for the real box
//  carries no information — and a control that never ran proves nothing, so a
//  transport failure disqualifies rather than permits. That polarity is the
//  opposite of `folderCapable`, whose getter answers `true` when unset because it
//  describes a capability the app NARROWS on proof; this describes a proof the
//  app REQUIRES.
//
//  AND WHAT "SAID NO" MEANS IS THE APP'S ONE DEFINITION. The control is decided
//  by `FileServerClient.negativeControlProvesNotFound`'s body-aware form — the
//  same `classifyAbsenceWitness` rule the pre-dispatch witness runs — so a bare
//  `404` and the compliant `207` whose single `<response>` names that exact
//  collection with a response-level `404` both pass, and everything short of an
//  unambiguous miss fails closed. The cases below lock both halves: the compliant
//  multistatus is believed (a status-only control would break file return end to
//  end on the hosts that send it), and every unreadable, over-cap, multi-row,
//  wrong-href or inner-`2xx` body is not.
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
    ///
    /// `controlBody` takes the control's URL because the control key is minted
    /// fresh on every listing — a fixture that hard-coded an href would be
    /// testing a body about some other collection, which is its own failure
    /// mode and has its own case below.
    private func script(
        listing: (status: Int, body: Data),
        control: Int?,
        controlBody: @escaping (URL) -> Data = { _ in Data() },
        recorder: FileLaneRequestRecorder
    ) {
        MockURLProtocol.requestHandler = { [self] request in
            let url = request.url!
            recorder.record(method: request.httpMethod ?? "", url: url)
            if isControl(request) {
                guard let control else { throw URLError(.timedOut) }
                return (http(url, control), controlBody(url))
            }
            return (http(url, listing.status), listing.body)
        }
    }

    /// The compliant "not there" multistatus: ONE `<response>` naming the
    /// collection that was asked about, carrying a RESPONSE-LEVEL status. Shares
    /// its shape with the witness fixtures in `FileServerClientTests`, because
    /// the two read the same rule.
    private func missMultistatus(
        href: String,
        innerStatus: String = "HTTP/1.1 404 Not Found"
    ) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>\(href)</D:href>
            <D:status>\(innerStatus)</D:status>
          </D:response>
        </D:multistatus>
        """.utf8)
    }

    /// The collection href a compliant server echoes for `url` — absolute path,
    /// trailing slash.
    private func collectionHref(of url: URL) -> String {
        url.path() + "/"
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

    // MARK: - The compliant `207` "not there", which is also a definite miss

    /// THE CASE THIS RULE EXISTS FOR. RFC 4918 lets a server report a missing
    /// collection as a `207` whose one `<response>` names it with a
    /// response-level `404`, and commercial WebDAV hosts send exactly that. A
    /// status-only control condemns those lanes — and condemns them on the very
    /// population the pre-dispatch witness has just cleared to name a folder, so
    /// the agent writes its files into a folder Conduck named and no chip ever
    /// appears for any of them.
    func testCompliantMultistatusMissOnTheControlPermitsTheListing() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()),
               control: 207,
               controlBody: { [self] url in missMultistatus(href: collectionHref(of: url)) },
               recorder: recorder)

        let verdict = await list()

        XCTAssertEqual(verdict, .entries([
            FileServerEntry(name: "report.pdf", isDirectory: false, byteSize: 2048)
        ]), "a host that says 'not there' in the multistatus form has demonstrated it can say no")
        XCTAssertEqual(recorder.calls.count, 2)
    }

    /// `410 Gone` is the same sentence with a history attached, and it counts as
    /// an INNER status exactly as `404` does.
    func testInnerGoneOnTheControlAlsoPermitsTheListing() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()),
               control: 207,
               controlBody: { [self] url in
                   missMultistatus(href: collectionHref(of: url), innerStatus: "HTTP/1.1 410 Gone")
               },
               recorder: recorder)

        let verdict = await list()
        XCTAssertEqual(verdict, .entries([
            FileServerEntry(name: "report.pdf", isDirectory: false, byteSize: 2048)
        ]))
    }

    /// THE INNER STATUS HAS TO SAY NO. A `207` whose response reports the
    /// sibling PRESENT is the catch-all namespace this control exists to catch,
    /// and reading the body must not soften that.
    func testControlWhoseInnerStatusIsSuccessDisqualifiesTheListing() async {
        for innerStatus in ["HTTP/1.1 200 OK", "HTTP/1.1 207 Multi-Status"] {
            let recorder = FileLaneRequestRecorder()
            script(listing: (207, listingBody()),
                   control: 207,
                   controlBody: { [self] url in
                       missMultistatus(href: collectionHref(of: url), innerStatus: innerStatus)
                   },
                   recorder: recorder)

            let verdict = await list()
            XCTAssertEqual(verdict, .unusable(.namespaceAnswersEverything),
                           "an inner \(innerStatus) claims the sibling is there")
        }
    }

    /// A `<propstat>` `404` says "you asked for properties I do not have on this
    /// resource" — an ordinary answer ABOUT AN EXISTING resource. Only the
    /// response-level status says the resource itself is not there.
    func testControlWithOnlyAPropstatNotFoundDisqualifiesTheListing() async {
        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()),
               control: 207,
               controlBody: { [self] url in
                   Data("""
                   <?xml version="1.0" encoding="utf-8"?>
                   <D:multistatus xmlns:D="DAV:">
                     <D:response>
                       <D:href>\(collectionHref(of: url))</D:href>
                       <D:propstat>
                         <D:prop><D:getcontentlength/></D:prop>
                         <D:status>HTTP/1.1 404 Not Found</D:status>
                       </D:propstat>
                     </D:response>
                   </D:multistatus>
                   """.utf8)
               },
               recorder: recorder)

        let verdict = await list()
        XCTAssertEqual(verdict, .unusable(.namespaceAnswersEverything))
    }

    /// EVERY WAY A CONTROL BODY CAN FAIL TO BE AN ANSWER, all landing on the
    /// same refusal. The list is the point: this control is what stands between
    /// a server's `207` and a tappable download chip, so only the reading a
    /// compliant server meant may pass it.
    func testUnreadableControlBodiesDisqualifyTheListing() async {
        let cases: [(name: String, body: (URL) -> Data)] = [
            ("empty", { _ in Data() }),
            ("not XML at all", { _ in Data("nope".utf8) }),
            ("not a multistatus root",
             { _ in Data("<html><body>Please sign in</body></html>".utf8) }),
            ("truncated mid-document",
             { [self] url in missMultistatus(href: collectionHref(of: url)).prefix(60) }),
            ("no inner status anywhere", { [self] url in
                Data("""
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>\(collectionHref(of: url))</D:href></D:response>
                </D:multistatus>
                """.utf8)
            }),
            ("an inner status nobody can read", { [self] url in
                missMultistatus(href: collectionHref(of: url),
                                innerStatus: "HTTP/1.1 not-a-code Hmm")
            }),
            ("more than one response row", { [self] url in
                Data("""
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:">
                  <D:response>
                    <D:href>\(collectionHref(of: url))</D:href>
                    <D:status>HTTP/1.1 404 Not Found</D:status>
                  </D:response>
                  <D:response>
                    <D:href>/somewhere/else/</D:href>
                    <D:status>HTTP/1.1 404 Not Found</D:status>
                  </D:response>
                </D:multistatus>
                """.utf8)
            }),
            ("a miss about some other collection",
             { [self] _ in missMultistatus(href: "/\(boxKey)/") }),
            ("a miss about another host",
             { [self] url in
                 missMultistatus(href: "https://elsewhere.example.test" + collectionHref(of: url))
             })
        ]

        for row in cases {
            let recorder = FileLaneRequestRecorder()
            script(listing: (207, listingBody()),
                   control: 207,
                   controlBody: row.body,
                   recorder: recorder)

            let verdict = await list()
            XCTAssertEqual(verdict, .unusable(.namespaceAnswersEverything),
                           "a control body that is \(row.name) settles nothing")
        }
    }

    /// THE CONTROL'S CAP IS THE WITNESS'S, NOT THE LISTING'S. One collection
    /// that does not exist is a few hundred bytes, so a control body past
    /// `absenceWitnessMaxBytes` has stopped being that answer — and the wire read
    /// stops there too, well inside the listing's own much larger budget, so a
    /// body documented as bounded at 16 KiB never reaches the parser at 256 KiB.
    func testOverCapControlBodyDisqualifiesTheListing() async {
        let padding = Data(repeating: 0x41, count: FileServerClient.absenceWitnessMaxBytes)
        XCTAssertLessThan(padding.count + 1024, FileServerClient.listingMaxBytes,
                          "the fixture has to be refused by the WITNESS's cap while staying "
                          + "inside the listing's — otherwise it proves nothing about which "
                          + "bound the control runs under")

        let recorder = FileLaneRequestRecorder()
        script(listing: (207, listingBody()),
               control: 207,
               controlBody: { [self] url in
                   var padded = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!-- ".utf8)
                   padded.append(padding)
                   padded.append(Data(" -->\n".utf8))
                   padded.append(missMultistatus(href: collectionHref(of: url)))
                   return padded
               },
               recorder: recorder)

        let verdict = await list()
        XCTAssertEqual(verdict, .unusable(.namespaceAnswersEverything),
                       "a body the reader had to cut proves nothing: the rest of it could say "
                       + "the sibling is right there")
    }

    /// ADDITIVE, NEVER A REPLACEMENT. A bare `404` is still a definite miss, and
    /// still decides on the status line alone — whatever the server padded it
    /// with is never read, so it can neither help nor hurt.
    func testBare404ControlStillProvesTheMissWhateverItsBody() async {
        for body in [Data(), Data("<html><body>Not found, friend</body></html>".utf8)] {
            let recorder = FileLaneRequestRecorder()
            script(listing: (207, listingBody()),
                   control: 404,
                   controlBody: { _ in body },
                   recorder: recorder)

            let verdict = await list()
            XCTAssertEqual(verdict, .entries([
                FileServerEntry(name: "report.pdf", isDirectory: false, byteSize: 2048)
            ]), "the 404 status line is the whole answer")
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

    // MARK: - One definition of a definite miss

    /// THE DRIFT GUARD. The listing's control and the pre-dispatch witness are
    /// the same question asked of the same server, so they must be the same
    /// rule: two definitions is how a lane gets cleared to name a folder on
    /// every dispatch while every listing of that folder is refused.
    func testTheControlRuleIsTheAbsenceWitnessRule() {
        let url = FileServerClient.listingCollectionURL(
            snapshot: makeSnapshot(), collectionKey: "\(conversationID)/__conduck_absent_abc123")
        let bodies: [Data] = [
            Data(),
            missMultistatus(href: collectionHref(of: url)),
            missMultistatus(href: collectionHref(of: url), innerStatus: "HTTP/1.1 410 Gone"),
            missMultistatus(href: collectionHref(of: url), innerStatus: "HTTP/1.1 200 OK"),
            missMultistatus(href: "/somewhere/else/"),
            Data("<html>sign in</html>".utf8)
        ]
        for status in [200, 207, 404, 401, 403, 405, 410, 501, 500, 302] {
            for body in bodies {
                for exceededCap in [false, true] {
                    XCTAssertEqual(
                        FileServerClient.negativeControlProvesNotFound(
                            status: status, body: body,
                            bodyExceededCap: exceededCap, requestedURL: url),
                        FileServerClient.classifyAbsenceWitness(
                            status: status, body: body,
                            bodyExceededCap: exceededCap, requestedURL: url) == .absent,
                        "status \(status) must mean the same thing to the control and the witness")
                }
            }
        }
    }

    /// The status-only form is UNCHANGED and still the whole answer for a `GET`
    /// probe's control, which has one truthful shape rather than two.
    func testTheStatusOnlyControlRuleIsStillExactlyA404() {
        XCTAssertTrue(FileServerClient.negativeControlProvesNotFound(status: 404))
        for status in [200, 201, 204, 206, 301, 302, 401, 403, 405, 410, 416, 500, 502, 207] {
            XCTAssertFalse(FileServerClient.negativeControlProvesNotFound(status: status),
                           "only a 404 status line is a definite miss on its own")
        }
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

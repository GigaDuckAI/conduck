// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileProbeBodyVerdictTests.swift
//
// The existence probe's verdict — the app's answer to a file server that
// CHANGED after the user set it up. Two ordinary, non-adversarial deployments
// both end with a convincing answer for a file that is not there:
//
//   1. An SSO portal in front of the server: every path 200s with a login page.
//   2. A static host with an SPA fallback (`try_files $uri /index.html`): a GET
//      for a missing `report.pdf` is rewritten INTERNALLY to a file that does
//      exist, so the client sees the URL it asked for and a textbook 206 with a
//      well-formed `Content-Range`. Nothing about that response is malformed.
//
// Case 2 is why the rule is uniform: no positive verdict comes from the
// candidate's own response, however good it looks. The discriminator is whether
// the namespace can say NO — the negative control.
//
// Two seams, both driven without a live file-server:
//   1. `FileServerClient.classifyProbe` — pure; the rules, one response at a
//      time. No network at all.
//   2. `BackgroundFileTransfer.probeExistsWithLength(…session:evaluator:)` —
//      the real two-request sequence (candidate, then the negative control) over
//      a `MockURLProtocol`-stubbed session, so the scenarios below are the ones
//      an actual server produces rather than hand-built evidence values.
//
// PRIVACY: the fixtures are synthetic; these tests assert on returned values and
// never on any emitted log (the probe path emits none).

import XCTest
@testable import Conduck

final class FileProbeBodyVerdictTests: XCTestCase {

    // MARK: - Fixtures

    private func snapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.test")!,
            username: "conduck",
            credential: "secret",
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        try await super.tearDown()
    }

    /// A hand-built response, for the pure rules. Every field the verdict can
    /// read is explicit so a test states the exact server behaviour it means.
    private func evidence(
        status: Int,
        contentRange: String? = nil,
        contentLength: String? = nil,
        contentType: String? = nil,
        contentEncoding: String? = nil,
        body: Data = Data(),
        delivered: Int64? = nil,
        exceededCap: Bool = false,
        finalName: String? = nil,
        key: String = "report.pdf"
    ) -> FileProbeEvidence {
        FileProbeEvidence(
            status: status,
            contentRange: contentRange,
            contentLength: contentLength,
            contentType: contentType,
            contentEncoding: contentEncoding,
            bodyPrefix: body,
            deliveredBytes: delivered ?? Int64(body.count),
            bodyExceededSniffCap: exceededCap,
            finalPathComponent: finalName ?? (key as NSString).lastPathComponent,
            requestedKey: key
        )
    }

    /// The shape an SSO portal / control-panel UI answers every path with — and
    /// also what an SPA fallback serves for a path that does not exist.
    private let loginPage = Data("""
    <!DOCTYPE html>
    <html lang="en"><head><title>Sign in</title></head>
    <body><form method="post" action="/login"><input name="password"></form></body>
    </html>
    """.utf8)

    private let pdfBytes = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\n".utf8)

    // MARK: - 1. classifyProbe — the range answers

    func testWellFormedRangedHitIsNeverBelievedOnItsOwn() {
        // The headline rule. This response is exactly what a healthy rclone
        // serves for a real file — and exactly what nginx's `try_files` fallback
        // serves for one that does not exist. Nothing in it can tell them apart,
        // so it buys the right to ask the control, not a verdict.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 206, contentRange: "bytes 0-0/4096", body: Data([0x25]))),
            .needsNegativeControl(byteLength: 4096),
            "the size comes from Content-Range, never the 1-byte Content-Length")
    }

    func testRangedHitWithoutContentRangeIsAmbiguous() {
        // A 206 is trivially forgeable as a status; the header is the only thing
        // that makes the response internally checkable at all.
        XCTAssertEqual(
            FileServerClient.classifyProbe(evidence(status: 206, body: Data([0x25]))),
            .settled(.ambiguous, byteLength: nil))
    }

    func testRangedHitWithUnknownCompleteLengthIsAmbiguous() {
        // `bytes 0-0/*` is legal HTTP but names no total, so there is no size for
        // the chip and nothing to check the delivered body against.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 206, contentRange: "bytes 0-0/*", body: Data([0x25]))),
            .settled(.ambiguous, byteLength: nil))
    }

    func testRangedHitThatStreamsTheWholeFileIsAmbiguous() {
        // The server promised one byte and then sent a file. A 206's body is
        // supposed to BE its Content-Range; this one contradicts itself.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 206, contentRange: "bytes 0-0/900000",
                         body: Data(repeating: 0x41, count: 1024),
                         delivered: 1025, exceededCap: true)),
            .settled(.ambiguous, byteLength: nil))
    }

    func testRangedHitBodyMustMatchItsOwnContentRangeExactly() {
        // Not an impostor heuristic — protocol-integrity validation. A response
        // claiming `bytes 0-0` must contain one byte, no more and no fewer.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 206, contentRange: "bytes 0-0/4096", body: Data())),
            .settled(.ambiguous, byteLength: nil),
            "a 206 that delivered nothing contradicts the single byte it promised")
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 206, contentRange: "bytes 0-0/4096", body: Data([0x25, 0x26]))),
            .settled(.ambiguous, byteLength: nil),
            "two bytes for a one-byte range is the same contradiction")
    }

    func testWidenedRangeIsAcceptedOnlyWhenTheBodyMatchesIt() {
        // A proxy may widen our one-byte ask. `first == 0` is required; `last` is
        // not pinned — but the delivered length must then equal the range it
        // declared, which is what makes the tolerance safe.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 206, contentRange: "bytes 0-1023/4096",
                         body: Data(repeating: 0x41, count: 1024))),
            .needsNegativeControl(byteLength: 4096))
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 206, contentRange: "bytes 0-1023/4096",
                         body: Data(repeating: 0x41, count: 512))),
            .settled(.ambiguous, byteLength: nil),
            "a declared 1024-byte range delivering 512 bytes is not coherent")
    }

    func testContentCodedRangeResponseIsAmbiguous() {
        // The probe asks for identity. An intermediary that compresses anyway
        // makes Content-Range describe encoded bytes while URLSession hands the
        // app decoded ones, so the integrity check is measuring two things.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 206, contentRange: "bytes 0-0/4096",
                         contentEncoding: "gzip", body: Data([0x25]))),
            .settled(.ambiguous, byteLength: nil))
    }

    func testEmptyFileNeedsTheEmptyRepresentationRange() {
        XCTAssertEqual(
            FileServerClient.classifyProbe(evidence(status: 416, contentRange: "bytes */0")),
            .needsNegativeControl(byteLength: 0),
            "bytes */0 is the empty-file answer (dufs) — still control-gated")
        // RFC 9110 also lets a server 416 because it rejected the range SET, and
        // a WAF or range-hostile proxy can 416 everything, so a bare 416 proves
        // nothing about the file.
        XCTAssertEqual(
            FileServerClient.classifyProbe(evidence(status: 416)),
            .settled(.ambiguous, byteLength: nil))
        XCTAssertEqual(
            FileServerClient.classifyProbe(evidence(status: 416, contentRange: "bytes */9000")),
            .settled(.ambiguous, byteLength: nil),
            "a 416 naming a NON-zero total contradicts our bytes=0-0 ask — not an empty file")
    }

    func testEmptyFile416IsNotVetoedByAnHTMLErrorPage() {
        // A 416 body is an ERROR representation, not file content, so an HTML one
        // says nothing about a wall. Applying the HTML veto here would refuse
        // every empty file on a server with styled error pages.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 416, contentRange: "bytes */0",
                         contentType: "text/html", body: loginPage, key: "empty.log")),
            .needsNegativeControl(byteLength: 0))
    }

    // MARK: - 2. classifyProbe — the statuses that need no body

    func testAbsentAuthAndServerFaultStatuses() {
        XCTAssertEqual(FileServerClient.classifyProbe(evidence(status: 404)),
                       .settled(.missing, byteLength: nil))
        XCTAssertEqual(FileServerClient.classifyProbe(evidence(status: 401)),
                       .settled(.unauthorized, byteLength: nil))
        XCTAssertEqual(FileServerClient.classifyProbe(evidence(status: 403)),
                       .settled(.unauthorized, byteLength: nil))
        XCTAssertEqual(FileServerClient.classifyProbe(evidence(status: 503)),
                       .settled(.serverError, byteLength: nil))
        // An unmapped status is a fact about the ENDPOINT, so it is lane-wide.
        XCTAssertEqual(FileServerClient.classifyProbe(evidence(status: 418)),
                       .settled(.unknown, byteLength: nil))
    }

    func testNotFoundStaysMissingEvenWhenItsErrorPageIsHTML() {
        // Real servers render HTML 404 pages. Absence mints nothing, so the body
        // has no verdict to change here — and treating an HTML 404 as ambiguous
        // would leave every honest not-found permanently unresolved.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 404, contentType: "text/html; charset=utf-8", body: loginPage)),
            .settled(.missing, byteLength: nil))
    }

    // MARK: - 3. classifyProbe — the bare 200

    func testPlainTwoHundredOfRealBytesDefersToTheNegativeControl() {
        // A range-ignoring server (nginx `max_ranges 0`, Apache `MaxRanges none`)
        // is legitimate — and indistinguishable, from this response alone, from a
        // wall.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, contentLength: "8342",
                         contentType: "application/pdf", body: pdfBytes)),
            .needsNegativeControl(byteLength: 8342))
    }

    func testContentCodedTwoHundredKeepsTheVerdictButDropsTheSize() {
        // Under a coding, Content-Length counts encoded bytes while the app is
        // handed decoded ones. No size beats a wrong size: the chip renders
        // without one and the large-download confirm stands down.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, contentLength: "1201", contentType: "application/pdf",
                         contentEncoding: "gzip", body: pdfBytes)),
            .needsNegativeControl(byteLength: nil))
    }

    func testLoginPageServedForANonHTMLKeyIsVetoedForFree() {
        // The served content and the requested name disagree — the signature of
        // both the wall and the SPA fallback. No control request needed.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, contentType: "text/html; charset=utf-8",
                         body: loginPage, key: "report.pdf")),
            .settled(.ambiguous, byteLength: nil))
    }

    func testContentTypeAloneVetoesEvenWithoutAnHTMLBody() {
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, contentType: "text/html",
                         body: Data("Please sign in.".utf8), key: "notes.md")),
            .settled(.ambiguous, byteLength: nil))
    }

    func testHTMLBodyAloneVetoesEvenWithoutAnHTMLContentType() {
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, contentType: nil, body: loginPage, key: "export.csv")),
            .settled(.ambiguous, byteLength: nil))
    }

    func testLegitimateHTMLFileIsNotVetoedByItsOwnContent() {
        // `html` is on the output allowlist, so a real deliverable CAN be an HTML
        // document. The veto fires on DISAGREEMENT, not on HTML; here the name
        // and the content agree, so the control decides.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, contentLength: "2048",
                         contentType: "text/html; charset=utf-8",
                         body: loginPage, key: "report.html")),
            .needsNegativeControl(byteLength: 2048))
    }

    func testResponseFromADifferentlyNamedResourceIsVetoed() {
        // The cheapest wall: a same-host redirect to /login that URLSession
        // follows for us, leaving a clean 200 and only the final URL remembering.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, contentType: "application/pdf", body: pdfBytes,
                         finalName: "login", key: "report.pdf")),
            .settled(.ambiguous, byteLength: nil))
    }

    func testKnownCostAnHTMLOpeningMarkdownFileIsVetoed() {
        // Stated as a decision, not discovered as a bug: a `README.md` whose very
        // first bytes are an HTML document is indistinguishable from a login page
        // by inspection, so it is refused. `.ambiguous` keeps the turn open AND
        // lets the pass go on to the next filename in the same reply.
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, body: loginPage, key: "README.md")),
            .settled(.ambiguous, byteLength: nil))
    }

    // MARK: - 4. The HTML sniff

    func testSniffRequiresATokenBoundarySoRealXMLSurvives() {
        // `<htmlReport>` is a perfectly ordinary XML root element. Without a
        // boundary check it reads as an HTML document and a real file is refused.
        XCTAssertFalse(
            FileServerClient.bodySniffsAsHTMLDocument(Data("<htmlReport><id>7</id></htmlReport>".utf8)))
        XCTAssertFalse(
            FileServerClient.bodySniffsAsHTMLDocument(Data("<!doctype htmlish>".utf8)))
        XCTAssertTrue(FileServerClient.bodySniffsAsHTMLDocument(Data("<html>".utf8)))
        XCTAssertTrue(FileServerClient.bodySniffsAsHTMLDocument(Data("<html lang=\"en\">".utf8)))
        XCTAssertTrue(FileServerClient.bodySniffsAsHTMLDocument(Data("<HTML/>".utf8)))
        XCTAssertTrue(FileServerClient.bodySniffsAsHTMLDocument(Data("<!DOCTYPE html>".utf8)))
    }

    func testSniffSkipsALeadingGeneratedBanner() {
        let banner = Data("""
        <!-- generated by acme-portal 4.2 -->
        <!doctype html>
        <html><body>Sign in</body></html>
        """.utf8)
        XCTAssertTrue(FileServerClient.bodySniffsAsHTMLDocument(banner),
                      "a comment banner above the doctype is an ordinary page shape")
    }

    func testXHTMLLoginPageBehindAnXMLDeclarationStillSniffs() {
        let xhtml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>Sign in</body></html>
        """.utf8)
        XCTAssertTrue(FileServerClient.bodySniffsAsHTMLDocument(xhtml))
        XCTAssertEqual(
            FileServerClient.classifyProbe(evidence(status: 200, body: xhtml, key: "data.json")),
            .settled(.ambiguous, byteLength: nil))
    }

    func testHTMLMentionedMidDocumentIsNotAVeto() {
        // The sniff is ANCHORED to the document start. Unanchored, it would veto
        // any Markdown, log, source file or CSV that merely mentions the tag —
        // all ordinary legitimate outputs.
        let markdown = Data("""
        # Release notes

        Wrap the fragment in `<html>` before serving it.
        """.utf8)
        XCTAssertEqual(
            FileServerClient.classifyProbe(
                evidence(status: 200, contentLength: "77",
                         contentType: "text/markdown", body: markdown, key: "notes.md")),
            .needsNegativeControl(byteLength: 77))
    }

    func testBinaryBodyNeverSniffsAsHTML() {
        XCTAssertFalse(
            FileServerClient.bodySniffsAsHTMLDocument(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])),
            "PNG magic decodes to replacement characters and must simply fail to match")
        XCTAssertFalse(FileServerClient.bodySniffsAsHTMLDocument(Data()))
    }

    // MARK: - 5. The pure helpers

    func testProbeKeyExtension() {
        XCTAssertEqual(FileServerClient.probeKeyExtension("report.pdf"), "pdf")
        XCTAssertEqual(FileServerClient.probeKeyExtension("REPORT.PDF"), "pdf")
        XCTAssertEqual(FileServerClient.probeKeyExtension("a1b2/report.tar.gz"), "gz")
        XCTAssertEqual(FileServerClient.probeKeyExtension("Makefile"), "")
        XCTAssertEqual(FileServerClient.probeKeyExtension(".hidden"), "",
                       "a leading dot is not an extension separator")
    }

    func testNegativeControlKeyIsRootOnlyUnguessableAndKeepsTheExtension() {
        let key = FileServerClient.negativeControlKey(forExtension: "pdf")
        XCTAssertFalse(key.contains("/"),
                       "root-only containment: a control key must not be able to express a path")
        XCTAssertTrue(key.hasPrefix("__conduck_absent_"))
        XCTAssertTrue(key.hasSuffix(".pdf"),
                      "servers route on extension, so the control must share the candidate's")
        XCTAssertNotEqual(key, FileServerClient.negativeControlKey(forExtension: "pdf"),
                          "the nonce must differ per call — a fixed key could be special-cased")
        XCTAssertFalse(FileServerClient.negativeControlKey(forExtension: "").contains("."))
    }

    func testOnlyANotFoundProvesTheNamespaceCanSayNo() {
        XCTAssertTrue(FileServerClient.negativeControlProvesNotFound(status: 404))
        for status in [200, 206, 301, 403, 416, 500] {
            XCTAssertFalse(FileServerClient.negativeControlProvesNotFound(status: status),
                           "\(status) for a key that cannot exist is not a credible not-found")
        }
    }

    func testContentRangeParsing() {
        XCTAssertEqual(FileServerClient.satisfiedRange("bytes 0-0/1")?.total, 1)
        XCTAssertNil(FileServerClient.satisfiedRange("bytes 0-0/0"),
                     "a zero total contradicts a SATISFIED range")
        XCTAssertNil(FileServerClient.satisfiedRange("bytes 5-5/4096"),
                     "we asked from byte 0; an answer about another offset is not our answer")
        XCTAssertNil(FileServerClient.satisfiedRange("bytes 0-9000/4096"),
                     "a last byte past the total is nonsense")
        XCTAssertNil(FileServerClient.satisfiedRange("items 0-0/4096"),
                     "only the bytes unit means anything here")
        XCTAssertNil(FileServerClient.satisfiedRange("bytes +0-0/4096"),
                     "HTTP's grammar is 1*DIGIT — signed forms are not numbers here")
        XCTAssertNil(FileServerClient.satisfiedRange("0-0/4096"))
        XCTAssertNil(FileServerClient.satisfiedRange(nil))
        XCTAssertTrue(FileServerClient.emptyRepresentationRange("bytes */0"))
        XCTAssertTrue(FileServerClient.emptyRepresentationRange("bytes */00"),
                      "leading zeroes are still 1*DIGIT")
        XCTAssertFalse(FileServerClient.emptyRepresentationRange("bytes */*"))
        XCTAssertFalse(FileServerClient.emptyRepresentationRange(nil))
    }

    func testContentTypeAndCodingHelpers() {
        XCTAssertTrue(FileServerClient.contentTypeIsHTMLDocument("text/html"))
        XCTAssertTrue(FileServerClient.contentTypeIsHTMLDocument("TEXT/HTML; charset=utf-8"))
        XCTAssertTrue(FileServerClient.contentTypeIsHTMLDocument("application/xhtml+xml"))
        XCTAssertFalse(FileServerClient.contentTypeIsHTMLDocument("text/plain"))
        XCTAssertFalse(FileServerClient.contentTypeIsHTMLDocument("application/octet-stream"))
        XCTAssertFalse(FileServerClient.contentTypeIsHTMLDocument(nil))

        XCTAssertTrue(FileServerClient.responseCodingIsIdentity(nil))
        XCTAssertTrue(FileServerClient.responseCodingIsIdentity("identity"))
        XCTAssertFalse(FileServerClient.responseCodingIsIdentity("gzip"))
        XCTAssertFalse(FileServerClient.responseCodingIsIdentity("br"))
    }

    // MARK: - 6. The whole sequence, over a stubbed server

    /// Scripts a fake file-server by last path component and records what was
    /// asked for, so a test can assert BOTH the verdict and whether the negative
    /// control was spent.
    ///
    /// `nonisolated(unsafe)` because `URLProtocol` calls the handler off the main
    /// actor; each test scripts its server, runs one probe sequence, and reads
    /// the record afterwards, so there is no concurrent access to protect.
    private final class FakeServer {
        nonisolated(unsafe) var handler: (String) -> (Int, [String: String], Data) = { _ in (404, [:], Data()) }
        nonisolated(unsafe) private(set) var requestedNames: [String] = []

        var controlRequests: [String] { requestedNames.filter { $0.hasPrefix("__conduck_absent_") } }

        func install() {
            MockURLProtocol.requestHandler = { [self] request in
                let name = request.url!.lastPathComponent
                requestedNames.append(name)
                let (status, headers, body) = handler(name)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: headers)!
                return (response, body)
            }
        }
    }

    private func probe(_ key: String) async -> (FileProbeOutcome, Int64?) {
        await BackgroundFileTransfer.probeExistsWithLength(
            snapshot: snapshot(), storedKey: key, session: mockSession(), evaluator: nil)
    }

    func testRealFileOnARangeHonouringServerExists() async {
        let server = FakeServer()
        server.handler = { name in
            name == "report.pdf"
                ? (206, ["Content-Range": "bytes 0-0/8342", "Content-Type": "application/pdf"],
                   Data([0x25]))
                : (404, [:], Data())
        }
        server.install()

        let (outcome, size) = await probe("report.pdf")
        XCTAssertEqual(outcome, .exists)
        XCTAssertEqual(size, 8342, "the chip's size comes from Content-Range on a 206")
        XCTAssertEqual(server.controlRequests.count, 1,
                       "every positive verdict is paid for with one control request")
    }

    func testEmptyFileExistsWithZeroLength() async {
        let server = FakeServer()
        server.handler = { name in
            name == "empty.log" ? (416, ["Content-Range": "bytes */0"], Data()) : (404, [:], Data())
        }
        server.install()

        let (outcome, size) = await probe("empty.log")
        XCTAssertEqual(outcome, .exists)
        XCTAssertEqual(size, 0)
    }

    func testFileTheAgentNeverWroteIsMissing() async {
        let server = FakeServer()
        server.handler = { _ in (404, [:], Data()) }
        server.install()

        let (outcome, size) = await probe("invented.csv")
        XCTAssertEqual(outcome, .missing, "a name the model made up must chip nothing")
        XCTAssertNil(size)
        XCTAssertTrue(server.controlRequests.isEmpty,
                      "absence needs no control — a missing candidate costs one request")
    }

    func testSPAFallbackServingAnExistingIndexIsNotExistence() async {
        // `try_files $uri /index.html`. The GET for a `report.html` that does not
        // exist is rewritten INTERNALLY to a file that does, so the response is a
        // textbook 206 under the requested URL with the requested extension —
        // every free check passes. Only the control sees it: the random key falls
        // through the same fallback and gets the same 206.
        let server = FakeServer()
        let index = loginPage
        server.handler = { _ in
            (206, ["Content-Range": "bytes 0-\(index.count - 1)/\(index.count)",
                   "Content-Type": "text/html; charset=utf-8"], index)
        }
        server.install()

        let (outcome, size) = await probe("report.html")
        XCTAssertEqual(outcome, .unknown,
                       "a well-formed 206 for a key that was never written is exactly the case "
                       + "no single response can catch")
        XCTAssertNil(size)
        XCTAssertEqual(server.controlRequests.count, 1)
    }

    func testSPAFallbackUnderANonHTMLNameIsCaughtWithoutSpendingAControl() async {
        let server = FakeServer()
        let index = loginPage
        server.handler = { _ in
            (206, ["Content-Range": "bytes 0-\(index.count - 1)/\(index.count)",
                   "Content-Type": "text/html; charset=utf-8"], index)
        }
        server.install()

        let (outcome, _) = await probe("report.pdf")
        XCTAssertEqual(outcome, .ambiguous,
                       "HTML under a .pdf name disagrees with itself — key-local, so the pass "
                       + "keeps scanning the rest of the reply")
        XCTAssertTrue(server.controlRequests.isEmpty)
    }

    func testLoginWallAnsweringEverythingWithHTMLIsNotExistence() async {
        // THE DEFECT THIS EXISTS FOR. Every path 200s with the portal's own page.
        // A status-only reading mints a download chip for a file nobody wrote.
        let server = FakeServer()
        let page = loginPage
        server.handler = { _ in (200, ["Content-Type": "text/html; charset=utf-8"], page) }
        server.install()

        let (outcome, size) = await probe("report.pdf")
        XCTAssertEqual(outcome, .ambiguous,
                       "an HTML page served under a .pdf name is the wall, not the file")
        XCTAssertNil(size)
        XCTAssertNotEqual(outcome, .exists, "this is the false chip the probe exists to prevent")
        XCTAssertNotEqual(outcome, .missing,
                          "we learned about the RESPONSE, not the file — .missing would close the "
                          + "turn on evidence we do not have")
        XCTAssertTrue(server.controlRequests.isEmpty,
                      "the extension disagreement vetoes for free; no control request is spent")
    }

    func testLoginWallIsCaughtEvenWhenTheCandidateIsItselfAnHTMLFile() async {
        // The hard case: a real `report.html` and an SSO wall are BOTH text/html
        // at 200, so nothing in that one response separates them. The negative
        // control does — the wall 200s a key that cannot exist.
        let server = FakeServer()
        let page = loginPage
        server.handler = { _ in (200, ["Content-Type": "text/html; charset=utf-8"], page) }
        server.install()

        let (outcome, _) = await probe("report.html")
        XCTAssertEqual(outcome, .unknown,
                       "a server that cannot say NO cannot be believed when it says YES")
        XCTAssertEqual(server.controlRequests.count, 1,
                       "exactly one control request decides it")
    }

    func testLegitimateHTMLFileOnAServerWithRealNotFoundSemanticsExists() async {
        let server = FakeServer()
        let report = Data("<!DOCTYPE html><html><body><h1>Q3</h1></body></html>".utf8)
        server.handler = { name in
            name == "report.html"
                ? (200, ["Content-Type": "text/html; charset=utf-8",
                         "Content-Length": String(report.count)], report)
                : (404, [:], Data())
        }
        server.install()

        let (outcome, size) = await probe("report.html")
        XCTAssertEqual(outcome, .exists,
                       "a real HTML deliverable must still chip — the veto is on disagreement, "
                       + "not on HTML")
        XCTAssertEqual(size, Int64(report.count))
        XCTAssertEqual(server.controlRequests.count, 1)
        XCTAssertTrue(server.controlRequests[0].hasSuffix(".html"),
                      "the control carries the candidate's extension")
    }

    func testRangeIgnoringServerServingALargeFileIsBoundedAndStillExists() async {
        // nginx `max_ranges 0` / Apache `MaxRanges none`: the range is dropped and
        // the whole file comes back at 200. Legitimate — and the reason the cap is
        // client-side, because otherwise this probe pulls the file into memory.
        let server = FakeServer()
        let huge = Data(repeating: 0x42, count: 400_000)
        server.handler = { name in
            name == "export.zip"
                ? (200, ["Content-Type": "application/zip", "Content-Length": "400000"], huge)
                : (404, [:], Data())
        }
        server.install()

        let (outcome, size) = await probe("export.zip")
        XCTAssertEqual(outcome, .exists)
        XCTAssertEqual(size, 400_000, "Content-Length IS the whole size when the range was ignored")
    }

    func testCollectProbeEvidenceStopsOneBytePastTheSniffCap() async throws {
        // The OOM guard, measured directly: a 400 KB body must cost ~1 KB.
        let server = FakeServer()
        let huge = Data(repeating: 0x42, count: 400_000)
        server.handler = { _ in (200, ["Content-Type": "application/zip"], huge) }
        server.install()

        let evidence = try await BackgroundFileTransfer.collectProbeEvidence(
            session: mockSession(),
            request: FileServerClient.buildProbeRequest(snapshot: snapshot(), storedKey: "export.zip"),
            requestedKey: "export.zip")

        XCTAssertEqual(evidence.bodyPrefix.count, Constants.fileServerProbeBodySniffBytes,
                       "the prefix never exceeds the cap")
        XCTAssertEqual(evidence.deliveredBytes, Int64(Constants.fileServerProbeBodySniffBytes) + 1,
                       "one byte past the cap is where the client stops and cancels")
        XCTAssertTrue(evidence.bodyExceededSniffCap)
    }

    func testCollectProbeEvidenceReadsAWholeSmallBody() async throws {
        let server = FakeServer()
        let body = Data([0x25])
        server.handler = { _ in (206, ["Content-Range": "bytes 0-0/8342"], body) }
        server.install()

        let evidence = try await BackgroundFileTransfer.collectProbeEvidence(
            session: mockSession(),
            request: FileServerClient.buildProbeRequest(snapshot: snapshot(), storedKey: "report.pdf"),
            requestedKey: "report.pdf")

        XCTAssertEqual(evidence.deliveredBytes, 1)
        XCTAssertFalse(evidence.bodyExceededSniffCap)
        XCTAssertEqual(evidence.contentRange, "bytes 0-0/8342")
        XCTAssertEqual(evidence.finalPathComponent, "report.pdf")
    }

    func testAuthWallAndServerFaultAreNeitherExistsNorMissing() async {
        // Both are lane-wide conditions the user can fix, so the turn must stay
        // pending rather than be permanently stamped as scanned.
        for (status, expected) in [(401, FileProbeOutcome.unauthorized),
                                   (503, FileProbeOutcome.serverError)] {
            let server = FakeServer()
            server.handler = { _ in (status, [:], Data("nope".utf8)) }
            server.install()

            let (outcome, size) = await probe("report.pdf")
            XCTAssertEqual(outcome, expected)
            XCTAssertNil(size)
            XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(outcome),
                           "\(status) must leave the turn open for a later pass")
        }
    }

    func testTransportFailureIsUnknownNeverMissing() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let (outcome, size) = await probe("report.pdf")
        XCTAssertEqual(outcome, .unknown,
                       "a dead tunnel says nothing about the file — a caller must not false-delete")
        XCTAssertNil(size)
    }

    func testAControlThatFailsInTransportDoesNotMintAChip() async {
        let server = FakeServer()
        server.handler = { _ in (206, ["Content-Range": "bytes 0-0/8342"], Data([0x25])) }
        MockURLProtocol.requestHandler = { request in
            if request.url!.lastPathComponent.hasPrefix("__conduck_absent_") {
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-0/8342"])!
            return (response, Data([0x25]))
        }

        let (outcome, _) = await probe("report.pdf")
        XCTAssertEqual(outcome, .unknown,
                       "an unanswered control is not a passed control")
    }

    // MARK: - 7. Composition with the output detector's verdict model

    func testOnlyExistsAndMissingCloseATurn() {
        // The probe's outcomes feed `scanMayClose` through `probeIsConclusive`.
        // Everything the body vetoes is deliberately NOT conclusive: a vetoed
        // candidate must be re-probed after the user fixes their server, never
        // stamped as permanently scanned.
        XCTAssertTrue(FileTransferOutputDetector.probeIsConclusive(.exists))
        XCTAssertTrue(FileTransferOutputDetector.probeIsConclusive(.missing))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.ambiguous))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.unknown))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.unauthorized))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.serverError))
        XCTAssertFalse(FileTransferOutputDetector.probeIsConclusive(.certRefused))
    }

    func testOnlyKeyLocalAmbiguityLetsThePassKeepScanning() {
        // The starvation guard. A pass stops on a LANE-wide failure because every
        // remaining probe would meet the same wall; it must NOT stop on a
        // key-local one, or one unreadable filename permanently hides every real
        // deliverable named after it in the same reply.
        XCTAssertFalse(FileTransferOutputDetector.probeFailureIsLaneWide(.ambiguous))
        XCTAssertTrue(FileTransferOutputDetector.probeFailureIsLaneWide(.unknown))
        XCTAssertTrue(FileTransferOutputDetector.probeFailureIsLaneWide(.unauthorized))
        XCTAssertTrue(FileTransferOutputDetector.probeFailureIsLaneWide(.serverError))
        XCTAssertTrue(FileTransferOutputDetector.probeFailureIsLaneWide(.certRefused))
    }
}

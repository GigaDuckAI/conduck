// SPDX-License-Identifier: Apache-2.0

//
//  FileServerConnectionTests.swift
//  ConduckTests
//
//  Locks the FileServer staged "Test Connection" state machine + nested-
//  write capability detection + transport-error → AppError taxonomy + the
//  PROPFIND parser edges the existing `FileServerClientTests` /
//  `FileServerPropfindTests` do NOT cover.
//
//  What this file pins (and why each can FAIL on a regression):
//    • `runConnectionTest(session:)` staged verdicts driven by a MockURLProtocol
//      session: reachability / auth / write / read-back / listing, and that
//      `success`+`folderCapable` flip ONLY on a full pass. A 5xx on the write is
//      NOT treated as auth (it stays a retryable server error at the WRITE
//      stage). The read-back round-trip is the false-positive guard: a read-only
//      Control-UI that 200s on GET but rejects the PUT (405) fails at the WRITE
//      stage rather than falsely passing.
//    • Nested-write probe → `FileTransferTestResult.folderCapable`, and that
//      `folderCapable == false` drives FLAT stored keys (`makeStoredKey(folder:nil)`).
//    • Transport-error mapping (exercised THROUGH `runConnectionTest`, since
//      `mapTransportError` is private): timeout / cannotConnectToHost /
//      serverCertificateUntrusted, and the pin-vs-no-pin distinction
//      (cert mismatch only when a fingerprint is pinned).
//    • PROPFIND parser edges the sibling test omits: a directory (collection)
//      flagged `isDirectory`, a percent-encoded href decoded, a trailing-slash
//      directory href, and a mixed/lowercase `d:` namespace prefix.
//
//  Deterministic + headless: no real network (URLProtocol injection), no
//  Keychain (the session is injected, so `runConnectionTest` never builds the
//  cert-pinned ephemeral session or reads secrets), no Core Data. The verdict is
//  compared via `FileTransferTestResult`'s `errorCode`-based `==`.
//
//  Privacy: synthetic fixtures only; no real credentials/URLs/filenames logged.
//

import XCTest
@testable import Conduck

final class FileServerConnectionTests: XCTestCase {

    private var session: URLSession!

    // The probe-file key the staged test mints is `__conduck_probe_<tag>.txt`
    // (flat) and the nested-capability probe is `__conduck_probe__/<tag>.txt`.
    // The nested probe is uniquely identifiable by the directory segment.
    private static let nestedDirMarker = "__conduck_probe__/"

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

    /// A synthetic file-transfer snapshot. `fingerprint` defaults to a pinned
    /// value so the cert-mismatch branch is exercised; pass nil for the no-pin
    /// case.
    private func makeSnapshot(
        base: String = "https://fileserver.example.test",
        fingerprint: String? = "aabbcc"
    ) -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: base)!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: fingerprint,
            available: false,
            folderCapable: true
        )
    }

    private func http(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func isNested(_ request: URLRequest) -> Bool {
        (request.url?.absoluteString ?? "").contains(Self.nestedDirMarker)
    }

    /// The healthy answer to the staged test's LISTING stage: `207` for a
    /// collection that exists, `404` for the one that cannot. Every handler that
    /// expects a full pass must script it — the return direction is a stage now,
    /// and a `default:` arm answering `200` is a server that cannot say no.
    private func propfindStatus(_ request: URLRequest) -> Int {
        (request.url?.absoluteString ?? "").contains("__conduck_absent_") ? 404 : 207
    }

    // MARK: - Staged verdicts: full pass

    /// Every stage 2xx + the nested probe also passes → success, reachedStage
    /// == .listing, no failure, folderCapable == true.
    func testFullPassWithNestedCapableYieldsSuccessListingStageAndFolderCapable() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            switch request.httpMethod {
            case "PUT":   return (self.http(request.url!, 201), Data())   // flat + nested write
            // The read stage now byte-echoes: the flat GET must return the flat
            // probe bytes and the nested GET the nested probe bytes, else the
            // byte-compare fails. Route each GET to the payload its stage PUT.
            case "GET":
                let body = self.isNested(request) ? "conduck-nested-probe" : "conduck-probe"
                return (self.http(request.url!, 200), Data(body.utf8))
            case "DELETE": return (self.http(request.url!, 204), Data())
            case "PROPFIND": return (self.http(request.url!, self.propfindStatus(request)), Data())
            default:      return (self.http(request.url!, 200), Data())
            }
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertEqual(result.reachedStage, .listing, "a full pass reaches the .listing stage")
        XCTAssertTrue(result.success, "every byte-moving stage 2xx + byte-echo + a listable lane → success")
        XCTAssertNil(result.failure, "success carries no failure")
        XCTAssertTrue(result.folderCapable, "a 2xx nested PUT+GET with echoed bytes → folderCapable true")
    }

    /// A uniform-200 auth-wall / SSO proxy that answers EVERY request with 200 +
    /// its own HTML (never the bytes we PUT) must FAIL the read stage on the
    /// byte-echo. A status-only check would wrongly PASS here (200 GET →
    /// `.exists`) and set `fileTransferAvailable` against a non-WebDAV endpoint;
    /// the byte-compare is what closes that false-positive.
    func testUniform200WithNonProbeBodyFailsReadStage() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            // Every method 200s with a login/HTML body — never the echoed probe.
            (self.http(request.url!, 200), Data("<html>login</html>".utf8))
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertFalse(result.success,
                       "a 200 GET whose body != the PUT probe bytes must NOT pass (uniform-200 auth-wall)")
        XCTAssertEqual(result.reachedStage, .read,
                       "reachability/auth/write pass on 200; the byte-echo fails at .read")
        XCTAssertEqual(result.failure?.errorCode, 61,
                       "wrong bytes back → fileTransferNotAFileServer (61): the login page IS the diagnosis. Never 48 — the server's own logs show a clean 200.")
    }

    /// Full connectivity pass but the NESTED write returns 405 (server needs
    /// MKCOL): the test still SUCCEEDS (nested probe is not a user-facing stage)
    /// but folderCapable narrows to false.
    func testFullPassButNestedRejectedDrivesFolderCapableFalse() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "PUT" {
                // Flat probe write succeeds; the nested probe write is rejected.
                let status = self.isNested(request) ? 405 : 201
                return (self.http(request.url!, status), Data())
            }
            if request.httpMethod == "GET" {
                return (self.http(request.url!, 200), Data("conduck-probe".utf8))
            }
            if request.httpMethod == "PROPFIND" {
                return (self.http(request.url!, self.propfindStatus(request)), Data())
            }
            return (self.http(request.url!, 204), Data())  // DELETE cleanup
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertTrue(result.success, "nested-probe rejection does NOT fail the connection test")
        XCTAssertEqual(result.reachedStage, .listing)
        XCTAssertNil(result.failure)
        XCTAssertFalse(result.folderCapable,
                       "a 405 on the nested PUT narrows folderCapable to false (flat-key fallback)")
    }

    /// rclone-shaped server: a nested PUT whose parent does NOT yet exist is
    /// rejected (409 — RFC 4918 §9.7; `rclone serve webdav` answers exactly
    /// this) and the parent only exists after an MKCOL. The probe must MKCOL
    /// the collection FIRST and then land the nested PUT → folderCapable TRUE.
    /// This is the regression lock for the stock-wizard rig (rclone is what
    /// conduck-connect installs): without the MKCOL the probe reads 409 and
    /// silently downgrades every conversation to flat keys.
    func testNestedProbeMkcolsFirstSoRcloneShapedServerIsFolderCapable() async {
        let snap = makeSnapshot()
        // The staged test awaits each request in sequence, so plain vars
        // captured by the handler are race-free.
        final class Box: @unchecked Sendable {
            var mkcolSeen = false
            var mkcolPrecededNestedPut = false
        }
        let box = Box()
        MockURLProtocol.requestHandler = { request in
            switch request.httpMethod {
            case "MKCOL":
                box.mkcolSeen = true
                return (self.http(request.url!, 201), Data())
            case "PUT":
                if self.isNested(request) {
                    box.mkcolPrecededNestedPut = box.mkcolSeen
                    // Parent exists only once MKCOL ran — otherwise rclone's 409.
                    return (self.http(request.url!, box.mkcolSeen ? 201 : 409), Data())
                }
                return (self.http(request.url!, 201), Data())
            case "GET":
                let body = self.isNested(request) ? "conduck-nested-probe" : "conduck-probe"
                return (self.http(request.url!, 200), Data(body.utf8))
            case "PROPFIND":
                return (self.http(request.url!, self.propfindStatus(request)), Data())
            default:
                return (self.http(request.url!, 204), Data())   // DELETE cleanup
            }
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertTrue(result.success)
        XCTAssertTrue(box.mkcolPrecededNestedPut,
                      "the probe must MKCOL the collection BEFORE the nested PUT")
        XCTAssertTrue(result.folderCapable,
                      "MKCOL-then-PUT landing on an rclone-shaped server → folderCapable true")
    }

    // MARK: - Staged verdicts: failures

    /// 401 on the write → auth stage failure (`fileTransferAuthFailed`, code 46).
    func testAuthRejectedOnWriteFailsAtAuthStage() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            (self.http(request.url!, 401), Data())
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reachedStage, .auth, "401 on the first request is an auth failure")
        XCTAssertEqual(result.failure?.errorCode, 46, "auth failure → fileTransferAuthFailed (46)")
        // A failed test never runs the nested probe; the failure-path result is
        // built WITHOUT a folderCapable argument, so it keeps the init DEFAULT
        // (true — flat fallback is a narrowing only flipped on a definitive
        // nested-PUT rejection). The flag is meaningless on failure (success is
        // false), but the default is locked here so a regression that changes
        // the failure-path default is caught.
        XCTAssertTrue(result.folderCapable,
                      "failure-path result keeps the folderCapable default (true)")
    }

    /// 403 on the write is ALSO an auth failure (the 401/403 pair).
    func testForbiddenOnWriteFailsAtAuthStage() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            (self.http(request.url!, 403), Data())
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertEqual(result.reachedStage, .auth)
        XCTAssertEqual(result.failure?.errorCode, 46, "403 → fileTransferAuthFailed (46)")
    }

    /// A 5xx on the write is NOT treated as auth — it fails at the WRITE stage
    /// with a retryable server error (`fileTransferServerError`, code 48). This
    /// is the contract that a sick server is distinguishable from a bad
    /// credential.
    func testServerErrorOnWriteIsNotAuthAndFailsAtWriteStage() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            (self.http(request.url!, 503), Data())
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reachedStage, .write, "a 5xx is NOT auth — it credits reachability+auth and fails the write")
        XCTAssertEqual(result.failure?.errorCode, 48, "5xx → fileTransferServerError (48), not auth (46)")
        XCTAssertNotEqual(result.failure?.errorCode, 46, "a 5xx must never be classified as auth")
    }

    /// A 405 Method Not Allowed on the write — the endpoint is not a writable
    /// WebDAV root — fails the WRITE stage with `fileTransferNotAFileServer`
    /// (61), NOT the generic `fileTransferUploadFailed` (49). The distinction is
    /// the whole point: 49 sends the user hunting a transport fault; 61 names the
    /// actual cause (wrong URL / read-only server).
    func testMethodNotAllowedOnWriteFailsAsNotAFileServer() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            (self.http(request.url!, 405), Data())
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reachedStage, .write)
        XCTAssertEqual(result.failure?.errorCode, 61, "405 write → fileTransferNotAFileServer (61)")
    }

    /// The false-positive guard: a read-only Control-UI gateway that answers a
    /// PUT with 405 (cannot write) must NEVER pass — even though it would 200 a
    /// GET. The write stage rejects it before the read-back is ever consulted.
    func testControlUIThatRejectsWriteIsNotAFalsePositive() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            // A Control-UI HTML page: GET always 200s with HTML, but the root is
            // not a writable WebDAV endpoint, so the PUT is refused.
            if request.httpMethod == "GET" {
                return (self.http(request.url!, 200),
                        Data("<html><body>OpenClaw Control UI</body></html>".utf8))
            }
            return (self.http(request.url!, 405), Data())  // PUT/DELETE refused
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertFalse(result.success, "a write-rejecting Control-UI 200-on-GET must NOT pass the test")
        XCTAssertEqual(result.reachedStage, .write, "it fails at the write stage, never reaching a trusted read")
        XCTAssertEqual(result.failure?.errorCode, 61,
                       "a 405 write (read-only Control-UI root) → fileTransferNotAFileServer (61)")
    }

    /// The read-back stage itself: write 2xx but the GET of the probe comes back
    /// 404 (the bytes did not actually land / are not served) → fails at the
    /// .read stage as `fileTransferNotAFileServer` (61). An endpoint that accepts
    /// a PUT and then can't serve it back is not a file server; blaming the
    /// server's health (48) would send the user to logs showing a clean 2xx.
    /// Proves the write+read round-trip is what's trusted, not the write alone.
    func testWriteSucceedsButReadBackMissingFailsAtReadStage() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in
            switch request.httpMethod {
            case "PUT":    return (self.http(request.url!, 201), Data())
            case "GET":    return (self.http(request.url!, 404), Data())  // probe not served back
            default:       return (self.http(request.url!, 204), Data())
            }
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertFalse(result.success, "a write that doesn't read back must not pass")
        XCTAssertEqual(result.reachedStage, .read, "the read-back stage is reached then fails")
        XCTAssertEqual(result.failure?.errorCode, 61, "read-back miss → fileTransferNotAFileServer (61)")
    }

    // MARK: - Transport-error mapping (through runConnectionTest)

    /// A connect-timeout URLError on the first request → reachability failure
    /// mapped to `fileTransferUnreachable` (code 45).
    func testTimeoutTransportErrorMapsToUnreachable() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reachedStage, .reachability)
        XCTAssertEqual(result.failure?.errorCode, 45, "timedOut → fileTransferUnreachable (45)")
    }

    /// cannotConnectToHost → unreachable (45).
    func testCannotConnectTransportErrorMapsToUnreachable() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertEqual(result.reachedStage, .reachability)
        XCTAssertEqual(result.failure?.errorCode, 45, "cannotConnectToHost → fileTransferUnreachable (45)")
    }

    /// A TLS rejection (serverCertificateUntrusted) WITH a pinned fingerprint,
    /// and NO confirmed pin rejection → certificate-not-trusted (66), the SAME
    /// answer as the unpinned case below. The system named the certificate; the
    /// pin was never consulted, so reporting 47 ("your fingerprint changed")
    /// would send the user to edit a pin that had nothing to do with it — and
    /// would spend the interception warning that only a real mismatch earns.
    func testCertUntrustedWithAPinButNoPinRejectionStaysCertUntrusted() async {
        let snap = makeSnapshot(fingerprint: "aabbcc")  // pinned
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.serverCertificateUntrusted)
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reachedStage, .reachability)
        XCTAssertEqual(result.failure?.errorCode, 66,
                       "cert-rejection with a pin but no confirmed pin rejection → fileTransferCertUntrusted (66)")
        XCTAssertNotEqual(result.failure?.errorCode, 47,
                          "a pin merely EXISTING must never relabel a system certificate rejection as a key mismatch")
    }

    /// The SAME TLS rejection WITHOUT a pin → certificate-not-trusted (66), NOT
    /// cert mismatch (47) and NOT unreachable (45). 45 is wrong here: the host
    /// answered, so "check your file-server is running" points the user at
    /// nothing.
    func testCertUntrustedWithoutPinMapsToCertUntrusted() async {
        let snap = makeSnapshot(fingerprint: nil)  // no pin
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.serverCertificateUntrusted)
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertEqual(result.failure?.errorCode, 66,
                       "cert-rejection with NO pin → fileTransferCertUntrusted (66)")
        XCTAssertNotEqual(result.failure?.errorCode, 47,
                          "without a pin, a TLS reject must NOT be reported as a cert mismatch")
    }

    /// An EMPTY-string fingerprint is treated as "no pin" (hasPin = false) — the
    /// production code is `pin?.isEmpty == false`. A cert reject with an empty
    /// pin maps to unreachable (45), not cert mismatch.
    func testEmptyFingerprintIsTreatedAsNoPin() async {
        let snap = makeSnapshot(fingerprint: "")  // empty == no pin
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.secureConnectionFailed)
        }

        let result = await FileServerClient.runConnectionTest(snapshot: snap, session: session)

        XCTAssertEqual(result.failure?.errorCode, 45,
                       "an empty-string fingerprint is hasPin=false → unreachable (45)")
    }

    // MARK: - folderCapable drives FLAT stored keys

    /// When the nested-write probe fails (folderCapable=false), the caller passes
    /// `folder: nil` to `makeStoredKey`, producing the FLAT historic key with no
    /// directory segment. This pins the consequence of the capability flag.
    func testFolderCapableFalseDrivesFlatStoredKey() {
        // Mirrors the call site's branch: folderCapable=false → folder argument
        // is nil → flat key.
        let uuid = UUID(uuidString: "8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F")!
        let flat = FileServerClient.makeStoredKey(originalName: "report.pdf", uuid: uuid, folder: nil)

        // First 8 hex of the UUID, lowercased, no dashes: "8e4e2d0a".
        XCTAssertEqual(flat, "8e4e2d0a__report.pdf",
                       "folderCapable=false → folder:nil → flat <8hex>__<name>")
        XCTAssertFalse(flat.contains("/"), "a flat key carries no directory separator")

        // And the folder-capable branch (folder supplied) prefixes a directory.
        let convID = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789"
        let nested = FileServerClient.makeStoredKey(originalName: "report.pdf", uuid: uuid, folder: convID)
        XCTAssertEqual(nested, "\(convID)/8e4e2d0a__report.pdf",
                       "folderCapable=true → folder supplied → <convID>/<8hex>__<name>")
    }

    // MARK: - PROPFIND parser edges (additive to FileServerPropfindTests)

    /// A 207 body with a directory entry (a `<resourcetype><collection/>`) must
    /// be flagged `isDirectory == true`. The sibling test filters dirs OUT; this
    /// asserts the flag is actually set.
    func testPropfindFlagsCollectionAsDirectory() {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/subdir</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/file.txt</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>10</D:getcontentlength>
                <D:resourcetype/>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = FileServerClient.parsePropfindBody(Data(body.utf8))

        let dir = entries.first { $0.name == "subdir" }
        XCTAssertNotNil(dir, "the collection entry must be parsed")
        XCTAssertEqual(dir?.isDirectory, true, "a <collection/> resourcetype → isDirectory true")
        XCTAssertEqual(dir?.byteSize, 0, "a directory has no getcontentlength → byteSize 0")

        let file = entries.first { $0.name == "file.txt" }
        XCTAssertEqual(file?.isDirectory, false, "a plain file (empty resourcetype) is NOT a directory")
        XCTAssertEqual(file?.byteSize, 10)
    }

    /// A percent-encoded href is decoded for display fidelity: `%20` → space.
    /// The entry name is the last path component, percent-decoded.
    func testPropfindDecodesPercentEncodedHref() {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/my%20report%20(final).pdf</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>2048</D:getcontentlength>
                <D:resourcetype/>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = FileServerClient.parsePropfindBody(Data(body.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "my report (final).pdf",
                       "percent-encoded href must be decoded for the entry name")
        XCTAssertEqual(entries.first?.byteSize, 2048)
        XCTAssertEqual(entries.first?.isDirectory, false)
    }

    /// A directory href with a TRAILING SLASH: the trailing slash is dropped
    /// before taking the last path component, so the name is the directory's own
    /// last component (not empty).
    func testPropfindHandlesTrailingSlashDirectoryHref() {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/photos/vacation/</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let entries = FileServerClient.parsePropfindBody(Data(body.utf8))

        XCTAssertEqual(entries.count, 1, "a trailing-slash dir href still yields exactly one entry")
        XCTAssertEqual(entries.first?.name, "vacation",
                       "trailing slash is dropped → name is the dir's last component, not empty")
        XCTAssertEqual(entries.first?.isDirectory, true)
    }

    /// A MIXED/lowercase namespace prefix (`d:` instead of `D:`) must parse
    /// identically — the parser matches the LOCAL element name namespace-
    /// agnostically. Also covers `getcontentlength` populating byteSize under the
    /// lowercase prefix.
    func testPropfindParsesLowercaseNamespacePrefix() {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/data.csv</d:href>
            <d:propstat>
              <d:prop>
                <d:getcontentlength>512</d:getcontentlength>
                <d:resourcetype/>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
        let entries = FileServerClient.parsePropfindBody(Data(body.utf8))

        XCTAssertEqual(entries.count, 1, "lowercase d: prefix parses the same as D:")
        XCTAssertEqual(entries.first?.name, "data.csv")
        XCTAssertEqual(entries.first?.byteSize, 512, "getcontentlength populates byteSize under d: prefix")
        XCTAssertEqual(entries.first?.isDirectory, false)
    }

    // MARK: - Non-mutating reach+auth probe (Diagnostics "Test connections")

    /// The status classifier is INVERTED vs `probeStatusPrefilter`: a 404 is the
    /// intended PASS (the server answered our impossible-key GET past the auth
    /// gate), a 200 is SUSPICIOUS, a 401/403 is auth-failed, and 405/other fails
    /// closed (NOT auth). Codex catch 2 — "404 = auth OK" is not protocol-universal,
    /// so the mapping is conservative.
    func testClassifyReachabilityMapping() {
        XCTAssertEqual(FileServerClient.classifyReachability(status: 404), .reachAuthOK)
        XCTAssertEqual(FileServerClient.classifyReachability(status: 401), .authFailed)
        XCTAssertEqual(FileServerClient.classifyReachability(status: 403), .authFailed)
        for exists in [200, 206, 416] {
            XCTAssertEqual(FileServerClient.classifyReachability(status: exists), .suspicious, "\(exists) exists-status is suspicious for a not-found probe")
        }
        for redirect in [301, 302, 307, 308] {
            XCTAssertEqual(FileServerClient.classifyReachability(status: redirect), .suspicious, "\(redirect) redirect is suspicious")
        }
        for closed in [405, 500, 501, 418] {
            XCTAssertEqual(FileServerClient.classifyReachability(status: closed), .inconclusive, "\(closed) fails closed, not auth-failed")
        }
    }

    /// END-TO-END through the public method with an injected session (Codex catch:
    /// test the full method, not just the parser). A 404 → reach/auth OK; the probe
    /// is a single non-mutating GET (never a PUT/DELETE).
    func testProbeReachability404YieldsReachAuthOK() async {
        let snap = makeSnapshot()
        var methods: Set<String> = []
        MockURLProtocol.requestHandler = { request in
            methods.insert(request.httpMethod ?? "?")
            return (self.http(request.url!, 404), Data())
        }
        let outcome = await FileServerClient.probeReachability(snapshot: snap, session: session)
        XCTAssertEqual(outcome, .reachAuthOK)
        XCTAssertEqual(methods, ["GET"], "the reach probe is a single non-mutating GET — no PUT/DELETE")
    }

    func testProbeReachability401YieldsAuthFailed() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in (self.http(request.url!, 401), Data()) }
        let outcome = await FileServerClient.probeReachability(snapshot: snap, session: session)
        XCTAssertEqual(outcome, .authFailed)
    }

    func testProbeReachability200IsSuspicious() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in (self.http(request.url!, 200), Data("<html>login</html>".utf8)) }
        let outcome = await FileServerClient.probeReachability(snapshot: snap, session: session)
        XCTAssertEqual(outcome, .suspicious, "a 200 on a not-found probe is a Control-UI/login page — suspicious, not a pass")
    }

    func testProbeReachability416IsSuspicious() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in (self.http(request.url!, 416), Data()) }
        let outcome = await FileServerClient.probeReachability(snapshot: snap, session: session)
        XCTAssertEqual(outcome, .suspicious)
    }

    func testProbeReachability3xxIsSuspicious() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in (self.http(request.url!, 302), Data()) }
        let outcome = await FileServerClient.probeReachability(snapshot: snap, session: session)
        XCTAssertEqual(outcome, .suspicious, "a raw redirect (redirect-to-login risk) is flagged, not passed")
    }

    func testProbeReachability405FailsClosed() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { request in (self.http(request.url!, 405), Data()) }
        let outcome = await FileServerClient.probeReachability(snapshot: snap, session: session)
        XCTAssertEqual(outcome, .inconclusive, "405 is method/endpoint, NOT a bad credential — fail closed")
    }

    func testProbeReachabilityTransportErrorIsUnreachable() async {
        let snap = makeSnapshot()
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotConnectToHost) }
        let outcome = await FileServerClient.probeReachability(snapshot: snap, session: session)
        XCTAssertEqual(outcome, .unreachable)
    }

    // MARK: - The two file-lane probes must tell ONE story about one server

    /// One attempt's verdicts, STATED IN FULL — the shape the probe seam takes.
    /// Nothing here is inferred from the snapshot's pin: a seam that derived
    /// `challengeRefused` from "a pin is configured" let these cases lock a
    /// shape production never produces (a cold tunnel raises no challenge, so
    /// nothing can have refused it), and it kept alive on a test path the exact
    /// pin-as-proxy the classifier removed.
    private func signals(
        systemTrustRejected: Bool = false,
        challengeRefused: Bool = false,
        pinRejected: Bool = false,
        pinComparisonUnsupported: Bool = false
    ) -> @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals {
        let snapshot = RemoteAgentTrustEvaluator.AttemptTrustSignals(
            systemTrustRejected: systemTrustRejected,
            challengeRefused: challengeRefused,
            pinRejected: pinRejected,
            pinComparisonUnsupported: pinComparisonUnsupported)
        return { snapshot }
    }

    func testProbeReachabilityReportsAConfirmedPinMismatchAsItsOwnOutcome() async {
        // THE DEFECT: the reach probe read only `systemTrustRejected`, so a
        // genuine pin mismatch — the host presented a certificate this device
        // TRUSTS and the pinned key disagreed — collapsed into `.unreachable`
        // and Diagnostics rendered "check your file-server is running". That is
        // the one signal that means the connection may be intercepted, and it
        // was being thrown away for a row about a server that is running fine.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }
        let outcome = await FileServerClient.probeReachability(
            snapshot: makeSnapshot(fingerprint: "aabbcc"),
            session: session,
            signalsOverride: signals(challengeRefused: true, pinRejected: true))
        XCTAssertEqual(outcome, .certMismatch,
                       "A confirmed digest disagreement keeps its own outcome — it is not a reachability problem and not an untrusted certificate.")
    }

    func testProbeReachabilityKeepsTheUntrustedVerdictAheadOfTheMismatch() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }
        let outcome = await FileServerClient.probeReachability(
            snapshot: makeSnapshot(fingerprint: "aabbcc"),
            session: session,
            signalsOverride: signals(systemTrustRejected: true,
                                     challengeRefused: true,
                                     pinRejected: true))
        XCTAssertEqual(outcome, .certUntrusted,
                       "Same precedence as every other lane: a chain this device refused is the truthful statement, so it outranks the key mismatch.")
    }

    func testProbeReachabilityGivesAnUnpinnableKeyItsOwnOutcome() async {
        // System trust PASSED and nothing disagreed — the leaf's key algorithm
        // is outside the SPKI prefix table, so no digest could be computed to
        // compare. Reading that as `.certMismatch` would raise the app's most
        // alarming message over a certificate that is fine.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }
        let outcome = await FileServerClient.probeReachability(
            snapshot: makeSnapshot(fingerprint: "aabbcc"),
            session: session,
            signalsOverride: signals(challengeRefused: true,
                                     pinRejected: true,
                                     pinComparisonUnsupported: true))
        XCTAssertEqual(outcome, .certKeyUnpinnable,
                       "A key Conduck cannot fingerprint is not an interception signal and must not borrow the mismatch outcome.")
    }

    func testProbeReachabilityNamesTheCertificateWhenTheSystemDoes() async {
        // No evaluator signal at all (an injected session carries none), but the
        // SYSTEM named the certificate in the error code. The staged write test
        // has always resolved these to a certificate verdict; the reach probe
        // discarded them, so the same server produced two different stories.
        for code in [URLError.Code.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            MockURLProtocol.requestHandler = { _ in throw URLError(code) }
            let outcome = await FileServerClient.probeReachability(
                snapshot: makeSnapshot(fingerprint: nil),
                session: session)
            XCTAssertEqual(outcome, .certUntrusted,
                           "\(code): the host answered and this device refused its certificate — never 'check your file-server is running'.")
        }
    }

    func testProbeReachabilityLeavesAColdTunnelRetryable() async {
        // The regression guard both probes share: a generic `-1200` with neither
        // signal set is a transient handshake failure, not a certificate verdict.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let outcome = await FileServerClient.probeReachability(
            snapshot: makeSnapshot(fingerprint: "aabbcc"),
            session: session,
            signalsOverride: signals())
        XCTAssertEqual(outcome, .unreachable,
                       "A cold tunnel on a pinned lane must stay retryable — no verdict fired, so nothing rejected a certificate.")
    }

    func testProbeReachabilityLeavesAnUnpinnedCancelAlone() async {
        // An unpinned probe cannot be cancelled BY the evaluator (it returns
        // default handling), so a -999 there is a real cancellation — even with
        // the advisory system-trust flag latched. `challengeRefused: false` is
        // the whole statement now, and it is the honest one: the evaluator did
        // not refuse this challenge.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }
        let outcome = await FileServerClient.probeReachability(
            snapshot: makeSnapshot(fingerprint: nil),
            session: session,
            signalsOverride: signals(systemTrustRejected: true))
        XCTAssertEqual(outcome, .unreachable,
                       "An unpinned cancel is not a certificate verdict; promoting it would blame the certificate for a cancelled probe.")
    }
}

//
//  FileServerClientTests.swift
//  ConduckTests
//
//  Unit coverage for the pure `FileServerClient` request-builder + parser
//  surface. These tests are fully deterministic and run unsigned:
//  no network, no Keychain, no Core Data. They lock the wire-level invariants the
//  file-transfer feature depends on:
//    • storedKey shape  = "<8 lowercase hex>__<sanitized original>"
//    • basic-auth header = "Basic " + base64("user:pass")
//    • request shapes    = correct HTTP verb (PUT upload / GET download+probe —
//                          NEVER HEAD / DELETE / PROPFIND), URL = base/storedKey,
//                          Authorization Basic present, timeouts from Constants.
//    • parseProbeOutcome = the exact status→outcome table.
//
//  Privacy: no real credentials/URLs/filenames are logged; the fixtures below are
//  synthetic and never printed.
//

import XCTest
@testable import Conduck

final class FileServerClientTests: XCTestCase {

    // MARK: - Fixtures

    /// A synthetic snapshot pointing at a fake base URL. `baseURL` deliberately has
    /// NO trailing slash so we exercise `appending(path:)` path-joining.
    private func makeSnapshot(
        base: String = "https://fileserver.example.test",
        fingerprint: String? = "AA:BB:CC",
        available: Bool = true,
        folderCapable: Bool = true
    ) -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: base)!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: fingerprint,
            available: available,
            folderCapable: folderCapable
        )
    }

    /// Fresh `MockURLProtocol`-backed session per transport test.
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - makeStoredKey

    func testMakeStoredKeyShapeIsShortHexThenDoubleUnderscoreThenName() {
        let uuid = UUID(uuidString: "A1B2C3D4-E5F6-7890-1234-567890ABCDEF")!
        let key = FileServerClient.makeStoredKey(originalName: "report.pdf", uuid: uuid)

        // "<8 lowercase hex>__<sanitized>"
        let parts = key.components(separatedBy: "__")
        XCTAssertEqual(parts.count, 2, "storedKey must contain exactly one '__' separator")
        let prefix = parts[0]
        XCTAssertEqual(prefix.count, 8, "shortid is the first 8 hex of the UUID")
        XCTAssertEqual(prefix, prefix.lowercased(), "shortid must be lowercase")
        XCTAssertEqual(prefix, "a1b2c3d4", "shortid = first 8 hex of the UUID, lowercased")
        XCTAssertTrue(prefix.allSatisfy { $0.isHexDigit }, "shortid must be hex")
        XCTAssertEqual(parts[1], "report.pdf", "a clean name passes through unchanged")
    }

    func testMakeStoredKeyIsDeterministicForSameUUIDAndName() {
        let uuid = UUID()
        let a = FileServerClient.makeStoredKey(originalName: "data.csv", uuid: uuid)
        let b = FileServerClient.makeStoredKey(originalName: "data.csv", uuid: uuid)
        XCTAssertEqual(a, b, "same uuid + name must yield the same storedKey")
    }

    func testMakeStoredKeyPrefixVariesWithUUID() {
        let name = "x.txt"
        let a = FileServerClient.makeStoredKey(originalName: name, uuid: UUID())
        let b = FileServerClient.makeStoredKey(originalName: name, uuid: UUID())
        // Astronomically unlikely to collide on the first 8 hex; guards determinism
        // is keyed on the UUID, not a constant.
        XCTAssertNotEqual(a, b, "different UUIDs should produce different prefixes")
    }

    func testMakeStoredKeySanitizesUnsafeCharacters() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let key = FileServerClient.makeStoredKey(
            originalName: "my report (final)/v2:draft?.pdf",
            uuid: uuid
        )
        let name = key.components(separatedBy: "__")[1]
        // Sanitize keeps [A-Za-z0-9._-], replaces everything else with "_".
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        XCTAssertTrue(
            name.unicodeScalars.allSatisfy { allowed.contains($0) },
            "sanitized name must only contain [A-Za-z0-9._-]"
        )
        XCTAssertFalse(name.contains(" "), "spaces must be replaced")
        XCTAssertFalse(name.contains("/"), "slashes must be replaced")
        XCTAssertFalse(name.contains(":"), "colons must be replaced")
        XCTAssertFalse(name.contains("?"), "question marks must be replaced")
    }

    func testMakeStoredKeyPreservesDotsDashesUnderscores() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let key = FileServerClient.makeStoredKey(originalName: "a.b-c_d.tar.gz", uuid: uuid)
        let name = key.components(separatedBy: "__")[1]
        XCTAssertEqual(name, "a.b-c_d.tar.gz", "dots, dashes, underscores are preserved")
    }

    func testMakeStoredKeyFallsBackToFileForEmptySanitizedName() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        // A name that sanitizes to nothing meaningful → non-empty fallback "file".
        let key = FileServerClient.makeStoredKey(originalName: "", uuid: uuid)
        let name = key.components(separatedBy: "__")[1]
        XCTAssertEqual(name, "file", "empty original name falls back to 'file'")
    }

    // MARK: - makeStoredKey — per-conversation folder prefix

    /// With a `folder`, the key is `<folder>/<8hex>__<name>` — the folder is a
    /// real path component followed by a single `/` separator, then the historic
    /// flat key.
    func testMakeStoredKeyWithFolderPrefixesConversationDirectory() {
        let uuid = UUID(uuidString: "A1B2C3D4-E5F6-7890-1234-567890ABCDEF")!
        let convID = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789"
        let key = FileServerClient.makeStoredKey(originalName: "report.pdf", uuid: uuid, folder: convID)

        XCTAssertEqual(key, "\(convID)/a1b2c3d4__report.pdf",
                       "key = <conversationID>/<8hex>__<name>")
        // Exactly one slash (the folder/file separator) — the folder + the 8hex
        // prefix + name carry no slashes themselves.
        XCTAssertEqual(key.filter { $0 == "/" }.count, 1,
                       "exactly one '/' separator between folder and filename")
        // The conversationID UUID string is carried VERBATIM (already in the
        // WebDAV-safe set).
        XCTAssertTrue(key.hasPrefix("\(convID)/"), "folder segment is the convID verbatim")
    }

    /// A nil / empty folder yields the historic FLAT key (no leading slash) — the
    /// folderCapable==false fallback.
    func testMakeStoredKeyNilFolderStaysFlat() {
        let uuid = UUID(uuidString: "A1B2C3D4-E5F6-7890-1234-567890ABCDEF")!
        let flat = FileServerClient.makeStoredKey(originalName: "report.pdf", uuid: uuid, folder: nil)
        XCTAssertEqual(flat, "a1b2c3d4__report.pdf", "nil folder → flat key")
        XCTAssertFalse(flat.hasPrefix("/"), "no leading slash on a flat key")

        let emptyFolder = FileServerClient.makeStoredKey(originalName: "report.pdf", uuid: uuid, folder: "")
        XCTAssertEqual(emptyFolder, "a1b2c3d4__report.pdf", "empty folder → flat key")
    }

    /// Folder + same `(uuid, name)` is deterministic (a retry re-mints the same
    /// nested key — the bytes are already on the server).
    func testMakeStoredKeyWithFolderIsDeterministic() {
        let uuid = UUID()
        let convID = UUID().uuidString
        let a = FileServerClient.makeStoredKey(originalName: "data.csv", uuid: uuid, folder: convID)
        let b = FileServerClient.makeStoredKey(originalName: "data.csv", uuid: uuid, folder: convID)
        XCTAssertEqual(a, b, "same uuid + name + folder → same nested key")
    }

    /// The folder applies to ANY file type (not image-gated): pdf / csv / txt /
    /// jpeg / png all land under the same conversation folder. The shared choke
    /// point guarantees this.
    func testMakeStoredKeyFolderAppliesToAllFileTypes() {
        let convID = UUID().uuidString
        for name in ["report.pdf", "data.csv", "notes.txt", "photo.jpeg", "diagram.png"] {
            let key = FileServerClient.makeStoredKey(originalName: name, uuid: UUID(), folder: convID)
            XCTAssertTrue(key.hasPrefix("\(convID)/"),
                          "\(name) must land under the conversation folder (no image gating)")
        }
    }

    /// `deterministicStoredKey` (the share-extension path) ALSO takes the folder,
    /// so shared files land in the same per-conversation directory + stay
    /// idempotent across a replay.
    func testDeterministicStoredKeyWithFolderPrefixesAndIsStable() {
        let envelope = UUID(uuidString: "A1B2C3D4-E5F6-7890-1234-567890ABCDEF")!
        let convID = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789"
        let key = FileServerClient.deterministicStoredKey(
            envelopeID: envelope, sequence: 2, originalName: "report.pdf", folder: convID
        )
        XCTAssertEqual(key, "\(convID)/a1b2c3d4-2__report.pdf",
                       "share key = <conversationID>/<8hex>-<seq>__<name>")
        // Idempotent: same inputs re-mint the same nested key.
        let again = FileServerClient.deterministicStoredKey(
            envelopeID: envelope, sequence: 2, originalName: "report.pdf", folder: convID
        )
        XCTAssertEqual(key, again, "replay re-mints the identical nested key")
        // nil folder → flat (folderCapable==false fallback), unchanged shape.
        let flat = FileServerClient.deterministicStoredKey(
            envelopeID: envelope, sequence: 2, originalName: "report.pdf", folder: nil
        )
        XCTAssertEqual(flat, "a1b2c3d4-2__report.pdf", "nil folder → historic flat share key")
    }

    // MARK: - basicAuthHeaderValue

    func testBasicAuthHeaderValueEncodesUserColonPassword() {
        let value = FileServerClient.basicAuthHeaderValue(username: "conduck", password: "s3cr3t")
        XCTAssertTrue(value.hasPrefix("Basic "), "header must start with the Basic scheme")
        let b64 = String(value.dropFirst("Basic ".count))
        let decoded = Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(decoded, "conduck:s3cr3t", "must base64-encode 'username:password'")
    }

    func testBasicAuthHeaderValueMatchesKnownVector() {
        // base64("conduck:abc123") — a stable golden vector.
        let value = FileServerClient.basicAuthHeaderValue(username: "conduck", password: "abc123")
        let expected = "Basic " + Data("conduck:abc123".utf8).base64EncodedString()
        XCTAssertEqual(value, expected)
    }

    // MARK: - URL building / request shapes

    func testBuildUploadRequestIsPutToBaseSlashStoredKeyWithAuthAndTimeout() {
        let snap = makeSnapshot()
        let key = "a1b2c3d4__report.pdf"
        let req = FileServerClient.buildUploadRequest(snapshot: snap, storedKey: key, contentLength: 1234)

        XCTAssertEqual(req.httpMethod, "PUT", "upload must use PUT")
        XCTAssertEqual(req.url?.absoluteString, "https://fileserver.example.test/" + key,
                       "upload URL must be base/storedKey")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       FileServerClient.basicAuthHeaderValue(username: snap.username, password: snap.credential),
                       "upload must carry the Basic auth header")
        XCTAssertEqual(req.timeoutInterval, Constants.fileTransferRequestTimeout, accuracy: 0.001,
                       "upload uses the long file-transfer request timeout")
    }

    /// A NESTED (folder) storedKey resolves to `base/<folder>/<file>` with the
    /// inner slash kept as a PATH SEPARATOR (not percent-encoded to `%2F`) —
    /// `URL.appending(path:)` preserves it, which is what makes the per-conversation
    /// folder reach the server as a real directory.
    func testBuildUploadRequestKeepsNestedFolderSlashUnescaped() {
        let snap = makeSnapshot()
        let key = "1F2E3D4C-5B6A-7890-ABCD-EF0123456789/a1b2c3d4__report.pdf"
        let req = FileServerClient.buildUploadRequest(snapshot: snap, storedKey: key, contentLength: 10)

        XCTAssertEqual(req.url?.absoluteString,
                       "https://fileserver.example.test/" + key,
                       "nested key must join as base/<folder>/<file> with the slash intact")
        XCTAssertFalse(req.url?.absoluteString.contains("%2F") ?? true,
                       "the folder separator must NOT be percent-encoded to %2F")
        // The download/probe builders share the same join — confirm the probe too.
        let probe = FileServerClient.buildProbeRequest(snapshot: snap, storedKey: key)
        XCTAssertEqual(probe.url?.absoluteString, "https://fileserver.example.test/" + key)
    }

    /// MKCOL builder: the collection-create that precedes every nested PUT
    /// (WebDAV won't auto-create the parent; rclone 409s a nested PUT into a
    /// missing folder). Probe-length timeout — it's a tiny bodyless request.
    func testBuildMkcolRequestIsMkcolToBaseSlashCollectionWithAuthAndProbeTimeout() {
        let snap = makeSnapshot()
        let req = FileServerClient.buildMkcolRequest(snapshot: snap, collectionKey: "__conduck_probe__")

        XCTAssertEqual(req.httpMethod, "MKCOL", "collection create must use MKCOL")
        XCTAssertEqual(req.url?.absoluteString, "https://fileserver.example.test/__conduck_probe__",
                       "MKCOL URL must be base/collectionKey")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"),
                       FileServerClient.basicAuthHeaderValue(username: snap.username, password: snap.credential),
                       "MKCOL must carry the Basic auth header")
        XCTAssertEqual(req.timeoutInterval, Constants.fileServerProbeTimeout, accuracy: 0.001,
                       "MKCOL uses the short probe timeout, not the multi-MB transfer budget")
    }

    func testBuildDownloadRequestIsGetToBaseSlashStoredKeyWithAuth() {
        let snap = makeSnapshot()
        let key = "a1b2c3d4__out.zip"
        let req = FileServerClient.buildDownloadRequest(snapshot: snap, storedKey: key)

        XCTAssertEqual(req.httpMethod, "GET", "download must use GET")
        XCTAssertEqual(req.url?.absoluteString, "https://fileserver.example.test/" + key)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.timeoutInterval, Constants.fileTransferRequestTimeout, accuracy: 0.001)
    }

    func testBuildProbeRequestIsGetNeverHeadWithProbeTimeout() {
        let snap = makeSnapshot()
        let key = "a1b2c3d4__probe.txt"
        let req = FileServerClient.buildProbeRequest(snapshot: snap, storedKey: key)

        // Locked design decision A: existence probe is GET, NEVER HEAD
        // (a HEAD/read-only 200 false-positives on OpenClaw's Control-UI HTML).
        XCTAssertEqual(req.httpMethod, "GET", "probe MUST be GET, never HEAD")
        XCTAssertNotEqual(req.httpMethod, "HEAD", "probe MUST NOT use HEAD")
        XCTAssertEqual(req.url?.absoluteString, "https://fileserver.example.test/" + key)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.timeoutInterval, Constants.fileServerProbeTimeout, accuracy: 0.001,
                       "probe uses the short ephemeral probe timeout")
        // The existence probe is capped to a single byte so it can never pull a
        // large file into memory; a server that ignores Range still 200s the
        // full body (parsed identically as `.exists`). The real download
        // (`buildDownloadRequest`) carries NO Range.
        XCTAssertEqual(req.value(forHTTPHeaderField: "Range"), "bytes=0-0",
                       "probe MUST cap the body via Range: bytes=0-0")
        let download = FileServerClient.buildDownloadRequest(snapshot: snap, storedKey: key)
        XCTAssertNil(download.value(forHTTPHeaderField: "Range"),
                     "the real download must NOT be range-capped")
    }

    func testBuildDeleteRequestIsDeleteToBaseSlashStoredKeyWithAuth() {
        let snap = makeSnapshot()
        let key = "a1b2c3d4__orphan.bin"
        let req = FileServerClient.buildDeleteRequest(snapshot: snap, storedKey: key)

        XCTAssertEqual(req.httpMethod, "DELETE", "delete must use DELETE")
        XCTAssertEqual(req.url?.absoluteString, "https://fileserver.example.test/" + key)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testBuildPropfindRequestUsesPropfindVerbAndDepthHeader() {
        let snap = makeSnapshot()
        let req = FileServerClient.buildPropfindRequest(snapshot: snap, depth: 1)

        XCTAssertEqual(req.httpMethod, "PROPFIND", "directory listing uses the WebDAV PROPFIND verb")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Depth"), "1", "PROPFIND must carry the Depth header")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testRequestURLsEncodeStoredKeyAgainstBaseRoot() {
        // The client is root-relative by design: every request targets
        // base/storedKey at the server ROOT. The served folder is a server-side
        // concern the client neither knows nor encodes.
        let snap = makeSnapshot(base: "https://host.test/dav")
        let key = "0badf00d__x.txt"
        let req = FileServerClient.buildUploadRequest(snapshot: snap, storedKey: key, contentLength: nil)
        XCTAssertEqual(req.url?.absoluteString, "https://host.test/dav/" + key,
                       "URL = base.appending(path: storedKey); nothing but the storedKey is in the path")
    }

    // MARK: - parseProbeOutcome table

    func testParseProbeOutcomeStatusTable() {
        // 200/206 → exists ; 404 → missing ; 401/403 → unauthorized ;
        // 5xx → serverError ; everything else → unknown.
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 200), .exists)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 206), .exists)
        // 416 Range-Not-Satisfiable ⟹ the resource exists but is shorter than the
        // `bytes=0-0` probe range (an empty file); a missing file 404s, so 416 is
        // an existence signal, not a failure.
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 416), .exists)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 404), .missing)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 401), .unauthorized)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 403), .unauthorized)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 500), .serverError)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 502), .serverError)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 503), .serverError)
        // Unmapped statuses fall through to .unknown.
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 301), .unknown)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 418), .unknown)
        XCTAssertEqual(FileServerClient.parseProbeOutcome(status: 0), .unknown)
    }

    // MARK: - Transport-error classification (staged test)

    func testTransportPinMismatchMapsToCertMismatch() async {
        // Pin set + the evaluator confirmed the mismatch (`pinRejectedOverride`)
        // → cert mismatch.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: "AA:BB:CC"),
            session: makeMockSession(),
            pinRejectedOverride: { true }
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferCertMismatch = result.failure else {
            return XCTFail("Pin set + confirmed mismatch must map to fileTransferCertMismatch (got \(String(describing: result.failure))).")
        }
    }

    func testTransportPinTransientMapsToUnreachable() async {
        // THE FIX (file lane, pin path): a generic `.secureConnectionFailed`
        // with NO confirmed mismatch (cold tunnel) must be retryable, NOT a
        // false cert mismatch.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: "AA:BB:CC"),
            session: makeMockSession(),
            pinRejectedOverride: { false }
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferUnreachable = result.failure else {
            return XCTFail("A pinned host on a cold tunnel (no confirmed mismatch) must be unreachable, not a cert mismatch (got \(String(describing: result.failure))).")
        }
    }

    func testTransportNoPinUntrustedMapsToUnreachable() async {
        // No pin: the staged test never offers TOFU → an untrusted cert reads
        // as unreachable (TOFU lives in the Settings save path).
        MockURLProtocol.requestHandler = { _ in throw URLError(.serverCertificateUntrusted) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: nil),
            session: makeMockSession()
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferUnreachable = result.failure else {
            return XCTFail("No-pin untrusted cert during the staged test reads as unreachable, not a TOFU offer (got \(String(describing: result.failure))).")
        }
    }
}

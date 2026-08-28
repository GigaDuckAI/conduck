// SPDX-License-Identifier: Apache-2.0

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
//    • probeStatusPrefilter = the exact status→outcome table. NOTE this is the
//                          byte-echo PRE-FILTER, not the existence verdict —
//                          the body-reading verdict lives in
//                          `FileProbeBodyVerdictTests`.
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
        folderCapable: Bool = true,
        returnCapable: Bool = true
    ) -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: base)!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: fingerprint,
            available: available,
            folderCapable: folderCapable,
            returnCapable: returnCapable
        )
    }

    /// Fresh `MockURLProtocol`-backed session per transport test.
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        // The staged test and the mint both write to the PROCESS-WIDE witness
        // breaker, so a case that seeds "this lane cannot return" would make the
        // next case's mint skip its request entirely and assert on a probe that
        // never happened. Cleared on both edges: a case that fails mid-way must
        // not poison the run either.
        BackgroundFileTransfer.FileLaneWitnessBreaker.shared.resetAll()
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        BackgroundFileTransfer.FileLaneWitnessBreaker.shared.resetAll()
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

    // MARK: - makeStoredKey: path-component bound
    //
    // The stored key's last segment becomes a real filename on the file server's
    // filesystem (POSIX NAME_MAX = 255 bytes). The 8-hex prefix and `__` are pure
    // additions to the user's name, so a filename the SOURCE filesystem accepts
    // at its own 255-byte limit mints a 265-byte component here — refused on PUT,
    // which means a legitimately long filename cannot be sent at all.

    /// The bound must be invisible to every name that already fits, or it would
    /// silently re-key attachments that existing conversations already hold.
    func testMakeStoredKeyLeavesNamesThatAlreadyFitByteIdentical() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let budget = FileServerClient.storedKeyComponentMaxCharacters - "00000000__".count
        for name in ["a", "report.pdf", "a.b-c_d.tar.gz", String(repeating: "x", count: budget)] {
            let key = FileServerClient.makeStoredKey(originalName: name, uuid: uuid)
            XCTAssertEqual(
                key.components(separatedBy: "__")[1], name,
                "a name within budget must pass through untouched"
            )
        }
    }

    func testMakeStoredKeyBoundsAnOverlongNameToOnePathComponent() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        // 300 characters — well past what any filesystem accepts once prefixed.
        let key = FileServerClient.makeStoredKey(
            originalName: String(repeating: "a", count: 296) + ".pdf",
            uuid: uuid
        )
        XCTAssertEqual(
            key.count, FileServerClient.storedKeyComponentMaxCharacters,
            "an overlong name is cut to exactly the component budget"
        )
        XCTAssertLessThanOrEqual(key.utf8.count, 255, "must fit POSIX NAME_MAX in BYTES")
        XCTAssertTrue(key.hasSuffix(".pdf"), "the extension survives truncation")
    }

    /// An agent decides what to do with a file by its extension, so the stem is
    /// what gets cut — `report.p` would be useless where `repo.pdf` still works.
    func testMakeStoredKeyPreservesTheLastExtensionWhenTruncating() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let key = FileServerClient.makeStoredKey(
            originalName: String(repeating: "a", count: 300) + ".tar.gz",
            uuid: uuid
        )
        // Only the LAST dot-suffix is preserved: `.gz` survives, `.tar` is inside
        // the stem and may be cut with it.
        XCTAssertTrue(key.hasSuffix(".gz"), "the final extension is kept")
        XCTAssertLessThanOrEqual(key.utf8.count, 255)
    }

    /// A dotfile has no extension — treating the leading dot as one would
    /// truncate the entire name away.
    func testMakeStoredKeyTreatsALeadingDotAsStemNotExtension() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let key = FileServerClient.makeStoredKey(
            originalName: "." + String(repeating: "a", count: 300),
            uuid: uuid
        )
        let name = key.components(separatedBy: "__")[1]
        XCTAssertTrue(name.hasPrefix(".a"), "the dotfile name is truncated, not consumed")
        XCTAssertLessThanOrEqual(key.utf8.count, 255)
    }

    /// A pathological "extension" must not eat the budget the stem needs.
    func testMakeStoredKeyTruncatesBlindWhenTheSuffixIsNotAPlausibleExtension() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let key = FileServerClient.makeStoredKey(
            originalName: String(repeating: "a", count: 10) + "." + String(repeating: "b", count: 300),
            uuid: uuid
        )
        XCTAssertEqual(key.count, FileServerClient.storedKeyComponentMaxCharacters)
        XCTAssertTrue(
            key.components(separatedBy: "__")[1].hasPrefix("aaaaaaaaaa."),
            "the real stem is kept; the absurd suffix is simply cut"
        )
    }

    /// Retry re-mints the key and re-PUTs over the partial blob, so truncation
    /// has to be deterministic or a retry would orphan the first attempt.
    func testMakeStoredKeyTruncationIsDeterministic() {
        let uuid = UUID()
        let name = String(repeating: "z", count: 400) + ".bin"
        XCTAssertEqual(
            FileServerClient.makeStoredKey(originalName: name, uuid: uuid),
            FileServerClient.makeStoredKey(originalName: name, uuid: uuid)
        )
    }

    /// The folder is its own path component and carries the same budget.
    func testMakeStoredKeyBoundsTheFolderComponentToo() {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let key = FileServerClient.makeStoredKey(
            originalName: "x.txt",
            uuid: uuid,
            folder: String(repeating: "f", count: 400)
        )
        let parts = key.components(separatedBy: "/")
        XCTAssertEqual(parts.count, 2, "still exactly one folder segment")
        for part in parts {
            XCTAssertLessThanOrEqual(
                part.utf8.count, 255,
                "every path component must fit NAME_MAX"
            )
        }
    }

    /// `deterministicStoredKey`'s prefix widens with `sequence`, so its budget is
    /// derived from the prefix actually built rather than a hardcoded width.
    func testDeterministicStoredKeyBoundsTheNameAcrossSequenceWidths() {
        let envelope = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let name = String(repeating: "a", count: 400) + ".pdf"
        for sequence in [0, 7, 999_999] {
            let key = FileServerClient.deterministicStoredKey(
                envelopeID: envelope,
                sequence: sequence,
                originalName: name
            )
            XCTAssertEqual(
                key.count, FileServerClient.storedKeyComponentMaxCharacters,
                "a wider sequence must eat into the name budget, not overflow it"
            )
            XCTAssertLessThanOrEqual(key.utf8.count, 255)
            XCTAssertTrue(key.hasSuffix(".pdf"))
        }
    }

    /// Same no-op guarantee on the share path: a manifest-bounded name (120
    /// characters) must keep minting exactly the key it minted before.
    func testDeterministicStoredKeyLeavesNamesThatAlreadyFitByteIdentical() {
        let envelope = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let name = String(repeating: "n", count: 120) + ".pdf"
        let key = FileServerClient.deterministicStoredKey(
            envelopeID: envelope, sequence: 3, originalName: name
        )
        XCTAssertTrue(key.hasSuffix("__" + name), "a within-budget name is untouched")
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
        // The existence probe asks for a single byte so a compliant server saves
        // the bandwidth; the real safety is the client-side cap in
        // `collectProbeEvidence`. The real download (`buildDownloadRequest`)
        // carries NO Range.
        XCTAssertEqual(req.value(forHTTPHeaderField: "Range"), "bytes=0-0",
                       "probe MUST cap the body via Range: bytes=0-0")
        // Two of the verdict's inputs are byte counts (one delivered byte for a
        // one-byte range; Content-Length as the file's size on a 200), so
        // transparent decompression must be refused or neither is verifiable.
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept-Encoding"), "identity",
                       "probe MUST refuse transparent decompression")
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
        let key = "11111111-2222-3333-4444-555555555555/out-0123456789abcdef"
        let req = FileServerClient.buildPropfindRequest(snapshot: snap, collectionKey: key, depth: 1)

        XCTAssertEqual(req.httpMethod, "PROPFIND", "directory listing uses the WebDAV PROPFIND verb")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Depth"), "1", "PROPFIND must carry the Depth header")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
        // The collection is a PARAMETER, not the base URL: a listing aimed at the
        // served root answers with every file every conversation ever uploaded,
        // which is the one thing the per-dispatch box exists to prevent.
        XCTAssertEqual(req.url?.absoluteString, "https://fileserver.example.test/" + key,
                       "PROPFIND targets base/collectionKey, and the `/` stays a real separator")
        XCTAssertEqual(req.url, FileServerClient.listingCollectionURL(snapshot: snap, collectionKey: key),
                       "the request builder and the href resolver must agree on what was asked for")
    }

    func testBuildPropfindRequestWithEmptyCollectionTargetsTheServedRoot() {
        let snap = makeSnapshot()
        let req = FileServerClient.buildPropfindRequest(snapshot: snap, collectionKey: "", depth: 0)
        XCTAssertEqual(req.url?.absoluteString, "https://fileserver.example.test",
                       "an empty collection key is the deliberate whole-server listing")
    }

    // MARK: - ensureFreshCollection (201, and nothing else)

    /// The MKCOL sequence for an outbox: a best-effort parent, then a leaf that
    /// must have been created by THIS call.
    private func recordMkcolStatuses(
        leaf: Int?,
        parent: Int = 201,
        recorder: FileLaneRequestRecorder
    ) {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            recorder.record(method: request.httpMethod ?? "", url: url)
            let isLeaf = url.absoluteString.contains("/out-")
            if isLeaf {
                guard let leaf else { throw URLError(.cannotConnectToHost) }
                return (HTTPURLResponse(url: url, statusCode: leaf, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: parent, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
    }

    /// A `201` on the leaf is the ONLY success. NOT the dispatch path — the
    /// per-dispatch box is NAMED by Conduck and CREATED by the agent, because a
    /// client-created directory belongs to whoever the WebDAV lane runs as and
    /// the agent usually is not that user. What is pinned here is the primitive
    /// itself: 201-only is the one expression of "created by this call" in the
    /// client, and any future collection Conduck genuinely must own needs it.
    func testEnsureFreshCollectionRequiresTwoOhOneOnTheLeaf() async {
        let snap = makeSnapshot()
        let key = "11111111-2222-3333-4444-555555555555/out-0123456789abcdef"
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }

        for (status, expected) in [(201, true), (200, false), (204, false), (405, false),
                                   (403, false), (409, false), (500, false)] {
            let recorder = FileLaneRequestRecorder()
            recordMkcolStatuses(leaf: status, recorder: recorder)
            let fresh = await FileServerClient.ensureFreshCollection(
                snapshot: snap, collectionKey: key, session: session)
            XCTAssertEqual(fresh, expected,
                           "MKCOL \(status) on a freshly-random key must read as fresh == \(expected)")
        }
    }

    /// `405 already exists` is a COLLISION. Called out on its own because the
    /// shipped `mkcolConclusive` idiom accepts it, so anything that reuses that
    /// idiom while meaning "created" is silently wrong.
    func testEnsureFreshCollectionTreatsMethodNotAllowedAsCollisionNotSuccess() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        recordMkcolStatuses(leaf: 405, recorder: recorder)

        let fresh = await FileServerClient.ensureFreshCollection(
            snapshot: snap,
            collectionKey: "11111111-2222-3333-4444-555555555555/out-0123456789abcdef",
            session: session)

        XCTAssertFalse(fresh, "405 means the collection was already there — never fresh")
    }

    /// A transport failure is not a creation. Fails closed.
    func testEnsureFreshCollectionFailsClosedOnTransportError() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        recordMkcolStatuses(leaf: nil, recorder: recorder)

        let fresh = await FileServerClient.ensureFreshCollection(
            snapshot: snap,
            collectionKey: "11111111-2222-3333-4444-555555555555/out-0123456789abcdef",
            session: session)

        XCTAssertFalse(fresh, "a MKCOL that never got an answer proves no freshness")
    }

    /// The parent conversation folder is ensured best-effort FIRST — a WebDAV
    /// MKCOL into a missing parent is a 409, so a conversation whose first file
    /// is an agent output would otherwise never get a box.
    func testEnsureFreshCollectionCreatesTheParentBeforeTheLeaf() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        // The parent already exists (405) — which is CORRECT for a long-lived
        // per-conversation folder, and is exactly why only the leaf is strict.
        recordMkcolStatuses(leaf: 201, parent: 405, recorder: recorder)

        let fresh = await FileServerClient.ensureFreshCollection(
            snapshot: snap,
            collectionKey: "11111111-2222-3333-4444-555555555555/out-0123456789abcdef",
            session: session)

        XCTAssertTrue(fresh, "a 405 on the SHARED parent must not veto a freshly-created leaf")
        let calls = recorder.calls
        XCTAssertEqual(calls.count, 2, "one parent MKCOL, then one leaf MKCOL")
        XCTAssertTrue(calls.allSatisfy { $0.method == "MKCOL" })
        XCTAssertEqual(calls.first?.url.absoluteString,
                       "https://fileserver.example.test/11111111-2222-3333-4444-555555555555",
                       "the parent is the conversation folder")
        XCTAssertTrue(calls.last?.url.absoluteString.hasSuffix("/out-0123456789abcdef") == true,
                      "the leaf is the box itself")
    }

    // MARK: - The pre-dispatch absence witness (a definite miss, and nothing else)

    /// The verdict rule as a STATUS LINE alone can settle it: only a `404`
    /// witnesses that this dispatch's box is not there yet. `207` is the
    /// interesting refusal at this level — read without its body it means either
    /// a collision on 128 bits of fresh entropy or a namespace that answers
    /// everything, and under both readings the folder cannot vouch for what
    /// turns up in it. (What a `207`'s BODY can still establish is the section
    /// further down; this locks the floor the body-aware form builds on.)
    func testOnlyAFourOhFourWitnessesAbsenceFromTheStatusLineAlone() {
        XCTAssertEqual(FileServerClient.classifyAbsenceWitness(status: 404), .absent)
        for status in [200, 204, 207, 301, 302, 401, 403, 405, 409, 500, 503] {
            XCTAssertNotEqual(FileServerClient.classifyAbsenceWitness(status: status), .absent,
                              "status \(status) is not a witnessed absence on its own")
        }
    }

    /// The taxonomy underneath that Bool, because ONE of the non-404 answers is
    /// not a failure at all. A server that does not implement `PROPFIND` has
    /// told us a permanent fact about itself, and reporting that to the user as
    /// "your file server stopped answering" — once per turn, forever — is the
    /// noise this split exists to remove.
    func testAbsenceWitnessSeparatesCannotAnswerFromEveryOtherRefusal() {
        XCTAssertEqual(FileServerClient.classifyAbsenceWitness(status: 404), .absent)
        for status in [405, 501] {
            XCTAssertEqual(FileServerClient.classifyAbsenceWitness(status: status), .cannotAnswer,
                           "status \(status) is a server saying it does not do PROPFIND")
        }
        for status in [200, 204, 207] {
            XCTAssertEqual(FileServerClient.classifyAbsenceWitness(status: status), .occupied,
                           "status \(status) claims the folder is already there")
        }
        // A rejected credential and a sick server are things that WERE working
        // and stopped — actionable, never a permanent incapability.
        for status in [400, 301, 302, 401, 403, 409, 500, 503] {
            XCTAssertEqual(FileServerClient.classifyAbsenceWitness(status: status), .indeterminate,
                           "status \(status) settles nothing and must stay actionable")
        }
    }

    /// The wire shape: `PROPFIND` at `Depth: 0` against the box itself. Depth 0
    /// because the question is about the collection, not its children — a
    /// listing would be a strictly larger answer to a smaller question, and on a
    /// catch-all host a much more expensive one.
    func testAbsenceWitnessIssuesOnePropfindAtDepthZeroOnTheBox() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        let key = "11111111-2222-3333-4444-555555555555/out-0123456789abcdef0123456789abcdef"
        var depthHeaders: [String] = []

        MockURLProtocol.requestHandler = { request in
            recorder.record(method: request.httpMethod ?? "", url: request.url!)
            depthHeaders.append(request.value(forHTTPHeaderField: "Depth") ?? "")
            return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }

        let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: snap, collectionKey: key, session: session)

        XCTAssertEqual(witnessed, .absent, "a definite miss on the box is the witness")
        XCTAssertEqual(recorder.calls.count, 1, "exactly one request — no negative control, no listing")
        XCTAssertEqual(recorder.calls.first?.method, "PROPFIND")
        XCTAssertEqual(depthHeaders, ["0"], "Depth: 0 — the collection itself, not its children")
        XCTAssertEqual(recorder.calls.first?.url.absoluteString,
                       "https://fileserver.example.test/" + key,
                       "aimed at the exact box, never the served root")
    }

    /// Every non-404 answer fails CLOSED. Naming no folder costs one turn
    /// without automatic delivery; a wrongly witnessed absence costs the user a
    /// file that is not theirs, so the asymmetry decides the polarity — and it
    /// holds for every one of the taxonomy's non-`.absent` cases.
    func testAbsenceWitnessFailsClosedOnEveryOtherStatus() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let key = "11111111-2222-3333-4444-555555555555/out-0123456789abcdef0123456789abcdef"

        for status in [200, 207, 401, 403, 405, 500] {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: status,
                                 httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
                snapshot: snap, collectionKey: key, session: session)
            XCTAssertNotEqual(witnessed, .absent,
                              "status \(status) must not read as a witnessed absence")
        }
    }

    /// A transport failure witnesses nothing, and reads as `.unreachable` — the
    /// case that means "no HTTP response arrived", which is the rotated-tunnel
    /// signature the breaker backs off fastest on. A refused certificate reaches
    /// here as an ordinary throw and lands in the same case deliberately: this
    /// verdict is rendered as a consequence ("this turn has no folder"), not as
    /// a cause, so there is no certificate diagnosis for it to lose.
    func testAbsenceWitnessFailsClosedOnTransportError() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }

        let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: snap,
            collectionKey: "11111111-2222-3333-4444-555555555555/out-0123456789abcdef0123456789abcdef",
            session: session)

        XCTAssertEqual(witnessed, .unreachable,
                       "a request that never got an answer proves no absence")
    }

    /// An offline device is evidence about THIS DEVICE, not the lane: the
    /// request never left the phone, so nothing was observed and nothing may be
    /// charged. Reading it as `.unreachable` opened a one-strike cooldown that
    /// suppressed the folder on the very retry the user sent once their
    /// connection came back — a "No folder for this reply" row under a healthy
    /// server.
    func testAnOfflineDeviceIsNoObservationNotUnreachable() async {
        for code: URLError.Code in [
            .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive
        ] {
            let session = makeMockSession()
            defer { session.invalidateAndCancel() }
            MockURLProtocol.requestHandler = { _ in throw URLError(code) }

            let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
                snapshot: makeSnapshot(),
                collectionKey: Self.witnessBoxKey,
                session: session)

            XCTAssertEqual(witnessed, .noObservation,
                           "\(code): a request the device never sent says nothing about the lane")
        }
    }

    /// A `-999` HAS THREE AUTHORS, and only one of them is silent. Our own
    /// dispatch being stopped is a fact about this device and witnesses
    /// `.noObservation`; the pin delegate refusing the server's certificate and
    /// a peer resetting the stream mid-request are both the lane's doing and
    /// keep the one-strike `.unreachable` patience. The evaluator's record
    /// extracts the refusal; `Task.isCancelled`, read inside the catch, is the
    /// only witness to whether the cancel was ours — the same rule
    /// `RemoteAgentClient.mapTransportError` makes a required parameter.
    /// Reading a refusal as `.noObservation` would let a rotated or intercepted
    /// certificate charge nothing, open no cooldown, and never draw the
    /// folder-less row — a silent, permanent loss of the one report that case
    /// exists for, while every send pays a doomed handshake.
    func testACancelIsOnlySilentWhenItWasOurs() {
        XCTAssertEqual(
            BackgroundFileTransfer.witnessTransportVerdict(
                code: .cancelled, signals: .empty, isTaskCancelled: true),
            .noObservation,
            "the user's Stop must not charge the lane's health")
        XCTAssertEqual(
            BackgroundFileTransfer.witnessTransportVerdict(
                code: .cancelled, signals: .empty, isTaskCancelled: false),
            .unreachable,
            "a peer reset wears the same code and is the lane's doing — the tunnel-hiccup patience applies")
    }

    /// The `-999` that is a pin refusal stays lane evidence whatever the task
    /// state — a refusal recorded during a turn the user then stopped is still
    /// a refusal, and the interception shape may never go quiet.
    func testAPinRefusalDressedAsACancelStaysUnreachable() {
        let untrustedChain = RemoteAgentTrustEvaluator.AttemptTrustSignals(
            systemTrustRejected: true, challengeRefused: true,
            pinRejected: false, pinComparisonUnsupported: false)
        XCTAssertEqual(
            BackgroundFileTransfer.witnessTransportVerdict(
                code: .cancelled, signals: untrustedChain, isTaskCancelled: false),
            .unreachable,
            "a pinned lane over a chain the system rejected fails closed as lane evidence")

        let keyMismatch = RemoteAgentTrustEvaluator.AttemptTrustSignals(
            systemTrustRejected: false, challengeRefused: true,
            pinRejected: true, pinComparisonUnsupported: false)
        XCTAssertEqual(
            BackgroundFileTransfer.witnessTransportVerdict(
                code: .cancelled, signals: keyMismatch, isTaskCancelled: true),
            .unreachable,
            "a pin that caught a different key is the interception shape, even mid-Stop")
    }

    /// The LISTING half of the same rule, sited here so the two lanes read side
    /// by side: a cancel is silent only when it was ours.
    func testAListingCancelIsOnlySilentWhenItWasOurs() {
        XCTAssertEqual(
            BackgroundFileTransfer.listingTransportVerdict(
                URLError(.cancelled), evaluator: nil, isTaskCancelled: true),
            .noObservation,
            "the user's Stop must not charge the lane's health on the listing either")
        XCTAssertEqual(
            BackgroundFileTransfer.listingTransportVerdict(
                URLError(.cancelled), evaluator: nil, isTaskCancelled: false),
            .unusable(.transport),
            "a peer reset wears the same code and is the lane's doing")
    }

    /// A task torn down before its request left carries no `URLError` at all.
    func testACancellationErrorOnAListingIsNoObservation() {
        XCTAssertEqual(
            BackgroundFileTransfer.listingTransportVerdict(
                CancellationError(), evaluator: nil, isTaskCancelled: true),
            .noObservation)
    }

    /// THE DRIFT GUARD, and the most valuable test in this pair. The witness and
    /// the listing are two request paths to ONE server, and a user reads their
    /// two rows a few points apart on the same screen. So for every transport
    /// failure, the two must agree about whether this DEVICE failed to ask —
    /// which makes an edit to one lane fail here rather than ship a pair of
    /// surfaces telling one user two stories about one file server.
    func testTheTwoLanesReadOneTransportFailureTheSameWay() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
            .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed, .cancelled
        ]
        for code in codes {
            for ours in [true, false] {
                let witness = BackgroundFileTransfer.witnessTransportVerdict(
                    code: code, signals: .empty, isTaskCancelled: ours)
                let listing = BackgroundFileTransfer.listingTransportVerdict(
                    URLError(code), evaluator: nil, isTaskCancelled: ours)
                XCTAssertEqual(
                    witness == .noObservation, listing == .noObservation,
                    "\(code) (ourCancel=\(ours)) is read differently by the two lanes")
            }
        }
    }

    /// The full request path agrees: a bare `-999` from the wire with no task
    /// cancellation and no refusal on record is the peer-reset shape.
    func testABareUncancelledCancelThroughTheSeamStaysUnreachable() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }

        let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: makeSnapshot(),
            collectionKey: Self.witnessBoxKey,
            session: session)

        XCTAssertEqual(witnessed, .unreachable)
    }

    /// The rotated-tunnel signature keeps its fast backoff: with a network path
    /// present, a host that cannot be found or that timed out is an observation
    /// ABOUT THE LANE, and stays `.unreachable`. `.networkConnectionLost` too —
    /// a connection that existed and died is one the lane participated in.
    func testHostSideTransportFailuresStayUnreachable() async {
        for code: URLError.Code in [.cannotFindHost, .timedOut, .networkConnectionLost] {
            let session = makeMockSession()
            defer { session.invalidateAndCancel() }
            MockURLProtocol.requestHandler = { _ in throw URLError(code) }

            let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
                snapshot: makeSnapshot(),
                collectionKey: Self.witnessBoxKey,
                session: session)

            XCTAssertEqual(witnessed, .unreachable,
                           "\(code) is evidence about the lane and keeps the one-strike patience")
        }
    }

    /// A root-level collection has no parent to create.
    func testParentCollectionKeyIsNilAtTheServedRoot() {
        XCTAssertNil(FileServerClient.parentCollectionKey(of: "out-0123456789abcdef"))
        XCTAssertEqual(FileServerClient.parentCollectionKey(of: "conv/out-abc"), "conv")
        XCTAssertEqual(FileServerClient.parentCollectionKey(of: "a/b/c"), "a/b")
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

    // MARK: - probeStatusPrefilter table

    func testProbeStatusPrefilterStatusTable() {
        // 200/206 → exists ; 404 → missing ; 401/403 → unauthorized ;
        // 5xx → serverError ; everything else → unknown.
        //
        // This is a PRE-FILTER, not a verdict: its `.exists` is exactly what a
        // uniform-200 SSO wall produces, which is why its only two callers each
        // require a byte-echo of a payload they just PUT. The existence probe's
        // real verdict is `classifyProbe` (`FileProbeBodyVerdictTests`).
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 200), .exists)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 206), .exists)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 416), .exists)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 404), .missing)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 401), .unauthorized)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 403), .unauthorized)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 500), .serverError)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 502), .serverError)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 503), .serverError)
        // Unmapped statuses fall through to .unknown.
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 301), .unknown)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 418), .unknown)
        XCTAssertEqual(FileServerClient.probeStatusPrefilter(status: 0), .unknown)
    }

    // MARK: - Transport-error classification (staged test)

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

    func testTransportPinMismatchMapsToCertMismatch() async {
        // The evaluator refused the challenge because the presented key
        // disagreed with the pin → cert mismatch.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: "AA:BB:CC"),
            session: makeMockSession(),
            signalsOverride: signals(challengeRefused: true, pinRejected: true)
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferCertMismatch = result.failure else {
            return XCTFail("Pin set + confirmed mismatch must map to fileTransferCertMismatch (got \(String(describing: result.failure))).")
        }
    }

    func testTransportUnpinnableKeyMapsToItsOwnCode() async {
        // The chain is system-trusted and NOTHING disagreed — the leaf's key
        // algorithm is simply outside the SPKI prefix table, so the pin could
        // not be computed. Borrowing `.fileTransferCertMismatch` here would tell
        // a user with a perfectly good certificate that their connection may be
        // intercepted, which is how people learn to dismiss the real warning.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: "AA:BB:CC"),
            session: makeMockSession(),
            signalsOverride: signals(challengeRefused: true,
                                     pinRejected: true,
                                     pinComparisonUnsupported: true)
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferCertKeyUnpinnable = result.failure else {
            return XCTFail("A key Conduck cannot fingerprint must keep its own code (got \(String(describing: result.failure))).")
        }
    }

    func testTransportPinTransientMapsToUnreachable() async {
        // THE FIX (file lane, pin path): a generic `.secureConnectionFailed`
        // with NO confirmed mismatch (cold tunnel) must be retryable, NOT a
        // false cert mismatch. Nothing refused anything — the handshake never
        // reached a certificate — so every verdict is false.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: "AA:BB:CC"),
            session: makeMockSession(),
            signalsOverride: signals()
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferUnreachable = result.failure else {
            return XCTFail("A pinned host on a cold tunnel (no confirmed mismatch) must be unreachable, not a cert mismatch (got \(String(describing: result.failure))).")
        }
    }

    func testTransportNoPinUntrustedMapsToCertUntrusted() async {
        // No pin: the host ANSWERED and then this device refused its
        // certificate. Folding that into `.fileTransferUnreachable` would tell
        // the user to check whether their file server is running — a hunt for a
        // problem that isn't there, and one that never leads to the real fix.
        MockURLProtocol.requestHandler = { _ in throw URLError(.serverCertificateUntrusted) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: nil),
            session: makeMockSession()
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferCertUntrusted = result.failure else {
            return XCTFail("An untrusted cert must name the certificate, not read as unreachable (got \(String(describing: result.failure))).")
        }
    }

    func testTransportSystemTrustRejectionOutranksAPinRejection() async {
        // The fail-closed arm reaches this lane too: the evaluator refuses a
        // PINNED connection whose chain the device does not trust, and that must
        // not be reported as "the pinned key changed" — the fingerprint was
        // never the problem, so the pin-mismatch copy would send the user to fix
        // the wrong thing.
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: "AA:BB:CC"),
            session: makeMockSession(),
            // The fail-closed arm's real shape: the evaluator cancelled, the
            // system had objected, and no digest was ever compared.
            signalsOverride: signals(systemTrustRejected: true, challengeRefused: true)
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferCertUntrusted = result.failure else {
            return XCTFail("An untrusted chain must NOT be reported as a pin mismatch (got \(String(describing: result.failure))).")
        }
    }

    func testTransportSystemTrustSignalDoesNotFireOnAColdTunnel() async {
        // Both trust signals are POSITIVE: a transient `-1200` never reached a
        // certificate challenge, so neither is set and the lane stays retryable.
        // This is the regression the classifier exists to prevent, re-locked at
        // the seam that now carries the real signal.
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }
        let result = await FileServerClient.runConnectionTest(
            snapshot: makeSnapshot(fingerprint: "AA:BB:CC"),
            session: makeMockSession(),
            signalsOverride: signals()
        )
        XCTAssertFalse(result.success)
        guard case .fileTransferUnreachable = result.failure else {
            return XCTFail("A cold tunnel must stay retryable (got \(String(describing: result.failure))).")
        }
    }

    // MARK: - The witness runs on the dispatch critical path

    private static let witnessBoxKey =
        "11111111-2222-3333-4444-555555555555/out-0123456789abcdef0123456789abcdef"

    /// EVERY send on a configured lane awaits the witness before the converse
    /// request is even built — including a pure-text turn that was never going to
    /// involve a file. On the lane's ordinary interactive budget a file server
    /// that is simply not answering (a NAS behind a VPN that is down) stalls the
    /// user's every turn by that full budget; the witness therefore carries its
    /// own, much shorter deadline.
    func testAbsenceWitnessRequestCarriesItsOwnShortDeadline() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let deadlines = TimeoutRecorder()

        MockURLProtocol.requestHandler = { request in
            deadlines.record(request.timeoutInterval)
            return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        _ = await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: snap, collectionKey: Self.witnessBoxKey, session: session)

        XCTAssertEqual(deadlines.values, [Constants.fileServerAbsenceWitnessTimeout],
                       "the pre-dispatch witness runs on its own deadline, not the lane's")
        XCTAssertLessThan(Constants.fileServerAbsenceWitnessTimeout,
                          Constants.fileServerProbeTimeout,
                          "a liveness check the user never asked for must not cost what a "
                          + "download the user is waiting for may")

        // The POST-reply listing keeps the interactive budget — it runs once, off
        // the send path, and a user watching for their file can wait.
        XCTAssertEqual(
            FileServerClient.buildPropfindRequest(
                snapshot: snap, collectionKey: Self.witnessBoxKey, depth: 1).timeoutInterval,
            Constants.fileServerProbeTimeout)
    }

    /// The verdict is a function of the STATUS LINE, so the body is never read.
    /// Draining it spent up to the listing cap of async iterations per send for
    /// bytes nothing inspects — and it turned a `404` that happened to carry a
    /// large body into "not witnessed", disabling file return on a server that
    /// answered the question correctly.
    func testAbsenceWitnessIgnoresAnOverCapBodyOnADefiniteMiss() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let huge = Data(repeating: 0x41, count: FileServerClient.listingMaxBytes + 1)

        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, huge)
        }
        let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: snap, collectionKey: Self.witnessBoxKey, session: session)

        XCTAssertEqual(witnessed, .absent,
                       "a definite miss is a definite miss whatever the server padded it with")
    }

    /// A `207` whose body says nothing useful still fails closed however large it
    /// is — the read is capped and an over-cap body is refused on size, so a
    /// catch-all host's login page is never parsed for a verdict.
    func testAbsenceWitnessStillFailsClosedOnATwoOhSevenWithAHugeBody() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 207,
                             httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data(repeating: 0x41, count: FileServerClient.absenceWitnessMaxBytes + 1))
        }
        let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: snap, collectionKey: Self.witnessBoxKey, session: session)
        XCTAssertEqual(witnessed, .occupied)
    }

    // MARK: - The `207` that IS a miss (reading the inner status)

    /// The compliant "not there" multistatus: one `<response>` naming the
    /// collection that was asked about, with a RESPONSE-LEVEL status.
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

    /// The same shape for a collection that IS there: properties under a `2xx`
    /// propstat and no response-level status at all, which is what a real server
    /// sends for a folder it has.
    private func presentMultistatus(href: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>\(href)</D:href>
            <D:propstat>
              <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """.utf8)
    }

    /// The href a compliant server echoes for the dispatch box — absolute path,
    /// trailing slash, which is the ordinary collection form.
    private static let witnessBoxHref = "/" + witnessBoxKey + "/"

    /// Serve one PROPFIND answer for the witness and report the verdict.
    private func witness(
        status: Int,
        body: Data,
        snapshot: SettingsManager.FileTransferSnapshot? = nil
    ) async -> FileServerAbsenceWitness {
        let snap = snapshot ?? makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, body)
        }
        return await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: snap, collectionKey: Self.witnessBoxKey, session: session)
    }

    /// THE DEFECT THIS SECTION EXISTS FOR. RFC 4918 lets a server report a
    /// `PROPFIND` of a collection that is not there as a `207` whose one inner
    /// response carries the `404`, and commercial WebDAV hosts do exactly that.
    /// Read from the status line alone every such host was `.occupied` on every
    /// dispatch — a folder-less row under every agent turn, forever, with no
    /// in-app action that could silence it.
    func testACompliantMultistatusMissIsAWitnessedAbsence() async {
        let witnessed = await witness(
            status: 207, body: missMultistatus(href: Self.witnessBoxHref))
        XCTAssertEqual(witnessed, .absent,
                       "an outer 207 whose inner response for this exact collection is 404 is "
                       + "the server saying 'not there', in the second form the RFC allows")
    }

    /// `410 Gone` is the same sentence with a history attached, so it lands in
    /// the same place — a server that remembers deleting the collection is still
    /// telling us the collection is not there.
    func testAnInnerGoneIsAlsoAWitnessedAbsence() async {
        let witnessed = await witness(
            status: 207,
            body: missMultistatus(href: Self.witnessBoxHref, innerStatus: "HTTP/1.1 410 Gone"))
        XCTAssertEqual(witnessed, .absent)
    }

    /// The other direction, and the one that keeps the whole change safe: a
    /// namespace that answers everything says the collection is THERE, and that
    /// is still `.occupied`. Nothing about reading the body loosens the verdict
    /// for a wall.
    func testAnInnerSuccessIsStillOccupied() async {
        let witnessed = await witness(
            status: 207, body: presentMultistatus(href: Self.witnessBoxHref))
        XCTAssertEqual(witnessed, .occupied,
                       "a catch-all host that claims the freshly minted path exists has not "
                       + "witnessed anything, whatever shape it says it in")
    }

    /// A response-level `2xx` is equally not a miss, even with no properties
    /// behind it — the status is the resource's own answer and it said yes.
    func testAnExplicitInnerTwoHundredStatusIsOccupied() async {
        let witnessed = await witness(
            status: 207,
            body: missMultistatus(href: Self.witnessBoxHref, innerStatus: "HTTP/1.1 200 OK"))
        XCTAssertEqual(witnessed, .occupied)
    }

    /// STRICT HREF MATCHING. A `404` about some OTHER collection is not an
    /// answer about this one, and accepting it would let a server hand back a
    /// miss for a path nobody asked about and have Conduck name a folder on the
    /// strength of it.
    func testAMissAboutADifferentHrefWitnessesNothing() async {
        let elsewhere = "/11111111-2222-3333-4444-555555555555/out-ffffffffffffffffffffffffffffffff/"
        let witnessed = await witness(status: 207, body: missMultistatus(href: elsewhere))
        XCTAssertEqual(witnessed, .occupied,
                       "the row has to be about the collection that was asked about")
    }

    /// A trailing slash and percent-encoding are serialization choices a
    /// compliant server is free to make, and refusing them would refuse the
    /// exact population this repair is for. The href resolver is the listing's
    /// own, so this variance is understood in one place.
    func testTheHrefMayVaryInTrailingSlashAndEncoding() async {
        let noSlash = "/" + Self.witnessBoxKey
        let withoutSlash = await witness(status: 207, body: missMultistatus(href: noSlash))
        XCTAssertEqual(withoutSlash, .absent)

        let encoded = "/11111111%2D2222%2D3333%2D4444%2D555555555555/out-0123456789abcdef0123456789abcdef/"
        let percentEncoded = await witness(status: 207, body: missMultistatus(href: encoded))
        XCTAssertEqual(percentEncoded, .absent,
                       "percent-encoded but identical once decoded — the same collection")
    }

    /// MORE THAN ONE ROW IS AMBIGUOUS. A `Depth: 0` question about one
    /// collection has one honest answer row; picking the one that suits us out
    /// of a set nobody understood is the same mistake as reading a status line.
    func testASecondResponseElementRefusesTheReading() async {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>\(Self.witnessBoxHref)</D:href>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:response>
          <D:response>
            <D:href>/somewhere/else/</D:href>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:response>
        </D:multistatus>
        """.utf8)
        let witnessed = await witness(status: 207, body: body)
        XCTAssertEqual(witnessed, .occupied)
    }

    /// Every way a body can fail to be an answer, all landing on today's
    /// `.occupied`. The list is the point: `.absent` is what lets a folder name
    /// go on the wire, so only the reading a compliant server meant may produce
    /// it.
    func testEveryUnreadableTwoOhSevenBodyFailsClosed() async {
        let cases: [(name: String, body: Data)] = [
            ("empty", Data()),
            ("not XML at all", Data("nope".utf8)),
            ("truncated mid-document",
             missMultistatus(href: Self.witnessBoxHref).prefix(60)),
            ("not a multistatus root",
             Data("<html><body>Please sign in</body></html>".utf8)),
            ("no inner status anywhere",
             Data("""
             <?xml version="1.0" encoding="utf-8"?>
             <D:multistatus xmlns:D="DAV:">
               <D:response><D:href>\(Self.witnessBoxHref)</D:href></D:response>
             </D:multistatus>
             """.utf8)),
            ("an inner status nobody can read",
             missMultistatus(href: Self.witnessBoxHref, innerStatus: "HTTP/1.1 not-a-code Hmm")),
            ("a propstat 404, which is about PROPERTIES not the resource",
             Data("""
             <?xml version="1.0" encoding="utf-8"?>
             <D:multistatus xmlns:D="DAV:">
               <D:response>
                 <D:href>\(Self.witnessBoxHref)</D:href>
                 <D:propstat>
                   <D:prop><D:getcontentlength/></D:prop>
                   <D:status>HTTP/1.1 404 Not Found</D:status>
                 </D:propstat>
               </D:response>
             </D:multistatus>
             """.utf8))
        ]
        for row in cases {
            let witnessed = await witness(status: 207, body: row.body)
            XCTAssertEqual(witnessed, .occupied,
                           "\(row.name) settles nothing and must stay occupied")
        }
    }

    /// A body that WOULD have been a miss but arrived over the cap is not a
    /// miss: the reader cut it, so the rest of the document could say anything.
    /// The cap is what stops a stranger's server making the app buffer megabytes
    /// on the dispatch critical path.
    func testAnOverCapMissBodyIsRefusedRatherThanParsed() async {
        var padded = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!-- ".utf8)
        padded.append(Data(repeating: 0x41, count: FileServerClient.absenceWitnessMaxBytes))
        padded.append(Data(" -->\n".utf8))
        padded.append(missMultistatus(href: Self.witnessBoxHref))

        let witnessed = await witness(status: 207, body: padded)
        XCTAssertEqual(witnessed, .occupied,
                       "truncated is not 'not there' — the bytes that would have said so were "
                       + "never read")
    }

    /// THE BODY CHANGES NOTHING FOR ANY OTHER STATUS. Only a `207` is a
    /// multistatus, so only a `207` gets its body read; every other status has
    /// already said everything it is going to say, and a forged body cannot
    /// promote or demote it.
    func testTheBodyOnlyEverDecidesATwoOhSeven() async {
        let miss = missMultistatus(href: Self.witnessBoxHref)
        let present = presentMultistatus(href: Self.witnessBoxHref)

        let paddedMiss = await witness(status: 404, body: present)
        XCTAssertEqual(paddedMiss, .absent,
                       "a 404 is a definite miss whatever the server padded it with")
        let notMultistatus = await witness(status: 200, body: miss)
        XCTAssertEqual(notMultistatus, .occupied,
                       "a 200 is not a multistatus, so its body is never a verdict")
        for status in [405, 501] {
            let structural = await witness(status: status, body: miss)
            XCTAssertEqual(structural, .cannotAnswer,
                           "status \(status) states an incapability its body cannot soften")
        }
        for status in [401, 403, 429, 500, 502, 503, 302] {
            let answered = await witness(status: status, body: miss)
            XCTAssertEqual(answered, .indeterminate,
                           "status \(status) stays actionable — its body is not read")
        }
    }

    /// The pure rule, exercised without a session so the taxonomy is pinned
    /// independently of how the bytes reached it.
    func testTheBodyAwareClassifierDelegatesEveryNonMultistatusStatus() {
        let url = URL(string: "https://fileserver.example.test/" + Self.witnessBoxKey)!
        let miss = missMultistatus(href: Self.witnessBoxHref)
        for status in [200, 204, 404, 401, 403, 405, 501, 500, 302] {
            XCTAssertEqual(
                FileServerClient.classifyAbsenceWitness(
                    status: status, body: miss, bodyExceededCap: false, requestedURL: url),
                FileServerClient.classifyAbsenceWitness(status: status),
                "status \(status) must read the same with a body as without one")
        }
        XCTAssertEqual(
            FileServerClient.classifyAbsenceWitness(
                status: 207, body: miss, bodyExceededCap: false, requestedURL: url),
            .absent,
            "the 207 is the one status the body may re-decide")
        XCTAssertEqual(
            FileServerClient.classifyAbsenceWitness(
                status: 207, body: miss, bodyExceededCap: true, requestedURL: url),
            .occupied,
            "and the reader's own report that it stopped early overrides bytes that parse")
    }

    // MARK: - What gates the outbox mint

    /// `folderCapable` measures whether the CLIENT may nested-PUT. Conduck never
    /// creates the box and never writes into it — the agent does — so the only
    /// client operation the box ever sees is a PROPFIND, which a nested-PUT-hostile
    /// lane answers perfectly well. Gating the mint on it left phone, Mac and
    /// CarPlay with no file return on a lane where the Watch, which is never told
    /// the flag, named a box anyway: two surfaces on ONE lane disagreeing.
    func testTheMintIsGatedOnTheWitnessNotOnNestedPutCapability() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        let conversationID = UUID()

        let key = await BackgroundFileTransfer.mintWitnessedOutboxKey(
            conversationID: conversationID,
            snapshot: makeSnapshot(folderCapable: false),
            session: session)

        XCTAssertNotNil(key, "a lane that refuses nested PUTs can still be listed")
        XCTAssertEqual(key?.hasPrefix(conversationID.uuidString + "/" + OutboxKey.componentPrefix), true)
    }

    /// And the gate that IS consulted still holds: no witnessed absence, no box,
    /// no line on the wire — on a fully folder-capable lane.
    func testAFailedWitnessMintsNoBoxEvenOnAFolderCapableLane() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 207,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        let key = await BackgroundFileTransfer.mintWitnessedOutboxKey(
            conversationID: UUID(),
            snapshot: makeSnapshot(folderCapable: true),
            session: session)
        XCTAssertNil(key, "freshness that was not witnessed is not freshness")
    }

    // MARK: - The staged test certifies the RETURN direction too

    /// Script a staged test that passes every byte-moving stage, with PROPFIND
    /// answered by `propfind` — a throw stands in for a transport failure, and
    /// the returned body is empty unless `propfindBody` supplies one.
    private func scriptStagedTest(
        propfind: @escaping (URLRequest) throws -> Int,
        propfindBody: @escaping (URLRequest) -> Data = { _ in Data() }
    ) {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let ok = { (status: Int, body: Data) in
                (HTTPURLResponse(url: url, statusCode: status,
                                 httpVersion: "HTTP/1.1", headerFields: nil)!, body)
            }
            switch request.httpMethod {
            case "PUT": return ok(201, Data())
            case "GET":
                // The nested capability probe writes into this run's own
                // `__conduck_probe_<8hex>__/` collection; the flat read stage
                // fetches `__conduck_probe_<tag>.txt` at the root.
                let nested = url.absoluteString.contains("__/")
                return ok(200, Data((nested ? "conduck-nested-probe" : "conduck-probe").utf8))
            case "DELETE": return ok(204, Data())
            case "PROPFIND": return ok(try propfind(request), propfindBody(request))
            default: return ok(200, Data())
            }
        }
    }

    /// PROPFIND is the SOLE delivery authority — it gates every dispatch (the
    /// absence witness) and reads every reply's folder — so a staged test that
    /// never issued one certified half a lane as fully green. The user then got
    /// no file return at all, permanently, with no signal anywhere they could act
    /// on.
    func testStagedTestReportsUploadOnlyWhenTheServerCannotAnswerPropfind() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        // A plain-HTTP store, or an nginx-DAV without the ext module: PUT and GET
        // are perfect, PROPFIND is not implemented.
        scriptStagedTest(propfind: { _ in 405 })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertTrue(result.success,
                      "the four byte-moving stages passed, so uploads work — failing the whole "
                      + "test here revoked availability and disabled uploads on a server that "
                      + "uploads perfectly")
        XCTAssertFalse(result.returnCapable, "nothing an agent writes can ever come back")
        XCTAssertTrue(result.isUploadOnly, "the third outcome, and every status surface reads it")
        XCTAssertNil(result.listingUnverified, "the server ANSWERED — this is knowledge, not a blank")
        XCTAssertEqual(result.reachedStage, .listing,
                       "every byte-moving stage passed; the return direction is what did not")
        XCTAssertNil(result.failure, "a capability the server has not got is not a failure")
    }

    /// `501 Not Implemented` is the other half of the structural pair (RFC 9110
    /// §15.6.2 — a method the server does not recognise at all), and it must land
    /// in exactly the same place as `405` or the same server behind a slightly
    /// different front end would get a different diagnosis.
    func testStagedTestReportsUploadOnlyOnA501Propfind() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in 501 })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertTrue(result.isUploadOnly)
        XCTAssertTrue(result.success)
    }

    /// THE CORE REPAIR. Every status that is not a structural refusal proves
    /// NOTHING, and the damage of reading one as proof was total: a healthy
    /// WebDAV server whose reverse proxy answered a single `502` while the user
    /// tapped Test Connection was marked permanently unable to return files, the
    /// witness breaker was seeded to match, and no folder was named for the rest
    /// of the process.
    func testAServerErrorDuringTheListingStageProvesNothing() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in 502 })

        let result = await FileServerClient.runConnectionTest(snapshot: snapshot, session: session)

        XCTAssertTrue(result.success, "the upload half was proven with a byte-echo and stays proven")
        XCTAssertTrue(result.returnCapable,
                      "a narrowing may only follow proof — a proxy fault is not the server "
                      + "stating an incapability")
        XCTAssertFalse(result.isUploadOnly, "and it must never be RENDERED as one either")
        XCTAssertEqual(result.listingUnverified?.errorCode, AppError.fileTransferServerError.errorCode,
                       "the surfaces need something to say: 'couldn't check', with the code")
        XCTAssertEqual(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
            .probe,
            "and the dispatch path must be free to measure for itself on the very next turn")
    }

    /// Table-driven, because the boundary IS the fix: one row per class of
    /// answer, and only the two structural statuses may narrow the lane.
    func testOnlyAStructuralRefusalMayNarrowTheLane() async {
        // status → (upload-only?, the code the surfaces show when unverified)
        let cases: [(status: Int, uploadOnly: Bool, unverified: AppError?)] = [
            (405, true, nil),                                  // structural: method not allowed here
            (501, true, nil),                                  // structural: method not implemented
            (401, false, .fileTransferAuthFailed),             // the credential stopped working
            (403, false, .fileTransferServerError),            // PUT/GET just authenticated — a policy refusal, not the password
            (429, false, .fileTransferServerError),            // rate limited this minute
            (500, false, .fileTransferServerError),            // the server is sick
            (502, false, .fileTransferServerError),            // the reverse proxy is
            (302, false, .fileTransferServerError),            // a redirect to a portal
            (200, false, .fileTransferServerError),            // answered, but not a multistatus
        ]
        for row in cases {
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.resetAll()
            let session = makeMockSession()
            scriptStagedTest(propfind: { _ in row.status })
            let result = await FileServerClient.runConnectionTest(
                snapshot: makeSnapshot(), session: session)
            session.invalidateAndCancel()

            XCTAssertTrue(result.success, "uploads stay proven whatever the listing stage says (\(row.status))")
            XCTAssertEqual(result.isUploadOnly, row.uploadOnly, "status \(row.status)")
            XCTAssertEqual(result.listingUnverified?.errorCode, row.unverified?.errorCode,
                           "status \(row.status)")
        }
    }

    /// A catch-all host that answers every path with a `207` cannot witness an
    /// absence, so it can never mint a box — but that is a WALL or a route, not
    /// the server stating it does not implement the method, and real deployments
    /// answer an outer `207` whose inner response is the `404` we asked for.
    /// A status-only reading cannot tell those apart, so it may not diagnose.
    func testACatchAllNamespaceIsUnverifiedRatherThanIncapable() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in 207 })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertTrue(result.success, "uploads were proven before this probe ran")
        XCTAssertFalse(result.isUploadOnly,
                       "a namespace that answers everything is a fixable misconfiguration, and "
                       + "displaying it as a permanent limitation hides the fix")
        XCTAssertNotNil(result.listingUnverified)
    }

    /// AND THE STAGED TEST MUST NOT DISAGREE WITH THE DISPATCH WITNESS ABOUT THE
    /// SAME SERVER. A host whose control PROPFIND comes back as the compliant
    /// `207`-with-an-inner-`404` is a host that CAN say no, so the listing stage
    /// passes — reading only the outer status told the user "couldn't verify,
    /// check again" about a lane that answers the question correctly, while
    /// their dispatches concluded the opposite in silence.
    func testACompliantMultistatusMissPassesTheListingStage() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(
            propfind: { _ in 207 },
            propfindBody: { request in
                guard request.url!.absoluteString.contains("__conduck_absent_") else { return Data() }
                return Data("""
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:">
                  <D:response>
                    <D:href>\(request.url!.path)</D:href>
                    <D:status>HTTP/1.1 404 Not Found</D:status>
                  </D:response>
                </D:multistatus>
                """.utf8)
            })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.returnCapable)
        XCTAssertFalse(result.isUploadOnly)
        XCTAssertNil(result.listingUnverified,
                     "the control demonstrated a definite miss; there is nothing left unverified")
    }

    /// The second probe is not allowed to reach the structural verdict at all:
    /// step one has just had a `207` back, so this server demonstrably performs
    /// the method, and a refusal on the missing-resource route is a fact about
    /// that route.
    func testARefusalOnTheNegativeControlIsNotAMethodIncapability() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { request in
            request.url!.absoluteString.contains("__conduck_absent_") ? 405 : 207
        })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertFalse(result.isUploadOnly)
        XCTAssertNotNil(result.listingUnverified)
    }

    /// The staged verdict SEEDS the dispatch path's witness state, so a lane the
    /// user has just tested costs no per-turn probe to rediscover a fact
    /// Settings is already displaying.
    func testAPassingStagedTestClearsTheWitnessCooldown() async {
        let snapshot = makeSnapshot()
        let lane = BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)
        let breaker = BackgroundFileTransfer.FileLaneWitnessBreaker.shared
        breaker.recordFailure(lane: lane, severity: .unreachable)
        XCTAssertEqual(breaker.decide(lane: lane), .cooldown, "precondition: parked")

        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { request in
            request.url!.absoluteString.contains("__conduck_absent_") ? 404 : 207
        })
        _ = await FileServerClient.runConnectionTest(snapshot: snapshot, session: session)

        XCTAssertEqual(breaker.decide(lane: lane), .probe,
                       "a user who just repaired their server must not keep sending folder-less "
                       + "turns until a cooldown they cannot see expires")
        XCTAssertNil(breaker.faultedSince(lane: lane), "and the thread's rows must clear with it")
    }

    /// The other direction: a structural refusal parks the lane, so the very
    /// next dispatch spends nothing and says nothing.
    func testAnUploadOnlyStagedVerdictSilencesTheDispatchProbe() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in 405 })
        _ = await FileServerClient.runConnectionTest(snapshot: snapshot, session: session)

        XCTAssertEqual(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
            .cannotReturn)
        XCTAssertNil(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.faultedSince(
                lane: BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)),
            "a limitation is not a fault, so no thread row may derive from it")
    }

    /// An UNSETTLED probe states no CAPABILITY — not the incapability, and not
    /// the "witnessed" reset either. The breaker's capability slot is a cache of
    /// facts, and a `502` is not one.
    func testAnUnverifiedListingStageStatesNoCapabilityEitherWay() async {
        let snapshot = makeSnapshot()
        let breaker = BackgroundFileTransfer.FileLaneWitnessBreaker.shared
        let lane = BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)
        // A lane the server has already told us cannot list. An inconclusive
        // test must not let it out of that: widening is a claim, and claims need
        // proof.
        breaker.recordCannotReturn(lane: lane)

        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in 502 })
        _ = await FileServerClient.runConnectionTest(snapshot: snapshot, session: session)

        XCTAssertEqual(breaker.decide(lane: lane), .cannotReturn,
                       "an inconclusive test neither condemns the lane nor exonerates it")
    }

    /// THE COOLDOWN CLEARS WHATEVER THE LISTING STAGE CONCLUDED, and the
    /// asymmetry with the test above is the point: a capability is a claim about
    /// the server and needs proof, while a cooldown is only a guess about
    /// whether another request is worth spending.
    ///
    /// The case that forced it: the server goes unreachable, ONE witness failure
    /// opens the ladder to as much as an hour, the user restarts the server —
    /// same URL, credential and pin, so the lane key does not move — and taps
    /// Test Connection. The four upload stages pass against the repaired server
    /// and a reverse proxy still warming up answers the listing probe `502`. The
    /// user has just proved reachability far better than the streak ever guessed
    /// it, and must not be left waiting out a pause they cannot see.
    func testAPassingTestClearsTheCooldownEvenWhenTheListingStageSettledNothing() async {
        let snapshot = makeSnapshot()
        let breaker = BackgroundFileTransfer.FileLaneWitnessBreaker.shared
        let lane = BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)
        breaker.recordFailure(lane: lane, severity: .unreachable)
        XCTAssertEqual(breaker.decide(lane: lane), .cooldown, "precondition: parked")

        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in 502 })
        let result = await FileServerClient.runConnectionTest(snapshot: snapshot, session: session)

        XCTAssertEqual(breaker.decide(lane: lane), .probe,
                       "four stages of moved bytes outweigh the streak that opened the pause")
        XCTAssertNil(breaker.faultedSince(lane: lane),
                     "and the thread's folder-less rows clear with it")
        XCTAssertTrue(result.returnCapable,
                      "clearing a pause is not a claim — the listing verdict is still unstated")
        XCTAssertNotNil(result.listingUnverified,
                        "and the surfaces still say 'couldn't check' rather than picking an answer")
    }

    /// The probe asks the two questions the dispatch path asks, in the shape it
    /// asks them: `Depth: 0` on a collection that exists, then `Depth: 0` on one
    /// that cannot.
    func testStagedTestPassesWhenPropfindWorksAndCanSayNo() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        var depths: [String] = []
        scriptStagedTest(propfind: { request in
            recorder.record(method: "PROPFIND", url: request.url!)
            depths.append(request.value(forHTTPHeaderField: "Depth") ?? "")
            return request.url!.absoluteString.contains("__conduck_absent_") ? 404 : 207
        })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.reachedStage, .listing, "a full pass now reaches the listing stage")
        XCTAssertNil(result.failure)
        XCTAssertNil(result.listingUnverified)
        XCTAssertTrue(result.folderCapable)

        let propfinds = recorder.calls
        XCTAssertEqual(propfinds.count, 2, "one collection that exists, one that cannot")
        XCTAssertEqual(propfinds.first?.url.absoluteString, "https://fileserver.example.test",
                       "the first asks a collection that certainly exists — the served root")
        XCTAssertTrue(propfinds.last?.url.absoluteString.contains("__conduck_absent_") == true)
        XCTAssertEqual(depths, ["0", "0"],
                       "Depth: 0 — a yes/no question must not enumerate the user's files")
    }

    /// A transport failure on the listing probe is NOT a verdict. It narrows
    /// nothing, and — the part that took a real repair — it must not revoke the
    /// upload direction either: four stages moved real bytes end to end before
    /// this request was ever issued, and a fifth-request hiccup cannot un-prove
    /// them.
    func testStagedTestTolerantOfATransportHiccupOnTheListingProbe() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in throw URLError(.timedOut) })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertTrue(result.success, "uploads stay usable — nothing about them was disproved")
        XCTAssertTrue(result.returnCapable,
                      "`returnCapable` is a NARROWING — only a structural refusal may flip it, "
                      + "or a hiccup would strip file return off a healthy lane")
        XCTAssertEqual(result.listingUnverified?.errorCode,
                       AppError.fileTransferUnreachable.errorCode,
                       "no HTTP answer at all reads as reachability, not as a server fault")
        XCTAssertEqual(result.reachedStage, .listing)
    }

    // MARK: - The mint's typed outcome (which folder-less turns are worth a word)

    /// A dispatch with no lane at all — the unconfigured majority, and every
    /// wrist-originated turn, since the Watch holds no file-server credential by
    /// design. Silent: the user is not missing anything they asked for.
    func testAWristOrUnconfiguredTurnMintsNothingAndSaysNothing() async {
        let outcome = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: nil)

        XCTAssertEqual(outcome, .noLane)
        XCTAssertNil(outcome.key)
        XCTAssertFalse(outcome.isActionableFault,
                       "a device that was never given a credential has not failed at anything")
    }

    /// A lane the STAGED test found return-incapable. Silent, and — the point of
    /// the persisted verdict — silent for FREE on every turn, including the
    /// first one after a relaunch, when the process-local breaker knows nothing.
    ///
    /// The gate is the durable flag, not an inference this dispatch drew: the
    /// witness never issues a request at all here, which is also what stops the
    /// large plain-nginx population paying a `PROPFIND` per turn to re-learn
    /// what Settings already shows them in amber.
    func testAReturnIncapableLaneStaysSilentAndSpendsNothing() async {
        let snapshot = makeSnapshot(returnCapable: false)
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.record(method: request.httpMethod ?? "", url: request.url!)
            return (HTTPURLResponse(url: request.url!, statusCode: 405,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }

        let first = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)
        let second = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertEqual(first, .laneCannotReturn)
        XCTAssertEqual(second, .laneCannotReturn)
        XCTAssertFalse(first.isActionableFault,
                       "a permanent property of the user's server is not a per-turn complaint")
        XCTAssertEqual(recorder.calls.count, 0,
                       "a settled, persisted verdict is not worth one more request")
    }

    /// THE INFERENCE THE DISPATCH PATH MAY NOT DRAW. The witness PROPFINDs the
    /// box this turn is about to name, which by construction is not there — so a
    /// `405` answers a question about the ROUTE a missing path is served by, not
    /// about the method the server performs. Path-scoped `dav_methods`, a WAF,
    /// an SSO layer and a rewrite all produce exactly this on a server that
    /// lists existing collections perfectly.
    ///
    /// The old behaviour marked such a lane permanently and silently incapable
    /// for the rest of the process, from one answer, while the staged test
    /// looking at the same server concluded nothing bad at all.
    func testAStructuralRefusalAtDispatchIsAFaultNotAnIncapability() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 405,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }

        let outcome = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertEqual(outcome, .witnessFailed,
                       "unhelpful answer, not a verdict — the turn is folder-less and says so")
        XCTAssertTrue(outcome.isActionableFault)
        XCTAssertNotEqual(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
            .cannotReturn,
            "a `405` on a path that does not exist may never stamp the lane incapable")
    }

    /// And it is charged as an ANSWERED failure, so the lane keeps the same
    /// three-sample patience every other answered failure earns. Backing off
    /// after one would be the old permanent verdict wearing a cooldown's
    /// clothes.
    func testAStructuralRefusalAtDispatchKeepsTheAnsweredPatience() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.record(method: request.httpMethod ?? "", url: request.url!)
            return (HTTPURLResponse(url: request.url!, statusCode: 405,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }

        for _ in 0..<4 {
            _ = await BackgroundFileTransfer.mintOutboxKey(
                conversationID: UUID(), snapshot: snapshot, session: session)
        }

        XCTAssertEqual(recorder.calls.count, 3,
                       "three samples, then the lane is parked — the `.answered` threshold")
    }

    /// THE OFFLINE-RETRY SCENARIO, end to end. A send from a dead spot used to
    /// charge the lane an `.unreachable` — one strike, cooldown open — so the
    /// retry the user sent the moment their connection came back was
    /// `.witnessSuppressed`, went out folder-less, and drew "No folder for this
    /// reply" under a healthy server's answer. The offline attempt is a fact
    /// about the device; the lane's health must come through it untouched, so
    /// the retry probes normally and gets its folder.
    func testAnOfflineMintChargesNothingAndTheOnlineRetryGetsItsFolder() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }

        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertEqual(offline, .noObservation)
        XCTAssertFalse(offline.isActionableFault,
                       "a request the device never sent is nobody's fault worth a row")
        let lane = BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)
        XCTAssertNil(BackgroundFileTransfer.FileLaneWitnessBreaker.shared.faultedSince(lane: lane),
                     "no streak may open — `faultedSince` is the folder-less row's only live input")
        XCTAssertEqual(BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
                       .probe,
                       "the retry must be allowed to ask, not sat in a cooldown the device caused")

        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        let retry = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertNotNil(retry.key, "connection back, absence witnessed — the retry gets its folder")
    }

    /// And a `-999` the task did NOT cancel — a peer reset, or a pin refusal —
    /// charges the mint like any unreachable lane: one strike, cooldown open.
    /// The device-side carve-out must not widen into a hole a flapping tunnel
    /// or a rotated certificate can hide in.
    func testAnUncancelledCancelMintKeepsTheOneStrikePatience() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { _ in throw URLError(.cancelled) }

        let outcome = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertEqual(outcome, .witnessFailed)
        XCTAssertEqual(BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
                       .cooldown,
                       "lane-authored -999s keep the fast backoff a dead host earns")
    }

    /// THE TWO PATHS MUST AGREE ABOUT ONE SERVER. A route-scoped `405` server —
    /// `PROPFIND` works on collections that exist, missing paths are refused by
    /// a rule in front of it — is the case that used to split them: the staged
    /// test said "couldn't check" while the dispatch witness silently concluded
    /// "cannot ever list". Neither may now claim a capability OR an
    /// incapability; both may only report that nothing was settled.
    func testStagedTestAndDispatchAgreeAboutARouteScoped405Server() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        // The served root exists and lists; anything carrying the negative
        // control's or the mint's entropy is a path that does not exist, and
        // this server's route answers those `405`.
        scriptStagedTest(propfind: { request in
            let path = request.url?.path ?? "/"
            let isRoot = path == "/" || path.isEmpty
            return isRoot ? 207 : 405
        })

        let staged = await FileServerClient.probeListingCapability(
            snapshot: snapshot, session: session, signals: { .empty })

        XCTAssertEqual(staged, .unverified(.fileTransferServerError),
                       "step 2 already refuses to read a `405` on a missing path as a verdict")
        XCTAssertNotEqual(staged, .methodUnavailable)

        let dispatched = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertEqual(dispatched, .witnessFailed,
                       "and the dispatch path reaches the same non-verdict")
        XCTAssertNotEqual(dispatched, .laneCannotReturn)
        XCTAssertNotEqual(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
            .cannotReturn)
    }

    /// The actionable case: a lane the user configured and tested green that has
    /// stopped answering. It must NOT be silent, and it must not be silent only
    /// once either — every turn dispatched into a broken lane genuinely went out
    /// folder-less.
    func testAnUnreachableConfiguredLaneIsAnActionableFault() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { _ in throw URLError(.cannotFindHost) }

        let outcome = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertEqual(outcome, .witnessFailed)
        XCTAssertNil(outcome.key, "no witnessed absence, no folder on the wire")
        XCTAssertTrue(outcome.isActionableFault)
        XCTAssertNotNil(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.faultedSince(
                lane: BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)),
            "and the thread has a streak start to scope its rows against")
    }

    /// A host that is not there will not be there next turn, so ONE observation
    /// opens the cooldown — three would spend ~12 s of the user's time
    /// re-learning it. The turn is still reported folder-less; only the REQUEST
    /// is suppressed.
    func testAnUnreachableLaneStopsBeingProbedAfterOneFailure() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.record(method: request.httpMethod ?? "", url: request.url!)
            throw URLError(.cannotFindHost)
        }

        _ = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)
        let second = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertEqual(second, .witnessSuppressed)
        XCTAssertTrue(second.isActionableFault,
                      "the backoff suppresses the request, never the truth")
        XCTAssertEqual(recorder.calls.count, 1, "the second turn pays no latency at all")
    }

    /// A server that ANSWERS, unhelpfully, keeps its benefit of the doubt for
    /// longer: those failures are transient often enough that one sample is not
    /// a diagnosis, and a one-in-a-billion name collision must not park a
    /// healthy lane.
    func testALaneThatAnswersBadlyIsProbedThreeTimesBeforeBackingOff() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.record(method: request.httpMethod ?? "", url: request.url!)
            return (HTTPURLResponse(url: request.url!, statusCode: 500,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }

        for _ in 0..<4 {
            _ = await BackgroundFileTransfer.mintOutboxKey(
                conversationID: UUID(), snapshot: snapshot, session: session)
        }

        XCTAssertEqual(recorder.calls.count, 3,
                       "three samples, then the lane is parked")
    }

    // MARK: - No lane may nag forever (the occupancy run)

    /// ONE occupied answer proves nothing and says so. A genuine collision on
    /// 128 bits is astronomically unlikely but the next turn mints a different
    /// name anyway, so a single occurrence self-heals and the turn is reported
    /// folder-less like any other failure.
    func testOneOccupiedAnswerIsAFaultNotASilencing() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 207,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }

        let outcome = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertEqual(outcome, .witnessFailed)
        XCTAssertTrue(outcome.isActionableFault)
        XCTAssertNotEqual(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
            .cannotReturn,
            "one answer is not proof of anything about the next name")
    }

    /// A RUN of them is proof, and this is the row that could never be silenced.
    /// Every name in the run carried fresh entropy and every one came back
    /// occupied, so this lane will claim every name Conduck can ever mint and can
    /// never witness an absence. That is a capability limit, and the mint's
    /// contract table says capability limits are silent — otherwise the
    /// folder-less row draws under every agent turn forever with no in-app action
    /// that could stop it.
    func testARunOfOccupiedAnswersSilencesTheLaneInsteadOfNaggingForever() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.record(method: request.httpMethod ?? "", url: request.url!)
            return (HTTPURLResponse(url: request.url!, statusCode: 207,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }

        var outcomes: [BackgroundFileTransfer.OutboxMintOutcome] = []
        for _ in 0..<4 {
            outcomes.append(await BackgroundFileTransfer.mintOutboxKey(
                conversationID: UUID(), snapshot: snapshot, session: session))
        }

        XCTAssertEqual(Array(outcomes.prefix(2)), [.witnessFailed, .witnessFailed],
                       "the first two still might have been bad luck")
        XCTAssertEqual(outcomes[2], .laneCannotReturn,
                       "the answer that completes the run is the one that stops being a fault")
        XCTAssertEqual(outcomes[3], .laneCannotReturn)
        XCTAssertFalse(outcomes[2].isActionableFault, "and it draws no row")
        XCTAssertEqual(recorder.calls.count, 3,
                       "a lane that has proved it can never say no is not worth another request")
        XCTAssertEqual(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
            .cannotReturn)
        XCTAssertNil(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.faultedSince(
                lane: BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)),
            "`faultedSince` is the row's only live input, so silencing the lane has to clear "
            + "it — including for the two turns that were reported as faults before the run "
            + "completed")
    }

    /// AND ONLY A RUN OF OCCUPANCY COUNTS. A `502` mixed into the sequence
    /// answered nothing about whether this lane can say no, so it breaks the
    /// proof rather than contributing to it — a lane having a bad few minutes
    /// must not be mistaken for a lane that answers everything.
    func testAMixedStreakNeverSilencesTheLane() async {
        let snapshot = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let recorder = FileLaneRequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.record(method: request.httpMethod ?? "", url: request.url!)
            // occupied, then a reverse-proxy fault, then occupied again.
            let status = recorder.calls.count == 2 ? 502 : 207
            return (HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }

        var outcomes: [BackgroundFileTransfer.OutboxMintOutcome] = []
        for _ in 0..<3 {
            outcomes.append(await BackgroundFileTransfer.mintOutboxKey(
                conversationID: UUID(), snapshot: snapshot, session: session))
        }

        XCTAssertEqual(outcomes, [.witnessFailed, .witnessFailed, .witnessFailed])
        XCTAssertNotEqual(
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.laneDecision(for: snapshot),
            .cannotReturn,
            "two occupied answers with a 502 between them are not a run")
    }

    /// The way back out, and the only one this state has: a deliberate,
    /// user-watched measurement that shows the lane answering a fresh name with a
    /// definite miss. A passing staged verdict clears the silence exactly as it
    /// clears a cooldown.
    func testAPassingStagedVerdictClearsTheOccupancySilence() async {
        let snapshot = makeSnapshot()
        let breaker = BackgroundFileTransfer.FileLaneWitnessBreaker.shared
        let lane = BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 207,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        for _ in 0..<3 {
            _ = await BackgroundFileTransfer.mintOutboxKey(
                conversationID: UUID(), snapshot: snapshot, session: session)
        }
        XCTAssertEqual(breaker.decide(lane: lane), .cannotReturn, "precondition: silenced")

        breaker.noteStagedVerdict(lane: lane, returnCapable: true)

        XCTAssertEqual(breaker.decide(lane: lane), .probe,
                       "the app narrows on proof and must widen on proof too")
        XCTAssertNil(breaker.faultedSince(lane: lane))
    }

    /// Recovery with no user action: one witnessed absence resets everything,
    /// including the streak the thread's rows are scoped against.
    func testAWitnessedAbsenceResetsTheStreakAndTheRows() async {
        let snapshot = makeSnapshot()
        let breaker = BackgroundFileTransfer.FileLaneWitnessBreaker.shared
        let lane = BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)
        breaker.recordFailure(lane: lane, severity: .answered)
        breaker.recordFailure(lane: lane, severity: .answered)

        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404,
                             httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
        }
        let outcome = await BackgroundFileTransfer.mintOutboxKey(
            conversationID: UUID(), snapshot: snapshot, session: session)

        XCTAssertNotNil(outcome.key)
        XCTAssertFalse(outcome.isActionableFault)
        XCTAssertNil(breaker.faultedSince(lane: lane))
        XCTAssertEqual(breaker.decide(lane: lane), .probe)
    }

    /// Any edit to the URL, the credential or the device-local pin lands on a
    /// NEW lane key, so "I just fixed my settings" needs no reset path at all.
    func testEditingTheLaneConfigurationLandsOnACleanKey() {
        let breaker = BackgroundFileTransfer.FileLaneWitnessBreaker.shared
        let before = makeSnapshot()
        breaker.recordFailure(
            lane: BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: before),
            severity: .unreachable)

        let repointed = makeSnapshot(base: "https://fileserver-2.example.test")
        let repinned = makeSnapshot(fingerprint: "DD:EE:FF")

        XCTAssertEqual(breaker.laneDecision(for: before), .cooldown)
        XCTAssertEqual(breaker.laneDecision(for: repointed), .probe,
                       "a new address is a new lane")
        XCTAssertEqual(breaker.laneDecision(for: repinned), .probe,
                       "a corrected certificate pin is one of the repairs that must reopen "
                       + "the lane instantly, and it moves no durable id")
    }
}

/// Records the `timeoutInterval` of every request a mocked session issued.
/// Locked for the same reason `FileLaneRequestRecorder` is — `startLoading` runs
/// off the test's thread.
final class TimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: TimeInterval) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

/// Records the requests a `MockURLProtocol`-backed session actually issued, so a
/// test can assert on the SEQUENCE rather than only on the verdict. Shared by
/// the MKCOL-freshness cases here and the listing/negative-control cases in
/// `OutboxNegativeControlTests`.
///
/// `@unchecked Sendable` behind a lock: `URLProtocol.startLoading` runs off the
/// test's thread, so an unsynchronised array would be a data race.
final class FileLaneRequestRecorder: @unchecked Sendable {
    struct Call {
        let method: String
        let url: URL
    }

    private let lock = NSLock()
    private var storage: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(method: String, url: URL) {
        lock.lock()
        storage.append(Call(method: method, url: url))
        lock.unlock()
    }
}

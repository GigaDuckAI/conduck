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

    // MARK: - The pre-dispatch absence witness (404, and nothing else)

    /// The verdict rule: ONLY a `404` witnesses that this dispatch's box is not
    /// there yet. `207` is the interesting refusal — it means either a collision
    /// on 128 bits of fresh entropy or a namespace that answers everything, and
    /// under both readings the folder cannot vouch for what turns up in it.
    func testAbsenceIsWitnessedOnlyByAFourOhFour() {
        XCTAssertTrue(FileServerClient.absenceWitnessed(status: 404))
        for status in [200, 204, 207, 301, 302, 401, 403, 405, 409, 500, 503] {
            XCTAssertFalse(FileServerClient.absenceWitnessed(status: status),
                           "status \(status) is not a witnessed absence")
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

        XCTAssertTrue(witnessed, "a definite miss on the box is the witness")
        XCTAssertEqual(recorder.calls.count, 1, "exactly one request — no negative control, no listing")
        XCTAssertEqual(recorder.calls.first?.method, "PROPFIND")
        XCTAssertEqual(depthHeaders, ["0"], "Depth: 0 — the collection itself, not its children")
        XCTAssertEqual(recorder.calls.first?.url.absoluteString,
                       "https://fileserver.example.test/" + key,
                       "aimed at the exact box, never the served root")
    }

    /// Every non-404 answer fails CLOSED. `false` costs one turn without
    /// automatic delivery; a wrong `true` costs the user a file that is not
    /// theirs, so the asymmetry decides the polarity.
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
            XCTAssertFalse(witnessed, "status \(status) must not read as a witnessed absence")
        }
    }

    /// A transport failure witnesses nothing. Freshness that was not observed is
    /// not freshness — including when the failure is a refused certificate,
    /// which reaches here as an ordinary throw and needs no separate arm because
    /// the answer to every failure is the same one Bool.
    func testAbsenceWitnessFailsClosedOnTransportError() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { _ in throw URLError(.secureConnectionFailed) }

        let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: snap,
            collectionKey: "11111111-2222-3333-4444-555555555555/out-0123456789abcdef0123456789abcdef",
            session: session)

        XCTAssertFalse(witnessed, "a request that never got an answer proves no absence")
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

        XCTAssertTrue(witnessed,
                      "a definite miss is a definite miss whatever the server padded it with")
    }

    /// A `207` still fails closed with an over-cap body — the body is irrelevant
    /// in BOTH directions, which is what makes ignoring it safe.
    func testAbsenceWitnessStillFailsClosedOnATwoOhSevenWithAHugeBody() async {
        let snap = makeSnapshot()
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 207,
                             httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data(repeating: 0x41, count: FileServerClient.listingMaxBytes + 1))
        }
        let witnessed = await BackgroundFileTransfer.witnessCollectionAbsent(
            snapshot: snap, collectionKey: Self.witnessBoxKey, session: session)
        XCTAssertFalse(witnessed)
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
    /// answered by `propfind` — `nil` throws, standing in for a transport
    /// failure.
    private func scriptStagedTest(propfind: @escaping (URLRequest) throws -> Int) {
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let ok = { (status: Int, body: Data) in
                (HTTPURLResponse(url: url, statusCode: status,
                                 httpVersion: "HTTP/1.1", headerFields: nil)!, body)
            }
            switch request.httpMethod {
            case "PUT": return ok(201, Data())
            case "GET":
                let nested = url.absoluteString.contains("__conduck_probe__/")
                return ok(200, Data((nested ? "conduck-nested-probe" : "conduck-probe").utf8))
            case "DELETE": return ok(204, Data())
            case "PROPFIND": return ok(try propfind(request), Data())
            default: return ok(200, Data())
            }
        }
    }

    /// PROPFIND is the SOLE delivery authority — it gates every dispatch (the
    /// absence witness) and reads every reply's folder — so a staged test that
    /// never issued one certified half a lane as fully green. The user then got
    /// no file return at all, permanently, with no signal anywhere they could act
    /// on.
    func testStagedTestFailsWhenTheServerCannotAnswerPropfind() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        // A plain-HTTP store, or an nginx-DAV without the ext module: PUT and GET
        // are perfect, PROPFIND is not implemented.
        scriptStagedTest(propfind: { _ in 405 })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reachedStage, .listing,
                       "every byte-moving stage passed; the return direction is what failed")
        XCTAssertEqual(result.failure?.errorCode, AppError.fileTransferNotAFileServer.errorCode)
    }

    /// A catch-all host that answers every path with a `207` passes the listing
    /// itself and can never witness an absence, so it can never mint a box. It
    /// fails the same stage.
    func testStagedTestFailsWhenTheNamespaceAnswersEverything() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in 207 })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.reachedStage, .listing)
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
    /// nothing that could be persisted wrong, and failing an otherwise clean
    /// five-request sequence on the fifth request's hiccup would be a test that
    /// lies about the server.
    func testStagedTestTolerantOfATransportHiccupOnTheListingProbe() async {
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        scriptStagedTest(propfind: { _ in throw URLError(.timedOut) })

        let result = await FileServerClient.runConnectionTest(snapshot: makeSnapshot(), session: session)

        XCTAssertTrue(result.success, "nothing was learned, so nothing is claimed")
        XCTAssertEqual(result.reachedStage, .listing)
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

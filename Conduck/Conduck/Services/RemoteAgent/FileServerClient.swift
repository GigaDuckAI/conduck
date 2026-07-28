// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileServerClient.swift
//
// Agent File Transfer. PURE request-builders + response-parsers + a
// staged "Test Connection" for the user-run file-server (rclone serve webdav
// over HTTPS, exposed via Tailscale Serve / Cloudflare Tunnel). The device is
// a thin CLIENT: it PUTs file bytes to the server ROOT as `<storedKey>`, GETs
// them back, probes existence with a GET (NEVER a HEAD — see below), DELETEs
// orphans, and (V1.1) lists with PROPFIND. GigaDuck ships NO server binary; the
// app is a pure WebDAV client, and standing up the server is the user's job
// (Quick connect via `conduck-connect`, or the setup guide's manual steps).
//
// Mirrors the split in `RemoteAgentClient` / `RemoteAgentClient+TestConnection`:
//   - The `build*Request(...)` helpers are pure URL/header assembly so the
//     wire SHAPE is unit-testable without a network round-trip
//     (`FileServerClientTests`). They do NOT carry the cert-pinning delegate —
//     that lives on the `URLSession` the caller hands the request to
//     (`BackgroundFileTransfer` for transfers, the ephemeral session built
//     here for the staged test).
//   - THREE methods touch the network, and ALL THREE answer server-trust
//     challenges: `runConnectionTest(...)` (the staged test),
//     `probeReachability(...)` and `probeFolderCapability(...)`. Each builds its
//     own session through the single `makeProbeSession(...)` recipe, which
//     clones the ephemeral 15 s cert-pinned `URLSession` pattern from
//     `RemoteAgentClient+TestConnection.swift` so the `RemoteAgentTrustEvaluator`
//     SPKI-pinning delegate is installed for THAT probe only, never on
//     `URLSession.shared` — and each reads the resulting verdicts back through
//     its own `AttemptTrustSignals` source. Audit all three, not just the named
//     one: a trust refusal that goes unread inside a probe degrades to "host is
//     down", which is the one misreading this taxonomy exists to prevent.
//
// Why GET-never-HEAD for existence: a read-only HEAD/GET 200 on a
// gateway that exposes a Control-UI HTML page false-positives existence; rclone
// serve webdav answers GET on a real file with the bytes (200/206) and 404 on a
// missing one, so a GET is the only reliable existence signal. The staged test
// goes further (reachability → auth → write → read → delete) precisely because
// a bare read-only 200 is not trustworthy on its own.
//
// Privacy invariants (see the spec's Privacy & Security section): the storedKey, the base
// URL, the basic-auth credential, and filenames are NEVER logged, printed, or
// echoed into a thrown `AppError`. The credential appears ONLY in the
// `Authorization` header on the request object and (separately) in the setup
// guide's masked credential row the user deliberately copies. Thrown errors are
// taxonomy codes only.

import Foundation

/// Outcome of a single existence probe (GET, never HEAD) against a stored file.
/// Maps a raw HTTP status into the four states the output-download path
/// and the orphan/retry checks care about; anything unexpected
/// collapses to `.unknown` so callers fail closed rather than guess.
enum FileProbeOutcome: Equatable, Sendable {
    /// File is present (HTTP 200 or 206 — rclone answers a ranged GET with 206).
    case exists
    /// File is absent (HTTP 404).
    case missing
    /// Auth rejected (HTTP 401 / 403) — credential wrong or server reconfigured.
    case unauthorized
    /// Server-side fault (HTTP 5xx) — transient, the caller may retry.
    case serverError
    /// This device refused the server's certificate — an untrusted chain, a
    /// pinned key that disagreed with a chain it DID trust, or a key algorithm
    /// Conduck cannot fingerprint. Never `.missing`: a refusal is evidence about
    /// the connection, never about the file, so a caller that acts on absence
    /// must not act on this.
    ///
    /// Distinct from `.unknown` because the two answer different questions.
    /// `.unknown` says "this attempt learned nothing"; this says "this attempt
    /// learned nothing AND no further attempt will, until something outside the
    /// app changes". Only the evaluator's own verdicts can tell them apart —
    /// every refusal arrives as the same bare `-999` a benign cancellation does.
    case certRefused
    /// Any other status (3xx redirect, 4xx other, transport-mapped) — fail closed.
    case unknown
}

/// Outcome of the NON-MUTATING reach+auth probe (`probeReachability`) — a single
/// ranged GET of a key that cannot exist on the server. DISTINCT from
/// `FileProbeOutcome` because the semantics are inverted: here a `404` is the GOOD
/// case (the server answered our not-found probe PAST the auth gate), and a `200`
/// is SUSPICIOUS (a Control-UI / SSO page that 200s everything). Never certifies
/// that uploads work — only the staged write test (`runConnectionTest`) does.
enum FileReachabilityOutcome: Equatable, Sendable {
    /// `404` — the host answered a GET for an impossible key with a clean
    /// "not found" past the auth gate. Reach + auth APPEAR OK. Residual limit
    /// (why the label says "appears"): a server that 404s BEFORE auth, or an
    /// authenticated 404 on a wrong base path, can false-pass — the write test
    /// is the only certification.
    case reachAuthOK
    /// `401` / `403` — the basic-auth credential was rejected.
    case authFailed
    /// `200` / `206` / `416` / `3xx` — the host answered, but with a status a real
    /// WebDAV file-not-found probe should never give (a Control-UI page, a
    /// `Range`-rejecting server, or a redirect-to-login). Reachable, but sign-in
    /// can't be confirmed — flag, don't green.
    case suspicious
    /// `405` / `501` / any other `4xx`/`5xx` — the host answered but
    /// inconclusively. FAIL CLOSED (NOT `authFailed` — a `405` is
    /// "method/endpoint", not "bad credential").
    case inconclusive
    /// Transport failure (DNS / timeout / refused / a transient handshake
    /// hiccup) — the host was not reachable at all.
    case unreachable
    /// The host answered the TLS handshake and this device REFUSED its
    /// certificate. Split from `.unreachable` because the two carry opposite
    /// instructions: unreachable sends the user to check the server is running,
    /// which is exactly wrong here — it is running, and the fix is to give it a
    /// certificate this device trusts.
    case certUntrusted
    /// The host presented a certificate this device DOES trust, and the
    /// configured pin disagreed with its key. Its own outcome because it is the
    /// only one that means the connection may be intercepted: folding it into
    /// `.unreachable` threw that signal away and told the user to check whether
    /// their file server was running, and folding it into `.certUntrusted` would
    /// send them to obtain a certificate they already have.
    case certMismatch
    /// The host presented a certificate this device DOES trust, and Conduck
    /// could not compute a digest for its key algorithm, so the configured pin
    /// was never compared. Its own outcome for the same reason `.certMismatch`
    /// is: sharing that case would tell a user with a valid certificate their
    /// connection may be intercepted, and sharing `.certUntrusted` would send
    /// them to replace a certificate the device already accepts.
    case certKeyUnpinnable
}

/// One entry from a PROPFIND `Depth: 1` directory listing. Built NOW + unit-
/// tested (`FileServerPropfindTests`) but the in-app browser that consumes
/// it is deferred to V1.1 — the minimal output path uses a single
/// GET existence probe, not a listing.
struct FileServerEntry: Equatable, Sendable {
    /// Last path component of the entry's `<D:href>` (the stored name).
    let name: String
    /// Whether the entry is a collection (`<D:collection/>` resource type).
    let isDirectory: Bool
    /// `<D:getcontentlength>` in bytes, or 0 when absent (directories, or a
    /// server that omits the property).
    let byteSize: Int
}

/// The four stages of the staged Test Connection, in order. `Int` raw value =
/// stage ordinal so the Settings UI can render a determinate per-stage
/// result list and `FileTransferTestResult.reachedStage` can report how far the
/// probe got before a failure (or `.read` on a full pass).
///
/// Note: the actual probe runs a 5th step — a best-effort DELETE cleanup of the
/// tiny probe file — AFTER `.read`, but that cleanup is never surfaced as a
/// user-facing stage (its failure does not fail the test; an orphaned 12-byte
/// probe file is harmless and the user owns the server).
enum FileTransferTestStage: Int, Equatable, Sendable, CaseIterable {
    /// TCP/TLS reachability — can we open a connection to the file-server host
    /// at all (DNS resolves, cert validates / pins, port answers)?
    case reachability
    /// Auth — does the basic-auth credential get past the server's gate
    /// (i.e. NOT a 401/403)?
    case auth
    /// Write — can we PUT a tiny probe file and get a 2xx?
    case write
    /// Read — can we GET the probe file back and get a 2xx (proving the write
    /// actually landed and is served, not a Control-UI HTML 200)?
    case read
}

/// Result of a staged Test Connection: how far it got + whether the full
/// reachability→auth→write→read sequence passed + the mapped failure (nil on
/// success). `fileTransferAvailable` is set true ONLY when `success`.
struct FileTransferTestResult: Equatable, Sendable {
    /// The furthest stage reached — on success this is `.read`; on failure it
    /// is the stage that failed (everything before it passed).
    let reachedStage: FileTransferTestStage
    /// True only on a full pass through all four stages.
    let success: Bool
    /// The taxonomy error on failure (nil on success). Never names the
    /// credential.
    let failure: AppError?
    /// Whether the post-pass NESTED write-probe succeeded — i.e. the gateway
    /// accepts a `PUT __conduck_probe__/<uuid>` (folder) + GET + DELETE. True →
    /// uploads can mint per-conversation `<convID>/…` keys; false → the gateway
    /// rejected nested PUTs (nginx-DAV needing MKCOL, an S3-DAV bridge, …) so the
    /// client must fall back to FLAT `<8hex>__<name>` keys for it. Defaults true
    /// so a failed connectivity test (where the nested probe never runs) and
    /// every legacy construction read as folder-capable until proven otherwise —
    /// the flat fallback is a narrowing, only flipped on a definitive nested-PUT
    /// rejection. NOT a user-facing stage (the nested probe failing does NOT fail
    /// the connection test — flat keys still work fine).
    let folderCapable: Bool

    init(
        reachedStage: FileTransferTestStage,
        success: Bool,
        failure: AppError?,
        folderCapable: Bool = true
    ) {
        self.reachedStage = reachedStage
        self.success = success
        self.failure = failure
        self.folderCapable = folderCapable
    }

    /// `AppError` is `LocalizedError`, NOT `Equatable` (its `Error`-carrying
    /// cases can't synthesize `==`). Compare the failure by its stable numeric
    /// `errorCode` so this value stays `Equatable` for tests without forcing an
    /// `AppError: Equatable` conformance across the whole taxonomy.
    static func == (lhs: FileTransferTestResult, rhs: FileTransferTestResult) -> Bool {
        lhs.reachedStage == rhs.reachedStage
            && lhs.success == rhs.success
            && lhs.failure?.errorCode == rhs.failure?.errorCode
            && lhs.folderCapable == rhs.folderCapable
    }
}

/// Pure request-builders + response-parsers + the staged Test Connection for
/// the user-run file-server. Stateless namespace `enum` (no instances) — every
/// method is `static`. The transfer-execution side (background upload/download,
/// progress, delegate cert-pinning) lives in `BackgroundFileTransfer`,
/// which consumes the `build*Request(...)` helpers here.
enum FileServerClient {

    // MARK: - Stored-key minting

    /// Longest single path component a stored key may occupy, in characters.
    ///
    /// Every stored key's last segment becomes a real filename on whatever
    /// filesystem backs the user's file server, where POSIX `NAME_MAX` is 255
    /// BYTES. Sanitization maps each character to one of `[A-Za-z0-9._-]`, all
    /// single-byte, so a sanitized component's character count IS its byte count
    /// and the budget can be counted in characters.
    ///
    /// The cap sits below 255 to leave headroom for a temporary name the server
    /// may write and rename into place during a PUT. A key that only overflows
    /// once the server appends its own suffix fails just as hard as one that
    /// overflows on its own, and diagnosing that from an opaque 5xx is far worse
    /// than reserving the room up front.
    static let storedKeyComponentMaxCharacters = 200

    /// Longest dot-suffix still treated as an extension worth preserving.
    ///
    /// Real extensions are short (`.markdown` is 9). The bound exists so a
    /// pathological name whose "extension" is hundreds of characters cannot
    /// consume the budget the stem needs — such a name is truncated blind
    /// instead, which is the better failure.
    private static let maxPreservedExtensionCharacters = 16

    /// Bound an already-sanitized name so `<prefix><name>` fits inside one path
    /// component, keeping the file extension.
    ///
    /// The stem is what gets cut, because an agent routes on the extension: a
    /// `report.pdf` shortened to `repo.pdf` is still a PDF to whatever tooling
    /// opens it, where `report.p` is nothing at all.
    ///
    /// Pure and deterministic, which the retry path depends on — the same inputs
    /// must re-mint the same key so a re-PUT overwrites the partial blob instead
    /// of orphaning it. And a no-op for every name that already fits, so no key
    /// any existing conversation already holds changes shape.
    static func boundedStoredKeyName(
        _ safeName: String,
        reservedPrefixCharacters: Int
    ) -> String {
        let budget = storedKeyComponentMaxCharacters - reservedPrefixCharacters
        guard budget > 0 else { return "" }
        guard safeName.count > budget else { return safeName }

        // The extension is the last dot-suffix, but only when the dot is not the
        // leading character — a dotfile like `.gitignore` is all stem, and
        // treating it as an extension would truncate away the entire name.
        var stem = safeName
        var ext = ""
        if let dot = safeName.lastIndex(of: "."), dot != safeName.startIndex {
            let suffix = safeName[dot...]
            if suffix.count <= maxPreservedExtensionCharacters, suffix.count < budget {
                stem = String(safeName[..<dot])
                ext = String(suffix)
            }
        }
        return String(stem.prefix(budget - ext.count)) + ext
    }

    /// Derive the opaque stored name for an attachment:
    /// `[<folder>/]<8 lowercase hex>__<sanitized original>` (with the
    /// per-conversation folder prefix).
    ///
    /// - The 8-hex prefix is the first 8 hex digits of `uuid` (lowercased, no
    ///   dashes) — enough entropy to avoid collisions in the agent's working
    ///   folder while staying short + human-glanceable in the spliced
    ///   "saved as …" chat line.
    /// - The original name is sanitized to the WebDAV-safe set `[A-Za-z0-9._-]`;
    ///   every other character (spaces, slashes, unicode, shell-metachars) is
    ///   replaced with `_`. This keeps the FILENAME segment a single safe path
    ///   component for both the `PUT baseURL/<storedKey>` URL and the agent's
    ///   shell-side tooling. An empty sanitized result (e.g. a name that was all
    ///   spaces) falls back to `"file"` so the key is always well-formed.
    /// - The sanitized name is then bounded so the whole `<8hex>__<name>`
    ///   component fits `storedKeyComponentMaxCharacters`, extension preserved
    ///   (`boundedStoredKeyName`). Unbounded, a filename the source filesystem
    ///   happily accepts at its own 255-byte limit mints a LONGER component here
    ///   — the 8-hex prefix and `__` are pure additions — which the file server's
    ///   filesystem then refuses, so the attachment cannot be sent at all.
    /// - `folder` (optional) namespaces the upload under a per-conversation
    ///   directory: when present (and non-empty after the same safe-set
    ///   sanitization — a `conversationID` UUID string is already in the safe
    ///   set, so it passes through verbatim), the key becomes
    ///   `<folder>/<8hex>__<name>`. The lone `/` between folder and filename is a
    ///   real path SEPARATOR — `URL.appending(path:)` keeps it unescaped. WebDAV
    ///   servers do NOT auto-create a missing parent on a nested PUT (RFC 4918
    ///   §9.7 — a 409; `rclone serve webdav` answers exactly that), so the
    ///   uploader MKCOLs the parent collection first (`ensureCollection`). A
    ///   gateway that still rejects the nested PUT after MKCOL (probed at Test
    ///   Connection → `folderCapable=false`) passes `folder: nil` here and gets
    ///   the historic flat `<8hex>__<name>`.
    ///
    /// Deterministic given the same `(originalName, uuid, folder)` — tests assert
    /// this so a retry mints the SAME key (the bytes are already on the server).
    static func makeStoredKey(originalName: String, uuid: UUID, folder: String? = nil) -> String {
        // First 8 hex of the UUID, lowercased, no dashes. `uuidString` is
        // upper-cased with dashes (`E621E1F8-C36C-...`); strip + lower + take 8.
        let hex = uuid.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let shortID = String(hex.prefix(8))

        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = String(originalName.map { allowed.contains($0) ? $0 : "_" })
        let safeName = sanitized.isEmpty ? "file" : sanitized

        let prefix = "\(shortID)__"
        let baseKey = prefix + boundedStoredKeyName(
            safeName,
            reservedPrefixCharacters: prefix.count
        )

        // Prefix the per-conversation folder when supplied + capable. The folder
        // segment is sanitized through the SAME safe set (a UUID string is
        // already safe; this guards a hand-crafted caller). An empty/degenerate
        // sanitized folder falls back to the flat key (never emit a leading `/`).
        guard let folder, !folder.isEmpty else { return baseKey }
        let safeFolder = String(folder.map { allowed.contains($0) ? $0 : "_" })
        guard !safeFolder.isEmpty else { return baseKey }
        // The folder is its own path component, so it carries the same NAME_MAX
        // budget as the filename. A plain truncation is right here where the
        // filename gets extension-aware treatment: a directory name has no
        // extension to protect, and the value is a `conversationID` UUID (36
        // characters) in every real caller.
        return "\(safeFolder.prefix(storedKeyComponentMaxCharacters))/\(baseKey)"
    }

    /// Derive the deterministic stored key for a SHARE-EXTENSION attachment:
    /// `<8 lowercase hex of envelopeID>-<sequence>__<sanitized original>`.
    ///
    /// Distinct from `makeStoredKey(originalName:uuid:)` (the in-app composer's
    /// per-attachment-UUID key) because the share drain must recompute the SAME
    /// key on a relaunch WITHOUT a persisted per-attachment UUID — only the
    /// envelope UUID + the attachment's `sequence` survive (both live in the
    /// manifest). The `-<sequence>` segment keeps two same-named files in one
    /// envelope from colliding, so the key is unique per attachment AND stable
    /// across a re-PUT (idempotent, exactly-once recovery).
    ///
    /// - The 8-hex prefix is the first 8 hex digits of `envelopeID` (lowercased,
    ///   no dashes) — enough entropy in the agent's flat working folder while
    ///   staying short + glanceable in the spliced "saved as …" chat line.
    /// - `originalName` is sanitized to the WebDAV-safe set `[A-Za-z0-9._-]`;
    ///   every other character (spaces, slashes, unicode, shell-metachars) is
    ///   replaced with `-` (a single safe path component for the
    ///   `PUT baseURL/<storedKey>` URL + the agent's shell-side tooling). An empty
    ///   sanitized result (e.g. a name that was all spaces) falls back to `"file"`
    ///   so the key is always well-formed.
    /// - The sanitized name is then bounded to fit
    ///   `storedKeyComponentMaxCharacters` with the extension preserved, exactly
    ///   as the in-app key is. The budget is derived from the prefix actually
    ///   built, because `sequence` widens it. `SharedInboxManifest` already
    ///   bounds `originalName` on the way in, but that guards the manifest, not
    ///   this component — a manifest decoded from an older build carries whatever
    ///   name it was written with, and the bound belongs where the filesystem
    ///   constraint actually is.
    ///
    /// Deterministic given the same `(envelopeID, sequence, originalName, folder)`
    /// — tests assert this so a relaunch re-mints the SAME key (the bytes are
    /// already on the server) and that distinct `sequence`s never collide.
    ///
    /// `folder` (optional) namespaces the upload under the per-conversation
    /// directory `<folder>/<8hex>-<seq>__<name>` — applied uniformly with the
    /// in-app `makeStoredKey` so EVERY file a conversation receives (composer or
    /// share-extension) lands under the same `<conversationID>/` folder. Idempotent
    /// recovery still holds: a relaunch passes the SAME folder (the routed
    /// `conversationID`) so the re-mint is byte-identical. A gateway probed
    /// `folderCapable=false` passes `folder: nil` → the historic flat key.
    static func deterministicStoredKey(
        envelopeID: UUID,
        sequence: Int,
        originalName: String,
        folder: String? = nil
    ) -> String {
        let hex = envelopeID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let shortID = String(hex.prefix(8))

        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = String(originalName.map { allowed.contains($0) ? $0 : "-" })
        let safeName = sanitized.isEmpty ? "file" : sanitized

        // `sequence` widens the prefix, so the name budget is derived from the
        // prefix actually built rather than a hardcoded width.
        let prefix = "\(shortID)-\(sequence)__"
        let baseKey = prefix + boundedStoredKeyName(
            safeName,
            reservedPrefixCharacters: prefix.count
        )

        guard let folder, !folder.isEmpty else { return baseKey }
        let safeFolder = String(folder.map { allowed.contains($0) ? $0 : "_" })
        guard !safeFolder.isEmpty else { return baseKey }
        return "\(safeFolder.prefix(storedKeyComponentMaxCharacters))/\(baseKey)"
    }

    // MARK: - Auth

    /// Build the `Authorization: Basic <base64(user:password)>` header VALUE
    /// (the full string including the `"Basic "` scheme prefix).
    ///
    /// Privacy: the returned string embeds the credential — callers set it
    /// directly onto a `URLRequest` and never log it. The caller is responsible
    /// for keeping the value off any logging path.
    static func basicAuthHeaderValue(username: String, password: String) -> String {
        let raw = "\(username):\(password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    // MARK: - Request builders (pure)

    /// `PUT <baseURL>/<storedKey>` — upload the file bytes to the server root.
    ///
    /// - `Content-Type: application/octet-stream` (rclone serve webdav accepts
    ///   any body; octet-stream is the safe generic for arbitrary bytes — the
    ///   agent's own tooling sniffs the real type from the bytes / original name).
    /// - `Content-Length` is set only when `contentLength` is known up front
    ///   (the background uploadTask supplies the body via a file URL, which lets
    ///   `URLSession` set the length itself; the pure path may still pass it for
    ///   tests / non-streamed uploads).
    /// - `timeoutInterval = fileTransferRequestTimeout` (600 s — a multi-MB PUT
    ///   over a home tunnel can take real time).
    static func buildUploadRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String,
        contentLength: Int?
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: storedKey))
        request.httpMethod = "PUT"
        request.timeoutInterval = Constants.fileTransferRequestTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let contentLength {
            request.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    /// `MKCOL <baseURL>/<collectionKey>` — create the parent collection (folder)
    /// for nested uploads. WebDAV servers do NOT auto-create a missing parent on
    /// `PUT <folder>/<file>` (RFC 4918 §9.7 — a 409; rclone answers exactly
    /// that), so the client creates the folder explicitly before the first
    /// nested PUT. On a server where the collection already exists MKCOL answers
    /// 405 — callers treat every outcome as best-effort (the PUT that follows is
    /// the authoritative verdict). Probe-length timeout: MKCOL is a tiny
    /// bodyless request, never a multi-MB transfer.
    static func buildMkcolRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: collectionKey))
        request.httpMethod = "MKCOL"
        request.timeoutInterval = Constants.fileServerProbeTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    /// Best-effort MKCOL of `collectionKey` ahead of a nested PUT. Swallows
    /// every outcome — 201 (created), 405 (already exists), any other status,
    /// transport errors — because the nested PUT that follows is the
    /// authoritative pass/fail, and a server that auto-creates parents never
    /// needed the MKCOL at all. Shared by the Test-Connection nested probe and
    /// `BackgroundFileTransfer.uploadFile` so the probe exercises the EXACT
    /// sequence real uploads use.
    static func ensureCollection(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession
    ) async {
        _ = await performMkcol(snapshot: snapshot, collectionKey: collectionKey, session: session)
    }

    /// MKCOL `collectionKey` and report the HTTP status (nil on transport
    /// error). Same wire call as `ensureCollection`; separated so the
    /// folder-capability probe can tell "collection ensured" (2xx created /
    /// 405 already-exists) from an AMBIENT failure (timeout, 5xx, auth) —
    /// a nested-PUT 409 after the latter is indeterminate, not a verdict
    /// that the server rejects folders.
    static func performMkcol(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession
    ) async -> Int? {
        let request = buildMkcolRequest(snapshot: snapshot, collectionKey: collectionKey)
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// `GET <baseURL>/<storedKey>` — download the file bytes.
    /// `timeoutInterval = fileTransferRequestTimeout` (same multi-MB budget as
    /// upload).
    static func buildDownloadRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: storedKey))
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.fileTransferRequestTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    /// `GET <baseURL>/<storedKey>` for an EXISTENCE probe — NEVER HEAD
    /// (a read-only HEAD/GET on a Control-UI HTML page
    /// false-positives; a GET against rclone serve webdav returns the bytes on
    /// 200/206 and 404 on miss, the only reliable existence signal).
    ///
    /// Ranged to `bytes=0-0` so the probe stays an O(1) existence check and can
    /// NEVER pull the whole file into memory: `rclone serve webdav` honours the
    /// range and answers a present file with `206` + 1 byte, a missing file with
    /// `404`, and an empty file with `416` — all mapped by `parseProbeOutcome`. A
    /// server that ignores `Range` still returns `200` + the full body (no worse
    /// than an unranged GET), so the range is a strict safety cap, never a
    /// correctness dependency. Without it, probing a reply that names a large
    /// existing output (e.g. `export.zip`) would download the entire file into a
    /// single in-memory `Data` on every reply, before the user taps anything —
    /// an OOM/jetsam risk on iOS. The real chip download stays a full-range GET
    /// (`buildDownloadRequest`).
    ///
    /// Identical wire shape to the download request EXCEPT the short
    /// `fileServerProbeTimeout` (15 s — interactive, the user is waiting; this
    /// is a quick "does it exist?" not a bulk transfer) and the `Range` cap.
    /// Kept as a separate builder so the two timeouts never drift.
    static func buildProbeRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: storedKey))
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.fileServerProbeTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        // Existence-only: cap the body at a single byte. A server that ignores
        // Range degrades to a full-body 200 (parsed identically as `.exists`).
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        return request
    }

    /// `DELETE <baseURL>/<storedKey>` — best-effort orphan cleanup (a cancelled
    /// in-flight upload, or the probe file after the staged test). The caller
    /// treats the result as best-effort and never throws on failure.
    /// `timeoutInterval = fileServerProbeTimeout` (a DELETE is lightweight).
    static func buildDeleteRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: storedKey))
        request.httpMethod = "DELETE"
        request.timeoutInterval = Constants.fileServerProbeTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    /// `PROPFIND <baseURL>` with a `Depth` header — directory listing (V1.1
    /// browser; parser is `parsePropfindBody`). Built + unit-tested now so the
    /// 207 multistatus path is ready when the browser ships.
    ///
    /// The request body is the standard `<D:propfind><D:allprop/></D:propfind>`
    /// envelope so any compliant WebDAV server returns the property set.
    /// `timeoutInterval = fileServerProbeTimeout` (a listing is interactive).
    static func buildPropfindRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        depth: Int
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = Constants.fileServerProbeTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>".utf8
        )
        return request
    }

    // MARK: - Response parsers (pure)

    /// Map a raw HTTP status code to a `FileProbeOutcome`:
    ///   - 200 / 206 / 416 → `.exists` (rclone answers a ranged GET with 206;
    ///     416 Range-Not-Satisfiable means the resource EXISTS but is shorter
    ///     than the `bytes=0-0` probe range — i.e. an empty file — a missing
    ///     file 404s, so 416 is unambiguously "exists")
    ///   - 404       → `.missing`
    ///   - 401 / 403 → `.unauthorized`
    ///   - 5xx       → `.serverError`
    ///   - anything else → `.unknown` (fail closed)
    static func parseProbeOutcome(status: Int) -> FileProbeOutcome {
        switch status {
        case 200, 206, 416:
            return .exists
        case 404:
            return .missing
        case 401, 403:
            return .unauthorized
        case 500...599:
            return .serverError
        default:
            return .unknown
        }
    }

    /// Map a raw HTTP status from the NON-MUTATING reach+auth probe (a GET of a
    /// key that cannot exist) to a `FileReachabilityOutcome`. Inverted vs
    /// `parseProbeOutcome` (see the enum): `404` is the intended PASS.
    ///   - `404`                    → `.reachAuthOK`
    ///   - `401` / `403`            → `.authFailed`
    ///   - `200` / `206` / `416`    → `.suspicious` (a real WebDAV 404-probe never
    ///                                 returns "exists"; a `200` here is a
    ///                                 Control-UI/login page)
    ///   - `3xx`                    → `.suspicious` (a raw redirect surfaced by a
    ///                                 non-redirect-following session; in
    ///                                 production `URLSession` follows redirects
    ///                                 and this classifies the FINAL status)
    ///   - anything else            → `.inconclusive` (fail closed — `405`/`501`/
    ///                                 other `4xx`/`5xx` are NOT auth failures)
    static func classifyReachability(status: Int) -> FileReachabilityOutcome {
        switch status {
        case 404:
            return .reachAuthOK
        case 401, 403:
            return .authFailed
        case 200, 206, 416:
            return .suspicious
        case 300...399:
            return .suspicious
        default:
            return .inconclusive
        }
    }

    /// Parse a WebDAV `207 Multi-Status` body into `[FileServerEntry]`.
    /// TOLERANT by contract — NEVER throws. Any malformed / unexpected / empty
    /// XML yields `[]` so a flaky server can never crash the (V1.1) browser.
    ///
    /// Strategy: a lightweight `XMLParser` delegate that, namespace-agnostically
    /// (matching the LOCAL element name so it works whether the server uses the
    /// `D:` / `d:` / no prefix for the `DAV:` namespace), collects per-`response`:
    ///   - `<href>`             → the entry path (last component → `name`)
    ///   - `<getcontentlength>` → `byteSize`
    ///   - `<collection/>` inside `<resourcetype>` → `isDirectory`
    static func parsePropfindBody(_ data: Data) -> [FileServerEntry] {
        guard !data.isEmpty else { return [] }
        let delegate = PropfindParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false   // match local names; tolerate any/no prefix
        // Ignore the Bool result — a parse error just means we keep whatever
        // entries completed before the fault (tolerant; never throw).
        parser.parse()
        return delegate.entries
    }

    // MARK: - Staged Test Connection (the only network-touching method)

    /// Run the staged Test Connection against `snapshot`'s file-server:
    /// **reachability → auth → write(PUT tiny probe) → read(GET) → delete(cleanup)**.
    /// Sets `fileTransferAvailable` (caller side) only on a full pass — a
    /// read-only 200 false-positives on a Control-UI HTML page, so availability
    /// requires the write+read round-trip to actually land.
    ///
    /// - The probe file is `__conduck_probe_<8hex>.txt` with a tiny known body;
    ///   it is GET-read back, then best-effort DELETEd. A DELETE failure does
    ///   NOT fail the test (a stray 12-byte probe file is harmless on the user's
    ///   own server).
    /// - When `session` is nil, builds a 15 s ephemeral cert-pinned
    ///   `URLSession` (cloning `RemoteAgentClient+TestConnection`) so the
    ///   `RemoteAgentTrustEvaluator` SPKI delegate is installed for THIS probe
    ///   only. Tests inject a `MockURLProtocol`-backed session instead.
    ///
    /// Returns the furthest `reachedStage` + `success` + the mapped `failure`
    /// (nil on success). Never throws — every failure is captured into the
    /// result so the UI renders a per-stage outcome list. Never names the
    /// credential in the failure.
    static func runConnectionTest(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession? = nil,
        signalsOverride: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)? = nil
    ) async -> FileTransferTestResult {
        // Build (or adopt) the probe session. When we build it, install the
        // SPKI-pinning delegate scoped to THIS probe only — same posture as the
        // converse Test Connection. What a TLS-rejection URLError resolves to is
        // decided by the evaluator's own POSITIVE verdicts, never by whether a
        // pin exists. `signalsOverride` is the test seam (an injected session
        // has no real evaluator to read); production reads the real evaluator,
        // so a certificate the device does not trust is reported as such instead
        // of being discarded by construction.
        //
        // ONE closure returning the whole snapshot, not several loose Bools: the
        // staged test issues a SEQUENCE of requests on this session, and reading
        // the verdicts separately could pair one request's system verdict with
        // another's pin verdict.
        let pin = snapshot.certFingerprintHex
        let ownsSession: Bool
        let probeSession: URLSession
        let signals: @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
        if let session {
            probeSession = session
            ownsSession = false
            signals = Self.probeSignals(override: signalsOverride, evaluator: nil)
        } else {
            let built = makeProbeSession(pinnedFingerprintHex: pin)
            probeSession = built.session
            ownsSession = true
            signals = Self.probeSignals(override: signalsOverride, evaluator: built.evaluator)
        }
        if ownsSession {
            defer { probeSession.invalidateAndCancel() }
            return await performStagedTest(snapshot: snapshot, session: probeSession, signals: signals)
        } else {
            return await performStagedTest(snapshot: snapshot, session: probeSession, signals: signals)
        }
    }

    /// Resolve the attempt-verdict source for a probe: the override answers when
    /// one is supplied, otherwise the real evaluator does (and `.empty`'s
    /// no-verdict values stand in when there is neither — an injected mock
    /// session raises no challenge, so no verdict is the truthful reading).
    ///
    /// THE OVERRIDE SUPPLIES A WHOLE `AttemptTrustSignals`, never a field at a
    /// time. Deriving one field from another input is what this seam is
    /// forbidden to do: it previously read `challengeRefused` off "a pin is
    /// configured", which is precisely the proxy the classifier removed —
    /// correct only because of an invariant inside `decide`, invisible from
    /// here, and reintroduced on a REAL lane the moment someone shares one
    /// session between Diagnostics probes. It also let the file-lane tests lock
    /// a signal shape production never produces (a cold tunnel raises no
    /// challenge, so nothing can have refused it). A whole snapshot makes the
    /// test state the shape it is testing, and leaves the seam with nothing to
    /// infer.
    private static func probeSignals(
        override: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)?,
        evaluator: RemoteAgentTrustEvaluator?
    ) -> @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals {
        if let override { return override }
        return { evaluator?.attemptSignals ?? .empty }
    }

    /// NON-MUTATING reach+auth probe — a SINGLE ranged GET of a key that cannot
    /// exist on the server, mapped by `classifyReachability`. Wired into the
    /// explicit "Test connections" tap so Diagnostics can say something about a
    /// file lane WITHOUT the staged write test's PUT/DELETE. It NEVER mutates the
    /// server and NEVER sets `fileTransferAvailable`, and its best outcome is a
    /// WARNING, never a pass (`DiagnosticsRunner.fileReachStatus`): a `404` pass
    /// signal is equally consistent with a read-only server, a wrong base path,
    /// or a host that 404s before auth. Only `runConnectionTest` certifies uploads.
    ///
    /// Session posture mirrors `runConnectionTest`: when `session` is nil, builds
    /// the 15 s ephemeral cert-pinned `URLSession` (SPKI delegate scoped to THIS
    /// probe only); tests inject a `MockURLProtocol`-backed session, and
    /// `signalsOverride` is the seam that stands in for the evaluator such a
    /// session does not carry.
    ///
    /// A transport failure is classified by the SAME
    /// `RemoteAgentTrustEvaluator.classifyTransportError` the staged write test
    /// uses, reading the SAME attempt snapshot, so the two file-lane probes
    /// cannot tell a user two different stories about one server. All three
    /// certificate classes survive: a chain the device refuses is
    /// `.certUntrusted`, a pin that disagreed with a chain it accepted is
    /// `.certMismatch`, and a key that could not be hashed at all is
    /// `.certKeyUnpinnable` — folding any of them into `.unreachable` produces
    /// the "check your file-server is running" row for a host that answered, and
    /// in the mismatch case discards the one signal that means the connection may
    /// be intercepted. Everything else still folds to `.unreachable`. Never names
    /// the credential.
    static func probeReachability(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession? = nil,
        signalsOverride: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)? = nil
    ) async -> FileReachabilityOutcome {
        let probeSession: URLSession
        let ownsSession: Bool
        let signals: @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
        if let session {
            probeSession = session
            ownsSession = false
            signals = Self.probeSignals(override: signalsOverride, evaluator: nil)
        } else {
            let built = makeProbeSession(pinnedFingerprintHex: snapshot.certFingerprintHex)
            probeSession = built.session
            ownsSession = true
            signals = Self.probeSignals(override: signalsOverride, evaluator: built.evaluator)
        }
        defer { if ownsSession { probeSession.invalidateAndCancel() } }

        // A key that cannot exist — a real WebDAV file-not-found probe. The
        // 12-hex tag makes a collision with a real stored file impossible.
        let reachTag = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let reachKey = "__conduck_reach_\(reachTag)__"
        let request = buildProbeRequest(snapshot: snapshot, storedKey: reachKey)

        do {
            let (_, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable
            }
            return classifyReachability(status: http.statusCode)
        } catch {
            // Both trust signals are POSITIVE — set only once a server-trust
            // challenge actually failed — so a cold tunnel or a dead host leaves
            // both false and still reads as unreachable. A non-`URLError` is
            // unclassifiable and takes the same conservative answer.
            guard let urlError = error as? URLError else { return .unreachable }
            switch RemoteAgentTrustEvaluator.classifyTransportError(urlError.code, signals: signals()) {
            case .untrustedCert: return .certUntrusted
            case .certMismatch: return .certMismatch
            case .certKeyUnpinnable: return .certKeyUnpinnable
            case .timeout, .unreachable, .cancelled: return .unreachable
            }
        }
    }

    // MARK: - Private

    /// Build the 15 s ephemeral cert-pinned probe session + its trust
    /// evaluator. The ONE session recipe for every FileServerClient entry that
    /// constructs its own (staged test, reach probe, folder-capability probe)
    /// — a timeout/TLS/cache-posture change lands in all three at once instead
    /// of silently diverging per probe. The caller owns invalidation.
    private static func makeProbeSession(
        pinnedFingerprintHex: String?
    ) -> (session: URLSession, evaluator: RemoteAgentTrustEvaluator) {
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: pinnedFingerprintHex)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.fileServerProbeTimeout
        config.timeoutIntervalForResource = Constants.fileServerProbeTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return (URLSession(configuration: config, delegate: evaluator, delegateQueue: nil), evaluator)
    }

    /// Execute the staged sequence on a ready `session`. Factored out of
    /// `runConnectionTest` so the session-ownership / `defer` plumbing stays in
    /// the public method and this body reads as a linear stage list.
    private static func performStagedTest(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession,
        signals: @escaping @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) async -> FileTransferTestResult {
        // Mint a unique tiny probe file name for this test run. The 8-hex tag
        // keeps concurrent / repeated tests from colliding on the same key.
        let probeTag = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let probeKey = "__conduck_probe_\(probeTag).txt"
        let probeBody = Data("conduck-probe".utf8)

        // --- Stage 1+2: reachability + auth (folded into the write attempt's
        // transport + status classification) ---
        //
        // The PUT is the first request that actually reaches the server, so its
        // TRANSPORT outcome answers reachability and its STATUS answers auth.
        // We classify a transport failure as a reachability/cert failure and a
        // 401/403 as an auth failure BEFORE crediting the write stage.

        // Body travels via `upload(for:from:)` ONLY — setting `httpBody` too makes
        // URLSession warn ("upload task should not contain a body or a body stream").
        let writeRequest = buildUploadRequest(snapshot: snapshot, storedKey: probeKey, contentLength: probeBody.count)

        let writeStatus: Int
        do {
            let (_, response) = try await session.upload(for: writeRequest, from: probeBody)
            guard let http = response as? HTTPURLResponse else {
                // No HTTP response → treat as unreachable; we got past TLS but
                // the server answered something non-HTTP.
                return FileTransferTestResult(reachedStage: .reachability, success: false, failure: .fileTransferUnreachable)
            }
            writeStatus = http.statusCode
        } catch let error as URLError {
            // Transport failure on the first request → reachability stage.
            // A pin mismatch is the one case we surface as cert-mismatch.
            return FileTransferTestResult(
                reachedStage: .reachability,
                success: false,
                failure: mapTransportError(error, signals: signals())
            )
        } catch {
            return FileTransferTestResult(reachedStage: .reachability, success: false, failure: .fileTransferUnreachable)
        }

        // Reachability passed (we got an HTTP status). Now classify auth.
        if writeStatus == 401 || writeStatus == 403 {
            return FileTransferTestResult(reachedStage: .auth, success: false, failure: .fileTransferAuthFailed)
        }
        if (500...599).contains(writeStatus) {
            // Server sick during the write — fail at the write stage with a
            // retryable server error (auth implicitly passed: a 5xx is not a
            // 401/403).
            return FileTransferTestResult(reachedStage: .write, success: false, failure: .fileTransferServerError)
        }
        // 404 / 405 / 501 on the PUT: the endpoint took the request but refuses
        // to STORE at it — a read-only nginx, the gateway's own web UI on the
        // wrong port, a base path that isn't the DAV root. This is the likeliest
        // real misconfiguration, and "couldn't upload the file" sends the user
        // hunting a transport problem that doesn't exist. Name the actual cause.
        if writeStatus == 404 || writeStatus == 405 || writeStatus == 501 {
            return FileTransferTestResult(reachedStage: .write, success: false, failure: .fileTransferNotAFileServer)
        }
        guard (200...299).contains(writeStatus) else {
            // Any other non-2xx on the write (a redirect, a 4xx we can't
            // attribute) → the write did not land. Fail the write stage.
            return FileTransferTestResult(reachedStage: .write, success: false, failure: .fileTransferUploadFailed)
        }

        // --- Stage 4: read (GET the probe back) ---
        // This is the stage that defeats the Control-UI-HTML / uniform-200
        // auth-wall false-positive: we only trust the connection if the VERY
        // BYTES we just wrote come back. Status classification is the first gate
        // (a non-2xx/404/416 still fails the read stage here), but a uniform-200
        // SSO proxy that answers every GET with its own HTML passes the status
        // gate — so we ALSO require an exact byte-equality against `probeBody`.
        // A full-range GET (`buildDownloadRequest`, NOT the ranged
        // `buildProbeRequest`) is used so the whole 13-byte body comes back to
        // compare; the blessed transports (Tailscale Serve/Funnel, Cloudflare
        // Tunnel, rclone) pass a raw file GET through unchanged, so exact
        // equality holds for real WebDAV and only the impostor endpoint fails.
        //
        // The FAILURE we attribute matters as much as the pass. A wrong-bytes
        // read is not "your server errored" — the server's own logs show a clean
        // 200. It means the URL is answering with something that isn't our file
        // (a login page, an SSO wall, a dashboard), so it gets its own code
        // (`.fileTransferNotAFileServer`, 61) that says exactly that. A 404 on
        // the key we just PUT a 2xx for is the same class: the endpoint took the
        // write and doesn't serve it back. Only a real 5xx is a server error.
        let readRequest = buildDownloadRequest(snapshot: snapshot, storedKey: probeKey)
        var readOK = false
        var readFailure: AppError = .fileTransferNotAFileServer
        do {
            let (data, response) = try await session.data(for: readRequest)
            if let http = response as? HTTPURLResponse {
                switch parseProbeOutcome(status: http.statusCode) {
                case .exists:
                    // Byte-echo: the returned body must be EXACTLY what we PUT.
                    readOK = (data == probeBody)
                case .unauthorized:
                    // Write passed the gate but the read didn't — a half-open
                    // auth config, not an impostor endpoint.
                    readFailure = .fileTransferAuthFailed
                case .serverError:
                    readFailure = .fileTransferServerError
                case .missing, .certRefused, .unknown:
                    // Stays `.fileTransferNotAFileServer`. `.certRefused` is
                    // listed for exhaustiveness only — it is a TRANSPORT verdict
                    // and `parseProbeOutcome` reads a status, so a response we
                    // are holding here cannot carry it.
                    break
                }
            } else {
                readFailure = .fileTransferUnreachable
            }
        } catch {
            // The PUT reached the host, so a transport failure on the very next
            // GET is ordinarily a connectivity fault rather than a config one —
            // but a CERTIFICATE refusal is neither, and hardcoding unreachable
            // here threw it away. The PUT and the GET are separate attempts (the
            // pool can drop and re-establish the connection between them, and a
            // re-handshake raises its own challenge), so the read is entitled to
            // its own verdict. `mapTransportError` still answers unreachable for
            // everything that carries no certificate verdict, which is what keeps
            // the connectivity reading for the case this comment described.
            readFailure = mapTransportError(error, signals: signals())
        }

        // --- Stage 5: delete (best-effort cleanup) — never affects the verdict ---
        await bestEffortDelete(snapshot: snapshot, storedKey: probeKey, session: session)

        guard readOK else {
            return FileTransferTestResult(reachedStage: .read, success: false, failure: readFailure)
        }

        // --- NESTED write-probe (capability detection, NOT a user-facing stage) ---
        // The flat reachability/auth/write/read sequence has passed. Now probe
        // whether the gateway accepts the client's nested upload sequence —
        // MKCOL the folder, then PUT into it. WebDAV servers don't auto-create
        // a missing parent on PUT (rclone 409s it — RFC 4918 §9.7), and some
        // (an S3-DAV bridge, a locked-down nginx-DAV) reject the nested PUT
        // even after MKCOL. The result decides whether the client mints
        // per-conversation `<convID>/…` keys or falls back to flat ones. This
        // probe failing does NOT fail the connection test (flat keys work fine) —
        // it only narrows `folderCapable` to false.
        //
        // WITH ONE EXCEPTION, and it is the reason this switch is not a `==
        // .capable`. A CERTIFICATE refusal here is not a capability answer at
        // all: it says the connection was refused, and absorbing it into
        // `folderCapable = false` reported a trust refusal as a green connection
        // test with a narrowed feature — the failure mode that looks like
        // success. It fails the test, with the certificate's own error.
        let folderCapable: Bool
        switch await probeFolderCapability(snapshot: snapshot, session: session, signals: signals) {
        case .capable:
            folderCapable = true
        case .rejected, .indeterminate:
            // The staged test runs interactively against a server the flat stages
            // just passed, so "indeterminate" here is a narrowing like any other —
            // and the silent launch-time re-probe un-sticks a false verdict at the
            // next probe-algorithm revision anyway.
            folderCapable = false
        case .certificateRefused(let refusal):
            // Reported at `.reachability`, not at `.read`: a certificate refusal
            // is a TLS-layer verdict about the CONNECTION, and it is where every
            // other certificate refusal in this lane lands, so the user gets one
            // story about certificates wherever in the sequence one is observed.
            // Marking `.read` failed would put a red X on a stage that visibly
            // succeeded.
            //
            // `folderCapable` keeps its init DEFAULT (true), like every other
            // failure path here: the flag is a narrowing that only a DEFINITIVE
            // nested-PUT rejection may flip, a refused connection proves nothing
            // about folders, and neither caller persists it unless `success`.
            return FileTransferTestResult(
                reachedStage: .reachability,
                success: false,
                failure: refusal.fileTransferError
            )
        }

        // Full pass (connectivity). `folderCapable` rides alongside the verdict.
        return FileTransferTestResult(
            reachedStage: .read,
            success: true,
            failure: nil,
            folderCapable: folderCapable
        )
    }

    /// Outcome of the folder-capability probe. `rejected` is the ONLY value that
    /// means "the server answered and refuses nested writes"; `indeterminate`
    /// (transport error, ambient MKCOL failure, ambiguous status) must never be
    /// persisted as a capability verdict — the silent re-probe retries it later,
    /// and recording it would park a healthy server in flat mode until the next
    /// probe-revision bump.
    ///
    /// `certificateRefused` is a CASE rather than a flavour of `indeterminate`
    /// because the two demand opposite handling and Swift has to ask each caller
    /// which it means. `indeterminate` says "try again later"; this says "the
    /// connection itself was refused, and no later probe will do better until
    /// something outside the app changes". Folding it into `indeterminate` is
    /// exactly how a trust refusal disappeared into `folderCapable = false` while
    /// the connection test still reported success.
    enum FolderProbeOutcome: Equatable {
        case capable
        case rejected
        case indeterminate
        case certificateRefused(CertificateRefusal)
    }

    /// Which of the three CERTIFICATE refusals a probe hit. Deliberately narrower
    /// than `RemoteAgentTrustEvaluator.TransportErrorClass`: an outcome that
    /// carried the full class could name a timeout as a certificate refusal, and
    /// the whole point of the case that holds this is that a trust refusal is
    /// neither a capability verdict nor a reachability verdict.
    enum CertificateRefusal: Equatable, Sendable {
        /// This device does not trust the presented chain.
        case untrusted
        /// The chain IS system-trusted and the configured pin disagreed with its
        /// key — the one shape that means the connection may be intercepted.
        case mismatch
        /// The chain IS system-trusted and no digest could be computed for its
        /// key algorithm, so the pin was never compared.
        case keyUnpinnable

        /// `nil` for every non-certificate class, so a refusal can never be
        /// constructed out of a timeout, a cold tunnel, or a cancel. This
        /// exhaustive switch is the single place the split is decided; adding a
        /// transport class breaks it here rather than silently at a call site.
        init?(_ transportClass: RemoteAgentTrustEvaluator.TransportErrorClass) {
            switch transportClass {
            case .untrustedCert: self = .untrusted
            case .certMismatch: self = .mismatch
            case .certKeyUnpinnable: self = .keyUnpinnable
            case .timeout, .unreachable, .cancelled: return nil
            }
        }

        /// The file-lane taxonomy code for this refusal. Each is its own code, and
        /// none of them is `.fileTransferUnreachable`: the host answered the
        /// handshake, so "check your file-server is running" sends the user
        /// hunting a problem that is not there.
        var fileTransferError: AppError {
            switch self {
            case .untrusted:
                // This device refused the certificate. The remedy is on the
                // server, and it is the shared one every lane shows, so the file
                // lane never invents a second story.
                return .fileTransferCertUntrusted
            case .mismatch:
                return .fileTransferCertMismatch
            case .keyUnpinnable:
                // System trust PASSED, so nothing disagreed — the pin simply
                // could not be computed for this key algorithm. Its own code so
                // the file lane states that, rather than borrowing the mismatch
                // warning.
                return .fileTransferCertKeyUnpinnable
            }
        }
    }

    /// The certificate refusal behind a transport failure, or `nil` when the
    /// failure was not a certificate verdict at all (a non-`URLError`, a timeout,
    /// a cold tunnel, a cancel). ONE place every probe in this file asks the
    /// shared classifier, so no catch block can answer the question its own way.
    private static func certificateRefusal(
        _ error: Error,
        signals: RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) -> CertificateRefusal? {
        guard let urlError = error as? URLError else { return nil }
        return CertificateRefusal(
            RemoteAgentTrustEvaluator.classifyTransportError(urlError.code, signals: signals)
        )
    }

    /// Probe whether `snapshot`'s file-server accepts the client's nested
    /// upload sequence: `MKCOL __conduck_probe__` (status INSPECTED), then
    /// `PUT __conduck_probe__/<uuid>.txt`, `GET` byte-echo, best-effort
    /// `DELETE`. Callers: the staged Test Connection (which fails the whole test
    /// on `.certificateRefused` and collapses everything else to a Bool) and the
    /// silent launch-time capability refresh (upgrade-only — writes
    /// `folderCapable=true` on `.capable`, records a definitive revision on
    /// `.rejected`, does nothing on `.indeterminate` or a refusal).
    ///
    /// Classification:
    /// - PUT 2xx + GET echoes the written bytes → `.capable`.
    /// - PUT 2xx + GET serves something else / 404 → `.rejected` (a
    ///   uniform-200 wall or a server that acks writes it doesn't store —
    ///   nested uploads would not actually land).
    /// - PUT 403/405/409 AFTER a conclusive MKCOL (2xx created / 405
    ///   already-exists) → `.rejected` — the server saw the collection exist
    ///   and still refused the nested write (S3-DAV bridge, locked-down
    ///   nginx-DAV).
    /// - PUT 403/405/409 after an INCONCLUSIVE MKCOL (transport error, 5xx,
    ///   auth failure) → `.indeterminate` — the 409 is explained by the
    ///   missing parent, not by a folder-rejecting server.
    /// - PUT/GET transport failure carrying a CERTIFICATE verdict →
    ///   `.certificateRefused`. Never `.indeterminate`: the connection was
    ///   refused, so this probe learned nothing about folders AND no later probe
    ///   will, which is a different instruction from "try again".
    /// - Any other PUT status, any other PUT/GET transport error →
    ///   `.indeterminate`.
    ///
    /// When `session` is nil, builds the 15 s ephemeral cert-pinned session
    /// (same posture as `runConnectionTest`) and reads ITS evaluator. A caller
    /// supplying a `session` must supply `signals` too — the probe cannot read an
    /// evaluator it did not build, and without a verdict source a certificate
    /// refusal on that session is indistinguishable from a dead host. Tests inject
    /// a `MockURLProtocol`-backed session and state the verdicts they are testing.
    ///
    /// The probe DIR is a fixed throwaway namespace (`__conduck_probe__`) distinct
    /// from any conversation folder; the file carries a per-run uuid so concurrent
    /// probes never collide. The DELETE is best-effort and never affects the
    /// outcome.
    static func probeFolderCapability(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession? = nil,
        signals: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)? = nil
    ) async -> FolderProbeOutcome {
        let probeSession: URLSession
        let ownsSession: Bool
        let attemptSignals: @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
        if let session {
            probeSession = session
            ownsSession = false
            attemptSignals = Self.probeSignals(override: signals, evaluator: nil)
        } else {
            let built = makeProbeSession(pinnedFingerprintHex: snapshot.certFingerprintHex)
            probeSession = built.session
            ownsSession = true
            attemptSignals = Self.probeSignals(override: signals, evaluator: built.evaluator)
        }
        defer { if ownsSession { probeSession.invalidateAndCancel() } }

        let probeTag = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        // Nested path: a real `/` separator. `buildUploadRequest` resolves it via
        // `URL.appending(path:)`, which keeps the slash unescaped as a path
        // separator (the whole point of the probe).
        let nestedKey = "__conduck_probe__/\(probeTag).txt"
        let body = Data("conduck-nested-probe".utf8)

        // Create the collection first — the client's real upload sequence is
        // MKCOL-then-PUT (WebDAV won't auto-create the parent; rclone 409s a
        // nested PUT into a missing folder). Conclusive = the server answered
        // that the collection now exists: 2xx (created; rclone re-answers 201
        // on repeat) or 405 (RFC 4918 "already exists").
        let mkcolStatus = await performMkcol(
            snapshot: snapshot, collectionKey: "__conduck_probe__", session: probeSession)
        let mkcolConclusive = mkcolStatus.map { (200...299).contains($0) || $0 == 405 } ?? false

        // PUT the nested file. Body via `from:` only (no `httpBody` — see the
        // flat-write path: it makes URLSession warn about a body on an upload task).
        let putRequest = buildUploadRequest(snapshot: snapshot, storedKey: nestedKey, contentLength: body.count)
        let putStatus: Int
        do {
            let (_, response) = try await probeSession.upload(for: putRequest, from: body)
            guard let http = response as? HTTPURLResponse else { return .indeterminate }
            putStatus = http.statusCode
        } catch {
            if let refusal = certificateRefusal(error, signals: attemptSignals()) {
                return .certificateRefused(refusal)
            }
            return .indeterminate
        }

        guard (200...299).contains(putStatus) else {
            // Best-effort clean up any partial before classifying.
            await bestEffortDelete(snapshot: snapshot, storedKey: nestedKey, session: probeSession)
            switch putStatus {
            case 403, 405, 409:
                // Definitive folder-rejection ONLY when the parent provably
                // existed; otherwise the status is explained by the missing
                // parent (ambient MKCOL failure) and proves nothing.
                return mkcolConclusive ? .rejected : .indeterminate
            default:
                return .indeterminate
            }
        }

        // GET it back — confirm the nested write actually landed + is served.
        // Same byte-echo as the flat read stage: a uniform-200 auth-wall would
        // 200 the GET with its own HTML, so require the returned body to EQUAL
        // the nested payload we PUT before crediting folder-capability. Full-range
        // GET so the whole body comes back to compare. Transport error →
        // indeterminate (the write may well have landed) UNLESS it carries a
        // certificate verdict, which is about the connection and not about the
        // write; a served-but-wrong body or 404 → rejected (acked writes that
        // don't land are not a lane).
        let getRequest = buildDownloadRequest(snapshot: snapshot, storedKey: nestedKey)
        let outcome: FolderProbeOutcome
        do {
            let (data, response) = try await probeSession.data(for: getRequest)
            if let http = response as? HTTPURLResponse, parseProbeOutcome(status: http.statusCode) == .exists {
                outcome = (data == body) ? .capable : .rejected
            } else {
                outcome = .rejected
            }
        } catch {
            outcome = certificateRefusal(error, signals: attemptSignals())
                .map(FolderProbeOutcome.certificateRefused) ?? .indeterminate
        }

        // Best-effort cleanup (never affects the verdict).
        await bestEffortDelete(snapshot: snapshot, storedKey: nestedKey, session: probeSession)
        return outcome
    }

    /// Best-effort DELETE of the staged-test probe file. Swallows every outcome
    /// (success, non-2xx, transport error) — an orphaned probe file is harmless
    /// and must never turn a passing test into a failure.
    private static func bestEffortDelete(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String,
        session: URLSession
    ) async {
        let request = buildDeleteRequest(snapshot: snapshot, storedKey: storedKey)
        _ = try? await session.data(for: request)
    }

    /// Map a transport failure to the file-transfer taxonomy via the shared
    /// `RemoteAgentTrustEvaluator.classifyTransportError` classifier (single
    /// source of truth). The trust verdicts are threaded through from the probe's
    /// own evaluator rather than hardcoded — a hardcoded `false` made a genuine
    /// certificate rejection indistinguishable from a cold tunnel. Everything
    /// that is NOT a certificate refusal collapses to unreachable, which keeps a
    /// transient `.secureConnectionFailed` (cold tunnel, no verdict set) and a
    /// connect-timeout reading as reachability rather than as a cert failure.
    /// Never names the credential.
    private static func mapTransportError(
        _ error: Error,
        signals: RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) -> AppError {
        certificateRefusal(error, signals: signals)?.fileTransferError ?? .fileTransferUnreachable
    }
}

// MARK: - PROPFIND parser delegate

/// Streaming `XMLParser` delegate that collects `FileServerEntry` rows from a
/// WebDAV 207 multistatus body. Namespace-agnostic (matches LOCAL element names
/// so it works for `D:`, `d:`, or unprefixed `DAV:` documents). Strictly
/// tolerant — it accumulates whatever it can and never reports failure upward;
/// `FileServerClient.parsePropfindBody` ignores the parser's return value.
private final class PropfindParserDelegate: NSObject, XMLParserDelegate {
    /// Completed entries (one per `<response>` that carried an `<href>`).
    private(set) var entries: [FileServerEntry] = []

    // Per-`<response>` accumulators, reset on each `<response>` open.
    private var inResponse = false
    private var currentHref = ""
    private var currentLength = 0
    private var currentIsDirectory = false

    // Element-text capture state.
    private var capturingChars = false
    private var charBuffer = ""

    // Resource-type scoping — a `<collection/>` only counts inside
    // `<resourcetype>` (avoids a stray element name colliding).
    private var inResourceType = false

    /// Lowercased local name, stripping any `prefix:` so `D:href` / `d:href` /
    /// `href` all match `"href"`.
    private func localName(_ elementName: String) -> String {
        if let colon = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...]).lowercased()
        }
        return elementName.lowercased()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch localName(elementName) {
        case "response":
            inResponse = true
            currentHref = ""
            currentLength = 0
            currentIsDirectory = false
        case "resourcetype":
            inResourceType = true
        case "collection":
            if inResourceType { currentIsDirectory = true }
        case "href", "getcontentlength":
            capturingChars = true
            charBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingChars { charBuffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localName(elementName)
        switch local {
        case "href":
            currentHref = charBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            capturingChars = false
        case "getcontentlength":
            currentLength = Int(charBuffer.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            capturingChars = false
        case "resourcetype":
            inResourceType = false
        case "response":
            // Emit only when the response carried an href; derive the entry name
            // from the href's last non-empty path component (handles a trailing
            // slash on directory hrefs). Percent-decode for display fidelity.
            if !currentHref.isEmpty {
                let trimmed = currentHref.hasSuffix("/") ? String(currentHref.dropLast()) : currentHref
                let lastComponent = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
                let name = lastComponent.removingPercentEncoding ?? lastComponent
                if !name.isEmpty {
                    entries.append(FileServerEntry(
                        name: name,
                        isDirectory: currentIsDirectory,
                        byteSize: currentLength
                    ))
                }
            }
            inResponse = false
        default:
            break
        }
    }
}

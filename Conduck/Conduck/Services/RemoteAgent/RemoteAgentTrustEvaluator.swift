// Conduck
// RemoteAgentTrustEvaluator.swift
//
// Network foundation. URLSessionDelegate that implements optional
// SHA-256 public-key fingerprint pinning for the Personal AI gateway
// (`spec.md "Remote Agent Round-Trip"`). When the user has configured a
// "Custom certificate fingerprint" in Settings, this evaluator:
//
//   1. Extracts the leaf cert from `challenge.protectionSpace.serverTrust`.
//   2. Pulls the public key (`SecCertificateCopyKey`) and its DER
//      external representation (`SecKeyCopyExternalRepresentation`).
//   3. Hashes the DER with SHA-256.
//   4. Compares the lowercase-hex digest against the user-saved
//      fingerprint. Match → accept; mismatch → cancel challenge
//      (URLSession surfaces this as a transport error that
//      `RemoteAgentClient` maps to `.remoteAgentCertMismatch`).
//
// It is also the app's REDIRECT policy: a cross-ORIGIN 3xx is refused
// (`willPerformHTTPRedirection`), so no endpoint can re-point a request's body
// + `Authorization` header at a host the user never configured. Every session
// that installs this evaluator inherits both policies at once.
//
// When no fingerprint is configured (`pinnedFingerprintHex == nil`), the
// evaluator falls through to `.performDefaultHandling` and the system's
// standard ATS chain validation applies. This is the recommended setup
// for users on Tailscale Funnel / Cloudflare Tunnel / Let's Encrypt
// (publicly-trusted cert; no pinning UX required).
//
// `SecTrust` is opaque in unit tests (no public constructor for arbitrary
// cert chains), so unit tests cover only the pure `sha256Hex(publicKeyDER:)`
// helper — the integration delegate path is exercised by the
// "Test Connection" path against a real Caddy/nginx instance.
//
// `nonisolated final class … @unchecked Sendable` matches the
// `BackgroundSTT` delegate shape (`STTClient+Background.swift:34`).
// URLSession holds the delegate as a reference and dispatches callbacks
// from its own queue; Swift 6 default isolation in this module would
// otherwise infect the delegate signature.

import Foundation
import CryptoKit

/// URLSessionDelegate implementing optional SHA-256 public-key pinning for
/// the Personal AI gateway. Pass `pinnedFingerprintHex: nil` to fall
/// through to default ATS validation.
///
/// Also carries the app's redirect policy (`URLSessionTaskDelegate`, below):
/// a cross-ORIGIN 3xx is REFUSED so a compromised endpoint cannot re-point a
/// request — with its body, its bearer header, and the user's pin scope — at
/// a host the user never configured.
final class RemoteAgentTrustEvaluator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// Expected SHA-256 (lowercase hex, no separators) of the leaf cert's
    /// public-key DER. `nil` disables pinning → default ATS validation.
    let pinnedFingerprintHex: String?

    /// SPKI SHA-256 (lowercase hex) of the leaf cert the gateway most
    /// recently *presented* during a server-trust challenge — captured on
    /// EVERY server-trust challenge (including the no-pin default-handling
    /// path), so the "Test Connection" caller can surface it for one-tap
    /// TOFU "Trust & Save" when the system rejects an untrusted self-signed
    /// cert. `nil` until the first server-trust challenge fires (or when the
    /// leaf's key algorithm is outside the V1 SPKI prefix table).
    ///
    /// Thread-safety: written on URLSession's delegate queue during the
    /// server-trust challenge (which fires while `session.data(for:)` is in
    /// flight) and read by the Test Connection caller after that awaited call
    /// returns. `fingerprintLock` (`NSLock`) is the actual cross-thread
    /// guarantee — it makes the read safe regardless of delegate-queue vs.
    /// await ordering, including any late callback.
    private(set) var presentedFingerprintHex: String? {
        get { fingerprintLock.withLock { _presentedFingerprintHex } }
        set { fingerprintLock.withLock { _presentedFingerprintHex = newValue } }
    }
    private var _presentedFingerprintHex: String?
    private let fingerprintLock = NSLock()

    /// `true` once the NO-PIN system-trust evaluation actually REJECTED the
    /// presented cert (an explicit `SecTrustEvaluateWithError` on the
    /// default-handling path failed). Stays `false` when the server-trust
    /// challenge never fires (a transient handshake failure before any cert is
    /// received) — which is exactly how a transient `.secureConnectionFailed`
    /// is told apart from a genuine untrusted-cert rejection. Read by the probe
    /// caller AFTER the awaited request returns. Lock-guarded (same `fingerprintLock`).
    private(set) var systemTrustRejected: Bool {
        get { fingerprintLock.withLock { _systemTrustRejected } }
        set { fingerprintLock.withLock { _systemTrustRejected = newValue } }
    }
    private var _systemTrustRejected = false

    /// `true` once the evaluator ACTIVELY cancelled a server-trust challenge
    /// because a configured pin did not match (or the pinned cert's key
    /// algorithm is unpinnable). Distinguishes a real pin mismatch from a
    /// benign task cancellation / transient handshake failure that URLSession
    /// also surfaces as `.cancelled` / `.secureConnectionFailed`. Lock-guarded.
    private(set) var pinRejected: Bool {
        get { fingerprintLock.withLock { _pinRejected } }
        set { fingerprintLock.withLock { _pinRejected = newValue } }
    }
    private var _pinRejected = false

    init(pinnedFingerprintHex: String? = nil) {
        self.pinnedFingerprintHex = pinnedFingerprintHex
        super.init()
    }

    // MARK: - Per-ref pin resolution (durable, live)

    /// The pinned SPKI SHA-256 (lowercase hex) stored for `ref`, read LIVE from
    /// App-Group `UserDefaults`. `nil` when unset or empty → default ATS.
    ///
    /// Defaults-only by design (no iCloud-KVS fallback, unlike
    /// `getRemoteAgentURL(for:)`): a cert pin is a per-DEVICE TOFU artefact and
    /// is never synced. Nonisolated synchronous read, so it is safe both inside
    /// a trust delegate (no MainActor hop into `SettingsManager`) and on the
    /// foreground send path — and reading it at challenge/dispatch time rather
    /// than caching it means a re-pin between compose and send is honored, and a
    /// cross-launch background resume re-reads the durable value.
    static func storedConversePin(for ref: RemoteAgentRef) -> String? {
        let defaults = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
        guard let pin = defaults.string(forKey: Constants.remoteAgentCertFingerprintKey(for: ref)),
              !pin.isEmpty
        else { return nil }
        return pin
    }

    /// Resolve the pinned SHA-256 fingerprint to apply to a converse
    /// background-upload task's server-trust `challenge`, given the task's
    /// recovered `metadata`. Returns nil (→ caller should `performDefaultHandling`,
    /// i.e. default ATS) unless all hold:
    ///   1. the challenge is a server-trust challenge (client-cert/HTTP-auth → nil);
    ///   2. the metadata carries a `refRawValue` that parses to a `RemoteAgentRef`;
    ///   3. that ref has a non-empty per-ref pin (`storedConversePin(for:)`).
    /// Shared by `BackgroundRemoteAgent` + `CarPlayConverseUploader` so both
    /// converse delegates pin identically; mirrors the per-ref resolution
    /// `STTClient+Background` does for the custom STT endpoint.
    ///
    /// HOST-BLIND, deliberately (load-bearing): the resolved pin applies to EVERY
    /// server-trust challenge this task raises, including one raised by a redirect
    /// target. A background `URLSession` always follows redirects and never
    /// delivers `willPerformHTTPRedirection` (SDK contract), so the trust callback
    /// is the only place a background converse task can push back on a cross-host
    /// hop at all. Host-SCOPING the pin here instead returned nil for the redirect
    /// host and degraded that hop to default ATS — i.e. the user's pin stopped
    /// applying exactly when it mattered, letting a compromised gateway replay the
    /// request body (full conversation history + images + bearer header) to any
    /// host holding an ordinary publicly-trusted cert. Host-blind, that redirect
    /// target must present the PINNED KEY or the evaluator cancels. Matches the
    /// interactive lanes (Test Connection, custom STT/TTS, file-server probes),
    /// which have always applied their pin host-blind.
    ///
    /// HONEST LIMIT — this is a mitigation, not a redirect veto. A pin compare
    /// proves "same key", not "same origin": a wildcard / multi-SAN cert, or the
    /// same private key deployed behind several proxy names, satisfies the pin at a
    /// different host, and URLSession may reuse a connection or a trust decision
    /// without emitting a fresh challenge at all. The complete answer is the
    /// `willPerformHTTPRedirection` refusal below, which background sessions
    /// cannot receive. Treat "point Conduck at the TERMINAL gateway URL, not one
    /// that redirects" as the actual contract; Test Connection surfaces a
    /// redirecting endpoint rather than silently following it.
    static func converseTaskPin(
        for challenge: URLAuthenticationChallenge,
        metadata: RemoteAgentBackgroundMetadata?
    ) -> String? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let refRaw = metadata?.refRawValue,
              let ref = RemoteAgentRef(rawString: refRaw)
        else { return nil }

        return storedConversePin(for: ref)
    }

    // MARK: - Pure helpers (independently unit-testable)

    /// SHA-256 hash of arbitrary DER bytes, formatted as lowercase hex with
    /// no separators (`"deadbeef…"`). Plain pass-through over the data —
    /// callers are responsible for passing the *correct* DER bytes to
    /// hash. For the SubjectPublicKeyInfo (SPKI) digest expected by the
    /// industry-standard `openssl x509 -pubkey | shasum -a 256` workflow,
    /// see `spkiDER(from:)`.
    static func sha256Hex(publicKeyDER: Data) -> String {
        let digest = SHA256.hash(data: publicKeyDER)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// ASN.1 SubjectPublicKeyInfo prefixes for common key algorithms.
    /// `SecKeyCopyExternalRepresentation` on Apple platforms returns the
    /// raw key body (`PKCS#1 RSAPublicKey` for RSA, X9.63 uncompressed
    /// point for EC) — NOT the SPKI envelope. To match the SPKI digest
    /// that `openssl x509 -pubkey ...` produces (the pin format users
    /// will compute against their gateway), prepend the appropriate
    /// algorithm prefix before hashing.
    ///
    /// References: RFC 5280 §4.1.2.7, RFC 8017, RFC 5480.
    /// Generated via `openssl asn1parse` on known-good SPKI samples.
    private enum SPKIPrefix {
        // RSA SPKI envelope: SEQUENCE { SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }, BIT STRING 00 <PKCS#1> }
        // Length bytes inside the prefix depend on the modulus size, so
        // each RSA key length needs its own prefix.
        static let rsa2048: [UInt8] = [
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86,
            0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03,
            0x82, 0x01, 0x0f, 0x00,
        ]
        static let rsa3072: [UInt8] = [
            0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86,
            0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03,
            0x82, 0x01, 0x8f, 0x00,
        ]
        static let rsa4096: [UInt8] = [
            0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86,
            0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03,
            0x82, 0x02, 0x0f, 0x00,
        ]
        // EC P-256: SEQUENCE { SEQUENCE { OID 1.2.840.10045.2.1 (ecPublicKey), OID 1.2.840.10045.3.1.7 (prime256v1) }, BIT STRING 00 <X9.63> }
        static let ecP256: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce,
            0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
            0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ]
        // EC P-384: SEQUENCE { SEQUENCE { OID ecPublicKey, OID secp384r1 (1.3.132.0.34) }, BIT STRING 00 <X9.63> }
        static let ecP384: [UInt8] = [
            0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce,
            0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22,
            0x03, 0x62, 0x00,
        ]
    }

    /// Wrap the raw key body from `SecKeyCopyExternalRepresentation` in
    /// the appropriate ASN.1 SPKI envelope so the SHA-256 digest matches
    /// the value produced by `openssl x509 -pubkey -in cert.pem | openssl
    /// pkey -pubin -outform DER | shasum -a 256` (the canonical recipe
    /// users will follow to compute their gateway's pin).
    ///
    /// Returns `nil` for key types Conduck does not have a prefix for.
    /// V1 covers RSA-2048/3072/4096 + EC P-256/P-384 — the algorithms
    /// every modern reverse-proxy (Caddy / Nginx / Cloudflare Tunnel /
    /// Tailscale Funnel) issues by default.
    static func spkiDER(from publicKey: SecKey) -> Data? {
        guard
            let rawBody = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
            let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
            let keyType = attributes[kSecAttrKeyType as String] as? String,
            let keySizeNumber = attributes[kSecAttrKeySizeInBits as String] as? NSNumber
        else {
            return nil
        }

        let keySize = keySizeNumber.intValue
        let rsaType = kSecAttrKeyTypeRSA as String
        let ecType = kSecAttrKeyTypeECSECPrimeRandom as String
        let prefix: [UInt8]?
        if keyType == rsaType {
            switch keySize {
            case 2048: prefix = SPKIPrefix.rsa2048
            case 3072: prefix = SPKIPrefix.rsa3072
            case 4096: prefix = SPKIPrefix.rsa4096
            default: prefix = nil
            }
        } else if keyType == ecType {
            switch keySize {
            case 256: prefix = SPKIPrefix.ecP256
            case 384: prefix = SPKIPrefix.ecP384
            default: prefix = nil
            }
        } else {
            prefix = nil
        }

        guard let prefix else { return nil }
        var spki = Data(prefix)
        spki.append(rawBody)
        return spki
    }

    /// Extract the leaf certificate from a `SecTrust`, compute its SPKI
    /// SHA-256 digest, and return it as lowercase hex. Returns `nil` when
    /// the chain is empty, the public key can't be copied, or the key
    /// algorithm is outside the V1 SPKI prefix table (e.g. Ed25519).
    ///
    /// Shared by the pin-compare path and the TOFU capture path so both
    /// compute an identical digest from an identical leaf.
    static func computeLeafSPKIHex(from serverTrust: SecTrust) -> String? {
        // Extract the leaf cert (index 0 in the chain). `SecTrustGetCertificateAtIndex`
        // is deprecated in favour of `SecTrustCopyCertificateChain` on
        // newer SDKs; since Conduck deploys iOS 26.5+ / macOS 26.5+
        // unconditionally, use the chain-array API.
        guard
            let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
            let leaf = chain.first,
            let publicKey = SecCertificateCopyKey(leaf),
            let spki = spkiDER(from: publicKey)
        else {
            return nil
        }
        return sha256Hex(publicKeyDER: spki)
    }

    // MARK: - Transport-error classification (single source of truth)

    /// Neutral classification of a transport `URLError`, shared by EVERY
    /// gateway probe (gateway Test Connection, STT suite, file-lane staged
    /// test). Each caller maps the result onto its own outcome type. This one
    /// pure function is the single source of truth that kills the copy-paste
    /// drift which let `URLError.secureConnectionFailed` — a GENERIC SSL
    /// handshake failure (`-1200`), distinct from the certificate-specific
    /// codes `-1201…-1204` — get mislabeled as a certificate-trust failure.
    /// (Observed: a cold Tailscale tunnel produced `.secureConnectionFailed`
    /// on a perfectly-trusted Let's Encrypt cert → false "Untrusted certificate".)
    ///
    /// The two trust SIGNALS disambiguate the generic `.secureConnectionFailed`
    /// / `.cancelled` codes (which fire for BOTH real cert rejections and
    /// transient handshake hiccups). Read them from the evaluator instance
    /// AFTER the awaited request returns:
    ///   - `systemTrustRejected` — the no-pin system trust eval actually failed.
    ///   - `pinRejected`         — the evaluator actively cancelled a pin mismatch.
    /// With neither set, a generic TLS failure is transient → `.unreachable`.
    enum TransportErrorClass: Equatable, Sendable {
        case timeout
        case unreachable
        case untrustedCert
        case certMismatch
        case cancelled
    }

    static func classifyTransportError(
        _ code: URLError.Code,
        hasPin: Bool,
        systemTrustRejected: Bool,
        pinRejected: Bool
    ) -> TransportErrorClass {
        switch code {
        case .timedOut:
            return .timeout
        case .cannotConnectToHost,
             .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return .unreachable
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            // Unambiguous certificate-trust rejection codes — classify
            // unconditionally (the system named the cert as the cause).
            return hasPin ? .certMismatch : .untrustedCert
        case .secureConnectionFailed:
            // GENERIC SSL failure: a cert rejection OR a transient handshake
            // hiccup. Treat it as a cert problem ONLY when the trust layer
            // actually rejected; otherwise it is transient → retryable.
            if hasPin { return pinRejected ? .certMismatch : .unreachable }
            return systemTrustRejected ? .untrustedCert : .unreachable
        case .cancelled:
            // The evaluator cancels ONLY on a pinned-cert mismatch. Any other
            // `.cancelled` is a real task cancellation (user abort / teardown).
            if hasPin && pinRejected { return .certMismatch }
            return .cancelled
        default:
            return .unreachable
        }
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only server-trust challenges go through the pinning path. Client-
        // cert / NTLM / HTTP-auth challenges hit default handling — we
        // don't want a pinned-fingerprint user to accidentally block a
        // bearer-token 401 retry, for example.
        //
        // A PROXY server-trust challenge is likewise default-handled: the pin is
        // a statement about the GATEWAY's public key, not about an HTTPS forward
        // proxy the OS/MDM configured on this network. Comparing the gateway pin
        // against the proxy's own cert would refuse the CONNECT hop and lock a
        // proxied user out entirely, and it buys nothing — the tunnelled
        // end-to-end TLS session to the gateway raises its OWN challenge (with
        // `isProxy == false`), which IS pinned. A transparent MITM with no
        // CONNECT also reports `isProxy == false`, so it stays pinned/refused.
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            !challenge.protectionSpace.isProxy(),
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Capture the presented leaf's SPKI digest on EVERY server-trust
        // challenge — BEFORE the no-pin early-return — so the "Test
        // Connection" caller can offer one-tap TOFU "Trust & Save" when the
        // system later rejects an untrusted self-signed cert. `nil` here
        // (extraction failed / unsupported key algorithm) just means the
        // caller surfaces "untrusted cert" without a copyable fingerprint.
        let presentedDigest = Self.computeLeafSPKIHex(from: serverTrust)
        presentedFingerprintHex = presentedDigest

        // No pin configured → default ATS chain validation. This is the
        // expected path for users on Tailscale Funnel / Cloudflare Tunnel
        // / Let's Encrypt (publicly-trusted cert).
        guard let expectedHex = pinnedFingerprintHex, !expectedHex.isEmpty else {
            // Record whether system trust did NOT pass (read-only —
            // `.performDefaultHandling` below stays authoritative). Note:
            // `SecTrustEvaluateWithError` returns false for BOTH "untrusted"
            // AND "evaluation could not complete", so this is "system trust did
            // not pass", not strictly "malicious cert" — which is the right
            // signal here: either way we tell a genuine non-passing cert
            // (→ TOFU) from a transient handshake failure that never reached a
            // cert challenge (→ retryable) when URLSession later surfaces the
            // generic `.secureConnectionFailed`.
            if !SecTrustEvaluateWithError(serverTrust, nil) {
                systemTrustRejected = true
            }
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let actualHex = presentedDigest else {
            // Could not extract SPKI — refuse the challenge. Letting it
            // fall through to default handling could accept a chain the
            // user explicitly pinned against, which is worse than the
            // user-visible cert-mismatch banner. Unsupported key algorithms
            // (e.g. Ed25519 — not in V1 prefix table) end up here, which
            // is correct: pinning with an unknown algorithm = cancel.
            pinRejected = true
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Lowercase compare — pinned value is stored lowercase by the
        // Settings save path. Defensive lowercase here lets a user
        // hand-paste an uppercase fingerprint without surprise mismatch.
        if actualHex.lowercased() == expectedHex.lowercased() {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // URLSession surfaces this to the data-task as
            // NSURLErrorServerCertificateUntrusted (or similar) or `.cancelled`;
            // `pinRejected` lets the caller map it to `.remoteAgentCertMismatch`
            // (a genuine mismatch) and NOT confuse it with a transient
            // handshake failure or a benign task cancellation.
            pinRejected = true
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: - URLSessionTaskDelegate (redirect policy)

    /// Refuse a redirect that leaves the ORIGIN the request was sent to; follow a
    /// same-origin one unchanged.
    ///
    /// WHY: a user-configured endpoint answering `307 Location: https://elsewhere`
    /// otherwise gets URLSession to replay the request — the full client-owned
    /// conversation history, inline images, raw audio, file bytes, and the
    /// preset `Authorization` header — to a host the user never configured, and
    /// with the pin no longer meaningfully in scope (a redirect target holding
    /// an ordinary publicly-trusted cert passes default ATS). Refusing turns
    /// that into a VISIBLE outcome instead: passing `nil` completes the task
    /// with the 3xx response itself, which every caller already classifies
    /// (`FileServerClient.classifyReachability` maps 3xx → `.suspicious`; the
    /// gateway probes fail the body-envelope verdict; `RemoteAgentStatusMap`
    /// turns it into an HTTP error). Matches `conduck-connect --check-server`,
    /// which never follows redirects either.
    ///
    /// Same-ORIGIN redirects stay allowed because they are ordinary and benign —
    /// a reverse proxy canonicalising a path, adding/removing a trailing slash,
    /// or a WebDAV server relocating a collection. Compared on
    /// `(scheme, host, effective port)`, not host alone: `:443` → `:8443` on the
    /// same name is a different service, and https is mandatory app-wide so a
    /// 3xx must never be able to downgrade the hop.
    ///
    /// Scope: every session that installs this evaluator as its delegate
    /// inherits the policy — Test Connection, model discovery, custom STT/TTS,
    /// file-server probes, and the macOS foreground converse session. BACKGROUND
    /// sessions never receive this callback (SDK: "For tasks in background
    /// sessions, redirections will always be followed and this method will not
    /// be called"), which is why the background lanes additionally rely on the
    /// unscoped pin in `converseTaskPin(for:metadata:)`. That mitigation is
    /// weaker than a redirect veto and is documented as such there.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // `response.url` is the URL that ANSWERED with the 3xx — i.e. the origin
        // we were actually talking to on this hop (which, across a redirect
        // chain, is not necessarily the original request's).
        let from = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
        guard let target = request.url,
              let source = from,
              Self.sameOrigin(source, target),
              target.scheme?.lowercased() == "https"
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// Scheme + host + EFFECTIVE port equality (the URL origin), case-folded.
    /// `URL.port` is nil for a default port, so it is resolved against the
    /// scheme — otherwise `https://host` and `https://host:443` read as
    /// different origins and a legitimate canonicalising redirect would be
    /// refused. Only https/http are resolvable here, which is all this app speaks.
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func effectivePort(_ url: URL) -> Int? {
            if let port = url.port { return port }
            switch url.scheme?.lowercased() {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }
        guard let lhsHost = lhs.host(percentEncoded: false)?.lowercased(),
              let rhsHost = rhs.host(percentEncoded: false)?.lowercased(),
              let lhsPort = effectivePort(lhs),
              let rhsPort = effectivePort(rhs)
        else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhsHost == rhsHost
            && lhsPort == rhsPort
    }
}

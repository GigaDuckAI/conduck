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
final class RemoteAgentTrustEvaluator: NSObject, URLSessionDelegate, @unchecked Sendable {

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

    // MARK: - Converse background-task pin resolution

    /// Resolve the pinned SHA-256 fingerprint to apply to a converse
    /// background-upload task's server-trust `challenge`, given the task's
    /// recovered `metadata`. Returns nil (→ caller should `performDefaultHandling`,
    /// i.e. default ATS) UNLESS all hold:
    ///   1. the challenge is a server-trust challenge (client-cert/HTTP-auth → nil);
    ///   2. the metadata carries a `refRawValue` that parses to a `RemoteAgentRef`;
    ///   3. that ref has a non-empty per-ref pin in App-Group UserDefaults; AND
    ///   4. the challenge host matches the ref's configured URL host
    ///      (defensive redirect / cross-host guard).
    /// Shared by `BackgroundRemoteAgent` + `CarPlayConverseUploader` so both
    /// converse delegates pin identically; mirrors the per-ref/host-scoped
    /// resolution `STTClient+Background` does for the custom STT endpoint.
    /// Nonisolated synchronous UserDefaults read — safe in the trust delegate
    /// (no MainActor hop into `SettingsManager`); relaunch-safe + honors a
    /// post-enqueue re-pin because it reads the durable store live.
    ///
    /// INVARIANT (load-bearing): the host-guard reads the ref's URL from
    /// App-Group `defaults` ONLY (no iCloud-KVS fallback, unlike
    /// `getRemoteAgentURL(for:)`). This stays equivalent to the request's
    /// `snapshot.url` host because (a) the per-ref pin is defaults-only (never
    /// KVS-synced), so the host-guard is only reached when the pin — and thus
    /// the co-written defaults URL — is present, and (b) no `.userPinnable`
    /// backend has a fixed (defaults-absent) URL. If a future change syncs the
    /// pin to KVS, or makes a fixed-URL built-in pinnable, this guard would
    /// return nil → default ATS → a self-signed turn would fail; resolve the
    /// URL with the same source the snapshot used if either invariant changes.
    static func converseTaskPin(
        for challenge: URLAuthenticationChallenge,
        metadata: RemoteAgentBackgroundMetadata?
    ) -> String? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let refRaw = metadata?.refRawValue,
              let ref = RemoteAgentRef(rawString: refRaw)
        else { return nil }

        let defaults = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
        guard let pin = defaults.string(forKey: Constants.remoteAgentCertFingerprintKey(for: ref)),
              !pin.isEmpty
        else { return nil }

        // Host-guard: pin ONLY when the challenge host matches this ref's
        // configured URL host. A mismatch (e.g. a redirect to another host) →
        // nil → default ATS rather than pinning the wrong host.
        guard let urlString = defaults.string(forKey: Constants.remoteAgentURLKey(for: ref)),
              let host = URL(string: urlString)?.host(percentEncoded: false),
              challenge.protectionSpace.host == host
        else { return nil }

        return pin
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
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
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
}

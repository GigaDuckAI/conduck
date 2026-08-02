// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentTrustEvaluator.swift
//
// Network foundation. URLSessionDelegate that implements optional
// SHA-256 public-key fingerprint pinning for the Personal AI gateway
// (`spec.md "Remote Agent Round-Trip"`).
//
// THE TRUST RULE, in one line: a pin is an ADDITIONAL restriction on a
// connection the system ALREADY trusts. It can never rescue an untrusted
// chain. So `SecTrustEvaluateWithError` runs on EVERY server-trust challenge,
// pinned or not, and a configured pin over a chain the system rejects is
// answered with `cancelAuthenticationChallenge` — fail closed, in our own
// code, independently of whatever App Transport Security would have done.
//
// THE SIGNAL LIFETIME, in one line: every trust signal belongs to ONE TASK.
// `urlSession(_:didCreateTask:)` opens a window STAMPED with that task's
// identifier, and a challenge writes only into the window stamped for the task
// that raised it, so no EARLIER task's verdict can land in a LATER task's
// window (`AttemptTrustSignals`). That is a property of the type, not a rule
// each new arm of `classifyTransportError` has to remember — and it is the
// WRITE side. The READ (`attemptSignals`) is UNKEYED: it reports whichever
// window was opened last, so it answers the asking caller only while the lanes
// sharing one evaluator stay SEQUENTIAL. That precondition, and what breaks if
// a concurrent request is added to a shared session, is stated on
// `attemptSignals`.
//
// When the user has configured a "Custom certificate fingerprint" in
// Settings, this evaluator:
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
// for users on Tailscale Serve/Funnel / Cloudflare Tunnel / Let's Encrypt
// (publicly-trusted cert; no pinning UX required).
//
// `SecTrust` cannot be pulled out of a synthesised `URLAuthenticationChallenge`
// (no public API sets `protectionSpace.serverTrust`), so the branch order lives
// in the pure `decide(serverTrust:)` below and the delegate method is a thin
// adapter over it. Tests build a real `SecTrust` from a fixture certificate and
// substitute the system-chain verdict through the `#if DEBUG` initializer — no
// live TLS server required, and no shipping build can compile that call.
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
/// through to default ATS validation. A non-nil pin only ever TIGHTENS a chain
/// the system already trusts — see `decide(serverTrust:)` for the branch order.
///
/// Also carries the app's redirect policy (`URLSessionTaskDelegate`, below):
/// a cross-ORIGIN 3xx is REFUSED so a compromised endpoint cannot re-point a
/// request — with its body, its bearer header, and the user's pin scope — at
/// a host the user never configured.
final class RemoteAgentTrustEvaluator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// Expected SHA-256 (lowercase hex, no separators) of the leaf cert's
    /// public-key DER. `nil` disables pinning → default ATS validation.
    let pinnedFingerprintHex: String?

    /// The VERDICTS one connection attempt reached. Read as a UNIT so a
    /// classification can never pair one attempt's system verdict with another
    /// attempt's pin verdict, and never pair either with an error they did not
    /// belong to.
    ///
    /// VERDICTS ONLY — the presented leaf digest is deliberately NOT in here, even
    /// though it is recorded on the same attempt window. It is not part of any
    /// classification, so bundling it would buy nothing and cost the guarantee
    /// that no fingerprint travels to a classifying call site at all. Absence is
    /// stronger than an access-control fence: a value the type system never
    /// carries cannot be routed back into a pin field, while a value that travels
    /// is one callers are merely trusted not to use. See
    /// `presentedFingerprintHex`.
    struct AttemptTrustSignals: Equatable, Sendable {

        /// The system-chain evaluation OBJECTED to the certificate presented
        /// during this attempt (an explicit `SecTrustEvaluateWithError` failed).
        /// Evaluated on EVERY server-trust challenge — pinned or not — because a
        /// pin may only tighten a chain the system already accepts, never rescue
        /// one it rejected. `false` when this attempt raised no server-trust
        /// challenge at all (a handshake that failed before any certificate
        /// arrived), which is exactly how a transient `.secureConnectionFailed`
        /// is told apart from a genuine untrusted-cert rejection.
        ///
        /// AN OBJECTION, NOT A REFUSAL. On an UNPINNED lane `decide` records it
        /// and then hands the challenge back to the system, whose full policy may
        /// still ACCEPT the chain — the evaluation is advisory and also fails when
        /// it merely could not COMPLETE (an OCSP fetch that needed the network).
        /// So it can be `true` on an attempt that SUCCEEDED. It therefore explains
        /// a FAILURE of the SAME attempt, never a refusal on its own, which is why
        /// `classifyTransportError`'s `.cancelled` arm still gates on the pin
        /// posture.
        let systemTrustRejected: Bool

        /// The evaluator ANSWERED this attempt's server-trust challenge with
        /// `cancelAuthenticationChallenge` — for any of its three reasons (a pin
        /// over a chain the system rejected, a key it cannot fingerprint, a digest
        /// that disagreed). It is the fact that makes a `-999` attributable: every
        /// one of those refusals reaches the caller as a bare `.cancelled`, the
        /// same code a user tapping Cancel produces.
        ///
        /// A pin's mere EXISTENCE was never the reason a connection was refused;
        /// it was only ever a proxy for "the evaluator is on a path that CAN
        /// cancel", correct because of an invariant maintained in `decide` rather
        /// than because of anything the caller could see. Recording the refusal
        /// where it happens removes the proxy — and there is no loose-Bool
        /// classifier surface left through which a caller could reintroduce it.
        let challengeRefused: Bool

        /// The evaluator refused this attempt on a chain the system DID trust,
        /// because of the KEY: either the presented key disagreed with the pin, or
        /// it could not be fingerprinted at all (`pinComparisonUnsupported` says
        /// which). Deliberately NOT set by the fail-closed "pinned but the system
        /// rejected the chain" arm: that is an untrusted certificate, not a key
        /// problem, and `classifyTransportError` must be able to tell the two
        /// apart.
        let pinRejected: Bool

        /// The pin could not be COMPUTED at all: the leaf's key algorithm is
        /// outside the V1 SPKI prefix table (Ed25519, RSA-1024/8192, P-521), so
        /// `computeLeafSPKIHex` returned nil and the evaluator failed closed
        /// rather than accept a chain the user pinned against. Always accompanied
        /// by `pinRejected`.
        ///
        /// It selects a CLASS, not a copy variant: `classifyTransportError`
        /// resolves this shape to `.certKeyUnpinnable` and a real digest
        /// disagreement to `.certMismatch`, so every lane's exhaustive switch is
        /// forced to answer for both. Nothing about telling those two apart is
        /// left to a consumer remembering to read a second value — a consumer that
        /// forgot would tell a user with an Ed25519 certificate that their
        /// connection may be intercepted.
        let pinComparisonUnsupported: Bool

        /// An attempt that reached no verdict — the state every attempt starts
        /// in, the state a lane sees when its request never reached a
        /// certificate, and what a lane with no evaluator at all should
        /// substitute (`evaluator?.attemptSignals ?? .empty`). Named `empty`, not
        /// `none`, so it never collides with `Optional.none` at a call site.
        static let empty = AttemptTrustSignals(
            systemTrustRejected: false,
            challengeRefused: false,
            pinRejected: false,
            pinComparisonUnsupported: false
        )
    }

    /// What the CURRENT attempt has recorded. A snapshot of one window, not a
    /// running total: `urlSession(_:didCreateTask:)` opens a fresh window, stamped
    /// with that task's identifier, for every task the session creates.
    ///
    /// WHY THE WINDOW EXISTS — the defect it closes. Several lanes reuse ONE
    /// evaluator across MULTIPLE attempts: `STTClient.transcribe` retries up to
    /// three times on one ephemeral session, `TTSClient` twice, and
    /// `FileServerClient`'s staged test and folder probe issue a whole sequence of
    /// requests on one probe session. Because `systemTrustRejected` is an advisory
    /// OBJECTION that an attempt can survive, a per-evaluator flag recorded one on
    /// an attempt that WORKED and then explained a later, unrelated transient
    /// `-1200` (or `-999`) as a certificate verdict the user could not act on.
    /// Three review rounds patched that in three different arms of
    /// `classifyTransportError`; the lifetime is the actual fix, and it makes the
    /// stale-signal shape unrepresentable rather than something each new arm has
    /// to guard against.
    ///
    /// WHICH window this reports, exactly: the one belonging to the LAST task the
    /// session created. It matters because the reader has no task to name:
    /// `session.data(for:)` never hands one back, so "the attempt in flight" is
    /// the only thing a caller can ask about.
    ///
    /// THE SEQUENTIAL-LANE PRECONDITION — what makes that the RIGHT window, and
    /// the thing to check before adding concurrency. This read is UNKEYED: it
    /// reports whichever window was opened last, whoever is asking. It is the
    /// caller's own window only because every lane sharing one evaluator issues
    /// its requests IN SEQUENCE — `STTClient` / `TTSClient` retry loops await
    /// each attempt, `FileServerClient`'s staged test, read stage and folder
    /// probe await in order, each foreground converse send builds its own
    /// session and evaluator, and the per-challenge background lanes never open
    /// a window at all.
    ///
    /// The task stamp does NOT substitute for that precondition — it governs the
    /// WRITE side only (`commit` drops a challenge whose task no longer owns the
    /// window). With two tasks in flight on one evaluator, an EARLIER task's
    /// caller reads the LATER task's window and gets that task's verdicts, not
    /// an empty one — so a transient `-1200` / `-999` would be classified
    /// alongside a `systemTrustRejected` it never earned and surface as the
    /// terminal, non-retryable "this device doesn't trust the certificate".
    /// Putting a concurrent request on a shared probe session is what would
    /// create that shape.
    ///
    /// Thread-safety: written on URLSession's delegate queue during the
    /// server-trust challenge (which fires while `session.data(for:)` is in
    /// flight) and read by the caller after that awaited call returns.
    /// `fingerprintLock` (`NSLock`) is the actual cross-thread guarantee — it
    /// makes the read safe regardless of delegate-queue vs. await ordering,
    /// including any late callback, and taking all four verdicts under ONE
    /// acquisition is what stops a classification pairing a system verdict read
    /// before a challenge with a pin verdict read after it.
    var attemptSignals: AttemptTrustSignals {
        fingerprintLock.withLock { _window.signals }
    }

    // Single-verdict conveniences, for a caller asserting on ONE verdict in
    // isolation (the `decide(serverTrust:)` unit tests). Shipping code reads the
    // snapshot instead — a classification that pairs verdicts must take them under
    // one lock acquisition. Only the two verdicts something actually reads exist;
    // an accessor per field would invite exactly the loose-Bool call sites
    // `AttemptTrustSignals` was introduced to remove.

    /// `attemptSignals.systemTrustRejected` — see that field for what it does and
    /// does not mean.
    var systemTrustRejected: Bool { attemptSignals.systemTrustRejected }

    /// `attemptSignals.pinRejected` — see that field.
    var pinRejected: Bool { attemptSignals.pinRejected }

    /// SPKI SHA-256 (lowercase hex) of the leaf certificate presented during the
    /// current attempt, or `nil` when the attempt raised no server-trust challenge
    /// or the leaf's key algorithm is outside the V1 SPKI prefix table. Cleared at
    /// the attempt boundary like every verdict.
    ///
    /// A TEST-OBSERVABLE RECORD, and nothing more. No shipping code reads it: with
    /// trust-on-first-use deleted everywhere, its whole remaining job is to let a
    /// test see that the evaluator hashed the leaf it was supposed to
    /// (`RemoteAgentLiveTLSTrustTests`' openssl drift guard). It is read-only and
    /// kept OUT of `AttemptTrustSignals` on purpose — see that type. Nothing pins
    /// it, and no classifying call site is ever handed it.
    var presentedFingerprintHex: String? {
        fingerprintLock.withLock { _window.presentedFingerprintHex }
    }

    /// One task's window: WHOSE it is, and everything recorded in it. The task
    /// identifier lives INSIDE the window rather than beside it so "open a window"
    /// and "stamp it" cannot happen apart — a window whose owner was assigned in a
    /// separate step is a window a refactor can leave stamped for the previous
    /// task, which is the misattribution the stamp exists to prevent.
    ///
    /// `owningTaskIdentifier` is nil for a window no task opened: an evaluator
    /// built PER CHALLENGE by a lane that is not a session delegate never receives
    /// `didCreateTask`, so it has no task to disagree with and records
    /// unconditionally.
    private struct AttemptWindow {
        var owningTaskIdentifier: Int?
        var presentedFingerprintHex: String?
        var signals: AttemptTrustSignals = .empty
    }

    private var _window = AttemptWindow()
    private let fingerprintLock = NSLock()

    /// System chain validation for one `SecTrust`. `SecTrustEvaluateWithError`
    /// in every shipping build — the only way to put anything else here is the
    /// `#if DEBUG` initializer below, which does not exist in a Release build.
    private let evaluateSystemTrust: @Sendable (SecTrust) -> Bool

    init(pinnedFingerprintHex: String? = nil) {
        self.pinnedFingerprintHex = pinnedFingerprintHex
        self.evaluateSystemTrust = { SecTrustEvaluateWithError($0, nil) }
        super.init()
    }

    #if DEBUG
    /// TEST-ONLY. Substitutes the system-chain verdict so the branch order
    /// below ("a pin applies ON TOP of system trust") is exercisable against a
    /// fixture certificate: a synthesised `URLAuthenticationChallenge` cannot
    /// carry a `serverTrust`, and no test can make this machine trust a
    /// certificate it does not already trust.
    ///
    /// `#if DEBUG` IS the security control here, not a naming convention.
    /// Passing `{ _ in true }` switches chain validation off outright — the
    /// fail-closed arm never fires, and loopback plus the machine's own
    /// routable addresses are ATS-exempt, so App Transport Security is not a
    /// backstop behind it. The fence means a Release or Archive build cannot
    /// COMPILE a call that supplies the closure, while tests keep it: the
    /// Conduck scheme's TestAction builds Debug-Testing, which defines DEBUG (so
    /// `xcodebuild test` and `build-for-testing` both do), its ArchiveAction and
    /// ProfileAction build Release, and no CI job passes `-configuration`.
    init(
        pinnedFingerprintHex: String?,
        evaluateSystemTrust: @escaping @Sendable (SecTrust) -> Bool
    ) {
        self.pinnedFingerprintHex = pinnedFingerprintHex
        self.evaluateSystemTrust = evaluateSystemTrust
        super.init()
    }
    #endif

    // MARK: - Per-ref pin resolution (durable, live)

    /// The pinned SPKI SHA-256 (lowercase hex) stored for `ref`, read LIVE from
    /// App-Group `UserDefaults`. `nil` when unset or empty → default ATS.
    ///
    /// Defaults-only by design (no iCloud-KVS fallback, unlike
    /// `getRemoteAgentURL(for:)`): a cert pin is a per-DEVICE tightening of a
    /// chain THIS device already trusts, and is never synced — another device
    /// may legitimately see a different (also-trusted) certificate.
    /// Nonisolated synchronous read, so it is safe both inside
    /// a trust delegate (no MainActor hop into `SettingsManager`) and on the
    /// foreground send path — and reading it at challenge/dispatch time rather
    /// than caching it means a re-pin between compose and send is honored, and a
    /// cross-launch background resume re-reads the durable value.
    static func storedConversePin(for ref: RemoteAgentRef) -> String? {
        let defaults = SettingsDependencies.processDefault.defaults
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
    /// Shared by the pin-compare path and the diagnostic capture path so both
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
    /// The trust VERDICTS disambiguate the generic `.secureConnectionFailed` /
    /// `.cancelled` codes, which fire for BOTH real certificate rejections and
    /// transient handshake hiccups. They arrive as one `AttemptTrustSignals`
    /// snapshot and MUST describe the attempt that produced `code` — that is the
    /// whole reason the snapshot is scoped to an attempt. With none of them set,
    /// a generic TLS failure is transient → `.unreachable`.
    ///
    /// `systemTrustRejected` is checked FIRST wherever several apply: "this device
    /// does not trust this certificate" is the truthful, actionable statement,
    /// and the pinned fail-closed arm cancels the challenge (surfacing as
    /// `.cancelled`/-999) without ever setting `pinRejected`.
    enum TransportErrorClass: Equatable, Sendable {
        case timeout
        /// The UNCERTAIN bucket: the attempt failed and the app cannot tell
        /// whether the request reached the gateway. What lands here is a dropped
        /// connection, a cold TLS handshake with no trust verdict, and anything
        /// unrecognised — i.e. exactly the cases where a retry might repeat work
        /// the gateway already did. The two situations the app CAN be definite
        /// about were split out into `.notEstablished` and `.offline`.
        case unreachable
        /// No connection was ever established — the name did not resolve, or the
        /// host refused. Delivery is UNLIKELY, and the copy says "unlikely", not
        /// "nothing was sent": without transport metrics the app cannot prove a
        /// negative, and even metrics could not prove the far side didn't run it.
        ///
        /// Deliberately excludes `.resourceUnavailable`, which is ambiguous
        /// enough that it stays in `.unreachable`.
        case notEstablished
        /// THIS DEVICE has no usable network. Split out so an aeroplane-mode
        /// failure stops telling the user to go check a server that is fine.
        case offline
        /// This device does not trust the presented certificate. TERMINAL —
        /// there is no trust-on-first-use affordance anywhere in the app; the
        /// remedy is a certificate the device would trust.
        case untrustedCert
        /// A configured pin was compared against a chain the system DID trust and
        /// the presented key DISAGREED. Narrow by construction, and now actually
        /// so: an untrusted chain fails closed into `.untrustedCert` before any
        /// digest work, and a key Conduck cannot fingerprint resolves to
        /// `.certKeyUnpinnable` instead — so this class only ever describes a
        /// valid, system-trusted certificate that is not the pinned one. That is
        /// the interception shape the pin exists to catch.
        ///
        /// It is the ONLY class that may say the connection MAY BE INTERCEPTED,
        /// its remedy is "stop and check" rather than anything server-side, and
        /// nothing may suggest removing the pin — the pin just did its job.
        /// TERMINAL, never retried.
        case certMismatch
        /// The pin could not be COMPUTED, so it could not be compared: the leaf's
        /// public-key algorithm is outside the V1 SPKI prefix table (Ed25519,
        /// RSA-1024/8192, P-521 — see `SPKIPrefix`). The evaluator failed closed
        /// rather than wave through a chain the user had pinned against.
        /// TERMINAL, never retried.
        ///
        /// NOT AN INTERCEPTION SIGNAL, and copy must not imply one. This arm is
        /// reached only after `guard systemTrusts` has already PASSED, so the
        /// chain is publicly trusted and nothing disagreed with anything — the
        /// user's only problem is a key type Conduck cannot fingerprint. Telling
        /// them their connection may be intercepted would be a false alarm on the
        /// most alarming message in the app, which is how people learn to dismiss
        /// the real one.
        ///
        /// Copy names the real cause and BOTH remedies: reissue the certificate
        /// with a key Conduck can fingerprint (RSA-2048/3072/4096, EC
        /// P-256/P-384), **or remove the saved fingerprint**. That second phrase
        /// is banned everywhere else in the app and is legitimate HERE AND ONLY
        /// HERE: elsewhere it means "switch off the control that just caught
        /// something", whereas here nothing was caught and dropping the pin simply
        /// returns the connection to ordinary system trust, which is already
        /// passing. Do not "correct" this back.
        case certKeyUnpinnable
        case cancelled
    }

    /// Which class a REFUSAL on a system-trusted chain resolves to. One helper so
    /// the digest-disagreement and the cannot-compute shapes can never diverge
    /// between arms — the way to add a third shape is to add a case here, not to
    /// re-derive the split at each `case` in the switch below.
    private static func keyRefusalClass(_ signals: AttemptTrustSignals) -> TransportErrorClass {
        signals.pinComparisonUnsupported ? .certKeyUnpinnable : .certMismatch
    }

    /// Classify `code` against THIS attempt's verdicts — THE FORM EVERY LANE THAT
    /// HOLDS THE EVALUATOR SHOULD USE. Every input comes from one
    /// `attemptSignals` snapshot taken off the evaluator that answered the
    /// challenge, so a caller can neither pair a stale verdict with a fresh error
    /// nor declare a posture the evaluator itself contradicts.
    func classifyTransportError(_ code: URLError.Code) -> TransportErrorClass {
        Self.classifyTransportError(code, signals: attemptSignals)
    }

    /// Snapshot form, for a lane that holds one attempt's verdicts but not the
    /// evaluator — a test seam, or a per-task registry replaying the record it
    /// captured inside the challenge (`BackgroundRemoteAgent`,
    /// `CarPlayConverseUploader`, `STTClient+Background`, `WatchAudioUploader`).
    ///
    /// THE CORE. Every other form funnels through here, so an arm added below
    /// applies to all of them at once.
    static func classifyTransportError(
        _ code: URLError.Code,
        signals: AttemptTrustSignals
    ) -> TransportErrorClass {
        let systemTrustRejected = signals.systemTrustRejected
        let pinRejected = signals.pinRejected
        switch code {
        case .timedOut:
            return .timeout
        case .notConnectedToInternet:
            // The device itself has no route. Answered before the host-shaped
            // codes below so a failure that is entirely local never gets
            // reported as a problem with the user's server.
            return .offline
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            // The connection never opened: DNS gave nothing, or the host
            // actively refused. These are the only codes definite enough to
            // tell the user a retry is unlikely to repeat gateway-side work.
            return .notEstablished
        case .networkConnectionLost,
             .resourceUnavailable:
            // Stay UNCERTAIN. A dropped connection may have delivered the
            // request first, and `.resourceUnavailable` is too vague to promise
            // anything about delivery.
            return .unreachable
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            // Unambiguous certificate-trust rejection codes: the SYSTEM named
            // the certificate as the cause, so these resolve even with neither
            // signal set — and with neither signal set they resolve to
            // UNTRUSTED. `pinRejected` is the only thing that can turn one of
            // them into a mismatch, because it is the positive record that a
            // digest was actually compared against a chain the system DID trust
            // and the key disagreed. A pin's mere EXISTENCE would not do: a
            // user whose certificate this device refuses would be told their
            // fingerprint changed and sent to edit a pin nothing ever
            // consulted. `systemTrustRejected` still outranks
            // `pinRejected`, same as every arm below.
            if pinRejected && !systemTrustRejected { return keyRefusalClass(signals) }
            return .untrustedCert
        case .secureConnectionFailed:
            // GENERIC SSL failure: a cert rejection OR a transient handshake
            // hiccup. Treat it as a cert problem ONLY when the trust layer
            // actually rejected; otherwise it is transient → retryable. Every
            // verdict is POSITIVE, so a cold-tunnel `-1200` (none set) stays
            // `.unreachable` — the regression this classifier exists to prevent.
            if systemTrustRejected { return .untrustedCert }
            if pinRejected { return keyRefusalClass(signals) }
            return .unreachable
        case .cancelled:
            // -999 is the app's most overloaded code: the user tapping Cancel, a
            // session teardown, structured-concurrency cancellation, AND all three
            // of the evaluator's own refusals look identical here. So this arm
            // reads `challengeRefused` — the positive record that the refusal was
            // OURS.
            //
            // WHY that and not `systemTrustRejected` alone: the objection can be
            // set on an attempt the evaluator did NOT refuse.
            // `SecTrustEvaluateWithError` inside a challenge is ADVISORY and also
            // fails when evaluation merely could not COMPLETE (an OCSP fetch that
            // needed the network); on an unpinned lane `decide` then hands the
            // challenge back, the system ACCEPTS the chain, and the response
            // starts arriving. Tap Cancel mid-reply and that one attempt carries
            // an objection and a -999 that have nothing to do with each other.
            // Reading the objection alone reports a user cancel as an untrusted
            // certificate.
            //
            // A "is a pin configured" gate would give the same answer only
            // because of an invariant maintained in `decide` — that an unpinned
            // challenge is never cancelled — which the classifier cannot see and
            // a caller cannot check. `challengeRefused` states the fact directly,
            // at the point it happens.
            //
            // `pinRejected` needs no such gate: only a refusing branch sets it.
            // It is still checked SECOND so the precedence matches every arm
            // above, and a caller that contradicts itself (`pinRejected` without
            // `challengeRefused`) keeps the refusal rather than silently dropping
            // an interception signal.
            if signals.challengeRefused && systemTrustRejected { return .untrustedCert }
            if pinRejected { return keyRefusalClass(signals) }
            return .cancelled
        default:
            return .unreachable
        }
    }

    // MARK: - Trust decision (pure core, independently unit-testable)

    /// What the evaluator wants URLSession to do with one server-trust
    /// challenge. Factored out of the delegate method because a synthesised
    /// `URLAuthenticationChallenge` cannot be given a `serverTrust`, so this is
    /// the only shape the branch order can be tested in.
    enum TrustDecision: Equatable, Sendable {
        case performDefaultHandling
        case useCredential
        case cancel
    }

    /// THE branch order. A pin is an ADDITIONAL restriction on a chain the
    /// system already trusts; it can never rescue an untrusted one.
    ///
    ///   1. Capture the presented leaf's SPKI digest — on EVERY challenge,
    ///      before any branch (diagnostic only; nothing pins it).
    ///   2. Evaluate system trust — on EVERY challenge, pinned or not.
    ///   3. No pin              → `.performDefaultHandling` (the system stays
    ///      authoritative: our evaluation is advisory and the full system policy
    ///      may legitimately differ from it).
    ///   4. Pin + system rejected → `.cancel`. FAIL CLOSED, in our own code —
    ///      never `.useCredential` on the assumption App Transport Security will
    ///      kill it anyway. `pinRejected` stays false: the certificate is
    ///      untrusted, which is a different verdict from a key mismatch.
    ///   5. Pin + unpinnable key → `pinRejected` + `pinComparisonUnsupported`,
    ///      `.cancel` (an algorithm outside the V1 SPKI prefix table cannot be
    ///      compared, and falling through to default handling would accept a
    ///      chain the user pinned against). The second verdict is what routes it
    ///      to `.certKeyUnpinnable` instead of an interception warning.
    ///   6. Pin + digest match  → `.useCredential`.
    ///   7. Pin + digest differs → `pinRejected`, `.cancel`.
    ///
    /// `challengeRefused` is recorded from the returned decision rather than by
    /// each cancelling arm: an arm added later cannot forget to set it, and it
    /// cannot be set by an arm that did not actually cancel.
    ///
    /// `taskIdentifier` names the task this challenge belongs to, and everything
    /// recorded is committed to THAT task's window or discarded — see `commit`.
    /// Pass nil from a lane that is not a session delegate (the evaluator is built
    /// per challenge there, so there is no other task it could be confused with);
    /// the delegate path always passes the real identifier.
    ///
    /// CAVEAT (preserved): `SecTrustEvaluateWithError` inside a challenge is
    /// ADVISORY. It returns false for BOTH "untrusted" AND "evaluation could not
    /// complete", so `systemTrustRejected` means "system trust did not pass",
    /// not strictly "malicious cert". That is the right signal in both places it
    /// is used: it tells a genuine non-passing cert apart from a transient
    /// handshake failure that never reached a cert challenge at all. It is also
    /// why the signal must not outlive its attempt — an evaluation that could not
    /// complete leaves a request that SUCCEEDED carrying an objection.
    func decide(serverTrust: SecTrust, taskIdentifier: Int? = nil) -> TrustDecision {
        let (decision, record) = evaluate(serverTrust: serverTrust)
        commit(record, decision: decision, taskIdentifier: taskIdentifier)
        return decision
    }

    /// What ONE challenge concluded, before it is committed to a window. A value,
    /// not four writes into shared state: the branch order below cannot record
    /// anything until the decision is known, so a challenge that turns out to
    /// belong to a different task leaves nothing behind to clean up.
    private struct ChallengeRecord {
        var presentedFingerprintHex: String?
        var systemTrustRejected = false
        var pinRejected = false
        var pinComparisonUnsupported = false
    }

    /// The branch order itself. Pure with respect to the window — it returns what
    /// it concluded and `decide` decides where (or whether) that lands.
    private func evaluate(serverTrust: SecTrust) -> (TrustDecision, ChallengeRecord) {
        let presentedDigest = Self.computeLeafSPKIHex(from: serverTrust)
        let systemTrusts = evaluateSystemTrust(serverTrust)
        var record = ChallengeRecord(presentedFingerprintHex: presentedDigest)
        record.systemTrustRejected = !systemTrusts

        guard let expectedHex = pinnedFingerprintHex, !expectedHex.isEmpty else {
            return (.performDefaultHandling, record)
        }

        guard systemTrusts else { return (.cancel, record) }

        guard let actualHex = presentedDigest else {
            // The key algorithm is outside the V1 SPKI prefix table, so there is
            // no digest to compare. Fail closed — but record WHY, because
            // "Conduck cannot fingerprint this key" and "the key disagreed" are
            // different classes with different remedies, and only the second is
            // evidence of interception.
            record.pinRejected = true
            record.pinComparisonUnsupported = true
            return (.cancel, record)
        }

        // Lowercase compare — pinned value is stored lowercase by the
        // Settings save path. Defensive lowercase here lets a user
        // hand-paste an uppercase fingerprint without surprise mismatch.
        guard actualHex.lowercased() == expectedHex.lowercased() else {
            // URLSession surfaces this to the data-task as
            // NSURLErrorServerCertificateUntrusted (or similar) or `.cancelled`;
            // `pinRejected` lets the caller map it to `.remoteAgentCertMismatch`
            // (a genuine mismatch) and NOT confuse it with a transient
            // handshake failure or a benign task cancellation.
            record.pinRejected = true
            return (.cancel, record)
        }
        return (.useCredential, record)
    }

    /// Land one challenge's conclusions in the window they belong to — or nowhere.
    ///
    /// THE OWNERSHIP GATE, and the reason the window carries a task identifier at
    /// all. Apple's own header says a server-trust challenge is CONNECTION-level
    /// and "will apply to more than one request on a given connection", so a
    /// challenge cannot be assumed to belong to whichever task happened to open the
    /// window last. Without the gate: task A is created (window opens for A), task
    /// B is created (window reopens for B), A's challenge records A's rejection
    /// into B's window, and B's unrelated `-999` or `-1200` is then explained as a
    /// certificate verdict A earned. With it, a challenge whose task no longer owns
    /// the window is ANSWERED normally and simply recorded nowhere.
    ///
    /// SCOPE OF THAT GUARANTEE, stated exactly: no EARLIER task's verdict can land
    /// in a LATER task's window. It is a WRITE-side rule and says nothing about
    /// what a concurrent READER gets — the earlier task's caller still reads the
    /// LATER task's window, which carries that task's own verdicts the moment its
    /// own challenge commits into it. Discarding is the safe direction for this
    /// half; read-side correctness is the sequential-lane precondition documented
    /// on `attemptSignals`.
    ///
    /// Verdicts OR together within one window: a lane may raise several challenges
    /// on one task (a same-origin redirect hop), and the second must not erase what
    /// the first found. The presented digest is the exception — it is the LATEST
    /// leaf seen, which is what a diagnostic reading of it means.
    private func commit(_ record: ChallengeRecord, decision: TrustDecision, taskIdentifier: Int?) {
        fingerprintLock.withLock {
            if let taskIdentifier,
               let owner = _window.owningTaskIdentifier,
               taskIdentifier != owner {
                return
            }
            _window.presentedFingerprintHex = record.presentedFingerprintHex
            _window.signals = AttemptTrustSignals(
                systemTrustRejected: _window.signals.systemTrustRejected || record.systemTrustRejected,
                challengeRefused: _window.signals.challengeRefused || decision == .cancel,
                pinRejected: _window.signals.pinRejected || record.pinRejected,
                pinComparisonUnsupported:
                    _window.signals.pinComparisonUnsupported || record.pinComparisonUnsupported
            )
        }
    }

    // MARK: - URLSessionDelegate

    /// THE ATTEMPT BOUNDARY. URLSession calls this once for every task it creates
    /// on a session whose delegate is this evaluator, before that task can raise a
    /// challenge, so it is the one point where "a new attempt starts" is known
    /// WITHOUT cooperation from the caller. That is what makes the per-attempt
    /// lifetime automatic for every lane rather than a discipline each retry loop
    /// has to remember — and a lane cannot opt out of it by forgetting something.
    ///
    /// Concurrency: attempts on one evaluator are SEQUENTIAL by contract (every
    /// lane awaits one request before issuing the next), and it is that CONTRACT
    /// — not the task stamp — that makes the last-created task's window the one
    /// the reading caller wants. The STAMP covers only the write side when the
    /// contract does not hold: a challenge belonging to an older task is recorded
    /// nowhere rather than into this one (see `commit`). The older task's caller
    /// still reads THIS task's window, verdicts included, so two tasks in flight
    /// on one evaluator can hand a transient failure a `systemTrustRejected` it
    /// never earned. Re-check the precondition before putting a second concurrent
    /// request on a session that shares an evaluator.
    ///
    /// An evaluator built PER CHALLENGE and read synchronously inside it
    /// (`WatchAudioUploader`, `BackgroundFileTransfer`, `CarPlayConverseUploader`,
    /// `STTClient+Background`, `BackgroundRemoteAgent`) is never a session
    /// delegate and never receives this callback. Those lanes are attempt-scoped
    /// by construction — the evaluator does not outlive the challenge — and their
    /// per-task registries carry the verdict onward.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        fingerprintLock.withLock {
            _window = AttemptWindow(owningTaskIdentifier: task.taskIdentifier)
        }
    }

    /// The TASK-level challenge handler — the one URLSession actually calls for
    /// this delegate, and the only one that knows which task raised the challenge.
    ///
    /// The file lane already ships this shape
    /// (`BackgroundFileTransfer.urlSession(_:task:didReceive:completionHandler:)`,
    /// driven against a real handshake by `RemoteAgentLiveTLSTrustTests`), so a
    /// server-trust challenge reaching a task-level handler is a property this
    /// codebase already relies on rather than an assumption made here.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, taskIdentifier: task.taskIdentifier, completionHandler: completionHandler)
    }

    /// Answer ONE challenge with no task to attribute it to — the entry point for
    /// the five lanes that build an evaluator PER CHALLENGE inside their own
    /// task-level delegate (`BackgroundFileTransfer`, `BackgroundRemoteAgent`,
    /// `CarPlayConverseUploader`, `STTClient+Background`, `WatchAudioUploader`).
    /// Those evaluators are never a session delegate, so they never open a window
    /// and have no second task their verdict could be misread against.
    ///
    /// `@nonobjc` IS LOAD-BEARING, not tidiness. This method's Swift signature is
    /// also the session-level `URLSessionDelegate` requirement, and a session-level
    /// handler TAKES PRECEDENCE over the task-level one for server-trust
    /// challenges — so leaving it visible to the Objective-C runtime would route
    /// every challenge here, to the arm that cannot name a task, and the window
    /// stamp above would never do anything. Hiding the selector keeps the Swift
    /// call sites and hands URLSession the task-level handler. Removing the
    /// attribute is not a security regression (the same policy runs either way);
    /// it silently costs the task attribution.
    @nonobjc
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, taskIdentifier: nil, completionHandler: completionHandler)
    }

    private func respond(
        to challenge: URLAuthenticationChallenge,
        taskIdentifier: Int?,
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

        // Every branch, including the digest capture and the system-trust
        // evaluation that must run on EVERY challenge, lives in `decide`.
        switch decide(serverTrust: serverTrust, taskIdentifier: taskIdentifier) {
        case .performDefaultHandling:
            completionHandler(.performDefaultHandling, nil)
        case .useCredential:
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .cancel:
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
    /// be called"), which is why every background lane additionally resolves its
    /// pin from the TASK and applies it host-blind — `converseTaskPin(for:metadata:)`
    /// here, and its per-lane twins on the file-transfer and Watch converse lanes.
    /// That mitigation is weaker than a redirect veto and is documented as such
    /// on `converseTaskPin`.
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

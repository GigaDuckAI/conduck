// Conduck
// PairingTrustDecision.swift
//
// Trust policy for an INBOUND pairing code (`conduck-setup:` QR / paste).
// Pure decision logic — no networking, no persistence, no UI — so the whole
// matrix is unit-testable without a TLS fixture.
//
// WHY THIS EXISTS. `RemoteAgentTrustEvaluator` implements pinning as
// "pin configured → match accepts, mismatch cancels", and standard chain
// validation runs ONLY when no pin is set (`RemoteAgentTrustEvaluator.swift:406`).
// A pin therefore REPLACES ordinary trust rather than adding to it. That is the
// right shape for a pin the USER typed into Settings for their own self-signed
// gateway. It is the wrong shape for a pin that arrived inside a code someone
// else generated: the payload would be asking the app to lower its standards,
// and the app would comply without ever checking whether the live server agrees
// with the claim.
//
// So a pairing import probes UNPINNED first (`payloadPinHex` is compared in
// software here, never installed before this verdict), which yields all three
// signals off one handshake — see `PairingTrustProbeSignals`.
//
// THE AUTHORITATIVE PASS SIGNAL IS `requestCompleted`, NOT `systemTrustRejected`.
// The evaluator's `SecTrustEvaluateWithError` call is explicitly advisory
// (`RemoteAgentTrustEvaluator.swift:407-415`) and App Transport Security layers
// requirements ON TOP of trust-policy evaluation (TLS ≥ 1.2, forward secrecy,
// SHA-2). "The advisory check did not object" is therefore NOT proof the
// connection would be accepted; the request completing is.
//
// THE ROW THAT MOTIVATES THE WHOLE FILE is `requestCompleted == true` with a
// MISMATCHING payload pin. Under enterprise TLS inspection the middlebox's root
// is installed on the device, so ordinary trust PASSES — while the key actually
// on the wire is the middlebox's, not the one the code names. An inspecting
// middlebox does not announce itself as a proxy, so the evaluator's challenge
// fires with `isProxy == false` and the presented digest is captured normally
// (`RemoteAgentTrustEvaluator.swift:385-401`). A binary "ordinary trust passed →
// drop the pin" rule would silently accept exactly that disagreement.
//
// TRANSIENT IS NEVER A TRUST VERDICT. A cold tunnel produces a generic
// `.secureConnectionFailed` on a perfectly valid cert — the incident recorded at
// `RemoteAgentTrustEvaluator.swift:304-317`. Those cases resolve to
// `.unreachable`, which the UI must present as "could not reach", never as a
// statement about the certificate.

import Foundation

/// The three signals a single UNPINNED probe yields, plus the claim the payload
/// made. Everything here is captured by machinery that already exists; this
/// struct only names it so the decision below is a pure function of it.
struct PairingTrustProbeSignals: Equatable, Sendable {

    /// The SPKI SHA-256 the pairing payload carries for this lane
    /// (`PairingPayload.certFP` / `PairingPayload.FileServer.certFP`), or `nil`
    /// when the code carries none. Compared case-insensitively; an all-whitespace
    /// or empty value is treated as absent.
    let payloadPinHex: String?

    /// The leaf SPKI SHA-256 the server actually presented, captured by
    /// `RemoteAgentTrustEvaluator` on every server-trust challenge — including
    /// the default-handling path (`RemoteAgentTrustEvaluator.swift:400-401`).
    ///
    /// `nil` means the digest could not be computed: no server-trust challenge
    /// fired at all, or the leaf's key algorithm is outside the V1 SPKI prefix
    /// table (e.g. Ed25519, `spkiDER(from:)` returns nil). `nil` is NOT evidence
    /// of anything — it is absence of evidence, and the matrix treats it that way.
    let presentedFingerprintHex: String?

    /// The TLS handshake was accepted — i.e. an HTTP response came back at ANY
    /// status. A 401 or a 404 still proves ordinary trust accepted the chain,
    /// and this is the authoritative signal that it did (see the file header).
    ///
    /// CONTRACT FOR THE CALLER: this must be derived from whether a response was
    /// received, NOT from whether the probe "passed". `RemoteAgentClient`'s
    /// Test Connection surface throws on 401/404/5xx and on a wrong body envelope
    /// (`RemoteAgentClient+TestConnection.performTestConnection`) — all AFTER the
    /// handshake succeeded. Feeding it `false` in those cases would report a
    /// reachable, ordinarily-trusted server as unreachable, and would skip the
    /// pin-contradiction check that only this arm performs. The pairing probe
    /// must therefore capture handshake completion at the transport boundary,
    /// before any status or body verdict is applied.
    let requestCompleted: Bool

    /// How the transport failed, when `requestCompleted == false`. Produced by
    /// `RemoteAgentTrustEvaluator.classifyTransportError(_:hasPin:systemTrustRejected:pinRejected:)`,
    /// the app's single source of truth for telling a genuine certificate
    /// rejection apart from a transient handshake failure.
    ///
    /// `nil` alongside `requestCompleted == false` means the failure was not a
    /// `URLError` at all — classified conservatively as unreachable.
    let transportClass: RemoteAgentTrustEvaluator.TransportErrorClass?

    init(
        payloadPinHex: String?,
        presentedFingerprintHex: String?,
        requestCompleted: Bool,
        transportClass: RemoteAgentTrustEvaluator.TransportErrorClass? = nil
    ) {
        self.payloadPinHex = payloadPinHex
        self.presentedFingerprintHex = presentedFingerprintHex
        self.requestCompleted = requestCompleted
        self.transportClass = transportClass
    }
}

/// Why an import was refused on trust grounds. Each case is a DIFFERENT sentence
/// to the user; they are kept distinct rather than collapsed to one "blocked"
/// because the remedies differ (rotate setup vs. get a fresh code vs. the code is
/// lying about the server).
enum PairingTrustBlock: Equatable, Sendable {

    /// Ordinary trust ACCEPTED the chain, but the key on the wire is not the key
    /// the code names. The code and the live server disagree about the server's
    /// identity — the enterprise-TLS-inspection row, and the one case a naive
    /// "trust passed, we're fine" rule would wave through.
    case pinContradictsLiveServer

    /// Ordinary trust REJECTED the cert AND the key on the wire is not the key
    /// the code names. Never offer a one-tap exception here: the user has no way
    /// to tell a re-issued self-signed cert from a substituted one, and the code
    /// itself already fails to vouch for what is being presented.
    case untrustedAndPinMismatch

    /// The code carries a pin, but the presented key could not be digested (no
    /// challenge fired, or an unsupported key algorithm). The claim is therefore
    /// UNVERIFIABLE. Fail closed rather than installing a pin never checked
    /// against the wire — silently keeping an unverified pin is precisely the
    /// posture this file exists to remove.
    case unverifiablePin

    /// Ordinary trust rejected the cert and no pinnable digest could be computed,
    /// so there is nothing to offer an exception FOR. Distinct from
    /// `unverifiablePin`: here the code made no claim either.
    case untrustedWithoutPinnableKey

    /// Ordinary trust rejected the cert and the code names NO key.
    ///
    /// This blocks rather than offering first-contact trust, because omission is
    /// not a legitimate variant: the LOCKED v1 contract emits `certFP` whenever
    /// the transport is self-signed (`spec.md` "Pairing payload v1" — *"omit
    /// unless self-signed"*). A canonical self-signed code therefore always
    /// carries one, so a self-signed server whose code claims nothing is
    /// non-canonical.
    ///
    /// Treating it as an ordinary trust-on-first-use opportunity would hand the
    /// attacker BRANCH SELECTION: deleting one field from a payload that would
    /// otherwise hit `untrustedAndPinMismatch` would downgrade a hard block into
    /// a one-tap trust prompt. The import path must not be steerable by field
    /// omission. (The Settings editor's manual TOFU, where the human typed the
    /// URL themselves, is a different trust context and is unaffected.)
    case untrustedWithoutClaim
}

/// What the import should do about certificates, decided BEFORE anything is
/// persisted and BEFORE any pin from the payload reaches storage.
enum PairingTrustVerdict: Equatable, Sendable {

    /// Ordinary system trust is sufficient. **Do not install an exception pin** —
    /// including when the payload carried one that matched. Retaining it would
    /// convert a working publicly-trusted gateway into a pinned one that breaks
    /// on ordinary certificate renewal, and would re-introduce pin-replaces-WebPKI
    /// for a lane that does not need it.
    case useOrdinaryTrust

    /// Ordinary trust does not accept this server, but the key on the wire is
    /// pinnable and is EXACTLY the key the code claims. The user must be told
    /// what is being pinned BEFORE it is stored — this verdict is an offer,
    /// never an action.
    ///
    /// Reached only when the code made a claim and it matched. A code that names
    /// no key never lands here (`untrustedWithoutClaim`), so the offer cannot be
    /// unlocked by deleting a field.
    case offerPinException(fingerprintHex: String)

    /// Refuse the import on trust grounds.
    case blocked(PairingTrustBlock)

    /// The server could not be reached. NOT a statement about the certificate —
    /// the UI must not render this as a trust problem, and nothing may be
    /// persisted on the strength of it.
    case unreachable(RemoteAgentTrustEvaluator.TransportErrorClass)
}

/// What "Connect anyway" would actually DO for a blocked import.
///
/// A blanket override is not implementable as a single action, because the app
/// has no "ignore certificate errors" mode: `RemoteAgentTrustEvaluator` either
/// accepts on a pin match or falls through to ordinary system trust. There is no
/// third door. So proceeding means one of exactly two concrete things — and in
/// one situation it means nothing at all, because no mechanism exists.
///
/// THE INVARIANT ACROSS BOTH CASES: an override trusts what is **on the wire**,
/// never what the **code claims**. Installing a claimed-but-unconfirmed pin would
/// be strictly worse than blocking — it would either brick the connection (the
/// real server can never present that key) or pin the user to a key chosen by
/// whoever wrote the code.
enum PairingTrustOverride: Equatable, Sendable {

    /// Proceed under ordinary system trust, DISCARDING the code's contradictory
    /// claim. Available only when ordinary trust already accepted the chain, so
    /// the connection keeps full chain, hostname and expiry validation — the user
    /// is choosing to disregard a disagreement, not to disable verification.
    ///
    /// This is the enterprise-TLS-inspection case, and it is the reason an
    /// override has to exist at all: on a corporate network the inspecting
    /// middlebox makes this disagreement permanent, and without a way past it
    /// those users could never pair.
    case proceedUnderOrdinaryTrust

    /// Pin the key the server ACTUALLY presented. The user is accepting a server
    /// that nothing vouches for — this is genuine trust-on-first-use, and the
    /// disclosure must say so before it is stored.
    case pinPresentedKey(fingerprintHex: String)
}

enum PairingTrustDecision {

    /// What proceeding anyway would mean for a blocked verdict, or `nil` when
    /// there is no way to proceed at all.
    ///
    /// Returns `nil` for any verdict that is not `.blocked` — an override is
    /// meaningless when nothing was refused, and returning nil makes it
    /// impossible to offer one by accident.
    ///
    /// The one genuinely unavailable case is an untrusted certificate whose key
    /// could not be digested (`untrustedWithoutPinnableKey`): ordinary trust has
    /// refused it, and with no computable fingerprint there is nothing to pin,
    /// so the app cannot complete a connection to that server by any route. The
    /// remedy is on the server (use a supported key type), not in the app — the
    /// UI must say that rather than offering a button that cannot work.
    static func override(
        for verdict: PairingTrustVerdict,
        signals: PairingTrustProbeSignals
    ) -> PairingTrustOverride? {
        guard case .blocked = verdict else { return nil }

        // Ordinary trust already accepted the chain, so proceeding keeps every
        // standard protection and merely disregards the code's claim.
        if signals.requestCompleted { return .proceedUnderOrdinaryTrust }

        // Ordinary trust refused. The only way onward is to pin what was actually
        // presented — never `payloadPinHex`, which is the attacker-controlled
        // side of the disagreement.
        if let presented = normalized(signals.presentedFingerprintHex) {
            return .pinPresentedKey(fingerprintHex: presented)
        }

        // Refused, and nothing pinnable. No mechanism exists.
        return nil
    }

    /// The full matrix. Pure — same input, same verdict, no I/O.
    ///
    /// | ordinary trust | live key vs the code's claim | verdict |
    /// |---|---|---|
    /// | accepted | matches, or code claimed none | `.useOrdinaryTrust` (pin NOT installed) |
    /// | accepted | **differs** | `.blocked(.pinContradictsLiveServer)` |
    /// | accepted | unreadable, code claimed one | `.blocked(.unverifiablePin)` |
    /// | rejected | matches | `.offerPinException` |
    /// | rejected | code claimed none | `.blocked(.untrustedWithoutClaim)` |
    /// | rejected | unreadable, code claimed one | `.blocked(.unverifiablePin)` |
    /// | rejected | unreadable, code claimed none | `.blocked(.untrustedWithoutPinnableKey)` |
    /// | rejected | **differs** | `.blocked(.untrustedAndPinMismatch)` |
    /// | transient / timeout / cancelled | unknown | `.unreachable` |
    static func decide(_ signals: PairingTrustProbeSignals) -> PairingTrustVerdict {
        let claimed = normalized(signals.payloadPinHex)
        let presented = normalized(signals.presentedFingerprintHex)

        // ORDINARY TRUST ACCEPTED THE CHAIN.
        if signals.requestCompleted {
            guard let claimed else {
                // No claim to contradict, and the system is satisfied. The
                // ordinary, overwhelmingly common case: Tailscale Funnel /
                // Cloudflare Tunnel / Let's Encrypt.
                return .useOrdinaryTrust
            }
            guard let presented else {
                return .blocked(.unverifiablePin)
            }
            return presented == claimed
                ? .useOrdinaryTrust
                : .blocked(.pinContradictsLiveServer)
        }

        // THE REQUEST DID NOT COMPLETE.
        switch signals.transportClass {
        case .untrustedCert:
            // The system genuinely rejected the presented cert — the self-signed
            // lane this app explicitly supports.
            //
            // ORDER MATTERS. The CLAIM is tested before the presented digest, so
            // an unverifiable claim is reported as `unverifiablePin` rather than
            // as "the code claimed nothing". Both fail closed, but they are
            // different sentences to the user with different remedies, and the
            // reason must match what actually happened.
            guard let claimed else {
                // No claim. A canonical self-signed code always carries one, so
                // this is refused rather than offered — see `untrustedWithoutClaim`.
                return .blocked(presented == nil
                    ? .untrustedWithoutPinnableKey
                    : .untrustedWithoutClaim)
            }
            guard let presented else {
                return .blocked(.unverifiablePin)
            }
            return presented == claimed
                ? .offerPinException(fingerprintHex: presented)
                : .blocked(.untrustedAndPinMismatch)

        case .certMismatch:
            // The evaluator actively cancelled on a pin mismatch. A pairing probe
            // runs UNPINNED, so this is not expected here — but if the signal ever
            // arrives, "the wire disagrees with the pin" is exactly what it means,
            // and the safe reading is the blocking one.
            return .blocked(.pinContradictsLiveServer)

        case .timeout:
            return .unreachable(.timeout)

        case .cancelled:
            return .unreachable(.cancelled)

        case .unreachable:
            return .unreachable(.unreachable)

        case nil:
            // Not a `URLError` at all — classify conservatively. Never a trust
            // verdict.
            return .unreachable(.unreachable)
        }
    }

    /// Lowercase, whitespace-trimmed, empty-as-absent. Mirrors the evaluator's
    /// defensive lowercase compare (`RemoteAgentTrustEvaluator.swift:435-438`) so
    /// a hand-pasted uppercase fingerprint never reads as a mismatch.
    private static func normalized(_ hex: String?) -> String? {
        guard let trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed.lowercased()
    }
}

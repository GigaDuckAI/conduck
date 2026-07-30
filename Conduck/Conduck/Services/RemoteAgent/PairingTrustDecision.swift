// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingTrustDecision.swift
//
// Trust policy for an INBOUND pairing code (`conduck-setup:` QR / paste).
// Pure decision logic — no networking, no persistence, no UI — so the whole
// table is unit-testable without a TLS fixture.
//
// WHY THIS EXISTS. A CERTIFICATE PIN IS AN ADDITIONAL RESTRICTION ON A
// CONNECTION THE SYSTEM ALREADY TRUSTS; it can never rescue an untrusted
// chain. App Transport Security lets an app TIGHTEN trust evaluation and
// refuses to let it loosen one, so a private-CA or self-signed certificate on
// a remote host fails at the transport layer even when an SPKI pin matches.
// A pairing code therefore has nothing useful to say about certificates, and
// this file exists to say what happens instead: the app asks the LIVE server,
// through this device's own trust store, and takes the answer as final.
//
// So a pairing import probes UNPINNED (`RemoteAgentClient.pairingTrustProbe`,
// `pinnedFingerprintHex: nil`) and reads the outcome — see
// `PairingTrustProbeSignals`. Nothing the code says enters the decision,
// because there is no field in the payload by which it could.
//
// THE AUTHORITATIVE PASS SIGNAL IS `requestCompleted`, NOT `systemTrustRejected`.
// The evaluator's `SecTrustEvaluateWithError` call is explicitly advisory, and
// ATS layers requirements ON TOP of trust-policy evaluation (TLS ≥ 1.2, forward
// secrecy, SHA-2). "The advisory check did not object" is therefore NOT proof
// the connection would be accepted; the request completing is.
//
// TRANSIENT IS NEVER A TRUST VERDICT. A cold tunnel produces a generic
// `.secureConnectionFailed` on a perfectly valid cert — the incident recorded in
// `RemoteAgentTrustEvaluator`. Those cases resolve to `.unreachable`, which the
// UI must present as "could not reach", never as a statement about the
// certificate.

import Foundation

/// What a single UNPINNED probe yields. Everything here is captured by
/// machinery that already exists; this struct only names it so the decision
/// below is a pure function of it.
///
/// IT CARRIES NO LEAF DIGEST, and that absence is the point: `decide(_:)` has no
/// certificate to compare and no way to grow one, so "the verdict comes from
/// this device's trust store alone" is a property of the type rather than a rule
/// a later change could quietly drop.
struct PairingTrustProbeSignals: Equatable, Sendable {

    /// The TLS handshake was accepted — i.e. an HTTP response came back at ANY
    /// status. A 401 or a 404 still proves ordinary trust accepted the chain,
    /// and this is the authoritative signal that it did (see the file header).
    ///
    /// CONTRACT FOR THE CALLER: this must be derived from whether a response was
    /// received, NOT from whether the probe "passed". `RemoteAgentClient`'s
    /// Test Connection surface throws on 401/404/5xx and on a wrong body envelope
    /// (`RemoteAgentClient+TestConnection.performTestConnection`) — all AFTER the
    /// handshake succeeded. Feeding it `false` in those cases would report a
    /// reachable, ordinarily-trusted server as unreachable. The pairing probe
    /// must therefore capture handshake completion at the transport boundary,
    /// before any status or body verdict is applied.
    let requestCompleted: Bool

    /// How the transport failed, when `requestCompleted == false`. Produced by
    /// `RemoteAgentTrustEvaluator.classifyTransportError(_:signals:)`,
    /// the app's single source of truth for telling a genuine certificate
    /// rejection apart from a transient handshake failure.
    ///
    /// `nil` alongside `requestCompleted == false` means the failure was not a
    /// `URLError` at all — classified conservatively as unreachable.
    let transportClass: RemoteAgentTrustEvaluator.TransportErrorClass?

    init(
        requestCompleted: Bool,
        transportClass: RemoteAgentTrustEvaluator.TransportErrorClass? = nil
    ) {
        self.requestCompleted = requestCompleted
        self.transportClass = transportClass
    }
}

/// Why an import was refused on trust grounds.
enum PairingTrustBlock: Equatable, Sendable {

    /// This device does not trust the server's certificate.
    ///
    /// TERMINAL, with no first-contact affordance of any kind. There is nothing
    /// the app could offer that would work: a pin cannot make an untrusted chain
    /// acceptable to the system, so a "trust it anyway" button would either lie
    /// or produce a gateway that fails every subsequent request. The remedy is on
    /// the SERVER — give it a certificate the device already trusts — and the
    /// UI's job is to name that, not to hint at a way around it.
    case certificateNotPubliclyTrusted
}

/// What the import should do about certificates, decided BEFORE anything is
/// persisted.
enum PairingTrustVerdict: Equatable, Sendable {

    /// The system accepts this server. **No pin is installed** — an import has
    /// no reason to start pinning a certificate that already validates, and
    /// doing so would break the gateway on ordinary certificate renewal.
    case useOrdinaryTrust

    /// Refuse the import on trust grounds.
    case blocked(PairingTrustBlock)

    /// The server could not be reached. NOT a statement about the certificate —
    /// the UI must not render this as a trust problem, and nothing may be
    /// persisted on the strength of it.
    case unreachable(RemoteAgentTrustEvaluator.TransportErrorClass)
}

enum PairingTrustDecision {

    /// The full table. Pure — same input, same verdict, no I/O.
    ///
    /// | unpinned probe result | verdict |
    /// |---|---|
    /// | handshake accepted | `.useOrdinaryTrust` (no pin stored) |
    /// | `.untrustedCert` | `.blocked(.certificateNotPubliclyTrusted)` |
    /// | anything else | `.unreachable(class)` |
    static func decide(_ signals: PairingTrustProbeSignals) -> PairingTrustVerdict {
        // The handshake completing is authoritative and outranks any leftover
        // classification: the system accepted this chain, which is the entire
        // question this probe asks.
        if signals.requestCompleted { return .useOrdinaryTrust }

        switch signals.transportClass {
        case .untrustedCert:
            return .blocked(.certificateNotPubliclyTrusted)

        case .certMismatch:
            // Unreachable by construction — the probe runs with no pin, so the
            // evaluator has nothing to mismatch against. If the signal ever does
            // arrive, degrading it to "could not reach" is the honest reading:
            // it is not evidence about a policy this import applies.
            return .unreachable(.certMismatch)

        case .certKeyUnpinnable:
            // Unreachable by construction for the same reason, and degraded the
            // same way: a pin that was never configured cannot have failed to
            // compute. It is emphatically not a trust verdict — the chain was
            // system-trusted in every path that produces this class.
            return .unreachable(.certKeyUnpinnable)

        case .timeout:
            return .unreachable(.timeout)

        case .cancelled:
            return .unreachable(.cancelled)

        case .unreachable, .notEstablished, .offline:
            // A pairing import only needs "could this device reach it?", so the
            // gateway lane's finer delivery-certainty split collapses here.
            return .unreachable(.unreachable)

        case nil:
            // Not a `URLError` at all — classify conservatively. Never a trust
            // verdict.
            return .unreachable(.unreachable)
        }
    }
}

// Conduck
// SettingsViewModel+PairingTrust.swift
//
// Resolves the certificate question for an inbound pairing code BEFORE anything
// is persisted, turning `PairingTrustDecision` from advice into the thing that
// actually decides what reaches storage.
//
// THE PROPERTY THIS FILE EXISTS TO CREATE: the fingerprint a scanned code claims
// NEVER reaches disk. `executePairingImport` no longer reads `payload.certFP`;
// it takes a RESOLVED pin — `nil` for ordinary trust, or the digest the server
// actually presented and the user explicitly accepted. A claim that was never
// checked against the wire cannot be stored by any path.
//
// PRIVACY: the probe carries the payload's token so a gateway that demands auth
// still completes a handshake, but the token is never logged, retained, or put
// into any returned value — the resolution carries fingerprints and verdicts only.

import Foundation

/// Which half of a pairing payload a trust verdict refers to. The two lanes can
/// be different hosts with different certificates, so they are resolved and
/// reported separately.
enum PairingTrustLane: Equatable, Sendable {
    case gateway
    case fileServer
}

/// What the import should do, decided before persistence.
enum PairingTrustResolution: Equatable {

    /// Nothing needs the user's consent. Persist with these pins — `nil` means
    /// ordinary system trust, which is also what a MATCHING claim resolves to
    /// (see `PairingTrustVerdict.useOrdinaryTrust`: a matching pin is proof, not
    /// a reason to start pinning).
    case proceed(gatewayPin: String?, fileServerPin: String?)

    /// At least one lane needs an explicit certificate exception. These are the
    /// exact pins that would be stored if the user accepts — nothing is written
    /// unless and until they do.
    case needsPinConsent(gatewayPin: String?, fileServerPin: String?, lanes: [PairingTrustLane])

    /// Refused on trust grounds. `override` is what "Connect anyway" would
    /// concretely do, or `nil` when no mechanism exists (see `PairingTrustOverride`).
    case blocked(lane: PairingTrustLane, block: PairingTrustBlock, override: PairingTrustOverride?)

    /// A lane carried a certificate claim that could not be checked because the
    /// server was unreachable. Deliberately NOT an import: persisting an
    /// unverified pin is the exact hole this work closes, and "try again when you
    /// can reach it" is both honest and cheap for someone holding the code.
    ///
    /// A lane with NO claim never lands here — nothing is unverified, so an
    /// unreachable server still imports exactly as it always has.
    case unverifiableWhileUnreachable(
        lane: PairingTrustLane,
        transportClass: RemoteAgentTrustEvaluator.TransportErrorClass
    )
}

extension SettingsViewModel {

    /// The file-server pin a payload CLAIMS, applying the inheritance rule: an
    /// explicit `fileServer.certFP` wins; otherwise, when the wizard declared a
    /// self-signed recipe AND the file server rides the same host as the gateway,
    /// the gateway's claim covers it too.
    ///
    /// Pulled out of `executePairingImport` so the value that gets CHECKED is
    /// provably the same value that would get STORED — computing it twice in two
    /// places is how a check and a write drift apart.
    static func claimedFileServerPin(for payload: PairingPayload) -> String? {
        guard let fileServer = payload.fileServer else { return nil }
        if let explicit = fileServer.certFP { return explicit }
        if payload.transport == .selfsigned, fileServer.url.host == payload.url.host {
            return payload.certFP
        }
        return nil
    }

    /// Probe both lanes UNPINNED and decide what may be persisted.
    ///
    /// Ordering is deliberate: the gateway is resolved first and its refusal
    /// short-circuits, because a gateway the user must not connect to makes the
    /// file lane moot — and asking about two certificates when the first one
    /// already disqualifies the import is noise.
    /// - Parameter acceptedOverrides: the EXACT override action the user accepted
    ///   for each lane, keyed by lane.
    ///
    ///   Keyed by the concrete `PairingTrustOverride`, not merely by lane, and
    ///   compared for equality below — because the probe is deliberately re-run,
    ///   and between the alert and the retry the server may present something
    ///   different. Accepting "keep ordinary trust, ignore the code's claim" must
    ///   never silently become "pin this newly-appeared untrusted key", and
    ///   accepting one presented key must never authorise a different one. When
    ///   the fresh observation disagrees with what was accepted, the lane blocks
    ///   again and the user is asked about what is actually there now.
    ///
    ///   Accumulating across calls is the caller's job — passing only the
    ///   most-recently-accepted lane would make two blocked lanes unresolvable,
    ///   each retry re-blocking the other.
    func resolvePairingTrust(
        _ payload: PairingPayload,
        acceptedOverrides: [PairingTrustLane: PairingTrustOverride] = [:]
    ) async -> PairingTrustResolution {
        // MARK: Gateway lane
        let gatewaySignals = await RemoteAgentClient.shared.pairingTrustProbe(
            url: payload.url,
            token: payload.token ?? "",
            authScheme: payload.authScheme,
            payloadPinHex: payload.certFP
        )
        let gatewayVerdict = PairingTrustDecision.decide(gatewaySignals)

        var gatewayPin: String?
        var consentLanes: [PairingTrustLane] = []

        switch gatewayVerdict {
        case .useOrdinaryTrust:
            gatewayPin = nil

        case .offerPinException(let fingerprintHex):
            gatewayPin = fingerprintHex
            consentLanes.append(.gateway)

        case .blocked(let block):
            let override = PairingTrustDecision.override(for: gatewayVerdict, signals: gatewaySignals)
            // Equality, not mere lane membership: what the user accepted must be
            // what is about to happen.
            guard let override, acceptedOverrides[.gateway] == override else {
                return .blocked(lane: .gateway, block: block, override: override)
            }
            // The user accepted "Connect anyway" for this lane. No separate pin
            // consent follows — that decision was the stronger one.
            gatewayPin = Self.pin(forAccepted: override)

        case .unreachable(let transportClass):
            // No claim → nothing is unverified → import as before. A claim →
            // refuse rather than store something unchecked.
            guard payload.certFP == nil else {
                return .unverifiableWhileUnreachable(lane: .gateway, transportClass: transportClass)
            }
            gatewayPin = nil
        }

        // MARK: File-server lane
        var fileServerPin: String?
        if let fileServer = payload.fileServer {
            let claim = Self.claimedFileServerPin(for: payload)
            // Probed with NO credential and at the root path: this asks only
            // whether the TLS handshake is accepted and by whom. A 401 from a
            // WebDAV root answers that perfectly well, and keeping the
            // file-server credential out of the probe keeps it out of one more
            // code path.
            let fileSignals = await RemoteAgentClient.shared.pairingTrustProbe(
                url: fileServer.url,
                token: "",
                authScheme: .none,
                payloadPinHex: claim,
                probePath: "/"
            )
            let fileVerdict = PairingTrustDecision.decide(fileSignals)

            switch fileVerdict {
            case .useOrdinaryTrust:
                fileServerPin = nil

            case .offerPinException(let fingerprintHex):
                fileServerPin = fingerprintHex
                consentLanes.append(.fileServer)

            case .blocked(let block):
                let override = PairingTrustDecision.override(for: fileVerdict, signals: fileSignals)
                guard let override, acceptedOverrides[.fileServer] == override else {
                    return .blocked(lane: .fileServer, block: block, override: override)
                }
                fileServerPin = Self.pin(forAccepted: override)

            case .unreachable(let transportClass):
                guard claim == nil else {
                    return .unverifiableWhileUnreachable(lane: .fileServer, transportClass: transportClass)
                }
                fileServerPin = nil
            }
        }

        return consentLanes.isEmpty
            ? .proceed(gatewayPin: gatewayPin, fileServerPin: fileServerPin)
            : .needsPinConsent(gatewayPin: gatewayPin, fileServerPin: fileServerPin, lanes: consentLanes)
    }

    /// Apply a user-accepted "Connect anyway" to a blocked lane, yielding the pin
    /// that lane should persist.
    ///
    /// `nil` return means "no pin" — which for `.proceedUnderOrdinaryTrust` is the
    /// whole point: ordinary trust already accepted the chain, so proceeding keeps
    /// full validation and merely disregards the code's contradictory claim.
    static func pin(forAccepted override: PairingTrustOverride) -> String? {
        switch override {
        case .proceedUnderOrdinaryTrust:
            return nil
        case .pinPresentedKey(let fingerprintHex):
            return fingerprintHex
        }
    }
}

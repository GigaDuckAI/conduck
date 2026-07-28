// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModel+PairingTrust.swift
//
// Resolves the certificate question for an inbound pairing code BEFORE anything
// is persisted, turning `PairingTrustDecision` from advice into the thing that
// actually decides what reaches storage.
//
// THE PROPERTY THIS FILE EXISTS TO CREATE: no certificate pin derived from a
// scanned code can reach disk. `executePairingImport` takes a RESOLVED pin, and
// the only value this resolver ever produces is `nil` — ordinary system trust.
// The parameter shape stays because it is what makes that provable at the call
// site rather than by reading the payload type.
//
// PRIVACY: the probe carries the payload's token so a gateway that demands auth
// still completes a handshake, but the token is never logged, retained, or put
// into any returned value — the resolution carries verdicts only.

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

    /// Persist with these pins. Both are always `nil` — ordinary system trust —
    /// because a pairing code names no key and a probe that succeeded proves the
    /// device already trusts the chain. They are passed explicitly rather than
    /// implied so `executePairingImport` reads its pins from a decision, never
    /// from a payload.
    case proceed(gatewayPin: String?, fileServerPin: String?)

    /// Refused on trust grounds. Terminal — `PairingTrustBlock` has no arm the
    /// app can proceed past, so no override is offered anywhere.
    case blocked(lane: PairingTrustLane, block: PairingTrustBlock)

    /// The resolution was abandoned between lanes (see the cancellation
    /// checkpoint below). It is never a reason to persist and never a statement
    /// about a server; the caller's generation guard normally discards it before
    /// it is read at all.
    case abandoned
}

extension SettingsViewModel {

    /// Probe both lanes UNPINNED and decide what may be persisted.
    ///
    /// Ordering is deliberate: the gateway is resolved first and its refusal
    /// short-circuits, because a gateway the user must not connect to makes the
    /// file lane moot — and reporting two certificate problems when the first one
    /// already disqualifies the import is noise.
    ///
    /// An UNREACHABLE lane proceeds. Nothing about the code needs checking
    /// against the server, so a server that is merely down imports exactly as it
    /// always has: the configuration saves, and the connectivity stage that runs
    /// afterwards is where the user learns it could not be reached, with the
    /// retry affordances that stage already owns.
    func resolvePairingTrust(_ payload: PairingPayload) async -> PairingTrustResolution {
        // MARK: Gateway lane
        let gatewaySignals = await RemoteAgentClient.shared.pairingTrustProbe(
            url: payload.url,
            token: payload.token ?? "",
            authScheme: payload.authScheme
        )

        switch PairingTrustDecision.decide(gatewaySignals) {
        case .useOrdinaryTrust, .unreachable:
            break
        case .blocked(let block):
            return .blocked(lane: .gateway, block: block)
        }

        // MARK: File-server lane
        //
        // Cancellation checkpoint. The caller's generation guard runs only after
        // this whole method returns, so without this an abandoned resolution
        // would finish the gateway probe and then open a SECOND connection to an
        // attacker-selected file host — after the user cancelled. Nothing would
        // be stored either way, but "cancel" has to mean the outbound work stops,
        // not merely that its result is discarded.
        if let fileServer = payload.fileServer {
            guard !Task.isCancelled else { return .abandoned }
            // Probed with NO credential and at the root path: this asks only
            // whether the TLS handshake is accepted and by whom. A 401 from a
            // WebDAV root answers that perfectly well, and keeping the
            // file-server credential out of the probe keeps it out of one more
            // code path.
            let fileSignals = await RemoteAgentClient.shared.pairingTrustProbe(
                url: fileServer.url,
                token: "",
                authScheme: .none,
                probePath: "/"
            )

            switch PairingTrustDecision.decide(fileSignals) {
            case .useOrdinaryTrust, .unreachable:
                break
            case .blocked(let block):
                return .blocked(lane: .fileServer, block: block)
            }
        }

        return .proceed(gatewayPin: nil, fileServerPin: nil)
    }
}

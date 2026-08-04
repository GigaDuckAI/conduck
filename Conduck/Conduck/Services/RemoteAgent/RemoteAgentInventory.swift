// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentInventory.swift
//
// One snapshot answering every "what state does this device hold for gateway X"
// question, produced by `SettingsManager.remoteAgentInventory()` in a single
// actor turn.
//
// It exists because two DIFFERENT questions were previously answered by one
// predicate:
//
//   • READINESS — "can this gateway send?" Drives the Diagnostics row and the
//     Personal AI list mark. A user-facing judgement about whether the gateway
//     works.
//   • REMOVABILITY — "would Forget erase anything?" Drives the editor's
//     destructive section. A storage fact about whether bytes exist.
//
// They are not the same set. Auxiliary residue (a transport hint, an
// image-history policy) makes a gateway removable without making its setup
// incomplete — offering Forget there is correct, claiming the gateway is broken
// is not. The one direction that MUST hold is
//
//     readiness == .incomplete  ⇒  hasRemovableState == true
//
// because the incomplete row tells the user to go remove it; a screen that says
// "fix this in Settings" while Settings offers no way to is the exact bug this
// split prevents. `RemoteAgentInventoryTests` locks that implication.

import Foundation

/// How far along a gateway's setup is ON THIS DEVICE.
///
/// Deliberately three states, not a `Bool`: "never touched" and "half set up"
/// look identical through a configured/not-configured lens, which is precisely
/// how a gateway holding a URL without its key stayed invisible in the Personal
/// AI list while Diagnostics warned about it.
enum RemoteAgentReadiness: String, Sendable, Equatable, CaseIterable {
    /// No evidence this device ever held setup for the gateway.
    case untouched
    /// Setup was attempted — but the gateway cannot send as it stands. Either
    /// a genuinely missing field, or a field that hasn't synced here yet, or a
    /// Keychain that could not be read this moment. Those are indistinguishable
    /// from storage, which is why the copy says "setup incomplete on this
    /// device" and never claims a specific field is missing.
    case incomplete
    /// Everything a send needs is present and readable here.
    case configured
}

/// One gateway's classification. Both fields come from the SAME slot reads, so
/// they can never describe adjacent moments.
struct RemoteAgentInventoryEntry: Sendable, Equatable {
    let ref: RemoteAgentRef
    let readiness: RemoteAgentReadiness
    /// Whether Forget would erase something — see the file header for why this
    /// is deliberately wider than `readiness != .untouched`.
    let hasRemovableState: Bool
}

/// Every gateway this device knows about: the built-ins plus the custom roster,
/// each classified once.
///
/// Ordering matches the queries this replaced — built-ins in
/// `RemoteAgentBackend.allCases` order first, then customs in roster order — so
/// the projections below are drop-in for callers that relied on it.
struct RemoteAgentInventory: Sendable, Equatable {
    /// The custom-gateway roster as read for this snapshot. Carried so callers
    /// can resolve display names and canonical ordinals WITHOUT a second actor
    /// hop that could observe a different roster.
    let customGateways: [CustomGateway]
    let entries: [RemoteAgentInventoryEntry]

    /// Send-able gateways, in the ordering described above.
    var configuredRefs: [RemoteAgentRef] {
        entries.filter { $0.readiness == .configured }.map(\.ref)
    }

    /// Gateways with setup evidence that cannot send as they stand.
    /// Disjoint from `configuredRefs` by construction — one classification pass
    /// produced both, so no ref can appear in each.
    var incompleteRefs: [RemoteAgentRef] {
        entries.filter { $0.readiness == .incomplete }.map(\.ref)
    }

    /// Refs holding anything Forget would erase.
    var removableRefs: Set<RemoteAgentRef> {
        Set(entries.filter(\.hasRemovableState).map(\.ref))
    }

    func entry(for ref: RemoteAgentRef) -> RemoteAgentInventoryEntry? {
        entries.first { $0.ref == ref }
    }

    /// Readiness of `ref`, defaulting to `.untouched` for a ref this snapshot
    /// never enumerated (a custom whose roster entry is gone).
    func readiness(for ref: RemoteAgentRef) -> RemoteAgentReadiness {
        entry(for: ref)?.readiness ?? .untouched
    }
}

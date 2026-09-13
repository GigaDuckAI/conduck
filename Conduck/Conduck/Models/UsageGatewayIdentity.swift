// SPDX-License-Identifier: Apache-2.0

// Usage resolves gateway names separately from its content-free attempt ledger.
// Live settings win; local retirement records supply a last known name only.
// A roster disappearing during sync is not proof the user removed a gateway.
// This projection is display-only: never feed its roster into routing or save it.

import Foundation

nonisolated struct UsageGatewayIdentity: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case removed
        case unavailable
    }

    let name: String
    var status: Status? = nil

    var statusText: String? {
        switch status {
        case .removed:
            String(localized: "settings.usage.gateway.removed", defaultValue: "removed")
        case .unavailable:
            String(localized: "settings.usage.gateway.unavailable", defaultValue: "unavailable")
        case nil:
            nil
        }
    }

    var label: String {
        guard let statusText else { return name }
        return String(localized: "settings.usage.gateway.statusLabel",
                      defaultValue: "\(name) (\(statusText))")
    }
}

nonisolated struct UsageGatewayIdentitySnapshot: Sendable {
    var live: [CustomGateway] = []
    var retired: [RetiredGatewayBadge] = []

    @MainActor
    func display(for key: String?) -> UsageGatewayIdentity {
        guard let key else {
            return UsageGatewayIdentity(name: String(
                localized: "settings.usage.gateway.unattributed", defaultValue: "Not recorded"))
        }
        guard let ref = RemoteAgentRef(rawString: key) else {
            return UsageGatewayIdentity(name: key)
        }
        switch ref {
        case .builtin:
            return UsageGatewayIdentity(name: RemoteAgentRefMetadata.displayName(for: ref, customs: []))
        case .custom(let id):
            if let gateway = live.first(where: { $0.id == id }) {
                return UsageGatewayIdentity(name: gateway.name)
            }
            let badge = retired.first { $0.id == id }
            let name = badge?.lastKnownName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return UsageGatewayIdentity(
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? RemoteAgentRefMetadata.genericCustomName,
                status: badge?.explicitlyRemovedAt == nil ? .unavailable : .removed)
        }
    }

    /// Existing Usage charts and thread rows accept a display roster. Keep
    /// their inputs consistent without changing the shared app badge resolver.
    @MainActor
    var roster: [CustomGateway] {
        let liveIDs = Set(live.map(\.id))
        return live + retired.filter { !liveIDs.contains($0.id) }.map { badge in
            CustomGateway(id: badge.id, name: display(for: badge.ref.rawString).label,
                          colorID: badge.colorID, monogram: badge.monogram)
        }
    }
}

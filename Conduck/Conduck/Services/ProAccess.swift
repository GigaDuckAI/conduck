// SPDX-License-Identifier: Apache-2.0

// Verified subscription access for synchronous storage admission. No entitlement
// is read from preferences or iCloud. A deadline is checked on every read, so a
// suspended app cannot keep granting unlimited access after its paid period.
// The observable StoreKit owner publishes verified evidence into this cache;
// tests inject independent snapshots into the domain stores.

import Foundation

nonisolated struct ProAccessSnapshot: Sendable, Equatable {
    let hasProAccess: Bool
    let hasExpiredSubscription: Bool

    init(hasProAccess: Bool = false, hasExpiredSubscription: Bool = false) {
        self.hasProAccess = hasProAccess
        self.hasExpiredSubscription = !hasProAccess && hasExpiredSubscription
    }
}

nonisolated struct ProEntitlementRecord: Sendable, Equatable {
    let productID: String
    let isVerified: Bool
    let isAutoRenewable: Bool
    let expirationDate: Date?
    var revocationDate: Date? = nil
    var isUpgraded = false
    var gracePeriodExpirationDate: Date? = nil
    // History alone is not a grant. A successful StoreKit status read can
    // explicitly remove eligibility even when the device clock is behind.
    var isEligibleForAccess = true
}

nonisolated struct ProEntitlementEvaluation: Sendable, Equatable {
    let hasPurchaseHistory: Bool
    let accessUntil: Date?

    func snapshot(at now: Date) -> ProAccessSnapshot {
        let active = accessUntil.map { $0 > now } ?? false
        return ProAccessSnapshot(hasProAccess: active, hasExpiredSubscription: hasPurchaseHistory && !active)
    }

    static func evaluate(_ records: [ProEntitlementRecord], productID: String, now: Date) -> Self {
        let verified = records.filter { $0.isVerified && $0.isAutoRenewable && $0.productID == productID }
        let deadline = verified.compactMap { record -> Date? in
            guard record.isEligibleForAccess, record.revocationDate == nil, !record.isUpgraded,
                  let expiration = record.expirationDate else { return nil }
            let end = max(expiration, record.gracePeriodExpirationDate ?? expiration)
            return end > now ? end : nil
        }.max()
        return Self(hasPurchaseHistory: !verified.isEmpty, accessUntil: deadline)
    }
}

nonisolated final class ProAccessCache: @unchecked Sendable {
    private let lock = NSLock()
    private var evaluation = ProEntitlementEvaluation(hasPurchaseHistory: false, accessUntil: nil)

    func snapshot(at now: Date = Date()) -> ProAccessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return evaluation.snapshot(at: now)
    }

    func update(_ value: ProEntitlementEvaluation) {
        lock.lock()
        defer { lock.unlock() }
        evaluation = value
    }
}

nonisolated enum ProAccess {
    private static let cache = ProAccessCache()
    static var current: ProAccessSnapshot { cache.snapshot() }
    static func update(_ value: ProEntitlementEvaluation) { cache.update(value) }
}

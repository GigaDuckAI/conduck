// SPDX-License-Identifier: Apache-2.0

// StoreKit owns payments and signed purchase history; this process owns access.
// Observers start once at launch, also covering purchases on another device and
// refunds. Foreground refresh and a bounded expiry timer reconcile a running app.
// Only signed transactions for this build's monthly product can grant access;
// signed renewal information extends that deadline during Apple's grace period.
// Product lookup failure never invents a price or an available purchase button.

import Foundation
import Observation
import StoreKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

nonisolated struct ProSubscriptionConfiguration: Sendable {
    let productID: String?

    static let current = Self(productID: validatedProductID(
        Bundle.main.object(forInfoDictionaryKey: "ConduckProMonthlyProductID") as? String
    ))

    static func validatedProductID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 255,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }) else { return nil }
        return value
    }
}

@MainActor @Observable
final class ProSubscriptionStore {
    static let shared = ProSubscriptionStore(loadsAccessOnDemand: liveAccessLoadingEnabled, publishAccess: ProAccess.update)

    private nonisolated static var liveAccessLoadingEnabled: Bool {
        #if CONDUCK_TESTING
        false
        #else
        true
        #endif
    }

    private(set) var access = ProAccessSnapshot()
    private(set) var product: Product?
    private(set) var isLoadingProduct = false
    private(set) var isRestoring = false
    private(set) var hasLoadedAccess = false
    private(set) var purchaseIsPending = false
    var message: String?

    var hasProAccess: Bool { access.hasProAccess }
    var hasExpiredSubscription: Bool { access.hasExpiredSubscription }
    var isConfigured: Bool { configuration.productID != nil }

    @ObservationIgnored let configuration: ProSubscriptionConfiguration
    @ObservationIgnored private let loadRecords: @Sendable (String) async throws -> [ProEntitlementRecord]
    @ObservationIgnored private let syncPurchases: @Sendable () async throws -> Void
    @ObservationIgnored private let loadsAccessOnDemand: Bool
    @ObservationIgnored private let publishAccess: @Sendable (ProEntitlementEvaluation) -> Void
    @ObservationIgnored private var evaluation = ProEntitlementEvaluation(hasPurchaseHistory: false, accessUntil: nil)
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var appliedGeneration: UInt64 = 0
    @ObservationIgnored private var appliedRefreshSucceeded = false
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var statusesTask: Task<Void, Never>?
    @ObservationIgnored private var expirationTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var initialRefresh: Task<Void, Never>?
    @ObservationIgnored private var initialAccessWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: ProSubscriptionConfiguration = .current,
         loadRecords: @escaping @Sendable (String) async throws -> [ProEntitlementRecord] = ProSubscriptionStore.verifiedRecords,
         syncPurchases: @escaping @Sendable () async throws -> Void = { try await AppStore.sync() },
         loadsAccessOnDemand: Bool = true,
         publishAccess: @escaping @Sendable (ProEntitlementEvaluation) -> Void = { _ in }) {
        self.configuration = configuration
        self.loadRecords = loadRecords
        self.syncPurchases = syncPurchases
        self.loadsAccessOnDemand = loadsAccessOnDemand
        self.publishAccess = publishAccess
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        #if CONDUCK_TESTING
        // Test hosts never contact the App Store or inherit real purchases.
        return
        #else
        guard isConfigured else { hasLoadedAccess = true; return }
        #if os(iOS)
        let foregroundNotification = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let foregroundNotification = NSApplication.didBecomeActiveNotification
        #endif
        #if os(iOS) || os(macOS)
        foregroundObserver = NotificationCenter.default.addObserver(forName: foregroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        #endif
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self, !Task.isCancelled else { return }
                guard case .verified(let transaction) = result,
                      transaction.productID == self.configuration.productID else { continue }
                await self.refresh()
                await transaction.finish()
            }
        }
        statusesTask = Task { [weak self] in
            for await status in Product.SubscriptionInfo.Status.updates {
                guard let self, !Task.isCancelled else { return }
                guard case .verified(let transaction) = status.transaction,
                      transaction.productID == self.configuration.productID else { continue }
                await self.refresh()
            }
        }
        Task { [weak self] in await self?.awaitInitialAccess() }
        #endif
    }

    /// Async send preparation waits for the first signed entitlement read;
    /// synchronous storage still fails closed until that read has completed.
    func awaitInitialAccess() async {
        guard loadsAccessOnDemand else { return }
        guard isConfigured else { hasLoadedAccess = true; return }
        guard !hasLoadedAccess else { return }
        await withCheckedContinuation { continuation in
            initialAccessWaiters.append(continuation)
            if initialRefresh == nil {
                initialRefresh = Task { [weak self] in await self?.refresh() }
            }
        }
    }

    func refresh() async {
        guard let productID = configuration.productID else { hasLoadedAccess = true; return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        var succeeded = false
        do {
            let records = try await loadRecords(productID)
            guard generation == refreshGeneration else { return }
            let result = ProEntitlementEvaluation.evaluate(records, productID: productID, now: Date())
            // Losing a verifiable record cannot turn an expired subscriber into
            // an unrestricted pre-subscription import. This is process-local
            // history only and can never grant access.
            evaluation = ProEntitlementEvaluation(
                hasPurchaseHistory: result.hasPurchaseHistory || evaluation.hasPurchaseHistory,
                accessUntil: result.accessUntil
            )
            succeeded = true
            publishCurrentAccess()
        } catch {
            guard generation == refreshGeneration else { return }
            // A network failure cannot extend a signed deadline, or invalidate
            // the still-valid signed period already verified in this process.
            publishCurrentAccess()
        }
        hasLoadedAccess = true
        appliedRefreshSucceeded = succeeded
        appliedGeneration = generation
        let waiters = initialAccessWaiters
        initialAccessWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let pendingRefreshes = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in pendingRefreshes { waiter.resume() }
    }

    /// Restore and purchase completion must not interpret a discarded older
    /// request as proof that the account has no current entitlement.
    @discardableResult
    func refreshAndWaitUntilApplied() async -> Bool {
        await refresh()
        if appliedGeneration != refreshGeneration {
            await withCheckedContinuation { refreshWaiters.append($0) }
        }
        return appliedRefreshSucceeded
    }

    func loadProduct() async {
        guard let productID = configuration.productID, !isLoadingProduct else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            let products = try await Product.products(for: [productID])
            product = products.first { candidate in
                guard candidate.id == productID, candidate.type == .autoRenewable,
                      let period = candidate.subscription?.subscriptionPeriod else { return false }
                return period.value == 1 && period.unit == .month
            }
            if product == nil { message = String(localized: "pro.store.unavailable", defaultValue: "Subscriptions are unavailable right now. Please try again later.") }
        } catch {
            product = nil
            message = String(localized: "pro.store.unavailable", defaultValue: "Subscriptions are unavailable right now. Please try again later.")
        }
    }

    func restorePurchases() async {
        guard !isRestoring else { return }
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        do {
            try await syncPurchases()
            let didVerifyAccess = await refreshAndWaitUntilApplied()
            if !hasProAccess {
                message = didVerifyAccess
                    ? String(localized: "pro.restore.none", defaultValue: "No active Conduck Pro subscription was found for this Apple Account.")
                    : String(localized: "pro.restore.unavailable", defaultValue: "Your subscription could not be checked. Please try again.")
            }
        } catch StoreKitError.userCancelled {
            // Cancellation returns to the offer without an error accusation.
        } catch {
            message = String(localized: "pro.restore.failed", defaultValue: "Purchases could not be restored. Please try again.")
        }
    }

    func purchaseCompleted(product: Product, result: Result<Product.PurchaseResult, any Error>) async {
        guard product.id == configuration.productID else { return }
        message = nil
        switch result {
        case .success(.success(let verification)):
            guard case .verified(let transaction) = verification,
                  transaction.productID == configuration.productID,
                  transaction.productType == .autoRenewable else {
                message = String(localized: "pro.purchase.unverified", defaultValue: "Apple could not verify this purchase. Try Restore Purchases before purchasing again.")
                return
            }
            purchaseIsPending = false
            await refreshAndWaitUntilApplied()
            await transaction.finish()
            if !hasProAccess {
                message = String(localized: "pro.purchase.checking", defaultValue: "Your purchase is being checked. Try Restore Purchases if access does not appear.")
            }
        case .success(.pending):
            purchaseIsPending = true
            message = String(localized: "pro.purchase.pending", defaultValue: "Your purchase is awaiting approval. Pro will become available when Apple confirms it.")
        case .success(.userCancelled): break
        case .failure(let error):
            if case StoreKitError.userCancelled = error { return }
            message = String(localized: "pro.purchase.failed", defaultValue: "The purchase could not be completed. Please try again.")
        @unknown default: break
        }
    }

    private func publishCurrentAccess() {
        let previous = access
        access = evaluation.snapshot(at: Date())
        publishAccess(evaluation)
        if access != previous {
            NotificationCenter.default.post(name: .settingsDidChangeRemotely, object: nil)
        }
        if access.hasProAccess { purchaseIsPending = false; message = nil }
        expirationTask?.cancel()
        guard let deadline = evaluation.accessUntil, deadline > Date() else { return }
        let delay = min(max(deadline.timeIntervalSinceNow, 0.05), 86_400)
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // The firing timer is no longer a pending timer. Publishing may
            // cancel/reschedule the next timer, never this reconciliation task.
            self.expirationTask = nil
            self.publishCurrentAccess()
            await self.refresh()
        }
    }

    private nonisolated static func verifiedRecords(productID: String) async throws -> [ProEntitlementRecord] {
        var records: [UInt64: ProEntitlementRecord] = [:]
        var groupID: String?
        func record(_ transaction: StoreKit.Transaction) -> ProEntitlementRecord {
            ProEntitlementRecord(productID: transaction.productID, isVerified: true,
                isAutoRenewable: transaction.productType == .autoRenewable,
                expirationDate: transaction.expirationDate, revocationDate: transaction.revocationDate,
                isUpgraded: transaction.isUpgraded)
        }
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == productID else { continue }
            records[transaction.id] = record(transaction)
            groupID = transaction.subscriptionGroupID
        }
        if case .verified(let transaction) = await StoreKit.Transaction.latest(for: productID) {
            var value = record(transaction)
            // latest(for:) supplies purchase history, including expired
            // transactions. Only current entitlement or successful status
            // evidence may make that historical transaction a grant.
            value.isEligibleForAccess = records[transaction.id]?.isEligibleForAccess ?? false
            records[transaction.id] = value
            groupID = transaction.subscriptionGroupID
        }
        if let groupID {
            let statuses: [Product.SubscriptionInfo.Status]
            do { statuses = try await Product.SubscriptionInfo.status(for: groupID) }
            catch {
                return try Self.recordsAfterStatusFailure(Array(records.values), now: Date())
            }
            for status in statuses {
                guard case .verified(let transaction) = status.transaction, transaction.productID == productID else { continue }
                var verifiedGraceDeadline: Date?
                if case .verified(let renewal) = status.renewalInfo {
                    verifiedGraceDeadline = renewal.gracePeriodExpirationDate
                }
                var value = Self.applyingSubscriptionStatus(status.state, to: record(transaction),
                    verifiedGracePeriodExpirationDate: verifiedGraceDeadline)
                if status.state == .revoked { value.revocationDate = transaction.revocationDate ?? Date() }
                records[transaction.id] = value
            }
        }
        return Array(records.values)
    }

    /// A successful status read wins over historical date evidence. In
    /// particular, a locally slow clock cannot resurrect expired or retry-only
    /// subscriptions. Unknown future states also carry history without access.
    nonisolated static func applyingSubscriptionStatus(_ state: Product.SubscriptionInfo.RenewalState,
        to record: ProEntitlementRecord, verifiedGracePeriodExpirationDate: Date? = nil) -> ProEntitlementRecord {
        var value = record
        value.isEligibleForAccess = state == .subscribed || state == .inGracePeriod
        value.gracePeriodExpirationDate = state == .inGracePeriod ? verifiedGracePeriodExpirationDate : nil
        return value
    }

    /// Missing renewal status cannot overwrite a still-valid signed grace
    /// deadline in the observable owner. A verified revocation must still be
    /// delivered, and an ordinary future paid period needs no grace extension.
    nonisolated static func recordsAfterStatusFailure(_ records: [ProEntitlementRecord], now: Date) throws -> [ProEntitlementRecord] {
        let verified = records.filter { $0.isVerified && $0.isAutoRenewable }
        if verified.contains(where: { $0.revocationDate != nil }) { return records }
        let eligible = verified.filter(\.isEligibleForAccess)
        if eligible.contains(where: { !$0.isUpgraded && ($0.expirationDate ?? .distantPast) > now }) { return records }
        if !eligible.isEmpty { throw URLError(.cannotLoadFromNetwork) }
        return records
    }
}

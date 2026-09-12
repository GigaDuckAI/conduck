// SPDX-License-Identifier: Apache-2.0

// Signed-evidence reduction and storage-cache boundaries. Fixtures never
// contact Apple, grant production access, or read a real preferences domain.

import XCTest
import StoreKit
@testable import Conduck

final class ProEntitlementTests: XCTestCase {
    private let productID = "com.example.conduck.pro.monthly"
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func record(expiration: Date? = nil) -> ProEntitlementRecord {
        ProEntitlementRecord(productID: productID, isVerified: true, isAutoRenewable: true,
                             expirationDate: expiration ?? now.addingTimeInterval(100))
    }

    func testFreeAndUnverifiedNeverGrantAccess() {
        let unverified = ProEntitlementRecord(productID: productID, isVerified: false,
            isAutoRenewable: true, expirationDate: now.addingTimeInterval(100))
        for values in [[], [unverified]] {
            let result = ProEntitlementEvaluation.evaluate(values, productID: productID, now: now)
            XCTAssertEqual(result.snapshot(at: now), ProAccessSnapshot())
        }
    }

    func testUnrelatedProductAndWrongProductTypeNeverGrantAccess() {
        let unrelated = ProEntitlementRecord(productID: "another.plan", isVerified: true,
            isAutoRenewable: true, expirationDate: now.addingTimeInterval(100))
        let consumable = ProEntitlementRecord(productID: productID, isVerified: true,
            isAutoRenewable: false, expirationDate: now.addingTimeInterval(100))
        let result = ProEntitlementEvaluation.evaluate([unrelated, consumable], productID: productID, now: now)
        XCTAssertEqual(result.snapshot(at: now), ProAccessSnapshot())
    }

    func testPaidAccessEndsAtExactSignedDeadline() {
        let result = ProEntitlementEvaluation.evaluate([record()], productID: productID, now: now)
        XCTAssertTrue(result.snapshot(at: now).hasProAccess)
        XCTAssertFalse(result.snapshot(at: now).hasExpiredSubscription)
        XCTAssertEqual(result.snapshot(at: now.addingTimeInterval(100)), ProAccessSnapshot(hasExpiredSubscription: true))
    }

    func testExpiredHistoryRequiresFreeSelectionWithoutGrantingAccess() {
        let result = ProEntitlementEvaluation.evaluate([record(expiration: now.addingTimeInterval(-1))], productID: productID, now: now)
        XCTAssertEqual(result.snapshot(at: now), ProAccessSnapshot(hasExpiredSubscription: true))
    }

    func testRevocationWinsOverFutureExpiryAndGrace() {
        var value = record()
        value.revocationDate = now
        value.gracePeriodExpirationDate = now.addingTimeInterval(500)
        let result = ProEntitlementEvaluation.evaluate([value], productID: productID, now: now)
        XCTAssertFalse(result.snapshot(at: now).hasProAccess)
        XCTAssertTrue(result.snapshot(at: now).hasExpiredSubscription)
    }

    func testSupersededTransactionDoesNotGrantAccess() {
        var value = record()
        value.isUpgraded = true
        XCTAssertFalse(ProEntitlementEvaluation.evaluate([value], productID: productID, now: now).snapshot(at: now).hasProAccess)
    }

    func testSignedGracePeriodHasItsOwnDeadline() {
        var value = record(expiration: now.addingTimeInterval(-5))
        value.gracePeriodExpirationDate = now.addingTimeInterval(50)
        let result = ProEntitlementEvaluation.evaluate([value], productID: productID, now: now)
        XCTAssertTrue(result.snapshot(at: now).hasProAccess)
        XCTAssertFalse(result.snapshot(at: now.addingTimeInterval(50)).hasProAccess)
    }

    func testMissingExpirationCannotBecomeLifetimeAccess() {
        let value = ProEntitlementRecord(productID: productID, isVerified: true, isAutoRenewable: true, expirationDate: nil)
        XCTAssertFalse(ProEntitlementEvaluation.evaluate([value], productID: productID, now: now).snapshot(at: now).hasProAccess)
    }

    func testHistoricalTransactionCannotGrantWhenTheLocalClockIsBeforeItsExpiry() {
        var value = record()
        value.isEligibleForAccess = false
        let result = ProEntitlementEvaluation.evaluate([value], productID: productID, now: now)
        XCTAssertEqual(result.snapshot(at: now), ProAccessSnapshot(hasExpiredSubscription: true))
    }

    func testInactiveStatusOverridesLocallyFutureExpiryAndPreviouslyVerifiedGrace() {
        var value = record()
        value.gracePeriodExpirationDate = now.addingTimeInterval(500)
        for state in [Product.SubscriptionInfo.RenewalState.expired, .inBillingRetryPeriod, .revoked] {
            let inactive = ProSubscriptionStore.applyingSubscriptionStatus(state, to: value,
                verifiedGracePeriodExpirationDate: now.addingTimeInterval(500))
            let result = ProEntitlementEvaluation.evaluate([inactive], productID: productID, now: now)
            XCTAssertEqual(result.snapshot(at: now), ProAccessSnapshot(hasExpiredSubscription: true))
        }
    }

    func testEntitledStatusesKeepOnlyTheirSignedAccessDeadlines() {
        let subscribed = ProSubscriptionStore.applyingSubscriptionStatus(.subscribed, to: record(),
            verifiedGracePeriodExpirationDate: now.addingTimeInterval(500))
        let paid = ProEntitlementEvaluation.evaluate([subscribed], productID: productID, now: now)
        XCTAssertTrue(paid.snapshot(at: now).hasProAccess)
        XCTAssertFalse(paid.snapshot(at: now.addingTimeInterval(100)).hasProAccess)

        let expired = record(expiration: now.addingTimeInterval(-5))
        let grace = ProSubscriptionStore.applyingSubscriptionStatus(.inGracePeriod, to: expired,
            verifiedGracePeriodExpirationDate: now.addingTimeInterval(50))
        let graceAccess = ProEntitlementEvaluation.evaluate([grace], productID: productID, now: now)
        XCTAssertTrue(graceAccess.snapshot(at: now).hasProAccess)
        XCTAssertFalse(graceAccess.snapshot(at: now.addingTimeInterval(50)).hasProAccess)

        let unsignedGrace = ProSubscriptionStore.applyingSubscriptionStatus(.inGracePeriod, to: expired)
        XCTAssertFalse(ProEntitlementEvaluation.evaluate([unsignedGrace], productID: productID, now: now).snapshot(at: now).hasProAccess)
    }

    func testFailedStatusReadDoesNotTurnHistoricalOnlyEvidenceIntoAnOfflineGrant() throws {
        var history = record()
        history.isEligibleForAccess = false
        let values = try ProSubscriptionStore.recordsAfterStatusFailure([history], now: now)
        XCTAssertEqual(ProEntitlementEvaluation.evaluate(values, productID: productID, now: now).snapshot(at: now),
                       ProAccessSnapshot(hasExpiredSubscription: true))
    }

    func testStorageCacheRechecksTimeWithoutObservableRefresh() {
        let cache = ProAccessCache()
        cache.update(.evaluate([record()], productID: productID, now: now))
        XCTAssertTrue(cache.snapshot(at: now).hasProAccess)
        XCTAssertTrue(cache.snapshot(at: now.addingTimeInterval(101)).hasExpiredSubscription)
        cache.update(.init(hasPurchaseHistory: false, accessUntil: nil))
        XCTAssertEqual(cache.snapshot(at: now), ProAccessSnapshot())
    }

    func testOnlyValidBuildConfiguredProductIdentifiersAreAccepted() {
        for value in [nil, "", "$(CONDUCK_PRO_MONTHLY_PRODUCT_ID)", " a.plan", "https://store.example/plan", String(repeating: "x", count: 256)] {
            XCTAssertNil(ProSubscriptionConfiguration.validatedProductID(value))
        }
        XCTAssertEqual(ProSubscriptionConfiguration.validatedProductID(productID), productID)
    }
}

@MainActor
final class ProSubscriptionStoreTests: XCTestCase {
    private let productID = "com.example.conduck.pro.monthly"

    func testRefreshPublishesOnlyVerifiedMatchingAccess() async {
        let id = productID
        let record = ProEntitlementRecord(productID: id, isVerified: true, isAutoRenewable: true,
                                         expirationDate: Date().addingTimeInterval(3600))
        let cache = ProAccessCache()
        let store = ProSubscriptionStore(configuration: .init(productID: id),
            loadRecords: { _ in [record] }, publishAccess: cache.update)
        await store.refresh()
        XCTAssertTrue(store.hasLoadedAccess)
        XCTAssertTrue(store.hasProAccess)
        XCTAssertTrue(cache.snapshot().hasProAccess)
    }

    func testUnconfiguredBuildDoesNotCallPurchaseLoader() async {
        let store = ProSubscriptionStore(configuration: .init(productID: nil), loadRecords: { _ in
            XCTFail("An unconfigured distribution must not query another app's products")
            return []
        })
        await store.refresh()
        XCTAssertTrue(store.hasLoadedAccess)
        XCTAssertFalse(store.hasProAccess)
    }

    func testRefreshFailureNeverCreatesPaidAccess() async {
        let store = ProSubscriptionStore(configuration: .init(productID: productID), loadRecords: { _ in throw URLError(.notConnectedToInternet) })
        await store.refresh()
        XCTAssertFalse(store.hasProAccess)
        XCTAssertFalse(store.hasExpiredSubscription)
    }

    func testRevokedRefreshRemovesActiveGrant() async {
        let loader = EvidenceQueue(productID: productID)
        let store = ProSubscriptionStore(configuration: .init(productID: productID), loadRecords: { _ in await loader.next() })
        await store.refresh()
        XCTAssertTrue(store.hasProAccess)
        await store.refresh()
        XCTAssertFalse(store.hasProAccess)
        XCTAssertTrue(store.hasExpiredSubscription)
    }

    func testAnOlderRefreshCannotOverwriteNewerRevocation() async {
        let loader = SuspendedEvidence(productID: productID)
        let store = ProSubscriptionStore(configuration: .init(productID: productID), loadRecords: { _ in await loader.next() })
        let first = Task { await store.refresh() }
        await loader.awaitFirstRequest()
        await store.refresh()
        XCTAssertTrue(store.hasExpiredSubscription)
        await loader.releaseFirst()
        await first.value
        XCTAssertFalse(store.hasProAccess)
        XCTAssertTrue(store.hasExpiredSubscription)
    }

    func testInitialAccessWaitsForTheAppliedRefreshWhenForegroundSupersedesIt() async throws {
        let script = InitialAccessRace(productID: productID)
        let store = ProSubscriptionStore(configuration: .init(productID: productID), loadRecords: { _ in await script.next() })
        var resumed = false
        let first = Task { await store.awaitInitialAccess(); resumed = true }
        await script.waitForRequests(1)
        let foreground = Task { await store.refresh() }
        await script.waitForRequests(2)
        await script.release(1)
        // Give the stale request's waiting task an opportunity to resume. The
        // barrier must still be held while the authoritative response is held.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(resumed)
        XCTAssertFalse(store.hasLoadedAccess)
        await script.release(2)
        await foreground.value
        await first.value
        XCTAssertTrue(resumed)
        XCTAssertTrue(store.hasLoadedAccess)
        XCTAssertTrue(store.hasProAccess)
    }

    func testStatusFetchFailurePreservesVerifiedGraceButRevocationStillWins() async {
        let script = GraceStatusFailure(productID: productID)
        let cache = ProAccessCache()
        let store = ProSubscriptionStore(configuration: .init(productID: productID),
            loadRecords: { _ in try await script.next() }, publishAccess: cache.update)
        await store.refresh()
        XCTAssertTrue(store.hasProAccess)
        await store.refresh()
        XCTAssertTrue(store.hasProAccess)
        XCTAssertTrue(cache.snapshot().hasProAccess)
        await store.refresh()
        XCTAssertFalse(store.hasProAccess)
        XCTAssertTrue(store.hasExpiredSubscription)
    }

    func testExpiryTimerDoesNotCancelItsOwnRenewalRefresh() async {
        let called = expectation(description: "timer refreshed")
        let script = TimerEvidence(productID: productID)
        let store = ProSubscriptionStore(configuration: .init(productID: productID),
            loadRecords: { _ in await script.next() }, publishAccess: { value in
                if (value.accessUntil ?? .distantPast) > Date().addingTimeInterval(60) { called.fulfill() }
            })
        await store.refresh()
        await fulfillment(of: [called], timeout: 2)
        let cancelled = await script.wasCancelled
        XCTAssertFalse(cancelled)
        XCTAssertTrue(store.hasProAccess)
    }

    func testCompletionBarrierWaitsForNewerRefreshAndClearsObsoleteMessage() async throws {
        let script = InitialAccessRace(productID: productID)
        let store = ProSubscriptionStore(configuration: .init(productID: productID), loadRecords: { _ in await script.next() })
        store.message = "Earlier restore result"
        var resumed = false
        let completion = Task { await store.refreshAndWaitUntilApplied(); resumed = true }
        await script.waitForRequests(1)
        let foreground = Task { await store.refresh() }
        await script.waitForRequests(2)
        await script.release(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(resumed)
        await script.release(2)
        await foreground.value
        await completion.value
        XCTAssertTrue(resumed)
        XCTAssertTrue(store.hasProAccess)
        XCTAssertNil(store.message)
    }

    func testRestoreDistinguishesAnUnreadableStatusFromVerifiedAbsence() async {
        let store = ProSubscriptionStore(configuration: .init(productID: productID),
            loadRecords: { _ in throw URLError(.cannotLoadFromNetwork) }, syncPurchases: {})
        await store.restorePurchases()
        XCTAssertFalse(store.hasProAccess)
        XCTAssertFalse(store.isRestoring)
        XCTAssertEqual(store.message, String(localized: "pro.restore.unavailable",
            defaultValue: "Your subscription could not be checked. Please try again."))

        let absent = ProSubscriptionStore(configuration: .init(productID: productID),
            loadRecords: { _ in [] }, syncPurchases: {})
        await absent.restorePurchases()
        XCTAssertEqual(absent.message, String(localized: "pro.restore.none",
            defaultValue: "No active Conduck Pro subscription was found for this Apple Account."))
    }

    func testRestoreUsesAppliedRefreshOutcomeWhenAnotherReadSupersedesIt() async throws {
        for latestReadFails in [false, true] {
            let script = RestoreOutcomeRace()
            let store = ProSubscriptionStore(configuration: .init(productID: productID),
                loadRecords: { _ in try await script.next() }, syncPurchases: {})
            let restore = Task { await store.restorePurchases() }
            await script.waitForRequests(1)
            let foreground = Task { await store.refresh() }
            await script.waitForRequests(2)
            await script.release(1, fails: !latestReadFails)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(store.isRestoring)
            XCTAssertNil(store.message)
            await script.release(2, fails: latestReadFails)
            await foreground.value
            await restore.value
            let expected = latestReadFails
                ? String(localized: "pro.restore.unavailable", defaultValue: "Your subscription could not be checked. Please try again.")
                : String(localized: "pro.restore.none", defaultValue: "No active Conduck Pro subscription was found for this Apple Account.")
            XCTAssertEqual(store.message, expected)
            XCTAssertFalse(store.isRestoring)
        }
    }
}

private actor RestoreOutcomeRace {
    private var count = 0
    private var responses: [Int: CheckedContinuation<[ProEntitlementRecord], any Error>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func next() async throws -> [ProEntitlementRecord] {
        count += 1
        let request = count
        return try await withCheckedThrowingContinuation { continuation in
            responses[request] = continuation
            let ready = requestWaiters.filter { $0.0 <= count }
            requestWaiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if self.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func release(_ request: Int, fails: Bool) {
        guard let continuation = responses.removeValue(forKey: request) else { return }
        if fails { continuation.resume(throwing: URLError(.cannotLoadFromNetwork)) }
        else { continuation.resume(returning: []) }
    }
}

private actor TimerEvidence {
    let productID: String
    private var count = 0
    private(set) var wasCancelled = false
    init(productID: String) { self.productID = productID }
    func next() -> [ProEntitlementRecord] {
        count += 1
        if count > 1 { wasCancelled = Task.isCancelled }
        return [ProEntitlementRecord(productID: productID, isVerified: true, isAutoRenewable: true,
            expirationDate: Date().addingTimeInterval(count == 1 ? 0.08 : 3600))]
    }
}

private actor GraceStatusFailure {
    let productID: String
    private var count = 0
    init(productID: String) { self.productID = productID }
    func next() throws -> [ProEntitlementRecord] {
        count += 1
        let now = Date()
        var record = ProEntitlementRecord(productID: productID, isVerified: true, isAutoRenewable: true,
            expirationDate: now.addingTimeInterval(-60))
        if count == 1 {
            record.gracePeriodExpirationDate = now.addingTimeInterval(3600)
            return [record]
        }
        if count > 2 { record.revocationDate = now }
        // This is the exact fallback called when Apple's renewal-status read
        // fails after the production loader has verified its transactions.
        return try ProSubscriptionStore.recordsAfterStatusFailure([record], now: now)
    }
}

private actor InitialAccessRace {
    let productID: String
    private var count = 0
    private var responses: [Int: CheckedContinuation<[ProEntitlementRecord], Never>] = [:]
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(productID: String) { self.productID = productID }
    func next() async -> [ProEntitlementRecord] {
        count += 1
        let number = count
        return await withCheckedContinuation { continuation in
            responses[number] = continuation
            let ready = requestWaiters.filter { $0.0 <= count }
            requestWaiters.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRequests(_ number: Int) async {
        if count >= number { return }
        await withCheckedContinuation { requestWaiters.append((number, $0)) }
    }
    func release(_ number: Int) {
        responses.removeValue(forKey: number)?.resume(returning: [
            ProEntitlementRecord(productID: productID, isVerified: true, isAutoRenewable: true,
                expirationDate: Date().addingTimeInterval(3600))
        ])
    }
}

private actor EvidenceQueue {
    let productID: String
    private var count = 0
    init(productID: String) { self.productID = productID }
    func next() -> [ProEntitlementRecord] {
        count += 1
        return [ProEntitlementRecord(productID: productID, isVerified: true, isAutoRenewable: true,
            expirationDate: Date().addingTimeInterval(3600), revocationDate: count > 1 ? Date() : nil)]
    }
}

private actor SuspendedEvidence {
    let productID: String
    private var continuation: CheckedContinuation<[ProEntitlementRecord], Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var count = 0
    init(productID: String) { self.productID = productID }
    func next() async -> [ProEntitlementRecord] {
        count += 1
        if count == 1 {
            return await withCheckedContinuation { value in
                continuation = value
                started?.resume(); started = nil
            }
        }
        return [ProEntitlementRecord(productID: productID, isVerified: true, isAutoRenewable: true,
            expirationDate: Date().addingTimeInterval(-1))]
    }
    func awaitFirstRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseFirst() {
        continuation?.resume(returning: [ProEntitlementRecord(productID: productID, isVerified: true,
            isAutoRenewable: true, expirationDate: Date().addingTimeInterval(3600))])
        continuation = nil
    }
}

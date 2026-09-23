// SPDX-License-Identifier: Apache-2.0

// Apple's local StoreKit test session supplies real StoreKit transaction and
// product objects with simulated money. The production verifier reads them;
// no subscription singleton, real account or production entitlement is used.
//
// Runtime quirks these cases are written around (measured on the iOS 27.0
// simulator): `Product.price` truncates the fixture's 29.99 to 29 while
// `displayPrice` stays "$29.99", so the price is asserted through the string
// StoreKit shows the buyer; and `expireSubscription(productIdentifier:)` is a
// no-op (renewal status stays subscribed, expiry date unchanged), so expiry is
// driven by an accelerated renewal clock with auto-renew turned off. Session
// mutations reach StoreKit asynchronously, so state is polled with a deadline
// instead of read once.

import XCTest
import StoreKit
import StoreKitTest
@testable import Conduck

@MainActor
final class ProStoreKitIntegrationTests: XCTestCase {
    private let productID = "com.example.conduck.pro.monthly"

    private func session() throws -> SKTestSession {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "ConduckPro", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        guard session.disableDialogs else {
            // Some simulator runtimes reject SKTestSession configuration
            // mutations (SKInternalErrorDomain 3) outside an IDE debug session.
            // Probe the read-back instead of the OS version, so a runtime that
            // works always runs these cases and one that doesn't never reaches
            // an empty product list or a real Apple Account prompt.
            throw XCTSkip("The StoreKit test service rejected the local configuration (disableDialogs did not persist). Run these cases from an Xcode StoreKit debug session before release.")
        }
        session.timeRate = .realTime
        session.clearTransactions()
        return session
    }

    /// Refreshes until the store reaches the expected state or the deadline
    /// passes. A verifier that never reaches it still fails, with the state it
    /// was left in.
    private func waitForAccess(_ store: ProSubscriptionStore, hasAccess: Bool, expired: Bool,
                               timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            await store.refresh()
            if store.hasProAccess == hasAccess && store.hasExpiredSubscription == expired { return }
            guard Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("Expected hasProAccess=\(hasAccess) hasExpiredSubscription=\(expired) within \(timeout)s; got \(store.hasProAccess)/\(store.hasExpiredSubscription)",
                file: file, line: line)
    }

    func testMonthlyProductPurchaseAndRefundUseProductionVerifier() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let cache = ProAccessCache()
        let store = ProSubscriptionStore(configuration: .init(productID: productID), publishAccess: cache.update)
        await store.loadProduct()
        let product = try XCTUnwrap(store.product)
        XCTAssertEqual(product.type, .autoRenewable)
        XCTAssertTrue(product.displayPrice.contains("29.99"), "displayPrice was \(product.displayPrice)")
        XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.value, 1)
        await store.refresh()
        XCTAssertFalse(store.hasProAccess)
        _ = try await session.buyProduct(identifier: productID)
        await waitForAccess(store, hasAccess: true, expired: false)
        XCTAssertTrue(cache.snapshot().hasProAccess)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        await waitForAccess(store, hasAccess: false, expired: true)
        XCTAssertFalse(cache.snapshot().hasProAccess)
    }

    func testPendingAndCancelledPurchaseNeverGrantAccessAndExpiryRemovesIt() async throws {
        let session = try session()
        defer {
            session.timeRate = .realTime
            session.clearTransactions()
        }
        let store = ProSubscriptionStore(configuration: .init(productID: productID))
        await store.loadProduct()
        let product = try XCTUnwrap(store.product)
        await store.purchaseCompleted(product: product, result: .success(.userCancelled))
        XCTAssertNil(store.message)
        XCTAssertFalse(store.hasProAccess)
        await store.purchaseCompleted(product: product, result: .success(.pending))
        XCTAssertTrue(store.purchaseIsPending)
        XCTAssertFalse(store.hasProAccess)
        session.timeRate = .oneRenewalEveryTwoSeconds
        _ = try await session.buyProduct(identifier: productID)
        await waitForAccess(store, hasAccess: true, expired: false)
        XCTAssertFalse(store.purchaseIsPending)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        await waitForAccess(store, hasAccess: false, expired: true)
    }
}

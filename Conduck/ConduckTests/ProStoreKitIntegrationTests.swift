// SPDX-License-Identifier: Apache-2.0

// Apple's local StoreKit test session supplies real StoreKit transaction and
// product objects with simulated money. The production verifier reads them;
// no subscription singleton, real account or production entitlement is used.

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
        #if targetEnvironment(simulator)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion == 26, version.minorVersion == 5, !session.disableDialogs {
            // This runtime can reject SKTestSession configuration mutations
            // with SKInternalErrorDomain 3 outside an IDE debug session. Probe
            // the setting read-back instead of treating an empty product list
            // as success, or falling through to a real Apple Account prompt.
            throw XCTSkip("iOS 26.5 StoreKit test service rejected the local configuration (disableDialogs did not persist). Run these cases from an Xcode StoreKit debug session before release.")
        }
        #endif
        XCTAssertTrue(session.disableDialogs, "The local StoreKit test session must be active before querying products")
        session.clearTransactions()
        return session
    }

    func testMonthlyProductPurchaseAndRefundUseProductionVerifier() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let cache = ProAccessCache()
        let store = ProSubscriptionStore(configuration: .init(productID: productID), publishAccess: cache.update)
        await store.loadProduct()
        let product = try XCTUnwrap(store.product)
        XCTAssertEqual(product.price, Decimal(string: "29.99"))
        XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.value, 1)
        await store.refresh()
        XCTAssertFalse(store.hasProAccess)
        _ = try await session.buyProduct(identifier: productID)
        await store.refresh()
        XCTAssertTrue(store.hasProAccess)
        XCTAssertTrue(cache.snapshot().hasProAccess)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        await store.refresh()
        XCTAssertFalse(store.hasProAccess)
        XCTAssertTrue(store.hasExpiredSubscription)
        XCTAssertFalse(cache.snapshot().hasProAccess)
    }

    func testPendingAndCancelledPurchaseNeverGrantAccessAndExpiryRemovesIt() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let store = ProSubscriptionStore(configuration: .init(productID: productID))
        await store.loadProduct()
        let product = try XCTUnwrap(store.product)
        await store.purchaseCompleted(product: product, result: .success(.userCancelled))
        XCTAssertNil(store.message)
        XCTAssertFalse(store.hasProAccess)
        await store.purchaseCompleted(product: product, result: .success(.pending))
        XCTAssertTrue(store.purchaseIsPending)
        XCTAssertFalse(store.hasProAccess)
        _ = try await session.buyProduct(identifier: productID)
        await store.refresh()
        XCTAssertTrue(store.hasProAccess)
        XCTAssertFalse(store.purchaseIsPending)
        try session.expireSubscription(productIdentifier: productID)
        await store.refresh()
        XCTAssertFalse(store.hasProAccess)
        XCTAssertTrue(store.hasExpiredSubscription)
    }
}

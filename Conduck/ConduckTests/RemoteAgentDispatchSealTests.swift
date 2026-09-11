// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentDispatchSealTests.swift
//
// A reviewed gateway slot may not silently turn into a different destination
// during an asynchronous handoff. Every routing/authentication/trust field is
// covered; stateless session bookkeeping deliberately does not change the seal.

import XCTest
@testable import Conduck

final class RemoteAgentDispatchSealTests: XCTestCase {
    func testDestinationAuthenticationModelAndPinChangesBreakTheSeal() {
        let original = snapshot()
        let changes = [
            snapshot(ref: .builtin(.hermes)),
            snapshot(url: "https://other.example.invalid"),
            snapshot(token: "replacement"),
            snapshot(auth: .none),
            snapshot(model: "other-model"),
            snapshot(pin: "different-pin")
        ]
        for changed in changes {
            XCTAssertFalse(original.hasSameDispatchDestination(as: changed))
        }
        XCTAssertTrue(original.hasSameDispatchDestination(as: snapshot()))
    }

    func testEphemeralSessionDoesNotRebindTheConnection() {
        XCTAssertTrue(snapshot(session: "first").hasSameDispatchDestination(as: snapshot(session: "second")))
    }

    func testMissingBearerCredentialNeverMatchesReviewedCredential() {
        XCTAssertFalse(snapshot().hasSameDispatchDestination(as: snapshot(token: nil)))
    }

    private func snapshot(
        ref: RemoteAgentRef = .builtin(.openclaw),
        url: String = "https://example.invalid",
        token: String? = "fixture",
        auth: RemoteAgentAuthScheme = .bearer,
        model: String? = nil,
        pin: String? = nil,
        session: String? = nil
    ) -> SettingsManager.RemoteAgentSnapshot {
        .init(backend: .openclaw, ref: ref, url: URL(string: url)!, token: token, authScheme: auth, model: model, certFingerprintHex: pin, activeSessionID: session)
    }
}

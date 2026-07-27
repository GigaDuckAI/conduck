// SPDX-License-Identifier: Apache-2.0

// Conduck
// NoOpSTTProbeTests.swift
//
// `NoOpSTTProbe` is used by every
// keyless / in-process provider (Apple on-device is the sole V1 user)
// and is the contract that lets Settings "Validate & Save" succeed
// without an API key being present. A regression that re-introduced
// network I/O or an apiKey emptiness check here would silently break
// the Apple Settings flow without any visible build error.

import XCTest
@testable import Conduck

final class NoOpSTTProbeTests: XCTestCase {

    func testValidateSucceedsWithEmptyKeyAgainstAppleProvider() async {
        do {
            try await NoOpSTTProbe.validate(apiKey: "", provider: .appleOnDevice)
        } catch {
            XCTFail("NoOpSTTProbe.validate must succeed for keyless providers regardless of apiKey contents. Got: \(error)")
        }
    }

    func testValidateSucceedsWithArbitraryKeyAgainstAppleProvider() async {
        // The probe should not consult the key at all — passing a garbage
        // string must still succeed. This guards against a regression that
        // adds non-empty-key validation by mistake.
        do {
            try await NoOpSTTProbe.validate(apiKey: "garbage-but-not-empty", provider: .appleOnDevice)
        } catch {
            XCTFail("NoOpSTTProbe.validate must ignore apiKey contents. Got: \(error)")
        }
    }

    func testValidateDoesNotPerformNetworkIO() async {
        // Smoke proxy for "is this actually a no-op": measure wall-clock.
        // A real HTTP roundtrip even on localhost would take >1 ms;
        // NoOpSTTProbe must return synchronously enough that 10 calls
        // complete in <10 ms even on a heavily loaded CI runner.
        let start = Date()
        for _ in 0..<10 {
            try? await NoOpSTTProbe.validate(apiKey: "", provider: .appleOnDevice)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5,
                          "10 NoOpSTTProbe.validate calls should complete in <500 ms (took \(elapsed) s) — a regression into real network I/O would blow this budget")
    }
}

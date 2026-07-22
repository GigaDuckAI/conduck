// Conduck
// RelayRoutingDecisionTests.swift
//
// watch-stt-fix — pins `AppleSpeechRelayCoordinator.resolveNilProviderRoute`,
// the pure routing verdict for a relay request that arrived WITHOUT a
// providerID stamp. Semantics (2026-06 fix): absent providerID means
// "transcribe with the iPhone's CURRENT active provider" — the iPhone is
// the settings authority, so a stale Watch that still thinks Apple is
// active gets the user's real provider instead of a guaranteed-wrong
// Apple run.
//
// The resolver is deliberately a static pure function (presetID + flag in,
// verdict out) so the precedence rules below are testable without a
// `SettingsManager` snapshot or any WCSession plumbing. The snapshot-driven
// caller (`transcribeWithActiveProvider`) feeds it
// `snapshot.provider.dynamicEndpointKey != nil` as the flag.
//
// PLATFORM GATE: `#if os(iOS)` — same reasoning as RelayWireContractTests:
// `AppleSpeechRelayCoordinator` only exists where WatchConnectivity does.

#if os(iOS)

import XCTest
@testable import Conduck

final class RelayRoutingDecisionTests: XCTestCase {

    private typealias Route = AppleSpeechRelayCoordinator.NilProviderRoute

    func testAppleActiveRoutesOnDevice() {
        // Apple is the fresh-install default; the most common unstamped
        // request must keep the byte-identical legacy on-device path.
        let route = AppleSpeechRelayCoordinator.resolveNilProviderRoute(
            activePresetID: "apple-on-device",
            activeHasDynamicEndpoint: false
        )
        XCTAssertEqual(route, Route.appleOnDevice)
    }

    func testCustomEndpointActiveRoutesToThatExactPreset() {
        // The verdict must carry the snapshot's OWN per-uuid presetID so
        // `transcribeViaCustomEndpoint`'s same-endpoint guard passes by
        // construction — never a bare prefix or a different endpoint.
        let presetID = "custom-openai_8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F"
        let route = AppleSpeechRelayCoordinator.resolveNilProviderRoute(
            activePresetID: presetID,
            activeHasDynamicEndpoint: true
        )
        XCTAssertEqual(route, Route.customEndpoint(presetID: presetID))
    }

    func testCloudProviderActiveRoutesToActiveCloud() {
        // A frozen cloud preset (no dynamic endpoint) transcribes via
        // `STTClient` with the snapshot key — never the cert-pin path.
        let route = AppleSpeechRelayCoordinator.resolveNilProviderRoute(
            activePresetID: "mistral-voxtral",
            activeHasDynamicEndpoint: false
        )
        XCTAssertEqual(route, Route.activeCloud)
    }

    func testAppleWinsRegardlessOfDynamicEndpointFlag() {
        // Precedence pin: the Apple registry entry never carries a dynamic
        // endpoint, but if the flag ever lied, Apple must still win — a
        // mis-flagged snapshot must not push an on-device user onto a
        // network endpoint.
        let route = AppleSpeechRelayCoordinator.resolveNilProviderRoute(
            activePresetID: "apple-on-device",
            activeHasDynamicEndpoint: true
        )
        XCTAssertEqual(route, Route.appleOnDevice)
    }
}

#endif // os(iOS)

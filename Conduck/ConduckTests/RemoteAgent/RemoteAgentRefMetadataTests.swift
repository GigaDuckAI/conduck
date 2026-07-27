// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentRefMetadataTests.swift
//
// Custom-gateways. Pure display-identity + badge-palette resolution shared by
// every surface (pickers / Settings / Watch badge / CarPlay switcher). Tests
// the string-returning helpers (label / monogram derivation / palette id
// assignment); Color values are not asserted (SwiftUI Color isn't reliably
// Equatable).

import XCTest
@testable import Conduck

final class RemoteAgentRefMetadataTests: XCTestCase {

    private func custom(_ name: String, monogram: String? = nil, colorID: String? = nil) -> CustomGateway {
        CustomGateway(id: UUID(), name: name, model: nil, colorID: colorID, monogram: monogram)
    }

    // MARK: - displayName

    func testDisplayNameBuiltin() {
        XCTAssertEqual(RemoteAgentRefMetadata.displayName(for: .builtin(.openclaw), customs: []), "OpenClaw")
        XCTAssertEqual(RemoteAgentRefMetadata.displayName(for: .builtin(.hermes), customs: []), "Hermes")
    }

    func testDisplayNameCustom() {
        let gateway = custom("Home vLLM")
        let name = RemoteAgentRefMetadata.displayName(for: gateway.ref, customs: [gateway])
        XCTAssertEqual(name, "Home vLLM")
    }

    func testDisplayNameMissingCustomFallsBack() {
        // A deleted / not-yet-synced custom resolves to a generic label, never crashes.
        let label = RemoteAgentRefMetadata.displayName(for: .custom(UUID()), customs: [])
        XCTAssertFalse(label.isEmpty)
    }

    // MARK: - monogram

    func testMonogramBuiltinUsesShortCode() {
        XCTAssertEqual(RemoteAgentRefMetadata.monogram(for: .builtin(.openclaw), customs: []), "OC")
        XCTAssertEqual(RemoteAgentRefMetadata.monogram(for: .builtin(.hermes), customs: []), "H")
    }

    func testMonogramCustomPrefersExplicit() {
        let gateway = custom("Home Server", monogram: "O3")
        XCTAssertEqual(RemoteAgentRefMetadata.monogram(for: gateway.ref, customs: [gateway]), "O3")
    }

    func testMonogramCustomDerivesFromNameWhenUnset() {
        let gateway = custom("Home Server")
        XCTAssertEqual(RemoteAgentRefMetadata.monogram(for: gateway.ref, customs: [gateway]), "HO")
    }

    func testDeriveMonogram() {
        XCTAssertEqual(RemoteAgentRefMetadata.deriveMonogram(from: "Home Server"), "HO")
        XCTAssertEqual(RemoteAgentRefMetadata.deriveMonogram(from: "vLLM box"), "VL")
        XCTAssertEqual(RemoteAgentRefMetadata.deriveMonogram(from: "  9 lives"), "9L")
        XCTAssertEqual(RemoteAgentRefMetadata.deriveMonogram(from: ""), "")
        XCTAssertEqual(RemoteAgentRefMetadata.deriveMonogram(from: "!!!"), "")
    }

    // MARK: - Badge palette

    func testCustomPaletteIDsAreUniqueAndNonEmpty() {
        let ids = RemoteAgentBadgePalette.customPalette.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Palette color ids must be unique (they are persisted keys)")
        XCTAssertFalse(ids.isEmpty)
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
    }

    func testNextUnusedIDSkipsUsed() {
        let all = RemoteAgentBadgePalette.customPalette.map(\.id)
        let first = all[0]
        let second = all[1]
        XCTAssertEqual(RemoteAgentBadgePalette.nextUnusedID(existing: []), first)
        XCTAssertEqual(RemoteAgentBadgePalette.nextUnusedID(existing: [first]), second)
    }

    func testNextUnusedIDWrapsWhenAllUsed() {
        let all = RemoteAgentBadgePalette.customPalette.map(\.id)
        // Defensive: > palette size of customs is impossible under the cap, but
        // the assignment must not crash — it wraps to the first slot.
        XCTAssertEqual(RemoteAgentBadgePalette.nextUnusedID(existing: all), all[0])
    }
}

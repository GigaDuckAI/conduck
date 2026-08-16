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

    // MARK: - shortDisplayName (the narrow + spoken surfaces)

    /// THE GUARANTEE, and the only one that matters: nothing this returns can
    /// exceed the budget, on ANY lane, for ANY name the save path allows.
    ///
    /// Custom names are capped at 40 characters when saved
    /// (`SettingsViewModel.saveRemoteAgentConfig`), so 40 is the worst case a
    /// wrist banner or a CarPlay row can ever be handed. Without the bound, an
    /// instance-named sentence ("Couldn't reach X.") runs to 58 characters on a
    /// surface measured at roughly 38 — a regression on exactly the surfaces
    /// instance-naming exists to improve.
    func testShortDisplayNameNeverExceedsTheBudget() {
        let limit = RemoteAgentRefMetadata.shortDisplayNameLimit
        for backend in RemoteAgentBackend.allCases {
            let short = RemoteAgentRefMetadata.shortDisplayName(for: .builtin(backend), customs: [])
            XCTAssertLessThanOrEqual(short.count, limit, "\(backend) short form overruns the budget")
            XCTAssertFalse(short.isEmpty)
        }
        // The save cap, exactly: 40 characters is the longest name that exists.
        let atCap = custom(String(repeating: "x", count: 40))
        let cappedShort = RemoteAgentRefMetadata.shortDisplayName(for: atCap.ref, customs: [atCap])
        XCTAssertLessThanOrEqual(cappedShort.count, limit,
                                 "a name at the 40-char save cap must still fit the narrow surfaces")
        XCTAssertFalse(cappedShort.isEmpty)
    }

    /// A name that FITS is returned untouched. The budget bounds a line; it is
    /// not a style — abbreviating "OpenClaw" to "OC" would make the spoken
    /// CarPlay line worse, not shorter in any way that helps.
    func testShortDisplayNameLeavesFittingNamesAlone() {
        XCTAssertEqual(RemoteAgentRefMetadata.shortDisplayName(for: .builtin(.openclaw), customs: []), "OpenClaw")
        XCTAssertEqual(RemoteAgentRefMetadata.shortDisplayName(for: .builtin(.hermes), customs: []), "Hermes")
        XCTAssertEqual(RemoteAgentRefMetadata.shortDisplayName(for: .builtin(.openrouter), customs: []), "OpenRouter")

        let gateway = custom("Home vLLM")
        XCTAssertEqual(RemoteAgentRefMetadata.shortDisplayName(for: gateway.ref, customs: [gateway]), "Home vLLM")
    }

    /// The truncation itself: the ellipsis is INSIDE the budget (so the result
    /// is what fits, not the input), and a trailing separator is dropped so the
    /// form never reads "hermes-vps-…".
    func testTruncationCountsTheEllipsisAndDropsTrailingSeparators() {
        let limit = RemoteAgentRefMetadata.shortDisplayNameLimit

        let hostname = RemoteAgentRefMetadata.truncatedToShortLimit("hermes-vps-01-frankfurt")
        XCTAssertLessThanOrEqual(hostname.count, limit)
        XCTAssertTrue(hostname.hasSuffix("…"))

        // Cut lands immediately after a separator → the separator goes with it.
        let separatorAtCut = RemoteAgentRefMetadata.truncatedToShortLimit("hermes-vps-012-frankfurt")
        XCTAssertFalse(separatorAtCut.hasSuffix("-…"), "a dangling separator before the ellipsis reads as corruption")
        XCTAssertLessThanOrEqual(separatorAtCut.count, limit)

        // Exactly at the budget → untouched, no ellipsis for nothing.
        let exact = String(repeating: "a", count: limit)
        XCTAssertEqual(RemoteAgentRefMetadata.truncatedToShortLimit(exact), exact)

        // Pathological: nothing but separators past the cut. Must still return
        // characters rather than an ellipsis floating on its own.
        let allSeparators = RemoteAgentRefMetadata.truncatedToShortLimit(String(repeating: "-", count: 30))
        XCTAssertLessThanOrEqual(allSeparators.count, limit)
        XCTAssertGreaterThan(allSeparators.count, 1)
    }

    /// A custom with no usable name still NAMES something. An empty short form
    /// would compose into "Couldn't reach ." on the wrist.
    func testShortDisplayNameNeverReturnsEmpty() {
        // Deleted / not-yet-synced roster entry.
        let missing = RemoteAgentRefMetadata.shortDisplayName(for: .custom(UUID()), customs: [])
        XCTAssertFalse(missing.isEmpty)
        XCTAssertLessThanOrEqual(missing.count, RemoteAgentRefMetadata.shortDisplayNameLimit)

        // Present but whitespace-only name, with a monogram to fall back to.
        let blank = custom("   ", monogram: "LT")
        XCTAssertEqual(RemoteAgentRefMetadata.shortDisplayName(for: blank.ref, customs: [blank]), "LT")

        // Present, blank, and no monogram either → the shared generic label.
        let bare = custom("   ")
        let bareShort = RemoteAgentRefMetadata.shortDisplayName(for: bare.ref, customs: [bare])
        XCTAssertFalse(bareShort.isEmpty)
        XCTAssertLessThanOrEqual(bareShort.count, RemoteAgentRefMetadata.shortDisplayNameLimit,
                                 "the generic fallback is itself a narrow-surface string and must fit")
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

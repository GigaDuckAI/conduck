// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetsSnapshotWriterColorTests.swift
//
// Share-Extension "Send to" picker — coverage for the Color → "#RRGGBB" helper
// the main-app writer uses to FREEZE each gateway's badge color into the appex
// snapshot (the appex can't reach the palette enum to resolve a semantic color).
// Pure static func, no signing / no App Group / no Keychain.

import XCTest
import SwiftUI
@testable import Conduck

final class ShareTargetsSnapshotWriterColorTests: XCTestCase {

    /// Always 7 chars, leading "#", and 6 uppercase hex digits.
    private func assertWellFormed(_ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(hex.count, 7, "Hex must be '#RRGGBB' (7 chars).", file: file, line: line)
        XCTAssertTrue(hex.hasPrefix("#"), "Hex must start with '#'.", file: file, line: line)
        let body = hex.dropFirst()
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        XCTAssertTrue(body.unicodeScalars.allSatisfy { allowed.contains($0) },
                      "Hex body must be uppercase hex digits, got \(hex).", file: file, line: line)
    }

    func testPrimaryColorsResolveToExpectedHex() {
        // Pure sRGB primaries resolve exactly.
        XCTAssertEqual(ShareTargetsSnapshotWriter.hexString(from: Color(red: 1, green: 0, blue: 0)), "#FF0000")
        XCTAssertEqual(ShareTargetsSnapshotWriter.hexString(from: Color(red: 0, green: 1, blue: 0)), "#00FF00")
        XCTAssertEqual(ShareTargetsSnapshotWriter.hexString(from: Color(red: 0, green: 0, blue: 1)), "#0000FF")
        XCTAssertEqual(ShareTargetsSnapshotWriter.hexString(from: Color(red: 0, green: 0, blue: 0)), "#000000")
        XCTAssertEqual(ShareTargetsSnapshotWriter.hexString(from: Color(red: 1, green: 1, blue: 1)), "#FFFFFF")
    }

    func testMidChannelClampsAndRounds() {
        // 0.5 → 128 (0.5*255 = 127.5, rounds to 128).
        XCTAssertEqual(ShareTargetsSnapshotWriter.hexString(from: Color(red: 0.5, green: 0.5, blue: 0.5)), "#808080")
    }

    func testPaletteColorsAreWellFormed() {
        // Every built-in + custom palette hue must produce a well-formed hex (the
        // appex renders it directly — a malformed string would blank the badge).
        assertWellFormed(ShareTargetsSnapshotWriter.hexString(from: RemoteAgentBadgePalette.openclaw))
        assertWellFormed(ShareTargetsSnapshotWriter.hexString(from: RemoteAgentBadgePalette.hermes))
        assertWellFormed(ShareTargetsSnapshotWriter.hexString(from: RemoteAgentBadgePalette.openrouter))
        for entry in RemoteAgentBadgePalette.customPalette {
            assertWellFormed(ShareTargetsSnapshotWriter.hexString(from: entry.color))
        }
    }

    func testBuiltInReservedColorsAreDisjointFromCustomPalette() {
        // INVARIANT: a built-in's reserved badge color must never equal a custom
        // palette hue — else a custom gateway auto-assigned that hue collides
        // with the built-in (the OpenRouter=indigo vs custom=indigo regression
        // this guards against). Compare by FROZEN hex — the same representation
        // the appex snapshot persists, and what the user actually sees.
        let builtIns: [(name: String, color: Color)] = [
            ("OpenClaw", RemoteAgentBadgePalette.openclaw),
            ("Hermes", RemoteAgentBadgePalette.hermes),
            ("OpenRouter", RemoteAgentBadgePalette.openrouter),
        ]
        let customHexes = Set(RemoteAgentBadgePalette.customPalette.map {
            ShareTargetsSnapshotWriter.hexString(from: $0.color)
        })
        for builtIn in builtIns {
            let hex = ShareTargetsSnapshotWriter.hexString(from: builtIn.color)
            XCTAssertFalse(customHexes.contains(hex),
                           "Built-in \(builtIn.name) badge color \(hex) collides with a custom palette hue.")
        }
    }

    // MARK: - Dead-gateway recents filter (iOS-only — RecentConversation is iOS)

    #if os(iOS)

    /// A recent bound to a STILL-CONFIGURED gateway is kept; one bound to a
    /// deleted / unconfigured gateway (its `backend` not in the configured set) is
    /// DROPPED — presenting it would route → throw → guaranteed share failure.
    func testFilterRecentsDropsUnconfiguredBackends() {
        let keptID = UUID()
        let droppedID = UUID()
        let recents: [ConversationStore.RecentConversation] = [
            ConversationStore.RecentConversation(
                id: keptID, label: "Live one", lastActivityAt: Date(),
                backend: RemoteAgentRef.builtin(.openclaw).rawString
            ),
            ConversationStore.RecentConversation(
                id: droppedID, label: "Dead one", lastActivityAt: Date(),
                backend: "custom_deadbeef-dead-beef-dead-beefdeadbeef"
            ),
        ]
        let configured: Set<String> = [RemoteAgentRef.builtin(.openclaw).rawString]

        let filtered = ShareTargetsSnapshotWriter.filterRecents(recents, configuredRefStrings: configured)

        XCTAssertEqual(filtered.map(\.id), [keptID],
                       "Only the recent on a configured gateway must survive the filter.")
        XCTAssertEqual(filtered.first?.backendRef, RemoteAgentRef.builtin(.openclaw).rawString)
    }

    /// With NO configured gateways, every recent is dropped (the picker never
    /// offers an unroutable target).
    func testFilterRecentsDropsAllWhenNothingConfigured() {
        let recents: [ConversationStore.RecentConversation] = [
            ConversationStore.RecentConversation(
                id: UUID(), label: "a", lastActivityAt: Date(),
                backend: RemoteAgentRef.builtin(.hermes).rawString
            ),
        ]
        let filtered = ShareTargetsSnapshotWriter.filterRecents(recents, configuredRefStrings: [])
        XCTAssertTrue(filtered.isEmpty, "No configured gateways → no recents offered.")
    }

    #endif
}

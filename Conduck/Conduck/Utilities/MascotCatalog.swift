// SPDX-License-Identifier: Apache-2.0

// Conduck
// MascotCatalog.swift
//
// Empty-state mascot rotation: a curated mixed-aspect pose pool + a
// device-local "shuffle bag" picker. Pure logic (no SwiftUI); the renderer is
// `EmptyStateMascot`. Persisted in UserDefaults so the rotation continues across
// launches.

import Foundation

/// The empty-state mascot rotation pool. Mixed aspect ratios (landscape, square,
/// and portrait sticker scenes); `EmptyStateMascot` renders every pose at the same
/// fixed height, so square/portrait poses simply show a narrower footprint. Names
/// are the `conduck-*` asset-catalog imageset names. Edit this one list to curate.
enum MascotCatalog {
    static let emptyStatePoses: [String] = [
        "conduck-wrestling-bear", "conduck-bench-press", "conduck-pumping-iron",
        "conduck-disco", "conduck-kickboxing", "conduck-laptop", "conduck-barbecue",
        "conduck-chopping-wood", "conduck-dj", "conduck-ladies-man",
        "conduck-luxury-car", "conduck-painter", "conduck-skateboarding",
        "conduck-snowboarding", "conduck-surfing", "conduck-meditation",
        "conduck-boxing", "conduck-chef", "conduck-leather-jacket",
        "conduck-motorcycle", "conduck-top-hat", "conduck-waving",
        // Sticker-scene poses (mixed aspect ratios).
        "conduck-astronaut", "conduck-basketball-slam-dunk", "conduck-chess",
        "conduck-coconut-under-palm", "conduck-diving-with-sharks", "conduck-golf",
        "conduck-riding-rhino", "conduck-rockstar", "conduck-roulette",
        "conduck-superhero", "conduck-sushi-chef", "conduck-winning-peace-nobel-price",
        "conduck-winning-soccer-world-cup", "conduck-love-letters",
    ]
}

/// Device-local "shuffle bag": shuffle the full pool, deal until empty, reshuffle.
/// Feels random, never repeats a pose until every pose has been shown, and avoids
/// a repeat across the reshuffle boundary. Persisted in UserDefaults (per device).
enum MascotShuffleBag {
    private static let deckKey = "mascot.emptyState.deck"
    private static let lastKey = "mascot.emptyState.last"

    static func next() -> String {
        next(pool: MascotCatalog.emptyStatePoses, defaults: .standard)
    }

    /// Test seam — inject a pool + an isolated UserDefaults suite.
    static func next(pool: [String], defaults: UserDefaults) -> String {
        guard let fallback = pool.first else { return "conduck-wrestling-bear" }
        var deck = (defaults.stringArray(forKey: deckKey) ?? []).filter { pool.contains($0) }
        if deck.isEmpty {
            deck = pool.shuffled()
            if deck.count > 1, let last = defaults.string(forKey: lastKey), deck.first == last {
                deck.swapAt(0, deck.count - 1)
            }
        }
        let pose = deck.isEmpty ? fallback : deck.removeFirst()
        defaults.set(deck, forKey: deckKey)
        defaults.set(pose, forKey: lastKey)
        return pose
    }
}

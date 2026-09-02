// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardCardActionPolicy.swift
//
// What a desk card may offer a person, decided once from what the store says is
// behind it. Every card surface asks this — the tile, its menu, its VoiceOver
// actions, the audio card's transport and the preview router — so a state whose
// bytes are not readable here cannot be opened through one surface while being
// refused by another.
//
// WHY A TYPE OF ITS OWN: the three availability answers that are NOT "readable
// bytes on this device" mean different things to a person. Missing bytes are
// something only they can repair; bytes still arriving through private CloudKit
// are something only waiting repairs, and offering to replace them would ask
// for work that is already happening. Spelling that distinction at each call
// site is how one surface ends up opening a thumbnail while its neighbour shows
// a reattachment error for the same card.
//
// The switch below is exhaustive on purpose: a new availability state cannot be
// added without deciding, here, what it lets a person do.

import Foundation

/// The things a board card can offer for one material. Permission only — which
/// of them a card actually draws is the card's own business: a source card
/// never plays, and an audio card plays instead of opening its tile.
enum WorkboardCardAction: Hashable, Sendable {
    case open
    case play
    case reattach
}

enum WorkboardCardActionPolicy {
    /// Everything this availability state permits.
    ///
    /// Readable bytes permit both verbs; missing bytes permit only the repair;
    /// bytes still on their way permit nothing at all, because every action a
    /// card could offer would either read bytes that are not there or ask for a
    /// replacement of bytes that are arriving.
    static func actions(
        for availability: WorkboardMaterialAvailability
    ) -> Set<WorkboardCardAction> {
        switch availability {
        case .available, .localOnly:
            return [.open, .play]
        case .unavailableOnThisDevice:
            return [.reattach]
        case .syncPending:
            return []
        }
    }

    static func allows(
        _ action: WorkboardCardAction,
        when availability: WorkboardMaterialAvailability
    ) -> Bool {
        actions(for: availability).contains(action)
    }

    /// The ONE thing a tap on the tile does, derived from the permitted set so
    /// the tile and the menu can never disagree. `nil` is a card that is not a
    /// control at all: its status copy is the whole answer.
    ///
    /// Playback is deliberately never the answer here. An audio card owns its
    /// own transport and asks `allows(.play,…)` for permission, so the tap
    /// funnel that reaches the preview router carries no playback.
    static func primaryAction(
        for availability: WorkboardMaterialAvailability
    ) -> WorkboardCardAction? {
        let permitted = actions(for: availability)
        if permitted.contains(.open) { return .open }
        if permitted.contains(.reattach) { return .reattach }
        return nil
    }

    /// Performs that one thing. The desk canvas and its tests drive THIS, so the
    /// routing under test is the routing that ships rather than a copy of it.
    static func performPrimaryAction(
        for availability: WorkboardMaterialAvailability,
        open: () -> Void,
        reattach: () -> Void
    ) {
        switch primaryAction(for: availability) {
        case .open:
            open()
        case .reattach:
            reattach()
        case .play, .none:
            break
        }
    }
}

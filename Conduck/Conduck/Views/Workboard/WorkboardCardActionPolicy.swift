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

/// Why a card offers no primary action, in the words a card face can draw.
///
/// A CLICK IS NEVER SILENT. `primaryAction` is nil for exactly one state, and a
/// tile that answers a tap with nothing is indistinguishable from a broken one.
/// The refusal already exists in VoiceOver; this is the same sentence for
/// everybody else, and it is a value rather than a string inside a view so the
/// card, the list row and the tests all say it once.
///
/// It names only what OPENING is waiting for. Arranging, resizing and removing
/// a waiting card are not blocked and never were — a surface that dimmed the
/// whole card on this value would take away three verbs the person still has.
enum WorkboardCardBlockedReason: Hashable, Sendable {
    /// The bytes ride the person's own private CloudKit and have not landed on
    /// this device yet. Nothing to repair — it resolves by waiting.
    case waitingForICloud

    /// What a card face draws. The same row the availability glyph already
    /// speaks, so the visible sentence and the spoken one cannot drift.
    var label: LocalizedStringResource {
        switch self {
        case .waitingForICloud:
            return LocalizedStringResource(
                "workboard.material.syncPending",
                defaultValue: "Waiting for iCloud…"
            )
        }
    }
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

    /// Why a tap on this card does nothing, or nil when it does something.
    ///
    /// Derived from `primaryAction` rather than from a second switch on
    /// availability: the card that draws this and the tap funnel that refuses
    /// it are then answering from one rule, so a state can never be silent in
    /// the funnel while looking actionable on the tile.
    static func blockedReason(
        for availability: WorkboardMaterialAvailability
    ) -> WorkboardCardBlockedReason? {
        guard primaryAction(for: availability) == nil else { return nil }
        switch availability {
        case .syncPending:
            return .waitingForICloud
        case .available, .localOnly, .unavailableOnThisDevice:
            // Unreachable while those three states permit a primary action; the
            // switch is exhaustive so a state added later has to decide here.
            return nil
        }
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

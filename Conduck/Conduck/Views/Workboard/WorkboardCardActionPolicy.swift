// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardCardActionPolicy.swift
//
// Material details and user notes are available independently of source bytes.
// Native source preview, sharing and playback still require readable bytes;
// reattachment is offered only for missing bytes, never a pending sync.
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
    case details
    case open
    case play
    case reattach
}

enum WorkboardCardActionPolicy {
    /// Everything this availability state permits.
    ///
    /// Details read only metadata. The other verbs retain their source-byte
    /// requirements even when notes can be read and edited.
    static func actions(
        for availability: WorkboardMaterialAvailability
    ) -> Set<WorkboardCardAction> {
        switch availability {
        case .available, .localOnly:
            return [.details, .open, .play]
        case .unavailableOnThisDevice:
            return [.details, .reattach]
        case .syncPending:
            return [.details]
        }
    }

    static func allows(
        _ action: WorkboardCardAction,
        when availability: WorkboardMaterialAvailability
    ) -> Bool {
        actions(for: availability).contains(action)
    }

    /// The tile opens material details, including notes and source availability.
    ///
    /// Playback is deliberately never the answer here. An audio card owns its
    /// own transport and asks `allows(.play,…)` for permission, so the tap
    /// funnel that reaches the preview router carries no playback.
    static func primaryAction(
        for availability: WorkboardMaterialAvailability
    ) -> WorkboardCardAction? {
        let permitted = actions(for: availability)
        if permitted.contains(.details) { return .details }
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
        case .details, .open:
            open()
        case .reattach:
            reattach()
        case .play, .none:
            break
        }
    }
}

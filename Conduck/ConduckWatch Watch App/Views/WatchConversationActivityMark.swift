// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchConversationActivityMark.swift
//
// The Watch conversation-list row's trailing attention mark: the wrist's
// rendering of the two ATTENTION facts in `ConversationRowState` — an unseen
// reply, and a failure the account has not yet acknowledged.
//
// A SEPARATE FILE FROM THE PHONE'S `ConversationActivityMark`, not a shared one.
// That view reaches `InFlightTurnRegistry`, which is not a Watch target member,
// so it could not compile here; and its geometry is sized against an iPhone row
// with a two-line subtitle and a 44 mm-wide title column. The wrist row is a
// two-line stack on a 40 mm screen where every reserved point is a point the
// title loses, so the sizes are chosen here rather than inherited.
//
// SHAPE, NOT COLOUR — the same discipline the phone mark states, and it is
// enforced by there being exactly three renderings: a filled disc, an
// exclamation punched out of a circle, and nothing at all. Every pair of them is
// still distinguishable with the colour channel removed, which matters more on
// this surface than on any other: watchOS draws on black, in sunlight, at a
// glance, and Always-On Display dims the whole row.
//
// ATTENTION ONLY — THE MARK IS SILENT FOR DELIVERY STATE, and that is a division
// of labour rather than an omission. The wrist already renders `working` and
// `failed` as WORDS in its date slot ("Waiting for a reply…", "Not sent"),
// because the row has no width for both a glyph and a status line. A spinner
// here would say a second time what the line below already says, and would cost
// a per-minute animation on the smallest battery in the fleet. The mark carries
// only the two facts those words cannot: that a reply is UNREAD, and that a
// failure is UNACKNOWLEDGED.
//
// THE SLOT IS ALWAYS PRESENT. The empty case is a transparent shape of exactly
// the same size, never a conditional view, so the title's truncation point does
// not move when a row changes state. Without that, a reply landing would shorten
// its own row's title by a glyph's width and re-truncate it, which reads as the
// text changing rather than as an indicator appearing.

import SwiftUI

/// The trailing mark on a Watch conversation row's title line.
///
/// Takes an already-resolved `ConversationRowState` — the row resolves it ONCE
/// per build (`WatchConversationViewModel.rowState`) and hands the same value to
/// the title, this mark and the metadata line, so the three can never disagree
/// about what the row is reporting.
struct WatchConversationActivityMark: View {
    let state: ConversationRowState

    /// Scales with Dynamic Type so the mark keeps its proportion to the
    /// `.caption` title beside it at the accessibility sizes, instead of
    /// shrinking to a speck the wrist cannot resolve. Deliberately smaller than
    /// the phone's slot: this row is on a 40 mm screen and the title is the
    /// content, so the reserved column is as narrow as a legible glyph allows.
    @ScaledMetric private var slot: CGFloat = 11

    var body: some View {
        mark
            .frame(width: slot, height: slot)
    }

    /// PRECEDENCE IS FAILURE FIRST, then the unseen reply. On the wrist the two
    /// cannot actually co-occur — a row paints `.failed` only while the failed
    /// USER turn is still the conversation's last activity, which makes the tail
    /// a user turn, and the unseen branch needs an `.agent` tail — but the
    /// ordering is written down rather than left to that argument, because it
    /// depends on the resolver's bounds holding and this view is the wrong layer
    /// to depend on them. A problem outranks a new reply either way.
    ///
    /// AN ACKNOWLEDGED FAILURE KEEPS ITS WORDS AND LOSES ITS MARK — the row's
    /// metadata line still says "Not sent", because the message still did not
    /// go; what it drops is the alert, which has already been delivered. The
    /// `.failed` check is NOT redundant with the flag: the resolver only ever
    /// sets `failureAcknowledged` alongside `.failed`, but the memberwise
    /// initializer accepts any pairing and validates nothing, so a stray
    /// `failureAcknowledged: true` on `.answeredUnseen` would silently blank the
    /// amber disc — the list's only call to action.
    @ViewBuilder
    private var mark: some View {
        switch state.activity {
        case .failed:
            if state.failureAcknowledged {
                Color.clear
            } else {
                // Hidden from VoiceOver: the metadata line one row below already
                // reads "Not sent", and an independently labelled glyph would
                // announce the same fact twice.
                symbol("exclamationmark.circle.fill", scale: 1.0, tint: AppColors.error)
                    .accessibilityHidden(true)
            }

        case .answeredUnseen:
            // LABELLED, unlike the failure glyph, because the wrist row has no
            // composed accessibility label and its metadata line shows only a
            // date here — so without this a VoiceOver user gets no signal at all
            // that the row has an unread reply. Reuses the phone's existing
            // phrase so both surfaces announce the same words.
            symbol("circle.fill", scale: 0.6, tint: AppColors.brandAmber)
                .accessibilityLabel(Text(newReplyLabel))

        case .idle, .working:
            // Nothing to draw, but the slot still occupies its width — see the
            // file header.
            Color.clear
        }
    }

    /// `resizable().scaledToFit()` inside a fraction of the slot rather than a
    /// point size: it guarantees the glyph stays inside the reserved column at
    /// every Dynamic Type size, including the accessibility sizes where a fixed
    /// point size would overflow the row and push the gateway badge off-screen.
    private func symbol(_ name: String, scale: CGFloat, tint: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .foregroundStyle(tint)
            .frame(width: slot * scale, height: slot * scale)
    }

    private var newReplyLabel: String {
        String(localized: "activity.a11y.newReply", defaultValue: "New reply")  // xcstrings: chat-ui
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// ComposerCardChrome.swift
//
// The ONE definition of the composer card: the elevated rounded container, plus
// the readable column every composer is capped to. Three hosts consume BOTH —
// Chat's macOS bar (`MessageComposerBar` + its cap in `MainWindowView`), Chat's
// iPad-regular bar (`iOSMessageComposerBar.regularLayout`) and Work's pinned bar
// (`WorkboardCaptureCanvas.pinnedComposer`) — so no host may re-type a radius,
// an inset, a stroke or a width. Work is Chat's composer, not a board-width
// variant of it: it caps to this column, never to `WorkboardMetrics`.
// Compact iPhone consumes neither — its composer is a docked full-bleed bar,
// not a card.

import SwiftUI

extension View {
    /// Chat's composer card. The inner 16/12 inset belongs to the CARD, not to
    /// the bar around it — every consumer adds its own outer 16/12 on top, which
    /// is what separates the card from the window edge.
    func composerCardChrome() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppColors.cardBackgroundElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
            )
    }

    /// The readable column Chat's thread and every composer share. Two frames,
    /// not one: the cap sizes the content, the infinity frame centres it in
    /// whatever pane it was handed — and re-expands, so a host that paints a
    /// full-bleed band behind the composer still gets one.
    ///
    /// WHERE it goes in the chain decides the card width, so a host must not move
    /// it: applied AFTER the bar's 16/12 inset (macOS) the card is one inset
    /// narrower than the column; applied to the card itself (iOS regular) the card
    /// IS the column. Work matches Chat per platform by matching that position.
    func composerReadableWidth() -> some View {
        frame(maxWidth: Constants.Layout.chatContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

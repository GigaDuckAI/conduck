// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDeskPresentation.swift
//
// What the Work surface draws, decided once and away from any `body`. The
// column that mounts the desk and the desk itself both read this value, so
// neither can hold its own opinion about which of the four states is on screen.
//
// Work is ONE desk at a compile-time identity, so this type takes no id and
// hands one out: a surface rendering it cannot be pointed at a second board.
// The desk before its first capture is a STATE OF THE DESK, not a missing
// board, which is why it and a failed load are different cases here — only the
// desk case mounts the pinned composer, so only it can take a capture.

import Foundation

enum WorkboardDeskPresentation: Equatable {
    /// The first load, before there is any desk state to draw. A reload with a
    /// desk already in hand keeps drawing that desk instead: the board on
    /// screen is warm, and replacing it with a spinner would lose the cards for
    /// the length of a fetch.
    case loading

    /// The load failed and left nothing to draw. The desk is unchanged behind
    /// this; only the read failed, so the surface offers to try again.
    case loadFailed(message: String)

    /// The desk, with or without cards on it.
    case desk(Desk)

    struct Desk: Equatable {
        /// What the scrolling board draws.
        enum Board: Equatable {
            /// Nothing has landed yet, so the board draws the invitation in
            /// place of an empty grid.
            case invitation
            /// The cards, on the capture canvas.
            case cards
        }

        /// The desk the board draws and the pinned composer writes into. Its id
        /// is `Constants.workboardDeskItemID` whether or not the row exists yet,
        /// so a capture taken before the first card lands on the identity that
        /// card will carry.
        let item: WorkboardItemSnapshot
        let board: Board

        init(item: WorkboardItemSnapshot) {
            self.item = item
            self.board = item.materials.isEmpty ? .invitation : .cards
        }
    }

    /// Both failure states are conditioned on there being no desk in hand: a
    /// board already loaded stays on screen through a refresh and through a
    /// refresh that failed, because the cards it shows are still the truth.
    static func resolve(
        isLoading: Bool,
        loadError: String?,
        desk: WorkboardItemSnapshot?
    ) -> WorkboardDeskPresentation {
        guard let desk else {
            if isLoading { return .loading }
            if let loadError { return .loadFailed(message: loadError) }
            return .desk(Desk(item: WorkboardItemSnapshot(id: Constants.workboardDeskItemID)))
        }
        return .desk(Desk(item: desk))
    }
}

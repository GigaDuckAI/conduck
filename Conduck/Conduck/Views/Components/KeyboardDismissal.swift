// SPDX-License-Identifier: Apache-2.0

// Conduck
// KeyboardDismissal.swift
//
// Local keyboard dismissal for Chat and Work, with composers kept OUTSIDE
// the gesture-bearing view in their host's bottom safe-area inset.
//
// Scroll surfaces dismiss as soon as scrolling starts. Interactive dismissal
// requires the finger to reach the keyboard; an ordinary scroll is not enough.
// Always-on bounce lets short content participate, and an explicit rectangular
// hit region includes blank viewport space in the plain, child-first tap.
// No competing drag gesture is added to the scroll surface: Work's card drags
// and the scroll view's own pan keep their existing ownership.
//
// A fresh Chat has no thread or ScrollView yet. Its centered, full-size empty
// state uses a separate tap/drag modifier, after its expanding frame. That
// modifier is only for noninteractive empty content, never cards or composers.
//
// The local tap resigns the first responder; SwiftUI updates its focus binding
// when the field loses focus. No window recognizer or high-priority/simultaneous
// tap observes unrelated controls. Source guards check placement, but actual
// keyboard gestures still require the human device pass.

import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Apply to the ScrollView before the composer's safe-area inset.
    func dismissesKeyboardOnScrollOrTap() -> some View {
        #if os(iOS)
        scrollBounceBehavior(.always)
            .scrollDismissesKeyboard(.immediately)
            .contentShape(Rectangle())
            .onTapGesture { KeyboardDismissal.dismissKeyboard() }
        #else
        scrollDismissesKeyboard(.interactively)
        #endif
    }

    /// For the full-size, non-scrollable new-Chat empty state only.
    func dismissesKeyboardOnEmptySpaceInteraction() -> some View {
        #if os(iOS)
        contentShape(Rectangle())
            .onTapGesture { KeyboardDismissal.dismissKeyboard() }
            .gesture(
                DragGesture()
                    .onChanged { _ in KeyboardDismissal.dismissKeyboard() }
            )
        #else
        self
        #endif
    }
}

#if os(iOS)
enum KeyboardDismissal {
    /// Resigns the current first responder, whichever field it is.
    @MainActor
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}
#endif

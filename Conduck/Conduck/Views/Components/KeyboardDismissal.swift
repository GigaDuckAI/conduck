// SPDX-License-Identifier: Apache-2.0

// Conduck
// KeyboardDismissal.swift
//
// The ONE sanctioned tap-to-dismiss, and the drag-to-dismiss that works on a
// short list. Applied to the ScrollView of a surface whose text field lives
// OUTSIDE it — Chat's thread and Work's board, whose composers are each a
// `.safeAreaInset` on the host — never window-wide.
//
// Two pieces, each for a reason the other cannot cover:
//
// - `.scrollBounceBehavior(.always)`: `.interactively` rides the scroll view's
//   pan, and a scroll view whose content is shorter than the viewport never
//   starts one. A one-message thread or a two-card board is exactly that shape,
//   so without always-on bounce the standard gesture silently does nothing.
// - A plain `.onTapGesture` on the ScrollView itself: it covers the whole
//   viewport (a `.background` layer behind a ScrollView never sees a touch, and
//   one on the content stops where the content does), and it is child-first —
//   Buttons, links, context-menu and selection long-presses and card drags
//   inside keep winning. Never `.highPriorityGesture` (steals child taps) and
//   never `.simultaneousGesture` (fires on every button tap).
//
// The tap resigns whichever responder holds the keyboard. Both composers keep
// their `@FocusState` private, and SwiftUI mirrors a UIKit-side resign into it
// exactly as `.interactively` already does — so the composer's own focus logic
// sees the same transition it always has. The window-wide form this replaces
// (`window.endEditing(true)` or a window tap recognizer) stays banned: that one
// cannot exclude Buttons and races a tap that just focused another field.
//
// Order matters at the call site: apply it to the ScrollView BEFORE any
// `.safeAreaInset` that hosts a text field, so the composer sits outside the
// tap-bearing view. `KeyboardDismissalDriftGuardTests` holds both call sites
// to that shape.

import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Drag-to-dismiss that also works on short content, plus tap-empty-space
    /// dismissal. macOS keeps only the (no-op) dismissal mode: always-on bounce
    /// would rubber-band a short thread there, a visible change for no keyboard.
    func dismissesKeyboardOnScrollOrTap() -> some View {
        #if os(iOS)
        scrollBounceBehavior(.always)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { KeyboardDismissal.dismissKeyboard() }
        #else
        scrollDismissesKeyboard(.interactively)
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

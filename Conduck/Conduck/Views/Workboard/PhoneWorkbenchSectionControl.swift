// SPDX-License-Identifier: Apache-2.0

// Conduck
// PhoneWorkbenchSectionControl.swift
//
// Compact iPhone navigation between Chats and Work: one icon-only toolbar
// button per surface that OPENS the other one. Destination semantics, never
// location — on Chats the glyph is Work's tray and the spoken label is
// "Open Work"; on Work it is the Chats bubbles and "Open Chats". A text label
// or chevron would put a second dropdown beside the gateway title, the one
// picker the phone bar is allowed; the bare icon is the point.
//
// The tap routes through `selectDestination`, the only path that arms the
// Work first-visit tour; a bare `destination` assignment is what deep links
// use precisely so they never introduce it. The button presents nothing of
// its own, so the tour has no presenter to compete with.

#if os(iOS)

import SwiftUI

private struct PhoneWorkbenchRouterKey: EnvironmentKey {
    static let defaultValue: PersonalWorkbenchRouter? = nil
}

extension EnvironmentValues {
    /// Present only in the compact phone shell. iPad keeps its own persistent
    /// section control, even when both platforms share a destination view.
    var phoneWorkbenchRouter: PersonalWorkbenchRouter? {
        get { self[PhoneWorkbenchRouterKey.self] }
        set { self[PhoneWorkbenchRouterKey.self] = newValue }
    }
}

struct PhoneWorkbenchFlipButton: View {
    let router: PersonalWorkbenchRouter
    /// The surface whose bar hosts this button; the button opens the other.
    let from: PersonalWorkbenchRouter.Destination

    private var target: PersonalWorkbenchRouter.Destination {
        from == .chats ? .work : .chats
    }

    private var label: LocalizedStringResource {
        target == .work
            ? LocalizedStringResource("workbench.phone.openWork", defaultValue: "Open Work")
            : LocalizedStringResource("workbench.phone.openChats", defaultValue: "Open Chats")
    }

    var body: some View {
        Button {
            // A departing surface may finish disappearing after the next one
            // is active; its stale button routes nothing on the new one's behalf.
            guard router.destination == from else { return }
            KeyboardDismissal.dismissKeyboard()
            router.selectDestination(target)
        } label: {
            Image(systemName: target == .work ? "tray.full" : "bubble.left.and.bubble.right")
        }
        // Let the system own this toolbar button's glass and foreground;
        // applying amber tint here would leak into native toolbar neighbors.
        // No `.help`: on iOS it doubles as the accessibility hint, and a hint
        // that repeats the label makes VoiceOver say "Open Work" twice.
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(
            target == .work ? "workbench.phone.openWork" : "workbench.phone.openChats"
        )
    }
}

#endif

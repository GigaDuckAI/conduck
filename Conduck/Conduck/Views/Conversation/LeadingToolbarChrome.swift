// SPDX-License-Identifier: Apache-2.0

// Conduck
// LeadingToolbarChrome.swift
//
// The leading toolbar chrome for the two SPLIT-VIEW surfaces — the macOS
// unified window (`MainWindowView`) and the iPad library
// (`ConversationLibraryView`): the system sidebar toggle, then the compose
// action, in that order.
//
// WHY the compose action lives here and not in the sidebar: a sidebar-hosted
// button is gone the moment the sidebar is collapsed, which is exactly when
// starting a new chat is hardest to reach. iPhone is untouched — its compose
// action already lives permanently in the thread's nav bar (`ContentView`),
// which is the right shape for a single-column layout.
//
// WHY `DefaultToolbarItem` rather than a lone placement: a plain `ToolbarItem`
// carries NO promise about where it lands relative to the toggle SwiftUI
// inserts automatically, and "immediately after the toggle" is the whole
// requirement. `DefaultToolbarItem(kind: .sidebarToggle,)` represents that
// same toggle rather than adding a second one, which makes declaration order
// the contract WITHIN the toolbar it is declared in.
//
// CAVEAT, iPad: this is declared on the DETAIL column, while iPadOS may also
// place a hide-sidebar control in the SIDEBAR column's own bar. Repositioning
// across columns is not something the API promises, so if a second toggle ever
// shows up while both columns are tiled, the fix is `.toolbar(removing:
// .sidebarToggle)` on the sidebar column — not a change here. macOS has no such
// ambiguity: one toolbar spans the whole split view.
//
// WHY both items live in ONE type: macOS and iPad must not drift on this. Each
// host declares a single line and cannot pick a different placement for one of
// the pair.
//
// WHY `.navigation` on BOTH platforms: it is the only placement that is both
// available and LEADING on each — macOS puts it at the leading edge ahead of
// the inline title, iOS at the leading edge of the navigation bar.
// `.topBarLeading` is macOS-unavailable and `.primaryAction` docks TRAILING on
// iOS, so neither can be shared. (The documented iOS degradation of
// `.navigation` to `.primaryAction` needs a system back button AND a compact
// size class; iPad mounts this split view only at `.regular` — compact falls
// through to the phone layout.)
//
// WHY no `MacPointerTargets` primitive: `.pointerIconButton()` REPLACES the
// button style, which would strip the macOS 26 Liquid Glass toolbar treatment
// and stop this button matching the system toggle beside it — the opposite of
// the goal. That primitive's own header scopes it to CUSTOM-DRAWN controls;
// this is a system-styled one. (Contrast the gateway pill in `MainWindowView`,
// which draws its own capsule and whose item suppresses system glass — custom-
// drawn, so it does use the primitive.) For the same reason this item does NOT
// set `.sharedBackgroundVisibility(.hidden)`: it WANTS the system glass.
//
// It owns NO keyboard shortcut. ⌘N already has exactly one owner per platform —
// `CommandGroup(replacing: .newItem)` in `ConduckApp` on macOS, the zero-size
// `keyboardShortcuts` stack in `ConversationLibraryView` on iPad — and a second
// declaration would be a duplicate binding, not a redundant one.

import SwiftUI

struct LeadingToolbarChrome: ToolbarContent {
    /// Start a fresh conversation. Each host means something different by it
    /// (macOS clears the WINDOW lane and re-seeds the pending gateway ref; iPad
    /// clears the selection so the next send mints a thread), so the action
    /// stays the host's.
    let action: () -> Void

    var body: some ToolbarContent {
        DefaultToolbarItem(kind: .sidebarToggle, placement: .navigation)

        ToolbarItem(placement: .navigation) {
            Button(action: action) {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New conversation")  // xcstrings: chat-ui
            .accessibilityIdentifier("toolbar.newConversation")  // stable QA target (non-localized)
            // NOT gated to macOS: `.help` drives the pointer tooltip on iPadOS
            // too, this split view mounts only at `.regular` (where a trackpad
            // is the likely input), and ⌘N is bound on both platforms — so the
            // string is accurate on both. Gating it would be exactly the drift
            // this type exists to prevent.
            .help(String(localized: LocalizedStringResource(
                "conversations.newConversation.help",
                defaultValue: "New conversation (⌘N)"
            )))
        }
    }
}

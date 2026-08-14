// SPDX-License-Identifier: Apache-2.0

// Conduck
// LeadingToolbarChrome.swift
//
// The compose action for the two SPLIT-VIEW surfaces — the macOS unified window
// (`MainWindowView`) and the iPad library (`ConversationLibraryView`) — placed
// so it sits immediately beside the sidebar toggle in BOTH sidebar states.
//
// WHY compose is toolbar chrome and not a sidebar row: a button in the sidebar's
// CONTENT is unmounted the moment the column collapses, which is exactly when
// starting a new chat is hardest to reach. A sidebar-region TOOLBAR item is a
// different thing — it belongs to the window's `NSToolbar`, and it survives the
// collapse (measured below). iPhone is untouched: its compose action already
// lives permanently in the thread's nav bar (`ContentView`), the right shape for
// a single-column layout.
//
// ── WHERE THIS MUST BE ATTACHED ────────────────────────────────────────────
// macOS: on the SIDEBAR COLUMN.  iPad: on the DETAIL COLUMN.
// Neither is interchangeable, and the type cannot enforce it, so read the two
// measured reasons below before moving either call site.
//
// macOS splits a unified toolbar in two at the column divider with an
// `NSTrackingSeparatorToolbarItem`. Items before it in `toolbar.items` draw over
// the sidebar; items after it draw over the content. The system builds this:
//
//   [0] NSToolbarFlexibleSpaceItem                     <- sidebar region
//   [1] <this item, when declared on the sidebar column>
//   [2] com.apple.SwiftUI.navigationSplitView.toggleSidebar
//   [3] com.apple.SwiftUI.splitViewSeparator-0         <- NSTrackingSeparator
//   [4] <items declared on the split view or detail column>  <- content region
//
// The leading flexible space is what pushes the whole sidebar group against the
// divider — which is why the toggle renders at the sidebar's TRAILING edge
// rather than at the window's top-left.
//
// WHY the trailing `ToolbarSpacer`: macOS 26 wraps ADJACENT items of the same
// placement in ONE shared Liquid Glass capsule. Without the spacer, compose and
// the toggle fuse into a single 73.5pt pill once the sidebar collapses, which
// reads as one wide two-glyph control rather than two buttons. A fixed spacer is
// the documented way to break a shared background, and it is the ONLY one that
// keeps both controls system-styled — `.sharedBackgroundVisibility(.hidden)`
// would remove compose's capsule entirely, leaving nothing to highlight.
//
// MEASURED (macOS 26.5, throwaway NavigationSplitView probe, 2026-08-14; window
// 900x652, sidebar column 288pt, x in window coordinates):
//
//   `.primaryAction` on the SIDEBAR column + trailing fixed spacer <- this file
//   — sidebar SHOWING
//     compose    189–233   w 44   glyph 21x20   no capsule
//     spacer     233–241   w  8
//     toggle     241–288   w 47   glyph 24x18   no capsule
//     Both inside the sidebar column (0–288), each drawn flat.
//
//   — sidebar COLLAPSED
//     compose    100–145   CAPSULE 104–141   37x36
//     spacer     145–153
//     toggle     153–201   CAPSULE 157–197   40x36
//     TWO separate capsules rather than one fused pill. The 3pt width gap is
//     each button sizing to its own glyph — a toolbar capsule comes out at
//     glyph + 16pt, and `square.and.pencil` is 3pt narrower than
//     `sidebar.leading`.
//
// WHY the capsules are NOT forced to equal widths: pinning the compose glyph's
// frame to the toggle glyph's width does equalize the containers (both 40x36),
// but it does NOT scale the SF Symbol — so the compose glyph ends up sitting in
// MORE dead space than before, which reads as a smaller button inside a bigger
// capsule. It also hardcodes a measurement of a system symbol that a point
// release can change. Container parity is not visual parity; the platform sizes
// each control to its own glyph, and matching that is the correct behaviour.
//
// WHY the two SIDEBAR STATES cannot be made to look identical: collapsed, AppKit
// encloses each button in a bounded 36pt glass capsule, because the controls
// then float over content and need their own ground. Expanded, they are drawn
// flat inside a 47x52 toolbar slot with nothing bounding them, so the
// surrounding whitespace reads as part of the control. A bounded 40x36 aperture
// genuinely looks smaller than an unbounded 47x52 allocation even though the
// hover target is 36x36 in BOTH states. This is macOS 26 Liquid Glass behaviour
// applied equally to both controls, not something this file sets — the only way
// to equalize it is to stop using system toolbar buttons entirely and draw both
// controls (including a replacement sidebar toggle) by hand, which forfeits the
// Liquid Glass treatment, `⌃⌘S`, the View-menu item, and the toggle's own
// VoiceOver name.
//
//   ORDER is not a choice. The system pins its toggle last in the sidebar
//   region, flush against the divider, so it does not move as the column opens
//   and closes. Anything this file declares lands to its LEFT, in both states.
//
//   Sidebar column, NO spacer — COLLAPSED                         <- rejected
//     PLATTER 106–179.5  w 73.5  glass=YES        <- ONE capsule over BOTH
//
//   `.navigation` on the SIDEBAR column — sidebar SHOWING          <- rejected
//     toggle     241–288
//     compose    292–337   glass=YES     (past the divider, content region)
//     Array position alone does not decide the region: this item still lands at
//     index 1, yet renders in the CONTENT half. The PLACEMENT decides it, so
//     `.navigation` cannot be shared with iPad here.
//
//   `.navigation` on the SPLIT VIEW — sidebar SHOWING              <- rejected
//     compose    292–337   glass=YES     (index 4, content region)
//     Declaring on the split view can only ever reach the content region.
//
//   `.toolbar(removing: .sidebarToggle)` + `DefaultToolbarItem(kind:
//   .sidebarToggle)` on the sidebar column, to put the toggle FIRST <- rejected
//     Suppressing the system toggle does not let `DefaultToolbarItem` supply a
//     replacement: it emits the same empty 10x10 phantom described below and no
//     working toggle, in both sidebar states. The system toggle cannot be
//     re-ordered, only removed and lost.
//
// WHY iPad keeps `.navigation` on the DETAIL column: iPadOS gives each column
// its own navigation bar, and the sidebar column's bar genuinely goes away with
// the sidebar — the macOS "toolbar item outlives the column" property does not
// exist there. The detail column's bar is the only one that is always on screen,
// and the system toggle already sits at its leading edge, so compose declared
// `.navigation` lands beside it in both column states. `.automatic` is NOT
// substitutable: `.topBarLeading` is macOS-unavailable and `.primaryAction`
// docks TRAILING on iOS. (The documented iOS degradation of `.navigation` to
// `.primaryAction` needs a system back button AND a compact size class; iPad
// mounts this split view only at `.regular` — compact falls through to phone.)
//
// WHY never `DefaultToolbarItem(kind: .sidebarToggle, placement:)`: on macOS it
// does NOT represent, move, or reorder the toggle. It adds a SEPARATE, EMPTY
// item — 10x10pt inside a ~41pt viewer carrying its own glass — which macOS then
// merges into one capsule with the item beside it, producing a wide pill with
// the glyph in its right half and dead, unclickable padding to its left. AppKit
// places the real toggle either way.
//
// WHY the label stays a bare `Image`: measured, `Label` and a titled `Button`
// produce identical item metrics — width tracks the GLYPH, not the label
// construction. The name reaches assistive technology via `.accessibilityLabel`.
// The glyph carries no `.frame`, `.font`, `.imageScale` or `.padding` at all —
// see the container-parity note above for why sizing it by hand backfires.
//
// WHY no `MacPointerTargets` primitive: `.pointerIconButton()` REPLACES the
// button style, which strips the macOS 26 toolbar treatment and stops this
// matching the system toggle beside it — the opposite of the goal. That
// primitive is scoped to CUSTOM-DRAWN controls; this is a system-styled one.
// (Contrast the gateway pill in `MainWindowView`, which draws its own capsule
// and suppresses system glass, and therefore does use the primitive.) For the
// same reason this sets no `.sharedBackgroundVisibility` — it WANTS the system
// capsule, which is what makes it read as a peer of the toggle when collapsed.
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

    /// macOS: `.primaryAction` is what Apple documents for this exact action —
    /// its own example for the placement is "compose a new message in a chat
    /// app" — and it docks LEADING there. Measured, it resolves to the same
    /// toolbar slot as `.automatic` (same array index, same sidebar region, same
    /// geometry in both sidebar states), so it costs nothing and stops the
    /// arrangement resting on how `.automatic` happens to resolve.
    ///
    /// iOS: `.primaryAction` docks TRAILING, so iPad keeps `.navigation` — the
    /// only placement that is both available and leading there.
    private var placement: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .navigation
        #endif
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: placement) {
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

        #if os(macOS)
        // Keeps compose and the sidebar toggle two separate capsules instead of
        // one fused pill. macOS only: on iPad this content sits on the detail
        // column ahead of the principal gateway control, where a spacer would
        // push that control off centre for no gain — the two are already in
        // different groups there.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        #endif
    }
}

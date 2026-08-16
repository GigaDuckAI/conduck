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
// macOS: on the SIDEBAR COLUMN, in both sidebar states.  iPad: on the SIDEBAR
// COLUMN while its bar is on screen, the DETAIL COLUMN otherwise.
// That is THREE call sites (`MainWindowView` once, `ConversationLibraryView`
// twice), none interchangeable with another, and the type cannot enforce it —
// so read the measured reasons below before moving any of them.
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
// ── iPad: TWO ATTACHMENTS, ONE PER SIDEBAR STATE ───────────────────────────
// iPadOS gives each column its OWN navigation bar, and the sidebar column's bar
// dies with its column — measured, everything declared there (Delete-All
// included) leaves the accessibility tree the instant the sidebar collapses. So
// iPad has neither macOS property: no unified toolbar, and no item that outlives
// its column. No single attachment point reaches both states, and two do — the
// sidebar column carries compose while that column's bar is on screen, the
// detail column carries it otherwise. `ConversationLibraryView.sidebarBarOnScreen`
// picks between them, and its doc comment carries the fail-safe reasoning: the
// detail bar is on screen in EVERY column state, so any ambiguity about where
// the sidebar column is must resolve toward the detail copy. Zero compose
// buttons strands the user; a transient duplicate does not.
//
// ── MEASURED, iPad Pro 12.9-inch (6th gen), iPadOS 26.5 simulator ──────────
// The founder's own geometry. Artifacts under `final-probe/`, taken on the
// arrangement in this file. Frames are absolute window x from `idb ui
// describe-point` sweeps across the whole bar row (a flat `describe-all` does
// not reach either column's bar); the toolbar row is y 36 h 36.
//
//   PORTRAIT 1024x1366pt, sidebar column x 10–330
//
//   — sidebar SHOWING — everything in the SIDEBAR bar, drawn flat in its one
//     rounded panel, no per-item capsule (`ax-V1-final-portrait-expanded.json`)
//     Delete-All   14.0–62.0
//     compose     214.5–265.5
//     toggle      271.5–326.0
//     6pt compose→toggle, 4pt toggle→column edge. Item for item the macOS
//     arrangement, which is why parity is reachable. Delete-All's own inset is
//     the system's; `ConversationListView.deleteAllPlacement` carries the
//     levers built and probed against it.
//
//   — sidebar HIDDEN — the sidebar bar is gone, the detail bar is all there is
//     (`ax-V2-final-portrait-collapsed.json`)
//     toggle      14.0–50.0   CAPSULE
//     compose     72.5–103.5  CAPSULE      22.5pt apart
//
//   LANDSCAPE 1366x1024pt — SCREENSHOT evidence only
//     `V3-final-landscape-expanded.png` (sidebar up) and
//     `V4-final-landscape-collapsed.png` (sidebar down) show the same
//     arrangement and, collapsed, exactly one compose glyph beside the toggle
//     at the leading edge with nothing at the trailing edge. No AX frames are
//     quoted for landscape: `describe-point` takes UNROTATED coordinates there
//     and a mis-mapped sweep silently returns bottom-of-screen elements, so a
//     sweep result would need its own cross-check to mean anything.
//
// WHY the detail host takes `.topBarLeading`: it names the leading slot
// outright rather than leaving it to a placement that has to resolve, and it
// measures there in every collapsed state probed. NO CLAIM is made about
// `.navigation` on this attachment — no experiment in this corpus swapped it,
// so nothing here rules it in or out.
//
// WHY the detail item is CONDITIONAL rather than mounted-but-hidden: `.opacity`
// holds the leading slot, but it also leaves an empty 36pt glass capsule
// floating in the detail bar the whole time the sidebar is open, and
// `.sharedBackgroundVisibility(.hidden)` is a property of the ITEM — it would
// strip the capsule from the VISIBLE collapsed button too.
//
//   ORDER collapsed is toggle → compose, the mirror of macOS, and it is the
//   system's choice: iPadOS pins its reveal control leading-most in the detail
//   bar. This file records no iPadOS reorder experiment, so it claims neither
//   that a lever exists nor that one is inert — only the measured order.
//
// WHY no `ToolbarSpacer` on iPad in EITHER host: its bars do not fuse adjacent
// items. The sidebar bar draws them flat inside one panel with a 6pt system gap,
// and the collapsed detail bar's two capsules already sit 22.5pt apart.
//
// WHY the iPad cluster is not hand-drawn: an iPadOS nav bar is all-or-nothing,
// so hand-placing ONE control beside the system toggle is not an available
// option — an overlay draws ON TOP of the toggle, not beside it. The reachable
// hand-draw hides both columns' bars and rebuilds the whole top band (the
// centred gateway control, Delete-All, the safe-area/scroll-inset contract,
// Dynamic Type metrics, pointer hover, keyboard focus order, and the toggle's
// localized VoiceOver name plus its expanded/collapsed state) for one gain a
// system bar cannot give.
//
// ── THE TRAILING-COMPOSE OBSERVATION: UNREPRODUCED ─────────────────────────
// The founder observed a `square.and.pencil` at the TRAILING edge of the
// collapsed bar, with nothing at the leading edge, on a 12.9-inch iPad Pro, in
// the empty-thread mascot state. That observation is what set this rework
// going, and it is UNREPRODUCED: it has been hunted on that exact geometry, in
// portrait and landscape, and every probe puts compose at the LEADING edge with
// nothing at the trailing one. NO MECHANISM IS CLAIMED — do not write a comment
// in this file that asserts one. Probing settled states also cannot rule out a
// sub-frame window, and it says nothing about the presentations the simulator
// cannot reach (see `sidebarBarOnScreen`).
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
// WHY no `MacPointerTargets` primitive: `.pointerIconButton()` OVERRIDES the
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
    /// Which split-view column this instance is attached to. macOS has exactly
    /// one call site (`.sidebar`) and resolves the same placement either way;
    /// iPad has two, mutually exclusive, picked by
    /// `ConversationLibraryView.sidebarBarOnScreen`.
    enum Column { case sidebar, detail }

    let column: Column

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
    /// iOS: `.primaryAction` docks TRAILING — which inside the sidebar column's
    /// own bar means immediately LEFT of the trailing-pinned system toggle, the
    /// macOS relationship. The detail host takes `.topBarLeading`, which names
    /// the leading slot outright rather than leaving it to a placement that has
    /// to resolve; the header carries the frames for both.
    private var placement: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        switch column {
        case .sidebar: .primaryAction
        case .detail:  .topBarLeading
        }
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
        // one fused pill. macOS only: iPad needs no spacer in either host —
        // measured, its bars never fuse adjacent items (6pt flat gap in the
        // sidebar bar; 22.5pt between separate capsules in the detail bar), and
        // a spacer ahead of the principal gateway control would push it off
        // centre for no gain.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        #endif
    }
}

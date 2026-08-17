// SPDX-License-Identifier: Apache-2.0

// Conduck
// LeadingToolbarChrome.swift
//
// The compose action for the two SPLIT-VIEW surfaces — the macOS unified window
// (`MainWindowView`) and the iPad library (`ConversationLibraryView`) — placed
// so it reads as the sidebar toggle's neighbour in BOTH sidebar states. macOS
// puts the pair inside one toolbar and reads compose → toggle throughout. iPad
// reads compose → toggle inside the sidebar bar while that column is up, and
// toggle → compose once the column is gone — an inversion the platform imposes
// and no lever removes; the seven measured against it are below.
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
// detail bar is present in EVERY column state, so any ambiguity about where the
// sidebar column is must resolve toward the detail copy. Zero compose buttons
// strands the user; a transient duplicate does not.
//
// THE ALTERNATIVE — one unconditional item in the detail bar, making "exactly
// one compose button" a property of the view tree instead of two signals
// agreeing — was built and measured (frames in the lever table below, expanded
// compose at 356.5–387.5). It is a genuinely stronger guarantee and it is NOT
// what ships: expanded, it puts compose across the column divider, 30.5pt from
// the toggle and in a different treatment (capsule vs flat-in-panel), so the two
// stop reading as one pair. The product call is that the expanded pair matching
// the macOS window is worth keeping a runtime fail-safe for. If that fail-safe
// ever proves unsound, that arrangement is the measured way out.
//
// ── MEASURED, iPad Pro 13-inch (M5), iPadOS 26.5 simulator ─────────────────
// Frames are absolute window x from `idb ui describe-point` sweeps across the
// whole bar row. A flat `describe-all` is NOT a substitute — but its limit is
// narrower than "it reaches nothing": in portrait it returns ~20 elements and
// DOES return this column's bar items (Delete-All at 14.0, the reveal control at
// 271.5) while missing the detail bar's compose entirely. So it can report a
// toolbar as empty that a sweep finds fully populated, and a sweep is what any
// frame quoted here rests on. The toolbar row is y 36 h 36. A sweep is only
// trustworthy after a cross-check against an element whose x is already known:
// Delete-All, which iPadOS pins at 14.0 and holds there.
//
//   PORTRAIT 1032x1376pt, sidebar column x 10–330 (the `Sidebar` group's frame)
//
//   — sidebar SHOWING — everything in the SIDEBAR bar, drawn flat in its one
//     rounded panel, no per-item capsule
//     Delete-All   14.0–62.0
//     compose     214.5–265.5
//     toggle      271.5–326.0
//     6pt compose→toggle, 4pt toggle→column edge. Item for item the macOS
//     arrangement, which is why parity is reachable in THIS state. Delete-All's
//     own inset is the system's; `ConversationListView.deleteAllPlacement`
//     carries the levers built and probed against it.
//
//   — sidebar HIDDEN — the sidebar bar is gone, the detail bar is all there is
//     toggle      14.0–50.0    CAPSULE
//     compose     72.5–103.5   CAPSULE      22.5pt apart
//     The order inverts here and cannot be made to match the state above; the
//     lever table below is the evidence.
//
//   LANDSCAPE 1376x1032pt — cross-checked, then swept
//     sidebar HIDDEN    toggle  14.0–50.0    compose  72.5–103.5
//     Identical to portrait: the bar's leading cluster does not reflow with the
//     long edge, and a full-width sweep to 1376 finds nothing else in the row.
//     This state is the DETAIL bar alone, so it is the same measurement whichever
//     column owns compose when the sidebar is up.
//     sidebar SHOWING is NOT measured in landscape on this arrangement. The
//     landscape sweep was run against the one-attachment build, whose expanded
//     compose lives in the detail bar; its numbers do not describe this file's
//     sidebar-bar attachment and are deliberately not quoted here.
//
//     THE COORDINATE TRAP, and the mapping that clears it. AX REPORTS rotated,
//     logical frames (the Application element measures 0–1376 x 0–1032), but
//     `idb ui describe-point` CONSUMES unrotated buffer coordinates, so feeding
//     it a logical point returns a miss or a silently unrelated element. Rotated
//     left, the mapping is `bufferX = 1032 - logicalY`, `bufferY = logicalX`. It
//     was confirmed by containment on three elements of known frame before any
//     toolbar number was trusted — the Settings footer row, the composer's
//     bottom band, and a conversation row — and only then by Delete-All coming
//     back at 14.0, matching portrait. Do not quote a landscape frame that has
//     not passed that check.
//
// ── ORDER: THE COLLAPSED INVERSION IS UNFIXABLE, MEASURED ──────────────────
// macOS reads compose → toggle in both states. iPad matches it while the sidebar
// is up — the sidebar bar renders app items to the LEFT of its trailing-pinned
// reveal control — and cannot match it once the sidebar is down, because iPadOS
// pins the reveal control leading-most in the detail bar and nothing an app
// declares out-ranks it. Seven levers were built and probed against the geometry
// above, one per build, never stacked; the pass criterion was
// `compose.maxX <= toggle.minX` in the COLLAPSED bar, with exactly one compose
// item and one reveal control still present and still working.
//
// An independent review (a different model and harness, not this one) was asked
// whether any untried API could reach it — toolbar customization IDs,
// `.toolbar(id:)`, `UINavigationItem.leadingItemGroups`, `additionalOverflowItems`,
// `UINavigationBarAppearance`, `.principal`/custom title view, `.balanced` /
// `.prominentDetail`, and driving `columnVisibility` by hand. It rated every one
// of them a no, and named only two escapes: own a UIKit `UISplitViewController`
// outright, or hide both bars and hand-draw the top band. Both replace the system
// reveal control with an imitation, which is the cost the last section rejects.
//
//   BASELINE                    toggle  14.0–50.0    compose  72.5–103.5
//
//   `.navigation` on the detail item              MOVES — WRONG DIRECTION
//     toggle  14.0–50.0   compose 984.5–1015.5. The item does not vanish; it
//     relocates to the bar's TRAILING edge, the full width of the screen away
//     from the control it is meant to sit beside.
//
//   `DefaultToolbarItem(kind: .sidebarToggle, placement: .topBarLeading)`
//   declared after compose in the detail bar      NO REORDER
//     toggle 14.0–50.0 unchanged; compose 70.0–111.0, i.e. the SAME glyph in a
//     capsule widened 31.0 → 41.0 with the glyph in its left half and dead
//     padding to its right. It contributes an empty item, not a representation
//     of the real toggle.
//
//   `.toolbar(removing: .sidebarToggle)` on the DETAIL column        INERT
//     toggle 14.0–50.0, compose 72.5–103.5 — baseline, unchanged.
//
//   `.toolbar(removing: .sidebarToggle)` on the SPLIT VIEW           INERT
//     toggle 14.0–50.0, compose 72.5–103.5 — baseline, unchanged.
//
//   `.toolbar(removing: .sidebarToggle)` on the SIDEBAR column   MOVES — FATAL
//     It reaches the SIDEBAR bar's toggle and no other. Expanded, `Hide Sidebar`
//     leaves the tree entirely and compose slides into the vacated slot
//     (214.5–265.5 → 275.0–326.0) while a full-width sweep finds no reveal
//     control anywhere on screen: the sidebar can never be collapsed again. The
//     collapsed detail bar is untouched, because the column carrying the
//     modifier is unmounted by then.
//
//   the same removal + `DefaultToolbarItem(kind: .sidebarToggle,
//   placement: .primaryAction)` declared ahead of compose      NO TOGGLE BACK
//     Expanded: Delete-All 14.0–62.0, compose 275.0–326.0, and still no reveal
//     control. The item does not represent the removed system control.
//
//   `.topBarTrailing` instead of `.primaryAction` on the sidebar item  INERT
//     Expanded: compose 214.5–265.5, toggle 271.5–326.0 — the two placements
//     resolve to the same slot, and the system's toggle stays trailing-most.
//
// So the arrangement this file ships matches macOS while the sidebar is up and
// takes the platform's order once it is down. The other way round — the
// platform's order in BOTH states — is reachable, and is the one-attachment
// build described above; it trades the expanded pair for consistency. Neither
// choice buys both, and no lever here changes that.
//
// WHY the detail item is CONDITIONAL rather than mounted-but-hidden: `.opacity`
// holds the leading slot, but it also leaves an empty 36pt glass capsule
// floating in the detail bar the whole time the sidebar is open, and
// `.sharedBackgroundVisibility(.hidden)` is a property of the ITEM — it would
// strip the capsule from the VISIBLE collapsed button too.
//
// WHY no `ToolbarSpacer` on iPad in EITHER host: neither bar fuses the items
// this file actually declares. The sidebar bar draws compose and the toggle flat
// inside one panel with a 6pt system gap; the collapsed detail bar's two
// capsules sit 22.5pt apart. That is NOT a general "iPad bars never fuse" rule,
// and the lever table above is the counter-example: a `DefaultToolbarItem`
// declared next to compose was absorbed INTO its capsule, widening it 31.0 →
// 41.0. So a second real item added to either bar has to be re-measured, not
// assumed spaced.
//
// WHY the iPad cluster is not hand-drawn: an iPadOS nav bar is all-or-nothing,
// so hand-placing ONE control beside the system toggle is not an available
// option — an overlay draws ON TOP of the toggle, not beside it. The reachable
// hand-draw hides both columns' bars and rebuilds the whole top band (the
// centred gateway control, Delete-All, the safe-area/scroll-inset contract,
// Dynamic Type metrics, pointer hover, keyboard focus order, and the toggle's
// localized VoiceOver name plus its expanded/collapsed state) for one gain a
// system bar cannot give. The narrower hand-draw — remove the system toggle and
// replace just that one control — is measured above: removal reaches only the
// sidebar bar, so it would hand the two sidebar states two different reveal
// controls announcing themselves two different ways to VoiceOver.
//
// ── THE TRAILING-COMPOSE OBSERVATION: UNREPRODUCED ─────────────────────────
// The founder observed a `square.and.pencil` at the TRAILING edge of the
// collapsed bar, with nothing at the leading edge, on a 12.9-inch iPad Pro, in
// the empty-thread mascot state. That observation is what set this rework
// going, and it is UNREPRODUCED by the shipped arrangement: it has been hunted
// on 12.9-inch and 13-inch geometry, portrait and landscape, and every probe of
// the shipped code puts compose at the leading edge with nothing at the trailing
// one. NO MECHANISM IS CLAIMED — do not write a comment in this file that
// asserts one. The `.navigation` row above is the one arrangement measured to
// put compose at the trailing edge, and this file does not use it; that is a
// coincidence of appearance, not an explanation. Probing settled states also
// cannot rule out a sub-frame window, and it says nothing about the
// presentations the simulator cannot reach (iPadOS Split View and Stage Manager
// are unreachable from the probe harness).
//
// WHY never `DefaultToolbarItem(kind: .sidebarToggle, placement:)` — measured on
// BOTH platforms, and neither finding is inferred from the other. On macOS it
// does NOT represent, move, or reorder the toggle: it adds a SEPARATE, EMPTY
// item — 10x10pt inside a ~41pt viewer carrying its own glass — which macOS then
// merges into one capsule with the item beside it, producing a wide pill with
// the glyph in its right half and dead, unclickable padding to its left, and
// AppKit places the real toggle either way. On iPadOS it likewise adds an empty
// item rather than representing the toggle: beside a system toggle it widens the
// neighbouring capsule 31.0 → 41.0 and reorders nothing, and with that toggle
// removed it supplies no control at all. The two platforms' toolbars are
// structurally unrelated — macOS has one `NSToolbar` split by an
// `NSTrackingSeparatorToolbarItem`, iPadOS gives each column an independent nav
// bar — so each half of this finding rests on its own measurement.
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
    /// macOS relationship. The `.detail` host takes `.topBarLeading`, which names
    /// the leading slot outright rather than leaving it to a placement that has
    /// to resolve. The header's lever table carries what every other placement
    /// measured there. Both cases are reachable on iOS — that is the point of
    /// the enum, and the header explains which state each serves — so the enum
    /// stays total and a future iOS sidebar-bar item inherits a measured value
    /// rather than an invented one.
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
        // one fused pill. macOS only: neither iPad host needs a spacer — measured,
        // the sidebar bar draws the pair flat with a 6pt system gap and the
        // collapsed detail bar's two capsules sit 22.5pt apart — and in the detail
        // host a spacer ahead of the principal gateway control would push that
        // control off centre for no gain.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        #endif
    }
}

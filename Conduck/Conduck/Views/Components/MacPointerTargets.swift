// SPDX-License-Identifier: Apache-2.0

// Conduck
// MacPointerTargets.swift
//
// The macOS pointer-affordance layer: the shared button styles that turn every
// custom-drawn control in the app into a real MOUSE target — a hit region that
// matches what the control looks like, a hover wash that says "this is
// clickable", and a pressed state that confirms the click landed.
//
// WHY it exists: the app draws most of its controls itself (`Button { } label:
// { … }` + `.buttonStyle(.plain)`), and a plain button hit-tests only the pixels
// its label actually draws. A settings row that renders as a full-width capsule
// is therefore live only on its text and icon glyphs — the rest of the capsule
// looks identical and does nothing. Multiply that by ~140 call sites and the Mac
// app requires near-pixel-perfect aim everywhere.
//
// MEASURED BEHAVIOUR these styles are built around (macOS 26.5, verified with
// synthesised clicks against a probe harness — do NOT "simplify" past them):
//
//  1. A control's hit region is EXACTLY its laid-out frame. Nothing enlarges it
//     from the outside. `.contentShape(Rectangle().inset(by: -12))`, the
//     `.padding(N)` → `.contentShape` → `.padding(-N)` overflow trick,
//     `.frame(maxHeight: .infinity)`, `.listRowInsets(EdgeInsets())` and
//     `.environment(\.defaultMinListRowHeight, …)` were each measured and each
//     changed the live rect by ZERO points inside a grouped `Form`. The frame is
//     the only lever, so these styles work by growing the frame.
//
//  2. Filling the width is not enough on its own. A row label shaped
//     `HStack { Text(…); Spacer(); chevron }` already spans the row, yet the
//     `Spacer()` region stays dead until `.contentShape(Rectangle())` declares
//     the whole frame hittable. Both halves are required; either alone leaves a
//     dead zone.
//
//  3. A grouped `Form` wraps every row's content box in FIXED padding —
//     measured ~10.4pt above and below (48.8pt row pitch around a 28pt hover
//     wash) plus ~10pt each side. It is PADDING, not a minimum row height, so
//     it survives whatever `minHeight` the row asks for: raising the row's
//     floor grows the wash and pushes the pitch out with it, leaving the dead
//     border exactly as wide. And it belongs to the Form, so nothing applied
//     from inside the row reaches it — `.listRowInsets`, `.listRowBackground`,
//     `.contentShape(inset:)` and negative padding each move the live rect by
//     zero (see (1)), and `.listSectionMargins` does not exist on macOS. A row
//     inside a `Form` is therefore live over its content box and dead over the
//     border around it, by construction. Screens that need the card live edge
//     to edge draw the card themselves instead: `SettingsCard`
//     (`MacSettingsCard.swift`) renders the section chrome with ZERO container
//     padding, so a row's own frame IS the card's full bleed, and its rows take
//     `.settingsCardRowButton()` / `.settingsCardRowLink()` — the same styles
//     with the inset moved inside the live frame and the wash squared off.
//
//  4. A `List` insets its rows the same unreachable way — measured 16pt each
//     side and 4pt above/below under `.listStyle(.inset)` (8pt each side under
//     `.plain`), with `.listRowInsets(EdgeInsets())` moving it by ZERO, exactly
//     as in the `Form`. `.listRowBackground` is the one thing that DOES span the
//     full row band, which is why a selected sidebar row's fill reached the edge
//     while its hover wash did not.
//
//     What DOES move the frame is negative padding applied OUTSIDE the styled
//     button: `.buttonStyle(…)` then `.padding(.horizontal, -16)` measured a
//     268pt live frame → 300pt in a 300pt list, against an untouched control
//     that stayed at 268pt. This does NOT contradict (1): that measurement
//     covers tricks that leave the frame's own size alone and try to widen only
//     the `.contentShape` on top of it. Here the negative padding changes the
//     LAYOUT PROPOSAL, so the frame itself grows — and the hit region follows it
//     because the hit region is the frame. Overshoot is safe: the list clips the
//     wash to its own bounds, measured identical at -16 and -40. Reach it
//     through `.settingsListRowButton()`, which pairs the negative padding with
//     an equal label inset so the text does not move.
//
// DELIBERATELY NOT DONE: no pointing-hand cursor on rows and buttons. macOS
// reserves that cursor for links; System Settings, Finder and Mail all keep the
// arrow over a list row, and a hand everywhere would read as a web page rather
// than a Mac app. The hover wash carries the discoverability instead. Genuine
// inline text links DO take the hand — that is what `.inlineLinkButton()` is for.
//
// EVERY style here is macOS-only. The `View` helpers compile on all platforms and
// fall through to exactly `.buttonStyle(.plain)` off macOS, so iOS / iPadOS /
// watchOS behaviour is byte-for-byte unchanged — touch surfaces already hit-test
// their whole row and have no cursor to feed.

import SwiftUI

// MARK: - Geometry

/// Shared geometry for macOS pointer targets. One home for the numbers so a
/// tweak lands everywhere at once instead of drifting per screen.
enum MacPointer {
    /// Minimum live square for an icon-only control. Apple's pointer guidance
    /// puts the floor at 28pt; a bare SF Symbol glyph is roughly 13pt, which is
    /// where the "I have to aim exactly at the chevron" complaint comes from.
    static let minTarget: CGFloat = 28

    /// Minimum live height for a settings row. The row's own content is often a
    /// single 16pt line, so without a floor the live band is under half the
    /// capsule the user is aiming at.
    static let rowMinHeight: CGFloat = 28

    /// Corner radius of the hover/pressed wash on a full-width row.
    static let rowCornerRadius: CGFloat = 7

    /// The horizontal inset a macOS `List` puts around every row's content —
    /// measured 16pt each side under `.listStyle(.inset)` (and 8pt under
    /// `.plain`). Rows reclaim it with matching negative padding; see
    /// `.settingsListRowButton()` and file-header measurement 4.
    static let listRowInset: CGFloat = 16

    /// The vertical half of the same inset — measured 4pt above and below a
    /// row's content box (a 36pt row content sits in a 44pt row background).
    static let listRowVerticalInset: CGFloat = 4

    /// Corner radius of the wash behind a compact icon control.
    static let iconCornerRadius: CGFloat = 6

    /// Hover/press cross-fade. Short enough to feel instant, long enough not to
    /// strobe when the pointer sweeps down a list.
    static let highlightAnimation: Animation = .easeOut(duration: 0.12)

    /// Outline of a compact control's hover wash. Match the control's OWN drawn
    /// shape: a rounded-square wash behind a circular chrome button tints only
    /// the corner slivers outside the circle, which reads as a rendering bug.
    ///
    /// Declared here rather than nested in `PointerIconButtonStyle` because
    /// `pointerIconButton(size:shape:horizontalPadding:)` is compiled on EVERY
    /// platform and takes it as a defaulted argument — a type behind
    /// `#if os(macOS)` would break the iOS build.
    enum WashShape { case roundedRect, circle, capsule }
}

#if os(macOS)

// MARK: - Disabled appearance

/// How far a disabled control is dimmed.
///
/// MEASURED: SwiftUI's built-in `.plain` renders a disabled label at roughly
/// half strength (peak label luminance 0.912 enabled → 0.488 disabled on this
/// palette). A CUSTOM `ButtonStyle` gets no such treatment for free — it renders
/// a disabled label identically to an enabled one. Since every style here
/// REPLACED `.plain` at its call sites, each one owes that dimming back, or a
/// `.disabled(...)` row looks fully live and silently swallows clicks. The
/// repo's own `MacDiagnosticsActionButtonStyle` reached the same 0.5.
private let pointerDisabledOpacity: Double = 0.5

// MARK: - Shared highlight

/// The wash painted OVER a hovered or pressed control. Returns `.clear` when
/// the control is disabled — a highlight on something inert is a lie about what
/// a click would do.
///
/// It is an overlay, not a background, and that is load-bearing: most of this
/// app's cards, chips and CTAs paint their OWN opaque fill inside the button's
/// label (`AppColors.cardBackground`, `cardBackgroundElevated`,
/// `backgroundSecondary` and the accent pills all have no alpha). A wash behind
/// such a label is completely hidden, so a background-based highlight silently
/// does nothing on exactly the controls that most look like buttons. Over the
/// top, the same 7% warm tint lightens an opaque fill and a transparent row
/// alike. It never intercepts clicks — see `.allowsHitTesting(false)`.
private func pointerHighlightFill(hovering: Bool, pressed: Bool, enabled: Bool) -> Color {
    guard enabled else { return .clear }
    if pressed { return AppColors.pointerPressedFill }
    return hovering ? AppColors.pointerHoverFill : .clear
}

// MARK: - Settings row

/// A full-width settings row: the whole row box is live, washes on hover, and
/// deepens while the mouse is down.
///
/// Reach it through `.settingsRowButton()` rather than naming it directly, so the
/// non-macOS fallback stays in one place.
struct SettingsRowButtonStyle: ButtonStyle {
    /// Where the label sits once the row is stretched to full width. `.leading`
    /// for ordinary rows; pass `.center` for a centred call-to-action so widening
    /// the frame doesn't shove it to the left edge.
    var alignment: Alignment = .leading

    /// Floor for the row's live height. Rows whose content is already taller
    /// (a title over a subtitle) keep their natural height.
    var minHeight: CGFloat = MacPointer.rowMinHeight

    /// Horizontal inset applied to the LABEL inside the live area. Defaults to
    /// 0 so a styled row's text stays exactly where it sits today — the row is
    /// widened by the frame, not by this, and any non-zero value would indent
    /// the styled rows of a Section while its unstyled rows stayed put, leaving
    /// a visibly ragged left edge.
    var horizontalPadding: CGFloat = 0

    /// Corner radius of the hover/pressed wash. Pass 0 inside a `SettingsCard`,
    /// where rows TOUCH: a rounded wash on two adjacent hovered rows leaves an
    /// untinted notch where their corners meet. The card's own `.clipShape`
    /// supplies the outer corners, so squaring the wash costs nothing at the
    /// card's top and bottom edges.
    var washCornerRadius: CGFloat = MacPointer.rowCornerRadius

    func makeBody(configuration: Configuration) -> some View {
        RowBody(
            configuration: configuration,
            alignment: alignment,
            minHeight: minHeight,
            horizontalPadding: horizontalPadding,
            washCornerRadius: washCornerRadius
        )
    }

    /// A `ButtonStyle` is not a `View`, so `@State` and `@Environment` cannot
    /// live on the style itself — SwiftUI never installs storage for them there
    /// and they silently keep their initial value. Hover tracking and the
    /// enabled check therefore go in this nested view, which IS one.
    private struct RowBody: View {
        let configuration: Configuration
        let alignment: Alignment
        let minHeight: CGFloat
        let horizontalPadding: CGFloat
        let washCornerRadius: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                // Grow the row's OWN frame — the only thing that moves the hit
                // region (see file header, measurement 1).
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
                .overlay {
                    RoundedRectangle(cornerRadius: washCornerRadius, style: .continuous)
                        .fill(pointerHighlightFill(
                            hovering: hovering,
                            pressed: configuration.isPressed,
                            enabled: isEnabled
                        ))
                        .allowsHitTesting(false)
                }
                // Last, so the ENTIRE grown frame hit-tests — including the
                // `Spacer()` gap a row label leaves in its middle (measurement 2).
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                // Restores the dimming `.plain` gave these call sites for free.
                .opacity(isEnabled ? 1 : pointerDisabledOpacity)
                .animation(MacPointer.highlightAnimation, value: hovering)
                .animation(MacPointer.highlightAnimation, value: configuration.isPressed)
        }
    }
}

// MARK: - Icon control

/// A compact icon-only control — back chevrons, info "i" buttons, close boxes,
/// overflow menus. Guarantees a `MacPointer.minTarget` square of live area and
/// washes a rounded square behind the glyph on hover.
struct PointerIconButtonStyle: ButtonStyle {
    /// Live square edge. Bump it for a control that should feel chunkier.
    var size: CGFloat = MacPointer.minTarget

    /// Outline of the hover wash.
    var shape: MacPointer.WashShape = .roundedRect

    /// Extra width for a control whose label is a WORD rather than a glyph — a
    /// header's "Save"/"Cancel". Without it the wash hugs the letters with no
    /// side breathing room and reads as a cramped highlight pill.
    var horizontalPadding: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        IconBody(
            configuration: configuration,
            size: size,
            shape: shape,
            horizontalPadding: horizontalPadding
        )
    }

    private struct IconBody: View {
        let configuration: Configuration
        let size: CGFloat
        let shape: MacPointer.WashShape
        let horizontalPadding: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: size, minHeight: size)
                .overlay {
                    washShape
                        .fill(pointerHighlightFill(
                            hovering: hovering,
                            pressed: configuration.isPressed,
                            enabled: isEnabled
                        ))
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                // Restores the dimming `.plain` gave these call sites for free.
                .opacity(isEnabled ? 1 : pointerDisabledOpacity)
                .animation(MacPointer.highlightAnimation, value: hovering)
                .animation(MacPointer.highlightAnimation, value: configuration.isPressed)
        }

        /// Type-erased so the three cases can share one property. `AnyShape`
        /// exists precisely for this and costs nothing at these sizes.
        private var washShape: AnyShape {
            switch shape {
            case .roundedRect:
                AnyShape(RoundedRectangle(cornerRadius: MacPointer.iconCornerRadius, style: .continuous))
            case .circle:
                AnyShape(Circle())
            case .capsule:
                AnyShape(Capsule())
            }
        }
    }
}

// MARK: - Persistent chrome control

/// A header-chrome control that is VISIBLE AT REST — the Settings back chevron,
/// an editor's Cancel. Draws a filled, stroked container the label sits on, and
/// merely brightens it on hover.
///
/// WHY it is not `PointerIconButtonStyle`: that style's affordance is the hover
/// wash alone, so at rest a bare chevron on the window background reads as
/// decoration rather than as a control — the user has to sweep the pointer over
/// it to discover it is clickable. Chrome that anchors a screen has to announce
/// itself before the pointer arrives, so here the resting state carries the
/// affordance and hover only confirms it.
///
/// The resting fill is OPAQUE chrome the label sits ON, so it is drawn as a
/// `.background` with the hover/pressed wash stacked ABOVE it inside that same
/// background — the file's usual overlay-only pattern would paint a wash with
/// nothing underneath it, which is precisely the resting affordance this style
/// exists to provide. Same construction as
/// `MacDiagnosticsActionButtonStyle`.
///
/// Disabled drops the fill AND the stroke, not just the opacity: chrome that
/// still looks like a container is a lie about what a click would do, the same
/// reasoning behind `pointerHighlightFill`'s `guard enabled`.
///
/// A rounded square, deliberately not a circle or capsule — this is header
/// chrome docked to a corner, not a floating control. Arrow cursor, per the
/// file's rule reserving the hand for genuine links.
struct PointerChromeButtonStyle: ButtonStyle {
    /// Live square edge, and the resting container's size.
    var size: CGFloat = 32

    /// Radius of the container and of its hover wash — one shape, so they
    /// cannot disagree at the corners.
    var cornerRadius: CGFloat = 8

    /// Extra width for a WORD label ("Cancel") rather than a glyph, exactly as
    /// `PointerIconButtonStyle` uses it: without it the container hugs the
    /// letters and reads as a cramped pill.
    var horizontalPadding: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        ChromeBody(
            configuration: configuration,
            size: size,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding
        )
    }

    private struct ChromeBody: View {
        let configuration: Configuration
        let size: CGFloat
        let cornerRadius: CGFloat
        let horizontalPadding: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            return configuration.label
                // The style OWNS the label colour — that is how hover reaches
                // `textEmphasis`. A call site that sets its own
                // `.foregroundStyle` on the button applies it closer to the
                // leaf, wins, and freezes the label at one colour.
                .foregroundStyle(labelColor)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: size, minHeight: size)
                .background {
                    ZStack {
                        shape.fill(isEnabled ? AppColors.cardBackgroundElevated : .clear)
                        // Above the resting fill and still behind the label:
                        // the fill is opaque, so a wash painted under it would
                        // never be visible.
                        shape.fill(pointerHighlightFill(
                            hovering: hovering,
                            pressed: configuration.isPressed,
                            enabled: isEnabled
                        ))
                    }
                }
                .overlay {
                    shape
                        // `strokeBorder`, not `stroke`: a centred stroke puts
                        // half its width outside the frame, where the container
                        // it outlines has already ended.
                        .strokeBorder(isEnabled ? AppColors.borderSubtle : .clear, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                // The whole square, not just the rounded container — this style
                // stands in for `PointerIconButtonStyle` at its call sites and
                // must not hand back live area they already have.
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : pointerDisabledOpacity)
                .animation(MacPointer.highlightAnimation, value: hovering)
                .animation(MacPointer.highlightAnimation, value: configuration.isPressed)
        }

        private var labelColor: Color {
            guard isEnabled, hovering else { return AppColors.textSecondary }
            return AppColors.textEmphasis
        }
    }
}

// MARK: - Inline text link

/// An inline text affordance inside prose — "What do I enter here?", "Learn
/// more", a help disclosure. Gets a taller live band than the text's own line
/// box, the pointing-hand cursor (the one place macOS actually wants it), and a
/// brightening on hover instead of a box, so it still reads as text.
struct InlineLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                // Real padding, not the negative-padding overflow trick — that
                // trick was measured to add zero live area (file header, 1).
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .opacity(opacity)
                .onHover { hovering = $0 }
                .pointerStyle(isEnabled ? .link : nil)
                .animation(MacPointer.highlightAnimation, value: hovering)
        }

        private var opacity: Double {
            // Disabled dims rather than staying full-strength — see
            // `pointerDisabledOpacity`.
            guard isEnabled else { return pointerDisabledOpacity }
            if configuration.isPressed { return 0.6 }
            return hovering ? 0.78 : 1
        }
    }
}

// MARK: - Filled call-to-action

/// The flagship forward button of a flow — a filled accent pill ("Continue",
/// "Enable Voice", "Done"). These paint their own OPAQUE fill, so they get a
/// brightness lift rather than a tint wash: a 7% overlay on a saturated accent
/// pill is nearly invisible, while lifting the whole pill reads instantly as
/// "armed". Pressed dips below the resting brightness so the click is
/// unmistakable even though the pointer never leaves the button.
///
/// No pointing-hand cursor: this is a commit, not a link.
struct PrimaryCTAButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CTABody(configuration: configuration)
    }

    private struct CTABody: View {
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .brightness(brightness)
                .onHover { hovering = $0 }
                // Restores the dimming `.plain` gave these call sites for free.
                .opacity(isEnabled ? 1 : pointerDisabledOpacity)
                .animation(MacPointer.highlightAnimation, value: hovering)
                .animation(MacPointer.highlightAnimation, value: configuration.isPressed)
        }

        private var brightness: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return -0.07 }
            return hovering ? 0.10 : 0
        }
    }
}

// MARK: - Choice card

/// A large tappable card — an onboarding choice, a setup lane, the Personal AI
/// "Guided Setup" front door. The whole card is live; hover lifts the fill and
/// brightens the border so the card reads as pickable rather than decorative.
struct ChoiceCardButtonStyle: ButtonStyle {
    /// Match the card's own corner radius so the wash lines up with its edge.
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct CardBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(pointerHighlightFill(
                            hovering: hovering,
                            pressed: configuration.isPressed,
                            enabled: isEnabled
                        ))
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                // Restores the dimming `.plain` gave these call sites for free.
                .opacity(isEnabled ? 1 : pointerDisabledOpacity)
                .animation(MacPointer.highlightAnimation, value: hovering)
                .animation(MacPointer.highlightAnimation, value: configuration.isPressed)
        }
    }
}

#endif

// MARK: - Call-site API

extension View {
    /// The canonical treatment for a settings row that is a `Button`: full-width
    /// live area, a raised minimum height, a hover wash and a pressed state.
    ///
    /// Replaces `.buttonStyle(.plain)` at row call sites. Off macOS it IS
    /// `.buttonStyle(.plain)` — touch already hit-tests the whole row, so nothing
    /// about the iOS build changes.
    ///
    /// - Parameters:
    ///   - alignment: where the label sits in the widened row. Pass `.center`
    ///     for a centred call-to-action.
    ///   - minHeight: floor for the live height; taller content keeps its height.
    ///   - horizontalPadding: inset applied to the LABEL inside the live area.
    ///     Defaults to 0 — the row is widened by the frame, not by this, and any
    ///     non-zero value indents the styled rows of a Section while its
    ///     unstyled rows stay put, leaving a visibly ragged left edge. Keep this
    ///     in step with `SettingsRowButtonStyle.horizontalPadding`: call sites
    ///     go through here, so THIS default is the one that ships.
    ///   - washCornerRadius: corner radius of the hover/pressed wash. Pass 0
    ///     where the row owns a full-bleed band that touches its neighbours.
    func settingsRowButton(
        alignment: Alignment = .leading,
        minHeight: CGFloat = MacPointer.rowMinHeight,
        horizontalPadding: CGFloat = 0,
        washCornerRadius: CGFloat = MacPointer.rowCornerRadius
    ) -> some View {
        #if os(macOS)
        buttonStyle(SettingsRowButtonStyle(
            alignment: alignment,
            minHeight: minHeight,
            horizontalPadding: horizontalPadding,
            washCornerRadius: washCornerRadius
        ))
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The treatment for a row that is a `Button` inside a macOS `List` — the
    /// sidebar's conversation rows.
    ///
    /// A `List` insets every row's content (measured 16pt each side, 4pt above
    /// and below) and nothing applied from inside the row reaches that inset,
    /// exactly as in a grouped `Form`. But `.listRowBackground` paints the FULL
    /// row band, so a selected row's fill already runs edge to edge while the
    /// hover wash floated in a narrower rounded box inside it — two different
    /// shapes for the same row, with the outer strip lit by neither and live to
    /// neither.
    ///
    /// The row reclaims the inset by growing its own frame outwards
    /// (file-header measurement 4) and re-applying the same value to the label,
    /// so the wash and the live area both match `.listRowBackground` while the
    /// text does not move by a point. The wash is SQUARED to match it too.
    ///
    /// Off macOS this is exactly `.buttonStyle(.plain)` — the shared list
    /// compiles for iPhone and iPad, where touch already hit-tests the whole row
    /// and the negative padding would shove rows off the screen edge.
    func settingsListRowButton() -> some View {
        #if os(macOS)
        settingsRowButton(
            horizontalPadding: MacPointer.listRowInset,
            washCornerRadius: 0
        )
        .padding(.horizontal, -MacPointer.listRowInset)
        .padding(.vertical, -MacPointer.listRowVerticalInset)
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The `settingsRowButton` of a hand-drawn `SettingsCard` — the treatment
    /// for a row that owns the card's FULL BLEED rather than a `Form`'s inset
    /// content box.
    ///
    /// Two differences from `.settingsRowButton()`, both forced by the card:
    /// the label's inset moves INSIDE the live frame (the card adds no padding
    /// of its own, so anything it added would be dead), and the hover wash is
    /// SQUARED — card rows touch, and a 7pt rounded wash leaves untinted
    /// notches between two adjacent hovered rows. The card's `.clipShape`
    /// supplies the rounded corners at its own top and bottom edges.
    ///
    /// Off macOS this is exactly `.buttonStyle(.plain)` — byte-identical to
    /// what these rows already do on iOS, which matters because the shared
    /// settings screens compile for both.
    ///
    /// - Parameters:
    ///   - alignment: where the label sits in the widened row. Pass `.center`
    ///     for a centred call-to-action.
    ///   - minHeight: floor for the live height; taller content keeps its own.
    func settingsCardRowButton(
        alignment: Alignment = .leading,
        minHeight: CGFloat = SettingsCardMetrics.rowMinHeight
    ) -> some View {
        #if os(macOS)
        buttonStyle(SettingsRowButtonStyle(
            alignment: alignment,
            minHeight: minHeight,
            horizontalPadding: SettingsCardMetrics.rowInset,
            washCornerRadius: 0
        ))
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The `settingsRowLink` of a hand-drawn `SettingsCard`: same full-bleed
    /// live row and same arrow cursor as `.settingsCardRowButton()`, for a
    /// `Link` with a custom label. No-op off macOS, matching
    /// `.settingsRowLink()`.
    ///
    /// - Parameter minHeight: floor for the live height.
    func settingsCardRowLink(minHeight: CGFloat = SettingsCardMetrics.rowMinHeight) -> some View {
        #if os(macOS)
        modifier(SettingsRowLink(
            minHeight: minHeight,
            horizontalPadding: SettingsCardMetrics.rowInset,
            washCornerRadius: 0
        ))
        #else
        self
        #endif
    }

    /// The `.settingsCardRowButton()` of a SPLIT-ACTION row: a composite built
    /// from several sub-`Button`s that all perform the SAME action (the
    /// secret/certificate row shape — a label `Button` plus a trailing status
    /// `Button`, split only so an info tip can sit between them without either
    /// swallowing its tap). Same full-bleed live frame, same squared wash and
    /// same row inset as every other `SettingsCard` row, applied from OUTSIDE as
    /// a `ViewModifier` rather than a `ButtonStyle` because there is no single
    /// `Button` for a style to reach.
    ///
    /// Shares its engine with `.settingsCardRowLink()`: `SettingsRowLink` holds
    /// nothing `Link`-specific, so the two are separate NAMES over one modifier
    /// purely so a call site reads as what it wraps.
    ///
    /// PASS THE ROW'S ACTION. The sub-`Button`s cannot reach the inset band this
    /// modifier adds on either side, so without `action` that band washes under
    /// the pointer and answers nothing — a lit target that does nothing is the
    /// exact defect the card exists to remove, merely at `rowInset` instead of
    /// the `Form`'s 10pt. With it, the uncovered band forwards to the row's one
    /// action. Omit it only for a row that genuinely has none.
    ///
    /// MEASURED (macOS 26.5, synthesised clicks against a probe of this exact
    /// shape): the tap sits UNDER the sub-`Button`s rather than fighting them. A
    /// click on a child fires that child exactly once and never this action; a
    /// click on the bare band fires this action exactly once; and the children's
    /// hit regions and pressed states are identical whether the action is
    /// attached or not — a popover child (`InfoTipButton`) included, which still
    /// receives its own tap. So this neither steals a tap nor double-fires.
    ///
    /// The one-same-action rule still decides WHICH rows may take this modifier,
    /// because one wash promises one row-level action. So:
    ///   - A row whose only live thing is a `Toggle` or a `Picker(.menu)` does
    ///     NOT take this modifier. A `Toggle` row becomes a whole-row `Button`
    ///     that flips the binding (with the switch `.allowsHitTesting(false)` so
    ///     the two cannot both fire) and takes `.settingsCardRowButton()` — the
    ///     shape a grouped `Form` gives a `Toggle` for free. A popup opens on its
    ///     own frame and no row action can raise its menu, so a `Picker` row
    ///     takes `.settingsCardPassiveRow()`.
    ///   - A row holding two INDEPENDENT actions — an `InfoTipButton` beside a
    ///     switch or a popup — takes `.settingsCardPassiveRow()` too: each keeps
    ///     its own affordance and no wash claims a row-level action.
    ///   - A `.segmented` `Picker` is a set of choices, not one action:
    ///     `.settingsCardPassiveRow()` again.
    ///
    /// Off macOS this is a no-op, for the same reason `.settingsCardRowLink()`
    /// is: the row already sits inside a real grouped `Form`, which supplies the
    /// identical inset, pitch and native control styling for free.
    ///
    /// - Parameters:
    ///   - minHeight: floor for the row's live height.
    ///   - action: the row's single action, fired when the pointer lands on the
    ///     part of the row no sub-`Button` covers. Omit ONLY for a row that has
    ///     no row-level action at all — a washed band with nothing behind it is
    ///     the defect this parameter exists to close.
    func settingsCardRowControl(
        minHeight: CGFloat = SettingsCardMetrics.rowMinHeight,
        action: (() -> Void)? = nil
    ) -> some View {
        #if os(macOS)
        modifier(SettingsRowLink(
            minHeight: minHeight,
            horizontalPadding: SettingsCardMetrics.rowInset,
            washCornerRadius: 0,
            action: action
        ))
        #else
        self
        #endif
    }

    /// The PASSIVE counterpart to `.settingsCardRowButton()` /
    /// `.settingsCardRowLink()` / `.settingsCardRowControl()` — for a
    /// `SettingsCard` row that is not a single activation: a
    /// `TextField`/`SecureField` block, a `.segmented` `Picker`, a row holding two
    /// independent controls, or plain descriptive text (a status caption, a
    /// warning banner, a disclosure's expanded body).
    ///
    /// Supplies exactly what the card withholds — the row's own inset and a
    /// height floor — and nothing else: no wash, no `contentShape`, no
    /// `onHover`. A wash here would promise a single row-level action that a
    /// multi-control row does not have.
    ///
    /// It never reaches inside its content, so two control-specific gaps stay
    /// the call site's to close, on the control it owns: outside a `Form` a
    /// `Toggle` renders as a CHECKBOX until it is given `.toggleStyle(.switch)`
    /// (and `.tint` alone does not reshape it), and a `Picker` fills the row's
    /// full width until the call site gives it a `.fixedSize()` or an explicit
    /// trailing width. A `Picker(.menu)` also needs `.labelsHidden()` plus a
    /// hand-rolled sibling label `Text`, since a `Picker`'s own label does not
    /// lay out beside its value outside a `Form`.
    ///
    /// Off macOS this is a no-op — the row already sits inside a real grouped
    /// `Form`, which supplies the identical inset and pitch for free.
    ///
    /// - Parameter minHeight: floor for the row's live height. Defaults to the
    ///   same floor as an active row, so a passive row keeps the rhythm of its
    ///   Button/Toggle/Picker siblings in the same card. Taller content (a
    ///   multi-line `TextField` block) grows past it — this is a floor, not a cap.
    func settingsCardPassiveRow(minHeight: CGFloat = SettingsCardMetrics.rowMinHeight) -> some View {
        #if os(macOS)
        padding(.horizontal, SettingsCardMetrics.rowInset)
            .padding(.vertical, SettingsCardMetrics.passiveRowVerticalInset)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        #else
        self
        #endif
    }

    /// The canonical treatment for an icon-only control: a guaranteed
    /// `MacPointer.minTarget` square of live area plus a hover wash.
    /// `.buttonStyle(.plain)` off macOS.
    /// - Parameters:
    ///   - size: the guaranteed live square.
    ///   - shape: outline of the hover wash — match the control's own drawn
    ///     shape, or a circular button gets a square halo.
    ///   - horizontalPadding: extra width when the label is a word, not a glyph.
    func pointerIconButton(
        size: CGFloat = MacPointer.minTarget,
        shape: MacPointer.WashShape = .roundedRect,
        horizontalPadding: CGFloat = 0
    ) -> some View {
        #if os(macOS)
        buttonStyle(PointerIconButtonStyle(
            size: size,
            shape: shape,
            horizontalPadding: horizontalPadding
        ))
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The treatment for a header-chrome control that must be VISIBLE AT REST —
    /// a Settings back chevron, an editor's Cancel: a filled, stroked container
    /// that brightens on hover, rather than `.pointerIconButton()`'s wash that
    /// only exists under the pointer. `.buttonStyle(.plain)` off macOS.
    ///
    /// The style sets the label's colour itself (that is how hover reaches
    /// `AppColors.textEmphasis`), so the call site must NOT apply its own
    /// `.foregroundStyle` to the button — a call-site modifier lands closer to
    /// the leaf, wins, and pins the label to one colour through every state.
    ///
    /// - Parameters:
    ///   - size: the live square, and the resting container's edge.
    ///   - cornerRadius: radius of the container and its wash.
    ///   - horizontalPadding: extra width when the label is a word, not a
    ///     glyph — 0 for a chevron, ~10 for "Cancel".
    func pointerChromeButton(
        size: CGFloat = 32,
        cornerRadius: CGFloat = 8,
        horizontalPadding: CGFloat = 0
    ) -> some View {
        #if os(macOS)
        buttonStyle(PointerChromeButtonStyle(
            size: size,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding
        ))
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The canonical treatment for an inline text link inside prose: a taller
    /// live band, the pointing-hand cursor, and a hover brightening.
    /// `.buttonStyle(.plain)` off macOS.
    func inlineLinkButton() -> some View {
        #if os(macOS)
        buttonStyle(InlineLinkButtonStyle())
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The canonical treatment for a flow's filled accent call-to-action pill.
    /// Lifts on hover and dips while pressed, instead of the tint wash the other
    /// styles use — a wash is invisible over a saturated opaque fill.
    /// `.buttonStyle(.plain)` off macOS.
    func primaryCTAButton() -> some View {
        #if os(macOS)
        buttonStyle(PrimaryCTAButtonStyle())
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The canonical treatment for a large tappable card.
    /// `.buttonStyle(.plain)` off macOS.
    ///
    /// - Parameter cornerRadius: match the card's own radius so the hover wash
    ///   lines up with its edge.
    func choiceCardButton(cornerRadius: CGFloat = 12) -> some View {
        #if os(macOS)
        buttonStyle(ChoiceCardButtonStyle(cornerRadius: cornerRadius))
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The treatment for a SwiftUI `Link` that carries a CUSTOM label — the
    /// "Open the docs ↗" rows scattered through the help and setup screens.
    ///
    /// `Link` is not a `Button`, so no `ButtonStyle` reaches it and
    /// `.inlineLinkButton()` does nothing there. Left alone, a custom-labelled
    /// `Link` on macOS hit-tests only the glyph runs it draws and never shows the
    /// pointing hand — the one control class where the hand IS the native
    /// answer. Apply this to the `Link` itself, not to its label.
    ///
    /// - Parameter minHeight: floor for the live band. Deliberately does not
    ///   stretch the width: a link should stay as wide as its text so it still
    ///   reads as a link rather than a row.
    func pointerLink(minHeight: CGFloat = 22) -> some View {
        #if os(macOS)
        modifier(PointerLink(minHeight: minHeight))
        #else
        self
        #endif
    }

    /// The treatment for a SwiftUI `Link` shaped like a settings ROW rather than
    /// inline prose — the About screen's "Visit conduck.com / Privacy Policy /
    /// Terms / Discord" rows, which carry an icon, a title and a trailing glyph
    /// and sit between ordinary `Button` rows.
    ///
    /// Same full-width live area and wash as `.settingsRowButton()`, and
    /// deliberately the SAME arrow cursor: these are rows, so giving them the
    /// pointing hand would make one card answer the pointer three different ways
    /// (arrow on "Send Feedback", hand on "Privacy Policy", arrow on "Licenses").
    /// Use `.pointerLink()` for a genuine inline link inside prose, which DOES
    /// take the hand.
    func settingsRowLink(minHeight: CGFloat = MacPointer.rowMinHeight) -> some View {
        #if os(macOS)
        modifier(SettingsRowLink(minHeight: minHeight))
        #else
        self
        #endif
    }

    /// Hover feedback, and optionally the tap, for a control whose own drawn
    /// shape a `ButtonStyle` cannot reach: a fixed-size tile or chip that would
    /// be stretched by `.choiceCardButton`'s full-width frame, a custom-drawn
    /// cell, a row that owns a `.onTapGesture` for a non-activation reason.
    ///
    /// Pass `action` for a SPLIT-ACTION composite — a chip whose padding ring
    /// sits outside every sub-`Button`, so the wash would otherwise light a band
    /// that answers nothing. This is `.settingsCardRowControl()`'s shape for a
    /// container that is not a card row: same `RowActionTap`, same measured
    /// contract (a click on a child fires only that child, a click on the bare
    /// band only this action), without the full-width frame and squared wash a
    /// card row needs. The one-same-action rule carries over — the action a bare
    /// click lands on must be the composite's PRIMARY one, and a sub-`Button`
    /// with a DIFFERENT action keeps its own affordance (`.pointerIconButton()`).
    ///
    /// Without `action` this paints the wash and nothing else, so it gives no
    /// keyboard or VoiceOver activation — the content must already carry that
    /// (wrap a `Button`, as the image-grid tile and the thread's file chips do).
    /// No-op off macOS.
    func pointerHoverWash(
        cornerRadius: CGFloat = MacPointer.rowCornerRadius,
        action: (() -> Void)? = nil
    ) -> some View {
        #if os(macOS)
        modifier(PointerHoverWash(cornerRadius: cornerRadius, action: action))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Backing modifier for `settingsRowLink`. A `ViewModifier` rather than a
/// `ButtonStyle` because `Link` routes through a button style only incidentally;
/// this keeps the row treatment explicit and cursor-free.
private struct SettingsRowLink: ViewModifier {
    let minHeight: CGFloat

    /// Inset applied to the LABEL inside the live area, mirroring
    /// `SettingsRowButtonStyle.horizontalPadding`: the frame below widens the
    /// row PAST this padding, so it indents the text without costing live area.
    /// Defaults to 0 so a `Form` row's text stays flush with its unstyled
    /// neighbours; a `SettingsCard` row passes `SettingsCardMetrics.rowInset`.
    var horizontalPadding: CGFloat = 0

    /// Corner radius of the hover wash — 0 inside a `SettingsCard`, for the
    /// touching-rows reason spelled out on `SettingsRowButtonStyle`.
    var washCornerRadius: CGFloat = MacPointer.rowCornerRadius

    /// The row's single action, for a SPLIT-ACTION row whose sub-`Button`s
    /// cannot reach the inset band this modifier adds. Nil for a `Link` row,
    /// where the `Link` itself owns activation across the whole frame.
    var action: (() -> Void)? = nil

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: washCornerRadius, style: .continuous)
                    .fill(pointerHighlightFill(hovering: hovering, pressed: false, enabled: isEnabled))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            // AFTER `contentShape`, so the tap covers the whole padded frame
            // including the inset band. MEASURED to sit under the sub-`Button`s:
            // a click on a child fires only that child, a click on the bare band
            // only this — see `settingsCardRowControl`.
            .modifier(RowActionTap(action: action))
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : pointerDisabledOpacity)
            .animation(MacPointer.highlightAnimation, value: hovering)
    }
}

/// Attaches the row-level tap only when there IS one. A `.onTapGesture` wired to
/// an empty closure would still claim the band and swallow the click silently,
/// which reads to the user exactly like the dead band being fixed.
private struct RowActionTap: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture { action() }
        } else {
            content
        }
    }
}

/// Backing modifier for `pointerLink`.
private struct PointerLink: ViewModifier {
    let minHeight: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
            .opacity(hovering && isEnabled ? 0.78 : 1)
            .onHover { hovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
            .animation(MacPointer.highlightAnimation, value: hovering)
    }
}

/// Backing modifier for `pointerHoverWash`.
private struct PointerHoverWash: ViewModifier {
    let cornerRadius: CGFloat

    /// The composite's primary action, for a SPLIT-ACTION call site whose
    /// sub-`Button`s cannot reach the padding ring this wash covers. Nil where
    /// the content already hit-tests everything the wash lights.
    var action: (() -> Void)? = nil

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(pointerHighlightFill(hovering: hovering, pressed: false, enabled: isEnabled))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            // AFTER `contentShape`, so the tap covers everything the wash lights.
            // Sits UNDER the sub-`Button`s — see `settingsCardRowControl`.
            .modifier(RowActionTap(action: action))
            .onHover { hovering = $0 }
            .animation(MacPointer.highlightAnimation, value: hovering)
    }
}
#endif

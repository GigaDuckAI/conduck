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
//  3. A grouped `Form` adds a constant ~21pt of vertical inset per row and ~9pt
//     of horizontal gutter between the section card's edge and the row's content
//     box. That margin belongs to the Form and is unreachable — see (1). So a
//     row can be made to fill its content box, not the card's full bleed, and a
//     thin dead border around each row survives by construction. `SettingsRow`
//     therefore also RAISES the row's minimum height, which is the only way to
//     convert dead margin into live target.
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

    func makeBody(configuration: Configuration) -> some View {
        RowBody(
            configuration: configuration,
            alignment: alignment,
            minHeight: minHeight,
            horizontalPadding: horizontalPadding
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

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                // Grow the row's OWN frame — the only thing that moves the hit
                // region (see file header, measurement 1).
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
                .overlay {
                    RoundedRectangle(cornerRadius: MacPointer.rowCornerRadius, style: .continuous)
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
    func settingsRowButton(
        alignment: Alignment = .leading,
        minHeight: CGFloat = MacPointer.rowMinHeight,
        horizontalPadding: CGFloat = 0
    ) -> some View {
        #if os(macOS)
        buttonStyle(SettingsRowButtonStyle(
            alignment: alignment,
            minHeight: minHeight,
            horizontalPadding: horizontalPadding
        ))
        #else
        buttonStyle(.plain)
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

    /// Hover + pressed feedback for something that is NOT a `Button` and cannot
    /// become one (a row that owns a `.onTapGesture` for a non-activation
    /// reason, a custom-drawn cell). Prefer converting to a `Button` — this only
    /// paints the wash, so it gives no keyboard or VoiceOver activation.
    /// No-op off macOS.
    func pointerHoverWash(cornerRadius: CGFloat = MacPointer.rowCornerRadius) -> some View {
        #if os(macOS)
        modifier(PointerHoverWash(cornerRadius: cornerRadius))
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

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: MacPointer.rowCornerRadius, style: .continuous)
                    .fill(pointerHighlightFill(hovering: hovering, pressed: false, enabled: isEnabled))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : pointerDisabledOpacity)
            .animation(MacPointer.highlightAnimation, value: hovering)
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
            .onHover { hovering = $0 }
            .animation(MacPointer.highlightAnimation, value: hovering)
    }
}
#endif

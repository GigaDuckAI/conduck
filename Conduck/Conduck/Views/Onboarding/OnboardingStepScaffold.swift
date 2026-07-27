// SPDX-License-Identifier: Apache-2.0

// Conduck
// OnboardingStepScaffold.swift
//
// Shared layout for every onboarding step (iOS / iPadOS / macOS). Replaces
// the old per-step `VStack { Spacer(); …; Spacer(); action.padding(.bottom) }
// .macOSCentered().scrollableWhenNeeded()` recipe, which buried the primary
// CTA inside the scrolled content. At large Dynamic Type sizes that pushed
// the CTA off the bottom / under the home indicator — effectively
// unreachable.
//
// The scaffold splits each step into a `VStack`:
//   - UPPER content (mascot + title + body) → lives in a greedy `ScrollView`
//     that fills all space above the footer.
//   - FOOTER (primary CTA + optional secondary link) → a VStack SIBLING below
//     the ScrollView, so it's ALWAYS fully on-screen at any text size. The
//     container's content stack respects the bottom safe area, so SwiftUI's
//     keyboard avoidance still raises the whole stack — the footer rides above
//     the software keyboard exactly as before (the one keyboard step,
//     `APIKeyStepView`, keeps its `SecureField` in the scroll body).
//
// Centering: short content is centered inside the ScrollView via
// `frame(minHeight: scrollViewportHeight, alignment: .center)`, where
// `scrollViewportHeight` is the ScrollView's OWN measured height. Because the
// footer is a VStack sibling, the ScrollView's frame IS the real viewport —
// so the height the content is sized against and the height
// `.scrollBounceBehavior(.basedOnSize)` compares against are the SAME box.
//
// Why not `.safeAreaInset(edge: .bottom)` (the previous approach): the inset
// reduced the scroll VIEWPORT to `availableHeight - footerHeight`, but
// `.scrollBounceBehavior` still decided scroll-vs-fit against the FULL frame.
// When accessibility text pushed content TALLER than the reduced viewport yet
// SHORTER than the full frame, bounce-scrolling stayed OFF and the overflow
// rendered UNDER the pinned CTA, unreachable (repro'd on Welcome at
// accessibility-XXXL). Sibling layout makes that overlap structurally
// impossible — the footer can never share pixels with the scroll content.
//
// Width caps apply ONLY on macOS and iPad-regular. iPhone (compact, and
// large iPhones in landscape which report `.regular` — hence the
// `idiom == .pad` guard) stays full-width / visually unchanged at normal
// sizes, so `Constants.Layout.buttonMaxWidth` is left alone (`.infinity` on
// iOS).

import SwiftUI

// MARK: - Step placement (centered ceremony vs. top-anchored wizard)

/// Where a step's content sits in the scroll viewport.
///
/// `.center` (the DEFAULT) is the first-run ceremony treatment: Welcome /
/// Enable-Voice / Completion are single-beat screens, and centering them reads
/// as composed.
///
/// `.top` is the WIZARD treatment, set by `GuidedGatewaySetupView` for every
/// guided gateway step. Centering is actively wrong for a multi-step flow: the
/// gap above the mascot becomes a side-effect of how much body text a step
/// happens to carry (measured across the guided flow: ~120pt on the fork, ~22pt
/// on the helper step, 0 on the adapter step), so the mascot and title JUMP as
/// the user walks the flow — and two steps sit close enough to the
/// centers-vs-scrolls threshold that they flip mode on a longer text wrap or an
/// optional callout. Top-anchoring pins every step's mascot to the same y and
/// lets the variance fall out the bottom, where the pinned footer gives it a
/// deliberate boundary.
enum OnboardingStepPlacement {
    case center
    case top
}

private struct OnboardingStepPlacementKey: EnvironmentKey {
    static let defaultValue: OnboardingStepPlacement = .center
}

/// Top band the HOST reserves for chrome it overlays on top of the step content
/// (`GuidedGatewaySetupView`'s floating Back / ✕ circles). The scaffold pads its
/// scroll content down by this much so tall, top-anchored content can never
/// slide under the chrome. Default `0` — first-run onboarding overlays nothing,
/// so it is unaffected.
private struct OnboardingChromeInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Set by a step host to pick the ceremony (`.center`) or wizard (`.top`)
    /// treatment. See `OnboardingStepPlacement`.
    var onboardingStepPlacement: OnboardingStepPlacement {
        get { self[OnboardingStepPlacementKey.self] }
        set { self[OnboardingStepPlacementKey.self] = newValue }
    }

    /// Height of the host's overlaid top chrome, reserved by the scaffold.
    var onboardingChromeInset: CGFloat {
        get { self[OnboardingChromeInsetKey.self] }
        set { self[OnboardingChromeInsetKey.self] = newValue }
    }
}

// MARK: - Scaffold modifier

/// Lays out an onboarding step: scrollable upper content + a pinned footer.
/// Owns footer-height-aware placement and the iPad/macOS width caps.
private struct OnboardingStepScaffold<Footer: View>: ViewModifier {
    @ViewBuilder let footer: () -> Footer

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// `.center` (first-run ceremony) or `.top` (guided wizard) — see
    /// `OnboardingStepPlacement`.
    @Environment(\.onboardingStepPlacement) private var placement

    /// Top band reserved for the host's overlaid chrome (0 outside the guided flow).
    @Environment(\.onboardingChromeInset) private var chromeInset

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The ScrollView's own measured height (the real viewport above the
    /// footer). Short content is centered against it (or pinned to its top);
    /// tall content scrolls.
    @State private var scrollViewportHeight: CGFloat = 0

    /// A "regular" onboarding surface — macOS (always), or iPad in a
    /// regular-width layout. iPhone (compact, and large iPhones in landscape
    /// that report `.regular`) is excluded via the idiom guard. This single
    /// predicate drives BOTH the width caps below AND the
    /// `onboardingRegularSurface` environment flag (typography + card padding),
    /// so the layout and the type scale can never disagree about what counts
    /// as "the big-screen treatment."
    private var isRegularSurface: Bool {
        #if os(macOS)
        return true
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        #else
        return false
        #endif
    }

    /// Width cap for the upper content (mascot + title + body). Centralized in
    /// `Constants.Layout` alongside the other layout tokens.
    private var contentMaxWidth: CGFloat {
        isRegularSurface ? Constants.Layout.onboardingContentMaxWidth : .infinity
    }

    /// Width cap for the pinned footer (primary CTA + secondary link).
    private var footerMaxWidth: CGFloat {
        isRegularSurface ? Constants.Layout.onboardingFooterMaxWidth : .infinity
    }

    /// Guided wizard (`.top` placement) on a big canvas (macOS / iPad-regular):
    /// bound the whole step (content + footer) to a height-capped PANEL centered
    /// in the region below the chrome band, instead of stretching content-top /
    /// footer-bottom across a tall window with a dead zone in the middle. The
    /// panel height is constant across steps at a given window size, so the
    /// mascot AND the CTA hold their y through step transitions — the same
    /// stability that motivated `.top` placement. When the window is short
    /// (region ≤ cap) the panel fills it and the geometry degrades to exactly
    /// the un-capped layout. Off at accessibility type sizes — large text needs
    /// the full height back.
    private var isPanelSurface: Bool {
        placement == .top && isRegularSurface && dynamicTypeSize < .accessibility1
    }

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    // Reserve the host's overlaid top chrome BEFORE the placement
                    // frame, so the inset is part of the content's height and
                    // survives both placements: top-anchored content starts below
                    // the chrome instead of level with it, and centered content
                    // is nudged down by the same band rather than tucking under it.
                    // In panel mode the reservation moves OUTSIDE the panel (the
                    // trailing `.padding(.top, …)` on the VStack) so it shrinks
                    // the centering region rather than unbalancing the panel.
                    .padding(.top, isPanelSurface ? 0 : chromeInset)
                    // Place short content within the viewport — centered (first-run
                    // ceremony) or pinned to the top (guided wizard). Tall content
                    // grows past `minHeight` and scrolls under both.
                    // `scrollViewportHeight` is the ScrollView's OWN frame (set by
                    // the VStack to exactly the space left above the footer), so
                    // it's both the placement box AND the box
                    // `.scrollBounceBehavior` measures — they can never disagree the
                    // way the old safe-area-inset layout did. No feedback loop: the
                    // ScrollView is greedy and sizes from the VStack, not from this
                    // content.
                    .frame(
                        minHeight: scrollViewportHeight,
                        alignment: placement == .top ? .top : .center
                    )
            }
            .scrollBounceBehavior(.basedOnSize)
            // Drag-to-dismiss the software keyboard, matching the app's other
            // scroll surfaces (`SettingsView`, `ConversationThreadView`). The one
            // onboarding step with a keyboard (`APIKeyStepView`) also adds an
            // explicit `.keyboard`-toolbar Done button for discoverability.
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newValue in
                scrollViewportHeight = newValue
            }

            // Pinned footer — a sibling, NOT a `.safeAreaInset`, so the scroll
            // content can never render beneath it at any Dynamic Type size. The
            // top padding guarantees a gap between the scrollable content's
            // bottom and the CTA: when content is tall enough to scroll (e.g.
            // the Watch step's Ultra disclosure expanded), the last element
            // would otherwise butt flush against the button.
            footer()
                .frame(maxWidth: footerMaxWidth)
                .frame(maxWidth: .infinity)
                // Slightly more breathing room around the CTA on the bigger
                // surfaces (iPad/macOS); iPhone keeps 20/32.
                .padding(.top, isRegularSurface ? 24 : 20)
                .padding(.bottom, isRegularSurface ? 36 : 32)
        }
        // Panel mode (guided wizard on macOS / iPad-regular): cap the step's
        // height, center the capped panel in what remains, and reserve the
        // Back/✕ band ABOVE the centering region. Order is load-bearing:
        // cap → greedy centering frame → external chrome reservation. Outside
        // panel mode all three modifiers are neutral (the VStack is already
        // greedy via the ScrollView; the padding is 0), so iPhone and the
        // first-run `.center` flow render byte-identically.
        .frame(maxHeight: isPanelSurface ? Constants.Layout.onboardingPanelMaxHeight : .infinity)
        .frame(maxHeight: .infinity)
        .padding(.top, isPanelSurface ? chromeInset : 0)
        // Publish the regular-surface flag to every descendant (content +
        // footer). Default is `false` (see the EnvironmentKey), so onboarding
        // text/cards scale up ONLY here, and shared components reused elsewhere
        // in Settings stay at their base size.
        .environment(\.onboardingRegularSurface, isRegularSurface)
    }
}

// MARK: - Responsive typography (iPad / macOS)

private struct OnboardingRegularSurfaceKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// `true` inside an `onboardingStepLayout` rendered on a regular surface
    /// (macOS, or iPad in a regular-width layout). Set ONLY by the scaffold,
    /// using the same predicate that drives the width caps. Defaults `false`
    /// everywhere else — so `onboardingScaledFont` / `onboardingCardPadding`
    /// applied in a component reused OUTSIDE the scaffold, or on iPhone, render
    /// at the base size unchanged.
    var onboardingRegularSurface: Bool {
        get { self[OnboardingRegularSurfaceKey.self] }
        set { self[OnboardingRegularSurfaceKey.self] = newValue }
    }
}

/// One-notch-up semantic font scaling for onboarding text. On a regular surface
/// each base `Font.TextStyle` maps UP one step on the Apple text-style ladder,
/// so the flow doesn't read small/sparse on iPad/macOS; on iPhone (flag false)
/// it returns the base unchanged, byte-for-byte. Scales SEMANTIC styles (not
/// raw point sizes) so the user's Dynamic Type setting keeps working within
/// each style.
private struct OnboardingScaledFont: ViewModifier {
    let base: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design
    @Environment(\.onboardingRegularSurface) private var regular
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    /// Apply the +1 notch ONLY on a regular surface AND while the user's
    /// Dynamic Type is still below the accessibility range. The notch exists to
    /// fill the bigger iPad/macOS screen at normal sizes; once the user is at an
    /// accessibility size the text is already large, so stacking another notch
    /// on top over-inflates the column and overflows the scroll fold. Same
    /// accessibility1 threshold the mascot uses to shrink (see `OnboardingMascot`).
    private var shouldBump: Bool {
        regular && dynamicTypeSize < .accessibility1
    }

    private var resolvedFont: Font {
        let style = shouldBump ? Self.bumped(base) : base
        // `.headline` is inherently semibold; once it's bumped to `.title3`
        // (regular weight) we must re-apply semibold or the CTA / card heading
        // loses its emphasis. Any caller-supplied weight still wins.
        let effectiveWeight: Font.Weight? =
            (shouldBump && base == .headline && weight == nil) ? .semibold : weight
        var font = Font.system(style, design: design)
        if let effectiveWeight { font = font.weight(effectiveWeight) }
        return font
    }

    /// One step up the Apple text-style ladder. The ends (`largeTitle` / `body`)
    /// are no-ops so nothing overshoots.
    private static func bumped(_ style: Font.TextStyle) -> Font.TextStyle {
        switch style {
        case .caption2:    return .caption
        case .caption:     return .footnote
        case .footnote:    return .subheadline
        case .subheadline: return .body
        case .callout:     return .body
        case .body:        return .body
        case .headline:    return .title3
        case .title3:      return .title2
        case .title2:      return .title
        case .title:       return .largeTitle
        case .largeTitle:  return .largeTitle
        @unknown default:  return style
        }
    }
}

/// Card internal padding that grows modestly on iPad/macOS (24) vs iPhone (20).
private struct OnboardingCardPadding: ViewModifier {
    @Environment(\.onboardingRegularSurface) private var regular

    func body(content: Content) -> some View {
        content.padding(regular ? 24 : 20)
    }
}

extension View {
    /// Onboarding-scaffold-aware font: the base style on iPhone / outside the
    /// scaffold; one notch larger on iPad-regular + macOS. Folds in the optional
    /// `weight` (replacing a separate `.fontWeight(...)`) and an optional
    /// `design` (e.g. `.monospaced` for the shell-command block).
    func onboardingScaledFont(
        _ base: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> some View {
        modifier(OnboardingScaledFont(base: base, weight: weight, design: design))
    }

    /// Card internal padding that grows slightly on iPad/macOS. Replaces a
    /// literal `.padding(20)` on onboarding content cards.
    func onboardingCardPadding() -> some View {
        modifier(OnboardingCardPadding())
    }
}

// MARK: - View extension

extension View {
    /// Applies the shared onboarding step layout: this view becomes the
    /// scrollable UPPER content (mascot + title + body — no Spacers, no action
    /// block), and `footer` holds the pinned action block (primary CTA +
    /// optional secondary link). See the file header for the centering math.
    func onboardingStepLayout<Footer: View>(
        @ViewBuilder footer: @escaping () -> Footer
    ) -> some View {
        modifier(OnboardingStepScaffold(footer: footer))
    }
}

// MARK: - Form rail

/// Constrains interactive form content (fields, inline buttons, summary cards) to
/// the SAME width + center line as the pinned footer CTA. On iPhone the Layout
/// tokens are `.infinity`, so this is just full-width-minus-padding; on macOS and
/// regular-width iPad they diverge (the footer caps narrower than the content
/// column), and without this the fields, cards, and inline buttons end up at
/// several different widths/alignments and read as ragged. Mirrors the scaffold's
/// own `footerMaxWidth` logic so a rail-wrapped stack lines up exactly under the
/// footer button.
private struct OnboardingFormRail: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// iPad in a regular-width layout (matches the scaffold's idiom guard so
    /// landscape iPhones reporting `.regular` stay full-width).
    private var isRegularPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    /// Same cap the scaffold applies to the footer, so the rail and the CTA match.
    private var railMaxWidth: CGFloat {
        #if os(macOS)
        Constants.Layout.onboardingFooterMaxWidth
        #else
        isRegularPad ? Constants.Layout.onboardingFooterMaxWidth : .infinity
        #endif
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Constants.Layout.horizontalPadding)
            .frame(maxWidth: railMaxWidth)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Wrap a guided-setup form stack so its fields/cards/buttons share the
    /// footer-CTA width and center line. Children should fill it with
    /// `.frame(maxWidth: .infinity, alignment: .leading)`.
    func guidedFormRail() -> some View {
        modifier(OnboardingFormRail())
    }
}

// MARK: - Shared mascot

extension View {
    /// Standardizes the onboarding mascot image: a per-platform / per-role
    /// height that SHRINKS at accessibility text sizes so it never crowds the
    /// content, plus the shared amber shadow. Apply to the `Image(...)` after
    /// `.resizable().aspectRatio(contentMode: .fit)`.
    ///
    /// `hero` picks the larger size used by the Welcome / Completion /
    /// Shortcut / Action-Button steps (iPhone regular 200 · macOS 140) vs the
    /// smaller mid-flow size (iPhone regular 160 · macOS 120). The menu-bar
    /// step's bespoke 110 is handled by its own call. The compact (landscape
    /// iPhone) sizes are preserved. `scale` is a per-call multiplier (default 1)
    /// for the rare step that wants a slightly larger/smaller mascot than its
    /// tier — it rides on top of the accessibility shrink.
    func onboardingMascot(hero: Bool = false, scale: CGFloat = 1) -> some View {
        modifier(OnboardingMascot(hero: hero, scale: scale))
    }
}

/// Backs `onboardingMascot(hero:)`. Keeps the existing per-platform sizes
/// (iPhone compact 100/80 · regular 200/160; macOS 140/120), then multiplies
/// by ~0.6 once Dynamic Type reaches `.accessibility1`+ so the (now larger)
/// text and CTA aren't crowded. An optional per-call `scale` layers on top.
private struct OnboardingMascot: ViewModifier {
    let hero: Bool
    var scale: CGFloat = 1

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var baseHeight: CGFloat {
        #if os(macOS)
        hero ? 140 : 120
        #else
        if verticalSizeClass == .compact {
            return hero ? 100 : 80
        }
        return hero ? 200 : 160
        #endif
    }

    /// Shrink the mascot at accessibility sizes so the (now larger) text and
    /// CTA never get crowded off-screen; the per-call `scale` rides on top.
    private var height: CGFloat {
        let tierHeight = dynamicTypeSize >= .accessibility1 ? baseHeight * 0.6 : baseHeight
        return tierHeight * scale
    }

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            // Soft neutral depth shadow — grounds the sticker art against the
            // atmosphere's key light. Never a brand tint: the mascot is the only
            // saturated color on the step and a tinted halo would muddy it.
            .shadow(color: Color.black.opacity(0.4), radius: 18, y: 9)
    }
}

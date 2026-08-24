// SPDX-License-Identifier: Apache-2.0

// Conduck
// MacSettingsCard.swift
//
// The macOS settings SECTION CARD, drawn by the app instead of by SwiftUI's
// grouped `Form`. Pairs with `MacPointerTargets.swift`: that file makes a row's
// own frame live, this one makes the row's own frame the card's FULL BLEED, so
// there is nothing left between the two that a click can land in and lose.
//
// WHY it exists: a grouped `Form` wraps every row in FIXED padding — measured
// ~10.4pt above and below (48.8pt row pitch around a 28pt hover wash) and ~10pt
// left and right. That padding belongs to the Form, not to the row, so nothing
// applied from inside the row reaches it, and because it is padding rather than
// a minimum row height it survives any `minHeight` the row asks for.
// `.listRowInsets`, `.listRowBackground`, `.contentShape(inset:)` and negative
// padding each move the live rect by ZERO points, and `.listSectionMargins`
// does not exist on macOS. The dead border is therefore unreachable by
// construction as long as the Form draws the card — so here the card is drawn
// by hand and the Form is not in the picture at all.
//
// THE ONE RULE for this container: it applies ZERO padding around its rows. Any
// padding added here would land OUTSIDE each row's button frame and become new
// dead margin — the exact bug the card exists to remove. Row padding lives
// INSIDE the row's own live frame, supplied by
// `.settingsCardRowButton()` / `.settingsCardRowLink()` (see
// `MacPointerTargets.swift`), which pad the LABEL and then stretch the live
// frame past that padding.
//
// Rows arrive as opaque `Subview`s. The card draws CHROME ONLY — background,
// corner clip, separators, header and footer — and never inspects a row to
// decide whether it is a button, a toggle or passive text. A row that needs a
// treatment asks for it at its own call site.
//
// MEASURED RESOLUTION BEHAVIOUR (macOS 26.5, probe hierarchies rendered through
// `ImageRenderer`). This is the contract a caller honours, not a set of
// inferences — do not re-derive it:
//
//  1. `Group(sections:)` DESCENDS into a custom view whose body is a `Section`.
//     A shared subview that declares its own section therefore arrives here as
//     its own card, with its header and footer intact.
//  2. `Group(subviews:)` descends into custom views as well, so a child's SHAPE
//     decides its row count: a child whose body is a `VStack` is ONE row, a
//     child whose body emits two `Text`s is TWO rows. Whatever must stay a
//     single row says so with a stack of its own.
//  3. `Section { EmptyView() } footer: { … }` is NOT dropped. It resolves to a
//     real section whose content collection is EMPTY, so the card draws a
//     zero-row panel beneath the footnote. A footnote-only section belongs
//     outside the card stack, as free-floating text.
//  4. A LOOSE view among sections becomes its own header-less section — its own
//     bare card. An `EmptyView()` sibling and an `if false { Section … }` both
//     resolve to nothing, so a conditional section costs no phantom card.

import SwiftUI

// MARK: - Geometry

/// Shared geometry for the hand-drawn settings card. Compiled on EVERY platform
/// because `MacPointerTargets`' call-site helpers take these as DEFAULTED
/// ARGUMENTS, and a defaulted argument's expression is type-checked on every
/// platform even when the body it feeds is behind `#if os(macOS)`.
enum SettingsCardMetrics {
    /// Corner radius of the section card. Measured off the card a grouped
    /// `Form` draws, so a converted screen sits beside an unconverted one
    /// without the two reading as different widgets.
    static let cornerRadius: CGFloat = 10

    /// Live height of a card row. This is the measured pitch of a `Form` row —
    /// the difference is that here the whole 48pt is inside the row's own
    /// button frame instead of 28pt of it being live and 20.8pt being Form
    /// padding.
    static let rowMinHeight: CGFloat = 48

    /// Inset of a row's LABEL inside its live frame. Applied by the row, never
    /// by the card: padding applied by the card would sit outside the row's
    /// frame and be dead.
    static let rowInset: CGFloat = 14

    /// Vertical inset of a PASSIVE row's content inside its own frame (see
    /// `.settingsCardPassiveRow()`). Smaller than the horizontal inset on
    /// purpose: `rowMinHeight` already sets the pitch for a short row, and this
    /// only decides how much air a TALL row — a multi-line field block, a
    /// wrapped warning banner — keeps once it grows past that floor.
    static let passiveRowVerticalInset: CGFloat = 10

    /// Gap between stacked cards in a `PlatformSettingsForm`.
    ///
    /// Sized AGAINST the 6pt that binds a header to its card and a card to its
    /// footer, not picked on its own: a section's own parts have to sit far
    /// closer to it than the next section does, or a footer caption and the
    /// header beneath it read as one run of small text and the boundary between
    /// two cards stops being findable. A grouped `Form` buys that separation on
    /// the other platforms; here it is the only thing standing between two
    /// cards, so it carries the whole signal.
    static let sectionSpacing: CGFloat = 28
}

#if os(macOS)

// MARK: - Section card

/// One settings section rendered as a card the app draws itself: a rounded
/// filled panel with its rows butted edge to edge, hairline separators between
/// them, and the optional header above / footer below.
///
/// The API deliberately mirrors `Section`, so converting a screen is mechanical:
///
/// ```swift
/// SettingsCard { rows }
/// SettingsCard { rows } header: { Text("Providers") }
/// SettingsCard { rows } header: { … } footer: { … }
/// SettingsCard { rows } footer: { … }
/// ```
///
/// An omitted header or footer renders no slot and contributes no spacing — the
/// slots are stored as optionals rather than as an `EmptyView` that would still
/// occupy a `VStack` position.
struct SettingsCard<Content: View, Header: View, Footer: View>: View {
    private let rows: Content
    private let cardHeader: Header?
    private let cardFooter: Footer?

    /// Gap between the header and the card's top edge. Small: the header is
    /// already set apart by weight and colour, and a large gap breaks the
    /// header away from the card it names.
    private static var headerGap: CGFloat { 6 }

    /// Gap between the card's bottom edge and its footer caption.
    private static var footerGap: CGFloat { 6 }

    /// Header + footer.
    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.init(rows: content(), cardHeader: header(), cardFooter: footer())
    }

    /// Direct-value init. `PlatformSettingsForm` reaches for this: a `Section`'s
    /// header, content and footer arrive as `SubviewsCollection` VALUES, and
    /// they have to reach the slots as optionals so an empty one can be dropped
    /// rather than rendered as a zero-height slot with live spacing around it.
    init(rows: Content, cardHeader: Header?, cardFooter: Footer?) {
        self.rows = rows
        self.cardHeader = cardHeader
        self.cardFooter = cardFooter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cardHeader {
                cardHeader
                    // The grouped-`Form` section-header treatment: sentence-case
                    // 13pt semibold in the secondary colour. Applied as a
                    // DEFAULT — a header that styles itself (the screens'
                    // existing `zoneHeader`) sets these closer to the leaf and
                    // therefore wins.
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.bottom, Self.headerGap)
            }

            card

            if let cardFooter {
                cardFooter
                    .font(.caption)
                    // A STEP BELOW the header's tone, never level with it. The
                    // next section's header is small secondary text as well, so
                    // with both in one colour a footnote and the header under it
                    // read as a single block and the card boundary vanishes
                    // between them. This also puts the footer in the same
                    // recessive tone every other caption on these screens
                    // already uses.
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.top, Self.footerGap)
            }
        }
    }

    // MARK: Card body

    private var card: some View {
        Group(subviews: rows) { subviews in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(subviews) { subview in
                    subview
                        // Stretch each row to the card's full width so a row
                        // that does not fill on its own still carries a
                        // full-bleed separator. A frame, never padding — see
                        // the file header's one rule.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) {
                            // Every row but the last. A trailing separator
                            // would draw a line along the card's own bottom
                            // edge, which the clip then bevels into the corner.
                            if subview.id != subviews.last?.id {
                                separator
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground, in: cardShape)
        // Load-bearing, not cosmetic: a row's hover wash is a RECTANGLE, and the
        // first and last rows touch the card's edge. Without this clip their
        // wash paints square corners over the card's rounded ones.
        .clipShape(cardShape)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsCardMetrics.cornerRadius, style: .continuous)
    }

    /// The hairline between two rows. Full bleed — the shipping separators run
    /// edge to edge with no leading inset.
    ///
    /// An `.overlay` on the row rather than a sibling `Divider()`, for two
    /// reasons: a sibling would insert its own strip of container-owned dead
    /// height between the rows (the bug again), and an overlay draws ON TOP of
    /// the hover wash, so the separator stays visible while a row is hovered
    /// instead of being swallowed by the tint.
    private var separator: some View {
        Rectangle()
            .fill(AppColors.borderSubtle)
            .frame(height: 1)
            .allowsHitTesting(false)
    }
}

// MARK: Header/footer-free conveniences

extension SettingsCard where Header == EmptyView, Footer == EmptyView {
    /// Rows only — no header slot, no footer slot, no spacing for either.
    init(@ViewBuilder content: () -> Content) {
        self.init(rows: content(), cardHeader: nil, cardFooter: nil)
    }
}

extension SettingsCard where Footer == EmptyView {
    /// Header + rows.
    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) {
        self.init(rows: content(), cardHeader: header(), cardFooter: nil)
    }
}

extension SettingsCard where Header == EmptyView {
    /// Rows + footer, no header.
    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.init(rows: content(), cardHeader: nil, cardFooter: footer())
    }
}

#endif

// MARK: - Adaptive settings container

/// A settings container whose `Section` tree is written ONCE and rendered
/// natively on each platform: hand-drawn `SettingsCard`s on macOS, a grouped
/// `Form` everywhere else.
///
/// It exists for the settings screens compiled for BOTH iOS and macOS, which
/// cannot simply swap `Form` for `SettingsCard` without forking their content
/// into two copies that then drift. Drop-in for `Form { … }.formStyle(.grouped)`:
/// the non-macOS branch IS that expression, so touch behaviour is unchanged.
///
/// Write the content as ordinary `Section`s. On macOS `Group(sections:)` lifts
/// each `Section` declaration back out and feeds its header, content and footer
/// into the matching `SettingsCard` slot; an empty header or footer collection
/// is dropped rather than rendered, or a headerless section would leave phantom
/// spacing above its card. That branch also carries the page chrome a `Form`
/// would otherwise supply — scrolling, the window gutter and the settings rail —
/// so a shared screen needs no macOS-only wrapper of its own.
struct PlatformSettingsForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        // The macOS branch owns the page chrome a `Form` supplies for free on
        // the other platforms: a scroll surface, the window gutter, and the
        // settings reading rail. The gutter is padding INSIDE the rail's cap,
        // and the cap goes on the card stack rather than on the `ScrollView`,
        // so the scroll surface still spans the pane — see `.macSettingsRail()`.
        ScrollView {
            Group(sections: content) { sections in
                VStack(alignment: .leading, spacing: SettingsCardMetrics.sectionSpacing) {
                    ForEach(sections) { section in
                        SettingsCard(
                            rows: section.content,
                            cardHeader: section.header.isEmpty ? nil : section.header,
                            cardFooter: section.footer.isEmpty ? nil : section.footer
                        )
                    }
                }
            }
            .padding(MacSettingsRail.minGutter)
            .macSettingsRail()
        }
        #else
        Form {
            content
        }
        .formStyle(.grouped)
        #endif
    }
}

// Conduck
// InfoTipButton.swift
//
// The ONE popover primitive in the app: a small `info.circle` button that opens a
// plain-English DEFINITION of the field it sits next to. Scope it honestly — a tip
// answers "what is this?", it is not the remedy for a failing gateway (that's the
// error copy + the credential-help sheet + Diagnostics). Keep the vocabulary
// contained to this component; do not scatter `.popover` elsewhere.
//
// Placement contract (every caller must honor it):
//   - The button is a SIBLING of any enclosing row action, NEVER nested inside it.
//     The secret row and the image-history row are Buttons/Menus whose
//     `.contentShape(Rectangle())` claims the whole row — nesting the tip inside
//     one would hand its taps to the row's primary action.
//   - Sibling buttons in a Form row get EXPLICIT `.plain`; an automatic button
//     style inside a List row activates row-wide.
//   - The host row must NOT `.accessibilityElement(children: .combine)` — VoiceOver
//     would fuse the row's primary action and this tip into one element; they must
//     read (and be actionable) as two.
//   - The semantic rule for WHERE it goes: nearest its label, while staying a
//     separate interactive sibling of the row's action. A full-width Button/Menu
//     leaves no gap beside its label, so a row that wants the tip there splits its
//     action in two around the tip (see `secretRow`). Where that split isn't worth
//     it — a Menu, whose label is the control (the iOS image-history row, the
//     file-transfer disclosure) — the tip becomes the row's TRAILING accessory and
//     passes `glyphAlignment: .trailing`.
//
// SIZING — the load-bearing part. A popover asks its content for an IDEAL size
// (an unspecified proposal). A `maxWidth`-only frame forwards that unspecified
// proposal straight to the Text, gets back the Text's ideal size (the whole string
// on ONE line), and clamps only the WIDTH — it never re-measures the Text at the
// clamped width. The popover then comes out one line tall, the Text lays out at the
// clamped width, wraps to six lines, and the overflow is CLIPPED. So the content
// carries a DEFINITE `.frame(width:)`, never `maxWidth`. Do not "simplify" it back.
//
// Adaptation: on iPhone a `.popover` silently degrades to a sheet unless the
// CONTENT carries `.presentationCompactAdaptation(.popover)`. We force the popover
// at ordinary type sizes (a tip is a glance, not a modal), but DELIBERATELY let it
// adapt back to a sheet at accessibility sizes — a forced ~300pt popover at AX5 is
// a column of two-word lines. macOS additionally gets `.help(…)` so a hover
// surfaces the same text with no click.

import SwiftUI

/// One field's tip: an SF Symbol, the popover's title, its body, and the VoiceOver
/// label for the button itself (always specific — "About Gateway URL", never a bare
/// "info").
struct GatewayFieldTip {
    let symbol: String
    let accessibilityLabel: LocalizedStringResource
    let title: LocalizedStringResource
    let message: LocalizedStringResource
}

struct InfoTipButton: View {
    let tip: GatewayFieldTip
    /// Where the glyph sits inside its 44×44 tap target. The tap target is a fixed
    /// HIG minimum, so a centered glyph strands ~14pt of dead space on BOTH sides
    /// and the ⓘ visually drifts away from whatever it annotates. Pushing the glyph
    /// to one edge moves all the slack to the far side: `.leading` when the tip
    /// follows a label, `.trailing` when it is a row's trailing accessory.
    var glyphAlignment: Alignment = .leading

    @State private var isPresented: Bool = false
    @State private var sheetDetent: PresentationDetent = .large
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                // 44×44 minimum tap target (HIG), claimed via `contentShape` so the
                // glyph's own bounds don't shrink it.
                .frame(width: 44, height: 44, alignment: glyphAlignment)
                .contentShape(Rectangle())
        }
        // Explicit `.plain`: an automatic style on a sibling button inside a Form
        // row makes the WHOLE row activate ambiguously.
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tip.accessibilityLabel))
        #if os(macOS)
        .help(Text(tip.message))
        #endif
        .popover(isPresented: $isPresented) {
            tipContent
        }
    }

    // MARK: - Presentation

    @ViewBuilder
    private var tipContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            #if os(iOS)
            if horizontalSizeClass == .compact {
                // Let the compact adaptation stand (iPhone → sheet): scrollable,
                // full width, readable. No `presentationCompactAdaptation(.popover)`
                // here. `.medium` alone is cramped at AX4/AX5, so open on `.large`
                // and let the user pull it down.
                ScrollView {
                    tipBody
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(AppColors.cardBackgroundElevated)
                .presentationDetents([.medium, .large], selection: $sheetDetent)
                .presentationDragIndicator(.visible)
                .presentationBackground(AppColors.cardBackgroundElevated)
            } else {
                accessibilityPopover
            }
            #else
            accessibilityPopover
            #endif
        } else {
            standardPopover
        }
    }

    /// Ordinary type sizes, every surface: a definite-width popover. The ScrollView
    /// is the safety net for the tall cases (a long tip at xxxLarge, or an iPhone in
    /// landscape where the screen is only ~390pt tall) — it scrolls rather than
    /// clipping. `.basedOnSize` keeps it inert when the tip already fits.
    private var standardPopover: some View {
        ScrollView {
            tipBody
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: tipWidth)
        .frame(maxHeight: 460)
        .background(AppColors.cardBackgroundElevated)
        .presentationCompactAdaptation(.popover)
    }

    /// iPad/macOS at accessibility type sizes: still a popover (compact adaptation
    /// can't reach these), so it needs its own definite width and an explicit
    /// height cap or it grows without bound.
    private var accessibilityPopover: some View {
        ScrollView {
            tipBody
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 400)
        .frame(maxHeight: 520)
        .background(AppColors.cardBackgroundElevated)
    }

    /// Total content width, padding included — a 300pt frame leaves 264pt for text.
    /// 300 is safe on the narrowest supported iPhone (375pt) with real margins.
    private var tipWidth: CGFloat {
        #if os(macOS)
        return 340
        #else
        return horizontalSizeClass == .regular ? 360 : 300
        #endif
    }

    // MARK: - Content

    /// Mirrors the shared amber-callout treatment (leading amber glyph · title ·
    /// body) so a tip reads as the same family as the editor's callouts rather than
    /// a foreign floating card.
    private var tipBody: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tip.symbol)
                .font(.subheadline)
                .foregroundStyle(AppColors.brandAmber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(tip.title)
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(tip.message)
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }
}

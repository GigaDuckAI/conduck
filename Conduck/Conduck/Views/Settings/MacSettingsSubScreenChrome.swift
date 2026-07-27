// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MacSettingsSubScreenChrome.swift
//
// The CANONICAL chrome for EVERY macOS Settings sub-screen push (the choosers,
// the providers library, the per-vendor detail — any non-editor screen reached
// via a category `NavigationStack`'s `navigationDestination`).
//
// WHY it exists: on macOS, pushing ANY destination onto a `NavigationStack`
// makes SwiftUI materialize a window toolbar with a back chevron in the
// title-bar region. That toolbar appearing GROWS the window's title-bar area and
// shoves the whole window — sidebar included — downward (the chevron also lands
// over the sidebar). So instead of the native bar we HIDE the toolbar entirely
// (`.toolbar(.hidden)` — exactly what `BufferedEditorChrome` does for the
// buffered editors) and render our own pinned in-pane header via
// `.safeAreaInset(.top)`. The window title bar then stays empty + stable across
// root↔pushed states ⇒ no sidebar shift, and the back affordance lives INSIDE
// the detail pane, never over the sidebar.
//
// Layout mirrors `BufferedEditorChrome.macHeader` for sibling consistency (a
// list → editor jump keeps the title centered): a `ZStack` centers the title
// regardless of the leading button's width, a bottom hairline separates it from
// the scrolling content, opaque `gradientStart` fill so content can't ghost
// through. The buffered EDITORS keep their own (Cancel/title/Save) chrome — this
// is for the non-editor sub-screens, whose only top control is Back.
//
// Back navigation uses `@Environment(\.dismiss)`, which pops the stack and
// resets the parent's `navigationDestination(item:)` binding to nil — identical
// to the native back button it replaces.

import SwiftUI

private struct MacSettingsSubScreenChrome: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    /// The screen title, shown centered in the pinned header.
    let title: String

    func body(content: Content) -> some View {
        content
            // Suppress the nested-stack window toolbar (back chevron + title) —
            // the custom `header` is the sole top bar. `.navigationBar` placement
            // is iOS-only, so use the placement-free visibility overload here.
            .toolbar(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    /// Back (leading) · title (centered). The `ZStack` centers the title
    /// independent of the back button's width; a bottom hairline divides it from
    /// the scrolling content. Sits flush under the detail pane's top edge.
    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppColors.textEmphasis)
                    .lineLimit(1)
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "settings.mac.back",
                        defaultValue: "Back"
                    )))
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider().overlay(AppColors.border)
        }
        // OPAQUE — the detail pane's gradient reads as `gradientStart` at its top
        // edge, so a flat `gradientStart` fill is seamless against it while fully
        // hiding any form content that scrolls underneath.
        .background(AppColors.gradientStart)
    }
}

extension View {
    /// Applies the canonical macOS Settings sub-screen chrome: hides the native
    /// window toolbar (so the sidebar never shifts) and pins a custom header with
    /// a leading back chevron + centered title. Use on EVERY non-editor settings
    /// sub-screen pushed inside a category `NavigationStack`, in place of
    /// `.navigationTitle(...)`. See `MacSettingsSubScreenChrome`.
    func macSettingsSubScreenChrome(title: String) -> some View {
        modifier(MacSettingsSubScreenChrome(title: title))
    }
}

// MARK: - Settings content rail

/// The shared macOS Settings reading rail: content capped at 720pt, centered,
/// with a 28pt minimum gutter. For `Form`/`List`-based pages apply the cap via
/// `.contentMargins(.horizontal, MacSettingsRail.margin(for: paneWidth))` on
/// the FORM (inside a `GeometryReader` for the pane width) — never via
/// `.frame(maxWidth:)` on the form itself, which shrinks the scroll surface to
/// the rail and leaves a wide window's margins as dead, unscrollable glass.
enum MacSettingsRail {
    static let maxWidth: CGFloat = 720
    static let minGutter: CGFloat = 28

    /// The horizontal content margin that centers a `maxWidth` rail in a pane
    /// of `paneWidth`, never tighter than `minGutter`.
    static func margin(for paneWidth: CGFloat) -> CGFloat {
        max(minGutter, (paneWidth - maxWidth) / 2)
    }
}
#endif

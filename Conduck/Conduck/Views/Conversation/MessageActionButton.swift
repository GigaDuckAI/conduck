// SPDX-License-Identifier: Apache-2.0

// Conduck
// MessageActionButton.swift
//
// Message footer controls shared by the iPhone/iPad/Mac thread and Mac quick
// reply. Playback stays directly accessible; Copy and Save to Work live in a
// labelled ellipsis menu, separate from the selectable message text. Two jobs:
//   1. A generous, platform-correct INVISIBLE hit region around a small visible
//      glyph (the old 12pt glyph had a sub-minimum tap target with zero slop).
//      iOS gets a full 44×44pt touch target (Apple HIG minimum is 44pt); macOS —
//      a precise-pointer surface — gets a tighter 28×24pt label frame, which
//      `.pointerIconButton()` then grows to the 28pt pointer floor in both axes.
//      `.contentShape` makes the whole (otherwise transparent) frame tappable,
//      not just the glyph.
//   2. Platform-correct feedback: macOS takes the shared `.pointerIconButton()`
//      treatment (hover wash + pressed wash), because a mouse needs hover to
//      learn a bare glyph is a control at all; touch surfaces have no hover to
//      feed and keep `PressableFooterButtonStyle`'s subtle press-scale, which is
//      Reduce-Motion aware (static under Reduce Motion).
//
// The control is content-agnostic: callers pass either a system-symbol name
// (Copy) or arbitrary label content (Speak, whose glyph is state-driven —
// idle/loading/playing — and includes a `ProgressView` in the loading state).
// Accessibility label is required so VoiceOver reads "Speak aloud" / "Loading" /
// "Stop" / "Copy" / "Copied" correctly.

import SwiftUI

// MARK: - Hit-region metrics (per platform)

/// Footer action-button hit-region size. iOS uses a full 44×44pt target (the HIG
/// minimum in both axes); macOS uses a tighter pointer-precise target.
/// Centralized so playback and the actions menu stay identical.
private enum FooterHitRegion {
    #if os(macOS)
    static let width: CGFloat = 28
    static let height: CGFloat = 24
    #else
    static let width: CGFloat = 44
    static let height: CGFloat = 44
    #endif
}

// MARK: - MessageActionButton

/// A footer action button with a generous invisible hit region + press style.
/// Use the convenience `systemImage:` initializer for a plain state-less glyph
/// (Copy), or the `content:` initializer for state-driven label content (Speak).
struct MessageActionButton<Label: View>: View {
    /// VoiceOver label (already localized by the caller). Switches with state
    /// for the Speak control (Speak aloud / Loading / Stop).
    let accessibilityLabel: Text
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                // The visible glyph sits centered inside a transparent frame
                // that is the actual tap target. `.contentShape(Rectangle())`
                // makes the whole frame (not just the glyph pixels) hittable.
                .frame(width: FooterHitRegion.width, height: FooterHitRegion.height)
                .contentShape(Rectangle())
        }
        // See header note 2: the pointer surface trades the press-scale for the
        // shared hover/pressed wash and the `MacPointer.minTarget` live square.
        #if os(macOS)
        .pointerIconButton()
        #else
        .buttonStyle(PressableFooterButtonStyle())
        #endif
        .accessibilityLabel(accessibilityLabel)
    }
}

extension MessageActionButton where Label == AnyView {
    /// Convenience for a plain state-less system-symbol glyph (Copy). The glyph
    /// is rendered at 16pt with the supplied tint.
    init(
        systemImage: String,
        size: CGFloat = 16,
        tint: Color,
        accessibilityLabel: Text,
        action: @escaping () -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.label = {
            AnyView(
                Image(systemName: systemImage)
                    .font(.system(size: size))
                    .foregroundStyle(tint)
            )
        }
    }
}

// MARK: - MessageActionsMenu

/// A visible menu keeps secondary actions discoverable without taking over
/// text selection. File recovery belongs beside a relevant file problem,
/// so every host offers only Copy and Save to Work here. The one host whose
/// bar has no room for a Copy-conversation item — the iPhone thread — hands
/// in `onCopyConversation`, and the menu grows a separated thread-level row.
/// The checkmark briefly acknowledges Copy even after the native menu closes.
struct MessageActionsMenu: View {
    let didCopy: Bool
    var size: CGFloat = 16
    let tint: Color
    let onCopy: () -> Void
    let onSaveToWork: () -> Void
    /// Whole-thread copy. Nil where the bar already carries that action.
    var onCopyConversation: (() -> Void)? = nil

    var body: some View {
        Menu {
            Button(action: onCopy) {
                Label(
                    LocalizedStringResource("bubble.actions.copy", defaultValue: "Copy message"),
                    systemImage: "doc.on.doc"
                )
            }
            Button(action: onSaveToWork) {
                Label(
                    LocalizedStringResource("workboard.chatCapture.action", defaultValue: "Save message to Work"),
                    systemImage: "rectangle.stack.badge.plus"
                )
            }
            if let onCopyConversation {
                // A divider and a different glyph: two rows that both say
                // "copy" must never look like one action listed twice.
                Divider()
                Button(action: onCopyConversation) {
                    Label(
                        LocalizedStringResource("thread.copyAll.button", defaultValue: "Copy conversation"),
                        systemImage: "doc.plaintext"
                    )
                }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "ellipsis")
                .font(.system(size: size))
                .foregroundStyle(tint)
                .frame(width: FooterHitRegion.width, height: FooterHitRegion.height)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        #if os(macOS)
        .pointerIconButton()
        #else
        .buttonStyle(PressableFooterButtonStyle())
        #endif
        .accessibilityLabel(Text(LocalizedStringResource(
            "bubble.actions.menu", defaultValue: "Message actions"
        )))
        .help(Text(LocalizedStringResource(
            "bubble.actions.menu", defaultValue: "Message actions"
        )))
    }
}

// MARK: - PressableFooterButtonStyle

/// Subtle press feedback for the footer action buttons: scales the glyph down
/// while pressed so the control feels tactile. Reduce-Motion aware — under
/// Reduce Motion the scale is pinned to 1.0 (no movement), so the state change
/// is instant + static. Shared by Speak + Copy for a consistent feel on the
/// touch surfaces; macOS uses the shared pointer treatment instead.
struct PressableFooterButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scale(pressed: configuration.isPressed))
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }

    private func scale(pressed: Bool) -> CGFloat {
        guard pressed, !reduceMotion else { return 1.0 }
        return 0.88
    }
}

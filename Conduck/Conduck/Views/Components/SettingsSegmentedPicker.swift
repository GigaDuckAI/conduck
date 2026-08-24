// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsSegmentedPicker.swift
//
// A segmented CHOICE control for the settings surfaces — a small closed set the
// user flips between in place (a usage range, a chart measure), where a popup
// menu would hide the alternatives behind a click.
//
// TWO IMPLEMENTATIONS, ONE CALL SITE. On iOS / iPadOS this IS the system
// control: `Picker` + `.pickerStyle(.segmented)` + the brand tint, exactly what
// these screens already shipped, so the approved iPhone look does not move by a
// pixel. On macOS the system control is `NSSegmentedControl`, which draws
// system-grey chrome and applies a tint to half of itself — beside the app's
// hand-drawn dark cards it reads as a control borrowed from another window. That
// branch is drawn here instead, from the same palette as the cards around it.
//
// THE MACOS BRANCH OWES BACK WHAT THE SYSTEM CONTROL GAVE FOR FREE. Two things,
// both easy to lose: the VoiceOver semantics (a container that announces the
// group, segments that announce themselves as selected) and the pointer
// affordances every custom-drawn control in this app carries
// (`MacPointerTargets.swift`) — a full-frame hit region, a hover state and a
// pressed state. Both are reproduced below rather than assumed.
//
// NO STRINGS OF ITS OWN. The group label and every segment title arrive from the
// call site, which already owns them; a control that named its own options would
// be a second place the same words live.

import SwiftUI

/// A segmented picker over a fixed option list.
///
/// - Parameters:
///   - selection: the bound choice.
///   - options: every segment, in display order.
///   - label: the group's accessibility label — the control hides it visually on
///     both platforms, because the surrounding card already names the choice.
///   - title: one segment's visible title.
struct SettingsSegmentedPicker<Option: Hashable>: View {
    @Binding private var selection: Option

    private let options: [Option]
    private let label: Text
    private let title: (Option) -> Text

    init(
        selection: Binding<Option>,
        options: [Option],
        label: Text,
        title: @escaping (Option) -> Text
    ) {
        self._selection = selection
        self.options = options
        self.label = label
        self.title = title
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { option in
                title(option).tag(option)
            }
        } label: {
            label
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(AppColors.brandAmber)
        .accessibilityLabel(label)
        #endif
    }

    #if os(macOS)

    /// Container radius. The segments sit one inset inside it on a slightly
    /// tighter radius, so the selected fill follows the container's curve
    /// instead of cutting across it.
    private static var containerCornerRadius: CGFloat { 8 }
    private static var segmentCornerRadius: CGFloat { 6 }

    /// Gap between the track's edge and a segment — also the gap between two
    /// segments, so a selected segment is framed evenly on every side.
    private static var trackInset: CGFloat { 2 }

    /// Equal-width segments on a filled track, sized to whatever width the host
    /// row offers. A segmented control that hugged its titles would be a
    /// different width on every screen it appears on, and these two call sites
    /// sit in cards of the same width.
    private var macBody: some View {
        HStack(spacing: Self.trackInset) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    title(option)
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        // Dark on amber, the app's one treatment for a label
                        // sitting on a filled brand surface.
                        .foregroundStyle(
                            isSelected ? AppColors.background : AppColors.textSecondary)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(SegmentButtonStyle(
                    isSelected: isSelected,
                    cornerRadius: Self.segmentCornerRadius
                ))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(Self.trackInset)
        .background {
            RoundedRectangle(cornerRadius: Self.containerCornerRadius, style: .continuous)
                .fill(AppColors.backgroundSecondary)
        }
        .frame(maxWidth: .infinity)
        // A cross-fade, not a slide: the fill belongs to whichever segment is
        // selected, and a travelling pill would animate a shape the control
        // does not otherwise have.
        .animation(.easeInOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    #endif
}

#if os(macOS)

/// One segment's pointer treatment, built to `MacPointerTargets.swift`'s rules:
/// the frame is the hit region (`.contentShape` over the whole grown frame), the
/// feedback constants are that file's own, and a disabled control dims rather
/// than staying full-strength.
///
/// TWO FEEDBACK MODES, for the reason `PrimaryCTAButtonStyle` documents: an
/// UNSELECTED segment is transparent, so the 7% warm wash reads on it; a
/// SELECTED one paints opaque brand amber, over which that wash is nearly
/// invisible, so it lifts in brightness instead. One style rather than two so a
/// segment cannot answer the pointer differently depending on which it is.
///
/// Private to this file: it is the segmented control's own chrome, not a
/// treatment other call sites should reach for.
private struct SegmentButtonStyle: ButtonStyle {
    let isSelected: Bool
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(
            configuration: configuration,
            isSelected: isSelected,
            cornerRadius: cornerRadius
        )
    }

    /// A `ButtonStyle` is not a `View`, so hover tracking and the enabled check
    /// live in this nested view — the same construction every style in
    /// `MacPointerTargets.swift` uses, and for the same reason.
    private struct SegmentBody: View {
        let configuration: Configuration
        let isSelected: Bool
        let cornerRadius: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            return configuration.label
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        shape.fill(AppColors.brandAmber)
                    }
                }
                .overlay {
                    shape
                        .fill(washFill)
                        .allowsHitTesting(false)
                }
                // After the background, so a selected segment's fill lifts with
                // its label rather than the label brightening alone.
                .brightness(brightness)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.5)
                .animation(MacPointer.highlightAnimation, value: hovering)
                .animation(MacPointer.highlightAnimation, value: configuration.isPressed)
        }

        /// Unselected segments only — see the style's note. `.clear` while
        /// disabled: a highlight on something inert is a lie about what a click
        /// would do.
        private var washFill: Color {
            guard isEnabled, !isSelected else { return .clear }
            if configuration.isPressed { return AppColors.pointerPressedFill }
            return hovering ? AppColors.pointerHoverFill : .clear
        }

        /// Selected segments only, at `PrimaryCTAButtonStyle`'s measured
        /// amounts: pressed dips below rest so the click registers even though
        /// the pointer never leaves the segment.
        private var brightness: Double {
            guard isEnabled, isSelected else { return 0 }
            if configuration.isPressed { return -0.07 }
            return hovering ? 0.10 : 0
        }
    }
}

#endif

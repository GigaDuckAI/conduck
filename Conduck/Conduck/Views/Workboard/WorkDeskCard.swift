// SPDX-License-Identifier: Apache-2.0

// Spatial card chrome, separate from the material's existing preview, playback,
// repair and share controls. Only the visible grip moves the card. Selection
// and pin controls keep their screen-sized targets as the desk zooms out.

import SwiftUI

struct WorkDeskCard<Content: View>: View {
    let title: String
    let width: CGFloat
    let isSelected: Bool
    let isPinned: Bool
    let isSelecting: Bool
    let isLifted: Bool
    let isGroupTarget: Bool
    let coordinateSpace: UUID
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    let onDragCancelled: () -> Void
    let onNudge: (CGSize) -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            handleBar
            content()
        }
        .frame(width: width)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 19))
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19)
                .strokeBorder(
                    isSelected || isGroupTarget ? AppColors.brandAmber : AppColors.border,
                    lineWidth: isSelected || isGroupTarget ? 2 : 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isLifted ? 0.42 : 0.24), radius: isLifted ? 24 : 12, y: isLifted ? 14 : 7)
        .overlay(alignment: .bottom) {
            if isGroupTarget {
                Label(LocalizedStringResource("workdesk.canvas.groupDrop", defaultValue: "Create a project"), systemImage: "square.stack.3d.up.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppColors.brandAmber, in: Capsule())
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isGroupTarget)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
        .accessibilityElement(children: .contain)
    }

    private var handleBar: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? AppColors.brandAmber : AppColors.textTertiary)
                    .frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44)
            .accessibilityLabel(Text(LocalizedStringResource(
                "workdesk.canvas.selectCard", defaultValue: "Select material"
            )))
            .accessibilityValue(Text(verbatim: title))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            WorkDeskDragGrip(
                title: title,
                coordinateSpace: coordinateSpace,
                onChanged: onDragChanged,
                onEnded: onDragEnded,
                onCancelled: onDragCancelled,
                onNudge: onNudge
            )
            .frame(maxWidth: .infinity)

            if width >= 140 {
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isPinned ? AppColors.brandAmber : AppColors.textTertiary)
                        .frame(width: 44, height: 44)
                }
                .pointerIconButton(size: 44)
                .accessibilityLabel(Text(isPinned
                    ? LocalizedStringResource("workdesk.canvas.unpin", defaultValue: "Unpin material")
                    : LocalizedStringResource("workdesk.canvas.pin", defaultValue: "Pin material")))
                .accessibilityValue(Text(verbatim: title))
            }
        }
        .background(isSelecting ? AppColors.brandAmber.opacity(0.055) : .clear)
    }
}

/// A dedicated grip leaves taps and playback on the mature material card
/// untouched. GestureState also ends a cancelled drag, which onEnded alone
/// cannot observe (for example, when Work loses focus mid-gesture).
struct WorkDeskDragGrip: View {
    let title: String
    let coordinateSpace: UUID
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onCancelled: () -> Void
    let onNudge: (CGSize) -> Void

    @GestureState private var isDragging = false

    var body: some View {
        Image(systemName: "circle.grid.3x2.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppColors.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .pointerHoverWash(cornerRadius: 8)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinateSpace))
                    .updating($isDragging) { _, active, _ in active = true }
                    .onChanged { onChanged($0.translation) }
                    .onEnded { onEnded($0.translation) }
            )
            .onChange(of: isDragging) { _, active in
                if !active { onCancelled() }
            }
            #if os(macOS)
            .pointerStyle(isDragging ? .grabActive : .grabIdle)
            #endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.move", defaultValue: "Move material")))
            .accessibilityValue(Text(verbatim: title))
            .accessibilityHint(Text(LocalizedStringResource("workdesk.canvas.moveHint", defaultValue: "Drag this handle to arrange your desk")))
            .accessibilityActions {
                Button(LocalizedStringResource("workdesk.canvas.moveLeft", defaultValue: "Move left")) { onNudge(CGSize(width: -32, height: 0)) }
                Button(LocalizedStringResource("workdesk.canvas.moveRight", defaultValue: "Move right")) { onNudge(CGSize(width: 32, height: 0)) }
                Button(LocalizedStringResource("workdesk.canvas.moveUp", defaultValue: "Move up")) { onNudge(CGSize(width: 0, height: -32)) }
                Button(LocalizedStringResource("workdesk.canvas.moveDown", defaultValue: "Move down")) { onNudge(CGSize(width: 0, height: 32)) }
            }
    }
}

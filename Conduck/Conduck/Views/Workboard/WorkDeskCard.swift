// SPDX-License-Identifier: Apache-2.0

// A single material surface with spatial selection/lift decoration. Whole-card
// movement, keyboard nudges and accessibility actions share one gesture owner.
// Escape suppresses the held gesture until physical release.

import SwiftUI

// The preview owns the tile's face and border. This wrapper only marks spatial
// selection and lifting; it adds no header, inner panel or fixed-size chrome.
struct WorkDeskCard<Content: View>: View {
    let scale: CGFloat
    let isSelected: Bool
    let isLifted: Bool
    let isGroupTarget: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .overlay {
                RoundedRectangle(cornerRadius: 13 * scale)
                    .strokeBorder(isSelected || isGroupTarget || isLifted ? AppColors.brandAmber : .clear,
                                  lineWidth: isSelected || isGroupTarget ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isLifted ? 0.38 : 0.20),
                    radius: isLifted ? 19 : 8 * scale, y: isLifted ? 11 : 4 * scale)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isGroupTarget)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isLifted)
    }
}

/// A cancelled gesture remains physically held. Forgetting that distinction
/// lets its next update start the drag again and eventually persist a move
/// the person explicitly cancelled.
nonisolated struct WorkDeskGripDragState {
    private(set) var isActive = false
    private(set) var isSuppressed = false

    mutating func beginUpdate() -> Bool {
        guard !isSuppressed else { return false }
        isActive = true
        return true
    }

    @discardableResult
    mutating func cancel() -> Bool {
        guard isActive else { return false }
        isActive = false
        isSuppressed = true
        return true
    }

    /// Returns whether a natural release may commit. The same reset answers
    /// a system cancellation; its caller cancels instead of committing then.
    mutating func release() -> Bool {
        let shouldCommit = isActive && !isSuppressed
        isActive = false
        isSuppressed = false
        return shouldCommit
    }
}

nonisolated enum WorkDeskGripKeyboardPolicy {
    static func translation(for key: KeyEquivalent, modifiers: EventModifiers) -> CGSize? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        let distance: CGFloat = modifiers.contains(.shift) ? 128 : 32
        switch key {
        case .leftArrow: return CGSize(width: -distance, height: 0)
        case .rightArrow: return CGSize(width: distance, height: 0)
        case .upArrow: return CGSize(width: 0, height: -distance)
        case .downArrow: return CGSize(width: 0, height: distance)
        default: return nil
        }
    }
}

extension View {
    /// One high-priority gesture for the whole object, outside its preview and
    /// header. Until movement crosses the threshold, nested buttons keep taps.
    func workDeskObjectDrag(
        coordinateSpace: UUID, isEnabled: Bool, cancellationGeneration: Int,
        onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize) -> Void,
        onCancelled: @escaping () -> Void, onNudge: @escaping (CGSize) -> Void,
        onLocation: @escaping (CGPoint) -> Void, onActivate: @escaping () -> Void
    ) -> some View {
        modifier(WorkDeskObjectDragModifier(coordinateSpace: coordinateSpace, isEnabled: isEnabled,
            cancellationGeneration: cancellationGeneration, onChanged: onChanged, onEnded: onEnded,
            onCancelled: onCancelled, onNudge: onNudge, onLocation: onLocation, onActivate: onActivate))
    }
}

private struct WorkDeskObjectDragModifier: ViewModifier {
    let coordinateSpace: UUID
    let isEnabled: Bool
    let cancellationGeneration: Int
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onCancelled: () -> Void
    let onNudge: (CGSize) -> Void
    let onLocation: (CGPoint) -> Void
    let onActivate: () -> Void

    @GestureState private var isDragging = false
    @State private var dragState = WorkDeskGripDragState()
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .focusable(isEnabled)
            .focused($isFocused)
            .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
                    .updating($isDragging) { _, active, _ in active = true }
                    .onChanged { value in
                        guard isEnabled else { return }
                        let wasActive = dragState.isActive
                        guard dragState.beginUpdate() else { return }
                        if !wasActive { isFocused = true; onActivate() }
                        onLocation(value.location)
                        onChanged(value.translation)
                    }
                    .onEnded { value in
                        if dragState.release() {
                            if isEnabled { onLocation(value.location); onEnded(value.translation) }
                            else { onCancelled() }
                        }
                    },
                including: isEnabled ? .all : .none
            )
            .onChange(of: isDragging) { _, active in
                if !active, dragState.release() { onCancelled() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    if dragState.cancel() { onCancelled() }
                    isFocused = false
                }
            }
            .onChange(of: cancellationGeneration) { _, _ in
                if dragState.cancel() { onCancelled() }
            }
            .onDisappear { if dragState.release() { onCancelled() } }
            .help(Text(LocalizedStringResource("workdesk.canvas.moveObjectHint", defaultValue: "Drag anywhere on a card to arrange your desk")))
            .accessibilityActions {
                Button(LocalizedStringResource("workdesk.canvas.moveLeft", defaultValue: "Move left")) { nudge(.leftArrow) }
                Button(LocalizedStringResource("workdesk.canvas.moveRight", defaultValue: "Move right")) { nudge(.rightArrow) }
                Button(LocalizedStringResource("workdesk.canvas.moveUp", defaultValue: "Move up")) { nudge(.upArrow) }
                Button(LocalizedStringResource("workdesk.canvas.moveDown", defaultValue: "Move down")) { nudge(.downArrow) }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .escape]) { press in
                guard isEnabled, isFocused,
                      press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                if press.key == .escape {
                    if dragState.cancel() { onCancelled() }
                    else if !dragState.isSuppressed { isFocused = false }
                    return .handled
                }
                guard !isDragging,
                      let translation = WorkDeskGripKeyboardPolicy.translation(for: press.key, modifiers: press.modifiers) else { return .ignored }
                onActivate()
                onNudge(translation)
                return .handled
            }
    }

    private func nudge(_ key: KeyEquivalent) {
        guard isEnabled, !isDragging,
              let translation = WorkDeskGripKeyboardPolicy.translation(for: key, modifiers: []) else { return }
        onActivate()
        onNudge(translation)
    }

}

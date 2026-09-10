// SPDX-License-Identifier: Apache-2.0

// Spatial card chrome, separate from the material's existing preview, playback,
// repair and share controls. The entire object can move after a deliberate
// drag threshold; ordinary taps still reach its preview and buttons. Selection
// and pin controls keep their screen-sized targets as the desk zooms out. Escape
// cancels the held gesture and suppresses updates until physical release.

import SwiftUI

struct WorkDeskCard<Content: View>: View {
    let title: String
    let width: CGFloat
    let isSelected: Bool
    let isPinned: Bool
    let isSelecting: Bool
    let isLifted: Bool
    let isGroupTarget: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onNudge: (CGSize) -> Void
    var isNavigating: Bool = false
    var onActivate: () -> Void = {}
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var isActive
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            handleBar
                .environment(\.workbenchDestinationIsActive, isActive && !isNavigating)
                .disabled(isNavigating)
            content()
        }
        .frame(width: width)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 19))
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19)
                .strokeBorder(
                    isSelected || isGroupTarget ? AppColors.brandAmber : isLifted ? AppColors.brandAmber.opacity(0.65) : AppColors.border,
                    lineWidth: isSelected || isGroupTarget || isLifted ? 2 : 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isLifted ? 0.38 : 0.20), radius: isLifted ? 19 : 8, y: isLifted ? 11 : 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isGroupTarget)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isLifted)
        // A tap raises the card while its nested control still owns the action.
        .simultaneousGesture(TapGesture().onEnded { onActivate() })
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button(LocalizedStringResource("workdesk.canvas.selectCard", defaultValue: "Select material"), action: onSelect)
            Button(isPinned
                ? LocalizedStringResource("workdesk.canvas.unpin", defaultValue: "Unpin material")
                : LocalizedStringResource("workdesk.canvas.pin", defaultValue: "Pin material"), action: onTogglePin)
        }
    }

    private var handleBar: some View {
        HStack(spacing: 0) {
            if WorkDeskCardHeaderPolicy.showsSelection(width: width), isSelecting || isSelected {
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
            }

            WorkDeskDragGrip(
                title: title,
                onNudge: onNudge,
                isLifted: isLifted,
                onActivate: onActivate
            )
            .frame(minWidth: WorkDeskCardHeaderPolicy.targetSize, maxWidth: .infinity)

            if WorkDeskCardHeaderPolicy.showsPin(width: width), isPinned || isSelecting || isHovering {
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
        .frame(height: WorkDeskCardHeaderPolicy.targetSize)
        .background(AppColors.brandAmber.opacity(isSelecting || isLifted ? 0.09 : 0))
    }
}

/// Leave a complete drag target before adding adjacent controls. The canvas
/// normally enters overview first; this also protects a temporarily narrower
/// card during resize or a future change to its overview threshold.
nonisolated enum WorkDeskCardHeaderPolicy {
    static let targetSize: CGFloat = 44
    static func showsSelection(width: CGFloat) -> Bool { width >= targetSize * 2 }
    static func showsPin(width: CGFloat) -> Bool { width >= targetSize * 3 }
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

/// The handle remains a discoverable keyboard and accessibility control. The
/// containing object's one gesture owns movement everywhere, including here.
struct WorkDeskDragGrip: View {
    let title: String
    let onNudge: (CGSize) -> Void
    var isLifted: Bool = false
    var onActivate: () -> Void = {}

    @FocusState private var isFocused: Bool
    @Environment(\.workbenchDestinationIsActive) private var isActive

    var body: some View {
        Image(systemName: "circle.grid.3x2.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isFocused || isLifted ? AppColors.brandAmber : AppColors.textTertiary.opacity(0.55))
            .frame(minWidth: WorkDeskCardHeaderPolicy.targetSize, maxWidth: .infinity,
                   minHeight: WorkDeskCardHeaderPolicy.targetSize)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(AppColors.textPrimary.opacity(isFocused || isLifted ? 0.09 : 0))
                    .padding(.horizontal, 4).padding(.vertical, 7)
            }
            .pointerHoverWash(cornerRadius: 8)
            .focusable(isActive)
            .focused($isFocused)
            .onTapGesture { guard isActive else { return }; isFocused = true; onActivate() }
            .onChange(of: isActive) { _, active in if !active { isFocused = false } }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .escape]) { press in
                guard isActive, !isLifted,
                      press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                if press.key == .escape { isFocused = false; return .handled }
                guard let translation = WorkDeskGripKeyboardPolicy.translation(for: press.key, modifiers: press.modifiers) else { return .ignored }
                onActivate()
                onNudge(translation)
                return .handled
            }
            #if os(macOS)
            .pointerStyle(isLifted ? .grabActive : .grabIdle)
            #endif
            .help(Text(LocalizedStringResource("workdesk.canvas.moveObjectHint", defaultValue: "Drag anywhere on a card to arrange your desk")))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.canvas.move", defaultValue: "Move material")))
            .accessibilityValue(Text(verbatim: title))
            .accessibilityHint(Text(LocalizedStringResource("workdesk.canvas.moveObjectHint", defaultValue: "Drag anywhere on a card to arrange your desk")))
            .accessibilityActions {
                Button(LocalizedStringResource("workdesk.canvas.moveLeft", defaultValue: "Move left")) { nudge(.leftArrow) }
                Button(LocalizedStringResource("workdesk.canvas.moveRight", defaultValue: "Move right")) { nudge(.rightArrow) }
                Button(LocalizedStringResource("workdesk.canvas.moveUp", defaultValue: "Move up")) { nudge(.upArrow) }
                Button(LocalizedStringResource("workdesk.canvas.moveDown", defaultValue: "Move down")) { nudge(.downArrow) }
            }
    }

    private func nudge(_ key: KeyEquivalent) {
        guard isActive, !isLifted,
              let translation = WorkDeskGripKeyboardPolicy.translation(for: key, modifiers: []) else { return }
        onActivate()
        onNudge(translation)
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
}

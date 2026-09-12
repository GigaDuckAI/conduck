// SPDX-License-Identifier: Apache-2.0

// Preview rows use the Desk's workspace transfer coordinator rather than a
// separate native provider path. Mac begins with a normal pointer drag; touch
// requires a hold first so the list can still scroll. Apply only to the open
// button, leaving its sibling actions menu outside the gesture. Escape keeps
// the held gesture suppressed until release, as it does on Desk cards.

import SwiftUI

struct WorkDeskProjectPreviewDrag: ViewModifier {
    let isEnabled: Bool
    let cancellationGeneration: Int
    let onChanged: (DragGesture.Value, CGRect) -> Void
    let onEnded: (DragGesture.Value, CGRect) -> Void
    let onCancelled: () -> Void
    @State private var frame: CGRect = .zero
    @State private var startFrame: CGRect?
    @State private var state = WorkDeskGripDragState()
    @GestureState private var gestureActive = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            #if os(macOS)
            .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .updating($gestureActive) { _, active, _ in active = true }
                    .onChanged(changed).onEnded(ended),
                including: isEnabled ? .all : .none)
            .pointerStyle(isEnabled ? .grabIdle : .default)
            #else
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.3, maximumDistance: 10)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .updating($gestureActive) { value, active, _ in
                        if case .second(true, .some) = value { active = true }
                    }
                    .onChanged { value in
                        if case .second(true, let drag?) = value { changed(drag) }
                    }
                    .onEnded { value in
                        if case .second(true, let drag?) = value { ended(drag) }
                        else { cancel() }
                    }, including: isEnabled ? .all : .none)
            #endif
            .onChange(of: gestureActive) { _, active in
                if !active, state.release() { startFrame = nil; onCancelled() }
            }
            .onChange(of: cancellationGeneration) { _, _ in cancel() }
            .onChange(of: isEnabled) { _, enabled in if !enabled { cancel() } }
            .onDisappear {
                if state.release() { onCancelled() }
                startFrame = nil
            }
    }

    private func changed(_ value: DragGesture.Value) {
        guard isEnabled, frame.width > 0, frame.height > 0, state.beginUpdate() else { return }
        if startFrame == nil { startFrame = frame }
        onChanged(value, startFrame ?? frame)
    }

    private func ended(_ value: DragGesture.Value) {
        let origin = startFrame ?? frame
        startFrame = nil
        guard state.release() else { return }
        if isEnabled { onEnded(value, origin) }
        else { onCancelled() }
    }

    private func cancel() {
        if state.cancel() { onCancelled() }
        startFrame = nil
    }
}

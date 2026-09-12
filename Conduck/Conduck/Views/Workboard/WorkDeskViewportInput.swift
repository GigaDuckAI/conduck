// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskViewportInput.swift
//
// Native input for one spatial viewport. A transparent marker preserves the
// SwiftUI card/drop tree and describes the exact local region that may navigate.
// macOS observes only wheel, magnify and middle-button events in that marker's
// own window; UIKit attaches two-finger recognizers to its enclosing controller
// view and refuses every touch outside the marker or inside excluded controls.
// No keyboard, left-click, tap or drag/drop handler is installed, and native
// recognizers never attach to UIWindow. The geometry filter is the boundary.
// All callbacks are incremental screen-space values, so pan and pinch compose
// on the host's current transform instead of restoring competing start values.
// AppKit's additive magnification belongs to the current gesture, never to the
// absolute document zoom. Touch pan and pinch share a centroid so callback order
// cannot translate an already-scaled movement a second time.
// Mouse wheels zoom at the pointer; gesture scrolling (including momentum) pans.
// AppKit identifies that gesture by its phases, not its precision: some wheels
// also send precise deltas. UIKit separates discrete wheel and continuous pan
// recognizers; the wheel recognizer refuses touches so it cannot steal card drags.

#if !os(watchOS)
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

nonisolated enum WorkDeskViewportInputDelta: Equatable {
    case pan(CGSize)
    case zoom(factor: CGFloat, anchor: CGPoint)
}

/// Platform event normalization, independent of views and live input devices.
nonisolated enum WorkDeskViewportInputMath {
    static let discreteWheelPoints: CGFloat = 28

    static func accepts(point: CGPoint, bounds: CGRect, excludedRects: [CGRect], isEnabled: Bool) -> Bool {
        guard isEnabled, point.x.isFinite, point.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return false }
        return !excludedRects.contains { $0.contains(point) }
    }

    static func scroll(delta: CGSize, precise: Bool, shift: Bool, zoom: Bool,
                       phase: WorkDeskViewportEventPhase = .unphased,
                       momentumPhase: WorkDeskViewportEventPhase = .unphased,
                       anchor: CGPoint) -> WorkDeskViewportInputDelta? {
        guard delta.width.isFinite, delta.height.isFinite,
              anchor.x.isFinite, anchor.y.isFinite,
              delta.width != 0 || delta.height != 0 else { return nil }
        if zoom || (phase == .unphased && momentumPhase == .unphased) {
            let amount = delta.height == 0 ? delta.width : delta.height
            // Exponential increments make equal opposite wheel movements
            // reciprocal, and cap malformed device spikes before exponentiation.
            let exponent = min(2, max(-2, amount * (precise ? 0.008 : 0.12)))
            return .zoom(factor: exp(exponent), anchor: anchor)
        }
        let multiplier: CGFloat = precise ? 1 : discreteWheelPoints
        // AppKit already applies the user's natural-scrolling preference. Shift
        // wheels may already arrive on X; do not swap an existing X back to Y.
        let x = shift ? (delta.width == 0 ? delta.height : delta.width) : delta.width
        let y = shift ? 0 : delta.height
        let translated = CGSize(width: x * multiplier, height: y * multiplier)
        guard translated.width.isFinite, translated.height.isFinite else { return nil }
        return .pan(translated)
    }

    static func pinchScale(_ factor: CGFloat, anchor: CGPoint) -> WorkDeskViewportInputDelta? {
        guard factor.isFinite, factor > 0, factor != 1,
              anchor.x.isFinite, anchor.y.isFinite else { return nil }
        return .zoom(factor: factor, anchor: anchor)
    }

    static func translation(from previous: CGPoint, to current: CGPoint) -> CGSize? {
        let result = CGSize(width: current.x - previous.x, height: current.y - previous.y)
        guard result.width.isFinite, result.height.isFinite,
              result.width != 0 || result.height != 0 else { return nil }
        return result
    }
}

/// NSEvent magnification is additive within a gesture. Convert that accumulated
/// gesture scale into incremental ratios, preserving proportional movement even
/// when the document starts far below 100%. Limits keep malformed input finite;
/// reversing a held gesture immediately reverses the delivered ratio.
nonisolated struct WorkDeskViewportMagnification {
    static let minimumGestureScale: CGFloat = 0.01
    static let maximumGestureScale: CGFloat = 100
    private(set) var gestureScale: CGFloat = 1

    mutating func receive(_ amount: CGFloat, anchor: CGPoint) -> WorkDeskViewportInputDelta? {
        guard amount.isFinite, anchor.x.isFinite, anchor.y.isFinite else { return nil }
        let previous = gestureScale
        gestureScale = min(Self.maximumGestureScale, max(Self.minimumGestureScale, previous + amount))
        return WorkDeskViewportInputMath.pinchScale(gestureScale / previous, anchor: anchor)
    }

    mutating func reset() { gestureScale = 1 }
}

/// Pan and pinch observe the same touch centroid. Whichever callback arrives
/// first supplies its movement; the pinch then zooms at that updated anchor.
/// This avoids both duplicate translation and pan/zoom order-dependent drift.
nonisolated struct WorkDeskViewportTouchMotion {
    private var centroid: CGPoint?

    mutating func pan(_ translation: CGPoint, anchor: CGPoint, isPinching: Bool) -> CGSize? {
        guard anchor.x.isFinite, anchor.y.isFinite,
              translation.x.isFinite, translation.y.isFinite else { return nil }
        if isPinching { return moveCentroid(to: anchor) }
        centroid = anchor
        return WorkDeskViewportInputMath.translation(from: .zero, to: translation)
    }

    mutating func pinch(_ factor: CGFloat, anchor: CGPoint) -> (pan: CGSize?, zoom: WorkDeskViewportInputDelta?) {
        guard factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite else { return (nil, nil) }
        return (moveCentroid(to: anchor), WorkDeskViewportInputMath.pinchScale(factor, anchor: anchor))
    }

    mutating func reset() { centroid = nil }

    private mutating func moveCentroid(to anchor: CGPoint) -> CGSize? {
        let previous = centroid
        centroid = anchor
        return previous.flatMap { WorkDeskViewportInputMath.translation(from: $0, to: anchor) }
    }
}

/// A phased stream is acquired only at its beginning. Entering the viewport
/// during someone else's gesture never transfers ownership to this canvas.
nonisolated enum WorkDeskViewportEventPhase: Equatable { case unphased, mayBegin, began, changed, ended, cancelled }

nonisolated struct WorkDeskViewportEventDecision: Equatable {
    let consumes: Bool
    let appliesDelta: Bool
    let isActive: Bool
}

nonisolated struct WorkDeskViewportGestureOwnership {
    private(set) var isOwned = false

    mutating func receive(phase: WorkDeskViewportEventPhase, inside: Bool, canBegin: Bool? = nil) -> WorkDeskViewportEventDecision {
        if phase == .began { isOwned = canBegin ?? inside }
        let consumed = isOwned
        if phase == .ended || phase == .cancelled { isOwned = false }
        return WorkDeskViewportEventDecision(
            consumes: consumed,
            appliesDelta: consumed && inside && phase != .cancelled && phase != .mayBegin,
            isActive: isOwned
        )
    }
}

nonisolated struct WorkDeskViewportWheelOwnership {
    private var gesture = WorkDeskViewportGestureOwnership()
    private var momentum = WorkDeskViewportGestureOwnership()
    private var mayContinueWithMomentum = false

    mutating func receive(phase: WorkDeskViewportEventPhase, momentumPhase: WorkDeskViewportEventPhase, inside: Bool) -> WorkDeskViewportEventDecision {
        if phase == .unphased, momentumPhase == .unphased {
            // A physical mouse wheel has no owned multi-event gesture.
            return WorkDeskViewportEventDecision(consumes: inside, appliesDelta: inside, isActive: gesture.isOwned || momentum.isOwned)
        }
        if momentumPhase != .unphased {
            // A momentum beginning is continuation, never a new opportunity to
            // acquire a gesture that began on another surface.
            let eligible = mayContinueWithMomentum || gesture.isOwned || momentum.isOwned
            let result = momentum.receive(phase: momentumPhase, inside: inside, canBegin: eligible)
            if momentumPhase == .began {
                _ = gesture.receive(phase: .ended, inside: false)
                mayContinueWithMomentum = false
            }
            if momentumPhase == .ended || momentumPhase == .cancelled {
                mayContinueWithMomentum = false
            }
            return result
        }
        if phase == .began {
            momentum = WorkDeskViewportGestureOwnership()
            mayContinueWithMomentum = false
        }
        let result = gesture.receive(phase: phase, inside: inside)
        if phase == .ended { mayContinueWithMomentum = result.consumes }
        if phase == .cancelled { mayContinueWithMomentum = false }
        return result
    }
}

/// An accepted middle-button down owns its matching up even while movement
/// leaves the canvas. Re-entry rebases at the first point back inside so skipped
/// motion across controls cannot become a large jump.
nonisolated struct WorkDeskViewportMiddleButtonOwnership {
    private(set) var isOwned = false
    private var previousPoint: CGPoint?

    mutating func begin(at point: CGPoint, inside: Bool) -> Bool {
        isOwned = inside && point.x.isFinite && point.y.isFinite
        previousPoint = isOwned ? point : nil
        return isOwned
    }

    mutating func drag(to point: CGPoint, inside: Bool) -> CGSize? {
        guard isOwned else { return nil }
        guard inside, point.x.isFinite, point.y.isFinite else {
            previousPoint = nil
            return nil
        }
        let previous = previousPoint
        previousPoint = point
        return previous.flatMap { WorkDeskViewportInputMath.translation(from: $0, to: point) }
    }

    mutating func end() -> Bool {
        let consumed = isOwned
        isOwned = false
        previousPoint = nil
        return consumed
    }
}

/// Pan and pinch can overlap. Ending either must not tell the host navigation
/// is finished while the other still owns an active stream.
nonisolated struct WorkDeskViewportInputSessions {
    enum Kind: Hashable { case pan, pinch, wheel, middleButton }
    private(set) var active: Set<Kind> = []

    mutating func set(_ kind: Kind, active isActive: Bool) -> Bool? {
        let before = !active.isEmpty
        if isActive { active.insert(kind) } else { active.remove(kind) }
        let after = !active.isEmpty
        return before == after ? nil : after
    }

    mutating func reset() -> Bool? {
        guard !active.isEmpty else { return nil }
        active = []
        return false
    }
}

@MainActor private struct WorkDeskViewportInputConfiguration {
    let isEnabled: Bool
    let excludedRects: [CGRect]
    let onPan: @MainActor (CGSize) -> Void
    let onZoom: @MainActor (CGFloat, CGPoint) -> Void
    let onInteractionChanged: @MainActor (Bool) -> Void

    func accepts(_ point: CGPoint, bounds: CGRect) -> Bool {
        WorkDeskViewportInputMath.accepts(point: point, bounds: bounds, excludedRects: excludedRects, isEnabled: isEnabled)
    }

    func deliver(_ delta: WorkDeskViewportInputDelta) {
        switch delta {
        case .pan(let translation): onPan(translation)
        case .zoom(let factor, let anchor): onZoom(factor, anchor)
        }
    }
}

extension View {
    /// Apply before overlays, or exclude their measured canvas-local frames.
    /// `onInteractionChanged` lets the owner suspend its one-finger/card drag
    /// while native two-finger or middle-button navigation is underway.
    /// `onZoom` receives proportional factors on every platform, with the
    /// actual local focal point. AppKit's additive events are normalized here.
    @MainActor func workDeskViewportInput(
        isEnabled: Bool,
        excludedRects: [CGRect] = [],
        onPan: @escaping @MainActor (CGSize) -> Void,
        onZoom: @escaping @MainActor (CGFloat, CGPoint) -> Void,
        onInteractionChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> some View {
        background {
            WorkDeskViewportInputMarker(configuration: WorkDeskViewportInputConfiguration(
                isEnabled: isEnabled,
                excludedRects: excludedRects,
                onPan: onPan,
                onZoom: onZoom,
                onInteractionChanged: onInteractionChanged
            ))
            .accessibilityHidden(true)
        }
    }
}

#if os(macOS)
private struct WorkDeskViewportInputMarker: NSViewRepresentable {
    let configuration: WorkDeskViewportInputConfiguration

    func makeNSView(context: Context) -> WorkDeskMacViewportInputView {
        WorkDeskMacViewportInputView(configuration: configuration)
    }

    func updateNSView(_ view: WorkDeskMacViewportInputView, context: Context) {
        view.configuration = configuration
        view.updateMonitoring()
    }

    static func dismantleNSView(_ view: WorkDeskMacViewportInputView, coordinator: ()) {
        view.stopMonitoring()
    }
}

@MainActor private final class WorkDeskMacViewportInputView: NSView {
    var configuration: WorkDeskViewportInputConfiguration
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var sessions = WorkDeskViewportInputSessions()
    private var middleButton = WorkDeskViewportMiddleButtonOwnership()
    private var wheel = WorkDeskViewportWheelOwnership()
    private var magnify = WorkDeskViewportGestureOwnership()
    private var magnification = WorkDeskViewportMagnification()

    init(configuration: WorkDeskViewportInputConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitoring()
    }

    func updateMonitoring() {
        guard configuration.isEnabled, window != nil else { stopMonitoring(); return }
        guard monitor == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetSessions() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }

    func stopMonitoring() {
        // Clear ownership before removal; AppKit requires exactly one removal
        // per monitor, including repeated disappear/update/dismantle callbacks.
        if let monitor {
            self.monitor = nil
            NSEvent.removeMonitor(monitor)
        }
        if let resignObserver {
            self.resignObserver = nil
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resetSessions()
    }

    private func resetSessions() {
        _ = middleButton.end()
        wheel = WorkDeskViewportWheelOwnership()
        magnify = WorkDeskViewportGestureOwnership()
        magnification.reset()
        if let changed = sessions.reset() { configuration.onInteractionChanged(changed) }
    }

    private func setSession(_ kind: WorkDeskViewportInputSessions.Kind, active: Bool) {
        if let changed = sessions.set(kind, active: active) { configuration.onInteractionChanged(changed) }
    }

    private static func phase(_ phase: NSEvent.Phase) -> WorkDeskViewportEventPhase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.mayBegin) { return .mayBegin }
        return phase.isEmpty ? .unphased : .changed
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard configuration.isEnabled, let window, event.window === window,
              !isHiddenOrHasHiddenAncestor else { resetSessions(); return event }
        let point = convert(event.locationInWindow, from: nil)
        let inside = configuration.accepts(point, bounds: bounds)
        // Ownership processes outside points too: a foreign beginning cannot
        // turn into an inside acquisition later, and an owned ending must close
        // its session even if the pointer has left the viewport.
        switch event.type {
        case .scrollWheel:
            let decision = wheel.receive(phase: Self.phase(event.phase), momentumPhase: Self.phase(event.momentumPhase), inside: inside)
            if decision.consumes { setSession(.wheel, active: true) }
            if decision.appliesDelta, let delta = WorkDeskViewportInputMath.scroll(
                delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                precise: event.hasPreciseScrollingDeltas,
                shift: event.modifierFlags.contains(.shift),
                zoom: event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
                phase: Self.phase(event.phase),
                momentumPhase: Self.phase(event.momentumPhase),
                anchor: point
            ) { configuration.deliver(delta) }
            setSession(.wheel, active: decision.isActive)
            return decision.consumes ? nil : event
        case .magnify:
            let phase = Self.phase(event.phase)
            if phase == .began { magnification.reset() }
            let decision = magnify.receive(phase: phase, inside: inside)
            if decision.consumes { setSession(.pinch, active: true) }
            if decision.appliesDelta, let delta = magnification.receive(event.magnification, anchor: point) {
                configuration.deliver(delta)
            }
            // Outside movement is skipped and rebased, never replayed on entry.
            if !decision.isActive || !decision.appliesDelta { magnification.reset() }
            setSession(.pinch, active: decision.isActive)
            return decision.consumes ? nil : event
        case .otherMouseDown where event.buttonNumber == 2:
            guard middleButton.begin(at: point, inside: inside) else { return event }
            setSession(.middleButton, active: true)
            return nil
        case .otherMouseDragged where event.buttonNumber == 2:
            guard middleButton.isOwned else { return event }
            if let delta = middleButton.drag(to: point, inside: inside) { configuration.onPan(delta) }
            return nil
        case .otherMouseUp where event.buttonNumber == 2:
            guard middleButton.end() else { return event }
            setSession(.middleButton, active: false)
            return nil
        default:
            return event
        }
    }

}
#elseif os(iOS)
private struct WorkDeskViewportInputMarker: UIViewRepresentable {
    let configuration: WorkDeskViewportInputConfiguration

    func makeUIView(context: Context) -> WorkDeskTouchViewportInputView {
        WorkDeskTouchViewportInputView(configuration: configuration)
    }

    func updateUIView(_ view: WorkDeskTouchViewportInputView, context: Context) {
        view.configuration = configuration
        view.updateRecognizers()
    }

    static func dismantleUIView(_ view: WorkDeskTouchViewportInputView, coordinator: ()) {
        view.removeRecognizers()
    }
}

@MainActor private final class WorkDeskTouchViewportInputView: UIView, UIGestureRecognizerDelegate {
    var configuration: WorkDeskViewportInputConfiguration
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let wheelScroll = UIPanGestureRecognizer()
    private weak var recognizerOwner: UIView?
    private var sessions = WorkDeskViewportInputSessions()
    private var touchMotion = WorkDeskViewportTouchMotion()

    init(configuration: WorkDeskViewportInputConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .continuous
        pan.addTarget(self, action: #selector(panned(_:)))
        pinch.addTarget(self, action: #selector(pinched(_:)))
        wheelScroll.allowedScrollTypesMask = .discrete
        wheelScroll.allowedTouchTypes = []
        wheelScroll.addTarget(self, action: #selector(wheelScrolled(_:)))
        for recognizer in [pan, pinch, wheelScroll] {
            // Once two-finger navigation recognizes, cancel the first finger's
            // pending button/preview touch. A one-finger gesture never reaches
            // recognition here, so its ordinary controls keep receiving input.
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
        }
    }

    required init?(coder: NSCoder) { nil }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRecognizers()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateRecognizers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateRecognizers()
    }

    /// The enclosing controller's content view receives touches destined for
    /// SwiftUI siblings; the marker alone cannot receive them. This follows
    /// public responder ownership, not private SwiftUI class names, and never
    /// attaches a recognizer to UIWindow. All touches still pass the marker's
    /// exact local geometry and exclusion checks before recognition may begin.
    private var enclosingContentView: UIView? {
        var responder: UIResponder? = superview
        while let current = responder, !(current is UIWindow) {
            if let controller = current as? UIViewController,
               let view = controller.viewIfLoaded, !(view is UIWindow) { return view }
            responder = current.next
        }
        return nil
    }

    func updateRecognizers() {
        guard configuration.isEnabled, window != nil,
              let owner = enclosingContentView else { removeRecognizers(); return }
        guard recognizerOwner !== owner else { return }
        removeRecognizers()
        recognizerOwner = owner
        owner.addGestureRecognizer(pan)
        owner.addGestureRecognizer(pinch)
        owner.addGestureRecognizer(wheelScroll)
    }

    func removeRecognizers() {
        if let recognizerOwner {
            recognizerOwner.removeGestureRecognizer(pan)
            recognizerOwner.removeGestureRecognizer(pinch)
            recognizerOwner.removeGestureRecognizer(wheelScroll)
            self.recognizerOwner = nil
        }
        pan.setTranslation(.zero, in: self)
        wheelScroll.setTranslation(.zero, in: self)
        pinch.scale = 1
        touchMotion.reset()
        if let changed = sessions.reset() { configuration.onInteractionChanged(changed) }
    }

    private func accepts(_ point: CGPoint) -> Bool {
        configuration.isEnabled && window != nil && !isHidden
            && configuration.accepts(point, bounds: bounds)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard touch.window === window else { return false }
        return accepts(touch.location(in: self))
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard accepts(gestureRecognizer.location(in: self)) else { return false }
        // Indirect pointer gestures can produce zero touches. UIKit's own
        // recognizer still requires two fingers for the direct-touch lane.
        let count = gestureRecognizer.numberOfTouches
        guard count == 2 || count == 0 else { return false }
        return (0..<count).allSatisfy { accepts(gestureRecognizer.location(ofTouch: $0, in: self)) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A first finger can already own a SwiftUI card drag when the second
        // lands. Allow native recognition to begin; onInteractionChanged then
        // lets the host cancel that card's transient drag, never commit it.
        gestureRecognizer === pan || gestureRecognizer === pinch || gestureRecognizer === wheelScroll
    }

    private func setSession(_ kind: WorkDeskViewportInputSessions.Kind, active: Bool) {
        if let changed = sessions.set(kind, active: active) {
            if !changed { touchMotion.reset() }
            configuration.onInteractionChanged(changed)
        }
    }

    private func acceptsGesture(_ recognizer: UIGestureRecognizer) -> Bool {
        accepts(recognizer.location(in: self)) && (0..<recognizer.numberOfTouches).allSatisfy {
            accepts(recognizer.location(ofTouch: $0, in: self))
        }
    }

    @objc private func wheelScrolled(_ recognizer: UIPanGestureRecognizer) {
        guard configuration.isEnabled else { setSession(.wheel, active: false); return }
        let finished = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
        if !finished { setSession(.wheel, active: true) }
        defer {
            recognizer.setTranslation(.zero, in: self)
            if finished { setSession(.wheel, active: false) }
        }
        guard recognizer.state != .cancelled, recognizer.state != .failed,
              acceptsGesture(recognizer) else { return }
        let translation = recognizer.translation(in: self)
        // UIKit reports scroll translation in view points, even for a wheel;
        // AppKit's coarse tick multiplier must not be applied a second time.
        if let delta = WorkDeskViewportInputMath.scroll(
            delta: CGSize(width: translation.x, height: translation.y),
            precise: true, shift: false, zoom: true,
            anchor: recognizer.location(in: self)
        ) { configuration.deliver(delta) }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard configuration.isEnabled else { setSession(.pan, active: false); return }
        let finished = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
        if !finished { setSession(.pan, active: true) }
        defer {
            recognizer.setTranslation(.zero, in: self)
            if finished { setSession(.pan, active: false) }
        }
        guard recognizer.state != .cancelled, recognizer.state != .failed,
              acceptsGesture(recognizer) else { touchMotion.reset(); return }
        let isPinching = pinch.state == .began || pinch.state == .changed
        if isPinching, finished || recognizer.numberOfTouches == 1 {
            touchMotion.reset()
            return
        }
        if let translated = touchMotion.pan(recognizer.translation(in: self),
            anchor: recognizer.location(in: self), isPinching: isPinching) {
            configuration.onPan(translated)
        }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard configuration.isEnabled else { setSession(.pinch, active: false); return }
        let finished = recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed
        if !finished { setSession(.pinch, active: true) }
        defer {
            recognizer.scale = 1
            if finished { setSession(.pinch, active: false) }
        }
        // Once a finger lifts, location may become the remaining finger instead
        // of the previous two-touch center. Its ending must never move the desk.
        guard !finished, acceptsGesture(recognizer) else {
            touchMotion.reset()
            return
        }
        let update = touchMotion.pinch(recognizer.scale, anchor: recognizer.location(in: self))
        if let translation = update.pan { configuration.onPan(translation) }
        if let delta = update.zoom { configuration.deliver(delta) }
    }
}
#endif
#endif

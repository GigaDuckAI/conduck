// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskViewportInputTests.swift
//
// Device-independent navigation arithmetic and the platform scope/cleanup
// boundaries. Real trackpad feel, touch recognition and pointer interaction
// remain device QA; these tests do not synthesize or send real input events.

import XCTest
@testable import Conduck

final class WorkDeskViewportInputTests: XCTestCase {
    func testPreciseScrollKeepsScreenPointMagnitudeAndNativeDirection() {
        let result = WorkDeskViewportInputMath.scroll(delta: CGSize(width: -3.5, height: 12.25), precise: true, shift: false, zoom: false, anchor: .zero)
        XCTAssertEqual(result, .pan(CGSize(width: -3.5, height: 12.25)))
    }

    func testWheelTicksHaveUsefulDistanceAndShiftCannotBecomeVertical() {
        XCTAssertEqual(
            WorkDeskViewportInputMath.scroll(delta: CGSize(width: 0, height: -2), precise: false, shift: false, zoom: false, anchor: .zero),
            .pan(CGSize(width: 0, height: -56))
        )
        XCTAssertEqual(
            WorkDeskViewportInputMath.scroll(delta: CGSize(width: 0, height: -2), precise: false, shift: true, zoom: false, anchor: .zero),
            .pan(CGSize(width: -56, height: 0))
        )
        // AppKit can already redirect Shift-wheel onto X; never swap it back.
        XCTAssertEqual(
            WorkDeskViewportInputMath.scroll(delta: CGSize(width: 3, height: 0), precise: false, shift: true, zoom: false, anchor: .zero),
            .pan(CGSize(width: 84, height: 0))
        )
    }

    func testOppositeZoomWheelAmountsAreReciprocalAtTheRealAnchor() throws {
        let anchor = CGPoint(x: 73, y: 241)
        guard case .zoom(let inward, let firstAnchor) = WorkDeskViewportInputMath.scroll(delta: CGSize(width: 0, height: 2), precise: false, shift: false, zoom: true, anchor: anchor),
              case .zoom(let outward, let secondAnchor) = WorkDeskViewportInputMath.scroll(delta: CGSize(width: 0, height: -2), precise: false, shift: false, zoom: true, anchor: anchor) else {
            return XCTFail("Modifier-wheel must produce zoom, never a simultaneous pan")
        }
        XCTAssertGreaterThan(inward, 1)
        XCTAssertLessThan(outward, 1)
        XCTAssertEqual(inward * outward, 1, accuracy: 0.000_001)
        XCTAssertEqual(firstAnchor, anchor)
        XCTAssertEqual(secondAnchor, anchor)
    }

    func testUIKitPinchScaleIsMultiplicativeAndPreservesFocalPoint() {
        let anchor = CGPoint(x: 91, y: 157)
        XCTAssertEqual(WorkDeskViewportInputMath.pinchScale(1.25, anchor: anchor), .zoom(factor: 1.25, anchor: anchor))
        XCTAssertEqual(WorkDeskViewportInputMath.pinchScale(0.8, anchor: anchor), .zoom(factor: 0.8, anchor: anchor))
        XCTAssertNil(WorkDeskViewportInputMath.pinchScale(-1, anchor: anchor))
        XCTAssertNil(WorkDeskViewportInputMath.pinchScale(1, anchor: anchor))
    }

    func testAppKitAddsWithinTheGestureThenScalesTheDocumentProportionally() throws {
        let anchor = CGPoint(x: 81, y: 203)
        for initialScale: CGFloat in [0.02, 0.1, 0.8, 1] {
            var gesture = WorkDeskViewportMagnification()
            var camera = WorkDeskCanvasTransform(scale: initialScale)
            let before = WorkDeskCanvasGeometry.worldPoint(anchor, transform: camera)
            for _ in 0..<2 {
                guard case .zoom(let factor, let actualAnchor) = gesture.receive(0.1, anchor: anchor) else {
                    return XCTFail("AppKit magnification must become a proportional zoom factor")
                }
                XCTAssertEqual(actualAnchor, anchor)
                camera = WorkDeskCanvasGeometry.zoomed(camera, to: camera.scale * factor, anchor: actualAnchor)
            }
            XCTAssertEqual(camera.scale, initialScale * 1.2, accuracy: 0.000_001)
            let screen = WorkDeskCanvasGeometry.screenPoint(before, transform: camera)
            XCTAssertEqual(screen.x, anchor.x, accuracy: 0.000_001)
            XCTAssertEqual(screen.y, anchor.y, accuracy: 0.000_001)
            XCTAssertEqual(gesture.gestureScale, 1.2, accuracy: 0.000_001)
        }
    }

    func testAppKitGestureResultDoesNotDependOnNumberOfDeliveredEvents() throws {
        var many = WorkDeskViewportMagnification(), one = WorkDeskViewportMagnification()
        var combined: CGFloat = 1
        for _ in 0..<20 {
            guard case .zoom(let factor, _) = many.receive(-0.02, anchor: .zero) else { return XCTFail() }
            combined *= factor
        }
        guard case .zoom(let factor, _) = one.receive(-0.4, anchor: .zero) else { return XCTFail() }
        XCTAssertEqual(combined, factor, accuracy: 0.000_001)
        XCTAssertEqual(combined, 0.6, accuracy: 0.000_001)
    }

    func testAppKitGestureResetRebasesAfterEndingCancellationOrBoundaryExit() throws {
        var gesture = WorkDeskViewportMagnification()
        _ = gesture.receive(0.8, anchor: .zero)
        gesture.reset()
        XCTAssertEqual(gesture.gestureScale, 1)
        XCTAssertEqual(gesture.receive(0.1, anchor: .zero), .zoom(factor: 1.1, anchor: .zero))
        gesture.reset()
        gesture.reset()
        XCTAssertEqual(gesture.receive(-0.1, anchor: .zero), .zoom(factor: 0.9, anchor: .zero))
    }

    func testAppKitZoomReversesImmediatelyAtDocumentAndGestureLimits() throws {
        for start in [WorkDeskCanvasGeometry.minimumScale, WorkDeskCanvasGeometry.maximumScale] {
            var gesture = WorkDeskViewportMagnification()
            var camera = WorkDeskCanvasTransform(scale: start)
            let outward: CGFloat = start == WorkDeskCanvasGeometry.minimumScale ? -0.4 : 0.4
            for amount in [outward, -outward / 4] {
                guard case .zoom(let factor, _) = gesture.receive(amount, anchor: .zero) else { return XCTFail() }
                camera = WorkDeskCanvasGeometry.zoomed(camera, to: camera.scale * factor, anchor: .zero)
            }
            if start == WorkDeskCanvasGeometry.minimumScale { XCTAssertGreaterThan(camera.scale, start) }
            else { XCTAssertLessThan(camera.scale, start) }
        }
        var gesture = WorkDeskViewportMagnification()
        _ = gesture.receive(-1000, anchor: .zero)
        XCTAssertEqual(gesture.gestureScale, WorkDeskViewportMagnification.minimumGestureScale)
        guard case .zoom(let reverseLow, _) = gesture.receive(0.01, anchor: .zero) else { return XCTFail() }
        XCTAssertGreaterThan(reverseLow, 1)
        _ = gesture.receive(1000, anchor: .zero)
        XCTAssertEqual(gesture.gestureScale, WorkDeskViewportMagnification.maximumGestureScale)
        guard case .zoom(let reverseHigh, _) = gesture.receive(-0.01, anchor: .zero) else { return XCTFail() }
        XCTAssertLessThan(reverseHigh, 1)
    }

    func testMalformedAppKitMagnificationDoesNotChangeItsBaseline() {
        var gesture = WorkDeskViewportMagnification()
        XCTAssertNil(gesture.receive(.infinity, anchor: .zero))
        XCTAssertNil(gesture.receive(.nan, anchor: .zero))
        XCTAssertNil(gesture.receive(0.1, anchor: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertNil(gesture.receive(0, anchor: .zero))
        XCTAssertEqual(gesture.gestureScale, 1)
    }

    func testTouchPanAndPinchKeepTheCentroidAnchoredInEitherCallbackOrder() throws {
        let first = CGPoint(x: 200, y: 180), next = CGPoint(x: 220, y: 210)
        let initial = WorkDeskCanvasTransform(scale: 0.8, offset: CGSize(width: 25, height: -40))
        let held = WorkDeskCanvasGeometry.worldPoint(first, transform: initial)
        var results: [WorkDeskCanvasTransform] = []
        for panFirst in [true, false] {
            var motion = WorkDeskViewportTouchMotion()
            var camera = initial
            _ = motion.pan(.zero, anchor: first, isPinching: false)
            func pan() {
                if let delta = motion.pan(CGPoint(x: 20, y: 30), anchor: next, isPinching: true) {
                    camera = WorkDeskCanvasGeometry.panned(camera, by: delta)
                }
            }
            func pinch() {
                let update = motion.pinch(1.2, anchor: next)
                if let delta = update.pan { camera = WorkDeskCanvasGeometry.panned(camera, by: delta) }
                if case .zoom(let factor, let anchor) = update.zoom {
                    camera = WorkDeskCanvasGeometry.zoomed(camera, to: camera.scale * factor, anchor: anchor)
                }
            }
            if panFirst { pan(); pinch() } else { pinch(); pan() }
            let screen = WorkDeskCanvasGeometry.screenPoint(held, transform: camera)
            XCTAssertEqual(screen.x, next.x, accuracy: 0.000_001)
            XCTAssertEqual(screen.y, next.y, accuracy: 0.000_001)
            results.append(camera)
        }
        XCTAssertEqual(results[0], results[1])
    }

    func testTouchPinchMovesTheCentroidEvenWithoutAMatchingPanCallback() {
        var motion = WorkDeskViewportTouchMotion()
        _ = motion.pinch(1, anchor: CGPoint(x: 100, y: 100))
        let moved = motion.pinch(1, anchor: CGPoint(x: 120, y: 90))
        XCTAssertEqual(moved.pan, CGSize(width: 20, height: -10))
        XCTAssertNil(moved.zoom, "Moving both fingers with unchanged separation still pans.")
        XCTAssertNil(motion.pan(CGPoint(x: 20, y: -10), anchor: CGPoint(x: 120, y: 90), isPinching: true),
            "The pan callback cannot repeat a centroid movement already supplied by pinch.")
    }

    func testTouchBoundaryReentryAndLifecycleResetNeverReplaySkippedMovement() {
        var motion = WorkDeskViewportTouchMotion()
        _ = motion.pinch(1, anchor: CGPoint(x: 20, y: 40))
        motion.reset()
        let reentry = motion.pinch(1.1, anchor: CGPoint(x: 500, y: 600))
        XCTAssertNil(reentry.pan)
        XCTAssertEqual(reentry.zoom, .zoom(factor: 1.1, anchor: CGPoint(x: 500, y: 600)))
        XCTAssertEqual(motion.pan(CGPoint(x: 2, y: 3), anchor: CGPoint(x: 502, y: 603), isPinching: true),
            CGSize(width: 2, height: 3))
        motion.reset()
        XCTAssertEqual(motion.pan(CGPoint(x: 8, y: -3), anchor: CGPoint(x: 150, y: 200), isPinching: false),
            CGSize(width: 8, height: -3), "Ordinary two-finger pan resumes its own incremental translation.")
    }

    func testMalformedTouchInputCannotContaminateTheNextCentroid() {
        var motion = WorkDeskViewportTouchMotion()
        _ = motion.pinch(1, anchor: CGPoint(x: 100, y: 100))
        XCTAssertNil(motion.pinch(.nan, anchor: CGPoint(x: 400, y: 400)).pan)
        XCTAssertNil(motion.pan(CGPoint(x: CGFloat.infinity, y: 2), anchor: CGPoint(x: 200, y: 200), isPinching: true))
        XCTAssertEqual(motion.pinch(1, anchor: CGPoint(x: 105, y: 108)).pan, CGSize(width: 5, height: 8))
    }

    func testWheelGestureBeginningOutsideCannotBeAcquiredByEnteringDuringChangeOrMomentum() {
        var ownership = WorkDeskViewportWheelOwnership()
        XCTAssertFalse(ownership.receive(phase: .began, momentumPhase: .unphased, inside: false).consumes)
        XCTAssertFalse(ownership.receive(phase: .changed, momentumPhase: .unphased, inside: true).appliesDelta)
        XCTAssertFalse(ownership.receive(phase: .ended, momentumPhase: .unphased, inside: true).consumes)
        XCTAssertFalse(ownership.receive(phase: .unphased, momentumPhase: .began, inside: true).consumes)
        XCTAssertFalse(ownership.receive(phase: .unphased, momentumPhase: .changed, inside: true).appliesDelta)
        XCTAssertFalse(ownership.receive(phase: .unphased, momentumPhase: .ended, inside: true).consumes)
    }

    func testOwnedWheelEndingOutsideIsConsumedAndOwnMomentumPausesThenResumes() {
        var ownership = WorkDeskViewportWheelOwnership()
        XCTAssertEqual(ownership.receive(phase: .began, momentumPhase: .unphased, inside: true), .init(consumes: true, appliesDelta: true, isActive: true))
        XCTAssertEqual(ownership.receive(phase: .changed, momentumPhase: .unphased, inside: false), .init(consumes: true, appliesDelta: false, isActive: true))
        XCTAssertEqual(ownership.receive(phase: .ended, momentumPhase: .unphased, inside: false), .init(consumes: true, appliesDelta: false, isActive: false))
        XCTAssertEqual(ownership.receive(phase: .unphased, momentumPhase: .began, inside: false), .init(consumes: true, appliesDelta: false, isActive: true))
        XCTAssertTrue(ownership.receive(phase: .unphased, momentumPhase: .changed, inside: true).appliesDelta)
        XCTAssertEqual(ownership.receive(phase: .unphased, momentumPhase: .ended, inside: false), .init(consumes: true, appliesDelta: false, isActive: false))
    }

    func testUnphasedWheelKeepsPerEventEligibility() {
        var ownership = WorkDeskViewportWheelOwnership()
        XCTAssertFalse(ownership.receive(phase: .unphased, momentumPhase: .unphased, inside: false).consumes)
        XCTAssertEqual(ownership.receive(phase: .unphased, momentumPhase: .unphased, inside: true), .init(consumes: true, appliesDelta: true, isActive: false))
    }

    func testForeignPinchCannotBeAcquiredOnChangeAndOwnedPinchEndsOutside() {
        var ownership = WorkDeskViewportGestureOwnership()
        XCTAssertFalse(ownership.receive(phase: .began, inside: false).consumes)
        XCTAssertFalse(ownership.receive(phase: .changed, inside: true).consumes)
        XCTAssertFalse(ownership.receive(phase: .ended, inside: true).consumes)
        XCTAssertTrue(ownership.receive(phase: .began, inside: true).isActive)
        XCTAssertEqual(ownership.receive(phase: .ended, inside: false), .init(consumes: true, appliesDelta: false, isActive: false))
        XCTAssertFalse(ownership.receive(phase: .changed, inside: true).consumes)
    }

    func testMiddleButtonOwnershipSurvivesOutsideMovementAndRebasesOnReentry() {
        var ownership = WorkDeskViewportMiddleButtonOwnership()
        XCTAssertTrue(ownership.begin(at: CGPoint(x: 10, y: 20), inside: true))
        XCTAssertEqual(ownership.drag(to: CGPoint(x: 12, y: 23), inside: true), CGSize(width: 2, height: 3))
        XCTAssertNil(ownership.drag(to: CGPoint(x: 900, y: 800), inside: false))
        XCTAssertTrue(ownership.isOwned)
        XCTAssertNil(ownership.drag(to: CGPoint(x: 35, y: 40), inside: true), "Re-entry establishes a baseline instead of applying skipped movement")
        XCTAssertEqual(ownership.drag(to: CGPoint(x: 38, y: 44), inside: true), CGSize(width: 3, height: 4))
        XCTAssertTrue(ownership.end(), "Matching up must still be consumed after leaving and reentering")
        XCTAssertFalse(ownership.end())
    }

    func testMiddleButtonUpOutsideRemainsOwnedAndForeignDragsNeverAcquire() {
        var ownership = WorkDeskViewportMiddleButtonOwnership()
        XCTAssertFalse(ownership.begin(at: .zero, inside: false))
        XCTAssertNil(ownership.drag(to: CGPoint(x: 30, y: 50), inside: true))
        XCTAssertFalse(ownership.end())
        XCTAssertTrue(ownership.begin(at: .zero, inside: true))
        XCTAssertNil(ownership.drag(to: CGPoint(x: 999, y: 999), inside: false))
        XCTAssertTrue(ownership.end())
    }

    func testMalformedEventsCannotProduceInfiniteTransformInputs() {
        XCTAssertNil(WorkDeskViewportInputMath.scroll(delta: CGSize(width: CGFloat.infinity, height: 1), precise: true, shift: false, zoom: false, anchor: .zero))
        XCTAssertNil(WorkDeskViewportInputMath.scroll(delta: .zero, precise: true, shift: false, zoom: false, anchor: .zero))
        XCTAssertNil(WorkDeskViewportInputMath.scroll(delta: CGSize(width: 1, height: 0), precise: true, shift: false, zoom: true, anchor: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertNil(WorkDeskViewportInputMath.pinchScale(CGFloat.nan, anchor: .zero))
        guard case .zoom(let factor, _) = WorkDeskViewportInputMath.scroll(delta: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude), precise: false, shift: false, zoom: true, anchor: .zero) else {
            return XCTFail("Finite extreme wheel input should remain a bounded zoom increment")
        }
        XCTAssertTrue(factor.isFinite)
        XCTAssertGreaterThan(factor, 0)
        XCTAssertLessThan(factor, 10)
    }

    func testViewportScopeRejectsDisabledOutsideAndOverlayInput() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let controls = CGRect(x: 420, y: 340, width: 166, height: 44)
        XCTAssertTrue(WorkDeskViewportInputMath.accepts(point: CGPoint(x: 200, y: 200), bounds: bounds, excludedRects: [controls], isEnabled: true))
        for point in [CGPoint(x: -1, y: 20), CGPoint(x: 601, y: 20), CGPoint(x: 450, y: 350), CGPoint(x: CGFloat.nan, y: 20)] {
            XCTAssertFalse(WorkDeskViewportInputMath.accepts(point: point, bounds: bounds, excludedRects: [controls], isEnabled: true))
        }
        XCTAssertFalse(WorkDeskViewportInputMath.accepts(point: CGPoint(x: 200, y: 200), bounds: bounds, excludedRects: [], isEnabled: false))
        XCTAssertFalse(WorkDeskViewportInputMath.accepts(point: .zero, bounds: .zero, excludedRects: [], isEnabled: true))
    }

    func testOverlappingPanAndPinchCannotFinishEachOthersNavigationSession() {
        var sessions = WorkDeskViewportInputSessions()
        XCTAssertEqual(sessions.set(.pan, active: true), true)
        XCTAssertNil(sessions.set(.pan, active: true))
        XCTAssertNil(sessions.set(.pinch, active: true))
        XCTAssertNil(sessions.set(.pan, active: false))
        XCTAssertEqual(sessions.set(.pinch, active: false), false)
        XCTAssertNil(sessions.set(.pinch, active: false))
    }

    func testLifecycleResetIsIdempotentAndDropsAllInputOwners() {
        var sessions = WorkDeskViewportInputSessions()
        _ = sessions.set(.middleButton, active: true)
        _ = sessions.set(.wheel, active: true)
        XCTAssertEqual(sessions.reset(), false)
        XCTAssertTrue(sessions.active.isEmpty)
        XCTAssertNil(sessions.reset())
        XCTAssertNil(sessions.set(.wheel, active: false))
        XCTAssertEqual(sessions.set(.pinch, active: true), true)
    }

    func testMiddlePointerDeltasStayRelativeToLastLocalPosition() {
        XCTAssertEqual(WorkDeskViewportInputMath.translation(from: CGPoint(x: 800, y: 900), to: CGPoint(x: 796, y: 912)), CGSize(width: -4, height: 12))
        XCTAssertNil(WorkDeskViewportInputMath.translation(from: .zero, to: .zero))
        XCTAssertNil(WorkDeskViewportInputMath.translation(from: CGPoint(x: CGFloat.infinity, y: 0), to: .zero))
    }

    func testMacMonitorIsViewportScopedAndConsumedEventsStayConsumed() throws {
        let source = try inputSource()
        let mac = try RefusalLaneSource.trailingClosure(after: "private final class WorkDeskMacViewportInputView", in: source, path: Self.path)
        XCTAssertTrue(mac.contains("matching: [.scrollWheel, .magnify, .otherMouseDown, .otherMouseDragged, .otherMouseUp]"))
        XCTAssertTrue(mac.contains("event.window === window"))
        XCTAssertTrue(mac.contains("convert(event.locationInWindow, from: nil)"))
        XCTAssertTrue(mac.contains("configuration.accepts(point, bounds: bounds)"))
        XCTAssertTrue(mac.contains("return self.handle(event)"))
        XCTAssertTrue(mac.contains("magnification.receive(event.magnification, anchor: point)"))
        XCTAssertTrue(mac.contains("if phase == .began { magnification.reset() }"))
        XCTAssertTrue(mac.contains("if !decision.isActive || !decision.appliesDelta { magnification.reset() }"))
        XCTAssertFalse(source.contains("onMagnifyBy"))
        XCTAssertFalse(mac.contains("self?.handle(event) ?? event"), "Nil from a handled event must not be replaced with the original event")
        XCTAssertFalse(mac.contains("addGlobalMonitor"))
        XCTAssertFalse(mac.contains(".leftMouseDown"))
        XCTAssertFalse(mac.contains(".keyDown"))
        XCTAssertTrue(mac.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }"))
    }

    func testMacMonitorAndWindowObserverAreRemovedExactlyOnceOnDismantle() throws {
        let source = try inputSource()
        let stop = try RefusalLaneSource.body(ofFunction: "stopMonitoring", in: source, path: Self.path)
        let nilAt = try XCTUnwrap(stop.range(of: "self.monitor = nil")?.lowerBound)
        let removeAt = try XCTUnwrap(stop.range(of: "NSEvent.removeMonitor(monitor)")?.lowerBound)
        XCTAssertLessThan(nilAt, removeAt)
        XCTAssertTrue(stop.contains("NotificationCenter.default.removeObserver(resignObserver)"))
        XCTAssertTrue(stop.contains("resetSessions()"))
        let dismantle = try RefusalLaneSource.body(ofFunction: "dismantleNSView", in: source, path: Self.path)
        XCTAssertTrue(dismantle.contains("view.stopMonitoring()"))
        XCTAssertTrue(source.contains("forName: NSWindow.didResignKeyNotification, object: window"))
    }

    func testTouchAdapterPreservesSingleFingerControlsAndUsesIncrementalPanPinch() throws {
        let source = try inputSource()
        let touch = try RefusalLaneSource.trailingClosure(after: "private final class WorkDeskTouchViewportInputView", in: source, path: Self.path)
        XCTAssertTrue(touch.contains("pan.minimumNumberOfTouches = 2"))
        XCTAssertTrue(touch.contains("pan.maximumNumberOfTouches = 2"))
        XCTAssertTrue(touch.contains("pan.allowedScrollTypesMask = .all"))
        XCTAssertTrue(touch.contains("recognizer.cancelsTouchesInView = true"))
        XCTAssertTrue(touch.contains("recognizer.delaysTouchesBegan = false"))
        XCTAssertTrue(touch.contains("touch.window === window"))
        XCTAssertTrue(touch.contains("accepts(touch.location(in: self))"))
        XCTAssertTrue(touch.contains("!(current is UIWindow)"))
        XCTAssertTrue(touch.contains("!(view is UIWindow)"))
        XCTAssertTrue(touch.contains("recognizer.setTranslation(.zero, in: self)"))
        XCTAssertTrue(touch.contains("recognizer.scale = 1"))
        XCTAssertTrue(touch.contains("touchMotion.pinch(recognizer.scale, anchor: recognizer.location(in: self))"))
        XCTAssertTrue(touch.contains("touchMotion.pan(recognizer.translation(in: self)"))
        XCTAssertTrue(touch.contains("guard !finished, acceptsGesture(recognizer)"))
        let pinched = try RefusalLaneSource.body(ofFunction: "pinched", in: touch, path: Self.path)
        let panDelivery = try XCTUnwrap(pinched.range(of: "configuration.onPan(translation)"))
        let zoomDelivery = try XCTUnwrap(pinched.range(of: "configuration.deliver(delta)"))
        XCTAssertLessThan(panDelivery.lowerBound, zoomDelivery.lowerBound)
        XCTAssertTrue(touch.contains("recognizer.location(in: self)"))
        XCTAssertFalse(touch.contains("UITapGestureRecognizer"))
        let dismantle = try RefusalLaneSource.body(ofFunction: "dismantleUIView", in: source, path: Self.path)
        XCTAssertTrue(dismantle.contains("view.removeRecognizers()"))
        let remove = try RefusalLaneSource.body(ofFunction: "removeRecognizers", in: touch, path: Self.path)
        XCTAssertTrue(remove.contains("recognizerOwner.removeGestureRecognizer(pan)"))
        XCTAssertTrue(remove.contains("recognizerOwner.removeGestureRecognizer(pinch)"))
    }

    private static let path = "Conduck/Views/Workboard/WorkDeskViewportInput.swift"
    private func inputSource() throws -> String { try RefusalLaneSource.source(at: Self.path) }
}

// SPDX-License-Identifier: Apache-2.0

// Retaining Work's pixels must not retain permission to move its camera or
// claim keyboard focus. Hidden geometry leaves reveals queued; a later active
// viewport applies them once using its current size, independent of mount order.

import XCTest
import SwiftUI
@testable import Conduck

@MainActor
final class WorkDeskRetainedInputTests: XCTestCase {
    func testHiddenGeometryKeepsCameraAndRevealUntilCurrentActiveSizeArrives() {
        let session = WorkDeskCanvasSession()
        let owner = UUID()
        let oldSize = CGSize(width: 900, height: 700)
        let camera = WorkDeskCanvasTransform(scale: 0.45, offset: CGSize(width: -530, height: 125))
        session.receiveViewport(oldSize, owner: owner, isActive: true)
        session.transform = camera
        session.isInitialized = true
        XCTAssertFalse(session.receiveViewport(.zero, owner: owner, isActive: false))
        let frames = [CGRect(x: 2200, y: -900, width: 240, height: 260)]
        session.reveal(frames: frames)
        session.applyPendingReveal()
        XCTAssertEqual(session.viewportSize, oldSize)
        XCTAssertEqual(session.transform, camera)

        let currentSize = CGSize(width: 1200, height: 650)
        XCTAssertTrue(session.receiveViewport(currentSize, owner: owner, isActive: true))
        session.applyPendingReveal()
        XCTAssertEqual(session.transform, WorkDeskCanvasGeometry.fit(frames: frames, viewport: currentSize))
        session.transform = camera
        session.applyPendingReveal()
        XCTAssertEqual(session.transform, camera, "A reveal is consumed only once.")
    }

    func testInvalidActiveGeometryDoesNotConsumeAQueuedReveal() {
        let session = WorkDeskCanvasSession()
        let owner = UUID()
        let frames = [CGRect(x: 1500, y: 1600, width: 240, height: 260)]
        session.reveal(frames: frames)
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 400), CGSize(width: 600, height: CGFloat.nan)] {
            XCTAssertFalse(session.receiveViewport(size, owner: owner, isActive: true))
            session.applyPendingReveal()
            XCTAssertFalse(session.isInitialized)
        }
        let validSize = CGSize(width: 900, height: 600)
        session.receiveViewport(validSize, owner: owner, isActive: true)
        session.applyPendingReveal()
        XCTAssertTrue(session.isInitialized)
        XCTAssertEqual(session.transform, WorkDeskCanvasGeometry.fit(frames: frames, viewport: validSize))
    }

    func testOlderMountTeardownCannotDeactivateTheNewVisibleCanvas() {
        let session = WorkDeskCanvasSession()
        let oldOwner = UUID(), newOwner = UUID()
        session.receiveViewport(CGSize(width: 800, height: 500), owner: oldOwner, isActive: true)
        let currentSize = CGSize(width: 1000, height: 650)
        session.receiveViewport(currentSize, owner: newOwner, isActive: true)
        session.suspendViewport(owner: oldOwner)
        session.receiveViewport(.zero, owner: oldOwner, isActive: false)
        let frames = [CGRect(x: -1200, y: 900, width: 250, height: 230)]
        session.reveal(frames: frames)
        XCTAssertEqual(session.viewportSize, currentSize)
        XCTAssertEqual(session.transform, WorkDeskCanvasGeometry.fit(frames: frames, viewport: currentSize))
    }

    func testOrdinaryHideAndResizePreserveTheManualCameraWithoutAReveal() {
        let session = WorkDeskCanvasSession()
        let owner = UUID()
        let camera = WorkDeskCanvasTransform(scale: 0.37, offset: CGSize(width: 620, height: -300))
        session.receiveViewport(CGSize(width: 850, height: 600), owner: owner, isActive: true)
        session.transform = camera
        session.suspendViewport(owner: owner)
        session.receiveViewport(CGSize(width: 120, height: 120), owner: owner, isActive: false)
        session.receiveViewport(CGSize(width: 1300, height: 780), owner: owner, isActive: true)
        session.applyPendingReveal()
        XCTAssertEqual(session.transform, camera)
    }

    func testCanvasActivationReappliesGeometryAndHiddenRefreshCannotSeedOrFit() throws {
        let path = "Conduck/Views/Workboard/WorkDeskCanvas.swift"
        let source = try RefusalLaneSource.source(at: path)
        XCTAssertTrue(source.contains(".onChange(of: isActive) { _, active in\n                    updateViewport(proxy.size)"))
        let update = try RefusalLaneSource.body(ofFunction: "updateViewport", in: source, path: path)
        let validation = try XCTUnwrap(update.range(of: "session.receiveViewport(size, owner: viewportOwner, isActive: isActive)"))
        let publication = try XCTUnwrap(update.range(of: "viewport = size"))
        XCTAssertLessThan(validation.lowerBound, publication.lowerBound)
        let refresh = try RefusalLaneSource.body(ofFunction: "refreshLayout", in: source, path: path)
        XCTAssertTrue(refresh.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("guard isActive else { return }"))
        XCTAssertTrue(source.contains("session.suspendViewport(owner: viewportOwner)"))
    }

    func testRetainedComposersCannotClaimFocusAtMountOrFromLateVoiceCompletion() throws {
        let mac = try RefusalLaneSource.source(at: "Conduck/Views/Conversation/MessageComposerBar.swift")
        XCTAssertTrue(mac.contains(".onAppear {\n            fieldFocused = workbenchDestinationIsActive"))
        XCTAssertTrue(mac.contains("guard workbenchDestinationIsActive else { return }\n                    fieldFocused = true"))
        let work = try RefusalLaneSource.source(at: "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift")
        XCTAssertEqual(work.components(separatedBy: "focusLease.permits(focusRequest, currentScope: viewModel.composerScope,").count - 1, 2)
        XCTAssertEqual(work.components(separatedBy: "destinationIsActive: deskWorkspace?.isActive ?? true)").count - 1, 2)
        XCTAssertTrue(work.contains("focusLease.invalidate()"))
        XCTAssertTrue(work.contains("focusLease.setActive(isActive)"))
        XCTAssertFalse(work.contains("composerFocused = workbenchDestinationIsActive"),
            "An old async View value carries a stale environment, so focus must consult a live owner.")
    }

    func testCaptureFocusLeaseRejectsHideReturnAndOldMountCompletions() {
        let lease = WorkCaptureFocusLease()
        let scope = WorkDeskScope.project(UUID())
        lease.setActive(true)
        let request = lease.capture(scope: scope)
        XCTAssertTrue(lease.permits(request, currentScope: scope, destinationIsActive: true))
        lease.setActive(false)
        XCTAssertFalse(lease.permits(request, currentScope: scope, destinationIsActive: true))
        lease.setActive(true)
        XCTAssertFalse(lease.permits(request, currentScope: scope, destinationIsActive: true),
            "Returning to Work must not authorize a completion from before it was hidden.")
        let current = lease.capture(scope: scope)
        XCTAssertTrue(lease.permits(current, currentScope: scope, destinationIsActive: true))
        lease.invalidate()
        lease.setActive(true)
        XCTAssertFalse(lease.permits(current, currentScope: scope, destinationIsActive: true))
    }

    func testCaptureFocusLeaseUsesLiveScopeAndDestinationForGenericAndProjectPaths() {
        let lease = WorkCaptureFocusLease()
        XCTAssertNil(lease.capture(scope: .all))
        lease.setActive(true)
        let request = lease.capture(scope: .all)
        XCTAssertFalse(lease.permits(request, currentScope: .project(UUID()), destinationIsActive: true))
        XCTAssertFalse(lease.permits(request, currentScope: .all, destinationIsActive: false))
        XCTAssertTrue(lease.permits(request, currentScope: .all, destinationIsActive: true))
        // Repeated active updates do not invalidate the current capture.
        lease.setActive(true)
        XCTAssertTrue(lease.permits(request, currentScope: .all, destinationIsActive: true))
    }
}

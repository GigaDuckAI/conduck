// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureRefreshCoordinatorTests.swift
//
// The board's single load owner and its visibility gate. The first pass always
// runs so the board is warm the first time Work is opened; every later reload is
// deferred while Work is hidden, because the board is its only reader and a chat
// turn posts one reload request per store mutation. Capture drains are durable
// and never wait on visibility — only the reload they trigger does.
//
// Negative assertions are timing-safe by construction: a deferred pass performs
// no work, so "still zero" holds whether or not the debounce has fired. Positive
// assertions poll instead of sleeping a fixed interval.

import Foundation
import XCTest
@testable import Conduck

@MainActor
final class WorkCaptureRefreshCoordinatorTests: XCTestCase {
    /// Short enough to keep the suite quick, long enough that a deferred pass
    /// cannot be mistaken for an immediate one.
    private let debounce = Duration.milliseconds(20)

    func testTheFirstPassRunsEvenWhileWorkIsHidden() async {
        var refreshCount = 0
        let coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: debounce,
            boardIsVisible: { false },
            drainCaptures: { true },
            refresh: { refreshCount += 1 }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await waitUntil("the launch pass loads the board") { refreshCount == 1 }

        XCTAssertEqual(refreshCount, 1, "Opening Work must show projects, not the empty-board copy")
    }

    func testLaterHiddenReloadsAreDeferredUntilWorkComesBack() async {
        var isVisible = false
        var refreshCount = 0
        let coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: debounce,
            boardIsVisible: { isVisible },
            drainCaptures: { true },
            refresh: { refreshCount += 1 }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await waitUntil("the launch pass runs") { refreshCount == 1 }

        // Three chat turns while Work is hidden collapse into one deferred pass.
        coordinator.schedule(includeCaptureDrain: false)
        coordinator.schedule(includeCaptureDrain: false)
        coordinator.schedule(includeCaptureDrain: false)
        await settle()
        XCTAssertEqual(refreshCount, 1, "A chat turn must not pay for a board fetch nobody can see")

        isVisible = true
        coordinator.drainDeferredRefresh()
        await waitUntil("the deferred reload runs") { refreshCount == 2 }
        await settle()

        XCTAssertEqual(refreshCount, 2, "The newest deferred reload lands exactly once")
    }

    func testASectionFlipWithNothingStaleDoesNotRefetch() async {
        var isVisible = false
        var refreshCount = 0
        let coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: debounce,
            boardIsVisible: { isVisible },
            drainCaptures: { true },
            refresh: { refreshCount += 1 }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await waitUntil("the launch pass runs") { refreshCount == 1 }

        isVisible = true
        coordinator.drainDeferredRefresh()
        await settle()

        XCTAssertEqual(refreshCount, 1, "An unchanged board is not refetched on every section switch")
    }

    func testACaptureDrainStillRunsWhileHiddenAndOnlyItsReloadIsDeferred() async {
        var isVisible = false
        var drainCount = 0
        var refreshCount = 0
        let coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: debounce,
            boardIsVisible: { isVisible },
            drainCaptures: {
                drainCount += 1
                return true
            },
            refresh: { refreshCount += 1 }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await waitUntil("the launch pass runs") { refreshCount == 1 }

        // A share arriving later, while the person is in Chats.
        coordinator.schedule(includeCaptureDrain: true)
        await waitUntil("the capture drains while Work is hidden") { drainCount == 2 }
        await settle()

        XCTAssertEqual(refreshCount, 1, "Queue claims are durable; their reload still waits for Work")

        isVisible = true
        coordinator.drainDeferredRefresh()
        await waitUntil("the import reaches the board") { refreshCount == 2 }
        await settle()

        XCTAssertEqual(drainCount, 2, "Coming back to Work reloads; it does not re-drain")
        XCTAssertEqual(refreshCount, 2)
    }

    func testDrainingTheDeferredReloadIsInertWhileWorkIsStillHidden() async {
        var refreshCount = 0
        let coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: debounce,
            boardIsVisible: { false },
            drainCaptures: { true },
            refresh: { refreshCount += 1 }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await waitUntil("the launch pass runs") { refreshCount == 1 }

        coordinator.schedule(includeCaptureDrain: false)
        await settle()
        // The section flipped Work -> Chats: the same hook fires, and must not
        // schedule a pass for a destination that is still hidden.
        coordinator.drainDeferredRefresh()
        await settle()

        XCTAssertEqual(refreshCount, 1)
    }

    func testAVisibleBoardStillReloadsOnEveryMutation() async {
        var refreshCount = 0
        let coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: debounce,
            boardIsVisible: { true },
            drainCaptures: { true },
            refresh: { refreshCount += 1 }
        )

        coordinator.schedule(includeCaptureDrain: false)
        await waitUntil("the first reload runs") { refreshCount == 1 }
        coordinator.schedule(includeCaptureDrain: false)
        await waitUntil("a visible board keeps reloading") { refreshCount == 2 }

        XCTAssertEqual(refreshCount, 2, "The gate only defers; it must never suppress a visible reload")
    }

    /// Long enough for the debounce plus one scheduling turn, and only ever used
    /// where the expected outcome is "nothing more happened".
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }
}

// Conduck — pure truth-table tests for the headless-trigger routing decision
// (Action Button / ControlWidget press draining into the mounted nav host).
// Extracted from `WatchNoteView.drainCoordinatorIfNeeded`; the view executes
// the verdict's side effects, so a regression here is the shipped
// "press Action Button, app just shows the chat, no recording" bug class.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchHeadlessDrainDecisionTests: XCTestCase {

    private let newTarget = WatchCaptureTarget.new(backendRef: "openclaw")

    func testLiveStatesRefuse() {
        let live: [WatchRecordingState] = [.arming, .recording, .uploading, .waiting(startedAt: Date())]
        for state in live {
            XCTAssertEqual(
                HeadlessDrainDecision.make(target: newTarget, displayedConversationID: nil,
                                           state: state, watchEnabled: true),
                .refuse,
                "A genuinely live turn (\(state.phaseKind)) must refuse the trigger."
            )
        }
    }

    func testIdleAndErrorProceed() {
        XCTAssertEqual(
            HeadlessDrainDecision.make(target: newTarget, displayedConversationID: nil,
                                       state: .idle, watchEnabled: true),
            .pushAndStart
        )
        XCTAssertEqual(
            HeadlessDrainDecision.make(target: newTarget, displayedConversationID: nil,
                                       state: .error(message: "stale"), watchEnabled: true),
            .pushAndStart,
            "A lingering error must not permanently swallow the Action Button."
        )
    }

    func testDisabledSurfacesDisabledError() {
        XCTAssertEqual(
            HeadlessDrainDecision.make(target: newTarget, displayedConversationID: nil,
                                       state: .idle, watchEnabled: false),
            .disabledError
        )
        // A LIVE turn outranks the master switch: the view's disabled arm writes
        // `state = .error` directly, which over `.recording` would orphan a hot
        // mic (`stopRecording` guards `state == .recording`). The disable takes
        // effect at the next idle press instead.
        XCTAssertEqual(
            HeadlessDrainDecision.make(target: newTarget, displayedConversationID: nil,
                                       state: .recording, watchEnabled: false),
            .refuse
        )
    }

    func testSameDisplayedExistingTargetStartsDirectly() {
        let id = UUID()
        XCTAssertEqual(
            HeadlessDrainDecision.make(target: .existing(id), displayedConversationID: id,
                                       state: .idle, watchEnabled: true),
            .directStart,
            "Re-pushing the on-screen thread is a SwiftUI no-op — capture must start directly."
        )
    }

    func testDifferentOrAbsentDisplayedThreadPushes() {
        let id = UUID()
        XCTAssertEqual(
            HeadlessDrainDecision.make(target: .existing(id), displayedConversationID: UUID(),
                                       state: .idle, watchEnabled: true),
            .pushAndStart
        )
        XCTAssertEqual(
            HeadlessDrainDecision.make(target: .existing(id), displayedConversationID: nil,
                                       state: .idle, watchEnabled: true),
            .pushAndStart
        )
        XCTAssertEqual(
            HeadlessDrainDecision.make(target: .new(backendRef: "hermes"), displayedConversationID: UUID(),
                                       state: .idle, watchEnabled: true),
            .pushAndStart,
            "A `.new` draft target always pushes, even with a thread on screen."
        )
    }
}

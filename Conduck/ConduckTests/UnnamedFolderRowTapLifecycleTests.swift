// SPDX-License-Identifier: Apache-2.0

// Conduck
// UnnamedFolderRowTapLifecycleTests.swift
//
// Locks what a TAP does to the thread's folder-less row — the row that says a
// turn went out with no output folder because the user's file server stopped
// answering the pre-dispatch witness.
//
// THE BUG THIS PINS. Both manual looks ("Check again", "Search mentioned
// files") deliberately reset the witness breaker before they probe: a user who
// has just repaired their tunnel must not keep sending folder-less turns
// through a cooldown they cannot see. But the breaker's failure streak is also
// the ONLY live input to the row's selection rule, so the reset used to answer
// the empty set synchronously — the row the user had just tapped vanished under
// their finger, before the look ran, taking its explanation and its "Review file
// setup" button with it, and every sibling folder-less row in the thread with
// it. A row that evaporates on touch reads as a crash or a misfire, and it
// removes the affordance the user may have been reaching for next.
//
// The repair separates the two halves: probing reopens IMMEDIATELY (the reset
// is still the point), while the rows are HELD at exactly the set that was on
// screen until something earns their removal — a real answer out of the server,
// a later turn on the lane that did get a folder, or the lane moving. Intent to
// look earns nothing. The pure halves of that rule live in
// `UnnamedOutputFolderRowTests`; this file covers the seam where the view model
// and the real breaker meet, which is where the defect actually lived.
//
// Deterministic + headless: no network, no Core Data, no Keychain. The breaker
// is process-local and reset around every case.

import XCTest
@testable import Conduck

@MainActor
final class UnnamedFolderRowTapLifecycleTests: XCTestCase {

    private typealias Breaker = BackgroundFileTransfer.FileLaneWitnessBreaker

    override func setUp() async throws {
        try await super.setUp()
        Breaker.shared.resetAll()
    }

    override func tearDown() async throws {
        Breaker.shared.resetAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Synthetic lane. `.test` host, and the credential is filler of the right
    /// shape — nothing here resolves to a real server.
    private func makeSnapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.example.test/dav")!,
            username: Constants.fileServerUsername,
            credential: String(repeating: "a", count: 32),
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }

    private func agentTurn(laneID: String?, boxKey: String?) -> MessageRecord {
        MessageRecord(
            id: UUID(),
            role: "agent",
            text: "Saved it.",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            sourceDevice: "iphone",
            outputScanDone: false,
            outputScanLaneID: laneID,
            outputBoxKey: boxKey,
            attachments: []
        )
    }

    /// A view model painted as the thread would have been the instant before the
    /// tap: two folder-less rows on the configured lane, and the breaker sitting
    /// on a failure streak that put them there.
    private func modelWithTwoFolderLessRows(
        _ snapshot: SettingsManager.FileTransferSnapshot
    ) -> (model: ConversationDetailViewModel, tapped: MessageRecord, sibling: MessageRecord) {
        let model = ConversationDetailViewModel(conversationID: UUID())
        let tapped = agentTurn(laneID: snapshot.durableLaneID, boxKey: nil)
        let sibling = agentTurn(laneID: snapshot.durableLaneID, boxKey: nil)
        model.messages = [tapped, sibling]
        model.currentFileLaneID = snapshot.durableLaneID
        model.outputFolderUnnamedIDs = [tapped.id, sibling.id]
        Breaker.shared.recordFailure(lane: Breaker.laneKey(for: snapshot), severity: .unreachable)
        return (model, tapped, sibling)
    }

    // MARK: - Cases

    /// THE REGRESSION. The tap reopens probing and the rows stay exactly where
    /// they were — including the sibling the user never touched.
    func testTheTappedRowSurvivesTheBreakerResetTheTapPerforms() {
        let snapshot = makeSnapshot()
        let (model, tapped, sibling) = modelWithTwoFolderLessRows(snapshot)

        model.reopenWitnessProbing(for: snapshot)

        XCTAssertEqual(
            model.outputFolderUnnamedIDs, [tapped.id, sibling.id],
            "The row deleted itself the instant it was tapped — its title, its explanation and its 'Review file setup' button all went with it, before the look had run."
        )
    }

    /// The reset itself is NOT what was wrong, and must not be lost in the
    /// repair: a deliberate tap is the user asserting their server is worth
    /// asking again, and the very next turn they send has to try to name a
    /// folder rather than sit out the ladder.
    func testTheTapStillReopensProbingOnTheLane() {
        let snapshot = makeSnapshot()
        let (model, _, _) = modelWithTwoFolderLessRows(snapshot)
        XCTAssertEqual(Breaker.shared.decide(lane: Breaker.laneKey(for: snapshot)), .cooldown,
                       "fixture precondition: the lane is inside its backoff before the tap")

        model.reopenWitnessProbing(for: snapshot)

        XCTAssertEqual(Breaker.shared.decide(lane: Breaker.laneKey(for: snapshot)), .probe,
                       "a user who has just fixed their tunnel must not wait out a cooldown they cannot see")
    }

    /// An ordinary reload during the look repaints from the derivation, which is
    /// empty post-reset. The hold has to survive that too, or the row disappears
    /// a beat later instead of instantly — the same defect with a delay.
    func testAReloadDuringTheLookDoesNotDropTheHeldRows() {
        let snapshot = makeSnapshot()
        let (model, tapped, sibling) = modelWithTwoFolderLessRows(snapshot)
        model.reopenWitnessProbing(for: snapshot)

        model.refreshUnnamedFolderRows()

        XCTAssertEqual(model.outputFolderUnnamedIDs, [tapped.id, sibling.id])
    }

    /// EARNED. The look got a real answer out of the server, so the standing
    /// claim "your file server didn't answer" is false and the rows go.
    func testAnAnswerRetiresTheHeldRows() {
        let snapshot = makeSnapshot()
        let (model, _, _) = modelWithTwoFolderLessRows(snapshot)
        model.reopenWitnessProbing(for: snapshot)

        model.releaseUnnamedFolderHold()

        XCTAssertTrue(model.outputFolderUnnamedIDs.isEmpty,
                      "clearing is earned by an answer — and an answer did arrive")
    }

    /// A second tap after an unanswered one re-takes the hold rather than
    /// leaking the rows: the first look resolved nothing, so the rows are still
    /// on screen and still the truth.
    func testASecondTapAfterAnUnansweredLookStillHoldsTheRows() {
        let snapshot = makeSnapshot()
        let (model, tapped, sibling) = modelWithTwoFolderLessRows(snapshot)
        model.reopenWitnessProbing(for: snapshot)   // look one: no release

        model.reopenWitnessProbing(for: snapshot)   // look two

        XCTAssertEqual(model.outputFolderUnnamedIDs, [tapped.id, sibling.id])
    }

    /// A release with nothing held is a no-op, not a way to clear rows a LIVE
    /// streak is still asserting. Belt-and-braces: the tap paths call it on
    /// evidence, and evidence can arrive on a thread that never held anything.
    func testReleasingWithoutAHoldChangesNothing() {
        let model = ConversationDetailViewModel(conversationID: UUID())
        let orphan = UUID()
        model.outputFolderUnnamedIDs = [orphan]

        model.releaseUnnamedFolderHold()

        XCTAssertEqual(model.outputFolderUnnamedIDs, [orphan])
    }
}

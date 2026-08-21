// SPDX-License-Identifier: Apache-2.0

// Conduck — lazy draft-mint contract tests (guardrails 1/2: a `.new` capture
// mints NOTHING until the first non-empty transcript; cancel / empty
// transcript leave ZERO orphan conversations in the CloudKit-synced store;
// the one-shot Ask hint binds the mint to the CAPTURE-TIME gateway choice
// and survives a parallel bound send untouched).
//
// ALSO the draft-ADOPTION contract: a mint is stamped with the capture request
// that owns it and that record outlives the live pin, so a draft suspended
// across its own mint can still identify its conversation afterwards — and a
// mint owned by nobody (a deferred drain replaying an older capture) can never
// be adopted by whatever draft happens to be on screen.
//
// The hops run against an injected in-memory store + never-configured custom
// refs, so every path stops at the not-configured gate AFTER the resolver —
// the mint mechanics execute with zero network. Shared App-Group state (Ask
// hint, quick-capture pointer, in-flight markers) is wiped per test; iCloud
// KVS untouched (unsigned test host → inert store).

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchDraftMintTests: XCTestCase {

    private var store: ConversationStore!
    private var service: WatchRecordingService!

    override func setUp() async throws {
        try await super.setUp()
        wipeSharedState()
        store = ConversationStore(inMemory: true)
        service = WatchRecordingService()
        service.store = store
    }

    override func tearDown() async throws {
        wipeSharedState()
        store = nil
        service = nil
        try await super.tearDown()
    }

    private func wipeSharedState() {
        let appGroup = TestStores.defaults
        appGroup.removeObject(forKey: "watch.inFlight.conversationID")
        appGroup.removeObject(forKey: "watch.inFlight.startedAt")
        appGroup.removeObject(forKey: "watch.inFlight.turnID")
        WatchSettingsReader.shared.clearPendingInAppNewConversationBackend()
        WatchSettingsReader.shared.clearActiveConversation()
        AutoSpeakMailbox.shared.clear()
    }

    func testNonEmptyTranscriptMintsExactlyOneConversationOnCapturedRef() async throws {
        // The CAPTURED ref (the Ask hint) deliberately differs from the live
        // default — the mint must bind to the capture-time choice.
        let capturedRef = "custom_\(UUID().uuidString)"
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend(capturedRef)

        await service.startConverseHop(transcript: "hello wrist")

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1,
                       "Exactly one conversation minted at the first non-empty transcript.")
        XCTAssertEqual(conversations.first?.backend, capturedRef,
                       "The draft must bind to the CAPTURED ref, not the live default.")
        XCTAssertEqual(service.inFlightConversationID, conversations.first?.id,
                       "mintedConversationID must publish so the draft shell adopts the real id.")
        XCTAssertEqual(WatchSettingsReader.shared.resolveActiveConversationID(), conversations.first?.id,
                       "The Ask-mint branch stamps the quick-capture pointer.")
        // Never-configured ref → the hop surfaces not-configured AFTER the
        // mint (zero network); the mint mechanics above hold regardless.
        guard case .error = service.state else {
            return XCTFail("An unconfigured captured ref must surface the not-configured error.")
        }
    }

    func testEmptyTranscriptLeavesZeroOrphans() async throws {
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend("custom_\(UUID().uuidString)")

        await service.startConverseHop(transcript: "  \n ")

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 0,
                       "An empty transcript must mint nothing (guardrail 1/2 — no orphan in the synced store).")
        XCTAssertEqual(service.captureMintCount, 0,
                       "A discard must never read as a mint — the counter is a draft's cue to look for its id.")
        XCTAssertNil(service.lastMintOutcome)
        XCTAssertNil(WatchSettingsReader.shared.consumePendingInAppNewConversationBackend(),
                     "The empty-transcript reset drops the one-shot hint.")
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.inFlightConversationID)
    }

    func testCancelLeavesZeroOrphansAndNoStaleHint() async throws {
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend("custom_\(UUID().uuidString)")

        service.cancelRecording()

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 0,
                       "Cancel before any transcript mints nothing (lazy mint — no delete-on-exit needed).")
        XCTAssertNil(WatchSettingsReader.shared.consumePendingInAppNewConversationBackend(),
                     "Cancel must clear the pending hint — a later headless trigger must never consume it.")
        XCTAssertEqual(service.state, .idle)
    }

    func testAskHintSurvivesParallelBoundSend() async throws {
        let hintRef = "custom_\(UUID().uuidString)"
        let bound = try await store.createConversation(backend: "custom_\(UUID().uuidString)")
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend(hintRef)

        // The bound ref is never configured, so the hop errors at the config
        // gate — AFTER the resolver's bound branch, which must NOT consume
        // the always-new flow's hint ("CRITICAL: do NOT consume" contract).
        let sent = await service.sendTypedText("follow-up", into: bound.id)

        XCTAssertTrue(sent)
        XCTAssertEqual(WatchSettingsReader.shared.consumePendingInAppNewConversationBackend(), hintRef,
                       "The bound resolver branch must leave the Ask hint untouched.")
        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1, "A bound send mints nothing new.")
    }

    // MARK: - Draft adoption (mint outcome)

    func testMintOutcomeCarriesTheOwningRequestID() async throws {
        let request = UUID()
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend("custom_\(UUID().uuidString)")
        // Arms the mic and takes ownership of the turn; the hop below then
        // mints under that ownership.
        service.startCapture(boundTo: .new(backendRef: "ignored"), requestID: request)

        await service.startConverseHop(transcript: "hello wrist")

        let mintedRows = try await store.fetchConversations()
        let minted = try XCTUnwrap(mintedRows.first?.id)
        XCTAssertEqual(service.captureMintCount, 1)
        XCTAssertEqual(service.lastMintOutcome,
                       WatchCaptureMintOutcome(requestID: request, conversationID: minted),
                       "The mint must be stamped with the request that owns it — adoption is a match, not a read.")

        // Tear the armed machine down before its permission Task advances.
        service.cancelRecording()
    }

    func testMintOutcomeSurvivesTheTerminalClearThatWipesThePin() async throws {
        let request = UUID()
        WatchSettingsReader.shared.setPendingInAppNewConversationBackend("custom_\(UUID().uuidString)")
        service.startCapture(boundTo: .new(backendRef: "ignored"), requestID: request)
        await service.startConverseHop(transcript: "hello wrist")
        let mintedRows = try await store.fetchConversations()
        let minted = try XCTUnwrap(mintedRows.first?.id)

        // `dismissError()` runs the same terminal-clear block the reply path
        // reaches through `clearInFlight()` — the boundary that wipes the pin.
        // It is used here because it is the one such boundary a test can reach
        // without a live converse hop.
        service.dismissError()

        XCTAssertNil(service.inFlightConversationID,
                     "The live pin is transient by design — this is the state a suspended draft resumes into.")
        XCTAssertEqual(service.lastMintOutcome?.conversationID, minted,
                       "The OUTCOME must outlive the pin, or a draft that missed the window can never find its thread.")
        XCTAssertEqual(service.lastMintOutcome?.requestID, request)
    }

    func testDeferredMintIsOwnedByNobodyAndRecordsNoOutcome() async throws {
        // A LIVE capture request holds the machine — the state a mounted draft
        // is in. The deferred drain must still own nothing: a claim-nil reset
        // can hand the machine over without passing a terminal boundary, so the
        // hop clears the request itself rather than trusting its caller.
        service.startCapture(boundTo: .new(backendRef: "ignored"), requestID: UUID())
        service.cancelRecording()
        // A deferred relay drain replays a capture taken earlier: it sets the
        // pin directly and never calls `startCapture`, so nothing owns it.
        await service.startDeferredConverseHop(transcript: "an older ask", boundTo: nil)

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1, "The deferred hop still mints (it has a transcript to send).")
        XCTAssertEqual(service.captureMintCount, 1)
        XCTAssertNil(service.lastMintOutcome,
                     "An unowned mint must be adoptable by NO draft — otherwise a draft waiting on its own turn "
                     + "would show the user a conversation belonging to an older, unrelated one.")
    }

    func testDeferredMintIsUnownedEvenWhenARequestStillHoldsTheMachine() async throws {
        // The claim-nil "superseded" resets hand the machine over WITHOUT
        // passing a terminal boundary, so a draft's request can still be
        // latched when the deferred hop runs. Its mint must remain unadoptable
        // — otherwise that draft opens an older turn's conversation.
        let draftRequest = UUID()
        service.startCapture(boundTo: .new(backendRef: "ignored"), requestID: draftRequest)

        await service.startDeferredConverseHop(transcript: "an older ask", boundTo: nil)

        let conversations = try await store.fetchConversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertNil(service.lastMintOutcome,
                     "A deferred hop must never stamp its mint with a draft's request id.")
    }
}

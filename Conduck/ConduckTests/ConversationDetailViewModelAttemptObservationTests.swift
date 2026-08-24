// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationDetailViewModelAttemptObservationTests.swift
//
// The macOS foreground lane's pure decisions about the usage ledger, pinned
// where they can be asserted without standing up a converse round-trip:
//
//   1. `ConversationDetailViewModel.terminalObservation(for:attemptID:)` — how a
//      thrown error becomes the observation that CLOSES an attempt row.
//   2. `TurnModality.inputMode` — how a composer's modality becomes the ledger's
//      input mode.
//   3. `ConversationDetailViewModel.dispatchOrigin(fromMenuBarSurface:)` — how a
//      dispatching surface becomes the ledger's origin.
//
// Both are `nonisolated static` / value-level on purpose: the branches that call
// them are `#if os(macOS)`, but this suite runs on an iOS simulator (the app's
// authoritative test destination), so anything fenced to macOS would be
// untestable by construction. That is the reason the helpers are not private
// closures inside the send path.
//
// The properties that matter here are not "does it return something". They are:
// a failure that reached a response must close its attempt with THAT hop's
// completion instant and whatever the gateway reported (a gateway can bill for
// work it then failed to return); a failure that never reached one must claim no
// usage at all; and a dispatch whose measurement never opened must produce an
// observation that is a no-op rather than one that invents a row — capture is
// fail-open, and a defect in it may never cost the user a reply.

import XCTest
@testable import Conduck

final class ConversationDetailViewModelAttemptObservationTests: XCTestCase {

    private let attemptID = UUID()

    // MARK: - A failure that reached a response

    func testACarriedFailureClosesTheAttemptWithTheHopsOwnInstantAndUsage() throws {
        let landed = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = RemoteAgentSendFailure(
            appError: .remoteAgentServerError,
            wireCode: .upstreamFailure,
            metadata: GatewayResponseMetadata(
                reportedModel: "m-1", reportedInputTokens: 90, reportedTotalTokens: 90
            ),
            completedAt: landed
        )

        let observation = ConversationDetailViewModel.terminalObservation(
            for: failure, attemptID: attemptID, now: Date()
        )

        XCTAssertEqual(observation.attemptID, attemptID)
        XCTAssertEqual(observation.outcome, .failed)
        XCTAssertEqual(observation.completedAt, landed,
                       "The hop ended when the bytes arrived. Re-reading the clock here would charge the store save to the gateway.")
        XCTAssertEqual(observation.appErrorCode, AppError.remoteAgentServerError.errorCode,
                       "Conduck's OWN taxonomy code — never a server status. It is the same code the message row persists, so the dashboard and the thread cannot tell different stories about one failure.")
        let metadata = try XCTUnwrap(observation.metadata)
        XCTAssertEqual(metadata.reportedInputTokens, 90)
        XCTAssertEqual(metadata.reportedModel, "m-1")
    }

    // MARK: - A failure that never reached one

    func testALocalPreflightFailureStampsNowAndClaimsNoUsage() {
        // `AppError.fileTransferNotConfigured` is thrown by the lane
        // revalidation INSIDE the dispatch task — a local refusal with no
        // request behind it. Reporting usage for it would count spend that never
        // happened.
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let observation = ConversationDetailViewModel.terminalObservation(
            for: AppError.fileTransferNotConfigured, attemptID: attemptID, now: now
        )

        XCTAssertEqual(observation.completedAt, now)
        XCTAssertEqual(observation.outcome, .failed)
        XCTAssertEqual(observation.appErrorCode, AppError.fileTransferNotConfigured.errorCode)
        XCTAssertNil(observation.metadata)
    }

    func testTheBodyClassifiedCarrierKeepsItsTaxonomyThroughTheObservation() {
        // `ClassifiedRemoteAgentFailure` can still reach this catch arm from the
        // shared body classifier, and it must not degrade to the generic bucket
        // on its way into the ledger.
        let classified = ClassifiedRemoteAgentFailure(
            appError: .remoteAgentVisionUnsupported, wireCode: .imageUnsupported
        )

        let observation = ConversationDetailViewModel.terminalObservation(
            for: classified, attemptID: attemptID, now: Date()
        )

        XCTAssertEqual(observation.appErrorCode, AppError.remoteAgentVisionUnsupported.errorCode)
    }

    func testAnUnrecognisedErrorBucketsExactlyWhereTheFailureWritersBucketIt() {
        // The same fallback `TurnFailureClassification.init(from:)` applies, so
        // the ledger's code and the message row's code agree even here.
        struct Weird: Error {}

        let observation = ConversationDetailViewModel.terminalObservation(
            for: Weird(), attemptID: attemptID, now: Date()
        )
        let classification = ConversationStore.TurnFailureClassification(
            from: Weird(), hadHistoryImages: nil
        )

        XCTAssertEqual(observation.appErrorCode, AppError.remoteAgentUnreachable.errorCode)
        XCTAssertEqual(observation.appErrorCode, classification.failureCode,
                       "One error, one code — the ledger must never disagree with the row the user is looking at.")
    }

    // MARK: - Fail-open

    func testADispatchWhoseMeasurementNeverOpenedProducesAnInertObservation() {
        // `beginGatewayAttempt` returns nil when the insert failed, and the catch
        // arms then pass a nil id. The observation still exists (one code path,
        // not two) but names no row, so terminalizing it writes nothing — the
        // reply/failure landing is completely unaffected.
        let observation = ConversationDetailViewModel.terminalObservation(
            for: AppError.remoteAgentTimeout, attemptID: nil, now: Date()
        )

        XCTAssertNil(observation.attemptID,
                     "A missing row is a MEASUREMENT no-op. Fabricating an id here would invent an attempt that never opened.")
        XCTAssertEqual(observation.appErrorCode, AppError.remoteAgentTimeout.errorCode)
    }

    // MARK: - Surface → ledger origin

    func testTheOriginNamesTheSurfaceRunningTheDispatch() {
        XCTAssertEqual(ConversationDetailViewModel.dispatchOrigin(fromMenuBarSurface: true), .menuBar)
        XCTAssertEqual(ConversationDetailViewModel.dispatchOrigin(fromMenuBarSurface: false), .app)
    }

    func testARetryFromTheWindowIsNeverCreditedToTheMenuBar() {
        // The regression this pins: one VM instance serves BOTH the menu-bar
        // popover and the window for the same conversation, and the popover
        // latch is keyed by MESSAGE and survives a failed turn. Deriving the
        // origin from that latch credited the menu bar for a retry the user ran
        // from the window. The retry's origin comes from the CALLER instead —
        // the popover's Retry button passes `fromPopover: true`, every window
        // caller keeps the default — so the surface is stated, never inferred.
        let quickCaptureFailedEarlier = true          // still latched in `popoverReplyMessageIDs`
        let retryRanFromTheWindow = false             // `retry(_:)`'s default `fromPopover`

        XCTAssertEqual(
            ConversationDetailViewModel.dispatchOrigin(fromMenuBarSurface: retryRanFromTheWindow),
            .app,
            "The per-surface mix must describe where the attempt ACTUALLY ran."
        )
        XCTAssertNotEqual(
            ConversationDetailViewModel.dispatchOrigin(fromMenuBarSurface: retryRanFromTheWindow),
            ConversationDetailViewModel.dispatchOrigin(fromMenuBarSurface: quickCaptureFailedEarlier),
            "The original send's surface and the retry's surface are independent facts."
        )
    }

    // MARK: - Modality → input mode

    func testEveryComposerModalityHasALedgerInputMode() {
        XCTAssertEqual(TurnModality.voice.inputMode, .voice)
        XCTAssertEqual(TurnModality.text.inputMode, .text)
    }

    func testAModalityNeverProducesTheUnknownOrSharedModes() {
        // `GatewayInputMode` is the wider vocabulary — it also carries `shared`
        // (the share sheet, which never passes through `TurnModality`) and
        // `unknown` (a legacy row with no recorded modality). A live composer
        // send always knows which it was, so neither may ever be the answer here.
        for modality in [TurnModality.voice, .text] {
            XCTAssertNotEqual(modality.inputMode, .unknown)
            XCTAssertNotEqual(modality.inputMode, .shared)
        }
    }

    func testARetrysInputModeComesFromTheOriginalTurnsRecordedModality() {
        // A retry acquires no new input, so the mode describes the ORIGINAL
        // capture, read off the stored `sourceDevice` tag — which is what the
        // macOS retry branch passes into its draft.
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "mac-voice"), .voice)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "iphone-text"), .text)
        XCTAssertEqual(GatewayInputMode.from(sourceDevice: "mac"), .unknown,
                       "A legacy tag recorded no modality, and `unknown` is the honest answer rather than a guess that would skew the mix.")
    }
}

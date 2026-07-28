// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingImportFlowTests.swift
//
// The pairing-import LIFECYCLE — the sequence properties that no model-level test
// can reach: that scanning contacts nothing, that nothing is persisted before
// consent, that every way of abandoning cleans up after itself, and that a
// decision made about one destination is never executed against another.
//
// These exist because two real concurrency bugs shipped into review while this
// logic lived inside a SwiftUI `View`: an unguarded `await` that persisted after
// Cancel, and a cancellation checkpoint whose Task was never retained. Both were
// caught by reading, because nothing could drive the flow. Every test below would
// have failed on one of those two states.
//
// `StubPairingImportEnvironment` records the CALL SEQUENCE, which is what most of
// these assert: "the server was never contacted" is a statement about which
// methods ran, not about their results.

import XCTest
@testable import Conduck

// MARK: - Stub environment

@MainActor
final class StubPairingImportEnvironment: PairingImportEnvironment {

    enum Call: Equatable {
        case plan, review, resolveTrust, execute, gatewayTest, fileTest, discardDraft
    }

    /// Every call, in order. The network-touching ones are `.resolveTrust`,
    /// `.gatewayTest` and `.fileTest`; the storage-touching one is `.execute`.
    private(set) var calls: [Call] = []
    private(set) var discardedDrafts: [RemoteAgentRef] = []
    private(set) var executedGatewayPins: [String?] = []
    private(set) var executedFileServerPins: [String?] = []
    /// Whether the resolve-trust call observed cancellation when it resumed.
    private(set) var resolveTrustSawCancellation: Bool?

    var planResult: PairingImportPlan = .ready(target: .builtin(.openclaw))
    var trustResult: PairingTrustResolution = .proceed(gatewayPin: nil, fileServerPin: nil)
    var executeResult: PairingImportOutcome = .committed
    var gatewayTestResult: PairingGatewayTestOutcome = .passed
    var fileTestResult = PairingFileTestResult(passed: true, failureMessage: nil, retryable: true)

    /// Successive `review` answers; the last repeats. Empty → `defaultModel`.
    /// A test models "the target moved underneath" by making a later entry differ.
    var reviewResults: [PairingReviewModel] = []
    private var reviewIndex = 0

    /// Park `plan` / `resolveTrust` until `release…()` so a test can abandon the
    /// import while the await is genuinely in flight.
    var suspendPlan = false
    var suspendResolveTrust = false
    private var planGate: CheckedContinuation<Void, Never>?
    private var trustGate: CheckedContinuation<Void, Never>?

    var planIsSuspended: Bool { planGate != nil }
    var resolveTrustIsSuspended: Bool { trustGate != nil }

    func releasePlan() { planGate?.resume(); planGate = nil }
    func releaseResolveTrust() { trustGate?.resume(); trustGate = nil }

    static let defaultModel = PairingReviewModel(
        gatewayDestination: "https://gw.example.test:18789",
        previousGatewayDestination: nil,
        targetName: nil,
        fileLane: nil,
        becomesDefault: true
    )

    var didTouchTheNetwork: Bool {
        calls.contains { $0 == .resolveTrust || $0 == .gatewayTest || $0 == .fileTest }
    }

    var didPersist: Bool { calls.contains(.execute) }

    // MARK: PairingImportEnvironment

    func plan(_ payload: PairingPayload, lockedTarget: RemoteAgentRef?) async -> PairingImportPlan {
        calls.append(.plan)
        if suspendPlan {
            await withCheckedContinuation { planGate = $0 }
        }
        return planResult
    }

    func review(_ payload: PairingPayload, target: RemoteAgentRef, freshlyMinted: Bool) async -> PairingReviewModel {
        calls.append(.review)
        guard !reviewResults.isEmpty else { return Self.defaultModel }
        let model = reviewResults[min(reviewIndex, reviewResults.count - 1)]
        reviewIndex += 1
        return model
    }

    func resolveTrust(_ payload: PairingPayload) async -> PairingTrustResolution {
        calls.append(.resolveTrust)
        if suspendResolveTrust {
            await withCheckedContinuation { trustGate = $0 }
        }
        resolveTrustSawCancellation = Task.isCancelled
        return trustResult
    }

    func execute(_ payload: PairingPayload, target: RemoteAgentRef,
                 gatewayPin: String?, fileServerPin: String?) async -> PairingImportOutcome {
        calls.append(.execute)
        executedGatewayPins.append(gatewayPin)
        executedFileServerPins.append(fileServerPin)
        return executeResult
    }

    func runGatewayTest(_ payload: PairingPayload, target: RemoteAgentRef) async -> PairingGatewayTestOutcome {
        calls.append(.gatewayTest)
        return gatewayTestResult
    }

    func runFileTest(for target: RemoteAgentRef) async -> PairingFileTestResult {
        calls.append(.fileTest)
        return fileTestResult
    }

    func discardDraft(_ target: RemoteAgentRef) {
        calls.append(.discardDraft)
        discardedDrafts.append(target)
    }
}

// MARK: - Tests

@MainActor
final class PairingImportFlowTests: XCTestCase {

    private var env: StubPairingImportEnvironment!
    private let openclaw: RemoteAgentRef = .builtin(.openclaw)
    private let customTarget: RemoteAgentRef = .custom(UUID())

    override func setUp() async throws {
        try await super.setUp()
        env = StubPairingImportEnvironment()
    }

    // MARK: Fixtures

    private func code(kind: String = "openclaw",
                      name: String? = nil,
                      url: String = "https://gw.example.test:18789",
                      fileServer: [String: Any]? = nil) throws -> String {
        var gateway: [String: Any] = ["kind": kind, "url": url, "auth": "none"]
        if let name { gateway["name"] = name }
        var dict: [String: Any] = ["v": 1, "gateway": gateway]
        if let fileServer { dict["fileServer"] = fileServer }
        return "conduck-setup:v1:" + (try JSONSerialization.data(withJSONObject: dict)).base64EncodedString()
    }

    private func makeFlow(
        lockedTarget: RemoteAgentRef? = nil,
        onImported: ((RemoteAgentRef) -> Void)? = nil,
        onConnected: ((RemoteAgentRef) -> Void)? = nil
    ) -> PairingImportFlow {
        PairingImportFlow(environment: env, lockedTarget: lockedTarget,
                          onImported: onImported, onConnected: onConnected)
    }

    /// Drive the main actor until `condition` holds. Every stub answer resolves
    /// immediately unless a test parked it, so this settles the flow's
    /// unstructured Tasks without exposing their handles to production code.
    private func settle(until condition: () -> Bool,
                        _ message: String,
                        file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func scanIntoReview(_ flow: PairingImportFlow,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        flow.handleCode(try code())
        await settle(until: { flow.phase == .review },
                     "the code should have reached the review card", file: file, line: line)
    }

    // MARK: - Nothing happens until Connect

    /// The invariant that makes a hostile QR code safe to point a camera at.
    func testScanningACodeContactsNothingAndPersistsNothing() async throws {
        let flow = makeFlow()
        try await scanIntoReview(flow)

        XCTAssertFalse(env.didTouchTheNetwork,
                       "Scanning must not reach the server — a hostile code would otherwise get a callback just for being scanned.")
        XCTAssertFalse(env.didPersist, "Scanning must not configure anything.")
        XCTAssertEqual(env.calls, [.plan, .review])
    }

    func testConnectIsTheFirstThingThatReachesTheServer() async throws {
        let flow = makeFlow()
        try await scanIntoReview(flow)
        XCTAssertFalse(env.didTouchTheNetwork)

        flow.connect()
        await settle(until: { self.env.didPersist }, "connect should have completed the import")

        XCTAssertTrue(env.calls.contains(.resolveTrust))
        // The re-read at Connect, then the re-read at the commit gate.
        XCTAssertEqual(env.calls.filter { $0 == .review }.count, 3,
                       "One review at scan, one at Connect, one immediately before committing.")
    }

    // MARK: - Abandonment leaves nothing behind

    /// The 2a bug, verbatim: tap Import, then Cancel, and the gateway used to be
    /// configured anyway when the probe returned.
    func testCancellingDuringTheTrustProbeNeverPersists() async throws {
        let flow = makeFlow()
        try await scanIntoReview(flow)
        env.suspendResolveTrust = true

        flow.connect()
        await settle(until: { self.env.resolveTrustIsSuspended }, "the probe should be in flight")

        flow.invalidatePendingImport()
        env.releaseResolveTrust()
        for _ in 0..<200 { await Task.yield() }

        XCTAssertFalse(env.didPersist,
                       "A probe that returns after the user cancelled must not configure anything.")
    }

    /// Cancel must stop the outbound work, not merely discard its answer: the
    /// probe checks two lanes in sequence, so a resolution that keeps running
    /// would open a second connection to an attacker-selected file host.
    func testCancellingDuringTheTrustProbeCancelsTheProbeItself() async throws {
        let flow = makeFlow()
        try await scanIntoReview(flow)
        env.suspendResolveTrust = true

        flow.connect()
        await settle(until: { self.env.resolveTrustIsSuspended }, "the probe should be in flight")

        flow.invalidatePendingImport()
        env.releaseResolveTrust()
        await settle(until: { self.env.resolveTrustSawCancellation != nil }, "the probe should have resumed")

        XCTAssertEqual(env.resolveTrustSawCancellation, true,
                       "The retained Task must actually be cancelled, or the checkpoint between lanes can never fire.")
    }

    /// Planning MINTS the roster draft for a free-target custom, so abandoning
    /// mid-plan must clean it up — the task that holds it is the only thing that
    /// knows about it.
    func testCancellingDuringPlanningDiscardsTheMintedDraft() async throws {
        env.planResult = .ready(target: customTarget)
        env.suspendPlan = true
        let flow = makeFlow()

        flow.handleCode(try code(kind: "custom", name: "Home LLM"))
        await settle(until: { self.env.planIsSuspended }, "planning should be in flight")

        flow.invalidatePendingImport()
        env.releasePlan()
        await settle(until: { !self.env.discardedDrafts.isEmpty },
                     "the orphaned draft should have been discarded")

        XCTAssertEqual(env.discardedDrafts, [customTarget])
        XCTAssertEqual(flow.phase, .input)
        XCTAssertFalse(env.didPersist)
    }

    /// Dismissing the sheet from the review card (swipe, window close, Cancel).
    func testAbandoningFromTheReviewCardDiscardsTheDraft() async throws {
        env.planResult = .ready(target: customTarget)
        let flow = makeFlow()
        flow.handleCode(try code(kind: "custom", name: "Home LLM"))
        await settle(until: { flow.phase == .review }, "should have reached the card")

        flow.invalidatePendingImport()

        XCTAssertEqual(env.discardedDrafts, [customTarget])
        XCTAssertNil(flow.reviewContext)
    }

    func testUseADifferentCodeDiscardsTheDraftAndReArmsTheScanner() async throws {
        env.planResult = .ready(target: customTarget)
        let flow = makeFlow()
        flow.handleCode(try code(kind: "custom", name: "Home LLM"))
        await settle(until: { flow.phase == .review }, "should have reached the card")
        let generationBefore = flow.scannerGeneration

        flow.useDifferentCode()

        XCTAssertEqual(env.discardedDrafts, [customTarget])
        XCTAssertEqual(flow.phase, .input)
        XCTAssertGreaterThan(flow.scannerGeneration, generationBefore,
                             "the camera must be re-armed or the viewport stays frozen")
    }

    /// A locked target owns no draft — abandoning must not try to discard someone
    /// else's configured gateway.
    func testAbandoningALockedTargetImportDiscardsNothing() async throws {
        env.planResult = .ready(target: openclaw)
        let flow = makeFlow(lockedTarget: openclaw)
        try await scanIntoReview(flow)

        flow.invalidatePendingImport()

        XCTAssertTrue(env.discardedDrafts.isEmpty,
                      "Only a freshly minted draft may be discarded; a real gateway must survive a cancel.")
    }

    // MARK: - The reviewed snapshot binds the commit

    /// The blocker Codex found: the card was compared before a probe, then
    /// committed without looking again.
    func testATargetThatMovesBeforeTheCommitBlocksTheCommit() async throws {
        let moved = PairingReviewModel(
            gatewayDestination: "https://gw.example.test:18789",
            previousGatewayDestination: "https://production.example.test",
            targetName: "OpenClaw",
            fileLane: nil,
            becomesDefault: false
        )
        // Scan and the Connect re-read agree; the FINAL gate sees a moved slot.
        env.reviewResults = [StubPairingImportEnvironment.defaultModel, StubPairingImportEnvironment.defaultModel, moved]
        let flow = makeFlow()
        try await scanIntoReview(flow)

        flow.connect()
        await settle(until: { flow.reviewContext?.notice != nil },
                     "the moved destination should have been surfaced")

        XCTAssertFalse(env.didPersist,
                       "A destination that moved after consent must never be written.")
        XCTAssertEqual(flow.reviewContext?.notice, .destinationChanged)
        XCTAssertEqual(flow.reviewContext?.model, moved, "the card must now show the NEW facts")
        XCTAssertEqual(flow.phase, .review)
    }

    /// The cheaper half of the same gate: catch it before spending a network call.
    func testATargetThatMovesBeforeProbingBlocksBeforeAnyNetworkCall() async throws {
        let moved = PairingReviewModel(
            gatewayDestination: "https://elsewhere.example.test",
            previousGatewayDestination: nil, targetName: nil, fileLane: nil,
            becomesDefault: true
        )
        env.reviewResults = [StubPairingImportEnvironment.defaultModel, moved]
        let flow = makeFlow()
        try await scanIntoReview(flow)

        flow.connect()
        await settle(until: { flow.reviewContext?.notice != nil }, "should have refused")

        XCTAssertFalse(env.didTouchTheNetwork,
                       "No point probing a destination the user did not consent to.")
    }

    /// A trust refusal the user dismissed must not be a way around the commit
    /// gate either: backing out of the alert returns to the card, and Connect
    /// from there re-reads before acting, exactly like the first time.
    func testConnectingAgainAfterARefusalStillGoesThroughTheFinalGate() async throws {
        let moved = PairingReviewModel(
            gatewayDestination: "https://gw.example.test:18789",
            previousGatewayDestination: "https://production.example.test",
            targetName: "OpenClaw", fileLane: nil,
            becomesDefault: false
        )
        // scan, Connect re-read, then the commit gate sees the move.
        env.reviewResults = [StubPairingImportEnvironment.defaultModel,
                             StubPairingImportEnvironment.defaultModel, moved]
        env.trustResult = .blocked(lane: .gateway, block: .certificateNotPubliclyTrusted)
        let flow = makeFlow()
        try await scanIntoReview(flow)

        flow.connect()
        await settle(until: { flow.showingTrustBlockAlert }, "the block alert should be up")
        flow.returnToReview(notice: .refused("because reasons"))

        // The server has since been fixed; the destination has not.
        env.trustResult = .proceed(gatewayPin: nil, fileServerPin: nil)
        flow.connect()
        await settle(until: { flow.reviewContext?.notice == .destinationChanged },
                     "should have refused after the alert")

        XCTAssertFalse(env.didPersist,
                       "A destination that moved while an alert sat open must never be written.")
    }

    // MARK: - Certificate outcomes land somewhere the user can see

    /// A refusal raised from an alert vanishes with the alert. Carrying it back
    /// onto the card is what stops the user tapping Connect again into the same
    /// wall with no explanation.
    func testARefusalStaysVisibleOnTheCardAfterTheAlertCloses() async throws {
        env.trustResult = .blocked(lane: .gateway, block: .certificateNotPubliclyTrusted)
        let flow = makeFlow()
        try await scanIntoReview(flow)

        flow.connect()
        await settle(until: { flow.showingTrustBlockAlert }, "the block alert should be up")
        flow.returnToReview(notice: .refused("because reasons"))

        XCTAssertEqual(flow.reviewContext?.notice, .refused("because reasons"))
        XCTAssertEqual(flow.phase, .review)
        XCTAssertFalse(env.didPersist, "A refused import must configure nothing.")
    }

    /// Backing out of the refusal keeps the import alive — the draft belongs to a
    /// card the user is still standing on, not to an abandoned attempt.
    func testDismissingTheRefusalReturnsToTheCardWithTheDraftIntact() async throws {
        env.planResult = .ready(target: customTarget)
        env.trustResult = .blocked(lane: .gateway, block: .certificateNotPubliclyTrusted)
        let flow = makeFlow()
        flow.handleCode(try code(kind: "custom", name: "Home LLM"))
        await settle(until: { flow.phase == .review }, "should have reached the card")

        flow.connect()
        await settle(until: { flow.showingTrustBlockAlert }, "the block alert should be up")
        flow.returnToReview(notice: .refused("because reasons"))

        XCTAssertEqual(flow.phase, .review)
        XCTAssertNotNil(flow.reviewContext, "the card must survive — this is one step back, not out")
        XCTAssertTrue(env.discardedDrafts.isEmpty,
                      "Dismissing a refusal is not abandoning the import; the draft is still live.")
    }

    /// A server that is merely DOWN is not a trust problem and must not be
    /// treated as one: the configuration saves, and the connectivity stage that
    /// follows is where the user learns it could not be reached — with the retry
    /// affordances that stage already owns.
    func testAnUnreachableServerStillImportsAndFailsAtTheConnectivityStage() async throws {
        env.trustResult = .proceed(gatewayPin: nil, fileServerPin: nil)
        env.gatewayTestResult = .failed(message: "couldn't reach it",
                                        error: .remoteAgentUnreachable)
        let flow = makeFlow()
        try await scanIntoReview(flow)

        flow.connect()
        await settle(until: { flow.phase == .done }, "the run should have finished")

        XCTAssertTrue(env.didPersist, "An unreachable server is a retry, not a bad code.")
        XCTAssertEqual(flow.stageStatus[.gateway] ?? .pending,
                       .failed("couldn't reach it", retryable: true))
        XCTAssertTrue(flow.gatewayStageFailed, "the recovery actions must be offered")
        XCTAssertTrue(flow.gatewayFailureIsRetryable,
                      "A server that is merely down is the one failure 'Try again' can actually clear.")
    }

    // MARK: - What actually gets written

    /// A save that fails leaves a minted draft with nothing behind it.
    func testAFailedSaveDiscardsAFreshlyMintedDraft() async throws {
        env.planResult = .ready(target: customTarget)
        env.executeResult = .failed
        let flow = makeFlow()

        flow.handleCode(try code(kind: "custom", name: "Home LLM"))
        await settle(until: { flow.phase == .review }, "should have reached the card")
        flow.connect()
        await settle(until: { flow.phase == .done }, "the run should have finished")

        XCTAssertEqual(env.discardedDrafts, [customTarget])
        XCTAssertEqual(flow.stageStatus[.gateway] ?? .pending, .pending,
                       "a failed save must not go on to probe a config that isn't there")
    }

    // MARK: - Host hooks

    func testOnConnectedFiresOnlyWhenTheGatewayStageActuallyPassed() async throws {
        env.gatewayTestResult = .failed(message: "nope", error: .remoteAgentUnreachable)
        var connectedRefs: [RemoteAgentRef] = []
        var importedRefs: [RemoteAgentRef] = []
        let flow = makeFlow(onImported: { importedRefs.append($0) },
                            onConnected: { connectedRefs.append($0) })

        try await scanIntoReview(flow)
        flow.connect()
        await settle(until: { flow.phase == .done }, "the run should have finished")

        XCTAssertEqual(importedRefs, [openclaw], "a save that committed must report the import")
        XCTAssertTrue(connectedRefs.isEmpty,
                      "a save that never verified must NOT report a connection")
    }

    func testHooksFireExactlyOnceEvenAfterDismissal() async throws {
        var importedRefs: [RemoteAgentRef] = []
        var connectedRefs: [RemoteAgentRef] = []
        let flow = makeFlow(onImported: { importedRefs.append($0) },
                            onConnected: { connectedRefs.append($0) })

        try await scanIntoReview(flow)
        flow.connect()
        await settle(until: { flow.phase == .done }, "the run should have finished")
        flow.handleDisappear()
        flow.handleDisappear()

        XCTAssertEqual(importedRefs, [openclaw])
        XCTAssertEqual(connectedRefs, [openclaw])
    }

    // MARK: - Blocked plans

    func testABlockedPlanReturnsToInputAndMintsNothing() async throws {
        env.planResult = .blocked(.customGatewayCapReached)
        let flow = makeFlow()

        flow.handleCode(try code(kind: "custom", name: "Home LLM"))
        await settle(until: { flow.inlineError != nil }, "should have surfaced the cap error")

        XCTAssertEqual(flow.phase, .input)
        XCTAssertNil(flow.reviewContext)
        XCTAssertTrue(env.discardedDrafts.isEmpty, "a blocked plan never minted anything to discard")
        XCTAssertFalse(env.didTouchTheNetwork)
    }

    func testAnUnparseableCodeNeverReachesThePlanner() async throws {
        let flow = makeFlow()

        flow.handleCode("not-a-conduck-code")
        await settle(until: { flow.inlineError != nil }, "should have surfaced a parse error")

        XCTAssertEqual(env.calls, [], "a string that isn't a setup code must not start an import")
        XCTAssertEqual(flow.phase, .input)
    }

    // MARK: - No first-contact trust anywhere

    /// The pins that reach storage come from the resolver, and the resolver's
    /// only answer is "ordinary trust". Nothing in this flow can produce a
    /// non-nil pin — there is no consent alert, no override, and no retry that
    /// pins a presented key, because a pin cannot rescue a chain the system
    /// rejected in the first place.
    func testNoImportPathEverStoresACertificatePin() async throws {
        env.trustResult = .proceed(gatewayPin: nil, fileServerPin: nil)
        let flow = makeFlow()

        try await scanIntoReview(flow)
        flow.connect()
        await settle(until: { self.env.didPersist }, "should have imported")

        XCTAssertEqual(env.executedGatewayPins, [nil])
        XCTAssertEqual(env.executedFileServerPins, [nil])
    }

    /// The gateway stage has exactly two terminal outcomes. An untrusted
    /// certificate arrives as an ordinary `.failed` — there is no amber
    /// pause state for it to land in, so the run finishes and the recovery
    /// actions are what the user gets.
    func testAnUntrustedCertificateAtTheGatewayStageIsAPlainFailure() async throws {
        env.gatewayTestResult = .failed(message: CertificateTrustCopy.untrustedRefusalWithRemedy,
                                        error: .remoteAgentCertUntrusted)
        let flow = makeFlow()

        try await scanIntoReview(flow)
        flow.connect()
        await settle(until: { flow.phase == .done }, "the run should have finished")

        XCTAssertEqual(flow.stageStatus[.gateway] ?? .pending,
                       .failed(CertificateTrustCopy.untrustedRefusalWithRemedy, retryable: false))
        XCTAssertTrue(flow.gatewayStageFailed,
                      "There is no trust-and-retry to shadow the recovery section any more.")
    }

    /// Each certificate refusal is TERMINAL, so the recovery section must show
    /// its way-out actions WITHOUT the retry: the probe reaches the same verdict
    /// every attempt until something outside the app changes, and a prominent
    /// "Try again" over a refusal both promises what it cannot deliver and
    /// buries the stage row's remedy under a spinner.
    func testEveryCertificateRefusalAtTheGatewayStageWithholdsTheRetry() async throws {
        let refusals: [(AppError, String)] = [
            (.remoteAgentCertUntrusted, CertificateTrustCopy.untrustedRefusalWithRemedy),
            (.remoteAgentCertMismatch, CertificateTrustCopy.pinMismatchRefusalWithRemedy),
            (.remoteAgentCertKeyUnpinnable, CertificateTrustCopy.keyUnpinnableRefusalWithRemedy),
        ]
        for (error, message) in refusals {
            // A fresh stub per refusal — the flow is single-use, so each arm
            // needs its own run from the input phase.
            env = StubPairingImportEnvironment()
            env.gatewayTestResult = .failed(message: message, error: error)
            let flow = makeFlow()

            try await scanIntoReview(flow)
            flow.connect()
            await settle(until: { flow.phase == .done }, "the run should have finished")

            XCTAssertTrue(flow.gatewayStageFailed,
                          "\(error): the way-out actions are still the user's exit.")
            XCTAssertFalse(flow.gatewayFailureIsRetryable,
                           "\(error): a terminal refusal must not be offered a retry that reaches the identical verdict.")
        }
    }

    /// The counterpart, and the reason the gate rides the taxonomy rather than a
    /// certificate special case: a failure with no typed error behind it keeps
    /// its retry. Unknown is not terminal.
    func testAnUntypedGatewayFailureKeepsItsRetry() async throws {
        env.gatewayTestResult = .failed(message: "Unexpected error. Try again.", error: nil)
        let flow = makeFlow()

        try await scanIntoReview(flow)
        flow.connect()
        await settle(until: { flow.phase == .done }, "the run should have finished")

        XCTAssertTrue(flow.gatewayFailureIsRetryable,
                      "No taxonomy entry means no terminality claim — the affordance stays.")
    }
}

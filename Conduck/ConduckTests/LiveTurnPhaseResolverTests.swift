// SPDX-License-Identifier: Apache-2.0

// Conduck
// LiveTurnPhaseResolverTests.swift
//
// The honesty rule for the in-flight row, tested with no socket, no
// URLSession and no view: given when a turn claimed the conversation, whether
// any of its request body has left the device, and whether this device has a
// usable network path, WHAT may the row say and WHERE does its clock start?
//
// The load-bearing cases are the two that decide whether the app names the
// user's gateway. On iPhone the converse hop rides a background URLSession that
// parks an un-sent request until a route exists, so "{Gateway} is answering…"
// before departure would blame a server that received nothing — and the elapsed
// counter beside it would report a wait the gateway never had. The reverse
// error is cheap and deliberate: an ambiguous reading resolves to `.sending`,
// which under-claims for a moment and then corrects itself.

import XCTest
@testable import Conduck

final class LiveTurnPhaseResolverTests: XCTestCase {

    private let claimed = Date(timeIntervalSince1970: 1_000)
    private let departed = Date(timeIntervalSince1970: 1_042)

    // MARK: - Rule 1 — nothing live here

    func testNoLiveClaimResolvesToNoIndicator() {
        XCTAssertNil(LiveTurnPhaseResolver.resolve(
            liveSince: nil, dispatchedAt: nil, pathIsUnsatisfied: false))
        XCTAssertNil(LiveTurnPhaseResolver.resolve(
            liveSince: nil, dispatchedAt: nil, pathIsUnsatisfied: true))
    }

    /// A dispatch stamp with no live claim is not a row: the turn resolved and
    /// the claim was released. Nothing may render for it.
    func testDispatchStampWithoutLiveClaimStillResolvesToNoIndicator() {
        XCTAssertNil(LiveTurnPhaseResolver.resolve(
            liveSince: nil, dispatchedAt: departed, pathIsUnsatisfied: false))
    }

    // MARK: - Rule 2 — bytes left the device

    func testDepartedBytesResolveToAnsweringAndClockStartsAtHandoff() {
        let resolved = LiveTurnPhaseResolver.resolve(
            liveSince: claimed, dispatchedAt: departed, pathIsUnsatisfied: false)
        XCTAssertEqual(resolved?.phase, .answering)
        // The HAND-OFF, not the claim: the number beside "is answering" means
        // "the gateway has had this for m:ss".
        XCTAssertEqual(resolved?.since, departed)
    }

    /// Rule 2 OUTRANKS rule 3, deliberately. If the body left and the path
    /// dropped afterwards, the gateway may well hold the turn and be working on
    /// it — saying "Waiting for a connection…" there would be an implicit claim
    /// of non-delivery this client cannot make.
    func testDepartedBytesOutrankAnUnsatisfiedPath() {
        let resolved = LiveTurnPhaseResolver.resolve(
            liveSince: claimed, dispatchedAt: departed, pathIsUnsatisfied: true)
        XCTAssertEqual(resolved?.phase, .answering)
        XCTAssertEqual(resolved?.since, departed)
    }

    // MARK: - Rule 3 — nothing sent, no route

    func testUndispatchedWithUnsatisfiedPathResolvesToWaitingForNetwork() {
        let resolved = LiveTurnPhaseResolver.resolve(
            liveSince: claimed, dispatchedAt: nil, pathIsUnsatisfied: true)
        XCTAssertEqual(resolved?.phase, .waitingForNetwork)
        // The CLAIM: this phase's clock means "this turn has been waiting m:ss".
        XCTAssertEqual(resolved?.since, claimed)
    }

    // MARK: - Rule 4 — nothing sent, path present

    func testUndispatchedWithSatisfiedPathResolvesToSending() {
        let resolved = LiveTurnPhaseResolver.resolve(
            liveSince: claimed, dispatchedAt: nil, pathIsUnsatisfied: false)
        XCTAssertEqual(resolved?.phase, .sending)
        XCTAssertEqual(resolved?.since, claimed)
    }

    /// An UNKNOWN path reads as `false` at the observer, so the refused-gateway
    /// case (a route exists, the connection is being retried out of process)
    /// must land on `.sending` — never on a claim that the device is offline.
    func testRefusedConnectionWithARouteNeverClaimsOffline() {
        let resolved = LiveTurnPhaseResolver.resolve(
            liveSince: claimed, dispatchedAt: nil, pathIsUnsatisfied: false)
        XCTAssertNotEqual(resolved?.phase, .waitingForNetwork)
    }

    // MARK: - What the phases actually say

    func testWaitingForNetworkNeverNamesTheGateway() {
        let label = ThinkingIndicator.label(phase: .waitingForNetwork, backendName: "OpenClaw")
        XCTAssertEqual(label, String(localized: "chat.waitingForConnection",
                                     defaultValue: "Waiting for a connection…"))
        XCTAssertFalse(label.contains("OpenClaw"))
        // Same label whatever the bound gateway is — no gateway is involved.
        XCTAssertEqual(
            label,
            ThinkingIndicator.label(phase: .waitingForNetwork, backendName: ""))
    }

    /// A surface that crossfades between phases must actually change words.
    func testAllFourPhaseLabelsAreDistinct() {
        let labels = [
            ThinkingIndicator.label(phase: .transcribing, backendName: "Hermes"),
            ThinkingIndicator.label(phase: .sending, backendName: "Hermes"),
            ThinkingIndicator.label(phase: .waitingForNetwork, backendName: "Hermes"),
            ThinkingIndicator.label(phase: .answering, backendName: "Hermes")
        ]
        XCTAssertEqual(Set(labels).count, 4)
    }

    // MARK: - The list row says the same words as the thread

    func testListCopyDelegatesTheResolvedPhase() {
        XCTAssertEqual(
            ConversationActivityCopy.working(.live, gatewayName: "OpenClaw", phase: .sending),
            ThinkingIndicator.label(phase: .sending, backendName: "OpenClaw"))
        XCTAssertEqual(
            ConversationActivityCopy.working(
                .live, gatewayName: "OpenClaw", phase: .waitingForNetwork),
            ThinkingIndicator.label(phase: .waitingForNetwork, backendName: "OpenClaw"))
    }

    /// The default keeps every caller that resolves no phase — the wrist, and
    /// the suites that assert the settled wording — on today's copy.
    func testListCopyDefaultsToAnswering() {
        XCTAssertEqual(
            ConversationActivityCopy.working(.live, gatewayName: "OpenClaw"),
            ThinkingIndicator.label(phase: .answering, backendName: "OpenClaw"))
    }

    /// The empty-name fallback survives the phase parameter: a `.live` row whose
    /// bound ref has not resolved yet says a bare "Answering…", never
    /// " is answering…".
    func testAnsweringEmptyGatewayNameStillFallsBackThroughTheListCopy() {
        let copy = ConversationActivityCopy.working(.live, gatewayName: "   ", phase: .answering)
        XCTAssertEqual(copy, String(localized: "Answering…"))
        XCTAssertFalse(copy.hasPrefix(" "))
    }

    /// The two non-`.live` confidences ignore the phase entirely — they are
    /// statements about a stored row this device cannot see a request for.
    func testHedgedAndStaleIgnoreThePhase() {
        for phase in [ThinkingPhase.sending, .waitingForNetwork, .answering] {
            XCTAssertEqual(
                ConversationActivityCopy.working(.hedged, gatewayName: "OpenClaw", phase: phase),
                ConversationActivityCopy.working(.hedged, gatewayName: "OpenClaw"))
            XCTAssertEqual(
                ConversationActivityCopy.working(.stale, gatewayName: "OpenClaw", phase: phase),
                ConversationActivityCopy.working(.stale, gatewayName: "OpenClaw"))
        }
    }

    // MARK: - The spoken row matches the seen row

    private func workingLabel(phase: ThinkingPhase) -> String {
        MessageRowFormatters.rowAccessibilityLabel(
            state: ConversationRowState(
                activity: .working(.live, since: claimed), hasUnseenReply: false),
            title: "Kitchen rebuild",
            subtitle: nil,
            gatewayName: "OpenClaw",
            lastActivityAt: claimed,
            showsGateway: true,
            phase: phase,
            now: claimed
        )
    }

    /// `.answering` puts the gateway INTO the status sentence, so the label must
    /// not then repeat it as a separate component.
    func testAnsweringLabelNamesTheGatewayExactlyOnce() {
        let label = workingLabel(phase: .answering)
        XCTAssertTrue(label.contains("OpenClaw is answering"))
        XCTAssertEqual(label.components(separatedBy: "OpenClaw").count - 1, 1)
    }

    /// A parked turn's sentence must not name the gateway — and dropping it from
    /// the sentence must not drop it from the LABEL, or a VoiceOver user loses
    /// the badge's information entirely.
    func testParkedPhasesDropTheGatewayFromTheSentenceButKeepTheBadge() {
        for phase in [ThinkingPhase.sending, .waitingForNetwork] {
            let label = workingLabel(phase: phase)
            XCTAssertFalse(label.contains("OpenClaw is answering"))
            XCTAssertTrue(label.contains("OpenClaw"))
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConverseCancelVerdictTests.swift
//
// The at-most-once proof, asserted without a socket. `ConverseCancelVerdict` is
// the ONLY thing in the app allowed to turn a user's Stop into a CLASSIFIED
// failure, and the whole safety argument is that it does so only when two
// independent counters agree that zero request-body bytes left the device.
//
// The direction that matters is asymmetric, and these cases are written around
// it: a missed classification is a blander failure message, while a wrongly
// granted one is a Try Again chip beside a turn the gateway already has — which
// spends the user's model budget twice and can make their agent act on the
// world twice. So every case above absolute zero must land on
// `.unknownDelivery`.

import XCTest
@testable import Conduck

final class ConverseCancelVerdictTests: XCTestCase {

    // MARK: - Proof withdrawn (the direction that must never be wrong)

    func testTheInProcessLatchAloneWithdrawsTheProof() {
        XCTAssertEqual(
            ConverseCancelVerdict.make(
                anyBytesDeparted: true,
                countOfBytesSent: 0,
                pathIsUnsatisfied: false
            ),
            .unknownDelivery
        )
    }

    /// The counter alone is enough: it covers out-of-process attempts this
    /// process never witnessed, which is exactly the case the in-process latch
    /// cannot see (a task resumed after a relaunch).
    func testTheTaskCounterAloneWithdrawsTheProof() {
        XCTAssertEqual(
            ConverseCancelVerdict.make(
                anyBytesDeparted: false,
                countOfBytesSent: 1,
                pathIsUnsatisfied: false
            ),
            .unknownDelivery
        )
    }

    /// A single byte is a whole request as far as this decision goes. There is
    /// no threshold below which departure is "not really" departure.
    func testOneByteIsEnoughToWithdrawTheProof() {
        XCTAssertEqual(
            ConverseCancelVerdict.make(
                anyBytesDeparted: false,
                countOfBytesSent: 1,
                pathIsUnsatisfied: true
            ),
            .unknownDelivery,
            "an offline reading must never override a departure the counters saw"
        )
    }

    /// A partially-sent body is the display latch's business, never this one's.
    /// It is not a proof of anything and must fall through.
    func testAPartiallySentBodyIsNotAProof() {
        XCTAssertEqual(
            ConverseCancelVerdict.make(
                anyBytesDeparted: true,
                countOfBytesSent: 4_096,
                pathIsUnsatisfied: true
            ),
            .unknownDelivery
        )
    }

    // MARK: - Proof held (zero, and only zero)

    func testNoRouteOutNamesTheOfflineCause() {
        XCTAssertEqual(
            ConverseCancelVerdict.make(
                anyBytesDeparted: false,
                countOfBytesSent: 0,
                pathIsUnsatisfied: true
            ),
            .provableNonDelivery(.noInternetConnection)
        )
    }

    /// A route existed and nothing left anyway. The client knows THAT and does
    /// not know WHY — a refused host, a captive portal that reads as connected,
    /// and a healthy gateway the transfer daemon has not started pushing to yet
    /// all land here — so the verdict names the stop and no machine.
    func testARouteThatSentNothingNamesOnlyTheStopItself() {
        XCTAssertEqual(
            ConverseCancelVerdict.make(
                anyBytesDeparted: false,
                countOfBytesSent: 0,
                pathIsUnsatisfied: false
            ),
            .provableNonDelivery(.turnStoppedBeforeSend)
        )
    }

    /// THE REMEDY MAY NEVER POINT AT THE WRONG MACHINE. A `.satisfied` reading
    /// proves nothing — Apple documents no guarantee behind it — so the arm it
    /// selects must not tell the user to go and check an address and a server
    /// that were very likely never involved. This is the case that fails if
    /// anyone re-points that arm at a gateway-connection error.
    func testTheSatisfiedPathArmNeverSendsTheUserToTheirServer() throws {
        guard case .provableNonDelivery(let cause) = ConverseCancelVerdict.make(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: false
        ) else { return XCTFail("zero departed bytes is a proof under either path reading") }

        for ref in [RemoteAgentRef.builtin(.openclaw), .builtin(.openrouter)] {
            let sentence = cause.descriptionWithRecovery(for: ref)
            XCTAssertFalse(
                sentence.localizedCaseInsensitiveContains("gateway"),
                "the satisfied-path Stop sends the user to their gateway: \(sentence)"
            )
            XCTAssertFalse(
                sentence.localizedCaseInsensitiveContains("address"),
                "the satisfied-path Stop tells the user to re-check an address "
                    + "that was very likely never the problem: \(sentence)"
            )
        }
        XCTAssertFalse(
            cause.isTroubleshootable,
            "a user's own Stop is not an environment Diagnostics can reason "
                + "about, and a troubleshootable code also files the row as "
                + "evidence against a gateway that was never contacted"
        )
        XCTAssertTrue(cause.isRetryable, "nothing was sent, so sending again is the whole remedy")
    }

    /// The path reading may only ADD the offline cause to an already-justified
    /// failure — it can neither create a proof nor withdraw one. Both zero-byte
    /// cases classify; they differ only in wording.
    func testThePathReadingOnlyChoosesTheWording() {
        let offline = ConverseCancelVerdict.make(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: true
        )
        let routed = ConverseCancelVerdict.make(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: false
        )
        XCTAssertNotEqual(offline, routed)
        for outcome in [offline, routed] {
            guard case .provableNonDelivery = outcome else {
                return XCTFail("zero departed bytes is a proof under either path reading")
            }
        }
    }

    /// The two codes the user actually reads. Pinned so a renumbering of
    /// `AppError` cannot silently swap which sentence a stopped turn gets:
    /// 3 is "No internet…", 76 is "You stopped this message before it was sent."
    func testTheClassifiedCodesAreTheOnesTheCopyLayerKeysOff() {
        guard case .provableNonDelivery(let offline) = ConverseCancelVerdict.make(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: true
        ) else { return XCTFail("expected a classification") }
        guard case .provableNonDelivery(let routed) = ConverseCancelVerdict.make(
            anyBytesDeparted: false, countOfBytesSent: 0, pathIsUnsatisfied: false
        ) else { return XCTFail("expected a classification") }
        XCTAssertEqual(offline.errorCode, 3)
        XCTAssertEqual(routed.errorCode, 76)
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS deferred-relay queue: retryable vs terminal.
//
// The queue's claim IS its destructor: `claimEntry` removes the entry, cancels
// the outstanding transfer and DELETES the queue-owned audio. So the single
// most consequential question a failed delivery attempt asks is whether the
// verdict is terminal — and the answer decides whether words the user already
// spoke into their wrist survive (I6).
//
// The defect these tests lock out: `drain()` and `reconcile()` recognised ONE
// leave-queued case (`.sttProviderUnreachable`) and claimed on everything else,
// so a retryable `.sttKeyUnreadable` — an iPhone Keychain that has not been
// unlocked since a reboot — destroyed the capture at the very next drain
// trigger, seconds after the wrist had promised the transcript would arrive.
// The question is now the taxonomy's own (`AppError.isRetryable`), asked
// through `AppleRelayPendingQueue.leavesEntryQueued(after:)`.
//
// Two halves, because either alone would pass over the defect: the predicate is
// exercised directly, and a source guard proves both call sites actually route
// through it rather than keeping a hand-rolled `if case` beside it.
import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchRelayQueueRetryabilityTests: XCTestCase {

    // MARK: - 1. The classification

    /// The regression itself. 75 is retryable precisely because the identical
    /// bytes succeed the moment the phone is unlocked, so the entry must live.
    func testABlackoutLeavesTheQueueEntryAlive() {
        XCTAssertTrue(
            AppleRelayPendingQueue.leavesEntryQueued(after: AppError.sttKeyUnreadable),
            "A Keychain blackout claimed the queue entry, which deletes the audio the user spoke on their wrist. Nothing about the capture is wrong — one unlock makes the same bytes transcribe (I6)."
        )
    }

    /// NEGATIVE CONTROL for the assertion above: a predicate that answered true
    /// unconditionally would satisfy it while destroying the queue's entire
    /// terminal path (an entry that never claims re-fires until it ages out, and
    /// the user is never told why).
    func testATerminalVerdictStillClaimsTheEntry() {
        let terminal: [AppError] = [
            // 23 — the slot is PROVABLY empty. Re-firing reaches the same
            // answer until the user adds a key on their iPhone.
            .sttMissingAPIKey,
            // The queue's own headline payload: a model the iPhone doesn't have.
            .appleSpeechModelNotInstalled,
            // Audio the provider cannot process — a second attempt cannot fix
            // the bytes.
            .audioProcessingFailed,
        ]
        for error in terminal {
            XCTAssertFalse(
                AppleRelayPendingQueue.leavesEntryQueued(after: error),
                "\(error) kept its queue entry. A verdict that returns the same answer on every re-fire must claim, notify, and let the user move on."
            )
        }
    }

    /// The classification may not drift into a hand-maintained list of cases:
    /// that is exactly the shape that missed 75. It has to BE `isRetryable`.
    func testTheClassificationIsTheTaxonomysOwn() {
        let cases: [AppError] = [
            .sttKeyUnreadable,
            // The one case the old shape did recognise — pinned so this fix
            // cannot regress the behaviour it started from.
            .sttProviderUnreachable,
            .sttServerError,
            .sttTooManyRequests,
            .sttMissingAPIKey,
            .sttAuthFailed,
            .appleSpeechModelNotInstalled,
            .appleSpeechLanguageUnsupported,
            .audioProcessingFailed,
            .audioInvalid,
            .noSpeechDetected,
            .sttDecodingFailure,
        ]
        for error in cases {
            XCTAssertEqual(
                AppleRelayPendingQueue.leavesEntryQueued(after: error), error.isRetryable,
                "\(error) is classified differently by the queue than by `AppError.isRetryable`. The queue is not entitled to its own opinion about which verdicts clear on their own — every other retry affordance in the app reads that property."
            )
        }
    }

    /// A throw the taxonomy has never seen is terminal: leaving it queued would
    /// re-fire a verdict nothing can reason about until the age cap.
    func testAnUnrecognisedThrowIsTerminal() {
        struct Boom: Error {}
        XCTAssertFalse(AppleRelayPendingQueue.leavesEntryQueued(after: Boom()))
    }

    // MARK: - 2. The notification sentence

    /// The shared 75 copy says "this device". This body renders on the WRIST —
    /// where that phrase reads as the watch the user just recorded on, which is
    /// unlocked — and mirrors to the paired iPhone's lock screen, where it is
    /// ambiguous a second way. The Keychain that blacked out on a relayed
    /// capture is always the iPhone's, so the body names it.
    func testTheBlackoutNotificationBodyNamesTheDevice() throws {
        let body = AppleRelayPendingQueue.notificationBody(
            for: .sttKeyUnreadable,
            fallback: "fallback copy"
        )
        XCTAssertTrue(
            body.contains("iPhone"),
            "The blackout notification body no longer names the iPhone. On the wrist and on a lock screen, an unnamed device is the wrong device."
        )
        XCTAssertFalse(
            body.lowercased().contains("this device"),
            "The blackout notification body says \"this device\" — the exact phrase this arm exists to keep off the wrist."
        )
    }

    /// NEGATIVE CONTROL. The assertions above pass vacuously the day the shared
    /// copy stops saying "this device" — at which point the arm they guard is
    /// answering a hazard that no longer exists, and this test should be the one
    /// that says so.
    func testTheSharedBlackoutCopyIsStillTheHazard() throws {
        let shared = try XCTUnwrap(AppError.sttKeyUnreadable.errorDescription)
        XCTAssertTrue(
            shared.lowercased().contains("this device"),
            "`AppError.sttKeyUnreadable`'s shared copy no longer says \"this device\", so the device-naming arm in `notificationBody` guards nothing. Re-point this file at whatever phrase is ambiguous now, or retire the arm."
        )
        let body = AppleRelayPendingQueue.notificationBody(
            for: .sttKeyUnreadable,
            fallback: "fallback copy"
        )
        XCTAssertNotEqual(
            body, shared,
            "The notification body fell back to the shared copy, so the arm is gone."
        )
    }

    // MARK: - 3. Source guard on the two call sites
    //
    // The predicate being right proves nothing about `drain()` and
    // `reconcile()`, which is where the defect actually lived — and neither has
    // a runtime seam a test can reach: both need `WCSession` activation, the
    // singleton's disk-touching `init` and a paired iPhone. So the call sites
    // are checked against the source, with the OLD shape as the negative
    // control: `case .sttProviderUnreachable` was the single-case match that
    // sent every other retryable verdict into the claim-and-delete branch.

    /// `.../Conduck/Conduck` — the Xcode project container.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckWatchTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Drops `//`-to-end-of-line on every line, so prose describing the rule can
    /// never satisfy a check on whether the code performs it.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    private func queueSource() throws -> String {
        let url = projectContainerURL()
            .appendingPathComponent("ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("Queue source unreadable at \(url.path) — this guard runs against a checkout only.")
        }
        return strippingComments(source)
    }

    func testBothDispatchPathsClassifyThroughThePredicate() throws {
        let code = try queueSource()
        XCTAssertEqual(
            code.components(separatedBy: "leavesEntryQueued(after:").count - 1, 2,
            "`drain()` and `reconcile()` must BOTH decide terminality through `leavesEntryQueued(after:)`. Exactly two call sites are expected; a third means a new path needs its own review, and fewer than two means one path is deciding on its own again."
        )
        XCTAssertFalse(
            code.contains("case .sttProviderUnreachable"),
            "A single-case `if case .sttProviderUnreachable` is back in the queue. That is the defect shape: it classifies exactly one retryable verdict as leave-queued and sends every other one — a Keychain blackout among them — into the branch that claims the entry and deletes the user's audio."
        )
    }
}

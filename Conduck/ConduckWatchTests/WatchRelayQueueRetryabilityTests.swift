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

    // MARK: - 1b. Destination: retention, and what a settled reply means
    //
    // A WORK entry is the only copy of a recording the person meant to keep,
    // and no gateway is waiting on it. Both halves of that sentence turn into
    // rules the queue has to hold, and neither can be observed through the
    // singleton (its `init` sweeps a real App Group container, `drain` needs an
    // activated `WCSession`, and the settled path needs a paired iPhone) — so
    // both are exercised through the pure surfaces the production paths route
    // into: `applyCaps`, `refusesNewWorkCapture` and `applySettledSuccess`.

    private func entry(
        _ destination: WatchCaptureDestination,
        ageSeconds: TimeInterval = 0,
        id: String = UUID().uuidString
    ) -> AppleRelayPendingQueue.Entry {
        AppleRelayPendingQueue.Entry(
            audioFilePath: "/dev/null/\(id).m4a",
            language: nil,
            enqueuedAt: Date().timeIntervalSince1970 - ageSeconds,
            providerID: nil,
            conversationID: nil,
            requestID: id,
            lastAttemptAt: nil,
            destination: destination == .chat ? nil : destination.rawValue
        )
    }

    /// The persisted shape, both directions. `destination` is additive Codable,
    /// so a blob written before Work existed has to decode as a chat entry —
    /// and a chat entry has to keep writing that same shape, or every queued
    /// capture on a watch that downgrades reads as something else.
    func testTheEntryRoundTripsItsDestinationAndALegacyBlobReadsAsChat() throws {
        let work = entry(.work)
        let chat = entry(.chat)

        let decoded = try JSONDecoder().decode(
            [AppleRelayPendingQueue.Entry].self,
            from: try JSONEncoder().encode([work, chat])
        )
        XCTAssertEqual(decoded, [work, chat])
        XCTAssertEqual(decoded[0].captureDestination, .work)
        XCTAssertEqual(decoded[1].captureDestination, .chat)

        // A chat entry writes NO destination key at all, so its serialized
        // shape is byte-identical to the pre-Work one.
        let chatBlob = try XCTUnwrap(String(data: try JSONEncoder().encode(chat), encoding: .utf8))
        XCTAssertFalse(
            chatBlob.contains("destination"),
            "A chat entry now serializes a destination key. The absent value IS the chat reading; writing it changes the on-disk shape for every capture that never needed it."
        )

        // The legacy blob itself: no key, and it must decode as chat rather
        // than fail or default to work.
        let legacy = Data("""
        [{"audioFilePath":"/tmp/legacy.m4a","enqueuedAt":1,"requestID":"legacy-id"}]
        """.utf8)
        let old = try JSONDecoder().decode([AppleRelayPendingQueue.Entry].self, from: legacy)
        XCTAssertEqual(old.count, 1)
        XCTAssertNil(old[0].destination)
        XCTAssertEqual(
            old[0].captureDestination, .chat,
            "A queue blob written before Work existed decoded as something other than chat. Every entry already on a wrist would change destination on update."
        )
    }

    /// The retention rule. An evicted entry has its audio DELETED, and for Work
    /// that audio is the only copy in existence — so neither cap may touch one.
    func testTheCapsNeverEvictAWorkEntryForAgeOrForRoom() {
        let now = Date().timeIntervalSince1970
        let day = AppleRelayPendingQueue.maxEntryAge

        // Age: a two-day-old pair. The chat ask has lost its conversation; the
        // work capture has lost nothing.
        let aged = AppleRelayPendingQueue.applyCaps(
            to: [entry(.chat, ageSeconds: day * 2), entry(.work, ageSeconds: day * 2)],
            now: now
        )
        XCTAssertEqual(aged.evicted.count, 1)
        XCTAssertEqual(aged.evicted.first?.captureDestination, .chat)
        XCTAssertEqual(
            aged.kept.map(\.captureDestination), [.work],
            "The age cap evicted a Work entry. That deletes the recording, and unlike a chat ask there is no transcript on a phone somewhere and no conversation it could have gone stale against."
        )

        // Room: a queue already full of Work entries, plus one fresh chat ask.
        // The overflow has to come out of Chat.
        let full = (0..<AppleRelayPendingQueue.maxEntryCount).map { entry(.work, ageSeconds: TimeInterval($0)) }
        let crowded = AppleRelayPendingQueue.applyCaps(to: full + [entry(.chat)], now: now)
        XCTAssertEqual(crowded.evicted.count, 1)
        XCTAssertEqual(
            crowded.evicted.first?.captureDestination, .chat,
            "Count eviction dropped a Work entry to make room. Work is exempt precisely so a burst of asks cannot cost the person a recording."
        )

        // And a queue that is ALL Work stays whole rather than being trimmed to
        // the cap — the pressure is answered at the entry point instead.
        let allWork = AppleRelayPendingQueue.applyCaps(to: full, now: now)
        XCTAssertTrue(allWork.evicted.isEmpty)
        XCTAssertEqual(allWork.kept.count, AppleRelayPendingQueue.maxEntryCount)
    }

    /// NEGATIVE CONTROL for the exemption above: a cap that never evicted
    /// anything would satisfy both assertions while destroying the chat lane's
    /// whole bound on queue growth.
    func testTheCapsStillEvictChatEntries() {
        let now = Date().timeIntervalSince1970
        let overflowing = (0...AppleRelayPendingQueue.maxEntryCount).map {
            entry(.chat, ageSeconds: TimeInterval($0))
        }
        let result = AppleRelayPendingQueue.applyCaps(to: overflowing, now: now)
        XCTAssertEqual(result.kept.count, AppleRelayPendingQueue.maxEntryCount)
        XCTAssertEqual(result.evicted.count, 1)
        XCTAssertEqual(
            result.evicted.first?.requestID, overflowing.first?.requestID,
            "Count eviction dropped something other than the OLDEST chat entry."
        )
        XCTAssertTrue(
            AppleRelayPendingQueue.applyCaps(
                to: [entry(.chat, ageSeconds: AppleRelayPendingQueue.maxEntryAge * 2)],
                now: now
            ).kept.isEmpty
        )
    }

    /// The other end of the exemption: because a full queue can no longer make
    /// room, a NEW Work capture is refused before the microphone arms. Refusing
    /// costs a sentence; accepting would cost audio.
    func testANewWorkCaptureIsRefusedAtCapacityRatherThanEvicting() {
        XCTAssertFalse(AppleRelayPendingQueue.refusesNewWorkCapture(queueDepth: 0))
        XCTAssertFalse(
            AppleRelayPendingQueue.refusesNewWorkCapture(
                queueDepth: AppleRelayPendingQueue.maxEntryCount - 1
            )
        )
        XCTAssertTrue(
            AppleRelayPendingQueue.refusesNewWorkCapture(
                queueDepth: AppleRelayPendingQueue.maxEntryCount
            ),
            "A Work capture was accepted onto a full queue. The queue cannot evict a Work entry to hold it, so the eleventh capture either breaks the cap or deletes one of the ten recordings already waiting."
        )
    }

    /// THE INVARIANT THIS WHOLE LANE EXISTS FOR: nothing on the desk reaches a
    /// gateway. The converse hop is the queue's only path to one, so a Work
    /// entry must never reach it — on either arm, stamped or not.
    func testAWorkReplyNeverReachesTheConverseHop() async {
        for workSaved in [true, false] {
            var hops = 0
            var claims = 0
            var writes = 0
            var finished: [AppleRelayPendingQueue.RelaySettlement] = []
            let result = await AppleRelayPendingQueue.applySettledSuccess(
                destination: .work,
                reply: RelayReply(text: "a private thought", workSaved: workSaved),
                claim: { claims += 1; return true },
                completeChat: { _ in hops += 1 },
                writeWorkWords: { _ in writes += 1; return true },
                finishWork: { finished.append($0) }
            )
            XCTAssertEqual(
                hops, 0,
                "A Work capture reached the converse hop (workSaved: \(workSaved)). That is the one path from this queue to a gateway, and a Work capture is a private thought the person deliberately kept off one."
            )
            XCTAssertEqual(claims, 1)
            XCTAssertEqual(finished, [workSaved ? .workAcknowledged : .workWordsOnly])
            XCTAssertEqual(result, .applied(workSaved ? .workAcknowledged : .workWordsOnly))
            XCTAssertEqual(writes, workSaved ? 0 : 1)
        }
    }

    /// NEGATIVE CONTROL: the same helper MUST still dispatch the hop for a chat
    /// ask, or the assertion above would pass on a settlement path that had
    /// simply stopped working.
    func testAChatReplyStillClaimsAndDispatchesTheHop() async {
        var hops: [String] = []
        var writes = 0
        var finished: [AppleRelayPendingQueue.RelaySettlement] = []
        let result = await AppleRelayPendingQueue.applySettledSuccess(
            destination: .chat,
            // A chat reply can carry the Work stamp only if the iPhone wrote it
            // onto the wrong lane; the destination decides, never the stamp.
            reply: RelayReply(text: "ask the agent", workSaved: true),
            claim: { true },
            completeChat: { hops.append($0) },
            writeWorkWords: { _ in writes += 1; return true },
            finishWork: { finished.append($0) }
        )
        XCTAssertEqual(hops, ["ask the agent"])
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(finished.isEmpty)
        XCTAssertEqual(result, .applied(.converseHop))
    }

    /// THE ORDERING THAT KEEPS THE WORDS: a claim DELETES the recording, and a
    /// reply with a transcript but no durability stamp means the iPhone kept
    /// nothing. So the desk write comes first, and a failed write claims
    /// nothing at all — the entry and the recording stay exactly where they
    /// were, for the next drain to try again.
    func testAWordsOnlyWorkReplyClaimsOnlyAfterTheNoteIsWritten() async {
        var order: [String] = []
        let failed = await AppleRelayPendingQueue.applySettledSuccess(
            destination: .work,
            reply: RelayReply(text: "the words", workSaved: false),
            claim: { order.append("claim"); return true },
            completeChat: { _ in order.append("hop") },
            writeWorkWords: { _ in order.append("write"); return false },
            finishWork: { _ in order.append("finish") }
        )
        XCTAssertEqual(
            order, ["write"],
            "A words-only Work reply whose desk write FAILED still claimed the entry. The claim deletes the recording, and the note that was supposed to replace it does not exist — the capture is simply gone."
        )
        XCTAssertEqual(failed, .workWordsUnwritten)

        order = []
        let succeeded = await AppleRelayPendingQueue.applySettledSuccess(
            destination: .work,
            reply: RelayReply(text: "the words", workSaved: false),
            claim: { order.append("claim"); return true },
            completeChat: { _ in order.append("hop") },
            writeWorkWords: { _ in order.append("write"); return true },
            finishWork: { _ in order.append("finish") }
        )
        XCTAssertEqual(
            order, ["write", "claim", "finish"],
            "The words-only path must write, THEN claim, THEN report — in that order."
        )
        XCTAssertEqual(succeeded, .applied(.workWordsOnly))
    }

    /// Exactly-once, unchanged for both lanes: a verdict a racing path already
    /// consumed does nothing here, and in particular writes no second card.
    func testASupersededVerdictSettlesNothingOnEitherLane() async {
        for destination in [WatchCaptureDestination.chat, .work] {
            var effects = 0
            let result = await AppleRelayPendingQueue.applySettledSuccess(
                destination: destination,
                reply: RelayReply(text: "already handled", workSaved: true),
                claim: { false },
                completeChat: { _ in effects += 1 },
                writeWorkWords: { _ in effects += 1; return true },
                finishWork: { _ in effects += 1 }
            )
            XCTAssertEqual(result, .superseded)
            XCTAssertEqual(effects, 0, "A superseded \(destination) verdict still ran an effect.")
        }
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

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
    /// simply stopped working. An ordinary chat reply carries no Work stamp —
    /// the iPhone writes one from a single line (`workSaved = parkedClip !=
    /// nil`) and only for a capture whose recording it holds.
    func testAChatReplyStillClaimsAndDispatchesTheHop() async {
        var hops: [String] = []
        var writes = 0
        var finished: [AppleRelayPendingQueue.RelaySettlement] = []
        let result = await AppleRelayPendingQueue.applySettledSuccess(
            destination: .chat,
            reply: RelayReply(text: "ask the agent", workSaved: false),
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

    /// The receipt is a SECOND witness to the destination, and the two
    /// disagreeing is not a tie the queue may break by sending. A reply
    /// carrying `work: true` is a reply about a capture the iPhone put on the
    /// desk; an entry whose destination says chat — because the field was
    /// dropped, or written with a value this build does not recognise, and
    /// `captureDestination` reads both as chat — is the other half of the
    /// disagreement. Dispatching would speak a private thought to an agent,
    /// which is the one outcome this lane exists to prevent, so nothing is
    /// claimed and nothing is sent.
    func testAWorkReceiptOnAChatStampedEntryIsRefusedRatherThanSent() async {
        var hops = 0
        var claims = 0
        var writes = 0
        var finished: [AppleRelayPendingQueue.RelaySettlement] = []
        let result = await AppleRelayPendingQueue.applySettledSuccess(
            destination: .chat,
            reply: RelayReply(text: "a private thought", workSaved: true),
            claim: { claims += 1; return true },
            completeChat: { _ in hops += 1 },
            writeWorkWords: { _ in writes += 1; return true },
            finishWork: { finished.append($0) }
        )
        XCTAssertEqual(
            hops, 0,
            "A reply that says the iPhone published this capture to the DESK still reached the converse hop."
        )
        XCTAssertEqual(
            claims, 0,
            "The entry was claimed on a verdict nobody could resolve — the claim deletes the recording."
        )
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(finished.isEmpty, "Nothing settled, so no line may be written for it.")
        XCTAssertEqual(result, .destinationContradicted)
        XCTAssertEqual(
            AppleRelayPendingQueue.settlement(for: .chat, workSaved: true),
            .receiptContradictsDestination
        )
        XCTAssertNil(
            WatchWorkCaptureOutcome.forSettlement(.receiptContradictsDestination),
            "Every sentence this type can produce would claim one half of the disagreement."
        )
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
                // The stamp AGREES with each lane in turn: a chat reply
                // carrying a Work receipt is refused before the claim is even
                // asked, which would measure the contradiction rather than the
                // exactly-once rule this case is about.
                reply: RelayReply(text: "already handled", workSaved: destination == .work),
                claim: { false },
                completeChat: { _ in effects += 1 },
                writeWorkWords: { _ in effects += 1; return true },
                finishWork: { _ in effects += 1 }
            )
            XCTAssertEqual(result, .superseded)
            XCTAssertEqual(effects, 0, "A superseded \(destination) verdict still ran an effect.")
        }
    }

    // MARK: - 1c. Destination-specific FAILURE retention
    //
    // The classification above answers "can the identical bytes still succeed?"
    // — the right question for a chat ask, whose audio is a means to a
    // transcript. It is the WRONG question for a Work capture, whose audio IS
    // the thing: until the iPhone answers `result.work == true`, or its words
    // reach the desk, the queue holds the only copy in existence. So a Work
    // entry is retained after ANY failed attempt, and "terminal" describes the
    // attempt rather than the capture. Two shipped realities make that concrete:
    // a current iPhone whose desk write fails deliberately replies a RETRYABLE
    // code so the wrist keeps the clip, and an iPhone predating Work has no Work
    // branch at all — it publishes nothing, deletes its own temp file, and can
    // answer a TERMINAL code that would otherwise take the last copy with it.

    /// An unacknowledged Work entry survives every verdict, on both sides of the
    /// retryable/terminal line — with the chat reading of the same errors as the
    /// control, so a predicate that simply started answering true would fail.
    func testAnUnacknowledgedWorkEntryIsRetainedAfterEveryFailedAttempt() {
        let verdicts: [AppError] = [
            // The phone's own phase-1 refusal: retryable BY CONSTRUCTION.
            .workDeskWriteFailed,
            // Retryable, and already covered for chat — pinned here so the Work
            // arm is not accidentally narrower.
            .sttKeyUnreadable,
            // TERMINAL, and the reason this rule exists: an iPhone that predates
            // Work answers exactly like this and kept nothing itself.
            .appleSpeechModelNotInstalled,
            .sttMissingAPIKey,
            .audioProcessingFailed,
        ]
        for error in verdicts {
            XCTAssertTrue(
                AppleRelayPendingQueue.leavesEntryQueued(after: error, destination: .work),
                "\(error) claimed an unacknowledged Work entry. The claim deletes the recording, and on this lane nothing else holds a copy — no attempt's verdict is worth the person's audio."
            )
            XCTAssertEqual(
                AppleRelayPendingQueue.leavesEntryQueued(after: error, destination: .chat),
                error.isRetryable,
                "The chat reading of \(error) changed. Chat's retention is the taxonomy's own and must be byte-identical to what it always was."
            )
        }
    }

    /// A throw the taxonomy has never seen still keeps a Work entry: an
    /// unrecognised failure is the LEAST reason to delete the only copy.
    func testAnUnrecognisedThrowStillKeepsAWorkEntry() {
        struct Boom: Error {}
        XCTAssertTrue(AppleRelayPendingQueue.leavesEntryQueued(after: Boom(), destination: .work))
        XCTAssertFalse(AppleRelayPendingQueue.leavesEntryQueued(after: Boom(), destination: .chat))
    }

    /// Retention and the DRAIN's halt are two different questions, and merging
    /// them wedges the queue: a Work entry retained on a terminal verdict never
    /// ages out (it is exempt from both caps), so a drain that stopped there
    /// would leave every entry behind it undelivered forever.
    func testOnlyAVerdictAboutThePhoneItselfHaltsTheDrain() {
        XCTAssertTrue(
            AppleRelayPendingQueue.sameBytesCanStillSucceed(after: AppError.sttKeyUnreadable),
            "A retryable verdict is the iPhone saying it cannot serve ANY relay right now; the entries behind this one would buy the identical answer."
        )
        XCTAssertFalse(
            AppleRelayPendingQueue.sameBytesCanStillSucceed(after: AppError.appleSpeechModelNotInstalled),
            "A terminal verdict is about this one clip. A Work entry retained on it must not stop the drain, or it wedges every entry behind it — permanently, since Work never ages out."
        )
        struct Boom: Error {}
        XCTAssertFalse(AppleRelayPendingQueue.sameBytesCanStillSucceed(after: Boom()))
    }

    // MARK: - 1d. The LIVE relay leg, driven end to end
    //
    // The predicate governs the queue's two deferred paths. The third path is
    // the live continuation in `WatchRecordingService.runRelay`, which is where
    // the defect actually bit: it recognised two deferral cases by name and
    // CLAIMED on everything else, so the iPhone's own "keep your clip, my desk
    // write failed" (retryable, code 78) deleted the recording it was asking the
    // wrist to hold. Driven through the `relayTranscribe` seam, against the real
    // queue, so the retention is observed rather than argued.

    private func makeRelayAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-retention-\(UUID().uuidString).m4a")
        try Data(repeating: 0xCD, count: 4096).write(to: url)
        return url
    }

    /// A Work capture the iPhone refused — on EITHER side of the taxonomy —
    /// keeps its entry, keeps its audio on disk, and says the deferral line.
    func testAFailedWorkRelayKeepsTheRecordingAndShowsTheDeferralLine() async throws {
        for verdict in [AppError.workDeskWriteFailed, .appleSpeechModelNotInstalled] {
            let service = WatchRecordingService()
            service.store = ConversationStore(inMemory: true)
            var relayed: String?
            service.relayTranscribe = { requestID, _, _, _, _ in
                relayed = requestID
                throw verdict
            }

            let baseline = AppleRelayPendingQueue.shared.entryCount
            let audioURL = try makeRelayAudio()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            await service.runRelay(
                audioFileURL: audioURL,
                originalFileURL: audioURL,
                providerID: nil,
                destination: .work
            )

            let requestID = try XCTUnwrap(relayed, "The relay seam was never reached.")
            defer { _ = AppleRelayPendingQueue.shared.claimEntry(requestID: requestID) }

            let entry = try XCTUnwrap(
                AppleRelayPendingQueue.shared.peekEntry(requestID: requestID),
                "\(verdict) claimed the Work entry on the live leg. The claim deletes the queued recording, and on this lane nothing else has a copy — the capture is simply gone (I6)."
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: entry.audioFilePath),
                "The queued Work recording was deleted after \(verdict)."
            )
            XCTAssertEqual(AppleRelayPendingQueue.shared.entryCount, baseline + 1)
            XCTAssertEqual(
                service.workCaptureOutcome, .deferredToPhone,
                "A retained Work capture must read as deferred, not as a failure: the recording is safe on this watch and the next delivery attempt carries it."
            )
            XCTAssertEqual(service.state, .idle, "Work parks nothing in the state machine.")
        }
    }

    /// The entry holding the pick is only half the guarantee: the queue has to
    /// HAND IT OVER. That half has no pure helper behind it — the defect is a
    /// dropped argument at one call site — so this drives the settlement with
    /// the dispatch substituted and reads what the queue actually passed.
    /// Deleting either binding from `completeEntry` fails here and nowhere else.
    ///
    /// The two shapes run separately because the entry itself keeps them
    /// exclusive: a pinned entry already names its conversation, and that
    /// conversation names its own gateway, so `enqueue` drops the ref for one.
    func testTheSettlementHandsTheDeferredHopWhicheverBindingTheEntryCarries() async throws {
        final class Handover: @unchecked Sendable {
            var calls = 0
            var transcript: String?
            var conversationID: UUID?
            var backendRef: String?
        }

        let pinned = UUID()
        let picked = RemoteAgentRef.custom(UUID()).rawString
        let shapes: [(name: String, pin: UUID?, ref: String?)] = [
            (name: "a pinned in-thread capture", pin: pinned, ref: nil),
            (name: "an Ask chooser pick", pin: nil, ref: picked)
        ]

        for shape in shapes {
            let handover = Handover()
            AppleRelayPendingQueue.deferredChatDispatch = { transcript, conversationID, backendRef in
                handover.calls += 1
                handover.transcript = transcript
                handover.conversationID = conversationID
                handover.backendRef = backendRef
            }
            defer {
                AppleRelayPendingQueue.deferredChatDispatch = AppleRelayPendingQueue.liveDeferredChatDispatch
            }

            let requestID = "handover-\(UUID().uuidString)"
            let audioURL = try makeRelayAudio()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            _ = AppleRelayPendingQueue.shared.enqueue(
                requestID: requestID,
                audioFileURL: audioURL,
                language: nil,
                conversationID: shape.pin,
                backendRef: shape.ref,
                destination: .chat
            )
            defer { _ = AppleRelayPendingQueue.shared.claimEntry(requestID: requestID) }

            await AppleRelayPendingQueue.shared.reconcile(
                requestID: requestID,
                outcome: .success(RelayReply(text: "the words", workSaved: false))
            )

            XCTAssertEqual(handover.calls, 1,
                           "\(shape.name): the settled chat entry never reached the deferred dispatch at all.")
            XCTAssertEqual(handover.transcript, "the words")
            XCTAssertEqual(
                handover.conversationID, shape.pin,
                "\(shape.name): the entry's pin was dropped on the way to the hop — the deferred ask lands in a NEW thread instead of the one it was spoken into."
            )
            XCTAssertEqual(
                handover.backendRef, shape.ref,
                "\(shape.name): the entry's gateway was dropped on the way to the hop — the words go to whichever gateway happens to be default when the phone comes back."
            )
        }
    }

    /// The gateway the person picked has to reach the ENTRY, because the
    /// settlement has nowhere else to read it: the Ask hint is one-shot and
    /// belongs to the live hop, and a `.new` draft has no conversation to pin.
    /// Work stamps none — it cleared the hint on the way in and reaches no
    /// gateway at all — which is also the control that the field is written by
    /// the lane rather than by whatever happens to be in the hint.
    func testADeferredChatEntryCarriesThePickedGatewayAndAWorkEntryCarriesNone() async throws {
        let picked = RemoteAgentRef.custom(UUID()).rawString
        defer { WatchSettingsReader.shared.clearPendingInAppNewConversationBackend() }

        for destination in [WatchCaptureDestination.chat, .work] {
            let service = WatchRecordingService()
            service.store = ConversationStore(inMemory: true)
            var relayed: String?
            service.relayTranscribe = { requestID, _, _, _, _ in
                relayed = requestID
                // Retryable on both lanes, so the entry is still there to read.
                throw AppError.sttProviderUnreachable
            }
            WatchSettingsReader.shared.setPendingInAppNewConversationBackend(picked)
            let audioURL = try makeRelayAudio()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            await service.runRelay(
                audioFileURL: audioURL,
                originalFileURL: audioURL,
                providerID: nil,
                destination: destination
            )

            let requestID = try XCTUnwrap(relayed, "The relay seam was never reached.")
            defer { _ = AppleRelayPendingQueue.shared.claimEntry(requestID: requestID) }
            let entry = try XCTUnwrap(AppleRelayPendingQueue.shared.peekEntry(requestID: requestID))
            XCTAssertEqual(
                entry.backendRef,
                destination == .chat ? picked : nil,
                "\(destination) wrote the wrong addressed gateway onto its entry."
            )
            if destination == .chat {
                // Peeked, never consumed — the LIVE hop still owns the one-shot
                // hint. (Work's own terminal clears it moments later, which is
                // why this is asked of the lane that keeps it.)
                XCTAssertEqual(
                    WatchSettingsReader.shared.peekPendingInAppNewConversationBackend(), picked,
                    "The enqueue consumed the hint the live hop still needs."
                )
            }
        }
    }

    /// The persisted half: `backendRef` is additive, so an entry without one
    /// must keep the exact shape it had before the field existed.
    func testAnEntryWithNoAddressedGatewayKeepsItsOldSerializedShape() throws {
        let plain = entry(.chat)
        let blob = try XCTUnwrap(String(data: try JSONEncoder().encode(plain), encoding: .utf8))
        XCTAssertFalse(
            blob.contains("backendRef"),
            "An entry that named no gateway now serializes a key for one. The absent value IS the answer."
        )

        let legacy = Data("""
        [{"audioFilePath":"/tmp/legacy.m4a","enqueuedAt":1,"requestID":"legacy-id"}]
        """.utf8)
        let old = try JSONDecoder().decode([AppleRelayPendingQueue.Entry].self, from: legacy)
        XCTAssertNil(old.first?.backendRef,
                     "A blob written before the field existed must decode as naming no gateway, not fail.")
    }

    /// NEGATIVE CONTROL, and the byte-identical half of the rule: a CHAT ask
    /// still claims on a terminal verdict. Without this the assertion above
    /// would pass on a `runRelay` that had simply stopped claiming anything.
    func testAFailedChatRelayStillClaimsItsEntry() async throws {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        var relayed: String?
        service.relayTranscribe = { requestID, _, _, _, _ in
            relayed = requestID
            throw AppError.appleSpeechModelNotInstalled
        }

        let baseline = AppleRelayPendingQueue.shared.entryCount
        let audioURL = try makeRelayAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        await service.runRelay(audioFileURL: audioURL, originalFileURL: audioURL, providerID: nil)

        let requestID = try XCTUnwrap(relayed)
        XCTAssertNil(
            AppleRelayPendingQueue.shared.peekEntry(requestID: requestID),
            "A terminal chat verdict must still claim — an entry that never claims re-fires until it ages out and the user is never told why."
        )
        XCTAssertEqual(AppleRelayPendingQueue.shared.entryCount, baseline)
        XCTAssertNil(service.workCaptureOutcome, "A chat failure must never write the Work lane's line.")
        guard case .error = service.state else {
            return XCTFail("Chat keeps its error state and its Retry affordance.")
        }
    }

    /// The wrist can hold several deferred Work captures at once, so the one
    /// that settles is routinely NOT the one on screen. The settlement carries
    /// the claim token and is applied only when it names the displayed capture;
    /// a sibling's acknowledgement still posts its banner (the queue does that
    /// before this call) but leaves the line alone.
    func testALateSettlementForAnotherCaptureLeavesTheDisplayedLineAlone() async throws {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        var relayed: String?
        service.relayTranscribe = { requestID, _, _, _, _ in
            relayed = requestID
            throw AppError.sttProviderUnreachable
        }

        let audioURL = try makeRelayAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        await service.runRelay(
            audioFileURL: audioURL,
            originalFileURL: audioURL,
            providerID: nil,
            destination: .work
        )
        let requestID = try XCTUnwrap(relayed)
        defer { _ = AppleRelayPendingQueue.shared.claimEntry(requestID: requestID) }

        XCTAssertEqual(service.workCaptureOutcome, .deferredToPhone)
        XCTAssertEqual(service.workRelayRequestID, requestID,
                       "The displayed capture must remember the token its settlement will arrive under.")

        service.noteWorkCaptureSettled(.workAcknowledged, requestID: UUID().uuidString)
        XCTAssertEqual(
            service.workCaptureOutcome, .deferredToPhone,
            "A sibling capture's acknowledgement repainted this screen as saved, over a recording still sitting on the wrist. That is the one lie this surface must never tell."
        )
        service.noteWorkCaptureSettled(.workWordsOnly, requestID: nil)
        XCTAssertEqual(service.workCaptureOutcome, .deferredToPhone,
                       "A settlement with no token names nothing and may claim no screen.")

        service.noteWorkCaptureSettled(.workAcknowledged, requestID: requestID)
        XCTAssertEqual(
            service.workCaptureOutcome, .saved,
            "The displayed capture's OWN settlement must still land, or the deferral line outlives the delivery it promised."
        )
    }

    // MARK: - 1e. A stamped reply with no words
    //
    // The iPhone parks the recording BEFORE it transcribes, so a transcription
    // that fails settles against a clip the phone already holds and leaves no
    // words anywhere. That reply is success-shaped with an EMPTY transcript,
    // and it has to settle the wrist: the phone holds the durable copy, so a
    // retained entry is a clip nothing will ever claim — and Work entries never
    // age out, so "never" is literal.

    func testAStampedReplyWithNoWordsStillSettlesTheEntry() async {
        for transcript in ["", "   ", "\n"] {
            var hops = 0
            var claims = 0
            var writes = 0
            var finished: [AppleRelayPendingQueue.RelaySettlement] = []
            let result = await AppleRelayPendingQueue.applySettledSuccess(
                destination: .work,
                reply: RelayReply(text: transcript, workSaved: true),
                claim: { claims += 1; return true },
                completeChat: { _ in hops += 1 },
                writeWorkWords: { _ in writes += 1; return true },
                finishWork: { finished.append($0) }
            )
            XCTAssertEqual(
                claims, 1,
                "A stamped reply with no words left the entry queued. The iPhone holds the recording, so this clip is one the wrist can never settle — and a Work entry never ages out."
            )
            XCTAssertEqual(hops, 0, "Nothing on the Work lane may reach the converse hop.")
            XCTAssertEqual(
                writes, 0,
                "There are no words to write. The words-only lane is for an OLD iPhone that kept no recording; this one kept it."
            )
            XCTAssertEqual(finished, [.workRecordingOnly])
            XCTAssertEqual(result, .applied(.workRecordingOnly))
        }
    }

    /// NEGATIVE CONTROL: words plus the stamp is still the clean save, or the
    /// assertion above would pass on a lane that had stopped telling the two
    /// apart in the other direction.
    func testAStampedReplyWithWordsIsStillACleanSave() async {
        var finished: [AppleRelayPendingQueue.RelaySettlement] = []
        let result = await AppleRelayPendingQueue.applySettledSuccess(
            destination: .work,
            reply: RelayReply(text: "remember the oat milk", workSaved: true),
            claim: { true },
            completeChat: { _ in XCTFail("a Work capture reached the converse hop") },
            writeWorkWords: { _ in XCTFail("a stamped reply needs no words written"); return true },
            finishWork: { finished.append($0) }
        )
        XCTAssertEqual(finished, [.workAcknowledged])
        XCTAssertEqual(result, .applied(.workAcknowledged))
    }

    /// The classification itself, in both dimensions. An UNSTAMPED reply is the
    /// old-iPhone lane whatever its transcript looks like — the words are the
    /// only thing that can be rescued there — so emptiness must not divert it.
    func testTheWordlessAnswerIsScopedToAStampedWorkReply() {
        XCTAssertEqual(
            AppleRelayPendingQueue.settlement(for: .work, workSaved: true, hasWords: false),
            .workRecordingOnly
        )
        XCTAssertEqual(
            AppleRelayPendingQueue.settlement(for: .work, workSaved: true, hasWords: true),
            .workAcknowledged
        )
        XCTAssertEqual(
            AppleRelayPendingQueue.settlement(for: .work, workSaved: false, hasWords: false),
            .workWordsOnly,
            "An unstamped reply kept no recording; its entry is settled by the WRITE, not by a stamp it never carried."
        )
        XCTAssertEqual(
            AppleRelayPendingQueue.settlement(for: .chat, workSaved: false, hasWords: false),
            .converseHop,
            "The destination decides. A chat ask with an empty transcript is still a chat ask."
        )
        XCTAssertFalse(AppleRelayPendingQueue.carriesWords(" \t\n"))
        XCTAssertTrue(AppleRelayPendingQueue.carriesWords("oat milk"))
    }

    /// The LIVE leg, driven end to end against the real queue: the iPhone kept
    /// the recording, so the wrist releases its clip — and says which half of
    /// the card is missing rather than reporting a clean save.
    func testAStampedEmptyReplyReleasesTheWristsClipAndNamesTheGap() async throws {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        var relayed: String?
        service.relayTranscribe = { requestID, _, _, _, _ in
            relayed = requestID
            return RelayReply(text: "", workSaved: true)
        }

        let baseline = AppleRelayPendingQueue.shared.entryCount
        let audioURL = try makeRelayAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        await service.runRelay(
            audioFileURL: audioURL,
            originalFileURL: audioURL,
            providerID: nil,
            destination: .work
        )

        let requestID = try XCTUnwrap(relayed, "The relay seam was never reached.")
        XCTAssertNil(
            AppleRelayPendingQueue.shared.peekEntry(requestID: requestID),
            "The wrist kept a clip whose recording is already on the desk. Nothing will ever settle it: the phone answers every re-fire of this requestID from its verdict cache, and Work entries never age out."
        )
        XCTAssertEqual(AppleRelayPendingQueue.shared.entryCount, baseline)
        XCTAssertEqual(
            service.workCaptureOutcome, .savedWithoutWords,
            "The card is on the desk with no words on it. Reporting the clean save hides the one thing the person has to do next; reporting a failure hides the card."
        )
        XCTAssertEqual(service.state, .idle, "Work parks nothing in the state machine.")
    }

    /// The DEFERRED half of the same settlement: the capture screen is still up
    /// minutes later, and the line it flips to is the one that names the gap.
    func testADeferredSettlementWithNoWordsRepaintsTheLineItNames() async throws {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        var relayed: String?
        service.relayTranscribe = { requestID, _, _, _, _ in
            relayed = requestID
            throw AppError.sttProviderUnreachable
        }

        let audioURL = try makeRelayAudio()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        await service.runRelay(
            audioFileURL: audioURL,
            originalFileURL: audioURL,
            providerID: nil,
            destination: .work
        )
        let requestID = try XCTUnwrap(relayed)
        defer { _ = AppleRelayPendingQueue.shared.claimEntry(requestID: requestID) }
        XCTAssertEqual(service.workCaptureOutcome, .deferredToPhone)

        service.noteWorkCaptureSettled(.workRecordingOnly, requestID: UUID().uuidString)
        XCTAssertEqual(
            service.workCaptureOutcome, .deferredToPhone,
            "A sibling's settlement may not repaint this screen, whatever shape it takes."
        )

        service.noteWorkCaptureSettled(.workRecordingOnly, requestID: requestID)
        XCTAssertEqual(
            service.workCaptureOutcome, .savedWithoutWords,
            "The displayed capture's own settlement must land, or the deferral line outlives the delivery it promised."
        )
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

    /// …and both of them ASK ABOUT THE DESTINATION. The predicate answering
    /// correctly proves nothing if a dispatch path calls it with the default
    /// chat reading: the entry's persisted destination is the whole rule, and
    /// this is a lane where a wrong answer deletes the only copy of a recording.
    func testBothDispatchPathsAskAboutTheEntrysDestination() throws {
        let code = try queueSource()
        XCTAssertEqual(
            code.components(separatedBy: "leavesEntryQueued(after: error, destination:").count - 1, 2,
            "`drain()` and `reconcile()` must both pass the ENTRY's destination. A bare `leavesEntryQueued(after:)` takes the chat reading by default, which claims an unacknowledged Work entry — and the claim deletes the recording."
        )
        XCTAssertTrue(
            code.contains("destination: entry.captureDestination"),
            "`drain()` reads the destination off the entry it is re-firing. A live reading would be wrong twice over: this drain may run in a process that never saw the capture."
        )
        XCTAssertTrue(
            code.contains("let destination = peekEntry(requestID: requestID)?.captureDestination ?? .chat"),
            "`reconcile()` must PEEK the entry before deciding. Claiming is the only other way to see an entry, and by then the recording is already deleted."
        )
    }

    /// The drain's halt is a separate question from retention, asked through its
    /// own predicate. Merging the two wedges the queue: a Work entry retained on
    /// a terminal verdict never ages out, so a drain that stopped on it would
    /// leave every entry behind it undelivered forever.
    func testTheDrainStopsOnlyOnAVerdictAboutThePhoneItself() throws {
        let code = try queueSource()
        XCTAssertTrue(
            code.contains("guard Self.sameBytesCanStillSucceed(after: error) else { continue }"),
            "`drain()` no longer separates 'this entry is retained' from 'stop the whole drain'. A retained Work entry that halts the loop blocks every queued ask behind it, permanently."
        )
    }
}

// MARK: - The wrist's Work outcome belongs to ONE capture
//
// `workCaptureOutcome` is a single value on a process-wide service, and the
// queue can hold several deferred Work captures at once (they are exempt from
// both caps). So the capture that settles is routinely not the capture on
// screen, and both halves of the correlation have to hold: the service refuses a
// settlement that names another token (exercised directly in
// `WatchRelayQueueRetryabilityTests`), and the screen refuses a line stamped
// with another capture's nonce — which has no runtime seam, because it is a
// SwiftUI body, so it is read off the source.
@MainActor
final class WatchWorkOutcomeOwnershipTests: XCTestCase {

    private func captureViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckWatchTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
            .appendingPathComponent("ConduckWatch Watch App/Views/WatchWorkCaptureView.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("Capture-view source unreadable at \(url.path) — this guard runs against a checkout only.")
        }
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    func testTheCaptureScreenRendersOnlyItsOwnOutcome() throws {
        let code = try captureViewSource()
        XCTAssertTrue(
            code.contains("guard recordingService.workCaptureID == requestID else { return nil }"),
            "The capture screen reads the service's outcome unscoped again. Two deferred Work captures then share one line, and the sibling that settles first repaints the other's screen as saved."
        )
        XCTAssertEqual(
            code.components(separatedBy: "recordingService.workCaptureOutcome").count - 1, 2,
            "Exactly two reads of the raw outcome are expected: the scoped accessor, and the `onChange` trigger that observes it. A third is a surface reading past the ownership stamp."
        )
    }

    /// The service half, stated as the rule rather than as one scenario: a
    /// settlement applies only when its token names the capture on screen, and
    /// an absent token names nothing.
    func testASettlementAppliesOnlyToTheCaptureItNames() {
        let service = WatchRecordingService()
        XCTAssertNil(service.workRelayRequestID,
                     "A fresh service is showing no Work capture, so no settlement can claim its screen.")
        service.noteWorkCaptureSettled(.workAcknowledged, requestID: UUID().uuidString)
        XCTAssertNil(
            service.workCaptureOutcome,
            "A settlement landed on a wrist that is showing no Work capture at all. The banner is what the person reads then; the screen has nothing to correct."
        )
    }
}

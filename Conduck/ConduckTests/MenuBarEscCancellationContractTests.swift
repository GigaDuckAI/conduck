// SPDX-License-Identifier: Apache-2.0

// Conduck
// MenuBarEscCancellationContractTests.swift
//
// SOURCE DRIFT GUARD over the promise the capture guide makes about Esc:
// "Press Esc to cancel", taught as step 3 under ⌘⇧1 and ⌘⇧2.
//
// Esc reaches `MenuBarCoordinator.cancelActiveCapture` →
// `DictationService.cancelRecording` in every state — but a stop has already
// moved the service to `.processing`, and a cancel that does nothing there lets
// the finished transcript walk into `onTranscript`, which SENDS. The words then
// reach a gateway after the person cancelled, and the paid turn arrives as an
// unread reply for a question they withdrew.
//
// The provider hop cannot be recalled (a foreground `URLSession` this service
// does not retain), so the cancellation is of the RESULT: a generation the run
// carries, moved by the cancel, checked before every terminal write.
//
// `DictationService` is `#if os(macOS)` and is not compiled by this suite, so
// the rules are asserted where they are written, over comment-stripped source —
// a header that DESCRIBES the contract can never stand in for the code that
// keeps it.

import XCTest

final class MenuBarEscCancellationContractTests: XCTestCase {

    private static let servicePath = "Conduck/MenuBar/DictationService.swift"
    private static let guidePath = "Conduck/Views/Settings/MenuBarGuideView.swift"

    /// The cancel has an answer for `.processing`, and its answer moves the
    /// generation. Without the bump every guard downstream is decorative: the
    /// run's token still matches, so it hands its words over exactly as if
    /// nothing had been pressed.
    func testTheCancelInvalidatesAnInFlightTranscription() throws {
        let body = try Self.serviceFunction("cancelRecording")

        XCTAssertTrue(
            body.contains(Self.squeezed("case .processing:")),
            "`cancelRecording` no longer answers for `.processing`, so Esc during transcription is a "
            + "no-op and the words are sent after the cancel: \(body.prefix(400))"
        )
        let processing = try XCTUnwrap(
            body.range(of: Self.squeezed("case .processing:")),
            "The `.processing` arm is gone; this guard's anchor needs updating."
        )
        let error = try XCTUnwrap(
            body.range(of: Self.squeezed("case .error:")),
            "The `.error` arm is gone; this guard's anchor needs updating."
        )
        let bump = try XCTUnwrap(
            body.range(of: Self.squeezed("transcriptionGeneration &+= 1")),
            "The `.processing` arm no longer moves the generation, so the run in flight still matches "
            + "the token every terminal write checks: \(body.prefix(400))"
        )
        // `squeezed` removes ALL whitespace, so the arm label and the statement
        // under it are adjacent: the label's last index and the bump's first are
        // the same. `LessThanOrEqual` is the strictest form that can hold, and
        // it still refuses a bump in either neighbouring arm.
        XCTAssertTrue(
            processing.upperBound <= bump.lowerBound && bump.upperBound <= error.lowerBound,
            "The generation moves outside the `.processing` arm — a bump on an error dismissal "
            + "cancels nothing, and one on a recording stop would cancel the capture the person just "
            + "finished: \(body.prefix(400))"
        )

        // NEGATIVE CONTROL: the shape this replaced — `.recording` and `.error`
        // handled, everything else swallowed by `default` — must fail both.
        let noOp = Self.squeezed("""
        switch state {
        case .recording:
            recorder.cancelRecording()
            stopDisplayTimer()
            state = .idle
            lastError = nil
        case .error:
            state = .idle
            lastError = nil
        default:
            break
        }
        """)
        XCTAssertFalse(
            noOp.contains(Self.squeezed("case .processing:")),
            "Control: a cancel that falls into `default` during transcription must FAIL this guard."
        )
        XCTAssertFalse(
            noOp.contains(Self.squeezed("transcriptionGeneration &+= 1")),
            "Control: …and it moves no generation, which is why the send went out anyway."
        )
    }

    /// The hand-off is where a cancelled run does its damage, so the token is
    /// checked BEFORE it — not after, and not only on the failure arms.
    /// `onTranscript` is a send: once the words are handed over the turn exists,
    /// and no later check can take it back.
    func testTheTranscriptIsNotHandedOverAfterACancel() throws {
        let body = try Self.serviceFunction("processTranscription")

        let guarded = try XCTUnwrap(
            body.range(of: Self.squeezed("guard stillCurrent(generation) else { return }")),
            "The transcription no longer asks whether it is still the run the person is waiting for: "
            + "\(body.prefix(600))"
        )
        let handOff = try XCTUnwrap(
            body.range(of: Self.squeezed("onTranscript(trimmed)")),
            "The transcript hand-off is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            guarded.upperBound, handOff.lowerBound,
            "The staleness check sits BELOW the hand-off, which is the whole defect — the words are "
            + "already on their way to a gateway by then: \(body.prefix(600))"
        )
        // …and ABOVE it is not enough on its own. The suspension the check
        // exists for is the provider round trip, so a check hoisted to just
        // BEFORE `transcribe` still reads a token nothing has had the chance to
        // move — it passes every ordering assertion above and sends the
        // cancelled words anyway. Pin it between the answer and the hand-off.
        let provider = try XCTUnwrap(
            body.range(of: Self.squeezed("STTClient.shared.transcribe(")),
            "The provider hop is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            provider.upperBound, guarded.lowerBound,
            "The success-path staleness check runs BEFORE the provider suspension it guards, so an "
            + "Esc pressed while the provider is working is never seen: \(body.prefix(600))"
        )
        // …and the failure arms answer it too, or a cancelled capture comes back
        // as an error banner over a dismissed popover and a Retry card for words
        // the person threw away.
        XCTAssertGreaterThanOrEqual(
            body.components(separatedBy: Self.squeezed("guard stillCurrent(generation) else { return }")).count - 1,
            3,
            "A cancelled run still writes on at least one arm — success, `AppError`, and the generic "
            + "catch each own one check: \(body.prefix(600))"
        )
        XCTAssertTrue(
            body.contains(Self.squeezed("guard stillCurrent(generation) else { return } await preserveForRetry(")),
            "The preservation is no longer gated, so a cancelled capture reappears as a Retry the "
            + "person never parked: \(body.prefix(600))"
        )

        // NEGATIVE CONTROL: an ungated hand-off must fail the ordering above.
        let ungated = Self.squeezed("""
        let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .idle
        onTranscript(trimmed)
        """)
        XCTAssertNil(
            ungated.range(of: Self.squeezed("guard stillCurrent(generation) else { return }")),
            "Control: a hand-off with no staleness check must FAIL this guard."
        )
    }

    /// The run carries the token it was born with. Reading the property at the
    /// terminal step instead would compare the generation with itself and answer
    /// "still current" after every cancel.
    func testTheRunCarriesTheTokenItStartedWith() throws {
        let stop = try Self.serviceFunction("stopAndProcess")

        let taken = try XCTUnwrap(
            stop.range(of: Self.squeezed("let generation = transcriptionGeneration")),
            "The stop no longer takes the run's identity, so nothing downstream can tell a cancelled "
            + "run from the current one: \(stop.prefix(400))"
        )
        let dispatched = try XCTUnwrap(
            stop.range(of: Self.squeezed("await processAudio(audioData: audioData, startTime: startTime, generation: generation)")),
            "The pipeline is no longer handed the token: \(stop.prefix(400))"
        )
        XCTAssertLessThan(
            taken.upperBound, dispatched.lowerBound,
            "The token is read after the run it identifies has already started: \(stop.prefix(400))"
        )
        // …and "before the call" is not "before the TASK". Moved inside the
        // `Task`, the read still precedes `processAudio` and satisfies the
        // ordering above — while a cancel landing between the press and the
        // task's first resumption has ALREADY moved the generation, so the run
        // adopts the new token as its own and sends the audio that press
        // withdrew. The origin is what has to be pinned, not the argument.
        let stopTask = try XCTUnwrap(
            stop.range(of: Self.squeezed("Task {")),
            "The pipeline's task is gone; this guard's anchor needs updating."
        )
        // Adjacent after squeezing, so `LessThanOrEqual` is the strictest form
        // that can hold; a read moved inside the task still fails it.
        XCTAssertLessThanOrEqual(
            taken.upperBound, stopTask.lowerBound,
            "The run's identity is read INSIDE the task it identifies, so a cancel that lands "
            + "before the task starts is invisible to it: \(stop.prefix(400))"
        )

        // The stop also ENDS the start. `.recording` is declared before the
        // primitive's permission hop completes, so a second press lands here
        // while the microphone is still coming up: the recorder holds nothing,
        // the error below is written, and the resumed startup then opened a
        // microphone that sat live behind a surface whose only key clears the
        // banner.
        let endsTheStart = try XCTUnwrap(
            stop.range(of: Self.squeezed("recordingStartToken &+= 1")),
            "The stop no longer invalidates a start still in flight: \(stop.prefix(400))"
        )
        let noAudio = try XCTUnwrap(
            stop.range(of: Self.squeezed("guard let audioData = recorder.stopRecording() else {")),
            "The stop's no-audio arm is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThanOrEqual(
            endsTheStart.upperBound, noAudio.lowerBound,
            "The start is invalidated below the arm that answers nil, so a stop pressed during the "
            + "permission prompt still lets the microphone come up: \(stop.prefix(400))"
        )

        // And the pipeline's own hop passes it on rather than re-reading it.
        let audio = try Self.serviceFunction("processAudio")
        XCTAssertTrue(
            audio.contains(Self.squeezed("generation: generation")),
            "`processAudio` no longer forwards the token to the transcription it starts: "
            + "\(audio.prefix(600))"
        )
        XCTAssertFalse(
            audio.contains(Self.squeezed("let generation = transcriptionGeneration")),
            "`processAudio` re-reads the generation instead of carrying the one it was given, which "
            + "makes every check below it compare the property with itself: \(audio.prefix(600))"
        )
    }

    /// The check has to compare the run's token with the SERVICE's generation.
    ///
    /// Every guard in this file is an assertion about a call to `stillCurrent`,
    /// and a call proves nothing about what the callee compares: rewritten as
    /// `token == token` the helper answers "still current" after every cancel
    /// while leaving all of them green. So the body is pinned whole — it is one
    /// expression, and there is exactly one right form of it.
    func testTheStalenessCheckComparesTheTokenWithTheServicesGeneration() throws {
        let body = try Self.serviceFunction("stillCurrent")

        // Minus the function's own closing brace: `RefusalLaneSource.body`
        // returns through it.
        XCTAssertEqual(
            String(body.dropLast()), Self.squeezed("token == transcriptionGeneration"),
            "`stillCurrent` no longer compares the run's token with the service's generation, which "
            + "makes every guard downstream decorative: \(body)"
        )

        // NEGATIVE CONTROL: the self-comparison — the mutation that satisfies
        // every call-site assertion in this suite.
        XCTAssertNotEqual(
            Self.squeezed("token == token"), Self.squeezed("token == transcriptionGeneration"),
            "Control: `token == token` is always true, so a cancelled run passes every check and "
            + "hands its words over exactly as if nothing had been pressed."
        )
    }

    /// The PRESERVATION suspends, so the cancel can land inside it — and both
    /// halves of that have to be answered.
    ///
    /// A run that parked its bytes and came back to write `.error`
    /// unconditionally lands that banner on whatever the person started next:
    /// the new microphone disappears behind it, its stop has nothing to stop,
    /// and the recording that was thrown away is the one Retry offers back. And
    /// the entry the cancelled run wrote is its own to retire — by id, so a
    /// capture another surface has since taken over is left alone.
    func testACancelDuringThePreservationWritesNothingAndParksNothing() throws {
        let transcription = try Self.serviceFunction("processTranscription")

        XCTAssertTrue(
            transcription.contains(Self.squeezed("""
            await preserveForRetry(
                error: error,
                audioData: audioData,
                preferredLanguage: preferredLanguage,
                generation: generation
            )
            guard stillCurrent(generation) else { return }
            lastError = error
            """)),
            "The failure arm writes its banner straight out of the preservation, with no second "
            + "reading of the token the suspension invalidated: \(transcription.prefix(800))"
        )

        let audio = try Self.serviceFunction("processAudio")
        XCTAssertTrue(
            audio.contains(Self.squeezed("""
            await preserveForRetry(
                error: .sttKeyUnreadable,
                audioData: audioData,
                preferredLanguage: preferredLanguage,
                generation: generation
            )
            guard stillCurrent(generation) else { return }
            lastError = .sttKeyUnreadable
            """)),
            "The locked-keychain arm has the same hole: \(audio.prefix(800))"
        )

        // …and the preservation itself carries the identity, so a save that
        // landed after the cancel is retired rather than left as a Retry
        // nobody parked.
        let preserve = try Self.serviceFunction("preserveForRetry")
        XCTAssertTrue(
            preserve.contains(Self.squeezed("""
            if !stillCurrent(generation) {
                if let claim = await PendingRetryStore.shared.claim(id: captureID) {
                    _ = await PendingRetryStore.shared.clear(claim)
                }
            }
            """)),
            "A capture cancelled while its bytes were being written stays in the queue, so the "
            + "words the person threw away come back as a Retry: \(preserve.prefix(800))"
        )
        XCTAssertTrue(
            preserve.contains(Self.squeezed("claim(id: captureID)")),
            "The retirement addresses something other than the id this call just wrote — every "
            + "other address is somebody else's recording: \(preserve.prefix(800))"
        )

        // NEGATIVE CONTROL: the shape this replaced — one guard above the
        // preservation and an unconditional write below it.
        let unguarded = Self.squeezed("""
        guard stillCurrent(generation) else { return }
        await preserveForRetry(
            error: error,
            audioData: audioData,
            preferredLanguage: preferredLanguage
        )
        lastError = error
        """)
        XCTAssertTrue(
            unguarded.contains(Self.squeezed("guard stillCurrent(generation) else { return }")),
            "Control: the old shape still names the check, which is why presence was never the test."
        )
        XCTAssertFalse(
            unguarded.contains(Self.squeezed("generation: generation")),
            "Control: …and it never hands the identity to the preservation, so nothing inside it "
            + "can tell a cancelled run from the current one."
        )
    }

    /// A RETRY is a run like any other, and Esc reaches `.processing` whichever
    /// way the words are being bought.
    ///
    /// Without the token the promise is true of a stop and false of a Retry: the
    /// cancelled run comes back, retires the entry and hands its words to a
    /// gateway. `false` is the right answer for a cancelled attempt — nothing
    /// was finished, so `retryLast` hands the reservation back and the capture
    /// stays queued for the next tap.
    func testARetryCarriesTheSameCancellationIdentity() throws {
        let retry = try Self.serviceFunction("retryLast")

        let taken = try XCTUnwrap(
            retry.range(of: Self.squeezed("let generation = transcriptionGeneration")),
            "The Retry no longer takes a cancellation identity: \(retry.prefix(500))"
        )
        let dispatched = try XCTUnwrap(
            retry.range(of: Self.squeezed("await attemptRetry(claim, generation: generation)")),
            "The attempt is no longer handed the token: \(retry.prefix(500))"
        )
        XCTAssertLessThan(
            taken.upperBound, dispatched.lowerBound,
            "The token is read after the run it identifies has started: \(retry.prefix(500))"
        )

        let attempt = try Self.serviceFunction("attemptRetry")
        let refusal = Self.squeezed("guard stillCurrent(generation) else { return false }")
        XCTAssertGreaterThanOrEqual(
            attempt.components(separatedBy: refusal).count - 1, 4,
            "The attempt suspends on the settings hop, the key verdict, the provider round trip and "
            + "each failure arm; every one of them needs its own reading: \(attempt.prefix(900))"
        )

        // The one that matters most: the check stands between the provider's
        // answer and everything terminal — the retirement of the entry and the
        // hand-off that sends.
        let provider = try XCTUnwrap(
            attempt.range(of: Self.squeezed("PendingRetryLeaseRenewal.whileRenewing(claim)")),
            "The provider hop is gone; this guard's anchor needs updating."
        )
        let afterProvider = attempt[provider.upperBound...]
        let guarded = try XCTUnwrap(
            afterProvider.range(of: refusal),
            "Nothing asks whether the Retry is still wanted once the provider answers: "
            + "\(attempt.prefix(900))"
        )
        for terminal in [
            "settleAfterFinishing(claim, generation: generation)",
            "(onRecoveredTranscript ?? onTranscript)(trimmed)"
        ] {
            let step = try XCTUnwrap(
                afterProvider.range(of: Self.squeezed(terminal)),
                "`\(terminal)` is gone; this guard's anchor needs updating."
            )
            XCTAssertLessThan(
                guarded.upperBound, step.lowerBound,
                "`\(terminal)` runs before the staleness check, which is the whole defect — the "
                + "entry is retired and the words are sent after the Esc: \(attempt.prefix(900))"
            )
        }

        // NEGATIVE CONTROL: the un-tokened attempt this replaced.
        let untokened = Self.squeezed("""
        if await attemptRetry(claim) == false {
            await PendingRetryStore.shared.release(claim)
        }
        """)
        XCTAssertFalse(
            untokened.contains(Self.squeezed("attemptRetry(claim, generation: generation)")),
            "Control: an attempt with no identity must FAIL this guard — there is nothing inside it "
            + "that can tell a cancelled Retry from a live one."
        )
    }

    /// The SETTLEMENT suspends, and a cancel can land inside it.
    ///
    /// `settleAfterFinishing` clears the queue entry and refreshes the count —
    /// two actor hops — and then writes `.idle` or a backlog banner. A run whose
    /// Esc arrived during those hops used to paint that state over a recording
    /// the person had already started, and then hand its words to a gateway with
    /// no second reading of the token at all.
    func testTheSettlementCannotWriteASurfaceAfterACancel() throws {
        let settle = try Self.serviceFunction("settleAfterFinishing")
        let source = try Self.squeezedSource(at: Self.servicePath)

        XCTAssertTrue(
            source.contains(Self.squeezed("""
            private func settleAfterFinishing(
                _ claim: PendingRetryClaim,
                generation: Int
            ) async -> Bool
            """)),
            "The settlement no longer takes the run's identity, so it cannot tell a cancelled run's "
            + "outcome from the current one's: \(settle.prefix(500))"
        )
        let refresh = try XCTUnwrap(
            settle.range(of: Self.squeezed("await refreshPendingRetryCount()")),
            "The count refresh is gone; this guard's anchor needs updating."
        )
        let checked = try XCTUnwrap(
            settle[refresh.upperBound...].range(of: Self.squeezed("guard stillCurrent(generation) else { return retired }")),
            "Nothing asks whether this run is still wanted after the settlement's own suspensions: "
            + "\(settle.prefix(500))"
        )
        for write in ["state = .idle", "lastError = backlogCode.map"] {
            let step = try XCTUnwrap(
                settle.range(of: Self.squeezed(write)),
                "`\(write)` is gone; this guard's anchor needs updating."
            )
            XCTAssertLessThan(
                checked.upperBound, step.lowerBound,
                "`\(write)` runs before the settlement's staleness check, which is the defect — a "
                + "finished Retry describes itself over a live capture: \(settle.prefix(500))"
            )
        }
        // The second hop needs its own reading: `pendingErrorCode()` suspends
        // between the first check and the banner it feeds.
        XCTAssertGreaterThanOrEqual(
            settle.components(separatedBy: Self.squeezed("guard stillCurrent(generation) else { return retired }")).count - 1,
            2,
            "One check cannot cover two suspensions — the clear/refresh pair and the backlog read "
            + "each need their own: \(settle.prefix(500))"
        )
        // …and COUNTING them is not enough. Two checks stacked above
        // `pendingErrorCode()` satisfy the count while leaving the read they
        // exist for uncovered, so the second one is asserted against its own
        // suspension: a cancel landing in the backlog read must not overwrite
        // the state of whatever the person started instead.
        let backlogRead = try XCTUnwrap(
            settle.range(of: Self.squeezed("await PendingRetryStore.shared.pendingErrorCode()")),
            "The backlog read is gone; this guard's anchor needs updating."
        )
        let afterBacklog = settle[backlogRead.upperBound...]
        let secondCheck = try XCTUnwrap(
            afterBacklog.range(of: Self.squeezed("guard stillCurrent(generation) else { return retired }")),
            "The second check sits above the backlog read it is supposed to cover: "
            + "\(settle.prefix(700))"
        )
        let backlogWrite = try XCTUnwrap(
            afterBacklog.range(of: Self.squeezed("lastError = backlogCode.map")),
            "The backlog write is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThanOrEqual(
            secondCheck.upperBound, backlogWrite.lowerBound,
            "The second check runs after the surface it guards is already written: "
            + "\(settle.prefix(700))"
        )

        // The hand-off is re-checked AFTER the settlement, which is the door the
        // first check cannot reach: it runs before the settlement suspends.
        let attempt = try Self.serviceFunction("attemptRetry")
        let settled = try XCTUnwrap(
            attempt.range(of: Self.squeezed("guard await settleAfterFinishing(claim, generation: generation) else")),
            "The settlement call is gone; this guard's anchor needs updating."
        )
        let after = attempt[settled.upperBound...]
        let recheck = try XCTUnwrap(
            after.range(of: Self.squeezed("guard stillCurrent(generation) else { return true }")),
            "The hand-off is not re-checked after the settlement, so a cancel landing inside the "
            + "queue clear still sends the words: \(attempt.suffix(900))"
        )
        let handOff = try XCTUnwrap(
            after.range(of: Self.squeezed("(onRecoveredTranscript ?? onTranscript)(trimmed)")),
            "The recovered hand-off is gone; this guard's anchor needs updating."
        )
        // Adjacent after squeezing, so `LessThanOrEqual` is the strictest form
        // that can hold; a re-check below the send still fails it.
        XCTAssertLessThanOrEqual(
            recheck.upperBound, handOff.lowerBound,
            "The re-check sits below the send it is supposed to stop: \(attempt.suffix(900))"
        )

        // A Work retry writes its surface after three more suspensions —
        // ownership, the screenshot publication, the desk recovery — so it
        // carries the same identity and routes every sentence through one gate.
        let work = try Self.serviceFunction("finishWorkRetry")
        XCTAssertTrue(
            source.contains(Self.squeezed("""
            private func finishWorkRetry(
                _ claim: PendingRetryClaim,
                transcript: String,
                generation: Int
            ) async -> Bool
            """)),
            "The Work retry no longer takes the run's identity: \(work.prefix(500))"
        )
        XCTAssertNil(
            work.range(of: Self.squeezed("state = .error(")),
            "A Work retry writes `state` directly again, so a cancelled one draws its banner over "
            + "whatever the person started next — every sentence goes through "
            + "`presentRetryOutcome`, which reads the token: \(work.prefix(700))"
        )
        // `RefusalLaneSource.body` returns through the function's own closing
        // brace, so the expected shape is compared against the body without it.
        let gate = String(try Self.serviceFunction("presentRetryOutcome").dropLast())
        XCTAssertEqual(
            gate,
            Self.squeezed("""
            guard stillCurrent(generation) else { return }
            lastError = nil
            state = .error(message: message, isRetryable: isRetryable)
            """),
            "The outcome gate is no longer exactly a staleness check followed by the write it "
            + "guards: \(gate)"
        )

        // NEGATIVE CONTROL: the un-tokened settlement this replaced writes both
        // states with nothing to stop it.
        let untokened = Self.squeezed("""
        await refreshPendingRetryCount()
        guard pendingRetryCount > 0 else {
            lastError = nil
            state = .idle
            return retired
        }
        """)
        XCTAssertNil(
            untokened.range(of: Self.squeezed("guard stillCurrent(generation) else { return retired }")),
            "Control: a settlement with no staleness check must FAIL this guard."
        )
    }

    /// An Ask START can be cancelled too, and for most of it there is nothing
    /// else to cancel.
    ///
    /// The press suspends twice before a microphone exists — the
    /// Speech-Recognition preflight, then `AudioRecorder.startRecording()`'s own
    /// permission hop — and through the first of them the service reads `.idle`,
    /// which `cancelRecording` has no arm for. So the bail invalidated nothing
    /// and the microphone came up behind the popover it had just closed.
    func testAnAskStartCarriesACancellationIdentity() throws {
        let cancel = try Self.serviceFunction("cancelRecording")
        let bump = try XCTUnwrap(
            cancel.range(of: Self.squeezed("recordingStartToken &+= 1")),
            "The bail no longer invalidates a start in flight, so an Esc pressed during the "
            + "permission hops is a no-op: \(cancel.prefix(400))"
        )
        let switchRange = try XCTUnwrap(
            cancel.range(of: Self.squeezed("switch state {")),
            "The state switch is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThanOrEqual(
            bump.upperBound, switchRange.lowerBound,
            "The start token moves inside an arm of the switch — the state it has to reach is "
            + "`.idle`, which has no arm at all: \(cancel.prefix(400))"
        )

        let start = try Self.serviceFunction("startRecording")
        XCTAssertTrue(
            start.contains(Self.squeezed("let startToken = recordingStartToken")),
            "The start no longer takes an identity: \(start.prefix(400))"
        )
        let preflightGuard = try XCTUnwrap(
            start.range(of: Self.squeezed("guard startToken == recordingStartToken else { return }")),
            "The preflight's answer is acted on unconditionally, so a withdrawn press still brings "
            + "the microphone up: \(start.prefix(400))"
        )
        let session = try XCTUnwrap(
            start.range(of: Self.squeezed("beginRecordingSession(startToken: startToken)")),
            "The session start is gone or no longer carries the token; anchor needs updating."
        )
        XCTAssertLessThan(
            preflightGuard.upperBound, session.lowerBound,
            "The withdrawal check runs after the session it is supposed to prevent: \(start.prefix(400))"
        )

        // And the far side of the SECOND hop tears the microphone down, because
        // by then it is live and belongs to nobody.
        let session2 = try Self.serviceFunction("beginRecordingSession")
        XCTAssertTrue(
            session2.contains(Self.squeezed("""
            guard startToken == recordingStartToken else {
                if state != .recording { recorder.cancelRecording() }
                return
            }
            """)),
            "A microphone that comes up after the bail is left running: the far side of "
            + "`recorder.startRecording()` must tear it down — and only when no live capture owns "
            + "the recorder, or it would stop the one the person is watching: \(session2.prefix(700))"
        )
        // …and THE FAR SIDE is the whole claim. Hoisted above the await, the
        // block reads a token nothing has had the chance to move and the
        // microphone still comes up after the press — every assertion above
        // stays green. The check is asserted against the suspension it protects.
        let primitiveStart = try XCTUnwrap(
            session2.range(of: Self.squeezed("let started = try await recorder.startRecording()")),
            "The primitive start is gone; this guard's anchor needs updating."
        )
        let staleStart = try XCTUnwrap(
            session2.range(of: Self.squeezed("guard startToken == recordingStartToken else {")),
            "The stale-start guard is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThanOrEqual(
            primitiveStart.upperBound, staleStart.lowerBound,
            "The stale-start check runs BEFORE the hop that brings the microphone up, so it reads a "
            + "token no press has had the chance to move: \(session2.prefix(700))"
        )

        // The primitive owns the other half. Its own entry guard is read before
        // the microphone-permission prompt, so two starts can both pass it: the
        // second used to build a SECOND recorder over the live one, and a stop
        // then returned the earlier recording. A reservation checked on the far
        // side of the prompt is what makes the start a single act.
        let primitive = try Self.recorderFunction("startRecording")
        let reservationTaken = try XCTUnwrap(
            primitive.range(of: Self.squeezed("let session = sessionGeneration")),
            "The primitive start takes no reservation: \(primitive.prefix(600))"
        )
        let prompt = try XCTUnwrap(
            primitive.range(of: Self.squeezed(
                "let permissionGranted = await AVAudioApplication.requestRecordPermission()"
            )),
            "The permission prompt is gone; this guard's anchor needs updating."
        )
        let reservationChecked = try XCTUnwrap(
            primitive.range(of: Self.squeezed(
                "guard session == sessionGeneration, !isRecording else { return false }"
            )),
            "Nothing re-reads the reservation after the prompt, so a start suspended in it still "
            + "takes the input: \(primitive.prefix(600))"
        )
        let built = try XCTUnwrap(
            primitive.range(of: Self.squeezed("audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)")),
            "The recorder construction is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThanOrEqual(
            reservationTaken.upperBound, prompt.lowerBound,
            "The reservation is taken after the prompt it has to outlive: \(primitive.prefix(600))"
        )
        XCTAssertLessThanOrEqual(
            prompt.upperBound, reservationChecked.lowerBound,
            "The reservation is checked before the prompt, which is the moment nothing can have "
            + "changed: \(primitive.prefix(600))"
        )
        XCTAssertLessThanOrEqual(
            reservationChecked.upperBound, built.lowerBound,
            "The recorder is built before the reservation is checked, so the clobber has already "
            + "happened: \(primitive.prefix(600))"
        )
        // …and both presses move it, including the ones that find nothing.
        for ender in ["stopRecording", "cancelRecording"] {
            let body = try Self.recorderFunction(ender)
            let moved = try XCTUnwrap(
                body.range(of: Self.squeezed("sessionGeneration &+= 1")),
                "`\(ender)` no longer ends the session, so a start suspended in the prompt "
                + "survives it: \(body.prefix(400))"
            )
            let earlyReturn = try XCTUnwrap(
                body.range(of: Self.squeezed("guard let recorder")),
                "`\(ender)`'s early return is gone; this guard's anchor needs updating."
            )
            XCTAssertLessThanOrEqual(
                moved.upperBound, earlyReturn.lowerBound,
                "`\(ender)` moves the session below its own early return — and that return is "
                + "exactly the path a press during the prompt takes: \(body.prefix(400))"
            )
        }

        // NEGATIVE CONTROL: the un-tokened start this replaced.
        let untokened = Self.squeezed("""
        Task {
            let speechStatus = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
            beginRecordingSession()
        }
        """)
        XCTAssertNil(
            untokened.range(of: Self.squeezed("guard startToken == recordingStartToken else { return }")),
            "Control: a start with no identity must FAIL this guard."
        )
    }

    /// Esc during the HAND-OFF — after the words exist and before the turn does.
    ///
    /// `handleQuickSend` suspends on the arm resolve, a settings read and a
    /// conversation mint, and through all of it `cancelActiveCapture` finds no
    /// dictation to stop and no reply to abandon. Settings promises "Esc always
    /// cancels the request"; without a token carried across that window the
    /// promise is false of the one moment the request does not exist yet.
    func testTheHandoffIsCancellableBeforeDispatch() throws {
        let coordinator = try Self.coordinatorFunction("handleQuickSend")
        let source = try Self.squeezedSource(at: "Conduck/MenuBar/MenuBarCoordinator.swift")

        // THE IDENTITY IS A PARAMETER, taken synchronously at the press. Read
        // inside the send's own `Task` it identifies nothing: a bail landing
        // between the claim and that task's first resumption has already moved
        // the generation, so the send adopts the moved value as its own and
        // passes its final check with the request the press withdrew.
        XCTAssertTrue(
            source.contains(Self.squeezed("sendGeneration: Int")),
            "The send no longer takes a cancellation identity: \(coordinator.prefix(500))"
        )
        XCTAssertFalse(
            coordinator.contains(Self.squeezed("let sendGeneration = quickSendGeneration")),
            "The send reads its own identity after the hop, which is the window a press lands in: "
            + "\(coordinator.prefix(500))"
        )
        let claim = String(try Self.coordinatorFunction("beginQuickSend").dropLast())
        XCTAssertEqual(
            claim,
            Self.squeezed("""
            turnStarting = true
            return quickSendGeneration
            """),
            "The synchronous claim is no longer exactly the gap-bridge flag and the identity taken "
            + "together — anything that suspends between them re-opens the window: \(claim)"
        )
        // Every door into the send takes it THERE, before its `Task` exists —
        // and `turnStarting` is claimed nowhere else, so there is no second
        // spelling of the press that could skip the identity.
        XCTAssertEqual(
            source.components(separatedBy: Self.squeezed("turnStarting = true")).count - 1, 1,
            "The gap-bridge flag is claimed outside `beginQuickSend` again, which is a press whose "
            + "send has no identity."
        )
        for wiring in [
            "guard let generation = self?.beginQuickSend() else { return } Task { [weak self] in",
            "let generation = beginQuickSend() quickDraft = \"\" armQuickCapture() Task { [weak self] in",
        ] {
            XCTAssertTrue(
                source.contains(Self.squeezed(wiring)),
                "A send door takes its identity inside its own `Task`, or after something that can "
                + "suspend: \(wiring)"
            )
        }
        XCTAssertFalse(
            source.contains(Self.squeezed("Task { [weak self] in let generation = self?.quickSendGeneration")),
            "A door reads the identity inside its task again, which is the defect this parameter "
            + "exists to close."
        )

        let checked = try XCTUnwrap(
            coordinator.range(of: Self.squeezed("guard sendGeneration == quickSendGeneration else { return }")),
            "Nothing re-reads the identity before the turn is committed: \(coordinator.prefix(500))"
        )

        // …and the CLEANUP is the send's too. A withdrawn send that still ran
        // its `defer` cleared the screenshot staged for the question started
        // after the bail and reset that question's destination — the cancel
        // doing exactly the damage the send was stopped from doing.
        XCTAssertTrue(
            coordinator.contains(Self.squeezed("""
            defer {
                if sendGeneration == quickSendGeneration {
                    turnStarting = false
                    if carriesComposition { clearPendingCaptureImage() }
                    if !keepSnapshot { resetQuickDestinationAfterTurn() }
                }
                sweepRegistry()
            }
            """)),
            "The exit cleanup runs for a send nobody is waiting for any more, so it consumes a "
            + "NEWER capture's composition: \(coordinator.prefix(900))"
        )

        // NEGATIVE CONTROL: the ungated cleanup this replaced. It keeps every
        // ordering assertion in this test and is the loss.
        let ungatedDefer = Self.squeezed("""
        defer {
            turnStarting = false
            if carriesComposition { clearPendingCaptureImage() }
            if !keepSnapshot { resetQuickDestinationAfterTurn() }
            sweepRegistry()
        }
        """)
        XCTAssertFalse(
            ungatedDefer.contains(Self.squeezed("if sendGeneration == quickSendGeneration {")),
            "Control: an ungated cleanup must FAIL the assertion above."
        )

        // …and the ERROR/STASH writes are asked BEFORE they happen, not at the
        // dispatch. Every one of them lands after a suspension, and a stash
        // written past the bail resurrects a withdrawn transcript as a live
        // Retry behind an error drawn over whatever was started instead.
        let stashGate = try Self.coordinatorFunction("stashQuickHandoffFailure")
        let gateChecked = try XCTUnwrap(
            stashGate.range(of: Self.squeezed("guard sendGeneration == quickSendGeneration else { return false }")),
            "The hand-off failure is presented and stashed without asking whether the send is still "
            + "wanted: \(stashGate)"
        )
        for write in ["dictationService.presentHandoffError(message: message)", "pendingFailedTurn = quickStash("] {
            let step = try XCTUnwrap(
                stashGate.range(of: Self.squeezed(write)),
                "`\(write)` is gone; this guard's anchor needs updating."
            )
            XCTAssertLessThan(
                gateChecked.upperBound, step.lowerBound,
                "`\(write)` runs before the cancellation is read: \(stashGate)"
            )
        }
        XCTAssertEqual(
            coordinator.components(separatedBy: Self.squeezed("dictationService.presentHandoffError(")).count - 1,
            0,
            "A hand-off failure is presented straight from the send again, which is a stash and an "
            + "error surface with no cancellation between them: \(coordinator.prefix(900))"
        )
        XCTAssertEqual(
            coordinator.components(separatedBy: Self.squeezed("stashQuickHandoffFailure(")).count - 1,
            4,
            "The four post-await failure arms — deleted destination, unavailable gateway, failed "
            + "mint, busy target — no longer go through the one gate that reads the token: "
            + "\(coordinator.prefix(900))"
        )
        let dispatch = try XCTUnwrap(
            coordinator.range(of: Self.squeezed("await vm.sendUserTurn(")),
            "The dispatch is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            checked.upperBound, dispatch.lowerBound,
            "The cancellation check runs after the turn is sent, which changes nothing: "
            + "\(coordinator.suffix(900))"
        )
        // The mint is the longest suspension on the path, so the check has to be
        // BELOW it — a check taken before the mint reads a token nothing has had
        // the chance to move.
        let mint = try XCTUnwrap(
            coordinator.range(of: Self.squeezed("conversationStore.createConversation(backend: ref.rawString)")),
            "The mint is gone; this guard's anchor needs updating."
        )
        XCTAssertLessThan(
            mint.upperBound, checked.lowerBound,
            "The commit check sits above the mint it is supposed to cover: \(coordinator.prefix(900))"
        )

        // The bail moves it, and only on the arm that owns the Ask surface: a
        // press the Work HUD answered returns before this line, because an Ask
        // send suspended underneath is not what that press was aimed at.
        let bail = try Self.coordinatorFunction("cancelActiveCapture")
        let hudReturn = try XCTUnwrap(
            bail.range(of: Self.squeezed("if owner == .workCapture { cancelWorkVoiceCapture() return }")),
            "The Work-HUD arm is gone or no longer returns; anchor needs updating."
        )
        let bump = try XCTUnwrap(
            bail.range(of: Self.squeezed("quickSendGeneration &+= 1")),
            "The bail no longer invalidates a suspended hand-off: \(bail.prefix(600))"
        )
        // Adjacent after squeezing; `LessThanOrEqual` is the strictest form that
        // can hold, and a bump above the return still fails it.
        XCTAssertLessThanOrEqual(
            hudReturn.upperBound, bump.lowerBound,
            "The send generation moves ABOVE the Work-HUD return, so an Esc typed over the Work HUD "
            + "cancels an Ask hand-off the person cannot see: \(bail.prefix(600))"
        )
    }

    /// The sentence the code above now keeps. The capture guide teaches Esc as
    /// step 3 under the two Ask shortcuts, so the promise is about the capture
    /// and not about the shortcut recorder — it is asserted here so the copy and
    /// the behaviour cannot drift apart in either direction.
    func testTheCaptureGuideStillPromisesTheCancel() throws {
        let source = try Self.squeezedSource(at: Self.guidePath)

        XCTAssertTrue(
            source.contains(Self.squeezed("Press Esc to cancel")),
            "The capture guide no longer teaches Esc as the way out of a capture. If the promise is "
            + "gone the guard above is homeless; if only the wording changed, re-point this assertion."
        )
    }

    // MARK: - Helpers

    /// Comment-stripped and whitespace-free, so indentation and line breaks
    /// cannot change what the code says.
    private static func squeezed(_ source: String) -> String {
        RefusalLaneSource.stripComments(source).filter { !$0.isWhitespace }
    }

    private static func squeezedSource(at relativePath: String) throws -> String {
        squeezed(try RefusalLaneSource.rawSource(at: relativePath))
    }

    /// One function's body from `DictationService`, squeezed. Scoping to a
    /// single function is what stops an assertion being satisfied by an
    /// unrelated statement elsewhere in a 1,000-line service.
    private static func serviceFunction(_ name: String) throws -> String {
        let source = try RefusalLaneSource.source(at: servicePath)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: servicePath))
    }

    /// One function's body from the `AudioRecorder` primitive, same rules. The
    /// second half of a cancelled start lives there: the service can invalidate
    /// a startup, but only the primitive can refuse to take the input.
    private static func recorderFunction(_ name: String) throws -> String {
        let path = "Conduck/Services/AudioRecorder.swift"
        let source = try RefusalLaneSource.source(at: path)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: path))
    }

    /// One function's body from `MenuBarCoordinator`, same rules. The hand-off
    /// the Esc promise covers ends there, not in the service.
    private static func coordinatorFunction(_ name: String) throws -> String {
        let path = "Conduck/MenuBar/MenuBarCoordinator.swift"
        let source = try RefusalLaneSource.source(at: path)
        return squeezed(try RefusalLaneSource.body(ofFunction: name, in: source, path: path))
    }
}

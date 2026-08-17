// SPDX-License-Identifier: Apache-2.0

// Conduck
// HeadlessRetryGuardSpanTests.swift
//
// SOURCE DRIFT GUARD over invariant I6 on the ONE lane that can break it
// silently: never destroy a recording the user has already made.
//
// The bug this locks down. `ConverseIntent.perform()` arms `PendingRetryGuard`
// before the microphone's output is spent, and used to disarm the instant STT
// returned — while the DESTINATION was still unresolved. `disarm` cancels the
// deferred "Recording Saved" notification AND clears `PendingRetryStore`, so any
// refusal raised after that point deleted the only copy of what the user said.
// It is reachable through a TIME gap rather than a rule gap: the pre-flight
// approves because a quick-capture pointer is TTL-fresh, the user speaks for
// thirty seconds, the pointer crosses its `SessionContinuationPolicy` window
// mid-recording, and the post-mic resolve refuses. No pre-flight ordering rule
// can close that — only the guard's SPAN can.
//
// Why a source guard and not a behavioural test. `ConverseIntent` is an App
// Intent whose `perform()` takes an `IntentFile` supplied by the Shortcuts
// runtime and drives a live `STTClient` upload; the iOS-Simulator suite cannot
// construct one or reach the code without a network provider. `PendingRetryGuard`
// itself is exercised elsewhere. What is untestable here — and what actually
// broke — is WHERE the disarm sits relative to the refusals, so that is what is
// asserted, in the style of `HeadlessRefusalLaneDriftGuardTests`.
//
// The same defect has two more shapes, and they are guarded here for the same
// reason — each is a matter of WHERE a statement sits, which no runtime test in
// this suite can reach:
//
//   • A refusal raised ABOVE the arm. `perform()` used to decide the STT key was
//     missing before `PendingRetryGuard.arm` ran, from a nil that a locked
//     Keychain produces just as readily as an empty slot. On a rebooted,
//     not-yet-unlocked iPhone — the Action-Button-from-the-lock-screen case —
//     that told a correctly configured user they had no key and destroyed the
//     recording to say it. Moving the check merely INSIDE the `do` would not
//     have helped: with `transcriptCaptured` still false, the typed-error arm
//     disarms and deletes the audio anyway. It has to be armed first and thrown
//     from outside the `do`, which is what Rule 3 pins.
//
//   • A throwing statement moved OUT of the hop's `do`. Below the disarm, the
//     only thing that can fail a `sending` turn is that `do`'s catch — it calls
//     `failTurn`, `postTurnFailed` and `postFailureNotification`. A `try` that
//     escapes it leaves the turn spinning on every device until the launch-time
//     stale sweep runs, with no Retry chip and no notification. Rule 4 pins the
//     assembler inside it, and pins the gap above it as throw-free.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS GUARD CHECKS (on comment-stripped source)
//
//   Rule 1 — `perform()` never disarms unconditionally. It holds exactly TWO:
//     the provable-absence refusal's own, taken inline in that arm because code
//     23 preserves nothing and the store's single slot is better spent on a
//     capture that can succeed; and the catch chain's, gated on the words NOT
//     yet existing as text. The blackout arm sitting beside the first one
//     disarms nothing — an unlock makes those exact bytes send.
//
//   Rule 2 — the disarm that does run sits BELOW the destination resolve and
//     BELOW the store append, so every refusal on the way is still armed.
//
//   Rule 3 — the STT-key verdict is reached BELOW the arm and thrown ABOVE the
//     `do`, and it is reached through `STTKeyReadiness` so the blackout reading
//     keeps its own code instead of being reported as an absent key (I3).
//
//   Rule 4 — every throwing statement below the disarm is inside the `do` whose
//     catch fails the turn.
//
//   Rule 0 — the negative control: each ordering check genuinely fails on the
//     shape the code used to have.

import XCTest
@testable import Conduck

final class HeadlessRetryGuardSpanTests: XCTestCase {

    private static let intentPath = "Conduck/Intents/ConverseIntent.swift"

    // MARK: - Rule 1 — the pre-transcript gate

    /// A bad-input verdict (silence, an oversized clip) may still clear the lane,
    /// because the same bytes cannot succeed twice. A verdict about the
    /// DESTINATION may not, because the same bytes succeed as soon as the user
    /// fixes what it names. `transcriptCaptured` is the line between them, and
    /// it has to be the gate on the catch chain's disarm rather than a comment
    /// about one.
    ///
    /// `perform()` holds exactly TWO disarms, and they are not interchangeable:
    ///
    ///   1. the PROVABLE-ABSENCE refusal (code 23), taken INLINE in its own arm
    ///      above the `do`. Code-specific and deliberate:
    ///      `sttMissingAPIKey.shouldPreserveForRetry` is false, and
    ///      `PendingRetryStore` is a single overwriting slot, so a capture that
    ///      cannot succeed until a key is entered may not hold it against one
    ///      that can. Its twin, the blackout arm, must NOT disarm — those bytes
    ///      succeed the moment the device is unlocked.
    ///
    ///   2. the CATCH CHAIN's, gated on the words not yet existing as text.
    ///
    /// A THIRD is how the unconditional post-STT disarm arrived, and it deleted
    /// the user's recording on every destination refusal.
    func testPerformDisarmsOnProvableAbsenceAndOtherwiseOnlyBeforeTheWordsExist() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        let body = try RefusalLaneSource.body(ofFunction: "perform", in: source, path: Self.intentPath)

        let disarms = body.components(separatedBy: "PendingRetryGuard.disarm").count - 1
        XCTAssertEqual(disarms, 2,
                       "`perform()` must hold exactly TWO disarms — the provable-absence refusal's and "
                       + "the catch chain's. A third is how the unconditional post-STT disarm arrived, "
                       + "and it deleted the user's recording on every destination refusal.")

        XCTAssertEqual(
            Self.armSpendsTheGuard(arm: "case .notConfigured:",
                                   throwToken: "throw AppError.sttMissingAPIKey",
                                   in: body),
            true,
            "The provable-absence arm no longer disarms, so code 23 parks a capture that can never be "
            + "sent in `PendingRetryStore`'s single slot — evicting a recoverable one and scheduling a "
            + "'Recording Saved' notification whose retry fails the same way."
        )
        XCTAssertEqual(
            Self.armSpendsTheGuard(arm: "case .unreadable:",
                                   throwToken: "throw AppError.sttKeyUnreadable",
                                   in: body),
            false,
            "The BLACKOUT arm must never disarm. Those bytes are bit-for-bit valid and an unlock makes "
            + "them succeed; deleting them is the original defect wearing the fix's clothes (I6)."
        )

        let gateAt = try XCTUnwrap(
            body.range(of: "if !transcriptCaptured {")?.lowerBound,
            "`perform()`'s catch-chain disarm is no longer gated on the transcript not existing yet. "
            + "Ungated, every destination verdict — code 12 included — clears the retry lane and the "
            + "spoken words are gone (I6)."
        )
        let firstDisarm = try XCTUnwrap(body.range(of: "PendingRetryGuard.disarm"))
        let secondDisarm = try XCTUnwrap(
            body.range(of: "PendingRetryGuard.disarm", range: firstDisarm.upperBound..<body.endIndex),
            "Only one disarm found where the count above says two; the matcher and the count disagree."
        )
        XCTAssertLessThan(firstDisarm.lowerBound, gateAt,
                          "The absence arm's disarm belongs ABOVE the `do`, in the refusal it is about — "
                          + "below the gate it would be the catch chain's, which cannot tell 23 from 75.")
        XCTAssertLessThan(gateAt, secondDisarm.lowerBound,
                          "The gate has to precede the catch chain's disarm, or it gates nothing.")

        // …and the flag must actually be raised, or the gate is always open.
        XCTAssertTrue(body.contains("transcriptCaptured = true"),
                      "Nothing sets the flag, so `!transcriptCaptured` is permanently true and the gate "
                      + "is decorative.")
    }

    /// Rule 1's control for the absence disarm — the regression this pins, and
    /// the overshoot that would be worse than it. Driven through the SAME
    /// matcher the check above uses, so a matcher broken by a formatting change
    /// fails here rather than quietly reporting the arms are as they should be.
    func testTheAbsenceDisarmCheckDistinguishesTheMissingAndOvershotShapes() {
        let neitherArmDisarms = """
        case .notConfigured:
            try? FileManager.default.removeItem(at: audioFileURL)
            throw AppError.sttMissingAPIKey
        case .unreadable:
            try? FileManager.default.removeItem(at: audioFileURL)
            throw AppError.sttKeyUnreadable
        """
        let bothArmsDisarm = """
        case .notConfigured:
            await PendingRetryGuard.disarm(guardToken)
            throw AppError.sttMissingAPIKey
        case .unreadable:
            await PendingRetryGuard.disarm(guardToken)
            throw AppError.sttKeyUnreadable
        """
        let compliant = """
        case .notConfigured:
            await PendingRetryGuard.disarm(guardToken)
            try? FileManager.default.removeItem(at: audioFileURL)
            throw AppError.sttMissingAPIKey
        case .unreadable:
            try? FileManager.default.removeItem(at: audioFileURL)
            throw AppError.sttKeyUnreadable
        """

        XCTAssertEqual(Self.armSpendsTheGuard(arm: "case .notConfigured:",
                                              throwToken: "throw AppError.sttMissingAPIKey",
                                              in: neitherArmDisarms), false,
                       "Control: the shape that shipped really did leave 23 armed — a terminal refusal "
                       + "holding the store's one slot — so the check must fail on it.")
        XCTAssertEqual(Self.armSpendsTheGuard(arm: "case .unreadable:",
                                              throwToken: "throw AppError.sttKeyUnreadable",
                                              in: bothArmsDisarm), true,
                       "Control: the overshoot really does spend the guard on the blackout arm, so the "
                       + "`false` assertion above is not vacuous.")
        XCTAssertEqual(Self.armSpendsTheGuard(arm: "case .notConfigured:",
                                              throwToken: "throw AppError.sttMissingAPIKey",
                                              in: compliant), true,
                       "Control: the compliant shape must pass both halves, or the checks are "
                       + "unsatisfiable.")
        XCTAssertEqual(Self.armSpendsTheGuard(arm: "case .unreadable:",
                                              throwToken: "throw AppError.sttKeyUnreadable",
                                              in: compliant), false)
        XCTAssertNil(Self.armSpendsTheGuard(arm: "case .notConfigured:",
                                            throwToken: "throw AppError.sttMissingAPIKey",
                                            in: "case .unreadable: throw AppError.sttKeyUnreadable"),
                     "Control: a missing arm must read as nil, not as a quiet `false` that would let a "
                     + "deleted arm pass the `false` assertion.")
    }

    /// The flag is raised only once the transcript has been validated non-empty
    /// — before that, `noSpeechDetected` is a verdict about the BYTES and must
    /// still disarm.
    func testTheTranscriptFlagIsRaisedAfterTheEmptyTranscriptRefusal() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        let body = try RefusalLaneSource.body(ofFunction: "perform", in: source, path: Self.intentPath)

        let silenceAt = try XCTUnwrap(
            body.range(of: "throw AppError.noSpeechDetected")?.lowerBound,
            "The empty-transcript refusal is gone; update this guard."
        )
        let raisedAt = try XCTUnwrap(body.range(of: "transcriptCaptured = true")?.lowerBound)
        XCTAssertLessThan(silenceAt, raisedAt,
                          "Raising the flag before the silence check would preserve a recording of nothing "
                          + "and hand the user a Retry that reaches the same emptiness.")
    }

    // MARK: - Rule 2 — the span reaches past the destination

    /// The refusal that costs the user their words is thrown by
    /// `SharedInboxRouting.resolveOrMint()`, inside `runConverseHop`. The disarm
    /// has to sit below it — and below the append that makes the transcript
    /// durable, which is the moment the recording stops being the only copy.
    func testTheConverseHopDisarmsOnlyAfterTheUserTurnIsStored() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        let body = try RefusalLaneSource.body(ofFunction: "runConverseHop", in: source, path: Self.intentPath)

        let resolveAt = try XCTUnwrap(
            body.range(of: "SharedInboxRouting.resolveOrMint")?.lowerBound,
            "`runConverseHop` no longer resolves the destination; update this guard."
        )
        let appendAt = try XCTUnwrap(
            body.range(of: "ConversationStore.shared.appendMessage")?.lowerBound,
            "`runConverseHop` no longer appends the user turn; update this guard."
        )
        let disarmAt = try XCTUnwrap(
            body.range(of: "PendingRetryGuard.disarm(retryGuardToken)")?.lowerBound,
            "`runConverseHop` never disarms, so a successful capture leaves a Retry card and a deferred "
            + "'Recording Saved' notification behind for a turn that went out fine."
        )
        XCTAssertLessThan(resolveAt, disarmAt,
                          "A destination refusal raised above the disarm is what keeps the audio in the "
                          + "retry lane. Below it, the words are deleted before the refusal is even "
                          + "surfaced (I6).")
        XCTAssertLessThan(appendAt, disarmAt,
                          "The transcript stops depending on the recording at the append, not before it.")
    }

    /// The token is a required parameter, not an optional with a default. An
    /// optional would let a future call site omit it and silently reinstate the
    /// never-disarms half of the bug.
    func testTheRetryTokenIsThreadedAsARequiredParameter() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        XCTAssertTrue(source.contains("retryGuardToken: PendingRetryGuard.Token"),
                      "The hop must OWN the disarm decision through a non-optional token.")
        XCTAssertFalse(source.contains("retryGuardToken: PendingRetryGuard.Token?"),
                       "An optional token makes 'forgot to pass it' a compiling, silent no-disarm.")
        XCTAssertTrue(source.contains("retryGuardToken: guardToken"),
                      "`perform()` must actually hand its armed token down, or the hop disarms a token "
                      + "nobody armed.")
    }

    // MARK: - Rule 3 — the key verdict is armed, and thrown outside the `do`

    /// The three positions that make a Keychain blackout survivable, in order:
    /// arm the guard, then decide about the key, then throw where no disarm can
    /// reach the throw. `var transcriptCaptured = false` is the last statement
    /// before the `do` opens, so "above that line" IS "outside the `do`" — and
    /// outside it is the only place that works, because inside it the
    /// `!transcriptCaptured` arm disarms on exactly these codes.
    func testTheKeyVerdictIsReachedAfterTheArmAndThrownOutsideTheTranscribeDo() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        let body = try RefusalLaneSource.body(ofFunction: "perform", in: source, path: Self.intentPath)

        let armAt = try XCTUnwrap(
            body.range(of: "PendingRetryGuard.arm")?.lowerBound,
            "`perform()` no longer arms the guard; update this guard."
        )
        let resolveAt = try XCTUnwrap(
            body.range(of: "STTKeyReadiness.resolve")?.lowerBound,
            "`perform()` must reach its key verdict through `STTKeyReadiness`. A bare "
            + "`snapshot.apiKey == nil` test cannot tell an empty slot from a Keychain that could not "
            + "answer, and calling the second one absence is the defect (I3)."
        )
        let missingAt = try XCTUnwrap(
            body.range(of: "throw AppError.sttMissingAPIKey")?.lowerBound,
            "The provable-absence refusal is gone; update this guard."
        )
        let blackoutAt = try XCTUnwrap(
            body.range(of: "throw AppError.sttKeyUnreadable")?.lowerBound,
            "The blackout reading lost its own code. Reporting it as `.sttMissingAPIKey` tells a user "
            + "whose key is present and correct that they have none."
        )
        let doOpensAt = try XCTUnwrap(
            body.range(of: "var transcriptCaptured = false")?.lowerBound,
            "The transcript flag is gone, so this guard can no longer locate the `do`; update it."
        )

        XCTAssertLessThan(armAt, resolveAt,
                          "The key verdict must be reached with the recording ALREADY preserved. Above the "
                          + "arm there is no `PendingRetryStore` entry, no deferred notification and no "
                          + "Retry card — the words are simply gone (I6).")
        XCTAssertLessThan(resolveAt, missingAt,
                          "Both refusals must come FROM the readiness verdict, not from a second, looser "
                          + "test that reintroduces the nil collapse.")
        XCTAssertLessThan(missingAt, doOpensAt,
                          "Thrown from inside the `do`, `.sttMissingAPIKey` meets the `!transcriptCaptured` "
                          + "arm, which disarms — and the recording is destroyed exactly as before.")
        XCTAssertLessThan(blackoutAt, doOpensAt,
                          "Same for the blackout code: inside the `do` it would disarm on a device whose "
                          + "only fault is that it has not been unlocked yet.")

        XCTAssertTrue(body.contains("case .notConfigured:"),
                      "Only the provable-absence arm may claim the key is missing.")
        XCTAssertTrue(body.contains("case .unreadable:"),
                      "The blackout arm must exist and be answered separately, or the two readings have "
                      + "silently merged again.")
        XCTAssertEqual(body.components(separatedBy: "throw AppError.sttMissingAPIKey").count - 1, 1,
                       "Exactly ONE site may assert the key is absent. A second one is where a nil-collapse "
                       + "grows back.")
    }

    /// The pre-microphone lane takes the OTHER half of the same verdict, and the
    /// asymmetry is the point: before the mic there is nothing to lose by
    /// continuing, so only provable absence refuses. A blackout refusal there
    /// would block a working device for the whole pre-first-unlock window.
    func testThePreflightRefusesOnlyProvableAbsence() throws {
        let path = "Conduck/Intents/CheckNetworkIntent.swift"
        let source = try RefusalLaneSource.source(at: path)
        let body = try RefusalLaneSource.body(ofFunction: "perform", in: source, path: path)

        XCTAssertTrue(body.contains("STTKeyReadiness.resolve"),
                      "The pre-flight must ask the SAME question `ConverseIntent` asks, through the same "
                      + "helper — a second implementation is how the two lanes drift into disagreeing "
                      + "about one Keychain slot.")
        XCTAssertTrue(body.contains("case .notConfigured = keyReadiness"),
                      "The refusal must be pinned to provable absence. Any wider test refuses a device "
                      + "whose key is present but temporarily unreadable.")
        XCTAssertFalse(body.contains("sttKeyUnreadable"),
                       "A blackout must NEVER refuse before the microphone: nothing has been spoken yet, "
                       + "so continuing costs nothing, and refusing blocks every capture on a rebooted "
                       + "device until someone unlocks it (I3).")
    }

    // MARK: - Rule 4 — nothing throws between the disarm and the failing catch

    /// The disarm's whole justification is that a later failure leaves a turn
    /// wearing its own Retry chip. That is only true of failures the hop's
    /// `do`/`catch` sees — it is the catch that calls `failTurn`,
    /// `postTurnFailed` and `postFailureNotification`. `assemble` reads Core
    /// Data and throws; outside the `do` its throw flips nothing, and the turn
    /// spins `sending` on every device until the launch-time stale sweep.
    func testEverythingBelowTheDisarmThrowsIntoTheFailingCatch() throws {
        let source = try RefusalLaneSource.source(at: Self.intentPath)
        let body = try RefusalLaneSource.body(ofFunction: "runConverseHop", in: source, path: Self.intentPath)

        let matched = try XCTUnwrap(
            Self.doBlock(enclosing: "BackgroundRemoteAgent.shared.send", in: body),
            "No `do` encloses the dispatch; update this guard."
        )
        XCTAssertTrue(matched.block.contains("ConversationHistoryAssembler.assemble"),
                      "`assemble` must sit INSIDE the dispatch `do`. Outside it, a Core Data fault leaves "
                      + "the user turn at `status: \"sending\"` with no Retry chip and no failure "
                      + "notification — the recording is already deleted, so the sweep 30 minutes later "
                      + "is the user's only recovery.")
        XCTAssertTrue(matched.tail.contains("ConversationStore.shared.failTurn"),
                      "The catch attached to that `do` must be the one that FAILS the turn, or being "
                      + "inside it buys nothing.")
        XCTAssertTrue(matched.tail.contains("postTurnFailed") && matched.tail.contains("postFailureNotification"),
                      "The Shortcut has already ended, so the catch's notification + red dot are the only "
                      + "way the failure reaches the user at all.")

        // …and the gap the disarm opens is genuinely empty of throws.
        let disarmAt = try XCTUnwrap(
            body.range(of: "PendingRetryGuard.disarm(retryGuardToken)")?.upperBound,
            "`runConverseHop` never disarms; update this guard."
        )
        let doAt = try XCTUnwrap(
            body.range(of: "do {", options: .backwards,
                       range: body.startIndex..<(body.range(of: "BackgroundRemoteAgent.shared.send")?.lowerBound ?? body.endIndex))?.lowerBound
        )
        XCTAssertLessThan(disarmAt, doAt, "The disarm must precede the dispatch `do`.")
        XCTAssertFalse(body[disarmAt..<doAt].contains("try "),
                       "A throwing statement between the disarm and the dispatch `do` fails into nothing: "
                       + "the recording is gone and no catch marks the turn. Move it inside the `do`.")
    }

    // MARK: - Rule 0 — the negative control

    /// The ordering assertions must genuinely fail on the shape the code had
    /// before this round, or they are checks nobody has seen bite.
    func testTheOrderingChecksDistinguishTheOldShapeFromTheNewOne() throws {
        let oldShape = """
        let response = try await STTClient.shared.transcribe(...)
        await PendingRetryGuard.disarm(guardToken)
        try await Self.runConverseHop(userText: transcript)
        """
        let newShape = """
        let response = try await STTClient.shared.transcribe(...)
        transcriptCaptured = true
        try await Self.runConverseHop(userText: transcript, retryGuardToken: guardToken)
        """
        XCTAssertTrue(oldShape.contains("PendingRetryGuard.disarm"),
                      "Control: the drifted shape disarms inside perform, above the hop.")
        let disarmAt = try XCTUnwrap(oldShape.range(of: "PendingRetryGuard.disarm")?.lowerBound)
        let hopAt = try XCTUnwrap(oldShape.range(of: "runConverseHop")?.lowerBound)
        XCTAssertLessThan(disarmAt, hopAt,
                          "Control: the old shape really did spend the guard before the destination was "
                          + "resolved — that is the whole defect.")
        XCTAssertFalse(newShape.contains("PendingRetryGuard.disarm"),
                       "Control: the compliant shape hands the token down instead of spending it.")
    }

    /// Rule 3's control. The shape that shipped decided about the key BEFORE the
    /// arm, so its refusal reached a recording nothing was protecting.
    func testTheKeyOrderingCheckDistinguishesTheUnarmedShape() throws {
        let oldShape = """
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        if let key = snapshot.apiKey, !key.isEmpty { apiKey = key } else { throw AppError.sttMissingAPIKey }
        let guardToken = await PendingRetryGuard.arm(audio: bytes, metadata: meta)
        var transcriptCaptured = false
        """
        let newShape = """
        let guardToken = await PendingRetryGuard.arm(audio: bytes, metadata: meta)
        switch await STTKeyReadiness.resolve(presetID: id, snapshotKey: snapshot.apiKey) {
        case .notConfigured: throw AppError.sttMissingAPIKey
        case .unreadable: throw AppError.sttKeyUnreadable
        }
        var transcriptCaptured = false
        """

        let oldArm = try XCTUnwrap(oldShape.range(of: "PendingRetryGuard.arm")?.lowerBound)
        let oldThrow = try XCTUnwrap(oldShape.range(of: "throw AppError.sttMissingAPIKey")?.lowerBound)
        XCTAssertGreaterThan(oldArm, oldThrow,
                             "Control: the drifted shape really did refuse before anything was preserved — "
                             + "that is the whole defect, and Rule 3 must fail on it.")
        XCTAssertFalse(oldShape.contains("STTKeyReadiness"),
                       "Control: the drifted shape read the collapsed nil directly, which is why it could "
                       + "not tell a locked Keychain from an empty slot.")

        let newArm = try XCTUnwrap(newShape.range(of: "PendingRetryGuard.arm")?.lowerBound)
        let newThrow = try XCTUnwrap(newShape.range(of: "throw AppError.sttMissingAPIKey")?.lowerBound)
        let newFlag = try XCTUnwrap(newShape.range(of: "var transcriptCaptured = false")?.lowerBound)
        XCTAssertLessThan(newArm, newThrow, "Control: the compliant shape arms first.")
        XCTAssertLessThan(newThrow, newFlag, "Control: and throws before the `do` opens.")
    }

    /// Rule 4's control. Driven through the SAME matcher Rule 4 uses, so a
    /// matcher broken by a formatting change fails here rather than quietly
    /// reporting that the assembler is where it should be.
    func testTheEnclosingDoMatcherDistinguishesTheEscapedAssembler() throws {
        let escaped = """
        await PendingRetryGuard.disarm(retryGuardToken)
        let priorTurns = try await ConversationHistoryAssembler.assemble(conversationID: id)
        do {
            try await BackgroundRemoteAgent.shared.send(priorTurns: priorTurns)
        } catch {
            await ConversationStore.shared.failTurn(messageID: id)
        }
        """
        let enclosed = """
        await PendingRetryGuard.disarm(retryGuardToken)
        do {
            let priorTurns = try await ConversationHistoryAssembler.assemble(conversationID: id)
            try await BackgroundRemoteAgent.shared.send(priorTurns: priorTurns)
        } catch {
            await ConversationStore.shared.failTurn(messageID: id)
        }
        """

        let escapedMatch = try XCTUnwrap(Self.doBlock(enclosing: "BackgroundRemoteAgent.shared.send", in: escaped))
        XCTAssertFalse(escapedMatch.block.contains("ConversationHistoryAssembler.assemble"),
                       "Control: in the shipped shape the assembler really was outside the `do`, so its "
                       + "throw reached no `failTurn` — Rule 4 must fail on this.")
        XCTAssertTrue(escapedMatch.tail.contains("ConversationStore.shared.failTurn"),
                      "Control: the catch is found in both shapes, so the block/tail split is what "
                      + "distinguishes them and not the presence of a catch.")

        let enclosedMatch = try XCTUnwrap(Self.doBlock(enclosing: "BackgroundRemoteAgent.shared.send", in: enclosed))
        XCTAssertTrue(enclosedMatch.block.contains("ConversationHistoryAssembler.assemble"),
                      "Control: the compliant shape must pass, or Rule 4 is unsatisfiable.")

        // The throw-free-gap half of Rule 4, on the same pair.
        let escapedGap = try XCTUnwrap(escaped.range(of: "PendingRetryGuard.disarm(retryGuardToken)")?.upperBound)
        let escapedDo = try XCTUnwrap(escaped.range(of: "do {")?.lowerBound)
        XCTAssertTrue(escaped[escapedGap..<escapedDo].contains("try "),
                      "Control: the escaped shape leaves a `try` in the gap the disarm opens.")
        let enclosedGap = try XCTUnwrap(enclosed.range(of: "PendingRetryGuard.disarm(retryGuardToken)")?.upperBound)
        let enclosedDo = try XCTUnwrap(enclosed.range(of: "do {")?.lowerBound)
        XCTAssertFalse(enclosed[enclosedGap..<enclosedDo].contains("try "),
                       "Control: the compliant shape leaves the gap empty.")
    }

    // MARK: - Source shape helpers

    /// Whether the switch arm opening at `arm` spends the retry guard before it
    /// reaches `throwToken`. Scoped to the arm rather than to the whole function
    /// because the two key arms sit adjacent and an unscoped `contains` cannot
    /// tell which of them holds the disarm — which is the entire distinction
    /// being asserted.
    ///
    /// Returns nil when the arm or its throw is absent, so a DELETED arm reads
    /// as "cannot tell" instead of quietly satisfying a `false` expectation.
    private static func armSpendsTheGuard(arm: String, throwToken: String, in body: String) -> Bool? {
        guard let start = body.range(of: arm)?.upperBound,
              let end = body.range(of: throwToken, range: start..<body.endIndex)?.lowerBound else {
            return nil
        }
        return body[start..<end].contains("PendingRetryGuard.disarm")
    }

    /// The `do` block that ENCLOSES `anchor`, brace-matched from the nearest
    /// `do {` above it, plus everything after its closing brace (where its
    /// `catch` lives). Returns nil when there is no enclosing `do` or the braces
    /// do not balance — both of which the callers report as a failure rather
    /// than passing silently.
    ///
    /// Operates on comment-stripped source, so a `do {` inside prose cannot be
    /// mistaken for one in code.
    private static func doBlock(enclosing anchor: String, in body: String) -> (block: Substring, tail: Substring)? {
        guard let anchorRange = body.range(of: anchor),
              let doRange = body.range(of: "do {", options: .backwards,
                                       range: body.startIndex..<anchorRange.lowerBound) else {
            return nil
        }
        var index = doRange.upperBound
        let start = index
        var depth = 1
        while index < body.endIndex, depth > 0 {
            if body[index] == "{" { depth += 1 }
            if body[index] == "}" { depth -= 1 }
            index = body.index(after: index)
        }
        guard depth == 0 else { return nil }
        return (body[start..<body.index(before: index)], body[index...])
    }
}

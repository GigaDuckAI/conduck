// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayVoiceTimingContractTests.swift
//
// Pins the parts of the CarPlay voice session that decide when a driver is cut
// off, and that no unit test can reach through an API.
//
// `CarPlayRecordingService` owns an audio engine, a CarPlay template and a live
// audio session, so its timing rules cannot be exercised by constructing it —
// `mute()`, `unmute()` and the no-speech timeout are private, and everything
// that reaches them needs a real session. Two of those rules are nonetheless
// invariants somebody could delete in one line, with a failure mode that only
// shows up in a moving car:
//
//   • A MUTED SESSION IS NEVER SIGNED OFF FOR SILENCE. `mute()` invalidates the
//     timers FIRST, and invalidating them bumps a generation token so a timeout
//     task already queued on the main actor is disarmed as well. `Timer`
//     invalidation alone cannot do that: once the timer's closure has run, the
//     task it enqueued is beyond recall.
//   • UNMUTE RE-ARMS FROM THE PARKED STATE ONLY. Muting does not interrupt a
//     reply or a retry prompt; those keep playing and park on `.muted` in their
//     own completion. An unconditional re-arm here would start capture before
//     the speech finished and leave a SECOND listener behind it.
//   • ONE LISTEN ARMS AT A TIME. `startListening` suspends several times before
//     it commits, so without a claim on the way in, two re-arms started moments
//     apart both run to the end and the second overwrites the first's engine
//     without stopping it — two taps on one HFP route, which is g6.
//   • A MUTE THAT LANDS MID-SETUP IS HONOURED AT THE COMMIT. `mute()` cannot
//     tear down a capture that does not exist yet, so the commit checks for
//     itself; otherwise the microphone runs behind a button reading "Unmute".
//
// So this file reads the two source files and asserts the shape, in the same
// spirit as the other source-scanning drift guards in this suite
// (`LoggingPrivacyDriftGuardTests`, `RelayWireSourceDriftGuardTests`). A textual
// guard is a blunt instrument and will need updating alongside a deliberate
// refactor; that is the point — it makes the deletion visible rather than
// silent. The behavioural half stays with the founder's cabin QA.
//
// The tuning constants and the spoken strings are pinned here too, because
// their values ARE the design: two silence windows, one quantized endpoint, and
// one spoken line for a broken microphone that has to exist in the catalog with
// the same language coverage as the ordinary sign-off.

import XCTest
@testable import Conduck

final class CarPlayVoiceTimingContractTests: XCTestCase {

    // MARK: - Tuning constants

    func testTheTwoSilenceWindows() {
        // 15 s cold-connect: the driver may still be connecting the phone,
        // finding the app, or deciding what to ask.
        XCTAssertEqual(Constants.carPlayInitialSilenceTimeout, 15)
        // 20 s follow-up: mid-conversation a driver may need to think, or to
        // attend to the road. Killing a live conversation is the worse failure,
        // and End and Mute both cover a driver who is done — while the ceiling
        // also bounds how long the car's paused radio is held after the last
        // reply (founder-tuned down from 30 s for exactly that cost).
        XCTAssertEqual(Constants.carPlayFollowUpSilenceTimeout, 20)
        XCTAssertGreaterThan(
            Constants.carPlayFollowUpSilenceTimeout,
            Constants.carPlayInitialSilenceTimeout,
            "patience grows once a conversation is under way, never shrinks"
        )
    }

    func testEndpointingTuning() {
        XCTAssertEqual(Constants.carPlayVADThreshold, 0.65)
        XCTAssertEqual(Constants.carPlayVADMinSilence, 1.5)
        XCTAssertEqual(
            CarPlayVADQuantization.feltEndOfSpeechDelay(minSilence: Constants.carPlayVADMinSilence),
            1.792,
            accuracy: 1e-9,
            "the felt endpoint is what the driver experiences; the constant is not"
        )
    }

    func testAListenCannotOutlastItsHardCap() {
        // Both silence windows have to fit inside the per-recording cap, or the
        // cap would end a listen the silence guard was still watching.
        XCTAssertLessThan(Constants.carPlayFollowUpSilenceTimeout, Constants.maxAudioDuration)
        XCTAssertLessThan(Constants.carPlayInitialSilenceTimeout, Constants.maxAudioDuration)
    }

    // MARK: - Spoken strings

    func testTheBrokenCaptureLineExistsWithTheSignOffsLanguageCoverage() throws {
        let catalog = try stringCatalog()
        let signOff = try XCTUnwrap(
            catalog["Talk to you later."] as? [String: Any],
            "the ordinary sign-off is the coverage baseline"
        )
        let broken = try XCTUnwrap(
            catalog["carplay.error.captureBroken.speak"] as? [String: Any],
            "a broken capture pipeline is spoken about, so it needs a catalog entry"
        )
        let signOffLanguages = Set((signOff["localizations"] as? [String: Any] ?? [:]).keys)
        let brokenLanguages = Set((broken["localizations"] as? [String: Any] ?? [:]).keys)
        XCTAssertFalse(signOffLanguages.isEmpty)
        XCTAssertEqual(
            brokenLanguages, signOffLanguages,
            "every spoken CarPlay line ships in the same languages"
        )
    }

    func testTheEmptyTurnPromptExistsInTheCatalog() throws {
        let catalog = try stringCatalog()
        XCTAssertNotNil(
            catalog["Didn't catch that — try again."],
            "the retry prompt is spoken twice — once before a retry and once on the way out"
        )
    }

    func testTheBrokenCaptureLineIsDistinctFromTheSignOff() throws {
        let catalog = try stringCatalog()
        let broken = try XCTUnwrap(catalog["carplay.error.captureBroken.speak"] as? [String: Any])
        let english = ((broken["localizations"] as? [String: Any])?["en"] as? [String: Any])
        let value = (english?["stringUnit"] as? [String: Any])?["value"] as? String
        let spoken = try XCTUnwrap(value)
        XCTAssertFalse(spoken.isEmpty)
        XCTAssertNotEqual(
            spoken, "Talk to you later.",
            "a wedged microphone must not sound like a normal goodbye"
        )
    }

    // MARK: - Mute exemption (D6), pinned at the only reachable seam

    func testMuteInvalidatesTimersBeforeTouchingAnythingElse() throws {
        let body = try functionBody("private func mute()", in: recordingServiceSource())
        let invalidate = try XCTUnwrap(
            body.range(of: "invalidateTimers()"),
            "a muted session must never be dropped for silence"
        )
        for later in ["tearDownCapture()", "state = .muted"] {
            let range = try XCTUnwrap(body.range(of: later), "expected \(later) in mute()")
            XCTAssertTrue(
                invalidate.lowerBound < range.lowerBound,
                "the timers go first: everything after this is allowed to take time"
            )
        }
    }

    func testInvalidatingTimersAlsoDisarmsAlreadyQueuedTimeouts() throws {
        let source = recordingServiceSource()
        let timers = try functionBody("private func invalidateTimers()", in: source)
        XCTAssertTrue(
            timers.contains("invalidateSilenceTimer()"),
            "the silence timer is the one that ends sessions"
        )
        let silence = try functionBody("private func invalidateSilenceTimer()", in: source)
        XCTAssertTrue(
            silence.contains("silenceTimerGeneration &+= 1"),
            "invalidating the Timer cannot revoke a task its closure already enqueued; the generation can"
        )
    }

    func testTheTimeoutHandlerChecksBothHalvesOfItsGuard() throws {
        let body = try functionBody(
            "private func handleSilenceTimeout(generation: UInt64, isFollowUp: Bool, graceUsed: Bool)",
            in: recordingServiceSource()
        )
        XCTAssertTrue(
            body.contains("generation == silenceTimerGeneration"),
            "a stale timeout task must recognise itself as stale"
        )
        XCTAssertTrue(
            body.contains("didCorroborateSpeechThisListen"),
            "speech that arrived while the timeout was queued still wins"
        )
        XCTAssertTrue(
            body.contains("counters.didCorroborateSpeech"),
            "the VAD task publishes corroboration before its main-actor hop; a timeout that overtakes the hop reads it here"
        )
        XCTAssertTrue(
            body.contains("graceUsed"),
            "the one-chunk expiry grace must not be able to chain"
        )
    }

    func testUnmuteReArmsOnlyFromTheParkedState() throws {
        let body = try functionBody("private func unmute()", in: recordingServiceSource())
        let guardRange = try XCTUnwrap(
            body.range(of: "guard state == .muted"),
            "a re-arm from any other state races the flow that already owns one"
        )
        let reArm = try XCTUnwrap(body.range(of: "reArmAfterSettle"))
        XCTAssertTrue(guardRange.lowerBound < reArm.lowerBound)
    }

    // MARK: - One listen at a time (g6), and mute wins over a listen mid-setup

    func testOnlyOneListenMayArmAtATime() throws {
        let body = try functionBody("private func startListening(isFollowUp: Bool) async", in: recordingServiceSource())
        let guardRange = try XCTUnwrap(
            body.range(of: "guard !isArmingListen, state != .recording else { return }"),
            "two overlapping re-arms leave two engines and two taps on the HFP route"
        )
        let bump = try XCTUnwrap(body.range(of: "listenAttemptID &+= 1"))
        XCTAssertTrue(
            guardRange.lowerBound < bump.lowerBound,
            "a rejected duplicate must not invalidate the listen already in flight"
        )
        XCTAssertTrue(
            body.contains("defer { isArmingListen = false }"),
            "every exit from the setup releases the claim, or the session never listens again"
        )
    }

    func testAMuteDuringSetupParksInsteadOfArmingTheMicrophone() throws {
        let body = try functionBody("private func startListening(isFollowUp: Bool) async", in: recordingServiceSource())
        let muteGuard = try XCTUnwrap(
            body.range(of: "guard !isMicMuted else {"),
            "mute() cannot tear down a capture that does not exist yet; the commit has to honour it"
        )
        let arm = try XCTUnwrap(
            body.range(of: "scheduleSilenceTimer(isFollowUp: isFollowUp)"),
            "the silence timer is armed at the commit"
        )
        XCTAssertTrue(
            muteGuard.lowerBound < arm.lowerBound,
            "a muted session must never end up with a live microphone and a running silence guard"
        )
    }

    // MARK: - Timers run in `.common` mode

    func testEverySessionTimerRunsInCommonRunLoopMode() {
        let source = recordingServiceSource()
        XCTAssertFalse(
            source.contains("Timer.scheduledTimer"),
            "the default run-loop mode stops firing during tracking; the Watch already uses .common"
        )
        let additions = source.components(separatedBy: "RunLoop.main.add(")
        XCTAssertGreaterThanOrEqual(additions.count - 1, 3, "expected the silence, grace and max-duration timers")
        for addition in additions.dropFirst() {
            XCTAssertTrue(
                addition.hasPrefix("timer, forMode: .common)"),
                "a session timer was added in a mode other than .common"
            )
        }
    }

    // MARK: - An uncorroborated episode is discarded, not fatal

    func testAnUncorroboratedSpeechEndKeepsTheStreamRunning() throws {
        let source = detectorSource()
        let discardRange = try XCTUnwrap(
            source.range(of: "guard corroboration.isCorroborated else {"),
            "an uncorroborated episode is a blip, not a turn"
        )
        // The guard's else-block, up to its closing brace.
        let afterGuard = source[discardRange.upperBound...]
        let closing = try XCTUnwrap(afterGuard.range(of: "}"))
        let elseBody = afterGuard[..<closing.lowerBound]
        XCTAssertTrue(
            elseBody.contains("continue"),
            "the stream keeps flowing so a later qualifying pair can still corroborate"
        )
        XCTAssertFalse(
            elseBody.contains("return"),
            "returning out of the processing loop would end listening on a pothole"
        )
    }

    func testTheDetectorLatchesOnlyForCorroboratedEpisodes() throws {
        let source = detectorSource()
        let guardRange = try XCTUnwrap(source.range(of: "guard corroboration.isCorroborated else {"))
        let fireRange = try XCTUnwrap(
            source.range(of: "self.didFire = true"),
            "the single-fire latch is what makes one listen one utterance"
        )
        XCTAssertTrue(
            guardRange.lowerBound < fireRange.lowerBound,
            "the latch is set only on the corroborated side of the guard"
        )
    }

    func testTheDeadSensitivityDialIsGone() {
        // It read three thresholds nothing ever passed to the CarPlay preset —
        // a tuning knob that looked live and was not. The two real dials are
        // `Constants.carPlayVADThreshold` and `Constants.carPlayVADMinSilence`.
        XCTAssertFalse(detectorSource().contains("SensitivityLevel"))
    }

    // MARK: - Capture lifecycle (stale commit + observer lifetime)

    func testACommitNeverLandsOnADeadSession() throws {
        let body = try functionBody("private func startListening(isFollowUp: Bool) async", in: recordingServiceSource())

        // THE HELPER ITSELF, pinned whole and first. Every assertion below
        // searches for `isCurrentListen(`, so removing the generation
        // comparison INSIDE it leaves the guard text, the ordering and the
        // cleanup untouched while the question becomes "is SOME session live" —
        // which is yes for the session that replaced this startup, and is
        // exactly the commit this test exists to stop.
        let lineage = try functionBody(
            "private func isCurrentListen(_ attemptID: UInt64) -> Bool", in: recordingServiceSource()
        )
        XCTAssertEqual(
            lineage.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "),
            "sessionActive && listenAttemptID == attemptID",
            "the lineage question no longer asks whose listen this is; the stale-commit guard below now passes for a replacement session"
        )

        // Everything from the engine-start call onward: the suspension the
        // stale-commit guard exists for.
        let retryCall = try XCTUnwrap(body.range(of: "startCaptureEngineWithRetry("))
        let afterRetry = String(body[retryCall.upperBound...])
        // ASKED OF THE STARTUP GENERATION, not of the bare session flag. A
        // session that REPLACED this one is live too, so `sessionActive` would
        // commit this engine and this detector onto it — and the detector's
        // callbacks carry the invalidated attempt id, so the driver could speak
        // into a running microphone that never endpoints.
        let staleGuard = try XCTUnwrap(
            afterRetry.range(of: "guard isCurrentListen(attemptID) else {"),
            "a session ended mid-engine-start must not be committed — a running engine nothing stops is the persistent-'nope' wedge"
        )
        XCTAssertNil(
            afterRetry.range(of: "guard sessionActive else {"),
            "the commit guard is back to the bare session flag, which answers yes for the session that replaced this startup"
        )
        let commit = try XCTUnwrap(afterRetry.range(of: "state = .recording"))
        XCTAssertTrue(staleGuard.lowerBound < commit.lowerBound)

        // EACH ARM ON ITS OWN, brace-matched. A scan of everything between the
        // guard and the commit finds the mute arm's identical three lines, so
        // deleting the stale arm's cleanup leaves a RUNNING engine and a live
        // input tap on the HFP route — the persistent-'nope' wedge that survives
        // until a reboot — with every token the scan looks for still present.
        let code = Self.normalisedCode(afterRetry)
        for (opening, extra, why) in [
            ("guard isCurrentListen(attemptID) else {",
             ["removeItem(at: url)", "handOnArmingSlotAfterAbandonedStartup()"],
             "a startup superseded during the engine start"),
            ("guard !isMicMuted else {",
             ["removeItem(at: url)", "state = .muted"],
             "a Mute that landed while this listen was spinning up")
        ] {
            let arm = try armBody(openedBy: opening, in: code)
            for cleanup in ["removeTap(onBus: 0)", "engine.stop()", "detector.stop()"] + extra {
                XCTAssertTrue(
                    arm.contains(cleanup),
                    "\(why) discards its engine without \(cleanup) — a running capture nothing will ever stop"
                )
            }
        }
        let muteGuard = try XCTUnwrap(afterRetry.range(of: "guard !isMicMuted else {"))
        XCTAssertTrue(
            staleGuard.lowerBound < muteGuard.lowerBound,
            "a dead session wins over mute-parking — endSession already reset the mute flag"
        )
    }

    func testEveryRetryAbortIsLogged() throws {
        let body = try functionBody("private func startCaptureEngineWithRetry(", in: recordingServiceSource())
        let aborts = body.components(separatedBy: "CarPlay engine retry abort").count - 1
        XCTAssertGreaterThanOrEqual(
            aborts, 4,
            "every silent guard exit logs its reason — the field diagnosis that took a night of archaeology takes one log line"
        )
        XCTAssertTrue(body.contains("CarPlay hard recovery begin"), "recovery entry is visible")
        XCTAssertTrue(
            body.contains("isVoiceModalPresented?() ?? true"),
            "hard recovery aborts when the voice modal is gone — the one signal that can go stale independently of sessionActive"
        )
    }

    func testObserversCannotOutliveTheService() throws {
        let source = recordingServiceSource()
        let wrapper = try XCTUnwrap(
            source.range(of: "final class NotificationToken"),
            "the release-driven observer wrapper is what makes a skipped didDisconnect unable to leak observers"
        )
        let afterWrapper = String(source[wrapper.upperBound...])
        XCTAssertTrue(
            afterWrapper.contains("deinit { NotificationCenter.default.removeObserver"),
            "the wrapper's whole job is removal on release"
        )
        for setup in ["setupInterruptionObserver", "setupRouteChangeObserver", "setupMediaResetObserver"] {
            let body = try functionBody("private func \(setup)()", in: source)
            XCTAssertTrue(
                body.contains("NotificationToken("),
                "\(setup) must hand its registration to the release-driven wrapper"
            )
        }
        XCTAssertTrue(
            source.contains("engineConfigChangeObserver = NotificationToken("),
            "the per-listen reconfig observer leaks the same way the session observers did"
        )
    }

    func testAReconnectTearsDownTheStaleService() throws {
        let source = sceneDelegateSource()
        let connect = try functionBody("didConnect interfaceController: CPInterfaceController", in: source)
        // The SHARED teardown, not a subset of it: a hard drop that skipped both
        // disconnect callbacks would otherwise hand this connection the previous
        // one's start claim, refresh latch, session override and observers.
        let teardown = try XCTUnwrap(
            connect.range(of: "disconnectCleanup()"),
            "a hard drop can skip didDisconnect; the next connect must not build on a live stale service"
        )
        let fresh = try XCTUnwrap(connect.range(of: "CarPlayRecordingService()"))
        XCTAssertTrue(teardown.lowerBound < fresh.lowerBound, "teardown of the old before construction of the new")
        let cleanup = try functionBody("private func disconnectCleanup()", in: source)
        XCTAssertTrue(
            cleanup.contains("recordingService?.teardown()"),
            "the shared cleanup is what actually tears the stale service down"
        )
        // UNCONDITIONALLY, and pinned by its neighbours. Present-but-unreachable
        // is the mutation this closes: `if false { recordingService?.teardown() }`
        // keeps both references above and leaves a stale engine, a stale tap and
        // a stale audio activation alive behind the new connection.
        XCTAssertTrue(
            Self.normalisedCode(cleanup).contains(
                "CarPlaySpeechService.shared.cancel() recordingService?.teardown() self.interfaceController = nil"
            ),
            "the teardown is no longer an unconditional statement of the shared cleanup — a branch around it leaves the previous connection's audio machinery running"
        )
        // THE CALLER'S CONDITION, whole. Inverting it to `recordingService ==
        // nil` keeps the call textually before the construction below and keeps
        // every ordering assertion above green, while the one case it exists for
        // — a hard drop that skipped both disconnect callbacks — is the one case
        // it now skips.
        XCTAssertTrue(
            Self.normalisedCode(connect).contains(
                "if recordingService != nil { "
                + "Self.log.info(\"didConnect found a stale recordingService — tearing it down first\") "
                + "disconnectCleanup() }"
            ),
            "the stale-service teardown is asked on the wrong condition — a hard drop hands this connection the previous one's engine, tap and audio activation"
        )
        let didDisconnect = try functionBody("func sceneDidDisconnect(", in: source)
        XCTAssertTrue(
            didDisconnect.contains("disconnectCleanup()"),
            "UIKit's scene-discard path cleans up even when the CarPlay-specific callback was skipped"
        )
    }

    func testStartFailureHintIsOneShot() throws {
        let source = sceneDelegateSource()
        // Consumed in the shared claim both starters take, so the Work row
        // consumes it on exactly the same terms the AI row does.
        let claim = try functionBody("private func claimStart(", in: source)
        XCTAssertTrue(
            claim.contains("oneShotStartFailureHint = false"),
            "the hint is consumed the moment the driver acts again"
        )
        // CONSUMED, not merely written. Re-setting the flag to `true` on the way
        // out satisfies the assertion above and leaves the hint on the picker
        // over the row the driver just tapped, so the false write is pinned as
        // the LAST thing the claim does.
        XCTAssertTrue(
            Self.normalisedCode(claim).contains("oneShotStartFailureHint = false return startClaimSerial"),
            "something writes the hint again after the claim consumed it — the one-shot is no longer one-shot"
        )
        // THE CALLBACK, whole. It carries BOTH halves of a silent start-failure
        // end — the flag the refresh renders and the dismiss-then-refresh
        // itself — because that end never leaves `.idle` and so reaches no state
        // observation. Wrapping its two lines in `if !service.isSceneActive`
        // keeps the single `= true` write the count below asks for, and leaves
        // every foreground failure on a Listening modal over a dead session with
        // no hint and no dismiss: the exact end this wiring exists to finish.
        XCTAssertTrue(
            Self.normalisedCode(source).contains(
                "service.onCaptureStartFailed = { [weak self, weak service] in "
                + "guard let self, let service else { return } "
                + "self.oneShotStartFailureHint = true "
                + "self.applyState(service.state, service: service) }"
            ),
            "the start-failure callback no longer unconditionally raises the hint and runs the end's own transition — a silent failure leaves the driver on a Listening screen that ends nothing"
        )

        // And exactly one place raises it: the capture-start failure the row is
        // feedback for.
        XCTAssertEqual(
            source.components(separatedBy: "oneShotStartFailureHint = true").count - 1, 1,
            "a second writer raises the mic-couldn't-start hint; the picker now accuses the microphone of something else"
        )
        for starter in ["private func startSession(", "private func startWorkNote("] {
            let body = try functionBody(starter, in: source)
            XCTAssertTrue(
                body.contains("claimStart("),
                "\(starter) does not go through the claim, so it neither consumes the hint nor holds the one-start rule"
            )
        }
        let picker = try functionBody("private func refreshPicker()", in: source)
        XCTAssertTrue(
            picker.contains("oneShotStartFailureHint"),
            "the picker is where a silent start failure becomes visible"
        )
    }

    func testTheStartFailureHintStringsExistInTheCatalog() throws {
        let catalog = try stringCatalog()
        XCTAssertNotNil(
            catalog["carplay.hint.captureStartFailed.title"],
            "the one-shot picker row is the only feedback a silent start failure gets"
        )
        XCTAssertNotNil(catalog["carplay.hint.captureStartFailed.detail"])

        // THE VALUES, not just the keys. The whole reason there are two detail
        // strings is that each names the row that failed, and the ternary
        // choosing between them is pinned elsewhere by KEY — so editing the Work
        // row's English to "Tap New voice chat to try again." leaves every guard
        // in this bundle green while a driver whose private note failed is told,
        // out loud on the picker, to send it to an AI instead.
        for (key, english) in [
            ("carplay.hint.captureStartFailed.title", "Mic couldn't start"),
            ("carplay.hint.captureStartFailed.detail", "Tap New voice chat to try again."),
            ("carplay.hint.captureStartFailed.detail.work", "Tap Add to Work to try again.")
        ] {
            XCTAssertEqual(
                try englishValue(of: key, in: catalog), english,
                "the hint row no longer says what it means: this one names the row the driver has to tap next, and naming the wrong one routes a private thought to an AI"
            )
        }
        // …and the two details are DIFFERENT sentences. Equal values satisfy
        // every assertion above pairwise while the distinction the ternary
        // exists for is gone.
        XCTAssertNotEqual(
            try englishValue(of: "carplay.hint.captureStartFailed.detail", in: catalog),
            try englishValue(of: "carplay.hint.captureStartFailed.detail.work", in: catalog),
            "both hint details now read the same, so the failed row can no longer be named"
        )
    }

    // MARK: - Source access

    /// `.../Conduck/Conduck` — the project container holding every target's
    /// sources, derived from this file's compile-time path so the scan does not
    /// depend on the runner's working directory. Same derivation as the other
    /// source-scanning guards in this suite.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    private func source(_ relativePath: String) -> String {
        let url = projectContainerURL().appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Could not read \(url.path) — update this guard's path derivation.")
            return ""
        }
        return text
    }

    /// Comment-stripped and whitespace-normalised, for the guards that pin what
    /// STANDS NEXT TO what: a wrapped call, a one-line call and a re-flowed
    /// comment have to read identically, or these assertions fail on formatting
    /// rather than on the mutation they exist to catch.
    static func normalisedCode(_ text: String) -> String {
        RefusalLaneSource.stripComments(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func recordingServiceSource() -> String {
        source("Conduck/CarPlay/CarPlayRecordingService.swift")
    }

    private func detectorSource() -> String {
        source("Conduck/CarPlay/EndOfSpeechDetector.swift")
    }

    private func sceneDelegateSource() -> String {
        source("Conduck/CarPlay/CarPlaySceneDelegate.swift")
    }

    /// The English `stringUnit` value for `key`, or a failure naming the shape
    /// that broke. Values, not keys, are what the driver hears read back.
    private func englishValue(of key: String, in catalog: [String: Any]) throws -> String {
        let entry = try XCTUnwrap(catalog[key] as? [String: Any], "\(key) is not in the catalog")
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "\(key) has no localizations")
        let english = try XCTUnwrap(localizations["en"] as? [String: Any], "\(key) has no English")
        let unit = try XCTUnwrap(english["stringUnit"] as? [String: Any], "\(key) has no English stringUnit")
        return try XCTUnwrap(unit["value"] as? String, "\(key) has no English value")
    }

    private func stringCatalog() throws -> [String: Any] {
        let url = projectContainerURL().appendingPathComponent("Conduck/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: Any])
    }

    /// The brace-matched arm opened by `opening` (which must end in its `{`).
    ///
    /// Needed wherever two arms of the same function run the same cleanup: a
    /// scan of the span that contains both is satisfied by either, so deleting
    /// one is invisible. Scoping the assertion to ONE arm is what makes it an
    /// assertion about that arm.
    private func armBody(openedBy opening: String, in code: String) throws -> String {
        let start = try XCTUnwrap(
            code.range(of: opening),
            "`\(opening)` is gone — this guard needs updating alongside whatever replaced it"
        )
        var index = start.upperBound
        var depth = 1
        while index < code.endIndex, depth > 0 {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" { depth -= 1 }
            if depth == 0 { return String(code[start.upperBound..<index]) }
            index = code.index(after: index)
        }
        XCTFail("Unbalanced braces after \(opening)")
        return ""
    }

    /// The body of a function, brace-matched from its signature. Returns the
    /// text between the opening and closing brace so an ordering assertion
    /// cannot be satisfied by a line somewhere else in the file.
    private func functionBody(_ signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: signature),
            "\(signature) is gone — this guard needs updating alongside whatever replaced it"
        )
        var depth = 0
        var index = start.upperBound
        var bodyStart: String.Index?
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
                if depth == 1 { bodyStart = source.index(after: index) }
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let opening = try XCTUnwrap(bodyStart)
                    return String(source[opening..<index])
                }
            }
            index = source.index(after: index)
        }
        XCTFail("Unbalanced braces after \(signature)")
        return ""
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTKeyBlackoutLaneTests.swift
//
// Every lane that can refuse a capture because the speech-to-text API key
// "isn't there" must first establish WHICH of the two facts it is looking at,
// and the two must not produce the same sentence. Where the lane has a retry
// mechanism at all, they must not produce the same fate for the user's words
// either — CarPlay is the one registered lane with none, and its row says so
// rather than implying a preservation it cannot perform.
//
// THE DEFECT. `SettingsManager.activeSTTSnapshot()` hands back
// `apiKey: String?`, and that nil collapses "the slot is empty" into "the
// Keychain could not answer". Keys are stored
// `kSecAttrAccessibleAfterFirstUnlock`, so on a device that has rebooted and
// not yet been unlocked every slot reads back exactly as an empty one. Six
// lanes treated that nil as proof of absence and raised code 23, whose copy
// asserts the user has no key — false on a correctly configured device — and
// on the wrist and the menu bar the recording was destroyed on the way out.
// That is both locked invariants at once: I3 (an unreadable slot is never
// proof of absence) and I6 (a refusal after the user has spoken leaves the
// words in the retry lane).
//
// WHAT THIS FILE PINS
//
//   1. The TAXONOMY FACTS the six fixes lean on. Every lane's preservation
//      decision is delegated to `AppError`: `shouldPreserveForRetry` is what
//      puts the bytes in `PendingRetryStore` on iPhone and macOS, and
//      `isRetryable` is what steers the wrist away from its capture-deleting
//      branch. Flip either flag and all six lanes silently start destroying
//      recordings again, with no other test noticing.
//   2. The RELAY VERDICT CACHE — a real behavioural check on the one pure
//      function in this chain that the iOS suite can drive. A blackout the
//      iPhone reports to the Watch must NOT be memoized, or every re-fire of
//      that requestID replays the outage instead of transcribing.
//   3. A SOURCE DRIFT GUARD over all six lanes. None of them is reachable
//      from this suite: two are App Intents, one is `#if os(macOS)`, one is a
//      SwiftUI view method, and two are in a separate watchOS target. The
//      property being checked is also about how the code is WRITTEN — that the
//      verdict comes from a typed read and that BOTH arms exist — which is
//      exactly the shape that drifts, because a lane missing the second arm
//      compiles, reads as ordinary key plumbing in a diff, and fails only on a
//      rebooted device.
//   4. A NEGATIVE CONTROL for the guard, driven over synthetic sources in the
//      old collapsed shape and the new typed one.
//   5. An EXHAUSTIVENESS rule: a file that RAISES code 23 and is not
//      registered here fails the suite, so a further lane cannot join silently.
//      "Raises" covers the enum TOKENS and the hand-rolled absence COPY,
//      because a lane can assert an empty slot without ever touching
//      `AppError` — CarPlay spoke the claim aloud out of a `String(localized:)`
//      and was invisible to a token-only rule for exactly that reason.
//
// `RefusalLaneSource` (comment stripping, function-body scoping, container
// path) is shared with `HeadlessRefusalLaneDriftGuardTests` — the sibling guard
// over the destination question, which drifted the same way for the same
// reason.

import XCTest
@testable import Conduck

final class STTKeyBlackoutLaneTests: XCTestCase {

    // MARK: - 1. The taxonomy facts every lane delegates to

    /// Code 75 must PRESERVE and must RETRY. Neither flag is decoration: they
    /// are the whole of what makes the six lanes non-destructive, because each
    /// one asks `AppError` rather than deciding for itself.
    ///
    ///   `shouldPreserveForRetry` → `InAppAudioRecorder.preserveForRetry` and
    ///   `DictationService.preserveForRetry` no-op unless it is true, so a
    ///   false here deletes the capture on both surfaces.
    ///
    ///   `isRetryable` → `WatchRecordingService.runSTTUpload` deletes the
    ///   recording (`cleanupRecordingFile()`) on every NON-retryable verdict,
    ///   and `AppleSpeechRelayCoordinator.shouldCacheVerdict` memoizes on the
    ///   same flag. A false here both destroys the wrist capture and freezes
    ///   the blackout verdict for that requestID.
    func testCode75PreservesTheRecordingAndKeepsRetryAlive() {
        XCTAssertTrue(AppError.sttKeyUnreadable.shouldPreserveForRetry,
                      "A Keychain blackout leaves bit-for-bit valid audio and a fix that is an unlock, not a "
                      + "re-record. False here makes every fixed lane destroy the capture again (I6).")
        XCTAssertTrue(AppError.sttKeyUnreadable.isRetryable,
                      "The identical bytes succeed once the device is unlocked, and code 75's own copy tells "
                      + "the user to try again — withholding retry would deny the means to obey it.")
        XCTAssertEqual(AppError.sttKeyUnreadable.maxAttempts, 1,
                       "Retryable is not auto-retried: nothing may spin against a locked Keychain. The retry "
                       + "is the user's own tap.")
    }

    /// The contrast, and why 23 could not simply be reused: its copy asserts
    /// absence, and it is terminal. Both are correct for a genuinely empty
    /// slot and both are wrong for a blackout — which is the entire reason a
    /// second code exists.
    func testCode23StaysTerminalAndKeepsSayingTheSlotIsEmpty() throws {
        XCTAssertFalse(AppError.sttMissingAPIKey.shouldPreserveForRetry,
                       "An empty slot fails identically on a second attempt; parking audio for it would "
                       + "occupy the store's single slot with a capture that cannot succeed.")
        XCTAssertFalse(AppError.sttMissingAPIKey.isRetryable)
        let absence = try XCTUnwrap(AppError.sttMissingAPIKey.errorDescription)
        XCTAssertTrue(absence.contains("No STT API key set"),
                      "23's copy makes a claim ABOUT THE SLOT. That claim is what may not be shown on a "
                      + "device whose key merely could not be read.")
        let blackout = try XCTUnwrap(AppError.sttKeyUnreadable.errorDescription)
        XCTAssertFalse(blackout.contains("No STT API key set"),
                       "75 must never assert absence — it is raised precisely when absence is unproven.")
        XCTAssertNotEqual(absence, blackout,
                          "Two readings, two sentences. Identical copy would make the whole distinction "
                          + "invisible to the user it exists for.")
    }

    /// The wrist rebuilds a relayed verdict from a BARE integer
    /// (`AppleSpeechRelayCoordinator` ships `result.errorCode`, the watch calls
    /// `AppError.from(errorCode:)`), so the blackout distinction only survives
    /// the relay wire if 75 round-trips.
    func testCode75SurvivesTheRelayWireAsItself() {
        XCTAssertEqual(AppError.sttKeyUnreadable.errorCode, 75)
        XCTAssertEqual(AppError.from(errorCode: 75, message: nil).errorCode, 75,
                       "A verdict that decayed to the 99 catch-all on the way to the wrist would arrive "
                       + "terminal, and the wrist deletes the queued audio on a terminal verdict.")
        XCTAssertTrue(AppError.from(errorCode: 75, message: nil).isRetryable,
                      "The REBUILT error is what the watch branches on — its flags, not the phone's.")
    }

    // MARK: - 2. The relay verdict cache (behavioural)

    #if os(iOS)
    /// The iPhone side of a wrist relay memoizes SETTLED verdicts only, keyed
    /// on `isRetryable`. A blackout is not settled: the phone's Keychain
    /// unlocks, and the very next re-fire of the same requestID can transcribe
    /// for real. Caching it would poison that requestID until process death
    /// AND block the head of the wrist's drain queue behind it.
    @MainActor
    func testABlackoutVerdictIsNotMemoizedForTheWrist() {
        XCTAssertFalse(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .sttKeyUnreadable),
                       "A blackout must stay un-cached, or the wrist's re-fire replays the outage instead "
                       + "of reaching the now-unlocked Keychain.")
        XCTAssertTrue(AppleSpeechRelayCoordinator.shouldCacheVerdict(for: .sttMissingAPIKey),
                       "An empty slot IS settled — replaying it is pure savings, and this contrast is what "
                       + "shows the assertion above is not vacuous.")
    }
    #endif

    // MARK: - 3. The source drift guard

    /// One lane: a function that must reach its key verdict through a typed
    /// read and carry BOTH arms.
    private struct Lane {
        /// Path relative to the project container (`.../Conduck/Conduck`).
        let path: String
        /// The function whose body is scoped — an unscoped `contains` over a
        /// 1,500-line file is satisfied by any unrelated statement in it.
        let function: String
        /// The typed read this lane resolves its verdict through.
        let typedRead: String
        /// The provable-absence arm. Its copy is true, so it keeps code 23.
        let absenceArm: String
        /// The blackout arm. MUST be distinct from `absenceArm`.
        let blackoutArm: String
        /// Present when this lane refuses AFTER the microphone and therefore
        /// owes the words a retry lane: the token that hands them to it.
        let preservation: String?
        /// Why this lane is on the list.
        let note: String
    }

    private static let lanes: [Lane] = [
        // The wrist's own cloud upload — the priority lane. `setAPIKey`'s
        // comment names the ControlWidget cold launch as the reason the key is
        // readable before unlock, so the blackout window here is the DESIGNED
        // case, not a hypothetical. Code 23 is terminal on this lane, and
        // terminal means `cleanupRecordingFile()`.
        Lane(path: "ConduckWatch Watch App/Services/WatchNetworkClient.swift",
             function: "uploadSTT",
             typedRead: "WatchIdentityResolver.sttAPIKeyReadResult",
             absenceArm: "throw AppError.sttMissingAPIKey",
             blackoutArm: "throw AppError.sttKeyUnreadable",
             preservation: nil,   // the caller owns the audio; 75's retryability is what spares it
             note: "wrist foreground STT"),
        // The background daemon fallback, which re-reads the same slot.
        Lane(path: "ConduckWatch Watch App/Services/WatchAudioUploader.swift",
             function: "uploadSTT",
             typedRead: "WatchIdentityResolver.sttAPIKeyReadResult",
             absenceArm: "throw AppError.sttMissingAPIKey",
             blackoutArm: "throw AppError.sttKeyUnreadable",
             preservation: nil,
             note: "wrist background STT"),
        // iPhone side of a wrist relay, custom-endpoint arm. The words were
        // spoken on the WATCH; the refusal travels back as a bare code.
        Lane(path: "Conduck/Services/AppleSpeechRelayCoordinator.swift",
             function: "transcribeViaCustomEndpoint",
             typedRead: "STTKeyReadiness.resolve",
             absenceArm: "throw AppError.sttMissingAPIKey",
             blackoutArm: "throw AppError.sttKeyUnreadable",
             preservation: nil,
             note: "relay → BYO custom endpoint"),
        // Same relay, the unstamped active-provider arm.
        Lane(path: "Conduck/Services/AppleSpeechRelayCoordinator.swift",
             function: "transcribeWithActiveProvider",
             typedRead: "STTKeyReadiness.resolve",
             absenceArm: "throw AppError.sttMissingAPIKey",
             blackoutArm: "throw AppError.sttKeyUnreadable",
             preservation: nil,
             note: "relay → iPhone's active cloud provider"),
        // In-app composer mic. The user has spoken, so the blackout arm owes
        // the bytes to `PendingRetryStore`.
        Lane(path: "Conduck/Services/InAppAudioRecorder.swift",
             function: "finishAndUpload",
             typedRead: "STTKeyReadiness.resolve",
             absenceArm: ".sttMissingAPIKey",
             blackoutArm: ".sttKeyUnreadable",
             preservation: "preserveForRetry(",
             note: "iOS in-app composer capture"),
        // macOS menu bar, first attempt. Same debt.
        Lane(path: "Conduck/MenuBar/DictationService.swift",
             function: "processAudio",
             typedRead: "STTKeyReadiness.resolve",
             absenceArm: ".sttMissingAPIKey",
             blackoutArm: ".sttKeyUnreadable",
             preservation: "preserveForRetry(",
             note: "macOS menu-bar capture"),
        // macOS menu bar, the RETRY of an already-preserved capture: the store
        // already holds the words, so preservation is not this lane's job —
        // keeping the retry affordance alive is.
        Lane(path: "Conduck/MenuBar/DictationService.swift",
             function: "retryLast",
             typedRead: "STTKeyReadiness.resolve",
             absenceArm: ".sttMissingAPIKey",
             blackoutArm: ".sttKeyUnreadable",
             preservation: nil,
             note: "macOS retry of a preserved capture"),
        // The iOS retry card. Same shape: the store already holds the words,
        // and the card's sentence is the whole surface.
        Lane(path: "Conduck/ContentView.swift",
             function: "runPendingRetry",
             typedRead: "STTKeyReadiness.resolve",
             absenceArm: "No STT API key set",
             blackoutArm: ".sttKeyUnreadable",
             preservation: nil,
             note: "iOS retry card"),
        // CarPlay, and the one lane with NO retry mechanism of any kind. The
        // refusal is SPOKEN and it lands after the microphone: the on-disk
        // recording is deleted at the top of `processRecording`, the compressed
        // bytes live only in memory, and this surface has no `PendingRetryStore`
        // write and no queue to hand them to. `preservation` is therefore nil
        // because there is nothing to hand them TO, not because the lane refuses
        // before the mic — a known architectural gap, recorded here rather than
        // papered over. What this row pins is the half that is fixable: which
        // fact the refusal claims, and that the driver hears something true.
        //
        // It also reaches its verdict LIVE rather than from `CarPlaySettings`'s
        // process-lifetime cache, which is what stops a nil cached at launch —
        // before first unlock, when every slot reads empty — from telling the
        // driver they have no key for the rest of the drive.
        Lane(path: "Conduck/CarPlay/CarPlayRecordingService.swift",
             function: "processRecording",
             typedRead: "STTKeyReadiness.resolve",
             absenceArm: "Add your STT key",
             blackoutArm: "Unlock your iPhone and try again",
             preservation: nil,
             note: "CarPlay in-car capture"),
    ]

    /// Every lane resolves through a typed read and carries both arms, and the
    /// typed read comes FIRST — a refusal decided before the read would make
    /// the read decoration.
    func testEveryKeyRefusalLaneReadsTypedAndCarriesBothArms() throws {
        for lane in Self.lanes {
            let label = "\(lane.path) → \(lane.function) (\(lane.note))"
            let source = try RefusalLaneSource.source(at: lane.path)
            let body = try RefusalLaneSource.body(ofFunction: lane.function, in: source, path: lane.path)

            let readAt = try XCTUnwrap(
                body.range(of: lane.typedRead)?.lowerBound,
                "\(label) no longer reaches its verdict through `\(lane.typedRead)`. A collapsed "
                + "`snapshot.apiKey == nil` cannot tell an empty slot from a locked Keychain, so it "
                + "refuses a correctly configured device and says something false about why (I3).")
            let blackoutAt = try XCTUnwrap(
                body.range(of: lane.blackoutArm)?.lowerBound,
                "\(label) has no blackout arm. Without `\(lane.blackoutArm)` the unreadable reading falls "
                + "back onto code 23, whose copy asserts the user has no key.")
            XCTAssertNotNil(body.range(of: lane.absenceArm),
                            "\(label) lost its provable-absence arm (`\(lane.absenceArm)`). Code 23's copy "
                            + "is TRUE for an empty slot — the fix was never to stop saying it.")
            XCTAssertNotEqual(lane.absenceArm, lane.blackoutArm,
                              "\(label): the two readings must be spelled differently, or this row asserts "
                              + "nothing.")
            XCTAssertLessThan(readAt, blackoutAt,
                              "\(label) decides before it reads. The typed read has to precede the arm it "
                              + "selects.")

            if let preservation = lane.preservation {
                XCTAssertNotNil(body.range(of: preservation),
                                "\(label) refuses after the user has spoken and no longer hands the bytes to "
                                + "`\(preservation)`. A capture refused post-microphone must survive into "
                                + "the retry lane (I6).")
            }
        }
        XCTAssertEqual(Self.lanes.count, 9, "Nine registered lanes; the loop must have walked all of them.")
    }

    /// The wrist relay leg is the one lane whose words live in a DURABLE QUEUE
    /// rather than a file handle, and its generic error arm claims that entry —
    /// which deletes the queued audio. A blackout therefore has to take the
    /// DEFERRAL shape (leave it queued for a later drain) rather than the claim
    /// shape, and the deferral flag is what tells the two apart: a claim arm
    /// never sets it.
    func testTheWristRelayDefersABlackoutInsteadOfClaimingTheQueueEntry() throws {
        let path = "ConduckWatch Watch App/Services/WatchRecordingService.swift"
        let source = try RefusalLaneSource.source(at: path)
        let body = try RefusalLaneSource.body(ofFunction: "runRelay", in: source, path: path)

        let blackoutAt = try XCTUnwrap(
            body.range(of: "case .sttKeyUnreadable = appError")?.lowerBound,
            "`runRelay` no longer recognises a blackout, so it falls to the generic arm — which claims the "
            + "queue entry and deletes the audio the user spoke on their wrist (I6).")
        // Anchored on the GENERIC arm's own log line, not on the first
        // `claimEntry` in the function: the SUCCESS path claims too (that is
        // exactly-once dispatch, and correct), so a bare first-occurrence check
        // measures the wrong claim.
        let genericArmAt = try XCTUnwrap(
            body.range(of: "stt.prep.failed")?.lowerBound,
            "`runRelay`'s catch-all arm no longer logs `stt.prep.failed` — re-anchor this check on whatever "
            + "marks the arm that claims and surfaces a permanent verdict.")
        XCTAssertLessThan(blackoutAt, genericArmAt,
                          "The blackout arm must return BEFORE the catch-all arm, whose claim deletes the "
                          + "queued recording.")

        // …and the sentence it shows is the RELAY leg's own, not the shared one.
        // `terminalSTTMessage` renders code 75's copy, which says "this device" —
        // and on the wrist that device is the watch, which the user has just
        // recorded on and which is therefore unlocked. The Keychain that blacked
        // out on this leg is the iPHONE's, so a wrist sent to unlock itself does
        // the one thing that cannot help, once per idle-edge re-fire.
        let armEnd = try XCTUnwrap(
            body.range(of: "return", range: blackoutAt..<body.endIndex)?.upperBound,
            "The blackout arm no longer returns; re-scope this check.")
        let blackoutArm = String(body[blackoutAt..<armEnd])
        XCTAssertTrue(blackoutArm.contains("relayKeyUnreadableMessage"),
                      "The relay blackout arm must take its own wrist sentence, which names the iPHONE.")
        XCTAssertFalse(blackoutArm.contains("terminalSTTMessage"),
                       "`terminalSTTMessage` serves the UPLOAD leg, where the unreadable slot is this "
                       + "watch's own. On the relay leg its 'this device' names the wrong device.")
        XCTAssertEqual(body.components(separatedBy: "lastErrorIsRelayDeferral = true").count - 1, 2,
                       "Exactly two deferral arms: the reply-wait timeout and the blackout. A blackout that "
                       + "stopped setting the flag has taken the claim shape instead — or its toast will "
                       + "outlive the transcript that eventually lands.")
    }

    // MARK: - 4. The negative control

    /// The guard must genuinely fail on the shape that shipped, or it is an
    /// assertion nobody has seen bite. Both halves are asserted: the old
    /// collapsed form fails, the typed form passes.
    func testTheGuardDistinguishesTheCollapsedShapeFromTheTypedOne() throws {
        let collapsed = """
        func finishAndUpload() async -> Result<String, AppError> {
            let snapshot = await SettingsManager.shared.activeSTTSnapshot()
            if let key = snapshot.apiKey, !key.isEmpty { apiKey = key } else {
                state = .error(.sttMissingAPIKey)
                return .failure(.sttMissingAPIKey)
            }
        }
        """
        let typed = """
        func finishAndUpload() async -> Result<String, AppError> {
            let snapshot = await SettingsManager.shared.activeSTTSnapshot()
            switch await STTKeyReadiness.resolve(presetID: snapshot.presetID, snapshotKey: snapshot.apiKey) {
            case .ready(let key): apiKey = key
            case .notConfigured: return .failure(.sttMissingAPIKey)
            case .unreadable:
                await preserveForRetry(error: .sttKeyUnreadable)
                return .failure(.sttKeyUnreadable)
            }
        }
        """
        let old = try RefusalLaneSource.body(ofFunction: "finishAndUpload", in: collapsed, path: "<synthetic>")
        XCTAssertNil(old.range(of: "STTKeyReadiness.resolve"),
                     "Control: the shipped collapsed shape must FAIL the typed-read check.")
        XCTAssertNil(old.range(of: ".sttKeyUnreadable"),
                     "Control: it must also fail the blackout-arm check — one nil arm, both readings.")
        XCTAssertNil(old.range(of: "preserveForRetry("),
                     "Control: and the preservation check, which is how the recording was lost.")

        let new = try RefusalLaneSource.body(ofFunction: "finishAndUpload", in: typed, path: "<synthetic>")
        let readAt = try XCTUnwrap(new.range(of: "STTKeyReadiness.resolve")?.lowerBound)
        let blackoutAt = try XCTUnwrap(new.range(of: ".sttKeyUnreadable")?.lowerBound)
        XCTAssertLessThan(readAt, blackoutAt, "Control: the compliant shape must pass.")
        XCTAssertNotNil(new.range(of: ".sttMissingAPIKey"))
        XCTAssertNotNil(new.range(of: "preserveForRetry("))
    }

    /// Comment stripping is load-bearing here for the same reason it is in the
    /// sibling guard: every one of these files now DISCUSSES the two readings
    /// at length, and prose about the rule must never stand in for the code
    /// that implements it.
    func testCommentStrippingRemovesProseThatWouldSatisfyTheTypedReadCheck() {
        let source = """
        // Resolved through STTKeyReadiness.resolve so .sttKeyUnreadable is distinguishable.
        /* and again: STTKeyReadiness.resolve */
        throw AppError.sttMissingAPIKey
        """
        let stripped = RefusalLaneSource.stripComments(source)
        XCTAssertFalse(stripped.contains("STTKeyReadiness.resolve"),
                       "A header that DESCRIBES the typed read must not satisfy a check on whether the code "
                       + "PERFORMS it.")
        XCTAssertFalse(stripped.contains("sttKeyUnreadable"))
        XCTAssertTrue(stripped.contains("throw AppError.sttMissingAPIKey"))
    }

    // MARK: - 5. Exhaustiveness — a seventh lane cannot join silently

    /// What counts as RAISING code 23 — the enum TOKENS, and the hand-rolled
    /// absence COPY.
    ///
    /// The tokens deliberately exclude the `case .sttMissingAPIKey:` switches
    /// that merely map an existing verdict to copy or a diagnostic row: those
    /// decide nothing about the Keychain and adding one is not a new lane.
    ///
    /// The copy shapes exist because a lane does not need the enum to make the
    /// claim. CarPlay reached its verdict from a collapsed nil and SPOKE code
    /// 23's assertion out of a `String(localized:)`, so every token above walked
    /// straight past it — a refusal that asserts an empty slot in its own words
    /// is still a refusal that asserts an empty slot. Matching the shipped
    /// sentences is narrow, and narrow is the point: it fires on the claim, not
    /// on the subject.
    private static let raiseShapes = [
        "throw AppError.sttMissingAPIKey",
        ".error(.sttMissingAPIKey)",
        ".failure(.sttMissingAPIKey)",
        "= .sttMissingAPIKey",
        "AppError.sttMissingAPIKey.localizedDescription",
        "No STT API key set",
        "Add your STT key",
    ]

    /// Shared by the sweep and its control, so a shape list that stops matching
    /// fails the control rather than quietly reporting a clean sweep. Takes
    /// COMMENT-STRIPPED source: prose about a sentence is not the sentence.
    private static func raisesCode23(inStripped source: String) -> Bool {
        raiseShapes.contains { source.contains($0) }
    }

    /// Any shipping file that RAISES code 23 must be a registered lane (or the
    /// declaration itself).
    func testEveryFileThatRaisesCode23IsARegisteredLane() throws {
        // The lanes above, plus the two the previous round fixed — the bundled
        // Shortcut's pre-flight and GigaAction itself, both pinned in detail by
        // `HeadlessRetryGuardSpanTests` and `STTKeyReadinessTests`.
        let registered = Set(Self.lanes.map(\.path)).union([
            "Conduck/Intents/CheckNetworkIntent.swift",
            "Conduck/Intents/ConverseIntent.swift",
        ])

        let container = RefusalLaneSource.projectContainerURL
        guard let walker = FileManager.default.enumerator(
            at: container, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("Could not enumerate \(container.path) — update this guard's path derivation.")
        }
        var unregistered: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = url.path.replacingOccurrences(of: container.path + "/", with: "")
            guard !path.contains("Tests/") else { continue }
            guard path != "Conduck/Models/AppError.swift" else { continue }
            let source = RefusalLaneSource.stripComments(try String(contentsOf: url, encoding: .utf8))
            guard Self.raisesCode23(inStripped: source) else { continue }
            guard !registered.contains(path) else { continue }
            unregistered.append(path)
        }
        XCTAssertTrue(unregistered.isEmpty,
                      "New site(s) raising code 23 with no row in this guard: \(unregistered). Code 23 "
                      + "asserts the key slot is EMPTY; a lane that raises it from a collapsed nil says "
                      + "that on a device whose Keychain is merely locked — whether it raises the enum or "
                      + "just speaks the sentence. Register the lane and give it a blackout arm.")

        for path in registered {
            XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent(path).path),
                          "Registered path \(path) no longer exists — a stale row exempts nothing and hides "
                          + "a lane that moved.")
        }
    }

    /// The exhaustiveness rule's control, driven through the SAME matcher the
    /// sweep uses. Three halves, and all three are load-bearing:
    ///
    ///   • the hand-rolled spoken refusal must be CAUGHT — it is the shape that
    ///     hid an eighth lane behind a token-only rule;
    ///   • a switch that merely maps an existing verdict to copy must NOT be —
    ///     widening into those would flag half the app and the rule would be
    ///     turned off;
    ///   • prose ABOUT the sentence must not stand in for the sentence.
    func testTheRaiseShapesSeeAHandRolledRefusalAndStillIgnoreAMapping() {
        let handRolled = """
        if let key = cachedKey, !key.isEmpty { apiKey = key } else {
            endSession(speak: String(localized: "Add your STT key in Conduck on your iPhone."))
            return
        }
        """
        let tokensOnly = [
            "throw AppError.sttMissingAPIKey",
            ".error(.sttMissingAPIKey)",
            ".failure(.sttMissingAPIKey)",
            "= .sttMissingAPIKey",
            "AppError.sttMissingAPIKey.localizedDescription",
        ]
        XCTAssertFalse(tokensOnly.contains { handRolled.contains($0) },
                       "Control: the shape that shipped names no `AppError` at all, which is exactly why a "
                       + "token-only rule reported a clean sweep while a lane spoke code 23's claim aloud.")
        XCTAssertTrue(Self.raisesCode23(inStripped: handRolled),
                      "The widened shapes must catch a hand-rolled absence sentence, or the same lane hides "
                      + "again behind the same trick.")

        let mapsAnExistingVerdict = """
        switch error {
        case .sttMissingAPIKey:
            phrase = fallbackPhrase
        case .sttAuthFailed:
            phrase = rejectedPhrase
        }
        """
        XCTAssertFalse(Self.raisesCode23(inStripped: mapsAnExistingVerdict),
                       "Control: a mapping decides nothing about the Keychain. A rule that flagged these "
                       + "would fire everywhere and stop being read.")

        let prose = RefusalLaneSource.stripComments("""
        // Speaks "Add your STT key in Conduck on your iPhone." when the slot is provably empty.
        apiKey = key
        """)
        XCTAssertFalse(Self.raisesCode23(inStripped: prose),
                       "Control: a header that DESCRIBES the sentence must not register as a lane that "
                       + "says it.")
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayWorkNoteTests.swift
//
// The CarPlay "Add to Work" lane, asserted where it can be asserted without a
// head unit: the two pure decisions it makes, and the SHAPE of the code that
// makes the rest.
//
// A CarPlay session cannot be driven from a unit test — it owns an audio
// engine, a `CPVoiceControlTemplate` and a live route — so the parts that
// matter are extracted as pure functions and the rest is pinned by reading the
// source, the way every other guard in this bundle reads it
// (`RefusalLaneSource`, comments stripped so a wrapped call and a one-line call
// read identically).
//
// Four things are pinned, and each one held, or would have held, a real defect:
//
// (1) THE ROW BUDGET. `CPListTemplate.maximumItemCount` is a ceiling the
//     framework enforces by TRUNCATING. "Add to Work" is a permanent row in the
//     first section, so a budget that does not pay for it silently costs the
//     oldest conversation instead — a loss that appears in no diff.
// (2) THE DESTINATION DEFAULT. A Work note that left `sessionDestination` set
//     would aim the NEXT session — started from "New voice chat" — at the desk,
//     and a conversation the driver expects an answer to would become a silent
//     note. `.chat` is the value that must be reached by falling back, and
//     `.work` the one that must be asked for.
// (3) THE SPOKEN ACKNOWLEDGEMENT. It is HEARD once, at speed, by somebody who
//     cannot re-read it, so it has to be true of exactly the state it names —
//     and the three states have to sound different, or a driver whose words did
//     not land has no way to know they need to open the phone.
// (4) THE FORK ITSELF. Nothing on the Work lane may reach a gateway
//     (`startConverseHop`) or re-arm the microphone (`handleEmptyTurn`), the
//     recording must be durable BEFORE the speech hop, and the queue entry may
//     be released only when the words actually landed.

import XCTest
@testable import Conduck

// CarPlay is an iOS-only framework and both files under test are `#if os(iOS)`,
// so the whole case is — exactly as the CarPlay half of
// `HeadlessGatewayPreflightTests` is.
#if os(iOS)

final class CarPlayWorkNoteTests: XCTestCase {

    // MARK: - (1) The picker's row budget

    func testTheWorkRowCostsExactlyOneRecentConversation() {
        // `recentCap` answers the narrower question — what row 0 costs — and is
        // deliberately untouched by this feature. The budget the picker uses is
        // that answer minus the permanent Work row.
        XCTAssertEqual(
            CarPlaySceneDelegate.recentRowBudget(maximumItemCount: 12, showsStartFailureHint: false),
            CarPlayConversationLabel.recentCap(maximumItemCount: 12) - 1,
            "the Work row is permanent, so it is paid for out of the recent list every refresh"
        )
    }

    func testTheStartFailureHintCostsAnotherOneOnTopOfIt() {
        let withoutHint = CarPlaySceneDelegate.recentRowBudget(
            maximumItemCount: 12, showsStartFailureHint: false
        )
        let withHint = CarPlaySceneDelegate.recentRowBudget(
            maximumItemCount: 12, showsStartFailureHint: true
        )
        XCTAssertEqual(withHint, withoutHint - 1,
                       "the one-shot hint occupies a row while it is shown, exactly as it did before")
        XCTAssertEqual(withoutHint, 10)
        XCTAssertEqual(withHint, 9)
    }

    /// The property the arithmetic exists for, stated as the framework states
    /// it: everything the first section draws, plus the recent list, fits.
    func testTheFirstSectionAndTheRecentListAlwaysFitTheTemplateCeiling() {
        for ceiling in 0...16 {
            for hint in [false, true] {
                let recents = CarPlaySceneDelegate.recentRowBudget(
                    maximumItemCount: ceiling, showsStartFailureHint: hint
                )
                // Row 0 ("New voice chat") + the hint while shown + "Add to Work".
                let fixedRows = 1 + (hint ? 1 : 0) + 1
                XCTAssertGreaterThanOrEqual(recents, 0, "a budget is never negative")
                if ceiling >= fixedRows {
                    XCTAssertLessThanOrEqual(
                        fixedRows + recents, ceiling,
                        "ceiling \(ceiling), hint \(hint): the picker would be truncated by CarPlay"
                    )
                }
            }
        }
    }

    func testATinyCeilingRefusesRecentsRatherThanGoingNegative() {
        XCTAssertEqual(CarPlaySceneDelegate.recentRowBudget(maximumItemCount: 2, showsStartFailureHint: false), 0)
        XCTAssertEqual(CarPlaySceneDelegate.recentRowBudget(maximumItemCount: 1, showsStartFailureHint: false), 0)
        XCTAssertEqual(CarPlaySceneDelegate.recentRowBudget(maximumItemCount: 0, showsStartFailureHint: true), 0)
    }

    // MARK: - (2) The destination default

    func testTheSessionDestinationFallsBackToChatAndIsAskedForOnlyByTheWorkRow() throws {
        let source = try Self.recordingServiceSource()

        XCTAssertTrue(
            source.contains("private var sessionDestination: CarPlayCaptureDestination = .chat"),
            "the stored default is the fallback every session starts from"
        )

        let beginSession = try RefusalLaneSource.body(
            ofFunction: "beginSession", in: source, path: Self.recordingServicePath
        )
        XCTAssertTrue(beginSession.contains("sessionDestination = .chat"),
                      "a conversation session states its destination rather than inheriting one")

        let beginWorkNote = try RefusalLaneSource.body(
            ofFunction: "beginWorkNote", in: source, path: Self.recordingServicePath
        )
        XCTAssertTrue(beginWorkNote.contains("sessionDestination = .work"),
                      "`.work` is reached only by the row that asks for it")

        for terminal in ["endSession", "teardown"] {
            let body = try RefusalLaneSource.body(
                ofFunction: terminal, in: source, path: Self.recordingServicePath
            )
            XCTAssertTrue(
                body.contains("sessionDestination = .chat"),
                "\(terminal) must return the destination to the fallback, or a Work note aims the next drive's conversation at the desk"
            )
        }
    }

    func testTheWorkSessionStarterRegistersForNothingAGatewayWouldNeed() throws {
        let source = try Self.recordingServiceSource()
        let body = try RefusalLaneSource.body(
            ofFunction: "beginWorkNote", in: source, path: Self.recordingServicePath
        )
        for forbidden in [
            "setActiveService",         // would let a late reply speak over a private note
            "sessionDefaultRef",
            "sessionConversationID",
            "CarPlayConverseUploader"
        ] {
            XCTAssertFalse(body.contains(forbidden),
                           "`beginWorkNote` must not touch \(forbidden): nothing on this lane is dispatched")
        }
        XCTAssertTrue(body.contains("startListening(isFollowUp: false)"),
                      "it still starts the one listen it exists for")
    }

    // MARK: - (3) The spoken acknowledgement

    func testTheAcknowledgementIsDecidedByPublicationFirstAndWordsSecond() {
        XCTAssertEqual(
            CarPlayRecordingService.workNoteOutcome(recordingPublished: true, transcriptAttached: true),
            .saved
        )
        XCTAssertEqual(
            CarPlayRecordingService.workNoteOutcome(recordingPublished: true, transcriptAttached: false),
            .savedWithoutWords,
            "every refusal below the fork, and an empty transcript, land here"
        )
        XCTAssertEqual(
            CarPlayRecordingService.workNoteOutcome(recordingPublished: false, transcriptAttached: false),
            .notSaved
        )
    }

    /// The pair that cannot happen, pinned because of what it would SAY if it
    /// ever did: words cannot be attached to a recording that was never
    /// published, and a bug that produced that state must not tell the driver
    /// their note is saved.
    func testAnImpossibleStateNeverClaimsTheNoteIsSaved() {
        let outcome = CarPlayRecordingService.workNoteOutcome(
            recordingPublished: false, transcriptAttached: true
        )
        XCTAssertEqual(outcome, .notSaved)
        XCTAssertNotEqual(outcome, .saved)
    }

    func testTheThreeSpokenLinesAreDistinctAndNoneOfThemMentionsSending() {
        let lines = [
            CarPlayRecordingService.workNoteAcknowledgement(for: .saved),
            CarPlayRecordingService.workNoteAcknowledgement(for: .savedWithoutWords),
            CarPlayRecordingService.workNoteAcknowledgement(for: .notSaved)
        ]
        for line in lines {
            XCTAssertFalse(line.isEmpty, "a silent acknowledgement is no acknowledgement")
        }
        XCTAssertEqual(
            Set(lines).count, 3,
            "a driver whose words did not land must not hear what a driver whose words did land hears"
        )
        // Work opens, keeps and removes; it never sends. The desk has no code
        // path to a gateway, so any of these words would describe software that
        // does not exist.
        for line in lines {
            let lowered = line.lowercased()
            for forbidden in ["send", "sent", "dispatch", "draft", "brief", "chat", "conversation"] {
                XCTAssertFalse(lowered.contains(forbidden),
                               "spoken Work copy says “\(forbidden)”: “\(line)”")
            }
        }
    }

    /// Only the outcome that has somewhere to retry FROM may invite one. The
    /// other two would send a driver to a queue that holds nothing.
    func testOnlyTheUnsavedLineInvitesTheDriverBackToThePhoneToRetry() {
        let notSaved = CarPlayRecordingService.workNoteAcknowledgement(for: .notSaved).lowercased()
        XCTAssertTrue(notSaved.contains("retry") || notSaved.contains("try again"),
                      "the queued capture is the only reason this line exists")
        let saved = CarPlayRecordingService.workNoteAcknowledgement(for: .saved).lowercased()
        XCTAssertFalse(saved.contains("retry") || saved.contains("try again"),
                       "nothing is outstanding on a note whose words landed")
    }

    // MARK: - (4) The fork

    /// The invariant the whole slice exists for: the recording is durable, and
    /// on the desk, BEFORE a single word is transcribed.
    func testTheRecordingIsSecuredBeforeTheSpeechHopIsAttempted() throws {
        let source = try Self.recordingServiceSource()
        let body = try RefusalLaneSource.body(
            ofFunction: "processRecording", in: source, path: Self.recordingServicePath
        )
        let fork = try XCTUnwrap(body.range(of: "secureWorkNote("),
                                 "the Work fork is where the recording becomes durable")
        let speech = try XCTUnwrap(body.range(of: "STTClient.shared.transcribe("),
                                   "the speech hop is what the fork sits above")
        XCTAssertTrue(fork.lowerBound < speech.lowerBound,
                      "a refusal from the speech hop must cost the words, never the recording")
    }

    func testTheBytesReachTheQueueBeforeTheContainerFileIsDeletedAndBeforeTheDeskWrite() throws {
        let source = try Self.recordingServiceSource()
        let body = try RefusalLaneSource.body(
            ofFunction: "secureWorkNote", in: source, path: Self.recordingServicePath
        )
        let arm = try XCTUnwrap(body.range(of: "PendingRetryGuard.arm("))
        let deleteContainer = try XCTUnwrap(body.range(of: "removeItem(at: containerURL)"),
                                            "the container file is the only copy until the queue has one")
        let publish = try XCTUnwrap(body.range(of: "WorkVoiceCaptureCoordinator.publishRecording("))
        XCTAssertTrue(arm.lowerBound < deleteContainer.lowerBound,
                      "deleting the recording before it is queued leaves the bytes only in this process")
        XCTAssertTrue(arm.lowerBound < publish.lowerBound,
                      "a desk write that fails must still leave a retryable capture behind")
        XCTAssertTrue(body.contains("sourceDevice: \"carplay\""),
                      "the card remembers the surface the words were spoken at")
        XCTAssertTrue(body.contains("publicationState: .published"),
                      "a recovery cannot tell a refused publication from a deleted card without this verdict")
        XCTAssertTrue(body.contains("publicationState: .phaseOneFailed"),
                      "both verdicts are load-bearing; neither may be dropped")
        XCTAssertTrue(body.contains("requestNotificationAuthorization: false"),
                      "a driver is never asked for notification permission at the wheel")
    }

    func testTheQueueEntryIsReleasedOnlyWhenTheWordsActuallyLanded() throws {
        let source = try Self.recordingServiceSource()
        let body = try RefusalLaneSource.body(
            ofFunction: "attachWorkNoteTranscript", in: source, path: Self.recordingServicePath
        )
        let attached = try XCTUnwrap(body.range(of: "case .attached:"))
        let missing = try XCTUnwrap(body.range(of: "case .recordingMissing, .notAudio:"),
                                    "both non-attaching answers are handled explicitly")
        let disarms = body.components(separatedBy: "PendingRetryGuard.disarm(").count - 1
        XCTAssertEqual(disarms, 1, "exactly one release site, or the rule has two answers")
        let disarm = try XCTUnwrap(body.range(of: "PendingRetryGuard.disarm("))
        XCTAssertTrue(attached.lowerBound < disarm.lowerBound && disarm.lowerBound < missing.lowerBound,
                      "the release belongs to `.attached` alone; a card that is gone is settled on the phone")
    }

    /// The words may only be written while this process still HOLDS the
    /// capture.
    ///
    /// The attach is idempotent for identical words only: the store compares
    /// the stored text and rewrites the row whenever it differs. Lease renewal
    /// is best-effort and the speech hop can outlast the reservation window, so
    /// a lapsed hold can be taken by the phone's retry card — which transcribes
    /// the same bytes and saves its own words on this same card. Writing here
    /// afterwards would overwrite that surface's transcript with this one.
    func testTheWordsAreNotWrittenUnlessThisProcessStillHoldsTheCapture() throws {
        let source = try Self.recordingServiceSource()
        let body = try RefusalLaneSource.body(
            ofFunction: "attachWorkNoteTranscript", in: source, path: Self.recordingServicePath
        )
        let write = try XCTUnwrap(
            body.range(of: "WorkVoiceCaptureCoordinator.attachTranscript("),
            "the desk write is what the ownership question stands in front of"
        )
        let beforeTheWrite = body[..<write.lowerBound]
        XCTAssertTrue(
            beforeTheWrite.contains("PendingRetryGuard.stillOwnsCapture(capture.guardToken)"),
            "the transcript is written without asking whether the capture is still this process's — a retry card that took it has already saved its own words on that card"
        )
        let ownership = try XCTUnwrap(beforeTheWrite.range(of: "PendingRetryGuard.stillOwnsCapture("))
        let staleness = try XCTUnwrap(
            beforeTheWrite.range(of: "isCurrentListen("),
            "the ownership question suspends, so a staleness check has to follow it"
        )
        XCTAssertTrue(
            ownership.lowerBound < staleness.lowerBound,
            "a staleness check that runs before the ownership question does not cover its suspension"
        )
        XCTAssertGreaterThanOrEqual(
            beforeTheWrite.components(separatedBy: "isCurrentListen(").count - 1, 2,
            "both exits from the ownership gate — the refusal and the continuation — end a session that moved on"
        )
        // Refusing ownership writes NOTHING and releases NOTHING: the entry
        // belongs to whichever surface holds it.
        let refusal = beforeTheWrite[ownership.lowerBound...]
        XCTAssertFalse(refusal.contains("PendingRetryGuard.disarm("),
                       "a capture this process no longer owns is not this process's to release")
    }

    /// The compressed scratch copy has exactly one owner at every instant.
    ///
    /// `STTClient.transcribe` deletes it on all of its own exits, so the leak
    /// window is the refusals between the fork and that call — plus every
    /// failed exit inside phase one, where the file exists but no capture is
    /// ever handed back.
    func testTheCompressedScratchCopyIsDeletedOnEveryExitThatNeverReachesTheSpeechHop() throws {
        let source = try Self.recordingServiceSource()

        let secured = try RefusalLaneSource.body(
            ofFunction: "secureWorkNote", in: source, path: Self.recordingServicePath
        )
        let phaseOneDefer = try XCTUnwrap(
            secured.range(of: "defer {"),
            "a per-exit removal would be forgotten by the next refusal added below it"
        )
        let phaseOneRemoval = try XCTUnwrap(
            secured.range(of: "removeItem(at: audioFileURL)"),
            "phase one leaves the scratch file behind on every exit that returns nil"
        )
        XCTAssertTrue(phaseOneDefer.lowerBound < phaseOneRemoval.lowerBound,
                      "the removal is the defer's, so it covers exits that do not exist yet")
        let handOff = try XCTUnwrap(secured.range(of: "handedOff = true"))
        let handBack = try XCTUnwrap(secured.range(of: "return WorkNoteCapture("))
        XCTAssertTrue(handOff.lowerBound < handBack.lowerBound,
                      "the file survives only the exit that hands the capture to the caller")

        let body = try RefusalLaneSource.body(
            ofFunction: "processRecording", in: source, path: Self.recordingServicePath
        )
        XCTAssertTrue(
            body.contains("removeItem(at: workCapture.audioFileURL)"),
            "the refusals between the fork and the speech hop return without deleting the scratch copy"
        )
        let callerDefer = try XCTUnwrap(body.range(of: "if let workCapture, !workUploadHandedToSTT"))
        let callerHandOff = try XCTUnwrap(body.range(of: "workUploadHandedToSTT = true"))
        let speech = try XCTUnwrap(body.range(of: "STTClient.shared.transcribe("))
        XCTAssertTrue(callerDefer.lowerBound < callerHandOff.lowerBound,
                      "the caller's cleanup is armed at the fork, not after the refusals it exists for")
        XCTAssertTrue(callerHandOff.lowerBound < speech.lowerBound,
                      "ownership passes to `transcribe`, which deletes the file on every one of its exits")
        let lastRefusal = try XCTUnwrap(
            body.range(of: "endRefusalBelowFork(", options: .backwards),
            "the refusals below the fork are what the caller's cleanup covers"
        )
        XCTAssertTrue(lastRefusal.lowerBound < callerHandOff.lowerBound,
                      "a refusal that runs after the hand-off would leak the file it no longer owns")
    }

    func testEverySuspensionOnTheWorkLaneIsFollowedByAStalenessCheck() throws {
        let source = try Self.recordingServiceSource()
        for function in ["secureWorkNote", "attachWorkNoteTranscript"] {
            let body = try RefusalLaneSource.body(
                ofFunction: function, in: source, path: Self.recordingServicePath
            )
            let suspensions = body.components(separatedBy: "await ").count - 1
            let checks = body.components(separatedBy: "isCurrentListen(").count - 1
            XCTAssertGreaterThan(suspensions, 0, "\(function) is an async lane; the scan is broken otherwise")
            XCTAssertGreaterThanOrEqual(
                checks, 2,
                "\(function) resumes after \(suspensions) suspensions with only \(checks) staleness checks — a session that ended under one of them would be spoken to"
            )
        }
    }

    /// Nothing on the desk reaches a gateway. The two Work-only functions are
    /// scanned wholesale; `processRecording` is shared, so its two gateway-side
    /// calls are checked for a fork test standing in front of them instead.
    func testTheWorkLaneReachesNoGatewayAndNeverReArmsTheMicrophone() throws {
        let source = try Self.recordingServiceSource()
        let forbidden = [
            "startConverseHop",
            "startDeferredConverseHop",
            "handleQuickSend",
            "handleEmptyTurn",
            "speakThenRearm",
            "reArmAfterSettle",
            "speakErrorAndEnd"
        ]
        for function in ["secureWorkNote", "attachWorkNoteTranscript", "endRefusalBelowFork"] {
            let body = try RefusalLaneSource.body(
                ofFunction: function, in: source, path: Self.recordingServicePath
            )
            for token in forbidden {
                XCTAssertFalse(body.contains(token),
                               "\(function) reaches `\(token)` — a Work note is one-shot and reaches nothing")
            }
        }
    }

    /// The shared body's two lane-specific exits. Each must sit behind a test of
    /// the fork's verdict, or a Work note would re-arm the microphone or be
    /// dispatched to an AI.
    func testTheSharedBodysGatewayAndReArmExitsSitBehindAForkTest() throws {
        let source = try Self.recordingServiceSource()
        let body = try RefusalLaneSource.body(
            ofFunction: "processRecording", in: source, path: Self.recordingServicePath
        )
        // Comment stripping leaves blank lines behind, so the window counts
        // lines that still carry code — a window measured in raw lines would
        // grow and shrink with the prose around it.
        let lines = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var guarded = 0
        for (index, line) in lines.enumerated()
        where line.contains("handleEmptyTurn(") || line.contains("startConverseHop(") {
            let window = lines[max(0, index - 10)..<index]
            XCTAssertTrue(
                window.contains(where: { $0.contains("workCapture") }),
                "`\(line)` is reachable without testing the Work fork first"
            )
            guarded += 1
        }
        // Non-vacuity: a rename that hid both call sites would otherwise pass
        // this by asserting nothing at all.
        XCTAssertGreaterThanOrEqual(
            guarded, 3,
            "found \(guarded) chat-lane exits in `processRecording`; the scanner is probably broken"
        )
    }

    // MARK: - The scene's Work row

    func testTheWorkRowStartsASessionWithNoGatewayPreFlightAndKeepsTheAudioRaceContract() throws {
        let source = try Self.sceneDelegateSource()
        let body = try RefusalLaneSource.body(
            ofFunction: "startWorkNote", in: source, path: Self.sceneDelegatePath
        )
        for forbidden in ["newChatPlan", "effectiveCarPlayRef", "sessionDefaultRefOverride",
                          "newChatPickerSnapshot", "presentGatewayChooser", "fetchConversation"] {
            XCTAssertFalse(body.contains(forbidden),
                           "`startWorkNote` runs \(forbidden): Work needs no gateway, so nothing about one may refuse it")
        }
        let present = try XCTUnwrap(body.range(of: "ensureVoicePresented("),
                                    "the voice template is presented modally, as every session is")
        let begin = try XCTUnwrap(body.range(of: "beginWorkNote()"))
        XCTAssertTrue(present.lowerBound < begin.lowerBound,
                      "g1: the engine starts INSIDE the present completion, never before it")
    }

    func testTheWorkRowIsOfferedInBothPickerStatesAndTheDeskIsNeverBrowsed() throws {
        let source = try Self.sceneDelegateSource()
        let picker = try RefusalLaneSource.body(
            ofFunction: "refreshPicker", in: source, path: Self.sceneDelegatePath
        )
        let offers = picker.components(separatedBy: "makeWorkNoteItem(").count - 1
        XCTAssertEqual(
            offers, 2,
            "the row belongs in the configured picker AND in the no-gateway state, where it is the only working row"
        )
        // A Work CARD on a car screen is content, which the
        // voice-based-conversation entitlement forbids. The row records; it
        // never lists.
        for forbidden in ["WorkMaterial", "workboardViewModel", "loadWorkMaterial", "fetchWorkboard"] {
            XCTAssertFalse(source.contains(forbidden),
                           "the CarPlay scene reads \(forbidden): the desk is never browsed at the wheel")
        }
    }

    /// A start failure ends the session silently — no TTS over a wedged
    /// session, no `CPAlertTemplate` racing the modal dismiss — so the hint row
    /// is the ONLY feedback it gets. The no-gateway picker became startable
    /// when "Add to Work" was added to it, so it needs the row too, and with
    /// the sentence that names the row it actually draws.
    func testTheMicCouldNotStartHintIsRenderedInTheNoGatewayPickerToo() throws {
        let source = try Self.sceneDelegateSource()
        let picker = try RefusalLaneSource.body(
            ofFunction: "refreshPicker", in: source, path: Self.sceneDelegatePath
        )
        XCTAssertEqual(
            picker.components(separatedBy: "carplay.hint.captureStartFailed.title").count - 1, 2,
            "the hint belongs in BOTH picker states; the one that offers only Work is where a silent failure is least explicable"
        )

        // Scoped to the no-gateway branch itself — the branch runs from the
        // emptiness test to its `return`, which the roster fetch below it
        // marks. A hint rendered only in the configured branch would pass a
        // whole-function count.
        let branch = try XCTUnwrap(picker.range(of: "configuredRefs.isEmpty"))
        let configured = try XCTUnwrap(
            picker.range(of: "gatewayBadgeRoster("),
            "the first statement after the no-gateway branch returns"
        )
        let noGateway = picker[branch.upperBound..<configured.lowerBound]
        XCTAssertTrue(noGateway.contains("oneShotStartFailureHint"),
                      "the no-gateway picker never asks whether the microphone failed, so it shows nothing when it did")
        XCTAssertTrue(
            noGateway.contains("carplay.hint.captureStartFailed.detail.work"),
            "this state draws no “New voice chat” row, so the shared retry sentence would point at a row that is not there"
        )
        XCTAssertTrue(noGateway.contains("makeWorkNoteItem("),
                      "the row the hint tells the driver to tap has to be the row this state offers")
        // The budget: this state draws a fixed three rows at most (hint, setup
        // hint, Work) and no recent list, so there is nothing for the hint's row
        // to be priced out of — `recentRowBudget` pays for it in the branch that
        // does draw recents.
        XCTAssertFalse(noGateway.contains("fetchRecentForPicker"),
                       "a recent list here would need the hint priced into its own budget")
    }

    // MARK: - Source access

    private static let recordingServicePath = "Conduck/CarPlay/CarPlayRecordingService.swift"
    private static let sceneDelegatePath = "Conduck/CarPlay/CarPlaySceneDelegate.swift"

    private static func recordingServiceSource() throws -> String {
        try RefusalLaneSource.source(at: recordingServicePath)
    }

    private static func sceneDelegateSource() throws -> String {
        try RefusalLaneSource.source(at: sceneDelegatePath)
    }
}

#endif

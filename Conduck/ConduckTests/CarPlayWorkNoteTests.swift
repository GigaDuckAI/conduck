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

import Observation
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

    /// The words are PARKED on the queue entry first, and only then written to
    /// the card — and only while this process still HOLDS the capture.
    ///
    /// Two rules in one order, because the order is the whole point.
    ///
    /// Parking first: `attachTranscript` can throw, or find the card gone,
    /// after recognition already succeeded. Without the parking the transcript
    /// exists only in this process, so the phone's retry has to buy the same
    /// words again — and a kill during the attach loses them outright. The
    /// parking's own result is deliberately unused: it answers false both for
    /// an overtaken claim and for an arm that preserved nothing, which need
    /// opposite answers.
    ///
    /// Ownership after it: the attach is idempotent for identical words only —
    /// the store compares the stored text and rewrites the row whenever it
    /// differs. Lease renewal is best-effort and the speech hop can outlast the
    /// reservation window, so a lapsed hold can be taken by the phone's retry
    /// card, which transcribes the same bytes and saves its own words on this
    /// same card. Writing here afterwards would overwrite that surface's
    /// transcript with this one.
    func testTheWordsAreParkedBeforeTheyAreWrittenAndOnlyWrittenWhileThisProcessHoldsTheCapture() throws {
        let source = try Self.recordingServiceSource()
        let body = Self.normalised(try RefusalLaneSource.body(
            ofFunction: "attachWorkNoteTranscript", in: source, path: Self.recordingServicePath
        ))
        let write = try XCTUnwrap(
            body.range(of: "WorkVoiceCaptureCoordinator.attachTranscript("),
            "the desk write is what the parking and the ownership question stand in front of"
        )
        let beforeTheWrite = body[..<write.lowerBound]

        let parking = try XCTUnwrap(
            beforeTheWrite.range(of: "recordPublicationState(capture.guardToken, transcript: transcript"),
            "the recognised words are parked nowhere: an attach that throws leaves them only in this process, and the phone re-buys them"
        )
        let firstStaleness = try XCTUnwrap(
            beforeTheWrite.range(of: "isCurrentListen(", range: parking.upperBound..<beforeTheWrite.endIndex),
            "the parking suspends, so a staleness check has to follow it"
        )
        // THE WHOLE STATEMENT, not the call inside it. A guard satisfied by the
        // call alone is satisfied by `… stillOwnsCapture(…) || true`, which is
        // the check present and answering yes to everything.
        XCTAssertTrue(
            body.contains("guard await PendingRetryGuard.stillOwnsCapture(capture.guardToken) else {"),
            "the ownership question is no longer the whole condition — a disjunction beside it answers yes for a capture another surface already finished"
        )
        let ownership = try XCTUnwrap(
            beforeTheWrite.range(of: "stillOwnsCapture(capture.guardToken)",
                                 range: firstStaleness.upperBound..<beforeTheWrite.endIndex),
            "the transcript is written without asking whether the capture is still this process's — a retry card that took it has already saved its own words on that card"
        )
        // SKIP THE REFUSAL ARM. It carries its own staleness check, so a search
        // that merely starts at `stillOwnsCapture` finds THAT one and passes
        // while the check on the successful path — the one standing in front of
        // the desk write — is deleted. Brace-match the arm and look past it.
        let refusalArmEnd = try XCTUnwrap(
            Self.endOfBlock(openingAt: ownership.upperBound, in: body),
            "the ownership refusal is no longer a braced arm — update this guard rather than deleting it"
        )
        let saving = try XCTUnwrap(
            body.range(of: "VoiceState.saving", range: refusalArmEnd..<beforeTheWrite.endIndex),
            "the successful path no longer paints `saving` before the write — update this guard"
        )
        XCTAssertNotNil(
            body.range(of: "isCurrentListen(", range: refusalArmEnd..<saving.lowerBound),
            "the ownership question suspends too; with no check on the SUCCESSFUL path a session that ended is spoken to and the desk is written on its behalf"
        )
        // Stated as four ascending ranges rather than a count, so swapping the
        // parking and the ownership gate — which is the defect this pins — fails
        // even though both calls are still present.
        XCTAssertTrue(parking.lowerBound < firstStaleness.lowerBound,
                      "the parking must be the first thing this function does with the words")
        // UNCONDITIONAL, and the first statement — not merely the first
        // MENTION. `if !capture.guardToken.audioPreserved { … }` around it keeps
        // every range above in the same order while the captures that DID
        // preserve their audio — the ones with something to lose — park no
        // words at all, so an attach that throws costs the driver a second
        // transcription of speech they have already paid for.
        XCTAssertTrue(
            body.trimmingCharacters(in: .whitespaces).hasPrefix(
                "_ = await PendingRetryGuard.recordPublicationState(capture.guardToken, "
                + "transcript: transcript, publicationState: .published) "
                + "guard isCurrentListen(attemptID) else { return }"
            ),
            "the parking is no longer this function's unconditional opening — a branch around it leaves the recognised words in this process only, for exactly the captures that have something to lose"
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

    /// The token is registered with the uploader AT THE MINT, and released by a
    /// `defer` on the same scope.
    ///
    /// The cancel mark is bounded by age, and the oldest mark is normally an
    /// orphan — but it is also exactly the mark of the turn that has been
    /// suspended since before every other one started. On a long drive,
    /// `cancelClaimCeiling` later cancellations evicted the claim standing in
    /// front of an abandoned upload, and that turn resumed to find nothing and
    /// dispatched the transcript the driver had ended on. The registration is
    /// what tells the ceiling which marks are provably orphaned.
    ///
    /// AT THE MINT rather than at the `uploadConverse` call, because two
    /// suspensions (the file-lane revalidation and the outbox mint) and one
    /// executor hop sit between them — and `endSession` can cancel the token
    /// the instant it exists. The `defer` is what stops the registration
    /// leaking: dispatched, refused or thrown, the hop's exit retires the token.
    func testTheDispatchTokenIsHeldOpenFromTheMintUntilTheHopExits() throws {
        let source = Self.normalised(try Self.recordingServiceSource())
        let hop = try RefusalLaneSource.body(
            ofFunction: "startConverseHop", in: source, path: Self.recordingServicePath
        )
        XCTAssertTrue(
            hop.contains(
                "let dispatchTurnToken = Self.mintTurnToken() currentTurnToken = dispatchTurnToken "
                + "CarPlayConverseUploader.shared.beginPendingDispatch(turnToken: dispatchTurnToken) "
                + "defer { CarPlayConverseUploader.shared.endPendingDispatch(turnToken: dispatchTurnToken) }"
            ),
            "the minted token is not registered-and-released as one statement pair at the mint: unregistered, its cancel claim is an eviction candidate while the dispatch is still suspended; unreleased, the ceiling stops bounding the mark set at all"
        )
        // Exactly one of each, on the one scope that owns the token. A second
        // register with no matching release is the leak, and a second release is
        // a window with no protection in it.
        for call in ["beginPendingDispatch(", "endPendingDispatch("] {
            XCTAssertEqual(
                source.components(separatedBy: call).count - 1, 1,
                "`\(call)` is called from more than one place; the registration's lifetime is no longer the hop's"
            )
        }
    }

    /// The CHAT hop keeps the same contract, and the Work lane is what pays
    /// when it does not.
    ///
    /// `currentTurnToken` is `0` for this turn until the mint far below, so an
    /// End or a switch to Maps anywhere above it cancels NOTHING: `endSession`
    /// finds the sentinel, and the hop — parked in a gateway resolution, a
    /// conversation mint or the history assembly — resumes, mints a fresh token
    /// and dispatches a transcript the driver already abandoned. Worse for this
    /// slice: if the driver started a Work note in the meantime, that resumed
    /// task overwrites the live session's fields and its error arm ends the
    /// note. The listen lineage is the only thing that knows, and `endSession`
    /// bumps it.
    func testEverySuspensionInTheChatHopIsFollowedByAStalenessCheck() throws {
        let source = Self.normalised(try Self.recordingServiceSource())
        let hop = try RefusalLaneSource.body(
            ofFunction: "startConverseHop", in: source, path: Self.recordingServicePath
        )
        // Two shapes, and which one an exit uses is itself asserted below. The
        // bare form is for the suspensions ABOVE the user-turn append, where no
        // row exists yet; the settling form is for every one below it.
        let bareCheck = "guard isCurrentListen(attemptID) else { return }"
        let settlingCheck = "guard isCurrentListen(attemptID) else { await terminalizeAbandonedUserTurn(userRecord.id) return }"
        func hasCheck(_ range: Range<String.Index>) -> Bool {
            hop.range(of: bareCheck, range: range) != nil
                || hop.range(of: settlingCheck, range: range) != nil
        }

        // THE SCAN RUNS TO THE WIRE, not to the mint. The token was once
        // treated as the boundary — below it `endSession`'s cancel reaches the
        // uploader — but the uploader can only answer for the claim still
        // standing when its own recheck runs, and two suspensions separate the
        // mint from `uploadConverse`. Only the listen lineage covers those.
        let dispatch = try XCTUnwrap(
            hop.range(of: "CarPlayConverseUploader.shared.uploadConverse("),
            "the hop no longer dispatches here — update this guard rather than deleting it"
        )
        let mint = try XCTUnwrap(
            hop.range(of: "currentTurnToken = dispatchTurnToken"),
            "the turn token is no longer minted here, so this guard has no boundary to scan to"
        )
        XCTAssertTrue(mint.lowerBound < dispatch.lowerBound, "the mint sits above the dispatch")

        let suspensions = [
            "ConversationStore.shared.fetchConversation(id: existing)",
            "remoteAgentSnapshot(forConversationBackend: rawBackend ?? \"\")",
            "SettingsManager.shared.resolveDefaultGateway()",
            "SettingsManager.shared.gatewayBadgeRoster()",
            "remoteAgentSnapshot(for: defaultRef)",
            "ConversationStore.shared.createConversation(",
            "ConversationStore.shared.appendMessage(",
            "let fileTransferLane = await SettingsManager.shared .fileTransferReadySnapshot(for: snapshot.ref)",
            "ConversationHistoryAssembler.assemble(",
            // Post-mint, and the two the token cannot cover.
            "let revalidated = await SettingsManager.shared .fileTransferReadySnapshot(for: snapshot.ref)",
            "BackgroundFileTransfer.mintOutboxKey("
        ]
        var cursor = hop.startIndex
        for (index, call) in suspensions.enumerated() {
            let await_ = try XCTUnwrap(
                hop.range(of: call, range: cursor..<dispatch.lowerBound),
                "`startConverseHop` no longer suspends on `\(call)` in this order — update this guard rather than deleting it"
            )
            let end = index + 1 < suspensions.count
                ? (hop.range(of: suspensions[index + 1], range: await_.upperBound..<dispatch.lowerBound)?.lowerBound
                   ?? dispatch.lowerBound)
                : dispatch.lowerBound
            XCTAssertTrue(
                hasCheck(await_.upperBound..<end),
                "nothing re-checks the listen after `\(call)`: an End under it cancels no turn, and the resumed hop dispatches the abandoned transcript — or ends the Work note that replaced the session"
            )
            cursor = await_.upperBound
        }

        // THE ROW SETTLES ON EVERY ABANDONMENT BELOW THE APPEND. `sending` has
        // one writer — the uploader — so an exit above `uploadConverse` creates
        // no task and nothing ever flips it: the phone renders an unresolved
        // send with no Retry until the next launch's sweep, which is a repair
        // and not a settlement.
        let append = try XCTUnwrap(hop.range(of: "ConversationStore.shared.appendMessage("))
        XCTAssertNil(
            hop.range(of: bareCheck, range: append.upperBound..<dispatch.lowerBound),
            "an abandonment exit below the append still returns without settling the user turn it wrote"
        )
        XCTAssertGreaterThanOrEqual(
            hop.components(separatedBy: settlingCheck).count - 1, 4,
            "the settling exits below the append have thinned out — the scanner is probably broken"
        )
        // And the catch-all settles it too, ABOVE its own staleness fork, so the
        // spoken arm leaves a Retry chip as surely as the silent one.
        let generic = try XCTUnwrap(hop.range(of: "} catch {"))
        let settleInCatch = try XCTUnwrap(
            hop.range(of: "await terminalizeAbandonedUserTurn(appendedUserMessageID)",
                      range: generic.upperBound..<hop.endIndex),
            "a throw above the uploader leaves the appended turn reading `sending` forever"
        )
        let staleFork = try XCTUnwrap(
            hop.range(of: bareCheck, range: generic.upperBound..<hop.endIndex),
            "the catch-all no longer forks on staleness — update this guard"
        )
        XCTAssertTrue(
            settleInCatch.lowerBound < staleFork.lowerBound,
            "the settlement sits below the staleness fork, so a throw on a LIVE listen still leaves the row unresolved"
        )

        // The two snapshot refusals are HOISTED out of their `guard let` for
        // this reason alone: the check has to sit between the suspension and the
        // `endSession` / `speakErrorAndEnd` it guards, not after it.
        for hoisted in ["boundSnapshot", "defaultSnapshot"] {
            let resolved = try XCTUnwrap(
                hop.range(of: "let \(hoisted) = await"),
                "`\(hoisted)` is back inside its `guard let`, so its refusal runs before anything asks whose session this is"
            )
            let refusal = try XCTUnwrap(
                hop.range(of: "guard let resolved = \(hoisted) else",
                          range: resolved.upperBound..<hop.endIndex),
                "`\(hoisted)` no longer feeds a refusal — update this guard"
            )
            XCTAssertNotNil(
                hop.range(of: bareCheck, range: resolved.upperBound..<refusal.lowerBound),
                "the `\(hoisted)` refusal speaks over — and ends — whatever session replaced this one"
            )
        }

        // A THROW landing on a dead listen takes the same exit. `speakErrorAndEnd`
        // ends whatever session is live, with a chat's failure line.
        let spoken = try XCTUnwrap(
            hop.range(of: "speakErrorAndEnd(mapped", range: generic.upperBound..<hop.endIndex),
            "the catch-all no longer speaks — update this guard"
        )
        XCTAssertTrue(
            staleFork.lowerBound < spoken.lowerBound,
            "a throw arriving after the driver's End answers an empty seat — and ends the Work note started in the meantime with a chat's error line"
        )

        // THE SETTLEMENT ITSELF, whole. Every assertion above pins WHERE the
        // call sits; none of them can see what it stores, and the value is the
        // whole point: `sending` has exactly one writer — the uploader's
        // delegate — so a hop that never created a task leaves the row unsettled
        // forever, with no Retry chip in the iPhone thread until the next
        // launch's sweep. Writing `"sending"` here satisfies every ordering
        // check above and settles nothing.
        XCTAssertEqual(
            Self.closedBody(try RefusalLaneSource.body(
                ofFunction: "terminalizeAbandonedUserTurn", in: source, path: Self.recordingServicePath
            )),
            "await ConversationStore.shared.markPendingUserTurn(messageID: messageID, to: \"failed\")",
            "the abandoned user turn is settled to something other than `failed` — the row keeps reading as an unresolved send and the driver never gets a Retry"
        )

        // The lineage has to reach the hop at all.
        let process = try RefusalLaneSource.body(
            ofFunction: "processRecording", in: source, path: Self.recordingServicePath
        )
        XCTAssertTrue(
            process.contains("startConverseHop(transcript: transcript, attemptID: attemptID)"),
            "the hop is called without the listen id, so none of the checks above can be asked"
        )
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
        // The re-arm the Work lane cannot reach by calling it, it also cannot be
        // reached BY: the reply loop's re-arm carries no listen id and re-checks
        // only `sessionActive`, so a chat ended during its sign-off and a Work
        // note started at once could be re-armed into.
        let reArm = try RefusalLaneSource.body(
            ofFunction: "reArmAfterSettle", in: source, path: Self.recordingServicePath
        )
        // THE WHOLE RESTRICTION. A guard satisfied by the comparison alone is
        // satisfied by `if sessionDestination == .chat { }`, which reads the
        // destination and then re-arms whatever it found.
        let normalisedReArm = Self.normalised(reArm)
        XCTAssertTrue(
            normalisedReArm.contains("guard sessionDestination == .chat else { return }"),
            "`reArmAfterSettle` re-arms whatever session it lands in — a Work note would take a second listen it has no recording for"
        )
        // AND AFTER THE SETTLE, which is the suspension the replacement session
        // appears in. Asked above the sleep the guard reads a destination from
        // before the chat ended: a Work note started during the settle window is
        // then re-armed into by a check that has already passed.
        let sleep = try XCTUnwrap(
            normalisedReArm.range(of: "await Task.sleep(for: .seconds(Constants.carPlayHFPSettleDelay))"),
            "the re-arm no longer settles the HFP route before re-listening — update this guard"
        )
        XCTAssertNotNil(
            normalisedReArm.range(of: "guard sessionDestination == .chat else { return }",
                                  range: sleep.upperBound..<normalisedReArm.endIndex),
            "the destination is asked BEFORE the settle: a Work note started while the route was settling is re-armed into by a check that ran before it existed"
        )
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
        // BOTH halves: the note is claimed in one function and presented in
        // another (the chooser's action row claims before it pops and enters at
        // the second), so a gateway question smuggled into the presentation half
        // would refuse a Work note from outside the half this guard reads.
        for half in ["startWorkNote", "presentWorkNote"] {
            let body = try RefusalLaneSource.body(
                ofFunction: half, in: source, path: Self.sceneDelegatePath
            )
            for forbidden in ["newChatPlan", "effectiveCarPlayRef", "sessionDefaultRefOverride",
                              "newChatPickerSnapshot", "presentGatewayChooser", "fetchConversation"] {
                XCTAssertFalse(body.contains(forbidden),
                               "`\(half)` runs \(forbidden): Work needs no gateway, so nothing about one may refuse it")
            }
        }
        let body = try RefusalLaneSource.body(
            ofFunction: "presentWorkNote", in: source, path: Self.sceneDelegatePath
        )
        let present = try XCTUnwrap(body.range(of: "ensureVoicePresented("),
                                    "the voice template is presented modally, as every session is")
        let begin = try XCTUnwrap(body.range(of: "beginWorkNote()"))
        XCTAssertTrue(present.lowerBound < begin.lowerBound,
                      "g1: the engine starts INSIDE the present completion, never before it")
        // The claim half hands its serial on rather than starting a second one:
        // a presentation that claimed for itself would refuse the chooser's row
        // (the claim it was given is already held) and, from the root row, would
        // leave the first claim standing for the rest of the drive.
        XCTAssertEqual(
            Self.closedBody(try RefusalLaneSource.body(
                ofFunction: "startWorkNote", in: Self.normalised(source), path: Self.sceneDelegatePath
            )),
            "guard let serial = claimStart(.work, service: service) else { return } "
            + "presentWorkNote(serial: serial, service: service)",
            "the root row's starter no longer claims once and hands the serial to the presentation — a second claim inside it shuts the door it just opened"
        )
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

        // Scoped to the no-gateway branch itself — the brace-matched `else` arm
        // of the emptiness guard. A hint rendered only in the configured branch
        // would pass a whole-function count.
        let noGateway = try RefusalLaneSource.trailingClosure(
            after: "guard !configuredRefs.isEmpty else", in: picker, path: Self.sceneDelegatePath
        )
        // The configured branch's painting, from row 0 onward.
        let configuredStart = try XCTUnwrap(
            picker.range(of: "let newItem = CPListItem("),
            "row 0 is where the configured branch starts painting"
        )
        let configuredBranch = picker[configuredStart.lowerBound...]

        // The hint names the row that FAILED, in the state that draws both:
        // sending a failed Work start to "New voice chat" routes the repeated
        // private thought to an AI.
        XCTAssertTrue(
            Self.normalised(String(configuredBranch)).contains(
                "self.lastStartDestination == .work ? String(localized: \"carplay.hint.captureStartFailed.detail.work\""
            ),
            "the configured picker's hint reads no destination — or reads it BACKWARDS — so a failed Work start is told to tap the AI row and the repeated private thought reaches a gateway"
        )
        XCTAssertTrue(
            configuredBranch.contains("carplay.hint.captureStartFailed.detail.work"),
            "the Work sentence is missing from the state that offers both rows"
        )
        XCTAssertEqual(
            configuredBranch.components(separatedBy: "carplay.hint.captureStartFailed.detail").count - 1, 2,
            "both sentences belong here — the plain one and the `.work` one (which contains the plain key as a prefix)"
        )
        // …and the calculated sentence is what the ROW is built with. The
        // ternary above can stand, correct and unread, while the item carries a
        // literal "Tap New voice chat to try again." — which is the same defect
        // with the evidence still in the file.
        XCTAssertTrue(
            Self.normalised(String(configuredBranch)).contains("detailText: detail )"),
            "the configured picker computes the destination-specific sentence and then renders something else — a failed Work start is still told to tap the AI row"
        )

        // Day one: the row that WORKS first. The setup row above it read as a
        // prerequisite for the note below it.
        XCTAssertTrue(
            noGateway.contains("= [self.makeWorkNoteItem(service: service), item]"),
            "the no-gateway picker puts “Set up your AI on iPhone first.” above the only row that does anything"
        )
        // …and nothing re-orders it afterwards. Three mentions and no more: the
        // literal above, the hint's insert, and the section it paints.
        XCTAssertEqual(
            noGateway.components(separatedBy: "firstSectionItems").count - 1, 3,
            "the day-one row order is touched again between the literal and the paint — a reverse or a re-assignment restores the setup row to the top"
        )
        // Each of those three mentions pinned to the statement it belongs to, so
        // the count cannot be satisfied by a DIFFERENT third use: `.reversed()`
        // at the paint, or a re-assignment in place of the insert, both keep the
        // arithmetic and put the setup row back on top.
        for statement in [
            "firstSectionItems.insert(hint, at: 0)",
            "template.updateSections([CPListSection(items: firstSectionItems)])"
        ] {
            XCTAssertTrue(
                Self.normalised(String(noGateway)).contains(statement),
                "the day-one section is no longer built by `\(statement)` — a re-order slipped in under the mention count"
            )
        }

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

    /// The hint only becomes visible if something REFRESHES the picker, and a
    /// startup failure has nothing to refresh it with: the listen never reached
    /// `.recording`, so `endSession`'s closing `state = .idle` is an equal
    /// assignment and `@Observable` publishes nothing for it — no observation,
    /// no dismiss, no refresh. The driver is then parked on a Listening modal
    /// over a dead session whose "End" button is already a no-op (`endSession`
    /// guards on `sessionActive`), with the car audio session never freed in a
    /// dismiss completion. So the end has to TELL the scene, and the scene has
    /// to run the transition itself.
    func testASilentStartupFailureEndsTheSessionAndThenDrivesTheSceneItself() throws {
        let service = try Self.recordingServiceSource()
        let terminal = try RefusalLaneSource.body(
            ofFunction: "endSilentlyAfterCaptureStartFailure", in: service, path: Self.recordingServicePath
        )
        XCTAssertTrue(
            terminal.contains("guard sessionActive else { return }"),
            "a start that lost its session mid-await must not accuse the microphone of the driver's own End"
        )
        let end = try XCTUnwrap(
            terminal.range(of: "endSession(speak: nil)"),
            "the failure still ends the session silently — no TTS over a wedged audio session"
        )
        let notify = try XCTUnwrap(
            terminal.range(of: "onCaptureStartFailed?()"),
            "the scene is told explicitly, because the state assignment tells it nothing"
        )
        XCTAssertTrue(
            end.lowerBound < notify.lowerBound,
            "the scene is notified AFTER the teardown, so what it dismisses is a session already torn down"
        )

        // Every pre-`.recording` exit goes through that terminal. One left
        // ending on its own is one stuck Listening modal.
        let listen = try RefusalLaneSource.body(
            ofFunction: "startListening", in: service, path: Self.recordingServicePath
        )
        XCTAssertFalse(
            listen.contains("endSession(speak: nil)"),
            "a startup failure that ends the session directly leaves the voice modal up with nothing to dismiss it"
        )
        XCTAssertFalse(
            listen.contains("onCaptureStartFailed?()"),
            "the hint and the end belong to the same terminal; raised before the teardown it cannot dismiss anything"
        )
        XCTAssertEqual(
            listen.components(separatedBy: "endSilentlyAfterCaptureStartFailure()").count - 1, 4,
            "the four exits that fail before the `.recording` commit: activation, capture file, VAD start, engine retries"
        )

        // The scene half: the handler is the missing transition, not just a flag.
        let scene = try Self.sceneDelegateSource()
        let handler = try RefusalLaneSource.trailingClosure(
            after: "service.onCaptureStartFailed =", in: scene, path: Self.sceneDelegatePath
        )
        let flag = try XCTUnwrap(
            handler.range(of: "oneShotStartFailureHint = true"),
            "the hint flag is what the refresh below renders"
        )
        let apply = try XCTUnwrap(
            handler.range(of: "applyState("),
            "setting a flag nothing repaints is exactly the silent failure this lane had"
        )
        XCTAssertTrue(
            flag.lowerBound < apply.lowerBound,
            "the refresh has to run with the flag already set, or it repaints the picker without the hint"
        )
        // `applyState(.idle)` is dismiss-then-refresh; both halves matter (the
        // dismiss completion is where the car audio session is freed).
        let idleArm = try RefusalLaneSource.body(
            ofFunction: "applyState", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(idleArm.contains("ensureVoiceDismissed(animated: animated)"))
        XCTAssertTrue(idleArm.contains("refreshPicker()"))
    }

    // MARK: - (5) One session start at a time

    /// The rule, as the two pure answers the scene asks it for.
    ///
    /// `mayClaim` is the synchronous door: exactly ONE of its eight states may
    /// start a session. `isLive` is what every suspension re-asks, and each of
    /// its six protections is a different way a start can be overtaken between
    /// the row tap and the engine — so each is flipped on its own, and a
    /// constant answer fails whichever direction it is constant in.
    func testTheStartGateAdmitsOneClaimAndOnlyTheLiveOne() throws {
        var admitted: [[Bool]] = []
        for isIdle in [false, true] {
            for sessionActive in [false, true] {
                for claimHeld in [false, true] {
                    if CarPlayStartGate.mayClaim(isIdle: isIdle,
                                                 sessionActive: sessionActive,
                                                 claimHeld: claimHeld) {
                        admitted.append([isIdle, sessionActive, claimHeld])
                    }
                }
            }
        }
        XCTAssertEqual(
            admitted, [[true, false, false]],
            "exactly one of the eight states may claim a start: idle, no live session, no claim already held"
        )

        // EXHAUSTED, exactly as `mayClaim` is, and for a reason one-at-a-time
        // flips cannot cover: a conjunction can be replaced by a relation that
        // agrees with every fixture and still admits a state no fixture names.
        // `controllerAttached && sceneActive` rewritten as
        // `(controllerAttached == sceneActive)` answers the same for all three
        // cases the list below reaches — and yes for BOTH-false, a start
        // resuming with no controller and the driver in Maps.
        var liveStates: [[Bool]] = []
        for claimMatches in [false, true] {
            for serviceIsCurrent in [false, true] {
                for controllerAttached in [false, true] {
                    for sceneActive in [false, true] {
                        for isIdle in [false, true] {
                            for sessionActive in [false, true] {
                                guard CarPlayStartGate.isLive(
                                    claimSerial: claimMatches ? 7 : 8,
                                    serial: 7,
                                    serviceIsCurrent: serviceIsCurrent,
                                    controllerAttached: controllerAttached,
                                    sceneActive: sceneActive,
                                    isIdle: isIdle,
                                    sessionActive: sessionActive
                                ) else { continue }
                                liveStates.append([claimMatches, serviceIsCurrent,
                                                   controllerAttached, sceneActive,
                                                   isIdle, sessionActive])
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(
            liveStates, [[true, true, true, true, true, false]],
            "exactly one of the 64 states may still act: this claim, this service, a controller attached, the scene foreground, still idle, no session begun"
        )
        // …and the claim serial is not a Boolean, so its third state is asked
        // separately: no claim held at all must never read as this one.
        XCTAssertFalse(
            CarPlayStartGate.isLive(claimSerial: nil, serial: 7, serviceIsCurrent: true,
                                    controllerAttached: true, sceneActive: true,
                                    isIdle: true, sessionActive: false),
            "a released claim reads as live, so a start cancelled by End still reaches the engine"
        )

        let protections: [(String, Bool)] = [
            ("the claim was released or replaced",
             CarPlayStartGate.isLive(claimSerial: 8, serial: 7, serviceIsCurrent: true,
                                     controllerAttached: true, sceneActive: true,
                                     isIdle: true, sessionActive: false)),
            ("no claim is held at all",
             CarPlayStartGate.isLive(claimSerial: nil, serial: 7, serviceIsCurrent: true,
                                     controllerAttached: true, sceneActive: true,
                                     isIdle: true, sessionActive: false)),
            ("the connection was torn down and rebuilt",
             CarPlayStartGate.isLive(claimSerial: 7, serial: 7, serviceIsCurrent: false,
                                     controllerAttached: true, sceneActive: true,
                                     isIdle: true, sessionActive: false)),
            ("the interface controller went away",
             CarPlayStartGate.isLive(claimSerial: 7, serial: 7, serviceIsCurrent: true,
                                     controllerAttached: false, sceneActive: true,
                                     isIdle: true, sessionActive: false)),
            ("the driver switched to Maps",
             CarPlayStartGate.isLive(claimSerial: 7, serial: 7, serviceIsCurrent: true,
                                     controllerAttached: true, sceneActive: false,
                                     isIdle: true, sessionActive: false)),
            ("the service is no longer idle",
             CarPlayStartGate.isLive(claimSerial: 7, serial: 7, serviceIsCurrent: true,
                                     controllerAttached: true, sceneActive: true,
                                     isIdle: false, sessionActive: false)),
            ("a session already began",
             CarPlayStartGate.isLive(claimSerial: 7, serial: 7, serviceIsCurrent: true,
                                     controllerAttached: true, sceneActive: true,
                                     isIdle: true, sessionActive: true))
        ]
        for (reason, live) in protections {
            XCTAssertFalse(live, "a start survives “\(reason)” — that is how a tapped Work note becomes an AI chat")
        }
    }

    /// The three methods that ASK the pure gate, pinned WHOLE.
    ///
    /// A correct rule reached through a lying caller is not a protection, and
    /// the caller is the half no assertion about `CarPlayStartGate` can see:
    /// `claimStart` can pass `claimHeld: false` and admit a second start under
    /// the first, `startIsLive` can append `|| true` to the answer, and
    /// `releaseStart` can drop `refreshPicker()` and strand a refresh that was
    /// retained under the claim. Each of the three is short enough to be its own
    /// contract, so the contract is the whole body — a `contains` on any part of
    /// it admits all three mutations with the searched text still in place.
    ///
    /// The starters themselves are private, need a live `CPInterfaceController`,
    /// and cannot be exercised from the simulator suite; this is what stands in
    /// for that, and it fails on any edit — which is the intent. If a change here
    /// is deliberate, restate the body.
    func testTheGateIsAskedHonestly() throws {
        let scene = Self.normalised(try Self.sceneDelegateSource())
        let expected: [(String, String, String)] = [
            (
                "claimStart",
                "guard service === recordingService else { return nil } var isIdle = false if case .idle = service.state { isIdle = true } guard CarPlayStartGate.mayClaim( isIdle: isIdle, sessionActive: service.sessionActive, claimHeld: pendingStart != nil ) else { return nil } startClaimSerial &+= 1 pendingStart = (startClaimSerial, destination) lastStartDestination = destination oneShotStartFailureHint = false return startClaimSerial",
                "the claim is taken on terms the gate never sees — `claimHeld: false` admits a second start under the one already in its pre-flight, and a hint left unconsumed re-appears over the row the driver just tapped"
            ),
            (
                "startIsLive",
                "var isIdle = false if case .idle = service.state { isIdle = true } return CarPlayStartGate.isLive( claimSerial: pendingStart?.serial, serial: serial, serviceIsCurrent: service === recordingService, controllerAttached: interfaceController != nil, sceneActive: service.isSceneActive, isIdle: isIdle, sessionActive: service.sessionActive )",
                "the re-validation no longer forwards the live state, or no longer forwards ONLY it — an invalidated start reaches the engine with every call site still reading correctly"
            ),
            (
                "releaseStart",
                "guard pendingStart?.serial == serial else { return } pendingStart = nil if pickerRefreshPending, recordingService?.sessionActive != true { refreshPicker() }",
                "releasing the claim no longer drains the refresh it was holding — a start that never began leaves the picker painted as it was before the tap"
            )
        ]
        for (name, body, why) in expected {
            let actual = Self.closedBody(try RefusalLaneSource.body(
                ofFunction: name, in: scene, path: Self.sceneDelegatePath
            ))
            XCTAssertEqual(actual, body, "`\(name)`: \(why)")
        }
    }

    /// The wiring the pure gate cannot see: both starters CLAIM before they
    /// suspend, RE-VALIDATE after every suspension and inside the present
    /// completion, and RELEASE by serial on every exit.
    ///
    /// The defect: `startSession` guards `.idle && !sessionActive`, then
    /// suspends on the gateway pre-flight. "Add to Work" passes the same guard
    /// during that suspension and presents the modal; `ensureVoicePresented`
    /// sets its flag before the present completes and runs a later caller's
    /// completion immediately — so the resumed chat start reaches `beginSession`
    /// first and the driver who tapped Add to Work is in a chat session. The
    /// starters are private and need a `CPInterfaceController`, so the wiring is
    /// asserted where it is written.
    func testEverySessionStartClaimsBeforeItSuspendsAndRevalidatesBeforeItBegins() throws {
        let scene = Self.normalised(try Self.sceneDelegateSource())

        // Both starters take the claim as their FIRST statement — before the
        // `Task` hop, which is itself the suspension the race lives in.
        for starter in ["startSession", "startWorkNote"] {
            let body = try RefusalLaneSource.body(
                ofFunction: starter, in: scene, path: Self.sceneDelegatePath
            )
            XCTAssertTrue(
                body.trimmingCharacters(in: .whitespaces).hasPrefix("guard let serial = claimStart("),
                "`\(starter)` does not claim the start before it suspends: the other row's tap passes the same idle test underneath it"
            )
        }

        let chat = try RefusalLaneSource.body(
            ofFunction: "startSession", in: scene, path: Self.sceneDelegatePath
        )
        // Re-validated as the STATEMENT AFTER each suspension group, so a check
        // that drifted below a side effect fails here.
        for anchor in [
            "effectiveCarPlayRef()",
            "remoteAgentSnapshot(forConversationBackend: bound?.backend ?? \"\")",
            "newChatPickerSnapshot()"
        ] {
            let anchored = try XCTUnwrap(chat.range(of: anchor),
                                         "the pre-flight no longer awaits `\(anchor)` — update this guard")
            let tail = chat[anchored.upperBound...]
            let check = try XCTUnwrap(
                tail.range(of: "startIsLive(serial"),
                "nothing re-validates the claim after `\(anchor)`; a disconnect or an End under it still reaches the engine"
            )
            XCTAssertEqual(
                tail[..<check.lowerBound].trimmingCharacters(in: .whitespaces), "guard self.",
                "the re-validation after `\(anchor)` is not the next statement — whatever runs before it runs on a dead claim"
            )
        }
        XCTAssertTrue(
            chat.contains("defer { if !handedToPresent { self.releaseStart(serial) } }"),
            "the pre-flight's early returns — missing token, chooser repair, nothing set up — leak the claim, and no row starts anything again this drive"
        )

        // Both present completions: re-validate, release + dismiss on refusal,
        // begin, release.
        let starters = [
            ("startSession", chat, "beginSession("),
            // The Work note's PRESENTATION half — the claim is taken one call
            // earlier (root row) or before the chooser's pop (action row), and
            // both enter here carrying the same serial.
            ("presentWorkNote",
             try RefusalLaneSource.body(ofFunction: "presentWorkNote", in: scene, path: Self.sceneDelegatePath),
             "beginWorkNote()")
        ]
        for (name, body, beginCall) in starters {
            let completion = try RefusalLaneSource.trailingClosure(
                after: "ensureVoicePresented(", in: body, path: Self.sceneDelegatePath
            )
            let revalidate = try XCTUnwrap(
                completion.range(of: "startIsLive(serial"),
                "\(name)'s present completion begins a session without re-asking whether the claim is still live"
            )
            let releaseOnRefusal = try XCTUnwrap(
                completion.range(of: "releaseStart(serial)", range: revalidate.upperBound..<completion.endIndex),
                "\(name)'s refused start never releases its claim"
            )
            // The refusal arm itself, brace-matched: a `presented` dropped from
            // the guard, a missing `return`, or a dismiss issued on connection
            // identity alone all fail HERE rather than passing a whole-closure
            // token search.
            let refusalArm = try RefusalLaneSource.trailingClosure(
                after: "guard presented, self.startIsLive(serial, service: service) else",
                in: completion, path: Self.sceneDelegatePath
            )
            XCTAssertTrue(
                refusalArm.contains("releaseStart(serial)"),
                "\(name)'s refusal arm no longer releases the claim"
            )
            XCTAssertTrue(
                refusalArm.contains("dismissModalLeftOverBy(refusedStart: service)"),
                "\(name)'s refused start dismisses on connection identity alone — a completion delayed past a backgrounding tears down the NEWER capture and deletes its recording"
            )
            XCTAssertTrue(
                refusalArm.trimmingCharacters(in: .whitespaces).hasSuffix("return }"),
                "\(name)'s refusal arm falls through into the start it just refused"
            )
            let dismiss = try XCTUnwrap(
                completion.range(of: "dismissModalLeftOverBy(", range: releaseOnRefusal.upperBound..<completion.endIndex),
                "\(name) leaves a Listening modal up over no session when the start is refused"
            )
            let begin = try XCTUnwrap(
                completion.range(of: beginCall, range: dismiss.upperBound..<completion.endIndex),
                "\(name)'s `\(beginCall)` no longer sits inside the present completion (g1)"
            )
            XCTAssertNotNil(
                completion.range(of: "releaseStart(serial)", range: begin.upperBound..<completion.endIndex),
                "\(name) holds its claim after the session began; nothing releases it and the picker never repaints"
            )
        }

        // `ensureVoicePresented` answers whether a modal is actually up, and a
        // present belonging to a torn-down connection answers for nobody.
        let present = try RefusalLaneSource.body(
            ofFunction: "ensureVoicePresented", in: scene, path: Self.sceneDelegatePath
        )
        // The two false answers, each in ITS OWN brace-matched arm. A count
        // over the whole function was satisfied by the missing-self and
        // stale-controller branches alone, so deleting both of these was
        // invisible.
        for (arm, why) in [
            ("guard let controller = interfaceController else",
             "with no interface controller there is no modal, and a caller told “presented” records behind the picker"),
            ("guard success else",
             "a FAILED present must tell its caller no modal is up — that answer is what stops `beginSession()`")
        ] {
            let branch = try RefusalLaneSource.trailingClosure(
                after: arm, in: present, path: Self.sceneDelegatePath
            )
            XCTAssertTrue(branch.contains("completion?(false)"), why)
        }
        XCTAssertTrue(
            present.contains("interfaceController === controller"),
            "a present from the previous connection flips this connection's modal flag"
        )
        let dismissed = try RefusalLaneSource.body(
            ofFunction: "ensureVoiceDismissed", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            dismissed.contains("interfaceController === controller"),
            "a dismiss from the previous connection frees the NEW connection's audio route out from under a live session"
        )
        // …and a dismiss OVERTAKEN on this one: a start claimed and presented
        // while this dismiss was in flight owns the modal and the car radio now.
        let deactivate = try XCTUnwrap(
            dismissed.range(of: "deactivateAudioSession()"),
            "the dismiss completion is where the car radio is freed"
        )
        let overtaken = dismissed[..<deactivate.lowerBound]
        XCTAssertTrue(
            overtaken.contains("!self.isVoicePresented"),
            "a stale dismiss completion frees the route under a modal that has since been re-presented — cutting the new capture and its spoken acknowledgement"
        )
        XCTAssertTrue(
            overtaken.contains("sessionActive != true"),
            "a stale dismiss completion deactivates audio under a LIVE session"
        )

        // The claim's own identity, asserted at the two sites the pure gate
        // cannot see: `startIsLive` must ask about the STORED claim (passing
        // `claimSerial: serial` makes every gate answer yes), and `releaseStart`
        // must actually drop it.
        let live = try RefusalLaneSource.body(
            ofFunction: "startIsLive", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            live.contains("claimSerial: pendingStart?.serial"),
            "`startIsLive` no longer compares against the STORED claim, so a start invalidated by backgrounding resumes underneath a later one"
        )
        let releaseBody = try RefusalLaneSource.body(
            ofFunction: "releaseStart", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            releaseBody.contains("guard pendingStart?.serial == serial else { return }"),
            "`releaseStart` no longer releases BY SERIAL: a stale completion clears the claim the live start is holding"
        )
        XCTAssertTrue(
            releaseBody.contains("pendingStart = nil"),
            "`releaseStart` releases nothing, so the first refused start shuts every row for the rest of the drive"
        )

        // A modal left standing by a REFUSED start is dismissed only when it
        // belongs to nobody.
        let leftOver = try RefusalLaneSource.body(
            ofFunction: "dismissModalLeftOverBy", in: scene, path: Self.sceneDelegatePath
        )
        // THE WHOLE HELPER, not its three tokens. Every one of them survives
        // `… || true` appended to the last condition, and the dismiss then runs
        // for a modal that belongs to a LIVE start: `templateDidDisappear` ends
        // that session and deletes its partial recording. Three lines is its own
        // contract; if a change here is deliberate, restate the body.
        XCTAssertEqual(
            Self.closedBody(leftOver),
            "guard service === recordingService, pendingStart == nil, !service.sessionActive else { return } ensureVoiceDismissed(animated: true)",
            "the refused-start cleanup no longer dismisses ONLY a modal that belongs to nobody — a stale service, a later start's claim or a live session behind it each turn this into a teardown of someone else's capture"
        )

        // The two places the driver cancels a start that has no session yet.
        let endButton = try RefusalLaneSource.trailingClosure(
            after: "CPBarButton(title: String(localized: \"End\"))", in: scene, path: Self.sceneDelegatePath
        )
        let endCancel = try XCTUnwrap(
            endButton.range(of: "cancelPendingStart(for: service)"),
            "“End” pressed while a start is still inside its present completion ends nothing — `endSession` returns on its `sessionActive` guard — and the completion records anyway"
        )
        XCTAssertNotNil(
            endButton.range(of: "endFromButton()", range: endCancel.upperBound..<endButton.endIndex),
            "the claim must be dropped BEFORE the end, or the completion can still slip through"
        )
        let disappeared = try RefusalLaneSource.body(
            ofFunction: "templateDidDisappear", in: scene, path: Self.sceneDelegatePath
        )
        let disappearCancel = try XCTUnwrap(
            disappeared.range(of: "cancelPendingStart(for: service)"),
            "a modal dismissed before its present completion leaves the claim alive, and the completion starts recording behind the picker"
        )
        let sessionGuard = try XCTUnwrap(
            disappeared.range(of: "guard service.sessionActive else { return }"),
            "the session-teardown guard is where this function returns on a start that has no session yet"
        )
        XCTAssertTrue(
            disappearCancel.lowerBound < sessionGuard.lowerBound,
            "the claim is invalidated below the `sessionActive` guard — the one case that returns before reaching it"
        )
        let cancelBody = try RefusalLaneSource.body(
            ofFunction: "cancelPendingStart", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            cancelBody.contains("releaseStart("),
            "the cancellation clears the claim without draining a refresh retained under it, so the picker stays stale"
        )
        XCTAssertTrue(
            cancelBody.contains("service === recordingService"),
            "a stale connection's End cancels the LIVE connection's claim"
        )

        // A claim cannot outlive the foreground or the connection.
        for lifecycle in ["sceneWillResignActive", "disconnectCleanup"] {
            let body = try RefusalLaneSource.body(
                ofFunction: lifecycle, in: scene, path: Self.sceneDelegatePath
            )
            XCTAssertTrue(
                body.contains("pendingStart = nil"),
                "`\(lifecycle)` leaves a claim behind: a start suspended in its pre-flight begins over Maps, or holds the next connection's door shut"
            )
        }
        let didConnect = try RefusalLaneSource.body(
            ofFunction: "templateApplicationScene", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            didConnect.contains("disconnectCleanup()"),
            "`didConnect`'s stale-service path runs its own partial teardown instead of the shared one, so a hard drop hands this connection the previous one's claim and refresh latch"
        )

        // The two surfaces that act on a claim-free scene.
        let chooser = try RefusalLaneSource.body(
            ofFunction: "presentGatewayChooser", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(chooser.contains("service === self.recordingService"),
                      "a chooser pick that lands after a reconnect re-points a drive that no longer exists")
        XCTAssertTrue(chooser.contains("pendingStart == nil"),
                      "a chooser pick under a claimed start re-aims a session already starting")

        // The refresh computes first and gates ONCE, and a refusal is retained.
        let picker = try RefusalLaneSource.body(
            ofFunction: "refreshPicker", in: scene, path: Self.sceneDelegatePath
        )
        let lastAwait = try XCTUnwrap(picker.range(of: "await ", options: .backwards))
        let firstPaint = try XCTUnwrap(
            picker.range(of: "leadingNavigationBarButtons"),
            "the nav-bar buttons are the first template mutation the async half makes"
        )
        XCTAssertTrue(
            lastAwait.lowerBound < firstPaint.lowerBound,
            "the refresh still suspends after it has started painting: a refusal lands between two mutations"
        )
        let gate = picker[lastAwait.upperBound..<firstPaint.lowerBound]
        XCTAssertEqual(
            gate.components(separatedBy: "pickerRefreshPending = true").count - 1, 1,
            "the async half must gate exactly once, after the last read and before the first mutation"
        )
        // THE WHOLE GUARD, not a count of the retentions inside it. Deleting one
        // of its four conditions leaves the single `pickerRefreshPending = true`
        // exactly where it was: without `self.pendingStart == nil` the refresh
        // repaints the list root under a CLAIMED start — the repaint the claim
        // exists to defer, and repainting the root under a presented voice modal
        // is a known CarPlay assertion source.
        XCTAssertTrue(
            gate.contains(
                "guard service === self.recordingService, template === self.listTemplate, "
                + "self.pendingStart == nil, !service.sessionActive else { self.pickerRefreshPending = true return }"
            ),
            "the refresh's one gate no longer asks all four questions — a stale service, a stale template, a claimed start or a live session each let it paint over somebody else's screen"
        )
        XCTAssertTrue(
            releaseBody.contains("pickerRefreshPending"),
            "a refresh refused for a held claim is dropped: a start that never began leaves a stale picker for the rest of the drive"
        )

        // The notification path RETAINS under a claim (nothing else will repaint
        // if the start is then refused) and still DROPS mid-session (the
        // session's own teardown refreshes on the way out).
        let observer = try RefusalLaneSource.body(
            ofFunction: "observeConversations", in: scene, path: Self.sceneDelegatePath
        )
        let claimGate = try XCTUnwrap(
            observer.range(of: "pendingStart == nil"),
            "the notification handler no longer gates on a held claim"
        )
        XCTAssertFalse(
            observer[..<claimGate.lowerBound].contains("pickerRefreshPending"),
            "the mid-session ask is retained too — but the session's own teardown already refreshes, so this queues a second repaint"
        )
        let retained = try XCTUnwrap(
            observer.range(of: "pickerRefreshPending = true", range: claimGate.upperBound..<observer.endIndex),
            "a conversation change arriving under a claimed start is DROPPED: `releaseStart` finds nothing to drain, and a refused start leaves the Recent list stale for the rest of the drive"
        )
        XCTAssertNotNil(
            observer.range(of: "refreshPicker()", range: retained.upperBound..<observer.endIndex),
            "the handler retains the ask but no longer refreshes when nothing is claimed"
        )
    }

    /// "End" pressed while the microphone is still starting still clears the
    /// screen and still gives the car its radio back.
    ///
    /// `beginWorkNote`/`beginSession` flip `sessionActive` and leave `state`
    /// alone; the listen does not reach `.recording` until the commit far below
    /// the cold-route settle and the VAD model load. End inside that window
    /// therefore ends a REAL session whose `state` never moved, so
    /// `endSession`'s closing `state = .idle` is an equal assignment — and the
    /// case below proves what `@Observable` does with one of those. The
    /// observer never fires, so nothing dismisses the Listening modal and the
    /// dismiss completion that frees the car radio never runs; the driver is
    /// left on a "Listening" screen whose "End" is already a no-op, over a
    /// session that is dead, with the audio route still held. The abandoned
    /// startup supplies no signal either — it discards its engine and returns.
    func testEndDuringMicrophoneStartupStillClearsTheScreenAndFreesTheCar() throws {
        // THE PREMISE, executed. Everything else here is a source pin, and a
        // source pin for a reason nobody can check is folklore: if Observation
        // ever starts publishing equal assignments, this fails first and says
        // the hand-driven transition below is now a second dismiss.
        //
        // ONE PROBE EACH, because an equal assignment also leaves its observer
        // ARMED — the same fact from the other side. Reusing one probe would let
        // the first registration fire again on the second measurement and report
        // two changes for one.
        let unchanged = EqualAssignmentProbe()
        let unchangedTally = EqualAssignmentProbe.Tally()
        withObservationTracking { _ = unchanged.value } onChange: { unchangedTally.count += 1 }
        unchanged.value = .idle
        XCTAssertEqual(
            unchangedTally.count, 0,
            "an equal assignment now publishes — `endSession`'s closing `state = .idle` reaches the scene on its own again, and the hand-driven transition below is a second dismiss"
        )
        let changed = EqualAssignmentProbe()
        let changedTally = EqualAssignmentProbe.Tally()
        withObservationTracking { _ = changed.value } onChange: { changedTally.count += 1 }
        changed.value = .recording
        XCTAssertEqual(changedTally.count, 1, "a real change must still publish, or this probe is measuring nothing")

        let scene = Self.normalised(try Self.sceneDelegateSource())
        // The End handler, WHOLE. Asking `state` after the end answers `.idle`
        // for every session there has ever been, so the question can only be
        // asked before it — and an ordering that a `contains` cannot see is
        // exactly what this pins.
        let endButton = Self.closedBody(try RefusalLaneSource.trailingClosure(
            after: "CPBarButton(title: String(localized: \"End\"))", in: scene, path: Self.sceneDelegatePath
        ))
        XCTAssertEqual(
            endButton,
            "[weak self, weak service] _ in guard let service else { return } "
            + "self?.cancelPendingStart(for: service) "
            + "let startupNeverLeftIdle = service.state == .idle "
            + "service.endFromButton() "
            + "if startupNeverLeftIdle { self?.finishIdleEndTheObserverCannotDeliver(service: service) }",
            "“End” during the settle or the VAD load leaves the Listening modal up over a dead session and never frees the car radio"
        )
        // …and the transition it drives is the observer's own chokepoint, not a
        // second one that could drift from it.
        XCTAssertEqual(
            Self.closedBody(try RefusalLaneSource.body(
                ofFunction: "finishIdleEndTheObserverCannotDeliver", in: scene, path: Self.sceneDelegatePath
            )),
            "guard service === recordingService, service.state == .idle else { return } "
            + "applyState(service.state, service: service)",
            "the hand-driven end no longer runs the same `.idle` transition the observer would have — a stale service's End clears the live connection's screen, or a session that DID reach `.recording` is dismissed twice"
        )
        // The chokepoint itself still dismisses and repaints on `.idle`; without
        // this the pin above could be satisfied by an `applyState` that had
        // stopped doing either.
        let apply = try RefusalLaneSource.body(
            ofFunction: "applyState", in: scene, path: Self.sceneDelegatePath
        )
        let idleArm = try XCTUnwrap(
            apply.range(of: "case .idle:"),
            "the state chokepoint no longer has an `.idle` arm — update this guard"
        )
        let errorArm = try XCTUnwrap(
            apply.range(of: "case .error:", range: idleArm.upperBound..<apply.endIndex),
            "the `.idle` arm is no longer followed by `.error` — update this guard"
        )
        let idle = apply[idleArm.upperBound..<errorArm.lowerBound]
        XCTAssertTrue(
            idle.contains("ensureVoiceDismissed(animated: animated)"),
            "the `.idle` arm no longer dismisses the voice modal, so nothing frees the car radio on any end"
        )
        XCTAssertTrue(
            idle.contains("refreshPicker()"),
            "the `.idle` arm no longer repaints the picker, so every ended session leaves the list as it was"
        )
    }

    /// A Work note shows End only.
    ///
    /// `mute()` tears capture down and DELETES the partial recording; Unmute
    /// starts a fresh listen. On a multi-turn chat that is call-style mute. On a
    /// one-shot note it silently throws away everything said before the tap —
    /// and the driver, who cannot look, hears nothing about it.
    func testAWorkNoteOffersEndAndNoMute() throws {
        let scene = try Self.sceneDelegateSource()
        let workNote = try RefusalLaneSource.body(
            ofFunction: "presentWorkNote", in: Self.normalised(scene), path: Self.sceneDelegatePath
        )
        // UNCONDITIONAL, and the FIRST statement of the presentation half — the
        // one both doors enter through. An assignment moved inside any branch
        // still satisfies a `contains`, and a Work note that reaches the present
        // with the chat's Mute still installed can silently delete everything
        // said before the tap.
        XCTAssertTrue(
            workNote.trimmingCharacters(in: .whitespaces).hasPrefix(
                "service.voiceControlTemplate.trailingNavigationBarButtons = []"
            ),
            "the trailing-button clear is no longer the unconditional first statement of the presentation — a branch around it puts Mute back on a one-shot note"
        )
        XCTAssertFalse(
            workNote.contains("setMuteButton("),
            "Mute on a one-shot note deletes what was already said and says nothing about it"
        )
        // …and not through its wrapper either. `installVoiceTemplateButtons`
        // ends in `setMuteButton(service:)`, so a call to it AFTER the clear
        // reinstalls the button the clear just removed, with neither assertion
        // above noticing.
        XCTAssertFalse(
            workNote.contains("installVoiceTemplateButtons("),
            "the Work starter re-installs the shared button pair, which puts Mute back on the note it just cleared it from"
        )
        let chat = try RefusalLaneSource.body(
            ofFunction: "startSession", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            chat.contains("setMuteButton("),
            "the chat lane still repaints Mute before its present — a session that ended while muted left the button reading “Unmute”"
        )

        // A CENSUS, because the two assertions above only look inside the Work
        // starter, and the button can be restored from anywhere the note's own
        // path reaches. `ensureVoicePresented` is the one both starters call and
        // is where a single `setMuteButton(service:)` before the present puts
        // Mute back on a note that had just cleared it. So: exactly four
        // mentions in the whole scene, and each of them named.
        XCTAssertEqual(
            scene.components(separatedBy: "setMuteButton(").count - 1, 4,
            "the scene installs Mute from a fifth place; the Work note's clear is undone somewhere neither starter can see"
        )
        for (owner, count) in [
            ("installVoiceTemplateButtons", 1),   // the once-per-connection install
            ("setMuteButton", 1),                 // its own re-assignment on a discrete tap
            ("startSession", 1)                   // the chat lane's repaint before its present
        ] {
            XCTAssertEqual(
                try RefusalLaneSource.body(
                    ofFunction: owner, in: scene, path: Self.sceneDelegatePath
                ).components(separatedBy: "setMuteButton(").count - 1,
                count,
                "`\(owner)` no longer holds its one Mute install — the census above now covers something else"
            )
        }
        let present = try RefusalLaneSource.body(
            ofFunction: "ensureVoicePresented", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertFalse(
            present.contains("setMuteButton("),
            "the shared present installs Mute, so every Work note reaches the screen with the button that deletes what was already said"
        )
        XCTAssertFalse(
            present.contains("trailingNavigationBarButtons"),
            "the shared present writes the trailing button itself — the Work starter's clear is undone one call later, on the way to the modal"
        )
        // And the trailing button has exactly two writers: the one that installs
        // Mute and the one that clears it.
        XCTAssertEqual(
            scene.components(separatedBy: "trailingNavigationBarButtons").count - 1, 2,
            "a third writer of the trailing button — the Work note's End-only contract is decided somewhere the two assertions above cannot see"
        )
    }

    /// The drive-long override names a GATEWAY and never the desk.
    ///
    /// The chooser is sticky: its pick lives until the cable drops and resets
    /// silently on every reconnect — a fuel stop, a cable bump, a host restart.
    /// Between two gateways a stale override costs "wrong AI". Between an AI and
    /// the desk it changes category: a driver who believes Work is still
    /// selected taps row 0 and a private thought reaches an AI. Work is a row,
    /// not a mode, and this pins the mode out.
    func testTheDriveLongOverrideNamesAGatewayAndNeverTheDesk() throws {
        let scene = try Self.sceneDelegateSource()
        XCTAssertTrue(
            scene.contains("private var sessionDefaultRefOverride: RemoteAgentRef?"),
            "the session override is no longer gateway-typed, so the desk can be stored as this drive's destination"
        )
        let chooser = try RefusalLaneSource.body(
            ofFunction: "presentGatewayChooser", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(chooser.contains("configured.map"),
                      "the chooser's rows are the configured gateways")
        XCTAssertTrue(chooser.contains("sessionDefaultRefOverride = ref"),
                      "picking a row is what sets this drive's gateway")
        // ONE writer in the whole chooser — the gateway rows'. The list also
        // carries a Work ACTION row now, and the difference between an action
        // and a mode is exactly this assignment: a second one here, on the Work
        // row, is the drive-long Work mode this case exists to keep out.
        XCTAssertEqual(
            chooser.components(separatedBy: "sessionDefaultRefOverride =").count - 1, 1,
            "a second row in the chooser stores this drive's destination — the Work row is a mode again, and the next reconnect resets it without saying so"
        )
        XCTAssertFalse(
            chooser.contains("= .work"),
            "the chooser stores a Work MODE — one that survives until the cable drops and resets without saying so"
        )
        XCTAssertFalse(
            chooser.contains("beginWorkNote("),
            "the chooser starts a Work note outside a present completion (g1), instead of going through the starter"
        )

        // No SECOND place to keep a destination, either. The chooser is only one
        // route into a sticky mode; a separate flag consulted by the "New voice
        // chat" handler is another, and it would pass every assertion above.
        // The scene knows exactly three destination-shaped things and no more:
        // the claim's own tuple, the hint's record of the last start, and
        // `claimStart`'s parameter.
        XCTAssertEqual(
            scene.components(separatedBy: "CarPlayCaptureDestination").count - 1, 3,
            "the scene holds a fourth destination — a mode kept somewhere the chooser assertions cannot see"
        )
        for declaration in [
            "private var pendingStart: (serial: UInt64, destination: CarPlayCaptureDestination)?",
            "private var lastStartDestination: CarPlayCaptureDestination = .chat"
        ] {
            XCTAssertTrue(scene.contains(declaration),
                          "`\(declaration)` is gone — the count above now covers something else")
        }
        // Row 0 starts a CHAT, named at the row rather than read from state.
        let normalisedScene = Self.normalised(scene)
        let newChat = try RefusalLaneSource.body(
            ofFunction: "startSession", in: normalisedScene, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            newChat.trimmingCharacters(in: .whitespaces).hasPrefix(
                "guard let serial = claimStart(.chat, service: service) else { return }"
            ),
            "the AI row's destination is no longer the literal `.chat` — a stored mode decides it, and a drive that once tapped Work keeps sending notes to the desk from row 0"
        )
        // …and the ROW ITSELF, whole. Every assertion above is about the
        // starters and the chooser, and a mode can be kept in neither: a handler
        // that reads `lastStartDestination` — a field this scene legitimately
        // holds, for the hint — and calls `startWorkNote` instead satisfies the
        // declaration checks, the mention count and the starter prefix, while
        // one Work note turns row 0 into a second Work row for the rest of the
        // drive. Each handler is three statements; each is its own contract.
        let shared = "handler = { [weak self, weak service] _, completion in defer { completion() } "
            + "guard let self, let service else { return } guard !service.sessionActive else { return } "
        for (row, statement) in [
            ("New voice chat", "newItem." + shared + "self.startSession(service: service, conversationID: nil) }"),
            ("Add to Work", "item." + shared + "self.startWorkNote(service: service) }")
        ] {
            XCTAssertTrue(
                normalisedScene.contains(statement),
                "the “\(row)” row no longer starts what its title says, or no longer refuses mid-session — the driver's tap reaches the other destination"
            )
        }
    }

    // MARK: - (5b) The second door — the chooser's Work ACTION row

    /// The destination chooser ends with the desk, and the desk is its LAST row.
    ///
    /// The driver opened this list to pick an AI, so the AIs come first and the
    /// destination that is not one of them sits under all of them. It is the
    /// SECOND door to a note the root row already offers in one tap — that row
    /// stays, because on day one it is the only row in the picker that does
    /// anything and because one tap is fewer than three — so the door exists
    /// exactly where the list does: two or more gateways (the nav-bar switcher)
    /// or the repair chooser a broken default pushes. With a single gateway
    /// there is no switcher, no second door, and the root row is still one tap.
    func testTheDestinationChooserEndsWithTheWorkRowAndOpensNoNewDoorOfItsOwn() throws {
        let scene = try Self.sceneDelegateSource()
        let chooser = Self.normalised(try RefusalLaneSource.body(
            ofFunction: "presentGatewayChooser", in: scene, path: Self.sceneDelegatePath
        ))

        // LAST. Three ranges in one order: the gateway rows, then the Work row,
        // then the template they are handed to. A row appended before the map —
        // or built into it — puts the desk above an AI on a list the driver
        // reads top-down at the wheel.
        let gateways = try XCTUnwrap(
            chooser.range(of: "var items: [CPListItem] = configured.map"),
            "the chooser's rows are no longer the configured gateways plus what is appended after them"
        )
        let workRow = try XCTUnwrap(
            chooser.range(of: "carplay.picker.addToWork.title"),
            "the chooser no longer offers the desk at all — the founder's shape is a destination picker that names every destination"
        )
        let appended = try XCTUnwrap(
            chooser.range(of: "items.append(workItem)"),
            "the Work row is built but never added, so the second door is a dead object"
        )
        let template = try XCTUnwrap(
            chooser.range(of: "let chooser = CPListTemplate("),
            "the rows are no longer collected into the pushed template"
        )
        XCTAssertTrue(gateways.upperBound < workRow.lowerBound,
                      "the Work row is built before the gateway rows — it reads as a destination pick above the AIs the driver opened the list for")
        XCTAssertTrue(workRow.upperBound < appended.lowerBound,
                      "the row is appended before it is finished being built")
        XCTAssertTrue(appended.upperBound < template.lowerBound,
                      "the Work row is appended after the template was built from `items`, so the pushed list never shows it")
        XCTAssertEqual(
            chooser.components(separatedBy: "items.append(").count - 1, 1,
            "the chooser appends a second row of its own; whatever it is, it sits below the desk and nothing here says what it does"
        )

        // An ACTION, not a pick: no checkmark, and the one checkmark this list
        // draws belongs to the gateway rows above.
        XCTAssertEqual(
            chooser.components(separatedBy: "checkmark").count - 1, 1,
            "a second checkmark in the chooser — the Work row is being drawn as a selected state, which is the mode this lane refuses to have"
        )
        let checkmark = try XCTUnwrap(chooser.range(of: "checkmark"))
        XCTAssertTrue(checkmark.upperBound < workRow.lowerBound,
                      "the checkmark is drawn at or below the Work row: the desk looks like this drive's stored destination")

        // THE SAME WORDS AS THE ROOT ROW, from the same key: one action has one
        // name, and a second key here is a second name for the same thing.
        XCTAssertTrue(
            chooser.contains(
                "text: String(localized: \"carplay.picker.addToWork.title\", defaultValue: \"Add to Work\")"
            ),
            "the chooser's desk row no longer reads from the root row's key — two doors to one action now have two names"
        )
        XCTAssertTrue(
            chooser.contains("workItem.setImage(UIImage(systemName: \"tray.and.arrow.down.fill\"))"),
            "the two doors no longer carry the same symbol, so the row the driver knows from the root list is unrecognisable here"
        )
        XCTAssertEqual(
            scene.components(separatedBy: "carplay.picker.addToWork.title").count - 1, 2,
            "the desk row is built from a third place in the scene — a door nothing in this file describes"
        )

        // THE ROOT DOOR SURVIVES. This is the second door, not a replacement:
        // the root row is the only working row in the no-gateway state and the
        // shortest path to a note in every other.
        let picker = try RefusalLaneSource.body(
            ofFunction: "refreshPicker", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertEqual(
            picker.components(separatedBy: "makeWorkNoteItem(").count - 1, 2,
            "the one-tap root row was traded for the chooser row — the desk is now three taps away, and unreachable on a phone with no gateway at all"
        )

        // …AND NO THIRD DOOR. The chooser is pushed from exactly two places, and
        // both need gateways: the nav-bar switcher (≥2 configured) and the
        // repair step a broken default takes. Nothing about the Work row makes
        // the switcher appear where it did not before.
        XCTAssertEqual(
            scene.components(separatedBy: "presentGatewayChooser(").count - 1, 3,
            "the chooser is pushed from a third place — the second door now opens somewhere this guard cannot see"
        )
        XCTAssertTrue(
            Self.normalised(picker).contains("if configuredRefs.count >= 2 { current = await self.effectiveCarPlayRef() }"),
            "the switcher's gateway is resolved outside the ≥2 test, so a single-gateway phone grows a nav-bar button that exists only to reach the second door"
        )
        let switcher = try RefusalLaneSource.trailingClosure(
            after: "if let current {", in: Self.normalised(picker), path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            switcher.contains("self?.presentGatewayChooser("),
            "the switcher no longer opens the chooser from inside the `if let current` arm — the ≥2 test above stops governing who can reach it"
        )
    }

    /// Tapping the chooser's Work row starts a note through the SAME start
    /// claim, and stores nothing.
    ///
    /// Three separate contracts, and each is a boundary:
    ///
    /// • CLAIM BEFORE THE POP. The list underneath this one is "New voice chat".
    ///   The pop is a suspension; a claim taken on the far side of it leaves the
    ///   idle test open for that row, and the driver's note is answered by an AI
    ///   — the same race the root row's synchronous claim exists to close.
    /// • ONE CLAIM, CARRIED. The serial is passed into the presentation half,
    ///   never re-taken: a second `claimStart` would be refused by the claim
    ///   this tap is already holding, and the row would do nothing at all.
    /// • NO SESSION-LOCAL OVERRIDE. A gateway row stores this drive's target; a
    ///   Work row that stored anything would be the drive-long mode decision 1
    ///   refuses — reset silently by the next reconnect, and one tap from
    ///   handing a private thought to an AI.
    func testTheChoosersWorkRowStartsTheNoteOnTheSameClaimAndStoresNothing() throws {
        let scene = try Self.sceneDelegateSource()
        let chooser = Self.normalised(try RefusalLaneSource.body(
            ofFunction: "presentGatewayChooser", in: scene, path: Self.sceneDelegatePath
        ))
        let handler = try RefusalLaneSource.trailingClosure(
            after: "workItem.handler =", in: chooser, path: Self.sceneDelegatePath
        )

        let claim = try XCTUnwrap(
            handler.range(of: "self.claimStart(.work, service: service)"),
            "the chooser's Work row starts a note without claiming the single in-flight start"
        )
        let pop = try XCTUnwrap(
            handler.range(of: "popTemplate("),
            "the row starts a note without popping the chooser, so the voice modal goes up over a list that is still on the stack"
        )
        XCTAssertTrue(
            claim.upperBound < pop.lowerBound,
            "the claim is taken AFTER the pop: “New voice chat” is the row underneath this list, and a tap during the pop animation passes the idle test and answers this private note with an AI"
        )
        XCTAssertEqual(
            handler.components(separatedBy: "claimStart(").count - 1, 1,
            "the row claims twice — the second claim is refused by the first, and the desk row does nothing at all"
        )

        // Every exit hands the serial back. A claim leaked here shuts every row
        // in the picker for the rest of the drive.
        XCTAssertTrue(
            handler.contains(
                "guard let controller = self.interfaceController else { self.releaseStart(serial) return }"
            ),
            "a tap with no interface controller pops nothing and keeps the claim — the next tap on any row is refused for the rest of the drive"
        )
        let revalidation = try XCTUnwrap(
            handler.range(of: "self.startIsLive(serial, service: service)", range: pop.upperBound..<handler.endIndex),
            "nothing re-asks whether the claim is still live after the pop: a disconnect, a backgrounding or an End under the animation still reaches the microphone"
        )
        let refusalArm = try RefusalLaneSource.trailingClosure(
            after: "guard let service, success, self.startIsLive(serial, service: service) else",
            in: handler, path: Self.sceneDelegatePath
        )
        XCTAssertTrue(
            refusalArm.contains("self.releaseStart(serial)"),
            "a refused pop leaks the claim: nothing starts, and nothing can start again this drive"
        )
        XCTAssertTrue(
            refusalArm.trimmingCharacters(in: .whitespaces).hasSuffix("return }"),
            "the refusal arm falls through into the note it just refused"
        )
        XCTAssertNotNil(
            handler.range(of: "self.presentWorkNote(serial: serial, service: service)",
                          range: revalidation.upperBound..<handler.endIndex),
            "the row does not hand its serial to the shared presentation, so the note it starts is not the one the claim is holding"
        )
        // g1 stays where it is proven: the engine starts inside the PRESENT
        // completion, which is `presentWorkNote`'s contract and nobody else's.
        for forbidden in ["beginWorkNote(", "ensureVoicePresented("] {
            XCTAssertFalse(
                handler.contains(forbidden),
                "the chooser's row calls \(forbidden) itself, so the g1 audio-race contract now has a second, unproven copy"
            )
        }

        // STORES NOTHING. Not the override, not a destination, not a hint.
        for forbidden in ["sessionDefaultRefOverride", "lastStartDestination", "oneShotStartFailureHint"] {
            XCTAssertFalse(
                handler.contains(forbidden),
                "the chooser's Work row writes `\(forbidden)`: the tap outlives itself, and the state it leaves behind is read by the NEXT one"
            )
        }
        let override = try XCTUnwrap(chooser.range(of: "sessionDefaultRefOverride = ref"))
        let workRow = try XCTUnwrap(chooser.range(of: "carplay.picker.addToWork.title"))
        XCTAssertTrue(
            override.upperBound < workRow.lowerBound,
            "the drive's stored gateway is written at or below the Work row — the desk is being stored as this drive's destination"
        )

        // THE HANDLER, WHOLE. Every assertion above survives a statement moved
        // into a branch, and a claim taken inside an `if` is a claim the other
        // door never sees. Four statements and one completion; if a change here
        // is deliberate, restate the body.
        XCTAssertEqual(
            handler.trimmingCharacters(in: .whitespaces),
            "[weak self, weak service] _, completion in defer { completion() } "
            + "guard let self, let service else { return } "
            + "guard service === self.recordingService, !service.sessionActive else { return } "
            + "guard let serial = self.claimStart(.work, service: service) else { return } "
            + "guard let controller = self.interfaceController else { self.releaseStart(serial) return } "
            + "controller.popTemplate(animated: true) { [weak self, weak service] success, _ in "
            + "Task { @MainActor in guard let self else { return } "
            + "guard let service, success, self.startIsLive(serial, service: service) else { self.releaseStart(serial) return } "
            + "self.presentWorkNote(serial: serial, service: service) } } }",
            "the chooser's Work row is no longer the claim-pop-revalidate-present sequence it was written as — restate it here if the change is deliberate"
        )
    }

    /// A note taken from the chooser leaves NOTHING behind for the next tap.
    ///
    /// The whole cost of a second door is what it might make sticky. This is the
    /// answer: the only thing the tap writes is the start claim, and every exit
    /// hands that back — so the next "New voice chat" resolves its gateway from
    /// exactly the state it would have had if the desk row had never been
    /// tapped.
    func testAWorkNoteFromTheChooserLeavesNothingBehindForTheNextTap() throws {
        let scene = try Self.sceneDelegateSource()

        // The claim is the only thing a Work note holds, and the presentation
        // gives it back on BOTH of its exits (the refusal and the begin) — those
        // two are pinned by the starters guard; this is the count, so a third
        // exit added later cannot quietly keep it.
        let presentation = try RefusalLaneSource.body(
            ofFunction: "presentWorkNote", in: scene, path: Self.sceneDelegatePath
        )
        XCTAssertEqual(
            presentation.components(separatedBy: "releaseStart(serial)").count - 1, 2,
            "the Work note's presentation has an exit that keeps the claim — after that note, every row in the picker is refused for the rest of the drive"
        )

        // The destination is named at the ROW, as a literal, on both doors.
        // Reading it from state is what turns one Work tap into a drive-long
        // mode, and it is the single edit that would do it.
        let normalisedScene = Self.normalised(scene)
        for (door, statement) in [
            ("the root row", "guard let serial = claimStart(.work, service: service) else { return } presentWorkNote(serial: serial, service: service)"),
            ("the chooser row", "guard let serial = self.claimStart(.work, service: service) else { return }")
        ] {
            XCTAssertTrue(
                normalisedScene.contains(statement),
                "\(door)'s destination is no longer the literal `.work` handed to the claim — a stored destination decides it, and the tap starts outliving itself"
            )
        }

        // The scene still keeps exactly three destination-shaped things: the
        // claim's own tuple, the hint's record of the last start, and
        // `claimStart`'s parameter. A second door is a second opportunity to add
        // a fourth.
        XCTAssertEqual(
            scene.components(separatedBy: "CarPlayCaptureDestination").count - 1, 3,
            "the scene holds a fourth destination — a mode the chooser's row could set and the next tap could read"
        )

        // …and exactly four writes of this drive's gateway, each of them named.
        // A fifth is where a Work tap would store one.
        XCTAssertEqual(
            scene.components(separatedBy: "sessionDefaultRefOverride =").count - 1, 4,
            "a fifth writer of this drive's gateway; the census below no longer accounts for who re-points a drive"
        )
        for (owner, count) in [
            ("startSession", 2),          // adopt on `.proceed`, clear on `.chooseInstead`
            ("presentGatewayChooser", 1), // the gateway rows' pick
            ("disconnectCleanup", 1)      // the cable drops, the drive ends
        ] {
            XCTAssertEqual(
                try RefusalLaneSource.body(
                    ofFunction: owner, in: scene, path: Self.sceneDelegatePath
                ).components(separatedBy: "sessionDefaultRefOverride =").count - 1,
                count,
                "`\(owner)` no longer holds its \(count) write(s) of this drive's gateway — the census above now covers something else"
            )
        }

        // And the next tap reads that same one thing. `effectiveCarPlayRef` is
        // the whole of what a new chat's target depends on, so a Work note that
        // wrote nothing above cannot have moved it.
        XCTAssertEqual(
            Self.closedBody(try RefusalLaneSource.body(
                ofFunction: "effectiveCarPlayRef", in: Self.normalised(scene), path: Self.sceneDelegatePath
            )),
            "if let override = sessionDefaultRefOverride { return override } "
            + "return await SettingsManager.shared.defaultRemoteAgentRef()",
            "the effective gateway is resolved from something other than the drive's override and the phone's default — whatever that is, a Work note might now be able to move it"
        )
    }

    // MARK: - (6) Whose session is this?

    /// THE QUESTION EVERY OTHER GUARD IN THIS FILE ASKS, pinned whole.
    ///
    /// Nine assertions across this bundle search for `isCurrentListen(` and
    /// stop there. Dropping the generation comparison inside it — leaving
    /// `sessionActive` alone — satisfies every one of them while the answer
    /// becomes "is SOME session live", which is yes for the session that
    /// REPLACED this startup. That single edit re-opens the stale-commit, the
    /// stale-refusal and the desk-write races together, so the two-line body is
    /// its own contract and is asserted as one.
    func testTheListenLineageAsksBothHalves() throws {
        let source = Self.normalised(try Self.recordingServiceSource())
        let body = Self.closedBody(try RefusalLaneSource.body(
            ofFunction: "isCurrentListen", in: source, path: Self.recordingServicePath
        ))
        XCTAssertEqual(
            body, "sessionActive && listenAttemptID == attemptID",
            "the lineage question answers for whatever session is live rather than for THIS listen — every `isCurrentListen(` search in this bundle still passes, and a superseded startup commits its engine onto its replacement"
        )
    }

    /// The STT preflight answers for BOTH lanes or for neither.
    ///
    /// `endRefusalBelowFork` takes its CHAT arm whenever `workCapture` is nil,
    /// and that arm is `endSession(speak:)` — which ends whatever session is
    /// live, not the one that raised the refusal. So a chat suspended in
    /// `STTKeyReadiness.resolve` while the driver ends it and taps "Add to
    /// Work" would resume with `.notConfigured`, speak "Add your STT key" into
    /// the note's session, and delete the partial recording. Scoping the check
    /// to `workCapture != nil` protected the lane that could already answer for
    /// itself and left the other one holding the knife.
    func testTheStalenessChecksAroundTheSpeechPreflightCoverBothDestinations() throws {
        let source = Self.normalised(try Self.recordingServiceSource())
        let body = try RefusalLaneSource.body(
            ofFunction: "processRecording", in: source, path: Self.recordingServicePath
        )
        let check = "guard isCurrentListen(attemptID) else { endBackgroundTask() return }"

        // NEITHER check may be conditioned on the destination. This is the exact
        // mutation the fix removes, so it is pinned by absence as well as by
        // presence.
        XCTAssertNil(
            body.range(of: "if workCapture != nil, !isCurrentListen(attemptID)"),
            "the staleness check is scoped to the Work lane again — a chat refusal resuming here ends the Work note that replaced it"
        )

        // One after the compression, ABOVE the fork.
        let compression = try XCTUnwrap(
            body.range(of: "await AudioCompressor.compress(audioData)"),
            "the compression is no longer where the shared body suspends — update this guard"
        )
        let fork = try XCTUnwrap(
            body.range(of: "if destination == .work {", range: compression.upperBound..<body.endIndex),
            "the Work fork moved — update this guard"
        )
        XCTAssertNotNil(
            body.range(of: check, range: compression.upperBound..<fork.lowerBound),
            "the compression suspends and neither lane asks whose listen resumed from it"
        )
        try assertAskedUnconditionally(
            in: body, after: compression, is: check,
            "the compression's staleness check sits inside a branch — `if workCapture != nil { guard … }` keeps its complete text and restores exactly the Work-scoped question the fix removed"
        )

        // One after the key verdict, ABOVE every refusal it feeds.
        let readiness = try XCTUnwrap(
            body.range(of: "await STTKeyReadiness.resolve("),
            "the key verdict is no longer resolved here — update this guard"
        )
        let firstRefusal = try XCTUnwrap(
            body.range(of: "endRefusalBelowFork(", range: readiness.upperBound..<body.endIndex),
            "the key verdict no longer feeds a refusal — update this guard"
        )
        XCTAssertNotNil(
            body.range(of: check, range: readiness.upperBound..<firstRefusal.lowerBound),
            "the key question suspends and the refusal below it speaks into whatever session is live"
        )
        try assertAskedUnconditionally(
            in: body, after: readiness, is: check,
            "the key verdict's staleness check sits inside a branch — an old chat refusal resuming here again ends the Work note started in its place and deletes its partial recording"
        )
    }

    /// `check` is the FIRST `guard` after `anchor`, and nothing between them
    /// opens a block.
    ///
    /// Both callers already assert that the check is present and in range. That
    /// is satisfied by wrapping it: `if workCapture != nil { guard … }` keeps
    /// the complete text, in the right place, with no forbidden syntax anywhere
    /// — and is exactly the destination-scoped question the fix removed, which
    /// is the mutation this closes. A check reached only under a condition is
    /// not asked after a suspension; it is asked after a suspension sometimes.
    private func assertAskedUnconditionally(
        in body: String,
        after anchor: Range<String.Index>,
        is check: String,
        _ why: String
    ) throws {
        let tail = body[anchor.upperBound...]
        let next = try XCTUnwrap(tail.range(of: "guard "), why)
        XCTAssertTrue(String(tail[next.lowerBound...]).hasPrefix(check), why)
        XCTAssertFalse(tail[..<next.lowerBound].contains("{"), why)
    }

    /// A listen startup that was superseded may neither commit nor report.
    ///
    /// `isArmingListen` is a PROCESS latch, so End → "Add to Work" turns the
    /// replacement away at it while the old startup is still suspended in the
    /// VAD load or the engine retry. `sessionActive` is true again by the time
    /// that startup resumes — it just belongs to somebody else. Committing
    /// installs a running engine whose detector callbacks carry the invalidated
    /// attempt id (so the driver's speech never endpoints); failing ends the
    /// note they just started and paints the "Mic couldn't start" hint over it.
    func testASupersededListenStartupNeitherCommitsNorReports() throws {
        let source = Self.normalised(try Self.recordingServiceSource())
        let body = try RefusalLaneSource.body(
            ofFunction: "startListening", in: source, path: Self.recordingServicePath
        )

        // The generation is taken BEFORE the first suspension. Taken after one,
        // it would name whatever replaced this startup and answer "yes" to
        // every question below.
        let capture = try XCTUnwrap(
            body.range(of: "let attemptID = listenAttemptID"),
            "the startup no longer captures the generation it must carry"
        )
        // THE WHOLE ASSIGNMENT, with its neighbours. `listenAttemptID &+ 1`
        // reads as a prefix match of the search above and of every ordering
        // check below, while the startup carries an id it never owns: every
        // question it asks answers no, so it commits nothing, reports nothing
        // and hands the arming slot on to a session that is waiting for it.
        XCTAssertTrue(
            body.contains(
                "healthCollector = CapturePipelineHealthCollector() "
                + "let attemptID = listenAttemptID "
                + "var didActivateNow = false"
            ),
            "the startup captures something other than the lineage it just claimed — it then answers `no` to its own commit, its own failure report and its own hand-on"
        )
        let firstSuspension = try XCTUnwrap(
            body.range(of: "await "),
            "`startListening` no longer suspends; the scan is broken otherwise"
        )
        XCTAssertTrue(
            capture.lowerBound < firstSuspension.lowerBound,
            "the generation is captured after a suspension, so it names the startup that replaced this one"
        )
        let bump = try XCTUnwrap(body.range(of: "listenAttemptID &+= 1"))
        XCTAssertTrue(bump.lowerBound < capture.lowerBound,
                      "the capture reads the lineage before this startup has claimed it")

        // EVERY report of a start failure THAT CAN RESUME sits behind the
        // generation. A bare `sessionActive` here is the defect: the shared
        // terminal (`endSilentlyAfterCaptureStartFailure`) asks only that flag,
        // so it ends whichever session is live and paints the "Mic couldn't
        // start" hint over it. Scoped to reports that follow a suspension —
        // the audio-activation catch runs before this function has suspended at
        // all, and a generation check there would assert nothing.
        var searchFrom = body.startIndex
        var reports = 0
        var reportsAfterASuspension = 0
        while let report = body.range(
            of: "endSilentlyAfterCaptureStartFailure()", range: searchFrom..<body.endIndex
        ) {
            reports += 1
            searchFrom = report.upperBound
            guard let lastSuspension = body.range(
                of: "await ", options: .backwards, range: body.startIndex..<report.lowerBound
            ) else { continue }
            reportsAfterASuspension += 1
            XCTAssertNotNil(
                body.range(of: "isCurrentListen(attemptID)",
                           range: lastSuspension.upperBound..<report.lowerBound),
                "start-failure report #\(reports) resumes from a suspension and is raised without asking whether this startup is still the live one"
            )
        }
        XCTAssertGreaterThanOrEqual(
            reports, 4, "found \(reports) start-failure reports; the scanner is probably broken"
        )
        XCTAssertGreaterThanOrEqual(
            reportsAfterASuspension, 3,
            "no start-failure report follows a suspension; the scanner is probably broken"
        )

        // The COMMIT asks the generation, never the bare flag. This is the arm
        // that installs the engine and the detector.
        let commit = try XCTUnwrap(
            body.range(of: "guard isCurrentListen(attemptID) else { Self.log.info(\"CarPlay listen abort: startup superseded during engine start"),
            "the engine-start commit is guarded by `sessionActive` again — it would commit this startup onto the session that replaced it"
        )
        let engineStart = try XCTUnwrap(body.range(of: "await startCaptureEngineWithRetry("))
        let tap = try XCTUnwrap(
            body.range(of: "engineConfigChangeObserver =", range: commit.upperBound..<body.endIndex),
            "the commit no longer installs the reconfig observer — update this guard"
        )
        XCTAssertTrue(engineStart.lowerBound < commit.lowerBound && commit.lowerBound < tap.lowerBound,
                      "the commit guard no longer sits between the engine start and the state it commits")

        // And the arming slot is handed on, or the replacement session sits
        // there with End on the screen and a microphone that never started.
        XCTAssertGreaterThanOrEqual(
            body.components(separatedBy: "handOnArmingSlotAfterAbandonedStartup()").count - 1, 4,
            "a superseded startup disposes of its capture and keeps the arming latch; nothing re-arms the session that was turned away at it"
        )
        let handOn = try RefusalLaneSource.body(
            ofFunction: "handOnArmingSlotAfterAbandonedStartup", in: source, path: Self.recordingServicePath
        )
        // WHOLE, because both searches below survive a condition that is never
        // true: `if state == .recording { Task { … } }` keeps the guard, keeps
        // the task, and hands the arming slot to nobody — the replacement
        // session sits on a Listening screen with a microphone that never
        // started and an End button that ends it.
        XCTAssertEqual(
            Self.closedBody(handOn),
            "guard sessionActive, state == .idle else { return } "
            + "Self.log.info(\"CarPlay startup superseded — re-arming for the session that replaced it\") "
            + "Task { await startListening(isFollowUp: false) }",
            "the hand-on no longer unconditionally re-arms the live idle session waiting for the slot this startup abandoned"
        )
    }

    /// A present completion acts for ITS presentation and no other.
    ///
    /// Connection identity is not presentation identity: a start can be
    /// presented, cancelled by a backgrounding, and replaced by a second start
    /// on the SAME controller while the first `presentTemplate` callback is
    /// still outstanding. That callback used to pass the controller check and
    /// clear `isVoicePresented` — leaving a live modal behind a flag reading
    /// "nothing presented", which lets a later state change present a second
    /// time and makes `ensureVoiceDismissed` return at End without dismissing.
    func testAPresentCompletionActsOnlyForItsOwnPresentation() throws {
        let scene = Self.normalised(try Self.sceneDelegateSource())

        // The generation moves on EVERY write of the flag. A bump at each call
        // site instead would be opted out of by the ninth write somebody adds.
        XCTAssertTrue(
            scene.contains("private var isVoicePresented = false { didSet { presentationGeneration &+= 1 } }"),
            "the presentation flag no longer carries its generation, so a write from anywhere leaves stale callbacks looking current"
        )
        // …and NOTHING ELSE writes it. The `didSet` is not a guarantee on its
        // own: a `presentationGeneration = 0` before each flag write leaves the
        // bump in place, the declaration intact and every ordering assertion
        // below passing, while both presentations run as generation 1 and each
        // completion answers for the other. The counter is monotonic or it is
        // not an identity, so the only permitted write is the increment.
        // A CENSUS, not a regex. `presentationGeneration &= 0` before a flag
        // write is a plain-assignment pattern's blind spot, and so is every
        // other compound operator; the counter is monotonic or it is not an
        // identity, so the whole file is asked to name its four mentions.
        XCTAssertEqual(
            scene.components(separatedBy: "presentationGeneration").count - 1, 4,
            "the presentation generation is touched from a fifth place — a reset there makes two presentations share generation 1, and each completion then answers for the other"
        )
        for mention in [
            "private var presentationGeneration: UInt64 = 0",
            "didSet { presentationGeneration &+= 1 }",
            "let generation = presentationGeneration",
            "guard self.presentationGeneration == generation else"
        ] {
            XCTAssertTrue(
                scene.contains(mention),
                "`\(mention)` is gone — the census above now covers something else"
            )
        }
        XCTAssertEqual(
            scene.components(separatedBy: "presentationGeneration &+= 1").count - 1, 1,
            "the generation is bumped from more than one place; a second bump site is a second rule, and the one nobody updates is the one that lies"
        )

        let body = try RefusalLaneSource.body(
            ofFunction: "ensureVoicePresented", in: scene, path: Self.sceneDelegatePath
        )
        // Taken AFTER the write that owns this presentation, and before the
        // call. Taken before the write, it would be one behind from the start.
        let claim = try XCTUnwrap(body.range(of: "isVoicePresented = true"))
        let generation = try XCTUnwrap(
            body.range(of: "let generation = presentationGeneration", range: claim.upperBound..<body.endIndex),
            "the presentation takes no identity, so its completion cannot tell itself from the one that replaced it"
        )
        let present = try XCTUnwrap(
            body.range(of: "controller.presentTemplate(", range: generation.upperBound..<body.endIndex),
            "the generation is taken after the present — update this guard"
        )
        XCTAssertTrue(claim.lowerBound < generation.lowerBound && generation.lowerBound < present.lowerBound)

        // The guard sits ABOVE both arms, because both write presentation
        // state: the failure arm clears the flag, the success arm activates a
        // voice state on a template it may no longer own.
        let obsolete = try XCTUnwrap(
            body.range(of: "guard self.presentationGeneration == generation else { completion?(false) return }",
                       range: present.upperBound..<body.endIndex),
            "an obsolete present completion still changes presentation state — and answers its caller as though it were the live one"
        )
        let failureArm = try XCTUnwrap(
            body.range(of: "guard success else {", range: present.upperBound..<body.endIndex),
            "the completion no longer forks on `success` — update this guard"
        )
        let clearsFlag = try XCTUnwrap(
            body.range(of: "self.isVoicePresented = false", range: present.upperBound..<body.endIndex),
            "the failure arm no longer clears the flag — update this guard"
        )
        let activates = try XCTUnwrap(
            body.range(of: "activateVoiceControlState(withIdentifier: live)", range: present.upperBound..<body.endIndex),
            "the success arm no longer activates a live state — update this guard"
        )
        XCTAssertTrue(obsolete.lowerBound < failureArm.lowerBound,
                      "the identity check runs after the failure fork, so the flag is already cleared over somebody else's modal")
        XCTAssertTrue(obsolete.lowerBound < clearsFlag.lowerBound)
        XCTAssertTrue(obsolete.lowerBound < activates.lowerBound,
                      "the identity check runs after the success arm, so an obsolete present repaints the live modal's state")

        // The controller check stays: it answers a DIFFERENT question (a torn
        // -down connection), and neither subsumes the other.
        XCTAssertTrue(
            body.contains("guard self.interfaceController === controller else { completion?(false) return }"),
            "the connection-identity check is gone; a present from a previous connection answers for this one"
        )
    }

    // MARK: - Source access

    /// Whitespace-normalised source, for the guards that assert what FOLLOWS
    /// what: a wrapped call and a one-line call have to read identically, or
    /// these assertions fail on reformatting rather than on drift.
    private static func normalised(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A function body without the `}` that closes it — `body(ofFunction:)`
    /// keeps that brace, and a whole-body pin is easier to read against the
    /// source when the statements are all there is.
    private static func closedBody(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasSuffix("}") { body.removeLast() }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// The index just past the `}` closing the block opened by the first `{` at
    /// or after `from`.
    ///
    /// Needed wherever a guard has to tell "the check inside the refusal arm"
    /// from "the check after it". A plain forward search finds the arm's own
    /// copy and keeps passing while the one that matters is deleted — which is
    /// exactly how the ownership guard below admitted its own mutation.
    static func endOfBlock(openingAt from: String.Index, in text: String) -> String.Index? {
        guard let opening = text.range(of: "{", range: from..<text.endIndex) else { return nil }
        var index = opening.upperBound
        var depth = 1
        while index < text.endIndex, depth > 0 {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" { depth -= 1 }
            index = text.index(after: index)
        }
        return depth == 0 ? index : nil
    }

    private static let recordingServicePath = "Conduck/CarPlay/CarPlayRecordingService.swift"
    private static let sceneDelegatePath = "Conduck/CarPlay/CarPlaySceneDelegate.swift"

    private static func recordingServiceSource() throws -> String {
        try RefusalLaneSource.source(at: recordingServicePath)
    }

    private static func sceneDelegateSource() throws -> String {
        try RefusalLaneSource.source(at: sceneDelegatePath)
    }
}

/// A two-case `@Observable` stand-in for `CarPlayRecordingService.state`, so
/// the one assumption every hand-driven `.idle` transition in the scene rests
/// on can be EXECUTED rather than asserted about in a comment: assigning the
/// value a property already holds publishes nothing to
/// `withObservationTracking`. The real service cannot stand in for it — it owns
/// an audio engine and a `CPVoiceControlTemplate` — and the assumption is
/// Observation's, not the service's.
@Observable final class EqualAssignmentProbe {
    enum Value: Equatable { case idle, recording }
    var value: Value = .idle

    /// A tally the observation callback can write to. `onChange` is `@Sendable`,
    /// so a captured local `var` cannot be mutated from it; the callback is
    /// delivered synchronously on the mutating thread, so there is nothing here
    /// to synchronise.
    final class Tally: @unchecked Sendable {
        var count = 0
    }
}

#endif

// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WatchWorkRelayRecoveryTests.swift
//
// What the iPhone owes a wrist Work capture once it has answered.
//
// The acknowledgement this lane ships for a published recording with no words
// is a ONE-WAY DOOR: it is cached, so no re-fire ever reaches the speech
// provider again, and the wrist deletes its queued clip on reading it. The
// receipt the wrist then shows — "Saved to Work. Add the words on your iPhone."
// — is the same sentence CarPlay speaks for the same state, and CarPlay can
// keep it because its Work lane parks the capture before speech runs at all
// (`CarPlayRecordingService.secureWorkNote`). These cases hold this lane to the
// same promise, and hold the retryable branch to NOT walking through that door.
//
// PLATFORM GATE: `#if os(iOS)` — `AppleSpeechRelayCoordinator` exists only
// where WatchConnectivity does.

#if os(iOS)

import XCTest
@testable import Conduck

final class WatchWorkRelayRecoveryTests: XCTestCase {

    /// The durable arm, captured rather than performed: the production store
    /// writes the process-global App-Group container every other capture test
    /// in this bundle shares.
    private final class RecordingLane: PendingRetryQueueWriting, @unchecked Sendable {
        var saves: [(audio: Data, metadata: PendingRetryMetadata, image: Data?)] = []
        func save(audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?) async throws {
            saves.append((audio: audioData, metadata: metadata, image: workImageData))
        }
    }

    // MARK: - The record the wrist's receipt promises

    func testASettledSpeechFailureParksTheWordsTheWristIsSentToTheIPhoneFor() async throws {
        let lane = RecordingLane()
        let card = UUID()
        let clip = Data(repeating: 0xA7, count: 512)

        await AppleSpeechRelayCoordinator.preserveRelayedWorkWords(
            cardID: card,
            audio: clip,
            language: "en-US",
            errorCode: AppError.sttMissingAPIKey.errorCode,
            lane: lane
        )

        XCTAssertEqual(
            lane.saves.count, 1,
            """
            Nothing was parked before the acknowledgement. The wrist deletes its only queued copy \
            on reading that reply and is told to add the words on the iPhone — and with no record \
            here there is no capture for the retry card to offer, so restoring the key changes \
            nothing for this recording.
            """
        )
        let saved = try XCTUnwrap(lane.saves.first)
        XCTAssertEqual(saved.audio, clip, "A record with different bytes finishes a different recording.")
        XCTAssertEqual(
            saved.metadata.id, card,
            "The record's id IS the desk card's, or the recovery mints a second recording beside the one already on the desk instead of attaching to it."
        )
        XCTAssertEqual(saved.metadata.resolvedDestination, .work,
                       "A chat record would send these words to a gateway — the one thing this lane exists to prevent.")
        XCTAssertEqual(
            saved.metadata.publicationState, .published,
            "Without the verdict, an id that later names no card reads as a write that never happened, and the recovery resurrects a recording the person deleted."
        )
        XCTAssertNil(saved.metadata.transcript,
                     "There are no words yet — that is the whole reason this record exists.")
        XCTAssertEqual(saved.metadata.preferredLanguage, "en-US",
                       "The retry must ask for the same language the capture did.")
        XCTAssertEqual(saved.metadata.lastErrorCode, AppError.sttMissingAPIKey.errorCode)
        XCTAssertNil(saved.image, "The wrist sends no screenshot on this lane.")
        XCTAssertEqual(
            saved.metadata.retryTTL, PendingRetryMetadata.publishedWorkRetryTTL,
            "A published Work record is on the day-long clock, not the ten-minute one a person holding the failing device is offered."
        )
    }

    /// NEGATIVE CONTROL, and the one shape that must park nothing: no bytes
    /// means phase one never ran, and a queued record holding no recording is
    /// one every retry surface begins by failing to transcribe.
    func testAWorkRecordIsNeverParkedWithoutTheRecordingBehindIt() async {
        let lane = RecordingLane()

        await AppleSpeechRelayCoordinator.preserveRelayedWorkWords(
            cardID: UUID(), audio: nil, language: nil, errorCode: 23, lane: lane
        )
        await AppleSpeechRelayCoordinator.preserveRelayedWorkWords(
            cardID: UUID(), audio: Data(), language: nil, errorCode: 23, lane: lane
        )

        XCTAssertTrue(
            lane.saves.isEmpty,
            "An entry with no audio sits in the queue offering a retry that cannot work."
        )
    }

    /// The record above is worth nothing if the acknowledgement ships without
    /// it, and that call site has no behavioural test behind it (driving
    /// `processRelayRequest` needs a paired `WCSession` and a live speech
    /// provider). So it is pinned where it lives: between the settled verdict
    /// and the reply that closes the door on it.
    func testTheSettledAcknowledgementParksTheCaptureBeforeItShips() throws {
        let code = Self.strippingComments(try Self.coordinatorSource())
        let settledVerdict = try XCTUnwrap(
            code.range(of: "acknowledgesRecording(after: appError)"),
            "extractor sanity: the settled-verdict test must be in the stripped source"
        )
        let acknowledgement = try XCTUnwrap(
            code.range(of: "shipWorkRecordingAcknowledgement(", range: settledVerdict.upperBound..<code.endIndex),
            "extractor sanity: the settled arm must still ship the acknowledgement"
        )
        XCTAssertTrue(
            code[settledVerdict.upperBound..<acknowledgement.lowerBound].contains("preserveRelayedWorkWords"),
            """
            The settled acknowledgement ships without parking the capture. That reply is cached \
            and the wrist deletes its only queued copy on reading it, so the receipt it then \
            shows — "Add the words on your iPhone." — sends the person to a phone that has \
            nothing of this capture to finish.
            """
        )
    }

    // MARK: - The branch that must NOT walk through the one-way door

    /// A phase-2 write that the identical bytes could still land is answered as
    /// an ERROR, so the wrist keeps its entry and re-fires. The verdict helper
    /// says which answers are which; this pins the ORCHESTRATION — that the
    /// retryable arm leaves the request before the success verdict is cached
    /// and shipped. Structural because the regression is a deleted `return`
    /// that compiles and whose damage (a cached "here are your words" reply
    /// carrying none, memoised for every re-fire) no helper assertion sees.
    func testTheRetryableAttachmentLeavesBeforeTheSuccessVerdictIsCached() throws {
        let code = Self.strippingComments(try Self.coordinatorSource())
        let retryableArm = try XCTUnwrap(
            code.range(of: "case .retryable:"),
            "extractor sanity: the attachment switch's retryable arm must be in the stripped source"
        )
        let successCache = try XCTUnwrap(
            code.range(of: "let workSaved = workCardID != nil"),
            "extractor sanity: the success verdict's cache write must be in the stripped source"
        )
        XCTAssertLessThan(
            retryableArm.lowerBound, successCache.lowerBound,
            "extractor sanity: the retryable arm runs before the success verdict in this file"
        )
        XCTAssertTrue(
            code[retryableArm.upperBound..<successCache.lowerBound].contains("return"),
            """
            The retryable attachment arm falls THROUGH to the success verdict. It replies a \
            retryable code so the wrist keeps its clip and re-fires — and then caches a success \
            for the same requestID, which every re-fire is answered from. The words never land \
            and no attempt can ever add them.
            """
        )
    }

    // MARK: - Fixtures

    /// The coordinator's source, from this file's compile-time path so it holds
    /// regardless of the runner's working directory.
    private static func coordinatorSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Conduck/Services/AppleSpeechRelayCoordinator.swift"),
            encoding: .utf8
        )
    }

    /// Swift source with every comment removed, so a guard reads CODE and not
    /// the prose that describes it.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        let characters = Array(source)
        var index = 0
        var inLine = false
        var inBlock = false
        var inString = false
        while index < characters.count {
            let ch = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inLine {
                if ch == "\n" { inLine = false; out.append(ch) }
            } else if inBlock {
                if ch == "*", next == "/" { inBlock = false; index += 1 }
            } else if inString {
                if ch == "\\" { index += 2; continue }
                if ch == "\"" { inString = false }
                out.append(ch)
            } else if ch == "/", next == "/" {
                inLine = true
                index += 1
            } else if ch == "/", next == "*" {
                inBlock = true
                index += 1
            } else {
                if ch == "\"" { inString = true }
                out.append(ch)
            }
            index += 1
        }
        return out
    }
}

#endif

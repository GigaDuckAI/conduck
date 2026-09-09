// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WatchWorkRelayRecoveryTests.swift
//
// What the iPhone owes a wrist Work capture once it has answered.
//
// The acknowledgement this lane ships for a parked clip with no words is a
// ONE-WAY DOOR: it is cached, so no re-fire ever reaches the speech provider
// again, and the wrist deletes its queued clip on reading it. Everything that
// receipt then promises has to exist on THIS side of the door, and one record
// is the whole of it — the entry the failed request parked before speech and
// handed back on the way out, which the phone's own retry card claims and
// finishes.
//
// These cases hold the lane to that promise: the park's verdict is the one a
// recovery can act on, and the exits that ship the door hand the capture back
// first.
//
// PLATFORM GATE: `#if os(iOS)` — `AppleSpeechRelayCoordinator` exists only
// where WatchConnectivity does.

#if os(iOS)

import XCTest
@testable import Conduck

final class WatchWorkRelayRecoveryTests: XCTestCase {

    /// The retry lane over a directory of this case's own: the production store
    /// writes the process-global App-Group container every other capture test in
    /// this bundle shares.
    private var container: URL!
    private var lane: PendingRetryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-relay-recovery-\(UUID().uuidString)", isDirectory: true)
        lane = PendingRetryStore(containerURL: container, defaults: InMemoryDefaultsStore())
    }

    override func tearDownWithError() throws {
        lane = nil
        if let container { try? FileManager.default.removeItem(at: container) }
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - The record the wrist's receipt promises

    /// The verdict is written UP FRONT, at the park, not after a failure. It is
    /// the ordinary state of a fresh Work capture — the desk holds nothing, so
    /// these bytes are the only copy of what was said — and it is what makes the
    /// entry exempt from every clock. A record that said `.published` here would
    /// be swept on the day-long clock while the words were still owed.
    func testTheParkVerdictSaysTheDeskHoldsNothingForThisCapture() async throws {
        let claim = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
            requestID: UUID().uuidString,
            audio: Data(repeating: 0xA7, count: 512),
            language: "en-US",
            lane: lane
        )

        let parked = claim.entry.metadata
        XCTAssertEqual(
            parked.publicationState, .phaseOneFailed,
            """
            Without this verdict the entry is on a clock, and the recording it shelters is the only \
            copy of what the person said. Nothing is on the desk until the words arrive.
            """
        )
        XCTAssertEqual(
            parked.resolvedDestination, .work,
            "A chat record would send these words to a gateway — the one thing this lane prevents."
        )
        XCTAssertNil(
            parked.transcript,
            "There are no words yet — that is the whole reason this record exists."
        )
        XCTAssertEqual(parked.sourceDevice, "watch")
        XCTAssertEqual(parked.preferredLanguage, "en-US",
                       "The retry must ask for the same language the capture did.")
        XCTAssertTrue(
            parked.isExemptFromExpiry,
            "No clock retires the only copy of a recording whose words are still owed."
        )
        XCTAssertNil(parked.retryTTL, "An exempt record is on no clock, not a longer one.")
    }

    /// NEGATIVE CONTROL, and the state the park refuses to report: a save that
    /// landed without a RESERVATION is not a park. The entry would be claimable
    /// by the retry card while the relay was still transcribing, and the reply
    /// would be a durability claim about somebody else's work.
    func testACaptureAnotherSurfaceHoldsIsNeverReportedAsParked() async throws {
        let requestID = UUID().uuidString
        let captureID = AppleSpeechRelayCoordinator.workCaptureID(forRequestID: requestID)
        try await lane.save(
            audioData: Data(repeating: 0x5A, count: 512),
            metadata: PendingRetryMetadata(
                id: captureID,
                createdAt: Date(),
                audioFileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("relay-work-\(captureID.uuidString).m4a"),
                preferredLanguage: nil,
                attemptCount: 1,
                lastErrorCode: nil,
                destination: .work,
                publicationState: .phaseOneFailed,
                sourceDevice: "watch"
            ),
            workImageData: nil
        )
        let elsewhere = await lane.claim(id: captureID, duration: 600)
        XCTAssertNotNil(elsewhere, "fixture: another surface holds this capture")

        do {
            _ = try await AppleSpeechRelayCoordinator.parkRelayedWorkClip(
                requestID: requestID,
                audio: Data(repeating: 0x5A, count: 512),
                language: nil,
                lane: lane
            )
            XCTFail("a capture this request does not hold must never be reported as parked")
        } catch {
            // The retryable verdict the live path then ships: the wrist keeps
            // its clip and re-fires, and by then the other surface has finished.
        }
    }

    /// The record above is worth nothing if the acknowledgement ships without
    /// handing the capture back, and that call site has no behavioural test
    /// behind it (driving `processRelayRequest` needs a paired `WCSession` and a
    /// live speech provider). So it is pinned where it lives: before the reply
    /// that closes the door on it.
    func testTheAcknowledgementHandsTheCaptureBackBeforeItShips() throws {
        let code = Self.strippingComments(try Self.coordinatorSource())
        var searchStart = code.startIndex
        var arms = 0
        while let acknowledgement = code.range(
            of: "shipWorkRecordingAcknowledgement(", range: searchStart..<code.endIndex
        ) {
            searchStart = acknowledgement.upperBound
            let preceding = code[..<acknowledgement.lowerBound]
            // The helper's own declaration, further down the file, is not an arm.
            if preceding.hasSuffix("private func ") { continue }
            arms += 1

            let handBack = try XCTUnwrap(
                preceding.range(of: "handBackParkedClip(", options: .backwards),
                """
                An acknowledgement ships without handing the parked capture back. The wrist deletes \
                its only queued copy on reading that reply and is told the phone has it — and a \
                capture still under this request's lapsed reservation is one no retry card offers.
                """
            )
            // The hand-back belongs to THIS arm: nothing but this arm's own
            // statements may sit between the two, so an earlier arm's cannot be
            // mistaken for it.
            XCTAssertFalse(
                preceding[handBack.upperBound...].contains("shipWorkRecordingAcknowledgement("),
                "the hand-back belongs to an earlier arm, so this one ships the door with nothing behind it"
            )
        }
        XCTAssertEqual(
            arms, 3,
            """
            Three exits answer a parked capture with the acknowledgement — the refused publish, the \
            typed throw and the untyped throw. An arm that stopped doing so answers with an error, \
            and the wrist keeps a clip this phone already holds for ever.
            """
        )
    }

    // MARK: - The clear is what deletes the recording, and it comes last

    /// The bytes outlive the words by exactly the span of the desk write. A
    /// clear that ran first would leave a capture whose recording is gone and
    /// whose words never landed.
    func testTheRecordingSurvivesUntilTheWordsAreOnTheDesk() throws {
        let code = Self.strippingComments(try Self.coordinatorSource())
        let publish = try XCTUnwrap(
            code.range(of: "WorkVoiceCaptureCoordinator.publishTranscript("),
            "the desk write has moved or been renamed; re-anchor this guard"
        )
        let clear = try XCTUnwrap(
            code.range(of: "PendingRetryStore.shared.clear(parkedClip)"),
            "nothing deletes the parked recording, so the audio outlives the words it produced"
        )
        XCTAssertLessThan(
            publish.lowerBound, clear.lowerBound,
            """
            The entry is cleared BEFORE the words reach the desk. A refused write then finds the \
            only copy of the recording already deleted — and the wrist has been told the phone has \
            the capture.
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

// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkAudioPayloadRuleTests.swift
//
// One rule decides whether a payload is a recording, and three processes ask it:
// the app, the iOS share extension and the macOS share extension each compile
// their own copy of `WorkCaptureEnvelope`. The rule is what the desk's audio
// boundary is built on — a door that refuses recordings and a drainer that
// promotes them to playable cards both read this one answer — so the cases here
// pin the three annotations it consults, their order, and the one thing that is
// audible but is NOT a recording.
//
// Pure. Nothing is stored, nothing is transported, no store is opened.

import XCTest
@testable import Conduck

final class WorkAudioPayloadRuleTests: XCTestCase {

    // MARK: - The three annotations

    /// The MIME type is the annotation every share and Shortcut path fills in,
    /// so it is asked first and answers alone.
    func testAnAudioMIMETypeIsEnoughOnItsOwn() {
        XCTAssertTrue(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: "audio/mp4",
                typeIdentifier: nil,
                filename: nil
            )
        )
        XCTAssertTrue(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: "AUDIO/MPEG",
                typeIdentifier: nil,
                filename: nil
            ),
            "a source app that shouts its MIME type is describing the same file"
        )
    }

    /// Sources that declare a UTI instead are the same recording. Conformance
    /// rather than equality, so any concrete audio type answers rather than only
    /// the handful worth spelling out.
    func testATypeIdentifierConformingToAudioAnswers() {
        XCTAssertTrue(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: nil,
                typeIdentifier: "public.mp3",
                filename: nil
            )
        )
        XCTAssertTrue(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: nil,
                typeIdentifier: "com.apple.m4a-audio",
                filename: nil
            )
        )
    }

    /// The last resort, and the one that matters most at the desk's own doors: a
    /// file dropped onto Work arrives as bytes and a name, with neither
    /// annotation filled in. Without this arm a dropped recording reads as an
    /// ordinary document.
    func testAFilenameExtensionAnswersWhenNeitherAnnotationIsPresent() {
        XCTAssertTrue(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: nil,
                typeIdentifier: nil,
                filename: "memo.m4a"
            )
        )
        XCTAssertTrue(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: nil,
                typeIdentifier: nil,
                filename: "Interview 3.MP3"
            ),
            "an extension is not case-sensitive to a person typing a name"
        )
    }

    // MARK: - What is not a recording

    func testADocumentIsNotARecording() {
        XCTAssertFalse(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf",
                filename: "proposal.pdf"
            )
        )
    }

    func testAnImageIsNotARecording() {
        XCTAssertFalse(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: "image/png",
                typeIdentifier: "public.png",
                filename: "IMG_0043.png"
            )
        )
    }

    /// A film is audible and is still not a recording. `public.movie` does not
    /// conform to `public.audio`, and treating one as audio would refuse a video
    /// at doors that exist to keep microphone captures off the desk — a refusal
    /// the person could do nothing about.
    func testAVideoIsAudibleAndIsStillNotARecording() {
        XCTAssertFalse(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: "video/mp4",
                typeIdentifier: "public.mpeg-4",
                filename: "clip.mp4"
            )
        )
        XCTAssertFalse(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: nil,
                typeIdentifier: nil,
                filename: "screen recording.mov"
            )
        )
    }

    /// Nothing to read is not a recording. A payload the source annotated with
    /// nothing at all has to fall through to the file lane rather than being
    /// refused on a guess.
    func testAPayloadWithNothingToReadIsNotARecording() {
        XCTAssertFalse(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: nil,
                typeIdentifier: nil,
                filename: nil
            )
        )
        XCTAssertFalse(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: nil,
                typeIdentifier: nil,
                filename: "Attachment"
            ),
            "a name with no extension says nothing about what the bytes are"
        )
        XCTAssertFalse(
            WorkCaptureEnvelope.isAudioPayload(
                mimeType: nil,
                typeIdentifier: "not.a.real.identifier.at.all",
                filename: nil
            ),
            "an identifier the system cannot resolve is an answer of no, not a crash"
        )
    }
}

// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardImportMappingTests.swift
//
// The two in-app doors into Work — the attachment button's file picker and a
// drop onto the Work pane — and the ONE decision they share: what shape the
// file they were handed draws as.
//
// It matters because of what surrounds it. Every OTHER door refuses a
// recording: the share sheet, the Add Files Shortcut, the share-inbox drainer
// and Chat to Work all turn one away and say where to add it. These two keep
// it, as a playable card and nothing more — nothing here transcribes — so this
// mapping is the whole of the permission, and a rule that quietly stopped
// recognising audio would turn a deliberate recording into an unplayable
// document with no error anywhere.
//
// The mapping is driven directly rather than through a mounted picker, because
// a `fileImporter` result and a drop provider cannot be produced in a unit
// test; what CAN be produced is the resolved batch both doors hand over, which
// is the last thing either of them decides for itself.

import Foundation
import XCTest
@testable import Conduck

final class WorkboardImportMappingTests: XCTestCase {

    // MARK: - What a file draws as

    /// The founder's case: a voice memo picked or dropped into Work is a card
    /// that plays, whether or not the system handed over a specific mime type.
    ///
    /// Negative control: without the audio branch every one of these is `.file`
    /// — an openable document with no transport — and all three fail.
    func testARecordingBecomesAPlayableCardFromItsMimeTypeOrItsName() {
        XCTAssertEqual(
            WorkboardImportMapping.materialKind(filename: "memo.m4a", mimeType: "audio/mp4"),
            .audio
        )
        XCTAssertEqual(
            WorkboardImportMapping.materialKind(filename: "memo.m4a", mimeType: nil),
            .audio,
            "a drop that carried no mime type still names a recording by its extension"
        )
        XCTAssertEqual(
            WorkboardImportMapping.materialKind(
                filename: "interview.mp3",
                mimeType: "application/octet-stream"
            ),
            .audio,
            "a generic mime type says nothing, so the extension is what answers"
        )
    }

    /// A picture is still a picture, and it is decided FIRST: a format that
    /// both tables know must not be pulled into the audio arm.
    func testAPictureIsStillDecidedBeforeAnythingElse() {
        XCTAssertEqual(
            WorkboardImportMapping.materialKind(filename: "shot.png", mimeType: nil),
            .image
        )
        XCTAssertEqual(
            WorkboardImportMapping.materialKind(filename: "shot.png", mimeType: "image/png"),
            .image
        )
    }

    /// Everything that is not a picture and not audio stays a file — including
    /// a MOVIE, which is the boundary worth stating: a video is audiovisual
    /// content, not audio, and drawing a transport over it would promise a
    /// player the desk does not have.
    func testADocumentAndAMovieAreBothStillFiles() {
        XCTAssertEqual(
            WorkboardImportMapping.materialKind(filename: "proposal.pdf", mimeType: "application/pdf"),
            .file
        )
        XCTAssertEqual(
            WorkboardImportMapping.materialKind(filename: "clip.mov", mimeType: "video/quicktime"),
            .file,
            "a movie is audiovisual content; the desk has no transport for it"
        )
    }

    // MARK: - Through the batch both doors hand over

    /// The mapping where it actually runs. The picker and the drop each resolve
    /// their own batch and then converge here, so a recording that survives
    /// `materialKind` must also survive the import it is packed into: the file
    /// URL is what the store reads the bytes from, and a dropped name is what
    /// the card is called.
    ///
    /// Negative control: an audio arm that packed the item without its
    /// `fileURL` publishes a card with no payload — the URL assertion fails.
    func testAResolvedAudioFileIsPackedAsAnAudioImportWithItsBytesStillNamed() throws {
        let source = URL(fileURLWithPath: "/tmp/conduck-import-mapping/memo.m4a")
        let batch = WorkboardResolvedImportBatch(
            items: [.file(
                sourceURL: source,
                displayName: "memo.m4a",
                mimeType: "audio/mp4",
                byteCount: 4_096,
                // App-owned: a staged drop copy, which opens no security scope.
                isAppOwned: true
            )],
            failedCount: 0
        )

        let mapped = WorkboardImportMapping.imports(from: batch)
        let recording = try XCTUnwrap(mapped.imports.first)

        XCTAssertEqual(mapped.imports.count, 1)
        XCTAssertEqual(recording.kind, .audio)
        XCTAssertEqual(recording.name, "memo.m4a")
        XCTAssertEqual(recording.mimeType, "audio/mp4")
        XCTAssertEqual(recording.fileURL, source, "the bytes the card will be published from")
        XCTAssertEqual(recording.byteCount, 4_096)
        XCTAssertNil(recording.textContent, "nothing here transcribes")
        XCTAssertTrue(mapped.scopedURLs.isEmpty, "an app-owned copy opens no scope to close")
    }

    // MARK: - One audio rule

    /// The doors that KEEP a recording and the doors that REFUSE one read the
    /// same sniffer, so the pane holds exactly one audio rule. A second one
    /// written here is how a file the share sheet turned away would arrive
    /// through the picker as a plain document instead of a playable card.
    ///
    /// Negative control: reinstating a local `hasSuffix(".m4a")` test, or a
    /// second `UTType(...).conforms(to: .audio)` beside the mapping, makes the
    /// count 2 and this fails.
    func testThePaneAsksTheSharedSnifferExactlyOnce() throws {
        let source = try RefusalLaneSource.source(
            at: "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift"
        )
        XCTAssertEqual(
            source.components(separatedBy: "isAudioPayload(").count - 1,
            1,
            "one audio rule on the Work pane, and it is the shared sniffer"
        )
        let mapping = try RefusalLaneSource.body(
            ofFunction: "materialKind",
            in: source,
            path: "Conduck/Views/Workboard/WorkboardCaptureCanvas.swift"
        )
        XCTAssertTrue(
            mapping.contains("isAudioPayload("),
            "and it is asked inside the mapping both doors converge on"
        )
    }
}

// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureFileCaptureTests.swift
//
// The multi-file publication a Shortcut hands to `WorkCaptureInbox`: one
// envelope carrying every file in the order it was chosen, entry identities a
// rerun reproduces, and refusals that take the whole set rather than quietly
// dropping part of it. Nothing here touches Core Data, a gateway, or the
// network — a publication is bytes and a manifest on disk.
//
// One of those refusals is about what Work IS rather than about a limit: a
// recording. The desk keeps an audio file only when a person attaches it there
// themselves, and this lane is headless, so a set carrying one is refused whole
// and from the declaration alone — before a byte is copied.

import XCTest
@testable import Conduck

final class WorkCaptureFileCaptureTests: XCTestCase {
    private var root: URL!
    private var sources: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-files-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("inbox", isDirectory: true)
        sources = base.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        root = nil
        sources = nil
        try super.tearDownWithError()
    }

    // MARK: - One capture, every file

    func testEveryFileBecomesAnEntryInTheOrderItWasChosen() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID(uuidString: "9C0B7A3E-9E6E-4A2F-9A0D-2C2B9C1F44A1")!
        let first = try writeFile(named: "notes.txt", contents: "first")
        let second = try writeFile(named: "plan.pdf", contents: "second")
        let third = try writeFile(named: "sites.csv", contents: "third")

        let published = try await inbox.publishFileCapture(
            note: "Everything the surveyor sent",
            files: [
                input(first, mimeType: "text/plain", typeIdentifier: "public.plain-text"),
                input(second, mimeType: "application/pdf", typeIdentifier: "com.adobe.pdf"),
                input(third, mimeType: "text/csv", typeIdentifier: "public.comma-separated-values-text"),
            ],
            captureID: captureID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(published, captureID)

        let claimValue = try await inbox.claimNext()
        let claim = try XCTUnwrap(claimValue)
        XCTAssertEqual(claim.envelope.source, .shortcut,
                       "a Shortcut capture names its own source, not the app's")
        XCTAssertEqual(claim.envelope.note, "Everything the surveyor sent")
        XCTAssertEqual(claim.envelope.entries.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(claim.envelope.entries.map(\.kind), [.file, .file, .file])
        XCTAssertEqual(
            claim.envelope.entries.map(\.displayName),
            ["notes.txt", "plan.pdf", "sites.csv"]
        )
        XCTAssertEqual(
            claim.envelope.entries.map(\.mimeType),
            ["text/plain", "application/pdf", "text/csv"]
        )
        XCTAssertEqual(claim.envelope.entries.compactMap(\.byteCount), [5, 6, 5])

        for (offset, entry) in claim.envelope.entries.enumerated() {
            XCTAssertEqual(
                entry.id,
                WorkCaptureInbox.fileEntryID(forCapture: captureID, sequence: offset),
                "an entry is named by its capture and its position, never minted"
            )
            let payloadURL = try XCTUnwrap(claim.payloadURL(for: entry))
            XCTAssertEqual(payloadURL.lastPathComponent, entry.relativePath)
        }
        XCTAssertEqual(
            claim.envelope.entries.compactMap(\.relativePath),
            ["payload-000.txt", "payload-001.pdf", "payload-002.csv"]
        )
        let bytes = try claim.envelope.entries.map { entry in
            try Data(contentsOf: try XCTUnwrap(claim.payloadURL(for: entry)))
        }
        XCTAssertEqual(bytes, [Data("first".utf8), Data("second".utf8), Data("third".utf8)])
    }

    /// The identity a rerun depends on. A Shortcut killed after its publication
    /// republishes the same set, and every card it repairs has to be the card it
    /// wrote the first time rather than a second copy beside it.
    func testARepublishedCaptureDerivesTheSameEntryIdentities() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID(uuidString: "4F1A0C6B-1D1E-4B6C-8E44-6D1F0A9B3E21")!
        let files = [
            input(try writeFile(named: "one.txt", contents: "one")),
            input(try writeFile(named: "two.txt", contents: "two")),
        ]

        _ = try await inbox.publishFileCapture(note: nil, files: files, captureID: captureID)
        let firstValue = try await inbox.claimNext()
        let first = try XCTUnwrap(firstValue)
        try await inbox.acknowledge(first)

        _ = try await inbox.publishFileCapture(note: nil, files: files, captureID: captureID)
        let replayValue = try await inbox.claimNext()
        let replay = try XCTUnwrap(replayValue)

        XCTAssertEqual(replay.envelope.entries.map(\.id), first.envelope.entries.map(\.id))
        XCTAssertEqual(Set(replay.envelope.entries.map(\.id)).count, 2,
                       "two positions of one capture are two different cards")
    }

    /// Idempotency while the first envelope is still queued: a retry must not
    /// leave a second directory the drainer would import as a second capture.
    func testARepeatedCaptureIDPublishesNoSecondDirectory() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID()
        let files = [input(try writeFile(named: "one.txt", contents: "one"))]

        _ = try await inbox.publishFileCapture(note: "Once", files: files, captureID: captureID)
        _ = try await inbox.publishFileCapture(note: "Once", files: files, captureID: captureID)

        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(directories.map(\.lastPathComponent), [captureID.uuidString])
    }

    // MARK: - A picture is published as a picture

    /// The desk gives an `.image` entry a thumbnail and a place in the gallery,
    /// so a photo added from a Shortcut has to arrive as one — a picture landing
    /// as a generic file is a row the person opens one at a time to recognise.
    /// Either signal answers: a mime type (what a share sheet carries) or a type
    /// identifier (what a file-provider URL carries). Everything else stays a
    /// file.
    func testAnImageIsPublishedAsAnImageEntryAndOtherFilesStayFiles() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let byMIME = try writeFile(named: "sketch.png", contents: "png")
        let byTypeIdentifier = try writeFile(named: "photo.jpg", contents: "jpg")
        let document = try writeFile(named: "plan.pdf", contents: "pdf")

        _ = try await inbox.publishFileCapture(
            note: nil,
            files: [
                input(byMIME, mimeType: "image/png", typeIdentifier: nil),
                input(byTypeIdentifier, mimeType: nil, typeIdentifier: "public.jpeg"),
                input(document, mimeType: "application/pdf", typeIdentifier: "com.adobe.pdf"),
            ],
            captureID: UUID()
        )

        let claimValue = try await inbox.claimNext()
        let claim = try XCTUnwrap(claimValue)
        XCTAssertEqual(claim.envelope.entries.map(\.kind), [.image, .image, .file])
        for entry in claim.envelope.entries {
            XCTAssertNotNil(
                claim.payloadURL(for: entry),
                "an image entry is file-backed exactly as a file entry is"
            )
        }
    }

    // MARK: - Refusals take the whole set

    func testASetLargerThanTheEntryLimitIsRefusedWhole() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let files = try (0...WorkCaptureEnvelope.maximumEntryCount).map { index in
            input(try writeFile(named: "file-\(index).txt", contents: "x"))
        }

        do {
            _ = try await inbox.publishFileCapture(note: nil, files: files, captureID: UUID())
            XCTFail("A set above the entry limit must not be published, whole or trimmed")
        } catch {
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .tooManyEntries
            )
        }
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testAFileOverTheFileLimitIsRefused() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let oversized = try writeSparseFile(
            named: "huge.bin",
            byteCount: WorkCaptureEnvelope.maximumFileBytes + 1
        )

        do {
            _ = try await inbox.publishFileCapture(
                note: nil,
                files: [input(oversized)],
                captureID: UUID()
            )
            XCTFail("A file above the per-file ceiling must not be published")
        } catch {
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .invalidFileEntry
            )
        }
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testASetOverTheEnvelopeLimitIsRefusedBeforeAnyBytesAreCopied() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let each = WorkCaptureEnvelope.maximumEnvelopeBytes / 2
        let files = try (0..<3).map { index in
            input(try writeSparseFile(named: "half-\(index).bin", byteCount: each))
        }
        let captureID = UUID()

        do {
            _ = try await inbox.publishFileCapture(note: nil, files: files, captureID: captureID)
            XCTFail("A set above the envelope ceiling must not be published")
        } catch {
            XCTAssertEqual(
                error as? WorkCaptureInbox.InboxError,
                .invalidEnvelope(captureID, .envelopeTooLarge)
            )
        }
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(try stagedChildren().isEmpty,
                      "nothing is copied for a set the queue already knows it cannot carry")
    }

    /// A file the caller named but the queue cannot read is a contract
    /// violation, not a reason to publish the rest: the person chose all of
    /// them and would have no way of knowing which one never arrived.
    func testAMissingSourceRefusesTheWholeCapture() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let present = input(try writeFile(named: "present.txt", contents: "here"))
        let absent = WorkCaptureFileInput(
            url: sources.appendingPathComponent("gone.txt", isDirectory: false),
            displayName: "gone.txt",
            mimeType: "text/plain",
            typeIdentifier: nil,
            byteCount: 4
        )

        do {
            _ = try await inbox.publishFileCapture(
                note: nil,
                files: [present, absent],
                captureID: UUID()
            )
            XCTFail("A capture naming a file that is not there must be refused")
        } catch {
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .invalidFileEntry
            )
        }
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    /// The envelope's own emptiness rule still owns a capture with neither a
    /// note nor a file, exactly as the in-app publication does.
    func testACaptureWithNoNoteAndNoFilesIsRefused() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.publishFileCapture(note: "  ", files: [], captureID: UUID())
            XCTFail("An empty capture must not be published")
        } catch {
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .emptyCapture
            )
        }
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - The bytes the identity names are the bytes that land

    /// THE COLLISION THE DIGEST ALONE DOES NOT CLOSE. A capture id derived from
    /// a read of the SOURCE describes bytes that belong to somebody else's
    /// process: an editor, a sync client or a file provider can rewrite that
    /// file between the read that names the capture and the copy that publishes
    /// it, and the desk then repairs an existing card with content nothing ever
    /// described. Both runs are five bytes, so no size check can see it.
    ///
    /// The whole lane is exercised here — snapshot, identity, publication —
    /// because the property is a relationship BETWEEN those steps, and either
    /// one alone looks correct.
    func testASourceRewrittenAfterItsIdentityCannotPublishUnderTheEarlierCapture() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let source = input(try writeFile(named: "memo.txt", contents: "alpha"))
        let snapshots = sources.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)

        let snapshot = try AddFilesToWorkIntent.snapshot(
            source,
            into: snapshots.appendingPathComponent("payload-000.txt", isDirectory: false)
        )
        let captureID = AddFilesToWorkIntent.captureIdentity(note: nil, files: [snapshot])

        // The window the finding is about: the source changes between naming
        // the capture and publishing it.
        try Data("bravo".utf8).write(to: source.url, options: .atomic)

        _ = try await inbox.publishFileCapture(
            note: nil,
            files: [snapshot.input],
            captureID: captureID
        )
        let claimValue = try await inbox.claimNext()
        let claim = try XCTUnwrap(claimValue)
        let entry = try XCTUnwrap(claim.envelope.entries.first)
        let published = try Data(contentsOf: try XCTUnwrap(claim.payloadURL(for: entry)))

        XCTAssertEqual(
            published,
            Data("alpha".utf8),
            "the envelope carries the snapshot's bytes — the ones the capture id was derived from"
        )
        XCTAssertEqual(entry.byteCount, 5)

        // And the rewritten source is its own capture, so republishing it
        // cannot repair — that is, overwrite — the card above.
        let rewritten = try AddFilesToWorkIntent.snapshot(
            input(source.url),
            into: snapshots.appendingPathComponent("payload-001.txt", isDirectory: false)
        )
        XCTAssertNotEqual(
            AddFilesToWorkIntent.captureIdentity(note: nil, files: [rewritten]),
            captureID,
            "different bytes must never share a capture id: the second run would replace the first card"
        )
        XCTAssertEqual(
            try Data(contentsOf: rewritten.input.url),
            Data("bravo".utf8)
        )
    }

    // MARK: - A recording takes the whole set

    /// Work keeps an audio file only when a person attaches it at the desk
    /// itself. This lane is headless — it shows nobody what it kept — so a
    /// recording among the chosen files refuses the SET, the way every other
    /// verdict in this intent does: landing the documents and silently dropping
    /// the recording would tell a person who chose two files that one of them is
    /// what they captured.
    func testASetCarryingARecordingIsRefusedWhole() {
        let document = declared(named: "proposal.pdf", mimeType: "application/pdf", typeIdentifier: "com.adobe.pdf")
        let recording = declared(named: "memo.m4a", mimeType: "audio/mp4", typeIdentifier: "public.mpeg-4-audio")

        XCTAssertNil(AddFilesToWorkIntent.refusal(for: [document]))
        XCTAssertEqual(
            AddFilesToWorkIntent.refusal(for: [document, recording]),
            .audioFile(name: "memo.m4a"),
            "the refusal names the recording, not the document beside it"
        )
        XCTAssertNotNil(
            WorkFileCaptureRefusal.audioFile(name: "memo.m4a").errorDescription,
            "a shortcut shows the sentence, so there has to be one"
        )
    }

    /// Decided from the DECLARATION alone, before a byte is staged: these inputs
    /// name files that do not exist, and the verdict lands anyway. The intent
    /// calls this before it creates its staging directory, so a refused set
    /// never duplicates a person's file onto a disk they may be short of.
    func testARecordingIsRefusedBeforeAnythingIsStaged() throws {
        let recording = declared(named: "memo.m4a", mimeType: "audio/mp4", typeIdentifier: "public.mpeg-4-audio")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recording.url.path),
            "the case needs a declaration nothing has read"
        )
        XCTAssertEqual(AddFilesToWorkIntent.refusal(for: [recording]), .audioFile(name: "memo.m4a"))
        XCTAssertEqual(try stagedChildren().count, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).count,
            0,
            "no snapshot was written for a set that never becomes a capture"
        )
    }

    /// A source that annotates with a UTI instead of a MIME type is the same
    /// recording, and so is one that annotates with neither: the extension is
    /// the last thing asked, and it answers.
    func testARecordingDeclaredOnlyByTypeOrByNameIsRefusedToo() {
        XCTAssertEqual(
            AddFilesToWorkIntent.refusal(for: [
                declared(named: "interview", mimeType: nil, typeIdentifier: "public.mp3")
            ]),
            .audioFile(name: "interview"),
            "a UTI conforming to public.audio is a recording however the file is named"
        )
        XCTAssertEqual(
            AddFilesToWorkIntent.refusal(for: [
                declared(named: "voice.m4a", mimeType: nil, typeIdentifier: nil)
            ]),
            .audioFile(name: "voice.m4a")
        )
    }

    /// The residual, pinned so it is not mistaken for a leak: a file that
    /// declares nothing and carries no extension a recording is known by lands
    /// as an ordinary document. Nothing here reads bytes to guess — a headless
    /// process that sniffed every file would spend the memory this lane exists
    /// not to spend, and would still be guessing.
    func testAnUnannotatedFileIsNotTreatedAsARecording() {
        XCTAssertNil(
            AddFilesToWorkIntent.refusal(for: [
                declared(named: "recording", mimeType: nil, typeIdentifier: nil)
            ])
        )
        XCTAssertNil(
            AddFilesToWorkIntent.refusal(for: [
                declared(named: "walkthrough.mov", mimeType: "video/quicktime", typeIdentifier: "com.apple.quicktime-movie")
            ]),
            "a film is not a microphone capture; refusing it would close a door nobody asked to close"
        )
    }

    // MARK: - Fixtures

    private func input(
        _ url: URL,
        mimeType: String? = "text/plain",
        typeIdentifier: String? = nil
    ) -> WorkCaptureFileInput {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return WorkCaptureFileInput(
            url: url,
            displayName: url.lastPathComponent,
            mimeType: mimeType,
            typeIdentifier: typeIdentifier,
            byteCount: byteCount
        )
    }

    /// An input the way a shortcut hands one over — a name and whatever the
    /// graph declared — with no file behind it. The whole-set refusals are a
    /// pure function of the declaration, which is what lets them be taken
    /// before anything is copied.
    private func declared(
        named name: String,
        mimeType: String?,
        typeIdentifier: String?
    ) -> WorkCaptureFileInput {
        WorkCaptureFileInput(
            url: sources.appendingPathComponent(name, isDirectory: false),
            displayName: name,
            mimeType: mimeType,
            typeIdentifier: typeIdentifier,
            byteCount: 1_024
        )
    }

    private func writeFile(named name: String, contents: String) throws -> URL {
        let url = sources.appendingPathComponent(name, isDirectory: false)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    /// A file of a declared size without the blocks to back it. The size limits
    /// are hundreds of megabytes, and a suite that actually wrote them would
    /// fail on disk pressure rather than on the behaviour under test.
    private func writeSparseFile(named name: String, byteCount: Int64) throws -> URL {
        let url = sources.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
        return url
    }

    private func stagedChildren() throws -> [URL] {
        let staging = root.appendingPathComponent("tmp", isDirectory: true)
        guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
    }
}

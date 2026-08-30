// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureInboxTests.swift
//
// Pure filesystem/contract coverage for inert Workboard capture ingress: bounded
// metadata, cross-process wire parity, atomic claim/release/acknowledge, strict
// payload containment, and crash reconciliation. No gateway, Keychain, network,
// Core Data, or notification permission is touched.

import XCTest
@testable import Conduck

private final class OneShotManifestAccessFailureFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.lock()
        let failNow = shouldFail
            && path.contains("/processing/")
            && path.hasSuffix("/manifest.json")
        if failNow { shouldFail = false }
        lock.unlock()

        if failNow {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoPermissionError
            )
        }
        return try super.attributesOfItem(atPath: path)
    }
}

private final class OneShotClaimMoveFailureFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        lock.lock()
        let failNow = shouldFail
            && UUID(uuidString: srcURL.lastPathComponent) != nil
            && dstURL.deletingLastPathComponent().lastPathComponent == "processing"
        if failNow { shouldFail = false }
        lock.unlock()

        if failNow {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError
            )
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

final class WorkCaptureInboxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @discardableResult
    private func writePublished(
        id: UUID = UUID(),
        version: Int = WorkCaptureEnvelope.currentVersion,
        note: String = "Review this",
        entries: [WorkCaptureEnvelope.Entry]? = nil,
        extraFile: Bool = false
    ) throws -> UUID {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effectiveEntries = entries ?? [
            WorkCaptureEnvelope.Entry(
                kind: .file,
                sequence: 0,
                relativePath: "payload-000.pdf",
                displayName: "proposal.pdf",
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf",
                byteCount: 4
            ),
            WorkCaptureEnvelope.Entry(
                kind: .url,
                sequence: 1,
                text: "https://example.com/context"
            ),
        ]
        if effectiveEntries.contains(where: { $0.relativePath == "payload-000.pdf" }) {
            try Data("test".utf8).write(to: directory.appendingPathComponent("payload-000.pdf"))
        }
        if extraFile {
            try Data("unexpected".utf8).write(to: directory.appendingPathComponent("secret.bin"))
        }
        let envelope = WorkCaptureEnvelope(
            version: version,
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            note: note,
            source: .shareExtension,
            entries: effectiveEntries
        )
        try envelope.encoded().write(to: directory.appendingPathComponent("manifest.json"))
        return id
    }

    private func mutateManifest(
        id: UUID,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let manifestURL = root
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        let data = try Data(contentsOf: manifestURL)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try mutation(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)
    }

    // MARK: - Wire and sanitation

    func testWireRoundTripPreservesMaterialsAndHasNoDispatchFields() throws {
        let id = UUID()
        let targetWorkItemID = UUID()
        let envelope = WorkCaptureEnvelope(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            note: "Compare these",
            source: .shareExtension,
            targetWorkItemID: targetWorkItemID,
            entries: [
                .init(kind: .text, sequence: 0, text: "source note"),
                .init(kind: .url, sequence: 1, text: "https://example.com"),
                .init(
                    kind: .image,
                    sequence: 2,
                    relativePath: "payload-002.heic",
                    displayName: "IMG.heic",
                    mimeType: "image/heic",
                    typeIdentifier: "public.heic",
                    byteCount: 42
                ),
            ]
        )

        let data = try envelope.encoded()
        let decoded = try WorkCaptureEnvelope.decode(data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.targetWorkItemID, targetWorkItemID)
        let wire = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(wire.contains("gateway"))
        XCTAssertFalse(wire.contains("conversation"))
        XCTAssertFalse(wire.contains("autosend"))
        XCTAssertFalse(wire.contains("dispatch"))
    }

    func testOlderEnvelopeWithoutWorkDestinationDecodesAsNewWork() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","note":"Legacy capture","entries":[]}
        """

        let decoded = try WorkCaptureEnvelope.decode(Data(json.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.targetWorkItemID)
        XCTAssertEqual(decoded.source, .shareExtension)
    }

    func testConstructorsPreserveOversizedValuesAndPublicationValidationRejectsThem() {
        let oversizedNote = String(
            repeating: "n",
            count: WorkCaptureEnvelope.maximumNoteCharacters + 30
        )
        let noteEnvelope = WorkCaptureEnvelope(
            note: oversizedNote,
            source: .app,
            entries: []
        )
        XCTAssertEqual(noteEnvelope.note, oversizedNote)
        XCTAssertThrowsError(try noteEnvelope.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .noteTooLong
            )
        }

        let entries = (0..<(WorkCaptureEnvelope.maximumEntryCount + 4)).map {
            WorkCaptureEnvelope.Entry(
                kind: .text,
                sequence: $0,
                text: "Material \($0)"
            )
        }
        let entryEnvelope = WorkCaptureEnvelope(source: .app, entries: entries)
        XCTAssertEqual(entryEnvelope.entries.count, entries.count)
        XCTAssertThrowsError(try entryEnvelope.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .tooManyEntries
            )
        }

        let oversizedText = String(
            repeating: "t",
            count: WorkCaptureEnvelope.maximumTextCharacters + 30
        )
        let textEnvelope = WorkCaptureEnvelope(
            source: .app,
            entries: [
                .init(
                    kind: .text,
                    sequence: 0,
                    text: oversizedText
                )
            ]
        )
        XCTAssertEqual(textEnvelope.entries.first?.text, oversizedText)
        XCTAssertThrowsError(try textEnvelope.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .textTooLong
            )
        }

        let unsafeName = String(repeating: "x", count: 121) + ".pdf"
        let metadataEnvelope = WorkCaptureEnvelope(
            source: .app,
            entries: [
                .init(
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.pdf",
                    displayName: unsafeName,
                    byteCount: 1
                )
            ]
        )
        XCTAssertEqual(metadataEnvelope.entries.first?.displayName, unsafeName)
        XCTAssertThrowsError(try metadataEnvelope.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .unsafeMetadata
            )
        }
    }

    func testPublicationValidationAcceptsACompleteBoundedEnvelope() throws {
        let envelope = WorkCaptureEnvelope(
            note: "Compare these",
            source: .shareExtension,
            entries: [
                .init(kind: .text, sequence: 0, text: "Source note"),
                .init(kind: .url, sequence: 1, text: "https://example.com/context"),
                .init(
                    kind: .file,
                    sequence: 2,
                    relativePath: "payload-002.pdf",
                    displayName: "proposal.pdf",
                    mimeType: "application/pdf",
                    typeIdentifier: "com.adobe.pdf",
                    byteCount: 42
                ),
            ]
        )

        XCTAssertNoThrow(try envelope.validateForPublication())
    }

    func testShareWritersValidateAndRollbackBeforeAtomicPublication() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        for relativePath in [
            "ConduckShareExtension/ShareViewController.swift",
            "ConduckShareExtensionMac/ShareViewController.swift",
        ] {
            let source = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let validation = try XCTUnwrap(source.range(of: "try envelope.validateForPublication()"))
            let publication = try XCTUnwrap(
                source.range(of: "try fm.moveItem(at: tmp, to: published)", range: validation.upperBound..<source.endIndex)
            )
            XCTAssertLessThan(validation.lowerBound, publication.lowerBound, relativePath)
            XCTAssertTrue(source.contains("if !didPublish"), relativePath)
            XCTAssertTrue(source.contains("try? fm.removeItem(at: tmp)"), relativePath)
            XCTAssertTrue(
                source.contains("targetWorkItemID: targetWorkItemID"),
                "\(relativePath) must carry the optional inert Work destination into the envelope"
            )
        }
    }

    func testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let expectedWorkKeys = [
            "share.addToWork",
            "share.addToWork.progress",
            "share.work.new",
            "share.work.new.detail",
            "share.work.section.destination",
            "share.work.section.recent",
            "share.work.untitled",
            "share.work.error.empty",
            "share.work.error.title",
            "share.work.error.tooLarge",
            "share.work.error.unavailable",
        ]
        for relativePath in [
            "ConduckShareExtension/ShareView.swift",
            "ConduckShareExtensionMac/ShareView.swift",
        ] {
            let source = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("defaultValue: \"Add to Work\""), relativePath)
            XCTAssertTrue(source.contains("defaultValue: \"Adding to Work…\""), relativePath)
            XCTAssertFalse(source.contains("defaultValue: \"Add to Workboard\""), relativePath)
            XCTAssertTrue(source.contains(".frame(minHeight:"), relativePath)
            XCTAssertTrue(source.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"), relativePath)
            XCTAssertTrue(source.contains(".accessibilityAddTraits(.isHeader)"), relativePath)
            for key in expectedWorkKeys {
                XCTAssertTrue(
                    source.contains("String(localized: \"\(key)\""),
                    "\(relativePath) must use the exact catalog key \(key)"
                )
            }
            XCTAssertFalse(source.contains("String(localized: \"share.addToWorkboard"), relativePath)
            XCTAssertFalse(source.contains("String(localized: \"share.workboard."), relativePath)
        }

        for relativePath in [
            "ConduckShareExtension/Localizable.xcstrings",
            "ConduckShareExtensionMac/Localizable.xcstrings",
        ] {
            let catalog = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for key in expectedWorkKeys {
                XCTAssertTrue(
                    catalog.contains("\"\(key)\" :"),
                    "\(relativePath) must carry the exact source key \(key)"
                )
            }
            XCTAssertFalse(catalog.contains("\"share.addToWorkboard\" :"), relativePath)
            XCTAssertFalse(catalog.contains("\"share.workboard."), relativePath)
        }
    }

    func testFilenameSanitationRemovesPathControlsAndBidiWhilePreservingExtension() {
        let raw = "../../folder\\\u{202E}secret\nproposal.pdf"
        let safe = WorkCaptureEnvelope.safeDisplayName(raw)
        XCTAssertEqual(safe, "secretproposal.pdf")
        XCTAssertFalse(safe?.contains("/") == true)
        XCTAssertFalse(safe?.contains("\\") == true)
        XCTAssertLessThanOrEqual(safe?.count ?? .max, WorkCaptureEnvelope.maximumDisplayNameCharacters)
    }

    func testURLRuleAllowsWebAndRejectsLocalOrCredentiallessGarbage() {
        XCTAssertTrue(WorkCaptureEnvelope.isAcceptedWebURL("https://example.com/a"))
        XCTAssertTrue(WorkCaptureEnvelope.isAcceptedWebURL("http://192.168.1.4/context"))
        XCTAssertFalse(WorkCaptureEnvelope.isAcceptedWebURL("file:///private/notes.txt"))
        XCTAssertFalse(WorkCaptureEnvelope.isAcceptedWebURL("javascript:alert(1)"))
        XCTAssertFalse(WorkCaptureEnvelope.isAcceptedWebURL("https:///missing-host"))
    }

    func testThreeCrossProcessEnvelopeCopiesAreIdenticalBelowImport() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let urls = [
            projectDirectory.appendingPathComponent("Conduck/Models/WorkCaptureEnvelope.swift"),
            projectDirectory.appendingPathComponent("ConduckShareExtension/WorkCaptureEnvelope.swift"),
            projectDirectory.appendingPathComponent("ConduckShareExtensionMac/WorkCaptureEnvelope.swift"),
        ]
        let bodies = try urls.map { url -> Substring in
            let source = try String(contentsOf: url, encoding: .utf8)
            let anchor = try XCTUnwrap(source.range(of: "import Foundation"))
            return source[anchor.lowerBound...]
        }
        XCTAssertEqual(String(bodies[0]), String(bodies[1]))
        XCTAssertEqual(String(bodies[0]), String(bodies[2]))
    }

    // MARK: - Claim lifecycle

    func testAppCapturePublishesNoteAndScreenshotAsOneClaim() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let screenshot = Data([0x89, 0x50, 0x4E, 0x47])

        let id = try await inbox.publishAppCapture(
            note: "Compare this layout",
            screenshotPNG: screenshot,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        let claimedValue = try await inbox.claimNext()
        let claimed = try XCTUnwrap(claimedValue)
        XCTAssertEqual(claimed.id, id)
        XCTAssertEqual(claimed.envelope.source, .app)
        XCTAssertEqual(claimed.envelope.note, "Compare this layout")
        let image = try XCTUnwrap(claimed.envelope.entries.first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.byteCount, Int64(screenshot.count))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(claimed.payloadURL(for: image))), screenshot)
    }

    func testAppCaptureReplayAfterAcknowledgementKeepsEnvelopeAndEntryIdentity() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID(uuidString: "E50E9C29-C4FB-40F3-9C68-3D3AA141356B")!
        let screenshot = Data([0x89, 0x50, 0x4E, 0x47])

        _ = try await inbox.publishAppCapture(
            note: "Keep this once",
            screenshotPNG: screenshot,
            captureID: captureID
        )
        let firstValue = try await inbox.claimNext()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.id, captureID)
        XCTAssertEqual(first.envelope.entries.map(\.id), [captureID])
        try await inbox.acknowledge(first)

        // Simulates an intent killed after publish + drain but before clearing
        // its audio guard. Re-publication has the same identities even though
        // the acknowledged queue directory no longer exists.
        _ = try await inbox.publishAppCapture(
            note: "Keep this once",
            screenshotPNG: screenshot,
            captureID: captureID
        )
        let replayValue = try await inbox.claimNext()
        let replay = try XCTUnwrap(replayValue)
        XCTAssertEqual(replay.id, captureID)
        XCTAssertEqual(replay.envelope.entries.map(\.id), [captureID])
        XCTAssertEqual(replay.envelope.note, first.envelope.note)
    }

    func testEmptyAppCaptureFailsWithoutPublishingPartialDirectory() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.publishAppCapture(note: "   ", screenshotPNG: nil)
            XCTFail("An empty quick capture must not be published")
        } catch {
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .emptyCapture
            )
        }
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testClaimReturnsValidatedPayloadThenAcknowledgeDeletesIt() async throws {
        let id = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)

        let nextClaim = try await inbox.claimNext()
        let claim = try XCTUnwrap(nextClaim)
        XCTAssertEqual(claim.id, id)
        let pendingAfterClaim = try await inbox.pendingCount()
        XCTAssertEqual(pendingAfterClaim, 0)
        let fileEntry = try XCTUnwrap(claim.envelope.entries.first(where: { $0.kind == .file }))
        let payloadURL = try XCTUnwrap(claim.payloadURL(for: fileEntry))
        XCTAssertEqual(try Data(contentsOf: payloadURL), Data("test".utf8))

        try await inbox.acknowledge(claim)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claim.directoryURL.path))
        do {
            try await inbox.acknowledge(claim)
            XCTFail("A completed token must not acknowledge a later claim")
        } catch {
            XCTAssertEqual(error as? WorkCaptureInbox.InboxError, .staleClaim)
        }
    }

    func testReleaseMakesClaimPendingAgainWithoutChangingIdentity() async throws {
        let id = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)
        let firstResult = try await inbox.claimNext()
        let first = try XCTUnwrap(firstResult)

        try await inbox.release(first)
        let pendingAfterRelease = try await inbox.pendingCount()
        XCTAssertEqual(pendingAfterRelease, 1)
        let secondResult = try await inbox.claimNext()
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(second.id, id)
        XCTAssertNotEqual(second.token, first.token)
    }

    func testActiveClaimCannotBeClaimedTwice() async throws {
        _ = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)
        let first = try await inbox.claimNext()
        _ = try XCTUnwrap(first)
        let second = try await inbox.claimNext()
        XCTAssertNil(second)
    }

    // MARK: - Validation and reconciliation

    func testUnsupportedEnvelopeVersionIsRejectedAndRemoved() async throws {
        let id = try writePublished(version: WorkCaptureEnvelope.currentVersion + 1)
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.claimNext()
            XCTFail("A future wire version must not be interpreted with v1 semantics")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unsupportedVersion))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("processing/\(id.uuidString)").path
        ))
    }

    func testDecodedUnsafeFilenameMIMEAndTypeMetadataAreRejected() async throws {
        let mutations: [(String, String)] = [
            ("displayName", "report\u{2028}spoof.pdf"),
            ("mimeType", String(repeating: "x", count: 161)),
            ("typeIdentifier", "public.text\nspoofed"),
        ]

        for (key, value) in mutations {
            let id = try writePublished()
            try mutateManifest(id: id) { manifest in
                var entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
                entries[0][key] = value
                manifest["entries"] = entries
            }
            let inbox = WorkCaptureInbox(baseURL: root)

            do {
                _ = try await inbox.claimNext()
                XCTFail("Unsafe decoded \(key) metadata must not enter persistence")
            } catch let error as WorkCaptureInbox.InboxError {
                XCTAssertEqual(error, .invalidEnvelope(id, .unsafeMetadata), key)
            }
        }
    }

    func testHiddenUnreferencedPayloadIsIncludedInExactChildValidation() async throws {
        let id = try writePublished()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try Data("hidden".utf8).write(to: directory.appendingPathComponent(".private"))
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.claimNext()
            XCTFail("Hidden unreferenced bytes must not bypass containment")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unexpectedPayload))
        }
    }

    func testTransientManifestAccessFailurePreservesCaptureForRetry() async throws {
        let id = try writePublished()
        let fileManager = OneShotManifestAccessFailureFileManager()
        let inbox = WorkCaptureInbox(baseURL: root, fileManager: fileManager)

        do {
            _ = try await inbox.claimNext()
            XCTFail("A transient protection failure must surface")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(id.uuidString).path
        ), "Transient I/O must roll the claim back to pending")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("processing/\(id.uuidString)").path
        ))

        let retried = try await inbox.claimNext()
        XCTAssertEqual(try XCTUnwrap(retried).id, id)
    }

    func testTransientClaimMoveFailureSurfacesAndLeavesCapturePending() async throws {
        let id = try writePublished()
        let fileManager = OneShotClaimMoveFailureFileManager()
        let inbox = WorkCaptureInbox(baseURL: root, fileManager: fileManager)

        do {
            _ = try await inbox.claimNext()
            XCTFail("A protected pending directory must not look like an empty queue")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(id.uuidString).path
        ))

        let retried = try await inbox.claimNext()
        XCTAssertEqual(try XCTUnwrap(retried).id, id)
    }

    func testScaffoldFailureIsReportedAndRetriedInsteadOfLatched() async throws {
        let blockedBase = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedBase)
        let inbox = WorkCaptureInbox(baseURL: blockedBase)

        do {
            _ = try await inbox.pendingCount()
            XCTFail("A failed scaffold must not masquerade as an empty queue")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }
        let report = await inbox.reconcile()
        XCTAssertTrue(report.encounteredFilesystemFailure)

        try FileManager.default.removeItem(at: blockedBase)
        let recoveredPendingCount = try await inbox.pendingCount()
        XCTAssertEqual(recoveredPendingCount, 0,
                       "didScaffold must stay false so a later call can recover")
    }

    func testTraversalPathIsRejectedAndPrivateBytesAreRemoved() async throws {
        let id = UUID()
        let entries = [WorkCaptureEnvelope.Entry(
            kind: .file,
            sequence: 0,
            relativePath: "../escape.pdf",
            displayName: "escape.pdf",
            byteCount: 4
        )]
        _ = try writePublished(id: id, entries: entries)
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.claimNext()
            XCTFail("Unsafe relative paths must not be imported")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unsafeRelativePath))
        }
        let processing = root.appendingPathComponent("processing/\(id.uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: processing.path))
    }

    func testUnexpectedUnreferencedPayloadIsRejected() async throws {
        let id = try writePublished(extraFile: true)
        let inbox = WorkCaptureInbox(baseURL: root)
        do {
            _ = try await inbox.claimNext()
            XCTFail("Unreferenced bytes must not ride into a draft")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unexpectedPayload))
        }
    }

    func testReconcileReleasesCrashStrandedClaimAndSweepsOnlyOldTmp() async throws {
        let id = try writePublished()
        let processing = root.appendingPathComponent("processing", isDirectory: true)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(id.uuidString),
            to: processing.appendingPathComponent(id.uuidString)
        )
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let old = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fresh = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: old.path
        )

        let inbox = WorkCaptureInbox(baseURL: root)
        let report = await inbox.reconcile(now: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(report, .init(releasedClaimCount: 1, removedTemporaryCount: 1, collisionCount: 0))
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    @MainActor
    func testCaptureDrainOwnsDurableTaskAcrossItsOwnChangeNotification() async {
        let refreshed = expectation(description: "board refreshes after durable drain")
        var coordinator: WorkCaptureRefreshCoordinator!
        var drainPassCount = 0
        var refreshCount = 0
        var durableMutationCompleted = false

        coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: .seconds(30),
            drainCaptures: {
                drainPassCount += 1
                if drainPassCount == 1 {
                    // Mirrors claim/ack posting `didChangeNotification` while the
                    // owning drain is suspended. An unrelated UI notification is
                    // also queued to prove only its debounce task is cancelable.
                    coordinator.schedule(includeCaptureDrain: false)
                    coordinator.schedule(includeCaptureDrain: true)
                    await Task.yield()
                    XCTAssertFalse(Task.isCancelled)
                    durableMutationCompleted = true
                }
                return true
            },
            refresh: {
                refreshCount += 1
                XCTAssertTrue(durableMutationCompleted)
                refreshed.fulfill()
            }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await fulfillment(of: [refreshed], timeout: 2)

        XCTAssertEqual(drainPassCount, 2, "The self-notification is serialized as one follow-up pass")
        XCTAssertEqual(refreshCount, 1, "UI reload happens once after queue ownership is released")
    }

    @MainActor
    func testFailedCaptureDrainDefersRetryInsteadOfSpinningOnReleaseNotification() async {
        let refreshed = expectation(description: "board refreshes after failed durable drain")
        var coordinator: WorkCaptureRefreshCoordinator!
        var drainPassCount = 0

        coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: .seconds(30),
            drainCaptures: {
                drainPassCount += 1
                // Mirrors the failed claim being released to pending, which
                // posts another inbox-change notification before returning.
                coordinator.schedule(includeCaptureDrain: true)
                return false
            },
            refresh: { refreshed.fulfill() }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await fulfillment(of: [refreshed], timeout: 2)
        await Task.yield()

        XCTAssertEqual(drainPassCount, 1, "A persistent store failure waits for a later app wake")
    }
}

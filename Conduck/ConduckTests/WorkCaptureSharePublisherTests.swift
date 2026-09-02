// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureSharePublisherTests.swift
//
// Behavioural coverage of the publication transaction both share extensions and
// the in-app quick capture use: validation refusal, a staging write that cannot
// land, a destination already taken, and the successful atomic publication.
//
// Each extension is a separate target that compiles a verbatim mirror of
// `WorkCaptureDirectoryPublisher`, so no test bundle can link an extension's
// copy — two identical type names cannot coexist in one module. The coverage
// reaches both extensions in three steps instead: the failure paths are driven
// against the main-app copy through an injected filesystem, the three copies are
// proved byte-identical below `import Foundation`, and each extension's Work
// writer is proved to delegate to that transaction rather than publish by hand.

import XCTest
@testable import Conduck

/// Fails exactly one step of a publication transaction, so the rollback can be
/// observed on disk instead of inferred from the order of tokens in a caller's
/// source. Everything else is the production filesystem.
private nonisolated struct FailingWorkCaptureFileSystem: WorkCaptureFileSystem {
    enum Step {
        case write
        case move
    }

    let failing: Step
    private let live = WorkCaptureFileManagerFileSystem()

    init(failing: Step) {
        self.failing = failing
    }

    func createDirectory(at url: URL) throws {
        try live.createDirectory(at: url)
    }

    func writeProtected(_ data: Data, to url: URL) throws {
        guard failing != .write else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try live.writeProtected(data, to: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        guard failing != .move else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        try live.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try live.removeItem(at: url)
    }
}

final class WorkCaptureSharePublisherTests: XCTestCase {
    private var root: URL!
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-capture-publisher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makePublisher(
        fileSystem: WorkCaptureFileSystem = WorkCaptureFileManagerFileSystem()
    ) throws -> WorkCaptureDirectoryPublisher {
        WorkCaptureDirectoryPublisher(inboxURL: try XCTUnwrap(root), fileSystem: fileSystem)
    }

    /// One shared file entry, the shape every share capture carries.
    private func fileEnvelope(
        id: UUID,
        byteCount: Int64,
        targetWorkItemID: UUID? = nil
    ) -> WorkCaptureEnvelope {
        WorkCaptureEnvelope(
            id: id,
            createdAt: anchor,
            note: "Review this",
            source: .shareExtension,
            targetWorkItemID: targetWorkItemID,
            entries: [WorkCaptureEnvelope.Entry(
                kind: .file,
                sequence: 0,
                relativePath: "payload-000.pdf",
                displayName: "proposal.pdf",
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf",
                byteCount: byteCount
            )]
        )
    }

    /// Stages the directory the way a share extension does: open it, then copy
    /// the shared bytes into it before the envelope is finished.
    private func stagePayload(
        _ publisher: WorkCaptureDirectoryPublisher,
        id: UUID,
        bytes: Data = Data("payload".utf8)
    ) throws -> URL {
        let staging = try publisher.beginStaging(named: id.uuidString)
        try bytes.write(to: staging.appendingPathComponent("payload-000.pdf", isDirectory: false))
        return staging
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func childNames(of directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent))
    }

    /// The Work writer of each extension, sliced out of its source between its
    /// own declaration and the provider loader that follows it. The Send-now
    /// path publishes into a different queue and keeps its own rename, so the
    /// negative assertions below have to be scoped to this function.
    private func appexWorkWriters() throws -> [(path: String, writer: String)] {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        var writers: [(path: String, writer: String)] = []
        for relativePath in [
            "ConduckShareExtension/ShareViewController.swift",
            "ConduckShareExtensionMac/ShareViewController.swift",
        ] {
            let source = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let start = try XCTUnwrap(
                source.range(of: "private func writeWorkCaptureEnvelope("),
                relativePath
            )
            let end = try XCTUnwrap(
                source.range(
                    of: "private func loadOne(",
                    range: start.upperBound..<source.endIndex
                ),
                relativePath
            )
            writers.append((relativePath, String(source[start.lowerBound..<end.lowerBound])))
        }
        return writers
    }

    // MARK: - Successful publication

    func testAStagedCaptureIsPublishedByOneAtomicRename() throws {
        let publisher = try makePublisher()
        let id = UUID()
        let staging = try stagePayload(publisher, id: id)

        let published = try publisher.commit(fileEnvelope(id: id, byteCount: 7), staging: staging)

        XCTAssertEqual(published, root.appendingPathComponent(id.uuidString, isDirectory: true))
        XCTAssertEqual(
            try childNames(of: published),
            ["manifest.json", "payload-000.pdf"],
            "The published directory IS the staged one, renamed once"
        )
        XCTAssertEqual(
            try Data(contentsOf: published.appendingPathComponent("payload-000.pdf")),
            Data("payload".utf8)
        )
        XCTAssertFalse(exists(staging), "A published capture leaves no staging copy behind")

        let decoded = try WorkCaptureEnvelope.decode(
            try Data(contentsOf: published.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.note, "Review this")
        XCTAssertEqual(decoded.entries.map(\.relativePath), ["payload-000.pdf"])
        XCTAssertNil(decoded.targetWorkItemID)
    }

    // MARK: - Refusals

    func testARefusedEnvelopeIsNotPublishedAndTakesItsStagedBytesWithIt() throws {
        let publisher = try makePublisher()
        let id = UUID()
        let staging = try stagePayload(publisher, id: id)
        let empty = WorkCaptureEnvelope(
            id: id,
            createdAt: anchor,
            note: "   ",
            source: .shareExtension,
            entries: []
        )

        XCTAssertThrowsError(try publisher.commit(empty, staging: staging)) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .emptyCapture
            )
        }
        XCTAssertFalse(
            exists(publisher.publishedURL(for: id)),
            "A refused capture must never become visible to the drainer"
        )
        XCTAssertFalse(
            exists(staging),
            "A refused transaction removes its copy of private bytes rather than waiting for a sweep"
        )
    }

    func testAStagingWriteThatCannotLandPublishesNothing() throws {
        let publisher = try makePublisher(fileSystem: FailingWorkCaptureFileSystem(failing: .write))
        let id = UUID()
        let staging = try publisher.beginStaging(named: id.uuidString)
        try Data("payload".utf8).write(
            to: staging.appendingPathComponent("payload-000.pdf", isDirectory: false)
        )

        XCTAssertThrowsError(
            try publisher.commit(fileEnvelope(id: id, byteCount: 7), staging: staging)
        ) { error in
            XCTAssertEqual((error as NSError).code, NSFileWriteNoPermissionError)
        }
        XCTAssertFalse(exists(publisher.publishedURL(for: id)))
        XCTAssertFalse(exists(staging))
    }

    func testADestinationAlreadyTakenLeavesTheExistingCaptureUntouched() throws {
        let publisher = try makePublisher()
        let id = UUID()
        let occupied = publisher.publishedURL(for: id)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("first".utf8).write(
            to: occupied.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let staging = try stagePayload(publisher, id: id, bytes: Data("second".utf8))

        XCTAssertThrowsError(
            try publisher.commit(fileEnvelope(id: id, byteCount: 6), staging: staging)
        )
        XCTAssertEqual(
            try childNames(of: occupied),
            ["manifest.json"],
            "A collision must not merge the two directories"
        )
        XCTAssertEqual(
            try Data(contentsOf: occupied.appendingPathComponent("manifest.json")),
            Data("first".utf8),
            "The capture already in the queue is the durable one"
        )
        XCTAssertFalse(exists(staging))
    }

    func testAnEnvelopeNamingAWorkDestinationCannotBePublished() throws {
        // Work is ONE desk, so the drainer has no destination to resolve a
        // target against. Refusing it here makes a targeted share impossible
        // rather than merely unwritten by today's extensions.
        let publisher = try makePublisher()
        let id = UUID()
        let staging = try stagePayload(publisher, id: id)

        XCTAssertThrowsError(
            try publisher.commit(
                fileEnvelope(id: id, byteCount: 7, targetWorkItemID: UUID()),
                staging: staging
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkCaptureDirectoryPublisher.Failure,
                .envelopeNamesADestination
            )
        }
        XCTAssertFalse(exists(publisher.publishedURL(for: id)))
        XCTAssertFalse(exists(staging))
    }

    // MARK: - The extensions publish through this transaction

    func testThreeCrossProcessPublisherCopiesAreIdenticalBelowImport() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let urls = [
            projectDirectory.appendingPathComponent("Conduck/Services/WorkCaptureDirectoryPublisher.swift"),
            projectDirectory.appendingPathComponent("ConduckShareExtension/WorkCaptureDirectoryPublisher.swift"),
            projectDirectory.appendingPathComponent("ConduckShareExtensionMac/WorkCaptureDirectoryPublisher.swift"),
        ]
        let bodies = try urls.map { url -> Substring in
            let source = try String(contentsOf: url, encoding: .utf8)
            let anchor = try XCTUnwrap(source.range(of: "import Foundation"))
            return source[anchor.lowerBound...]
        }
        XCTAssertEqual(String(bodies[0]), String(bodies[1]))
        XCTAssertEqual(String(bodies[0]), String(bodies[2]))

        // Each copy restates the manifest name because an extension compiles
        // none of the rest of the queue. A divergence would publish a directory
        // the inbox rejects as manifest-less.
        XCTAssertEqual(
            WorkCaptureDirectoryPublisher.manifestFilename,
            WorkCaptureInbox.manifestFilename
        )
    }

    func testBothShareExtensionsPublishThroughThePublisherRatherThanByHand() throws {
        for (relativePath, writer) in try appexWorkWriters() {
            XCTAssertTrue(
                writer.contains("publisher.commit(envelope, staging: tmp)"),
                "\(relativePath) must publish through the transaction these tests exercise"
            )
            XCTAssertTrue(
                writer.contains("publisher.discard(tmp)"),
                "\(relativePath) must hand its abandoned staging directory back to the publisher"
            )
            XCTAssertFalse(
                writer.contains("moveItem(at: tmp"),
                "\(relativePath) must not publish a Work capture with a hand-rolled rename"
            )
            XCTAssertTrue(
                writer.contains("targetWorkItemID: nil"),
                "\(relativePath) must build a targetless envelope — Work is one desk, so an appex can never name a destination"
            )
        }
    }
}

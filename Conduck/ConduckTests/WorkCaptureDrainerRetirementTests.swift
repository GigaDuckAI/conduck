// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerRetirementTests.swift
//
// How a terminally refused capture's bytes leave the queue. The retirement is
// the ONE place in the drainer where the acknowledgement barrier is not the
// desk: nothing about that capture is on the desk, so what stands between the
// person's file and `acknowledge` — which deletes the queue's only copy of it —
// is a copy in `refused/` and nothing else.
//
// Which makes the existence of that copy's directory the wrong question. A
// crash, a killed process or a full disk between two files leaves a directory
// that exists and is short, and a retirement that took existence for completion
// would write a reason beside half a file and then acknowledge the complete
// original away. So the copy is staged under a scratch name, checked file by
// file against the byte counts the claimed directory still carries, and renamed
// into place only once it matches — the rename being the one step that is
// atomic, so a destination that exists is a destination something finished.
//
// These cases stage the three states that separates: a short retirement already
// on disk, a copy that cannot start, and a copy that lands incomplete. In every
// one of them the queue must still hold the file afterwards, or hold it until a
// complete copy provably exists.
//
// And there is one thing a complete retirement must NOT carry. `refused/` is
// swept by nothing, so a recording copied there would outlive every other copy
// of itself — the second non-desk barrier against a recording this device never
// agreed to keep, after the drainer's own refusal to make it a card.

import XCTest
@testable import Conduck

final class WorkCaptureDrainerRetirementTests: XCTestCase {
    private var root: URL!

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-work-drainer-retirement-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await isolated.cleanUp()
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    // MARK: - A retirement already on disk is verified, never believed

    /// The state a crash mid-copy leaves: the destination exists and its
    /// payload is short. The next refusal may not treat that as a finished
    /// retirement — the queue is still holding the only whole copy, and
    /// acknowledging against a short one destroys it.
    func testAShortRetirementOnDiskIsReplacedInsteadOfTrusted() async throws {
        let store = try await deskRefusingBothIDs(of: sharedID)
        let payload = Data("the shared file the queue is holding for us".utf8)
        let colliding = collidingEnvelope(at: sharedID, byteCount: Int64(payload.count))
        try publish(colliding, payloads: ["payload-000.bin": payload])

        // A previous retirement of this same envelope that never finished: the
        // manifest copied, the payload only part-way.
        let truncated = payload.prefix(7)
        let interrupted = refusedURL.appendingPathComponent(
            colliding.id.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try colliding.encoded().write(to: interrupted.appendingPathComponent("manifest.json"))
        try truncated.write(to: interrupted.appendingPathComponent("payload-000.bin"))

        let report = try await makeDrainer(store: store).drainAvailableCaptures()
        XCTAssertEqual(report.invalidCaptureCount, 1)

        // THE POINT: what the queue gave up its copy for is the whole file.
        let retired = refusedURL.appendingPathComponent(colliding.id.uuidString, isDirectory: true)
        XCTAssertEqual(
            try Data(contentsOf: retired.appendingPathComponent("payload-000.bin")),
            payload,
            "a retirement the queue was acknowledged against must carry every byte it had"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: retired.appendingPathComponent("manifest.json").path
            ),
            "the manifest goes with the bytes; it is the only record of what was shared"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: retired.appendingPathComponent(WorkCaptureInbox.leaseFilename).path
            ),
            "the ownership marker names an acquisition of a queue this directory has left"
        )
        let reason = try String(
            contentsOf: retired.appendingPathComponent("refusal.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(reason.contains(sharedID.uuidString))

        // And the short one was moved aside rather than deleted: this drainer
        // removes no bytes it did not itself just write.
        let displaced = try refusedChildren().filter { $0.lastPathComponent != colliding.id.uuidString }
        XCTAssertEqual(displaced.count, 1, "an incomplete retirement is displaced, not destroyed")
        let aside = try XCTUnwrap(displaced.first)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix(colliding.id.uuidString))
        XCTAssertEqual(
            try Data(contentsOf: aside.appendingPathComponent("payload-000.bin")),
            Data(truncated),
            "whatever the interrupted copy had reached is still on disk"
        )

        // Only now may the queue be empty.
        let pending = try await WorkCaptureInbox(baseURL: root).pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - A copy that cannot land keeps the queue entry

    /// The retirement is the only thing standing between the acknowledgement
    /// and the file, so a copy that cannot even start leaves the capture
    /// exactly where its publisher left it — and the next drain, once the
    /// filesystem allows it, finishes the retirement.
    func testARetirementWhoseCopyCannotLandLeavesTheQueueHoldingTheBytes() async throws {
        let store = try await deskRefusingBothIDs(of: sharedID)
        let payload = Data("the shared file the queue is holding for us".utf8)
        let colliding = collidingEnvelope(at: sharedID, byteCount: Int64(payload.count))
        try publish(colliding, payloads: ["payload-000.bin": payload])

        try FileManager.default.createDirectory(at: refusedURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: refusedURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: refusedURL.path
            )
        }
        XCTAssertFalse(
            FileManager.default.isWritableFile(atPath: refusedURL.path),
            "the case needs a filesystem that refuses the copy"
        )

        do {
            _ = try await makeDrainer(store: store).drainAvailableCaptures()
            XCTFail("a retirement that could not copy the bytes may not acknowledge them away")
        } catch {
            // The refusal is the point; which filesystem error it is, is not.
        }

        XCTAssertEqual(try refusedChildren().count, 0, "nothing was retired")
        let inbox = WorkCaptureInbox(baseURL: root)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1, "the capture is back in the queue, whole")
        XCTAssertEqual(
            try Data(
                contentsOf: root
                    .appendingPathComponent(colliding.id.uuidString, isDirectory: true)
                    .appendingPathComponent("payload-000.bin")
            ),
            payload
        )

        // The next drain, on a filesystem that allows the copy, finishes it.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: refusedURL.path
        )
        let report = try await makeDrainer(store: store).drainAvailableCaptures()
        XCTAssertEqual(report.invalidCaptureCount, 1)
        XCTAssertEqual(
            try Data(
                contentsOf: refusedURL
                    .appendingPathComponent(colliding.id.uuidString, isDirectory: true)
                    .appendingPathComponent("payload-000.bin")
            ),
            payload
        )
        let stillPending = try await inbox.pendingCount()
        XCTAssertEqual(stillPending, 0)
    }

    // MARK: - A copy that lands short never becomes the retirement

    /// A copy interrupted between two of its files is the state that made
    /// existence an unsafe test in the first place. It must not be renamed onto
    /// the retirement's name, and the entry must go back to the queue.
    func testAStagedRetirementThatLandedShortIsNeverRenamedIntoPlace() async throws {
        let store = try await deskRefusingBothIDs(of: sharedID)
        let payload = Data("the shared file the queue is holding for us".utf8)
        let colliding = collidingEnvelope(at: sharedID, byteCount: Int64(payload.count))
        try publish(colliding, payloads: ["payload-000.bin": payload])

        let drainer = makeDrainer(store: store)
        // The copy reaches the manifest and dies before the payload.
        await drainer._setRetirementStagingHoldForTesting { staged in
            try? FileManager.default.removeItem(
                at: staged.appendingPathComponent("payload-000.bin", isDirectory: false)
            )
        }

        do {
            _ = try await drainer.drainAvailableCaptures()
            XCTFail("an incomplete copy may not be acknowledged against")
        } catch {
            // Which error carries the refusal is not the assertion; that the
            // acknowledgement did not happen is.
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: refusedURL.appendingPathComponent(colliding.id.uuidString).path
            ),
            "the retirement's name may only ever appear on a complete copy"
        )
        XCTAssertEqual(
            try refusedChildren().count, 0,
            "and the copy that did not become one is cleaned up: the queue still has the original"
        )
        let inbox = WorkCaptureInbox(baseURL: root)
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(
            try Data(
                contentsOf: root
                    .appendingPathComponent(colliding.id.uuidString, isDirectory: true)
                    .appendingPathComponent("payload-000.bin")
            ),
            payload,
            "the queue's copy is untouched by a retirement that failed"
        )

        // A drain whose copy lands completes the retirement.
        await drainer._setRetirementStagingHoldForTesting(nil)
        let report = try await drainer.drainAvailableCaptures()
        XCTAssertEqual(report.invalidCaptureCount, 1)
        let retired = refusedURL.appendingPathComponent(colliding.id.uuidString, isDirectory: true)
        XCTAssertEqual(
            try Data(contentsOf: retired.appendingPathComponent("payload-000.bin")),
            payload
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: retired.appendingPathComponent("refusal.txt").path
            )
        )
        let stillPending = try await inbox.pendingCount()
        XCTAssertEqual(stillPending, 0)
    }

    // MARK: - The happy path is complete, and survives a second drain

    /// Two drains of the same envelope write one retirement, and the second
    /// finds it complete rather than copying a second time.
    func testARetirementIsByteCompleteAndIdempotentAcrossTwoDrains() async throws {
        let store = try await deskRefusingBothIDs(of: sharedID)
        let payload = Data(repeating: 0xAB, count: 4096)
        let colliding = collidingEnvelope(at: sharedID, byteCount: Int64(payload.count))
        try publish(colliding, payloads: ["payload-000.bin": payload])
        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        let retired = refusedURL.appendingPathComponent(colliding.id.uuidString, isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: retired.appendingPathComponent("payload-000.bin")), payload)
        XCTAssertEqual(
            try Data(contentsOf: retired.appendingPathComponent("manifest.json")),
            try colliding.encoded(),
            "the copy is byte-for-byte, manifest included"
        )
        let firstNames = Set(try refusedChildren().map(\.lastPathComponent))
        XCTAssertEqual(firstNames, [colliding.id.uuidString])

        // The same envelope shared again, refused again: one retirement, no
        // second copy of the same bytes beside it.
        try publish(colliding, payloads: ["payload-000.bin": payload])
        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        XCTAssertEqual(
            Set(try refusedChildren().map(\.lastPathComponent)), firstNames,
            "a repeated refusal of one envelope writes one retirement"
        )
        XCTAssertEqual(try Data(contentsOf: retired.appendingPathComponent("payload-000.bin")), payload)
        let pending = try await WorkCaptureInbox(baseURL: root).pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - A retirement never carries a recording

    /// A capture can hold both: a document whose id AND whose escape id are
    /// taken, which retires the whole claim, and beside it a recording the desk
    /// refuses to hold at all. The document's bytes have to survive in
    /// `refused/` — nobody else has them — and the recording's may not, because
    /// nothing sweeps that directory and a copy there would outlive every other
    /// copy of what a person said.
    func testARefusedRecordingIsNotRetiredWithTheSiblingThatCollided() async throws {
        let store = try await deskRefusingBothIDs(of: sharedID)
        let document = Data("the shared file the queue is holding for us".utf8)
        let recording = Data("compressed recording".utf8)
        let envelope = WorkCaptureEnvelope(
            note: "A capture whose entry id is already taken",
            source: .shareExtension,
            entries: [
                .init(
                    id: UUID(),
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.m4a",
                    displayName: "memo.m4a",
                    mimeType: "audio/mp4",
                    byteCount: Int64(recording.count)
                ),
                .init(
                    id: sharedID,
                    kind: .file,
                    sequence: 1,
                    relativePath: "payload-001.bin",
                    displayName: "contract.bin",
                    mimeType: "application/octet-stream",
                    byteCount: Int64(document.count)
                ),
            ]
        )
        try publish(envelope, payloads: [
            "payload-000.m4a": recording,
            "payload-001.bin": document,
        ])

        let report = try await makeDrainer(store: store).drainAvailableCaptures()
        XCTAssertEqual(report.invalidCaptureCount, 1)

        let retired = refusedURL.appendingPathComponent(envelope.id.uuidString, isDirectory: true)
        XCTAssertEqual(
            try Data(contentsOf: retired.appendingPathComponent("payload-001.bin")),
            document,
            "what the queue gave up its copy for is still whole"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: retired.appendingPathComponent("manifest.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: retired.appendingPathComponent("refusal.txt").path
            )
        )

        // THE POINT.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: retired.appendingPathComponent("payload-000.m4a").path
            ),
            "a retirement may not become a permanent holder of a recording"
        )
        XCTAssertEqual(
            try namesUnderRoot().filter { $0.hasSuffix(".m4a") }, [],
            "and no scratch or displaced copy of it is left behind either"
        )

        // The queue was still acknowledged, so the recording left with it.
        let pending = try await WorkCaptureInbox(baseURL: root).pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Helpers

    /// The id every case here collides on. Fixed per case by the fixture rather
    /// than by each test, since the desk has to be seeded against both it and
    /// its escape before anything is published.
    private let sharedID = UUID()

    private var refusedURL: URL {
        root.appendingPathComponent("refused", isDirectory: true)
    }

    /// Every regular file left anywhere under the inbox root, by name — the
    /// retirement, its scratch siblings and whatever the queue still holds.
    private func namesUnderRoot() throws -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var names: [String] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { names.append(url.lastPathComponent) }
        }
        return names.sorted()
    }

    private func refusedChildren() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: refusedURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: refusedURL,
            includingPropertiesForKeys: nil
        )
    }

    /// A desk holding an image card at `id` AND at its escape id, so a file
    /// capture claiming `id` is refused under both and is terminal.
    private func deskRefusingBothIDs(of id: UUID) async throws -> ConversationStore {
        let store = isolated.make()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: id)
        for (materialID, name) in [(id, "IMG.png"), (escapeID, "ESCAPE.png")] {
            let bytes = Data("the screenshot already at \(name)".utf8)
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: materialID,
                    kind: .image,
                    title: name,
                    filename: name,
                    mimeType: "image/png",
                    payload: bytes,
                    byteSize: Int64(bytes.count)
                )
            )
        }
        return store
    }

    /// One share-sheet capture whose only entry claims `id`.
    private func collidingEnvelope(at id: UUID, byteCount: Int64) -> WorkCaptureEnvelope {
        WorkCaptureEnvelope(
            note: "A capture whose entry id is already taken",
            source: .shareExtension,
            entries: [
                .init(
                    id: id,
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.bin",
                    displayName: "contract.bin",
                    mimeType: "application/octet-stream",
                    byteCount: byteCount
                )
            ]
        )
    }

    private func makeDrainer(store: ConversationStore) -> WorkCaptureDrainer {
        WorkCaptureDrainer(
            inbox: WorkCaptureInbox(baseURL: root),
            store: store,
            sourceDevice: "retirement-test"
        )
    }

    private func publish(
        _ envelope: WorkCaptureEnvelope,
        payloads: [String: Data] = [:]
    ) throws {
        let directory = root.appendingPathComponent(envelope.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (relativePath, bytes) in payloads {
            try bytes.write(
                to: directory.appendingPathComponent(relativePath, isDirectory: false),
                options: .atomic
            )
        }
        try envelope.encoded().write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}

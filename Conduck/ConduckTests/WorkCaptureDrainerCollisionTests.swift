// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerCollisionTests.swift
//
// What the share queue does when a capture's material id already names a
// DIFFERENT kind of card on the desk.
//
// The queue holds the only copy of a shared file, and the drainer may delete it
// only once the desk provably holds that file. An id collision is the one shape
// that can defeat that barrier from inside: if the desk write answered a
// colliding capture with the card that is already there — as an idempotent
// replay of itself — the drainer would see a record with a payload, pass its
// barrier on somebody else's bytes, and acknowledge. So the desk write refuses
// it. But a refusal alone is its own defect: the id never becomes free, so the
// entry refuses identically on every drain and stops every capture behind it
// for ever.
//
// The resolution these cases pin: the card is published once more under
// `WorkMaterialCollisionEscape.materialID(forCapture:)` — derived, so a replay
// in any process repairs that same card — and only a refusal of THAT id too is
// terminal, at which point the capture's bytes are copied into `refused/` and
// the entry leaves the queue so the drain can go on.

import XCTest
@testable import Conduck

final class WorkCaptureDrainerCollisionTests: XCTestCase {
    private var root: URL!

    /// Every store here mints a vault directory of its own that nothing else
    /// removes; the fixture empties them when the class is done.
    private let isolated = IsolatedWorkStores()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-work-drainer-collision-\(UUID().uuidString)",
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

    // MARK: - One collision escapes

    /// The colliding capture lands, under its escape id, with its own bytes —
    /// the standing card is not touched, the queue entry is consumed, and the
    /// capture published behind it drains in the SAME pass rather than waiting
    /// for a collision to be resolved by hand.
    func testACaptureCollidingWithACardOfAnotherKindLandsUnderItsEscapeID() async throws {
        let store = isolated.make()

        // The card the collision lands on: a screenshot already on the desk,
        // with its bytes on the synced lane, under the id the arriving capture
        // will claim.
        let sharedID = UUID()
        let theirs = Data("the screenshot the desk already holds".utf8)
        let existing = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: sharedID,
                kind: .image,
                title: "IMG.png",
                filename: "IMG.png",
                mimeType: "image/png",
                payload: theirs,
                byteSize: Int64(theirs.count)
            )
        )
        XCTAssertEqual(existing.availability, .synced)

        let payload = Data("the shared file the queue is holding for us".utf8)
        let colliding = collidingEnvelope(at: sharedID, byteCount: Int64(payload.count))
        let behindIt = WorkCaptureEnvelope(
            note: "The capture standing behind the collision",
            source: .app,
            entries: []
        )
        try publish(colliding, payloads: ["payload-000.bin": payload])
        try publish(behindIt)

        let report = try await makeDrainer(store: store).drainAvailableCaptures()

        XCTAssertEqual(report.invalidCaptureCount, 0, "a collision is not a discarded capture")
        XCTAssertEqual(
            report.importedCaptureCount + report.replayedCaptureCount, 2,
            "the collision must not stop the drain before the capture behind it"
        )

        let desk = try await unwrapDesk(store)
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: sharedID)

        // THE POINT: the capture's bytes are on the desk, under the escape id.
        let escaped = try XCTUnwrap(
            desk.materials.first { $0.id == escapeID },
            "a refused id must be escaped, not requeued for ever"
        )
        XCTAssertEqual(escaped.kind, .file)
        XCTAssertEqual(escaped.title, "contract.bin")
        let escapedBytes = try await store.loadWorkMaterialPayload(id: escapeID)
        XCTAssertEqual(escapedBytes, payload, "the escaped card carries the capture's own bytes")

        // And the card the collision landed on is exactly as it was.
        let collided = try XCTUnwrap(desk.materials.first { $0.id == sharedID })
        XCTAssertEqual(collided.kind, .image)
        XCTAssertEqual(collided.title, "IMG.png")
        XCTAssertEqual(collided.availability, .synced)
        let standingPayload = try await store.loadWorkMaterialPayload(id: sharedID)
        XCTAssertEqual(
            standingPayload, theirs,
            "the arriving capture's bytes must never become the standing card's payload"
        )

        // Both notes are on the desk, so the capture behind the collision was
        // drained in the same pass and not merely counted.
        XCTAssertTrue(desk.materials.contains { $0.id == colliding.id })
        XCTAssertTrue(desk.materials.contains { $0.id == behindIt.id })

        // The queue is empty, and nothing was retired: the capture succeeded.
        let pending = try await WorkCaptureInbox(baseURL: root).pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(try payloadCopies(named: "payload-000.bin", under: root), [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: refusedURL.path),
            "a capture that published needs no retirement"
        )
    }

    /// A second process replaying the same queue file derives the same escape
    /// id, so it repairs the one escaped card instead of publishing another.
    /// Staged with a second inbox and a second drainer over one directory and
    /// one store, which is the shape the app and the headless intent process
    /// have.
    func testAReplayOfACollidedCaptureRepairsTheSameEscapedCard() async throws {
        let store = isolated.make()
        let sharedID = UUID()
        let theirs = Data("the screenshot the desk already holds".utf8)
        _ = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                id: sharedID,
                kind: .image,
                title: "IMG.png",
                filename: "IMG.png",
                mimeType: "image/png",
                payload: theirs,
                byteSize: Int64(theirs.count)
            )
        )

        let payload = Data("the shared file the queue is holding for us".utf8)
        let colliding = collidingEnvelope(at: sharedID, byteCount: Int64(payload.count))
        try publish(colliding, payloads: ["payload-000.bin": payload])
        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        let afterFirst = try await unwrapDesk(store)
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: sharedID)
        XCTAssertTrue(afterFirst.materials.contains { $0.id == escapeID })

        // The same envelope, published again and drained by a different inbox
        // and drainer — the other process replaying the queue file.
        try publish(colliding, payloads: ["payload-000.bin": payload])
        _ = try await makeDrainer(store: store).drainAvailableCaptures()

        let afterReplay = try await unwrapDesk(store)
        XCTAssertEqual(
            afterReplay.materials.map(\.id).sorted { $0.uuidString < $1.uuidString },
            afterFirst.materials.map(\.id).sorted { $0.uuidString < $1.uuidString },
            "a derived escape id makes the replay a repair, not a second card"
        )
        XCTAssertEqual(
            afterReplay.materials.filter { $0.kind == .file }.count, 1,
            "one shared file is one card however many times its envelope is drained"
        )
        let escapedBytes = try await store.loadWorkMaterialPayload(id: escapeID)
        XCTAssertEqual(escapedBytes, payload)
    }

    // MARK: - A double collision is terminal, and unblocking

    /// Both ids taken by cards of another kind. There is no third id, so the
    /// capture is retired: its bytes are copied out of the queue first, the
    /// entry is then consumed rather than requeued, and the drain reaches the
    /// capture standing behind it in the same pass.
    func testACaptureRefusedUnderBothIdsIsRetiredWithItsBytesAndDoesNotBlockTheDrain() async throws {
        let store = isolated.make()
        let sharedID = UUID()
        let escapeID = WorkMaterialCollisionEscape.materialID(forCapture: sharedID)
        for (id, name) in [(sharedID, "IMG.png"), (escapeID, "ESCAPE.png")] {
            let bytes = Data("the screenshot already at \(name)".utf8)
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    id: id,
                    kind: .image,
                    title: name,
                    filename: name,
                    mimeType: "image/png",
                    payload: bytes,
                    byteSize: Int64(bytes.count)
                )
            )
        }

        let payload = Data("the shared file the queue is holding for us".utf8)
        let colliding = collidingEnvelope(at: sharedID, byteCount: Int64(payload.count))
        let behindIt = WorkCaptureEnvelope(
            note: "The capture standing behind the collision",
            source: .app,
            entries: []
        )
        try publish(colliding, payloads: ["payload-000.bin": payload])
        try publish(behindIt)

        let report = try await makeDrainer(store: store).drainAvailableCaptures()

        XCTAssertEqual(
            report.invalidCaptureCount, 1,
            "a capture that can never become a card is reported as one that did not arrive"
        )
        XCTAssertEqual(
            report.importedCaptureCount + report.replayedCaptureCount, 1,
            "and the capture behind it still imported"
        )

        let desk = try await unwrapDesk(store)
        XCTAssertTrue(
            desk.materials.contains { $0.id == behindIt.id },
            "a terminal refusal may not block the captures queued behind it"
        )
        XCTAssertFalse(
            desk.materials.contains { $0.kind == .file },
            "no card was published for the capture that was refused twice"
        )
        XCTAssertEqual(
            desk.materials.filter { $0.kind == .image }.map(\.title).sorted(),
            ["ESCAPE.png", "IMG.png"],
            "neither standing card was touched"
        )
        XCTAssertTrue(
            desk.materials.contains { $0.id == colliding.id },
            "the note this capture published before the refusal stays: retiring an entry"
                + " does not un-publish a card the desk already accepted"
        )

        // The queue no longer holds it, and neither does processing: an entry
        // that refuses identically on every drain may not be requeued.
        let inbox = WorkCaptureInbox(baseURL: root)
        let stillPending = try await inbox.pendingCount()
        XCTAssertEqual(stillPending, 0)
        XCTAssertEqual(
            try payloadCopies(named: "payload-000.bin", under: root.appendingPathComponent("processing")),
            []
        )

        // THE POINT: the bytes still exist, outside the queue.
        XCTAssertEqual(
            try payloadCopies(named: "payload-000.bin", under: refusedURL), [payload],
            "a capture the desk will never accept still keeps the file the person shared"
        )
        let retiredChildren = try FileManager.default.contentsOfDirectory(
            at: refusedURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            retiredChildren.map(\.lastPathComponent), [colliding.id.uuidString],
            "one retirement per envelope, named for it, so a repeated refusal writes no second copy"
        )
        let retired = try XCTUnwrap(
            retiredChildren.first,
            "the retired capture keeps its whole claimed directory"
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
        XCTAssertTrue(reason.contains(sharedID.uuidString), "the reason names the id that collided")
        XCTAssertTrue(reason.contains(escapeID.uuidString), "and the escape id that collided too")
    }

    // MARK: - Helpers

    private var refusedURL: URL {
        root.appendingPathComponent("refused", isDirectory: true)
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

    private func unwrapDesk(_ store: ConversationStore) async throws -> WorkItemRecord {
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        return try XCTUnwrap(deskValue, "every capture resolves the one desk")
    }

    private func makeDrainer(store: ConversationStore) -> WorkCaptureDrainer {
        WorkCaptureDrainer(
            inbox: WorkCaptureInbox(baseURL: root),
            store: store,
            sourceDevice: "collision-test"
        )
    }

    /// The bytes of every copy of one queued payload still on disk beneath
    /// `directory`. An absent directory holds no copies.
    private func payloadCopies(named name: String, under directory: URL) throws -> [Data] {
        guard FileManager.default.fileExists(atPath: directory.path),
              let walker = FileManager.default.enumerator(
                  at: directory,
                  includingPropertiesForKeys: nil
              ) else { return [] }
        var found: [Data] = []
        for case let url as URL in walker where url.lastPathComponent == name {
            found.append(try Data(contentsOf: url))
        }
        return found
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

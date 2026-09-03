// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkCaptureDrainerCollisionTests.swift
//
// What the share queue does when a capture's material id already names a
// DIFFERENT kind of card on the desk.
//
// The queue holds the only copy of a shared file, and the drainer may delete it
// only once the desk provably holds that file. An id collision is the one shape
// that can defeat that barrier from inside: if the desk write answers a
// colliding capture with the card that is already there — as an idempotent
// replay of itself — the drainer sees a record with a payload, passes its
// barrier on somebody else's bytes, and acknowledges. The capture is then gone
// with no card to show for it. Refusing the write is what keeps the bytes
// queued for a replay that can still land them.

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

    func testACaptureCollidingWithACardOfAnotherKindLeavesItsBytesQueued() async throws {
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
        let envelope = WorkCaptureEnvelope(
            note: "A capture whose entry id is already taken",
            source: .shareExtension,
            entries: [
                .init(
                    id: sharedID,
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.bin",
                    displayName: "contract.bin",
                    mimeType: "application/octet-stream",
                    byteCount: Int64(payload.count)
                )
            ]
        )
        try publish(envelope, payloads: ["payload-000.bin": payload])

        let inbox = WorkCaptureInbox(baseURL: root)
        let drainer = WorkCaptureDrainer(
            inbox: inbox,
            store: store,
            sourceDevice: "collision-test"
        )

        do {
            _ = try await drainer.drainAvailableCaptures()
            XCTFail("a capture that cannot publish its card must not report an import")
        } catch WorkboardStoreError.invalidMaterialOwner {
            // Expected: the desk write refuses the collision, and any throw
            // leaves the claim unacknowledged.
        }

        // THE POINT: the queue still holds the only copy of the shared file.
        XCTAssertEqual(
            try queuedPayloadBytes(named: "payload-000.bin"), [payload],
            "an unpublished capture's bytes may not be deleted from the queue"
        )

        // And the card the collision landed on is exactly as it was.
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let collided = try XCTUnwrap(desk.materials.first { $0.id == sharedID })
        XCTAssertEqual(collided.kind, .image)
        XCTAssertEqual(collided.title, "IMG.png")
        XCTAssertEqual(collided.availability, .synced)
        let standingPayload = try await store.loadWorkMaterialPayload(id: sharedID)
        XCTAssertEqual(
            standingPayload, theirs,
            "the arriving capture's bytes must never become the standing card's payload"
        )
        XCTAssertFalse(
            desk.materials.contains { $0.kind == .file },
            "and no card was published for the capture that was refused"
        )
    }

    // MARK: - Helpers

    /// The bytes of every copy of one queued payload still on disk, wherever
    /// the inbox has it — unclaimed at the root, or inside a claim directory.
    private func queuedPayloadBytes(named name: String) throws -> [Data] {
        guard let walker = FileManager.default.enumerator(
            at: root,
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

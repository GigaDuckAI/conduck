// SPDX-License-Identifier: Apache-2.0

// Conduck
// SharedInboxDrainerTests.swift
//
// Share Extension — coverage for `SharedInboxDrainer`, the main-app
// drainer that classifies → (uploads) → appends → assembles → dispatches each
// queued share envelope, reconciles prior-process leftovers on relaunch,
// surfaces failures (turn-exists → flip the exact turn `failed` + notify +
// DELETE; no-turn → notify + DELETE — no `failed/` quarantine graveyard), and
// janitors abandoned tmp/.
//
// ISOLATION (NO network, NO Keychain, NO signing):
//   - the inbox base is a per-test temp dir (never the App-Group container)
//   - the converse + upload ops are behind injected MOCK seams
//     (`MockConverseDispatcher` / `MockFileUploader`) — no URLSession
//   - routing is injected as a closure returning a PRE-RESOLVED target, so we
//     skip `SharedInboxRouting.resolveOrMint`'s non-empty-bearer-token
//     requirement (which would need a signed-build Keychain write)
//   - the file-server snapshot lookup is injected too (a canned snapshot, or nil
//     for the no-file-server case) — no Keychain credential read
//   - the store is a fresh `inMemory` `ConversationStore` per test
//
// The drainer drives `ConversationStore.shared`-less by accepting an injected
// `store`; `settings` defaults to `.shared` but is only touched for the
// (mocked-away) snapshot lookups, so no Keychain path runs.

import XCTest
import CoreData
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Conduck

final class SharedInboxDrainerTests: XCTestCase {

    // MARK: - Per-test temp inbox

    private var inboxBase: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        inboxBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-share-inbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxBase, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let inboxBase { try? FileManager.default.removeItem(at: inboxBase) }
        inboxBase = nil
        try super.tearDownWithError()
    }

    // MARK: - Layout helpers

    private var publishedRoot: URL { inboxBase }
    private var tmpDir: URL { inboxBase.appendingPathComponent("tmp", isDirectory: true) }
    private var processingDir: URL { inboxBase.appendingPathComponent("processing", isDirectory: true) }

    /// Write a PUBLISHED envelope (`Inbox/<uuid>/manifest.json` + each item's
    /// bytes) so the next `drain()` claims + processes it. Mirrors what the
    /// appex's atomic publish-rename leaves behind.
    @discardableResult
    private func writePublishedEnvelope(
        id: UUID = UUID(),
        caption: String = "",
        conversationID: UUID? = nil,
        urls: [String] = [],
        items: [(relPath: String, bytes: Data, originalName: String?, mimeType: String?, uti: String?, sequence: Int)] = [],
        createdAt: Date = Date(),
        // Provenance marker stamped on every item written (the webpage-capture
        // tests write ONE item). Defaults nil so every existing call stays
        // byte-identical — the manifest item's `sourceKind` already defaults nil.
        sourceKind: String? = nil
    ) throws -> UUID {
        let dir = publishedRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for item in items {
            try item.bytes.write(to: dir.appendingPathComponent(item.relPath))
        }

        let manifest = SharedInboxManifest(
            v: 1,
            uuid: id,
            createdAt: createdAt,
            caption: caption,
            conversationID: conversationID,
            newConversationGatewayRef: nil,
            selectedBackendRef: nil,
            items: items.map {
                SharedInboxManifestItem(
                    relPath: $0.relPath,
                    originalName: $0.originalName,
                    mimeType: $0.mimeType,
                    utTypeIdentifier: $0.uti,
                    sequence: $0.sequence,
                    sourceKind: sourceKind
                )
            },
            urls: urls,
            shouldAutosend: true
        )
        try manifest.encoded().write(to: dir.appendingPathComponent("manifest.json"))
        return id
    }

    /// Place an envelope directly in `processing/<uuid>/` (simulating a
    /// prior-process claim) with an optional `state.json`. Used by the reconcile
    /// tests. The dir's modification date is bumped to `createdAt`.
    @discardableResult
    private func writeProcessingEnvelope(
        id: UUID = UUID(),
        caption: String = "",
        conversationID: UUID? = nil,
        state: SharedInboxDrainer.EnvelopeState?,
        items: [(relPath: String, bytes: Data, originalName: String?, mimeType: String?, uti: String?, sequence: Int)] = []
    ) throws -> UUID {
        let dir = processingDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in items {
            try item.bytes.write(to: dir.appendingPathComponent(item.relPath))
        }
        let manifest = SharedInboxManifest(
            v: 1, uuid: id, createdAt: Date(), caption: caption, conversationID: conversationID,
            newConversationGatewayRef: nil, selectedBackendRef: nil,
            items: items.map {
                SharedInboxManifestItem(
                    relPath: $0.relPath, originalName: $0.originalName, mimeType: $0.mimeType,
                    utTypeIdentifier: $0.uti, sequence: $0.sequence)
            },
            urls: [], shouldAutosend: true
        )
        try manifest.encoded().write(to: dir.appendingPathComponent("manifest.json"))
        if let state {
            try JSONEncoder().encode(state).write(to: dir.appendingPathComponent("state.json"))
        }
        return id
    }

    /// Back-date a dir's modification time so the janitor sweep windows fire.
    private func backdate(_ url: URL, by interval: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-interval)], ofItemAtPath: url.path
        )
    }

    // MARK: - Image synthesis (real JPEG bytes — no network)

    /// A small real JPEG so `ImageProcessor.process` actually decodes it.
    private func makeJPEG(width: Int = 24, height: Int = 24) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    // MARK: - Webpage-capture fixture

    /// A synthetic captured-page Markdown blob (~`approxBytes` UTF-8): a metadata
    /// header + a long repeated body. Stands in for what the appex writes to
    /// `att-N.md`; the drainer treats it as any text file, so only the manifest
    /// item's `sourceKind == WebPageCapture.sourceKindWebpage` marks it a capture.
    private func webpageMarkdown(title: String, approxBytes: Int) -> String {
        let header = """
        # Captured Page: \(title)

        - Source: https://example.com/thread
        - Scope: Full page text

        ---

        """
        let unit = "This is a long captured paragraph of page text. "
        let repeats = max(1, approxBytes / unit.utf8.count)
        return header + String(repeating: unit, count: repeats)
    }

    // MARK: - Routing + snapshot fixtures (no Keychain)

    private func makeStore() -> ConversationStore { ConversationStore(inMemory: true) }

    /// A pre-resolved routing target bound to `conversationID` on the OpenClaw
    /// built-in. The snapshot's URL/token/model are canned (the mock dispatcher
    /// never opens a socket).
    private func resolved(conversationID: UUID) -> SharedInboxRouting.Resolved {
        let snapshot = SettingsManager.RemoteAgentSnapshot(
            backend: .openclaw,
            ref: .builtin(.openclaw),
            url: URL(string: "https://openclaw.example.test:18789")!,
            token: "tok",
            authScheme: .bearer,
            model: nil,
            certFingerprintHex: nil,
            activeSessionID: nil
        )
        return SharedInboxRouting.Resolved(
            conversationID: conversationID,
            snapshot: snapshot,
            token: "tok",
            ref: .builtin(.openclaw)
        )
    }

    private func fileServerSnapshot() -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://fileserver.example.test")!,
            username: Constants.fileServerUsername,
            credential: "deadbeefdeadbeefdeadbeefdeadbeef",
            certFingerprintHex: nil,
            available: true,
            folderCapable: true
        )
    }

    /// Build a drainer wired to `store`, a routing closure that mints a fresh
    /// conversation in `store` (so the append has a real parent row) then returns
    /// a pre-resolved target bound to it, and the given mock seams + file-server
    /// snapshot.
    private func makeDrainer(
        store: ConversationStore,
        dispatcher: MockConverseDispatcher,
        uploader: MockFileUploader = MockFileUploader(),
        fileServer: SettingsManager.FileTransferSnapshot? = nil
    ) -> SharedInboxDrainer {
        SharedInboxDrainer(
            inboxBase: inboxBase,
            dispatcher: dispatcher,
            uploader: uploader,
            store: store,
            settings: .shared,
            router: { [resolved] override, _, _, _, store in
                // Honour an override that resolves to an existing row; else mint a
                // fresh conversation in the test store + bind the resolved target.
                // (The new newConversationGatewayRef / selectedBackendRef args are
                // ignored by this canned router — the precedence itself is covered
                // in SharedInboxRoutingTests against the real resolveOrMint.)
                if let override, let existing = try? await store.fetchConversation(id: override) {
                    return resolved(existing.id)
                }
                let fresh = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
                return resolved(fresh.id)
            },
            fileTransferSnapshotProvider: { _, _ in fileServer }
        )
    }

    // MARK: - tmp/ is never drained

    func testTmpEnvelopesAreNeverClaimedOrProcessed() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        // A UUID dir under tmp/ (an in-progress appex write) must be ignored.
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpEnvelope = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpEnvelope, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: tmpEnvelope.appendingPathComponent("manifest.json"))

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 0, "A tmp/ envelope must never dispatch.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpEnvelope.path),
                      "A FRESH tmp/ envelope must not be swept by the janitor.")
    }

    // MARK: - Claim moves published → processing, then dispatches

    func testTextOnlyShareDispatchesAndDeletesEnvelopeOnSuccess() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "hi back")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        let id = try writePublishedEnvelope(caption: "hello agent", urls: ["https://example.com/x"])
        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1, "A text+URL share must dispatch exactly once.")
        let lastText = try XCTUnwrap(dispatcher.lastNewUserText)
        XCTAssertTrue(lastText.contains("hello agent"))
        XCTAssertTrue(lastText.contains("https://example.com/x"),
                      "Shared URLs must be combined into the user turn text.")

        // The user turn was appended under the envelope UUID.
        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        XCTAssertEqual(messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(messages.first?.id, id, "The user Message.id must be the envelope UUID.")

        // SUCCESS → the processing dir is deleted (no leftover).
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A successful dispatch must delete the processing/<uuid>/ dir.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: publishedRoot.appendingPathComponent(id.uuidString).path),
            "The published envelope must have been claimed (moved out).")
    }

    // MARK: - Image classification → image draft + data-URI

    /// Image + NO file-server → INLINE-ONLY (the no-regression baseline): one
    /// data-URI, zero uploads, no image ref, no persisted storedKey.
    func testImageItemProducesImageDraftAndDataURI() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "saw it")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: nil)

        let jpeg = try makeJPEG()
        let id = try writePublishedEnvelope(
            caption: "what is this",
            items: [(relPath: "att-0.jpg", bytes: jpeg, originalName: "photo.jpg",
                     mimeType: "image/jpeg", uti: UTType.jpeg.identifier, sequence: 0)]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(dispatcher.lastImageDataURIs?.count, 1,
                       "An image item must contribute one current-turn data-URI.")
        XCTAssertTrue(dispatcher.lastImageDataURIs?.first?.hasPrefix("data:image/jpeg;base64,") ?? false)
        XCTAssertEqual(uploader.uploadCount, 0, "No file-server → no upload (inline-only).")
        XCTAssertEqual(dispatcher.lastImageFileRefs?.count ?? 0, 0, "Inline-only → no image disk ref.")

        // The persisted user turn carries an inline image attachment draft (no key).
        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        let imageAtts = user.attachments.filter { $0.isImage }
        XCTAssertEqual(imageAtts.count, 1)
        XCTAssertNil(imageAtts.first?.storedKey, "An inline-only image persists no storedKey.")
        XCTAssertEqual(dispatcher.lastServerFileRefs?.count ?? 0, 0,
                       "An image is inline — it must NOT take the file-server path.")
    }

    /// Image + a file-server → DUAL (parity with the composer's `.dualImage`): the
    /// downsized JPEG rides inline (vision) AND the ORIGINAL raw bytes upload under
    /// the deterministic per-conversation key, threaded as an image disk ref.
    func testImageWithFileServerProducesDualInlineImagePlusUpload() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "saw + saved it")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let jpeg = try makeJPEG()
        let id = try writePublishedEnvelope(
            caption: "what is this",
            items: [(relPath: "att-0.jpg", bytes: jpeg, originalName: "photo.jpg",
                     mimeType: "image/jpeg", uti: UTType.jpeg.identifier, sequence: 0)]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(dispatcher.lastImageDataURIs?.count, 1,
                       "A dual image STILL rides inline (vision) — inline is never dropped this turn.")
        XCTAssertTrue(dispatcher.lastImageDataURIs?.first?.hasPrefix("data:image/jpeg;base64,") ?? false)
        XCTAssertEqual(uploader.uploadCount, 1,
                       "Image + file-server → DUAL: the ORIGINAL bytes also upload.")
        XCTAssertEqual(dispatcher.lastImageFileRefs?.count, 1,
                       "The dual-image turn carries a 'saved as' image disk ref alongside the inline part.")
        XCTAssertEqual(dispatcher.lastServerFileRefs?.count ?? 0, 0,
                       "A dual image is NOT a file-only server ref.")

        // The upload uses the deterministic per-attachment key under the routed
        // conversation folder (idempotent re-PUT on replay — same inputs, same key).
        let routedConvID = try XCTUnwrap(dispatcher.lastConversationID)
        let expectedKey = FileServerClient.deterministicStoredKey(
            envelopeID: id, sequence: 0, originalName: "photo.jpg",
            folder: routedConvID.uuidString)
        XCTAssertEqual(uploader.lastStoredKey, expectedKey)
        XCTAssertTrue((uploader.lastStoredKey ?? "").hasPrefix("\(routedConvID.uuidString)/"),
                      "The shared image must be namespaced under the conversation folder.")
        XCTAssertEqual(dispatcher.lastImageFileRefs?.first?.storedKey, expectedKey)
        XCTAssertEqual(dispatcher.lastImageFileRefs?.first?.filename, "photo.jpg")

        // Persisted: an INLINE image (isImage, NOT a server reference) that also
        // carries the storedKey — the exact dual-image shape `priorTurns` ages.
        let messages = try await store.fetchMessages(for: routedConvID)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        let imageAtts = user.attachments.filter { $0.isImage }
        XCTAssertEqual(imageAtts.count, 1)
        XCTAssertEqual(imageAtts.first?.storedKey, expectedKey, "The dual-image draft persists its upload key.")
        XCTAssertEqual(imageAtts.first?.isServerFile, false, "Dual image stays inline (not a download chip).")
    }

    /// Image with NO `originalName` → the upload name is synthesized from the
    /// ORIGINAL bytes' sniffed format (`image.<ext>`), deterministically.
    func testImageWithoutOriginalNameSynthesizesSniffedExtension() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let jpeg = try makeJPEG()
        let id = try writePublishedEnvelope(
            caption: "screenshot",
            items: [(relPath: "att-0", bytes: jpeg, originalName: nil,
                     mimeType: "image/jpeg", uti: UTType.jpeg.identifier, sequence: 0)]
        )

        await drainer.drain()

        XCTAssertEqual(uploader.uploadCount, 1)
        // makeJPEG() emits real JPEG magic bytes → sniffed ext "jpg".
        XCTAssertEqual(dispatcher.lastImageFileRefs?.first?.filename, "image.jpg",
                       "A nameless image is uploaded as image.<sniffed-ext>.")
        let routedConvID = try XCTUnwrap(dispatcher.lastConversationID)
        let expectedKey = FileServerClient.deterministicStoredKey(
            envelopeID: id, sequence: 0, originalName: "image.jpg",
            folder: routedConvID.uuidString)
        XCTAssertEqual(uploader.lastStoredKey, expectedKey)
    }

    /// Image dual upload FAILS → graceful inline-only (parity with the composer:
    /// inline is the guaranteed fallback). The turn STILL sends; no failure.
    func testImageUploadFailureGracefullyFallsBackToInlineOnly() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "saw it inline")
        let uploader = MockFileUploader(error: NSError(domain: "test", code: 1))
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let jpeg = try makeJPEG()
        let id = try writePublishedEnvelope(
            caption: "what is this",
            items: [(relPath: "att-0.jpg", bytes: jpeg, originalName: "photo.jpg",
                     mimeType: "image/jpeg", uti: UTType.jpeg.identifier, sequence: 0)]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1,
                       "A failed image upload must NOT block the send — it rides inline.")
        XCTAssertEqual(dispatcher.lastImageDataURIs?.count, 1, "The image still rides inline.")
        XCTAssertEqual(dispatcher.lastImageFileRefs?.count ?? 0, 0, "Failed upload → no image disk ref.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A failed dual-image upload must NOT fail the envelope — it sends inline and the successful dispatch deletes the processing dir.")

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        XCTAssertNil(user.attachments.first { $0.isImage }?.storedKey,
                     "A failed upload persists no storedKey (pure inline).")
    }

    /// A prior process's image upload for (envelope, sequence) is still in flight →
    /// DEFER the whole envelope (no re-PUT, no dispatch, stays in processing/).
    func testImageReplayWithLiveUploadTaskDefers() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "x")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let jpeg = try makeJPEG()
        let id = UUID()
        _ = try writePublishedEnvelope(
            id: id,
            caption: "pending image upload",
            items: [(relPath: "att-0.jpg", bytes: jpeg, originalName: "photo.jpg",
                     mimeType: "image/jpeg", uti: UTType.jpeg.identifier, sequence: 0)]
        )
        uploader.liveUploadKeys = [UploadKey(envelopeID: id, sequence: 0)]

        await drainer.drain()

        XCTAssertEqual(uploader.uploadCount, 0, "A live image upload task must DEFER, not re-PUT.")
        XCTAssertEqual(dispatcher.dispatchCount, 0, "A deferred envelope must not dispatch.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A deferred envelope must stay in processing/ for the next drain (not deleted, not failed).")
    }

    /// One envelope carrying an image + a small text file + a binary, all with a
    /// file-server → each routes to its own transport (image dual, text dual,
    /// binary file-only); three uploads; ordering preserved.
    func testMixedImageTextBinaryEachRouteCorrectly() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let jpeg = try makeJPEG()
        let textBytes = Data("a,b\n1,2\n".utf8)
        let binary = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x80, 0x81])
        let id = try writePublishedEnvelope(
            caption: "everything",
            items: [
                (relPath: "img.jpg", bytes: jpeg, originalName: "img.jpg",
                 mimeType: "image/jpeg", uti: UTType.jpeg.identifier, sequence: 0),
                (relPath: "data.csv", bytes: textBytes, originalName: "data.csv",
                 mimeType: "text/csv", uti: UTType.commaSeparatedText.identifier, sequence: 1),
                (relPath: "doc.pdf", bytes: binary, originalName: "doc.pdf",
                 mimeType: "application/pdf", uti: UTType.pdf.identifier, sequence: 2)
            ]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(dispatcher.lastImageDataURIs?.count, 1, "image → inline vision part")
        XCTAssertEqual(dispatcher.lastImageFileRefs?.count, 1, "image → dual disk ref")
        XCTAssertEqual(dispatcher.lastTextFileBlocks?.count, 1, "text → inline fenced block")
        XCTAssertEqual(dispatcher.lastTextFileServerRefs?.count, 1, "text → dual disk ref")
        XCTAssertEqual(dispatcher.lastServerFileRefs?.count, 1, "binary → file-only server ref")
        XCTAssertEqual(uploader.uploadCount, 3, "image + text + binary each upload once.")

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        XCTAssertEqual(user.attachments.count, 3, "all three attachments persist")
        XCTAssertEqual(user.attachments.map { $0.sequence }.sorted(), [0, 1, 2],
                       "attachment sequence order is preserved")
    }

    /// Dual-TEXT upload FAILS → graceful inline-only (the alignment with the
    /// composer this change locks in — it never fails the whole share).
    func testDualTextUploadFailureGracefullyFallsBackToInline() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "read it inline")
        let uploader = MockFileUploader(error: NSError(domain: "test", code: 1))
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let textBytes = Data("hello,world\n1,2\n".utf8)
        let id = try writePublishedEnvelope(
            caption: "summarize",
            items: [(relPath: "data.csv", bytes: textBytes, originalName: "data.csv",
                     mimeType: "text/csv", uti: UTType.commaSeparatedText.identifier, sequence: 0)]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1,
                       "A failed small-text upload must NOT block the send — it rides inline.")
        XCTAssertEqual(dispatcher.lastTextFileBlocks?.count, 1, "The text still rides inline.")
        XCTAssertEqual(dispatcher.lastTextFileServerRefs?.count ?? 0, 0, "Failed upload → no dual-text disk ref.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A failed dual-text upload must NOT fail the envelope — it sends inline and the successful dispatch deletes the processing dir.")

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        XCTAssertNil(user.attachments.first { $0.isText }?.storedKey,
                     "A failed upload persists no storedKey (pure inline).")
    }

    // MARK: - Text file → inline text block

    /// Small text + a file-server → DUAL: it rides inline as a text block AND
    /// uploads a byte-faithful copy so the agent's tools reach the real file
    /// (routed through `AttachmentDeliveryPlanner`, mirroring the composer).
    func testSmallTextFileWithServerProducesDualInlineBlockPlusUpload() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "read it")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let textBytes = Data("hello,world\n1,2\n".utf8)
        let id = try writePublishedEnvelope(
            caption: "summarize",
            items: [(relPath: "data.csv", bytes: textBytes, originalName: "data.csv",
                     mimeType: "text/csv", uti: UTType.commaSeparatedText.identifier, sequence: 0)]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(dispatcher.lastTextFileBlocks?.count, 1,
                       "A small dual-text file still rides as ONE inline text-file block.")
        XCTAssertEqual(dispatcher.lastTextFileBlocks?.first?.filename, "data.csv")
        XCTAssertEqual(uploader.uploadCount, 1,
                       "Small text + file-server → DUAL: the byte-faithful copy also uploads.")
        XCTAssertEqual(dispatcher.lastTextFileServerRefs?.count, 1,
                       "The dual-text turn carries a 'saved as' disk ref alongside the inline block.")
        XCTAssertEqual(dispatcher.lastTextFileServerRefs?.first?.originalName, "data.csv")
        XCTAssertEqual(dispatcher.lastServerFileRefs?.count ?? 0, 0,
                       "A dual-text file is NOT a file-only server ref.")

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        // Dual-text persists as an INLINE text attachment (isText) carrying a
        // storedKey — NOT a server reference (no download chip).
        let textAtts = user.attachments.filter { $0.isText }
        XCTAssertEqual(textAtts.count, 1)
        XCTAssertNotNil(textAtts.first?.storedKey, "the dual-text draft persists its upload storedKey")
        XCTAssertEqual(user.attachments.filter { $0.isServerFile }.count, 0)
    }

    /// Small text + NO file-server → INLINE-ONLY (today's behavior, no
    /// regression): one inline block, zero uploads, no disk ref.
    func testSmallTextFileWithoutServerStaysInlineOnly() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "read it")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: nil)

        let textBytes = Data("just a short note\n".utf8)
        let id = try writePublishedEnvelope(
            caption: "summarize",
            items: [(relPath: "note.txt", bytes: textBytes, originalName: "note.txt",
                     mimeType: "text/plain", uti: UTType.plainText.identifier, sequence: 0)]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(dispatcher.lastTextFileBlocks?.count, 1, "inline block rides")
        XCTAssertEqual(uploader.uploadCount, 0, "no file-server → no upload")
        XCTAssertEqual(dispatcher.lastTextFileServerRefs?.count ?? 0, 0, "no disk ref without a server")

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        XCTAssertEqual(user.attachments.filter { $0.isText }.count, 1)
        XCTAssertNil(user.attachments.first?.storedKey, "no storedKey persisted for an inline-only text file")
    }

    /// Large text + a file-server → FILE-ONLY: it uploads as a server reference
    /// (no inline block, gates as a normal server file) — the planner's
    /// `.required` route.
    func testLargeTextFileWithServerUploadsFileOnly() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "got it")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        // > textInlineMaxBytes of UTF-8 text → planner routes file-only.
        let bigText = String(repeating: "A", count: Constants.textInlineMaxBytes + 100)
        let id = try writePublishedEnvelope(
            caption: "process this big file",
            items: [(relPath: "big.txt", bytes: Data(bigText.utf8), originalName: "big.txt",
                     mimeType: "text/plain", uti: UTType.plainText.identifier, sequence: 0)]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(uploader.uploadCount, 1, "Large text + file-server → upload the file.")
        XCTAssertEqual(dispatcher.lastTextFileBlocks?.count ?? 0, 0,
                       "A large text file does NOT ride inline (too big).")
        XCTAssertEqual(dispatcher.lastServerFileRefs?.count, 1,
                       "A large text file rides as a file-only server ref (the 'in your working directory' line).")
        XCTAssertEqual(dispatcher.lastTextFileServerRefs?.count ?? 0, 0,
                       "A large text file is file-only, not dual (no dual-text ref).")

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        XCTAssertEqual(user.attachments.filter { $0.isServerFile }.count, 1,
                       "A large text file persists as a server-reference draft.")
    }

    // MARK: - Webpage capture (Safari page-text) — no-file-server inline clamp + originalName

    /// Webpage capture, NO file-server, > 32 KiB → the inline copy is CLAMPED to
    /// the inline cap with an honest note (this client-owned-history protocol
    /// re-sends the full conversation every turn, so an unbounded page would tax
    /// every subsequent turn), and the PERSISTED attachment is labelled with the
    /// capture's `originalName` (prior-turn replay reads the persisted filename).
    func testWebpageCaptureNoServerOverCapTruncatesWithHonestNote() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "read it")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: nil)

        let originalName = "Captured Page — Long Thread.md"
        let markdown = webpageMarkdown(title: "Long Thread", approxBytes: 60 * 1024)
        let bytes = Data(markdown.utf8)
        XCTAssertGreaterThan(bytes.count, Constants.textInlineMaxBytes,
                             "fixture must exceed the inline cap to exercise the clamp")

        let id = try writePublishedEnvelope(
            caption: "summarize this page",
            items: [(relPath: "att-0.md", bytes: bytes, originalName: originalName,
                     mimeType: "text/markdown", uti: "net.daringfireball.markdown", sequence: 0)],
            sourceKind: WebPageCapture.sourceKindWebpage
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(uploader.uploadCount, 0, "No file-server → no upload (inline-only, clamped).")

        // The inline block was CLAMPED to the inline cap with the honest note.
        let block = try XCTUnwrap(dispatcher.lastTextFileBlocks?.first)
        XCTAssertLessThanOrEqual(block.text.utf8.count, Constants.textInlineMaxBytes,
                                 "A webpage capture on a server-less gateway must clamp to the inline cap.")
        XCTAssertTrue(block.text.contains("Truncated by Conduck"))
        XCTAssertTrue(block.text.contains("no file server configured"))
        XCTAssertTrue(block.text.contains(WebPageCapture.formatKB(bytes.count)),
                      "The note states the true original size in KB.")
        XCTAssertEqual(block.filename, originalName,
                       "The inline block is labelled with the capture's originalName.")

        // The PERSISTED inline text attachment carries originalName + is ≤ cap.
        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        let textAtt = try XCTUnwrap(user.attachments.first { $0.isText })
        XCTAssertEqual(textAtt.filename, originalName,
                       "The persisted filename is the capture's originalName (prior-turn replay reads THIS).")
        XCTAssertLessThanOrEqual(textAtt.byteSize, Constants.textInlineMaxBytes,
                                 "The persisted clamped attachment is within the inline cap.")
        XCTAssertNil(textAtt.storedKey, "server-less inline-only → no storedKey")
    }

    /// Webpage capture, NO file-server, UNDER 32 KiB → rides VERBATIM (no clamp,
    /// no note), still labelled with the capture's `originalName`.
    func testWebpageCaptureNoServerUnderCapRidesVerbatim() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "read it")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, fileServer: nil)

        let originalName = "Captured Page — Short Note.md"
        let markdown = webpageMarkdown(title: "Short Note", approxBytes: 2 * 1024)
        let bytes = Data(markdown.utf8)
        XCTAssertLessThan(bytes.count, Constants.textInlineMaxBytes)

        let id = try writePublishedEnvelope(
            caption: "summarize",
            items: [(relPath: "att-0.md", bytes: bytes, originalName: originalName,
                     mimeType: "text/markdown", uti: "net.daringfireball.markdown", sequence: 0)],
            sourceKind: WebPageCapture.sourceKindWebpage
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        let block = try XCTUnwrap(dispatcher.lastTextFileBlocks?.first)
        XCTAssertEqual(block.text, markdown, "Under the cap, the capture rides verbatim (no clamp).")
        XCTAssertFalse(block.text.contains("Truncated by Conduck"), "No note when under the cap.")
        XCTAssertEqual(block.filename, originalName)

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        let textAtt = try XCTUnwrap(user.attachments.first { $0.isText })
        XCTAssertEqual(textAtt.filename, originalName)
        XCTAssertEqual(textAtt.byteSize, bytes.count, "The full (verbatim) bytes persist.")
    }

    /// REGRESSION LOCK: a NON-webpage (`sourceKind == nil`) large text file with NO
    /// file-server still rides UNLIMITED inline, untouched, under its extracted
    /// default filename — today's behavior, which the webpage clamp must NEVER
    /// change for a regular shared file.
    func testNonWebpageLargeTextNoServerStaysUnlimitedInline() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: nil)

        let bigText = String(repeating: "B", count: Constants.textInlineMaxBytes + 5000)
        let bytes = Data(bigText.utf8)
        let id = try writePublishedEnvelope(
            caption: "read my big note",
            items: [(relPath: "big.txt", bytes: bytes, originalName: "big.txt",
                     mimeType: "text/plain", uti: UTType.plainText.identifier, sequence: 0)]
            // sourceKind omitted → nil → NOT a webpage capture.
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(uploader.uploadCount, 0, "No file-server → no upload.")
        let block = try XCTUnwrap(dispatcher.lastTextFileBlocks?.first)
        XCTAssertEqual(block.text.utf8.count, bytes.count,
                       "REGRESSION LOCK: regular text on a server-less gateway rides UNLIMITED inline — never clamped.")
        XCTAssertFalse(block.text.contains("Truncated by Conduck"),
                       "Regular text must never get the webpage truncation note.")
        XCTAssertEqual(block.filename, "big.txt", "Non-webpage keeps the extracted default filename.")

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let messages = try await store.fetchMessages(for: cid)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        let textAtt = try XCTUnwrap(user.attachments.first { $0.isText })
        XCTAssertEqual(textAtt.byteSize, bytes.count, "The full (unclamped) bytes persist.")
        XCTAssertEqual(textAtt.filename, "big.txt")
    }

    // MARK: - Webpage capture WITH a file-server → routes as regular text, named by originalName

    /// Webpage capture WITH a file-server, small → DUAL (inline + upload), no
    /// truncation note; the inline block, dual disk ref, upload key + persisted
    /// filename all use the capture's `originalName`.
    func testWebpageCaptureWithServerSmallDualUsesOriginalName() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "read + saved")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let originalName = "Captured Page — Short Note.md"
        let markdown = webpageMarkdown(title: "Short Note", approxBytes: 2 * 1024)
        let bytes = Data(markdown.utf8)
        XCTAssertLessThan(bytes.count, Constants.textInlineMaxBytes)

        let id = try writePublishedEnvelope(
            caption: "summarize",
            items: [(relPath: "att-0.md", bytes: bytes, originalName: originalName,
                     mimeType: "text/markdown", uti: "net.daringfireball.markdown", sequence: 0)],
            sourceKind: WebPageCapture.sourceKindWebpage
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(uploader.uploadCount, 1, "Webpage + file-server small → DUAL (inline + upload).")

        let block = try XCTUnwrap(dispatcher.lastTextFileBlocks?.first)
        XCTAssertEqual(block.filename, originalName)
        XCTAssertFalse(block.text.contains("Truncated by Conduck"),
                       "Server present → the inline copy is NOT clamped (no note).")
        XCTAssertEqual(dispatcher.lastTextFileServerRefs?.first?.originalName, originalName,
                       "The dual disk ref uses the capture's originalName.")

        let routedConvID = try XCTUnwrap(dispatcher.lastConversationID)
        let expectedKey = FileServerClient.deterministicStoredKey(
            envelopeID: id, sequence: 0, originalName: originalName, folder: routedConvID.uuidString)
        XCTAssertEqual(uploader.lastStoredKey, expectedKey,
                       "The upload key is built from originalName, not the synthetic att-N.md.")

        let messages = try await store.fetchMessages(for: routedConvID)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        let textAtt = try XCTUnwrap(user.attachments.first { $0.isText })
        XCTAssertEqual(textAtt.filename, originalName, "Persisted dual-text filename == originalName.")
        XCTAssertNotNil(textAtt.storedKey, "Dual-text persists its upload key.")
    }

    /// Webpage capture WITH a file-server, > 32 KiB → FILE-ONLY upload (no inline
    /// block); the file-only server ref, upload key + persisted filename all use
    /// the capture's `originalName`.
    func testWebpageCaptureWithServerOverCapFileOnlyUsesOriginalName() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "got it")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let originalName = "Captured Page — Long Thread.md"
        let markdown = webpageMarkdown(title: "Long Thread", approxBytes: 60 * 1024)
        let bytes = Data(markdown.utf8)
        XCTAssertGreaterThan(bytes.count, Constants.textInlineMaxBytes)

        let id = try writePublishedEnvelope(
            caption: "process this page",
            items: [(relPath: "att-0.md", bytes: bytes, originalName: originalName,
                     mimeType: "text/markdown", uti: "net.daringfireball.markdown", sequence: 0)],
            sourceKind: WebPageCapture.sourceKindWebpage
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(uploader.uploadCount, 1, "Webpage + file-server large → file-only upload.")
        XCTAssertEqual(dispatcher.lastTextFileBlocks?.count ?? 0, 0, "File-only → no inline block.")
        XCTAssertEqual(dispatcher.lastServerFileRefs?.first?.originalName, originalName,
                       "The file-only server ref uses the capture's originalName.")

        let routedConvID = try XCTUnwrap(dispatcher.lastConversationID)
        let expectedKey = FileServerClient.deterministicStoredKey(
            envelopeID: id, sequence: 0, originalName: originalName, folder: routedConvID.uuidString)
        XCTAssertEqual(uploader.lastStoredKey, expectedKey)

        let messages = try await store.fetchMessages(for: routedConvID)
        let user = try XCTUnwrap(messages.first { $0.id == id })
        let serverAtt = try XCTUnwrap(user.attachments.first { $0.isServerFile })
        XCTAssertEqual(serverAtt.filename, originalName, "Persisted file-only draft filename == originalName.")
    }

    // MARK: - Binary + NO file-server → notify + DELETE the whole envelope (no-turn)

    /// A binary routed to a gateway with no file-server is a NO-TURN failure (it
    /// fails BEFORE the user turn is appended). The drainer notifies the user it
    /// couldn't send + DELETES the envelope (no `failed/` graveyard, no partial
    /// send, no inline bubble — there's nothing to flip). Replaces the old
    /// retention/quarantine behavior (`SharedInboxDrainerTests.swift:665`).
    func testBinaryWithNoFileServerNotifiesAndDeletesWholeEnvelope() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "x")
        let uploader = MockFileUploader()
        // fileServer: nil → no file-server for this gateway.
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: nil)

        // A binary (undecodable as UTF-8, not an image) PLUS a sibling image —
        // the WHOLE envelope must fail; the image must NOT be sent alone.
        let binary = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x80, 0x81])
        let jpeg = try makeJPEG()
        let id = try writePublishedEnvelope(
            caption: "look at my pdf",
            items: [
                (relPath: "img.jpg", bytes: jpeg, originalName: "img.jpg",
                 mimeType: "image/jpeg", uti: UTType.jpeg.identifier, sequence: 0),
                (relPath: "doc.pdf", bytes: binary, originalName: "doc.pdf",
                 mimeType: "application/pdf", uti: UTType.pdf.identifier, sequence: 1)
            ]
        )

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 0,
                       "A binary routed to a server-less gateway must NOT send a partial turn.")
        XCTAssertEqual(uploader.uploadCount, 0)
        // The envelope is DELETED — gone from BOTH the published root and
        // processing/ (no `failed/` graveyard exists anymore).
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: publishedRoot.appendingPathComponent(id.uuidString).path),
            "A no-turn failure must DELETE the envelope from the published root.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A no-turn failure must DELETE the claimed processing/ dir — no retention.")
    }

    // MARK: - Binary + file-server → uploadFile with the deterministic key

    func testBinaryWithFileServerUploadsWithDeterministicKey() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "got the file")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let binary = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x80, 0x81])
        let id = try writePublishedEnvelope(
            caption: "process this",
            items: [(relPath: "report.pdf", bytes: binary, originalName: "report.pdf",
                     mimeType: "application/pdf", uti: UTType.pdf.identifier, sequence: 2)]
        )

        await drainer.drain()

        XCTAssertEqual(uploader.uploadCount, 1, "A binary with a file-server must upload exactly once.")
        // The shared file lands under the routed conversation's folder (Phase B:
        // every file a conversation receives — composer or share — is namespaced
        // under `<conversationID>/`). The snapshot is folder-capable (default), so
        // the deterministic key carries the conversation folder.
        let routedConvID = try XCTUnwrap(dispatcher.lastConversationID)
        let expectedKey = FileServerClient.deterministicStoredKey(
            envelopeID: id, sequence: 2, originalName: "report.pdf",
            folder: routedConvID.uuidString)
        XCTAssertEqual(uploader.lastStoredKey, expectedKey,
                       "The upload must use the deterministic per-attachment key, under the conversation folder.")
        XCTAssertTrue((uploader.lastStoredKey ?? "").hasPrefix("\(routedConvID.uuidString)/"),
                      "The shared file must be namespaced under the conversation folder.")
        XCTAssertEqual(uploader.lastSequence, 2)
        XCTAssertEqual(uploader.lastShareEnvelopeID, id)

        // The turn dispatched with a server-file ref (not an inline block).
        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(dispatcher.lastServerFileRefs?.count, 1)
        XCTAssertEqual(dispatcher.lastServerFileRefs?.first?.storedKey, expectedKey)
    }

    // MARK: - Drain twice → one user turn (dedupe)

    func testDrainingSameEnvelopeTwiceProducesOneUserTurn() async throws {
        let store = makeStore()
        // Both drains SUCCEED. The append is keyed on the envelope UUID, so even
        // re-publishing the SAME id and draining again produces only ONE user
        // turn (dedupe-on-id). (Exercises the success → delete → re-publish path,
        // not a failure path.)
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        let id = try writePublishedEnvelope(caption: "dedupe me")

        // Drain once → success → user turn appended under `id`.
        await drainer.drain()
        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        let afterFirst = try await store.fetchMessages(for: cid)
        XCTAssertEqual(afterFirst.filter { $0.role == "user" }.count, 1)

        // Re-publish the SAME envelope id (a duplicate drain trigger / re-share)
        // and drain again — the dedupe-on-id append must NOT add a 2nd user turn.
        // Route the re-publish to the SAME conversation via the override path.
        _ = try writePublishedEnvelope(id: id, caption: "dedupe me", conversationID: cid)
        await drainer.drain()

        let afterSecond = try await store.fetchMessages(for: cid)
        XCTAssertEqual(afterSecond.filter { $0.role == "user" }.count, 1,
                       "Re-draining the same envelope UUID must not duplicate the user turn.")
    }

    // MARK: - Dispatch throws AFTER the append → fail the EXACT turn + DELETE

    /// The common failure (gateway down): the user turn was appended (id ==
    /// envelope uuid, `sending`) THEN the dispatch threw. This is a TURN-EXISTS
    /// failure → flip THAT exact turn to `failed` (inline failed bubble + Retry,
    /// which re-sends from Core Data) and DELETE the envelope (the conversation is
    /// the single recovery surface — no `failed/` graveyard). At-most-once holds:
    /// the deleted envelope is never re-dispatched; inline Retry re-sends from the
    /// store.
    func testDispatchFailureFlipsExactTurnToFailedAndDeletesEnvelope() async throws {
        let store = makeStore()
        // The dispatch THROWS (gateway down).
        let dispatcher = MockConverseDispatcher(reply: "x", error: NSError(domain: "test", code: 7))
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        let id = try writePublishedEnvelope(caption: "send me when gateway is down")

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 1, "The dispatch is attempted exactly once.")
        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        // The EXACT user turn (id == envelope uuid) is flipped off `sending` to
        // `failed` so the bubble shows Retry instead of an eternal spinner.
        let messages = try await store.fetchMessages(for: cid)
        let userTurn = try XCTUnwrap(messages.first { $0.id == id })
        XCTAssertEqual(userTurn.status, "failed",
                       "A dispatch failure must flip the EXACT user turn to `failed` (inline Retry).")
        // The envelope is DELETED (no retention, no `failed/` graveyard).
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A dispatch failure must DELETE the envelope (the conversation owns recovery).")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: publishedRoot.appendingPathComponent(id.uuidString).path))
    }

    // MARK: - Reconcile: submitted + live task → left in place

    func testReconcileSubmittedWithLiveTaskLeavesEnvelope() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "x")
        dispatcher.liveConverseEnvelopeIDs = []   // set below
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        let cid = UUID()
        let id = try writeProcessingEnvelope(
            state: .init(conversationID: cid, submitted: true)
        )
        dispatcher.liveConverseEnvelopeIDs = [id]   // a live task exists for it

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 0, "A submitted+live envelope must NOT re-dispatch.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A submitted envelope with a LIVE task must be left in processing/ (not deleted).")
    }

    // MARK: - Reconcile: submitted + reply landed → deleted

    func testReconcileSubmittedWithLandedReplyDeletesEnvelope() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "x")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        // Mint a real conversation + append the user turn (id == envelopeID) AND
        // an agent reply, simulating the delegate having landed it before the
        // prior process died.
        let convo = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        let id = UUID()
        _ = try await store.appendMessage(
            id: id, role: "user", text: "q", conversationID: convo.id, sourceDevice: "iphone", status: "sent")
        _ = try await store.appendMessage(
            role: "agent", text: "a", conversationID: convo.id, sourceDevice: "iphone")

        _ = try writeProcessingEnvelope(
            id: id, state: .init(conversationID: convo.id, submitted: true))

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 0, "A landed reply must NOT re-dispatch.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A submitted envelope whose reply already landed must be DELETED.")
    }

    // MARK: - Reconcile: submitted + no task + no reply → fail the turn + DELETE

    /// An ambiguous submitted envelope (no live task, no landed reply) is a
    /// TURN-EXISTS failure: `submitted` is written AFTER the append, so the user
    /// turn (id == envelopeID, still `sending`) exists. The reconcile flips THAT
    /// exact turn to `failed` (inline failed bubble + Retry re-sends from Core
    /// Data), NEVER auto-resends (at-most-once), and DELETES the envelope (no
    /// `failed/` graveyard). Replaces the old quarantine-retention behavior.
    func testReconcileSubmittedWithNoTaskNoReplyFailsTurnAndDeletes() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "x")  // no live task scripted
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        let convo = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        let id = UUID()
        // Only the user turn exists — no agent reply, no live task → ambiguous.
        _ = try await store.appendMessage(
            id: id, role: "user", text: "q", conversationID: convo.id, sourceDevice: "iphone", status: "sending")

        _ = try writeProcessingEnvelope(
            id: id, state: .init(conversationID: convo.id, submitted: true))

        await drainer.drain()

        XCTAssertEqual(dispatcher.dispatchCount, 0,
                       "At-most-once: a submitted envelope with no task + no reply must NEVER auto-resend.")
        // The envelope is DELETED (no `failed/` graveyard).
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "An ambiguous submitted envelope must be DELETED after failing its turn.")
        // The EXACT user turn (id == envelopeID) is flipped off `sending` to
        // `failed` so the inline bubble shows Retry instead of an eternal spinner.
        let messages = try await store.fetchMessages(for: convo.id)
        let userTurn = try XCTUnwrap(messages.first { $0.id == id })
        XCTAssertEqual(userTurn.status, "failed",
                       "The stranded user turn must be flipped to `failed` (inline Retry).")
    }

    // MARK: - Upload reconcile: live upload task → deferred

    func testReconcileLiveUploadTaskDefersEnvelope() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "x")
        let uploader = MockFileUploader()
        let drainer = makeDrainer(store: store, dispatcher: dispatcher, uploader: uploader,
                                  fileServer: fileServerSnapshot())

        let binary = Data([0x00, 0x01, 0xFF, 0x80])
        let id = UUID()
        _ = try writeProcessingEnvelope(
            id: id,
            caption: "pending upload",
            state: nil,   // submitted==false → re-run Process
            items: [(relPath: "f.bin", bytes: binary, originalName: "f.bin",
                     mimeType: "application/octet-stream", uti: UTType.data.identifier, sequence: 0)]
        )
        // A prior process's upload for (id, 0) is still in flight → DEFER.
        uploader.liveUploadKeys = [UploadKey(envelopeID: id, sequence: 0)]

        await drainer.drain()

        XCTAssertEqual(uploader.uploadCount, 0, "A live upload task must DEFER, not re-PUT.")
        XCTAssertEqual(dispatcher.dispatchCount, 0, "A deferred envelope must not dispatch.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A deferred envelope must stay in processing/ for the next drain (not deleted, not failed).")
    }

    // MARK: - Janitor sweeps stale tmp/ only

    func testJanitorSweepsStaleTmpButNotFresh() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "x")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        // Ensure the scaffold exists (a no-op drain creates tmp/processing).
        await drainer.drain()

        // A stale tmp/ envelope (>1h) + a fresh one.
        let staleTmp = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staleTmp, withIntermediateDirectories: true)
        try backdate(staleTmp, by: 2 * 60 * 60)
        let freshTmp = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: freshTmp, withIntermediateDirectories: true)

        await drainer.drain()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTmp.path),
                       "A tmp/ envelope older than 1h must be swept.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTmp.path),
                      "A FRESH tmp/ envelope (in-progress appex write) must NOT be swept.")
    }

    // MARK: - Double-dispatch race (in-flight guard)

    /// REGRESSION: a notification-tap drain and a foreground drain interleave so
    /// that a live `process(...)` owns a claimed `processing/<uuid>/` dir while
    /// still SUSPENDED in routing (BEFORE `writeState(submitted:true)`), and a
    /// concurrent `drain()` runs `reconcileProcessing` over that same dir,
    /// `readState` returns nil → without the in-flight guard it would re-run
    /// `process` and fire a SECOND `dispatcher.dispatch` (double-hit the user's
    /// gateway). The in-flight set must make the concurrent reconcile SKIP, so
    /// exactly ONE dispatch fires.
    ///
    /// The race window is reproduced deterministically by GATING the router: the
    /// first claim's `process` blocks inside the injected router (pre-`writeState`)
    /// on a continuation the test resumes ONLY after the concurrent reconcile has
    /// run to completion.
    func testConcurrentReconcileDoesNotDoubleDispatchWhileProcessInFlight() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")

        // A gate the router awaits on its FIRST invocation: it signals "I'm now in
        // routing (claimed + in-flight, no state.json yet)" then suspends until the
        // test releases it. Subsequent invocations (there must be none) pass
        // straight through — so a second router entry would be observable.
        let gate = RouterGate()

        let drainer = SharedInboxDrainer(
            inboxBase: inboxBase,
            dispatcher: dispatcher,
            uploader: MockFileUploader(),
            store: store,
            settings: .shared,
            router: { [resolved] override, _, _, _, store in
                await gate.enterAndWait()
                if let override, let existing = try? await store.fetchConversation(id: override) {
                    return resolved(existing.id)
                }
                let fresh = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
                return resolved(fresh.id)
            },
            fileTransferSnapshotProvider: { _, _ in nil }
        )

        let id = try writePublishedEnvelope(caption: "race me")

        // 1. Kick off the "notification tap" drain. It claims `id` into
        //    processing/, marks it in-flight, enters the router, and SUSPENDS.
        async let firstDrain: Void = drainer.drain()

        // 2. Wait until the first call is parked inside the router (claimed +
        //    in-flight, state.json not yet written).
        await gate.waitUntilEntered()

        // 3. Fire the concurrent "foreground" drain. Its reconcile sees the
        //    in-flight processing/ dir and MUST skip it (no second dispatch, no
        //    re-claim). This call returns promptly (nothing else to do).
        await drainer.drain()

        // 4. Release the parked first call so it finishes its single dispatch.
        await gate.release()
        await firstDrain

        XCTAssertEqual(dispatcher.dispatchCount, 1,
                       "The in-flight guard must prevent a concurrent reconcile from issuing a second dispatch.")
        XCTAssertEqual(gate.enterCount, 1,
                       "The router must be entered exactly once — a second entry means the envelope was re-processed.")

        // The envelope succeeded once → its processing/ dir is gone (deleted on
        // the single successful dispatch).
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "A single successful dispatch must delete the processing/<uuid>/ dir.")
    }

    // MARK: - drainAndResolve navigation (founder Phase-D bug)

    /// CASE A — `drainAndResolve` on a STILL-PUBLISHED envelope claims + processes
    /// it and returns the routed conversation id (the turn landed there), with a
    /// single dispatch.
    func testDrainAndResolveCaseAReturnsRoutedConversationID() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        let id = try writePublishedEnvelope(caption: "open me")

        let resolvedID = await drainer.drainAndResolve(envelopeID: id.uuidString)

        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        XCTAssertEqual(resolvedID, cid,
                       "CASE A must return the conversation id the turn was routed to.")
        XCTAssertEqual(dispatcher.dispatchCount, 1, "Exactly one dispatch on CASE A.")
        // The turn is durably in that conversation under the envelope UUID.
        let messages = try await store.fetchMessages(for: cid)
        XCTAssertTrue(messages.contains { $0.id == id })
    }

    /// THE FOUNDER PHASE-D RACE: a foreground `drain()` WINS the claim and fully
    /// processes the envelope (sends + deletes the dir on success → CASE C) BEFORE
    /// the notification-tap `drainAndResolve` runs. The old code returned nil here
    /// (no state.json, dir gone) → no navigation. The fix must resolve the target
    /// id durably via the landed message (`Message.id == envelope uuid`), and must
    /// NOT issue a second dispatch.
    func testDrainAndResolveAfterForegroundDrainReturnsLandedConversationID() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        let id = try writePublishedEnvelope(caption: "race nav")

        // Foreground drain processes + sends + deletes the envelope on success.
        await drainer.drain()
        let cid = try XCTUnwrap(dispatcher.lastConversationID)
        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: processingDir.appendingPathComponent(id.uuidString).path),
            "drain() success must have deleted the processing dir (→ CASE C for drainAndResolve).")

        // Notification tap now resolves — must find the landed conversation via the
        // durable message, NOT return nil, and NOT re-dispatch.
        let resolvedID = await drainer.drainAndResolve(envelopeID: id.uuidString)
        XCTAssertEqual(resolvedID, cid,
                       "drainAndResolve must resolve the conversation the foreground drain's turn landed in.")
        XCTAssertEqual(dispatcher.dispatchCount, 1,
                       "drainAndResolve must NOT re-dispatch an envelope another drain already processed.")
    }

    /// CASE B/C durable fallback in isolation: a turn with `Message.id == uuid`
    /// already exists (a prior drain appended it) but there is NO `state.json` and
    /// NO envelope dir — `drainAndResolve` must still resolve the conversation via
    /// the message lookup, with zero dispatches.
    func testDrainAndResolveResolvesViaMessageWhenStateAndDirAbsent() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        // Seed a conversation + a user turn whose id IS the envelope uuid (what a
        // prior successful drain leaves behind), with no envelope dir on disk.
        let id = UUID()
        let convo = try await store.createConversation(backend: RemoteAgentBackend.openclaw.rawValue)
        _ = try await store.appendMessage(
            id: id, role: "user", text: "already sent",
            conversationID: convo.id, sourceDevice: SourceDevice.current, status: "sent"
        )

        let resolvedID = await drainer.drainAndResolve(envelopeID: id.uuidString)
        XCTAssertEqual(resolvedID, convo.id,
                       "drainAndResolve must resolve the conversation the landed message belongs to.")
        XCTAssertEqual(dispatcher.dispatchCount, 0,
                       "Resolving a completed envelope must never dispatch.")
    }

    /// A truly unknown envelope (never queued, no message) resolves to nil after
    /// the poll budget — the tap then just foregrounds, no navigation.
    func testDrainAndResolveUnknownEnvelopeReturnsNil() async throws {
        let store = makeStore()
        let dispatcher = MockConverseDispatcher(reply: "ok")
        let drainer = makeDrainer(store: store, dispatcher: dispatcher)

        let resolvedID = await drainer.drainAndResolve(envelopeID: UUID().uuidString)
        XCTAssertNil(resolvedID, "An unknown envelope must resolve to nil (no navigation).")
        XCTAssertEqual(dispatcher.dispatchCount, 0)
    }
}

// MARK: - Mock seams

/// Records what the drainer asked it to dispatch + answers the live-task probe
/// + returns a canned reply or throws. NO network.
private final class MockConverseDispatcher: ShareConverseDispatching, @unchecked Sendable {
    private let lock = NSLock()

    let reply: String
    let error: Error?
    /// Envelope IDs the live-task probe should report as in flight.
    var liveConverseEnvelopeIDs: Set<UUID> = []

    private(set) var dispatchCount = 0
    private(set) var lastRef: RemoteAgentRef?
    private(set) var lastAuthScheme: RemoteAgentAuthScheme?
    private(set) var lastNewUserText: String?
    private(set) var lastImageDataURIs: [String]?
    private(set) var lastTextFileBlocks: [(filename: String, text: String)]?
    private(set) var lastServerFileRefs: [(originalName: String, storedKey: String)]?
    private(set) var lastTextFileServerRefs: [(originalName: String, storedKey: String)]?
    private(set) var lastImageFileRefs: [(storedKey: String, filename: String)]?
    private(set) var lastFileTransferLaneID: String?
    private(set) var lastConversationID: UUID?
    private(set) var lastShareEnvelopeID: UUID?

    init(reply: String = "ok", error: Error? = nil) {
        self.reply = reply
        self.error = error
    }

    func dispatch(
        backend: RemoteAgentBackend,
        ref: RemoteAgentRef,
        url: URL,
        token: String,
        authScheme: RemoteAgentAuthScheme,
        model: String?,
        priorTurns: [ConverseRequest.Message],
        newUserText: String,
        newUserImageDataURIs: [String],
        newUserTextFileBlocks: [(filename: String, text: String)],
        newUserServerFileRefs: [(originalName: String, storedKey: String)],
        newUserImageFileRefs: [(storedKey: String, filename: String)],
        newUserTextFileServerRefs: [(originalName: String, storedKey: String)],
        fileTransferSnapshot: SettingsManager.FileTransferSnapshot?,
        conversationID: UUID,
        shareEnvelopeID: UUID
    ) async throws -> String {
        lock.lock()
        dispatchCount += 1
        lastRef = ref
        lastAuthScheme = authScheme
        lastNewUserText = newUserText
        lastImageDataURIs = newUserImageDataURIs
        lastTextFileBlocks = newUserTextFileBlocks
        lastServerFileRefs = newUserServerFileRefs
        lastTextFileServerRefs = newUserTextFileServerRefs
        lastImageFileRefs = newUserImageFileRefs
        lastFileTransferLaneID = fileTransferSnapshot?.durableLaneID
        lastConversationID = conversationID
        lastShareEnvelopeID = shareEnvelopeID
        let err = error
        let rep = reply
        lock.unlock()
        if let err { throw err }
        return rep
    }

    func hasLiveConverseTask(shareEnvelopeID: UUID) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveConverseEnvelopeIDs.contains(shareEnvelopeID)
    }
}

/// The `(envelopeID, sequence)` identity of a single attachment upload.
private struct UploadKey: Hashable {
    let envelopeID: UUID
    let sequence: Int
}

/// Records the upload it was asked to perform + answers the live-task probe.
/// Deletes its `localURL` (mirroring the real `uploadFile` contract). NO network.
private final class MockFileUploader: ShareFileUploading, @unchecked Sendable {
    private let lock = NSLock()

    let error: Error?
    /// Uploads the live-task probe should report as in flight.
    var liveUploadKeys: Set<UploadKey> = []

    private(set) var uploadCount = 0
    private(set) var lastStoredKey: String?
    private(set) var lastSequence: Int?
    private(set) var lastShareEnvelopeID: UUID?

    init(error: Error? = nil) { self.error = error }

    func uploadFile(
        localURL: URL,
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String,
        shareEnvelopeID: UUID,
        sequence: Int
    ) async throws {
        // Honour the real contract: uploadFile deletes its input (a throwaway).
        try? FileManager.default.removeItem(at: localURL)
        lock.lock()
        uploadCount += 1
        lastStoredKey = storedKey
        lastSequence = sequence
        lastShareEnvelopeID = shareEnvelopeID
        let err = error
        lock.unlock()
        if let err { throw err }
    }

    func hasLiveUploadTask(shareEnvelopeID: UUID, sequence: Int) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveUploadKeys.contains(UploadKey(envelopeID: shareEnvelopeID, sequence: sequence))
    }
}

/// A test gate that parks the FIRST `process(...)` call inside the injected
/// router (pre-`writeState`), so the double-dispatch race window is reproduced
/// deterministically. The router calls `enterAndWait()`; the test awaits
/// `waitUntilEntered()` to know the first call is parked, runs the concurrent
/// reconcile, then `release()`s the parked call. `enterCount` lets the test
/// assert the router was entered exactly once (a second entry == re-processing).
private actor RouterGate {
    private(set) var enterCount = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var didEnter = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didRelease = false

    /// Called by the router. The FIRST entry signals `entered` then suspends until
    /// `release()`; any later entry returns immediately (so a second dispatch
    /// would still proceed and be observable via `dispatchCount` / `enterCount`).
    func enterAndWait() async {
        enterCount += 1
        guard enterCount == 1 else { return }
        didEnter = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        if didRelease { return }  // release() already arrived — don't park.
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    /// Suspends until the first `enterAndWait()` has been reached.
    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    /// Resume the parked first `enterAndWait()`.
    func release() {
        didRelease = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

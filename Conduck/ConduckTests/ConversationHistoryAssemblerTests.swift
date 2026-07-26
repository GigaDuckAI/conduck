// Conduck
// ConversationHistoryAssemblerTests.swift
//
// Locks `ConversationHistoryAssembler` — the single fetch → image-byte-
// resolution → policy-lookup → `priorTurns` choke point shared by all six
// converse dispatch surfaces. Runs against the in-memory `ConversationStore`
// seam (never the App Group sqlite) with REAL persisted attachments, so the
// store→data-URI hop the per-caller code used to own is exercised end-to-end.
//
// Coverage:
//   1. THE regression: a prior user turn's persisted image bytes resolve into
//      an inline `image_url` part (what headless/CarPlay/Watch were missing)
//   2. Exclusion: the just-appended user turn is in neither the image map nor
//      the wire (no duplicated trailing turn)
//   3. Empty-bytes honesty: an image attachment with empty data (un-synced
//      CloudKit asset) floors to the honest unavailable note, never bare text
//   4. Agent-output server-reference image (image MIME, empty data) is NOT
//      mapped — no degenerate `image_url` part (latent-bug lock)
//   5. Image-history policy: a stored `.all` forces every image turn inline
//      beyond the window; the default (`.recent`, nil ref) demotes the oldest
//      keyed turn to a disk reference; a LEGACY keep-images-inline bool with
//      no new key lazily resolves to `.all` (migration lock)
//   6. Throwing: a store that cannot load rethrows out of `assemble`
//
// The image-history policy lives in App-Group UserDefaults (NOT Keychain),
// so the policy tests run unsigned. Each uses a fresh `RemoteAgentRef.custom`
// per run — a unique defaults key that no other suite reads — and still
// resets in tearDown (App-Group defaults persist across tests).

import XCTest
@testable import Conduck

final class ConversationHistoryAssemblerTests: XCTestCase {
    private let ownedFileLaneID = String(repeating: "a", count: 64)

    /// Fresh isolated in-memory store per test (mirrors ConversationStoreTests).
    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    /// Set when a test writes a per-ref image-history policy (or seeds the
    /// legacy keep-images-inline bool), so tearDown always cleans up (the
    /// App-Group UserDefaults outlive the test process run).
    private var imagePolicyRef: RemoteAgentRef?

    override func tearDown() async throws {
        if let ref = imagePolicyRef {
            // Reset to `.default`, then strip BOTH raw keys — the new policy
            // key just rewritten and the LEGACY bool the migration test seeds
            // directly (the manager has no writer for the retired key).
            await SettingsManager.shared.setImageHistoryPolicy(.default, for: ref)
            let suite = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
            suite.removeObject(forKey: Constants.imageHistoryPolicyKey(for: ref))
            suite.removeObject(forKey: Constants.fileServerKeepImagesInlineKey(for: ref))
            imagePolicyRef = nil
        }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A user-side image attachment draft. `data` is whatever the test wants
    /// `loadAttachmentData` to return — the assembler base64s it verbatim
    /// (`ImageProcessor` normalisation happens upstream of the store, not here).
    private func imageDraft(data: Data, sequence: Int = 0, storedKey: String? = nil) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "image/jpeg",
            data: data,
            thumbnailData: nil,
            width: 8,
            height: 8,
            byteSize: data.count,
            sequence: sequence
        )
        draft.storedKey = storedKey
        return draft
    }

    /// An agent-reply OUTPUT chip: image MIME, EMPTY local data, bytes live on
    /// the gateway file-server (`isServerReference == true`).
    private func serverReferenceImageDraft(storedKey: String) -> AttachmentDraft {
        var draft = AttachmentDraft(
            mimeType: "image/png",
            filename: "chart.png",
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 0,
            sequence: 0
        )
        draft.isServerReference = true
        draft.storedKey = storedKey
        return draft
    }

    private func bareText(of message: ConverseRequest.Message) -> String? {
        if case .text(let string) = message.content { return string }
        return nil
    }

    private func imageURLs(of message: ConverseRequest.Message) -> [String] {
        guard case .parts(let parts) = message.content else { return [] }
        return parts.compactMap { part in
            if case .imageURL(let url) = part { return url }
            return nil
        }
    }

    /// Seed `count` user image turns (each with real bytes + a persisted
    /// storedKey, the dual-image shape the window policy can demote). Small
    /// sleeps keep `createdAt` strictly ordered (fetch sorts on it). Returns
    /// the per-turn (bytes, storedKey) pairs oldest → newest.
    @discardableResult
    private func seedKeyedImageTurns(
        store: ConversationStore,
        conversationID: UUID,
        count: Int
    ) async throws -> [(bytes: Data, storedKey: String)] {
        var seeded: [(bytes: Data, storedKey: String)] = []
        for index in 0..<count {
            let bytes = Data("jpeg-turn-\(index)".utf8)
            let key = "\(conversationID.uuidString)/aaaa000\(index)__image.jpg"
            _ = try await store.appendMessage(
                role: "user",
                text: "image turn \(index)",
                conversationID: conversationID,
                sourceDevice: "phone",
                fileTransferLaneID: ownedFileLaneID,
                attachments: [imageDraft(data: bytes, storedKey: key)]
            )
            seeded.append((bytes: bytes, storedKey: key))
            try await Task.sleep(nanoseconds: 15_000_000) // 15ms — strict createdAt order
        }
        return seeded
    }

    // MARK: - 1. THE regression: prior-turn images resolve inline

    func testAssembleResolvesPriorTurnImageIntoInlineImagePart() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let bytes = Data("prior-turn-jpeg-bytes".utf8)

        _ = try await store.appendMessage(
            role: "user",
            text: "look at this",
            conversationID: convo.id,
            sourceDevice: "phone",
            attachments: [imageDraft(data: bytes)]
        )
        try await Task.sleep(nanoseconds: 15_000_000)
        _ = try await store.appendMessage(
            role: "agent",
            text: "nice photo",
            conversationID: convo.id,
            sourceDevice: "phone"
        )

        let turns = try await ConversationHistoryAssembler.assemble(
            conversationID: convo.id,
            excludingUserMessageID: nil,
            excludingNewUserText: nil,
            boundRef: nil,
            store: store
        )

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].role, "user")
        guard case .parts(let parts) = turns[0].content else {
            return XCTFail("the prior image turn must ride as .parts — image-blind bare text is the bug the assembler fixes")
        }
        XCTAssertTrue(parts.contains(.text("look at this")), "the turn's text rides as the leading text part")
        XCTAssertTrue(parts.contains(.imageURL(DataURIBuilder.jpegDataURI(from: bytes))),
                      "the persisted image bytes must resolve into the exact data-URI image_url part")
        XCTAssertEqual(turns[1].role, "assistant", "agent maps to the OAI assistant role")
        XCTAssertEqual(bareText(of: turns[1]), "nice photo")
    }

    // MARK: - 2. Exclusion of the just-appended user turn

    func testAssembleExcludesTheJustAppendedUserTurnFromMapAndWire() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        _ = try await store.appendMessage(
            role: "user", text: "earlier question",
            conversationID: convo.id, sourceDevice: "phone"
        )
        try await Task.sleep(nanoseconds: 15_000_000)
        _ = try await store.appendMessage(
            role: "agent", text: "earlier answer",
            conversationID: convo.id, sourceDevice: "phone"
        )
        try await Task.sleep(nanoseconds: 15_000_000)
        // The NEW user turn — image-bearing, appended-before-build (store is
        // authoritative), must be excluded from both the map and the wire.
        let newTurn = try await store.appendMessage(
            role: "user", text: "what is in this picture",
            conversationID: convo.id, sourceDevice: "phone",
            attachments: [imageDraft(data: Data("new-turn-jpeg".utf8))]
        )

        let turns = try await ConversationHistoryAssembler.assemble(
            conversationID: convo.id,
            excludingUserMessageID: newTurn.id,
            excludingNewUserText: "what is in this picture",
            boundRef: nil,
            store: store
        )

        XCTAssertEqual(turns.count, 2, "the just-appended user turn must not ride as a duplicated trailing turn")
        XCTAssertEqual(turns.map(\.role), ["user", "assistant"])
        for turn in turns {
            XCTAssertTrue(imageURLs(of: turn).isEmpty,
                          "no prior turn carries images — the new turn's image must not leak into the map")
            XCTAssertNotEqual(bareText(of: turn), "what is in this picture")
        }
    }

    // MARK: - 3. Empty-bytes honesty (un-synced CloudKit asset)

    func testAssembleEmptyImageBytesFloorToHonestUnavailableNote() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // An image attachment whose stored data is EMPTY — the shape of a
        // CloudKit asset that hasn't synced its bytes yet. No storedKey →
        // nothing to reference on disk either.
        _ = try await store.appendMessage(
            role: "user", text: "what's in this photo",
            conversationID: convo.id, sourceDevice: "phone",
            attachments: [imageDraft(data: Data())]
        )

        let turns = try await ConversationHistoryAssembler.assemble(
            conversationID: convo.id,
            excludingUserMessageID: nil,
            excludingNewUserText: nil,
            boundRef: nil,
            store: store
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(imageURLs(of: turns[0]).isEmpty,
                      "empty bytes must never mint a degenerate image_url part")
        let content = try XCTUnwrap(bareText(of: turns[0]),
                                    "the floored turn rides as .text")
        XCTAssertNotEqual(content, "what's in this photo",
                          "an image turn must never silently flatten to bare text")
        XCTAssertTrue(content.contains("are not included in this request"),
                      "the honest unavailable note must be spliced")
    }

    // MARK: - 4. Agent-output server-reference image is never mapped

    func testAssembleAgentServerReferenceImageMintsNoImagePart() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // Agent reply carrying an OUTPUT image chip: image MIME, empty data,
        // isServerReference == true. Previously this polluted the map (empty
        // image_url part + a consumed inline-window slot) — the latent bug the
        // `!isServerReference` predicate locks out.
        _ = try await store.appendMessage(
            role: "agent", text: "here is the chart I generated",
            conversationID: convo.id, sourceDevice: "phone",
            attachments: [serverReferenceImageDraft(storedKey: "\(convo.id.uuidString)/out12345__chart.png")]
        )

        let turns = try await ConversationHistoryAssembler.assemble(
            conversationID: convo.id,
            excludingUserMessageID: nil,
            excludingNewUserText: nil,
            boundRef: nil,
            store: store
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(imageURLs(of: turns[0]).isEmpty,
                      "an agent-output server reference must not mint an image_url part")
        let content = try XCTUnwrap(bareText(of: turns[0]),
                                    "the turn rides as .text (its server-file ref line is a text splice)")
        XCTAssertTrue(content.contains("here is the chart I generated"))
        XCTAssertFalse(content.contains("are not included in this request"),
                       "a server-reference image is not a user-side image — the honesty floor must not fire")
    }

    /// WS-2 regression: once preview enrichment runs, an agent-output
    /// server-reference IMAGE chip carries a synced `thumbnailData` — but its
    /// authoritative `data` stays empty (the bytes live on the file-server).
    /// The data-URI replay path resolves bytes via `loadAttachmentData` (which
    /// reads `data`, never the thumbnail) and the assembler gates on
    /// `!isServerReference`, so a thumbnail-bearing server ref must STILL mint
    /// zero image parts — the thumbnail is never smuggled onto the wire.
    func testAssembleServerReferenceImageWithThumbnailMintsNoImagePart() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // Post-enrichment shape: image MIME, EMPTY authoritative data, a synced
        // thumbnail, isServerReference == true.
        var enriched = AttachmentDraft(
            mimeType: "image/png",
            filename: "chart.png",
            data: Data(),
            thumbnailData: Data("fake-thumbnail-jpeg-bytes".utf8),
            width: 0, height: 0, byteSize: 0, sequence: 0
        )
        enriched.isServerReference = true
        enriched.storedKey = "\(convo.id.uuidString)/out99999__chart.png"
        _ = try await store.appendMessage(
            role: "agent", text: "here is the chart I generated",
            conversationID: convo.id, sourceDevice: "phone",
            attachments: [enriched]
        )

        let turns = try await ConversationHistoryAssembler.assemble(
            conversationID: convo.id,
            excludingUserMessageID: nil,
            excludingNewUserText: nil,
            boundRef: nil,
            store: store
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(imageURLs(of: turns[0]).isEmpty,
                      "a server-reference image's synced thumbnail must never ride as an image_url part")
        let content = try XCTUnwrap(bareText(of: turns[0]))
        XCTAssertTrue(content.contains("here is the chart I generated"))
        XCTAssertFalse(content.contains("are not included in this request"),
                       "a server-reference image is not a user-side image — the honesty floor must not fire")
    }

    // MARK: - 5. Image-history policy (escape hatch / window / lazy migration)

    func testAssembleEscapeHatchKeepsAllPriorImagesInline() async throws {
        XCTAssertEqual(Constants.imageInlineWindow, 3, "this test assumes the window is 3")
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        // A fresh custom ref isolates the App-Group defaults key from every
        // other suite (a crashed run leaves only an orphan key nothing reads).
        let ref = RemoteAgentRef.custom(UUID())
        imagePolicyRef = ref
        await SettingsManager.shared.setImageHistoryPolicy(.all, for: ref)

        let seeded = try await seedKeyedImageTurns(store: store, conversationID: convo.id, count: 4)

        let turns = try await ConversationHistoryAssembler.assemble(
            conversationID: convo.id,
            excludingUserMessageID: nil,
            excludingNewUserText: nil,
            boundRef: ref,
            dispatchFileLaneID: ownedFileLaneID,
            store: store
        )

        XCTAssertEqual(turns.count, 4)
        for (index, turn) in turns.enumerated() {
            XCTAssertEqual(imageURLs(of: turn), [DataURIBuilder.jpegDataURI(from: seeded[index].bytes)],
                           "with policy .all stored, EVERY image turn stays inline (turn \(index))")
        }
    }

    func testAssembleWindowPolicyDemotesOldestKeyedImageTurnWithoutFlag() async throws {
        XCTAssertEqual(Constants.imageInlineWindow, 3, "this test assumes the window is 3")
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        // 4 keyed image turns, no stored policy (nil ref → the default
        // `.recent` window): the OLDEST aged-out turn has a storedKey, so it
        // demotes to the imperative on-disk reference; the newest 3 stay inline.
        let seeded = try await seedKeyedImageTurns(store: store, conversationID: convo.id, count: 4)

        let turns = try await ConversationHistoryAssembler.assemble(
            conversationID: convo.id,
            excludingUserMessageID: nil,
            excludingNewUserText: nil,
            boundRef: nil,
            dispatchFileLaneID: ownedFileLaneID,
            store: store
        )

        XCTAssertEqual(turns.count, 4)
        let demoted = try XCTUnwrap(bareText(of: turns[0]),
                                    "the aged-out keyed turn must demote to a .text disk reference")
        XCTAssertTrue(demoted.contains("no longer attached inline"),
                      "the demoted turn carries the imperative aged-image wording")
        XCTAssertTrue(demoted.contains(seeded[0].storedKey),
                      "the disk reference names the persisted storedKey path")
        for index in 1...3 {
            XCTAssertEqual(imageURLs(of: turns[index]), [DataURIBuilder.jpegDataURI(from: seeded[index].bytes)],
                           "the newest \(Constants.imageInlineWindow) image turns stay inline (turn \(index))")
        }
    }

    /// LAZY MIGRATION lock: a device upgraded from the bool era has the LEGACY
    /// per-ref "keep all prior images inline" key set `true` and NO new policy
    /// key. `getImageHistoryPolicy` must resolve `.all` (the bool's exact
    /// semantics), so EVERY keyed image turn stays inline beyond the window —
    /// the old escape hatch keeps working without any write-through. The bool
    /// is seeded RAW into the App-Group defaults (the manager has no writer
    /// for the retired key).
    func testAssembleLegacyKeepInlineBoolMigratesToAllPolicy() async throws {
        XCTAssertEqual(Constants.imageInlineWindow, 3, "this test assumes the window is 3")
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let ref = RemoteAgentRef.custom(UUID())
        imagePolicyRef = ref
        // Seed ONLY the legacy bool — the new key stays absent (the migration
        // path under test). Same suite-resolution fallback the manager uses.
        let suite = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
        suite.set(true, forKey: Constants.fileServerKeepImagesInlineKey(for: ref))

        let seeded = try await seedKeyedImageTurns(store: store, conversationID: convo.id, count: 4)

        let turns = try await ConversationHistoryAssembler.assemble(
            conversationID: convo.id,
            excludingUserMessageID: nil,
            excludingNewUserText: nil,
            boundRef: ref,
            dispatchFileLaneID: ownedFileLaneID,
            store: store
        )

        XCTAssertEqual(turns.count, 4)
        for (index, turn) in turns.enumerated() {
            XCTAssertEqual(imageURLs(of: turn), [DataURIBuilder.jpegDataURI(from: seeded[index].bytes)],
                           "legacy bool true + no new key must resolve .all — every image turn inline (turn \(index))")
        }
    }

    /// PRECEDENCE lock for the lazy migration: when BOTH the legacy
    /// keep-images-inline bool (`true`) AND an explicit new policy key exist,
    /// the NEW key must win. `setImageHistoryPolicy` always writes (even
    /// `.default`) precisely so a user's explicit picker choice permanently
    /// shadows a stale legacy `true` — a regression that consulted the legacy
    /// bool FIRST would resurrect `.all` and still pass every other test in
    /// this suite (legacy-only → `.all`, new-key-only → `.all`).
    func testExplicitPolicyShadowsLegacyKeepInlineBool() async {
        let ref = RemoteAgentRef.custom(UUID())
        imagePolicyRef = ref
        let suite = UserDefaults(suiteName: Constants.appGroupID) ?? .standard
        suite.set(true, forKey: Constants.fileServerKeepImagesInlineKey(for: ref))
        await SettingsManager.shared.setImageHistoryPolicy(.recent, for: ref)

        let resolved = await SettingsManager.shared.getImageHistoryPolicy(for: ref)
        XCTAssertEqual(resolved, .recent,
                       "an explicit policy choice must shadow the legacy keep-images-inline bool")
    }

    // MARK: - 6. Throwing posture

    func testAssembleThrowsWhenTheStoreCannotLoad() async {
        // A store URL whose parent directory does not exist —
        // `loadPersistentStores` fails, `ensureLoaded()` rethrows, and
        // `assemble` propagates (callers that surface store errors keep doing
        // so; non-throwing callers wrap in `try?`).
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/sub/store.sqlite")
        let store = ConversationStore(storeURL: bogus)

        do {
            _ = try await ConversationHistoryAssembler.assemble(
                conversationID: UUID(),
                excludingUserMessageID: nil,
                excludingNewUserText: nil,
                boundRef: nil,
                store: store
            )
            XCTFail("assemble must rethrow the store's load failure, not swallow it")
        } catch {
            // Any thrown error is the contract — the assembler propagates,
            // it does not error-map.
        }
    }
}

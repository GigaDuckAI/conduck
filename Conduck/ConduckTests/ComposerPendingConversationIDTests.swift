// SPDX-License-Identifier: Apache-2.0

// Conduck
// ComposerPendingConversationIDTests.swift
//
// Locks the composer's pre-minted conversation identifier — the thing that puts
// the FIRST attachment of a brand-new chat in that chat's folder instead of flat
// at the served root. Attachments are staged, and their file-server keys minted,
// before any conversation row exists, so the composer commits to an identifier
// up front and the host creates the row under it
// (`ConversationStore.createConversation(id:backend:)`).
//
// Pins, against source in `Views/Conversation/StagedAttachment.swift` +
// `Views/Conversation/ComposerAttachmentCoordinator.swift`:
//
//   - `ComposerMintFolder` resolves a folder for a VM-less composer. A helper
//     that returns nil there is a no-op patch: the optional chain
//     `vm?.conversationID.uuidString` already yielded nil, so the flat key came
//     out either way.
//   - the identifier ROTATES on every event that ends a new-chat session. One
//     that survives a handoff files the NEXT chat's first attachment into the
//     PREVIOUS conversation's folder.
//   - the identifier rides `ComposerTurnDispatch.pendingConversationID`, a field
//     of its own. `conversationID` stays nil for a new chat because it is the
//     ownership sentinel `ComposerDispatchOwnership` / `ComposerMintOwnership`
//     branch on; a UUID there makes every new-chat send a rejected dispatch.
//   - `ComposerImageName` numbers an unnamed image around the names on screen,
//     so removing a tile cannot leave two tiles claiming the same file, and the
//     extension sniffed from the image bytes reaches ONLY that numbered
//     fallback — a name the user supplied is passed through as given.

#if os(iOS) || os(macOS)

import XCTest
@testable import Conduck

final class ComposerPendingConversationIDTests: XCTestCase {

    // MARK: - The mint folder (the actual B1 fix)

    func testVMLessComposerStillNamesAConversationFolder() {
        let pending = UUID()
        XCTAssertEqual(
            ComposerMintFolder.storedKeyFolder(bound: nil, pending: pending, folderCapable: true),
            pending.uuidString,
            "a composer with no view model must still name a folder — resolving to nil here is exactly the flat-root bug"
        )
    }

    func testFirstAttachmentOfANewChatIsMintedInsideThatChatsFolder() {
        let pending = UUID()
        let key = FileServerClient.makeStoredKey(
            originalName: "quarterly-report.pdf",
            uuid: UUID(),
            folder: ComposerMintFolder.storedKeyFolder(
                bound: nil,
                pending: pending,
                folderCapable: true
            )
        )
        XCTAssertTrue(
            key.hasPrefix("\(pending.uuidString)/"),
            "the key the composer uploads under must sit in the folder the row it creates will own"
        )
        XCTAssertTrue(key.hasSuffix("__quarterly-report.pdf"))
    }

    func testBoundConversationOutranksThePreMintedIdentifier() {
        let bound = UUID()
        let pending = UUID()
        XCTAssertEqual(
            ComposerMintFolder.conversationID(bound: bound, pending: pending),
            bound,
            "an established conversation owns its own folder; the pre-minted identifier is only for the chat that does not exist yet"
        )
        XCTAssertEqual(
            ComposerMintFolder.storedKeyFolder(bound: bound, pending: pending, folderCapable: true),
            bound.uuidString
        )
    }

    func testFolderIncapableGatewayStillMintsFlat() {
        XCTAssertNil(
            ComposerMintFolder.storedKeyFolder(bound: UUID(), pending: UUID(), folderCapable: false),
            "a gateway whose nested-PUT probe failed gets a flat key — the one case where no folder is correct"
        )
    }

    func testEveryMintPathOfOneTurnResolvesTheSameFolder() {
        let pending = UUID()
        // The five mint paths differ only in what they are naming: two composer
        // `mintStoredKey` calls, two `TextAttachmentStagePreparer` call sites,
        // and the late mints (needs-setup promotion, upload-retry fallback).
        // They must agree, or one turn's files split across two folders.
        let viaStoredKey = ComposerMintFolder.storedKeyFolder(
            bound: nil,
            pending: pending,
            folderCapable: true
        )
        let viaPreparer = ComposerMintFolder.conversationID(bound: nil, pending: pending)
        XCTAssertEqual(viaStoredKey, viaPreparer.uuidString)
    }

    // MARK: - The dispatch field

    func testNewChatDispatchKeepsItsOwnershipSentinelNil() throws {
        let pending = UUID()
        let dispatch = try XCTUnwrap(
            [StagedAttachment]().makeDispatch(
                text: "first turn",
                ref: .builtin(.openclaw),
                conversationID: nil,
                pendingConversationID: pending,
                stagingGeneration: UUID()
            )
        )
        XCTAssertNil(
            dispatch.conversationID,
            "nil-means-new-chat is what the host's ownership guards branch on; a UUID here rejects the send and deletes the fresh row"
        )
        XCTAssertEqual(dispatch.pendingConversationID, pending)
        XCTAssertTrue(
            ComposerDispatchOwnership.matches(
                sealedConversationID: dispatch.conversationID,
                activeConversationID: nil
            ),
            "a new-chat send must still pass the ownership guard while the host is new-chat"
        )
        XCTAssertEqual(
            ComposerMintOwnership.resolve(
                sealedConversationID: dispatch.conversationID,
                activeConversationIDAfterMint: nil
            ),
            .adoptFreshConversation,
            "the host must still adopt the row it mints under the pre-minted identifier"
        )
    }

    func testRoutePairedDispatchCarriesThePreMintedIdentifierToo() throws {
        let pending = UUID()
        let dispatch = try XCTUnwrap(
            [StagedAttachment]().makeDispatch(
                text: "keyboard send",
                route: ComposerDispatchRoute(ref: .builtin(.hermes), conversationID: nil),
                pendingConversationID: pending,
                stagingGeneration: UUID()
            )
        )
        XCTAssertNil(dispatch.conversationID)
        XCTAssertEqual(dispatch.pendingConversationID, pending)
    }

    // MARK: - Unnamed-image naming

    /// THE SNIFFED EXTENSION REACHES ONLY THE NUMBERED FALLBACK, and this case
    /// holds both halves of that rule because it is the claim three headers make
    /// about this one helper: `stageImage` in `MessageComposerBar` (macOS) and in
    /// `ComposerAttachmentCoordinator` (iOS), plus `.dualImage` in
    /// `StagedAttachment`. A header saying the extension is always sniffed from
    /// the bytes describes a rewrite these assertions forbid.
    func testAPickedImageKeepsTheNameTheUserGaveIt() {
        // The sniffed `jpg` disagrees with the user's `.heic`. The user's name
        // wins whole, extension included — nothing is appended or replaced.
        XCTAssertEqual(
            ComposerImageName.resolve(originalName: "roof-crack.heic", extension: "jpg", staged: []),
            "roof-crack.heic",
            "the user's own name survives untouched, exactly as it does for a document"
        )
        // Same sniff, no name of its own: the fallback is the ONLY place the
        // sniffed extension lands.
        XCTAssertEqual(
            ComposerImageName.resolve(originalName: nil, extension: "jpg", staged: []),
            "image.jpg",
            "a source that genuinely has no name gets the real format from the bytes"
        )
    }

    func testAnUnnamedSourceFallsBackToANumberedImageName() {
        XCTAssertEqual(
            ComposerImageName.resolve(originalName: nil, extension: "heic", staged: []),
            "image.heic"
        )
        XCTAssertEqual(
            ComposerImageName.resolve(originalName: "   ", extension: "png", staged: []),
            "image.png",
            "a blank name is no name"
        )
    }

    func testRemovingATileNeverLeavesTwoTilesWithTheSameName() {
        // "image.heic" was removed; "image-2.heic" is still on screen. Numbering
        // from a COUNT of the staged tiles would hand out "image-2.heic" a second
        // time and leave two tiles claiming to be the same file.
        let survivor = StagedAttachment(
            kind: .dualImage(
                processedJPEG: Data([0x01]),
                thumbnail: Data([0x02]),
                width: 4,
                height: 4,
                byteSize: 1,
                filename: "image-2.heic"
            )
        )
        XCTAssertEqual(
            ComposerImageName.resolve(originalName: nil, extension: "heic", staged: [survivor]),
            "image.heic",
            "the freed name is reused before a new number is issued"
        )
        XCTAssertEqual(
            ComposerImageName.unnamed(extension: "heic", avoiding: ["image.heic", "image-2.heic"]),
            "image-3.heic"
        )
    }

    func testAnUnnamedImageIsAlsoNumberedAroundDocumentsOnTheStrip() {
        let document = StagedAttachment(
            kind: .serverFile(
                url: URL(fileURLWithPath: "/tmp/image.png"),
                originalName: "image.png",
                mimeType: "image/png"
            )
        )
        XCTAssertEqual(
            ComposerImageName.resolve(originalName: nil, extension: "png", staged: [document]),
            "image-2.png",
            "a document the user picked can already occupy the name, and two tiles must not share one"
        )
    }

    // MARK: - Rotation (iOS coordinator)

    // `ComposerAttachmentCoordinator` is `#if os(iOS)`, so the cases that
    // instantiate one must be too, or the whole target fails to compile for the
    // macOS destination. The macOS composer holds the same identifier as `@State`
    // on a `View`, which no unit seam can reach; its rotations sit in
    // `clearDiscardedAttachments()` / `clearAfterSuccessfulHandoff(_:)`.
    #if os(iOS)

    private func lane(folderCapable: Bool = true) -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: "https://files.example.test/dav/")!,
            username: "conduck",
            credential: "lane-a",
            certFingerprintHex: nil,
            available: true,
            folderCapable: folderCapable
        )
    }

    @MainActor
    func testTheComposerMintsAVMLessKeyInsideThePreMintedFolder() {
        let coordinator = ComposerAttachmentCoordinator()
        let key = coordinator.mintStoredKey(
            originalName: "quarterly-report.pdf",
            vm: nil,
            snapshot: lane()
        )
        XCTAssertTrue(
            key.hasPrefix("\(coordinator.pendingConversationID.uuidString)/"),
            "the very first attachment of a new chat must be uploaded inside that chat's folder, not flat at the served root"
        )
    }

    @MainActor
    func testAFolderIncapableLaneStillMintsFlatFromTheComposer() {
        let coordinator = ComposerAttachmentCoordinator()
        let key = coordinator.mintStoredKey(
            originalName: "quarterly-report.pdf",
            vm: nil,
            snapshot: lane(folderCapable: false)
        )
        XCTAssertFalse(
            key.contains("/"),
            "a gateway that rejected nested PUTs still gets a flat key"
        )
    }

    @MainActor
    func testEveryStagedFileOfOneVMLessTurnSharesOneFolder() {
        // Stage-time mint, the needs-setup promotion and the upload-retry
        // fallback all run through the same method, so they cannot disagree —
        // this is the property that keeps one turn's files together.
        let coordinator = ComposerAttachmentCoordinator()
        let snapshot = lane()
        let keys = ["a.pdf", "b.pdf", "c.pdf"].map {
            coordinator.mintStoredKey(originalName: $0, vm: nil, snapshot: snapshot)
        }
        let folders = Set(keys.map { $0.split(separator: "/").first.map(String.init) ?? "" })
        XCTAssertEqual(folders, [coordinator.pendingConversationID.uuidString])
    }

    @MainActor
    func testTheDispatchCarriesTheCoordinatorsOwnPreMintedIdentifier() throws {
        let coordinator = ComposerAttachmentCoordinator()
        let pending = coordinator.pendingConversationID
        XCTAssertTrue(coordinator.beginAttachmentDispatch())
        let dispatch = try XCTUnwrap(
            coordinator.makeDispatch(
                text: "first turn",
                ref: .builtin(.openclaw),
                conversationID: nil
            )
        )
        XCTAssertEqual(
            dispatch.pendingConversationID,
            pending,
            "the host creates the row under exactly the identifier the composer minted its keys against"
        )
    }

    @MainActor
    func testHandoffRotatesSoTheNextNewChatGetsItsOwnFolder() throws {
        let coordinator = ComposerAttachmentCoordinator()
        let first = coordinator.pendingConversationID
        XCTAssertTrue(coordinator.beginAttachmentDispatch())
        let dispatch = try XCTUnwrap(
            coordinator.makeDispatch(
                text: "first turn",
                ref: .builtin(.openclaw),
                conversationID: nil
            )
        )
        coordinator.clearAfterSuccessfulHandoff(dispatch)
        coordinator.endAttachmentDispatch()

        XCTAssertNotEqual(
            coordinator.pendingConversationID,
            first,
            "the handed-off identifier now names a real conversation; keeping it files the next chat's first attachment into that one"
        )
    }

    @MainActor
    func testDiscardingStagingRotates() {
        let coordinator = ComposerAttachmentCoordinator()
        let before = coordinator.pendingConversationID
        coordinator.staged = [StagedAttachment(kind: .image(Data([0x01])))]
        coordinator.clearDiscarded()
        XCTAssertNotEqual(coordinator.pendingConversationID, before)
    }

    @MainActor
    func testNavigationTeardownRotates() {
        let coordinator = ComposerAttachmentCoordinator()
        let before = coordinator.pendingConversationID
        coordinator.discardForNavigation(from: UUID(), to: nil)
        XCTAssertNotEqual(
            coordinator.pendingConversationID,
            before,
            "leaving a conversation ends the composer session that identifier belonged to"
        )
    }

    @MainActor
    func testDeferredNavigationTeardownRotatesWhenItFinallyRuns() {
        let coordinator = ComposerAttachmentCoordinator()
        let before = coordinator.pendingConversationID
        coordinator.staged = [StagedAttachment(kind: .image(Data([0x01])))]
        XCTAssertTrue(coordinator.beginAttachmentDispatch())

        coordinator.discardForNavigation(from: UUID(), to: UUID())
        XCTAssertEqual(
            coordinator.pendingConversationID,
            before,
            "teardown is deferred during dispatch, so nothing may rotate yet"
        )
        coordinator.endAttachmentDispatch()
        XCTAssertNotEqual(coordinator.pendingConversationID, before)
    }

    @MainActor
    func testStartingANewChatRotatesOnlyWhileNothingIsStaged() {
        let idle = ComposerAttachmentCoordinator()
        let idleBefore = idle.pendingConversationID
        idle.beginNewChatSession()
        XCTAssertNotEqual(idle.pendingConversationID, idleBefore)

        let staging = ComposerAttachmentCoordinator()
        staging.staged = [StagedAttachment(kind: .image(Data([0x01])))]
        let stagingBefore = staging.pendingConversationID
        staging.beginNewChatSession()
        XCTAssertEqual(
            staging.pendingConversationID,
            stagingBefore,
            "files are already uploaded under this identifier; rotating would split the turn across two folders"
        )
    }

    @MainActor
    func testRemovingTheOnlyTileDoesNotRotate() {
        let coordinator = ComposerAttachmentCoordinator()
        let tile = StagedAttachment(kind: .image(Data([0x01])))
        coordinator.staged = [tile]
        let before = coordinator.pendingConversationID
        coordinator.remove(tile.id)
        XCTAssertEqual(
            coordinator.pendingConversationID,
            before,
            "the composer session is still the same new chat; the user simply changed their mind about one file"
        )
    }

    #endif
}

#endif

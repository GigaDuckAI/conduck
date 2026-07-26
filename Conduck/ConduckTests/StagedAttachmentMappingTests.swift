// Conduck
// StagedAttachmentMappingTests.swift
//
// Locks the `StagedAttachment.pendingAttachment` mapping + send-gating contract
// for the kinds the sibling `StagedAttachmentTests` does NOT exercise (it only
// covers `.dualText` + `.needsSetup`). Pins, against source in
// `Views/Conversation/StagedAttachment.swift`:
//
//   - `.serverFile`: rides the wire ONLY once its eager upload has LANDED
//     (`serverUploadState == .uploaded(key)`) — carrying that exact storedKey;
//     an `.uploading` / `.failed` / nil-state server tile → `pendingAttachment`
//     nil AND gates Send (`hasUploadingItem` / `hasFailedUpload`), so it can
//     never be silently dropped from a dispatched turn.
//   - `.image` (inline-only) → `.image(data)` carrying the exact bytes.
//   - `.dualImage` → ALWAYS produces `.dualImage(...)` (inline base64 is the
//     guaranteed fallback); the storedKey rides ONLY on `.uploaded(key)`, and
//     the upload NEVER gates Send (excluded from the blocking helpers).
//   - `.file` (inline-only text/code) → `.textFile(url)`.
//   - `.loading` / `.failed` → `pendingAttachment` nil; `.loading` gates Send
//     via `hasLoadingItem`.
//
// `PendingAttachment` is Sendable (NOT Equatable), so each case is destructured
// and its payload asserted field-by-field. `StagedAttachment` is platform-
// agnostic but `PendingAttachment` lives in the iOS/macOS VM, so this suite runs
// on the iOS-sim test destination (mirrors `StagedAttachmentTests`).

#if os(iOS) || os(macOS)

import XCTest
@testable import Conduck

final class StagedAttachmentMappingTests: XCTestCase {

    private func lane(
        url: String = "https://files.example.test/dav/",
        credential: String = "lane-a",
        available: Bool = true
    ) -> SettingsManager.FileTransferSnapshot {
        SettingsManager.FileTransferSnapshot(
            baseURL: URL(string: url)!,
            username: "conduck",
            credential: credential,
            certFingerprintHex: nil,
            available: available,
            folderCapable: true
        )
    }

    // MARK: - .serverFile (file-transfer route; rides only once uploaded)

    private func serverFile(state: StagedAttachment.ServerFileUploadState?) -> StagedAttachment {
        StagedAttachment(
            kind: .serverFile(
                url: URL(fileURLWithPath: "/tmp/report.pdf"),
                originalName: "report.pdf",
                mimeType: "application/pdf"
            ),
            serverUploadState: state
        )
    }

    func testServerFile_pendingCarriesServerReferenceWhenUploaded() throws {
        let item = serverFile(state: .uploaded(storedKey: "conv/ab12cd34__report.pdf"))
        let pending = try XCTUnwrap(item.pendingAttachment,
                                    "a landed server-file upload (.uploaded) rides the wire")
        guard case let .serverFile(url, originalName, mimeType, storedKey) = pending else {
            return XCTFail("expected .serverFile pending")
        }
        XCTAssertEqual(url, URL(fileURLWithPath: "/tmp/report.pdf"))
        XCTAssertEqual(originalName, "report.pdf")
        XCTAssertEqual(mimeType, "application/pdf")
        XCTAssertEqual(storedKey, "conv/ab12cd34__report.pdf",
                       "the resolved storedKey is carried verbatim onto the wire")
    }

    func testServerFile_noPendingWhileUploading() {
        let item = serverFile(state: .uploading(progress: 0.5))
        XCTAssertNil(item.pendingAttachment,
                     "an in-flight server-file has no inline fallback — it must NOT ride the wire")
    }

    func testServerFile_noPendingWhenFailed() {
        let item = serverFile(state: .failed)
        XCTAssertNil(item.pendingAttachment,
                     "a failed server-file upload never rides the wire (strip shows Retry)")
    }

    func testServerFile_noPendingWhenNilState() {
        let item = serverFile(state: nil)
        XCTAssertNil(item.pendingAttachment,
                     "a server-file with no upload state has nothing to reference — nil")
    }

    func testServerFile_gatesSend_whileUploadingAndFailed() {
        // Unlike a dual tile, a `.serverFile` has NO inline fallback, so its
        // in-flight / failed upload MUST gate Send (else it would be silently
        // dropped from a dispatched turn).
        XCTAssertTrue([serverFile(state: .uploading(progress: 0.2))].hasUploadingItem,
                      "an in-flight server-file gates Send")
        XCTAssertTrue([serverFile(state: .failed)].hasFailedUpload,
                      "a failed server-file gates Send")
        XCTAssertTrue([serverFile(state: .uploading(progress: 0.2))].pendingAttachments.isEmpty,
                      "the sendable subset drops a still-uploading server-file")
    }

    func testServerFile_uploadedDoesNotGateSend() {
        let strip: [StagedAttachment] = [serverFile(state: .uploaded(storedKey: "abc12345__report.pdf"))]
        XCTAssertFalse(strip.hasUploadingItem)
        XCTAssertFalse(strip.hasFailedUpload)
        XCTAssertEqual(strip.pendingAttachments.count, 1,
                       "a landed server-file is part of the sendable subset")
    }

    func testServerFile_isServerFileFlag() {
        XCTAssertTrue(serverFile(state: nil).isServerFile)
        XCTAssertFalse(serverFile(state: nil).isDualImage)
        XCTAssertFalse(serverFile(state: nil).isDualText)
    }

    // MARK: - .image (inline-only image route)

    func testImage_pendingCarriesOriginalBytes() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let item = StagedAttachment(kind: .image(bytes))
        let pending = try XCTUnwrap(item.pendingAttachment)
        guard case let .image(data) = pending else {
            return XCTFail("expected .image pending")
        }
        XCTAssertEqual(data, bytes, "the inline-only image rides its original picked bytes verbatim")
    }

    func testImage_neverGatesSendAndIsSendable() {
        let item = StagedAttachment(kind: .image(Data([0x01])))
        XCTAssertFalse([item].hasLoadingItem)
        XCTAssertFalse([item].hasUploadingItem)
        XCTAssertFalse([item].hasFailedUpload)
        XCTAssertEqual([item].pendingAttachments.count, 1)
    }

    // MARK: - .dualImage (inline vision + eager file-server upload; never gates)

    private func dualImage(state: StagedAttachment.ServerFileUploadState?) -> StagedAttachment {
        StagedAttachment(
            kind: .dualImage(
                original: Data([0xAA, 0xBB]),
                processedJPEG: Data([0x01, 0x02, 0x03]),
                thumbnail: Data([0x09]),
                width: 1024,
                height: 768,
                byteSize: 4242,
                filename: "image.heic"
            ),
            serverUploadState: state
        )
    }

    func testDualImage_pendingCarriesProcessedPayloadAndStoredKeyWhenUploaded() throws {
        let item = dualImage(state: .uploaded(storedKey: "conv/ee99ff00__image.heic"))
        let pending = try XCTUnwrap(item.pendingAttachment)
        guard case let .dualImage(processedJPEG, thumbnail, width, height, byteSize, storedKey, filename) = pending else {
            return XCTFail("expected .dualImage pending")
        }
        // Vision reads the PROCESSED JPEG (not the original) — intentional asymmetry.
        XCTAssertEqual(processedJPEG, Data([0x01, 0x02, 0x03]),
                       "the inline payload is the processed JPEG, NOT the original bytes")
        XCTAssertEqual(thumbnail, Data([0x09]))
        XCTAssertEqual(width, 1024)
        XCTAssertEqual(height, 768)
        XCTAssertEqual(byteSize, 4242)
        XCTAssertEqual(filename, "image.heic",
                       "the true-format display name rides so the wire names the file by its real extension")
        XCTAssertEqual(storedKey, "conv/ee99ff00__image.heic",
                       "a landed upload carries its storedKey for the one-turn 'saved as' ref")
    }

    func testDualImage_pendingDropsStoredKeyWhileUploading() throws {
        let item = dualImage(state: .uploading(progress: 0.3))
        let pending = try XCTUnwrap(item.pendingAttachment,
                                    "a dual image ALWAYS rides the wire — inline base64 is the fallback")
        guard case let .dualImage(_, _, _, _, _, storedKey, _) = pending else {
            return XCTFail("expected .dualImage pending")
        }
        XCTAssertNil(storedKey, "an in-flight upload rides inline-only (no storedKey)")
    }

    func testDualImage_pendingDropsStoredKeyOnFailureAndNilState() throws {
        for state: StagedAttachment.ServerFileUploadState? in [.failed, nil] {
            let pending = try XCTUnwrap(dualImage(state: state).pendingAttachment,
                                        "a dual image rides inline-only even on a failed/absent upload")
            guard case let .dualImage(_, _, _, _, _, storedKey, _) = pending else {
                return XCTFail("expected .dualImage pending")
            }
            XCTAssertNil(storedKey, "failed / nil-state upload → inline-only (storedKey nil)")
        }
    }

    func testDualImage_excludedFromSendBlockers() {
        XCTAssertFalse([dualImage(state: .uploading(progress: 0.1))].hasUploadingItem,
                       "a dual image's in-flight upload must NOT gate Send")
        XCTAssertFalse([dualImage(state: .failed)].hasFailedUpload,
                       "a dual image's failed upload must NOT gate Send (rides inline-only)")
        XCTAssertTrue(dualImage(state: nil).isDualImage)
        XCTAssertFalse(dualImage(state: nil).isServerFile)
    }

    // MARK: - .file (inline-only text/code route)

    func testFile_pendingMapsToTextFileURL() throws {
        let url = URL(fileURLWithPath: "/tmp/script.py")
        let item = StagedAttachment(kind: .file(url))
        let pending = try XCTUnwrap(item.pendingAttachment)
        guard case let .textFile(mappedURL) = pending else {
            return XCTFail("expected .textFile pending")
        }
        XCTAssertEqual(mappedURL, url, "an inline-only file maps to .textFile carrying its source URL")
    }

    func testFile_neverGatesSendAndIsSendable() {
        let item = StagedAttachment(kind: .file(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse([item].hasLoadingItem)
        XCTAssertFalse([item].hasUploadingItem)
        XCTAssertFalse([item].hasFailedUpload)
        XCTAssertFalse([item].hasNeedsSetupItem)
        XCTAssertEqual([item].pendingAttachments.count, 1)
    }

    // MARK: - .loading / .failed (never ride the wire)

    func testLoading_noPendingAndGatesSend() {
        let item = StagedAttachment(kind: .loading)
        XCTAssertNil(item.pendingAttachment, "a still-loading tile has no bytes yet — nil")
        XCTAssertTrue(item.isLoading)
        XCTAssertTrue([item].hasLoadingItem, "any loading tile disables Send (no partial payloads)")
        XCTAssertTrue([item].pendingAttachments.isEmpty)
    }

    func testFailed_noPendingAndNotInSendableSubset() {
        let item = StagedAttachment(kind: .failed)
        XCTAssertNil(item.pendingAttachment, "a failed-to-load tile never reaches the wire")
        XCTAssertTrue(item.isFailed)
        // `.failed` (load failure) is distinct from `.serverFile` upload failure:
        // it carries no serverUploadState, so it trips neither upload-gating helper.
        XCTAssertFalse([item].hasUploadingItem)
        XCTAssertFalse([item].hasFailedUpload)
        XCTAssertTrue([item].pendingAttachments.isEmpty)
    }

    // MARK: - mixed strip: pendingAttachments preserves staged order, drops gated

    func testPendingAttachments_dropsGatedKeepsOrder() {
        let image = StagedAttachment(kind: .image(Data([0x11])))
        let loading = StagedAttachment(kind: .loading)
        let uploadingServer = serverFile(state: .uploading(progress: 0.5))
        let uploadedServer = serverFile(state: .uploaded(storedKey: "abc12345__report.pdf"))
        let strip = [image, loading, uploadingServer, uploadedServer]

        let resolved = strip.pendingAttachments
        XCTAssertEqual(resolved.count, 2,
                       "only the inline image + the landed server-file are sendable")
        guard case .image = resolved[0] else {
            return XCTFail("first sendable is the inline image (staged order preserved)")
        }
        guard case let .serverFile(_, _, _, storedKey) = resolved[1] else {
            return XCTFail("second sendable is the landed server-file")
        }
        XCTAssertEqual(storedKey, "abc12345__report.pdf")
    }

    // MARK: - gateway ownership (new-chat picker hardening)

    func testServerBackedTileMatchesOnlyItsCapturedGatewayOwner() {
        let openClaw: RemoteAgentRef = .builtin(.openclaw)
        let hermes: RemoteAgentRef = .builtin(.hermes)
        let item = StagedAttachment(
            kind: .serverFile(
                url: URL(fileURLWithPath: "/tmp/report.pdf"),
                originalName: "report.pdf",
                mimeType: "application/pdf"
            ),
            serverOwnerRef: openClaw,
            serverOwnerSnapshot: lane(),
            serverUploadState: .uploaded(storedKey: "abc12345__report.pdf")
        )

        XCTAssertTrue(item.serverOwnershipMatches(openClaw))
        XCTAssertFalse(item.serverOwnershipMatches(hermes),
                       "a storedKey uploaded through OpenClaw must never ride a Hermes turn")
        XCTAssertFalse([item].serverOwnershipMatches(hermes),
                       "the collection-level send guard fails closed on one mismatched tile")
    }

    func testServerBackedTileWithoutOwnerFailsClosed() {
        let ownerless = serverFile(state: .uploaded(storedKey: "abc12345__report.pdf"))
        XCTAssertFalse(ownerless.serverOwnershipMatches(.builtin(.openclaw)),
                       "legacy/buggy ownerless server staging must not be guessed onto a gateway")
    }

    func testInlineOnlyTilesAreGatewayIndependent() {
        let inline = [
            StagedAttachment(kind: .image(Data([0x01]))),
            StagedAttachment(kind: .file(URL(fileURLWithPath: "/tmp/note.txt")))
        ]
        XCTAssertTrue(inline.serverOwnershipMatches(.builtin(.openclaw)))
        XCTAssertTrue(inline.serverOwnershipMatches(.builtin(.hermes)))
    }

    func testDispatchSealsCapturedRefAndDurableLane() throws {
        let snapshot = lane()
        let conversationID = UUID()
        let stagingGeneration = UUID()
        let item = StagedAttachment(
            kind: .serverFile(
                url: URL(fileURLWithPath: "/tmp/report.pdf"),
                originalName: "report.pdf",
                mimeType: "application/pdf"
            ),
            serverOwnerRef: .builtin(.openclaw),
            serverOwnerSnapshot: snapshot,
            serverUploadState: .uploaded(storedKey: "abc12345__report.pdf")
        )

        let dispatch = try XCTUnwrap(
            [item].makeDispatch(
                text: "read it",
                ref: .builtin(.openclaw),
                conversationID: conversationID,
                stagingGeneration: stagingGeneration
            )
        )
        XCTAssertEqual(dispatch.ref, .builtin(.openclaw))
        XCTAssertEqual(dispatch.conversationID, conversationID)
        XCTAssertEqual(dispatch.stagingGeneration, stagingGeneration)
        XCTAssertEqual(dispatch.stagedAttachmentIDs, [item.id])
        XCTAssertEqual(dispatch.fileLaneID, snapshot.durableLaneID)
        XCTAssertEqual(dispatch.attachments.count, 1)
        XCTAssertEqual(dispatch.handedOffServerAttachmentIDs, [item.id])
    }

    func testDispatchFreezesWhichPreferredUploadsActuallyLanded() throws {
        let snapshot = lane()
        let conversationID = UUID()
        let stagingGeneration = UUID()
        var landed = dualImage(state: .uploaded(storedKey: "landed"))
        landed.serverOwnerRef = .builtin(.openclaw)
        landed.serverOwnerSnapshot = snapshot
        var stillUploading = dualImage(state: .uploading(progress: 0.9))
        stillUploading.serverOwnerRef = .builtin(.openclaw)
        stillUploading.serverOwnerSnapshot = snapshot

        let dispatch = try XCTUnwrap(
            [landed, stillUploading].makeDispatch(
                text: "inspect both",
                ref: .builtin(.openclaw),
                conversationID: conversationID,
                stagingGeneration: stagingGeneration
            )
        )

        XCTAssertEqual(dispatch.conversationID, conversationID)
        XCTAssertEqual(dispatch.stagingGeneration, stagingGeneration)
        XCTAssertEqual(dispatch.stagedAttachmentIDs, [landed.id, stillUploading.id])
        XCTAssertEqual(dispatch.attachments.count, 2)
        XCTAssertEqual(
            dispatch.handedOffServerAttachmentIDs,
            [landed.id],
            "a preferred upload that lands after sealing was inline-only in this dispatch and must be deleted during cleanup"
        )
    }

    func testDispatchRejectsMixedDurableLanesAndOwnerlessServerTile() {
        let conversationID = UUID()
        let stagingGeneration = UUID()
        let first = StagedAttachment(
            kind: .serverFile(
                url: URL(fileURLWithPath: "/tmp/a.pdf"),
                originalName: "a.pdf",
                mimeType: "application/pdf"
            ),
            serverOwnerRef: .builtin(.openclaw),
            serverOwnerSnapshot: lane(credential: "lane-a"),
            serverUploadState: .uploaded(storedKey: "a")
        )
        let second = StagedAttachment(
            kind: .serverFile(
                url: URL(fileURLWithPath: "/tmp/b.pdf"),
                originalName: "b.pdf",
                mimeType: "application/pdf"
            ),
            serverOwnerRef: .builtin(.openclaw),
            serverOwnerSnapshot: lane(credential: "lane-b"),
            serverUploadState: .uploaded(storedKey: "b")
        )
        XCTAssertNil(
            [first, second].makeDispatch(
                text: "",
                ref: .builtin(.openclaw),
                conversationID: conversationID,
                stagingGeneration: stagingGeneration
            )
        )

        var ownerless = first
        ownerless.serverOwnerSnapshot = nil
        XCTAssertNil(
            [ownerless].makeDispatch(
                text: "",
                ref: .builtin(.openclaw),
                conversationID: conversationID,
                stagingGeneration: stagingGeneration
            )
        )
    }

    // MARK: - sealed conversation + deferred teardown ownership

    func testButtonDispatchRejectsSameGatewayConversationSwitchAfterSeal() {
        let conversationA = UUID()
        let conversationB = UUID()

        XCTAssertFalse(
            ComposerDispatchOwnership.matches(
                sealedConversationID: conversationA,
                activeConversationID: conversationB
            ),
            "the button path must reject A→B even when both conversations use the same gateway"
        )
    }

    func testKeyboardDispatchRejectsSameGatewayConversationSwitchAfterSeal() {
        let conversationA = UUID()
        let conversationB = UUID()

        XCTAssertFalse(
            ComposerDispatchOwnership.matches(
                sealedConversationID: conversationA,
                activeConversationID: conversationB
            ),
            "the keyboard path shares the same final conversation-identity verdict"
        )
    }

    func testKeyboardRouteSnapshotKeepsConversationCapturedBeforeUploadJoin() throws {
        let conversationA = UUID()
        let conversationB = UUID()
        let capturedRoute = ComposerDispatchRoute(
            ref: .builtin(.openclaw),
            conversationID: conversationA
        )

        // Simulate the sidebar changing A → B (same gateway) while the keyboard
        // send is suspended in awaitPreferredUploads(). Dispatch construction
        // must consume the captured pair, never the now-live selection.
        let dispatch = try XCTUnwrap(
            [StagedAttachment]().makeDispatch(
                text: "sealed before upload join",
                route: capturedRoute,
                stagingGeneration: UUID()
            )
        )

        XCTAssertEqual(dispatch.ref, .builtin(.openclaw))
        XCTAssertEqual(dispatch.conversationID, conversationA)
        XCTAssertFalse(
            ComposerDispatchOwnership.matches(
                sealedConversationID: dispatch.conversationID,
                activeConversationID: conversationB
            ),
            "the host must reject the captured A route after selection moves to B"
        )
    }

    func testNilSealedConversationMatchesOnlyGenuineNewChatState() {
        XCTAssertTrue(
            ComposerDispatchOwnership.matches(
                sealedConversationID: nil,
                activeConversationID: nil
            )
        )
        XCTAssertFalse(
            ComposerDispatchOwnership.matches(
                sealedConversationID: nil,
                activeConversationID: UUID()
            ),
            "a nil seal must not become a wildcard for a user-selected existing conversation"
        )
    }

    func testMacComposerMountIdentityChangesAcrossConversationNavigation() {
        let conversationA = UUID()
        let conversationB = UUID()

        XCTAssertNotEqual(
            ComposerMountIdentity.conversation(conversationA),
            ComposerMountIdentity.conversation(conversationB),
            "A → B must remount the attachment-owning composer and run A's teardown"
        )
        XCTAssertNotEqual(
            ComposerMountIdentity.newChat,
            ComposerMountIdentity.conversation(conversationA),
            "the VM-less natural-mint composer remains a separate ownership state"
        )
    }

    @MainActor
    func testCoordinatorFreezesRemoveAndClearsOnlyExactSealedIDs() throws {
        let coordinator = ComposerAttachmentCoordinator()
        let sealed = StagedAttachment(kind: .image(Data([0x01])))
        let late = StagedAttachment(kind: .image(Data([0x02])))
        coordinator.staged = [sealed]
        XCTAssertTrue(coordinator.beginAttachmentDispatch())
        let dispatch = try XCTUnwrap(
            coordinator.makeDispatch(
                text: "send sealed",
                ref: .builtin(.openclaw),
                conversationID: UUID()
            )
        )

        // Simulate a late/programmatic stage mutation after sealing. User-facing
        // remove controls are frozen, so the remove attempt must do nothing.
        coordinator.staged.append(late)
        coordinator.remove(late.id)
        XCTAssertEqual(Set(coordinator.staged.map(\.id)), Set([sealed.id, late.id]))

        coordinator.clearAfterSuccessfulHandoff(dispatch)
        XCTAssertEqual(coordinator.staged.map(\.id), [late.id],
                       "successful cleanup consumes only ids frozen into the dispatch")
        coordinator.endAttachmentDispatch()
        XCTAssertEqual(coordinator.staged.map(\.id), [late.id],
                       "without navigation, a late/programmatic item remains for the next turn")
    }

    @MainActor
    func testNavigationBeforeRejectedAcceptanceDefersThenDiscardsAtDispatchEnd() {
        let coordinator = ComposerAttachmentCoordinator()
        let sealed = StagedAttachment(kind: .image(Data([0x01])))
        coordinator.staged = [sealed]
        XCTAssertTrue(coordinator.beginAttachmentDispatch())

        coordinator.discardForNavigation(from: UUID(), to: UUID())
        XCTAssertEqual(coordinator.staged.map(\.id), [sealed.id],
                       "navigation cannot mutate ownership before acceptance resolves")

        // Rejected handoff: no successful clear occurs.
        coordinator.endAttachmentDispatch()
        XCTAssertTrue(coordinator.staged.isEmpty,
                      "the deferred navigation discards the still-unsent sealed item")
    }

    @MainActor
    func testNilToExistingNavigationDuringDispatchDoesNotStrandAttachments() {
        let coordinator = ComposerAttachmentCoordinator()
        let sealed = StagedAttachment(kind: .image(Data([0x01])))
        coordinator.staged = [sealed]
        XCTAssertTrue(coordinator.beginAttachmentDispatch())

        coordinator.discardForNavigation(from: nil, to: UUID())
        XCTAssertEqual(coordinator.staged.map(\.id), [sealed.id],
                       "nil→non-nil is ambiguous until the host accepts or rejects")
        coordinator.endAttachmentDispatch()

        XCTAssertTrue(coordinator.staged.isEmpty,
                      "a rejected nil-sealed dispatch must not strand its attachments in the selected thread")
    }

    @MainActor
    func testNavigationDuringDispatchLetsSuccessfulHandoffCleanFirst() throws {
        let coordinator = ComposerAttachmentCoordinator()
        let sealed = StagedAttachment(kind: .image(Data([0x01])))
        coordinator.staged = [sealed]
        XCTAssertTrue(coordinator.beginAttachmentDispatch())
        let dispatch = try XCTUnwrap(
            coordinator.makeDispatch(
                text: "accepted",
                ref: .builtin(.openclaw),
                conversationID: UUID()
            )
        )

        coordinator.discardForNavigation(from: dispatch.conversationID, to: UUID())
        XCTAssertEqual(coordinator.staged.map(\.id), [sealed.id])
        coordinator.clearAfterSuccessfulHandoff(dispatch)
        coordinator.endAttachmentDispatch()

        XCTAssertTrue(coordinator.staged.isEmpty,
                      "handoff cleanup runs before the deferred navigation discard")
    }

    func testMacAcceptedBeforeDisappearDefersTeardownUntilDispatchEnd() {
        var lifecycle = ComposerDeferredTeardown()
        XCTAssertFalse(lifecycle.request(whileDispatching: true))
        XCTAssertTrue(lifecycle.consume(),
                      "an accepted send can run exact handed-off cleanup before consuming disappear")
        XCTAssertFalse(lifecycle.consume(), "the request is one-shot")
    }

    func testMacDisappearBeforeRejectedAcceptanceDefersDiscardUntilDispatchEnd() {
        var lifecycle = ComposerDeferredTeardown()
        XCTAssertFalse(lifecycle.request(whileDispatching: true))
        XCTAssertTrue(lifecycle.consume(),
                      "a rejected send consumes the same request and discards unsent staging")
    }

    func testDownloadLaneOwnershipFailsClosedForNilAndMismatch() {
        let laneA = String(repeating: "a", count: 64)
        let laneB = String(repeating: "b", count: 64)

        XCTAssertTrue(FileTransferLaneOwnership.matches(
            expectedLaneID: laneA,
            currentLaneID: laneA
        ))
        XCTAssertFalse(FileTransferLaneOwnership.matches(
            expectedLaneID: nil,
            currentLaneID: laneA
        ))
        XCTAssertFalse(FileTransferLaneOwnership.matches(
            expectedLaneID: laneA,
            currentLaneID: nil
        ))
        XCTAssertFalse(FileTransferLaneOwnership.matches(
            expectedLaneID: laneA,
            currentLaneID: laneB
        ))
    }

    func testBackgroundInputLaneRevalidationAllowsReadinessDropButRejectsRepoint() {
        let captured = lane(available: true)
        let sameIdentityNowUnavailable = lane(available: false)

        XCTAssertTrue(FileTransferLaneOwnership.samePhysicalLane(
            captured: captured,
            current: sameIdentityNowUnavailable
        ), "a failed re-test must not brick already-owned storedKeys")
        XCTAssertFalse(FileTransferLaneOwnership.samePhysicalLane(
            captured: captured,
            current: lane(credential: "replacement-lane")
        ), "credential rotation must reject the captured lane before enqueue")
        XCTAssertFalse(FileTransferLaneOwnership.samePhysicalLane(
            captured: captured,
            current: lane(url: "https://replacement.example.test/dav/")
        ), "URL repointing must reject the captured lane before enqueue")
        XCTAssertFalse(FileTransferLaneOwnership.samePhysicalLane(
            captured: captured,
            current: nil
        ))
    }
}

#endif

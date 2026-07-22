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
}

#endif

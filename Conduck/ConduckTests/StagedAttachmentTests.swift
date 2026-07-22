// Conduck
// StagedAttachmentTests.swift
//
// Locks the `.dualText` staging contract (mirrors `.dualImage`):
//   - `.dualText` → `.pendingAttachment` carries the storedKey ONLY when the
//     eager upload has landed (`.uploaded(key)`); not-ready / failed / nil-state
//     → storedKey nil (the file rides inline-only, the disk-ref defers).
//   - `.dualText` is EXCLUDED from the send-blocking helpers
//     (`hasUploadingItem` / `hasFailedUpload`) — its upload never gates Send (the
//     inline fenced text is the guaranteed fallback), exactly like `.dualImage`.
//
// `StagedAttachment` is platform-agnostic; `PendingAttachment` lives in the
// iOS/macOS VM, so this suite runs on the iOS-sim test destination.

#if os(iOS) || os(macOS)

import XCTest
@testable import Conduck

final class StagedAttachmentTests: XCTestCase {

    private func dualText(state: StagedAttachment.ServerFileUploadState?) -> StagedAttachment {
        StagedAttachment(
            kind: .dualText(
                url: URL(fileURLWithPath: "/tmp/notes.md"),
                extractedText: "# notes",
                filename: "notes.md",
                mimeType: "text/markdown"
            ),
            serverUploadState: state
        )
    }

    // MARK: - pendingAttachment storedKey gating

    func testDualText_pendingCarriesStoredKeyWhenUploaded() throws {
        let item = dualText(state: .uploaded(storedKey: "conv/ab12cd34__notes.md"))
        let pending = try XCTUnwrap(item.pendingAttachment)
        guard case let .dualText(url, extractedText, filename, mimeType, storedKey) = pending else {
            return XCTFail("expected .dualText pending")
        }
        XCTAssertEqual(url, URL(fileURLWithPath: "/tmp/notes.md"))
        XCTAssertEqual(extractedText, "# notes")
        XCTAssertEqual(filename, "notes.md")
        XCTAssertEqual(mimeType, "text/markdown")
        XCTAssertEqual(storedKey, "conv/ab12cd34__notes.md",
                       "a landed upload (.uploaded) carries its storedKey onto the wire")
    }

    func testDualText_pendingDropsStoredKeyWhileUploading() throws {
        let item = dualText(state: .uploading(progress: 0.4))
        let pending = try XCTUnwrap(item.pendingAttachment)
        guard case let .dualText(_, _, _, _, storedKey) = pending else {
            return XCTFail("expected .dualText pending")
        }
        XCTAssertNil(storedKey, "an in-flight upload rides inline-only (no storedKey, the disk-ref defers)")
    }

    func testDualText_pendingDropsStoredKeyOnFailure() throws {
        let item = dualText(state: .failed)
        let pending = try XCTUnwrap(item.pendingAttachment)
        guard case let .dualText(_, _, _, _, storedKey) = pending else {
            return XCTFail("expected .dualText pending")
        }
        XCTAssertNil(storedKey, "a failed upload rides inline-only (no storedKey)")
    }

    func testDualText_pendingDropsStoredKeyWhenNilState() throws {
        let item = dualText(state: nil)
        let pending = try XCTUnwrap(item.pendingAttachment)
        guard case let .dualText(_, _, _, _, storedKey) = pending else {
            return XCTFail("expected .dualText pending")
        }
        XCTAssertNil(storedKey)
    }

    // MARK: - Send-blocker exclusion (never gates Send)

    func testDualText_excludedFromSendBlockers_whileUploading() {
        let strip: [StagedAttachment] = [dualText(state: .uploading(progress: 0.1))]
        XCTAssertFalse(strip.hasUploadingItem,
                       "a dual-text tile's in-flight upload must NOT gate Send (inline is the fallback)")
        XCTAssertFalse(strip.hasFailedUpload)
    }

    func testDualText_excludedFromSendBlockers_whenFailed() {
        let strip: [StagedAttachment] = [dualText(state: .failed)]
        XCTAssertFalse(strip.hasFailedUpload,
                       "a dual-text tile's failed upload must NOT gate Send (it rides inline-only)")
        XCTAssertFalse(strip.hasUploadingItem)
    }

    func testServerFile_stillGatesSend_uploadingAndFailed() {
        // Contrast: a large/file-only `.serverFile` tile DOES gate (no inline
        // fallback), so the exclusion is specific to dual tiles.
        let uploadingServerFile = StagedAttachment(
            kind: .serverFile(url: URL(fileURLWithPath: "/tmp/x.pdf"), originalName: "x.pdf", mimeType: "application/pdf"),
            serverUploadState: .uploading(progress: 0.2))
        XCTAssertTrue([uploadingServerFile].hasUploadingItem)

        let failedServerFile = StagedAttachment(
            kind: .serverFile(url: URL(fileURLWithPath: "/tmp/x.pdf"), originalName: "x.pdf", mimeType: "application/pdf"),
            serverUploadState: .failed)
        XCTAssertTrue([failedServerFile].hasFailedUpload)
    }

    func testDualText_isDualTextFlag() {
        XCTAssertTrue(dualText(state: nil).isDualText)
        XCTAssertFalse(dualText(state: nil).isServerFile)
    }

    // MARK: - .needsSetup (binary picked/dropped with no file-server configured)

    private func needsSetup() -> StagedAttachment {
        StagedAttachment(kind: .needsSetup(
            url: URL(fileURLWithPath: "/tmp/report.pdf"),
            originalName: "report.pdf",
            mimeType: "application/pdf",
            byteSize: 12_345
        ))
    }

    func testNeedsSetup_neverRidesTheWire() {
        // No inline fallback + no server to upload to → `pendingAttachment` must
        // be nil so a `.needsSetup` tile can never be silently spliced into a turn.
        XCTAssertNil(needsSetup().pendingAttachment)
        XCTAssertTrue([needsSetup()].pendingAttachments.isEmpty)
    }

    func testNeedsSetup_gatesSend() {
        // The blocking helper: ANY `.needsSetup` tile in the strip disables Send
        // until the user sets up file transfer (host promotes) or removes it.
        XCTAssertTrue([needsSetup()].hasNeedsSetupItem)
        XCTAssertTrue(([dualText(state: nil), needsSetup()]).hasNeedsSetupItem)
        XCTAssertFalse([dualText(state: nil)].hasNeedsSetupItem)
    }

    func testNeedsSetup_flags() {
        let tile = needsSetup()
        XCTAssertTrue(tile.needsSetup)
        XCTAssertFalse(tile.isServerFile)
        XCTAssertFalse(tile.isLoading)
        XCTAssertFalse(tile.isFailed)
        // It must NOT trip the upload-gating helpers (it has no upload state) —
        // `hasNeedsSetupItem` is its own dedicated gate.
        XCTAssertFalse([tile].hasUploadingItem)
        XCTAssertFalse([tile].hasFailedUpload)
    }

    func testNeedsSetup_promotionShapeMatchesServerFile() {
        // Promotion swaps kind in place (same id) → `.serverFile` + `.uploading`,
        // after which the standard server-file gating takes over.
        var tile = needsSetup()
        guard case .needsSetup(let url, let name, let mime, _) = tile.kind else {
            return XCTFail("expected .needsSetup")
        }
        tile.kind = .serverFile(url: url, originalName: name, mimeType: mime)
        tile.serverUploadState = .uploading(progress: 0)
        XCTAssertFalse(tile.needsSetup)
        XCTAssertTrue(tile.isServerFile)
        XCTAssertFalse([tile].hasNeedsSetupItem)
        XCTAssertTrue([tile].hasUploadingItem)
        XCTAssertNil(tile.pendingAttachment, "still nil until the PUT lands")
        tile.serverUploadState = .uploaded(storedKey: "abc12345__report.pdf")
        XCTAssertNotNil(tile.pendingAttachment, "rides the wire once uploaded")
    }
}

#endif

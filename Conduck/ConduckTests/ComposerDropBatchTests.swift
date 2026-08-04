// SPDX-License-Identifier: Apache-2.0

// Conduck
// ComposerDropBatchTests.swift
//
// Locks the pane-wide drop session's contract — the rules that keep a
// multi-file drop honest when its loads finish out of order, one never finishes
// at all, or the user navigates away mid-drop:
//   - results reassemble in DROP order, not completion order;
//   - a slot resolves exactly once (a completion racing its own timeout cannot
//     double-store or leak the temp file it carried);
//   - a cancelled session hands back every app-owned file it holds, and every
//     late callback hands back its own — nothing else knows those temps exist;
//   - a drop made on conversation A never lands anywhere else;
//   - a Finder image drag (file URL AND image bytes) takes the FILE route, so
//     it keeps the size guard that lives only on the file path.
//
// The session models the drop; it never touches `NSItemProvider`. That is what
// lets this suite run on the iOS-sim destination while the composer it serves
// is macOS-only.

#if os(iOS) || os(macOS)

import XCTest
@testable import Conduck

@MainActor
final class ComposerDropBatchTests: XCTestCase {

    private func session(count: Int,
                         destination: ComposerMountIdentity = .newChat) -> DropSession {
        DropSession(destination: destination, count: count)
    }

    private func ownedFile(_ name: String) -> DroppedFileSource {
        DroppedFileSource(
            url: URL(fileURLWithPath: "/tmp/conduck-ftstage-\(UUID().uuidString)-\(name)"),
            originalName: name,
            isAppOwned: true
        )
    }

    // MARK: - Ordering

    /// The whole reason the session exists: a small file that loads fast must
    /// not overtake a large one dropped before it.
    func testResolvingOutOfOrder_batchKeepsDropOrder() throws {
        let s = session(count: 3)
        XCTAssertEqual(s.resolve(index: 2, with: .file(ownedFile("third.pdf"))), .accepted)
        XCTAssertEqual(s.resolve(index: 0, with: .file(ownedFile("first.pdf"))), .accepted)
        XCTAssertNil(s.takeBatch(), "incomplete session must not hand over a batch")
        XCTAssertEqual(s.resolve(index: 1, with: .image(Data([0xFF, 0xD8]))), .accepted)

        let batch = try XCTUnwrap(s.takeBatch())
        XCTAssertEqual(batch.items.count, 3)
        guard case .file(let a) = batch.items[0],
              case .image = batch.items[1],
              case .file(let c) = batch.items[2] else {
            return XCTFail("items landed in the wrong positions: \(batch.items)")
        }
        XCTAssertEqual(a.originalName, "first.pdf")
        XCTAssertEqual(c.originalName, "third.pdf")
    }

    func testIncompleteSession_isNotComplete() {
        let s = session(count: 2)
        XCTAssertEqual(s.resolve(index: 0, with: .failed), .accepted)
        XCTAssertFalse(s.isComplete)
        XCTAssertNil(s.takeBatch())
    }

    // MARK: - Finish-once

    /// A load completing just after its own timeout already failed the slot.
    /// The late result must be refused AND its temp handed back, or it leaks.
    func testDoubleResolve_isRejectedAndReclaimsTheLateFile() {
        let s = session(count: 1)
        XCTAssertEqual(s.resolve(index: 0, with: .failed), .accepted)

        let late = ownedFile("late.pdf")
        XCTAssertEqual(s.resolve(index: 0, with: .file(late)), .rejected(reclaim: late))
    }

    /// A rejected result that owns nothing has nothing to hand back.
    func testDoubleResolve_nonOwningResultReclaimsNothing() {
        let s = session(count: 1)
        XCTAssertEqual(s.resolve(index: 0, with: .failed), .accepted)
        XCTAssertEqual(s.resolve(index: 0, with: .image(Data())), .rejected(reclaim: nil))
    }

    /// A user-owned URL (the file importer's picks) must never be offered up
    /// for deletion.
    func testUserOwnedSource_isNeverReclaimed() {
        let s = session(count: 1)
        let userOwned = DroppedFileSource(
            url: URL(fileURLWithPath: "/Users/someone/report.pdf"),
            originalName: "report.pdf",
            isAppOwned: false
        )
        XCTAssertEqual(s.resolve(index: 0, with: .file(userOwned)), .accepted)
        XCTAssertEqual(s.cancel(), [], "a user-owned file is not ours to delete")
    }

    func testOutOfRangeIndex_isRejected() {
        let s = session(count: 1)
        let orphan = ownedFile("nowhere.pdf")
        XCTAssertEqual(s.resolve(index: 5, with: .file(orphan)), .rejected(reclaim: orphan))
    }

    // MARK: - Cancellation

    /// Navigating away mid-drop must reclaim what already landed...
    func testCancel_handsBackStoredAppOwnedFiles() {
        let s = session(count: 3)
        let a = ownedFile("a.pdf")
        let b = ownedFile("b.pdf")
        XCTAssertEqual(s.resolve(index: 0, with: .file(a)), .accepted)
        XCTAssertEqual(s.resolve(index: 1, with: .image(Data([0x89]))), .accepted)
        XCTAssertEqual(s.resolve(index: 2, with: .file(b)), .accepted)

        XCTAssertEqual(s.cancel(), [a, b])
        XCTAssertTrue(s.isFinished)
    }

    /// ...and a load still in flight must reclaim its own when it lands.
    func testResolveAfterCancel_isRejectedAndReclaims() {
        let s = session(count: 2)
        XCTAssertEqual(s.cancel(), [])

        let late = ownedFile("late.pdf")
        XCTAssertEqual(s.resolve(index: 0, with: .file(late)), .rejected(reclaim: late))
        XCTAssertNil(s.takeBatch(), "a cancelled session never produces a batch")
    }

    func testCancelIsIdempotent() {
        let s = session(count: 1)
        let a = ownedFile("a.pdf")
        XCTAssertEqual(s.resolve(index: 0, with: .file(a)), .accepted)
        XCTAssertEqual(s.cancel(), [a])
        XCTAssertEqual(s.cancel(), [], "a second cancel must not hand the same file back twice")
    }

    /// Taking the batch transfers ownership to the receiver, so the session
    /// must not also offer those files for deletion.
    func testTakeBatch_closesSessionAndStopsReclaiming() throws {
        let s = session(count: 1)
        let a = ownedFile("a.pdf")
        XCTAssertEqual(s.resolve(index: 0, with: .file(a)), .accepted)

        let batch = try XCTUnwrap(s.takeBatch())
        XCTAssertEqual(batch.appOwnedSources, [a])
        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.cancel(), [], "the batch's owner is responsible now")
        XCTAssertNil(s.takeBatch(), "a batch is handed over exactly once")
    }

    // MARK: - Routing stamps

    /// The destination stamp is the only thing standing between a drop made on
    /// one conversation and the composer that replaces it.
    func testBatchCarriesDestination() throws {
        let conversation = UUID()
        let s = session(count: 1, destination: .conversation(conversation))
        XCTAssertEqual(s.resolve(index: 0, with: .failed), .accepted)

        let batch = try XCTUnwrap(s.takeBatch())
        XCTAssertEqual(batch.destination, .conversation(conversation))
    }

    func testAppOwnedSources_excludesImagesAndFailures() throws {
        let s = session(count: 3)
        let a = ownedFile("a.pdf")
        XCTAssertEqual(s.resolve(index: 0, with: .image(Data([0x01]))), .accepted)
        XCTAssertEqual(s.resolve(index: 1, with: .file(a)), .accepted)
        XCTAssertEqual(s.resolve(index: 2, with: .failed), .accepted)

        let batch = try XCTUnwrap(s.takeBatch())
        XCTAssertEqual(batch.appOwnedSources, [a])
    }

    // MARK: - Provider routing

    /// The Finder image case. Taking the image branch here would skip the file
    /// classifier's size guard and heap-load a very large image.
    func testProviderOfferingBothTypes_prefersFileURL() {
        XCTAssertEqual(
            ComposerDropRouting.route(hasFileURL: true, canLoadImage: true),
            .fileURL
        )
    }

    /// The Safari file-promise case — image bytes with no file URL.
    func testImageOnlyProvider_takesImageRoute() {
        XCTAssertEqual(
            ComposerDropRouting.route(hasFileURL: false, canLoadImage: true),
            .imageData
        )
    }

    func testFileOnlyProvider_takesFileRoute() {
        XCTAssertEqual(
            ComposerDropRouting.route(hasFileURL: true, canLoadImage: false),
            .fileURL
        )
    }

    /// A dragged text selection reaches neither branch. It is refused rather
    /// than accepted-and-ignored.
    func testProviderOfferingNeither_isUnsupported() {
        XCTAssertEqual(
            ComposerDropRouting.route(hasFileURL: false, canLoadImage: false),
            .unsupported
        )
    }

    // MARK: - Directory guard

    /// Must be answered BEFORE the drop path copies anything: `copyItem`
    /// recurses, so a folder rejected after the copy has already been
    /// duplicated wholesale into temp.
    func testDirectoryIsDetected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-drop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(ComposerDropRouting.isDirectory(dir))
    }

    func testRegularFileIsNotADirectory() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-drop-test-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertFalse(ComposerDropRouting.isDirectory(file))
    }

    // MARK: - Drop admission

    func testDropAccepted_whenIdle() {
        XCTAssertTrue(ComposerDropRouting.canAcceptDrop(
            hasActiveSession: false, hasParkedBatch: false, isDispatching: false))
    }

    /// Each of these used to accept the drop and silently discard it.
    func testDropRefused_whileBusy() {
        XCTAssertFalse(ComposerDropRouting.canAcceptDrop(
            hasActiveSession: true, hasParkedBatch: false, isDispatching: false))
        XCTAssertFalse(ComposerDropRouting.canAcceptDrop(
            hasActiveSession: false, hasParkedBatch: true, isDispatching: false))
        XCTAssertFalse(ComposerDropRouting.canAcceptDrop(
            hasActiveSession: false, hasParkedBatch: false, isDispatching: true))
    }
}

#endif

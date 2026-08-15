// SPDX-License-Identifier: Apache-2.0

//
//  AgentDownloadScratchTests.swift
//  ConduckTests
//
//  Locks the Quick Look scratch store for downloaded agent-output files:
//    • `sanitizedLeaf` — separator/`.`/`..`/empty rejection, length bound,
//      extension preservation (an existing extension always beats the MIME),
//      MIME-inference ONLY when extension-less (parameterized MIME tolerated),
//      failed inference stays extension-less (never an invented `.bin`).
//    • `adopt` — per-download UUID directory + clean leaf; the raw temp is
//      MOVED (gone from its old path); distinct directories per call for the
//      same name (collision-proof).
//    • `adopt(data:)` — the inline-attachment route (bytes from the local
//      store, no temp): same directory/leaf contract, content written intact.
//    • `discard` — removes exactly its own per-download directory, leaves
//      sibling entries alone, and is harmless when it runs twice (the export
//      settle's guard depends on that).
//    • the export settle — a picker dismissed by GESTURE reports no outcome at
//      all, so nothing may claim a save, and the reclaim the binding drives
//      still leaves the scratch directory gone.
//    • `sweep` — age-bounded: reclaims only entries older than `maxEntryAge`,
//      spares young ones (the guarantee that a relaunch can't yank a file an
//      Open-with app picked up minutes ago).
//
//  Deterministic + headless: real FileManager against per-test temp fixtures
//  under the scratch root; every test reclaims what it creates.
//

import XCTest
@testable import Conduck

final class AgentDownloadScratchTests: XCTestCase {

    private var createdItems: [AgentDownloadScratch.ScratchItem] = []

    override func tearDown() async throws {
        for item in createdItems {
            await AgentDownloadScratch.shared.discard(item)
        }
        createdItems = []
        try await super.tearDown()
    }

    private func makeTemp(_ contents: String = "payload") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-test-\(UUID().uuidString)")
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - sanitizedLeaf

    func testLeafKeepsNameAndExtension() {
        XCTAssertEqual(
            AgentDownloadScratch.sanitizedLeaf(preferredName: "report.md", mimeType: "text/markdown"),
            "report.md")
    }

    func testLeafExistingExtensionBeatsDisagreeingMime() {
        // The filename is the agent's contract — a wrong recorded MIME must
        // never rewrite it.
        XCTAssertEqual(
            AgentDownloadScratch.sanitizedLeaf(preferredName: "data.csv", mimeType: "application/pdf"),
            "data.csv")
    }

    func testLeafInfersExtensionFromMimeWhenMissing() {
        XCTAssertEqual(
            AgentDownloadScratch.sanitizedLeaf(preferredName: "report", mimeType: "application/pdf"),
            "report.pdf")
    }

    func testLeafToleratesParameterizedMime() {
        XCTAssertEqual(
            AgentDownloadScratch.sanitizedLeaf(preferredName: "notes", mimeType: "text/plain; charset=utf-8"),
            "notes.txt")
    }

    func testLeafUnknownMimeStaysExtensionless() {
        // Never invent `.bin` — QL still shows a placeholder page.
        XCTAssertEqual(
            AgentDownloadScratch.sanitizedLeaf(preferredName: "blob", mimeType: "application/x-conduck-unknown"),
            "blob")
        XCTAssertEqual(
            AgentDownloadScratch.sanitizedLeaf(preferredName: "blob", mimeType: nil),
            "blob")
    }

    func testLeafStripsPathSeparators() {
        XCTAssertEqual(
            AgentDownloadScratch.sanitizedLeaf(preferredName: "../../etc/passwd.txt", mimeType: nil),
            "passwd.txt")
    }

    func testLeafRejectsDotAndEmpty() {
        XCTAssertEqual(AgentDownloadScratch.sanitizedLeaf(preferredName: "..", mimeType: nil), "file")
        XCTAssertEqual(AgentDownloadScratch.sanitizedLeaf(preferredName: "  ", mimeType: nil), "file")
        XCTAssertEqual(
            AgentDownloadScratch.sanitizedLeaf(preferredName: "", mimeType: "application/pdf"),
            "file.pdf")
    }

    func testLeafBoundsLengthKeepingExtension() {
        let long = String(repeating: "a", count: 300) + ".pdf"
        let leaf = AgentDownloadScratch.sanitizedLeaf(preferredName: long, mimeType: nil)
        XCTAssertLessThanOrEqual(leaf.count, 200)
        XCTAssertTrue(leaf.hasSuffix(".pdf"))
    }

    /// The preview leaf becomes a real filename under
    /// `tmp/AgentFileDownloads/<uuid>/`, where POSIX `NAME_MAX` is 255 BYTES. The
    /// name is the AGENT's to choose, so it is not necessarily ASCII: 200 CJK
    /// characters are a legal-looking 600-byte leaf that `moveItem` refuses
    /// outright, and the preview fails instead of opening.
    func testLeafBoundsLengthInBytesNotCharacters() {
        let long = String(repeating: "漢", count: 100) + ".pdf"
        XCTAssertLessThan(long.count, AgentDownloadScratch.maxLeafBytes, "fixture: short in CHARACTERS")

        let leaf = AgentDownloadScratch.sanitizedLeaf(preferredName: long, mimeType: nil)
        XCTAssertLessThanOrEqual(
            leaf.utf8.count, AgentDownloadScratch.maxLeafBytes,
            "a multibyte name must be bounded by the byte budget the filesystem enforces"
        )
        XCTAssertTrue(leaf.hasSuffix(".pdf"), "the extension still survives")
        XCTAssertEqual(
            String(decoding: Array(leaf.utf8), as: UTF8.self), leaf,
            "the cut must land on a Character boundary — a severed scalar decodes to U+FFFD"
        )
    }

    /// The byte bound has to survive contact with a real `moveItem`, which is the
    /// call that actually throws on an overlong leaf.
    func testAdoptSucceedsForAMultibyteNameThatWouldOverflowNameMax() async throws {
        let temp = try makeTemp()
        let item = try await AgentDownloadScratch.shared.adopt(
            temp, preferredName: String(repeating: "漢", count: 100) + ".pdf", mimeType: nil)
        createdItems.append(item)

        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertLessThanOrEqual(item.url.lastPathComponent.utf8.count, 255)
    }

    func testLeafBoundsLengthWithAbsurdExtension() {
        // A malformed `x.<250×a>` leaf: the "extension" is longer than the
        // whole length bound — must plain-truncate, never trap on a negative
        // prefix length.
        let absurd = "x." + String(repeating: "a", count: 250)
        let leaf = AgentDownloadScratch.sanitizedLeaf(preferredName: absurd, mimeType: nil)
        XCTAssertEqual(leaf.count, 200)
    }

    // MARK: - adopt

    func testAdoptMovesIntoCleanlyNamedPerDownloadDirectory() async throws {
        let temp = try makeTemp()
        let item = try await AgentDownloadScratch.shared.adopt(
            temp, preferredName: "report.md", mimeType: "text/markdown")
        createdItems.append(item)

        XCTAssertEqual(item.url.lastPathComponent, "report.md")
        XCTAssertEqual(item.url.deletingLastPathComponent().path, item.directory.path)
        XCTAssertEqual(
            item.directory.deletingLastPathComponent().path,
            AgentDownloadScratch.root.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        // Moved, not copied — the raw extension-less temp is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testAdoptSameNameTwiceYieldsDistinctDirectories() async throws {
        let a = try await AgentDownloadScratch.shared.adopt(
            try makeTemp("a"), preferredName: "report.md", mimeType: nil)
        let b = try await AgentDownloadScratch.shared.adopt(
            try makeTemp("b"), preferredName: "report.md", mimeType: nil)
        createdItems.append(contentsOf: [a, b])

        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path))
    }

    // MARK: - adopt(data:) — inline-attachment route

    func testAdoptDataWritesIntoCleanlyNamedPerDownloadDirectory() async throws {
        let item = try await AgentDownloadScratch.shared.adopt(
            Data("hello from conduck".utf8), preferredName: "hello.txt", mimeType: "text/plain")
        createdItems.append(item)

        XCTAssertEqual(item.url.lastPathComponent, "hello.txt")
        XCTAssertEqual(item.url.deletingLastPathComponent().path, item.directory.path)
        XCTAssertEqual(
            item.directory.deletingLastPathComponent().path,
            AgentDownloadScratch.root.path)
        XCTAssertEqual(
            try String(contentsOf: item.url, encoding: .utf8), "hello from conduck")
    }

    func testAdoptDataInfersExtensionForExtensionlessName() async throws {
        // A pasted/untitled inline attachment ("Attached file" fallback name)
        // still gets a type-carrying leaf so Quick Look picks the right renderer.
        let item = try await AgentDownloadScratch.shared.adopt(
            Data("{}".utf8), preferredName: "Attached file", mimeType: "application/json")
        createdItems.append(item)

        XCTAssertEqual(item.url.lastPathComponent, "Attached file.json")
    }

    func testAdoptDataSameNameTwiceYieldsDistinctDirectories() async throws {
        let a = try await AgentDownloadScratch.shared.adopt(
            Data("a".utf8), preferredName: "notes.md", mimeType: nil)
        let b = try await AgentDownloadScratch.shared.adopt(
            Data("b".utf8), preferredName: "notes.md", mimeType: nil)
        createdItems.append(contentsOf: [a, b])

        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertEqual(try String(contentsOf: a.url, encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: b.url, encoding: .utf8), "b")
    }

    // MARK: - discard

    func testDiscardRemovesOnlyItsOwnDirectory() async throws {
        let keep = try await AgentDownloadScratch.shared.adopt(
            try makeTemp(), preferredName: "keep.txt", mimeType: nil)
        let drop = try await AgentDownloadScratch.shared.adopt(
            try makeTemp(), preferredName: "drop.txt", mimeType: nil)
        createdItems.append(keep)

        await AgentDownloadScratch.shared.discard(drop)

        XCTAssertFalse(FileManager.default.fileExists(atPath: drop.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.url.path))
    }

    #if os(iOS)
    /// REGRESSION — an export the user dismissed BY GESTURE leaves no claim and
    /// no file behind.
    ///
    /// The picker's callback is the wrong thing to hang a reclaim on. A
    /// swipe-down (or a tap outside on iPad) nils the presentation binding and
    /// tears the representable down without ever entering
    /// `UIDocumentPickerDelegate`, so neither arm fires: a reclaim waiting on
    /// that closure never runs, and a row waiting on it sits on "Downloading…"
    /// forever with a dead button. The caller settles on the binding's
    /// non-nil → nil transition instead, which every exit shares.
    ///
    /// Both halves of what that settle rests on are pinned here. The picker
    /// reports NOTHING on this exit — so no "Saved" can be manufactured for a
    /// copy nobody made — and the reclaim it drives removes the whole
    /// per-download directory and is harmless if it runs again (the settle
    /// clears its ledger before the work, so a second call is a no-op).
    ///
    /// What stays out of reach here is the ROW's own resolution, which lives in
    /// SwiftUI `@State`; the founder's QA pass covers that half.
    @MainActor
    func testAGestureDismissedExportReportsNothingAndLeavesNoScratchBehind() async throws {
        let item = try await AgentDownloadScratch.shared.adopt(
            try makeTemp(), preferredName: "profile.mobileconfig", mimeType: nil)
        createdItems.append(item)

        // The picker as the caller builds it, taken to the exit a gesture takes:
        // constructed, its coordinator made, and dropped without either delegate
        // arm being reached.
        final class Outcomes { var reported: [Bool] = [] }
        let outcomes = Outcomes()
        let picker = ServerFileExportPicker(url: item.url) { outcomes.reported.append($0) }
        _ = picker.makeCoordinator()
        XCTAssertTrue(outcomes.reported.isEmpty,
                      "the closure reports an OUTCOME, not a lifecycle event — a caller that reads "
                      + "silence as a save would claim a copy that never happened")

        // The settle's reclaim, and a repeat of it.
        await AgentDownloadScratch.shared.discard(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.directory.path),
                       "the bytes were adopted for one export and that export is over")
        await AgentDownloadScratch.shared.discard(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.directory.path),
                       "settling twice must be harmless — the 24 h sweep is the net, never the plan")
    }
    #endif

    // MARK: - sweep

    func testSweepReclaimsOldEntriesSparesYoung() async throws {
        let young = try await AgentDownloadScratch.shared.adopt(
            try makeTemp(), preferredName: "young.txt", mimeType: nil)
        let old = try await AgentDownloadScratch.shared.adopt(
            try makeTemp(), preferredName: "old.txt", mimeType: nil)
        createdItems.append(young)

        // Backdate the "old" entry's directory past the age bound.
        let past = Date().addingTimeInterval(-AgentDownloadScratch.maxEntryAge - 60)
        try FileManager.default.setAttributes(
            [.creationDate: past], ofItemAtPath: old.directory.path)

        await AgentDownloadScratch.shared.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: young.url.path))
    }
}

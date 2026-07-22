// Conduck
// RelayInboxMoverTests.swift
//
// Relay-convergence rework, Stage A. Deterministic tests for
// `RelayInboxMover.takeOwnership(of:)` — the synchronous inbox-takeover
// helper whose whole reason to exist is that WatchConnectivity deletes the
// incoming `WCSessionFile` when the delegate returns. The tests exercise
// it with plain file URLs (no WCSession involved):
//   1. Happy path: move succeeds, source is GONE, destination carries the
//      `apple-relay-` prefix + the source's extension and the same bytes.
//   2. Copy fallback: a read-only parent directory denies unlink, so
//      `moveItem` fails but `copyItem` still succeeds — source REMAINS
//      (WatchConnectivity reclaims its own original), bytes intact.
//   3. Missing source ⇒ nil (both move and copy fail).
//   4. Extension handling: preserved when present, "m4a" default when
//      absent.
//
// PLATFORM GATE: same membership-exceptions-non-functional trap noted on
// AppleSpeechRunnerTests — wrap the file in `#if !os(watchOS)` so a Watch
// test target would compile this to an empty translation unit. The mover
// itself is platform-neutral Foundation, so no iOS-only gate is needed.

#if !os(watchOS)

import XCTest
@testable import Conduck

final class RelayInboxMoverTests: XCTestCase {

    /// Create a disposable source file inside its own temp subdirectory
    /// (a private parent dir lets the copy-fallback test flip permissions
    /// without touching anything shared). Teardown restores permissions
    /// before deleting so cleanup never fails on the read-only case.
    private func makeSourceFile(
        ext: String = "m4a",
        contents: Data = Data("relay-audio-bytes".utf8)
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-mover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("inbox-clip")
        if !ext.isEmpty {
            url = url.appendingPathExtension(ext)
        }
        try contents.write(to: url)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        return url
    }

    /// Register cleanup for the owned destination the mover produced.
    private func scheduleRemoval(of url: URL) {
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Happy path (move)

    func testMoveTakesOwnershipAndRemovesSource() throws {
        let payload = Data("watch-clip-payload".utf8)
        let source = try makeSourceFile(contents: payload)

        let owned = try XCTUnwrap(
            RelayInboxMover.takeOwnership(of: source),
            "takeOwnership must succeed for a plain movable file"
        )
        scheduleRemoval(of: owned)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source.path),
            "Move path must REMOVE the source (rename, not copy)"
        )
        XCTAssertEqual(
            try Data(contentsOf: owned), payload,
            "Owned file must carry the source bytes verbatim"
        )
        XCTAssertTrue(
            owned.lastPathComponent.hasPrefix("apple-relay-"),
            "Owned filename must use the apple-relay-<uuid> pattern, got \(owned.lastPathComponent)"
        )
        XCTAssertEqual(owned.pathExtension, "m4a")
    }

    // MARK: - Copy fallback

    func testCopyFallbackWhenSourceDirectoryDeniesUnlink() throws {
        let payload = Data("fallback-clip-payload".utf8)
        let source = try makeSourceFile(contents: payload)
        let parentDir = source.deletingLastPathComponent()

        // Read-only parent: POSIX unlink (and thus rename-away) needs WRITE
        // on the parent directory, while copy only needs READ on the file —
        // exactly the asymmetry the mover's fallback exists for.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: parentDir.path
        )

        let owned = try XCTUnwrap(
            RelayInboxMover.takeOwnership(of: source),
            "Copy fallback must rescue the audio when move is denied"
        )
        scheduleRemoval(of: owned)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "Copy fallback must LEAVE the source in place (WatchConnectivity reclaims its own original)"
        )
        XCTAssertEqual(
            try Data(contentsOf: owned), payload,
            "Owned copy must carry the source bytes verbatim"
        )
    }

    // MARK: - Both-fail ⇒ nil

    func testMissingSourceReturnsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-mover-missing-\(UUID().uuidString).m4a")
        XCTAssertNil(
            RelayInboxMover.takeOwnership(of: missing),
            "A non-existent source must fail BOTH move and copy ⇒ nil"
        )
    }

    // MARK: - Extension handling

    func testSourceExtensionIsPreserved() throws {
        let source = try makeSourceFile(ext: "wav")
        let owned = try XCTUnwrap(RelayInboxMover.takeOwnership(of: source))
        scheduleRemoval(of: owned)
        XCTAssertEqual(owned.pathExtension, "wav")
    }

    func testExtensionDefaultsToM4AWhenSourceHasNone() throws {
        let source = try makeSourceFile(ext: "")
        let owned = try XCTUnwrap(RelayInboxMover.takeOwnership(of: source))
        scheduleRemoval(of: owned)
        XCTAssertEqual(
            owned.pathExtension, "m4a",
            "Extension-less sources must default to m4a (the relay's V1 container)"
        )
    }
}

#endif // !os(watchOS)

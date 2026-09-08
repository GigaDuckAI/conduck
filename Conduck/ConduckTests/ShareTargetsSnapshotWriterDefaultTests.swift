// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetsSnapshotWriterDefaultTests.swift
//
// Share-Extension "Send to" picker — coverage for the ONE rule that decides which
// gateway the snapshot advertises as the default: `publishedDefaultRef` publishes
// the stored pointer only when that pointer is in the configured set, and `nil`
// otherwise. Plus a source-text guard asserting the writer reaches the pointer
// through the RAW read alone — every other reader of the default repairs,
// migrates or adopts, and a background regenerate that did any of those would
// rewrite the user's default as a side effect of filling a picker.
//
// Pure static func + an on-disk source read: no App Group, no Keychain, no store,
// no signing. Runs on any sim / headless.

import XCTest
@testable import Conduck

final class ShareTargetsSnapshotWriterDefaultTests: XCTestCase {

    // MARK: - publishedDefaultRef

    func testAConfiguredDefaultIsPublishedEvenWhenItIsNotFirst() {
        // The pointer names the gateway, not a position — the roster's first entry
        // is a FALLBACK the appex applies itself, never what the app publishes.
        let stored = RemoteAgentRef.builtin(.hermes)
        let configured: [RemoteAgentRef] = [.builtin(.openclaw), .builtin(.hermes), .custom(UUID())]

        XCTAssertEqual(
            ShareTargetsSnapshotWriter.publishedDefaultRef(stored: stored, configured: configured),
            RemoteAgentRef.builtin(.hermes).rawString,
            "a configured default must be published verbatim, whatever its place in the roster"
        )
    }

    func testACustomDefaultIsPublishedByItsRawString() {
        // A custom ref round-trips through the same `rawString` form the snapshot's
        // gateway rows carry, so the appex can match them by string alone.
        let id = UUID()
        let stored = RemoteAgentRef.custom(id)
        let configured: [RemoteAgentRef] = [.builtin(.openclaw), .custom(id)]

        XCTAssertEqual(
            ShareTargetsSnapshotWriter.publishedDefaultRef(stored: stored, configured: configured),
            RemoteAgentRef.custom(id).rawString
        )
    }

    func testAStoredPointerOutsideTheConfiguredSetIsNotPublished() {
        // A pointer at a gateway the user has since deleted or un-configured names
        // no row the picker can offer. Publishing it would highlight nothing, or
        // worse, a row the snapshot never carried.
        let stored = RemoteAgentRef.custom(UUID())
        let configured: [RemoteAgentRef] = [.builtin(.openclaw), .builtin(.hermes)]

        XCTAssertNil(
            ShareTargetsSnapshotWriter.publishedDefaultRef(stored: stored, configured: configured),
            "an unconfigured pointer must not reach the wire"
        )
    }

    func testNoStoredPointerPublishesNothing() {
        // "No pointer stored" is a REAL state — the writer reports it as nil rather
        // than inventing one, which is exactly the write the raw read exists to avoid.
        XCTAssertNil(
            ShareTargetsSnapshotWriter.publishedDefaultRef(
                stored: nil,
                configured: [.builtin(.openclaw), .builtin(.hermes)]
            )
        )
    }

    func testAnEmptyConfiguredRosterPublishesNothing() {
        // Nothing is configured, so nothing can be highlighted — even with a
        // pointer stored from before the last gateway was removed.
        XCTAssertNil(
            ShareTargetsSnapshotWriter.publishedDefaultRef(
                stored: .builtin(.openclaw),
                configured: []
            )
        )
        XCTAssertNil(
            ShareTargetsSnapshotWriter.publishedDefaultRef(stored: nil, configured: [])
        )
    }

    // MARK: - The writer reads the pointer RAW (source-text guard)

    /// Every other reader of the default gateway does work beyond reading: it can
    /// repair a dangling pointer, run a migration, adopt a survivor, or retire a
    /// parked marker. This writer runs on hot notification paths and from a
    /// background regenerate, so any of those would let filling a share picker
    /// silently change where the user's next chat goes. The invariant is which
    /// reader the writer calls, so it lives in the source text — read off disk and
    /// anchored on this file's own location, like the writer's other guard test.
    func testTheWriterReachesTheDefaultThroughTheRawReadOnly() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let source = try String(
            contentsOf: projectDirectory
                .appendingPathComponent("Conduck/Services/ShareTargetsSnapshotWriter.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("storedDefaultRemoteAgentRefRaw()"),
            "the writer must read the default pointer through the raw, side-effect-free reader"
        )
        for resolver in [
            "resolveDefaultGateway(",
            "defaultRemoteAgentRef(",
            "defaultRemoteAgentRefIfSendable(",
            "defaultGatewayVerdictWithoutRepair(",
            "newChatPickerSnapshot(",
        ] {
            XCTAssertFalse(
                source.contains(resolver),
                "\(resolver) can write while it reads — a snapshot regenerate must never move the user's default"
            )
        }
    }
}

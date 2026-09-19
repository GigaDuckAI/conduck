// SPDX-License-Identifier: Apache-2.0

// Exercises the on-disk mirror registration and its conservative death proof.
// A live or uninspectable process may be suspended: elapsed time never removes
// its registration. These tests cannot establish physical iOS suspension behavior.

import Darwin
import XCTest
@testable import Conduck

final class ContentSyncProcessLeaseTests: XCTestCase {
    private func fixture(
        processState: (@Sendable (pid_t) -> ContentSyncProcessLease.ProcessState)? = nil
    ) throws -> ContentSyncProcessLease {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-mirror-registration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("Conversations.sqlite")
        if let processState { return ContentSyncProcessLease(beside: store, processState: processState) }
        return ContentSyncProcessLease(beside: store)
    }

    func testMountedSessionRegistersWithoutHoldingAnyFileLock() throws {
        let lease = try fixture()
        let hold = try lease.acquireMirror()
        defer { try? hold.release() }
        XCTAssertThrowsError(try lease.confirmNoMirrors())
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))

        let markers = try FileManager.default.contentsOfDirectory(
            at: lease.registrationsURL, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(markers.count, 1)
        let marker = try XCTUnwrap(markers.first)
        let descriptor = open(marker.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        // Regression: another descriptor can exclusively lock every marker
        // even while the mirror remains registered. No lifetime flock remains.
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        flock(descriptor, LOCK_UN)
        try hold.release()
        try hold.release()
        XCTAssertNoThrow(try lease.confirmNoMirrors())
    }

    func testPermissionDeniedOrUninspectableOwnerKeepsOffPending() throws {
        let lease = try fixture(processState: { _ in .unknown })
        let hold = try lease.acquireMirror()
        defer { try? hold.release() }
        XCTAssertThrowsError(try lease.confirmNoMirrors()) { error in
            guard case ContentSyncProcessLease.Failure.anotherProcessStillMirroring = error else {
                return XCTFail("An uninspectable owner must remain pending")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lease.registrationsURL.path).count, 1)
    }

    func testConfirmedDeadOwnerIsRemovedButCurrentProcessIsRetained() throws {
        let lease = try fixture()
        try FileManager.default.createDirectory(at: lease.registrationsURL, withIntermediateDirectories: true)
        // Darwin's PID range cannot reach Int32.max. Exercise the real ESRCH
        // syscall result, not just a fake that tells the registry to clean up.
        XCTAssertEqual(kill(pid_t.max, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let deadMarker = lease.registrationsURL.appendingPathComponent("\(pid_t.max).\(UUID().uuidString).mirror")
        try Data().write(to: deadMarker)
        XCTAssertNoThrow(try lease.confirmNoMirrors())
        XCTAssertFalse(FileManager.default.fileExists(atPath: deadMarker.path))
        let live = try lease.acquireMirror()
        defer { try? live.release() }
        XCTAssertThrowsError(try lease.confirmNoMirrors())
    }

    func testOldMarkerForReusedLivePIDIsNeverExpired() throws {
        let lease = try fixture()
        let hold = try lease.acquireMirror()
        defer { try? hold.release() }
        let marker = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: lease.registrationsURL, includingPropertiesForKeys: nil
        ).first)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: marker.path)
        XCTAssertThrowsError(try lease.confirmNoMirrors())
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMalformedRegistrationAndUnreadableRegistryCannotProveOff() throws {
        let lease = try fixture()
        try FileManager.default.createDirectory(at: lease.registrationsURL, withIntermediateDirectories: true)
        let bad = lease.registrationsURL.appendingPathComponent("0.\(UUID().uuidString).mirror")
        try Data().write(to: bad)
        XCTAssertThrowsError(try lease.confirmNoMirrors())
        try FileManager.default.removeItem(at: bad)
        try FileManager.default.removeItem(at: lease.registrationsURL)
        try Data().write(to: lease.registrationsURL)
        XCTAssertThrowsError(try lease.confirmNoMirrors())
        XCTAssertThrowsError(try lease.acquireMirror())
    }

    func testDeadOwnerCleanupToleratesConcurrentRemoval() throws {
        let lease = try fixture(processState: { _ in .absent })
        let hold = try lease.acquireMirror()
        XCTAssertNoThrow(try lease.confirmNoMirrors())
        XCTAssertNoThrow(try hold.release())
        XCTAssertNoThrow(try lease.confirmNoMirrors())
    }

    func testLegacyMirrorStillKeepsOffPending() throws {
        let lease = try fixture()
        let descriptor = open(lease.url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_SH | LOCK_NB), 0)
        XCTAssertThrowsError(try lease.confirmNoMirrors())
        flock(descriptor, LOCK_UN)
        XCTAssertNoThrow(try lease.confirmNoMirrors())
    }

    func testUnregisterFailureRemainsRetryable() throws {
        let lease = try fixture()
        let hold = try lease.acquireMirror()
        defer { try? hold.release() }
        let marker = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: lease.registrationsURL, includingPropertiesForKeys: nil
        ).first)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        XCTAssertThrowsError(try hold.release())
        XCTAssertThrowsError(try lease.confirmNoMirrors())
        try FileManager.default.removeItem(at: marker)
        try Data().write(to: marker)
        XCTAssertNoThrow(try hold.release())
        XCTAssertNoThrow(try lease.confirmNoMirrors())
    }
}

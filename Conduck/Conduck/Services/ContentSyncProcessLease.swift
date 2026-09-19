// SPDX-License-Identifier: Apache-2.0

// Registers each mounted CloudKit session without holding a file lock. A
// lifetime flock in the App Group causes 0xdead10cc when iOS suspends the app.
// Publish BEFORE re-reading the durable sync preference, and remove ONLY after
// detaching every mirror. An Off writer persists false before scanning: a late
// registrant then reads false and cannot mount; an earlier one remains visible.
//
// Each empty marker has an immutable, unique name. Only a positively absent
// process (kill(pid, 0) == ESRCH) permits stale-marker cleanup. Suspension, age,
// permission denial and PID reuse never prove a mirror stopped; uncertainty
// keeps Off pending. PID reuse can conservatively delay Off until that process
// exits. Other-process start-time APIs are sandbox-restricted on iOS, so we do
// not infer identity from timestamps or expire a sleeping session.

import Foundation
import Darwin

nonisolated struct ContentSyncProcessLease: Sendable {
    enum Failure: Error { case unavailable, anotherProcessStillMirroring }
    enum ProcessState: Sendable { case present, absent, unknown }

    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var registration: URL?

        init(registration: URL) { self.registration = registration }

        func release() throws {
            try lock.withLock {
                guard let registration else { return }
                try ContentSyncProcessLease.removeRegistration(registration)
                self.registration = nil
            }
        }

        deinit { try? release() }
    }

    /// Retained only to detect a mirror held by an already-running older build.
    let url: URL
    let registrationsURL: URL
    private let processState: @Sendable (pid_t) -> ProcessState

    init(
        beside storeURL: URL,
        processState: @escaping @Sendable (pid_t) -> ProcessState = Self.probeProcess
    ) {
        url = storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + ".content-sync.lock")
        registrationsURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + ".content-sync-sessions", isDirectory: true)
        self.processState = processState
    }

    func acquireMirror() throws -> Hold {
        try FileManager.default.createDirectory(at: registrationsURL, withIntermediateDirectories: true)
        let registration = registrationsURL.appendingPathComponent("\(getpid()).\(UUID().uuidString).mirror")
        // Presence is the entire record, so exclusive creation publishes it
        // atomically. No payload write, staging file, or held descriptor/lock.
        let descriptor = registration.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        close(descriptor)
        return Hold(registration: registration)
    }

    /// Call only after persisting Off and detaching the caller's own mirrors.
    /// Never wait for another process: it may be suspended for an arbitrary time.
    func confirmNoMirrors() throws {
        try confirmNoLegacyMirror()
        let registrations: [URL]
        do {
            registrations = try FileManager.default.contentsOfDirectory(
                at: registrationsURL, includingPropertiesForKeys: nil
            )
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return
        } catch {
            throw Failure.unavailable
        }
        for registration in registrations {
            let parts = registration.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[2] == "mirror",
                  let pid = pid_t(parts[0]), pid > 0,
                  UUID(uuidString: String(parts[1])) != nil else { throw Failure.unavailable }
            switch processState(pid) {
            case .absent:
                // The name is never reused. A simultaneous detach or cleanup
                // may already have removed this exact stale registration.
                try Self.removeRegistration(registration)
            case .present, .unknown:
                throw Failure.anotherProcessStillMirroring
            }
        }
    }

    private static func probeProcess(_ pid: pid_t) -> ProcessState {
        guard pid > 0 else { return .unknown }
        if kill(pid, 0) == 0 { return .present }
        return errno == ESRCH ? .absent : .unknown
    }

    private static func removeRegistration(_ registration: URL) throws {
        let result = registration.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return unlink(path)
        }
        guard result == 0 || errno == ENOENT else { throw Failure.unavailable }
    }

    private func confirmNoLegacyMirror() throws {
        // One-way compatibility with a helper still running the former lock
        // protocol. This synchronous probe never retains a lock or crosses an
        // await. New sessions never acquire the legacy lifetime lock.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDWR | O_CLOEXEC)
        }
        if descriptor < 0 {
            guard errno == ENOENT else { throw Failure.unavailable }
            return
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw Failure.anotherProcessStillMirroring
            }
            throw Failure.unavailable
        }
        flock(descriptor, LOCK_UN)
    }
}

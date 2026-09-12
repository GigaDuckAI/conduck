// SPDX-License-Identifier: Apache-2.0

// A process holds a shared lease for the complete lifetime of its CloudKit
// mirror. Turning sync off probes an exclusive lease after detaching locally;
// success proves that no cooperating app or Shortcut process still mirrors the
// same files. The kernel releases leases on process death. Files are never
// unlinked, which would allow two processes to lock different inodes.

import Foundation
import Darwin

nonisolated struct ContentSyncProcessLease: Sendable {
    enum Failure: Error { case unavailable, anotherProcessStillMirroring }

    final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?

        init(descriptor: Int32) { self.descriptor = descriptor }

        func release() {
            lock.withLock {
                guard let descriptor else { return }
                self.descriptor = nil
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }

        deinit { release() }
    }

    let url: URL

    init(beside storeURL: URL) {
        url = storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + ".content-sync.lock")
    }

    func acquireMirror() throws -> Hold {
        try acquire(operation: LOCK_SH)
    }

    /// A nonblocking probe: callers remain visibly pending and retry instead of
    /// blocking an executor indefinitely behind a suspended helper process.
    func confirmNoMirrors() throws {
        let hold = try acquire(operation: LOCK_EX)
        hold.release()
    }

    private func acquire(operation: Int32) throws -> Hold {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        guard flock(descriptor, operation | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw Failure.anotherProcessStillMirroring
            }
            throw Failure.unavailable
        }
        return Hold(descriptor: descriptor)
    }
}

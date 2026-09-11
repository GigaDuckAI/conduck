// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkMaterialPublicationLock.swift
//
// A CROSS-PROCESS advisory lock over the publication of one material's payload.
//
// WHY IT HAS TO EXIST. A payload and the material row naming it commit in
// separate transactions across two stores, and Work's capture ids are
// deterministic, so two PROCESSES — the app and the headless intent process,
// sharing one App Group sqlite — can publish the same material id at the same
// instant. The second writer finds the first writer's blob already complete,
// adopts it without inserting a row of its own, and commits a card naming bytes
// it did not write; the first writer's rollback then deletes that row. The
// adopting card is left reading `.syncedPending`, and a share-inbox drainer that
// already proved the card durable can acknowledge — deleting the queue's only
// remaining copy — before the deletion lands. `ConversationStore`'s in-memory
// claim set cannot see across a process boundary, so the mutual exclusion has to
// live in the filesystem the two processes share.
//
// WHY `flock`. A lock has to survive the holder being killed — jetsam, a force
// quit, a crash between the blob save and the material save — without leaving
// every later publication of that material blocked for ever. `flock(2)` is
// released by the kernel when the descriptor closes, which includes process
// death, so there is no staleness horizon to tune and no lock file to reap. It
// is also scoped to the OPEN FILE DESCRIPTION rather than to the process, so two
// `ConversationStore` instances inside one process contend exactly as two
// processes do — which is what makes the takeover behaviour testable at all.
//
// WHY LOCK FILES ARE NEVER REMOVED. Unlinking one races a concurrent opener onto
// a different inode, and two holders of two inodes are not holding one lock. A
// zero-byte file per material ever published is the price; the directory is
// bounded by the number of cards the desk has ever held.
//
// This lock orders publications. It is not a transaction and it grants no
// atomicity: the crash-repair protocol in `ConversationStore+Workboard` is still
// what makes a half-finished publication recoverable.

#if !os(watchOS)

import Foundation

/// One material-keyed advisory lock file directory, shared by every process that
/// mounts the same store.
nonisolated struct WorkMaterialPublicationLock: Sendable {

    /// A lock that is HELD. Releasing closes the descriptor, which is also what
    /// the kernel does when the process dies — so a hold that is dropped on any
    /// path, including a crash, is a hold that is released.
    ///
    /// A class rather than a value so `deinit` is the backstop for a caller that
    /// forgets: an unreleased hold would block every later publication of that
    /// material in this process until it exits.
    final class Hold: @unchecked Sendable {
        private let descriptor: Int32
        private let lock = NSLock()
        private var released = false

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        /// Idempotent: the ordinary path releases in a `defer` and `deinit`
        /// releases whatever is left, so both may run for one hold.
        func release() {
            let shouldRelease = lock.withLock { () -> Bool in
                guard !released else { return false }
                released = true
                return true
            }
            guard shouldRelease else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        deinit { release() }
    }

    enum LockError: Error {
        /// The lock directory or its file could not be opened. A publication
        /// that cannot take the lock is refused rather than run unserialized:
        /// running it anyway is exactly the race the lock exists to close.
        case unavailable
    }

    /// Where the lock files live. Derived from the store's own location by
    /// `ConversationStore`, so the App Group container is queried once for both
    /// (`scripts/check-storage-seam.sh` counts a second query as a seam change).
    let directoryURL: URL

    /// How often a waiter retries. `flock` blocks in the kernel and cannot be
    /// cancelled, so waiting is a poll of the non-blocking form instead: the
    /// sleep between attempts is what makes a cancelled capture stop waiting.
    private let pollInterval: Duration

    init(directoryURL: URL, pollInterval: Duration = .milliseconds(20)) {
        self.directoryURL = directoryURL
        self.pollInterval = pollInterval
    }

    /// Take this material's lock, waiting for whoever holds it. Cancellation
    /// -aware: a cancelled task stops waiting and throws rather than holding a
    /// capture open for a lock it will never use.
    func acquire(materialID: UUID) async throws -> Hold {
        try await acquire(filename: "\(materialID.uuidString).lock")
    }

    /// Project membership and a reviewed project deletion use a separate name
    /// from material identities. Always acquire material holds before this one.
    func acquireOrganization() async throws -> Hold {
        try await acquire(filename: "desk-organization.lock")
    }

    private func acquire(filename: String) async throws -> Hold {
        try Task.checkCancellation()
        let descriptor = try openDescriptor(filename: filename)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return Hold(descriptor: descriptor)
            }
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR else {
                close(descriptor)
                throw LockError.unavailable
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                close(descriptor)
                throw error
            }
        }
    }

    /// The lock file for one material. `O_CLOEXEC` so a hold is never inherited
    /// by a child process this one spawns, which would keep the lock alive past
    /// the holder's own death.
    private func openDescriptor(filename: String) throws -> Int32 {
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let url = directoryURL.appendingPathComponent(filename)
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw LockError.unavailable }
        return descriptor
    }
}

#endif

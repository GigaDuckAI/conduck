// Conduck
// RelayInboxMover.swift
//
// Watch→iPhone Apple-speech relay — inbox-race fix (defect 1 of the relay
// convergence rework). WatchConnectivity owns the `WCSessionFile.fileURL`
// it hands to `session(_:didReceive:)` and DELETES that Inbox file the
// moment the delegate callback returns (Apple-documented contract). The
// previous implementation hopped into an async Task and copied the file
// there; whenever the Task lost the scheduling race against the delegate
// return, the copy threw and a perfectly good recording died as
// `audioInvalid` — a root cause of the Watch's "iPhone unreachable"
// timeouts on real devices.
//
// THE single load-bearing property of this helper: ownership transfer is
// SYNCHRONOUS, so `PhoneSessionManager` can call it on the WCSession
// delegate queue BEFORE returning from the delegate method. Everything
// downstream (transcription, reply, dedup) may be async; the move may not.
//
// Strategy: `moveItem` first (same-volume rename — cheap and atomic),
// `copyItem` fallback (covers layouts where the Inbox directory denies
// unlink of the source), nil when both fail — at that point the audio is
// unrecoverable by definition (the original dies on delegate return) and
// the caller replies `audioInvalid` so the Watch converges on an error
// instead of burning its 30 s timeout.
//
// `nonisolated` (the project compiles with MainActor default isolation):
// this helper MUST run inline on the calling (delegate) queue — an actor
// hop would reintroduce the exact race it exists to fix. Pure FileManager
// + URL, zero state, zero logging (file paths are privacy-scoped per
// the spec's Privacy & Security section) — trivially unit-testable with plain file URLs
// (ConduckTests/RelayInboxMoverTests.swift).

import Foundation

/// Synchronously moves a WatchConnectivity Inbox file into a temp URL the
/// app owns. See the header comment for why this must complete before the
/// `session(_:didReceive:)` delegate callback returns.
nonisolated enum RelayInboxMover {

    /// Take ownership of `source` by moving (preferred) or copying
    /// (fallback) it to
    /// `FileManager.default.temporaryDirectory/apple-relay-<uuid>.<ext>`.
    /// The source's path extension is preserved; extension-less sources
    /// default to "m4a" (the relay's only audio container at V1).
    ///
    /// - Returns: the owned destination URL, or nil when both move and
    ///   copy failed (the caller must treat the audio as lost and reply
    ///   with an error so the Watch converges).
    static func takeOwnership(of source: URL) -> URL? {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-relay-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            // Move can fail where a copy still succeeds (no unlink
            // permission on the source's parent directory, cross-volume
            // edge cases). A copy is enough — WatchConnectivity deletes
            // its own original when the delegate returns.
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            } catch {
                return nil
            }
        }
    }
}

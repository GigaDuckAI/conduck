// SPDX-License-Identifier: Apache-2.0

//
//  AgentDownloadScratch.swift
//  Conduck
//
//  Scratch store for files the user previews via Quick Look — downloaded
//  agent-output files AND inline attachments whose bytes already live in the
//  local store. `BackgroundFileTransfer.downloadFile` returns an extension-less
//  UUID temp — useless to Quick Look (no type, ugly title). `adopt` places the
//  bytes (moved from a temp URL, or written from in-memory `Data`) into
//  tmp/AgentFileDownloads/<UUID>/<real filename> so the preview resolves the
//  right renderer and shows the clean name (QL titles from the last path
//  component), and Save-to-Files / Open-with inherit it too.
//
//  Lifecycle — scratch retention, NOT a cache (retained files are never
//  reused; a re-tap re-downloads because the agent may have rewritten the
//  file): iOS discards a per-download dir the moment its preview dismisses;
//  macOS never deletes on panel close (the panel's "Open with <app>" hands the
//  target app the live path — deleting would yank it) and relies on the age
//  sweep. `sweep()` reclaims entries older than `maxEntryAge` at launch AND on
//  every adoption — launch-only would grow unbounded in a long-running
//  menu-bar app. An actor so adopt/discard/sweep never interleave.
//
//  PRIVACY: never logs filenames / URLs / storedKeys. A filename is itself
//  leakable — see `LoggingPrivacyDriftGuardTests`, which fails the build on the
//  mechanical half of this rule.

import Foundation
import UniformTypeIdentifiers

actor AgentDownloadScratch {
    static let shared = AgentDownloadScratch()

    /// Opaque handle for one adopted download. `discard` removes exactly this
    /// per-download directory — deliberately NOT a bare-URL API whose caller
    /// could point `deletingLastPathComponent()` at an unrelated parent.
    struct ScratchItem: Sendable, Equatable {
        let url: URL
        let directory: URL
    }

    /// Entries older than this are reclaimed by `sweep()`.
    static let maxEntryAge: TimeInterval = 24 * 60 * 60

    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentFileDownloads", isDirectory: true)
    }

    /// Move a downloaded temp file into a fresh per-download directory under a
    /// clean, type-carrying leaf name. On failure the created directory is
    /// reclaimed and the raw temp is left for the caller to clean up.
    func adopt(_ tempURL: URL, preferredName: String, mimeType: String?) throws -> ScratchItem {
        sweep()
        let leaf = Self.sanitizedLeaf(preferredName: preferredName, mimeType: mimeType)
        let directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(leaf)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return ScratchItem(url: destination, directory: directory)
    }

    /// Write in-memory bytes into a fresh per-download directory under a
    /// clean, type-carrying leaf name — the inline-attachment twin of the
    /// URL-based `adopt` (the bytes already live in the local store; no
    /// download, no temp file to move). On failure the created directory is
    /// reclaimed.
    func adopt(_ data: Data, preferredName: String, mimeType: String?) throws -> ScratchItem {
        sweep()
        let leaf = Self.sanitizedLeaf(preferredName: preferredName, mimeType: mimeType)
        let directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(leaf)
        do {
            try data.write(to: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return ScratchItem(url: destination, directory: directory)
    }

    func discard(_ item: ScratchItem) {
        try? FileManager.default.removeItem(at: item.directory)
    }

    /// Reclaim per-download directories older than `maxEntryAge`. Age-bounded —
    /// never the whole root — so a relaunch can't delete a file an Open-with
    /// app picked up minutes ago.
    func sweep() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Self.maxEntryAge)
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if (created ?? .distantPast) < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Leaf-name hardening: last path component only (no separators), no
    /// `.`/`..`/empty, bounded length. An existing extension always wins (even
    /// when the recorded MIME disagrees — the name is the agent's contract);
    /// only an extension-LESS leaf gets one inferred from the MIME type, and a
    /// failed inference stays extension-less (never an invented `.bin`).
    static func sanitizedLeaf(preferredName: String, mimeType: String?) -> String {
        var leaf = (preferredName as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if leaf.isEmpty || leaf == "." || leaf == ".." {
            leaf = "file"
        }
        if leaf.utf8.count > maxLeafBytes {
            // Keep the type-carrying extension when truncating an absurd name —
            // unless the "extension" is itself absurd (a malformed `x.<200×a>`
            // leaf), where a plain prefix is the only sane cut.
            let ext = (leaf as NSString).pathExtension
            if ext.isEmpty || ext.utf8.count > 20 {
                leaf = byteBoundedPrefix(leaf, maxBytes: maxLeafBytes)
            } else {
                let base = byteBoundedPrefix(
                    (leaf as NSString).deletingPathExtension,
                    maxBytes: maxLeafBytes - ext.utf8.count - 1
                )
                leaf = "\(base).\(ext)"
            }
        }
        if (leaf as NSString).pathExtension.isEmpty,
           let mimeType,
           // Tolerate parameterized values ("text/markdown; charset=utf-8").
           let bare = mimeType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
           let ext = UTType(mimeType: bare)?.preferredFilenameExtension {
            leaf += ".\(ext)"
        }
        return leaf
    }

    /// Longest leaf `sanitizedLeaf` will emit before appending a MIME-inferred
    /// extension, in BYTES.
    ///
    /// Counted in bytes, not characters, because the name is the AGENT's to
    /// choose and lands on a real filesystem: POSIX `NAME_MAX` is 255 bytes, so
    /// 200 CJK characters are a legal-looking 600-byte leaf that `moveItem`
    /// refuses outright — the preview fails instead of opening. The budget sits
    /// below 255 so the inferred extension still fits.
    static let maxLeafBytes = 200

    /// Longest prefix of `value` fitting `maxBytes`, cut on a Character
    /// boundary so the result is never a severed UTF-8 sequence (a leaf the
    /// filesystem would reject for a second, harder-to-read reason).
    private static func byteBoundedPrefix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard value.utf8.count > maxBytes else { return value }
        var kept = ""
        var used = 0
        for character in value {
            let width = String(character).utf8.count
            guard used + width <= maxBytes else { break }
            kept.append(character)
            used += width
        }
        return kept
    }
}

// MARK: - Orphaned-temp reclaim

/// Launch-time reclaim for temp files the app's OWN writers left behind.
///
/// WHY it is needed: every capture, staged upload, and request body is written to
/// `FileManager.default.temporaryDirectory` under a fresh UUID name, and every
/// cleanup is in-process (`defer`, or a URLSession delegate callback). A jetsam,
/// crash, or force-quit between the write and the cleanup therefore leaks a file
/// with no owner left to delete it — and because those names are unique, repeats
/// ACCUMULATE rather than overwrite. iOS/watchOS purge `tmp` only opportunistically
/// ("may be purged when the app is not running"), so on a device that is rarely
/// short of space those files can survive for weeks.
///
/// The one writer that does NOT accumulate is the onboarding shortcut export
/// (`GigaAction.shortcut` — a fixed name, deleted before each copy, so it
/// overwrites in place). It is a bundled resource holding no user data, and it is
/// deliberately absent from `ownedPrefixes`: a single self-replacing file is not
/// the failure this reclaim exists for. `TempScratchLeafDriftGuardTests` records
/// that exemption so the omission reads as a decision, not an oversight.
///
/// WHY it is a privacy fix, not disk hygiene: the leaked files are raw voice
/// recordings (`conduck_capture_`, `carplay_`, `watch-capture-`, `wav_*`, …) and
/// request bodies that embed either a second copy of a recording (`stt-body-`) or
/// the entire client-owned conversation history in plaintext
/// (`conduck-converse-body-`, `conduck-carplay-converse-body-`,
/// `conduck-watch-converse-body-`). The architecture's invariant is that Conduck
/// never persists audio where it controls the storage; an orphan contradicts it.
///
/// WHERE it runs: every process that writes those files — `ConduckApp` (iOS),
/// `AppDelegate` (macOS), `ConduckWatchApp` (watchOS), each through
/// `sweepInBackground()`. The wrist is not optional coverage: it is the surface
/// with the least memory headroom (jetsam mid-upload is routine there) and the
/// one whose `tmp` the user cannot inspect or clear.
///
/// `nonisolated` (the app targets compile with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated type would be
/// implicitly `@MainActor`): this scan enumerates the SHARED temp directory,
/// which every framework in the process also stages files in, so its cost scales
/// with someone else's activity, not ours — it has no business on the main
/// thread. See `sweepInBackground()` for why `nonisolated` alone is not enough.
/// Pure `FileManager` + `URL` + `Date`, no state beyond two immutable `let`s, so
/// it is safe on any executor (the shared `FileManager` is documented
/// thread-safe absent a delegate, and none is set).
///
/// WHY it cannot race a live upload: matching is PREFIX-scoped to names this app
/// writes (never the whole directory — other frameworks stage files in `tmp` too),
/// and age-bounded at `maxOrphanAge`. A background upload's own body file must
/// outlive the task, but the longest resource budget in the app is
/// `remoteAgentConverseResourceTimeout` (600 s), so a 24 h floor sits two orders
/// of magnitude clear of any in-flight body — and clear of `PendingRetryStore`'s
/// 10-minute retry-audio window, which owns `conduck_retry_` files until it
/// expires them itself. Mirrors `AgentDownloadScratch.sweep()`'s shape (same
/// `.creationDateKey` + cutoff pattern) so there is ONE reviewed idea here, not two.
nonisolated enum TempScratchSweeper {

    /// Age floor for reclaiming an orphan. See the type comment for why 24 h is
    /// the smallest safe value.
    static let maxOrphanAge: TimeInterval = 24 * 60 * 60

    /// Filename prefixes this app writes into `temporaryDirectory`. Prefix
    /// matching (not extension or wildcard) keeps the sweep off every file the
    /// system or another framework staged there. `carplay_` covers
    /// `carplay_upload_`; `conduck-stt-` covers `conduck-stt-body-`;
    /// `apple-relay-` covers `apple-relay-out-`.
    ///
    /// Every writer MUST prefix its leaf. A bare `UUID().uuidString` name is
    /// unreachable from here and can only be claimed by a rule loose enough to
    /// hit other frameworks' files — so an unprefixed capture is permanently
    /// unreclaimable, not merely unswept. `TempScratchSweeperTests` (iOS) and
    /// `WatchTempScratchSweeperTests` (watchOS) each pin the writer list.
    static let ownedPrefixes = [
        "conduck_capture_",                 // menu-bar dictation capture (audio)
        "conduck_retry_",                   // retry audio (PendingRetryStore-owned)
        "conduck-inapp-",                   // in-app recorder capture (audio)
        "conduck-stt-",                     // intent handoff audio + STT request body
        "conduck-apple-test-",              // Settings Apple-STT test recording (audio)
        "conduck-cloud-stt-test-",          // Settings cloud-STT test recording (audio)
        "carplay_",                         // CarPlay capture + upload copy (audio)
        "wav_input_", "wav_output_",        // AudioCompressor scratch (audio)
        "compress_input_", "compress_output_",
        "stt-body-",                        // multipart STT body (embeds the audio)
        "stt-json-body-",                   // JSON STT body (embeds the audio, base64)
        "conduck-converse-body-",           // converse request body (conversation history)
        "conduck-carplay-converse-body-",   // CarPlay converse request body
        "conduck-watch-converse-body-",     // wrist converse request body (same history)
        "conduck-recorder-",                // shared mic recorder capture (audio)
        "apple-relay-",                     // Apple-relay clip movers (audio)
        "watch-capture-",                   // wrist recorder capture (audio)
        "watch-stt-audio-",                 // wrist STT multipart input copy (audio)
        "conduck-download-",                // completed agent-output download body
        // Copies of USER CONTENT staged for a background uploader that deletes its
        // own input. That delete is in-process, so an abnormal termination between
        // the copy and the upload's completion strands the user's file.
        "conduck-imgupload-",               // original image bytes, full fidelity
        "conduck-ftstage-",                 // security-scoped file copy (leaf embeds the filename)
        "conduck-share-imgupload-",         // share-extension image, drained from the inbox
        "conduck-share-upload-",            // share-extension file, same path
        "diagnostics-stt-probe-",           // copy of a bundled probe clip (not user audio)
        "conduck-ftupload-",                // throwaway copy staged for the background driver
    ]

    /// Launch entry point — the only one callers should use.
    ///
    /// `Task.detached` is load-bearing, not stylistic. Every launch caller
    /// (`ConduckApp.init`, `AppDelegate.applicationDidFinishLaunching`,
    /// `ConduckWatchApp.init`) is main-actor isolated, so a plain `Task { }` there
    /// INHERITS main-actor isolation — it would defer the directory scan to a
    /// later main-thread turn, not move it off one. `sweep()` being `nonisolated`
    /// does not help either: a synchronous `nonisolated` call runs on whatever
    /// thread invokes it. Only a detached task actually puts the scan on a
    /// background executor, which is the whole point on watchOS, where this runs
    /// on every background-URLSession relaunch on the device with the least
    /// headroom.
    ///
    /// Fire-and-forget: best-effort hygiene with no result any caller needs, and
    /// nothing at launch orders against it. `PendingRetryStore` owns App-Group
    /// storage (a different container entirely) and `AgentDownloadScratch` owns
    /// the `AgentFileDownloads` subdirectory this scan never descends into, so a
    /// concurrent launch task cannot collide with it — and a lost race on any
    /// single file is a `try?` no-op by construction.
    static func sweepInBackground() {
        Task.detached(priority: .utility) { sweep() }
    }

    /// Delete owned-prefix entries older than `maxOrphanAge`. Best-effort and
    /// silent: a failure leaves the file for the next launch, and nothing here is
    /// ever logged (the names embed nothing sensitive, but the directory listing
    /// would reveal capture activity).
    ///
    /// Synchronous, and it BLOCKS the calling thread for the length of a scan of
    /// the shared temp directory. Shipping code goes through
    /// `sweepInBackground()`; the only direct callers are the tests, which need
    /// the scan finished before they assert.
    static func sweep() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxOrphanAge)
        for entry in entries {
            let name = entry.lastPathComponent
            guard ownedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            // An unreadable creation date is NOT treated as old — never delete on
            // a missing timestamp.
            guard let created, created < cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
}

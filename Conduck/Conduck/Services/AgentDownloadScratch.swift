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
//  PRIVACY: never logs filenames / URLs / storedKeys (spec — Agent File
//  Transfer, Privacy).

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
        if leaf.count > 200 {
            // Keep the type-carrying extension when truncating an absurd name —
            // unless the "extension" is itself absurd (a malformed `x.<200×a>`
            // leaf), where a plain prefix is the only sane cut.
            let ext = (leaf as NSString).pathExtension
            if ext.isEmpty || ext.count > 20 {
                leaf = String(leaf.prefix(200))
            } else {
                let base = String(((leaf as NSString).deletingPathExtension).prefix(200 - ext.count - 1))
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
}

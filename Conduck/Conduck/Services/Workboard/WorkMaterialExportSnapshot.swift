// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkMaterialExportSnapshot.swift
//
// ONE disposable copy of one desk card's bytes, for every surface that hands a
// Work material to something outside the app: Quick Look, "Open with", the
// share sheet.
//
// WHY A COPY AT ALL. `WorkAssetVault`'s URL is authoritative — the desk's own
// revision covers those bytes — and everything downstream of a preview or a
// share is free to mutate what it is given. So no external opener ever receives
// the vault's URL; it receives a throwaway file that nothing else reads.
//
// WHY ONE TYPE. The copy is made in two lanes (a device-local vault leaf is
// copied, a synced payload is written out) and both have to agree on the
// filename, the type and the reclaim rule. Two implementations of that is how
// the vault lane ended up deciding "does this title already carry an
// extension?" differently from the payload lane — a card called "Meeting v1.2"
// reads as having the extension `.2`, and its bytes then travel with their own
// type unstated.
//
// WHY EACH COPY IS ITS OWN TOP-LEVEL DIRECTORY. `TempScratchSweeper` ages
// entries directly under the shared temporary directory, so a single parent
// folder holding every copy would be aged by ITS creation date: once that
// folder is a day old, a copy made one second ago is swept out from under
// whatever is still reading it. Naming each copy's own directory with the
// sweeper's prefix makes the sweep per-copy, which is what a file handed to
// another process — with no dismissal signal of any kind coming back — needs.

#if !os(watchOS)

import Foundation
import UniformTypeIdentifiers

/// Why a copy could not be made. Only ONE case, deliberately: every other
/// failure here is a file-system error and must keep its own message, because
/// "out of space" and "these bytes are not on this device" are different things
/// to tell a person.
///
/// It carries NO copy of its own, and that is the contract: the sentence a
/// person reads names the verb they asked for, so the preview lane and the
/// share lane each map this to their own. A `LocalizedError` here would be a
/// third sentence neither surface chose.
nonisolated enum WorkMaterialExportError: Error, Equatable {
    /// The card names no bytes this device can read.
    case bytesUnavailable
}

/// Where a card's bytes come from. A struct of closures rather than a direct
/// `ConversationStore` call so the copy logic — filenames, types, reclaim — is
/// exercisable without a store, which is the half that keeps getting the edge
/// cases wrong.
nonisolated struct WorkMaterialExportBytes: Sendable {
    /// The vault's authoritative URL for a device-local payload, or nil for a
    /// card whose bytes are a synced payload (or absent).
    var localURL: @Sendable (UUID) async throws -> URL?
    /// The bytes themselves, from whichever lane the card names.
    var payload: @Sendable (UUID) async throws -> Data?

    init(
        localURL: @escaping @Sendable (UUID) async throws -> URL?,
        payload: @escaping @Sendable (UUID) async throws -> Data?
    ) {
        self.localURL = localURL
        self.payload = payload
    }

    static var live: WorkMaterialExportBytes {
        WorkMaterialExportBytes(
            localURL: { try await ConversationStore.shared.localURLForWorkMaterial(id: $0) },
            payload: { try await ConversationStore.shared.loadWorkMaterialPayload(id: $0) }
        )
    }
}

/// A finished throwaway copy: the file, the directory that owns it, and the
/// type the receiving app should read it as.
nonisolated struct WorkMaterialExportSnapshot: Sendable, Equatable {

    /// The per-copy directory, directly under the shared temporary directory
    /// and carrying `containerPrefix`. Reclaiming removes THIS, not the file:
    /// the directory is the unit the sweeper ages.
    let container: URL
    /// The copy itself.
    let url: URL
    /// What the bytes are, resolved once so a caller never has to guess.
    let contentType: UTType

    var filename: String { url.lastPathComponent }

    /// The prefix every copy directory carries. It is one of
    /// `TempScratchSweeper.ownedPrefixes`, and the per-copy suffix appended to
    /// it is what makes that sweep age each copy on its own.
    static let containerPrefix = "Conduck-Workboard-Preview-"

    // MARK: - Making one

    /// A throwaway copy of one card's bytes, from whichever lane holds them.
    ///
    /// A device-local payload is COPIED from the vault leaf, so a large capture
    /// never has to be read into memory to be handed on; a synced payload is
    /// written out. Both land in the same shape, so one reclaim rule and one
    /// sweep cover both and neither can be forgotten on its own.
    static func make(
        for material: WorkboardMaterialSnapshot,
        bytes: WorkMaterialExportBytes
    ) async throws -> WorkMaterialExportSnapshot {
        if let localURL = try await bytes.localURL(material.id) {
            return try await copying(
                from: localURL,
                displayName: material.name,
                mimeType: material.mimeType
            )
        }
        guard let data = try await bytes.payload(material.id) else {
            throw WorkMaterialExportError.bytesUnavailable
        }
        return try await writing(
            data,
            displayName: material.name,
            mimeType: material.mimeType
        )
    }

    /// The vault lane. The leaf's own extension is the last thing consulted,
    /// after the title and the stored mime type, because it is the only one of
    /// the three that describes storage rather than content.
    static func copying(
        from sourceURL: URL,
        displayName: String,
        mimeType: String?
    ) async throws -> WorkMaterialExportSnapshot {
        let name = filename(
            displayName: displayName,
            mimeType: mimeType,
            vaultLeafExtension: sourceURL.pathExtension
        )
        return try await stage(name: name, mimeType: mimeType) { destination in
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
    }

    /// The synced-payload lane. No vault leaf exists, so the title and the
    /// stored mime type are the whole description of these bytes.
    static func writing(
        _ data: Data,
        displayName: String,
        mimeType: String?
    ) async throws -> WorkMaterialExportSnapshot {
        let name = filename(
            displayName: displayName,
            mimeType: mimeType,
            vaultLeafExtension: nil
        )
        return try await stage(name: name, mimeType: mimeType) { destination in
            try data.write(to: destination, options: .atomic)
        }
    }

    /// Both lanes' shared body: make the per-copy directory, run the write, and
    /// take the whole directory back down if it fails. Detached because the
    /// write is uninterruptible file work and every caller is on the MainActor.
    private static func stage(
        name: String,
        mimeType: String?,
        write: @escaping @Sendable (URL) throws -> Void
    ) async throws -> WorkMaterialExportSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let container = try makeContainer()
            let destination = container.appendingPathComponent(name, isDirectory: false)
            do {
                try write(destination)
                #if os(iOS)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path
                )
                #endif
                return WorkMaterialExportSnapshot(
                    container: container,
                    url: destination,
                    contentType: contentType(filename: name, mimeType: mimeType)
                )
            } catch {
                reclaimContainer(container)
                throw error
            }
        }.value
    }

    private static func makeContainer() throws -> URL {
        // The leaf is spelled as a LITERAL prefix plus an interpolated id rather
        // than as `containerPrefix + …`: `TempScratchLeafDriftGuardTests` reads
        // this source and can only see that the leaf is claimed when the prefix
        // is written out here. `testEachCopyOwnsItsOwnSweepableContainer` is
        // what keeps the literal and `containerPrefix` from drifting apart.
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Conduck-Workboard-Preview-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return container
    }

    // MARK: - Reclaim

    /// Give the bytes back. Safe to call more than once.
    func reclaim() {
        Self.reclaimContainer(container)
    }

    /// The guard is the point: a reclaim that walked up from a file path could
    /// be handed a URL from somewhere else entirely and delete a directory it
    /// guessed at. Only a prefixed leaf sitting DIRECTLY in the temporary
    /// directory is ever removed.
    static func reclaimContainer(_ container: URL) {
        guard container.lastPathComponent.hasPrefix(containerPrefix) else { return }
        let parent = container.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == temporary else { return }
        try? FileManager.default.removeItem(at: container)
    }

    // MARK: - Naming

    /// The name a disposable copy carries.
    ///
    /// A card's NAME is a title, not a filename — a recording's is "Voice note",
    /// and a captured file's can be the first line of its own text — while Quick
    /// Look, the share sheet and every receiving app decide what a file IS from
    /// its extension alone.
    ///
    /// Three descriptions of the bytes reach this layer, consulted in
    /// decreasing order of how much each knows about CONTENT:
    ///
    ///   1. an extension the title already carries, when the system can name a
    ///      type for it. A title such as "Meeting v1.2" ends in something that
    ///      looks like an extension and describes nothing, so it does not
    ///      count — treating it as one leaves the payload's own type unstated,
    ///      which is exactly the defect this ordering exists to prevent.
    ///   2. the stored mime type, which is what the capture recorded about the
    ///      bytes themselves.
    ///   3. the vault leaf's extension. Last because it describes how the bytes
    ///      are STORED; it is taken verbatim, recognised or not, because it came
    ///      off the original file and is the only remaining description there
    ///      is.
    static func filename(
        displayName: String,
        mimeType: String?,
        vaultLeafExtension: String? = nil
    ) -> String {
        let base = safeFilename(displayName)
        if namesAType((base as NSString).pathExtension) { return base }
        if let mimeType, let preferred = UTType(mimeType: mimeType)?.preferredFilenameExtension {
            return "\(base).\(preferred)"
        }
        if let vaultLeafExtension, !vaultLeafExtension.isEmpty {
            return "\(base).\(vaultLeafExtension)"
        }
        return base
    }

    /// Whether a trailing fragment is an extension the system can name a type
    /// for, rather than a number that happens to follow a dot.
    static func namesAType(_ fileExtension: String) -> Bool {
        guard !fileExtension.isEmpty else { return false }
        return UTType(filenameExtension: fileExtension).map { !$0.isDynamic } == true
    }

    /// What the copy claims to be. The FILENAME is asked first, because it is
    /// what the receiving app reads anyway; the mime type answers for a name
    /// that states nothing. `.data` is the unknown fallback and never a
    /// substitute for either — it is the answer when there is no answer.
    static func contentType(filename: String, mimeType: String?) -> UTType {
        let fileExtension = (filename as NSString).pathExtension
        if !fileExtension.isEmpty,
           let fromName = UTType(filenameExtension: fileExtension), !fromName.isDynamic {
            return fromName
        }
        if let mimeType, let fromMime = UTType(mimeType: mimeType), !fromMime.isDynamic {
            return fromMime
        }
        return .data
    }

    /// A title reduced to something a file system accepts. Path separators
    /// become dashes rather than being dropped, so two cards whose titles differ
    /// only there still differ here.
    static func safeFilename(_ rawValue: String) -> String {
        let replaced = rawValue
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = replaced == "." || replaced == ".." ? "" : replaced
        return safe.isEmpty ? "Work material" : String(safe.prefix(120))
    }
}

#endif

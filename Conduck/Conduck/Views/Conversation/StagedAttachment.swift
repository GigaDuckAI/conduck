// Conduck
// StagedAttachment.swift
//
// The staging model for the composer's attachment strip. A staged item is
// a not-yet-sent attachment the host (ContentView / library / macOS composer)
// collected from a PhotosPicker / fileImporter / camera / paste / drop and is
// holding until the user taps Send. The host converts the resolved cases into
// `[PendingAttachment]` and hands them to `viewModel.sendUserTurn(...)`.
//
// The model carries a transient identity (`id`) so the preview strip can show a
// per-tile LOADING placeholder while a `PhotosPickerItem.loadTransferable`
// (the Progress overload) fetch is in flight, then swap that same tile in place
// to `.image` (resolved bytes) or `.failed` (load error) — siblings unaffected.
// Send is disabled while ANY item is still `.loading` (prevents partial
// payloads — key UX decision #6).
//
// `Equatable` so SwiftUI can diff the strip's `ForEach` cheaply (the heavy
// `Data` payload compares by identity in practice — distinct loads get distinct
// ids; we never mutate bytes in place).

import Foundation

/// One staged-but-unsent composer attachment. The `id` is stable across the
/// loading → resolved transition so the strip animates a tile in place rather
/// than replacing it.
struct StagedAttachment: Identifiable, Equatable {
    let id: UUID
    var kind: Kind

    /// Eager-upload state for a `.serverFile`, `.dualImage`, OR `.dualText` tile
    /// (the file-transfer routes). Nil for every other kind (plain `.image` /
    /// inline-only `.file` / loading / failed) — those never touch the file-server.
    /// The
    /// host kicks the background upload the instant the tile is staged
    /// (eager-on-attach, determinate progress) and mutates this in place as the
    /// PUT advances: `.uploading(p)` while the bytes climb, `.uploaded(storedKey)`
    /// once the PUT lands (carrying the server handle the wire splice needs),
    /// `.failed` on a fail-fast error (NO silent retry). Send-gating DIFFERS by
    /// kind: a `.serverFile` `.uploading`/`.failed` tile BLOCKS the turn (no
    /// inline fallback — the strip shows Retry), but a `.dualImage` NEVER blocks
    /// (the inline base64 is always a fallback — `hasUploadingItem` /
    /// `hasFailedUpload` exclude it).
    enum ServerFileUploadState: Equatable {
        /// The background PUT is in flight; `progress` is 0...1 (determinate).
        case uploading(progress: Double)
        /// The PUT landed; `storedKey` is the server handle (`<shortid>__<name>`)
        /// the turn references on the wire and persists on the draft.
        case uploaded(storedKey: String)
        /// The upload failed fast — the strip shows an error badge + Retry; the
        /// tile never rides the wire while in this state.
        case failed
    }

    /// The resolution state of a staged item.
    enum Kind: Equatable {
        /// A PhotosPicker item whose bytes are still being fetched (e.g. from
        /// iCloud). The strip shows a determinate `ProgressView` while pending.
        case loading
        /// A resolved image's original picked bytes (HEIC / ProRAW / …). The VM
        /// downsizes + strips EXIF at send time. This is the INLINE-ONLY image
        /// path — used when the bound gateway has NO file-server configured.
        case image(Data)
        /// A DUAL-route image (file-transfer route + inline vision): the bound
        /// gateway has a file-server, so at staging the host (a) processed the
        /// image ONCE (downsized + EXIF/GPS-stripped JPEG, the INLINE/persist
        /// payload) AND (b) eagerly uploaded the ORIGINAL RAW bytes to the
        /// file-server in their TRUE format (HEIC / PNG / DNG / JPEG, metadata
        /// intact) so the agent's tools act on the real file — NOT the downsized
        /// JPEG. The two payloads deliberately DIFFER: vision reads the processed
        /// JPEG, the agent's file tools read the original. `original` is the
        /// picked bytes (also kept so the strip thumbnail can render without
        /// re-decoding); `processedJPEG` is the inline-base64 + persisted-draft
        /// copy; `thumbnail`/`width`/`height`/`byteSize` are the processed-image
        /// metadata for the persisted draft; `filename` is the display name with
        /// the original's sniffed extension (e.g. `image.heic` / `image-2.png`),
        /// carried forward so the wire "saved as" splice names the file by its
        /// true format. The upload rides a determinate background PUT tracked in
        /// `serverUploadState`, but — unlike `.serverFile` — it NEVER blocks
        /// Send: the inline base64 is always available as a fallback, so at send
        /// time the storedKey is included only if the upload already landed
        /// (`.uploaded(key)`), else the image rides inline-only (NO auto-revert /
        /// NO degrade-to-inline state).
        case dualImage(original: Data, processedJPEG: Data, thumbnail: Data, width: Int, height: Int, byteSize: Int, filename: String)
        /// A security-scoped text/code file URL the VM extracts at send time.
        /// The INLINE-ONLY text route — used when the bound gateway has NO
        /// file-server configured (the extracted text rides the wire as a fenced
        /// block; today's behavior).
        case file(URL)
        /// A DUAL-route text/code file (file-transfer route + inline fenced text):
        /// the bound gateway has a file-server, so at staging the host (a)
        /// extracted the text ONCE (the INLINE/persist copy) AND (b) eagerly
        /// uploaded the ORIGINAL raw file bytes to the file-server so the agent's
        /// tools act on the real file — run / grep / transform — not just read the
        /// pasted text. Mirrors `.dualImage`. `url` is the picked file (kept so a
        /// Retry can re-upload from source); `extractedText` is the inline/persist
        /// copy; `filename` is the display name (chip label + the wire fence +
        /// "saved as …" line); `mimeType` is the UTType-derived text type. The
        /// upload rides a determinate background PUT in `serverUploadState`, but —
        /// unlike `.serverFile` — it NEVER blocks Send: the inline text is always
        /// a fallback, so at send time the storedKey is included only if the upload
        /// already landed (`.uploaded(key)`), else the file rides inline-only.
        case dualText(url: URL, extractedText: String, filename: String, mimeType: String)
        /// A NON-image arbitrary file (PDF / CSV / zip / …) bound for the agent's
        /// working folder via the file-server route. `url` is the user's picked
        /// file (the host keeps a security-scoped handle to it so a Retry can
        /// re-upload); `originalName` is its display name (chip label + the wire
        /// "saved as …" line); `mimeType` is its UTType-derived type. The actual
        /// bytes go up via a determinate background PUT tracked in
        /// `serverUploadState`, NOT inline on the wire. (Images take the
        /// `.dualImage` route instead — inline vision AND an editable file copy.)
        case serverFile(url: URL, originalName: String, mimeType: String)
        /// A NON-image binary file (PDF / video / zip / …) the user picked or
        /// dropped for a gateway that has NO file-server configured yet. There's
        /// no wire route for it (it can't ride inline, and there's no server to
        /// upload to), so it's a BLOCKING "needs file transfer" state: the strip
        /// shows an amber Set-Up tile, Send is gated (`hasNeedsSetupItem`), and the
        /// host AUTO-PROMOTES it to `.serverFile` (kicking the eager upload) once
        /// file transfer is set up for the bound gateway. `url` is the stable
        /// app-temp staging copy (kept so promotion can upload from it without a
        /// fresh pick); `originalName` is the chip label; `mimeType` is the
        /// UTType-derived type; `byteSize` drives the chip's size line + the
        /// >100 MB soft-confirm. NEVER rides the wire (`pendingAttachment` → nil).
        case needsSetup(url: URL, originalName: String, mimeType: String, byteSize: Int)
        /// The load failed — the strip shows an error badge; the user can
        /// remove the tile. Never reaches `sendUserTurn`.
        case failed
    }

    /// Eager-upload state — populated for a `.serverFile` OR `.dualImage` tile;
    /// nil for every other kind. The host mutates it as the background PUT
    /// advances.
    var serverUploadState: ServerFileUploadState?

    init(id: UUID = UUID(), kind: Kind, serverUploadState: ServerFileUploadState? = nil) {
        self.id = id
        self.kind = kind
        self.serverUploadState = serverUploadState
    }

    /// True while the bytes are still being fetched — gates Send.
    var isLoading: Bool {
        if case .loading = kind { return true }
        return false
    }

    /// True when the item failed to load — excluded from the sent payload.
    var isFailed: Bool {
        if case .failed = kind { return true }
        return false
    }

    /// True when this tile is a file-transfer server file (the file-server
    /// route) — drives the file-type-glyph tile + the upload-progress chrome.
    var isServerFile: Bool {
        if case .serverFile = kind { return true }
        return false
    }

    /// True when this tile is a DUAL-route image (inline vision + an eager
    /// file-server upload). Used to EXCLUDE this tile from the send-blocking
    /// helpers (`hasUploadingItem` / `hasFailedUpload`): a dual image has the
    /// inline base64 as a fallback, so its upload never gates Send — it rides
    /// the wire inline-only when the upload hasn't landed / failed.
    var isDualImage: Bool {
        if case .dualImage = kind { return true }
        return false
    }

    /// True when this tile is a DUAL-route text file (inline fenced text + an
    /// eager file-server upload). Used to EXCLUDE this tile from the send-blocking
    /// helpers (`hasUploadingItem` / `hasFailedUpload`): a dual text file has the
    /// inline extracted text as a fallback, so its upload never gates Send — it
    /// rides the wire inline-only when the upload hasn't landed / failed (exactly
    /// like `.dualImage`).
    var isDualText: Bool {
        if case .dualText = kind { return true }
        return false
    }

    /// True when this tile is a binary picked/dropped for a gateway with NO
    /// file-server configured — a BLOCKING "needs file transfer" state (no inline
    /// fallback, no server to upload to) that gates Send until the user sets up
    /// file transfer (the host then auto-promotes it to `.serverFile`).
    var needsSetup: Bool {
        if case .needsSetup = kind { return true }
        return false
    }

    /// True while a `.serverFile` tile's background PUT is in flight — gates
    /// Send (a turn cannot dispatch until every upload has landed).
    var isUploading: Bool {
        if case .uploading = serverUploadState { return true }
        return false
    }

    /// True when a `.serverFile` tile's upload failed fast — the strip shows
    /// Retry; the tile never rides the wire while failed, and it blocks Send.
    var serverUploadFailed: Bool {
        if case .failed = serverUploadState { return true }
        return false
    }

    /// Convert a resolved staged item into the VM's `PendingAttachment`. Nil for
    /// `.loading` / `.failed` (those never ride the wire). A `.serverFile` rides
    /// ONLY once its upload has landed — its `serverUploadState` must be
    /// `.uploaded(key)`, and the resolved `storedKey` is carried onto the wire;
    /// an `.uploading` / `.failed` / nil-state server tile returns nil (the host
    /// also gates Send on `hasUploadingItem` / `hasFailedUpload` so it can never
    /// be silently dropped from a dispatched turn).
    var pendingAttachment: PendingAttachment? {
        switch kind {
        case .image(let data): return .image(data)
        case .dualImage(_, let processedJPEG, let thumbnail, let width, let height, let byteSize, let filename):
            // ALWAYS rides the wire (inline base64 from `processedJPEG` is the
            // guaranteed fallback). The storedKey is carried ONLY if the eager
            // upload has already landed — `.uploaded(key)` → include inline + the
            // one-turn "saved as" ref; not-ready / failed / nil-state → inline-
            // only (storedKey: nil). No auto-revert: the upload never blocks Send.
            // `filename` (true-format display name) rides alongside so the wire
            // "saved as" line names the file by its real extension.
            let storedKey: String?
            if case .uploaded(let key) = serverUploadState { storedKey = key } else { storedKey = nil }
            return .dualImage(
                processedJPEG: processedJPEG,
                thumbnail: thumbnail,
                width: width,
                height: height,
                byteSize: byteSize,
                storedKey: storedKey,
                filename: filename
            )
        case .file(let url): return .textFile(url)
        case .dualText(let url, let extractedText, let filename, let mimeType):
            // ALWAYS rides the wire (the inline extracted text is the guaranteed
            // fallback). The storedKey is carried ONLY if the eager upload has
            // already landed — `.uploaded(key)` → inline fence + the "also on
            // disk" ref; not-ready / failed / nil-state → inline-only
            // (storedKey: nil). No auto-revert: the upload never blocks Send
            // (a `.dualText` tile is excluded from the send-gating helpers).
            let storedKey: String?
            if case .uploaded(let key) = serverUploadState { storedKey = key } else { storedKey = nil }
            return .dualText(
                url: url,
                extractedText: extractedText,
                filename: filename,
                mimeType: mimeType,
                storedKey: storedKey
            )
        case .serverFile(let url, let originalName, let mimeType):
            guard case .uploaded(let storedKey) = serverUploadState else { return nil }
            return .serverFile(url: url, originalName: originalName, mimeType: mimeType, storedKey: storedKey)
        // A `.needsSetup` tile has no wire route (no inline fallback, no server to
        // upload to). It NEVER rides the wire — it blocks Send (`hasNeedsSetupItem`)
        // until file transfer is set up and the host promotes it to `.serverFile`.
        case .needsSetup: return nil
        case .loading, .failed: return nil
        }
    }
}

extension Array where Element == StagedAttachment {
    /// True while any staged item is still loading — the host disables Send.
    var hasLoadingItem: Bool { contains { $0.isLoading } }

    /// True while any `.serverFile` tile's background PUT is still in flight —
    /// the host disables Send (the turn dispatches only after every upload has
    /// landed; strict send-gating). `.dualImage` AND `.dualText` tiles are
    /// EXCLUDED: a dual attachment's eager upload never blocks Send — the inline
    /// copy (base64 image / fenced text) is a guaranteed fallback, so an in-flight
    /// dual upload simply rides inline-only if it hasn't landed by send time
    /// (Send is never gated on a dual attachment). Only large/file-only
    /// `.serverFile` tiles block.
    var hasUploadingItem: Bool { contains { $0.isUploading && !$0.isDualImage && !$0.isDualText } }

    /// True while any `.serverFile` tile's upload failed — the host disables
    /// Send (the user must Retry or remove the failed tile first). `.dualImage`
    /// AND `.dualText` tiles are EXCLUDED: a failed dual upload does NOT block
    /// Send (the attachment rides inline-only, no Retry gate) — only arbitrary
    /// large/file-only server files block.
    var hasFailedUpload: Bool { contains { $0.serverUploadFailed && !$0.isDualImage && !$0.isDualText } }

    /// True while any tile is a binary picked/dropped for a gateway with NO
    /// file-server configured — the host disables Send (a BLOCKING state with no
    /// inline fallback and no upload target). The user either sets up file
    /// transfer (the host promotes the tile to `.serverFile` + uploads, clearing
    /// the gate) or removes the tile. Parallel to `hasUploadingItem` /
    /// `hasFailedUpload`.
    var hasNeedsSetupItem: Bool { contains { $0.needsSetup } }

    /// The resolved, sendable subset converted to `[PendingAttachment]` in
    /// staged order (loading + failed + still-uploading items are dropped).
    var pendingAttachments: [PendingAttachment] { compactMap { $0.pendingAttachment } }
}

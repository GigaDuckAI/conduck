// SPDX-License-Identifier: Apache-2.0

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
    /// The exact gateway whose file lane owns this staged server-side copy.
    ///
    /// This is intentionally attached to the tile itself rather than inferred
    /// from the composer's current picker value: uploads, retries, and orphan
    /// DELETEs can finish after the picker/view state has changed. Nil is valid
    /// only for inline-only/loading/failed tiles that never touched a file lane.
    var serverOwnerRef: RemoteAgentRef?
    /// The exact immutable file-lane configuration used to mint/upload this
    /// tile. A ref alone is insufficient: Settings can repoint the same gateway
    /// while an upload, retry, or late orphan cleanup is still running. Nil is
    /// valid for inline-only and `.needsSetup` tiles; every active server upload
    /// must carry this snapshot.
    var serverOwnerSnapshot: SettingsManager.FileTransferSnapshot?

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
        /// The upload was REFUSED for a reason a retry cannot change (a
        /// certificate this device won't accept, a rejected credential, a URL
        /// that isn't a file server). Carries the reason so the tile says what
        /// happened instead of showing a bare red badge, and the strip offers no
        /// Retry — an identical request against an identical refusal can only
        /// fail identically, and the spinner would bury the one sentence the
        /// user needs.
        ///
        /// TWO strings, because the tile and VoiceOver have opposite
        /// constraints. `reason` is the cause alone, for a ~180pt tile that
        /// clips at two lines. `detail` is cause AND remedy, for the tile's
        /// accessibility label, which has no width to run out of — and the
        /// remedy is the half that matters most: an untrusted certificate is
        /// fixed on the SERVER, and a pinned key that disagreed with a chain the
        /// system trusted carries the warning that the connection may be
        /// intercepted. Rendering only `reason` anywhere dropped that warning
        /// entirely.
        case refused(reason: String, detail: String)

        /// Classify a thrown upload error into the tile's failure state. The
        /// split rides `AppError.isRetryable` rather than a certificate special
        /// case, because it is the same question: a refused certificate, a
        /// rejected credential and a URL that isn't a file server are all
        /// terminal, and all three used to reach the user as an unlabelled red
        /// tile with a Retry chip that could only fail again. Anything else —
        /// including a non-`AppError` — keeps `.failed` + Retry.
        static func failure(for error: Error) -> Self {
            guard let appError = error as? AppError,
                  !appError.isRetryable,
                  let reason = appError.errorDescription else { return .failed }
            return .refused(reason: reason, detail: appError.descriptionWithRecovery())
        }

        /// Progress quantization, in buckets per unit. Whole percent: the only
        /// consumer is `AttachmentPreviewStrip`'s 110pt linear `ProgressView`, so
        /// a bucket is ~1pt of bar and anything finer moves no pixel.
        static let progressBuckets = 100.0

        /// The `.uploading` state to WRITE for `progress`, or `nil` when the
        /// rendered bar would not move and the write should be skipped.
        ///
        /// Load-bearing, not cosmetic. `URLSession` reports upload progress once
        /// per body-data callback — hundreds of times for a large file — and each
        /// write mutates the host's `@State` array, invalidating the whole
        /// composer and re-running the attachment strip's body. Quantizing caps
        /// that at `progressBuckets` mutations for the entire upload. (Tiles that
        /// render NO progress chrome at all — `.dualImage` / `.dualText` — skip
        /// the sink outright at the call site rather than quantizing.)
        ///
        /// TERMINAL-ABSORBING and MONOTONIC, both load-bearing. Each progress
        /// callback hops onto the main actor in its own unstructured `Task`, and
        /// those carry no FIFO guarantee — so a callback that lands late could
        /// otherwise overwrite a `.uploaded` / `.failed` / `.refused` with
        /// `.uploading` (the tile would drop its Retry chip, or a landed
        /// storedKey would appear to un-land), or drag a bar backwards. Requiring
        /// the current state to still BE `.uploading` and the bucket to be
        /// strictly greater makes both impossible without ordering the callbacks.
        /// The two roundings deliberately DIFFER, and mixing them up costs the
        /// whole saving. `progress` is a raw fraction, so its bucket is the one it
        /// has REACHED — floor. `shown` is a value this function itself wrote, so
        /// it is already an exact multiple of `1 / progressBuckets` in intent —
        /// but not in binary: `0.57 * 100` evaluates to `56.999999999999993`, and
        /// flooring that recovers 56, so bucket 57 would look unwritten and get
        /// written a second time. Rounding to NEAREST recovers the integer that
        /// was stored. (Measured: floor-on-both let 1001 callbacks through as 125
        /// writes instead of 100.)
        /// NOTE ON RETRY: this guard is monotonic WITHIN one upload attempt, and
    /// cannot be more than that on its own. Retry legitimately re-enters
    /// `.uploading(0)`, so a stale high-progress callback from the dead attempt
    /// still matches `.uploading` and still compares greater — it would be
    /// accepted, and would then block every genuine callback of the new attempt
    /// below it, freezing the bar until the upload passed the stale value.
    /// Distinguishing attempts needs an identity this state does not carry, so
    /// the callers own it: each `kickUpload` stamps an attempt number and drops
    /// callbacks that are not from the current one.
    static func nextUploading(from current: Self?, progress: Double) -> Self? {
            guard case .uploading(let shown)? = current else { return nil }
            let bucket = (min(max(progress, 0), 1) * progressBuckets).rounded(.down)
            let shownBucket = (min(max(shown, 0), 1) * progressBuckets).rounded()
            guard bucket > shownBucket else { return nil }
            return .uploading(progress: bucket / progressBuckets)
        }
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
        /// JPEG, the agent's file tools read the original. The original bytes are
        /// deliberately NOT an associated value: staging writes them to a
        /// throwaway temp file (tracked in the host's `serverStagingFiles`) and
        /// the upload reads that file, so carrying them here as well would pin a
        /// second full copy of every picked camera file — HEIC / ProRAW, tens of
        /// megabytes each — inside the composer's observed `@State` until Send,
        /// and hand the synthesized `Equatable` those buffers to compare on every
        /// strip diff. `processedJPEG` is the inline-base64 + persisted-draft
        /// copy; `thumbnail`/`width`/`height`/`byteSize` are the processed-image
        /// metadata for the persisted draft; `filename` is the name the user gave
        /// the picked file, and `ComposerImageName.unnamed` supplies a numbered
        /// `image…` name only where the source genuinely has none (a photo-library
        /// pick, a camera shot, a pasted bitmap). Only that fallback carries an
        /// extension sniffed from the original's bytes; a name the user supplied
        /// is passed through as given, extension included, so the wire "saved as"
        /// splice names the file the way the user does — the same rule a staged
        /// document follows. The upload rides a determinate background PUT tracked in
        /// `serverUploadState`, but — unlike `.serverFile` — it NEVER blocks
        /// Send: the inline base64 is always available as a fallback, so at send
        /// time the storedKey is included only if the upload already landed
        /// (`.uploaded(key)`), else the image rides inline-only (NO auto-revert /
        /// NO degrade-to-inline state).
        case dualImage(processedJPEG: Data, thumbnail: Data, width: Int, height: Int, byteSize: Int, filename: String)
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

    init(
        id: UUID = UUID(),
        kind: Kind,
        serverOwnerRef: RemoteAgentRef? = nil,
        serverOwnerSnapshot: SettingsManager.FileTransferSnapshot? = nil,
        serverUploadState: ServerFileUploadState? = nil
    ) {
        self.id = id
        self.kind = kind
        self.serverOwnerRef = serverOwnerRef
        self.serverOwnerSnapshot = serverOwnerSnapshot
        self.serverUploadState = serverUploadState
    }

    /// The name this tile shows and uploads under, or nil for a kind that has
    /// none (loading / failed / an inline-only image whose bytes arrived without
    /// a filename). Read by `ComposerImageName.unnamed` so a synthesized name is
    /// numbered around the names already on screen.
    var stagedFilename: String? {
        switch kind {
        case .dualImage(_, _, _, _, _, let filename): return filename
        case .dualText(_, _, let filename, _): return filename
        case .serverFile(_, let originalName, _): return originalName
        case .needsSetup(_, let originalName, _, _): return originalName
        case .file(let url): return url.lastPathComponent
        case .loading, .image, .failed: return nil
        }
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

    /// Whether this tile is safe to send through `ref`. Every kind that can
    /// carry a server `storedKey` (including a not-yet-configured binary) must
    /// retain an exact owner; inline-only kinds are gateway-independent.
    func serverOwnershipMatches(_ ref: RemoteAgentRef) -> Bool {
        switch kind {
        case .needsSetup:
            return serverOwnerRef == ref
        case .dualImage, .dualText, .serverFile:
            return serverOwnerRef == ref && serverOwnerSnapshot != nil
        case .loading, .image, .file, .failed:
            return true
        }
    }

    /// True while a `.serverFile` tile's background PUT is in flight — gates
    /// Send (a turn cannot dispatch until every upload has landed).
    var isUploading: Bool {
        if case .uploading = serverUploadState { return true }
        return false
    }

    /// True when a `.serverFile` tile's upload did not land — retryable or
    /// refused. The tile never rides the wire in either state, and both block
    /// Send: a refusal is not a reason to let the turn go out without the file.
    var serverUploadFailed: Bool {
        switch serverUploadState {
        case .failed, .refused: return true
        case .uploading, .uploaded, .none: return false
        }
    }

    /// True only for the RETRYABLE failure. `.refused` is deliberately excluded:
    /// re-issuing the identical request against the identical refusal spends the
    /// user's tap to reach the same verdict.
    var serverUploadRetryable: Bool {
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
        case .dualImage(let processedJPEG, let thumbnail, let width, let height, let byteSize, let filename):
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

/// Which conversation folder a composer's file-server keys are minted under.
///
/// A composer stages attachments before the conversation row exists, so the
/// bound view model is nil for the whole of a new chat's first turn. Every mint
/// path therefore resolves the folder through here against the composer's
/// pre-minted `pendingConversationID` — the identifier the host later hands to
/// `ConversationStore.createConversation(id:backend:)`, so the row adopts the
/// folder its files are already in.
///
/// ONE helper for every path — the two composers' `mintStoredKey`, the two
/// `TextAttachmentStagePreparer.prepare` call sites, the needs-setup promotion
/// and the upload-retry fallback — because a path that resolves the folder its
/// own way splits one turn's files across two folders on the user's server.
enum ComposerMintFolder {
    /// The conversation identifier this composer's keys belong to: the bound
    /// conversation when one exists, else the identifier the composer already
    /// committed to for the chat it is about to mint.
    static func conversationID(bound: UUID?, pending: UUID) -> UUID {
        bound ?? pending
    }

    /// The `folder` argument for `FileServerClient.makeStoredKey`. Nil only when
    /// the gateway's nested-PUT probe failed, which is the one case where a key
    /// must stay flat at the served root.
    static func storedKeyFolder(bound: UUID?, pending: UUID, folderCapable: Bool) -> String? {
        guard folderCapable else { return nil }
        return conversationID(bound: bound, pending: pending).uuidString
    }
}

/// Names for an image whose source never gave it one — a photo-library pick
/// (`PhotosPickerItem` vends bytes, not a filename), a camera shot, a pasted
/// bitmap. A file the user picked or dropped keeps its own name and never comes
/// here.
enum ComposerImageName {
    /// The name a staged image tile takes: the user's own, whenever the source
    /// carried one, exactly as a staged document does.
    static func resolve(
        originalName: String?,
        extension ext: String,
        staged: [StagedAttachment]
    ) -> String {
        if let originalName {
            let trimmed = originalName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return unnamed(extension: ext, avoiding: Set(staged.compactMap(\.stagedFilename)))
    }

    /// The first unused `image.<ext>` / `image-N.<ext>` for this strip.
    ///
    /// Numbered around the names already staged rather than from a count of
    /// them: a count recomputed from the live array repeats a label the moment
    /// an earlier tile is removed, leaving two tiles claiming to be the same
    /// file.
    static func unnamed(extension ext: String, avoiding taken: Set<String>) -> String {
        let first = "image.\(ext)"
        guard taken.contains(first) else { return first }
        var index = 2
        while taken.contains("image-\(index).\(ext)") { index += 1 }
        return "image-\(index).\(ext)"
    }
}

/// Pure identity verdict shared by the iOS/iPadOS button + keyboard host and
/// the macOS window host. Nil owns only the genuine new-chat state; it is not a
/// wildcard for whichever same-gateway conversation happens to be visible
/// when an asynchronous submission resumes.
enum ComposerDispatchOwnership {
    static func matches(
        sealedConversationID: UUID?,
        activeConversationID: UUID?
    ) -> Bool {
        sealedConversationID == activeConversationID
    }
}

/// Post-mint ownership verdict for a composer that started in the genuine
/// new-chat state. Conversation creation suspends; while it is in flight the
/// user can select an existing conversation. The fresh empty row may be
/// adopted only if the host is STILL new-chat when creation returns. Otherwise
/// the host deletes that unused mint and leaves the user's newer selection
/// untouched.
enum ComposerMintOwnership {
    enum Resolution: Equatable {
        case adoptFreshConversation
        case discardFreshConversation
    }

    static func resolve(
        sealedConversationID: UUID?,
        activeConversationIDAfterMint: UUID?
    ) -> Resolution {
        guard sealedConversationID == nil,
              activeConversationIDAfterMint == nil else {
            return .discardFreshConversation
        }
        return .adoptFreshConversation
    }
}

/// Gateway + conversation identity captured as one immutable routing decision.
/// A nil conversation belongs only to the genuine new-chat composer. Keeping
/// the pair together prevents an asynchronous upload join from combining the
/// gateway resolved for conversation A with conversation B's later selection.
struct ComposerDispatchRoute: Equatable, Sendable {
    let ref: RemoteAgentRef
    let conversationID: UUID?
}

/// SwiftUI identity for the macOS composer's attachment-owning mount. Active
/// conversations deliberately get distinct identities so an A → B navigation
/// tears down A's local staging state; new chat remains a separate VM-less
/// identity whose accepted first turn may mint naturally.
enum ComposerMountIdentity: Hashable {
    case newChat
    case conversation(UUID)
}

/// Shared deferred-teardown latch for composer navigation/disappearance. A
/// teardown request during dispatch cannot mutate attachment ownership
/// immediately: local acceptance may already have handed the sealed storedKeys
/// to a message. The host first performs successful handoff cleanup (if any),
/// then consumes this latch at dispatch end; a rejected send therefore discards
/// the still-unsent sealed items, while an accepted send never deletes its keys.
struct ComposerDeferredTeardown {
    private(set) var isPending = false

    /// Returns true when teardown can run immediately. During dispatch it only
    /// records the request and returns false.
    mutating func request(whileDispatching: Bool) -> Bool {
        guard whileDispatching else { return true }
        isPending = true
        return false
    }

    /// Consume the one-shot deferred request at dispatch completion.
    mutating func consume() -> Bool {
        let pending = isPending
        isPending = false
        return pending
    }
}

/// Can a server-reference chip address its bytes AT ALL — before any question
/// of whether the lane is currently reachable?
///
/// A GET needs two things that both live on the message: the opaque `storedKey`
/// naming the blob, and the durable lane that minted it (the credential the GET
/// authenticates with). Missing EITHER makes the file unaddressable, and the
/// two failure shapes are equally common: a cross-lane clone clears the key, and
/// a legacy/partially-synced row can carry a key with no provable owner.
/// Without this gate such a chip stays tappable and falls through to a red
/// "File transfer isn't set up for this gateway" — a dead tap under a claim
/// that is very often false (the gateway's file transfer may be perfectly fine;
/// it is THIS row that has nothing to point at).
///
/// Deliberately separate from `FileTransferLaneOwnership.matches`, which asks
/// the LATER question of whether the owning lane is the one configured now.
enum ServerFileChipAvailability {
    static func isAddressable(storedKey: String?, ownerLaneID: String?) -> Bool {
        guard let storedKey, !storedKey.isEmpty else { return false }
        guard let ownerLaneID, !ownerLaneID.isEmpty else { return false }
        return true
    }
}

/// Exact file-lane verdict used by download chips. Both sides must be present;
/// a legacy nil owner is unprovable and always fails closed.
enum FileTransferLaneOwnership {
    static func matches(expectedLaneID: String?, currentLaneID: String?) -> Bool {
        guard let expectedLaneID, let currentLaneID else { return false }
        return expectedLaneID == currentLaneID
    }

    /// Existing blobs remain operable when a later Test Connection verdict
    /// marks the otherwise unchanged lane unavailable. Readiness gates NEW
    /// uploads/output promises; it must not brick a key already owned by this
    /// exact durable lane.
    static func canAccessExistingBlob(
        expectedLaneID: String?,
        snapshot: SettingsManager.FileTransferSnapshot?
    ) -> Bool {
        matches(
            expectedLaneID: expectedLaneID,
            currentLaneID: snapshot?.durableLaneID
        )
    }

    /// Same physical configured lane, ignoring only mutable readiness/capability
    /// verdicts. Used at the final background-request enqueue boundary.
    static func samePhysicalLane(
        captured: SettingsManager.FileTransferSnapshot,
        current: SettingsManager.FileTransferSnapshot?
    ) -> Bool {
        guard let current else { return false }
        return current.durableLaneID == captured.durableLaneID
            && current.identitySignature == captured.identitySignature
    }
}

/// Immutable hand-off from a composer to the conversation host. It captures
/// the logical gateway once and, when a landed server reference is present,
/// the exact durable file lane that owns those keys.
struct ComposerTurnDispatch: Sendable {
    let text: String
    let attachments: [PendingAttachment]
    let ref: RemoteAgentRef
    let fileLaneID: String?
    /// Established conversation identity sealed by the composer. Nil is valid
    /// only for a genuine new-chat mint.
    let conversationID: UUID?
    /// The identifier the composer already minted its file-server keys under.
    ///
    /// A SEPARATE field from `conversationID`, never a substitute for it:
    /// `conversationID` is the nil-means-new-chat sentinel that
    /// `ComposerDispatchOwnership.matches` and `ComposerMintOwnership.resolve`
    /// branch on, so putting a pre-minted identifier there would make every
    /// new-chat send read as a conversation switch — rejected, and the fresh row
    /// deleted. A host that mints a conversation for this dispatch passes this
    /// value to `ConversationStore.createConversation(id:backend:)`; a host that
    /// appends to an established conversation ignores it.
    let pendingConversationID: UUID
    /// Per-composer staging generation captured with the exact item ids. Hosts
    /// treat this as opaque ownership evidence; no credential/config enters it.
    let stagingGeneration: UUID
    let stagedAttachmentIDs: Set<UUID>
    /// Local staged-item identities whose uploaded server keys were frozen into
    /// `attachments` above. Cleanup must use this captured set, not the tile's
    /// later live upload state: a preferred upload can land after dispatch was
    /// sealed but before local persistence accepts the turn, and that late key
    /// was never handed off.
    let handedOffServerAttachmentIDs: Set<UUID>

    init(
        text: String,
        attachments: [PendingAttachment],
        ref: RemoteAgentRef,
        fileLaneID: String?,
        handedOffServerAttachmentIDs: Set<UUID>,
        conversationID: UUID?,
        pendingConversationID: UUID,
        stagingGeneration: UUID,
        stagedAttachmentIDs: Set<UUID>
    ) {
        self.text = text
        self.attachments = attachments
        self.ref = ref
        self.fileLaneID = fileLaneID
        self.conversationID = conversationID
        self.pendingConversationID = pendingConversationID
        self.stagingGeneration = stagingGeneration
        self.stagedAttachmentIDs = stagedAttachmentIDs
        self.handedOffServerAttachmentIDs = handedOffServerAttachmentIDs
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

    /// Fail-closed send guard for a staged collection. The new-chat gateway
    /// picker is locked while attachments exist, but this remains the final
    /// defense against programmatic/state-restoration drift.
    func serverOwnershipMatches(_ ref: RemoteAgentRef) -> Bool {
        allSatisfy { $0.serverOwnershipMatches(ref) }
    }

    /// Seal the staged collection for one dispatch. Fails closed if a server
    /// tile lost its owner snapshot, targets another gateway, or mixes landed
    /// stored keys from different durable lanes.
    func makeDispatch(
        text: String,
        ref: RemoteAgentRef,
        conversationID: UUID?,
        pendingConversationID: UUID,
        stagingGeneration: UUID
    ) -> ComposerTurnDispatch? {
        guard serverOwnershipMatches(ref) else { return nil }

        var landedLaneIDs = Set<String>()
        var handedOffServerAttachmentIDs = Set<UUID>()
        for item in self {
            guard case .uploaded? = item.serverUploadState else { continue }
            guard let snapshot = item.serverOwnerSnapshot else { return nil }
            landedLaneIDs.insert(snapshot.durableLaneID)
            handedOffServerAttachmentIDs.insert(item.id)
        }
        guard landedLaneIDs.count <= 1 else { return nil }

        return ComposerTurnDispatch(
            text: text,
            attachments: pendingAttachments,
            ref: ref,
            fileLaneID: landedLaneIDs.first,
            handedOffServerAttachmentIDs: handedOffServerAttachmentIDs,
            conversationID: conversationID,
            pendingConversationID: pendingConversationID,
            stagingGeneration: stagingGeneration,
            stagedAttachmentIDs: Set(map(\.id))
        )
    }

    /// Route-paired overload used by async composer paths. The gateway and
    /// conversation were captured together before any upload join, so callers
    /// cannot accidentally seal a live post-await conversation with a stale ref.
    func makeDispatch(
        text: String,
        route: ComposerDispatchRoute,
        pendingConversationID: UUID,
        stagingGeneration: UUID
    ) -> ComposerTurnDispatch? {
        makeDispatch(
            text: text,
            ref: route.ref,
            conversationID: route.conversationID,
            pendingConversationID: pendingConversationID,
            stagingGeneration: stagingGeneration
        )
    }

    /// The resolved, sendable subset converted to `[PendingAttachment]` in
    /// staged order (loading + failed + still-uploading items are dropped).
    var pendingAttachments: [PendingAttachment] { compactMap { $0.pendingAttachment } }
}

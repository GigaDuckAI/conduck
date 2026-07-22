// Conduck
// ComposerAttachmentCoordinator.swift
//
// The shared host-side attachment plumbing for the iOS composer. Both
// hosts (ContentView/iPhone and ConversationLibraryView/iPad) own IDENTICAL
// staging logic — PhotosPicker + fileImporter + camera cover + the staged
// collection + the staged→PendingAttachment conversion. Rather than duplicate
// all of that in two views, both mount the `iOSMessageComposerBar` inside this
// `@Observable` coordinator's modifiers via the `composerWithAttachments`
// helper.
//
// Picker loading uses `PhotosPickerItem.loadTransferable(type: Data.self,
// completionHandler:)` — the PROGRESS overload — so each in-flight library
// fetch updates the strip's determinate bar; on completion the same staged tile
// is swapped in place from `.loading` to `.image` (or `.failed`). Send is
// disabled by the composer while any item is `.loading` (partial-payload
// guard). No `maxSelectionCount` is set on the picker — no cap (locked).
//
// UTType set: ONE unified "Choose Files…" importer accepts everything; the
// classifier (not the picker) decides routing. iOS-only.

#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum ComposerAttachmentTypes {
    /// Allowed content types for the UNIFIED "Choose Files…" importer — accepts
    /// ANY FILE the host's classifier can route (image → inline; text → inline/
    /// dual; binary → server or `.needsSetup`). The broad `.content`/`.data`
    /// supertypes ensure no file is greyed out (the old text-only set greyed
    /// PDFs/videos); `.audiovisualContent`/`.movie` make videos selectable;
    /// `.image` is included so a picked image still routes to inline vision.
    /// `.item` is deliberately ABSENT — it admits FOLDERS (`public.folder` →
    /// `public.item`), which the file-to-file staging copy would recursively
    /// duplicate into tmp and the upload could never send.
    static let unifiedContentTypes: [UTType] = [
        .content, .data, .image,
        .audiovisualContent, .movie,
        .pdf, .archive, .spreadsheet, .presentation,
        .commaSeparatedText, .json, .plainText, .rtf, .sourceCode,
    ]
}

/// Owns the staged-attachment collection + the in-flight PhotosPicker selection
/// and per-item load progress. `@Observable` so the composer + strip re-render
/// as items resolve. One instance per host (created as `@State`).
@Observable
@MainActor
final class ComposerAttachmentCoordinator {
    /// Staged-but-unsent attachments (mirrors the composer's `attachments`).
    var staged: [StagedAttachment] = []
    /// Per-loading-item determinate progress (0…1) for the strip.
    var progressByID: [UUID: Double] = [:]

    /// PhotosPicker binding target — cleared after each batch is consumed.
    var pickerSelection: [PhotosPickerItem] = []
    /// Unified "Choose Files…" importer presentation flag (accepts any file).
    var showingFileImporter = false
    /// Camera cover presentation flag (iOS, camera available + authorized).
    var showingCamera = false
    /// Camera-denied inline alert flag.
    var showingCameraDeniedAlert = false

    /// Pending large-file soft-confirm (Decision C / `Constants.fileTransferSoftConfirmBytes`).
    /// When a picked/dropped binary exceeds the soft threshold the host renders an
    /// alert naming the file + formatted size; Confirm proceeds to stage it,
    /// Cancel discards it. Multiple large files queue in `pendingLargeFiles` and
    /// are presented one at a time (rare). PRIVACY: holds the staging URL only
    /// in-memory; never logged.
    struct PendingLargeFile: Identifiable, Equatable {
        let id = UUID()
        let stagingURL: URL
        let originalName: String
        let mimeType: String
        let byteSize: Int
        /// The gateway this file would route to (drives `.serverFile` vs
        /// `.needsSetup` once the user confirms). The server-presence flag is
        /// deliberately NOT cached here — setup can complete while the alert is
        /// up (remote sync), so the confirm path re-resolves the snapshot fresh.
        let ref: RemoteAgentRef
    }

    /// FIFO queue of large files awaiting the user's soft-confirm. The head is the
    /// one the host's alert is currently asking about (`pendingLargeFile`).
    private var pendingLargeFiles: [PendingLargeFile] = []

    /// The large file the host's soft-confirm alert is currently presenting (the
    /// queue head), or nil when none is pending. The host binds an `.alert` to
    /// `pendingLargeFile != nil`.
    var pendingLargeFile: PendingLargeFile? { pendingLargeFiles.first }

    /// In-flight eager-upload tasks keyed by the staged item's id, so the X
    /// overlay can cancel one + a Retry can re-kick one. The task itself mutates
    /// `staged[…].serverUploadState` as the PUT advances. PRIVACY: keyed by UUID
    /// only — never holds (or logs) the file URL / storedKey.
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    /// Stable app-temp staging files (one per staged server item, keyed by item
    /// id), copied from the user's security-scoped pick so the async upload +
    /// send both read a plain file. Cleaned up on remove / after the turn clears.
    private var serverStagingFiles: [UUID: URL] = [:]
    /// The minted storedKey per staged server item (keyed by item id), so a
    /// Retry re-uploads under the SAME key — overwriting the failed partial blob
    /// rather than orphaning it under a fresh key. PRIVACY: in-memory only.
    private var serverStoredKeys: [UUID: String] = [:]
    /// The gateway each `.needsSetup` tile was STAGED for (keyed by item id).
    /// Promotion only fires when this matches the promote-time ref — staged tiles
    /// survive conversation switches, so without the stamp a tile staged for an
    /// unconfigured gateway A would silently upload to whatever configured
    /// gateway B the user switched to (and A's later turn would reference a key
    /// that only exists on B). The VM-less new-chat composer RE-STAMPS on a
    /// gateway-picker change instead (the next turn definitionally binds there).
    private var needsSetupRefs: [UUID: RemoteAgentRef] = [:]

    // MARK: - Menu actions

    func pickLibrary() {
        // PhotosPicker is presented via the `.photosPicker` modifier bound to
        // a flag; we flip it through a dedicated trigger so a re-pick re-opens.
        showingPhotosPicker = true
    }

    var showingPhotosPicker = false

    /// Open the UNIFIED "Choose Files…" importer (accepts any file; the host's
    /// classifier routes each pick).
    func pickFiles() { showingFileImporter = true }

    func takePhoto() {
        switch CameraPermission.current {
        case .proceed: showingCamera = true
        case .denied: showingCameraDeniedAlert = true
        }
    }

    /// Remove a staged item by id. For a server-file or uploaded dual-image tile
    /// this ALSO cancels its in-flight upload, best-effort DELETEs an
    /// already-uploaded orphan blob, and deletes the local staging temp file — so
    /// a user X-cancel never leaves an orphan on the gateway. `vm` + `ref` are
    /// needed only for the orphan DELETE;
    /// nil → a plain non-server remove (the menu callers pass them when the bound
    /// gateway + VM are known).
    func remove(_ id: UUID, vm: ConversationDetailViewModel? = nil, ref: RemoteAgentRef? = nil) {
        // Cancel an in-flight upload + reclaim its staging file.
        if let task = uploadTasks[id] {
            task.cancel()
            uploadTasks[id] = nil
        }
        // If the upload already landed, best-effort delete the orphan blob. Only
        // `.serverFile` and `.dualImage` ever set `serverUploadState`, so gating
        // on `.uploaded` alone covers BOTH routes — a tile X-removed after its PUT
        // landed is a pure orphan the user never sent (symmetry with `.serverFile`).
        // Needs only the ref (static helper), so a VM-less new chat cleans up too.
        if let item = staged.first(where: { $0.id == id }),
           case .uploaded(let storedKey)? = item.serverUploadState,
           let ref {
            Task { await ConversationDetailViewModel.deleteOrphanServerFile(storedKey: storedKey, ref: ref) }
        }
        cleanupStagingFile(id)
        staged.removeAll { $0.id == id }
        progressByID[id] = nil
    }

    func clear() {
        // Cancel any in-flight uploads + reclaim every server staging temp file.
        for task in uploadTasks.values { task.cancel() }
        uploadTasks.removeAll()
        for url in serverStagingFiles.values { try? FileManager.default.removeItem(at: url) }
        serverStagingFiles.removeAll()
        serverStoredKeys.removeAll()
        needsSetupRefs.removeAll()
        // Reclaim any not-yet-confirmed large-file staging temps too.
        for file in pendingLargeFiles { try? FileManager.default.removeItem(at: file.stagingURL) }
        pendingLargeFiles.removeAll()
        staged.removeAll()
        progressByID.removeAll()
        pickerSelection.removeAll()
    }

    /// Delete + forget the local staging temp file for `id` (best-effort).
    private func cleanupStagingFile(_ id: UUID) {
        serverStoredKeys[id] = nil
        needsSetupRefs[id] = nil
        if let url = serverStagingFiles[id] {
            try? FileManager.default.removeItem(at: url)
            serverStagingFiles[id] = nil
        }
    }

    // MARK: - Camera

    func stageCameraImage(_ data: Data, vm: ConversationDetailViewModel?, ref: RemoteAgentRef) {
        Task { await stageImage(data, vm: vm, ref: ref) }
    }

    // MARK: - Image staging (dual-route when a file-server is configured)

    /// Stage a composer image (library / camera / drop). When the bound gateway
    /// has a file-server AND `ImageProcessor` succeeds, this is the DUAL route
    /// (Approach C): process the image ONCE here (downsized + EXIF/GPS-stripped
    /// JPEG, the INLINE/persist copy), stage a `.dualImage` tile in
    /// `.uploading(0)`, and eagerly upload the ORIGINAL RAW bytes — the exact
    /// picked file in its TRUE format (HEIC / PNG / DNG / JPEG, metadata intact),
    /// NOT the processed JPEG — so the agent's tools act on the real file.
    /// Otherwise fall back to the INLINE-ONLY `.image(original)` tile (unchanged
    /// behaviour).
    ///
    /// The two payloads deliberately DIFFER: the inline base64 + bubble + Core
    /// Data draft all carry the downsized processed JPEG (vision is happy with
    /// 0.7-quality 1568px); the file-server gets the untouched original (the
    /// agent may need full resolution / true format / camera metadata).
    ///
    /// Send is NEVER gated on the image upload: a `.dualImage` tile is excluded
    /// from `hasUploadingItem` / `hasFailedUpload`. If the upload lands by send
    /// time the storedKey rides as a one-turn "saved as <filename>" ref; if not /
    /// failed, the image rides inline-only (NO degrade-to-inline / NO auto-revert
    /// state).
    ///
    /// PRIVACY: the upload name is SYNTHETIC by POSITION ("image.<ext>" /
    /// "image-N.<ext>") — never a real filename; only the original's true
    /// EXTENSION (sniffed from its bytes) is carried, so the agent's tooling
    /// knows the real format. The processed JPEG (inline) already has EXIF/GPS
    /// stripped; the uploaded original keeps its metadata (the user PUTs it to
    /// their OWN server, deliberately).
    func stageImage(_ original: Data, vm: ConversationDetailViewModel?, ref: RemoteAgentRef) async {
        // No READY file-server (unconfigured, untested, or failed its test) →
        // inline-only. WHY no `let vm`
        // gate: a VM-less brand-new conversation STILL dual-routes — `mintStoredKey`
        // yields a FLAT storedKey (folder:nil) when vm==nil and the binary path
        // already uploads VM-less, so the spec gives images no VM-less carve-out.
        // Gating on `let vm` here wrongly short-circuited the FIRST image turn to
        // inline-only and never uploaded the byte-faithful original.
        guard await SettingsManager.shared.fileTransferReadySnapshot(for: ref) != nil else {
            staged.append(StagedAttachment(kind: .image(original)))
            return
        }
        // Process ONCE at staging for the INLINE/persist copy. A processing
        // failure is NOT fatal — fall back to the inline-only path so the image
        // still rides vision (the VM re-processes a plain `.image`).
        guard let processed = try? await ImageProcessor.shared.process(original, maxPixel: ImageProcessor.defaultMaxPixel) else {
            staged.append(StagedAttachment(kind: .image(original)))
            return
        }

        // Sniff the ORIGINAL bytes for their true format. The position-based
        // synthetic name (`image` / `image-N`) carries no user filename; the
        // sniffed extension makes the uploaded file land on the user's server
        // with its real type so the agent's tooling treats it correctly.
        let format = ImageFormatSniffer.sniff(original)
        let position = staged.filter(\.isDualImage).count
        let filename = position == 0 ? "image.\(format.ext)" : "image-\(position + 1).\(format.ext)"
        // Per-conversation folder unless this gateway's nested-PUT probe failed.
        let storedKey = await Self.mintStoredKey(originalName: filename, vm: vm, ref: ref)
        // Write the ORIGINAL bytes (not the processed JPEG) to a throwaway temp
        // file under the sniffed extension — `uploadServerFile` copies it again
        // before handing the copy to the background driver (which DELETES its
        // input), so this source temp survives the upload; we reclaim it after
        // the upload resolves / the tile is removed.
        // sim-QA verified: the upload body is the ORIGINAL file (true format,
        // metadata intact), distinct from the inline `processedJPEG` — the
        // background-URLSession path has no clean unit seam for asserting the
        // written bytes, so it's covered by sim QA, not XCTest (the wire/filename
        // splitting IS unit-tested in ConverseWireTests + ImageFormatSnifferTests).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-imgupload-\(UUID().uuidString).\(format.ext)")
        // WHY off-main: writing up to 100 MB of original image bytes atomically can
        // BLOCK the main actor on a slow/full/external volume (`original: Data` is
        // Sendable, so the write hops off-main cleanly). Tile append + storedKey
        // stamping below stay on the MainActor. A write failure is NOT fatal — fall
        // back to inline-only (unchanged).
        do {
            try await Task.detached { try original.write(to: tmp, options: .atomic) }.value
        } catch {
            staged.append(StagedAttachment(kind: .image(original)))
            return
        }

        let item = StagedAttachment(
            kind: .dualImage(
                original: original,
                processedJPEG: processed.jpegData,
                thumbnail: processed.thumbnailData,
                width: processed.width,
                height: processed.height,
                byteSize: processed.byteSize,
                filename: filename
            ),
            serverUploadState: .uploading(progress: 0))
        let id = item.id
        staged.append(item)
        serverStagingFiles[id] = tmp
        serverStoredKeys[id] = storedKey
        kickImageUpload(id: id, localURL: tmp, storedKey: storedKey, ref: ref)
    }

    /// Eager upload for a `.dualImage` tile — modeled on `kickUpload` but on
    /// FAILURE just sets `.failed` (NO degrade-to-inline): the image already
    /// rides inline, so a failed upload simply means no editable file copy this
    /// turn. On success → `.uploaded(storedKey)` (the one-turn ref will splice).
    private func kickImageUpload(
        id: UUID,
        localURL: URL,
        storedKey: String,
        ref: RemoteAgentRef
    ) {
        let task = Task { @MainActor [weak self] in
            do {
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, ref: ref) { progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                        self.staged[i].serverUploadState = .uploading(progress: progress)
                    }
                }
                guard let self, let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                self.staged[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                // Upload failed → mark `.failed`. Does NOT block Send (a
                // `.dualImage` tile is excluded from the send-gating helpers); the
                // image rides inline-only this turn. NO silent retry, NO revert.
                guard let self, let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                self.staged[i].serverUploadState = .failed
            }
            self?.uploadTasks[id] = nil
        }
        uploadTasks[id] = task
    }

    // MARK: - File importer

    /// Handle a UNIFIED "Choose Files…" pick (any type). Routes EACH url through
    /// the classifier so a pick lands the same way regardless of source:
    ///   - image → `stageImage` (inline vision; dual when a file-server exists);
    ///   - text/code → `stageTextFile` (inline / dual / large server-file);
    ///   - binary → server upload (configured gateway) OR a `.needsSetup` tile
    ///     (unconfigured gateway), with the >100 MB soft-confirm.
    /// `vm` may be nil (brand-new conversation before the first turn) — the
    /// classifier handles it: images/text stage inline, a binary still uploads
    /// eagerly under a FLAT storedKey (no conversation folder exists yet) when the
    /// gateway has a file-server, else stages a `.needsSetup` tile.
    func handleUnifiedImport(_ result: Result<[URL], Error>, vm: ConversationDetailViewModel?, ref: RemoteAgentRef) {
        guard case .success(let urls) = result else { return }
        stageServerFiles(urls, vm: vm, ref: ref)
    }

    // MARK: - Text-file staging (dual-route when a file-server is configured)

    /// Stage one picked/dropped text-or-code file via `AttachmentDeliveryPlanner`.
    /// Extracts the text ONCE here (the inline/persist copy + the size the planner
    /// routes by), then:
    ///   - no file-server / no VM / extraction fails → inline-only `.file(url)`
    ///     (today's behavior — no regression);
    ///   - server + small (planner `inline:true`) → `.dualText` tile in
    ///     `.uploading(0)` + eager background PUT of the RAW file bytes (so the
    ///     agent's tools act on the real file), never gates Send;
    ///   - server + large / over budget (planner `inline:false`, `.required` or
    ///     `.preferred`) → `.serverFile` tile (file-only, strict send-gating for
    ///     `.required`; a `.preferred`-but-over-budget small file also uploads,
    ///     but as a dual tile so Send isn't gated — see below).
    ///
    /// Route is decided by EXTRACTED UTF-8 byte count, not raw file size. The
    /// per-turn inline budget is consulted via the live `staged` inline total so a
    /// turn that staples many small files demotes the overflow to ref-only.
    func stageTextFile(_ url: URL, extracted precomputed: TextFileExtractor.ExtractedFile? = nil, vm: ConversationDetailViewModel?, ref: RemoteAgentRef?) async {
        // Resolve file-server READINESS up front (drives the planner; a saved-
        // but-failed server routes inline-only, like no server). No VM →
        // no eager-upload capability → inline-only regardless.
        let snapshot: SettingsManager.FileTransferSnapshot?
        if let vm, let ref {
            snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
        } else {
            snapshot = nil
        }

        // Extract ONCE (the inline/persist copy + the planner's routing size). The
        // caller (`stageServerFiles`) already ran the extraction OFF-main as its
        // text-vs-binary probe and threads the result in, so the file is never read
        // twice; when it isn't provided we extract HERE, also OFF-main — it's a
        // WHOLE-FILE read + UTF-8 decode that BLOCKS on an iCloud-not-downloaded /
        // external volume (`TextFileExtractor.extract` is `nonisolated` + brackets
        // its OWN security scope, so it is safe from a detached task). A failed
        // extraction is NOT fatal — stage inline-only `.file` so the VM's existing
        // `.textFile` path re-tries at send time (historic behavior).
        let resolved: TextFileExtractor.ExtractedFile?
        if let precomputed {
            resolved = precomputed
        } else {
            resolved = await Task.detached { try? TextFileExtractor.extract(from: url) }.value
        }
        guard let extracted = resolved else {
            staged.append(StagedAttachment(kind: .file(url)))
            return
        }
        let byteCount = extracted.text.lengthOfBytes(using: .utf8)

        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: byteCount,
            fileServerPresent: snapshot != nil,
            inlineBudgetRemaining: inlineTextBudgetRemaining
        )

        // No server copy → inline-only `.file` (unchanged path).
        guard plan.serverCopy != .none, let vm, let ref else {
            staged.append(StagedAttachment(kind: .file(url)))
            return
        }

        if plan.inline {
            // DUAL: inline fenced text NOW + eager upload of the raw file bytes.
            // Copy the picked bytes UNDER scope to a stable temp so the async
            // upload + a later Retry both read a plain file (the picked scope may
            // not outlive the upload). The temp is reclaimed on remove / clear.
            // WHY off-main: the file-to-file copy BLOCKS on an iCloud-not-downloaded
            // / external / network volume (security scope is process-wide, so the
            // whole bracketed copy is correct in one detached call).
            guard let stagingURL = await Task.detached { Self.copyUnderScope(url) }.value else {
                // Couldn't copy the source — fall back to inline-only `.file`.
                staged.append(StagedAttachment(kind: .file(url)))
                return
            }
            let item = StagedAttachment(
                kind: .dualText(
                    url: stagingURL,
                    extractedText: extracted.text,
                    filename: extracted.filename,
                    mimeType: extracted.mimeType
                ),
                serverUploadState: .uploading(progress: 0))
            let id = item.id
            staged.append(item)
            serverStagingFiles[id] = stagingURL

            let storedKey = await Self.mintStoredKey(originalName: extracted.filename, vm: vm, ref: ref)
            serverStoredKeys[id] = storedKey
            kickDualUpload(id: id, localURL: stagingURL, storedKey: storedKey, ref: ref)
        } else {
            // FILE-ONLY (`inline:false`): the extracted text does NOT ride inline.
            // Both the large (`.required`) case and the small-but-over-budget
            // (`.preferred`) case land here — in both the inline copy is suppressed
            // on the wire and the file rides as a `.serverFile` tile (the agent's
            // tools reach the real bytes). A `.required` large file SHOULD gate
            // Send (no inline fallback exists for it); a `.preferred`-over-budget
            // small file also routes here for simplicity — an over-budget turn
            // already carries ≥`textInlineTurnBudgetBytes` of inline text, so
            // gating on its small overflow upload is acceptable. (The common dual
            // case — small + within budget — is the `plan.inline` branch above and
            // never gates Send.)
            // Off-main copy (BLOCKS on a remote volume; scope is process-wide).
            guard let stagingURL = await Task.detached { Self.copyUnderScope(url) }.value else {
                staged.append(StagedAttachment(kind: .file(url)))
                return
            }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? extracted.mimeType
            let item = StagedAttachment(
                kind: .serverFile(url: stagingURL, originalName: extracted.filename, mimeType: mimeType),
                serverUploadState: .uploading(progress: 0))
            let id = item.id
            staged.append(item)
            serverStagingFiles[id] = stagingURL

            let storedKey = await Self.mintStoredKey(originalName: extracted.filename, vm: vm, ref: ref)
            serverStoredKeys[id] = storedKey
            kickUpload(id: id, localURL: stagingURL, storedKey: storedKey, ref: ref)
        }
    }

    /// Running total of EXTRACTED inline-text bytes already staged this turn (the
    /// `.dualText` + inline `.file` tiles). Drives the planner's per-turn budget
    /// so the Nth small file demotes once the aggregate inline cap is hit. `.file`
    /// tiles haven't been extracted yet (lazy at send), so they're conservatively
    /// counted at their on-disk size — a slight over-count that only makes the
    /// budget MORE conservative (never under-counts, so the cap is never blown).
    private var inlineTextBudgetRemaining: Int {
        var used = 0
        for item in staged {
            switch item.kind {
            case .dualText(_, let text, _, _):
                used += text.lengthOfBytes(using: .utf8)
            default:
                break
            }
        }
        return max(0, Constants.textInlineTurnBudgetBytes - used)
    }

    /// Eager upload for a `.dualText` tile — modeled on `kickImageUpload`: on
    /// FAILURE just sets `.failed` (NO degrade-to-inline): the text already rides
    /// inline, so a failed upload simply means no editable file copy this turn. On
    /// success → `.uploaded(storedKey)` (the one-turn ref will splice).
    private func kickDualUpload(
        id: UUID,
        localURL: URL,
        storedKey: String,
        ref: RemoteAgentRef
    ) {
        let task = Task { @MainActor [weak self] in
            do {
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, ref: ref) { progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                        self.staged[i].serverUploadState = .uploading(progress: progress)
                    }
                }
                guard let self, let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                self.staged[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                // Upload failed → mark `.failed`. Does NOT block Send (a `.dualText`
                // tile is excluded from the send-gating helpers); the file rides
                // inline-only this turn. NO silent retry, NO revert.
                guard let self, let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                self.staged[i].serverUploadState = .failed
            }
            self?.uploadTasks[id] = nil
        }
        uploadTasks[id] = task
    }

    /// Bounded ~2s upload join: before a turn dispatches, give every DUAL tile
    /// (`.dualText` / `.dualImage`) whose eager upload is still `.uploading` a
    /// short window to land so its `storedKey` rides this turn's "also on disk"
    /// ref. If the upload hasn't landed within `timeout`, the turn proceeds
    /// inline-only (the storedKey is simply nil at `pendingAttachment` time — the
    /// file rides inline, the disk-ref is deferred to a later turn). NEVER blocks:
    /// the deadline is a hard cap; a slow upload does not gate Send. Returns once
    /// every dual tile is resolved OR the deadline passes.
    func awaitPreferredUploads(timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillUploadingDual = staged.contains { item in
                (item.isDualText || item.isDualImage) && item.isUploading
            }
            guard stillUploadingDual else { return }
            // 80 ms poll. A THROW here means the enclosing send Task was
            // cancelled — stop waiting immediately. `try?` would swallow the
            // `CancellationError` WITHOUT suspending, busy-spinning the MainActor
            // until the deadline; returning lets the (cancelled) send proceed.
            do { try await Task.sleep(nanoseconds: 80_000_000) }
            catch { return }
        }
    }

    // MARK: - PhotosPicker selection → staged

    /// Consume a fresh PhotosPicker batch: insert a `.loading` tile per item
    /// immediately (so the strip animates in), then resolve each via the
    /// `loadTransferable` Progress overload. On success the placeholder is
    /// REMOVED and the resolved bytes are routed through `stageImage` (which
    /// stages a `.dualImage` tile + kicks the eager upload when a file-server is
    /// configured, else a plain inline `.image`); on failure the placeholder
    /// flips to `.failed`. `vm` + `ref` thread the dual-route through (nil vm →
    /// inline-only fallback inside `stageImage`).
    func handlePickerSelection(_ items: [PhotosPickerItem], vm: ConversationDetailViewModel?, ref: RemoteAgentRef) {
        guard !items.isEmpty else { return }
        for item in items {
            let placeholder = StagedAttachment(kind: .loading)
            let id = placeholder.id
            staged.append(placeholder)

            let progress = item.loadTransferable(type: Data.self) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.progressByID[id] = nil
                    guard let index = self.staged.firstIndex(where: { $0.id == id }) else { return }
                    switch result {
                    case .success(let data?):
                        // Drop the loading placeholder, then stage the resolved
                        // bytes via the dual-route helper (image processing +
                        // eager upload happen there). A fresh tile is appended,
                        // so siblings + ordering are unaffected for the user.
                        self.staged.remove(at: index)
                        await self.stageImage(data, vm: vm, ref: ref)
                    case .success(nil), .failure:
                        self.staged[index].kind = .failed
                    }
                }
            }
            // Seed the determinate bar; observe completion fraction.
            progressByID[id] = progress.fractionCompleted
            observeProgress(progress, for: id)
        }
        // Clear the selection so a subsequent identical pick re-fires.
        pickerSelection.removeAll()
    }

    /// Poll the `Progress` fraction onto the strip's determinate bar. KVO on
    /// `Progress` is the canonical path; a lightweight timer keeps it Sendable-
    /// simple without a stored observer.
    private func observeProgress(_ progress: Progress, for id: UUID) {
        Task { @MainActor [weak self] in
            while let self, self.progressByID[id] != nil, !progress.isFinished {
                self.progressByID[id] = progress.fractionCompleted
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    // MARK: - Server-file staging (file-transfer route)

    /// Stage one-or-more picked NON-image files for the file-server route
    /// (eager-on-attach, Decision C/D). For each url:
    ///  1. copy its bytes UNDER its security scope into a stable app-temp staging
    ///     file `S` (the picked url's scope may not outlive the async upload), so
    ///     `S` is a plain app-temp file the upload + send can both read;
    ///  2. mint a `storedKey` + retain it in `serverStoredKeys` (so a Retry
    ///     reuses the SAME server path rather than orphaning a fresh-keyed blob);
    ///  3. append a `.serverFile` tile in `.uploading(0)`;
    ///  4. kick the eager background PUT (held in `uploadTasks[id]` so X-cancel
    ///     can cancel it), mutating the tile's `serverUploadState` as it climbs.
    /// An image picked here is redirected to the inline path as a fallback.
    /// `vm` may be nil (brand-new conversation): the binary route still works —
    /// the eager upload mints a FLAT storedKey (no conversation folder yet).
    func stageServerFiles(_ urls: [URL], vm: ConversationDetailViewModel?, ref: RemoteAgentRef) {
        // ONE ordered task drains the urls SEQUENTIALLY so tiles append — and the
        // wire `sequence` assigned at send — preserve the user's SELECTION order.
        // The blocking file I/O still hops off-main per url (the UI never freezes
        // on an iCloud-not-downloaded / external / network volume), but the urls
        // are NOT raced against each other: a fast small file must not overtake a
        // slow large one (per-url concurrent tasks reordered a multi-file drop —
        // see code-review). Cheap metadata probes stay on main.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for url in urls {
                // FOLDERS are unstageable (the staging copy would recursively
                // duplicate the whole tree into tmp; the upload can't send one) —
                // skip defensively; the importer's type set already excludes them.
                if self.isDirectoryURL(url) { continue }

                // Image picked via the server importer → DUAL route (inline vision +
                // editable file copy) via `stageImage`; falls back to inline-only
                // inside `stageImage` when no file-server is configured. The inline
                // route NEEDS the bytes in memory (vision processing), so an image
                // over the soft-confirm threshold falls through to the BINARY branch
                // instead (streamed server upload, soft-confirm) — a 500 MB TIFF must
                // not be heap-loaded just to downsize a thumbnail. The size guard is
                // metadata-only (stays on main); only the up-to-100 MB byte READ hops
                // off-main (scope is process-wide → the bracketed read is correct in
                // one detached call).
                if self.isImageURL(url), self.fileByteSize(url) <= Constants.fileTransferSoftConfirmBytes {
                    let data = await Task.detached { () -> Data? in
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try? Data(contentsOf: url)
                    }.value
                    if let data { await self.stageImage(data, vm: vm, ref: ref) }
                    continue
                }

                // TEXT/code file → route through the SAME planner as elsewhere so a
                // `.txt`/`.md`/`.csv`/source file lands IDENTICALLY regardless of
                // which picker opened it (`TextFileExtractor.extract` is the
                // text-vs-binary discriminator: success → text → planner;
                // `.undecodable` → binary → the `.serverFile` path below). GUARDED by
                // a cheap pre-check (type + `textProbeMaxBytes`). WHY off-main: the
                // extract is a WHOLE-FILE read that BLOCKS on a remote volume; run it
                // ONCE here and thread the result into `stageTextFile` so the file is
                // never read twice.
                if self.shouldAttemptTextProbe(url) {
                    let extracted = await Task.detached { try? TextFileExtractor.extract(from: url) }.value
                    if let extracted {
                        await self.stageTextFile(url, extracted: extracted, vm: vm, ref: ref)
                        continue
                    }
                }

                // BINARY (PDF / video / zip / …): file-to-file copy under scope
                // OFF-main (no whole-file memory read — large videos stay off the
                // heap; the copy BLOCKS on a remote volume), then route by gateway
                // file-server presence + size. Order preserved: copy → byteSize
                // check → >100 MB soft-confirm enqueue / finalize. A configured
                // gateway → `.serverFile` + eager upload; an UNCONFIGURED gateway →
                // a `.needsSetup` tile (blocks Send, auto-promotes once setup done).
                guard let stagingURL = await Task.detached { Self.copyUnderScope(url) }.value else { continue }
                let originalName = url.lastPathComponent
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                let byteSize = self.fileByteSize(stagingURL)
                // >100 MB → soft-confirm before staging (Decision C). The host
                // renders an alert; Confirm calls `confirmPendingLargeFile()`.
                if byteSize > Constants.fileTransferSoftConfirmBytes {
                    self.enqueueLargeFile(PendingLargeFile(
                        stagingURL: stagingURL,
                        originalName: originalName,
                        mimeType: mimeType,
                        byteSize: byteSize,
                        ref: ref))
                    continue
                }
                let hasServer = await SettingsManager.shared.fileTransferReadySnapshot(for: ref) != nil
                self.finalizeBinaryStage(
                    stagingURL: stagingURL,
                    originalName: originalName,
                    mimeType: mimeType,
                    byteSize: byteSize,
                    hasServer: hasServer,
                    vm: vm,
                    ref: ref)
            }
        }
    }

    /// Stage a (size-cleared) binary: a configured gateway → `.serverFile` +
    /// eager upload; an UNCONFIGURED gateway → a blocking `.needsSetup` tile (no
    /// upload — the host promotes it once setup completes). `stagingURL` is the
    /// already-copied app-temp file (caller stream-copied it under scope). A nil
    /// `vm` (brand-new conversation) still uploads — under a FLAT storedKey, since
    /// no conversation folder exists yet (flat keys are the historic first-class
    /// format every gateway supports).
    private func finalizeBinaryStage(
        stagingURL: URL,
        originalName: String,
        mimeType: String,
        byteSize: Int,
        hasServer: Bool,
        vm: ConversationDetailViewModel?,
        ref: RemoteAgentRef
    ) {
        guard hasServer else {
            // No file-server on the bound gateway → a `.needsSetup` tile. It blocks
            // Send and carries the staging URL so promotion can upload from it once
            // file transfer is set up. Stamped with the gateway it was staged FOR —
            // promotion only fires for a matching ref (see `needsSetupRefs`).
            let item = StagedAttachment(kind: .needsSetup(
                url: stagingURL,
                originalName: originalName,
                mimeType: mimeType,
                byteSize: byteSize))
            staged.append(item)
            serverStagingFiles[item.id] = stagingURL
            needsSetupRefs[item.id] = ref
            return
        }

        // Configured gateway → `.serverFile` + eager upload (unchanged route).
        let item = StagedAttachment(
            kind: .serverFile(url: stagingURL, originalName: originalName, mimeType: mimeType),
            serverUploadState: .uploading(progress: 0))
        let id = item.id
        staged.append(item)
        serverStagingFiles[id] = stagingURL

        Task { @MainActor [weak self] in
            guard let self else { return }
            let storedKey = await Self.mintStoredKey(originalName: originalName, vm: vm, ref: ref)
            self.serverStoredKeys[id] = storedKey
            self.kickUpload(id: id, localURL: stagingURL, storedKey: storedKey, ref: ref)
        }
    }

    /// Mint a storedKey for a server upload: namespaced under the conversation's
    /// folder when a VM exists AND the gateway's nested-PUT probe passed; FLAT
    /// otherwise (VM-less new chat / folder-incapable gateway).
    private static func mintStoredKey(
        originalName: String,
        vm: ConversationDetailViewModel?,
        ref: RemoteAgentRef
    ) async -> String {
        let folderCapable = await SettingsManager.shared.getFileServerFolderCapable(for: ref)
        return FileServerClient.makeStoredKey(
            originalName: originalName,
            uuid: UUID(),
            folder: (folderCapable && vm != nil) ? vm?.conversationID.uuidString : nil
        )
    }

    // MARK: - Large-file soft-confirm

    /// Enqueue a >100 MB binary for soft-confirm. Presents the head immediately
    /// (the host's alert binds `pendingLargeFile != nil`); subsequent ones wait
    /// in line and present one at a time as each is resolved.
    private func enqueueLargeFile(_ file: PendingLargeFile) {
        pendingLargeFiles.append(file)
    }

    /// Confirm the head soft-confirm: stage it (`.serverFile` / `.needsSetup`),
    /// then advance the queue. Routes to the gateway captured at ENQUEUE
    /// (`file.ref`), but re-resolves the server-presence snapshot FRESH — setup
    /// can complete while the alert is up (remote sync), and a stale flag would
    /// stage a misleading `.needsSetup` tile (or a guaranteed-fail upload). A nil
    /// VM (brand-new conversation) still uploads — under a FLAT storedKey
    /// (`finalizeBinaryStage` handles it).
    func confirmPendingLargeFile(vm: ConversationDetailViewModel?) {
        guard let file = pendingLargeFiles.first else { return }
        pendingLargeFiles.removeFirst()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hasServer = await SettingsManager.shared.fileTransferReadySnapshot(for: file.ref) != nil
            self.finalizeBinaryStage(
                stagingURL: file.stagingURL,
                originalName: file.originalName,
                mimeType: file.mimeType,
                byteSize: file.byteSize,
                hasServer: hasServer,
                vm: vm,
                ref: file.ref)
        }
    }

    /// Cancel (discard) the head soft-confirm: reclaim its staging temp file and
    /// advance the queue. The file is never staged.
    func cancelPendingLargeFile() {
        guard let file = pendingLargeFiles.first else { return }
        pendingLargeFiles.removeFirst()
        try? FileManager.default.removeItem(at: file.stagingURL)
    }

    // MARK: - Needs-setup promotion

    /// After file transfer is set up for `ref`, promote every `.needsSetup` tile
    /// to a `.serverFile` upload (if the server is now READY — saved AND its
    /// staged Test Connection passed). Each promoted tile
    /// mints a storedKey + kicks the eager PUT from its retained staging URL,
    /// exactly like a fresh binary pick. Works WITHOUT a VM (brand-new
    /// conversation — flat storedKey), so a user who completes setup from the
    /// new-chat composer unblocks immediately; only a still-absent snapshot keeps
    /// a tile `.needsSetup`.
    func promoteNeedsSetupTiles(vm: ConversationDetailViewModel?, ref: RemoteAgentRef) async {
        guard await SettingsManager.shared.fileTransferReadySnapshot(for: ref) != nil else { return }
        // Snapshot the ids first (the loop mutates `staged`). Only tiles STAMPED
        // for THIS ref promote — a tile staged for a different gateway stays
        // `.needsSetup` (still blocks Send) rather than uploading somewhere its
        // turn will never reference (see `needsSetupRefs`).
        let promotable: [(id: UUID, url: URL, name: String, mime: String)] = staged.compactMap { item in
            guard case .needsSetup(let url, let name, let mime, _) = item.kind,
                  (needsSetupRefs[item.id] ?? ref) == ref else { return nil }
            return (item.id, url, name, mime)
        }
        for entry in promotable {
            // Mint FIRST (the only suspension), then re-verify + flip + kick with
            // NO await in between (MainActor-atomic). Promote is invoked from
            // several overlapping triggers — the sheet's onDismiss PLUS the THREE
            // `.settingsDidChangeRemotely` posts one guide save fires — so a
            // concurrent promote may have already flipped this tile, or the user
            // may have X-removed it mid-mint. The `.needsSetup` re-check makes
            // promotion idempotent (never a double upload / a kick from a
            // reclaimed staging temp).
            let storedKey = await Self.mintStoredKey(originalName: entry.name, vm: vm, ref: ref)
            guard let index = staged.firstIndex(where: { $0.id == entry.id }),
                  case .needsSetup = staged[index].kind else { continue }
            staged[index].kind = .serverFile(url: entry.url, originalName: entry.name, mimeType: entry.mime)
            staged[index].serverUploadState = .uploading(progress: 0)
            serverStoredKeys[entry.id] = storedKey
            needsSetupRefs[entry.id] = nil
            kickUpload(id: entry.id, localURL: entry.url, storedKey: storedKey, ref: ref)
        }
    }

    /// Re-stamp every `.needsSetup` tile to `ref`. ONLY for the VM-less new-chat
    /// composer when the user flips the gateway picker — there the next turn
    /// definitionally binds to the new gateway, so its tiles should follow (and
    /// then promote, if the new gateway has a server). A conversation-bound
    /// composer must NOT re-stamp (its tiles belong to the bound gateway).
    func restampNeedsSetupTiles(to ref: RemoteAgentRef) {
        for item in staged where item.needsSetup {
            needsSetupRefs[item.id] = ref
        }
    }

    /// Re-kick a FAILED server upload (the strip's Retry). Re-uploads the SAME
    /// staging file under the SAME storedKey minted at stage time (reused from
    /// `serverStoredKeys` — so the retry overwrites the partial blob instead of
    /// orphaning it under a fresh key), flipping the tile back to `.uploading(0)`.
    /// `vm` may be nil (VM-less new chat): the fallback mint goes flat.
    func retryServerUpload(id: UUID, vm: ConversationDetailViewModel?, ref: RemoteAgentRef) {
        guard let index = staged.firstIndex(where: { $0.id == id }),
              case .serverFile(let url, let originalName, _) = staged[index].kind,
              staged[index].serverUploadFailed else { return }
        staged[index].serverUploadState = .uploading(progress: 0)

        // Reuse the key minted at stage time (so the retry overwrites the partial
        // blob instead of orphaning a fresh-keyed one). The fallback mint (key
        // somehow absent) resolves the gateway's folder-capability so a re-minted
        // key still lands in THIS conversation's folder.
        if let storedKey = serverStoredKeys[id] {
            kickUpload(id: id, localURL: url, storedKey: storedKey, ref: ref)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let storedKey = await Self.mintStoredKey(originalName: originalName, vm: vm, ref: ref)
            self.serverStoredKeys[id] = storedKey
            self.kickUpload(id: id, localURL: url, storedKey: storedKey, ref: ref)
        }
    }

    /// Spin up (and retain) the eager background upload for a staged server tile.
    /// On success → `.uploaded(storedKey)`; on cancel → silent (the tile is being
    /// removed); on error → `.failed` (visible Retry, NO silent retry). Mutates
    /// the tile by id (it may have shifted in `staged`).
    private func kickUpload(
        id: UUID,
        localURL: URL,
        storedKey: String,
        ref: RemoteAgentRef
    ) {
        let task = Task { @MainActor [weak self] in
            do {
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, ref: ref) { progress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                        self.staged[i].serverUploadState = .uploading(progress: progress)
                    }
                }
                guard let self, let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                self.staged[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                guard let self, let i = self.staged.firstIndex(where: { $0.id == id }) else { return }
                self.staged[i].serverUploadState = .failed
            }
            self?.uploadTasks[id] = nil
        }
        uploadTasks[id] = task
    }

    /// Copy `url` UNDER its security scope into a stable app-temp file using a
    /// FILE-TO-FILE copy (`FileManager.copyItem`) — NO whole-file memory read, so
    /// a multi-hundred-MB video / zip never balloons the app's footprint at
    /// staging time (the background upload already streams `fromFile`, so this
    /// closes the last in-memory hop on the large-file path). Returns the temp URL
    /// (caller-owned), or nil on copy failure.
    /// `nonisolated static` so callers can hop it OFF the main actor via
    /// `Task.detached` (the copy BLOCKS on a remote volume); it holds no instance
    /// state and brackets its OWN process-wide security scope.
    nonisolated private static func copyUnderScope(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-ftstage-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            // Defensive: copyItem throws if the destination exists (the UUID makes
            // a collision essentially impossible, but be safe).
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// The on-disk byte size of `url` under its security scope (for the chip's
    /// size line + the >100 MB soft-confirm). Zero on failure (treated as "small"
    /// → no soft-confirm; a true large file always resolves a real size).
    private func fileByteSize(_ url: URL) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// True when `url`'s extension maps to an image UTType — drives the
    /// inline-vs-server branch in `stageServerFiles`.
    private func isImageURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// True when `url` is a DIRECTORY (resolved under its security scope) —
    /// folders never stage (see `stageServerFiles`).
    private func isDirectoryURL(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Whether the text-vs-binary probe (`TextFileExtractor.extract`, a
    /// WHOLE-FILE memory read) may run on `url`. False for obviously-binary types
    /// (video / audio / archive) and anything over `Constants.textProbeMaxBytes`
    /// — those route straight to the binary branch so a 2 GB video never transits
    /// the heap just to fail a UTF-8 decode.
    private func shouldAttemptTextProbe(_ url: URL) -> Bool {
        // `.pdf` is excluded even though a rare all-ASCII PDF DECODES as UTF-8:
        // raw PDF markup is never useful inline text, and the text route would
        // silently skip the file-server transfer the user expects.
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .audiovisualContent) || type.conforms(to: .archive)
            || type.conforms(to: .pdf) {
            return false
        }
        return fileByteSize(url) <= Constants.textProbeMaxBytes
    }
}
#endif

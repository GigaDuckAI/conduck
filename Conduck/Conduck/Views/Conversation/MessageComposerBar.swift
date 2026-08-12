// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MessageComposerBar.swift
//
// The Conversations WINDOW composer (type-or-talk). The popover stays
// voice-only (plan decision #1); only the window gets this text field
// (decision #2). A `TextField` with Return-to-send + a Send button + a mic
// button that drives a HOST-OWNED `InAppAudioRecorder` (the same orchestrator
// the iOS composer uses): a spoken turn POPULATES the editable draft for
// review, then the user taps Send — exactly like iOS. (Earlier this borrowed
// the menu-bar `DictationService` via a single shared mutable transcript
// closure; with two composer mounts swapping in `MainWindowView`, SwiftUI's
// unspecified onAppear/onDisappear ordering left that closure a no-op or
// pointing at a torn-down mount, so the transcript was silently dropped — the
// bug this convergence onto `InAppAudioRecorder` fixes.)
//
// Attachments (macOS): library + files + drag-drop (no camera). Layout is
// `[mic][paperclip][field][send]` with the `AttachmentPreviewStrip` above.
//
// The DROP TARGET is not here — it spans the whole conversation pane and lives
// on `MainWindowView`, because the useful target is the transcript, not this
// bar. The window materialises every dropped item (a provider's bytes must be
// read inside the drop callback, which outlives no view), stamps the batch with
// the mount that was on screen, and parks it; `drainPendingDropBatch` claims
// only batches stamped for THIS mount, so a file dropped on one conversation
// can never surface in the composer that replaced it.
//
// Picked and dropped files meet at `stageOneFile`, the one classifier: image →
// inline/dual, text → planner, binary → server upload or a blocking
// `.needsSetup` tile. It runs inside ONE ordered task per batch so tiles append
// in the user's selection/drop order.
//
// Send enables when there's a draft OR a staged attachment that can actually
// carry something, and is disabled while any item is still loading — including
// while the window is resolving a drop this composer has not claimed yet.
//
// Typed sends go through the injected `onSendText` closure (the host wires it
// to `MenuBarCoordinator.handleTypedText`, which mints the conversation on the
// first turn, then calls `vm.sendUserTurn`) — so the composer is always
// mounted and works before any conversation exists (`viewModel` is OPTIONAL).
// The mic toggles the host-owned `recorder`; on stop the STT `Result` is handed
// to `onVoiceResult`, and the host appends the transcript to the shared `draft`.

import SwiftUI
import AppKit
import PhotosUI
import UniformTypeIdentifiers

/// A >100 MB binary awaiting the macOS composer's large-file soft-confirm.
/// PRIVACY: holds the staging URL only in-memory; never logged.
private struct MacPendingLargeFile: Identifiable, Equatable {
    let id = UUID()
    let stagingURL: URL
    let originalName: String
    let mimeType: String
    let byteSize: Int
    /// The gateway this file would route to (drives `.serverFile` vs
    /// `.needsSetup` once the user confirms). A ready snapshot is captured to
    /// pin the exact physical lane; only an initially-nil snapshot may resolve
    /// a newly configured lane while the alert is open.
    let ref: RemoteAgentRef
    let snapshot: SettingsManager.FileTransferSnapshot?
}

/// One file on its way through the classifier, plus what the app may do with
/// its bytes.
///
/// WHY `originalName` is carried rather than read back off `url`: a source the
/// app already copied into temp has a `conduck-ftstage-<uuid>-` prefix on its
/// leaf, and that prefixed leaf would otherwise become the name the user sees
/// on the tile and the name the agent is told to open.
private struct MacStagingSource {
    let url: URL
    let originalName: String
    /// True when `url` is an app-owned copy (staging adopts it and owns its
    /// deletion) rather than a user-owned file the picker vended.
    let isAppOwned: Bool

    /// A file the user picked through the importer: user-owned, and its own
    /// leaf IS its name.
    init(pickedURL: URL) {
        self.url = pickedURL
        self.originalName = pickedURL.lastPathComponent
        self.isAppOwned = false
    }

    /// A file the WINDOW already materialised out of a drop. The window copied
    /// it because a dropped `file://` URL is only a reference to content the
    /// drag source owns; staging adopts that copy instead of making a second
    /// one, which matters when the file is a multi-gigabyte video.
    init(adopting source: DroppedFileSource) {
        self.url = source.url
        self.originalName = source.originalName
        self.isAppOwned = source.isAppOwned
    }

    /// Delete the source if the app owns it. Safe to call on a user-owned
    /// pick, where it is a no-op — a picked file is never ours to delete.
    func disposeIfAppOwned() {
        guard isAppOwned else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Re-stamp an extraction with the source's true name. `TextFileExtractor`
    /// derives `filename` from the URL leaf, which is wrong for an adopted copy.
    func renaming(_ extracted: TextFileExtractor.ExtractedFile) -> TextFileExtractor.ExtractedFile {
        guard extracted.filename != originalName else { return extracted }
        return TextFileExtractor.ExtractedFile(
            filename: originalName,
            mimeType: extracted.mimeType,
            text: extracted.text
        )
    }
}

/// What the ordered staging loop should do after one source.
private enum MacStageSourceOutcome {
    /// Staged, or skipped as unstageable — either way, keep draining.
    case next
    /// The batch is being torn down; stop without touching later sources.
    case cancelled
}

struct MessageComposerBar: View {
    /// The thread VM the typed turn is sent to. Same VM the mic path lands on
    /// when this window shows the active conversation. Optional: nil before the
    /// first conversation is minted (composer is always mounted on the window).
    let viewModel: ConversationDetailViewModel?
    /// Mint-on-first-turn send path (host wires this to the coordinator). Lets the composer exist before any conversation does.
    let onSendText: (ComposerTurnDispatch) async -> Bool
    /// Host-owned in-app recorder (`MainWindowView.windowRecorder`). The mic
    /// button drives it; the same orchestrator the iOS composer uses.
    var recorder: InAppAudioRecorder
    /// The composer draft — host-owned (`MainWindowView.composerDraft`) and
    /// passed as a binding so a spoken transcript the HOST appends lands in the
    /// field regardless of which composer mount (new-chat / active) is on screen.
    /// The TextField writes through this binding.
    @Binding var draft: String
    /// Forward the STT `Result` from a spoken turn — the host routes success
    /// (append into `draft`) / failure + clears stale pending-retry on success.
    /// Same contract as the iOS composer's `onVoiceResult`.
    let onVoiceResult: (Result<String, AppError>) async -> Void
    /// STABLE host-owned Settings VM (`MainWindowView.settingsVM`) — reused for the
    /// file-transfer setup sheet so it isn't re-minted per open (re-minting
    /// triggers a full settings load + leaks an un-retained observer).
    let settingsVM: SettingsViewModel
    /// The host's AUTHORITATIVE new-conversation gateway selection
    /// (`MainWindowView.selectedRef`) — scopes the setup sheet + new-chat
    /// file-transfer resolution to the gateway the next mint binds to, not the
    /// compile-time default.
    let selectedRef: RemoteAgentRef
    /// VM-less host-owned lock for the title-bar gateway picker. Raised while
    /// attachment work owns the selected gateway; active conversations omit it
    /// because their gateway is already permanently bound.
    var newChatGatewaySelectionLocked: Binding<Bool>? = nil
    /// "Type Instead" bridge (⌘⇧2 Screenshot & Ask → typed composer): the host
    /// (`MainWindowView`) parks a screenshot's PNG bytes here; the composer drains
    /// them into `stageImage` (process + stage + eager-upload, for REVIEW — nothing
    /// is sent) and resets the binding to nil. Optional/default-nil so the iOS-
    /// parity new-chat and active-chat sites that don't bridge can omit it.
    var pendingStagedImage: Binding<Data?>? = nil
    /// Which mount this is. The window stamps a drop with the identity that was
    /// on screen when it landed, and only the composer wearing that identity
    /// drains it — so a file dropped on conversation A can never surface in the
    /// composer that replaced it.
    let mountIdentity: ComposerMountIdentity
    /// Drop bridge: the WINDOW owns the pane-wide drop target and materialises
    /// every dropped item (a provider's bytes must be read inside the drop
    /// callback, which outlives no view), then parks the resolved batch here.
    /// The composer claims it, stages it in drop order, and owns its temp files
    /// from that moment. Optional/default-nil so a site that doesn't bridge can
    /// omit it.
    var pendingDropBatch: Binding<PendingDropBatch?>? = nil
    /// Raised with THIS composer's identity while a dispatch owns staging, so
    /// the window can refuse a drop outright rather than accept one that
    /// staging would silently discard.
    var dispatchingIdentity: Binding<ComposerMountIdentity?>? = nil
    /// True while the window is still resolving a drop, or holds a resolved
    /// batch this composer has not claimed yet. Gates Send across a window the
    /// composer's own counters cannot see — the files exist, but no tile does.
    var isDropResolving: Bool = false
    /// How many items the window's in-flight drop carries. Mirrored as
    /// `.loading` tiles so the disabled Send has something on screen accounting
    /// for it while a slow item resolves.
    var resolvingDropCount: Int = 0

    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Attachment staging (local — macOS composer owns it directly)

    @State private var attachments: [StagedAttachment] = []
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showingPhotosPicker = false
    /// Unified "Choose Files…" importer (accepts any file; classifier routes).
    @State private var showingFileImporter = false
    /// File-transfer setup guide sheet (menu item or a `.needsSetup` tile's
    /// "Set Up" button). On dismiss: refresh + promote.
    @State private var showingSetupGuide = false
    /// FIFO queue of >100 MB binaries awaiting the soft-confirm alert (Decision C).
    /// The head is presented (`pendingLargeFile`); confirm stages it, cancel
    /// discards it + reclaims the staging temp. PRIVACY: in-memory only.
    @State private var pendingLargeFiles: [MacPendingLargeFile] = []

    // MARK: - File transfer (server-file staging) — macOS owns it directly

    /// Resolved file-transfer state for the composer's bound gateway.
    /// `available` drives the "Add File" menu item; `ref` is the
    /// upload/retry/orphan-DELETE target. Resolved on appear, on a conversation
    /// (VM) change, and on `.settingsDidChangeRemotely`. `effectiveRef` = the
    /// bound conversation's ref, else the Settings default (new/empty composer).
    @State private var fileTransferAvailable = false
    @State private var effectiveRef: RemoteAgentRef = .builtin(Constants.remoteAgentDefaultBackendDefault)
    /// In-flight eager-upload tasks keyed by the staged item's id (X-cancel +
    /// Retry). PRIVACY: keyed by UUID only — never holds the file URL / storedKey.
    @State private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    @State private var preparationTasks: [UUID: Task<Void, Never>] = [:]
    /// NSItemProvider/PhotosPicker loads expose cancellation through `Progress`
    /// rather than Swift `Task`; retain them so composer teardown can cancel
    /// pre-tile work instead of allowing a late callback to restage content.
    @State private var providerLoadProgresses: [UUID: Progress] = [:]
    /// Stable app-temp staging files per server item (copied from the picked /
    /// dropped url so the async upload + send both read a plain file). Cleaned up
    /// on remove / after a turn clears.
    @State private var serverStagingFiles: [UUID: URL] = [:]
    /// App-owned drop sources handed to a tile that RETAINS the URL (an
    /// inline-only text attachment reads it at send). Tracked separately from
    /// `serverStagingFiles` because deletability follows OWNERSHIP, not the
    /// path: the importer's picks live at the same kind of URL and are never
    /// ours to delete. Expires with the tile.
    @State private var adoptedSourceFiles: [UUID: URL] = [:]
    /// Tiles standing in for a drop the window is still resolving. Purely
    /// presentational — they are replaced by real tiles the moment the batch is
    /// claimed, and never reach a dispatch.
    @State private var dropPlaceholderIDs: [UUID] = []
    /// The minted storedKey per staged server item (keyed by item id), so a
    /// Retry re-uploads under the SAME key — overwriting the failed partial blob
    /// rather than orphaning it under a fresh key. In-memory only.
    @State private var serverStoredKeys: [UUID: String] = [:]
    /// Per-tile upload attempt number, bumped by every `kickUpload`. Retry
    /// re-enters `.uploading(0)`, which makes a stale callback from the dead
    /// attempt indistinguishable from a live one by state alone — see
    /// `ServerFileUploadState.nextUploading(from:progress:)`.
    @State private var serverUploadAttempts: [UUID: Int] = [:]
    /// Covers async importer/drop/image work before a tile has appeared.
    @State private var activeGatewayStages = 0
    /// Holds the picker lock across clear → host conversation mint/bind.
    @State private var attachmentDispatchInProgress = false
    /// A disappearing composer cannot tear down sealed attachment ownership
    /// until local acceptance resolves. Shared state-machine semantics with the
    /// iOS/iPadOS coordinator.
    @State private var deferredAttachmentTeardown = ComposerDeferredTeardown()

    private var shouldLockNewChatGateway: Bool {
        viewModel == nil
            && (showingPhotosPicker
                || showingFileImporter
                || activeGatewayStages > 0
                || attachmentDispatchInProgress
                || !attachments.isEmpty
                || !pendingLargeFiles.isEmpty)
    }
    private var isRecording: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    private var isProcessing: Bool {
        if case .processing = recorder.state { return true }
        return false
    }

    /// True while the Apple model self-heal is downloading before transcribing
    /// the SAME audio (recording → preparingVoice). Treated like `.processing`
    /// for control gating; surfaces the calm `PreparingVoiceIndicator` row.
    private var isPreparingVoice: Bool {
        if case .preparingVoice = recorder.state { return true }
        return false
    }

    /// The live capture's start instant (nil outside `.recording`). Feeds the
    /// self-ticking `LiveRecordingStatusIndicator`, which derives the `mm:ss`
    /// display + near-cap warning from it — so `recorder.state` stays stable
    /// during a capture and the chat pane no longer re-lays-out 10×/sec.
    private var recordingStartedAt: Date? {
        if case .recording(let startedAt) = recorder.state { return startedAt }
        return nil
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the turn has reached its gateway dispatch phase — the send
    /// control becomes a neutral Stop that cancels it. REQUIRED: change #6
    /// removed the inline Cancel from the shared thinking indicator, so this is
    /// the window's only cancel control during the wait.
    ///
    /// Gated on a CANCELLABLE live turn, NOT `isAwaitingReply`: during macOS's
    /// pre-dispatch window `inFlightTask` is still nil, so a Stop offered there
    /// would silently do nothing. `isSendDisabled` below stays on the claim, so
    /// the control is a *disabled Send* for that window rather than a Stop that
    /// lies. (There is no gap on the other side — nothing suspends between the
    /// VM claiming the turn and assigning `inFlightTask`, so the MainActor cannot
    /// render a Stop that has no task behind it.)
    ///
    /// Nor is it the wait indicator: a share-drained turn is visible to this
    /// process but carries no cancel handle, so it shows the wait row and a
    /// disabled Send — never a Stop that cannot stop anything.
    private var isInFlight: Bool {
        viewModel?.canStopLiveTurn ?? false
    }

    /// A `.failed` tile carries NO payload, so a strip holding only failures is
    /// not sendable — counting it would light up Send for a turn that then does
    /// nothing. Rare from the picker; routine once a whole pane accepts drops,
    /// where a load can time out.
    private var hasSendableContent: Bool {
        !trimmedDraft.isEmpty || attachments.contains { !$0.isFailed }
    }

    /// TWO in-flight terms, not one. `isAwaitingReply` is this VM instance's own
    /// claim — the only thing that covers the pre-dispatch window. The wait
    /// indicator covers turns this instance did not dispatch (the share drainer,
    /// a sibling VM), which would otherwise leave Send live beside a running turn.
    private var isSendDisabled: Bool {
        (viewModel?.isAwaitingReply ?? false)
            || (viewModel?.showsGatewayWaitIndicator ?? false)
            || attachments.hasLoadingItem
            || attachments.hasUploadingItem   // strict send-gating: a server-file PUT
            || attachments.hasFailedUpload    // is still climbing / failed (Retry first)
            || attachments.hasNeedsSetupItem  // a binary picked with no file-server —
                                              // blocks until setup or removal
            || activeGatewayStages > 0
            || !preparationTasks.isEmpty
            || attachmentDispatchInProgress
            || isDropResolving                // a dropped file is on its way but has
                                              // no tile yet — sending now would ship
                                              // the turn without it
            || captureActive                  // Part 1f: mic now POPULATES the field —
    }                                         // block Send + onSubmit during capture

    /// True while the window mic is capturing or transcribing (Part 1f). Folded
    /// into `isSendDisabled` so the Send button AND the field's `.onSubmit`
    /// (Return-to-send) are both blocked mid-capture — voice now populates the
    /// draft, so a send during capture would ship a stale draft.
    private var captureActive: Bool {
        isRecording || isProcessing || isPreparingVoice
    }

    var body: some View {
        composerStack
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: attachments)
        .onAppear {
            fieldFocused = true
            newChatGatewaySelectionLocked?.wrappedValue = shouldLockNewChatGateway
        }
        // "Type Instead" bridge: drain a screenshot parked by the host into the
        // composer's staging (process + stage + eager-upload, for REVIEW — nothing
        // is sent). Both on appear (window opened by the bridge) and on change
        // (window already open when the bridge fired), then reset the binding.
        .onAppear { drainPendingStagedImage() }
        .onChange(of: pendingStagedImage?.wrappedValue != nil) { _, hasImage in
            if hasImage { drainPendingStagedImage() }
        }
        // Photo library — NO maxSelectionCount.
        .photosPicker(
            isPresented: $showingPhotosPicker,
            selection: $pickerSelection,
            matching: .images
        )
        .onChange(of: pickerSelection) { _, items in
            stagePickerSelection(items)
        }
        // UNIFIED "Choose Files…" importer — accepts ANY file (broad type set so
        // PDFs / videos / archives aren't greyed out). Routes each pick through
        // the classifier (image → inline; text → inline/dual; binary → server or
        // a `.needsSetup` tile, with the >100 MB soft-confirm).
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: unifiedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { stageServerFiles(urls) }
        }
        // File-transfer setup guide (sheet) scoped to the bound gateway. On
        // dismiss: refresh + promote any `.needsSetup` tiles to uploads.
        .sheet(isPresented: $showingSetupGuide, onDismiss: {
            Task {
                await refreshFileTransfer()
                await promoteNeedsSetupTiles()
            }
        }) {
            NavigationStack {
                // Cancel/Save chrome (and the ready-and-clean auto-dismiss) come
                // from the content's `bufferedEditorChrome` — no host Done button.
                FileTransferSetupGuideView(
                    viewModel: settingsVM,
                    ref: effectiveRef,
                    titleOverride: settingsVM.displayName(for: effectiveRef),
                    context: .composer
                )
            }
            .frame(minWidth: 520, minHeight: 600)
        }
        // Large-file soft-confirm (>100 MB) — names the file + formatted size.
        // GOTCHA (load-bearing): the binding's setter MUST be a no-op — SwiftUI
        // sets `isPresented = false` on EVERY button tap, including Attach, so a
        // cancel-in-setter would discard the file the user just confirmed.
        // Cancellation is ONLY the cancel-role button (which also covers Esc).
        .alert(
            LocalizedStringResource("fileTransfer.softConfirm.title", defaultValue: "Attach large file?"),
            isPresented: Binding(
                get: { pendingLargeFiles.first != nil },
                set: { _ in }
            ),
            presenting: pendingLargeFiles.first
        ) { file in
            Button(LocalizedStringResource("fileTransfer.softConfirm.attach", defaultValue: "Attach")) {
                confirmPendingLargeFile()
            }
            Button(LocalizedStringResource("fileTransfer.softConfirm.cancel", defaultValue: "Cancel"), role: .cancel) {
                cancelPendingLargeFile()
            }
        } message: { file in
            Text(String(
                format: String(localized: LocalizedStringResource(
                    "fileTransfer.softConfirm.message",
                    defaultValue: "%1$@ is %2$@ in size. Large files can take a while to upload."
                )),
                file.originalName,
                AttachmentChipStyle.formattedSize(file.byteSize)
            ))
        }
        // Drops land on the WHOLE conversation pane, not this bar — the window
        // owns that target and parks the resolved batch here. Drain on appear
        // (a batch stamped for a mount that had not appeared yet) and on change
        // (this mount already on screen when the drop landed).
        .onAppear { drainPendingDropBatch() }
        .onChange(of: pendingDropBatch?.wrappedValue?.id) { _, id in
            if id != nil { drainPendingDropBatch() }
        }
        .onChange(of: resolvingDropCount) { _, count in
            syncDropPlaceholders(to: count)
        }
        .task(id: viewModel?.conversationID) {
            await refreshFileTransfer()
            // A VM-less new chat may have staged `.needsSetup` tiles for a gateway
            // that IS configured; once the first turn mints the VM, promote them.
            await promoteNeedsSetupTiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            Task {
                await refreshFileTransfer()
                // Setup can finish after the sheet dismissed (iCloud sync / another
                // device) — promote so a `.needsSetup` tile unblocks.
                await promoteNeedsSetupTiles()
            }
        }
        // The user can switch the NEW-chat gateway picker while the composer is
        // VM-less — re-resolve so the menu's discovery item, the setup sheet's
        // scope, and the binary route all track the gateway the next turn will
        // actually bind to. The host renders that picker read-only while
        // attachment work exists, so an existing tile is never silently moved.
        .onChange(of: selectedRef) {
            Task {
                await refreshFileTransfer()
                await promoteNeedsSetupTiles()
            }
        }
        .onChange(of: shouldLockNewChatGateway) { _, locked in
            newChatGatewaySelectionLocked?.wrappedValue = locked
        }
        // Teardown: this bar's mount can be SWAPPED OUT wholesale (the VM-less
        // new-chat placeholder ↔ the conversation-bound mount in
        // `MainWindowView`, or the window closing). `@State` dies with the view,
        // so without an explicit clear the staging temps + any in-flight uploads
        // of a swapped-away composer would silently leak.
        .onDisappear {
            // Defer every in-flight teardown. This may be the VM-less bar's
            // natural mint OR user navigation/window close; successful local
            // acceptance first clears sealed ids with handed-off semantics,
            // while rejection leaves them for discard at dispatch end.
            if deferredAttachmentTeardown.request(
                whileDispatching: attachmentDispatchInProgress
            ) {
                clearDiscardedAttachments()
            }
            newChatGatewaySelectionLocked?.wrappedValue = false
        }
    }

    // MARK: - Composer box (extracted to keep `body` type-checkable)

    /// The vertical stack of strips + box, split from `body`'s modifier chain
    /// so each piece stays within the type-checker's budget.
    private var composerStack: some View {
        VStack(spacing: 8) {
            AttachmentPreviewStrip(
                attachments: attachments,
                onRemove: { id in removeAttachment(id) },
                onRetryUpload: { id in
                    guard !attachmentDispatchInProgress else { return }
                    retryServerUpload(id: id)
                },
                onSetUp: { _ in
                    guard !attachmentDispatchInProgress else { return }
                    showingSetupGuide = true
                }
            )
            .allowsHitTesting(!attachmentDispatchInProgress)

            errorBanner

            // Recording dot+timer crossfading into the spinner+"Transcribing…"
            // row as capture stops (Part 2b) — closes the no-timer gap on the
            // macOS window (the weakest surface), shared look with the popover/iOS
            // composer. Reduce Motion swaps instantly.
            captureStatusBanner

            composerBox
        }
    }

    /// Cause AND remedy (`descriptionWithRecovery`). This banner is the ONLY
    /// slot the macOS composer has for a capture failure — no second line, no
    /// Troubleshoot chip — and `InAppAudioRecorder`'s `.error` carries the whole
    /// `AppError` taxonomy, certificate verdicts included. The cause alone
    /// strips a pin mismatch of "the connection may be intercepted", leaves an
    /// untrusted chain with no server-side fix named, and turns an unpinnable
    /// key into a server fault the user would go hunting. `descriptionWithRecovery`
    /// drops the generic "Try again." rather than appending it, so a terminal
    /// refusal reads as terminal here.
    @ViewBuilder
    private var errorBanner: some View {
        if case .error(let appError) = recorder.state {
            let message = appError.descriptionWithRecovery
            Text(message.isEmpty ? String(localized: "Something went wrong.") : message)  // xcstrings
                .font(.caption)
                .foregroundStyle(AppColors.error)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    /// Recording dot+timer crossfading into the spinner+"Transcribing…" row as
    /// capture stops (Part 2b). `.transition(.opacity)` + a spring keyed on the
    /// state phase; Reduce Motion swaps instantly (nil animation).
    @ViewBuilder
    private var captureStatusBanner: some View {
        Group {
            if let startedAt = recordingStartedAt {
                LiveRecordingStatusIndicator(startedAt: startedAt)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else if case .preparingVoice(let progress) = recorder.state {
                // Self-heal: the on-device model is downloading before we
                // transcribe the SAME audio. Calm label leads (progress is not
                // the hero), crossfading like the transcribing row.
                PreparingVoiceIndicator(progress: progress)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else if isProcessing {
                TranscribingIndicator()
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82),
            value: captureBannerPhase
        )
    }

    /// Discrete phase tag for the crossfade animation (0 none / 1 recording /
    /// 2 transcribing) — keyed instead of the full state so the 0.1s timer tick
    /// doesn't re-trigger the crossfade.
    private var captureBannerPhase: Int {
        if isRecording { return 1 }
        if isProcessing { return 2 }
        if isPreparingVoice { return 3 }
        return 0
    }

    /// The Claude-style box: multi-line text on top, control row inside along
    /// the bottom: [📎] —— Spacer —— [🎤] [⬆].
    private var composerBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                String(localized: LocalizedStringResource(
                    "composer.placeholder",
                    defaultValue: "Message your personal AI"
                )),
                text: $draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...12)
            .focused($fieldFocused)
            .onSubmit(send)

            controlRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppColors.border, lineWidth: 1)
                )
        )
        // The whole card is a focus target — the editable `TextField` is only as
        // tall as its text (a thin strip at the top), so the card's padding, the
        // gap above the control row, and the side margins were dead zones where a
        // click didn't place the cursor. `.contentShape` makes that transparent
        // area hittable; the plain `.onTapGesture` is automatically lower-priority
        // than the TextField + the mic/send Buttons, so clicks that land ON the
        // text still position the caret and clicks on the controls still fire —
        // only a click that misses every interactive child focuses the field.
        // A11y: the focus-assist tap lives in a BEHIND-content `.background` hit
        // layer (never `.overlay`, which would steal clicks from the field/buttons),
        // hidden from accessibility — VoiceOver users focus the TextField directly.
        // On the card wrapper itself it surfaced an unlabeled phantom tappable
        // element in the AX tree; hiding the wrapper would hide the field/buttons.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = true }
                .accessibilityHidden(true)
        )
    }

    private var controlRow: some View {
        HStack(spacing: 10) {
            AttachmentMenu(
                onPickLibrary: {
                    guard !attachmentDispatchInProgress else { return }
                    showingPhotosPicker = true
                },
                onTakePhoto: { },   // no camera on macOS — item is hidden
                onPickFiles: {
                    guard !attachmentDispatchInProgress else { return }
                    showingFileImporter = true
                },
                onSetUpFileTransfer: {
                    guard !attachmentDispatchInProgress else { return }
                    showingSetupGuide = true
                },
                fileTransferAvailable: fileTransferAvailable,
                // Bare glyph sits BELOW the trailing discs' point size: a
                // `.circle.fill` renders a disc ~3-4pt smaller than its nominal
                // size, so paperclip 20 ≈ mic/send 24 in actual visible width.
                iconPointSize: 20,
                iconFrame: 32
            )
            .disabled(attachmentDispatchInProgress)

            Spacer(minLength: 8)

            micButton
            sendButton
        }
    }

    // MARK: - Drop batch drain (the window owns the target; this owns staging)

    /// Claim a batch the window parked for THIS mount, if any.
    ///
    /// The claim is main-actor atomic and happens before any suspension: read
    /// the value, check the stamp, take it out, clear the binding. Two mounts
    /// can briefly observe the same binding during a SwiftUI transition, and
    /// whichever one runs first must leave nothing for the other to also claim.
    /// A composer whose identity does NOT match leaves the binding alone — the
    /// window owns discarding a batch whose destination has gone away.
    private func drainPendingDropBatch() {
        guard let binding = pendingDropBatch,
              let batch = binding.wrappedValue,
              batch.destination == mountIdentity else { return }
        binding.wrappedValue = nil
        stageDropBatch(batch)
    }

    /// Stage a claimed batch in DROP order through the same classifier the
    /// importer uses. One ordered task for the whole batch — per-item tasks
    /// would let a small file overtake a large one, which is the bug the
    /// old per-provider drop path shipped.
    private func stageDropBatch(_ batch: PendingDropBatch) {
        // Real tiles take over from here. Removed explicitly rather than left to
        // the count's `onChange`, which lands a render later and would show the
        // placeholders alongside the tiles that replaced them.
        removeDropPlaceholders()
        guard !attachmentDispatchInProgress else {
            // Staging would refuse every item; reclaim rather than accept the
            // drop and drop it on the floor.
            disposeDropSources(batch.items[...])
            return
        }
        activeGatewayStages += 1
        let preparationID = UUID()
        let task = Task { @MainActor in
            defer {
                activeGatewayStages -= 1
                preparationTasks[preparationID] = nil
            }
            // Resolve the gateway AUTHORITATIVELY (the conversation's persisted
            // backend), exactly as the screenshot bridge does. A just-mounted
            // composer's `effectiveRef` is still the default for a beat, so a
            // drop drained in that window would otherwise pick the wrong
            // gateway's file server.
            guard let ref = await authoritativeComposerRef(), !Task.isCancelled else {
                disposeDropSources(batch.items[...])
                return
            }
            // ONE lane snapshot for every binary in this batch.
            let capturedLane = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
            guard !Task.isCancelled else {
                disposeDropSources(batch.items[...])
                return
            }
            for (index, item) in batch.items.enumerated() {
                guard !Task.isCancelled else {
                    disposeDropSources(batch.items[index...])
                    return
                }
                switch item {
                case .image(let data):
                    await stageImage(data, ref: ref)
                case .file(let source):
                    let outcome = await stageOneFile(
                        MacStagingSource(adopting: source),
                        ref: ref,
                        capturedBinaryLane: capturedLane
                    )
                    if case .cancelled = outcome {
                        disposeDropSources(batch.items[(index + 1)...])
                        return
                    }
                case .failed:
                    // A load that errored or timed out. Shown as a failed tile
                    // rather than omitted — the user watched the app accept
                    // this item and is owed an explanation.
                    attachments.append(StagedAttachment(kind: .failed))
                }
            }
        }
        preparationTasks[preparationID] = task
    }

    /// Mirror the window's in-flight drop as `.loading` tiles. They gate Send
    /// through the ordinary `hasLoadingItem` path and, unlike a bare disabled
    /// button, say WHY. Cleared when the batch is claimed or the drop is
    /// abandoned (count returns to zero).
    private func syncDropPlaceholders(to count: Int) {
        guard count != dropPlaceholderIDs.count else { return }
        guard count > 0 else {
            removeDropPlaceholders()
            return
        }
        while dropPlaceholderIDs.count < count {
            let tile = StagedAttachment(kind: .loading)
            dropPlaceholderIDs.append(tile.id)
            attachments.append(tile)
        }
    }

    private func removeDropPlaceholders() {
        guard !dropPlaceholderIDs.isEmpty else { return }
        let ids = Set(dropPlaceholderIDs)
        dropPlaceholderIDs.removeAll()
        attachments.removeAll { ids.contains($0.id) }
    }

    /// Reclaim the app-owned temp behind every not-yet-staged item. Once
    /// staging adopts a source, its tile owns it and it must NOT be swept here.
    private func disposeDropSources(_ items: ArraySlice<ResolvedDropItem>) {
        for item in items {
            guard case .file(let source) = item, source.isAppOwned else { continue }
            try? FileManager.default.removeItem(at: source.url)
        }
    }

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
        return scopedFileByteSize(url) <= Constants.textProbeMaxBytes
    }

    /// On-disk byte size of a still-security-scoped SOURCE url (pre-copy). The
    /// post-copy app-temp staging files use the plain `fileByteSize`.
    private func scopedFileByteSize(_ url: URL) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: - PhotosPicker → staged

    private func stagePickerSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let ref = effectiveRef
        for item in items {
            let placeholder = StagedAttachment(kind: .loading)
            let id = placeholder.id
            attachments.append(placeholder)
            let progress = item.loadTransferable(type: Data.self) { result in
                Task { @MainActor in
                    providerLoadProgresses[id] = nil
                    guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
                    switch result {
                    case .success(let data?):
                        // Drop the loading placeholder, then stage the resolved
                        // bytes via the dual-route helper (process + eager upload
                        // when a file-server is configured, else inline-only).
                        attachments.remove(at: index)
                        await stageImage(data, ref: ref)
                    case .success(nil), .failure: attachments[index].kind = .failed
                    }
                }
            }
            providerLoadProgresses[id] = progress
        }
        pickerSelection.removeAll()
    }

    // MARK: - Mic

    private var micButton: some View {
        // Part 2: matching FILLED-circle treatment (denser 32pt disc for the mac
        // row). The disc itself is the affordance, so the old white-opacity hover
        // chip is dropped. Recording shows the soft pulsing halo (Reduce-Motion
        // static).
        CaptureCircleButton(
            symbol: micSymbol,
            fillColor: micColor,
            showsPulse: isRecording,
            animatesSymbol: isRecording,
            diameter: 32,
            glyphSize: 14,
            isDisabled: isProcessing || isPreparingVoice || (viewModel?.isAwaitingReply ?? false),
            accessibilityLabel: isRecording
                ? String(localized: LocalizedStringResource("composer.mic.stop", defaultValue: "Stop recording"))
                : String(localized: LocalizedStringResource("composer.mic.start", defaultValue: "Start recording")),
            action: toggleMic
        )
    }

    private var micSymbol: String {
        if isProcessing || isPreparingVoice { return "ellipsis" }
        return isRecording ? "stop.fill" : "mic.fill"
    }

    private var micColor: Color {
        if isProcessing || isPreparingVoice { return AppColors.disabled }
        return isRecording ? AppColors.error : AppColors.brandAmber
    }

    private func toggleMic() {
        // Mirrors `iOSMessageComposerBar.micButtonTapped`: idle/error → clear any
        // error + start; recording → stop, then hand the STT Result to the host
        // (`onVoiceResult`), which appends the transcript into the shared draft.
        // Processing is a no-op (the stall-Cancel lives elsewhere).
        switch recorder.state {
        case .idle, .error:
            recorder.dismissError()
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "voice.announce.recordingStarted",
                defaultValue: "Recording started"
            ))
            Task {
                // On-device default is keyboard dictation — no model download,
                // no proactive gate. A rare model-unavailable case surfaces
                // reactively as the recorder error banner after capture.
                await recorder.startRecording()
            }
        case .recording:
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "voice.announce.transcribing",
                defaultValue: "Transcribing"
            ))
            Task {
                let result = await recorder.stopAndUpload()
                await onVoiceResult(result)
            }
        case .processing, .preparingVoice:
            break
        }
    }

    // MARK: - Send

    /// What the trailing control MEANT when it was drawn. One control, two
    /// meanings — and the meaning must be decided at RENDER time, not at action
    /// time.
    ///
    /// The failure this prevents: the button morphs Send → Stop the moment a
    /// turn goes in flight. If the meaning is re-read inside the action closure,
    /// a click the user aimed at Send — queued while the main actor was busy —
    /// runs after the morph and CANCELS the turn they were trying to start. That
    /// is a destructive action produced by a click that meant the opposite, and
    /// it is silent: a cancelled turn writes no classification, so the thread
    /// just shows "wasn't delivered".
    /// `.stop` carries the identity of the turn it was rendered for, so a stale
    /// click cancels THAT turn or nothing — never whichever turn happens to be
    /// running when it lands. See `cancelInFlight(expecting:)`.
    private enum TrailingIntent { case send, stop(token: Date?) }

    private var trailingIntent: TrailingIntent {
        isInFlight ? .stop(token: viewModel?.inFlightTurnToken) : .send
    }

    private var sendButton: some View {
        // In-flight Stop morph (neutral) takes priority; otherwise the send
        // arrow (amber when a draft is ready). Part 2: FILLED-circle treatment.
        //
        // Deliberately ONE `CaptureCircleButton`, not two — the symbol swap
        // animates off a single stable button identity, and splitting it into
        // separate Send/Stop views would lose that. The safety comes from
        // capturing `intent` below, not from splitting the control.
        let intent = trailingIntent
        return CaptureCircleButton(
            symbol: isInFlight ? "stop.fill" : "arrow.up",
            fillColor: trailingColor,
            diameter: 32,
            glyphSize: 14,
            // In-flight Stop is always enabled. Otherwise Send enables on
            // sendable content (a draft OR a staged attachment), blocked while
            // loading / mid-capture.
            isDisabled: isInFlight ? false : (!hasSendableContent || isSendDisabled),
            accessibilityLabel: isInFlight
                ? String(localized: "Stop")  // xcstrings: chat-ui
                : String(localized: LocalizedStringResource("composer.send", defaultValue: "Send")),
            action: { trailingAction(intent) }
        )
    }

    private var trailingColor: Color {
        if isInFlight { return AppColors.textSecondary }
        return (hasSendableContent && !isSendDisabled) ? AppColors.brandAmber : AppColors.disabled
    }

    /// Acts on the intent CAPTURED when the button was built, never on a fresh
    /// read of `isInFlight`. Both arms are guarded against arriving late, and
    /// they need DIFFERENT guards: a stale `.send` falls through to `send()`,
    /// whose own live checks (`isSendDisabled` includes `isAwaitingReply`) turn
    /// it into a no-op, while a stale `.stop` is qualified by the turn token it
    /// captured — an unqualified cancel would kill whatever turn had started in
    /// the meantime.
    private func trailingAction(_ intent: TrailingIntent) {
        switch intent {
        case .stop(let token): viewModel?.cancelInFlight(expecting: token)
        case .send: send()
        }
    }

    private func send() {
        let text = trimmedDraft
        let submittedDraft = draft
        let dispatchRef = viewModel == nil ? selectedRef : effectiveRef
        guard hasSendableContent,
              !isSendDisabled,
              attachments.serverOwnershipMatches(dispatchRef) else { return }
        attachmentDispatchInProgress = true
        // Tell the window SYNCHRONOUSLY (an observed report would be a render
        // late, and a drop that lands in that gap gets accepted then discarded).
        dispatchingIdentity?.wrappedValue = mountIdentity
        Task {
            defer { finishAttachmentDispatch() }
            await awaitPreferredUploads()
            guard let dispatch = attachments.makeDispatch(
                text: text,
                ref: dispatchRef,
                conversationID: viewModel?.conversationID,
                stagingGeneration: UUID()
            ) else {
                viewModel?.reportComposerDispatchRejection()
                return
            }
            let accepted = await onSendText(dispatch)
            if accepted {
                clearAfterSuccessfulHandoff(dispatch)
                if draft == submittedDraft {
                    draft = ""
                }
            }
        }
    }

    private func finishAttachmentDispatch() {
        attachmentDispatchInProgress = false
        // Release only OUR claim: a composer that replaced us may already have
        // raised its own, and clearing that would let a drop through mid-send.
        if dispatchingIdentity?.wrappedValue == mountIdentity {
            dispatchingIdentity?.wrappedValue = nil
        }
        if deferredAttachmentTeardown.consume() {
            clearDiscardedAttachments()
        }
    }

    // MARK: - Server-file staging (file-transfer route)

    /// Allowed content types for the UNIFIED "Choose Files…" importer — accepts
    /// ANYTHING the classifier can route (image → inline; text → inline/dual;
    /// binary → server or `.needsSetup`). Broad supertypes so nothing is greyed
    /// out; `.audiovisualContent`/`.movie` make videos selectable. Mirrors the iOS
    /// `ComposerAttachmentTypes.unifiedContentTypes` set.
    /// `.item` is deliberately ABSENT — it admits FOLDERS (`public.folder` →
    /// `public.item`), which the file-to-file staging copy would recursively
    /// duplicate into tmp and the upload could never send.
    private var unifiedContentTypes: [UTType] {
        [.content, .data, .image,
         .audiovisualContent, .movie,
         .pdf, .archive, .spreadsheet, .presentation,
         .commaSeparatedText, .json, .plainText, .rtf, .sourceCode]
    }

    /// Stage one-or-more picked/dropped files. Classifies each: image → inline
    /// vision (`stageImage`); text/code → planner (`stageTextFile`); binary →
    /// server upload (configured gateway) OR a blocking `.needsSetup` tile
    /// (unconfigured gateway), with a >100 MB soft-confirm. Works WITHOUT a VM
    /// (brand-new chat): the binary route still uploads eagerly — under a FLAT
    /// storedKey, since no conversation folder exists yet.
    private func stageServerFiles(_ urls: [URL], ref stagedRef: RemoteAgentRef? = nil) {
        stageSources(urls.map(MacStagingSource.init(pickedURL:)), ref: stagedRef)
    }

    /// Drain an ordered list of sources through the classifier, sequentially.
    ///
    /// ONE ordered task drains them so tiles append in the user's SELECTION /
    /// DROP order — per-source concurrent tasks let a fast small file overtake a
    /// slow large one (which reordered a multi-file drop — see code-review). The
    /// blocking file I/O still hops off-main per source (the UI never beachballs
    /// on an iCloud-not-downloaded / external / network volume); the sources are
    /// just no longer raced against each other.
    ///
    /// The counter is raised BEFORE the first suspension and one task is
    /// registered for the WHOLE loop — both are load-bearing for Send gating.
    private func stageSources(_ sources: [MacStagingSource], ref stagedRef: RemoteAgentRef? = nil) {
        guard !attachmentDispatchInProgress else { return }
        let ref = stagedRef ?? effectiveRef
        activeGatewayStages += 1
        let preparationID = UUID()
        let task = Task { @MainActor in
            defer {
                activeGatewayStages -= 1
                preparationTasks[preparationID] = nil
            }
            // ONE lane snapshot for every binary in this batch — refetching per
            // source could mix physical lanes within a single selection.
            let capturedLane = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
            guard !Task.isCancelled else { return }
            for source in sources {
                guard !Task.isCancelled else { return }
                let outcome = await stageOneFile(
                    source, ref: ref, capturedBinaryLane: capturedLane)
                if case .cancelled = outcome { return }
            }
        }
        preparationTasks[preparationID] = task
    }

    /// Classify and stage ONE source. Runs inside `stageSources`' single ordered
    /// task and must never spawn a task of its own — doing so would reintroduce
    /// the cross-source reordering this loop exists to prevent.
    private func stageOneFile(
        _ source: MacStagingSource,
        ref: RemoteAgentRef,
        capturedBinaryLane: SettingsManager.FileTransferSnapshot?
    ) async -> MacStageSourceOutcome {
        let url = source.url
        // FOLDERS are unstageable (the staging copy would recursively duplicate
        // the whole tree into tmp; the upload can't send one) — skip defensively;
        // the importer's type set already excludes them. An adopted folder is
        // reclaimed here: nothing downstream will ever own it.
        if isDirectoryURL(url) {
            source.disposeIfAppOwned()
            return .next
        }

        // Image → DUAL route (inline vision + editable file copy) via
        // `stageImage`; inline-only fallback when no file-server / no VM.
        // The inline route NEEDS the bytes in memory (vision processing),
        // so an image over the soft-confirm threshold falls through to the
        // BINARY branch instead (streamed server upload, soft-confirm) — a
        // 500 MB TIFF must not be heap-loaded for a thumbnail. The size
        // guard is metadata-only (stays on main); only the up-to-100 MB
        // byte READ hops off-main (scope is process-wide → correct in one
        // detached call).
        if isImageURL(url), scopedFileByteSize(url) <= Constants.fileTransferSoftConfirmBytes {
            let data = await Task.detached { () -> Data? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            }.value
            // The bytes are in memory and `stageImage` makes its own upload
            // copy, so an adopted source is redundant the moment it is read —
            // reclaim it now rather than let a ~100 MB temp sit until teardown.
            source.disposeIfAppOwned()
            guard !Task.isCancelled else { return .cancelled }
            guard let data else {
                // The read failed AFTER the drop was accepted (memory pressure
                // on a large image, a volume that went away). A dropped item
                // the user watched land is owed a tile; a picked one keeps the
                // importer's historical silent skip.
                if source.isAppOwned { attachments.append(StagedAttachment(kind: .failed)) }
                return .next
            }
            await stageImage(data, ref: ref)
            return .next
        }

        // TEXT/code file → the SAME planner as the importer
        // (`TextFileExtractor.extract` is the text-vs-binary discriminator).
        // GUARDED by a cheap pre-check (type + `textProbeMaxBytes`). WHY
        // off-main: the extract is a WHOLE-FILE read that BLOCKS on a remote
        // volume; run it ONCE here and thread the result into `stageTextFile`
        // so the file is never read twice.
        if shouldAttemptTextProbe(url) {
            let extracted = await Task.detached { try? TextFileExtractor.extract(from: url) }.value
            guard !Task.isCancelled else {
                source.disposeIfAppOwned()
                return .cancelled
            }
            if let extracted {
                let stagedID = await stageTextFile(
                    url, extracted: source.renaming(extracted), ref: ref)
                // An inline-only text tile RETAINS this exact URL (the VM reads
                // it at send), so an adopted source cannot be reclaimed here —
                // hand it to the tile's lifetime instead. When the planner made
                // its own server copy ours is merely redundant, and expiring it
                // with the tile is still correct, just later.
                if source.isAppOwned {
                    if let stagedID {
                        adoptedSourceFiles[stagedID] = url
                    } else {
                        source.disposeIfAppOwned()
                    }
                }
                return .next
            }
        }

        // BINARY: file-to-file copy under scope OFF-main (no whole-file
        // memory read; the copy BLOCKS on a remote volume), then route by
        // gateway file-server presence + size. Order preserved: copy →
        // byteSize check → soft-confirm / finalize.
        // An adopted source IS already an app-owned copy — adopt it in place.
        // Copying again would double the disk cost of every dropped binary (a
        // 2 GB video copied twice) for no gain, and the staging leaf's
        // `conduck-ftstage-` prefix would compound.
        let stagingURL: URL
        if source.isAppOwned {
            stagingURL = url
        } else {
            guard let copied = await Task.detached(
                operation: { AttachmentStagingFile.copyUnderScope(url) }
            ).value else { return .next }
            stagingURL = copied
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: stagingURL)
            return .cancelled
        }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let byteSize = fileByteSize(stagingURL)
        if byteSize > Constants.fileTransferSoftConfirmBytes {
            pendingLargeFiles.append(MacPendingLargeFile(
                stagingURL: stagingURL, originalName: source.originalName,
                mimeType: mimeType, byteSize: byteSize, ref: ref,
                snapshot: capturedBinaryLane))
            return .next
        }
        finalizeBinaryStage(
            stagingURL: stagingURL, originalName: source.originalName,
            mimeType: mimeType, byteSize: byteSize,
            snapshot: capturedBinaryLane, ref: ref)
        return .next
    }

    /// Stage a (size-cleared) binary: READY gateway (Test Connection passed) →
    /// `.serverFile` + eager upload; not-ready gateway (unconfigured, untested,
    /// or failed) → a blocking `.needsSetup` tile (no upload — promotion defers). `stagingURL` is the already-copied app-temp file. A nil
    /// `viewModel` (brand-new chat) still uploads — under a FLAT storedKey (flat
    /// keys are the historic first-class format every gateway supports). `ref` is
    /// the gateway captured when the file was picked/confirmed — NOT re-read from
    /// `effectiveRef`, which may have moved under a queued soft-confirm.
    private func finalizeBinaryStage(
        stagingURL: URL,
        originalName: String,
        mimeType: String,
        byteSize: Int,
        snapshot: SettingsManager.FileTransferSnapshot?,
        ref: RemoteAgentRef
    ) {
        guard let snapshot else {
            let item = StagedAttachment(kind: .needsSetup(
                url: stagingURL, originalName: originalName,
                mimeType: mimeType, byteSize: byteSize),
                serverOwnerRef: ref)
            attachments.append(item)
            serverStagingFiles[item.id] = stagingURL
            return
        }
        let item = StagedAttachment(
            kind: .serverFile(url: stagingURL, originalName: originalName, mimeType: mimeType),
            serverOwnerRef: ref,
            serverOwnerSnapshot: snapshot,
            serverUploadState: .uploading(progress: 0))
        let id = item.id
        attachments.append(item)
        serverStagingFiles[id] = stagingURL

        let storedKey = Self.mintStoredKey(
            originalName: originalName,
            vm: viewModel,
            snapshot: snapshot
        )
        serverStoredKeys[id] = storedKey
        kickUpload(
            id: id,
            localURL: stagingURL,
            storedKey: storedKey,
            ref: ref,
            snapshot: snapshot
        )
    }

    /// Mint a storedKey for a server upload: namespaced under the conversation's
    /// folder when a VM exists AND the gateway's nested-PUT probe passed; FLAT
    /// otherwise (VM-less new chat / folder-incapable gateway).
    private static func mintStoredKey(
        originalName: String,
        vm: ConversationDetailViewModel?,
        snapshot: SettingsManager.FileTransferSnapshot
    ) -> String {
        return FileServerClient.makeStoredKey(
            originalName: originalName,
            uuid: UUID(),
            folder: (snapshot.folderCapable && vm != nil) ? vm?.conversationID.uuidString : nil
        )
    }

    // MARK: - Large-file soft-confirm

    /// Confirm the head soft-confirm: stage it (`.serverFile` / `.needsSetup`) and
    /// advance the queue. Routes to the gateway captured at ENQUEUE (`file.ref`)
    /// and reuses an already-captured physical lane. Only a file queued before
    /// transfer was ready resolves a newly configured lane at confirmation time.
    /// A nil VM (brand-new chat) still uploads under a FLAT storedKey.
    private func confirmPendingLargeFile() {
        guard !attachmentDispatchInProgress else { return }
        guard let file = pendingLargeFiles.first else { return }
        pendingLargeFiles.removeFirst()
        let preparationID = UUID()
        activeGatewayStages += 1
        let task = Task { @MainActor in
            defer {
                activeGatewayStages -= 1
                preparationTasks[preparationID] = nil
            }
            let lane: SettingsManager.FileTransferSnapshot?
            if let captured = file.snapshot {
                lane = captured
            } else {
                lane = await SettingsManager.shared.fileTransferReadySnapshot(for: file.ref)
            }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: file.stagingURL)
                return
            }
            finalizeBinaryStage(
                stagingURL: file.stagingURL, originalName: file.originalName,
                mimeType: file.mimeType, byteSize: file.byteSize,
                snapshot: lane, ref: file.ref)
        }
        preparationTasks[preparationID] = task
    }

    /// Cancel (discard) the head soft-confirm: reclaim its staging temp + advance.
    private func cancelPendingLargeFile() {
        guard !attachmentDispatchInProgress else { return }
        guard let file = pendingLargeFiles.first else { return }
        pendingLargeFiles.removeFirst()
        try? FileManager.default.removeItem(at: file.stagingURL)
    }

    // MARK: - Needs-setup promotion

    /// After file transfer is set up for `effectiveRef`, promote every
    /// `.needsSetup` tile to a `.serverFile` upload (if the server is now READY
    /// — saved AND its staged Test Connection passed).
    /// Mints a storedKey + kicks the eager PUT from each tile's retained staging
    /// URL. Works WITHOUT a VM (brand-new chat — flat storedKey), so a user who
    /// completes setup from the new-chat composer unblocks immediately; only a
    /// still-absent snapshot keeps a tile `.needsSetup`.
    private func promoteNeedsSetupTiles() async {
        let ref = effectiveRef
        guard let snapshot = await SettingsManager.shared.fileTransferReadySnapshot(for: ref) else { return }
        // Only tiles OWNED by THIS ref promote — a tile staged for a different
        // gateway stays `.needsSetup` (still blocks Send) rather than uploading
        // somewhere its turn will never reference.
        let promotable: [(id: UUID, url: URL, name: String, mime: String)] = attachments.compactMap { item in
            guard case .needsSetup(let url, let name, let mime, _) = item.kind,
                  item.serverOwnerRef == ref else { return nil }
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
            let storedKey = Self.mintStoredKey(
                originalName: entry.name,
                vm: viewModel,
                snapshot: snapshot
            )
            guard let index = attachments.firstIndex(where: { $0.id == entry.id }),
                  case .needsSetup = attachments[index].kind,
                  attachments[index].serverOwnerRef == ref else { continue }
            attachments[index].kind = .serverFile(url: entry.url, originalName: entry.name, mimeType: entry.mime)
            attachments[index].serverOwnerSnapshot = snapshot
            attachments[index].serverUploadState = .uploading(progress: 0)
            serverStoredKeys[entry.id] = storedKey
            kickUpload(
                id: entry.id,
                localURL: entry.url,
                storedKey: storedKey,
                ref: ref,
                snapshot: snapshot
            )
        }
    }

    // MARK: - Text-file staging (dual-route when a file-server is configured)

    /// Stage one picked/dropped text-or-code file via `AttachmentDeliveryPlanner`
    /// — the SAME planner the iOS composer + share drainer use, so a `.txt`/`.md`/
    /// `.csv`/source file lands IDENTICALLY regardless of surface/picker.
    /// Extracts the text ONCE here (inline/persist copy + planner routing size),
    /// then routes: no file-server / extraction fails → inline-only
    /// `.file(url)` (today's behavior); server + small → `.dualText` (inline +
    /// eager upload, never gates Send); server + large/over-budget → `.serverFile`
    /// (file-only). Routed by EXTRACTED UTF-8 byte count, not raw file size.
    ///
    /// Returns the id of the tile it appended, or nil when nothing was staged.
    /// The caller needs it to tie an ADOPTED drop source to that tile's
    /// lifetime — the inline-only route retains the passed `url` itself.
    @discardableResult
    private func stageTextFile(
        _ url: URL,
        extracted precomputed: TextFileExtractor.ExtractedFile? = nil,
        ref stagedRef: RemoteAgentRef? = nil
    ) async -> UUID? {
        guard !attachmentDispatchInProgress else { return nil }
        activeGatewayStages += 1
        defer { activeGatewayStages -= 1 }
        // Capture the effective gateway before any suspension. A brand-new chat
        // has no VM yet, but READY belongs to this ref and still supports a flat
        // storedKey + eager upload.
        let ref = stagedRef ?? effectiveRef
        let lane = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
        guard !Task.isCancelled else { return nil }
        let fileServerReady = lane != nil

        // Extract ONCE. The caller (`stageServerFiles`) already ran it OFF-main as
        // the text-vs-binary probe and threads the result in (file never read
        // twice); when absent we extract HERE, also OFF-main — a WHOLE-FILE read +
        // UTF-8 decode that BLOCKS on an iCloud-not-downloaded / external volume
        // (`extract` is `nonisolated` + brackets its OWN security scope). A failed
        // extraction is NOT fatal — stage inline-only `.file`.
        let resolved: TextFileExtractor.ExtractedFile?
        if let precomputed {
            resolved = precomputed
        } else {
            resolved = await Task.detached { try? TextFileExtractor.extract(from: url) }.value
        }
        guard !Task.isCancelled else { return nil }
        guard let extracted = resolved else {
            let fallback = StagedAttachment(kind: .file(url))
            attachments.append(fallback)
            return fallback.id
        }
        let folderCapable = lane?.folderCapable ?? false
        let prepared = await TextAttachmentStagePreparer.prepare(
            sourceURL: url,
            extracted: extracted,
            fileServerReady: fileServerReady,
            inlineBudgetRemaining: inlineTextBudgetRemaining,
            folderCapable: folderCapable,
            conversationID: viewModel?.conversationID
        )
        guard !Task.isCancelled else {
            if let upload = prepared.uploadRequest {
                try? FileManager.default.removeItem(at: upload.localURL)
            }
            return nil
        }
        var item = prepared.attachment
        if prepared.uploadRequest != nil {
            item.serverOwnerRef = ref
            item.serverOwnerSnapshot = lane
        }
        attachments.append(item)

        guard let upload = prepared.uploadRequest, let lane else {
            return item.id
        }
        let id = item.id
        serverStagingFiles[id] = upload.localURL
        serverStoredKeys[id] = upload.storedKey

        if item.isDualText {
            kickDualUpload(
                id: id,
                localURL: upload.localURL,
                storedKey: upload.storedKey,
                ref: ref,
                snapshot: lane
            )
        } else {
            kickUpload(
                id: id,
                localURL: upload.localURL,
                storedKey: upload.storedKey,
                ref: ref,
                snapshot: lane
            )
        }
        return id
    }

    /// Running remaining inline-text budget (per-turn cap) — `.dualText` tiles
    /// already staged count against it (see iOS coordinator for rationale).
    private var inlineTextBudgetRemaining: Int {
        var used = 0
        for item in attachments {
            if case .dualText(_, let text, _, _) = item.kind {
                used += text.lengthOfBytes(using: .utf8)
            }
        }
        return max(0, Constants.textInlineTurnBudgetBytes - used)
    }

    /// Eager upload for a `.dualText` tile (mirrors `kickImageUpload`): FAILURE →
    /// `.failed` (NO degrade-to-inline; the text already rides inline); SUCCESS →
    /// `.uploaded(storedKey)`. Never gates Send.
    private func kickDualUpload(
        id: UUID,
        localURL: URL,
        storedKey: String,
        ref: RemoteAgentRef,
        snapshot: SettingsManager.FileTransferSnapshot
    ) {
        let task = Task { @MainActor in
            do {
                // NO progress sink — same reason as `kickImageUpload`: a
                // `.dualText` tile renders no progress chrome, so an intermediate
                // write is a composer-wide invalidation for a number nothing
                // displays. Terminal states below still land.
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, snapshot: snapshot) { _ in }
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                // `.failed` (badge + Retry), or `.refused(reason)` when the error
                // is terminal — the tile then says what happened and shows no
                // Retry, because an identical request can only fail identically.
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .failure(for: error)
            }
            uploadTasks[id] = nil
        }
        uploadTasks[id] = task
    }

    /// Bounded ~2s upload join — give a still-uploading DUAL tile (`.dualText` /
    /// `.dualImage`) a brief window to land its storedKey before send. Never
    /// blocks: past the deadline the file rides inline-only.
    private func awaitPreferredUploads(timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillUploadingDual = attachments.contains { item in
                (item.isDualText || item.isDualImage) && item.isUploading
            }
            guard stillUploadingDual else { return }
            // A throw = the enclosing send Task was cancelled → stop waiting now.
            // `try?` would swallow the `CancellationError` without suspending,
            // busy-spinning the MainActor until the deadline.
            do { try await Task.sleep(nanoseconds: 80_000_000) }
            catch { return }
        }
    }

    // MARK: - Image staging (dual-route when a file-server is configured)

    /// Stage a composer image (picked / dropped). When the bound gateway has a
    /// file-server AND `ImageProcessor` succeeds, this is the DUAL route
    /// (Approach C): process ONCE here (downsized + EXIF/GPS-stripped JPEG, the
    /// INLINE/persist copy), stage a `.dualImage` tile in `.uploading(0)`, and
    /// eagerly upload the ORIGINAL RAW bytes — the exact picked file in its TRUE
    /// format (HEIC / PNG / DNG / JPEG, metadata intact), NOT the processed JPEG
    /// — so the agent's tools act on the real file. Otherwise fall back to the
    /// INLINE-ONLY `.image(original)` tile (unchanged). Send is NEVER gated on
    /// the image upload (a `.dualImage` tile is excluded from the send-gating
    /// helpers). PRIVACY: the upload name is SYNTHETIC by POSITION
    /// ("image.<ext>" / "image-N.<ext>") carrying only the original's sniffed
    /// extension; the processed JPEG (inline) already has EXIF/GPS stripped, the
    /// uploaded original keeps its metadata (the user PUTs it to their OWN
    /// server).
    /// Drain the "Type Instead" bridge: if the host parked a screenshot, stage it
    /// for review (reuses `stageImage`) and reset the binding so it drains exactly
    /// once. No-op when the binding is absent or empty.
    private func drainPendingStagedImage() {
        guard let binding = pendingStagedImage, let data = binding.wrappedValue else { return }
        binding.wrappedValue = nil
        let preparationID = UUID()
        activeGatewayStages += 1
        let task = Task { @MainActor in
            defer {
                activeGatewayStages -= 1
                preparationTasks[preparationID] = nil
            }
            guard let ref = await authoritativeComposerRef(), !Task.isCancelled else { return }
            await stageImage(data, ref: ref)
        }
        preparationTasks[preparationID] = task
    }

    private func stageImage(_ original: Data, ref stagedRef: RemoteAgentRef? = nil) async {
        guard !attachmentDispatchInProgress else { return }
        activeGatewayStages += 1
        defer { activeGatewayStages -= 1 }
        let ref = stagedRef ?? effectiveRef
        // No file-server configured → inline-only (unchanged). WHY no `viewModel`
        // gate: a VM-less brand-new conversation STILL dual-routes — `mintStoredKey`
        // yields a FLAT storedKey (folder:nil) when vm==nil and the binary path
        // already uploads VM-less, so the spec gives images no VM-less carve-out.
        // Gating on `viewModel` here wrongly short-circuited the FIRST image turn to
        // inline-only and never uploaded the byte-faithful original.
        let resolvedLane = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
        guard !Task.isCancelled else { return }
        guard let lane = resolvedLane else {
            attachments.append(StagedAttachment(kind: .image(original)))
            return
        }
        // Process ONCE for the INLINE/persist copy (fixed `defaultMaxPixel` — the
        // "Max image dimension" setting was removed; the file-transfer route now
        // sends originals, so only the inline copy is capped).
        let processedResult = try? await ImageProcessor.shared.process(
            original,
            maxPixel: ImageProcessor.defaultMaxPixel
        )
        guard !Task.isCancelled else { return }
        guard let processed = processedResult else {
            attachments.append(StagedAttachment(kind: .image(original)))
            return
        }

        // Sniff the ORIGINAL bytes for their true format; synthesize a
        // position-based name with the real extension (no user filename travels).
        let format = ImageFormatSniffer.sniff(original)
        let position = attachments.filter(\.isDualImage).count
        let filename = position == 0 ? "image.\(format.ext)" : "image-\(position + 1).\(format.ext)"
        // Per-conversation folder unless this gateway's nested-PUT probe failed.
        // Pass the OPTIONAL `viewModel` straight through — `mintStoredKey` yields a
        // FLAT storedKey (folder:nil) when it's nil (VM-less first turn).
        let storedKey = Self.mintStoredKey(
            originalName: filename,
            vm: viewModel,
            snapshot: lane
        )
        // Write the ORIGINAL bytes (not the processed JPEG) to a throwaway temp
        // file under the sniffed extension; the upload reads the real file.
        // sim-QA verified: the upload body is the ORIGINAL (true format), distinct
        // from the inline `processedJPEG` — the background-URLSession path has no
        // clean unit seam for the written bytes, so it's covered by sim QA, not
        // XCTest (the wire/filename split IS unit-tested).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-imgupload-\(UUID().uuidString).\(format.ext)")
        // WHY off-main: writing up to 100 MB of original image bytes atomically can
        // BLOCK the main actor (macOS beachball) on a slow/full/external volume
        // (`original: Data` is Sendable → the write hops off-main cleanly). Tile
        // append + storedKey stamping below stay on the MainActor. A write failure
        // is NOT fatal — fall back to inline-only (unchanged).
        do {
            try await Task.detached { try original.write(to: tmp, options: .atomic) }.value
        } catch {
            attachments.append(StagedAttachment(kind: .image(original)))
            return
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }

        let item = StagedAttachment(
            kind: .dualImage(
                processedJPEG: processed.jpegData,
                thumbnail: processed.thumbnailData,
                width: processed.width,
                height: processed.height,
                byteSize: processed.byteSize,
                filename: filename
            ),
            serverOwnerRef: ref,
            serverOwnerSnapshot: lane,
            serverUploadState: .uploading(progress: 0))
        let id = item.id
        attachments.append(item)
        serverStagingFiles[id] = tmp
        serverStoredKeys[id] = storedKey
        kickImageUpload(
            id: id,
            localURL: tmp,
            storedKey: storedKey,
            ref: ref,
            snapshot: lane
        )
    }

    /// Eager upload for a `.dualImage` tile — modeled on `kickUpload` but on
    /// FAILURE just sets `.failed` (NO degrade-to-inline): the image already
    /// rides inline, so a failed upload simply means no editable file copy this
    /// turn. On success → `.uploaded(storedKey)`.
    private func kickImageUpload(
        id: UUID,
        localURL: URL,
        storedKey: String,
        ref: RemoteAgentRef,
        snapshot: SettingsManager.FileTransferSnapshot
    ) {
        let task = Task { @MainActor in
            do {
                // NO progress sink: a `.dualImage` tile renders no progress
                // chrome (see `AttachmentPreviewStrip.tile`), so every
                // intermediate write would mutate `@State` — invalidating the
                // whole composer and re-running the strip's body — to publish a
                // number nothing displays. `URLSession` reports progress per
                // body-data callback, i.e. dozens of times for one camera
                // original. The tile stays at the `.uploading(0)` its staging set
                // (`isUploading` remains true, so `awaitPreferredUploads` still
                // joins it) until a terminal state lands below.
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, snapshot: snapshot) { _ in }
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                // `.failed` (badge + Retry), or `.refused(reason)` when the error
                // is terminal — the tile then says what happened and shows no
                // Retry, because an identical request can only fail identically.
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .failure(for: error)
            }
            uploadTasks[id] = nil
        }
        uploadTasks[id] = task
    }

    /// Re-kick a FAILED server upload (the strip's Retry) under the SAME staging
    /// file + the SAME storedKey minted at stage time (reused from
    /// `serverStoredKeys` so the retry overwrites the partial blob rather than
    /// orphaning it under a fresh key). Guarded on `serverUploadRetryable`, not
    /// `serverUploadFailed`: a `.refused` tile offers no Retry, and a
    /// programmatic call must not re-open one.
    private func retryServerUpload(id: UUID) {
        guard !attachmentDispatchInProgress else { return }
        guard let index = attachments.firstIndex(where: { $0.id == id }),
              case .serverFile(let url, let originalName, _) = attachments[index].kind,
              attachments[index].serverUploadRetryable,
              let ref = attachments[index].serverOwnerRef,
              let snapshot = attachments[index].serverOwnerSnapshot else { return }
        attachments[index].serverUploadState = .uploading(progress: 0)

        // Reuse the key minted at stage time (retry overwrites the partial blob).
        // The fallback mint (key somehow absent) resolves folder-capability so a
        // re-minted key still lands in THIS conversation's folder (flat VM-less).
        if let storedKey = serverStoredKeys[id] {
            kickUpload(
                id: id,
                localURL: url,
                storedKey: storedKey,
                ref: ref,
                snapshot: snapshot
            )
            return
        }
        let storedKey = Self.mintStoredKey(
            originalName: originalName,
            vm: viewModel,
            snapshot: snapshot
        )
        serverStoredKeys[id] = storedKey
        kickUpload(
            id: id,
            localURL: url,
            storedKey: storedKey,
            ref: ref,
            snapshot: snapshot
        )
    }

    /// Spin up (and retain) the eager background upload for a staged server tile.
    /// On success → `.uploaded(storedKey)`; cancel → silent; error → `.failed`.
    /// `ref` is caller-provided (the gateway the file was staged/promoted FOR) —
    /// never re-read from `effectiveRef`, which may have moved meanwhile.
    private func kickUpload(
        id: UUID,
        localURL: URL,
        storedKey: String,
        ref: RemoteAgentRef,
        snapshot: SettingsManager.FileTransferSnapshot
    ) {
        let attempt = (serverUploadAttempts[id] ?? 0) + 1
        serverUploadAttempts[id] = attempt
        let task = Task { @MainActor in
            do {
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, snapshot: snapshot) { progress in
                    Task { @MainActor in
                        // Attempt check FIRST: after a Retry the tile is back at
                        // `.uploading(0)`, so a callback left over from the dead
                        // attempt passes every state-based test.
                        guard serverUploadAttempts[id] == attempt,
                              let i = attachments.firstIndex(where: { $0.id == id }),
                              attachments[i].serverOwnerRef == ref,
                              attachments[i].serverOwnerSnapshot == snapshot else { return }
                        // Quantized — a write that doesn't move the rendered bar
                        // is a composer-wide invalidation for nothing.
                        guard let next = StagedAttachment.ServerFileUploadState.nextUploading(
                            from: attachments[i].serverUploadState,
                            progress: progress
                        ) else { return }
                        attachments[i].serverUploadState = next
                    }
                }
                guard serverUploadAttempts[id] == attempt,
                      let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                // `.failed` (badge + Retry), or `.refused(reason)` when the error
                // is terminal — the tile then says what happened and shows no
                // Retry, because an identical request can only fail identically.
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .failure(for: error)
            }
            uploadTasks[id] = nil
        }
        uploadTasks[id] = task
    }

    /// Remove a staged item by id. For a server tile this ALSO cancels its
    /// in-flight upload, best-effort DELETEs an already-uploaded orphan blob, and
    /// reclaims the local staging temp file — so an X-cancel never orphans a blob
    /// on the gateway.
    private func removeAttachment(_ id: UUID) {
        guard !attachmentDispatchInProgress else { return }
        dropPlaceholderIDs.removeAll { $0 == id }
        providerLoadProgresses.removeValue(forKey: id)?.cancel()
        releaseServerResources(for: id, wasHandedOff: false)
        attachments.removeAll { $0.id == id }
    }

    /// Discard ALL unsent staging: every minted server key is an orphan, including
    /// an eager upload that lands just after cancellation.
    private func clearDiscardedAttachments() {
        for task in preparationTasks.values { task.cancel() }
        preparationTasks.removeAll()
        for progress in providerLoadProgresses.values { progress.cancel() }
        providerLoadProgresses.removeAll()
        for id in attachments.map(\.id) {
            releaseServerResources(for: id, wasHandedOff: false)
        }
        uploadTasks.removeAll()
        // Reclaim any not-yet-confirmed large-file staging temps too.
        for file in pendingLargeFiles { try? FileManager.default.removeItem(at: file.stagingURL) }
        pendingLargeFiles.removeAll()
        // Sweep any adopted drop source whose tile never materialised (staging
        // lost a race with teardown), which the per-id pass above cannot see.
        for url in adoptedSourceFiles.values { try? FileManager.default.removeItem(at: url) }
        adoptedSourceFiles.removeAll()
        dropPlaceholderIDs.removeAll()
        attachments.removeAll()
        pickerSelection.removeAll()
    }

    private func clearAfterSuccessfulHandoff(_ dispatch: ComposerTurnDispatch) {
        let sealedIDs = dispatch.stagedAttachmentIDs
        for id in attachments.map(\.id) where sealedIDs.contains(id) {
            releaseServerResources(
                for: id,
                wasHandedOff: dispatch.handedOffServerAttachmentIDs.contains(id)
            )
        }
        attachments.removeAll { sealedIDs.contains($0.id) }
        for id in sealedIDs {
            providerLoadProgresses.removeValue(forKey: id)?.cancel()
            preparationTasks.removeValue(forKey: id)?.cancel()
        }
        if attachments.isEmpty {
            pickerSelection.removeAll()
        }
    }

    private func cleanupStagingFile(_ id: UUID) {
        serverStoredKeys[id] = nil
        // Cleared with the rest of the tile's per-id bookkeeping: a surviving
        // entry would both leak and, if the id were ever reused, let an old
        // attempt number admit a callback it should reject.
        serverUploadAttempts[id] = nil
        if let url = serverStagingFiles[id] {
            try? FileManager.default.removeItem(at: url)
            serverStagingFiles[id] = nil
        }
        // An adopted drop source the tile retained. Distinct from the staging
        // copy above: for an inline-only text tile this IS the file the turn
        // reads, and nothing else in the app knows it exists.
        if let adopted = adoptedSourceFiles[id] {
            try? FileManager.default.removeItem(at: adopted)
            adoptedSourceFiles[id] = nil
        }
    }

    private func releaseServerResources(for id: UUID, wasHandedOff: Bool) {
        let item = attachments.first(where: { $0.id == id })
        let task = uploadTasks.removeValue(forKey: id)
        let storedKey = serverStoredKeys[id]
        let snapshot = item?.serverOwnerSnapshot
        if !wasHandedOff {
            task?.cancel()
            if let storedKey, let snapshot {
                Task {
                    if let task { await task.value }
                    await ConversationDetailViewModel.deleteOrphanServerFile(
                        storedKey: storedKey,
                        snapshot: snapshot
                    )
                }
            }
        }
        cleanupStagingFile(id)
    }

    /// The on-disk byte size of `url` (for the chip's size line + the >100 MB
    /// soft-confirm). Zero on failure (treated as "small").
    private func fileByteSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Resolve the effective ref (bound conversation, else the host's pending
    /// new-chat gateway) + whether its file-server is READY (saved + test
    /// passed — drives the "Set Up File Transfer…" discovery item + the binary
    /// route).
    private func refreshFileTransfer() async {
        guard attachments.isEmpty,
              pendingLargeFiles.isEmpty,
              activeGatewayStages == 0,
              preparationTasks.isEmpty,
              !attachmentDispatchInProgress else {
            return
        }
        guard let vm = viewModel else {
            // Brand-new (VM-less) chat: scope to the host's AUTHORITATIVE pending
            // gateway (`selectedRef`), NOT the compile-time default — so a setup
            // sheet opened from the new-chat composer targets the right gateway.
            effectiveRef = selectedRef
            fileTransferAvailable = (await SettingsManager.shared.fileTransferReadySnapshot(for: selectedRef)) != nil
            return
        }
        // Resolve THIS conversation's bound gateway AUTHORITATIVELY from its
        // persisted backend — NOT `vm.boundRef`, which the VM populates async in
        // reload() and is still nil for a beat right after a conversation switch.
        // A nil-boundRef fallback to the DEFAULT gateway wrongly enabled "Add
        // File" for a conversation bound to an UNCONFIGURED gateway whenever the
        // default gateway happened to BE configured (the per-gateway gate leak).
        let ref: RemoteAgentRef
        if let raw = try? await ConversationStore.shared.fetchConversation(id: vm.conversationID)?.backend,
           let bound = RemoteAgentRef(rawString: raw) {
            ref = bound
        } else { return }
        effectiveRef = ref
        fileTransferAvailable = (await SettingsManager.shared.fileTransferReadySnapshot(for: ref)) != nil
    }

    private func authoritativeComposerRef() async -> RemoteAgentRef? {
        guard let vm = viewModel else { return selectedRef }
        guard let raw = try? await ConversationStore.shared
            .fetchConversation(id: vm.conversationID)?.backend else {
            return nil
        }
        return RemoteAgentRef(rawString: raw)
    }
}
#endif

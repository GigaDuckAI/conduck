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
// Attachments (macOS): library + files + DRAG-DROP (no camera). Layout is
// `[mic][paperclip][field][send]` with the `AttachmentPreviewStrip` above. The
// drop target uses RAW `NSItemProvider` (`.onDrop`, NOT typed
// `.dropDestination` — Safari image drags are file-promises) and routes image +
// text-file UTTypes into staging; an amber drop-target highlight animates while
// a drag hovers. Send enables when there's a draft OR a staged attachment, and
// is disabled while any item is still loading.
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

    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Attachment staging (local — macOS composer owns it directly)

    @State private var attachments: [StagedAttachment] = []
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showingPhotosPicker = false
    /// Unified "Choose Files…" importer (accepts any file; classifier routes).
    @State private var showingFileImporter = false
    @State private var isDropTargeted = false
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
    /// The minted storedKey per staged server item (keyed by item id), so a
    /// Retry re-uploads under the SAME key — overwriting the failed partial blob
    /// rather than orphaning it under a fresh key. In-memory only.
    @State private var serverStoredKeys: [UUID: String] = [:]
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

    /// True while an agent turn is in flight — the send control becomes a
    /// neutral Stop that cancels it. REQUIRED: change #6 removed the inline
    /// Cancel from the shared thinking indicator, so this is the window's only
    /// cancel control during the wait.
    private var isInFlight: Bool {
        viewModel?.isAwaitingReply ?? false
    }

    private var hasSendableContent: Bool {
        !trimmedDraft.isEmpty || !attachments.isEmpty
    }

    private var isSendDisabled: Bool {
        (viewModel?.isAwaitingReply ?? false)
            || attachments.hasLoadingItem
            || attachments.hasUploadingItem   // strict send-gating: a server-file PUT
            || attachments.hasFailedUpload    // is still climbing / failed (Retry first)
            || attachments.hasNeedsSetupItem  // a binary picked with no file-server —
                                              // blocks until setup or removal
            || activeGatewayStages > 0
            || !preparationTasks.isEmpty
            || attachmentDispatchInProgress
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
        .overlay(dropHighlight)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: attachments)
        .animation(.easeInOut(duration: 0.18), value: isDropTargeted)
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
        // Raw NSItemProvider drop (Safari drags are file-promises — typed
        // `.dropDestination` would miss them). `.fileURL` already catches any
        // dropped file (incl. videos/binaries → `.needsSetup` / server route).
        .onDrop(of: [.image, .fileURL, .plainText, .commaSeparatedText, .json, .rtf, .sourceCode], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
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

    @ViewBuilder
    private var errorBanner: some View {
        if case .error(let appError) = recorder.state {
            Text(appError.errorDescription ?? String(localized: "Something went wrong."))  // xcstrings
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

    // MARK: - Drop highlight

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AppColors.brandAmber, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppColors.brandAmber.opacity(0.08))
                )
                .padding(4)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Drop handling (raw NSItemProvider)

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            // Image data (incl. Safari file-promise drags).
            if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                let ref = effectiveRef
                let preparationID = UUID()
                activeGatewayStages += 1
                let progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    Task { @MainActor in
                        defer {
                            activeGatewayStages -= 1
                            providerLoadProgresses[preparationID] = nil
                        }
                        guard providerLoadProgresses[preparationID] != nil else { return }
                        guard let data else { return }
                        // DUAL route (inline vision + editable file copy) via
                        // `stageImage`; falls back to inline-only when no
                        // file-server is configured.
                        await stageImage(data, ref: ref)
                    }
                }
                providerLoadProgresses[preparationID] = progress
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                let ref = effectiveRef
                let preparationID = UUID()
                activeGatewayStages += 1
                let progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    let resolvedURL = data.flatMap {
                        URL(dataRepresentation: $0, relativeTo: nil)
                    }
                    Task { @MainActor in
                        defer {
                            activeGatewayStages -= 1
                            providerLoadProgresses[preparationID] = nil
                        }
                        guard providerLoadProgresses[preparationID] != nil else { return }
                        guard let resolvedURL else { return }
                        // ONE classifier for every dropped file — identical to the
                        // "Choose Files…" importer: image → DUAL/inline via
                        // `stageImage`; text/code → planner via `stageTextFile`
                        // (size/type-guarded probe, no whole-file read for
                        // binaries); binary → `.serverFile` upload on a configured
                        // gateway, or a blocking `.needsSetup` tile on an
                        // unconfigured one (no more silent doomed `.file(url)`
                        // that failed at send with a misleading "couldn't be
                        // read" banner). >100 MB → soft-confirm.
                        stageServerFiles([resolvedURL], ref: ref)
                    }
                }
                providerLoadProgresses[preparationID] = progress
            }
        }
        return handled
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

    private var sendButton: some View {
        // In-flight Stop morph (neutral) takes priority; otherwise the send
        // arrow (amber when a draft is ready). Part 2: FILLED-circle treatment.
        CaptureCircleButton(
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
            action: trailingAction
        )
    }

    private var trailingColor: Color {
        if isInFlight { return AppColors.textSecondary }
        return (hasSendableContent && !isSendDisabled) ? AppColors.brandAmber : AppColors.disabled
    }

    private func trailingAction() {
        if isInFlight {
            viewModel?.cancelInFlight()
        } else {
            send()
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
        guard !attachmentDispatchInProgress else { return }
        let ref = stagedRef ?? effectiveRef
        activeGatewayStages += 1
        let preparationID = UUID()
        // ONE ordered task drains the urls SEQUENTIALLY so tiles append in the
        // user's SELECTION order — per-url concurrent tasks let a fast small file
        // overtake a slow large one (which reordered a multi-file drop — see
        // code-review). The blocking file I/O still hops off-main per url (the UI
        // never beachballs on an iCloud-not-downloaded / external / network
        // volume); the urls are just no longer raced against each other.
        let task = Task { @MainActor in
            defer {
                activeGatewayStages -= 1
                preparationTasks[preparationID] = nil
            }
            let capturedLane = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
            guard !Task.isCancelled else { return }
            for url in urls {
                guard !Task.isCancelled else { return }
                // FOLDERS are unstageable (the staging copy would recursively
                // duplicate the whole tree into tmp; the upload can't send one) —
                // skip defensively; the importer's type set already excludes them.
                if isDirectoryURL(url) { continue }

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
                    guard !Task.isCancelled else { return }
                    if let data { await stageImage(data, ref: ref) }
                    continue
                }

                // TEXT/code file → the SAME planner as the importer
                // (`TextFileExtractor.extract` is the text-vs-binary discriminator).
                // GUARDED by a cheap pre-check (type + `textProbeMaxBytes`). WHY
                // off-main: the extract is a WHOLE-FILE read that BLOCKS on a remote
                // volume; run it ONCE here and thread the result into `stageTextFile`
                // so the file is never read twice.
                if shouldAttemptTextProbe(url) {
                    let extracted = await Task.detached { try? TextFileExtractor.extract(from: url) }.value
                    guard !Task.isCancelled else { return }
                    if let extracted {
                        await stageTextFile(url, extracted: extracted, ref: ref)
                        continue
                    }
                }

                // BINARY: file-to-file copy under scope OFF-main (no whole-file
                // memory read; the copy BLOCKS on a remote volume), then route by
                // gateway file-server presence + size. Order preserved: copy →
                // byteSize check → soft-confirm / finalize.
                guard let stagingURL = await Task.detached(
                    operation: { AttachmentStagingFile.copyUnderScope(url) }
                ).value else { continue }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: stagingURL)
                    return
                }
                let originalName = url.lastPathComponent
                let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                let byteSize = fileByteSize(stagingURL)
                if byteSize > Constants.fileTransferSoftConfirmBytes {
                    pendingLargeFiles.append(MacPendingLargeFile(
                        stagingURL: stagingURL, originalName: originalName,
                        mimeType: mimeType, byteSize: byteSize, ref: ref,
                        snapshot: capturedLane))
                    continue
                }
                finalizeBinaryStage(
                    stagingURL: stagingURL, originalName: originalName,
                    mimeType: mimeType, byteSize: byteSize,
                    snapshot: capturedLane, ref: ref)
            }
        }
        preparationTasks[preparationID] = task
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
    private func stageTextFile(
        _ url: URL,
        extracted precomputed: TextFileExtractor.ExtractedFile? = nil,
        ref stagedRef: RemoteAgentRef? = nil
    ) async {
        guard !attachmentDispatchInProgress else { return }
        activeGatewayStages += 1
        defer { activeGatewayStages -= 1 }
        // Capture the effective gateway before any suspension. A brand-new chat
        // has no VM yet, but READY belongs to this ref and still supports a flat
        // storedKey + eager upload.
        let ref = stagedRef ?? effectiveRef
        let lane = await SettingsManager.shared.fileTransferReadySnapshot(for: ref)
        guard !Task.isCancelled else { return }
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
        guard !Task.isCancelled else { return }
        guard let extracted = resolved else {
            attachments.append(StagedAttachment(kind: .file(url)))
            return
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
            return
        }
        var item = prepared.attachment
        if prepared.uploadRequest != nil {
            item.serverOwnerRef = ref
            item.serverOwnerSnapshot = lane
        }
        attachments.append(item)

        guard let upload = prepared.uploadRequest, let lane else {
            return
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
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, snapshot: snapshot) { progress in
                    Task { @MainActor in
                        guard let i = attachments.firstIndex(where: { $0.id == id }),
                              attachments[i].serverOwnerRef == ref,
                              attachments[i].serverOwnerSnapshot == snapshot else { return }
                        attachments[i].serverUploadState = .uploading(progress: progress)
                    }
                }
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .failed
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
                original: original,
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
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, snapshot: snapshot) { progress in
                    Task { @MainActor in
                        guard let i = attachments.firstIndex(where: { $0.id == id }),
                              attachments[i].serverOwnerRef == ref,
                              attachments[i].serverOwnerSnapshot == snapshot else { return }
                        attachments[i].serverUploadState = .uploading(progress: progress)
                    }
                }
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .failed
            }
            uploadTasks[id] = nil
        }
        uploadTasks[id] = task
    }

    /// Re-kick a FAILED server upload (the strip's Retry) under the SAME staging
    /// file + the SAME storedKey minted at stage time (reused from
    /// `serverStoredKeys` so the retry overwrites the partial blob rather than
    /// orphaning it under a fresh key).
    private func retryServerUpload(id: UUID) {
        guard !attachmentDispatchInProgress else { return }
        guard let index = attachments.firstIndex(where: { $0.id == id }),
              case .serverFile(let url, let originalName, _) = attachments[index].kind,
              attachments[index].serverUploadFailed,
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
        let task = Task { @MainActor in
            do {
                try await ConversationDetailViewModel.uploadServerFile(localURL: localURL, storedKey: storedKey, snapshot: snapshot) { progress in
                    Task { @MainActor in
                        guard let i = attachments.firstIndex(where: { $0.id == id }),
                              attachments[i].serverOwnerRef == ref,
                              attachments[i].serverOwnerSnapshot == snapshot else { return }
                        attachments[i].serverUploadState = .uploading(progress: progress)
                    }
                }
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .uploaded(storedKey: storedKey)
            } catch is CancellationError {
                // Tile is being removed — leave it.
            } catch {
                guard let i = attachments.firstIndex(where: { $0.id == id }),
                      attachments[i].serverOwnerRef == ref,
                      attachments[i].serverOwnerSnapshot == snapshot else { return }
                attachments[i].serverUploadState = .failed
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
        if let url = serverStagingFiles[id] {
            try? FileManager.default.removeItem(at: url)
            serverStagingFiles[id] = nil
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

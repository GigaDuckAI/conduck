#if os(iOS)
// Conduck
// AttachmentComposerContainer.swift
//
// Wraps `iOSMessageComposerBar` with all the host-owned attachment
// modifiers (`.photosPicker`, `.fileImporter`, the camera `.fullScreenCover`,
// and the camera-denied alert), driven by a shared
// `ComposerAttachmentCoordinator`. Both hosts (ContentView/iPhone and
// ConversationLibraryView/iPad) mount THIS instead of the bare composer so the
// staging plumbing lives in exactly one place.
//
// Send flow: the container's `onSendText` converts the coordinator's resolved
// staged items into `[PendingAttachment]`, forwards them with the typed text to
// the host's `onSend`, then clears staging. Send is blocked by the composer
// itself while any item is `.loading`.

import SwiftUI
import PhotosUI

struct AttachmentComposerContainer: View {
    let viewModel: ConversationDetailViewModel?
    var recorder: InAppAudioRecorder
    @Binding var draft: String
    /// Shared staging coordinator (host-owned `@State`).
    @Bindable var coordinator: ComposerAttachmentCoordinator
    /// Send a turn (text + resolved attachments). The host mints the
    /// conversation + routes to the VM, mirroring the voice/text paths.
    let onSend: (_ text: String, _ attachments: [PendingAttachment]) async -> Void
    /// Forward an STT voice result (host routes success/failure + pending retry).
    let onVoiceResult: (Result<String, AppError>) async -> Void
    /// STABLE host-owned Settings VM, reused for the file-transfer setup sheet.
    /// MUST be a single instance owned by the host (`ContentView` /
    /// `ConversationLibraryView`) — constructing a throwaway per sheet would
    /// re-trigger a full settings load + leak an un-retained observer each time.
    let settingsVM: SettingsViewModel
    /// The host's AUTHORITATIVE new-conversation gateway selection (the picker
    /// choice the next minted conversation binds to). Used to scope the setup
    /// sheet for a brand-new (VM-less) conversation to the RIGHT gateway, not the
    /// compile-time default.
    let pendingNewConversationRef: RemoteAgentRef

    /// Resolved file-transfer state for the composer's bound gateway. `available`
    /// drives the "Set Up File Transfer…" discovery item; `ref` is the
    /// upload/retry/orphan-DELETE + setup-scope target. Resolved on appear, on a
    /// conversation (VM) change, and on `.settingsDidChangeRemotely`.
    /// `effectiveRef` = the bound conversation's ref, else the host's authoritative
    /// pending ref (a brand-new/empty composer).
    @State private var fileTransferAvailable = false
    @State private var effectiveRef: RemoteAgentRef = .builtin(Constants.remoteAgentDefaultBackendDefault)
    /// Whether the file-transfer setup sheet is presented (menu item or a tile's
    /// "Set Up" button). On dismiss the host refreshes file-transfer state AND
    /// promotes any `.needsSetup` tiles to uploads.
    @State private var showingSetupGuide = false

    var body: some View {
        iOSMessageComposerBar(
            viewModel: viewModel,
            recorder: recorder,
            draft: $draft,
            attachments: $coordinator.staged,
            progressByID: coordinator.progressByID,
            onSendText: { text in
                // Bounded ~2s upload join: give a freshly-staged dual attachment
                // (`.dualText` / `.dualImage`) whose eager upload is still in
                // flight a brief window to land so its storedKey rides this turn's
                // "also on disk" ref. Never blocks — past the deadline the file
                // rides inline-only (the disk ref defers to a later turn).
                await coordinator.awaitPreferredUploads()
                let pending = coordinator.staged.pendingAttachments
                coordinator.clear()
                await onSend(text, pending)
            },
            onVoiceResult: onVoiceResult,
            onPickLibrary: { coordinator.pickLibrary() },
            onTakePhoto: { coordinator.takePhoto() },
            onPickFiles: { coordinator.pickFiles() },
            onSetUpFileTransfer: { showingSetupGuide = true },
            fileTransferAvailable: fileTransferAvailable,
            onRemoveAttachment: { removeAttachment($0) },
            onRetryUpload: { id in
                coordinator.retryServerUpload(id: id, vm: viewModel, ref: effectiveRef)
            },
            onSetUpAttachment: { _ in showingSetupGuide = true }
        )
        // Photo library — NO maxSelectionCount (no cap, locked).
        .photosPicker(
            isPresented: $coordinator.showingPhotosPicker,
            selection: $coordinator.pickerSelection,
            matching: .images
        )
        .onChange(of: coordinator.pickerSelection) { _, items in
            coordinator.handlePickerSelection(items, vm: viewModel, ref: effectiveRef)
        }
        // UNIFIED "Choose Files…" importer — accepts ANY file (broad type set so
        // PDFs / videos / archives are NOT greyed out). The coordinator's
        // classifier routes each pick (image → inline; text → inline/dual; binary
        // → server or a `.needsSetup` tile, with the >100 MB soft-confirm).
        .fileImporter(
            isPresented: $coordinator.showingFileImporter,
            allowedContentTypes: ComposerAttachmentTypes.unifiedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            coordinator.handleUnifiedImport(result, vm: viewModel, ref: effectiveRef)
        }
        .task(id: viewModel?.conversationID) {
            await refreshFileTransfer()
            // A VM-less new conversation may have staged `.needsSetup` tiles for a
            // gateway that IS configured (no VM to upload at pick time). Once the
            // first turn mints the VM, promote them so they upload + unblock Send.
            await coordinator.promoteNeedsSetupTiles(vm: viewModel, ref: effectiveRef)
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
            Task {
                await refreshFileTransfer()
                // Setup can finish remotely (iCloud sync / another device) — try a
                // promote so a `.needsSetup` tile unblocks without re-opening.
                await coordinator.promoteNeedsSetupTiles(vm: viewModel, ref: effectiveRef)
            }
        }
        // The user can switch the NEW-conversation gateway picker while the
        // composer is VM-less — re-resolve so the menu's discovery item, the setup
        // sheet's scope, and the binary route all track the gateway the next turn
        // will actually bind to. VM-less tiles RE-STAMP to the new gateway (the
        // next turn definitionally binds there) and then promote if it has a
        // server; a conversation-bound composer never re-stamps.
        .onChange(of: pendingNewConversationRef) {
            Task {
                await refreshFileTransfer()
                if viewModel == nil {
                    coordinator.restampNeedsSetupTiles(to: effectiveRef)
                }
                await coordinator.promoteNeedsSetupTiles(vm: viewModel, ref: effectiveRef)
            }
        }
        // File-transfer setup guide (sheet) scoped to the bound gateway. On
        // dismiss: refresh file-transfer state AND auto-promote any `.needsSetup`
        // tiles to uploads (the user may have just set up the server).
        .sheet(isPresented: $showingSetupGuide, onDismiss: {
            Task {
                await refreshFileTransfer()
                await coordinator.promoteNeedsSetupTiles(vm: viewModel, ref: effectiveRef)
            }
        }) {
            NavigationStack {
                // Cancel/Save chrome (and the ready-and-clean auto-dismiss) come
                // from the content's `bufferedEditorChrome` — no host Done button.
                FileTransferSetupGuideView(viewModel: settingsVM, ref: effectiveRef, titleOverride: setupSheetTitle, context: .composer)
            }
        }
        // Large-file soft-confirm (>100 MB). Names the file + formatted size;
        // Attach stages it (server / needsSetup), Cancel discards. Multiple large
        // files present one at a time (the coordinator queues them; the computed
        // binding re-presents for the next head). GOTCHA (load-bearing): the
        // binding's setter MUST be a no-op — SwiftUI sets `isPresented = false` on
        // EVERY button tap, including Attach, so a cancel-in-setter would discard
        // the file the user just confirmed. Cancellation is ONLY the cancel-role
        // button (which also covers Esc on iPad hardware keyboards).
        .alert(
            LocalizedStringResource("fileTransfer.softConfirm.title", defaultValue: "Attach large file?"),
            isPresented: Binding(
                get: { coordinator.pendingLargeFile != nil },
                set: { _ in }
            ),
            presenting: coordinator.pendingLargeFile
        ) { file in
            Button(LocalizedStringResource("fileTransfer.softConfirm.attach", defaultValue: "Attach")) {
                coordinator.confirmPendingLargeFile(vm: viewModel)
            }
            Button(LocalizedStringResource("fileTransfer.softConfirm.cancel", defaultValue: "Cancel"), role: .cancel) {
                coordinator.cancelPendingLargeFile()
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
        // Camera (JIT permission gated by the coordinator before presenting).
        .fullScreenCover(isPresented: $coordinator.showingCamera) {
            CameraPicker(
                onCapture: { coordinator.stageCameraImage($0, vm: viewModel, ref: effectiveRef) },
                onDismiss: { coordinator.showingCamera = false }
            )
            .ignoresSafeArea()
        }
        // Camera access denied — inline alert with an Open Settings action.
        .alert(
            LocalizedStringResource("composer.camera.deniedTitle", defaultValue: "Camera access is off"),
            isPresented: $coordinator.showingCameraDeniedAlert
        ) {
            Button(LocalizedStringResource("composer.camera.openSettings", defaultValue: "Open Settings")) {
                CameraPermission.openSettings()
            }
            Button(LocalizedStringResource("composer.camera.cancel", defaultValue: "Cancel"), role: .cancel) { }
        } message: {
            Text(LocalizedStringResource(
                "composer.camera.deniedMessage",
                defaultValue: "Allow camera access in Settings to take a photo."
            ))
        }
    }

    /// The setup-sheet title — the bound gateway's display name (resolved via the
    /// stable Settings VM's cached roster) so the user sees WHICH gateway they're
    /// configuring file transfer for.
    private var setupSheetTitle: String {
        settingsVM.displayName(for: effectiveRef)
    }

    /// Remove a staged item. Routes a server tile through the coordinator's
    /// cancel-aware remove (cancels the upload + DELETEs an orphan via the ref —
    /// works VM-less too); a plain non-server remove otherwise.
    private func removeAttachment(_ id: UUID) {
        coordinator.remove(id, vm: viewModel, ref: effectiveRef)
    }

    /// Resolve the effective ref (bound conversation, else the host's pending
    /// new-conversation gateway) + whether its file-server is READY (saved +
    /// test passed — drives the "Set Up File Transfer…" discovery item + the
    /// binary route).
    private func refreshFileTransfer() async {
        guard let vm = viewModel else {
            // Brand-new (VM-less) conversation: scope to the host's AUTHORITATIVE
            // pending gateway (the picker choice the next mint binds to), NOT the
            // compile-time default — so a setup sheet opened from the new-chat
            // composer targets the right gateway.
            effectiveRef = pendingNewConversationRef
            fileTransferAvailable = (await SettingsManager.shared.fileTransferReadySnapshot(for: pendingNewConversationRef)) != nil
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
        } else {
            // No persisted backend (brand-new conversation) → the gateway the
            // first turn will bind to is the default.
            ref = await SettingsManager.shared.defaultRemoteAgentRef()
        }
        effectiveRef = ref
        fileTransferAvailable = (await SettingsManager.shared.fileTransferReadySnapshot(for: ref)) != nil
    }
}
#endif

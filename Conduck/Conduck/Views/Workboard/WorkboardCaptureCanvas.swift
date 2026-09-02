// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardCaptureCanvas.swift
//
// The desk's capture surface. A typed thought, picker result, or drop is
// persisted as inert Work and nothing else: this view has no transport
// dependency of any kind, so capture can never become a send.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum WorkboardCaptureCanvasMode: Sendable {
    case sources
    case composer
}

/// Work is ONE desk, so capture has a single destination and its copy names no
/// target: there is nothing to choose between and no title to interpolate.
/// `private` because a host does not pick it — the canvas and the pane-wide drop
/// state it, which is what keeps a second destination from creeping back in.
private enum WorkboardCaptureDestination: Equatable, Sendable {
    case desk

    var composerPrompt: LocalizedStringResource {
        LocalizedStringResource(
            "workboard.workspace.composer.prompt",
            defaultValue: "Add to Work…"
        )
    }

    var dropTitle: LocalizedStringResource {
        LocalizedStringResource(
            "workboard.workspace.drop.overlay.title",
            defaultValue: "Drop into Work"
        )
    }

    var dropCaption: LocalizedStringResource {
        LocalizedStringResource(
            "workboard.workspace.drop.overlay.caption",
            defaultValue: "Files, photos, screenshots, links and text will be added here. Nothing is sent."
        )
    }
}

struct WorkboardCaptureCanvas: View {
    @Bindable var viewModel: WorkboardViewModel
    /// The desk as it stands: the cards to draw, and the count a photo name
    /// numbers from. Every write below addresses `Constants.workboardDeskItemID`
    /// rather than this snapshot's id, so capture on the desk-before-its-first-
    /// material canvas lands on the same identity the first card will.
    let item: WorkboardItemSnapshot
    let mode: WorkboardCaptureCanvasMode

    /// Capture always lands on the desk, so the destination is a constant the
    /// canvas states rather than an argument a host chooses.
    private let destination = WorkboardCaptureDestination.desk

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        viewModel: WorkboardViewModel,
        item: WorkboardItemSnapshot,
        mode: WorkboardCaptureCanvasMode
    ) {
        self.viewModel = viewModel
        self.item = item
        self.mode = mode
    }

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var materialPendingReattachment: WorkboardMaterialSnapshot?
    @State private var showsVoiceCapture = false
    @State private var showsLinkComposer = false
    @State private var largeImportConfirmation: WorkboardWorkspaceLargeImportConfirmation?
    @State private var isAddingThought = false
    /// The shared account-level monitor, observed rather than copied: the desk
    /// and the conversation list must never disagree about whether iCloud is
    /// signed in, nor about whether this outage's banner was already dismissed.
    @State private var syncMonitor = CloudSyncMonitor.shared
    @FocusState private var composerFocused: Bool
    #if os(iOS)
    @State private var showsCamera = false
    @State private var showsCameraDeniedAlert = false
    #endif

    private var isImporting: Bool {
        viewModel.isCapturingIntoDesk
    }

    var body: some View {
        Group {
            if mode == .composer {
                pinnedComposer
            } else {
                // No container around the cards: the WHOLE pane is the drop
                // target, and a bordered surface would read as the one place a
                // drop lands. An empty desk therefore renders nothing here —
                // the one-time tutorial teaches capture, the pane accepts it.
                boardStack
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fileImporter(
            isPresented: activeFileImporterIsPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: materialPendingReattachment == nil,
            onCompletion: handleFileImport
        )
        .photosPicker(
            isPresented: activePhotoPickerIsPresented,
            selection: $photoSelection,
            maxSelectionCount: 12,
            matching: .images
        )
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            guard workbenchDestinationIsActive else {
                photoSelection.removeAll()
                return
            }
            Task { await importPhotos(selection) }
        }
        .sheet(isPresented: activeLinkComposerIsPresented) {
            WorkboardTextMaterialSheet { materialImport in
                Task { await viewModel.importMaterials([materialImport]) }
            }
        }
        .sheet(isPresented: activeVoiceCaptureIsPresented) {
            WorkboardVoiceCaptureView(
                target: .context,
                onTranscript: { transcript in
                    viewModel.setComposerDraft(appending(transcript, to: composerText))
                    showsVoiceCapture = false
                    composerFocused = true
                },
                onCancel: { showsVoiceCapture = false }
            )
        }
        #if os(iOS)
        .fullScreenCover(isPresented: activeCameraIsPresented) {
            CameraPicker(
                onCapture: importCameraPhoto,
                onDismiss: { showsCamera = false }
            )
        }
        .alert(
            LocalizedStringResource("composer.camera.deniedTitle", defaultValue: "Camera access is off"),
            isPresented: activeCameraDeniedIsPresented
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
        #endif
        .workboardLargeImportAlert(
            item: activeLargeImportConfirmation,
            onConfirm: { confirmation in
                largeImportConfirmation = nil
                Task { await importResolvedBatch(confirmation.batch) }
            },
            onCancel: { confirmation in
                largeImportConfirmation = nil
                WorkboardImportMapping.reclaim(confirmation.batch)
            }
        )
        .onDisappear {
            dismissTransientCaptureUI()
        }
        .onChange(of: workbenchDestinationIsActive) { _, isActive in
            if !isActive { dismissTransientCaptureUI() }
        }
    }

    private var activeFileImporterIsPresented: Binding<Bool> {
        $showsFileImporter.gated(by: workbenchDestinationIsActive)
    }

    private var activePhotoPickerIsPresented: Binding<Bool> {
        $showsPhotoPicker.gated(by: workbenchDestinationIsActive)
    }

    private var activeVoiceCaptureIsPresented: Binding<Bool> {
        $showsVoiceCapture.gated(by: workbenchDestinationIsActive)
    }

    private var activeLinkComposerIsPresented: Binding<Bool> {
        $showsLinkComposer.gated(by: workbenchDestinationIsActive)
    }

    private var activeLargeImportConfirmation: Binding<WorkboardWorkspaceLargeImportConfirmation?> {
        $largeImportConfirmation.gated(by: workbenchDestinationIsActive)
    }

    #if os(iOS)
    private var activeCameraIsPresented: Binding<Bool> {
        $showsCamera.gated(by: workbenchDestinationIsActive)
    }

    private var activeCameraDeniedIsPresented: Binding<Bool> {
        $showsCameraDeniedAlert.gated(by: workbenchDestinationIsActive)
    }
    #endif

    private func dismissTransientCaptureUI() {
        if showsPhotoPicker { showsPhotoPicker = false }
        if !photoSelection.isEmpty { photoSelection.removeAll() }
        if showsFileImporter { showsFileImporter = false }
        if materialPendingReattachment != nil { materialPendingReattachment = nil }
        if showsVoiceCapture { showsVoiceCapture = false }
        if showsLinkComposer { showsLinkComposer = false }
        #if os(iOS)
        if showsCamera { showsCamera = false }
        if showsCameraDeniedAlert { showsCameraDeniedAlert = false }
        #endif
        if let confirmation = largeImportConfirmation {
            WorkboardImportMapping.reclaim(confirmation.batch)
            largeImportConfirmation = nil
        }
        if composerFocused { composerFocused = false }
    }

    /// The desk's sync notice, and the whole of it. It is driven by ACCOUNT
    /// state — signed out, restricted, storage full — because those are the only
    /// states a person can act on and the only ones that hold for every card at
    /// once. A failed sync EVENT is deliberately not a trigger: card metadata and
    /// card bytes are mirrored from two separate stores, so the most recent
    /// failure can concern one payload while the rest of the desk is syncing
    /// normally, and a banner is a claim about all of it.
    ///
    /// The dismissal is the same sticky per-outage flag the conversation list's
    /// banner uses, on purpose: the account is broken in one place, so saying so
    /// twice and asking to be dismissed twice would be the same interruption
    /// charged again.
    @ViewBuilder
    private var deskSyncBanner: some View {
        if syncMonitor.showsBanner, let reason = syncMonitor.unavailableReason {
            ICloudUnavailableBanner(reason: reason) {
                syncMonitor.dismissBanner()
            }
        }
    }

    /// The only surviving canvas status: it exists while an import is running
    /// and disappears with it, so it costs the de-texted board nothing at rest.
    @ViewBuilder
    private var importProgress: some View {
        if let state = viewModel.importState {
            let progressText = String.localizedStringWithFormat(
                String(localized: LocalizedStringResource(
                    "workboard.workspace.import.progress",
                    defaultValue: "%1$lld of %2$lld"
                )),
                Int64(state.completedCount),
                Int64(state.totalCount)
            )
            HStack(spacing: 8) {
                ProgressView(value: state.progress)
                    .frame(width: 92)
                Text(verbatim: progressText)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(LocalizedStringResource(
                "workboard.material.importing",
                defaultValue: "Adding materials"
            )))
            .accessibilityValue(Text(verbatim: progressText))
        }
    }

    /// Import status plus the cards, and nothing else. An empty board draws no
    /// placeholder: it is indistinguishable from the pane behind it, which is
    /// what makes the whole pane read as the drop target.
    @ViewBuilder
    private var boardStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            deskSyncBanner
            importProgress
            if !item.materials.isEmpty {
                WorkboardMaterialBoard(
                    viewModel: viewModel,
                    item: item,
                    onOpen: openMaterial,
                    onReattach: beginReattachment
                )
            }
        }
    }

    /// The desk's one door to the preview router, and the gate in front of it.
    /// `WorkboardCardActionPolicy` decides what this card's bytes allow, so a
    /// card still waiting for iCloud reaches nothing: opening it would present a
    /// thumbnail in place of the material, and offering to reattach it would ask
    /// a person to repair bytes that are already on their way.
    private func openMaterial(_ material: WorkboardMaterialSnapshot) {
        WorkboardCardActionPolicy.performPrimaryAction(
            for: material.availability,
            open: { viewModel.openMaterial(material) },
            reattach: { beginReattachment(material) }
        )
    }

    private func beginReattachment(_ material: WorkboardMaterialSnapshot) {
        guard workbenchDestinationIsActive else { return }
        materialPendingReattachment = material
        showsFileImporter = true
    }

    /// Work's pinned bar IS Chat's composer card — same chrome, same compact
    /// docked row — with Work's wiring behind it (text becomes a note, attach
    /// imports material, the mic captures a thought). The outer 16/12 is the
    /// bar's inset around the card; the card's own inset comes from
    /// `composerCardChrome()`, exactly as in Chat.
    ///
    /// The column is CHAT's — `composerReadableWidth()`, never the board's
    /// `contentMaxWidth` — and it is applied at the SAME point in the chain as
    /// Chat's own bar applies it on that platform, because the two Chat bars put
    /// it in different places and the card width follows the position:
    /// - macOS — `MainWindowView` caps the padded bar, so the cap goes AFTER the
    ///   16/12 inset here too and the card lands one bar-inset narrower.
    /// - iOS — `iOSMessageComposerBar.regularLayout` caps the CARD, inside the
    ///   inset, so the cap goes on `composerCard`. The compact docked row takes no
    ///   cap at all, exactly as in Chat's `compactLayout`.
    ///
    /// The host's material band is unaffected: the modifier's second frame
    /// re-expands to `.infinity`, so the band still reaches both window edges even
    /// though the card inside it does not.
    private var pinnedComposer: some View {
        Group {
            if usesComposerCard {
                #if os(macOS)
                composerCard
                #else
                composerCard.composerReadableWidth()
                #endif
            } else {
                compactComposerRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #if os(macOS)
        .composerReadableWidth()
        #endif
    }

    /// The same rule Chat's iOS composer uses (`usesRegularLayout`): a card on
    /// macOS and wide iPad, a docked single row everywhere narrower. Reading it
    /// from one place keeps the layout and the field's chrome from disagreeing.
    private var usesComposerCard: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular && DeviceCapabilities.isiPad
        #endif
    }

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            composerField(lineLimit: composerLineLimit, inCard: true)

            HStack(spacing: 10) {
                attachmentMenu
                Spacer(minLength: 8)
                voiceButton
                addThoughtButton
            }
        }
        .composerCardChrome()
        // Chat's focus assist, verbatim: the field is only as tall as its text,
        // so the card's padding is a dead zone unless a BEHIND-content hit layer
        // claims it. Never `.overlay` — that would steal clicks from the field
        // and the buttons — and hidden from accessibility so VoiceOver hears one
        // field rather than an unlabeled phantom element.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { composerFocused = true }
                .accessibilityHidden(true)
        )
    }

    private var compactComposerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachmentMenu
            composerField(lineLimit: composerLineLimit)
            voiceButton
            addThoughtButton
        }
    }

    private var composerLineLimit: ClosedRange<Int> {
        #if os(macOS)
        1...12
        #else
        1...6
        #endif
    }

    private var attachmentMenu: some View {
        WorkboardMaterialActions(
            presentation: .menu,
            onPickPhotos: {
                guard workbenchDestinationIsActive else { return }
                showsPhotoPicker = true
            },
            onTakePhoto: takePhoto,
            onPickFiles: {
                guard workbenchDestinationIsActive else { return }
                showsFileImporter = true
            },
            onAddLink: {
                guard workbenchDestinationIsActive else { return }
                showsLinkComposer = true
            },
            iconPointSize: attachmentIconPointSize,
            iconFrame: composerControlDiameter
        )
        .disabled(!workbenchDestinationIsActive || isImporting)
        .accessibilityLabel(Text(LocalizedStringResource(
            "workboard.workspace.attach",
            defaultValue: "Attach to Work"
        )))
    }

    /// `inCard` suppresses the field's own fill, inset and stroke: inside the
    /// composer card that chrome would read as a card in a card, which is the
    /// same reason Chat's iOS field clears its fill in the regular layout.
    private func composerField(
        lineLimit: ClosedRange<Int>,
        inCard: Bool = false
    ) -> some View {
        TextField(
            String(localized: destination.composerPrompt),
            text: composerTextBinding,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.body)
        .foregroundStyle(AppColors.textPrimary)
        .lineLimit(lineLimit)
        .focused($composerFocused)
        .padding(.horizontal, inCard ? 0 : 12)
        .padding(.vertical, inCard ? 0 : 10)
        .frame(maxWidth: .infinity, minHeight: inCard ? nil : WorkboardMetrics.touchTarget)
        .background(
            inCard ? Color.clear : AppColors.backgroundSecondary,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            if !inCard {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        composerFocused ? AppColors.brandAmber.opacity(0.65) : AppColors.borderSubtle,
                        lineWidth: 1
                    )
            }
        }
    }

    private var voiceButton: some View {
        CaptureCircleButton(
            symbol: "mic.fill",
            fillColor: AppColors.brandAmber,
            diameter: composerControlDiameter,
            glyphSize: composerGlyphSize,
            isDisabled: !workbenchDestinationIsActive || isImporting || isAddingThought,
            accessibilityLabel: String(localized: LocalizedStringResource(
                "workboard.voice.capture",
                defaultValue: "Add by voice"
            )),
            action: {
                guard workbenchDestinationIsActive else { return }
                showsVoiceCapture = true
            }
        )
    }

    private var addThoughtButton: some View {
        // The one statement of "this draft holds a thought" lives on the view
        // model, so the button and the capture path cannot disagree about
        // whether there is anything to add.
        let isDisabled = !workbenchDestinationIsActive
            || !viewModel.hasComposerDraft
            || isImporting
            || isAddingThought
        return CaptureCircleButton(
            symbol: isAddingThought ? "ellipsis" : "arrow.up",
            fillColor: isDisabled ? AppColors.disabled : AppColors.brandAmber,
            diameter: composerControlDiameter,
            glyphSize: composerGlyphSize,
            isDisabled: isDisabled,
            accessibilityLabel: String(localized: LocalizedStringResource(
                "workboard.workspace.add",
                defaultValue: "Add to Work"
            )),
            action: addThought
        )
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityHint(Text(LocalizedStringResource(
            "workboard.workspace.add.hint",
            defaultValue: "Saves this thought privately. Nothing is sent to an AI."
        )))
    }

    private var composerControlDiameter: CGFloat {
        #if os(macOS)
        32
        #else
        WorkboardMetrics.touchTarget
        #endif
    }

    private var composerGlyphSize: CGFloat {
        #if os(macOS)
        14
        #else
        18
        #endif
    }

    private var attachmentIconPointSize: CGFloat {
        #if os(macOS)
        20
        #else
        22
        #endif
    }

    private func takePhoto() {
        #if os(iOS)
        guard workbenchDestinationIsActive else { return }
        switch CameraPermission.current {
        case .proceed: showsCamera = true
        case .denied: showsCameraDeniedAlert = true
        }
        #endif
    }

    private var cleanComposerText: String {
        WorkboardWorkspaceCaptureLogic.normalizedThought(composerText)
    }

    private var composerText: String {
        viewModel.composerDraft
    }

    private var composerTextBinding: Binding<String> {
        Binding(
            get: { viewModel.composerDraft },
            set: { viewModel.setComposerDraft($0) }
        )
    }

    private func addThought() {
        let thought = cleanComposerText
        guard workbenchDestinationIsActive,
              !thought.isEmpty,
              !isAddingThought else { return }
        isAddingThought = true
        Task {
            let added = await viewModel.addThought(thought)
            if added {
                viewModel.setComposerDraft("")
                let message = String(localized: LocalizedStringResource(
                    "workboard.workspace.thought.saved",
                    defaultValue: "Added to Work. Nothing was sent."
                ))
                viewModel.workspaceStatus = WorkboardTransientStatus(message: message)
                AccessibilityAnnouncer.announce(message)
            }
            isAddingThought = false
            composerFocused = workbenchDestinationIsActive && !added
        }
    }

    // MARK: - Picker imports

    #if os(iOS)
    private func importCameraPhoto(_ data: Data) {
        showsCamera = false
        guard workbenchDestinationIsActive, !data.isEmpty else { return }
        let name = String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.material.photo.defaultName",
                defaultValue: "Photo %lld"
            )),
            Int64(item.materials.count + 1)
        )
        let batch = WorkboardResolvedImportBatch(
            items: [.image(data: data, displayName: name)],
            failedCount: 0
        )
        Task { await importResolvedBatch(batch) }
    }
    #endif

    private func importPhotos(_ selection: [PhotosPickerItem]) async {
        defer { photoSelection = [] }
        guard !viewModel.isCapturingIntoDesk else { return }
        var items: [WorkboardResolvedImportItem] = []
        var failures = 0
        for (offset, pickerItem) in selection.enumerated() {
            do {
                guard let data = try await pickerItem.loadTransferable(type: Data.self), !data.isEmpty else {
                    failures += 1
                    continue
                }
                items.append(.image(
                    data: data,
                    displayName: String.localizedStringWithFormat(
                        String(localized: LocalizedStringResource(
                            "workboard.material.photo.defaultName",
                            defaultValue: "Photo %lld"
                        )),
                        Int64(item.materials.count + offset + 1)
                    )
                ))
            } catch {
                failures += 1
            }
        }
        let batch = WorkboardResolvedImportBatch(items: items, failedCount: failures)
        guard !batch.items.isEmpty || batch.failedCount > 0 else { return }
        if batch.hasLargeFiles {
            largeImportConfirmation = WorkboardWorkspaceLargeImportConfirmation(batch: batch)
        } else {
            await importResolvedBatch(batch)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        Task {
            do {
                let urls = try result.get()
                if let material = materialPendingReattachment {
                    materialPendingReattachment = nil
                    guard let replacementURL = urls.first else { return }
                    await reattach(material, from: replacementURL)
                    return
                }
                let batch = await resolvedPickerBatch(urls)
                guard !batch.items.isEmpty || batch.failedCount > 0 else { return }
                if batch.hasLargeFiles {
                    largeImportConfirmation = WorkboardWorkspaceLargeImportConfirmation(batch: batch)
                } else {
                    await importResolvedBatch(batch)
                }
            } catch {
                materialPendingReattachment = nil
                if (error as NSError).code == NSUserCancelledError { return }
                viewModel.notice = WorkboardNotice(
                    kind: .error,
                    title: LocalizedStringResource(
                        "workboard.material.file.failed.title",
                        defaultValue: "Couldn’t add a file"
                    ),
                    message: error.localizedDescription
                )
            }
        }
    }

    @MainActor
    private func reattach(_ material: WorkboardMaterialSnapshot, from url: URL) async {
        let batch = await resolvedPickerBatch([url])
        guard case .file(let sourceURL, let name, let mimeType, let byteCount, _) = batch.items.first else {
            viewModel.presentImportReport(
                WorkboardImportReport(addedCount: 0, failedCount: 1 + batch.failedCount)
            )
            return
        }
        let replacement = WorkboardMaterialImport(
            kind: material.kind,
            name: name,
            detail: byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
            mimeType: mimeType,
            fileURL: sourceURL,
            byteCount: byteCount
        )
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        await viewModel.reattachMaterial(material, with: replacement)
    }

    private func resolvedPickerBatch(_ urls: [URL]) async -> WorkboardResolvedImportBatch {
        await Task.detached(priority: .userInitiated) {
            var items: [WorkboardResolvedImportItem] = []
            var failures = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard !ComposerDropRouting.isDirectory(url),
                      let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]) else {
                    failures += 1
                    continue
                }
                items.append(.file(
                    sourceURL: url,
                    displayName: url.lastPathComponent,
                    mimeType: values.contentType?.preferredMIMEType,
                    byteCount: values.fileSize.map(Int64.init),
                    isAppOwned: false
                ))
            }
            return WorkboardResolvedImportBatch(items: items, failedCount: failures)
        }.value
    }

    @MainActor
    private func importResolvedBatch(_ batch: WorkboardResolvedImportBatch) async {
        let mapped = WorkboardImportMapping.imports(from: batch)
        await viewModel.importMaterials(
            mapped.imports,
            additionalFailureCount: batch.failedCount
        )
        for url in mapped.scopedURLs { url.stopAccessingSecurityScopedResource() }
        WorkboardImportMapping.reclaim(batch)
    }

    private func appending(_ addition: String, to existing: String) -> String {
        let clean = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? addition : "\(clean)\n\n\(addition)"
    }
}

// MARK: - One pane-wide drop owner

extension View {
    /// Makes the complete Work detail region a capture target. This deliberately
    /// lives above both the scrolling canvas and pinned composer: nested drop
    /// handlers caused the composer to reject a valid drop while the populated
    /// desk had no handler at all. A drop names no target: the desk is the only
    /// one there is.
    func workboardPaneDropDestination(viewModel: WorkboardViewModel) -> some View {
        modifier(WorkboardPaneDropModifier(viewModel: viewModel))
    }
}

private struct WorkboardPaneDropModifier: ViewModifier {
    @Bindable var viewModel: WorkboardViewModel

    private let destination = WorkboardCaptureDestination.desk

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive
    @State private var isDropTargeted = false
    @State private var dropSession: DropSession<WorkboardResolvedDropSlot>?
    @State private var dropProgresses: [Progress] = []
    @State private var dropTimeoutTasks: [Task<Void, Never>] = []
    @State private var largeImportConfirmation: WorkboardWorkspaceLargeImportConfirmation?

    private var isImporting: Bool {
        viewModel.isCapturingIntoDesk || dropSession != nil
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                if isDropTargeted, !isImporting {
                    dropOverlay
                        .transition(.opacity)
                }
            }
            .onDrop(
                of: [.fileURL, .image, .url, .utf8PlainText],
                isTargeted: $isDropTargeted,
                perform: handleDrop
            )
            .workboardLargeImportAlert(
                item: activeLargeImportConfirmation,
                onConfirm: { confirmation in
                    largeImportConfirmation = nil
                    Task { await importResolvedBatch(confirmation.batch) }
                },
                onCancel: { confirmation in
                    largeImportConfirmation = nil
                    WorkboardImportMapping.reclaim(confirmation.batch)
                }
            )
            .onChange(of: workbenchDestinationIsActive) { _, isActive in
                if !isActive { cancelDropWork() }
            }
            .onDisappear(perform: cancelDropWork)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isDropTargeted)
    }

    private var activeLargeImportConfirmation: Binding<WorkboardWorkspaceLargeImportConfirmation?> {
        $largeImportConfirmation.gated(by: workbenchDestinationIsActive)
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppColors.brandAmber.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            AppColors.brandAmber,
                            style: StrokeStyle(lineWidth: 2.5, dash: [9, 6])
                        )
                }

            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AppColors.brandAmber)
                Text(destination.dropTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColors.textEmphasis)
                Text(destination.dropCaption)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColors.borderSubtle, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
            .padding(28)
        }
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isImporting, dropSession == nil else { return false }
        let routed = providers.compactMap { provider -> (NSItemProvider, WorkboardDropProviderRoute)? in
            guard let route = WorkboardDropProviderRoute(provider: provider) else { return nil }
            return (provider, route)
        }
        guard !routed.isEmpty else {
            viewModel.presentImportReport(
                WorkboardImportReport(addedCount: 0, failedCount: providers.count)
            )
            return !providers.isEmpty
        }

        let session = DropSession<WorkboardResolvedDropSlot>(
            count: routed.count,
            initialFailureCount: providers.count - routed.count
        )
        dropSession = session
        for (index, entry) in routed.enumerated() {
            startDropLoad(entry.0, route: entry.1, index: index, session: session)
        }
        return true
    }

    private func startDropLoad(
        _ provider: NSItemProvider,
        route: WorkboardDropProviderRoute,
        index: Int,
        session: DropSession<WorkboardResolvedDropSlot>
    ) {
        let progress: Progress
        switch route {
        case .fileURL, .imageData:
            let identifier = route == .fileURL ? UTType.fileURL.identifier : UTType.image.identifier
            progress = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                let resolved = Self.resolveDroppedData(data, route: route, index: index)
                Task { @MainActor in finishDropSlot(index, with: resolved, session: session) }
            }
        case .webURL:
            progress = provider.loadObject(ofClass: NSURL.self) { object, _ in
                let resolved: WorkboardResolvedDropSlot
                if let value = object as? NSURL {
                    resolved = .value(.text((value as URL).absoluteString))
                } else {
                    resolved = .failed
                }
                Task { @MainActor in finishDropSlot(index, with: resolved, session: session) }
            }
        case .plainText:
            progress = provider.loadObject(ofClass: NSString.self) { object, _ in
                let text = (object as? NSString)
                    .map(String.init)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? ""
                let resolved: WorkboardResolvedDropSlot = text.isEmpty ? .failed : .value(.text(text))
                Task { @MainActor in finishDropSlot(index, with: resolved, session: session) }
            }
        }
        dropProgresses.append(progress)

        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Constants.dropProviderLoadTimeoutSeconds))
            guard !Task.isCancelled, !session.isFinished else { return }
            progress.cancel()
            finishDropSlot(index, with: .failed, session: session)
        }
        dropTimeoutTasks.append(timeout)
    }

    nonisolated private static func resolveDroppedData(
        _ data: Data?,
        route: WorkboardDropProviderRoute,
        index: Int
    ) -> WorkboardResolvedDropSlot {
        guard let data, !data.isEmpty else { return .failed }
        switch route {
        case .imageData:
            let format = ImageFormatSniffer.sniff(data)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("conduck-workboard-drop-\(UUID().uuidString).\(format.ext)")
            do {
                try data.write(to: destination, options: [.atomic])
                return .value(.imageFile(
                    sourceURL: destination,
                    displayName: String(
                        localized: "workboard.workspace.drop.image",
                        defaultValue: "Dropped image \(index + 1).\(format.ext)"
                    ),
                    mimeType: format.mime,
                    byteCount: Int64(data.count)
                ))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return .failed
            }
        case .fileURL:
            guard let url = URL(dataRepresentation: data, relativeTo: nil),
                  !ComposerDropRouting.isDirectory(url) else { return .failed }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            guard let stagedURL = AttachmentStagingFile.copyUnderScope(url) else { return .failed }
            return .value(.file(
                sourceURL: stagedURL,
                displayName: url.lastPathComponent,
                mimeType: values?.contentType?.preferredMIMEType,
                byteCount: values?.fileSize.map(Int64.init),
                isAppOwned: true
            ))
        case .webURL, .plainText:
            return .failed
        }
    }

    @MainActor
    private func finishDropSlot(
        _ index: Int,
        with result: WorkboardResolvedDropSlot,
        session: DropSession<WorkboardResolvedDropSlot>
    ) {
        guard dropSession === session else {
            reclaim(result)
            return
        }
        if case .rejected(let orphan) = session.resolve(index: index, with: result), let orphan {
            try? FileManager.default.removeItem(at: orphan)
        }
        guard let batch = session.takeBatch() else { return }
        clearDropLoadBookkeeping()
        dropSession = nil
        if batch.hasLargeFiles {
            largeImportConfirmation = WorkboardWorkspaceLargeImportConfirmation(batch: batch)
        } else {
            Task { await importResolvedBatch(batch) }
        }
    }

    @MainActor
    private func importResolvedBatch(_ batch: WorkboardResolvedImportBatch) async {
        let mapped = WorkboardImportMapping.imports(from: batch)
        await viewModel.importMaterials(
            mapped.imports,
            additionalFailureCount: batch.failedCount
        )
        for url in mapped.scopedURLs { url.stopAccessingSecurityScopedResource() }
        WorkboardImportMapping.reclaim(batch)
    }

    private func cancelDropWork() {
        for progress in dropProgresses { progress.cancel() }
        clearDropLoadBookkeeping()
        if let session = dropSession {
            for url in session.cancel() { try? FileManager.default.removeItem(at: url) }
        }
        dropSession = nil
        if let confirmation = largeImportConfirmation {
            WorkboardImportMapping.reclaim(confirmation.batch)
            largeImportConfirmation = nil
        }
        isDropTargeted = false
    }

    private func clearDropLoadBookkeeping() {
        for task in dropTimeoutTasks { task.cancel() }
        dropTimeoutTasks.removeAll()
        dropProgresses.removeAll()
    }

    private func reclaim(_ result: WorkboardResolvedDropSlot) {
        guard let url = result.reclaimable else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - The board

/// The free card board. Cards render in the item's OWN material order — the
/// repository already sorts by `(sequence, createdAt, id)` — laid out by
/// `WorkboardMosaicLayout`, and every drop resolves to an insertion slot read
/// from the SAME engine result the layout placed with, so the gap a person aims
/// at is the gap the reorder writes.
private struct WorkboardMaterialBoard: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    let onOpen: (WorkboardMaterialSnapshot) -> Void
    let onReattach: (WorkboardMaterialSnapshot) -> Void

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    @State private var boardWidth: CGFloat = 0
    @State private var isDropTargeted = false
    @State private var materialPendingRemoval: WorkboardMaterialSnapshot?

    private var metrics: WorkboardMosaicMetrics {
        .scaled(for: dynamicTypeSize)
    }

    /// The grid the mosaic settles on at this width. A `large` card clamps to
    /// it, so the card needs the column count to know which layout it actually
    /// got rather than which one it asked for.
    private var gridColumns: Int {
        WorkboardMosaicEngine(metrics: metrics).columnCount(forWidth: boardWidth)
    }

    /// Placement is recomputed from the same inputs the `Layout` memoises, so
    /// drop geometry can never disagree with the frames on screen.
    private var placement: WorkboardMosaicEngine.Result {
        WorkboardMosaicEngine(metrics: metrics).place(
            sizes: item.materials.map { (id: $0.id, size: $0.cardSize) },
            availableWidth: boardWidth
        )
    }

    /// Order and footprint together: the two inputs a reflow can come from.
    private var arrangement: [WorkboardMosaicEngine.Item] {
        item.materials.map { WorkboardMosaicEngine.Item(id: $0.id, size: $0.cardSize) }
    }

    var body: some View {
        WorkboardMosaicLayout(metrics: metrics, layoutDirection: layoutDirection) {
            ForEach(Array(item.materials.enumerated()), id: \.element.id) { index, material in
                card(for: material, at: index)
                    .workboardMosaicCardSize(material.cardSize)
                    .draggable(WorkMaterialDragPayload(
                        itemID: Constants.workboardDeskItemID,
                        materialID: material.id
                    ))
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            boardWidth = width
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(AppColors.brandAmber, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(-6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12)) { content in
                    content.opacity(isDropTargeted ? 1 : 0)
                }
                .allowsHitTesting(false)
        }
        .dropDestination(for: WorkMaterialDragPayload.self) { payloads, location in
            drop(payloads, at: location)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        // A reflow is a frame change, not a leaf property, so it takes the
        // value form. It is scoped to the board container and never reaches the
        // navigation split view that hosts it.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: arrangement)
        .confirmationDialog(
            String(localized: LocalizedStringResource(
                "workboard.material.remove.confirm.title",
                defaultValue: "Remove this material?"
            )),
            isPresented: Binding(
                get: { materialPendingRemoval != nil },
                set: { if !$0 { materialPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: materialPendingRemoval
        ) { material in
            Button(
                LocalizedStringResource(
                    "workboard.material.remove.action",
                    defaultValue: "Remove Material"
                ),
                role: .destructive
            ) {
                materialPendingRemoval = nil
                remove(material)
            }
            Button(
                LocalizedStringResource("common.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {
                materialPendingRemoval = nil
            }
        } message: { material in
            Text(String.localizedStringWithFormat(
                String(localized: LocalizedStringResource(
                    "workboard.material.remove.confirm.message",
                    defaultValue: "“%@” will be removed from your Work desk."
                )),
                material.name
            ))
        }
    }

    /// Which card one material draws. A voice note is a transport rather than a
    /// preview, so it draws the audio card; every other kind draws the source
    /// card. Both take the same board arguments and carry the same arrange
    /// actions, so footprint, order, drag and removal behave identically
    /// whichever one is drawn — the kind decides the CONTENT of the tile and
    /// nothing about its place on the board.
    ///
    /// Both cards are handed the open and reattach seams unconditionally and
    /// gate them through `WorkboardCardActionPolicy` themselves. The board must
    /// not pre-filter by availability: a card that decided for itself which
    /// state may be repaired would be a second copy of that rule, and the two
    /// copies are what let a tile and its menu disagree about the same card.
    @ViewBuilder
    private func card(for material: WorkboardMaterialSnapshot, at index: Int) -> some View {
        let onMoveEarlier: (() -> Void)? = index > 0
            ? { move(material, direction: .earlier) }
            : nil
        let onMoveLater: (() -> Void)? = index + 1 < item.materials.count
            ? { move(material, direction: .later) }
            : nil
        if material.kind == .audio {
            WorkboardAudioCardView(
                material: material,
                size: material.cardSize,
                grantedColumns: gridColumns,
                boardPosition: index + 1,
                boardCount: item.materials.count,
                onOpen: { onOpen(material) },
                onReattach: { onReattach(material) },
                onSetSize: { size in setSize(size, for: material) },
                onMoveEarlier: onMoveEarlier,
                onMoveLater: onMoveLater,
                onRemove: { materialPendingRemoval = material }
            )
        } else {
            WorkboardSourceCard(
                material: material,
                size: material.cardSize,
                grantedColumns: gridColumns,
                boardPosition: index + 1,
                boardCount: item.materials.count,
                onOpen: { onOpen(material) },
                onReattach: { onReattach(material) },
                onSetSize: { size in setSize(size, for: material) },
                onMoveEarlier: onMoveEarlier,
                onMoveLater: onMoveLater,
                onRemove: { materialPendingRemoval = material }
            )
        }
    }

    private func drop(_ payloads: [WorkMaterialDragPayload], at location: CGPoint) -> Bool {
        guard workbenchDestinationIsActive,
              let moving = payloads.first,
              moving.itemID == Constants.workboardDeskItemID,
              item.materials.contains(where: { $0.id == moving.materialID }) else { return false }
        let index = WorkboardMosaicLayout.insertionIndex(
            at: location,
            in: placement,
            containerWidth: boardWidth,
            layoutDirection: layoutDirection
        )
        Task {
            await viewModel.reorderMaterial(
                moving.materialID,
                toInsertionIndex: index
            )
        }
        return true
    }

    private func setSize(_ size: WorkMaterialCardSize, for material: WorkboardMaterialSnapshot) {
        guard workbenchDestinationIsActive else { return }
        Task {
            await viewModel.setMaterialCardSize(size, materialID: material.id)
        }
    }

    /// Move Earlier/Later is the only non-drag path to arrange, so the new
    /// position is announced: the card's label changes but VoiceOver has no
    /// reason to re-read it after an action it did not visibly move.
    private func move(_ material: WorkboardMaterialSnapshot, direction: WorkboardMoveDirection) {
        guard workbenchDestinationIsActive else { return }
        Task {
            guard await viewModel.moveMaterial(material.id, direction: direction),
                  let refreshed = viewModel.desk,
                  let index = refreshed.materials.firstIndex(where: { $0.id == material.id })
            else { return }
            AccessibilityAnnouncer.announce([
                material.name,
                WorkboardSourceCard.boardPositionLabel(
                    position: index + 1,
                    count: refreshed.materials.count
                )
            ].joined(separator: ". "))
        }
    }

    private func remove(_ material: WorkboardMaterialSnapshot) {
        guard workbenchDestinationIsActive else { return }
        Task {
            await viewModel.removeMaterialFromBoard(material.id)
        }
    }
}

/// One material as a board card at one of three footprints. The card fills the
/// frame the mosaic proposes — it never states its own height — so a size change
/// is a single persisted attribute rather than a second layout system.
private struct WorkboardSourceCard: View {
    let material: WorkboardMaterialSnapshot
    var size: WorkMaterialCardSize = .standard
    /// The grid width the mosaic granted. `size` stays the stored choice — it
    /// drives the menu and the label — while the layout keys off the footprint
    /// the card actually received, which is narrower whenever the grid clamps.
    var grantedColumns: Int = WorkboardMosaicSpan.large.columns
    var boardPosition: Int = 0
    var boardCount: Int = 0
    let onOpen: () -> Void
    var onReattach: (() -> Void)?
    var onSetSize: ((WorkMaterialCardSize) -> Void)?
    var onMoveEarlier: (() -> Void)?
    var onMoveLater: (() -> Void)?
    var onRemove: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // A card whose bytes are still arriving is not a control: it is NOT
            // wrapped in a button, so it carries no button trait and offers no
            // activation that would do nothing. Its availability line is the
            // answer, and the arrange actions stay reachable either way.
            if let primaryAction {
                Button(action: primaryAction) { tile }
                    .choiceCardButton(cornerRadius: 13)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilitySummary)
                    .accessibilityActions { cardAccessibilityActions }
            } else {
                tile
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilitySummary)
                    .accessibilityActions { cardAccessibilityActions }
            }

            // Every action the menu carries is also an accessibility action on
            // the card itself, so the affordance is presentation only.
            cardMenu
                .padding(menuInset)
                .allowsHitTesting(showsMenuAffordance)
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12)) { content in
                    content.opacity(showsMenuAffordance ? 1 : 0)
                }
        }
        .contextMenu { cardMenuContent }
        #if os(macOS)
        .onHover { hovering in isHovering = hovering }
        #endif
    }

    /// The tile itself, without any decision about whether it is a control.
    /// The mosaic hands every card a fixed frame, so content that cannot
    /// compress is clipped rather than allowed to bleed over a neighbouring
    /// tile.
    private var tile: some View {
        cardBody
            .padding(layoutSize == .small ? 9 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    /// What this card's bytes allow. Asked once and consumed by the tile, the
    /// menu and the VoiceOver actions alike, so no surface can offer an action
    /// another one refuses.
    private var permittedActions: Set<WorkboardCardAction> {
        WorkboardCardActionPolicy.actions(for: material.availability)
    }

    private var openAction: (() -> Void)? {
        permittedActions.contains(.open) ? onOpen : nil
    }

    private var reattachAction: (() -> Void)? {
        permittedActions.contains(.reattach) ? onReattach : nil
    }

    /// The tile's single tap: open readable bytes, offer to bring back missing
    /// ones, and do nothing at all while they are still arriving.
    private var primaryAction: (() -> Void)? {
        switch WorkboardCardActionPolicy.primaryAction(for: material.availability) {
        case .open: return openAction
        case .reattach: return reattachAction
        case .play, .none: return nil
        }
    }

    /// Pointer platforms reveal the control on hover so a resting board is
    /// quiet; touch platforms have no hover state, so it is always there.
    private var showsMenuAffordance: Bool {
        #if os(macOS)
        return isHovering
        #else
        return true
        #endif
    }

    /// The footprint the card draws into. A `large` card on a grid too narrow
    /// to grant four columns is placed as a standard tile, so drawing the wide
    /// banner would push its text column under the clip shape.
    private var layoutSize: WorkMaterialCardSize {
        size == .large && grantedColumns < WorkboardMosaicSpan.large.columns ? .standard : size
    }

    /// Small is a thumbnail with one line of name; standard keeps the vertical
    /// card; large spends its extra width on bigger artwork beside more preview
    /// text rather than on a taller tile, because the mosaic gives `large` the
    /// same two-unit row band as `standard`.
    @ViewBuilder
    private var cardBody: some View {
        switch layoutSize {
        case .small:
            VStack(alignment: .leading, spacing: 6) {
                artwork(dimension: 30, cornerRadius: 8)
                HStack(spacing: 4) {
                    availabilityGlyph
                    Text(verbatim: material.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        case .standard:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    artwork(dimension: 40, cornerRadius: 10)
                    availabilityGlyph
                    // The menu affordance owns this corner: keep content clear.
                    Spacer(minLength: 26)
                }
                Text(verbatim: material.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                previewBody(lineLimit: 2)
                Spacer(minLength: 0)
                cardFooter
            }
        case .large:
            HStack(alignment: .top, spacing: 12) {
                artwork(dimension: 92, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: material.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                    Text(material.kind.title)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                    previewBody(lineLimit: 4)
                    Spacer(minLength: 0)
                    cardFooter
                }
                availabilityGlyph
                Spacer(minLength: 26)
            }
        }
    }

    @ViewBuilder
    private func previewBody(lineLimit: Int) -> some View {
        if let preview = previewText, !preview.isEmpty {
            Text(verbatim: preview)
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.leading)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cardFooter: some View {
        HStack(spacing: 6) {
            if let byteCount = material.byteCount {
                Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
            }
            Spacer(minLength: 5)
            Text(material.createdAt, format: .relative(presentation: .named))
        }
        .font(.caption2)
        .foregroundStyle(AppColors.textTertiary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var availabilityGlyph: some View {
        if material.availability != .available {
            Image(systemName: availabilityGlyphName)
                .font(.caption)
                .foregroundStyle(availabilityGlyphTint)
                .accessibilityHidden(true)
        }
    }

    /// A card waiting for iCloud is not a card asking to be repaired, so it
    /// carries the sync glyph in the tertiary tint rather than the paperclip in
    /// the warning tint: only `unavailableOnThisDevice` is something the person
    /// can act on.
    private var availabilityGlyphName: String {
        switch material.availability {
        case .localOnly: return "internaldrive"
        case .syncPending: return "icloud.and.arrow.down"
        case .available, .unavailableOnThisDevice: return "paperclip.badge.ellipsis"
        }
    }

    private var availabilityGlyphTint: Color {
        switch material.availability {
        case .localOnly: return AppColors.brandTeal
        case .syncPending: return AppColors.textTertiary
        case .available, .unavailableOnThisDevice: return AppColors.warning
        }
    }

    /// The glyph stays 30pt so it never dominates a tile, but the tappable
    /// region reaches the 44pt minimum on everything wider than a `small` card,
    /// where 44pt would swallow the tile the affordance sits on. The inset
    /// shrinks by the same amount, so the reserved 26pt content gap still
    /// clears the control.
    private var menuHitDimension: CGFloat {
        layoutSize == .small ? 30 : WorkboardMetrics.touchTarget
    }

    private var menuInset: CGFloat {
        layoutSize == .small ? 4 : 0
    }

    private var cardMenu: some View {
        Menu {
            cardMenuContent
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(AppColors.textSecondary, AppColors.cardBackgroundElevated)
                .frame(width: 30, height: 30)
                .frame(width: menuHitDimension, height: menuHitDimension)
                .contentShape(Circle())
        }
        .pointerIconButton(size: menuHitDimension, shape: .circle)
        .help(String(localized: LocalizedStringResource(
            "workboard.material.card.more",
            defaultValue: "Card actions"
        )))
    }

    /// Open and Reattach are the two rows the bytes decide: a card offers
    /// exactly the actions its availability permits, and a card that permits
    /// neither still carries its arrange rows.
    @ViewBuilder
    private var cardMenuContent: some View {
        if let openAction {
            Button(action: openAction) {
                Label(
                    LocalizedStringResource("workboard.material.open", defaultValue: "Open"),
                    systemImage: "arrow.up.forward.square"
                )
            }
        }
        if let reattachAction {
            Button(action: reattachAction) {
                Label(
                    LocalizedStringResource(
                        "workboard.material.reattach.action",
                        defaultValue: "Reattach or Replace"
                    ),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
        }
        if let onSetSize {
            Divider()
            Picker(
                LocalizedStringResource("workboard.material.card.size", defaultValue: "Card Size"),
                selection: Binding(get: { size }, set: { onSetSize($0) })
            ) {
                ForEach(WorkMaterialCardSize.allCases, id: \.self) { option in
                    Text(option.cardSizeTitle).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
        if onMoveEarlier != nil || onMoveLater != nil {
            Divider()
            if let onMoveEarlier {
                Button(action: onMoveEarlier) {
                    Label(
                        LocalizedStringResource("workboard.action.moveEarlier", defaultValue: "Move Earlier"),
                        systemImage: "arrow.left"
                    )
                }
            }
            if let onMoveLater {
                Button(action: onMoveLater) {
                    Label(
                        LocalizedStringResource("workboard.action.moveLater", defaultValue: "Move Later"),
                        systemImage: "arrow.right"
                    )
                }
            }
        }
        if let onRemove {
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label(
                    LocalizedStringResource(
                        "workboard.material.remove.action",
                        defaultValue: "Remove Material"
                    ),
                    systemImage: "trash"
                )
            }
        }
    }

    @ViewBuilder
    private var cardAccessibilityActions: some View {
        if let reattachAction {
            Button(
                LocalizedStringResource(
                    "workboard.material.reattach.action",
                    defaultValue: "Reattach or Replace"
                ),
                action: reattachAction
            )
        }
        if let onMoveEarlier {
            Button(
                LocalizedStringResource("workboard.action.moveEarlier", defaultValue: "Move Earlier"),
                action: onMoveEarlier
            )
        }
        if let onMoveLater {
            Button(
                LocalizedStringResource("workboard.action.moveLater", defaultValue: "Move Later"),
                action: onMoveLater
            )
        }
        if let onSetSize {
            ForEach(WorkMaterialCardSize.allCases.filter { $0 != size }, id: \.self) { option in
                Button(option.cardSizeAccessibilityAction) {
                    onSetSize(option)
                }
            }
        }
        if let onRemove {
            Button(
                LocalizedStringResource(
                    "workboard.material.remove.action",
                    defaultValue: "Remove Material"
                ),
                action: onRemove
            )
        }
    }

    @ViewBuilder
    private func artwork(dimension: CGFloat, cornerRadius: CGFloat) -> some View {
        if material.kind == .image, let data = material.thumbnailData {
            StagedImageTile(
                id: material.id,
                data: data,
                maxPixel: ImageProcessor.thumbnailMaxPixel,
                cacheVersion: material.revision
            ) {
                artworkPlaceholder(dimension: dimension, cornerRadius: cornerRadius)
            }
            .frame(width: dimension, height: dimension)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.borderSubtle, lineWidth: 1)
            }
            .accessibilityHidden(true)
        } else {
            artworkPlaceholder(dimension: dimension, cornerRadius: cornerRadius)
        }
    }

    private func artworkPlaceholder(dimension: CGFloat, cornerRadius: CGFloat) -> some View {
        Image(systemName: WorkboardMaterialIcon.symbol(for: material))
            .font(.system(size: max(13, dimension * 0.42)))
            .foregroundStyle(WorkboardMaterialIcon.tint(for: material))
            .frame(width: dimension, height: dimension)
            .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    /// `.audio` is listed for exhaustiveness only — a voice note draws
    /// `WorkboardAudioCardView`, never this card.
    private var previewText: String? {
        switch material.kind {
        case .note: return material.textContent
        case .link: return material.urlString
        case .image, .file, .audio: return material.detail
        }
    }

    private var accessibilitySummary: Text {
        var parts = [String(localized: material.kind.title), material.name]
        if let preview = previewText?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            parts.append(preview)
        }
        if material.availability != .available {
            parts.append(String(localized: availabilityLabel))
        }
        parts.append(String(localized: size.cardSizeTitle))
        // Arranging is what the board is for, so the position is part of the
        // card's identity: it is the only thing that changes when Move
        // Earlier/Later succeeds.
        if boardCount > 0, boardPosition > 0 {
            parts.append(Self.boardPositionLabel(position: boardPosition, count: boardCount))
        }
        return Text(parts.joined(separator: ". "))
    }

    static func boardPositionLabel(position: Int, count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.material.card.position",
                defaultValue: "%1$lld of %2$lld"
            )),
            position,
            count
        )
    }

    private var availabilityLabel: LocalizedStringResource {
        switch material.availability {
        case .localOnly:
            return LocalizedStringResource(
                "workboard.material.localOnly",
                defaultValue: "Available on this device"
            )
        case .syncPending:
            return LocalizedStringResource(
                "workboard.material.syncPending",
                defaultValue: "Waiting for iCloud…"
            )
        case .available, .unavailableOnThisDevice:
            return LocalizedStringResource(
                "workboard.material.reattach.short",
                defaultValue: "Reattach"
            )
        }
    }
}

extension WorkMaterialCardSize {
    /// Board footprint as the person picks it. Presentation only — the stored
    /// value carries no copy of its own.
    var cardSizeTitle: LocalizedStringResource {
        switch self {
        case .small:
            return LocalizedStringResource("workboard.material.card.size.small", defaultValue: "Small")
        case .standard:
            return LocalizedStringResource("workboard.material.card.size.standard", defaultValue: "Standard")
        case .large:
            return LocalizedStringResource("workboard.material.card.size.large", defaultValue: "Large")
        }
    }

    /// The same three footprints as verbs, because an accessibility action is
    /// an instruction rather than a selectable value.
    var cardSizeAccessibilityAction: LocalizedStringResource {
        switch self {
        case .small:
            return LocalizedStringResource(
                "workboard.material.card.size.small.action",
                defaultValue: "Make Card Small"
            )
        case .standard:
            return LocalizedStringResource(
                "workboard.material.card.size.standard.action",
                defaultValue: "Make Card Standard"
            )
        case .large:
            return LocalizedStringResource(
                "workboard.material.card.size.large.action",
                defaultValue: "Make Card Large"
            )
        }
    }
}

/// Work accepts two representations Chat does not — a dragged web URL and a
/// dragged text selection, which become link and note materials. The file-vs-image
/// precedence is NOT re-derived here: it carries a size guard that lives only on
/// the file path, so it stays the one decision in `ComposerDropRouting.route`.
private enum WorkboardDropProviderRoute: Equatable {
    case fileURL
    case imageData
    case webURL
    case plainText

    init?(provider: NSItemProvider) {
        switch ComposerDropRouting.route(
            hasFileURL: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            canLoadImage: provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        ) {
        case .fileURL:
            self = .fileURL
        case .imageData:
            self = .imageData
        case .unsupported:
            if provider.canLoadObject(ofClass: NSURL.self) {
                self = .webURL
            } else if provider.canLoadObject(ofClass: NSString.self) {
                self = .plainText
            } else {
                return nil
            }
        }
    }
}

private enum WorkboardResolvedImportItem: Sendable {
    case image(data: Data, displayName: String)
    case imageFile(
        sourceURL: URL,
        displayName: String,
        mimeType: String,
        byteCount: Int64
    )
    case file(
        sourceURL: URL,
        displayName: String,
        mimeType: String?,
        byteCount: Int64?,
        isAppOwned: Bool
    )
    case text(String)
}

private extension WorkboardResolvedImportItem {
    /// The app-owned temp this item carries. A user-owned URL and raw bytes own
    /// nothing the app may delete.
    var appOwnedURL: URL? {
        switch self {
        case .imageFile(let url, _, _, _): return url
        case .file(let url, _, _, _, true): return url
        case .image, .file, .text: return nil
        }
    }
}

private enum WorkboardResolvedDropSlot: Sendable {
    case value(WorkboardResolvedImportItem)
    case failed
}

extension WorkboardResolvedDropSlot: DropSessionItem {
    /// Providers this drop refused before the session started. They never get a
    /// slot, but they still count as failures in the report the import raises.
    typealias Context = Int

    var reclaimable: URL? {
        guard case .value(let item) = self else { return nil }
        return item.appOwnedURL
    }
}

private extension DropSession where Item == WorkboardResolvedDropSlot {
    var initialFailureCount: Int { context }

    convenience init(count: Int, initialFailureCount: Int) {
        self.init(context: max(0, initialFailureCount), count: count)
    }

    /// Take the finished batch exactly once, splitting resolved items from
    /// failures and folding in the providers refused before the session began.
    func takeBatch() -> WorkboardResolvedImportBatch? {
        guard let slots = takeItems() else { return nil }
        var items: [WorkboardResolvedImportItem] = []
        var failures = initialFailureCount
        for slot in slots {
            switch slot {
            case .value(let item): items.append(item)
            case .failed: failures += 1
            }
        }
        return WorkboardResolvedImportBatch(items: items, failedCount: failures)
    }
}

private struct WorkboardResolvedImportBatch: Sendable {
    let items: [WorkboardResolvedImportItem]
    let failedCount: Int

    var largeItemByteCounts: [Int64] {
        items.compactMap { item in
            let byteCount: Int64?
            switch item {
            case .image(let data, _):
                byteCount = Int64(data.count)
            case .imageFile(_, _, _, let value):
                byteCount = value
            case .file(_, _, _, let value, _):
                byteCount = value
            case .text:
                byteCount = nil
            }
            guard let byteCount,
                  byteCount > Int64(Constants.fileTransferSoftConfirmBytes) else { return nil }
            return byteCount
        }
    }

    var hasLargeFiles: Bool {
        !largeItemByteCounts.isEmpty
    }

    var appOwnedURLs: [URL] {
        items.compactMap(\.appOwnedURL)
    }
}

private struct WorkboardWorkspaceLargeImportConfirmation: WorkboardLargeImportConfirming {
    let id = UUID()
    let batch: WorkboardResolvedImportBatch

    var largeItemByteCounts: [Int64] { batch.largeItemByteCounts }
}

/// One mapping from a resolved batch to Work material, shared by the picker and
/// the pane-wide drop. Security scopes it opens are RETURNED rather than closed
/// here: a scoped URL must stay open until the caller's import has finished
/// reading the bytes.
private enum WorkboardImportMapping {
    static func imports(
        from batch: WorkboardResolvedImportBatch
    ) -> (imports: [WorkboardMaterialImport], scopedURLs: [URL]) {
        var imports: [WorkboardMaterialImport] = []
        var scopedURLs: [URL] = []
        for item in batch.items {
            switch item {
            case .image(let data, let name):
                imports.append(WorkboardMaterialImport(
                    kind: .image,
                    name: name,
                    mimeType: ImageFormatSniffer.sniff(data).mime,
                    data: data,
                    byteCount: Int64(data.count)
                ))
            case .imageFile(let url, let name, let mimeType, let byteCount):
                imports.append(WorkboardMaterialImport(
                    kind: .image,
                    name: name,
                    detail: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file),
                    mimeType: mimeType,
                    fileURL: url,
                    byteCount: byteCount
                ))
            case .file(let url, let name, let mimeType, let byteCount, let isAppOwned):
                if !isAppOwned, url.startAccessingSecurityScopedResource() {
                    scopedURLs.append(url)
                }
                imports.append(WorkboardMaterialImport(
                    kind: materialKind(filename: name, mimeType: mimeType),
                    name: name,
                    detail: byteCount.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    },
                    mimeType: mimeType,
                    fileURL: url,
                    byteCount: byteCount
                ))
            case .text(let value):
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if WorkCaptureEnvelope.isAcceptedWebURL(clean) {
                    let host = URLComponents(string: clean)?.host ?? clean
                    imports.append(WorkboardMaterialImport(
                        kind: .link,
                        name: host,
                        detail: host,
                        textContent: clean,
                        urlString: clean
                    ))
                } else if !clean.isEmpty {
                    imports.append(WorkboardMaterialImport(
                        kind: .note,
                        name: WorkboardWorkspaceCaptureLogic.noteTitle(for: clean),
                        textContent: clean
                    ))
                }
            }
        }
        return (imports, scopedURLs)
    }

    static func materialKind(filename: String, mimeType: String?) -> WorkboardMaterialKind {
        if let mimeType,
           let type = UTType(mimeType: mimeType),
           type.conforms(to: .image) {
            return .image
        }
        if let type = UTType(filenameExtension: (filename as NSString).pathExtension),
           type.conforms(to: .image) {
            return .image
        }
        return .file
    }

    static func reclaim(_ batch: WorkboardResolvedImportBatch) {
        for url in batch.appOwnedURLs { try? FileManager.default.removeItem(at: url) }
    }
}

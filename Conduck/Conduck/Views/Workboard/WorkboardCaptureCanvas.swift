// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardCaptureCanvas.swift
//
// The project-shaped capture surface from the Work sketches. A typed thought,
// picker result, or drop is always persisted as inert Work first. The visually
// separate Review & Send action can only open the exact existing preflight; this
// view has no transport dependency and cannot choose a gateway.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum WorkboardCaptureCanvasMode: Sendable {
    case full
    case sources
    case composer
}

enum WorkboardCaptureDestination: Equatable, Sendable {
    case existingWork(String)
    case newWork

    var composerPrompt: LocalizedStringResource {
        switch self {
        case .existingWork(let title):
            return LocalizedStringResource(
                "workboard.workspace.composer.prompt.existing",
                defaultValue: "Add a thought to \(title)…"
            )
        case .newWork:
            return LocalizedStringResource(
                "workboard.workspace.composer.prompt.new",
                defaultValue: "Start a new work item…"
            )
        }
    }

    var dropTitle: LocalizedStringResource {
        switch self {
        case .existingWork(let title):
            return LocalizedStringResource(
                "workboard.workspace.drop.overlay.existing",
                defaultValue: "Drop into \(title)"
            )
        case .newWork:
            return LocalizedStringResource(
                "workboard.workspace.drop.overlay.new",
                defaultValue: "Drop to create New Work"
            )
        }
    }

    var dropCaption: LocalizedStringResource {
        switch self {
        case .existingWork:
            return LocalizedStringResource(
                "workboard.workspace.drop.overlay.existing.caption",
                defaultValue: "Files, photos, screenshots, links and text will be added here. Nothing is sent."
            )
        case .newWork:
            return LocalizedStringResource(
                "workboard.workspace.drop.overlay.new.caption",
                defaultValue: "A private draft is created only after the first item is safely stored. Nothing is sent."
            )
        }
    }
}

struct WorkboardCaptureCanvas: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    var mode: WorkboardCaptureCanvasMode = .full
    var destination: WorkboardCaptureDestination

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    init(
        viewModel: WorkboardViewModel,
        item: WorkboardItemSnapshot,
        mode: WorkboardCaptureCanvasMode = .full,
        destination: WorkboardCaptureDestination? = nil
    ) {
        self.viewModel = viewModel
        self.item = item
        self.mode = mode
        self.destination = destination ?? .existingWork(item.displayTitle)
    }

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var materialPendingReattachment: WorkboardMaterialSnapshot?
    @State private var showsVoiceCapture = false
    @State private var materialComposer: WorkboardMaterialComposerKind?
    @State private var largeImportConfirmation: WorkboardWorkspaceLargeImportConfirmation?
    @State private var isAddingThought = false
    @State private var isReviewing = false
    @State private var reviewTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool
    #if os(iOS)
    @State private var showsCamera = false
    @State private var showsCameraDeniedAlert = false
    #endif

    private var isImporting: Bool {
        viewModel.isCapturingIntoAnyWorkspace
    }

    var body: some View {
        Group {
            if mode == .composer {
                compactComposer
            } else {
                WorkboardSurface {
                    VStack(alignment: .leading, spacing: 16) {
                        canvasHeader
                        dropTarget
                        if !item.materials.isEmpty {
                            sourceShelf
                        }
                        if mode == .full {
                            Divider().overlay(AppColors.borderSubtle)
                            expandedComposer
                        }
                        privacyStatus
                    }
                }
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
        .sheet(item: activeMaterialComposer) { kind in
            WorkboardTextMaterialSheet(kind: kind) { materialImport in
                Task {
                    await viewModel.importWorkspaceMaterials([materialImport], to: item.id)
                }
            }
        }
        .sheet(isPresented: activeVoiceCaptureIsPresented) {
            WorkboardVoiceCaptureView(
                target: .context,
                onTranscript: { transcript in
                    viewModel.setWorkspaceComposerDraft(
                        appending(transcript, to: composerText),
                        for: item.id
                    )
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

    private var activeMaterialComposer: Binding<WorkboardMaterialComposerKind?> {
        $materialComposer.gated(by: workbenchDestinationIsActive)
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
        if materialComposer != nil { materialComposer = nil }
        #if os(iOS)
        if showsCamera { showsCamera = false }
        if showsCameraDeniedAlert { showsCameraDeniedAlert = false }
        #endif
        if let confirmation = largeImportConfirmation {
            WorkboardImportMapping.reclaim(confirmation.batch)
            largeImportConfirmation = nil
        }
        if reviewTask != nil {
            reviewTask?.cancel()
            reviewTask = nil
        }
        if isReviewing { isReviewing = false }
        if composerFocused { composerFocused = false }
    }

    private var canvasHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringResource(
                    "workboard.workspace.canvas.title",
                    defaultValue: "Project canvas"
                ))
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.textEmphasis)
                .accessibilityAddTraits(.isHeader)

                Text(LocalizedStringResource(
                    "workboard.workspace.canvas.caption",
                    defaultValue: "Collect the rough material first. Shape and send it only when you are ready."
                ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 12)
            if let state = viewModel.workspaceImportState, state.itemID == item.id {
                VStack(alignment: .trailing, spacing: 5) {
                    ProgressView(value: state.progress)
                        .frame(width: 92)
                    Text(String.localizedStringWithFormat(
                        String(localized: LocalizedStringResource(
                            "workboard.workspace.import.progress",
                            defaultValue: "%1$lld of %2$lld"
                        )),
                        Int64(state.completedCount),
                        Int64(state.totalCount)
                    ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "workboard.material.importing",
                    defaultValue: "Adding materials"
                )))
                .accessibilityValue(Text(verbatim: String.localizedStringWithFormat(
                    String(localized: LocalizedStringResource(
                        "workboard.workspace.import.progress",
                        defaultValue: "%1$lld of %2$lld"
                    )),
                    Int64(state.completedCount),
                    Int64(state.totalCount)
                )))
            } else {
                Label(
                    LocalizedStringResource(
                        "workboard.workspace.inert",
                        defaultValue: "Not sent"
                    ),
                    systemImage: "lock.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.brandTeal)
            }
        }
    }

    private var dropTarget: some View {
        Button {
            guard !isImporting else { return }
            showsFileImporter = true
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(AppColors.brandAmber.opacity(0.12))
                        .frame(width: 62, height: 62)
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(AppColors.brandAmber)
                        .contentTransition(.symbolEffect(.replace))
                }

                VStack(spacing: 4) {
                    Text(LocalizedStringResource(
                        "workboard.workspace.drop.title",
                        defaultValue: "Drop anywhere, or choose files"
                    ))
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    Text(LocalizedStringResource(
                        "workboard.workspace.drop.caption",
                        defaultValue: "Files stay private and inert until Review & Send."
                    ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                }

                HStack(spacing: 8) {
                    captureRoute("square.and.arrow.up", LocalizedStringResource(
                        "workboard.workspace.route.share",
                        defaultValue: "Share"
                    ))
                    captureRoute("button.programmable", LocalizedStringResource(
                        "workboard.workspace.route.actionButton",
                        defaultValue: "Action Button"
                    ))
                    #if os(macOS)
                    captureRoute("menubar.rectangle", LocalizedStringResource(
                        "workboard.workspace.route.menuBar",
                        defaultValue: "Menu bar"
                    ))
                    #endif
                }
            }
            .frame(maxWidth: .infinity, minHeight: item.materials.isEmpty ? 190 : 142)
            .padding(.horizontal, 18)
            .background(AppColors.backgroundSecondary.opacity(0.7), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(
                        AppColors.borderSubtle,
                        style: StrokeStyle(lineWidth: 1, dash: [7, 5])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .choiceCardButton(cornerRadius: 15)
        .disabled(isImporting)
        .accessibilityHint(Text(LocalizedStringResource(
            "workboard.workspace.drop.accessibilityHint",
            defaultValue: "Opens the file picker. You can also drag items onto this project canvas."
        )))
    }

    private func captureRoute(_ systemImage: String, _ title: LocalizedStringResource) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(AppColors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AppColors.cardBackground, in: Capsule())
            .overlay { Capsule().stroke(AppColors.borderSubtle, lineWidth: 1) }
    }

    private var sourceShelf: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text(LocalizedStringResource(
                    "workboard.workspace.sources.title",
                    defaultValue: "Sources and thoughts"
                ))
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
                Text(item.materials.count, format: .number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(AppColors.backgroundSecondary, in: Capsule())
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(item.materials.sorted(by: newestMaterialFirst)) { material in
                    WorkboardSourceCard(material: material) {
                        if material.availability == .unavailableOnThisDevice {
                            materialPendingReattachment = material
                            showsFileImporter = true
                        } else {
                            viewModel.openMaterial(material)
                        }
                    }
                }
            }
        }
    }

    /// The pinned composer follows the sketch's single-row capture bar. The
    /// full source canvas already exposes Review & Send, and the detail toolbar
    /// owns that deliberate boundary, so it is not repeated below the keyboard.
    private var compactComposer: some View {
        HStack(alignment: .bottom, spacing: 7) {
            attachmentMenu
            composerField(lineLimit: 1...4)
            voiceButton
            addThoughtButton
        }
    }

    private var expandedComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource(
                "workboard.workspace.composer.title",
                defaultValue: "Add a thought"
            ))
            .font(.headline)
            .foregroundStyle(AppColors.textPrimary)
            .accessibilityAddTraits(.isHeader)

            HStack(alignment: .bottom, spacing: 8) {
                attachmentMenu
                composerField(lineLimit: 1...7)
                voiceButton
                addThoughtButton
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { reviewAndSendButton }
                VStack(spacing: 10) { reviewAndSendButton }
            }
        }
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
                materialComposer = .link
            },
            onAddNote: {
                guard workbenchDestinationIsActive else { return }
                materialComposer = .note
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

    private func composerField(lineLimit: ClosedRange<Int>) -> some View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: WorkboardMetrics.touchTarget)
        .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(composerFocused ? AppColors.brandAmber.opacity(0.65) : AppColors.borderSubtle, lineWidth: 1)
        }
    }

    private var voiceButton: some View {
        CaptureCircleButton(
            symbol: "mic.fill",
            fillColor: AppColors.brandAmber,
            diameter: composerControlDiameter,
            glyphSize: composerGlyphSize,
            isDisabled: !workbenchDestinationIsActive || isImporting || isAddingThought || isReviewing,
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
        let isDisabled = !workbenchDestinationIsActive
            || cleanComposerText.isEmpty
            || isImporting
            || isAddingThought
            || isReviewing
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

    private var reviewAndSendButton: some View {
        Button(action: reviewAndSend) {
            HStack(spacing: 8) {
                if isReviewing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.shield")
                }
                Text(LocalizedStringResource(
                    "workboard.editor.reviewAndSend",
                    defaultValue: "Review & Send…"
                ))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppColors.textPrimary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: WorkboardMetrics.touchTarget)
            .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColors.borderSubtle, lineWidth: 1)
            }
        }
        .choiceCardButton(cornerRadius: 12)
        .disabled(!workbenchDestinationIsActive
            || (!item.isReadyToSend && cleanComposerText.isEmpty)
            || isImporting || isAddingThought || isReviewing)
        .accessibilityHint(Text(LocalizedStringResource(
            "workboard.editor.reviewAndSend.hint",
            defaultValue: "Opens a final preview. Nothing is sent yet."
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

    private var privacyStatus: some View {
        Label {
            Text(LocalizedStringResource(
                "workboard.workspace.privacy",
                defaultValue: "Briefs sync privately. Source files and screenshots stay on this device. You choose every gateway at send time."
            ))
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(AppColors.brandTeal)
        }
        .font(.caption)
        .foregroundStyle(AppColors.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cleanComposerText: String {
        WorkboardWorkspaceCaptureLogic.normalizedThought(composerText)
    }

    private var composerText: String {
        viewModel.workspaceComposerDraft(for: item.id)
    }

    private var composerTextBinding: Binding<String> {
        Binding(
            get: { viewModel.workspaceComposerDraft(for: item.id) },
            set: { viewModel.setWorkspaceComposerDraft($0, for: item.id) }
        )
    }

    private func addThought() {
        let thought = cleanComposerText
        guard workbenchDestinationIsActive,
              !thought.isEmpty,
              !isAddingThought,
              !isReviewing else { return }
        isAddingThought = true
        Task {
            let added = await viewModel.addWorkspaceThought(thought, to: item.id)
            if added {
                viewModel.setWorkspaceComposerDraft("", for: item.id)
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

    private func reviewAndSend() {
        guard workbenchDestinationIsActive, !isAddingThought, !isReviewing else { return }
        isReviewing = true
        let targetItemID = item.id
        reviewTask?.cancel()
        reviewTask = Task {
            _ = await viewModel.reviewWorkspaceAndSend(itemID: targetItemID)
            guard !Task.isCancelled,
                  viewModel.selectedItemID == targetItemID else {
                isReviewing = false
                return
            }
            isReviewing = false
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
        guard !viewModel.isCapturingIntoAnyWorkspace else { return }
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
            viewModel.presentWorkspaceImportReport(
                WorkboardWorkspaceImportReport(addedCount: 0, failedCount: 1 + batch.failedCount)
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
        await viewModel.reattachWorkspaceMaterial(
            material,
            in: item.id,
            with: replacement
        )
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
        await viewModel.importWorkspaceMaterials(
            mapped.imports,
            to: item.id,
            additionalFailureCount: batch.failedCount
        )
        for url in mapped.scopedURLs { url.stopAccessingSecurityScopedResource() }
        WorkboardImportMapping.reclaim(batch)
    }

    private func newestMaterialFirst(_ lhs: WorkboardMaterialSnapshot, _ rhs: WorkboardMaterialSnapshot) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
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
    /// All Work screen had no handler at all.
    func workboardPaneDropDestination(
        viewModel: WorkboardViewModel,
        itemID: UUID,
        destination: WorkboardCaptureDestination
    ) -> some View {
        modifier(WorkboardPaneDropModifier(
            viewModel: viewModel,
            itemID: itemID,
            destination: destination
        ))
    }
}

private struct WorkboardPaneDropModifier: ViewModifier {
    @Bindable var viewModel: WorkboardViewModel
    let itemID: UUID
    let destination: WorkboardCaptureDestination

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive
    @State private var isDropTargeted = false
    @State private var dropSession: DropSession<WorkboardResolvedDropSlot>?
    @State private var dropProgresses: [Progress] = []
    @State private var dropTimeoutTasks: [Task<Void, Never>] = []
    @State private var largeImportConfirmation: WorkboardWorkspaceLargeImportConfirmation?

    private var isImporting: Bool {
        viewModel.isCapturingIntoAnyWorkspace || dropSession != nil
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
            .onChange(of: itemID) { _, _ in cancelDropWork() }
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
            viewModel.presentWorkspaceImportReport(
                WorkboardWorkspaceImportReport(addedCount: 0, failedCount: providers.count)
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
        await viewModel.importWorkspaceMaterials(
            mapped.imports,
            to: itemID,
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

private struct WorkboardSourceCard: View {
    let material: WorkboardMaterialSnapshot
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 9) {
                    sourceArtwork
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: material.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(2)
                        Text(material.kind.title)
                            .font(.caption2)
                            .foregroundStyle(AppColors.textTertiary)
                    }
                    Spacer(minLength: 5)
                    if material.availability != .available {
                        Image(systemName: material.availability == .localOnly ? "internaldrive" : "paperclip.badge.ellipsis")
                            .foregroundStyle(material.availability == .localOnly ? AppColors.brandTeal : AppColors.warning)
                            .accessibilityLabel(Text(availabilityLabel))
                    }
                }

                if let preview = previewText, !preview.isEmpty {
                    Text(verbatim: preview)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6) {
                    if let byteCount = material.byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                    }
                    Spacer(minLength: 5)
                    Text(material.createdAt, format: .relative(presentation: .named))
                }
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(AppColors.borderSubtle, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .choiceCardButton(cornerRadius: 13)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var sourceArtwork: some View {
        if material.kind == .image,
           let data = material.thumbnailData {
            StagedImageTile(
                id: material.id,
                data: data,
                maxPixel: ImageProcessor.thumbnailMaxPixel,
                cacheVersion: material.revision
            ) {
                sourceArtworkPlaceholder
            }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppColors.borderSubtle, lineWidth: 1)
                }
                .accessibilityHidden(true)
        } else {
            sourceArtworkPlaceholder
        }
    }

    private var sourceArtworkPlaceholder: some View {
        Image(systemName: WorkboardMaterialIcon.symbol(for: material))
            .font(.title3)
            .foregroundStyle(WorkboardMaterialIcon.tint(for: material))
            .frame(width: 38, height: 38)
            .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var previewText: String? {
        switch material.kind {
        case .note: return material.textContent
        case .link: return material.urlString
        case .image, .file: return material.detail
        }
    }

    private var availabilityLabel: LocalizedStringResource {
        material.availability == .localOnly
            ? LocalizedStringResource(
                "workboard.material.localOnly",
                defaultValue: "Available on this device"
            )
            : LocalizedStringResource(
                "workboard.material.reattach.short",
                defaultValue: "Reattach"
            )
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

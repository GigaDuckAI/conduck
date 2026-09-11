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

/// Capture remains on the canonical desk; this value freezes the optional
/// project membership before a picker, provider, or store operation suspends.
enum WorkboardCaptureDestination: Equatable, Sendable {
    case all
    case project(UUID, title: String)

    @MainActor
    init(workspace: WorkDeskWorkspaceState?) {
        if let workspace, !workspace.isSearching, let project = workspace.currentProject {
            self = .project(project.id, title: project.title)
        } else {
            self = .all
        }
    }

    var projectID: UUID? {
        if case .project(let id, _) = self { return id }
        return nil
    }

    var composerPrompt: LocalizedStringResource {
        switch self {
        case .all:
            LocalizedStringResource("workdesk.capture.all.prompt", defaultValue: "Add to All materials…")
        case .project(_, let title):
            LocalizedStringResource("workdesk.capture.project.prompt", defaultValue: "Add to \(title)…")
        }
    }

    var dropTitle: LocalizedStringResource {
        switch self {
        case .all:
            LocalizedStringResource("workdesk.capture.all.drop", defaultValue: "Drop into All materials")
        case .project(_, let title):
            LocalizedStringResource("workdesk.capture.project.drop", defaultValue: "Drop into \(title)")
        }
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
    var deskWorkspace: WorkDeskWorkspaceState?

    private var destination: WorkboardCaptureDestination {
        WorkboardCaptureDestination(workspace: deskWorkspace)
    }
    @State private var pickerDestination: WorkboardCaptureDestination = .all
    /// Separate from the picker: one launch owns its destination until its
    /// recorder and any words-only fallback have finished, despite navigation.
    @State private var voiceDestination: WorkboardCaptureDestination = .all
    @State private var voiceDraftScope: WorkDeskScope = .all

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        viewModel: WorkboardViewModel,
        item: WorkboardItemSnapshot,
        mode: WorkboardCaptureCanvasMode,
        deskWorkspace: WorkDeskWorkspaceState? = nil
    ) {
        self.viewModel = viewModel
        self.item = item
        self.mode = mode
        self.deskWorkspace = deskWorkspace
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
        .appReviewBusy(workbenchDestinationIsActive && (
            composerFocused || !cleanComposerText.isEmpty || isAddingThought || isImporting
                || showsPhotoPicker || showsFileImporter || showsVoiceCapture
                || showsLinkComposer || largeImportConfirmation != nil
        ))
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
            let target = pickerDestination
            Task { await importPhotos(selection, destination: target) }
        }
        .sheet(isPresented: activeLinkComposerIsPresented) {
            WorkboardTextMaterialSheet { materialImport in
                let target = pickerDestination
                Task { await viewModel.importMaterials([materialImport], projectID: target.projectID) }
            }
        }
        .sheet(isPresented: activeVoiceCaptureIsPresented) {
            WorkboardVoiceCaptureView(
                target: .context,
                projectID: voiceDestination.projectID,
                onTranscript: { transcript in
                    viewModel.receiveComposerTranscript(transcript, in: voiceDraftScope)
                    showsVoiceCapture = false
                    composerFocused = true
                },
                onCancel: { showsVoiceCapture = false },
                onSavedInAllMaterials: { viewModel.presentCaptureSavedInAllMaterials() }
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
                Task { await importResolvedBatch(confirmation.batch, destination: confirmation.destination) }
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
            if isActive {
                // A request that arrived while the pane was hidden was left
                // unconsumed, not dropped — this is where it lands.
                consumeVoiceCaptureLaunchRoute()
            } else {
                dismissTransientCaptureUI()
            }
        }
        .onAppear {
            consumeVoiceCaptureLaunchRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWorkboardVoiceCapture)) { _ in
            consumeVoiceCaptureLaunchRoute()
        }
    }

    /// Land a headless "record a note to Work" request on this canvas's own
    /// voice sheet — the same state the mic button sets, so the two entry points
    /// cannot present two different recorders.
    ///
    /// Both an `.onAppear` and the notification consult it, because a cold
    /// launch is asked BEFORE this view mounts and never hears the post while a
    /// warm one hears nothing else.
    ///
    /// THE GATES COME BEFORE THE CLAIM, and that ordering is the whole point:
    /// `consume()` is one-shot read-and-clear, so claiming first and then
    /// refusing to present would SPEND the request and show nothing. A hidden
    /// Work pane therefore leaves the route pending until it is on screen —
    /// `workbenchDestinationIsActive` is the same gate every other capture
    /// surface here reads, since a sheet presented by a pane the person is not
    /// looking at arrives over Chat.
    ///
    /// `.sources` returns early: only the composer canvas owns the voice sheet,
    /// and the two are mounted together, so consuming it here would take the
    /// request away from the surface that can honour it.
    private func consumeVoiceCaptureLaunchRoute() {
        guard mode == .composer else { return }
        guard workbenchDestinationIsActive else { return }
        guard !showsVoiceCapture else { return }
        guard WorkVoiceCaptureLaunchRoute.shared.consume() else { return }
        // A Shortcut opens this sheet but supplies no visible project context.
        // It must never inherit whichever project another window left open.
        voiceDestination = .all
        voiceDraftScope = .all
        showsVoiceCapture = true
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

    /// The desk's sync notice, and the whole of it. Both halves of it —
    /// whether there is one, and what it says — belong to
    /// `WorkboardSyncBannerPolicy`, which states the reasoning; this view only
    /// draws what the policy answers.
    ///
    /// The dismissal is the same sticky per-outage flag the conversation list's
    /// banner uses, on purpose: the account is broken in one place, so saying so
    /// twice and asking to be dismissed twice would be the same interruption
    /// charged again.
    @ViewBuilder
    private var deskSyncBanner: some View {
        if let message = WorkboardSyncBannerPolicy.message(
            showsBanner: syncMonitor.showsBanner,
            reason: syncMonitor.unavailableReason
        ) {
            WorkboardSyncBanner(message: message) {
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
            if let deskWorkspace {
                WorkDeskSourceBoard(
                    viewModel: viewModel, item: item, workspace: deskWorkspace,
                    onOpen: openMaterial, onShare: shareMaterial, onReattach: beginReattachment
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !item.materials.isEmpty {
                WorkboardMaterialBoard(
                    viewModel: viewModel,
                    item: item,
                    onOpen: openMaterial,
                    onShare: shareMaterial,
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
        if material.kind == .note, let source = viewModel.deskWorkspace.results[material.id] {
            viewModel.deskWorkspace.openResultSource(source)
            return
        }
        WorkboardCardActionPolicy.performPrimaryAction(
            for: material.availability,
            open: { viewModel.openMaterial(material) },
            reattach: { beginReattachment(material) }
        )
    }

    /// The desk's door to the share presenter, behind the SAME gate Open uses.
    /// Sharing reads the card's bytes, so a card whose bytes are not readable
    /// here must reach it no more than the preview router does — and the
    /// coordinator re-asks on the current card anyway, because this snapshot
    /// was taken when the board last loaded.
    private func shareMaterial(_ material: WorkboardMaterialSnapshot) {
        guard WorkboardCardActionPolicy.allows(.open, when: material.availability) else { return }
        viewModel.shareMaterial(material)
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
        VStack(alignment: .leading, spacing: 6) {
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
                pickerDestination = destination
                showsPhotoPicker = true
            },
            onTakePhoto: takePhoto,
            onPickFiles: {
                guard workbenchDestinationIsActive else { return }
                pickerDestination = destination
                showsFileImporter = true
            },
            onAddLink: {
                guard workbenchDestinationIsActive else { return }
                pickerDestination = destination
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
                voiceDestination = destination
                voiceDraftScope = viewModel.composerScope
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
            symbol: isAddingThought ? "ellipsis" : "plus",
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
        pickerDestination = destination
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
        let target = destination
        let capturedDraft = composerText
        let capturedScope = viewModel.composerScope
        Task {
            let added = await viewModel.addThought(thought, projectID: target.projectID)
            if added {
                // An import may finish after the person continues typing or
                // voice appends new words. Clear only the draft we captured.
                viewModel.clearComposerDraft(capturedDraft, in: capturedScope)
                let message = String(localized: LocalizedStringResource(
                    "workboard.workspace.thought.saved",
                    defaultValue: "Added to Work. Nothing was sent."
                ))
                if viewModel.notice == nil {
                    viewModel.workspaceStatus = WorkboardTransientStatus(message: message)
                }
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
        let target = pickerDestination
        Task { await importResolvedBatch(batch, destination: target) }
    }
    #endif

    private func importPhotos(_ selection: [PhotosPickerItem], destination: WorkboardCaptureDestination) async {
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
            largeImportConfirmation = WorkboardWorkspaceLargeImportConfirmation(batch: batch, destination: destination)
        } else {
            await importResolvedBatch(batch, destination: destination)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        let destination = pickerDestination
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
                    largeImportConfirmation = WorkboardWorkspaceLargeImportConfirmation(batch: batch, destination: destination)
                } else {
                    await importResolvedBatch(batch, destination: destination)
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
    private func importResolvedBatch(_ batch: WorkboardResolvedImportBatch, destination: WorkboardCaptureDestination) async {
        let mapped = WorkboardImportMapping.imports(from: batch)
        await viewModel.importMaterials(
            mapped.imports,
            projectID: destination.projectID,
            additionalFailureCount: batch.failedCount
        )
        for url in mapped.scopedURLs { url.stopAccessingSecurityScopedResource() }
        WorkboardImportMapping.reclaim(batch)
    }

}

// MARK: - One pane-wide drop owner

extension View {
    /// Makes the complete Work detail region a capture target. This deliberately
    /// lives above both the scrolling canvas and pinned composer: nested drop
    /// handlers caused the composer to reject a valid drop while the populated
    /// desk had no handler at all. The optional project destination is frozen
    /// when the drop starts, before any provider begins loading.
    func workboardPaneDropDestination(viewModel: WorkboardViewModel) -> some View {
        modifier(WorkboardPaneDropModifier(viewModel: viewModel))
    }
}

private struct WorkboardPaneDropModifier: ViewModifier {
    @Bindable var viewModel: WorkboardViewModel

    private var destination: WorkboardCaptureDestination {
        WorkboardCaptureDestination(workspace: viewModel.deskWorkspace)
    }
    @State private var sessionDestination: WorkboardCaptureDestination = .all

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
                    Task { await importResolvedBatch(confirmation.batch, destination: confirmation.destination) }
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
        guard workbenchDestinationIsActive, !viewModel.deskWorkspace.isShowingConversation,
              !isImporting, dropSession == nil else { return false }
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
        sessionDestination = destination
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
        let destination = sessionDestination
        clearDropLoadBookkeeping()
        dropSession = nil
        if batch.hasLargeFiles {
            largeImportConfirmation = WorkboardWorkspaceLargeImportConfirmation(batch: batch, destination: destination)
        } else {
            Task { await importResolvedBatch(batch, destination: destination) }
        }
    }

    @MainActor
    private func importResolvedBatch(_ batch: WorkboardResolvedImportBatch, destination: WorkboardCaptureDestination) async {
        let mapped = WorkboardImportMapping.imports(from: batch)
        await viewModel.importMaterials(
            mapped.imports,
            projectID: destination.projectID,
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

/// What a folded card can do to the RECORDING drawn inside it.
///
/// Each route acts on one member and validates only that member — the recording
/// plays and shares whether or not the picture's bytes are on this device, and
/// the picture opens whether or not the recording's are. There is deliberately
/// no "share both": the desk has one share coordinator, it prepares one file,
/// and a second envelope would be a second definition of what leaving Work
/// means.
///
/// Deleting is absent on purpose. A folded card is ONE card, so it has ONE
/// Delete, and that Delete removes both members together through
/// `WorkboardViewModel.removeGroupFromBoard`.
struct WorkboardCompanionActions {
    /// Quick Look on the recording. The same route the recording's own card
    /// used before it folded.
    var open: () -> Void
    /// The system share sheet on the recording's file, not the picture's.
    var share: () -> Void
    /// Repair the recording's bytes on this device. A readable screenshot says
    /// nothing about whether its recording arrived, so the two are repaired
    /// separately — the card's own Reattach replaces the PICTURE, which is the
    /// wrong file for a missing recording.
    var reattach: () -> Void
}

/// Binds a card's companion to the board's own single-material seams.
///
/// Pure and separate from the view so the binding itself can be asserted: the
/// failure this exists to prevent is a route that acts on the PICTURE while its
/// menu row says "Recording". Every closure here is handed
/// `companion.material` — the child as its own card — so the seams stay
/// single-material and their availability gates answer for the recording.
enum WorkboardCompanionRouting {
    static func actions(
        for material: WorkboardMaterialSnapshot,
        onOpen: @escaping (WorkboardMaterialSnapshot) -> Void,
        onShare: @escaping (WorkboardMaterialSnapshot) -> Void,
        onReattach: @escaping (WorkboardMaterialSnapshot) -> Void
    ) -> WorkboardCompanionActions? {
        guard let companion = material.companion else { return nil }
        let child = companion.material
        return WorkboardCompanionActions(
            open: { onOpen(child) },
            share: { onShare(child) },
            reattach: { onReattach(child) }
        )
    }
}

/// The free card board. Cards render in the item's OWN material order — the
/// repository already sorts by `(sequence, createdAt, id)` — laid out by
/// `WorkboardMosaicLayout`, and every drop resolves to an insertion slot read
/// from the SAME engine result the layout placed with, so the gap a person aims
/// at is the gap the reorder writes.
private struct WorkboardMaterialBoard: View {
    @Bindable var viewModel: WorkboardViewModel
    let item: WorkboardItemSnapshot
    let onOpen: (WorkboardMaterialSnapshot) -> Void
    let onShare: (WorkboardMaterialSnapshot) -> Void
    let onReattach: (WorkboardMaterialSnapshot) -> Void

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive

    @State private var boardWidth: CGFloat = 0
    /// The board's own origin in the space its frame is measured in, PUBLISHED
    /// — written at the lift and then only while a card is in the air, because
    /// a moving origin is what lets a stored pointer be re-derived while the
    /// pointer itself holds still.
    @State private var boardOrigin: CGPoint = .zero
    /// The same frame, recorded unpublished on every geometry change so the
    /// lift has a current origin to start from without any scroll having
    /// invalidated the board.
    @State private var boardFrame = BoardFrame()
    @State private var dragSession: DragSession?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var coordinateSpaceID = UUID()
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

    /// The tile one grid unit is granted here. The smallest footprint IS one
    /// unit, so a folded small card sizes its band and its row against the tile
    /// it actually received — the same width that grants 81 points at 360
    /// grants 64 at 292.
    private var gridUnitHeight: CGFloat {
        WorkboardMosaicEngine(metrics: metrics).unitSize(forWidth: boardWidth).height
    }

    /// The cards the board displays, in order. A folded recording is not one
    /// of them — it rides inside its picture — so this is the displayed order
    /// the slot arithmetic and the commit both speak in.
    private var displayedIDs: [UUID] {
        item.materials.map(\.id)
    }

    /// The gap the lifted card would fall into, `0...count` in the CURRENT,
    /// source-present order. Nil whenever nothing is lifted or the pointer is
    /// off the board, which is also what takes the placeholder away.
    ///
    /// A committed slot outranks the pointer: between the drop and the moment
    /// the view model's order arrives, the board keeps showing the destination
    /// the person released on. Dropping that presentation early would put the
    /// card back where it started for as long as the provider decode and the
    /// desk's mutation lane take — a snap-back the person reads as a failure.
    private var acceptedSlot: Int? {
        guard let session = dragSession else { return nil }
        if let committed = session.committedSlot { return committed }
        guard let global = session.globalPoint else { return nil }
        return slot(
            at: WorkboardDragResolution.boardPoint(global: global, boardOrigin: boardOrigin),
            in: session
        )
    }

    /// What the board DRAWS: the lifted card gone from the sequence and a
    /// placeholder standing in the slot it would land in.
    private var dragEntries: [WorkboardDragArrangement.Entry] {
        WorkboardDragArrangement.entries(
            displayedIDs: displayedIDs,
            sourceID: dragSession?.sourceID,
            acceptedSlot: acceptedSlot
        )
    }

    /// Order and footprint together: the two inputs a reflow can come from.
    private var arrangement: [WorkboardMosaicEngine.Item] {
        item.materials.map { WorkboardMosaicEngine.Item(id: $0.id, size: $0.cardSize) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(macOS)
            // Mac keeps the choice in the band; the window has the width for a
            // segmented control and no navigation bar of its own to hold one.
            // On iOS the Work bar's view menu owns it, so nothing sits between
            // the pane's top inset and the first card.
            arrangementControls
            #endif
            boardSurface
        }
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
            // A folded card is two materials, so the sentence names both. The
            // person is looking at one card and would otherwise read a promise
            // about the picture while the recording inside it goes too.
            Text(String.localizedStringWithFormat(
                material.companion == nil
                    ? String(localized: LocalizedStringResource(
                        "workboard.material.remove.confirm.message",
                        defaultValue: "“%@” will be removed from your Work desk."
                    ))
                    : String(localized: LocalizedStringResource(
                        "workboard.material.remove.confirm.message.pair",
                        defaultValue: "“%@” and the recording inside it will be removed from your Work desk."
                    )),
                material.name
            ))
        }
    }

    /// The board, everything a live drag reads from it, and everything that
    /// ends one. Split off the body because the whole chain in one expression
    /// is more than the type checker will solve in reasonable time.
    private var boardSurface: some View {
        boardDropSurface
            // A reflow is a frame change, not a leaf property, so it takes the
            // value form. It is scoped to the board container and never reaches
            // the navigation split view that hosts it.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: arrangement)
            // The lifted card's neighbours move when — and only when — the slot
            // the board accepted changes. Pointer movement inside one slot
            // changes nothing to animate.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: dragEntries)
            .workboardDragFeedback(source: dragSession?.sourceID, slot: acceptedSlot)
            // Geometry only. The board's measured maps describe the layout that
            // just went away, so they are dropped here; persistence belongs to
            // the view model that owns the preference, and a control outside
            // this board can change it.
            .onChange(of: viewModel.layoutMode) { _, _ in
                endDrag()
                rowFrames = [:]
            }
            // The desk moved under a live drag. Tiles rebase — their slot lines
            // are a function of (count, width) and nothing else — but three
            // changes end the drag instead, because no honest answer survives
            // them: the lifted card left the board, the view model took the
            // commit over, or a list's frozen row measurements stopped
            // describing what is on screen.
            .onChange(of: displayedIDs) { _, ids in
                reconcileDrag(with: ids)
            }
            .onChange(of: workbenchDestinationIsActive) { _, active in
                if !active { endDrag() }
            }
            .onDisappear { endDrag() }
    }

    private var boardDropSurface: some View {
        boardContent
            .frame(maxWidth: .infinity)
            // A real trailing drop region makes appending possible even when
            // the final row occupies every grid column.
            .padding(.bottom, 24)
            .contentShape(Rectangle())
            .coordinateSpace(name: coordinateSpaceID)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                boardWidth = width
            }
            // The board's own ORIGIN, which moves whenever the board scrolls.
            // That movement is the only signal a STILL pointer gets that the
            // slot under it has changed — a drop delegate reports nothing while
            // the pointer holds still, which is exactly what a person does at
            // the edge while waiting for the board to scroll.
            //
            // It is recorded into a reference, which costs no invalidation, and
            // PUBLISHED only while a card is in the air. Publishing it always
            // would rebuild this board's body at scroll rate for a number
            // nothing but a live drag reads.
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                boardFrame.rect = frame
                if dragSession != nil, boardOrigin != frame.origin {
                    boardOrigin = frame.origin
                }
            }
            .onPreferenceChange(WorkboardRowFramesKey.self) { rowFrames = $0 }
            .onDrop(
                of: [.conduckWorkboardMaterial],
                delegate: WorkboardReorderDropDelegate(
                    isEnabled: workbenchDestinationIsActive && !viewModel.isCapturingIntoDesk,
                    onLocation: { hover(at: $0) },
                    onDrop: drop
                )
            )
    }

    // The in-band arrangement row is macOS-only. iOS reaches the same
    // preference from Work's toolbar (`WorkboardLayoutMenu`), and the drag
    // affordance is taught once by the board tutorial, so neither helper has an
    // iOS caller left to keep compiled.
    #if os(macOS)
    private var arrangementControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                arrangeHint
                Spacer(minLength: 8)
                layoutPicker
            }
            HStack {
                Spacer(minLength: 0)
                layoutPicker
            }
        }
    }

    private var arrangeHint: some View {
        Label(LocalizedStringResource(
            "workboard.arrange.hint",
            defaultValue: "Drag to reorder"
        ), systemImage: "hand.draw")
        .font(.caption)
        .foregroundStyle(AppColors.textSecondary)
        .fixedSize()
    }

    private var layoutPicker: some View {
        Picker(selection: $viewModel.layoutMode) {
            ForEach(WorkboardLayoutMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        } label: {
            Text(LocalizedStringResource("workboard.layout.label", defaultValue: "Board view"))
        }
        .pickerStyle(.segmented)
        .frame(width: 184)
        .disabled(!workbenchDestinationIsActive)
        .accessibilityIdentifier("workboard-layout")
    }
    #endif

    @ViewBuilder
    private var boardContent: some View {
        if viewModel.layoutMode == .tiles {
            WorkboardMosaicLayout(metrics: metrics, layoutDirection: layoutDirection) {
                boardItems
            }
        } else {
            VStack(spacing: 10) {
                boardItems
            }
        }
    }

    /// The cards, in DISPLAYED order — with one of them missing and a
    /// placeholder in its place whenever a drag is live.
    ///
    /// A folded recording is not one of them: it rides inside its picture's
    /// snapshot, so the index looked up here is a card POSITION and stays the
    /// right thing to hand a drag payload, a Move Earlier row and an
    /// accessibility position count. `WorkboardDragArrangement` decides what is
    /// drawn; the layout below places whatever it returns, and because the
    /// placeholder occupies the lifted card's footprint the number of tiles
    /// never changes mid-drag — which is the whole reason the slot lines can be
    /// treated as fixed.
    private var boardItems: some View {
        ForEach(dragEntries, id: \.self) { entry in
            switch entry {
            case .card(let id):
                if let index = displayedIDs.firstIndex(of: id) {
                    boardCard(item.materials[index], at: index)
                }
            case .placeholder:
                dropPlaceholder
            }
        }
    }

    private func boardCard(_ material: WorkboardMaterialSnapshot, at index: Int) -> some View {
        card(for: material, at: index)
            .workboardMosaicCardSize(material.cardSize)
            .background {
                if viewModel.layoutMode == .list {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: WorkboardRowFramesKey.self,
                            value: [material.id: proxy.frame(in: .named(coordinateSpaceID))]
                        )
                    }
                }
            }
            .onDrag {
                guard workbenchDestinationIsActive,
                      !viewModel.isCapturingIntoDesk else { return NSItemProvider() }
                beginDrag(of: material)
                return WorkMaterialDragPayload(
                    itemID: Constants.workboardDeskItemID,
                    materialID: material.id
                ).itemProvider()
            } preview: {
                liftPreview(for: material)
            }
            #if os(macOS)
            // The pointer says what the gesture is before it starts, which is
            // the only lift language a Mac has: there is no long press to feel
            // and no haptic to hear.
            //
            // The closed hand follows the live POINTER rather than the session.
            // Nothing reports a drag ending outside the board, so a session can
            // outlive the gesture that made it; the pointer leaving the board
            // is reported, and a cursor that reverted then is right in every
            // case a stale session would have left it closed over an idle
            // board.
            .pointerStyle(dragSession?.globalPoint == nil ? .grabIdle : .grabActive)
            #endif
            .accessibilityIdentifier("workboard-material-\(material.id.uuidString)")
    }

    /// The hole the lifted card left, standing in the slot it would land in.
    ///
    /// It is drawn rather than merely left empty because an empty slot in a
    /// grid of cards is indistinguishable from the end of the board; and it is
    /// a real participant in the layout rather than an overlay, so the cards
    /// around it are actually displaced and the person reads the destination
    /// off the arrangement instead of off a marker they have to interpret.
    private var dropPlaceholder: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return shape
            .fill(AppColors.brandAmber.opacity(0.10))
            .overlay {
                shape.strokeBorder(
                    AppColors.brandAmber.opacity(0.75),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
            }
            .frame(maxWidth: .infinity, maxHeight: viewModel.layoutMode == .list ? nil : .infinity)
            .frame(height: viewModel.layoutMode == .list ? placeholderHeight(forSource: dragSession?.sourceID) : nil)
            .workboardMosaicCardSize(WorkboardFootprint.uniform)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// What travels under the pointer.
    ///
    /// Deliberately NOT the card itself. `WorkboardSourceCard` and
    /// `WorkboardAudioCardView` each own a player and a payload read, so a
    /// second instance of one would mount a second reader for the same
    /// recording purely to be dragged. The preview instead reads the same face
    /// policy the card reads and draws its first two lines, so it says what the
    /// card says with none of the card's machinery.
    private func liftPreview(for material: WorkboardMaterialSnapshot) -> some View {
        let face = WorkboardCardFacePolicy.face(for: material)
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let size = liftPreviewSize(for: material)
        return HStack(alignment: .top, spacing: 10) {
            liftPreviewArtwork(for: material)
            VStack(alignment: .leading, spacing: 3) {
                if let lead = face.leadLine {
                    Text(verbatim: lead)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(3)
                        .truncationMode(face.headingProtectsExtension ? .middle : .tail)
                }
                if let identity = face.identity {
                    Text(verbatim: identity)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(AppColors.cardBackgroundElevated, in: shape)
        .overlay { shape.strokeBorder(AppColors.borderSubtle, lineWidth: 1) }
        .clipShape(shape)
    }

    /// The preview decodes its thumbnail SYNCHRONOUSLY. A staged decode would
    /// resolve after the system has already snapshotted the preview, so the
    /// picture card would be dragged as an empty frame; the bytes here are an
    /// `ImageProcessor` thumbnail, which is what makes that affordable.
    @ViewBuilder
    private func liftPreviewArtwork(for material: WorkboardMaterialSnapshot) -> some View {
        let artworkShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let data = material.thumbnailData, let image = Image.platformImage(from: data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(artworkShape)
        } else {
            Image(systemName: WorkboardMaterialIcon.symbol(for: material))
                .font(.system(size: 18))
                .foregroundStyle(WorkboardMaterialIcon.tint(for: material))
                .frame(width: 40, height: 40)
                .background(AppColors.backgroundSecondary, in: artworkShape)
        }
    }

    /// The size of the hole the card leaves, so what the pointer carries and
    /// what the board is holding open for it are the same shape.
    private func liftPreviewSize(for material: WorkboardMaterialSnapshot) -> CGSize {
        if viewModel.layoutMode == .list {
            let width = boardWidth.isFinite && boardWidth > 0 ? boardWidth : Self.fallbackPreviewEdge * 2
            return CGSize(width: width, height: placeholderHeight(forSource: material.id))
        }
        let slot = WorkboardMosaicEngine(metrics: metrics)
            .slotFrames(count: max(1, item.materials.count), width: boardWidth)
            .first
        guard let slot,
              slot.width.isFinite, slot.height.isFinite,
              slot.width > 0, slot.height > 0 else {
            return CGSize(width: Self.fallbackPreviewEdge, height: Self.fallbackPreviewEdge)
        }
        return slot.size
    }

    /// A list row states a MINIMUM height and then grows with its text, so a
    /// placeholder that guessed would move every row below it. The source's own
    /// measured height is the only number that leaves them where they were.
    private func placeholderHeight(forSource id: UUID?) -> CGFloat {
        guard let id else { return Self.listRowMinimumHeight }
        return WorkboardDragResolution.placeholderHeight(
            for: id,
            frames: dragSession?.rowFrames ?? rowFrames,
            fallback: Self.listRowMinimumHeight
        )
    }

    private static let listRowMinimumHeight: CGFloat = 88
    private static let fallbackPreviewEdge: CGFloat = 160

    /// The board's live frame, held in a reference on purpose: a scroll changes
    /// it on every frame, and routing that through view state would rebuild the
    /// board's body at scroll rate for a value only a live drag reads.
    private final class BoardFrame {
        var rect: CGRect = .zero
    }

    // MARK: - The live drag

    /// One live drag, as a value.
    ///
    /// The SOURCE's lifetime is deliberately not the POINTER's. A drop delegate
    /// reports the pointer leaving the board; it never reports the drag ending,
    /// so a session torn down on exit could not resume when the pointer came
    /// back with the same card still in the air — and a session torn down on a
    /// timer would guess. What an exit clears is the pointer, which is what the
    /// placeholder is drawn from: leaving the board takes the placeholder away,
    /// returning puts it back, and a drag that ends elsewhere simply never
    /// draws one again.
    private struct DragSession: Equatable {
        /// This drag, told apart from every other one.
        ///
        /// The commit's tail runs LONG after the board released the session:
        /// the board holds the destination only until the view model's order
        /// arrives, and the person may already be holding the next card in the
        /// air by the time the provider decode and the mutation lane finish. A
        /// tail that cleared unconditionally would take that new drag's
        /// placeholder away and make its drop fail the session guard; a tail
        /// that clears only its own token leaves it alone.
        let token = UUID()
        let sourceID: UUID
        /// The displayed order at the lift. The frozen row frames below are
        /// true of this order and of no other.
        let listBaseline: [UUID]
        /// List row frames as measured at the lift. The reflow moves every row,
        /// so resolving against live frames would chase the cards it is moving.
        let rowFrames: [UUID: CGRect]
        /// The board width those frames were measured at. A row states a
        /// minimum height and grows with its text, so a width change re-wraps
        /// and re-measures every one of them.
        let listWidth: CGFloat
        /// The pointer, in the space the board's own frame is measured in — so
        /// a scroll under a still pointer re-derives a new board-local point
        /// instead of holding a stale slot. Nil while the pointer is off the
        /// board.
        var globalPoint: CGPoint? = nil
        /// Set at the drop and held until the view model's order arrives.
        var committedSlot: Int? = nil
    }

    /// The slot a board-local point is over, in the CURRENT source-present
    /// order.
    ///
    /// The count is the DISPLAYED count throughout the drag, never one less:
    /// the source is lifted rather than removed and the placeholder occupies
    /// its footprint, so a count that dropped by one would slide every slot
    /// line out from under a pointer that had not moved.
    ///
    /// Nil is a refusal, and only the list can answer it: its lines come from
    /// measurements that are true of one order, and it declines rather than
    /// resolve against measurements the board has outgrown.
    private func slot(at point: CGPoint, in session: DragSession) -> Int? {
        slot(
            at: point,
            baseline: session.listBaseline,
            frames: session.rowFrames,
            width: session.listWidth
        )
    }

    /// The same question asked from measurements the caller names, so a board
    /// that never lifted anything can still answer it — see `drop` for the one
    /// caller that has no session of its own. A LIVE baseline and live frames
    /// describe the board exactly as a frozen pair describes the board at the
    /// lift, so both go through one implementation and neither can drift.
    private func slot(
        at point: CGPoint,
        baseline: [UUID],
        frames: [UUID: CGRect],
        width: CGFloat
    ) -> Int? {
        guard !item.materials.isEmpty else { return nil }
        if viewModel.layoutMode == .list {
            // The frozen map is true of one order AND of one set of heights.
            // `listSlot` tests the order; this tests the measurements, which a
            // resize, a Dynamic Type change or a row settling to a taller
            // intrinsic height all move without touching the order at all.
            guard WorkboardDragResolution.measuredRowsHold(
                frozen: frames,
                live: rowFrames,
                frozenWidth: width,
                liveWidth: boardWidth
            ) else { return nil }
            return WorkboardDragResolution.listSlot(
                at: point,
                baseline: baseline,
                displayedIDs: displayedIDs,
                frames: frames
            )
        }
        return WorkboardMosaicEngine(metrics: metrics).insertionSlot(
            at: point,
            count: item.materials.count,
            width: boardWidth,
            layoutDirection: layoutDirection
        )
    }

    private func beginDrag(of material: WorkboardMaterialSnapshot) {
        // The published origin is only kept current while a drag is live, so
        // the lift is where it is brought up to date.
        boardOrigin = boardFrame.rect.origin
        dragSession = DragSession(
            sourceID: material.id,
            listBaseline: displayedIDs,
            rowFrames: rowFrames,
            listWidth: boardWidth
        )
    }

    /// A pointer position, or nil for a pointer that has left the board. A
    /// committed drag ignores both: the destination it is holding is no longer
    /// a question about where the pointer is.
    private func hover(at location: CGPoint?) {
        guard var session = dragSession, session.committedSlot == nil else { return }
        session.globalPoint = location.map {
            WorkboardDragResolution.globalPoint(board: $0, boardOrigin: boardOrigin)
        }
        dragSession = session
    }

    private func endDrag() {
        dragSession = nil
    }

    /// End one PARTICULAR drag. Everything that finishes asynchronously ends
    /// this way, because by the time it runs the session it belongs to may
    /// already be gone and a different card may be in the air.
    /// A nil token is a drag this board never drew — a lift in another window —
    /// so there is no presentation of its own to take down.
    private func endDrag(matching token: UUID?) {
        guard let token, dragSession?.token == token else { return }
        dragSession = nil
    }

    /// The desk moved while a card was in the air.
    ///
    /// Tiles rebase silently — their slot lines are a function of (count,
    /// width) and of nothing the desk stores — so an arriving capture just
    /// re-resolves. Three changes end the drag instead, because no honest
    /// answer survives them.
    private func reconcileDrag(with ids: [UUID]) {
        guard let session = dragSession else { return }
        guard WorkboardDragResolution.dragSurvives(
            sourceID: session.sourceID,
            listBaseline: session.listBaseline,
            displayedIDs: ids,
            isCommitted: session.committedSlot != nil,
            resolvesByMeasuredRows: viewModel.layoutMode == .list
        ) else {
            endDrag()
            return
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
    ///
    /// A folded card additionally carries the routes for the recording inside
    /// it, bound ONCE here so the two card families that can draw a companion
    /// cannot disagree about which material those routes act on. They are nil
    /// for every card that folded nothing, which is what keeps the rows off a
    /// card that has no recording to offer them for.
    @ViewBuilder
    private func card(for material: WorkboardMaterialSnapshot, at index: Int) -> some View {
        let onMoveEarlier: (() -> Void)? = index > 0
            ? { move(material, direction: .earlier) }
            : nil
        let onMoveLater: (() -> Void)? = index + 1 < item.materials.count
            ? { move(material, direction: .later) }
            : nil
        let companionRoutes = WorkboardCompanionRouting.actions(
            for: material,
            onOpen: onOpen,
            onShare: onShare,
            onReattach: onReattach
        )
        if viewModel.layoutMode == .list {
            WorkboardMaterialListRow(
                material: material,
                boardPosition: index + 1,
                boardCount: item.materials.count,
                onOpen: { onOpen(material) },
                onShare: { onShare(material) },
                onReattach: { onReattach(material) },
                onMoveEarlier: onMoveEarlier,
                onMoveLater: onMoveLater,
                onRemove: { materialPendingRemoval = material },
                onOpenCompanion: companionRoutes?.open,
                onShareCompanion: companionRoutes?.share,
                onReattachCompanion: companionRoutes?.reattach
            )
        } else if material.kind == .audio {
            WorkboardAudioCardView(
                material: material,
                size: material.cardSize,
                grantedColumns: gridColumns,
                boardPosition: index + 1,
                boardCount: item.materials.count,
                onOpen: { onOpen(material) },
                onShare: { onShare(material) },
                onReattach: { onReattach(material) },
                onMoveEarlier: onMoveEarlier,
                onMoveLater: onMoveLater,
                onRemove: { materialPendingRemoval = material }
            )
        } else {
            WorkboardSourceCard(
                material: material,
                size: material.cardSize,
                grantedColumns: gridColumns,
                grantedUnitHeight: gridUnitHeight,
                boardPosition: index + 1,
                boardCount: item.materials.count,
                onOpen: { onOpen(material) },
                onShare: { onShare(material) },
                onReattach: { onReattach(material) },
                onMoveEarlier: onMoveEarlier,
                onMoveLater: onMoveLater,
                onRemove: { materialPendingRemoval = material },
                onOpenCompanion: companionRoutes?.open,
                onShareCompanion: companionRoutes?.share,
                onReattachCompanion: companionRoutes?.reattach
            )
        }
    }

    /// The release.
    ///
    /// The slot is resolved SYNCHRONOUSLY, while the arrangement the person was
    /// looking at is still the arrangement, and immediately named by a
    /// neighbour card and a side. Everything after this is asynchronous — the
    /// provider decodes off the main actor and the view model then waits for
    /// the desk's mutation lane — and an arrival landing in either gap silently
    /// changes which gap an integer would have meant. A neighbour is re-found
    /// in whatever order the planner eventually sees, and a neighbour that has
    /// gone becomes a refusal the person can read.
    ///
    /// The board keeps drawing the destination across that whole interval. The
    /// alternative — clearing on release — puts the card back where it started
    /// until the write lands, so every successful drop would flash a snap-back
    /// first.
    private func drop(_ provider: NSItemProvider, at location: CGPoint) -> Bool {
        guard workbenchDestinationIsActive,
              !viewModel.isCapturingIntoDesk,
              !item.materials.isEmpty
        else {
            endDrag()
            return false
        }
        // A LIFT IN ANOTHER WINDOW reaches this board with no session of its
        // own. iPad runs several Work scenes (`UIApplicationSupportsMultipleScenes`)
        // and so does the Mac, the drag crosses them, and `validateDrop` has
        // already accepted a payload this process wrote — so requiring a local
        // lift here would refuse a reorder the board can answer perfectly well.
        // It can: the card was lifted from the OTHER window's sequence, not
        // from the desk, so it is still displayed here and the live order and
        // live row frames describe this board exactly as a frozen pair
        // describes the window that started the drag.
        //
        // `flatMap`, not `map`: a session that cannot ANSWER must not swallow
        // the fallback. `map` builds an `Int??` whose inner nil survives `??`,
        // so a board merely HOLDING a session — including the one a local drag
        // cancelled off the board leaves behind, which nothing clears — would
        // refuse a foreign drop before the payload is even decoded, and the
        // identity check below could never run. A frozen pair that has stopped
        // describing this board is not a reason to refuse a drag it never
        // belonged to; it is a reason to ask the same question of the
        // measurements that DO describe the board. Those are honest here
        // precisely BECAUSE the frozen pair refused: nothing is drawn lifted
        // while `acceptedSlot` is nil, so the live order and the live frames
        // are the arrangement the person released over. A frozen map that is
        // still answering keeps its answer — this never second-guesses it.
        let session = dragSession
        let heldSlot = session.flatMap { slot(at: location, in: $0) }
        let resolved = heldSlot ?? slot(
            at: location,
            baseline: displayedIDs,
            frames: rowFrames,
            width: boardWidth
        )
        guard let slot = resolved,
              let target = WorkboardDragArrangement.commitTarget(
                  slot: slot,
                  displayedIDs: displayedIDs
              )
        else {
            endDrag()
            return false
        }
        // Only a LOCAL drag has a presentation to hold: this board drew the
        // hole, so this board keeps drawing the destination until the view
        // model's order arrives. A drag from another window displaced nothing
        // here, so there is nothing to hold and nothing to release.
        // The hold belongs to the session that RESOLVED the drop, which is why
        // it is conditioned on `heldSlot` rather than on a session existing:
        // a session whose frozen pair refused did not draw this destination and
        // is about some other card, so committing the live slot onto it would
        // open a hole at the wrong card until the decode disowned it.
        var token: UUID?
        var heldSourceID: UUID?
        if heldSlot != nil, var session {
            session.globalPoint = nil
            session.committedSlot = slot
            dragSession = session
            token = session.token
            heldSourceID = session.sourceID
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.conduckWorkboardMaterial.identifier) { data, _ in
            guard let data,
                  let moving = try? JSONDecoder().decode(WorkMaterialDragPayload.self, from: data),
                  moving.itemID == Constants.workboardDeskItemID else {
                Task { @MainActor in endDrag(matching: token) }
                return
            }
            Task { @MainActor in
                guard workbenchDestinationIsActive else {
                    endDrag(matching: token)
                    return
                }
                // The destination this board is holding describes the card
                // that was lifted HERE. A payload naming a different material
                // came from somewhere else — another window, or a gesture this
                // board's own session outlived — so the presentation is about
                // the wrong card and is released before the write rather than
                // after it.
                if let heldSourceID, moving.materialID != heldSourceID {
                    endDrag(matching: token)
                }
                await viewModel.reorderMaterial(
                    moving.materialID,
                    relativeTo: target.neighbourID,
                    placement: target.placement
                )
                // A refused reorder leaves the desk's own order standing, so
                // the order may never change and the held presentation has to
                // be released by the operation ENDING as well as by the board
                // moving. Whichever happens first wins; both are idempotent —
                // and both release THIS drag only, never whichever one the
                // person started while the write was in flight.
                endDrag(matching: token)
            }
        }
        return true
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

    /// One card, one Delete. A folded card removes BOTH of its materials in one
    /// store mutation, so the recording can never be left behind as an orphan
    /// card the person never asked to keep.
    ///
    /// The companion id comes from the card that raised the menu — the pair the
    /// person was looking at — and is passed through unchanged. Re-resolving the
    /// fold here would let a sync that arrived mid-confirmation delete a
    /// different recording from the one on screen.
    private func remove(_ material: WorkboardMaterialSnapshot) {
        guard workbenchDestinationIsActive else { return }
        Task {
            if let companion = material.companion {
                await viewModel.removeGroupFromBoard(
                    parentID: material.id,
                    childID: companion.id
                )
            } else {
                await viewModel.removeMaterialFromBoard(material.id)
            }
        }
    }
}

/// The lift language a drag has on each platform, stated side by side rather
/// than buried in a board's modifier chain.
///
/// iOS gets haptics at the two moments the person's own hand is covering: the
/// card coming free of the board, and the destination changing under a finger
/// that cannot see past itself. macOS has neither — no long press to feel and
/// nothing to hear — so it says the same two things with the pointer, which is
/// why the grab cursors sit on the cards rather than here.
private extension View {
    func workboardDragFeedback(source: UUID?, slot: Int?) -> some View {
        #if os(iOS)
        return workboardLiftFeedback(source: source).workboardSlotFeedback(slot: slot)
        #else
        return self
        #endif
    }
}

#if os(iOS)
private extension View {
    func workboardLiftFeedback(source: UUID?) -> some View {
        // Any new card coming free of the board, not only the first one after
        // an idle board: a cancelled drag leaves no signal behind it, so a
        // session can still be standing when the next lift happens, and a
        // condition that demanded an idle board first would drop that lift's
        // haptic.
        sensoryFeedback(.impact(weight: .medium), trigger: source) { (previous: UUID?, current: UUID?) -> Bool in
            current != nil && previous != current
        }
    }

    func workboardSlotFeedback(slot: Int?) -> some View {
        sensoryFeedback(.impact(weight: .light), trigger: slot) { (previous: Int?, current: Int?) -> Bool in
            previous != nil && current != nil && previous != current
        }
    }
}
#endif

/// How a card spends its tile: on a picture, or on a text column with artwork
/// beside it.
///
/// Stated apart from the view, and pure, because the answer decides two
/// different layouts AND a scrim that has to stay legible over an arbitrary
/// photo — a rule that is asserted directly rather than inferred from a
/// rendered card. Only a picture the board already holds can be spent this way:
/// a thumbnail-less image card has nothing to fill the tile with, so it keeps
/// the glyph layout rather than drawing an empty frame with a caption over it.
enum WorkboardCardArtworkMode: String, Equatable, Sendable {
    /// The thumbnail IS the tile; the name and footer sit over a bottom scrim.
    case imageForward
    /// Artwork (glyph or thumbnail) beside the text column — every other card.
    case inline

    /// - Parameter footprint: the size the card was actually GRANTED, not the
    ///   stored choice. A `large` card clamped to a standard slot must resolve
    ///   as a standard one, or the caption would be laid out for a width the
    ///   mosaic never handed over.
    static func resolve(
        kind: WorkboardMaterialKind,
        hasThumbnail: Bool,
        footprint: WorkMaterialCardSize
    ) -> WorkboardCardArtworkMode {
        guard kind == .image, hasThumbnail else { return .inline }
        switch footprint {
        // A 30pt thumbnail cannot carry a caption over it, so the smallest
        // footprint keeps artwork + one line of name and reads its picture as
        // artwork rather than as the tile.
        case .small: return .inline
        case .standard, .large: return .imageForward
        }
    }
}

/// One row a folded card offers about the recording inside it. Named as
/// actions rather than as strings so the menu, the VoiceOver actions and the
/// transport cannot drift apart about what is offered, and so the set is
/// decidable without mounting a card.
enum WorkboardCompanionAction: String, Equatable, Sendable, CaseIterable {
    case play
    case pause
    case cancelLoading
    case openRecording
    case shareRecording
    /// The recording's own repair. A folded card that dropped this row would
    /// take the only route back for a recording whose local bytes are gone —
    /// the picture's Reattach answers for the picture.
    case reattachRecording
}

/// What a picture's folded voice material draws, and where.
///
/// TWO COMPANIONS, ONE BAND. A press of Capture to Work leaves the picture with
/// either the recording (`.audio`) or the words alone (`.transcript`), and the
/// band draws both: the name, as much of the words as the footprint holds, and
/// — only for a recording — the transport and its progress track. A words-only
/// companion has no bytes, so a transport over it would be a control that fails
/// on every activation and a clock that measures a clip nothing decoded.
///
/// Stated apart from the view, and pure, because the band appears in three
/// different tiles — over the photograph's scrim, inside a standard/large tile
/// with no thumbnail to fill itself with, and on the smallest footprint — and
/// "a picture with a voice material always shows it" must be ONE rule rather
/// than three layout branches that can each forget it. `WorkboardCompanionFold`
/// decides whether there is a companion at all; this decides only how the card
/// that hid it draws it.
///
/// The band is drawn for ANY card carrying a companion the tile has room for,
/// without re-checking the parent's kind: the fold only ever attaches a voice
/// material to a picture, and a card that hid one and then declined to draw it
/// would be the one way a material could vanish from the desk.
enum WorkboardCompanionBand {
    /// How the band is drawn on one card.
    enum Placement: String, Equatable, Sendable {
        /// On the photograph's bottom scrim, where the colours are literals
        /// because the surface underneath is an arbitrary picture.
        case scrim
        /// In the card's own text column, on the elevated card surface.
        case inline
        /// The transport alone, on a strip too short to hold words. The
        /// smallest tile is ONE grid unit — as little as 64 points, and never
        /// more than 81 on a compact board — and the strip band's own words
        /// plus the stacked thumbnail-and-name body do not both fit inside it,
        /// so the band gives up everything the card already says elsewhere: the
        /// recording's name and transcript stay in the card's spoken label and
        /// in its rows.
        case compact
    }

    /// - Parameter footprint: the size the card was actually GRANTED, exactly
    ///   as `WorkboardCardArtworkMode.resolve` takes it — a `large` card the
    ///   mosaic clamped draws the standard tile, so it draws the standard band.
    static func placement(
        for material: WorkboardMaterialSnapshot,
        footprint: WorkMaterialCardSize
    ) -> Placement? {
        guard let companion = material.companion else { return nil }
        // The smallest tile is compact whatever it draws inside itself: a
        // single grid unit has no room for a strip band's words on TOP of the
        // tile's own content, so the footprint decides before the artwork does.
        guard footprint != .small else {
            // And a compact band is its transport and NOTHING else, so a
            // words-only companion has nothing left to put there. It draws no
            // band at all rather than an empty strip standing on the picture:
            // the words are still in the card's spoken label and in the sheet
            // the tile opens.
            return companion.kind == .audio ? .compact : nil
        }
        switch WorkboardCardArtworkMode.resolve(
            kind: material.kind,
            hasThumbnail: material.thumbnailData != nil,
            footprint: footprint
        ) {
        case .imageForward: return .scrim
        case .inline: return .inline
        }
    }

    /// The pieces of the smallest tile's vertical budget at the REFERENCE unit,
    /// named here rather than left as literals in the view so the drawn sizes
    /// and the mosaic engine's own unit are one arithmetic a test can add up.
    /// The strip band (a 32-point transport, the recording's name and the
    /// progress track) plus the stacked thumbnail-and-name body needs about 116
    /// points — far more than the 64 to 81 a compact board's unit gives — which
    /// is why the small footprint draws neither.
    static let compactTransport: CGFloat = 26
    static let compactBandPadding: CGFloat = 4
    /// The thumbnail on a small folded card's single content row.
    static let compactArtwork: CGFloat = 24
    /// The inset the smallest tile draws its content in.
    static let compactInset: CGFloat = 9
    /// The tile the sizes above are drawn at: one grid unit at the compact
    /// board width. The grid grants LESS than this whenever the board is
    /// narrower — 71 points at 320, 64 points at the 292 where the four-column
    /// grid gives way — so the sizes above are a ceiling, never a promise.
    static let referenceUnitHeight: CGFloat = 81

    /// The compact band and the row it stands on, sized for the tile the mosaic
    /// actually granted.
    ///
    /// A single value rather than four call sites reading four statics, because
    /// the ONE thing that matters about these numbers is their sum: the band is
    /// drawn ON the tile, so a body that overflows is not merely clipped — it
    /// ends up hidden BEHIND the band, taking the picture's name and its
    /// availability glyph with it.
    struct CompactMetrics: Equatable, Sendable {
        let transport: CGFloat
        let bandPadding: CGFloat
        let artwork: CGFloat
        let inset: CGFloat

        /// A compact band is its transport and nothing else, so its height is
        /// one number rather than whatever dynamic type does to a line of words.
        var bandHeight: CGFloat { transport + 2 * bandPadding }
        /// What a folded small card asks of its tile, top to bottom.
        var foldedHeight: CGFloat { artwork + 2 * inset + bandHeight }
    }

    /// The compact sizes for a tile of `tileHeight` points.
    ///
    /// Everything scales with the granted tile below the reference unit and
    /// nothing grows above it: the fit is then arithmetic rather than luck —
    /// the pieces sum to at most `76/81` of whatever tile they are given, so a
    /// folded small card fits every unit the grid can produce, at every width,
    /// at every dynamic type size. Growing on a wide board would instead put a
    /// 46-point transport on a tile whose neighbours are drawn at 26.
    static func compactMetrics(forTileHeight tileHeight: CGFloat) -> CompactMetrics {
        let scale = compactScale(forTileHeight: tileHeight)
        // Rounded DOWN: half a point of slack per piece is invisible, and
        // rounding the other way would spend a tile the grid never granted.
        return CompactMetrics(
            transport: (compactTransport * scale).rounded(.down),
            bandPadding: (compactBandPadding * scale).rounded(.down),
            artwork: (compactArtwork * scale).rounded(.down),
            inset: (compactInset * scale).rounded(.down)
        )
    }

    /// A tile no bigger than the reference unit shrinks the drawing in
    /// proportion; a bigger one draws it as designed. A tile of no height at
    /// all is a card that has not been measured yet, which draws the reference
    /// rather than collapsing to nothing.
    private static func compactScale(forTileHeight tileHeight: CGFloat) -> CGFloat {
        guard tileHeight.isFinite, tileHeight > 0 else { return 1 }
        return min(1, tileHeight / referenceUnitHeight)
    }

    /// The strip band every other placement draws: a 32-point transport inside
    /// 8 points of padding.
    static let stripBandHeight: CGFloat = 32 + 2 * 8
    /// The stacked thumbnail-and-name body a card draws when no band is
    /// standing on it: a 30-point thumbnail, 6 points of spacing and a line of
    /// name, inside the compact inset.
    static let stackedBodyHeight: CGFloat = 30 + 6 + 14 + 2 * compactInset

    /// What a folded card asks of the tile it was granted, for the band that
    /// card actually draws.
    ///
    /// Stated for every placement, and keyed on the placement rather than on
    /// the footprint, so the question a test asks is the question the card
    /// answered: a card that stopped drawing the compact band falls back to the
    /// strip band standing on the stacked body, and that arrangement is
    /// measurable here instead of only visible as clipping on a device.
    static func foldedHeight(
        drawing placement: Placement,
        inTileOfHeight tileHeight: CGFloat
    ) -> CGFloat {
        switch placement {
        case .compact: return compactMetrics(forTileHeight: tileHeight).foldedHeight
        case .scrim, .inline: return stripBandHeight + stackedBodyHeight
        }
    }

    /// The words the band names the voice material with: the transcript's lead
    /// line, which the publication lane already wrote onto its title, and the
    /// placeholder that material's own card carries when there is no lead line
    /// to use. Never a second derivation of the title — a folded voice material
    /// and a standalone one are named identically.
    static func title(for companion: WorkboardCompanionSnapshot) -> String {
        let name = companion.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty else { return name }
        // A words-only companion is not a "Voice note": there is no recording
        // to call one. It falls back to the noun its own card would draw.
        guard companion.kind == .audio else {
            return String(localized: WorkboardMaterialKind.transcript.title)
        }
        return String(localized: LocalizedStringResource(
            "workboard.voice.recording.untitled",
            defaultValue: "Voice note"
        ))
    }

    /// The words under the name, when there are any. A recording with no
    /// transcript draws none rather than a placeholder: the recording is the
    /// material and the words are an extra, exactly as on the audio card.
    static func transcript(for companion: WorkboardCompanionSnapshot) -> String? {
        guard let text = companion.textContent?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The recording's two text slots, deduplicated by the SHARED face policy.
    ///
    /// Every surface that draws a folded recording draws this pair, so the
    /// folded card gets the same rule the standalone audio card already had: a
    /// title the transcript already says is dropped rather than stacked on top
    /// of it. Without this the band, the list row and the gallery each showed
    /// the recording's opening line twice — the one duplication the face policy
    /// could not see, because the companion hangs off another material's card.
    static func face(for companion: WorkboardCompanionSnapshot) -> WorkboardCardFace {
        WorkboardCardFacePolicy.companionFace(
            title: title(for: companion),
            transcript: transcript(for: companion)
        )
    }

    /// How much of the transcript a footprint can carry. The smallest tile
    /// carries none — its band is compact and draws no words at all, because a
    /// single grid unit is already spending its height on the picture and its
    /// name — and the large tile spends its extra height on the words.
    static func transcriptLineLimit(for footprint: WorkMaterialCardSize) -> Int? {
        switch footprint {
        case .small: return nil
        case .standard: return 2
        case .large: return 6
        }
    }

    /// The rows this card offers about the recording, in menu order.
    ///
    /// Each one asks the COMPANION's availability, never the picture's: a
    /// screenshot that is readable here says nothing about whether its
    /// recording's bytes arrived, and the two are separate materials with
    /// separate lanes.
    ///
    /// A WORDS-ONLY COMPANION OFFERS NONE OF THEM. Every row here names a file
    /// — play it, open it, share those bytes, repair them — and a `.transcript`
    /// has no file at all, so each row would be an action that fails the moment
    /// it is chosen. The words themselves are already drawn in the band and
    /// spoken in the card's label, and the card's own Share still hands over
    /// the picture.
    static func actions(
        for companion: WorkboardCompanionSnapshot,
        phase: WorkboardAudioPhase,
        hasOpenRecording: Bool,
        hasShareRecording: Bool,
        hasReattachRecording: Bool = false
    ) -> [WorkboardCompanionAction] {
        guard companion.kind == .audio else { return [] }
        var actions: [WorkboardCompanionAction] = []
        if WorkboardCardActionPolicy.allows(.play, when: companion.availability) {
            switch WorkboardAudioCardPresentation.transportAction(for: phase) {
            case .play: actions.append(.play)
            case .pause: actions.append(.pause)
            case .cancelLoading: actions.append(.cancelLoading)
            }
        }
        // Open and Share ride the SAME permission — both read the recording's
        // bytes — so a recording that cannot be opened cannot be shared either.
        if WorkboardCardActionPolicy.allows(.open, when: companion.availability) {
            if hasOpenRecording { actions.append(.openRecording) }
            if hasShareRecording { actions.append(.shareRecording) }
        }
        if hasReattachRecording,
           WorkboardCardActionPolicy.allows(.reattach, when: companion.availability) {
            actions.append(.reattachRecording)
        }
        return actions
    }

    static func title(for action: WorkboardCompanionAction) -> LocalizedStringResource {
        switch action {
        case .play:
            return LocalizedStringResource("workboard.companion.play", defaultValue: "Play Recording")
        case .pause:
            return LocalizedStringResource("workboard.companion.pause", defaultValue: "Pause Recording")
        case .cancelLoading:
            return LocalizedStringResource(
                "workboard.audio.cancelLoading",
                defaultValue: "Cancel Loading"
            )
        case .openRecording:
            return LocalizedStringResource(
                "workboard.companion.open.recording",
                defaultValue: "Open Recording"
            )
        case .shareRecording:
            return LocalizedStringResource(
                "workboard.companion.share.recording",
                defaultValue: "Share Recording"
            )
        case .reattachRecording:
            return LocalizedStringResource(
                "workboard.companion.reattach",
                defaultValue: "Reattach Recording"
            )
        }
    }

    static func symbol(for action: WorkboardCompanionAction) -> String {
        switch action {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .cancelLoading: return "xmark"
        case .openRecording: return "arrow.up.forward.app"
        case .shareRecording: return "square.and.arrow.up"
        case .reattachRecording: return "paperclip"
        }
    }

    /// What the card's own Share row is called. A folded card holds two files,
    /// so the unqualified "Share" would not say which one leaves.
    static func shareTitle(hasCompanion: Bool) -> LocalizedStringResource {
        hasCompanion
            ? LocalizedStringResource(
                "workboard.companion.share.picture",
                defaultValue: "Share Screenshot"
            )
            : LocalizedStringResource("workboard.material.share", defaultValue: "Share")
    }

    /// What the folded card SAYS the recording is doing, apart from what it is
    /// called. Spoken as the card's accessibility VALUE, the same split the
    /// audio card and the list row use: the label is what the card is, the
    /// value is the state it is in, and only a value can be re-read after an
    /// action without repeating the name and the transcript.
    ///
    /// Without it the band's state reaches VoiceOver nowhere at all — the band
    /// is accessibility-hidden, because its transport is a control drawn beside
    /// an element whose children are ignored — so a decode that failed, or an
    /// output another capture already holds, would offer "Play Recording" again
    /// with no explanation of the refusal.
    ///
    /// The RECORDING's own availability is asked, never the picture's, exactly
    /// as its rows do: a screenshot readable here says nothing about whether
    /// the audio's bytes arrived.
    static func accessibilityValue(
        for companion: WorkboardCompanionSnapshot,
        phase: WorkboardAudioPhase,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> String {
        var parts: [String] = []
        if companion.availability != .available {
            parts.append(String(localized: WorkboardCardAccessibility.availabilityLabel(
                for: companion.availability
            )))
        }
        // A words-only companion holds no clip, so the transport status and the
        // clock would both report a player that is not there. What it can be
        // doing is exactly its availability, and usually nothing at all.
        guard companion.kind == .audio else { return parts.joined(separator: ". ") }
        if let status = WorkboardAudioTransport.statusLabel(for: phase) {
            parts.append(String(localized: status))
        }
        // The clock is a fact only a decoded clip has. Announcing one before
        // that would state a length nothing has measured.
        if duration > 0 {
            parts.append(WorkboardAudioTransport.clockText(elapsed: elapsed, duration: duration))
        }
        return parts.joined(separator: ". ")
    }

    /// What a folded card IS, in the one place it is said. It replaces the
    /// kind's own title in the spoken card, because "Image" would describe half
    /// of what the person is touching.
    ///
    /// It names WHICH half, too. A picture with a recording on it offers Play,
    /// Open Recording and Share Recording; a picture with words on it offers
    /// none of them, and a label that called both "voice note" would promise a
    /// clip that half of these cards do not have.
    static func accessibilityKindLabel(
        for companion: WorkboardCompanionSnapshot
    ) -> LocalizedStringResource {
        companion.kind == .audio
            ? LocalizedStringResource(
                "workboard.companion.card.label",
                defaultValue: "Screenshot with voice note"
            )
            : LocalizedStringResource(
                "workboard.companion.card.label.words",
                defaultValue: "Screenshot with note"
            )
    }
}

/// One material as a board card at one of three footprints. The card fills the
/// frame the mosaic proposes — it never states its own height — so a size change
/// is a single persisted attribute rather than a second layout system.
struct WorkboardSourceCard: View {
    let material: WorkboardMaterialSnapshot
    var size: WorkMaterialCardSize = .standard
    /// The grid width the mosaic granted. `size` stays the stored choice — it
    /// drives the menu and the label — while the layout keys off the footprint
    /// the card actually received, which is narrower whenever the grid clamps.
    var grantedColumns: Int = WorkboardMosaicSpan.large.columns
    /// The height of one grid unit at this board width, which IS the tile a
    /// small card is drawn in. The compact band and the row under it are sized
    /// from it rather than from the compact board's unit, because the grid
    /// grants as little as 64 points before it drops to two columns.
    var grantedUnitHeight: CGFloat = WorkboardCompanionBand.referenceUnitHeight
    var boardPosition: Int = 0
    var boardCount: Int = 0
    let onOpen: () -> Void
    var onShare: (() -> Void)?
    var onReattach: (() -> Void)?
    var onMoveEarlier: (() -> Void)?
    var onMoveLater: (() -> Void)?
    var onRemove: (() -> Void)?
    /// Quick Look the RECORDING folded into this picture — the route the
    /// recording's own card had before it was folded away. Absent leaves the
    /// row off rather than naming an action the card cannot perform.
    var onOpenCompanion: (() -> Void)?
    /// Hand the recording to the system's share UI, as its own single item.
    /// The picture's `onShare` still shares the picture.
    var onShareCompanion: (() -> Void)?
    /// Repair the RECORDING whose local bytes are gone. Folding must not take
    /// away the repair route the recording's own card had — the picture's
    /// Reattach answers for the picture and would replace the wrong file.
    var onReattachCompanion: (() -> Void)?
    /// The band's only reach into storage, injected exactly as the audio card
    /// injects its own: the recording's bytes are read on the first play rather
    /// than on every board refresh.
    var loadCompanionPayload: (UUID) async throws -> Data? = { id in
        try await ConversationStore.shared.loadWorkMaterialPayload(id: id)
    }
    /// The personal desk adds organization to the existing menu. Other source
    /// cards retain their ordinary capture/attachment actions.
    var organizationActions: WorkDeskMaterialOrganizationActions? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive
    @State private var isHovering = false
    /// ONE player for the recording this card folded — the same ownership the
    /// audio card has, so the process-wide exclusivity registry still has a
    /// single holder and a band cannot play over a card.
    @State private var companionPlayer = WorkboardAudioCardPlayer()
    /// What the band actually measured, so the tile reserves exactly that much
    /// and no layout has to guess a height that dynamic type decides.
    @State private var bandHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardSurface

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
        // A card that leaves the board takes its audio with it, and a recording
        // that stops being this card's companion — because it unfolded, or
        // because the card now holds a different one — is no longer this
        // player's to hold.
        .onDisappear { companionPlayer.deactivate() }
        .onChange(of: material.companion?.id) { _, _ in companionPlayer.deactivate() }
        .onChange(of: material.companion?.availability) { _, availability in
            if let availability,
               !WorkboardCardActionPolicy.allows(.play, when: availability) {
                companionPlayer.deactivate()
            }
        }
        // The workbench can hide this card without unmounting it, and a hidden
        // card must not keep audio or a payload read alive.
        .onChange(of: workbenchDestinationIsActive) { _, isActive in
            if !isActive { companionPlayer.deactivate() }
        }
    }

    /// The tile, plus the recording folded into it.
    ///
    /// The band is a SIBLING of the tile rather than content inside it: the
    /// tile is a button that opens the gallery, and a control nested in a
    /// button's label never receives the tap. Both live under one clip so the
    /// band ends where the card's corners do.
    @ViewBuilder
    private var cardSurface: some View {
        if let companion = material.companion,
           let placement = WorkboardCompanionBand.placement(for: material, footprint: layoutSize) {
            ZStack(alignment: .bottom) {
                tileControl
                companionBand(companion, placement: placement)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        bandHeight = height
                    }
            }
            .clipShape(cardShape)
        } else {
            tileControl
        }
    }

    /// The tile, and the decision about whether it is a control.
    ///
    /// A card whose bytes are still arriving is not a control: it is NOT
    /// wrapped in a button, so it carries no button trait and offers no
    /// activation that would do nothing. Its availability line is the answer,
    /// and the arrange actions stay reachable either way.
    @ViewBuilder
    private var tileControl: some View {
        if let primaryAction {
            Button(action: primaryAction) { tile }
                .choiceCardButton(cornerRadius: 13)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityValue(companionAccessibilityValue)
                .accessibilityActions { cardAccessibilityActions }
        } else {
            tile
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityValue(companionAccessibilityValue)
                .accessibilityActions { cardAccessibilityActions }
        }
    }

    /// The recording's state, on the card that hid its band. Empty for a card
    /// with no companion, which has no second thing to be doing — the same
    /// shape the list row uses, where an ordinary row's value is empty too.
    private var companionAccessibilityValue: Text {
        guard let companion = material.companion else { return Text(verbatim: "") }
        return Text(verbatim: WorkboardCompanionBand.accessibilityValue(
            for: companion,
            phase: companionPlayer.phase,
            elapsed: companionPlayer.elapsed,
            duration: companionPlayer.duration
        ))
    }

    /// The tile itself, without any decision about whether it is a control.
    /// The mosaic hands every card a fixed frame, so content that cannot
    /// compress is clipped rather than allowed to bleed over a neighbouring
    /// tile.
    ///
    /// A picture the board already holds fills its own tile; every other card
    /// draws the padded text layout. The two are separate chains rather than one
    /// chain with a branching background, so the glyph card's geometry is
    /// untouched by the existence of the photo card's.
    @ViewBuilder
    private var tile: some View {
        switch artworkMode {
        case .imageForward:
            imageForwardTile
        case .inline:
            inlineTile
        }
    }

    private var inlineTile: some View {
        cardBody
            .padding(layoutSize == .small ? compactMetrics.inset : 12)
            // The band is drawn over the bottom of this tile, so the content
            // gives up exactly the height the band measured rather than sliding
            // underneath it.
            .padding(.bottom, bandReservation)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    /// The compact drawing, sized for the tile this card was granted. Read by
    /// the band, by the row it stands on and by the inset around both, so the
    /// three cannot disagree about how much of one grid unit they are spending.
    private var compactMetrics: WorkboardCompanionBand.CompactMetrics {
        WorkboardCompanionBand.compactMetrics(forTileHeight: grantedUnitHeight)
    }

    /// What this card spends its tile on. `layoutSize` is deliberate: a `large`
    /// card the grid clamped to a standard slot must caption a standard tile.
    private var artworkMode: WorkboardCardArtworkMode {
        WorkboardCardArtworkMode.resolve(
            kind: material.kind,
            hasThumbnail: material.thumbnailData != nil,
            footprint: layoutSize
        )
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
    }

    /// The picture IS the card: the thumbnail fills the tile edge to edge and
    /// the name and footer ride a scrim over its bottom.
    ///
    /// `Color.clear` states the geometry rather than the image doing it: a
    /// `scaledToFill` image proposes a size of its own, and letting that reach
    /// the mosaic's slot would make one photo's aspect ratio move the card it
    /// sits in. The clip is what turns the overflow into a fill.
    private var imageForwardTile: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { imageForwardArtwork }
            .overlay(alignment: .topLeading) { imageForwardAvailability }
            .overlay(alignment: .bottom) { imageForwardCaption }
            .clipShape(cardShape)
            .background(AppColors.cardBackgroundElevated, in: cardShape)
            .overlay {
                cardShape.strokeBorder(AppColors.borderSubtle, lineWidth: 1)
            }
            .contentShape(cardShape)
    }

    @ViewBuilder
    private var imageForwardArtwork: some View {
        if let data = material.thumbnailData {
            stagedThumbnail(data: data) {
                // The gap before a decode lands is the card's own surface, not
                // a glyph: a placeholder symbol at tile size would flash big and
                // then vanish, which reads as a failure rather than as loading.
                AppColors.backgroundSecondary
            }
            .accessibilityHidden(true)
        }
    }

    /// The same glyph and the same tint as the text layout, on a dark disc: the
    /// tint alone carries the meaning and no tint survives an arbitrary photo.
    /// An available card draws nothing here, exactly as it draws nothing there.
    @ViewBuilder
    private var imageForwardAvailability: some View {
        if material.availability != .available {
            Image(systemName: availabilityGlyphName)
                .font(.caption)
                .foregroundStyle(availabilityGlyphTint)
                .padding(5)
                .background(Color.black.opacity(0.45), in: Circle())
                .padding(8)
                .accessibilityHidden(true)
        }
    }

    /// Name + footer over a bottom scrim.
    ///
    /// The gradient is the caption's own background rather than a fixed slice of
    /// the tile, so it grows WITH the text: at an accessibility type size the
    /// name still lands on the dark band instead of climbing out of it onto the
    /// photo. White is a literal, not a semantic colour — the surface underneath
    /// is a photograph, so it does not follow the appearance.
    private var imageForwardCaption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: face.heading ?? material.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .lineLimit(2)
            if let label = face.availability {
                Label(label, systemImage: availabilityGlyphName)
                    .font(.caption2)
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .accessibilityHidden(true)
            }
            if let organizationActions,
               organizationActions.showsSource || (organizationActions.showsLocation && organizationActions.project != nil) {
                WorkDeskMaterialLocation(actions: organizationActions)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 4))
            }
            // The size and the age wait for the pointer, in space this block
            // reserves either way: revealing them by ADDING a row would move
            // the name every time the cursor crossed the card.
            footerRow(tint: Color.white.opacity(0.85))
                .opacity(showsDemotedMeta ? 1 : 0)
        }
        // Padding FIRST, then the width: a `maxWidth: .infinity` frame taken
        // before the inset would make the block the tile's full width and THEN
        // add 20pt of padding outside it, pushing the caption under the clip.
        .padding(.horizontal, 10)
        // The band's height is claimed INSIDE the caption's own padding, so the
        // gradient grows over the band too and the recording's words land on
        // the scrim's darkest end rather than on the bare photograph.
        .padding(.bottom, 9 + bandReservation)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: Companion

    /// How much of the tile the folded recording is standing on. Zero for a
    /// card with no companion, so an ordinary picture's geometry is untouched.
    private var bandReservation: CGFloat {
        material.companion == nil ? 0 : bandHeight
    }

    /// The voice material, drawn inside the picture that names it: the name it
    /// carries, as much of the words as this footprint can hold, and — for a
    /// recording — the transport and its progress track. It is one row of the
    /// SAME card — no second card, no second tap target for the gallery — and
    /// it sits outside the tile's button so its own control is reachable.
    private func companionBand(
        _ companion: WorkboardCompanionSnapshot,
        placement: WorkboardCompanionBand.Placement
    ) -> some View {
        let onScrim = placement == .scrim
        // The smallest tile keeps the control and gives up the words: they do
        // not fit over the card's own content, they would be three characters
        // wide beside a transport of at most 26 points, and the card already
        // carries them in its spoken label and in its rows. The control itself
        // is sized from the tile the grid granted, which on a narrow board is
        // smaller than the one the constants are drawn at.
        let isCompact = placement == .compact
        // Only a recording is played. A words-only companion draws the words
        // alone: a transport over bytes that do not exist is a control that
        // fails on every activation, and the track under it would fill for a
        // clip nothing decoded.
        let drawsTransport = companion.kind == .audio
        return HStack(alignment: .top, spacing: 8) {
            if drawsTransport {
                WorkboardAudioTransport(
                    materialID: companion.id,
                    player: companionPlayer,
                    availability: companion.availability,
                    isEnabled: workbenchDestinationIsActive,
                    activation: .control,
                    dimension: isCompact ? compactMetrics.transport : 32,
                    placement: onScrim ? .scrim : .card,
                    loadPayload: loadCompanionPayload
                )
            }
            if !isCompact {
                let companionFace = WorkboardCompanionBand.face(for: companion)
                VStack(alignment: .leading, spacing: 3) {
                    if let lead = companionFace.leadLine {
                        Text(verbatim: lead)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(onScrim ? Color.white : AppColors.textPrimary)
                            .lineLimit(1)
                    }
                    if let limit = WorkboardCompanionBand.transcriptLineLimit(for: layoutSize),
                       let transcript = companionFace.trailingExcerpt {
                        Text(verbatim: transcript)
                            .font(.caption2)
                            .foregroundStyle(onScrim ? Color.white.opacity(0.85) : AppColors.textSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(limit)
                    }
                    if drawsTransport {
                        WorkboardAudioProgressTrack(
                            player: companionPlayer,
                            placement: onScrim ? .scrim : .card
                        )
                    }
                }
                // Only the transport is a control here. Everything else lets the
                // touch through to the tile underneath, so a tap on the words still
                // opens the gallery exactly as a tap on the picture does.
                .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? compactMetrics.bandPadding : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // On a photograph the caption's own gradient is already underneath, so
        // the band adds nothing; inside a text card it is a recessed strip that
        // says the recording is a second thing on this card. It is drawn behind
        // and takes no hits: a strip that swallowed them would turn the bottom
        // of every folded card into a dead zone.
        .background {
            (onScrim ? Color.clear : AppColors.backgroundSecondary)
                .allowsHitTesting(false)
        }
        // The words belong to the card's own label, and the transport carries
        // "Play Recording" as one of that card's custom actions.
        .accessibilityHidden(true)
    }

    /// The recording's OWN availability decides whether it plays — the picture
    /// being readable here says nothing about where the audio's bytes are. A
    /// words-only companion never plays: it holds no bytes to reach for.
    private var companionIsPlayable: Bool {
        guard let companion = material.companion, companion.kind == .audio else { return false }
        return WorkboardCardActionPolicy.allows(.play, when: companion.availability)
    }

    /// The rows this card offers about the recording, asked once and consumed
    /// by the menu and the VoiceOver actions alike.
    private var companionActions: [WorkboardCompanionAction] {
        guard let companion = material.companion else { return [] }
        return WorkboardCompanionBand.actions(
            for: companion,
            phase: companionPlayer.phase,
            hasOpenRecording: onOpenCompanion != nil,
            hasShareRecording: onShareCompanion != nil,
            hasReattachRecording: onReattachCompanion != nil
        )
    }

    private func performCompanionAction(_ action: WorkboardCompanionAction) {
        switch action {
        case .play, .pause, .cancelLoading:
            guard workbenchDestinationIsActive, companionIsPlayable,
                  let companion = material.companion else { return }
            let id = companion.id
            let load = loadCompanionPayload
            companionPlayer.toggle { try await load(id) }
        case .openRecording:
            onOpenCompanion?()
        case .shareRecording:
            onShareCompanion?()
        case .reattachRecording:
            onReattachCompanion?()
        }
    }

    /// What this card's bytes allow. Asked once and consumed by the tile, the
    /// menu and the VoiceOver actions alike, so no surface can offer an action
    /// another one refuses.
    private var permittedActions: Set<WorkboardCardAction> {
        WorkboardCardActionPolicy.actions(for: material.availability)
    }

    private var openAction: (() -> Void)? {
        guard permittedActions.contains(.open) else { return nil }
        return { openMaterial() }
    }

    /// Opening the picture HANDS OVER the recording folded into it.
    ///
    /// The gallery presents its own transport for the same clip, so a board
    /// player left running would put a Play control over audio that is already
    /// sounding — and the sheet's own page-change teardown would then silence
    /// only its copy, leaving the previous picture's recording audible behind
    /// the next one. `deactivate` rather than a stop: a payload read still in
    /// flight has to die here too, or it claims output after the handover.
    private func openMaterial() {
        companionPlayer.deactivate()
        onOpen()
    }

    /// Share rides the SAME permission as Open — both read the card's bytes —
    /// so a card that cannot be opened here cannot be shared from here either.
    private var shareAction: (() -> Void)? {
        permittedActions.contains(.open) ? onShare : nil
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

    /// The footprint the card draws into, which is the SAME for every card on
    /// the desk. The board grants one slot size, so a row still carrying a
    /// stored `small` or `large` renders exactly like everything else rather
    /// than reinstating a second density beside it. The stored column is left
    /// readable on purpose — the footprint decision is reversible on evidence,
    /// and the placement rules below still answer for all three.
    private var layoutSize: WorkMaterialCardSize { .standard }

    /// ONE drawing, at one footprint. The board grants every card the same
    /// slot, so a card has no density to pick between; what changes between
    /// kinds is which face slots are filled, and that is decided once in
    /// `WorkboardCardFacePolicy` rather than three times here.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                artwork(dimension: 40, cornerRadius: 10)
                // The menu affordance owns this corner: keep content clear.
                Spacer(minLength: 26)
            }
            faceText
            Spacer(minLength: 0)
            availabilityLine
            if let organizationActions {
                WorkDeskMaterialLocation(actions: organizationActions)
            }
            cardFooter
        }
    }

    /// The face's slots, in the order they read.
    ///
    /// A card whose heading the body already says leads with the BODY, in the
    /// heading's own type size: a note then reads as one continuous excerpt
    /// instead of as a title that happens to be missing, and the sentence the
    /// person actually wrote is never the thing that gets dropped.
    @ViewBuilder
    private var faceText: some View {
        if let heading = face.heading {
            Text(verbatim: heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .truncationMode(face.headingProtectsExtension ? .middle : .tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let identity = face.identity {
                Text(verbatim: identity)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let excerpt = face.excerpt {
                Text(verbatim: excerpt)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let excerpt = face.excerpt {
            Text(verbatim: excerpt)
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Bytes that are not here, in WORDS and not only in a 12-point glyph. A
    /// syncing card refuses the tap, so the glyph was the entire explanation a
    /// sighted person got for a click that did nothing.
    @ViewBuilder
    private var availabilityLine: some View {
        if let label = face.availability {
            Label(label, systemImage: availabilityGlyphName)
                .font(.caption2)
                .foregroundStyle(availabilityGlyphTint)
                .lineLimit(2)
                .accessibilityHidden(true)
        }
    }

    private var cardFooter: some View {
        footerRow(tint: AppColors.textTertiary)
    }

    /// The demoted row: whatever the face put in `meta`, and the capture time.
    /// The tint is a parameter and not a constant because the identical row is
    /// also drawn over a photograph, where the tertiary text colour is
    /// unreadable.
    @ViewBuilder
    private func footerRow(tint: Color) -> some View {
        if face.meta != nil || face.showsAge {
            HStack(spacing: 6) {
                if let meta = face.meta {
                    Text(verbatim: meta)
                }
                Spacer(minLength: 5)
                if face.showsAge {
                    Text(material.createdAt, format: .relative(presentation: .named))
                }
            }
            .font(.caption2)
            .foregroundStyle(tint)
            .lineLimit(1)
        }
    }

    /// One card, one face. The tile, the caption over a photograph and the
    /// spoken label all read this, so no two of them can describe the same
    /// card differently.
    private var face: WorkboardCardFace {
        WorkboardCardFacePolicy.face(for: material)
    }

    /// A picture's size and age are the least of what it says. On a pointer
    /// platform they arrive with the pointer; on a touch platform there is no
    /// hover state to reveal them with, so they simply stay.
    private var showsDemotedMeta: Bool {
        guard face.metaWaitsForPointer else { return true }
        #if os(macOS)
        return isHovering
        #else
        return true
        #endif
    }

    private var availabilityGlyphName: String {
        WorkboardCardFacePolicy.availabilityGlyphName(for: material.availability)
    }

    private var availabilityGlyphTint: Color {
        WorkboardCardFacePolicy.availabilityTint(for: material.availability)
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

    /// Open, Share and Reattach are the rows the bytes decide: a card offers
    /// exactly the actions its availability permits, and a card that permits
    /// none of them still carries its arrange rows.
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
        if let shareAction {
            Button(action: shareAction) {
                Label(
                    WorkboardCompanionBand.shareTitle(hasCompanion: material.companion != nil),
                    systemImage: "square.and.arrow.up"
                )
            }
        }
        // Each row acts on ONE of the card's two files, through the same
        // single-material coordinators a standalone recording used: there is no
        // multi-item share, so nothing has to decide what a half-available pair
        // would mean.
        ForEach(companionActions, id: \.self) { action in
            Button {
                performCompanionAction(action)
            } label: {
                Label(
                    WorkboardCompanionBand.title(for: action),
                    systemImage: WorkboardCompanionBand.symbol(for: action)
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
        if let organizationActions {
            Divider()
            WorkDeskMaterialMenuActions(actions: organizationActions)
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

    /// The ellipsis menu is hidden from VoiceOver — every action it carries has
    /// to be reachable here or it is not reachable at all. Open is absent on
    /// purpose: the tile ITSELF is the open control and already activates.
    ///
    /// The band's transport is hidden for the same reason the menu is: it is a
    /// control drawn beside an element whose children are ignored, so playback
    /// reaches VoiceOver as a named action here or not at all.
    @ViewBuilder
    private var cardAccessibilityActions: some View {
        if let organizationActions {
            WorkDeskMaterialAccessibilityActions(actions: organizationActions)
        }
        if let shareAction {
            Button(
                WorkboardCompanionBand.shareTitle(hasCompanion: material.companion != nil),
                action: shareAction
            )
        }
        ForEach(companionActions, id: \.self) { action in
            Button(WorkboardCompanionBand.title(for: action)) {
                performCompanionAction(action)
            }
        }
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

    /// The one place this card builds a decode of its own thumbnail, so the
    /// small artwork and the full-bleed tile share a cache entry: the key is
    /// `(id, byte count, maxPixel, revision)`, and a second construction site
    /// would drift one of those and pay for the same picture twice.
    private func stagedThumbnail<Placeholder: View>(
        data: Data,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) -> StagedImageTile<Placeholder> {
        StagedImageTile(
            id: material.id,
            data: data,
            maxPixel: ImageProcessor.thumbnailMaxPixel,
            cacheVersion: material.revision,
            placeholder: placeholder
        )
    }

    /// Preview bytes the board ALREADY HOLDS, whatever kind wrote them — a PDF
    /// that arrived with a thumbnail shows it. Nothing is rendered on demand:
    /// this decodes stored bytes, so a card can never turn into a document
    /// rasteriser while the person scrolls past it.
    @ViewBuilder
    private func artwork(dimension: CGFloat, cornerRadius: CGFloat) -> some View {
        if let data = material.thumbnailData {
            stagedThumbnail(data: data) {
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

    private var accessibilitySummary: Text {
        let summary = Text(WorkboardCardAccessibility.summary(
            material: material,
            boardPosition: boardPosition,
            boardCount: boardCount
        ))
        if let actions = organizationActions, actions.showsLocation, let project = actions.project {
            return summary + Text(verbatim: ", " + project.title)
        }
        return summary
    }

    static func boardPositionLabel(position: Int, count: Int) -> String {
        WorkboardCardAccessibility.boardPositionLabel(position: position, count: count)
    }
}

/// What a board card SAYS, apart from what it draws.
///
/// Pure and file-scope-internal because the spoken card has to survive every
/// layout the card has: an image-forward tile hands VoiceOver no picture at all,
/// so the words are the whole card there, and a label built inside a view body
/// cannot be asserted. The card is the only caller.
enum WorkboardCardAccessibility {
    /// What the card IS, the face it draws, the availability it is in, and its
    /// place on the board — in that order, and independent of how the tile is
    /// drawn.
    ///
    /// The face is asked ONCE and spoken in its own order, which is what stops
    /// the label saying the same thing twice: it used to append the name and
    /// then the whole preview body, so a note whose title is its own first line
    /// was read out and then read out again. The footprint is gone from the
    /// sentence for the same reason — one board-wide footprint said on every
    /// card is a word that distinguishes nothing.
    ///
    /// A folded card says what it IS before it says its name: "Image" would
    /// describe half of what the person is touching, and the recording's words
    /// are the only thing on that card VoiceOver can carry — the transport is
    /// hidden, the picture is a picture, and the words are why the pair exists.
    static func summary(
        material: WorkboardMaterialSnapshot,
        boardPosition: Int,
        boardCount: Int
    ) -> String {
        let face = WorkboardCardFacePolicy.face(for: material)
        var parts = [String(localized: material.companion.map(
            WorkboardCompanionBand.accessibilityKindLabel(for:)
        ) ?? material.kind.title)]
        parts.append(contentsOf: face.spokenParts)
        // The recording's own slots, said once: the SAME deduplicated pair the
        // band draws, so what is heard and what is seen cannot disagree.
        if let companion = material.companion {
            parts.append(contentsOf: WorkboardCompanionBand.face(for: companion).spokenParts)
        }
        if let availability = face.availability {
            parts.append(String(localized: availability))
        }
        // Arranging is what the board is for, so the position is part of the
        // card's identity: it is the only thing that changes when Move
        // Earlier/Later succeeds.
        if boardCount > 0, boardPosition > 0 {
            parts.append(boardPositionLabel(position: boardPosition, count: boardCount))
        }
        return parts.joined(separator: ". ")
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

    /// The words for an availability, from the face policy — the desk turns an
    /// availability into a sentence in exactly one place. `.available` has no
    /// sentence and every caller guards on it first; the repair phrase is the
    /// fail-closed answer if one ever stops doing so.
    static func availabilityLabel(
        for availability: WorkboardMaterialAvailability
    ) -> LocalizedStringResource {
        WorkboardCardFacePolicy.availabilityLabel(for: availability)
            ?? LocalizedStringResource(
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

enum WorkboardResolvedImportItem: Sendable {
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

struct WorkboardResolvedImportBatch: Sendable {
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
    let destination: WorkboardCaptureDestination

    var largeItemByteCounts: [Int64] { batch.largeItemByteCounts }
}

/// One mapping from a resolved batch to Work material, shared by the picker and
/// the pane-wide drop. Security scopes it opens are RETURNED rather than closed
/// here: a scoped URL must stay open until the caller's import has finished
/// reading the bytes.
///
/// THE PICKER AND THE DROP ARE THE ONLY TWO DOORS through which an audio file
/// becomes a playable card. Both are deliberate gestures made inside the Work
/// pane on a file the person chose, which is the whole of the permission: every
/// other door — the share sheet, the Add Files Shortcut, the share-inbox
/// drainer, Chat to Work — refuses a recording and says where to add one.
///
/// NOTHING HERE TRANSCRIBES. A file that arrives this way is bytes to play and
/// never words to read, which is what separates it from the voice lanes: those
/// publish the words alone and keep no recording at all.
///
/// Internal rather than file-private for the reason `WorkboardCompanionBand` is:
/// the mapping the two doors actually run is what the tests drive, instead of a
/// copy of it that can silently disagree.
enum WorkboardImportMapping {
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

    /// The card shape a picked or dropped file draws as. Pictures first — a
    /// screenshot is the desk's commonest capture and has its own shape — then
    /// a recording, then everything else as a file.
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
        // The SHARED sniffer, never a second audio rule of this door's own: the
        // doors that refuse a recording and the two that keep one have to agree
        // about what a recording IS, or a file the share sheet turned away
        // would arrive here as a plain document instead of a playable card. It
        // answers from the mime type when that is specific and from the
        // extension when it is not, so `application/octet-stream` beside
        // `memo.m4a` still resolves.
        if WorkCaptureEnvelope.isAudioPayload(
            mimeType: mimeType,
            typeIdentifier: nil,
            filename: filename
        ) {
            return .audio
        }
        return .file
    }

    static func reclaim(_ batch: WorkboardResolvedImportBatch) {
        for url in batch.appOwnedURLs { try? FileManager.default.removeItem(at: url) }
    }
}

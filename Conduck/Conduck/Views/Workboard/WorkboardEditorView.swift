// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardEditorView.swift
//
// Document-like brief editor. Every keystroke remains an inert private draft;
// the persistent bottom action opens an exact dispatch preflight rather than
// sending. PhotosPicker and fileImporter are the system-owned privacy surfaces,
// while links and notes become gateway-neutral Workboard materials.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct WorkboardEditorView: View {
    @Bindable var viewModel: WorkboardViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var materialComposer: WorkboardMaterialComposerKind?
    @State private var materialPendingRemoval: WorkboardMaterialSnapshot?
    @State private var materialPendingReattachment: WorkboardMaterialSnapshot?
    @State private var isImportingMaterials = false
    @State private var largeFileConfirmation: WorkboardLargeFileConfirmation?
    @State private var photoImportTask: Task<Void, Never>?
    @State private var filePreparationTask: Task<Void, Never>?
    @State private var fileImportTask: Task<Void, Never>?
    @State private var materialMutationTask: Task<Void, Never>?
    @State private var showsCloseFailure = false
    @FocusState private var focusedField: WorkboardEditorField?
    #if os(iOS)
    @State private var showsCamera = false
    @State private var showsCameraDeniedAlert = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WorkboardMetrics.generousSpacing) {
                    versionBanner
                    titleBlock
                    objectiveBlock
                    contextBlock
                    desiredResultBlock
                    constraintsBlock
                    reviewByBlock
                    materialsBlock
                    privacyFooter
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
                .frame(maxWidth: WorkboardMetrics.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(LocalizedStringResource(
                "workboard.editor.title",
                defaultValue: "Prepare Brief"
            ))
            .workboardInlineNavigationTitle()
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .interactiveDismissDisabled(
                viewModel.editorIsSaving || viewModel.editorHasUnsavedChanges || isImportingMaterials
            )
        }
        .onChange(of: viewModel.editingDraft) { _, _ in
            viewModel.noteEditorChanged()
        }
        // Keyed on the request itself so it lands both when the brief opens
        // already carrying one and when Review & Send raises one in place.
        .task(id: viewModel.editorFocusRequest) {
            guard let target = viewModel.consumeEditorFocusRequest() else { return }
            focusedField = target.editorField
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(verbatim: notice.message),
                dismissButton: .default(Text(LocalizedStringResource(
                    "common.ok",
                    defaultValue: "OK"
                )))
            )
        }
        .alert(
            LocalizedStringResource(
                "workboard.close.failed.title",
                defaultValue: "Draft not saved"
            ),
            isPresented: $showsCloseFailure
        ) {
            Button(LocalizedStringResource(
                "workboard.close.failed.retry",
                defaultValue: "Try Saving Again"
            )) {
                attemptClose()
            }
            Button(
                LocalizedStringResource(
                    "workboard.close.failed.discard",
                    defaultValue: "Discard Unsaved Changes"
                ),
                role: .destructive
            ) {
                viewModel.discardUnsavedEditorChanges()
            }
            Button(
                LocalizedStringResource("common.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {}
        } message: {
            Text(LocalizedStringResource(
                "workboard.close.failed.message",
                defaultValue: "Conduck could not save the latest edits. Try again, keep editing, or discard only the changes that are not yet saved."
            ))
        }
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $photoSelection,
            maxSelectionCount: 12,
            matching: .images
        )
        .onChange(of: photoSelection) { _, newItems in
            guard !newItems.isEmpty else { return }
            startPhotoImports(newItems)
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .sheet(item: $materialComposer) { kind in
            WorkboardTextMaterialSheet(kind: kind) { materialImport in
                startMaterialImport(materialImport)
            }
        }
        .sheet(item: $viewModel.voiceCaptureTarget) { target in
            WorkboardVoiceCaptureView(
                target: target,
                onTranscript: { transcript in
                    viewModel.applyVoiceTranscript(transcript, to: target)
                },
                onCancel: {
                    viewModel.voiceCaptureTarget = nil
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.editorSuggestion != nil },
                set: { if !$0 { viewModel.editorSuggestion = nil } }
            )
        ) {
            if let suggestion = viewModel.editorSuggestion {
                WorkboardDraftSuggestionView(viewModel: viewModel, suggestion: suggestion)
            }
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
                startMaterialRemoval(material)
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
                    defaultValue: "“%@” will be removed from this private draft."
                )),
                material.name
            ))
        }
        .alert(item: $viewModel.editorConflict) { conflict in
            Alert(
                title: Text(LocalizedStringResource(
                    "workboard.conflict.title",
                    defaultValue: "This brief changed elsewhere"
                )),
                message: Text(verbatim: conflict.message),
                primaryButton: .default(Text(LocalizedStringResource(
                    "workboard.conflict.saveCopy",
                    defaultValue: "Save as New Brief"
                ))) {
                    Task { await viewModel.resolveEditorConflictBySavingCopy() }
                },
                secondaryButton: .destructive(Text(LocalizedStringResource(
                    "workboard.conflict.loadLatest",
                    defaultValue: "Load Latest"
                ))) {
                    Task { await viewModel.resolveEditorConflictByReloading() }
                }
            )
        }
        .workboardLargeImportAlert(
            item: $largeFileConfirmation,
            onConfirm: { confirmation in
                startFileImports(
                    confirmation.files,
                    replacing: confirmation.replacingMaterial,
                    in: confirmation.itemID
                )
            },
            onCancel: { _ in }
        )
        #if os(iOS)
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker(
                onCapture: importCameraPhoto,
                onDismiss: { showsCamera = false }
            )
        }
        .alert(
            LocalizedStringResource("composer.camera.deniedTitle", defaultValue: "Camera access is off"),
            isPresented: $showsCameraDeniedAlert
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: viewModel.editingDraft.materials)
        .onDisappear {
            cancelEditorTransients()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(LocalizedStringResource("common.close", defaultValue: "Close")) {
                attemptClose()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.editorIsSaving || isImportingMaterials)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.canShapeDraft {
                Button {
                    Task { await viewModel.shapeEditorDraft() }
                } label: {
                    if viewModel.isShapingDraft {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text(LocalizedStringResource(
                                "workboard.shape.inProgress",
                                defaultValue: "Shaping brief"
                            )))
                    } else {
                        Label(
                            LocalizedStringResource("workboard.shape.action", defaultValue: "Shape Brief"),
                            systemImage: "sparkles"
                        )
                    }
                }
                .disabled(viewModel.isShapingDraft || !viewModel.editingDraft.isMeaningful)
                .help(String(localized: LocalizedStringResource(
                    "workboard.shape.help",
                    defaultValue: "Suggest a clearer brief on this device. You review every change."
                )))
            }

            Button {
                viewModel.editingDraft.isPinned.toggle()
            } label: {
                Label(
                    viewModel.editingDraft.isPinned
                        ? LocalizedStringResource("workboard.unpin", defaultValue: "Unpin")
                        : LocalizedStringResource("workboard.pin", defaultValue: "Pin"),
                    systemImage: viewModel.editingDraft.isPinned ? "pin.slash" : "pin"
                )
            }
        }
    }

    private func attemptClose() {
        Task {
            if !(await viewModel.closeEditor()) {
                showsCloseFailure = true
            }
        }
    }

    @ViewBuilder
    private var versionBanner: some View {
        if let item = viewModel.item(withID: viewModel.editingDraft.id), !item.runs.isEmpty {
            WorkboardSurface {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.badge.clock")
                        .font(.title3)
                        .foregroundStyle(AppColors.warning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringResource(
                            "workboard.editor.sentVersion.title",
                            defaultValue: "Sent versions stay frozen"
                        ))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        Text(LocalizedStringResource(
                            "workboard.editor.sentVersion.message",
                            defaultValue: "These edits prepare the next run. They never rewrite what a gateway already received."
                        ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                String(localized: LocalizedStringResource(
                    "workboard.editor.title.prompt",
                    defaultValue: "Name this piece of work"
                )),
                text: $viewModel.editingDraft.title,
                axis: .vertical
            )
            .font(.title2.weight(.semibold))
            .foregroundStyle(AppColors.textEmphasis)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .focused($focusedField, equals: .title)

            Text(LocalizedStringResource(
                "workboard.editor.title.caption",
                defaultValue: "A short title makes the board easy to scan."
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
        }
        .padding(.horizontal, 4)
    }

    private var objectiveBlock: some View {
        WorkboardLabeledEditor(
            title: LocalizedStringResource(
                "workboard.editor.objective.title",
                defaultValue: "What needs doing?"
            ),
            prompt: LocalizedStringResource(
                "workboard.editor.objective.prompt",
                defaultValue: "Describe the decision, investigation, draft or action you want the AI to handle."
            ),
            text: $viewModel.editingDraft.objective,
            minHeight: 150,
            isRequired: true,
            focusedField: $focusedField,
            field: .objective
        ) {
            voiceButton(target: .objective)
        }
    }

    private var contextBlock: some View {
        WorkboardLabeledEditor(
            title: LocalizedStringResource(
                "workboard.editor.context.title",
                defaultValue: "Context and thoughts"
            ),
            prompt: LocalizedStringResource(
                "workboard.editor.context.prompt",
                defaultValue: "Add the background, rough thinking, people involved or what you have already tried."
            ),
            text: $viewModel.editingDraft.context,
            minHeight: 150,
            focusedField: $focusedField,
            field: .context
        ) {
            voiceButton(target: .context)
        }
    }

    private var desiredResultBlock: some View {
        WorkboardLabeledEditor(
            title: LocalizedStringResource(
                "workboard.editor.desiredResult.title",
                defaultValue: "A good result includes"
            ),
            prompt: LocalizedStringResource(
                "workboard.editor.desiredResult.prompt",
                defaultValue: "For example: a recommendation with trade-offs, a finished email, or three options ranked by risk."
            ),
            text: $viewModel.editingDraft.desiredResult,
            minHeight: 110,
            focusedField: $focusedField,
            field: .desiredResult
        )
    }

    private var constraintsBlock: some View {
        WorkboardLabeledEditor(
            title: LocalizedStringResource(
                "workboard.editor.constraints.title",
                defaultValue: "Constraints and guardrails"
            ),
            prompt: LocalizedStringResource(
                "workboard.editor.constraints.prompt",
                defaultValue: "Add boundaries the AI must respect: scope, tone, sources, budget, privacy or actions it must not take."
            ),
            text: $viewModel.editingDraft.constraints,
            minHeight: 100,
            focusedField: $focusedField,
            field: .constraints
        )
    }

    private var reviewByBlock: some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: reviewByEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reviewByLabel)
                                .font(.headline)
                            Text(LocalizedStringResource(
                                "workboard.editor.reviewBy.caption",
                                defaultValue: "A private board date. It is also preserved in the approved brief snapshot."
                            ))
                            .font(.caption)
                            .foregroundStyle(AppColors.textTertiary)
                        }
                    } icon: {
                        Image(systemName: "calendar")
                            .foregroundStyle(AppColors.brandAmber)
                    }
                }
                .toggleStyle(.switch)
                .tint(AppColors.brandAmber)

                if viewModel.editingDraft.reviewBy != nil {
                    Divider().overlay(AppColors.borderSubtle)
                    // The label repeats the block heading on screen, so it is
                    // hidden visually while VoiceOver still announces the field.
                    DatePicker(
                        reviewByLabel,
                        selection: reviewDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }
            }
        }
    }

    private var reviewByLabel: LocalizedStringResource {
        LocalizedStringResource(
            "workboard.editor.reviewBy.date",
            defaultValue: "Review by"
        )
    }

    private var materialsBlock: some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringResource(
                            "workboard.editor.materials.title",
                            defaultValue: "Materials"
                        ))
                        .font(.headline)
                        .foregroundStyle(AppColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        Text(LocalizedStringResource(
                            "workboard.editor.materials.caption",
                            defaultValue: "Gateway-neutral until you choose a destination at send time."
                        ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                    }
                    Spacer(minLength: 12)
                    if isImportingMaterials {
                        HStack(spacing: 8) {
                            if let progress = viewModel.materialImportProgress {
                                ProgressView(value: progress)
                                    .frame(width: 72)
                                    .accessibilityLabel(Text(LocalizedStringResource(
                                        "workboard.material.importing",
                                        defaultValue: "Adding materials"
                                    )))
                                    .accessibilityValue(Text(progress, format: .percent))
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel(Text(LocalizedStringResource(
                                        "workboard.material.importing",
                                        defaultValue: "Adding materials"
                                    )))
                            }
                            if fileImportTask != nil {
                                Button(LocalizedStringResource(
                                    "common.cancel",
                                    defaultValue: "Cancel"
                                )) {
                                    fileImportTask?.cancel()
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }

                materialActions

                if viewModel.editingDraft.materials.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "paperclip")
                            .foregroundStyle(AppColors.brandAmber)
                        Text(LocalizedStringResource(
                            "workboard.editor.materials.empty",
                            defaultValue: "Add screenshots, reference files, links or a standalone note."
                        ))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    }
                    .padding(.vertical, 12)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(viewModel.editingDraft.materials) { material in
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .topTrailing) {
                                        WorkboardMaterialTile(
                                            material: material,
                                            onOpen: { viewModel.openMaterial(material) }
                                        )

                                        Button {
                                            materialPendingRemoval = material
                                        } label: {
                                            Image(systemName: "minus")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(AppColors.error)
                                                .frame(width: 30, height: 30)
                                                .background(AppColors.cardBackgroundElevated, in: Circle())
                                                .overlay {
                                                    Circle().stroke(AppColors.error.opacity(0.35), lineWidth: 1)
                                                }
                                        }
                                        .pointerIconButton(
                                            size: WorkboardMetrics.touchTarget,
                                            shape: .circle
                                        )
                                        .accessibilityLabel(Text(LocalizedStringResource(
                                            "workboard.material.remove.action",
                                            defaultValue: "Remove Material"
                                        )))
                                        .help(String(localized: LocalizedStringResource(
                                            "workboard.material.remove.action",
                                            defaultValue: "Remove Material"
                                        )))
                                    }

                                    if material.availability == .unavailableOnThisDevice {
                                        Button {
                                            materialPendingReattachment = material
                                            showsFileImporter = true
                                        } label: {
                                            Label(
                                                LocalizedStringResource(
                                                    "workboard.material.reattach.short",
                                                    defaultValue: "Reattach"
                                                ),
                                                systemImage: "paperclip.badge.ellipsis"
                                            )
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 9)
                                            .frame(minHeight: 32)
                                            .background(AppColors.brandAmber, in: Capsule())
                                            .foregroundStyle(AppColors.background)
                                        }
                                        .primaryCTAButton()
                                        .accessibilityHint(Text(LocalizedStringResource(
                                            "workboard.material.reattach.hint",
                                            defaultValue: "Choose the same material on this device so it can be sent"
                                        )))
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        materialPendingReattachment = material
                                        showsFileImporter = true
                                    } label: {
                                        Label(
                                            LocalizedStringResource(
                                                "workboard.material.reattach.action",
                                                defaultValue: "Reattach or Replace"
                                            ),
                                            systemImage: "arrow.triangle.2.circlepath"
                                        )
                                    }
                                    Button(role: .destructive) {
                                        materialPendingRemoval = material
                                    } label: {
                                        Label(
                                            LocalizedStringResource(
                                                "workboard.material.remove.action",
                                                defaultValue: "Remove Material"
                                            ),
                                            systemImage: "trash"
                                        )
                                    }
                                }
                                .accessibilityAction(named: Text(LocalizedStringResource(
                                    "workboard.material.remove.action",
                                    defaultValue: "Remove Material"
                                ))) {
                                    materialPendingRemoval = material
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private var materialActions: some View {
        WorkboardMaterialActions(
            presentation: .row,
            onPickPhotos: { showsPhotoPicker = true },
            onTakePhoto: takePhoto,
            onPickFiles: {
                materialPendingReattachment = nil
                showsFileImporter = true
            },
            onAddLink: { materialComposer = .link },
            onAddNote: { materialComposer = .note }
        )
    }

    private func takePhoto() {
        #if os(iOS)
        switch CameraPermission.current {
        case .proceed: showsCamera = true
        case .denied: showsCameraDeniedAlert = true
        }
        #endif
    }

    #if os(iOS)
    private func importCameraPhoto(_ data: Data) {
        showsCamera = false
        guard !data.isEmpty else { return }
        let name = String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.material.photo.defaultName",
                defaultValue: "Photo %lld"
            )),
            Int64(viewModel.editingDraft.materials.count + 1)
        )
        startMaterialImport(WorkboardMaterialImport(
            kind: .image,
            name: name,
            mimeType: ImageFormatSniffer.sniff(data).mime,
            data: data
        ))
    }
    #endif

    @ViewBuilder
    private var privacyFooter: some View {
        Label {
            Text(LocalizedStringResource(
                "workboard.editor.privacy",
                defaultValue: "Autosaved to Conduck’s private store and your private iCloud. Drafts never execute."
            ))
        } icon: {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(AppColors.brandTeal)
        }
        .font(.caption)
        .foregroundStyle(AppColors.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    autosaveStatus
                    Spacer(minLength: 10)
                    disabledSendReason
                }
                VStack(alignment: .leading, spacing: 5) {
                    autosaveStatus
                    disabledSendReason
                }
            }

            Button {
                focusedField = nil
                Task { await viewModel.reviewEditorAndSend() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.shield")
                    Text(LocalizedStringResource(
                        "workboard.editor.reviewAndSend",
                        defaultValue: "Review & Send…"
                    ))
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.subheadline.weight(.semibold))
                }
                .font(.headline)
                .foregroundStyle(AppColors.background)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppColors.brandAmber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .primaryCTAButton()
            .disabled(
                !viewModel.editingDraft.isReadyToSend
                    || viewModel.editorIsSaving
                    || isImportingMaterials
            )
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityHint(Text(LocalizedStringResource(
                "workboard.editor.reviewAndSend.hint",
                defaultValue: "Opens a final preview. Nothing is sent yet."
            )))
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(AppColors.borderSubtle) }
    }

    private var autosaveStatus: some View {
        WorkboardAutosaveStatus(
            isSaving: viewModel.editorIsSaving,
            hasUnsavedChanges: viewModel.editorHasUnsavedChanges,
            savedAt: viewModel.editorSavedAt
        )
    }

    @ViewBuilder
    private var disabledSendReason: some View {
        if !viewModel.editingDraft.isReadyToSend {
            Text(LocalizedStringResource(
                "workboard.editor.send.disabledReason",
                defaultValue: "Add what needs doing to continue"
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
        }
    }

    private func voiceButton(target: WorkboardVoiceTarget) -> some View {
        CaptureCircleButton(
            symbol: "mic.fill",
            fillColor: AppColors.brandAmber,
            diameter: voiceButtonDiameter,
            glyphSize: voiceButtonGlyphSize,
            isDisabled: viewModel.voiceCaptureTarget != nil,
            accessibilityLabel: String(localized: LocalizedStringResource(
                "workboard.voice.capture",
                defaultValue: "Add by voice"
            )),
            action: { viewModel.presentVoiceCapture(for: target) }
        )
    }

    private var voiceButtonDiameter: CGFloat {
        #if os(macOS)
        32
        #else
        WorkboardMetrics.touchTarget
        #endif
    }

    private var voiceButtonGlyphSize: CGFloat {
        #if os(macOS)
        14
        #else
        18
        #endif
    }

    private var reviewByEnabled: Binding<Bool> {
        Binding(
            get: { viewModel.editingDraft.reviewBy != nil },
            set: { enabled in
                guard enabled else {
                    viewModel.editingDraft.reviewBy = nil
                    return
                }
                guard viewModel.editingDraft.reviewBy == nil else { return }
                viewModel.editingDraft.reviewBy = Calendar.current
                    .date(byAdding: .day, value: 1, to: Date()) ?? Date()
            }
        )
    }

    private var reviewDate: Binding<Date> {
        Binding(
            get: { viewModel.editingDraft.reviewBy ?? Date() },
            set: { viewModel.editingDraft.reviewBy = $0 }
        )
    }

    private func startPhotoImports(_ items: [PhotosPickerItem]) {
        photoImportTask?.cancel()
        let itemID = viewModel.editingDraft.id
        photoImportTask = Task { @MainActor in
            await importPhotos(items, into: itemID)
            photoImportTask = nil
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem], into itemID: UUID) async {
        isImportingMaterials = true
        defer {
            photoSelection = []
            isImportingMaterials = false
        }
        for (offset, item) in items.enumerated() {
            guard !Task.isCancelled, viewModel.editingDraft.id == itemID else { return }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                guard !Task.isCancelled, viewModel.editingDraft.id == itemID else { return }
                let name = String.localizedStringWithFormat(
                    String(localized: LocalizedStringResource(
                        "workboard.material.photo.defaultName",
                        defaultValue: "Photo %lld"
                    )),
                    Int64(viewModel.editingDraft.materials.count + offset + 1)
                )
                await viewModel.importMaterial(WorkboardMaterialImport(
                    kind: .image,
                    name: name,
                    mimeType: item.supportedContentTypes.first?.preferredMIMEType,
                    data: data
                ), into: itemID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, viewModel.editingDraft.id == itemID else { return }
                viewModel.notice = WorkboardNotice(
                    kind: .error,
                    title: LocalizedStringResource(
                        "workboard.material.photo.failed.title",
                        defaultValue: "Couldn’t add a photo"
                    ),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        filePreparationTask?.cancel()
        let itemID = viewModel.editingDraft.id
        filePreparationTask = Task { @MainActor in
            isImportingMaterials = true
            var handedOffToImportTask = false
            defer {
                if !handedOffToImportTask { isImportingMaterials = false }
                filePreparationTask = nil
            }
            do {
                let urls = try result.get()
                guard !Task.isCancelled, viewModel.editingDraft.id == itemID else { return }
                let replacement = materialPendingReattachment
                materialPendingReattachment = nil
                var files: [WorkboardPickedFile] = []
                let selectedURLs = replacement == nil ? urls : Array(urls.prefix(1))
                files.reserveCapacity(selectedURLs.count)
                for url in selectedURLs {
                    guard !Task.isCancelled else { return }
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                    files.append(WorkboardPickedFile(
                        url: url,
                        byteCount: Int64(values.fileSize ?? 0),
                        mimeType: values.contentType?.preferredMIMEType
                    ))
                }
                let oversized = files.filter { $0.byteCount > Int64(Constants.fileTransferSoftConfirmBytes) }
                if oversized.isEmpty {
                    handedOffToImportTask = true
                    startFileImports(files, replacing: replacement, in: itemID)
                } else {
                    largeFileConfirmation = WorkboardLargeFileConfirmation(
                        files: files,
                        replacingMaterial: replacement,
                        itemID: itemID
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                materialPendingReattachment = nil
                if (error as NSError).code == NSUserCancelledError { return }
                guard !Task.isCancelled, viewModel.editingDraft.id == itemID else { return }
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

    private func startFileImports(
        _ files: [WorkboardPickedFile],
        replacing material: WorkboardMaterialSnapshot? = nil,
        in itemID: UUID
    ) {
        fileImportTask?.cancel()
        guard viewModel.editingDraft.id == itemID else { return }
        fileImportTask = Task { @MainActor in
            isImportingMaterials = true
            defer {
                isImportingMaterials = false
                fileImportTask = nil
            }
            for file in material == nil ? files : Array(files.prefix(1)) {
                guard !Task.isCancelled, viewModel.editingDraft.id == itemID else { return }
                let hasAccess = file.url.startAccessingSecurityScopedResource()
                defer { if hasAccess { file.url.stopAccessingSecurityScopedResource() } }
                let replacement = WorkboardMaterialImport(
                    kind: material?.kind ?? .file,
                    name: file.url.lastPathComponent,
                    detail: ByteCountFormatter.string(
                        fromByteCount: file.byteCount,
                        countStyle: .file
                    ),
                    mimeType: file.mimeType,
                    fileURL: file.url,
                    byteCount: file.byteCount
                )
                if let material {
                    await viewModel.reattachMaterial(material, with: replacement, in: itemID)
                } else {
                    await viewModel.importMaterial(replacement, into: itemID)
                }
            }
        }
    }

    private func startMaterialImport(_ materialImport: WorkboardMaterialImport) {
        materialMutationTask?.cancel()
        let itemID = viewModel.editingDraft.id
        materialMutationTask = Task { @MainActor in
            isImportingMaterials = true
            defer {
                isImportingMaterials = false
                materialMutationTask = nil
            }
            await viewModel.importMaterial(materialImport, into: itemID)
        }
    }

    private func startMaterialRemoval(_ material: WorkboardMaterialSnapshot) {
        materialMutationTask?.cancel()
        let itemID = viewModel.editingDraft.id
        materialMutationTask = Task { @MainActor in
            isImportingMaterials = true
            defer {
                isImportingMaterials = false
                materialMutationTask = nil
            }
            await viewModel.removeMaterial(material, from: itemID)
        }
    }

    private func cancelEditorTransients() {
        photoImportTask?.cancel()
        filePreparationTask?.cancel()
        fileImportTask?.cancel()
        materialMutationTask?.cancel()
        photoImportTask = nil
        filePreparationTask = nil
        fileImportTask = nil
        materialMutationTask = nil
        viewModel.voiceCaptureTarget = nil
    }
}

private struct WorkboardPickedFile: Hashable, Sendable {
    let url: URL
    let byteCount: Int64
    let mimeType: String?
}

private struct WorkboardLargeFileConfirmation: WorkboardLargeImportConfirming {
    let id = UUID()
    let files: [WorkboardPickedFile]
    let replacingMaterial: WorkboardMaterialSnapshot?
    let itemID: UUID

    init(
        files: [WorkboardPickedFile],
        replacingMaterial: WorkboardMaterialSnapshot? = nil,
        itemID: UUID
    ) {
        self.files = files
        self.replacingMaterial = replacingMaterial
        self.itemID = itemID
    }

    var largeItemByteCounts: [Int64] {
        files.map(\.byteCount).filter { $0 > Int64(Constants.fileTransferSoftConfirmBytes) }
    }
}

private enum WorkboardEditorField: Hashable {
    case title
    case objective
    case context
    case desiredResult
    case constraints
}

private extension WorkboardEditorFocusTarget {
    var editorField: WorkboardEditorField {
        switch self {
        case .objective: return .objective
        }
    }
}

private struct WorkboardLabeledEditor<Trailing: View>: View {
    let title: LocalizedStringResource
    let prompt: LocalizedStringResource
    @Binding var text: String
    let minHeight: CGFloat
    var isRequired = false
    var focusedField: FocusState<WorkboardEditorField?>.Binding
    let field: WorkboardEditorField
    let trailing: Trailing

    init(
        title: LocalizedStringResource,
        prompt: LocalizedStringResource,
        text: Binding<String>,
        minHeight: CGFloat,
        isRequired: Bool = false,
        focusedField: FocusState<WorkboardEditorField?>.Binding,
        field: WorkboardEditorField,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.prompt = prompt
        _text = text
        self.minHeight = minHeight
        self.isRequired = isRequired
        self.focusedField = focusedField
        self.field = field
        self.trailing = trailing()
    }

    var body: some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if isRequired {
                        Text(LocalizedStringResource(
                            "workboard.editor.required",
                            defaultValue: "Required"
                        ))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.brandAmber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(AppColors.brandAmber.opacity(0.1), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    trailing
                }

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(prompt)
                            .font(.body)
                            .foregroundStyle(AppColors.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $text)
                        .font(.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .scrollContentBackground(.hidden)
                        .focused(focusedField, equals: field)
                        .frame(minHeight: minHeight)
                        .padding(.horizontal, -1)
                        .background(.clear)
                        .accessibilityLabel(Text(title))
                        .accessibilityHint(Text(prompt))
                }
                .padding(8)
                .background(AppColors.backgroundSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(focusedField.wrappedValue == field ? AppColors.brandAmber.opacity(0.62) : AppColors.borderSubtle, lineWidth: 1)
                }
            }
        }
    }
}

private extension WorkboardLabeledEditor where Trailing == EmptyView {
    init(
        title: LocalizedStringResource,
        prompt: LocalizedStringResource,
        text: Binding<String>,
        minHeight: CGFloat,
        isRequired: Bool = false,
        focusedField: FocusState<WorkboardEditorField?>.Binding,
        field: WorkboardEditorField
    ) {
        self.init(
            title: title,
            prompt: prompt,
            text: text,
            minHeight: minHeight,
            isRequired: isRequired,
            focusedField: focusedField,
            field: field,
            trailing: { EmptyView() }
        )
    }
}

enum WorkboardMaterialComposerKind: String, Identifiable {
    case link
    case note

    var id: String { rawValue }
}

struct WorkboardTextMaterialSheet: View {
    private enum Field: Hashable { case title, value }

    let kind: WorkboardMaterialComposerKind
    let onAdd: (WorkboardMaterialImport) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var value = ""
    @State private var validationMessage: LocalizedStringResource?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: titlePrompt),
                        text: $title
                    )
                    .focused($focusedField, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .value }
                    .accessibilityLabel(Text(titlePrompt))
                    if kind == .link {
                        TextField(
                            String(localized: LocalizedStringResource(
                                "workboard.material.link.url",
                                defaultValue: "https://example.com"
                            )),
                            text: $value
                        )
                        .textContentType(.URL)
                        .focused($focusedField, equals: .value)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "workboard.material.link.url.label",
                            defaultValue: "Web address"
                        )))
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    } else {
                        TextEditor(text: $value)
                            .frame(minHeight: 160)
                            .focused($focusedField, equals: .value)
                            .accessibilityLabel(Text(LocalizedStringResource(
                                "workboard.material.note.body",
                                defaultValue: "Note text"
                            )))
                    }
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(AppColors.error)
                    }
                } header: {
                    Text(kind == .link
                        ? LocalizedStringResource("workboard.material.link.title", defaultValue: "Reference Link")
                        : LocalizedStringResource("workboard.material.note.title", defaultValue: "Standalone Note"))
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text(kind == .link
                        ? LocalizedStringResource("workboard.material.link.footer", defaultValue: "The gateway receives the address as text. Conduck does not fetch the page in the background.")
                        : LocalizedStringResource("workboard.material.note.footer", defaultValue: "Use a note when a thought should remain a separate, reusable material."))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(kind == .link
                ? LocalizedStringResource("workboard.material.addLink", defaultValue: "Add Link")
                : LocalizedStringResource("workboard.material.addNote", defaultValue: "Add Note"))
            .workboardInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.add", defaultValue: "Add"), action: add)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .workboardDesktopSheetFrame(minWidth: 360, minHeight: kind == .note ? 360 : 260)
        .onAppear { focusedField = .value }
    }

    private var titlePrompt: LocalizedStringResource {
        kind == .link
            ? LocalizedStringResource("workboard.material.link.name", defaultValue: "Link name (optional)")
            : LocalizedStringResource("workboard.material.note.name", defaultValue: "Note title (optional)")
    }

    private func add() {
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .link:
            guard let url = URL(string: cleanValue),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                validationMessage = LocalizedStringResource(
                    "workboard.material.link.invalid",
                    defaultValue: "Enter a complete http or https address."
                )
                focusedField = .value
                AccessibilityAnnouncer.announce(LocalizedStringResource(
                    "workboard.material.link.invalid",
                    defaultValue: "Enter a complete http or https address."
                ))
                return
            }
            onAdd(WorkboardMaterialImport(
                kind: .link,
                name: cleanTitle.isEmpty ? (url.host ?? cleanValue) : cleanTitle,
                detail: url.host,
                textContent: cleanValue,
                urlString: cleanValue
            ))
        case .note:
            let fallback = String(localized: LocalizedStringResource(
                "workboard.material.note.defaultName",
                defaultValue: "Note"
            ))
            onAdd(WorkboardMaterialImport(
                kind: .note,
                name: cleanTitle.isEmpty ? fallback : cleanTitle,
                textContent: cleanValue
            ))
        }
        dismiss()
    }
}

private struct WorkboardDraftSuggestionView: View {
    @Bindable var viewModel: WorkboardViewModel
    let suggestion: WorkboardEditDraft

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label {
                        Text(LocalizedStringResource(
                            "workboard.shape.review.message",
                            defaultValue: "Review the proposed wording. Your original stays unchanged until you apply it."
                        ))
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(AppColors.brandTeal)
                    }
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)

                    suggestionSection(
                        LocalizedStringResource("workboard.editor.title.label", defaultValue: "Title"),
                        value: suggestion.title
                    )
                    suggestionSection(
                        LocalizedStringResource("workboard.editor.objective.title", defaultValue: "What needs doing?"),
                        value: suggestion.objective
                    )
                    suggestionSection(
                        LocalizedStringResource("workboard.editor.context.title", defaultValue: "Context and thoughts"),
                        value: suggestion.context
                    )
                    suggestionSection(
                        LocalizedStringResource("workboard.editor.desiredResult.title", defaultValue: "A good result includes"),
                        value: suggestion.desiredResult
                    )
                    suggestionSection(
                        LocalizedStringResource("workboard.editor.constraints.title", defaultValue: "Constraints and guardrails"),
                        value: suggestion.constraints
                    )
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(LocalizedStringResource(
                "workboard.shape.review.title",
                defaultValue: "Suggested Brief"
            ))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource(
                        "workboard.shape.keepOriginal",
                        defaultValue: "Keep Original"
                    )) {
                        viewModel.editorSuggestion = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource(
                        "workboard.shape.apply",
                        defaultValue: "Apply Changes"
                    )) {
                        viewModel.applyEditorSuggestion()
                    }
                }
            }
        }
        .workboardDesktopSheetFrame(minWidth: 420, minHeight: 520)
    }

    private func suggestionSection(_ title: LocalizedStringResource, value: String) -> some View {
        WorkboardSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.brandAmber)
                Text(value.isEmpty
                    ? String(localized: LocalizedStringResource("workboard.shape.noChange", defaultValue: "No suggestion"))
                    : value)
                    .font(.body)
                    .foregroundStyle(value.isEmpty ? AppColors.textTertiary : AppColors.textPrimary)
                    .textSelection(.enabled)
            }
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
//
// Text editing belongs to a material ID and field, never to a gallery index.
// The router retains sessions across presentation changes. Failed writes keep
// the draft and its original revision; only Save or explicit Cancel resolves it.

import SwiftUI
import Observation

nonisolated enum WorkMaterialTextField: String, Hashable, Sendable {
    case annotation, source
}

nonisolated struct WorkMaterialTextEditorID: Hashable, Identifiable, Sendable {
    let materialID: UUID
    let field: WorkMaterialTextField
    var id: Self { self }
}

nonisolated struct WorkMaterialTextState: Equatable, Sendable {
    let revision: Int64
    let textContent: String?
    let annotation: String?

    init(material: WorkboardMaterialSnapshot) {
        revision = material.revision
        textContent = material.textContent
        annotation = material.annotation
    }

    init(record: WorkMaterialRecord) {
        revision = WorkboardRevision.value(for: record.updatedAt)
        textContent = record.textContent
        annotation = record.annotation
    }

    init(revision: Int64, textContent: String?, annotation: String?) {
        self.revision = revision
        self.textContent = textContent
        self.annotation = annotation
    }

    func value(for field: WorkMaterialTextField) -> String {
        (field == .annotation ? annotation : textContent) ?? ""
    }
}

@MainActor
struct WorkMaterialTextEditingDependencies {
    let load: (UUID) async throws -> WorkMaterialTextState
    let save: (UUID, String?, String?, Int64) async throws -> WorkMaterialTextState

    static var live: Self {
        Self(load: { id in
            guard let record = try await ConversationStore.shared.fetchWorkMaterial(id: id) else {
                throw WorkboardStoreError.materialNotFound
            }
            return WorkMaterialTextState(record: record)
        }, save: { id, source, annotation, revision in
            let record = try await ConversationStore.shared.updateWorkMaterialText(
                id: id, textContent: source, annotation: annotation, expectedRevision: revision)
            return WorkMaterialTextState(record: record)
        })
    }
}

@Observable @MainActor
final class WorkMaterialTextEditorSession: Identifiable {
    let id: WorkMaterialTextEditorID
    let title: String
    let kind: WorkboardMaterialKind
    private let allowsSourceEditing: Bool
    var text: String
    private(set) var saved: WorkMaterialTextState
    private(set) var isSaving = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let dependencies: WorkMaterialTextEditingDependencies

    init(material: WorkboardMaterialSnapshot, field: WorkMaterialTextField,
         dependencies: WorkMaterialTextEditingDependencies? = nil) {
        id = .init(materialID: material.id, field: field)
        title = material.name
        kind = material.kind
        allowsSourceEditing = !material.isRemoteProjectResult && (material.kind == .note || material.kind == .transcript)
        let initialState = WorkMaterialTextState(material: material)
        saved = initialState
        text = initialState.value(for: field)
        self.dependencies = dependencies ?? .live
    }

    var isDirty: Bool { text != saved.value(for: id.field) }
    var isBusy: Bool { isSaving || isLoading }

    /// Called on editor presentation. Unsaved drafts always win over a refresh.
    func loadLatest(discardDraft: Bool = false) async {
        guard !isBusy, discardDraft || !isDirty else { return }
        isLoading = true
        errorMessage = nil
        let before = text
        defer { isLoading = false }
        do {
            let latest = try await dependencies.load(id.materialID)
            // A user could start typing during the load through another view
            // of the retained session. That edit must not be overwritten.
            guard text == before else { return }
            saved = latest
            text = latest.value(for: id.field)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard !isBusy else { return false }
        guard isDirty else { return true }
        guard id.field != .source || allowsSourceEditing else { return false }
        isSaving = true
        errorMessage = nil
        let submittedText = text
        let submittedRevision = saved.revision
        defer { isSaving = false }
        do {
            let accepted = try await dependencies.save(
                id.materialID,
                id.field == .source ? submittedText : nil,
                id.field == .annotation ? submittedText : saved.annotation,
                submittedRevision
            )
            saved = accepted
            if text == submittedText { text = accepted.value(for: id.field) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancel() {
        guard !isBusy else { return }
        text = saved.value(for: id.field)
        errorMessage = nil
    }
}

struct WorkMaterialTextEditor: View {
    @Bindable var session: WorkMaterialTextEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsReload = false

    private var heading: LocalizedStringResource {
        if session.id.field == .annotation {
            return LocalizedStringResource("workdesk.material.notes.title", defaultValue: "Your notes")
        }
        return session.kind == .transcript
            ? LocalizedStringResource("workboard.material.transcript.edit", defaultValue: "Edit transcript")
            : LocalizedStringResource("workboard.material.text.edit", defaultValue: "Edit text")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: session.title).font(.headline)
                    if session.id.field == .annotation {
                        Text(LocalizedStringResource("workboard.material.notes.explanation", defaultValue: "Keep context with this material. These notes are included when you bring it into a new conversation."))
                            .font(.callout).foregroundStyle(AppColors.textSecondary)
                    }
                    TextField(text: $session.text, axis: .vertical) {
                        Text(LocalizedStringResource("workboard.material.notes.placeholder", defaultValue: "Write here…"))
                    }
                    .lineLimit(10...30)
                    .padding(16)
                    .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(Text(heading))
                    .accessibilityIdentifier("workboard-material-text-editor")
                    if session.isLoading { ProgressView() }
                    if let error = session.errorMessage {
                        Text(verbatim: error).font(.callout).foregroundStyle(.red)
                        Text(LocalizedStringResource("workboard.material.notes.draftKept", defaultValue: "Your changes are still here. Try saving again, or load the saved text to replace your changes."))
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                        Button(LocalizedStringResource("workboard.material.notes.reload", defaultValue: "Load saved text…")) {
                            confirmsReload = true
                        }.inlineLinkButton()
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }
            .disabled(session.isBusy)
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.background)
            .navigationTitle(Text(heading))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) {
                        session.cancel(); dismiss()
                    }.disabled(session.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.save", defaultValue: "Save")) {
                        Task { if await session.save(), !session.isDirty { dismiss() } }
                    }.disabled(session.isBusy || !session.isDirty)
                }
            }
        }
        .interactiveDismissDisabled(session.isDirty || session.isBusy)
        .task { await session.loadLatest() }
        .confirmationDialog(Text(LocalizedStringResource("workboard.material.notes.reloadConfirm", defaultValue: "Replace your changes with the saved text?")), isPresented: $confirmsReload, titleVisibility: .visible) {
            Button(LocalizedStringResource("workboard.material.notes.reloadAction", defaultValue: "Load saved text"), role: .destructive) {
                Task { await session.loadLatest(discardDraft: true) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 440)
        #endif
    }
}

/// The source renderer stays visible while the user writes alongside it.
struct WorkMaterialInlineNotesEditor: View {
    @Bindable var session: WorkMaterialTextEditorSession
    let onFinish: () -> Void
    @State private var confirmsReload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource("workdesk.material.notes.title", defaultValue: "Your notes"))
                .font(.subheadline.weight(.semibold))
            TextField(text: $session.text, axis: .vertical) {
                Text(LocalizedStringResource("workboard.material.notes.placeholder", defaultValue: "Write here…"))
            }
            .lineLimit(3...8)
            .padding(12)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(Text(LocalizedStringResource("workdesk.material.notes.title", defaultValue: "Your notes")))
            .disabled(session.isBusy)
            if let error = session.errorMessage {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
                Text(LocalizedStringResource("workboard.material.notes.draftKept", defaultValue: "Your changes are still here. Try saving again, or load the saved text to replace your changes."))
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
                Button(LocalizedStringResource("workboard.material.notes.reload", defaultValue: "Load saved text…")) {
                    confirmsReload = true
                }.inlineLinkButton().disabled(session.isBusy)
            }
            HStack {
                if session.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) {
                    session.cancel(); onFinish()
                }.inlineLinkButton().disabled(session.isBusy)
                Button(LocalizedStringResource("common.save", defaultValue: "Save")) {
                    Task { if await session.save(), !session.isDirty { onFinish() } }
                }.buttonStyle(.borderedProminent).disabled(session.isBusy || !session.isDirty)
            }
        }
        .task { await session.loadLatest() }
        .confirmationDialog(Text(LocalizedStringResource("workboard.material.notes.reloadConfirm", defaultValue: "Replace your changes with the saved text?")), isPresented: $confirmsReload, titleVisibility: .visible) {
            Button(LocalizedStringResource("workboard.material.notes.reloadAction", defaultValue: "Load saved text"), role: .destructive) {
                Task { await session.loadLatest(discardDraft: true) }
            }
        }
    }
}

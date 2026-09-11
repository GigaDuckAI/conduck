// SPDX-License-Identifier: Apache-2.0

// Standing project context is edited independently of any conversation task.
// The opening revision stays fixed while typing, so a synced project change
// cannot silently overwrite or be overwritten by this editor's save.

import SwiftUI

struct WorkDeskProjectContextEditor: View {
    let organization: WorkDeskOrganization
    let onSaved: @MainActor (WorkDeskProjectRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: WorkDeskProjectRecord
    @State private var context: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(project: WorkDeskProjectRecord, organization: WorkDeskOrganization,
         onSaved: @escaping @MainActor (WorkDeskProjectRecord) -> Void = { _ in }) {
        self.organization = organization
        self.onSaved = onSaved
        _baseline = State(initialValue: project)
        _context = State(initialValue: project.brief)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: baseline.title).font(.title2.weight(.semibold))
                    Text(LocalizedStringResource("workdesk.project.context.explanation", defaultValue: "Background, goals and preferences to include when starting conversations in this project. Give each conversation its own task."))
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                    TextField(text: $context, axis: .vertical) {
                        Text(LocalizedStringResource("workdesk.project.context.placeholder", defaultValue: "What should your AI know about this project?"))
                    }
                    .lineLimit(8...20)
                    .padding(16)
                    .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(Text(LocalizedStringResource("workdesk.project.context.title", defaultValue: "Project context")))
                    .accessibilityIdentifier("workdesk-project-context-editor")
                    Text(LocalizedStringResource("workdesk.project.context.future", defaultValue: "Changes apply to new requests. Existing conversations keep the context they received."))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                    if let errorMessage {
                        Text(verbatim: errorMessage).font(.callout).foregroundStyle(.red)
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSaving)
            .background(AppColors.background)
            .navigationTitle(Text(LocalizedStringResource("workdesk.project.context.title", defaultValue: "Project context")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.save", defaultValue: "Save")) { save() }
                        .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(context != baseline.brief || isSaving)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 420)
        #endif
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            let saved = await organization.updateProject(
                id: baseline.id, title: baseline.title, brief: context,
                preferredGatewayRef: baseline.preferredGatewayRef,
                expectedUpdatedAt: baseline.updatedAt
            )
            isSaving = false
            if saved, let updated = organization.project(id: baseline.id) {
                onSaved(updated)
                dismiss()
            } else {
                errorMessage = organization.errorMessage
                organization.errorMessage = nil
            }
        }
    }
}

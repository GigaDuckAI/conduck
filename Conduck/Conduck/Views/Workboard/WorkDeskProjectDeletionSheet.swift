// SPDX-License-Identifier: Apache-2.0

// Deleting a project is a reviewed choice over an immutable material set.
// Keeping is the default; removing Work materials never removes sent chat
// history or gateway files. A stale review must be reopened, never enlarged.

import SwiftUI

struct WorkDeskProjectDeletionSheet: View {
    let review: WorkDeskProjectDeletionReview
    let organization: WorkDeskOrganization
    let onDeleted: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(LocalizedStringResource("workdesk.project.delete.question",
                        defaultValue: "Delete “\(review.projectTitle)”?"))
                        .font(.title2.weight(.semibold))
                    Text(LocalizedStringResource("workdesk.project.delete.context",
                        defaultValue: "The project and its saved context will be removed."))
                        .foregroundStyle(AppColors.textSecondary)
                    if review.conversationCount > 0 {
                        Text(WorkDeskCopy.retainedConversationCount(review.conversationCount))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    if let error {
                        Text(verbatim: error).foregroundStyle(AppColors.warning)
                        Text(LocalizedStringResource("workdesk.project.delete.reopen",
                            defaultValue: "Close this review and choose Delete project again to review the latest materials."))
                            .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                    } else if review.materialCount > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(LocalizedStringResource("workdesk.project.delete.keep", defaultValue: "Keep materials")) {
                                delete(keepingMaterials: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("workdesk-delete-project-keep")
                            Text(LocalizedStringResource("workdesk.project.delete.keep.explanation",
                                defaultValue: "They stay in All materials, grouped together in Desk view. Notes attached to them are kept too."))
                                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Button(WorkDeskCopy.deleteProjectAndMaterials(review.materialCount), role: .destructive) {
                                delete(keepingMaterials: false)
                            }.buttonStyle(.bordered)
                                .accessibilityIdentifier("workdesk-delete-project-materials")
                            Text(LocalizedStringResource("workdesk.project.delete.remove.explanation",
                                defaultValue: "Removes these materials and their attached notes from Work on your synced devices. Existing conversations and files already sent to gateways remain."))
                                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                        }
                    } else {
                        Button(WorkDeskCopy.deleteProjectAndMaterials(0), role: .destructive) {
                            delete(keepingMaterials: true)
                        }.buttonStyle(.bordered)
                    }
                    if isDeleting { ProgressView() }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isDeleting)
            }
            .navigationTitle(Text(LocalizedStringResource("workdesk.project.delete.review", defaultValue: "Delete project")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400)
        .presentationDetents([.large])
        .interactiveDismissDisabled(isDeleting)
    }

    private func delete(keepingMaterials: Bool) {
        guard !isDeleting, error == nil else { return }
        isDeleting = true
        Task {
            let saved = await organization.deleteProject(review: review, deleteMaterials: !keepingMaterials)
            isDeleting = false
            if saved { onDeleted(keepingMaterials); dismiss() }
            else {
                error = organization.errorMessage
                    ?? String(localized: "workdesk.project.delete.failed", defaultValue: "The project couldn’t be deleted.")
                organization.errorMessage = nil
            }
        }
    }
}

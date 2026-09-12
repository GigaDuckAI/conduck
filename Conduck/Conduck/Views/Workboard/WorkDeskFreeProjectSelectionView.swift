// SPDX-License-Identifier: Apache-2.0

// A free-plan allowance never chooses which projects matter. This
// review holds the exact active identities shown and archives only after an
// explicit confirmation. A changed active set or renewed Pro access refuses
// the stale write; all materials and conversation history stay in place.

import SwiftUI

struct WorkDeskFreeProjectSelectionView: View {
    let organization: WorkDeskOrganization
    @State private var reviewedProjects: [WorkDeskProjectRecord]
    @State private var selectedIDs: Set<UUID> = []
    @State private var isSaving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(organization: WorkDeskOrganization) {
        self.organization = organization
        _reviewedProjects = State(initialValue: organization.activeProjects)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringResource("workdesk.pro.selection.explanation", defaultValue: "Keep up to \(Constants.maxActiveWorkProjects) projects active. The others will be archived, with all their materials and conversations preserved."))
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
                    .padding(.horizontal, 20).padding(.top, 16)
                List(reviewedProjects) { project in
                    let selected = selectedIDs.contains(project.id)
                    Button {
                        if selected { selectedIDs.remove(project.id) }
                        else if selectedIDs.count < Constants.maxActiveWorkProjects { selectedIDs.insert(project.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? AppColors.accent : AppColors.textTertiary)
                            Text(verbatim: project.title).foregroundStyle(AppColors.textPrimary)
                            Spacer(minLength: 0)
                        }.padding(.vertical, 8)
                    }
                    .choiceCardButton(cornerRadius: 8)
                    .disabled(isSaving || (!selected && selectedIDs.count >= Constants.maxActiveWorkProjects))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                .scrollDismissesKeyboard(.interactively)
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringResource("workdesk.pro.selection.summary", defaultValue: "\(selectedIDs.count) will stay active. \(reviewedProjects.count - selectedIDs.count) will be archived."))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                    if let error {
                        Text(verbatim: error).font(.caption).foregroundStyle(.red)
                        Button(LocalizedStringResource("workdesk.pro.selection.reviewAgain", defaultValue: "Review projects again")) {
                            Task {
                                await organization.reload()
                                reviewedProjects = organization.activeProjects
                                selectedIDs.formIntersection(reviewedProjects.map(\.id))
                                self.error = nil
                            }
                        }.inlineLinkButton()
                    }
                    Button(selectedIDs.isEmpty
                        ? LocalizedStringResource("workdesk.pro.selection.archiveAll", defaultValue: "Archive all projects")
                        : LocalizedStringResource("workdesk.pro.selection.confirm", defaultValue: "Keep selected projects active")) {
                        confirm()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            .navigationTitle(Text(LocalizedStringResource("workdesk.pro.chooseProjects", defaultValue: "Choose projects")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 460, minHeight: 420, idealHeight: 580)
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSaving)
        .onChange(of: organization.hasProAccess) { _, hasAccess in
            if hasAccess { dismiss() }
        }
    }

    private func confirm() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let saved = await organization.selectFreeProjects(keeping: selectedIDs,
                expectedActiveProjectIDs: Set(reviewedProjects.map(\.id)))
            isSaving = false
            if saved { dismiss() }
            else {
                error = organization.errorMessage
                organization.errorMessage = nil
            }
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

// Usage is accepted conversation history, independent of a material's current
// project home. This picker lists only persisted receipts and keeps gateway
// identity visible when the same material was used on different destinations.

import SwiftUI

struct WorkDeskMaterialUsesSheet: View {
    @Bindable var workspace: WorkDeskWorkspaceState
    let materialID: UUID
    let materialName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let uses = workspace.uses(for: materialID)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: materialName).font(.headline)
                    Text(LocalizedStringResource("workdesk.material.used.explanation",
                        defaultValue: "These conversations used a copy of the material as it was when sent. Moving or editing it in Work doesn’t change earlier messages."))
                        .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                    if uses.isEmpty {
                        Text(LocalizedStringResource("workdesk.material.used.empty",
                            defaultValue: "No saved conversations use this material."))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    ForEach(uses) { use in
                        Button {
                            workspace.openRelatedConversation(use.conversationID)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: use.conversationTitle).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text(verbatim: gatewayName(use.gatewayRef))
                                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                                    Text(use.sentAt, format: .dateTime.day().month().year())
                                        .font(.caption).foregroundStyle(AppColors.textTertiary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12))
                        }.choiceCardButton(cornerRadius: 12)
                    }
                }.padding(20)
            }
            .navigationTitle(Text(WorkDeskCopy.conversationUses(uses.count)))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.done", defaultValue: "Done")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 480, minHeight: 320)
        .presentationDetents([.medium, .large])
    }

    private func gatewayName(_ raw: String) -> String {
        guard let ref = RemoteAgentRef(rawString: raw) else {
            return String(localized: "workdesk.conversation.connectionMissing", defaultValue: "Connection unavailable")
        }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: workspace.conversationSettings.customGateways)
    }
}

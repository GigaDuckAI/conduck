// SPDX-License-Identifier: Apache-2.0

// A conversation may reuse a material from anywhere in Work without moving
// its project home. This picker changes only the locally reviewed request.

import SwiftUI

struct WorkDeskMaterialPicker: View {
    let materials: [WorkboardMaterialSnapshot]
    let projectNames: [UUID: String]
    let onAdd: ([WorkboardMaterialSnapshot]) -> Bool
    @State private var selectedIDs: Set<UUID> = []
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var selectionChanged: Bool { !selectedIDs.isSubset(of: Set(materials.map(\.id))) }
    private var matching: [WorkboardMaterialSnapshot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return materials.filter { material in
            query.isEmpty || [material.name, material.textContent ?? "", material.annotation ?? "", projectNames[material.id] ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringResource("workdesk.conversation.addMaterials.explanation", defaultValue: "Use materials from anywhere in Work. They stay in their current projects."))
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                    ForEach(matching) { material in
                        Button {
                            if !selectedIDs.insert(material.id).inserted { selectedIDs.remove(material.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(material.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(AppColors.brandAmber)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: material.name).font(.body).lineLimit(2)
                                    Label {
                                        Text(verbatim: projectNames[material.id] ?? String(localized: "workdesk.material.unfiled", defaultValue: "No project"))
                                    } icon: { Image(systemName: "folder") }
                                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 10))
                        }.choiceCardButton(cornerRadius: 10)
                        .accessibilityValue(Text(selectedIDs.contains(material.id)
                            ? LocalizedStringResource("workdesk.brief.included", defaultValue: "Included")
                            : LocalizedStringResource("workdesk.brief.leftOut", defaultValue: "Left out")))
                    }
                    if selectionChanged {
                        Text(LocalizedStringResource("workdesk.conversation.selectionChanged", defaultValue: "The selected materials changed. Choose them again."))
                            .font(.callout).foregroundStyle(AppColors.textSecondary)
                        Button(LocalizedStringResource("workdesk.conversation.clearSelection", defaultValue: "Clear selection")) { selectedIDs = [] }
                            .inlineLinkButton()
                    }
                }.padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.background)
            .searchable(text: $search, prompt: Text(LocalizedStringResource("workdesk.conversation.findMaterial", defaultValue: "Find a material")))
            .navigationTitle(Text(LocalizedStringResource("workdesk.conversation.addMaterials.title", defaultValue: "Add materials")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("workdesk.conversation.addSelected", defaultValue: "Add selected")) {
                        guard !selectionChanged, onAdd(materials.filter { selectedIDs.contains($0.id) }) else { return }
                        dismiss()
                    }.disabled(selectedIDs.isEmpty || selectionChanged)
                }
            }
        }
        .workboardDesktopSheetFrame(minWidth: 420, minHeight: 400)
    }
}

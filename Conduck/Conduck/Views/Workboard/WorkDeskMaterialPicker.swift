// SPDX-License-Identifier: Apache-2.0

// A conversation may reuse a material from anywhere in Work without moving
// its project home. This picker changes only the locally reviewed request.
// Header, search and actions remain outside the scrolling results so narrow
// screens and the keyboard never strand the choice or the way back.

import SwiftUI

struct WorkDeskMaterialPicker: View {
    let materials: [WorkboardMaterialSnapshot]
    let projectNames: [UUID: String]
    let onAdd: ([WorkboardMaterialSnapshot]) -> Bool
    @State private var selectedIDs: Set<UUID> = []
    @State private var search = ""
    @State private var resultsHeight: CGFloat = 240
    @FocusState private var searchFocused: Bool
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringResource("workdesk.conversation.addMaterials.title", defaultValue: "Materials from Work"))
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                searchField
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringResource("workdesk.conversation.addMaterials.explanation", defaultValue: "Included in this conversation only. Their projects stay the same."))
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if matching.isEmpty {
                        Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? LocalizedStringResource("workdesk.conversation.addMaterials.empty", defaultValue: "All available materials are already in this conversation.")
                            : LocalizedStringResource("workdesk.conversation.addMaterials.noMatches", defaultValue: "No materials match your search."))
                            .font(.callout).foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                    }
                    ForEach(matching) { material in
                        Button {
                            if !selectedIDs.insert(material.id).inserted { selectedIDs.remove(material.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(material.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(material.id) ? AppColors.brandAmber : AppColors.textTertiary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: material.name).font(.body)
                                        .fixedSize(horizontal: false, vertical: true)
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
                        .accessibilityAddTraits(selectedIDs.contains(material.id) ? .isSelected : [])
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
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealHeight: min(max(resultsHeight, 100), 400))

            Divider().opacity(0.45)
            footer
        }
        .foregroundStyle(AppColors.textPrimary)
        .background(AppColors.background)
        .workboardDesktopSheetFrame(minWidth: 420, minHeight: 300, idealWidth: 580, maxWidth: 680, maxHeight: 720)
        .workDeskConversationSheetPresentation()
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppColors.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $search) {
                Text(LocalizedStringResource("workdesk.conversation.findMaterial", defaultValue: "Find a material"))
            }
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .submitLabel(.search)
            .onSubmit { searchFocused = false }
            .accessibilityIdentifier("workdesk-material-picker-search")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(width: WorkboardMetrics.touchTarget, height: WorkboardMetrics.touchTarget)
                }
                .pointerIconButton(size: WorkboardMetrics.touchTarget)
                .accessibilityLabel(Text(LocalizedStringResource("workdesk.search.clear", defaultValue: "Clear search")))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, search.isEmpty ? 12 : 0)
        .frame(minHeight: WorkboardMetrics.touchTarget)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Text(LocalizedStringResource("common.cancel", defaultValue: "Cancel"))
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(minHeight: WorkboardMetrics.touchTarget, maxHeight: .infinity)
                    .background(AppColors.cardBackgroundElevated, in: Capsule())
            }
            .primaryCTAButton()
            .keyboardShortcut(.cancelAction)
            Button {
                guard !selectedIDs.isEmpty, !selectionChanged,
                      onAdd(materials.filter { selectedIDs.contains($0.id) }) else { return }
                dismiss()
            } label: {
                Text(LocalizedStringResource("workdesk.conversation.addSelected", defaultValue: "Add selected"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(minHeight: WorkboardMetrics.touchTarget, maxHeight: .infinity)
                    .background(AppColors.brandAmber, in: Capsule())
            }
            .primaryCTAButton()
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIDs.isEmpty || selectionChanged)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

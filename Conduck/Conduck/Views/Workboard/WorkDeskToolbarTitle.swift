// SPDX-License-Identifier: Apache-2.0

// The Work identity occupies the same principal toolbar slot as Chat's gateway.
// Observe the workspace here so selection, search and rename update the title
// without copying state into a platform host. Project actions live in its pill;
// the full name stays accessible when a narrow navigation bar truncates it.

import SwiftUI

struct WorkDeskToolbarTitle: View {
    @Bindable var workspace: WorkDeskWorkspaceState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.phoneWorkbenchRouter) private var phoneWorkbenchRouter
    #endif

    private var title: String {
        if workspace.isSearching {
            return String(localized: LocalizedStringResource("workdesk.search.results", defaultValue: "Search results"))
        }
        return workspace.currentProject?.title
            ?? String(localized: LocalizedStringResource("workdesk.all", defaultValue: "All materials"))
    }

    private var maximumWidth: CGFloat {
        #if os(macOS)
        320
        #else
        horizontalSizeClass == .regular ? 280 : 160
        #endif
    }

    var body: some View {
        Group {
            if let project = workspace.currentProject, !workspace.isSearching {
                Menu {
                    Button(LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project"), systemImage: "pencil") {
                        workspace.editProject(project)
                    }
                    Button(LocalizedStringResource("workdesk.project.delete.action", defaultValue: "Delete project…"), systemImage: "trash") {
                        workspace.requestProjectDeletion(project.id)
                    }
                } label: {
                    pill(showsChevron: true)
                }
                #if os(macOS)
                .menuStyle(.button)
                .pointerIconButton(shape: .capsule)
                #endif
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityHint(Text(LocalizedStringResource("workdesk.options", defaultValue: "Desk options")))
                #if os(iOS)
                .simultaneousGesture(TapGesture().onEnded {
                    phoneWorkbenchRouter?.dismissPhoneSection(for: .work)
                })
                #endif
            } else {
                pill(showsChevron: false)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .accessibilityIdentifier("workdesk-toolbar-title")
        .help(title)
    }

    private func pill(showsChevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.tail)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(AppColors.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: maximumWidth)
        .fixedSize()
        .background(AppColors.cardBackgroundElevated, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

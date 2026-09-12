// SPDX-License-Identifier: Apache-2.0

// The Work identity occupies the same principal toolbar slot as Chat's gateway.
// Observe the workspace here so selection, search and rename update the title
// without copying state into a platform host. A conversation shows only Chat's
// gateway/clone chooser; project actions belong to the project view. The chooser
// opens the visible thread's existing sheet; it never rebinds a conversation or
// owns a second sender. Full names remain accessible when the bar truncates them.

import SwiftUI

struct WorkDeskToolbarTitle: View {
    @Bindable var workspace: WorkDeskWorkspaceState
    @Environment(\.workDeskConversationResolver) private var conversationResolver
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.phoneWorkbenchRouter) private var phoneWorkbenchRouter
    #endif

    private var title: String {
        if workspace.isSearching {
            return String(localized: LocalizedStringResource("workdesk.search.results", defaultValue: "Search results"))
        }
        if let project = workspace.currentProject {
            return project.title
        }
        return String(localized: LocalizedStringResource("workdesk.all", defaultValue: "Home"))
    }

    private var maximumWidth: CGFloat {
        #if os(macOS)
        320
        #else
        horizontalSizeClass == .regular ? 280 : 160
        #endif
    }

    var body: some View {
        if let conversation = workspace.currentConversation,
           let model = workspace.conversationModel(for: conversation.id, resolver: conversationResolver) {
            conversationGateway(model)
                .background(AppColors.cardBackgroundElevated, in: Capsule())
                #if os(macOS)
                .fixedSize()
                #endif
        } else {
            projectControl
        }
    }

    private var projectControl: some View {
        Group {
            if let project = workspace.currentProject, !workspace.isSearching {
                Menu {
                    Button(WorkDeskCopy.projectBriefState(hasBrief: !project.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                           systemImage: "text.alignleft") {
                        workspace.editingContextProjectID = project.id
                    }
                    .accessibilityIdentifier("workdesk-project-context")
                    if !workspace.conversations(in: project.id).isEmpty {
                        Menu {
                            ForEach(workspace.conversations(in: project.id)) { conversation in
                                Button {
                                    workspace.selectConversation(conversation.id, projectID: project.id)
                                } label: {
                                    Text(verbatim: conversation.displayTitle)
                                }
                            }
                        } label: {
                            Label(LocalizedStringResource("workdesk.project.conversations", defaultValue: "Conversations"),
                                  systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    Divider()
                    Button(LocalizedStringResource("workdesk.project.rename", defaultValue: "Rename project"), systemImage: "pencil") {
                        workspace.editProject(project)
                    }
                    WorkDeskProjectColorMenu(project: project, organization: workspace.organization)
                    WorkDeskProjectArchiveButton(project: project, organization: workspace.organization)
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
                .accessibilityHint(Text(LocalizedStringResource("workdesk.project.actions", defaultValue: "Project actions")))
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

    /// Same eligibility and sheet as a bound Chat. A forgotten gateway has no
    /// presence dot; its recovery action stays beside the error in the thread.
    private func conversationGateway(_ model: ConversationDetailViewModel) -> some View {
        let presenceRef = model.boundGatewayAvailable ? model.boundRef : nil
        let canSwitch = model.canSwitchGateway && model.hasTurns && model.boundGatewayAvailable
        return HStack(spacing: 6) {
            #if os(macOS)
            GatewayPresenceDot(ref: presenceRef, diameter: 6)
                .padding(.leading, 10)
            #endif
            if canSwitch {
                Button {
                    guard workspace.isActive, workspace.currentConversation?.id == model.conversationID else { return }
                    #if os(iOS)
                    phoneWorkbenchRouter?.dismissPhoneSection(for: .work)
                    #endif
                    model.showingGatewaySheet = true
                } label: {
                    gatewayLabel(model.backendDisplayName, presenceRef: presenceRef, interactive: true)
                }
                .pointerIconButton(shape: .capsule)
                .accessibilityLabel(Text(LocalizedStringResource("conversations.switchGateway", defaultValue: "Clone & continue on another gateway"))
                    + Text(verbatim: ": " + model.backendDisplayName))
                #if os(iOS)
                .gatewayPresenceAccessibilityValue(for: presenceRef)
                #endif
                .help(String(localized: LocalizedStringResource("conversations.switchGateway", defaultValue: "Clone & continue on another gateway")))
                .accessibilityIdentifier("toolbar.cloneGateway")
            } else {
                gatewayLabel(model.backendDisplayName, presenceRef: presenceRef, interactive: false)
            }
        }
        .accessibilityIdentifier("workdesk-conversation-gateway")
    }

    private func gatewayLabel(_ name: String, presenceRef: RemoteAgentRef?, interactive: Bool) -> some View {
        HStack(spacing: 4) {
            #if os(iOS)
            GatewayPresenceDot(ref: presenceRef, standaloneAccessibility: !interactive)
            #endif
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.tail)
            if interactive {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(AppColors.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: maximumWidth)
        .fixedSize(horizontal: false, vertical: true)
        #if os(iOS)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        #endif
        .help(name)
    }
}

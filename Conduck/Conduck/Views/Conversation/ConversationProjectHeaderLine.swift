// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationProjectHeaderLine.swift
//
// The one line a project's conversation shows under the navigation bar when
// it is opened from Chats: the same folder the Work sidebar draws for the
// project, in the project's colour, its name, and "Show in Work". It exists
// because a project thread listed among ordinary chats is otherwise
// indistinguishable from them once open — the row's mark scrolls away with
// the list. Absent inside Work (the workspace already frames the thread) and
// absent for an unfiled chat; a project whose row has not synced draws no
// line either, since there is no name to show and nowhere to go.
//
// Membership only. The line never claims the gateway knows the project's
// materials — a trimmed history forgets the brief like any other turn.
//
// `ProjectContextRefreshModifier` is the host-side half: it keeps a
// `ConversationProjectContext` current for the thread on screen, on the same
// signals the list uses (a desk or row write, a foreground re-read, a plan
// change) plus the send error — a refusal the write raised after a tap the
// lock did not catch re-syncs the lock.

import SwiftUI

struct ConversationProjectHeaderLine: View {
    let mark: WorkProjectMark
    /// Nil when no Work route is reachable from this host — the line still
    /// names the project, it just is not a control.
    let onShowInWork: (() -> Void)?

    private var name: String {
        MessageRowFormatters.projectDisplayName(mark.title)
    }

    private var showInWork: String {
        String(localized: "conversations.thread.showInWork", defaultValue: "Show in Work")  // xcstrings: chat-ui
    }

    var body: some View {
        Group {
            if let onShowInWork {
                Button(action: onShowInWork) { label }
                    .buttonStyle(.plain)
                    .pointerLink()
                    .accessibilityLabel(Text(verbatim: spokenLine))
                    .accessibilityHint(Text(verbatim: showInWork))
                    .accessibilityIdentifier("thread.project.showInWork")
            } else {
                label
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spokenLine))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: Constants.Layout.chatContentWidth)
        .frame(maxWidth: .infinity)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: mark.isArchived ? "archivebox" : "folder")
                .foregroundStyle(mark.color.tint)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .lineLimit(1)
            if mark.isArchived {
                Text(verbatim: "· \(MessageRowFormatters.archivedWord)")
                    .lineLimit(1)
                    .fixedSize()
            }
            if onShowInWork != nil {
                Spacer(minLength: 8)
                Text(verbatim: showInWork)
                    .foregroundStyle(AppColors.accent)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.accent)
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(AppColors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var spokenLine: String {
        let membership = String(localized: "conversations.row.a11y.inProject",
                                defaultValue: "In project \(name)")  // xcstrings: chat-ui
        return mark.isArchived ? "\(membership). \(MessageRowFormatters.archivedWord)" : membership
    }
}

/// Keeps a `ConversationProjectContext` current for the thread a host shows.
struct ProjectContextRefreshModifier: ViewModifier {
    let context: ConversationProjectContext
    let conversationID: UUID?
    let sendError: String?

    func body(content: Content) -> some View {
        content
            .task(id: conversationID) {
                await context.refresh(conversationID: conversationID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationsDidChange)) { _ in
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationsNeedLocalRefresh)) { _ in
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsDidChangeRemotely)) { _ in
                refresh()
            }
            .onChange(of: sendError) { _, newValue in
                if newValue != nil { refresh() }
            }
    }

    private func refresh() {
        let id = conversationID
        Task { @MainActor in await context.refresh(conversationID: id) }
    }
}

extension View {
    func projectContextRefresh(
        _ context: ConversationProjectContext, conversationID: UUID?, sendError: String?
    ) -> some View {
        modifier(ProjectContextRefreshModifier(context: context, conversationID: conversationID, sendError: sendError))
    }
}

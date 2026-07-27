// SPDX-License-Identifier: Apache-2.0

// Conduck
// WatchAttachmentTextView.swift
//
// Full-screen scrolling viewer for a locally-synced text/code attachment on
// the Watch (watchOS has no QuickLook). Pushed as a `.attachmentText` route from
// `WatchConversationThreadView`'s tappable file row; the route carries only IDs
// (never a filename or content in a route value), so this view loads the
// attachment's decoded `extractedText` from the store by id in a `.task`.
//
// Only reachable for a `.viewableText`-classified attachment (see
// `AttachmentRecord.watchDisplayClass`): either an INLINE text file (its bytes
// ride the snapshot's `extractedText`) or a server-reference TEXT PREVIEW (whose
// snapshot omits the bytes — they are lazily faulted via
// `ConversationStore.fetchPreviewText`, and the content carries a snapshot-
// honesty footer). A nil / no-longer-present row, or a preview whose blob hasn't
// synced yet, resolves to the passive "no longer available" state, never a blank
// screen. Native back navigation is the only dismiss (no custom control).

import SwiftUI

struct WatchAttachmentTextView: View {
    let conversationID: UUID
    let messageID: UUID
    let attachmentID: UUID
    /// Store seam — `.shared` in production (CloudKit-synced); injectable so a
    /// test can drive an in-memory store.
    var store: ConversationStore = .shared

    /// AOD dims via OPACITY only — never branch the text LAYOUT on luminance, so
    /// a wrist raise/lower can't force a full re-layout of a long file.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        /// `isPreview` true when the text is a server-reference SNAPSHOT (lazily
        /// faulted `previewData`), not the inline file's own bytes — drives the
        /// honesty footer ("the server file may have changed since").
        case content(title: String, text: String, isPreview: Bool)
        case missing
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .tint(AppColors.brandAmber)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)

            case .content(let title, let text, let isPreview):
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if isPreview {
                            // Snapshot honesty — the on-device copy is frozen at
                            // reply time; the authoritative server file may differ now.
                            Text(LocalizedStringResource(
                                "watch.attachment.snapshot.caption",
                                defaultValue: "Saved copy from when this reply arrived"
                            ))  // xcstrings
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)

            case .missing:
                Text(LocalizedStringResource(
                    "watch.attachment.missing",
                    defaultValue: "This file is no longer available."
                ))  // xcstrings
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            }
        }
        .opacity(isLuminanceReduced ? 0.6 : 1)
        .task { await load() }
    }

    /// Fetch the conversation's messages, find the target attachment by id, and
    /// resolve to `.content` (decoded text) or `.missing`. Never logs the
    /// filename or content — a metadata-only found/missing breadcrumb.
    private func load() async {
        let messages = (try? await store.fetchMessages(for: conversationID)) ?? []
        guard let attachment = messages
                .first(where: { $0.id == messageID })?
                .attachments.first(where: { $0.id == attachmentID }) else {
            WatchLog.info(.nav, "attachment.view", ["found": false])
            phase = .missing
            return
        }
        let title = attachment.filename ?? String(localized: LocalizedStringResource(
            "watch.attachment.untitled",
            defaultValue: "Attached file"
        ))
        // Inline text file: the decoded bytes ride the snapshot directly.
        if let text = attachment.extractedText {
            WatchLog.info(.nav, "attachment.view", ["found": true, "preview": false])
            phase = .content(title: title, text: text, isPreview: false)
            return
        }
        // Server-reference text PREVIEW: the snapshot deliberately omits the
        // preview bytes, so fault the single blob on demand. The `.loading` phase
        // stays up across this await (never pre-set `.missing`), so a slow local
        // fetch shows the spinner rather than flashing the missing state.
        // CloudKit can sync `previewKind` before the blob arrives — a nil result
        // with `hasTextPreview` true is exactly that, and resolves to `.missing`.
        if attachment.hasTextPreview,
           let preview = await store.fetchPreviewText(messageID: messageID, attachmentID: attachmentID) {
            WatchLog.info(.nav, "attachment.view", ["found": true, "preview": true])
            phase = .content(title: title, text: preview, isPreview: true)
            return
        }
        WatchLog.info(.nav, "attachment.view", ["found": false])
        phase = .missing
    }
}

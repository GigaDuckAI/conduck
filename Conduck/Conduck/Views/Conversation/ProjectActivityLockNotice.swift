// SPDX-License-Identifier: Apache-2.0

// Conduck
// ProjectActivityLockNotice.swift
//
// A project thread that cannot take a new turn: the reason, and a way to
// Work. It sits ABOVE the composer on every platform and the composer stays
// mounted — the Mac bar owns its staged attachments in view state and tears
// them down on disappear, and the iOS container would drop a recording's
// Stop button mid-capture and reset its resolved route under preserved
// staging. The hosts' send paths refuse instead, with the same sentence, so
// the draft, the staging and a capture in flight all survive the lock and
// the unlock.
//
// Shaped like the Work workspace's own paused-project line
// (`WorkDeskConversationView`), which is where the person will have seen it
// first.

import SwiftUI

struct ProjectActivityLockNotice: View {
    let refusal: WorkProjectAccessError
    /// Nil when no Work route is reachable from this host.
    let onShowInWork: (() -> Void)?

    private var reason: ProjectActivityRefusalCopy { ProjectActivityRefusalCopy(refusal) }

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: reason.sentence)
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            if let onShowInWork {
                Button(action: onShowInWork) {
                    Text(String(localized: "conversations.thread.showInWork", defaultValue: "Show in Work"))  // xcstrings: chat-ui
                }
                .accessibilityLabel(Text(verbatim: reason.accessibilityLabel))
                .accessibilityHint(Text(verbatim: reason.accessibilityHint))
                .accessibilityIdentifier(reason.accessibilityIdentifier)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayFileTransferPage.swift
//
// Agent File Transfer. The file-transfer setup as a PUSHED page: the
// gateway editor's "File transfer" nav row lands here (NavigationLink from
// `RemoteAgentConfigBody`), hosting the shared `FileTransferSetupContent`. Only
// reachable for a SAVED gateway — the editor gates the row on that, so this
// page never needs a "save the gateway first" state.
//
// The composer's mid-attach `.needsSetup` path presents the SAME content as a
// sheet (`FileTransferSetupGuideView`); this page is the Settings-side home.
// The content is a buffered EDITOR and brings its own Cancel/title/Save chrome
// (`bufferedEditorChrome` — which also hides the macOS window-toolbar back
// chevron, exactly like the gateway editor one level up); this host adds only
// the macOS content rail / iOS title.

import SwiftUI

/// Pushed file-transfer destination for a saved gateway.
struct GatewayFileTransferPage: View {
    @Bindable var viewModel: SettingsViewModel
    let ref: RemoteAgentRef

    var body: some View {
        #if os(macOS)
        // Full-width scroll surface, railed CONTENT (`MacSettingsRail`) — a
        // `.frame(maxWidth:)` on the form left a wide window's margins as dead,
        // unscrollable glass.
        GeometryReader { geo in
            FileTransferSetupContent(viewModel: viewModel, ref: ref)
                .contentMargins(.horizontal, MacSettingsRail.margin(for: geo.size.width), for: .scrollContent)
                .contentMargins(.top, 8, for: .scrollContent)
                .contentMargins(.bottom, 28, for: .scrollContent)
        }
        #else
        // Title (nav bar) comes from the content itself — its `resolvedTitle`
        // defaults to "File transfer" when no override is passed.
        FileTransferSetupContent(viewModel: viewModel, ref: ref)
        #endif
    }
}

// MARK: - GatewayFileLaneStatus display

/// User-facing label / meaning / tint for the file-lane status — the page's
/// status section and the editor's nav-row badge both read these, so the two
/// surfaces can't drift.
extension GatewayFileLaneStatus {
    /// nil for `.unsupported` — that state has no file-transfer surface at all
    /// (the editor hides the row), so a badge for it could only ever be dead copy.
    var shortLabel: LocalizedStringResource? {
        switch self {
        case .ready:
            return LocalizedStringResource("fileTransfer.status.ready.short", defaultValue: "Ready")
        case .needsAttention:
            return LocalizedStringResource("fileTransfer.status.needsAttention.short", defaultValue: "Needs attention")
        case .saved:
            return LocalizedStringResource("fileTransfer.status.saved.short", defaultValue: "Not tested yet")
        case .recommended:
            return LocalizedStringResource("fileTransfer.status.recommended.short", defaultValue: "Recommended")
        case .optional:
            return LocalizedStringResource("fileTransfer.status.optional.short", defaultValue: "Optional")
        case .unsupported:
            return nil
        }
    }

    /// Plain-English meaning of the badge. `.ready` is deliberately precise about
    /// WHAT was proven — a passing staged test proves uploads land on the server,
    /// not that the agent is looking in the folder they landed in (nothing on the
    /// device can prove that; see the setup explanation).
    var meaning: LocalizedStringResource? {
        switch self {
        case .ready:
            return LocalizedStringResource(
                "fileTransfer.status.ready.meaning",
                defaultValue: "Tested: Conduck can upload files to this server and read them back."
            )
        case .needsAttention:
            return LocalizedStringResource(
                "fileTransfer.status.needsAttention.meaning",
                defaultValue: "The last test failed. Files won't reach this gateway until it passes."
            )
        case .saved:
            return LocalizedStringResource(
                "fileTransfer.status.saved.meaning",
                defaultValue: "An address and password are saved, but nothing has been tested yet. Run the test — a saved lane that was never tested is a lane that fails at the worst moment."
            )
        case .recommended:
            return LocalizedStringResource(
                "fileTransfer.status.recommended.meaning",
                defaultValue: "Recommended: this gateway runs an agent with file tools, so it can actually work with the files you send it."
            )
        case .optional:
            return LocalizedStringResource(
                "fileTransfer.status.optional.meaning",
                defaultValue: "Optional: this gateway chats fine without it. Set it up only if you want to send files."
            )
        case .unsupported:
            return nil
        }
    }

    var tint: Color {
        switch self {
        case .ready: return AppColors.success
        case .needsAttention: return AppColors.error
        case .recommended: return AppColors.brandAmber
        case .saved, .optional, .unsupported: return AppColors.textTertiary
        }
    }
}

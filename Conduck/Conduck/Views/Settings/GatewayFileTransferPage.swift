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
// The content is a buffered EDITOR and brings its own Back/title/Save chrome
// (`bufferedEditorChrome` with `exit: .back` — which also hides the macOS
// window-toolbar back chevron and supplies its own, exactly like the gateway
// editor one level up). The composer's sheet presentation of the same content
// renders Cancel instead, being the root of its own stack rather than a push.
//
// This host adds NOTHING of its own. The content's `PlatformSettingsForm` owns
// the whole macOS page chrome — its own scroll surface, the window gutter and
// the settings rail — so a host-side `contentMargins` rail here would inset a
// column that is already railed, and give this page a different one from every
// other settings screen.

import SwiftUI

/// Pushed file-transfer destination for a saved gateway.
struct GatewayFileTransferPage: View {
    @Bindable var viewModel: SettingsViewModel
    let ref: RemoteAgentRef

    var body: some View {
        // Title (iOS nav bar) comes from the content itself — its `resolvedTitle`
        // defaults to "File transfer" when no override is passed — and the macOS
        // page chrome comes from its `PlatformSettingsForm`. Nothing is left for
        // this host to add on either platform.
        FileTransferSetupContent(viewModel: viewModel, ref: ref)
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
            return LocalizedStringResource("fileTransfer.status.ready.short", defaultValue: "Server tested")
        case .readyUploadsOnly:
            return LocalizedStringResource(
                "fileTransfer.status.uploadsOnly.short", defaultValue: "Uploads only")
        case .needsAttention:
            return LocalizedStringResource("fileTransfer.status.needsAttention.short", defaultValue: "Needs attention")
        case .saved:
            // "Test required", not "not tested yet". A lane whose staged test FAILED
            // lands back in `.saved` (availability revoked) and, once the session's
            // result is gone, is indistinguishable from one nobody ever tested — so
            // the history claim is not knowable, while the remedy always is.
            return LocalizedStringResource("fileTransfer.status.saved.short.v2", defaultValue: "Test required")
        case .recommended:
            return LocalizedStringResource("fileTransfer.status.recommended.short", defaultValue: "Recommended")
        case .optional:
            return LocalizedStringResource("fileTransfer.status.optional.short", defaultValue: "Optional")
        case .unsupported:
            return nil
        }
    }

    /// Plain-English meaning of the badge.
    ///
    /// `.ready` claims ONLY what this badge durably knows: a test file went up
    /// and came back. It deliberately does NOT claim that files can come the
    /// other way, even though a passing listing stage would prove it — the badge
    /// is derived from PERSISTED state, and the only listing outcome that
    /// persists is the structural refusal below. A green badge asserting "listed
    /// a folder" would therefore go on asserting it after a relaunch on a lane
    /// whose listing probe timed out and proved nothing. The live staged result
    /// says more, on the screen where it is still in hand.
    ///
    /// `.readyUploadsOnly` is the third answer and borrows neither of the other
    /// two: it names what works FIRST, then what does not, and it ends by saying
    /// where the files still are — a user whose server cannot list folders has
    /// not lost their files, only the automatic delivery of them.
    var meaning: LocalizedStringResource? {
        switch self {
        case .ready:
            return LocalizedStringResource(
                "fileTransfer.status.ready.meaning",
                defaultValue: "Conduck uploaded and retrieved a test file."
            )
        case .readyUploadsOnly:
            return LocalizedStringResource(
                "fileTransfer.status.uploadOnly.meaning",
                defaultValue: "Conduck uploaded a test file and read it back. This server can't list folders, so files the agent creates won't come back on their own — you'll still find them on the server."
            )
        case .needsAttention:
            return LocalizedStringResource(
                "fileTransfer.status.needsAttention.meaning",
                defaultValue: "The last server test failed."
            )
        case .saved:
            return LocalizedStringResource(
                "fileTransfer.status.saved.meaning",
                defaultValue: "The address and password are saved. Test the server before sending files."
            )
        case .recommended:
            return LocalizedStringResource(
                "fileTransfer.status.recommended.meaning",
                defaultValue: "Set up a file server so this agent can work with files."
            )
        case .optional:
            return LocalizedStringResource(
                "fileTransfer.status.optional.meaning",
                defaultValue: "Set this up only if you want this gateway to use files."
            )
        case .unsupported:
            return nil
        }
    }

    /// Screen-level status copy is more explicit than the compact badge used by
    /// the parent gateway editor. In particular, a green result names the file
    /// SERVER rather than claiming the agent can already use the uploaded file.
    var pageTitle: LocalizedStringResource? {
        switch self {
        case .ready:
            return LocalizedStringResource(
                "fileTransfer.status.ready.title",
                defaultValue: "File server tested"
            )
        case .readyUploadsOnly:
            return LocalizedStringResource(
                "fileTransfer.status.uploadOnly.title",
                defaultValue: "File server tested — uploads only"
            )
        case .needsAttention:
            return LocalizedStringResource(
                "fileTransfer.status.needsAttention.title",
                defaultValue: "Server test failed"
            )
        case .saved:
            // Same reason as `shortLabel` — a failed test plus a relaunch derives
            // this state, so "not tested" is a claim the app cannot back.
            return LocalizedStringResource(
                "fileTransfer.status.saved.title.v2",
                defaultValue: "File server test required"
            )
        case .recommended:
            return LocalizedStringResource(
                "fileTransfer.status.recommended.title",
                defaultValue: "Set up file transfer"
            )
        case .optional:
            return LocalizedStringResource(
                "fileTransfer.status.optional.title",
                defaultValue: "File transfer not set up"
            )
        case .unsupported:
            return nil
        }
    }

    var systemImage: String? {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .readyUploadsOnly: return "exclamationmark.triangle.fill"
        case .needsAttention: return "xmark.circle.fill"
        // NOT a clock. A clock means "pending, wait for it"; this state means "act" —
        // the lane is saved, uploads are off until a test passes, and the same state
        // is where a FAILED test lands once its session result is gone. The copy was
        // changed from a waiting statement ("Not tested yet") to a demand ("Test
        // required"), and a glyph telling the user to sit tight contradicts it.
        case .saved: return "exclamationmark.circle"
        case .recommended, .optional: return "externaldrive.badge.plus"
        case .unsupported: return nil
        }
    }

    var tint: Color {
        switch self {
        case .ready: return AppColors.success
        // Amber, never green and never red: the lane works, and half of what
        // the user set it up for does not.
        case .readyUploadsOnly: return AppColors.warning
        case .needsAttention: return AppColors.error
        case .recommended: return AppColors.brandAmber
        case .saved, .optional, .unsupported: return AppColors.textTertiary
        }
    }
}

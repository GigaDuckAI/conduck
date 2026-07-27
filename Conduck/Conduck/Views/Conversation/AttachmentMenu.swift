// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentMenu.swift
//
// The LEADING attach affordance: a `paperclip` button opening a SwiftUI
// `Menu` (NOT `confirmationDialog` — lighter, non-blocking, supports SF
// Symbols, and never steals the trailing mic↔send morph's edge). Placed on the
// LEADING edge so the fragile trailing morph stays untouched.
//
// Device-aware ordering (key UX decision #2):
//   - iPhone  : Take Photo · Photo Library · Choose Files…
//   - iPad    : Photo Library · Choose Files… · Take Photo
//   - macOS   : Choose Files… · Photo Library   (no camera)
//
// "Choose Files…" is the SINGLE unified document importer (replaces the old
// split of text-only "Choose Files" + a file-transfer-gated "Add File") — it
// accepts ANY file and the host's classifier routes each pick (image → inline
// vision; text → inline/dual; binary → server, or a `.needsSetup` tile when the
// bound gateway has no file-server). When file transfer is NOT set up, a
// separate "Set Up File Transfer…" item appears in its own section for
// proactive discovery (hidden once a server is configured).
//
// "Take Photo" is REMOVED from the menu (not disabled) when the device has no
// camera (`UIImagePickerController.isSourceTypeAvailable(.camera)` false) — and
// removed from the a11y tree with it. The item is `#if os(iOS)` gated so the
// macOS build never references UIKit camera APIs.
//
// This view is presentation only: the HOST owns the actual `.photosPicker` /
// `.fileImporter` / camera `.fullScreenCover` modifiers and wires them to the
// `onPickLibrary` / `onTakePhoto` / `onPickFiles` callbacks fired here.

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct AttachmentMenu: View {
    /// Open the system photo library picker (`PhotosPicker` host-side).
    let onPickLibrary: () -> Void
    /// Present the camera capture sheet (iOS only; the item is hidden on macOS
    /// and on iOS devices with no camera).
    let onTakePhoto: () -> Void
    /// Open the UNIFIED document picker (`.fileImporter`) — accepts ANY file. The
    /// host's classifier routes each pick (image → inline; text → inline/dual;
    /// binary → server, or a `.needsSetup` tile when no file-server is configured).
    let onPickFiles: () -> Void
    /// Open the file-transfer setup guide (`FileTransferSetupGuideView` as a sheet)
    /// scoped to the bound gateway. Fired by the "Set Up File Transfer…" item —
    /// itself shown only when `fileTransferAvailable` is false (proactive
    /// discovery). Default no-op so existing call sites still compile.
    var onSetUpFileTransfer: () -> Void = {}
    /// True when the conversation's bound gateway has a usable file-server
    /// snapshot — when FALSE the menu surfaces a "Set Up File Transfer…" item in
    /// its own section for proactive discovery (hidden once a server is
    /// configured). Default false so the discovery item shows until a host wires
    /// file-transfer state in.
    var fileTransferAvailable: Bool = false
    /// Paperclip glyph point size. Default preserves the iOS look; the macOS
    /// composer passes a smaller value to match its in-box control row.
    var iconPointSize: CGFloat = 22
    /// Tap-target frame for the paperclip. Default 44 keeps the iOS touch
    /// target; macOS passes a tighter 30.
    var iconFrame: CGFloat = 44

    /// True only on an iOS device with an available camera. Drives whether the
    /// "Take Photo" item is rendered at all (removed, never disabled).
    private var cameraAvailable: Bool {
        #if os(iOS)
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
        return false
        #endif
    }

    var body: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: iconPointSize, weight: .regular))
                .foregroundStyle(AppColors.brandAmber)
                .frame(width: iconFrame, height: iconFrame)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.attach.menu",
            defaultValue: "Add attachment"
        )))
    }

    @ViewBuilder
    private var menuItems: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad order: Photo Library · Choose Files… · Take Photo.
            photoLibraryButton
            chooseFilesButton
            if cameraAvailable { takePhotoButton }
        } else {
            // iPhone order: Take Photo · Photo Library · Choose Files….
            if cameraAvailable { takePhotoButton }
            photoLibraryButton
            chooseFilesButton
        }
        #else
        // macOS order: Choose Files… · Photo Library (no camera).
        chooseFilesButton
        photoLibraryButton
        #endif

        // Proactive discovery: when the bound gateway has NO file-server, offer a
        // dedicated "Set Up File Transfer…" item in its own section (divider). It
        // disappears once a server is configured (a binary then routes straight to
        // the server upload, no setup prompt needed).
        if !fileTransferAvailable {
            Section { setUpFileTransferButton }
        }
    }

    // MARK: - Items

    #if os(iOS)
    private var takePhotoButton: some View {
        Button(action: onTakePhoto) {
            Label(
                LocalizedStringResource("composer.attach.takePhoto", defaultValue: "Take Photo"),
                systemImage: "camera"
            )
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.attach.takePhoto",
            defaultValue: "Take Photo"
        )))
    }
    #endif

    private var photoLibraryButton: some View {
        Button(action: onPickLibrary) {
            Label(
                LocalizedStringResource("composer.attach.photoLibrary", defaultValue: "Photo Library"),
                systemImage: "photo.on.rectangle"
            )
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.attach.photoLibrary",
            defaultValue: "Photo Library"
        )))
    }

    /// The UNIFIED document importer — accepts ANY file. The trailing ellipsis
    /// signals it opens a picker; the a11y label is a SEPARATE key (no trailing
    /// ellipsis) so the visible-label vs a11y-label pair doesn't collide under
    /// `xcstringstool` casing/punctuation symbol generation.
    private var chooseFilesButton: some View {
        Button(action: onPickFiles) {
            Label(
                LocalizedStringResource("composer.attach.chooseFiles.label", defaultValue: "Choose Files…"),
                systemImage: "doc"
            )
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.attach.chooseFiles.a11y",
            defaultValue: "Choose files"
        )))
    }

    /// "Set Up File Transfer…" — proactive discovery shown only when the bound
    /// gateway has NO file-server. Opens `FileTransferSetupGuideView` as a sheet
    /// (host-owned), scoped to that gateway. The trailing ellipsis signals it
    /// opens a guide; the a11y label is a SEPARATE key (no ellipsis) to avoid an
    /// `xcstringstool` casing/punctuation collision.
    private var setUpFileTransferButton: some View {
        Button(action: onSetUpFileTransfer) {
            Label(
                LocalizedStringResource("fileTransfer.attach.setUp.label", defaultValue: "Set Up File Transfer…"),
                systemImage: "arrow.up.doc"
            )
        }
        .accessibilityLabel(Text(LocalizedStringResource(
            "fileTransfer.attach.setUp.a11y",
            defaultValue: "Set up file transfer"
        )))
    }
}

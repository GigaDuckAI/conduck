// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentPreviewStrip.swift
//
// The horizontal strip of staged-but-unsent attachments shown ABOVE the
// composer field. Renders:
//   - image tiles  : 64×64 rounded thumbnail (`UIImage(data:)` / `NSImage`)
//   - file chips   : color-coded by extension (icon + filename + size)
//   - loading tile : determinate `ProgressView(value:)` while a PhotosPicker
//                    `loadTransferable` (Progress overload) fetch is in flight
//   - error badge  : per-tile (a sibling failing never sinks the others)
// Each tile has an X-to-remove overlay. The strip is ZERO-HEIGHT when empty
// (no reserved space), and slides in with a spring + move(.top)+opacity so the
// thread doesn't hitch. Handles unbounded N (no cap — key UX decision #4/#8).
//
// Per-tile load progress is host-owned: the host drives `progressByID` from the
// `PhotosPickerItem.loadTransferable(type:completionHandler:)` Progress return,
// and the strip renders the determinate bar from it (falls back to an
// indeterminate spinner if no value yet).

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct AttachmentPreviewStrip: View {
    /// Staged items (host-owned). Empty → the strip renders nothing (0 height).
    let attachments: [StagedAttachment]
    /// Determinate load fraction (0…1) per loading item id; host-driven from
    /// the `loadTransferable` Progress. Missing id → indeterminate spinner.
    var progressByID: [UUID: Double] = [:]
    /// Remove a staged item by id (the X overlay).
    let onRemove: (UUID) -> Void
    /// Re-kick the eager background upload for a `.serverFile` tile whose PUT
    /// failed (`serverUploadState == .failed`). Host re-uploads the same staging
    /// file under the same deterministic `storedKey` (same server path). Default
    /// no-op so existing call sites that never stage server files still compile.
    var onRetryUpload: (UUID) -> Void = { _ in }
    /// Open the file-transfer setup guide for a `.needsSetup` tile (the inline
    /// "Set Up" button). The host presents `FileTransferSetupGuideView` as a sheet
    /// scoped to the bound gateway, then auto-promotes the tile once setup lands.
    /// Default no-op so existing call sites that never stage `.needsSetup` compile.
    var onSetUp: (UUID) -> Void = { _ in }

    private let tileSize: CGFloat = 64

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(attachments) { item in
                        tile(for: item)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
            }
            .frame(height: tileSize + 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Tile dispatch

    @ViewBuilder
    private func tile(for item: StagedAttachment) -> some View {
        switch item.kind {
        case .loading:
            loadingTile(id: item.id)
                .overlay(alignment: .topTrailing) { removeButton(id: item.id) }
        case .image(let data):
            imageTile(data: data)
                .overlay(alignment: .topTrailing) { removeButton(id: item.id) }
        case .dualImage(let original, _, _, _, _, _, _):
            // A dual-route image renders as a plain image tile (its eager
            // file-server upload runs silently in the background and NEVER gates
            // Send, so no upload-progress chrome is shown — the inline base64 is
            // always a guaranteed fallback). The thumbnail decodes from the
            // ORIGINAL picked bytes (already in memory; no re-decode of the
            // processed JPEG needed for a 64pt preview).
            imageTile(data: original)
                .overlay(alignment: .topTrailing) { removeButton(id: item.id) }
        case .file(let url):
            fileChip(url: url)
                .overlay(alignment: .topTrailing) { removeButton(id: item.id) }
        case .dualText(_, let extractedText, let filename, _):
            // A dual-route text file renders as a plain file chip (its eager
            // file-server upload runs silently in the background and NEVER gates
            // Send — the inline fenced text is always a guaranteed fallback — so no
            // upload-progress chrome is shown, exactly like `.dualImage`). The
            // display name + size come from the staged extraction, not the
            // throwaway staging URL's last path component.
            dualTextChip(filename: filename, byteCount: extractedText.lengthOfBytes(using: .utf8))
                .overlay(alignment: .topTrailing) { removeButton(id: item.id) }
        case .serverFile(_, let originalName, let mimeType):
            serverFileTile(
                id: item.id,
                originalName: originalName,
                mimeType: mimeType,
                state: item.serverUploadState
            )
            .overlay(alignment: .topTrailing) { removeButton(id: item.id) }
        case .needsSetup(_, let originalName, _, let byteSize):
            needsSetupTile(id: item.id, originalName: originalName, byteSize: byteSize)
                .overlay(alignment: .topTrailing) { removeButton(id: item.id) }
        case .failed:
            failedTile()
                .overlay(alignment: .topTrailing) { removeButton(id: item.id) }
        }
    }

    // MARK: - Image tile

    @ViewBuilder
    private func imageTile(data: Data) -> some View {
        Group {
            if let image = Image.platformImage(from: data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderGlyph("photo")
            }
        }
        .frame(width: tileSize, height: tileSize)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.attach.imageTile",
            defaultValue: "Attached image"
        )))
    }

    // MARK: - Loading tile

    private func loadingTile(id: UUID) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
            if let value = progressByID[id] {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .tint(AppColors.brandAmber)
                    .padding(.horizontal, 10)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.attach.loadingTile",
            defaultValue: "Loading attachment"
        )))
    }

    // MARK: - Failed tile

    private func failedTile() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.error.opacity(0.15))
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(AppColors.error)
        }
        .frame(width: tileSize, height: tileSize)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.error.opacity(0.5), lineWidth: 1)
        )
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.attach.failedTile",
            defaultValue: "Attachment failed to load"
        )))
    }

    // MARK: - File chip

    private func fileChip(url: URL) -> some View {
        let ext = url.pathExtension
        let symbol = AttachmentChipStyle.symbol(forExtension: ext)
        let tint = AttachmentChipStyle.tint(forExtension: ext)
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if size > 0 {
                    Text(AttachmentChipStyle.formattedSize(size))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: tileSize)
        .frame(maxWidth: 180)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(
            format: String(localized: LocalizedStringResource(
                "composer.attach.fileChip",
                defaultValue: "Attached file %@"
            )),
            name
        )))
    }

    // MARK: - Dual-text chip (inline fenced text + silent file-server upload)

    /// A staged DUAL-route text file: it rides inline as fenced text AND uploads
    /// silently to the file-server (so the agent's tools reach the real file). It
    /// looks IDENTICAL to a plain `fileChip` (same glyph/size styling), but its
    /// name + size come from the staged extraction (not the throwaway staging URL)
    /// and it shows NO upload-progress chrome — the upload never gates Send.
    private func dualTextChip(filename: String, byteCount: Int) -> some View {
        let ext = (filename as NSString).pathExtension
        let symbol = AttachmentChipStyle.symbol(forExtension: ext)
        let tint = AttachmentChipStyle.tint(forExtension: ext)

        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if byteCount > 0 {
                    Text(AttachmentChipStyle.formattedSize(byteCount))
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: tileSize)
        .frame(maxWidth: 180)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(
            format: String(localized: LocalizedStringResource(
                "composer.attach.fileChip",
                defaultValue: "Attached file %@"
            )),
            filename
        )))
    }

    // MARK: - Server-file tile (file-transfer route)

    /// A staged arbitrary file bound for the agent's working folder via the
    /// file-server route (PDF / CSV / zip / …). Same 64pt footprint + glyph
    /// styling as `fileChip`, but the size line is replaced by the eager-upload
    /// state chrome driven by `state`:
    ///   - `.uploading(p)` : a determinate `ProgressView(value:)` ring tinted
    ///     brandAmber (the PUT is climbing).
    ///   - `.failed`       : an error badge + a small inline Retry button that
    ///     re-kicks the upload under the same deterministic `storedKey`.
    ///   - `.uploaded` / nil: a subtle success check.
    /// Send is gated by the host while ANY server tile is `.uploading` /
    /// `.failed` (strict send-gating — `Array.hasUploadingItem` /
    /// `hasFailedUpload`).
    private func serverFileTile(
        id: UUID,
        originalName: String,
        mimeType: String,
        state: StagedAttachment.ServerFileUploadState?
    ) -> some View {
        let ext = (originalName as NSString).pathExtension
        let symbol = AttachmentChipStyle.symbol(forExtension: ext)
        let tint = AttachmentChipStyle.tint(forExtension: ext)
        // Error chrome covers BOTH failure states — a refusal is no less a
        // failure for being unretryable.
        let isFailed: Bool = {
            switch state {
            case .failed, .refused: return true
            case .uploading, .uploaded, .none: return false
            }
        }()
        // The a11y label takes `detail` (cause + remedy), never `reason` — see
        // `ServerFileUploadState.refused`.
        let refusalDetail: String? = { if case .refused(_, let detail) = state { return detail } else { return nil } }()

        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(isFailed ? AppColors.error : tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(originalName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                serverUploadStateChrome(id: id, state: state)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: tileSize)
        .frame(maxWidth: 180)
        .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((isFailed ? AppColors.error : tint).opacity(isFailed ? 0.5 : 0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        // The refusal rides the label in FULL — cause AND remedy. The visible
        // line truncates in a 180pt tile and can only carry the cause; VoiceOver
        // has no width to run out of, so this is where the remedy (and, for a
        // pin mismatch, the interception warning) actually reaches the user.
        .accessibilityLabel(Text(([
            String(
                format: String(localized: LocalizedStringResource(
                    "fileTransfer.attach.serverTile",
                    defaultValue: "Attached file %@ for your file server"
                )),
                originalName
            ),
            refusalDetail
        ] as [String?]).compactMap { $0 }.joined(separator: ". ")))
    }

    /// The state row under a server-file tile's name: the determinate upload
    /// bar, the failed-with-Retry affordance, the refusal's own sentence, or the
    /// success check.
    @ViewBuilder
    private func serverUploadStateChrome(
        id: UUID,
        state: StagedAttachment.ServerFileUploadState?
    ) -> some View {
        switch state {
        case .uploading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(AppColors.brandAmber)
                .frame(width: 110)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "fileTransfer.attach.uploading",
                    defaultValue: "Uploading to your file server"
                )))
        case .failed:
            Button {
                onRetryUpload(id)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                    Text(LocalizedStringResource("fileTransfer.attach.retry", defaultValue: "Retry"))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppColors.error)
            }
            .inlineLinkButton()
            .accessibilityLabel(Text(LocalizedStringResource(
                "fileTransfer.attach.retry",
                defaultValue: "Retry"
            )))
        case .refused(let reason, _):
            // The refusal's OWN words, not a strip-local paraphrase — the tile is
            // narrow, so this shows the CAUSE only and still truncates, but
            // truncated canonical copy beats a fifth wording for one cause. The
            // remedy rides the tile's accessibility label, which has the room.
            // NO Retry: the same request would be refused the same way.
            //
            // Cause-only is the deliberate exception to the app-wide rule, NOT an
            // oversight: at 180pt clipped to two lines there is no wording of any
            // remedy that survives, and a pin mismatch's warning sits at the end
            // of its remedy — first to be cut. The decision and the compensating
            // control are registered in `ErrorSurfaceDriftGuardTests`
            // (`compensatedCauseOnlySurfaces`), which fails if the a11y label that
            // carries the full verdict is ever removed. Change one, change both.
            Text(verbatim: reason)
                .font(.caption2)
                .foregroundStyle(AppColors.error)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        case .uploaded, .none:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(AppColors.success)
                .accessibilityLabel(Text(LocalizedStringResource(
                    "fileTransfer.attach.uploaded",
                    defaultValue: "Uploaded to your file server"
                )))
        }
    }

    // MARK: - Needs-setup tile (binary picked with no file-server configured)

    /// A binary (PDF / video / zip / …) picked or dropped for a gateway with NO
    /// file-server configured. There's no wire route for it, so instead of a
    /// silent doomed stage this tile TEACHES + UNBLOCKS: amber/info chrome (NOT
    /// `AppColors.error` — this is guidance, not a failure), the file glyph + name,
    /// a "Needs file transfer" sublabel, and an inline **Set Up** button that opens
    /// the setup guide. Send is gated (`hasNeedsSetupItem`) until file transfer is
    /// set up (the host then auto-promotes this to a `.serverFile` upload) or the
    /// user removes the tile.
    private func needsSetupTile(id: UUID, originalName: String, byteSize: Int) -> some View {
        let ext = (originalName as NSString).pathExtension
        let symbol = AttachmentChipStyle.symbol(forExtension: ext)

        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(AppColors.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(originalName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(LocalizedStringResource(
                    "fileTransfer.needsSetup.sublabel",
                    defaultValue: "Needs file transfer"
                ))
                .font(.caption2)
                .foregroundStyle(AppColors.warning)
                Button {
                    onSetUp(id)
                } label: {
                    Text(LocalizedStringResource(
                        "fileTransfer.needsSetup.setUp",
                        defaultValue: "Set Up"
                    ))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.brandAmber)
                }
                .inlineLinkButton()
                .accessibilityLabel(Text(LocalizedStringResource(
                    "fileTransfer.needsSetup.setUp.a11y",
                    defaultValue: "Set up file transfer"
                )))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: tileSize)
        .frame(maxWidth: 200)
        .background(AppColors.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.warning.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(
            format: String(localized: LocalizedStringResource(
                "fileTransfer.needsSetup.tile.a11y",
                defaultValue: "File %@ needs file transfer set up"
            )),
            originalName
        )))
    }

    // MARK: - Remove overlay

    private func removeButton(id: UUID) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                onRemove(id)
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, AppColors.background.opacity(0.75))
                .background(Circle().fill(AppColors.background.opacity(0.001)))
                .contentShape(Circle())
        }
        // The badge is drawn as a circle, so the hover wash is one too — a
        // rounded square would halo its corners against the thumbnail.
        .pointerIconButton(shape: .circle)
        .offset(x: 6, y: -6)
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.attach.remove",
            defaultValue: "Remove attachment"
        )))
    }

    // MARK: - Helpers

    private func placeholderGlyph(_ symbol: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(AppColors.textTertiary)
        }
    }

}

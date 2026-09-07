// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardMaterialListRow.swift
//
// The desk's compact alternative to mosaic cards. A steady thumbnail column,
// readable preview and visible actions make a long desk easier to scan. The
// board owns dragging and order; this row only marks the grip and exposes the
// same moves to keyboard and VoiceOver users. Card sizes remain a tile concern.
//
// Audio keeps the card family's player, lazy payload read and output ownership:
// changing presentation must not introduce a second audio session or make a
// recording unplayable. The player dies when the row leaves the screen, including
// a switch back to tiles. A persistent workbench may hide this view without
// removing it, so destination changes also cancel playback and pending reads.
// Availability gates every action through the same policy as the mosaic, so a
// thumbnail never stands in for missing bytes.

import SwiftUI

struct WorkboardMaterialListRow: View {
    let material: WorkboardMaterialSnapshot
    var boardPosition: Int = 0
    var boardCount: Int = 0
    let onOpen: () -> Void
    var onShare: (() -> Void)?
    var onReattach: (() -> Void)?
    var onMoveEarlier: (() -> Void)?
    var onMoveLater: (() -> Void)?
    var onRemove: (() -> Void)?

    @Environment(\.workbenchDestinationIsActive) private var workbenchDestinationIsActive
    @State private var player = WorkboardAudioCardPlayer()

    private static let cornerRadius: CGFloat = 13

    var body: some View {
        ZStack(alignment: .trailing) {
            if let primaryAction {
                Button(action: primaryAction) { rowContent }
                    .choiceCardButton(cornerRadius: Self.cornerRadius)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityAddTraits(playbackTraits)
                    .accessibilityActions { accessibilityActions }
            } else {
                rowContent
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityActions { accessibilityActions }
            }

            HStack(spacing: 0) {
                rowMenu
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(width: 20)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.trailing, 8)
        }
        .contextMenu { menuContent }
        .onDisappear { player.deactivate() }
        .onChange(of: workbenchDestinationIsActive) { _, isActive in
            if !isActive { player.deactivate() }
        }
        .onChange(of: material.availability) { _, availability in
            if !WorkboardCardActionPolicy.allows(.play, when: availability) {
                player.deactivate()
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: material.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .truncationMode(.middle)

                preview
                metadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 76)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            AppColors.cardBackgroundElevated,
            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if material.kind == .image, let data = material.thumbnailData {
            StagedImageTile(
                id: material.id,
                data: data,
                maxPixel: ImageProcessor.thumbnailMaxPixel,
                cacheVersion: material.revision
            ) {
                artworkPlaceholder
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        Image(systemName: material.kind == .audio ? audioSymbol : WorkboardMaterialIcon.symbol(for: material))
            .font(.system(size: 21, weight: material.kind == .audio ? .semibold : .regular))
            .foregroundStyle(WorkboardMaterialIcon.tint(for: material))
            .frame(width: 48, height: 48)
            .background(
                AppColors.backgroundSecondary,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var preview: some View {
        if let audioStatus {
            Text(audioStatus)
                .font(.caption)
                .foregroundStyle(player.phase == .failed ? AppColors.warning : AppColors.textSecondary)
                .lineLimit(2)
        } else if let previewText, !previewText.isEmpty {
            Text(verbatim: previewText)
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
        }
        if material.kind == .audio, player.duration > 0 {
            HStack(spacing: 8) {
                ProgressView(value: player.fraction)
                    .tint(AppColors.brandAmber)
                    .accessibilityHidden(true)
                Text(verbatim: clockText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize()
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(material.kind.title)
                if let byteCount = material.byteCount {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                }
                Spacer(minLength: 0)
                Text(material.createdAt, format: .relative(presentation: .named))
            }
            .font(.caption2)
            .foregroundStyle(AppColors.textTertiary)
            .lineLimit(1)

            if let availabilityLabel {
                Label(availabilityLabel, systemImage: availabilitySymbol)
                    .font(.caption2)
                    .foregroundStyle(availabilityTint)
                    .lineLimit(2)
            }
        }
    }

    private var rowMenu: some View {
        Menu {
            menuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: WorkboardMetrics.touchTarget, height: WorkboardMetrics.touchTarget)
        }
        .pointerIconButton(size: WorkboardMetrics.touchTarget, shape: .circle)
        .help(String(localized: LocalizedStringResource(
            "workboard.material.card.more", defaultValue: "Card actions"
        )))
        // All menu actions are available directly on the accessible row.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var menuContent: some View {
        if isPlayable {
            Button(action: toggleAudio) {
                Label(transportTitle, systemImage: transportSymbol)
            }
        }
        if WorkboardCardActionPolicy.allows(.open, when: material.availability) {
            Button(action: onOpen) {
                Label(LocalizedStringResource("workboard.material.open", defaultValue: "Open"), systemImage: "arrow.up.forward.app")
            }
            if let onShare {
                Button(action: onShare) {
                    Label(LocalizedStringResource("workboard.material.share", defaultValue: "Share"), systemImage: "square.and.arrow.up")
                }
            }
        }
        if WorkboardCardActionPolicy.allows(.reattach, when: material.availability), let onReattach {
            Button(action: onReattach) {
                Label(LocalizedStringResource("workboard.material.reattach.action", defaultValue: "Reattach or Replace"), systemImage: "paperclip")
            }
        }
        if onMoveEarlier != nil || onMoveLater != nil {
            Divider()
            if let onMoveEarlier {
                Button(action: onMoveEarlier) {
                    Label(LocalizedStringResource("workboard.action.moveEarlier", defaultValue: "Move Earlier"), systemImage: "arrow.up")
                }
            }
            if let onMoveLater {
                Button(action: onMoveLater) {
                    Label(LocalizedStringResource("workboard.action.moveLater", defaultValue: "Move Later"), systemImage: "arrow.down")
                }
            }
        }
        if let onRemove {
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label(LocalizedStringResource("workboard.material.remove.action", defaultValue: "Remove Material"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var accessibilityActions: some View {
        if WorkboardCardActionPolicy.allows(.open, when: material.availability) {
            if material.kind == .audio {
                Button(LocalizedStringResource("workboard.material.open", defaultValue: "Open"), action: onOpen)
            }
            if let onShare {
                Button(LocalizedStringResource("workboard.material.share", defaultValue: "Share"), action: onShare)
            }
        }
        if WorkboardCardActionPolicy.allows(.reattach, when: material.availability), let onReattach {
            Button(LocalizedStringResource("workboard.material.reattach.action", defaultValue: "Reattach or Replace"), action: onReattach)
        }
        if let onMoveEarlier {
            Button(LocalizedStringResource("workboard.action.moveEarlier", defaultValue: "Move Earlier"), action: onMoveEarlier)
        }
        if let onMoveLater {
            Button(LocalizedStringResource("workboard.action.moveLater", defaultValue: "Move Later"), action: onMoveLater)
        }
        if let onRemove {
            Button(LocalizedStringResource("workboard.material.remove.action", defaultValue: "Remove Material"), action: onRemove)
        }
    }

    private var primaryAction: (() -> Void)? {
        if isPlayable { return toggleAudio }
        switch WorkboardCardActionPolicy.primaryAction(for: material.availability) {
        case .open: return onOpen
        case .reattach: return onReattach
        case .play, .none: return nil
        }
    }

    private var isPlayable: Bool {
        material.kind == .audio && WorkboardCardActionPolicy.allows(.play, when: material.availability)
    }

    private func toggleAudio() {
        guard workbenchDestinationIsActive, isPlayable else { return }
        let id = material.id
        player.toggle { try await ConversationStore.shared.loadWorkMaterialPayload(id: id) }
    }

    private var previewText: String? {
        (material.kind == .audio ? material.textContent : WorkboardCardAccessibility.previewText(for: material))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var audioSymbol: String {
        guard isPlayable else { return "icloud.and.arrow.down" }
        switch player.phase {
        case .playing: return "pause.fill"
        case .loading: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .blocked: return "speaker.slash.fill"
        case .idle, .paused: return "play.fill"
        }
    }

    private var transportTitle: LocalizedStringResource {
        switch WorkboardAudioCardPresentation.transportAction(for: player.phase) {
        case .play: return LocalizedStringResource("workboard.audio.play", defaultValue: "Play")
        case .pause: return LocalizedStringResource("workboard.audio.pause", defaultValue: "Pause")
        case .cancelLoading: return LocalizedStringResource("workboard.audio.cancelLoading", defaultValue: "Cancel Loading")
        }
    }

    private var transportSymbol: String {
        switch WorkboardAudioCardPresentation.transportAction(for: player.phase) {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .cancelLoading: return "xmark"
        }
    }

    private var audioStatus: LocalizedStringResource? {
        guard material.kind == .audio else { return nil }
        switch player.phase {
        case .loading: return LocalizedStringResource("workboard.audio.loading", defaultValue: "Loading")
        case .playing: return LocalizedStringResource("workboard.audio.playing", defaultValue: "Playing")
        case .paused: return LocalizedStringResource("workboard.audio.paused", defaultValue: "Paused")
        case .failed: return LocalizedStringResource("workboard.audio.failed", defaultValue: "This recording couldn’t be played")
        case .blocked: return LocalizedStringResource("workboard.audio.busy", defaultValue: "Audio is in use right now")
        case .idle: return nil
        }
    }

    private var clockText: String {
        String.localizedStringWithFormat(
            String(localized: LocalizedStringResource("workboard.audio.position", defaultValue: "%1$@ of %2$@")),
            WorkboardAudioTiming.label(player.elapsed),
            WorkboardAudioTiming.label(player.duration)
        )
    }

    private var availabilityLabel: LocalizedStringResource? {
        guard material.availability != .available else { return nil }
        if material.availability == .unavailableOnThisDevice, onReattach == nil {
            return LocalizedStringResource("workboard.audio.unavailableHere", defaultValue: "Not on this device")
        }
        return WorkboardCardAccessibility.availabilityLabel(for: material.availability)
    }

    private var availabilitySymbol: String {
        switch material.availability {
        case .localOnly: return "internaldrive"
        case .syncPending: return "icloud.and.arrow.down"
        case .available, .unavailableOnThisDevice: return "paperclip.badge.ellipsis"
        }
    }

    private var availabilityTint: Color {
        switch material.availability {
        case .localOnly: return AppColors.brandTeal
        case .syncPending: return AppColors.textTertiary
        case .available, .unavailableOnThisDevice: return AppColors.warning
        }
    }

    private var accessibilityLabel: Text {
        var parts = [String(localized: material.kind.title), material.name]
        if isPlayable { parts.append(String(localized: transportTitle)) }
        if let previewText, !previewText.isEmpty { parts.append(previewText) }
        if boardCount > 0, boardPosition > 0 {
            parts.append(WorkboardCardAccessibility.boardPositionLabel(position: boardPosition, count: boardCount))
        }
        return Text(verbatim: parts.joined(separator: ". "))
    }

    private var accessibilityValue: Text {
        var parts: [String] = []
        if let availabilityLabel { parts.append(String(localized: availabilityLabel)) }
        if let audioStatus { parts.append(String(localized: audioStatus)) }
        if material.kind == .audio, player.duration > 0 { parts.append(clockText) }
        return Text(verbatim: parts.joined(separator: ". "))
    }

    private var playbackTraits: AccessibilityTraits {
        isPlayable && player.willStartPlayback ? [.startsMediaSession] : []
    }
}

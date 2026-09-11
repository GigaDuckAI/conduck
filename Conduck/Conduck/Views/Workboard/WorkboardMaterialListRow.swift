// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardMaterialListRow.swift
//
// The desk's compact alternative to mosaic cards. A steady thumbnail column,
// readable preview and visible actions make a long desk easier to scan. The
// board owns dragging and order; this row only marks the grip and exposes the
// same moves to keyboard and VoiceOver users. There is no footprint to pick:
// the board draws one slot size, so a row offers no card-size control either.
//
// WHAT THE ROW SAYS is not the row's decision. Title, body, the demoted meta
// line and the availability sentence all come from `WorkboardCardFacePolicy`,
// the same policy the mosaic tile and the spoken label read — a row that
// composed its own would be a third place for the desk to describe one card.
//
// Audio keeps the card family's player, lazy payload read and output ownership:
// changing presentation must not introduce a second audio session or make a
// recording unplayable. The player dies when the row leaves the screen, including
// a switch back to tiles. A persistent workbench may hide this view without
// removing it, so destination changes also cancel playback and pending reads.
// Availability gates every action through the same policy as the mosaic, so a
// thumbnail never stands in for missing bytes.
// Personal-desk organization joins the existing action menu; its live observer
// also supplies the project caption within the row's own metadata.
//
// A picture that folded a VOICE MATERIAL into it draws ONE row here too: the
// thumbnail, the voice material's words as the row's text, and the picture's own
// size and date underneath. That voice material is a recording or the words
// alone; only a recording puts a play badge over the thumbnail, because only a
// recording has bytes to reach for. The row's single player is the one that
// plays it — a folded row is never also an audio row, so the two can never both
// want it.

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
    /// Quick Look the recording folded into this picture, and hand that same
    /// recording to the share UI. Both act on the companion alone, through the
    /// single-material coordinators the recording's own card used.
    var onOpenCompanion: (() -> Void)?
    var onShareCompanion: (() -> Void)?
    /// Repair the RECORDING, not the picture: the row's own Reattach replaces
    /// the screenshot, which is the wrong file for a recording that is missing.
    var onReattachCompanion: (() -> Void)?
    var organizationActions: WorkDeskMaterialOrganizationActions? = nil

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
        .workDeskMetadataControls(organizationActions)
        // The recording's own control, over the picture it belongs to. It is a
        // sibling of the row's button rather than content inside it, because a
        // control nested in a button's label never receives the tap — and the
        // row's own tap still opens the picture.
        .overlay(alignment: .leading) { companionTransport }
        .contextMenu { menuContent }
        .onDisappear { player.deactivate() }
        .onChange(of: workbenchDestinationIsActive) { _, isActive in
            if !isActive { player.deactivate() }
        }
        .onChange(of: transportAvailability) { _, availability in
            if !WorkboardCardActionPolicy.allows(.play, when: availability) {
                player.deactivate()
            }
        }
        // A row that stops being about this recording — it unfolded, or the
        // card now holds a different one — stops holding its audio.
        .onChange(of: material.companion?.id) { _, _ in player.deactivate() }
    }

    /// The play/pause badge a folded row draws over its thumbnail. Sized inside
    /// the artwork column's own 48pt square so the picture still shows around
    /// it: the row is about the screenshot, and the recording is a control on
    /// it rather than a replacement for it.
    ///
    /// Drawn only for a RECORDING. A words-only companion has nothing to play,
    /// and a badge over it would be a control that fails on every tap while
    /// hiding part of the picture it sits on.
    @ViewBuilder
    private var companionTransport: some View {
        if let companion = material.companion, companion.kind == .audio {
            WorkboardAudioTransport(
                materialID: companion.id,
                player: player,
                availability: transportAvailability,
                isEnabled: workbenchDestinationIsActive,
                activation: .control,
                dimension: 32,
                placement: .scrim
            )
            .frame(width: 48, height: 48)
            .padding(.leading, 12)
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 4) {
                if let rowTitle {
                    Text(verbatim: rowTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                if let rowIdentity {
                    Text(verbatim: rowIdentity)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

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

    /// Preview bytes the row ALREADY HOLDS, whatever kind wrote them, decoded
    /// and never generated: a PDF that arrived with a thumbnail shows it, and
    /// one that did not keeps its glyph.
    @ViewBuilder
    private var artwork: some View {
        if let data = material.thumbnailData {
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
                .lineLimit(material.companion == nil ? 1 : 2)
        }
        if hasTransport, player.duration > 0 {
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
            WorkboardMaterialNotesIndicator(material: material)
                .foregroundStyle(AppColors.textSecondary)
            if let organizationActions {
                WorkDeskMaterialLocation(actions: organizationActions)
            }
            HStack(spacing: 6) {
                // The face's meta line where it has one — a file's type and
                // size, a picture's size — and the kind's own noun where it
                // does not, so the row never says both about the same card.
                if let meta = face.meta {
                    Text(verbatim: meta)
                } else {
                    Text(material.kind.title)
                }
                Spacer(minLength: 0)
                if face.showsAge {
                    Text(material.createdAt, format: .relative(presentation: .named))
                }
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
        if isPlayable, material.companion == nil {
            Button(action: toggleTransport) {
                Label(transportTitle, systemImage: transportSymbol)
            }
        }
        if WorkboardCardActionPolicy.allows(.details, when: material.availability) {
            Button(action: openMaterial) {
                Label(LocalizedStringResource("workboard.material.open", defaultValue: "Open"), systemImage: "arrow.up.forward.app")
            }
            if WorkboardCardActionPolicy.allows(.open, when: material.availability), let onShare {
                Button(action: onShare) {
                    Label(
                        WorkboardCompanionBand.shareTitle(hasCompanion: material.companion != nil),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
        }
        // The folded row's two files, each named — the same rows the mosaic
        // card offers, from the same one rule.
        ForEach(companionActions, id: \.self) { action in
            Button {
                performCompanionAction(action)
            } label: {
                Label(
                    WorkboardCompanionBand.title(for: action),
                    systemImage: WorkboardCompanionBand.symbol(for: action)
                )
            }
        }
        if WorkboardCardActionPolicy.allows(.reattach, when: material.availability), let onReattach {
            Button(action: onReattach) {
                Label(LocalizedStringResource("workboard.material.reattach.action", defaultValue: "Reattach or Replace"), systemImage: "paperclip")
            }
        }
        if let organizationActions {
            Divider()
            WorkDeskMaterialMenuActions(actions: organizationActions)
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
        if let organizationActions {
            WorkDeskMaterialAccessibilityActions(actions: organizationActions)
        }
        if WorkboardCardActionPolicy.allows(.details, when: material.availability) {
            if material.kind == .audio {
                Button(LocalizedStringResource("workboard.material.open", defaultValue: "Open"), action: openMaterial)
            }
            if WorkboardCardActionPolicy.allows(.open, when: material.availability), let onShare {
                Button(
                    WorkboardCompanionBand.shareTitle(hasCompanion: material.companion != nil),
                    action: onShare
                )
            }
        }
        // The badge over the thumbnail is hidden from VoiceOver, so playback
        // and the recording's own routes reach the person here or not at all.
        ForEach(companionActions, id: \.self) { action in
            Button(WorkboardCompanionBand.title(for: action)) {
                performCompanionAction(action)
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

    /// One card, one face, shared with the mosaic tile and the spoken label.
    private var face: WorkboardCardFace {
        WorkboardCardFacePolicy.face(for: material)
    }

    /// A folded row's tap opens the PICTURE: the recording has its own badge,
    /// and the row is a screenshot with a voice note on it rather than a
    /// recording that happens to have a thumbnail.
    private var primaryAction: (() -> Void)? {
        if material.kind == .audio, isPlayable { return toggleTransport }
        switch WorkboardCardActionPolicy.primaryAction(for: material.availability) {
        case .details, .open: return openMaterial
        case .reattach: return onReattach
        case .play, .none: return nil
        }
    }

    /// Opening hands the folded recording to the gallery, which presents its
    /// own transport for the same clip. The row's player is torn down first —
    /// including a payload read in flight — so the sheet never shows Play over
    /// audio the desk is still producing.
    private func openMaterial() {
        player.deactivate()
        onOpen()
    }

    /// Whether this row draws a transport at all — an audio row, or a picture
    /// with a RECORDING folded into it. Never both: the fold attaches a voice
    /// material only to a picture. A picture folded around words alone draws no
    /// transport, no clock and no playback status: there are no bytes behind it,
    /// so every one of those would report a player that does not exist.
    private var hasTransport: Bool {
        material.kind == .audio || material.companion?.kind == .audio
    }

    /// The recording this row's one player plays.
    private var transportMaterialID: UUID {
        material.companion?.id ?? material.id
    }

    /// Playback asks the RECORDING's availability. A screenshot that is
    /// readable here says nothing about whether its recording's bytes arrived.
    private var transportAvailability: WorkboardMaterialAvailability {
        material.companion?.availability ?? material.availability
    }

    private var isPlayable: Bool {
        hasTransport && WorkboardCardActionPolicy.allows(.play, when: transportAvailability)
    }

    private func toggleTransport() {
        guard workbenchDestinationIsActive, isPlayable else { return }
        let id = transportMaterialID
        player.toggle { try await ConversationStore.shared.loadWorkMaterialPayload(id: id) }
    }

    private var companionActions: [WorkboardCompanionAction] {
        guard let companion = material.companion else { return [] }
        return WorkboardCompanionBand.actions(
            for: companion,
            phase: player.phase,
            hasOpenRecording: onOpenCompanion != nil,
            hasShareRecording: onShareCompanion != nil,
            hasReattachRecording: onReattachCompanion != nil
        )
    }

    private func performCompanionAction(_ action: WorkboardCompanionAction) {
        switch action {
        case .play, .pause, .cancelLoading: toggleTransport()
        case .openRecording, .openTranscript:
            player.deactivate()
            onOpenCompanion?()
        case .shareRecording: onShareCompanion?()
        case .reattachRecording: onReattachCompanion?()
        }
    }

    /// The row's own headline: the recording's words on a folded row, and
    /// otherwise whatever the shared face leads with — its heading, or the body
    /// itself where the heading only repeated it. Absent means absent: a row
    /// with nothing to lead with draws no bold blank where a title would be.
    private var rowTitle: String? {
        guard let companion = material.companion else { return face.leadLine }
        return WorkboardCompanionBand.face(for: companion).leadLine
    }

    /// What names the card when its lead line is content rather than identity —
    /// a titled link's host. The tile and the spoken label both keep it, so a
    /// row that dropped it would be the one surface where "Winter timetable"
    /// never says which site it is on.
    private var rowIdentity: String? {
        guard material.companion == nil else { return nil }
        return face.identity
    }

    private var previewText: String? {
        if let companion = material.companion {
            return WorkboardCompanionBand.face(for: companion).trailingExcerpt
        }
        return face.trailingExcerpt
    }

    private var audioSymbol: String {
        WorkboardAudioTransport.symbolName(phase: player.phase, availability: transportAvailability)
    }

    private var transportTitle: LocalizedStringResource {
        WorkboardAudioTransport.actionTitle(for: player.phase)
    }

    private var transportSymbol: String {
        WorkboardAudioTransport.actionSymbol(for: player.phase)
    }

    /// One statement of what a transport is doing, shared with the audio card
    /// and the folded tile: three surfaces saying a refusal in three sets of
    /// words would be three chances to drift.
    private var audioStatus: LocalizedStringResource? {
        guard hasTransport else { return nil }
        return WorkboardAudioTransport.statusLabel(for: player.phase)
    }

    private var clockText: String {
        WorkboardAudioTransport.clockText(elapsed: player.elapsed, duration: player.duration)
    }

    private var availabilityLabel: LocalizedStringResource? {
        guard material.availability != .available else { return nil }
        if material.availability == .unavailableOnThisDevice, onReattach == nil {
            return LocalizedStringResource("workboard.audio.unavailableHere", defaultValue: "Not on this device")
        }
        return WorkboardCardAccessibility.availabilityLabel(for: material.availability)
    }

    private var availabilitySymbol: String {
        WorkboardCardFacePolicy.availabilityGlyphName(for: material.availability)
    }

    private var availabilityTint: Color {
        WorkboardCardFacePolicy.availabilityTint(for: material.availability)
    }

    /// A folded row says what it IS before it says the picture's name, then the
    /// recording's words: "Image" would describe half of the row.
    private var accessibilityLabel: Text {
        var parts = [String(localized: material.companion.map(
            WorkboardCompanionBand.accessibilityKindLabel(for:)
        ) ?? material.kind.title)]
        if let companion = material.companion {
            parts.append(material.name)
            if isPlayable { parts.append(String(localized: transportTitle)) }
            parts.append(contentsOf: WorkboardCompanionBand.face(for: companion).spokenParts)
        } else {
            if isPlayable { parts.append(String(localized: transportTitle)) }
            // The face's own slots, said once. The row used to append the name
            // and then the preview separately, so a card whose title is its own
            // first line was read out twice.
            parts.append(contentsOf: face.spokenParts)
        }
        if WorkboardMaterialNotesIndicator.isVisible(for: material) {
            parts.append(String(localized: WorkboardMaterialNotesIndicator.title))
        }
        if boardCount > 0, boardPosition > 0 {
            parts.append(WorkboardCardAccessibility.boardPositionLabel(position: boardPosition, count: boardCount))
        }
        return Text(verbatim: parts.joined(separator: ". "))
    }

    private var accessibilityValue: Text {
        var parts: [String] = []
        if let organizationActions { parts.append(contentsOf: organizationActions.accessibilityMetadata) }
        if let availabilityLabel { parts.append(String(localized: availabilityLabel)) }
        if let audioStatus { parts.append(String(localized: audioStatus)) }
        if hasTransport, player.duration > 0 { parts.append(clockText) }
        return Text(verbatim: parts.joined(separator: ". "))
    }

    /// The trait tells VoiceOver to fall silent for the activation, which is
    /// right only where activating the ROW starts audio — never on a folded
    /// row, where it opens the picture.
    private var playbackTraits: AccessibilityTraits {
        material.kind == .audio && isPlayable && player.willStartPlayback ? [.startsMediaSession] : []
    }
}

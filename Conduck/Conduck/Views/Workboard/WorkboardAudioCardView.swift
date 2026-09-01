// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardAudioCardView.swift
//
// The desk's playable voice-note card, and the small player behind it. A voice
// note is kept as AUDIO — the transcript is a caption on the recording, not a
// replacement for it — so the card is playable from the moment its bytes land,
// with or without a transcript.
//
// WHY ITS OWN PLAYER: Chat's read-aloud stack (`ReplyVoice` / `SpeechPlayer` /
// `ThreadSpeaker`) owns a per-turn exactly-once completion contract, an Apple
// on-device fallback leg and CarPlay's activate-once session invariant. A board
// card needs none of that and must never be able to disturb it, so the desk
// carries a separate `AVAudioPlayer` and never reaches into that stack.
//
// EXCLUSIVITY: a board can hold many audio cards and a person taps a second one
// to hear it INSTEAD of the first, never on top of it. One process-wide
// registry holds the card that currently owns output and stops the previous
// holder as the next one claims it; the registry keeps a weak reference, so a
// card scrolled out of existence cannot pin a player alive.
//
// AUDIO SESSION (iOS): the desk has no session owner of its own, and the
// recorder that produces these notes leaves the shared session on `.record` and
// inactive — playing into that is silence. So the card activates `.playback` /
// `.spokenAudio` around its own playback exactly as the chat read-aloud path
// does for its own, and releases it at every terminal. The release is
// best-effort: `setActive(false)` throws busy while another leg still holds
// audio I/O, which is precisely the case where releasing it would be wrong.
//
// TERMINALS: playback end is detected by the progress tick observing that the
// player stopped, not by an `AVAudioPlayerDelegate` funnel. The card has no
// second leg to hand a failure to and no completion a caller waits on, so the
// delegate's identity-guard machinery would buy nothing here.

import AVFoundation
import SwiftUI

// MARK: - Playback state

/// What the card's transport is doing. `failed` is a card whose bytes would not
/// load or would not decode: it stays on the board and stays tappable, because
/// the next tap is the only way to find out whether the bytes have since
/// arrived.
enum WorkboardAudioPhase: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed
}

/// Elapsed/duration arithmetic and the transport's clock copy, kept out of the
/// view so both are decidable without a simulator or real audio.
enum WorkboardAudioTiming {
    /// Progress as a fraction of the clip, clamped to `0...1`. A duration that
    /// is zero, negative or not yet known reads as 0 rather than as a full
    /// bar — an unknown clip has made no progress, and a bar that starts full
    /// would say the opposite.
    static func fraction(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0, elapsed.isFinite, elapsed > 0 else { return 0 }
        return min(1, elapsed / duration)
    }

    /// `m:ss`, and `h:mm:ss` past an hour. Deliberately not a
    /// `DateComponentsFormatter`: this string is redrawn on every progress tick
    /// and read aloud as an accessibility value, so it stays a pure function of
    /// its input with no shared formatter state. Anything unusable — negative,
    /// infinite, NaN — reads as the start of the clip.
    static func label(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return positionLabel(hours: 0, minutes: 0, seconds: 0) }
        let total = Int(seconds.rounded(.down))
        return positionLabel(
            hours: total / 3600,
            minutes: (total % 3600) / 60,
            seconds: total % 60
        )
    }

    private static func positionLabel(hours: Int, minutes: Int, seconds: Int) -> String {
        hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Exclusivity

/// A player that can be told to stop because another one is taking output.
/// A protocol rather than the concrete player so the registry's behaviour is
/// decidable without constructing an `AVAudioPlayer`.
@MainActor
protocol WorkboardAudioExclusive: AnyObject {
    func stopForExclusivity()
}

/// The single owner of desk audio output. Claiming stops whoever held it, so
/// two cards can never play over each other; resigning clears the slot only if
/// the resigning player is still the holder, so a terminal arriving after a
/// newer card claimed output cannot silence that newer card.
@MainActor
final class WorkboardAudioExclusivity {
    /// `nonisolated` so it can stand as a default argument, which is evaluated
    /// outside the actor. The instance itself is main-actor isolated; only the
    /// reference to it is reachable from anywhere.
    nonisolated static let shared = WorkboardAudioExclusivity()

    /// Weak: a card that goes away without resigning must not keep its player
    /// alive, and a stale holder must read as no holder.
    private weak var holder: (any WorkboardAudioExclusive)?

    nonisolated init() {}

    /// Test seam and assertion target — the registry's whole state.
    var currentHolder: (any WorkboardAudioExclusive)? { holder }

    func claim(_ next: any WorkboardAudioExclusive) {
        if let holder, holder !== next { holder.stopForExclusivity() }
        holder = next
    }

    func resign(_ player: any WorkboardAudioExclusive) {
        guard holder === player else { return }
        holder = nil
    }
}

// MARK: - Player

/// One card's playback. Owns an `AVAudioPlayer` built from the material's bytes
/// and nothing else: no queue, no fallback leg, no session category beyond its
/// own playback window.
@Observable
@MainActor
final class WorkboardAudioCardPlayer: WorkboardAudioExclusive {
    private(set) var phase: WorkboardAudioPhase = .idle
    private(set) var elapsed: TimeInterval = 0
    /// The clip's length, known only once its bytes have decoded. 0 means "not
    /// yet loaded", which is why the transport shows no clock before first play.
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let exclusivity: WorkboardAudioExclusivity

    /// How often the progress bar and the clock are refreshed. Slow enough to
    /// cost nothing on a board of cards, fast enough that the bar reads as
    /// motion rather than as steps.
    private static let tickInterval = Duration.milliseconds(100)

    init(exclusivity: WorkboardAudioExclusivity = .shared) {
        self.exclusivity = exclusivity
    }

    var fraction: Double {
        WorkboardAudioTiming.fraction(elapsed: elapsed, duration: duration)
    }

    /// True when the next tap starts audio rather than pausing it — the
    /// accessibility trait and the transport glyph both key off this.
    var willStartPlayback: Bool {
        phase != .playing && phase != .loading
    }

    /// Play, pause or resume, whichever the current phase makes the next tap
    /// mean. `load` is called only when bytes are actually needed, so a card
    /// that is never played never reads its payload.
    func toggle(load: @escaping () async throws -> Data?) {
        switch phase {
        case .playing:
            pause()
        case .paused:
            resume()
        case .idle, .failed:
            start(load: load)
        case .loading:
            // A second tap while bytes are in flight cancels the attempt rather
            // than queueing a second one.
            loading?.cancel()
            loading = nil
            phase = .idle
        }
    }

    /// Another card took output. Stop without touching the phase machinery of
    /// the card that claimed it.
    func stopForExclusivity() {
        teardown()
        phase = .idle
    }

    /// The card left the screen. Everything in flight dies with it: a board
    /// scrolled away must not keep audio, a session, or a payload read alive.
    func deactivate() {
        loading?.cancel()
        loading = nil
        teardown()
        phase = .idle
    }

    // MARK: Transitions

    private func start(load: @escaping () async throws -> Data?) {
        loading?.cancel()
        phase = .loading
        elapsed = 0
        duration = 0
        loading = Task { [weak self] in
            let data = try? await load()
            guard let self, !Task.isCancelled else { return }
            self.loading = nil
            guard let data, !data.isEmpty else {
                self.phase = .failed
                return
            }
            self.begin(with: data)
        }
    }

    private func begin(with data: Data) {
        exclusivity.claim(self)
        activateSession()
        do {
            let engine = try AVAudioPlayer(data: data)
            engine.prepareToPlay()
            guard engine.play() else {
                releaseSession()
                exclusivity.resign(self)
                phase = .failed
                return
            }
            player = engine
            duration = engine.duration
            elapsed = 0
            phase = .playing
            startTicking()
        } catch {
            // Undecodable bytes. Never logged — the recording is the person's.
            releaseSession()
            exclusivity.resign(self)
            phase = .failed
        }
    }

    private func pause() {
        player?.pause()
        stopTicking()
        // Un-duck other apps' audio while the note is parked; the resume path
        // activates again.
        releaseSession()
        phase = .paused
    }

    private func resume() {
        guard let player else {
            phase = .idle
            return
        }
        exclusivity.claim(self)
        activateSession()
        guard player.play() else {
            teardown()
            phase = .failed
            return
        }
        phase = .playing
        startTicking()
    }

    /// The clip reached its end on its own. The card returns to the start so a
    /// second tap replays it rather than doing nothing.
    private func finish() {
        teardown()
        phase = .idle
    }

    private func teardown() {
        stopTicking()
        player?.stop()
        player = nil
        elapsed = 0
        duration = 0
        releaseSession()
        exclusivity.resign(self)
    }

    // MARK: Progress

    private func startTicking() {
        stopTicking()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self, let player = self.player else { return }
                self.elapsed = player.currentTime
                // The player stopping while the card still believes it is
                // playing IS the terminal — a natural end, or a decode failure
                // that took the clip down mid-way. Both leave the card ready to
                // be tapped again.
                if !player.isPlaying {
                    self.finish()
                    return
                }
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: Session

    /// iOS only — macOS has no `AVAudioSession`. Both calls are best-effort:
    /// a refused activation shows up as a failed start, and a refused release
    /// means another leg still holds output, which is the one case where
    /// releasing would be wrong.
    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
        #endif
    }

    private func releaseSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

// MARK: - Card

/// A voice note as a board card: transport, progress, and the transcript as a
/// caption once one exists. An untranscribed note draws the same card without
/// the caption — the recording is the material, so it is playable before any
/// text arrives and stays playable if none ever does.
///
/// The whole tile is the transport, exactly as the other cards make the whole
/// tile the open control, so the glyph is presentation and the hit region is
/// the card. A card whose bytes are not readable here is not a transport at
/// all: it draws its availability and refuses the tap, which is the same
/// fail-closed rule the rest of the board follows.
struct WorkboardAudioCardView: View {
    let material: WorkboardMaterialSnapshot
    var size: WorkMaterialCardSize = .standard
    /// The grid width the mosaic granted, so a `large` card that was clamped
    /// draws the layout it actually received.
    var grantedColumns: Int = WorkboardMosaicSpan.large.columns
    var boardPosition: Int = 0
    var boardCount: Int = 0
    /// The card's only reach into storage. Injected so the transport can be
    /// exercised without a store, and so the bytes are read on the first play
    /// rather than on every board refresh.
    var loadPayload: (UUID) async throws -> Data? = { id in
        try await ConversationStore.shared.loadWorkMaterialPayload(id: id)
    }
    var onSetSize: ((WorkMaterialCardSize) -> Void)?
    var onMoveEarlier: (() -> Void)?
    var onMoveLater: (() -> Void)?
    var onRemove: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player = WorkboardAudioCardPlayer()
    @State private var isHovering = false

    /// Matches the tile the other board cards draw. The board's card radius is
    /// a property of the mosaic tile rather than of any one card, so an audio
    /// card that picked its own would read as a different kind of object.
    private static let tileCornerRadius: CGFloat = 13

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // A card whose bytes are not readable here is not a control: it is
            // NOT wrapped in a button, so it carries no button trait, offers no
            // activation that would do nothing, and is not dimmed the way a
            // disabled control would be — the availability chip is the answer,
            // and the arrange actions stay reachable either way.
            if isPlayable {
                Button(action: toggle) { tile }
                    .choiceCardButton(cornerRadius: Self.tileCornerRadius)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityAddTraits(playbackTraits)
                    .accessibilityActions { cardAccessibilityActions }
            } else {
                tile
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityActions { cardAccessibilityActions }
            }

            cardMenu
                .padding(menuInset)
                .allowsHitTesting(showsMenuAffordance)
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12)) { content in
                    content.opacity(showsMenuAffordance ? 1 : 0)
                }
        }
        .contextMenu { cardMenuContent }
        #if os(macOS)
        .onHover { hovering in isHovering = hovering }
        #endif
        .onDisappear { player.deactivate() }
    }

    // MARK: Layout

    /// The tile itself, without any decision about whether it is a control.
    /// The mosaic hands every card a fixed frame, so content that cannot
    /// compress is clipped rather than allowed to bleed over a neighbour.
    private var tile: some View {
        cardBody
            .padding(layoutSize == .small ? 9 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Self.tileCornerRadius, style: .continuous))
            .background(
                AppColors.cardBackgroundElevated,
                in: RoundedRectangle(cornerRadius: Self.tileCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Self.tileCornerRadius, style: .continuous)
                    .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.tileCornerRadius, style: .continuous))
    }

    private var showsMenuAffordance: Bool {
        #if os(macOS)
        return isHovering
        #else
        return true
        #endif
    }

    private var layoutSize: WorkMaterialCardSize {
        size == .large && grantedColumns < WorkboardMosaicSpan.large.columns ? .standard : size
    }

    @ViewBuilder
    private var cardBody: some View {
        switch layoutSize {
        case .small:
            VStack(alignment: .leading, spacing: 6) {
                transport(dimension: 30)
                Text(verbatim: material.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                progressBar
                Spacer(minLength: 0)
            }
        case .standard:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    transport(dimension: 40)
                    availabilityChip
                    // The menu affordance owns this corner: keep content clear.
                    Spacer(minLength: 26)
                }
                Text(verbatim: material.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                progressBar
                caption(lineLimit: 2)
                Spacer(minLength: 0)
                cardFooter
            }
        case .large:
            HStack(alignment: .top, spacing: 12) {
                transport(dimension: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: material.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                    progressBar
                    caption(lineLimit: 4)
                    Spacer(minLength: 0)
                    cardFooter
                }
                availabilityChip
                Spacer(minLength: 26)
            }
        }
    }

    /// The play/pause affordance. Not a control of its own — the card is the
    /// button — so it is hidden from accessibility and the card's own label
    /// carries the state.
    private func transport(dimension: CGFloat) -> some View {
        Image(systemName: transportSymbol)
            .font(.system(size: max(13, dimension * 0.44), weight: .semibold))
            .foregroundStyle(isPlayable ? AppColors.brandAmber : AppColors.textTertiary)
            .frame(width: dimension, height: dimension)
            .background(
                AppColors.backgroundSecondary,
                in: RoundedRectangle(cornerRadius: dimension * 0.3, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var transportSymbol: String {
        guard isPlayable else { return "icloud.and.arrow.down" }
        switch player.phase {
        case .playing: return "pause.fill"
        case .loading: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .idle, .paused: return "play.fill"
        }
    }

    /// The bar and the clock appear only once a clip has been decoded: before
    /// that its length is genuinely unknown, and a zeroed track beside a
    /// "0:00 of 0:00" clock would state a fact the card does not have.
    @ViewBuilder
    private var progressBar: some View {
        if player.duration > 0 {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(AppColors.backgroundSecondary)
                        Capsule(style: .continuous)
                            .fill(AppColors.brandAmber)
                            .frame(width: proxy.size.width * player.fraction)
                    }
                }
                .frame(height: 4)
                .animation(reduceMotion ? nil : .linear(duration: 0.1), value: player.fraction)
                Text(verbatim: clockText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var clockText: String {
        String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.audio.position",
                defaultValue: "%1$@ of %2$@"
            )),
            WorkboardAudioTiming.label(player.elapsed),
            WorkboardAudioTiming.label(player.duration)
        )
    }

    /// The transcript, once one exists. A note that has not been transcribed —
    /// or whose transcription failed — draws no caption at all rather than a
    /// placeholder: the card is the recording, and the caption is an extra.
    @ViewBuilder
    private func caption(lineLimit: Int) -> some View {
        if player.phase == .failed {
            Text(LocalizedStringResource(
                "workboard.audio.failed",
                defaultValue: "This recording couldn’t be played"
            ))
            .font(.caption)
            .foregroundStyle(AppColors.warning)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let transcript, !transcript.isEmpty {
            Text(verbatim: transcript)
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.leading)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcript: String? {
        material.textContent?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cardFooter: some View {
        HStack(spacing: 6) {
            if let byteCount = material.byteCount {
                Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
            }
            Spacer(minLength: 5)
            Text(material.createdAt, format: .relative(presentation: .named))
        }
        .font(.caption2)
        .foregroundStyle(AppColors.textTertiary)
        .lineLimit(1)
    }

    /// The same availability vocabulary the other cards carry: a note waiting
    /// for iCloud says so and cannot be played, a note whose local bytes are
    /// gone asks to be reattached.
    @ViewBuilder
    private var availabilityChip: some View {
        if material.availability != .available {
            HStack(spacing: 3) {
                Image(systemName: availabilityGlyphName)
                Text(availabilityLabel)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(availabilityTint)
            .accessibilityHidden(true)
        }
    }

    private var availabilityGlyphName: String {
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

    private var availabilityLabel: LocalizedStringResource {
        switch material.availability {
        case .localOnly:
            return LocalizedStringResource(
                "workboard.material.localOnly",
                defaultValue: "Available on this device"
            )
        case .syncPending:
            return LocalizedStringResource(
                "workboard.material.syncPending",
                defaultValue: "Waiting for iCloud…"
            )
        case .available, .unavailableOnThisDevice:
            return LocalizedStringResource(
                "workboard.material.reattach.short",
                defaultValue: "Reattach"
            )
        }
    }

    /// Bytes that are not readable on this device cannot be played on it. The
    /// readable cases are named by `isAvailable`, so a state added later fails
    /// closed rather than opening a transport over nothing.
    private var isPlayable: Bool {
        material.availability.isAvailable
    }

    // MARK: Actions

    private func toggle() {
        guard isPlayable else { return }
        let id = material.id
        let load = loadPayload
        player.toggle { try await load(id) }
    }

    private var menuHitDimension: CGFloat {
        layoutSize == .small ? 30 : WorkboardMetrics.touchTarget
    }

    private var menuInset: CGFloat {
        layoutSize == .small ? 4 : 0
    }

    private var cardMenu: some View {
        Menu {
            cardMenuContent
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(AppColors.textSecondary, AppColors.cardBackgroundElevated)
                .frame(width: 30, height: 30)
                .frame(width: menuHitDimension, height: menuHitDimension)
                .contentShape(Circle())
        }
        .pointerIconButton(size: menuHitDimension, shape: .circle)
        .help(String(localized: LocalizedStringResource(
            "workboard.material.card.more",
            defaultValue: "Card actions"
        )))
    }

    @ViewBuilder
    private var cardMenuContent: some View {
        if isPlayable {
            Button(action: toggle) {
                Label(
                    transportActionTitle,
                    systemImage: player.phase == .playing ? "pause.fill" : "play.fill"
                )
            }
        }
        if let onSetSize {
            Divider()
            Picker(
                LocalizedStringResource("workboard.material.card.size", defaultValue: "Card Size"),
                selection: Binding(get: { size }, set: { onSetSize($0) })
            ) {
                ForEach(WorkMaterialCardSize.allCases, id: \.self) { option in
                    Text(option.cardSizeTitle).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
        if onMoveEarlier != nil || onMoveLater != nil {
            Divider()
            if let onMoveEarlier {
                Button(action: onMoveEarlier) {
                    Label(
                        LocalizedStringResource("workboard.action.moveEarlier", defaultValue: "Move Earlier"),
                        systemImage: "arrow.left"
                    )
                }
            }
            if let onMoveLater {
                Button(action: onMoveLater) {
                    Label(
                        LocalizedStringResource("workboard.action.moveLater", defaultValue: "Move Later"),
                        systemImage: "arrow.right"
                    )
                }
            }
        }
        if let onRemove {
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label(
                    LocalizedStringResource(
                        "workboard.material.remove.action",
                        defaultValue: "Remove Material"
                    ),
                    systemImage: "trash"
                )
            }
        }
    }

    @ViewBuilder
    private var cardAccessibilityActions: some View {
        if let onMoveEarlier {
            Button(
                LocalizedStringResource("workboard.action.moveEarlier", defaultValue: "Move Earlier"),
                action: onMoveEarlier
            )
        }
        if let onMoveLater {
            Button(
                LocalizedStringResource("workboard.action.moveLater", defaultValue: "Move Later"),
                action: onMoveLater
            )
        }
        if let onSetSize {
            ForEach(WorkMaterialCardSize.allCases.filter { $0 != size }, id: \.self) { option in
                Button(option.cardSizeAccessibilityAction) {
                    onSetSize(option)
                }
            }
        }
        if let onRemove {
            Button(
                LocalizedStringResource(
                    "workboard.material.remove.action",
                    defaultValue: "Remove Material"
                ),
                action: onRemove
            )
        }
    }

    // MARK: Accessibility

    private var transportActionTitle: LocalizedStringResource {
        player.phase == .playing
            ? LocalizedStringResource("workboard.audio.pause", defaultValue: "Pause")
            : LocalizedStringResource("workboard.audio.play", defaultValue: "Play")
    }

    /// The label says what the card IS and what tapping it does; the value says
    /// what it is doing. Splitting them is what lets VoiceOver re-read the state
    /// after a tap without repeating the name and the transcript.
    private var accessibilityLabel: Text {
        // The kind's own copy, never a second name for the same thing: the
        // enum owns what a voice note is called everywhere else on the board.
        var parts = [String(localized: material.kind.title), material.name]
        if isPlayable {
            parts.append(String(localized: transportActionTitle))
        }
        if let transcript, !transcript.isEmpty {
            parts.append(transcript)
        }
        parts.append(String(localized: size.cardSizeTitle))
        if boardCount > 0, boardPosition > 0 {
            parts.append(Self.boardPositionLabel(position: boardPosition, count: boardCount))
        }
        return Text(parts.joined(separator: ". "))
    }

    private var accessibilityValue: Text {
        var parts: [String] = []
        if material.availability != .available {
            parts.append(String(localized: availabilityLabel))
        }
        switch player.phase {
        case .loading:
            parts.append(String(localized: LocalizedStringResource(
                "workboard.audio.loading",
                defaultValue: "Loading"
            )))
        case .playing:
            parts.append(String(localized: LocalizedStringResource(
                "workboard.audio.playing",
                defaultValue: "Playing"
            )))
        case .paused:
            parts.append(String(localized: LocalizedStringResource(
                "workboard.audio.paused",
                defaultValue: "Paused"
            )))
        case .failed:
            parts.append(String(localized: LocalizedStringResource(
                "workboard.audio.failed",
                defaultValue: "This recording couldn’t be played"
            )))
        case .idle:
            break
        }
        if player.duration > 0 {
            parts.append(clockText)
        }
        return Text(parts.joined(separator: ". "))
    }

    /// `startsMediaSession` tells VoiceOver to suppress its own speech for the
    /// tap, which is right only when the tap actually starts audio.
    private var playbackTraits: AccessibilityTraits {
        isPlayable && player.willStartPlayback ? [.startsMediaSession] : []
    }

    /// The same phrase, from the same key, the other board cards use: two cards
    /// on one board must not describe their place in the order differently.
    private static func boardPositionLabel(position: Int, count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.material.card.position",
                defaultValue: "%1$lld of %2$lld"
            )),
            position,
            count
        )
    }
}

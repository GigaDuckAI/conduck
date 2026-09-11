// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardAudioCardView.swift
//
// The desk's playable recording card, and the small player behind it. It draws
// an audio file a person attached in Work, or a recording written by an earlier
// build; nothing records into it, because a Work voice note is its words. The
// card is playable from the moment its bytes land, with or without a
// transcript.
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
// AUDIO OUTPUT: the desk has no session owner of its own, and the recorder that
// produces these notes leaves the iOS session on `.record` and inactive —
// playing into that is silence. `WorkboardAudioOutput` is the card family's one
// claim on process audio: it REFUSES while a capture is live (a CarPlay voice
// session, or any registered mic authority), it brings the session up through
// `SpokenAudioSession` — the one owner of that posture, shared with the chat
// read-aloud path — and it records WHICH client holds the claim so only that
// client's release can deactivate the session: a stale terminal from a card
// that already lost output must never silence the card that took it. A refused
// activation is a refusal, never a granted claim: `AVAudioPlayer.play()` is not
// trusted behind a swallowed session error.
//
// SPEECH BUS: the card is also a `SpeechExclusivityParty`. It claims before
// every start and resume, so a chat read-aloud stops rather than overlaps, and
// a mic start (`claim(nil)`) stops a playing card. Registration is lazy — at
// the first claim, not in `init` — because SwiftUI re-evaluates an `@State`
// default initializer on every struct init and would otherwise churn the
// registry with throwaway players. CarPlay registers no party, so nothing here
// can preempt its exactly-once / deactivate-once invariants.
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
/// arrived. `blocked` is the same card refused for a reason that is not about
/// the recording at all — a live capture owns audio — so it is stated as its
/// own state rather than reported as a broken recording.
enum WorkboardAudioPhase: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed
    case blocked
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

// MARK: - Presentation rules

/// Which action a tap on the transport means. Named as an action rather than as
/// a string so the rule — a loading card cancels, it does not play — is
/// decidable without mounting the view, and so the label and the glyph cannot
/// drift apart from what the tap does.
enum WorkboardAudioTransportAction: Equatable, Sendable {
    case play
    case pause
    case cancelLoading
}

/// What the availability corner says, and whether saying it is an ACTION. Only
/// `reattach` is a control: it is offered exactly when the card was given
/// somewhere to send the person, so the card never names a repair it cannot
/// perform.
enum WorkboardAudioCardChip: Equatable, Sendable {
    case localOnly
    case syncPending
    case reattach
    case notOnThisDevice

    var isAction: Bool { self == .reattach }

    /// The availability this chip stands for, which is what its glyph and its
    /// tint are decided from — so a recording and a picture in the same state
    /// are never drawn differently.
    var availability: WorkboardMaterialAvailability {
        switch self {
        case .localOnly: return .localOnly
        case .syncPending: return .syncPending
        case .reattach, .notOnThisDevice: return .unavailableOnThisDevice
        }
    }

    var glyphName: String {
        WorkboardCardFacePolicy.availabilityGlyphName(for: availability)
    }

    /// `@MainActor` because the palette is; the words and the glyph stay
    /// reachable from anywhere.
    @MainActor
    var tint: Color {
        WorkboardCardFacePolicy.availabilityTint(for: availability)
    }

    /// Only the WORDS are the chip's own: `.notOnThisDevice` is the sentence
    /// for a surface that wired no repair, which the shared availability policy
    /// has no reason to know about. Stated here rather than in the card, because
    /// the gallery's companion band draws the same chip and a second spelling
    /// is exactly the duplication the face policy exists to prevent.
    var label: LocalizedStringResource {
        switch self {
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
        case .reattach:
            return LocalizedStringResource(
                "workboard.material.reattach.short",
                defaultValue: "Reattach"
            )
        case .notOnThisDevice:
            return LocalizedStringResource(
                "workboard.audio.unavailableHere",
                defaultValue: "Not on this device"
            )
        }
    }
}

/// The card's presentation decisions as pure functions. They live outside the
/// view so what the person is shown — and what each affordance does — is
/// decidable without a mounted `View` and without audio hardware.
enum WorkboardAudioCardPresentation {
    /// The transport's meaning for a phase. Activating a LOADING card cancels
    /// the payload read, so it must not announce "Play".
    static func transportAction(for phase: WorkboardAudioPhase) -> WorkboardAudioTransportAction {
        switch phase {
        case .playing: return .pause
        case .loading: return .cancelLoading
        case .idle, .paused, .failed, .blocked: return .play
        }
    }

    /// Details and notes remain readable without the audio file. Playback and
    /// sharing keep their separate byte-availability gates.
    static func showsOpenAction(
        availability: WorkboardMaterialAvailability,
        hasOpenAction: Bool
    ) -> Bool {
        WorkboardCardActionPolicy.allows(.details, when: availability) && hasOpenAction
    }

    /// The availability corner. `nil` for a card whose bytes are simply here.
    /// The repair is named only where the policy permits one AND the board
    /// wired somewhere for it to go.
    static func chip(
        for availability: WorkboardMaterialAvailability,
        hasReattachAction: Bool
    ) -> WorkboardAudioCardChip? {
        switch availability {
        case .available:
            return nil
        case .localOnly:
            return .localOnly
        case .syncPending:
            return .syncPending
        case .unavailableOnThisDevice:
            let repairable = WorkboardCardActionPolicy.allows(.reattach, when: availability)
            return repairable && hasReattachAction ? .reattach : .notOnThisDevice
        }
    }
}

// MARK: - Audio output claim

/// The outcome of asking for process audio output.
enum WorkboardAudioOutputClaim: Equatable, Sendable {
    case granted
    /// A capture owns audio — a CarPlay voice session, or a registered mic
    /// authority. A live capture is sacred, so the card refuses rather than
    /// reconfiguring the session out from under it.
    case captureIsLive
    /// The session refused to come up. The card must NOT fall through to
    /// `AVAudioPlayer.play()` on the strength of a swallowed error.
    case sessionUnavailable
}

/// The one claim on process audio the desk's cards make. A protocol so the
/// player's discipline is decidable without a real `AVAudioSession`.
@MainActor
protocol WorkboardAudioOutputArbiter: AnyObject {
    /// Live read, not a cached flag: the probe is asked at the moment of the
    /// tap, because a capture can start between two taps.
    var captureIsLive: Bool { get }
    func claim(for client: AnyObject) -> WorkboardAudioOutputClaim
    func release(for client: AnyObject)
}

/// Process audio output for the desk's audio cards.
///
/// OWNERSHIP is the point of the type: `release` deactivates only for the
/// client that is still the holder, so a terminal arriving from a card that
/// already lost output cannot deactivate the session under the card that took
/// it. The holder is held weakly — a card that goes away without releasing
/// reads as no holder rather than as a corpse that owns audio forever.
///
/// The capture probe and the two session calls are injected so the ownership
/// rules can be exercised without audio hardware; the defaults are the real
/// system state and the real shared session.
@MainActor
final class WorkboardAudioOutput: WorkboardAudioOutputArbiter {
    static let shared = WorkboardAudioOutput()

    /// `@MainActor` closure types, not plain ones: a default argument is
    /// evaluated in the caller's (nonisolated) context, so the isolation has to
    /// travel with the closure rather than with the call site.
    private let captureProbe: @MainActor () -> Bool
    private let activateSession: @MainActor () throws -> Void
    private let deactivateSession: @MainActor () -> Void

    private weak var holder: AnyObject?

    init(
        captureIsLive: @escaping @MainActor () -> Bool = { WorkboardAudioOutput.systemCaptureIsLive() },
        activateSession: @escaping @MainActor () throws -> Void = { try WorkboardAudioOutput.activateSharedSession() },
        deactivateSession: @escaping @MainActor () -> Void = { WorkboardAudioOutput.releaseSharedSession() }
    ) {
        self.captureProbe = captureIsLive
        self.activateSession = activateSession
        self.deactivateSession = deactivateSession
    }

    /// Test seam and assertion target — who, if anyone, may deactivate.
    var currentHolder: AnyObject? { holder }

    var captureIsLive: Bool { captureProbe() }

    func claim(for client: AnyObject) -> WorkboardAudioOutputClaim {
        guard !captureProbe() else { return .captureIsLive }
        // Already ours: the session is configured and active, and re-activating
        // would be a second claim on a route we already hold.
        guard holder !== client else { return .granted }
        do {
            try activateSession()
        } catch {
            // The activation failed, so nothing was claimed. Leaving the holder
            // unset is what keeps a later release from deactivating a session
            // this client never brought up.
            return .sessionUnavailable
        }
        holder = client
        return .granted
    }

    func release(for client: AnyObject) {
        guard holder === client else { return }
        holder = nil
        deactivateSession()
    }

    // MARK: System state

    /// True while any capture that must not be played over is live. CarPlay's
    /// process-wide mirror covers the car's voice session; the speech bus's
    /// authority registry covers the app's own microphones.
    private static func systemCaptureIsLive() -> Bool {
        #if os(iOS)
        if CarPlayRecordingService.anySessionActive { return true }
        #endif
        return SpeechExclusivity.shared.isRecordingActive
    }

    /// iOS only — macOS has no `AVAudioSession`, so the claim there is
    /// ownership bookkeeping and the speech bus does the arbitration. The
    /// session's category, mode and options belong to `SpokenAudioSession`, the
    /// one owner the chat read-aloud path shares: a voice note and a spoken
    /// reply are the same kind of output, so two copies of that posture on one
    /// shared session would only be free to drift. The THROW is this surface's
    /// own policy and stays here — a card must not play blind behind a
    /// swallowed activation error.
    private static func activateSharedSession() throws {
        #if os(iOS)
        try SpokenAudioSession.configureAndActivate()
        #endif
    }

    /// Best-effort by design: `setActive(false)` throws busy while another leg
    /// still holds audio I/O, which is precisely the case where releasing would
    /// be wrong.
    private static func releaseSharedSession() {
        #if os(iOS)
        try? SpokenAudioSession.deactivate()
        #endif
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
    /// Injected shared collaborators, resolved on the main actor rather than as
    /// default arguments: both singletons are main-actor state, and a default
    /// argument is evaluated in the caller's context (a SwiftUI `@State`
    /// initializer, which is not isolated).
    @ObservationIgnored private let injectedOutput: (any WorkboardAudioOutputArbiter)?
    @ObservationIgnored private let injectedSpeechBus: SpeechExclusivity?

    /// How often the progress bar and the clock are refreshed. Slow enough to
    /// cost nothing on a board of cards, fast enough that the bar reads as
    /// motion rather than as steps.
    private static let tickInterval = Duration.milliseconds(100)

    init(
        exclusivity: WorkboardAudioExclusivity = .shared,
        output: (any WorkboardAudioOutputArbiter)? = nil,
        speechBus: SpeechExclusivity? = nil
    ) {
        self.exclusivity = exclusivity
        self.injectedOutput = output
        self.injectedSpeechBus = speechBus
    }

    private var output: any WorkboardAudioOutputArbiter { injectedOutput ?? WorkboardAudioOutput.shared }

    private var speechBus: SpeechExclusivity { injectedSpeechBus ?? .shared }

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
        case .blocked:
            // A refusal keeps whatever it already had: a clip that was refused
            // mid-way resumes from its position, one that never started reads
            // its bytes.
            player == nil ? start(load: load) : resume()
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
        // Registered before the bytes are even read, so a microphone starting
        // during the read stops the card instead of racing it to output. The
        // CLAIM waits until there is audio to produce.
        speechBus.register(self)
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
        // Probed BEFORE anything is claimed: a card refused for a live capture
        // must not have stopped the card that was playing on its way to saying
        // no.
        guard !output.captureIsLive else {
            phase = .blocked
            return
        }
        exclusivity.claim(self)
        claimSpeechOutput()
        switch output.claim(for: self) {
        case .granted:
            break
        case .captureIsLive:
            exclusivity.resign(self)
            phase = .blocked
            return
        case .sessionUnavailable:
            // The session refused. `AVAudioPlayer.play()` can still return true
            // into a session that permits no output, so the refusal is the
            // answer — not a silent transport that looks like it is playing.
            exclusivity.resign(self)
            phase = .failed
            return
        }
        do {
            let engine = try AVAudioPlayer(data: data)
            engine.prepareToPlay()
            guard engine.play() else {
                output.release(for: self)
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
            output.release(for: self)
            exclusivity.resign(self)
            phase = .failed
        }
    }

    private func pause() {
        player?.pause()
        stopTicking()
        // Un-duck other apps' audio while the note is parked; the resume path
        // activates again.
        output.release(for: self)
        phase = .paused
    }

    private func resume() {
        guard let player else {
            phase = .idle
            return
        }
        guard !output.captureIsLive else {
            // The position is kept: the next tap resumes where the refusal
            // caught it rather than restarting the note.
            phase = .blocked
            return
        }
        exclusivity.claim(self)
        claimSpeechOutput()
        switch output.claim(for: self) {
        case .granted:
            break
        case .captureIsLive:
            exclusivity.resign(self)
            phase = .blocked
            return
        case .sessionUnavailable:
            teardown()
            phase = .failed
            return
        }
        guard player.play() else {
            teardown()
            phase = .failed
            return
        }
        phase = .playing
        startTicking()
    }

    /// Silence every other speaker before this card produces audio. Registration
    /// is lazy and idempotent, so a throwaway player from an `@State` default
    /// initializer never enters the registry. The mic is never a registered
    /// party, so this cannot stop a capture; CarPlay registers nothing, so this
    /// cannot preempt the car's voice session either.
    private func claimSpeechOutput() {
        speechBus.register(self)
        speechBus.claim(self)
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
        output.release(for: self)
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

}

// MARK: - Speech bus

extension WorkboardAudioCardPlayer: SpeechExclusivityParty {
    /// Preempted by another party on the speech bus — a chat read-aloud
    /// starting, or a microphone claiming everything. A card that is not
    /// producing audio has nothing to stop, so an idle one no-ops rather than
    /// resigning a claim it does not hold.
    func stopForSpeechExclusivity() {
        guard phase == .playing || phase == .paused || phase == .loading else { return }
        deactivate()
    }
}

// MARK: - Transport

/// What a transport is drawn ON, which is the only thing that changes about it.
/// `card` uses the semantic palette; `scrim` is a transport over a photograph,
/// where the surface underneath is arbitrary and the colours are literals — the
/// same reason the image-forward caption draws white text on a gradient.
enum WorkboardAudioTransportPlacement: Equatable, Sendable {
    case card
    case scrim
}

/// The desk's play/pause control, wherever a recording is drawn: the standalone
/// audio card's tile, the companion band on the picture a recording named, and
/// the list row. One statement of what the glyph means, so a phase added later
/// cannot read one way on a card and another way on a band.
///
/// IT OWNS NO PLAYER. The surface that draws it holds exactly one
/// `WorkboardAudioCardPlayer`, which is what keeps the process-wide
/// `WorkboardAudioExclusivity` registry meaningful: a player constructed per
/// transport would let one recording play over another, and a band and its card
/// would each hold a copy of the same clip. Bytes are read on the first
/// activation and never before — a desk of twenty recordings loads nothing
/// until one is played, which is also why the clock and the progress track
/// appear only once a clip has decoded.
struct WorkboardAudioTransport: View {
    /// Whether this transport is a control of its own.
    enum Activation: Equatable, Sendable {
        /// The tile around it IS the button — the standalone audio card, where
        /// the whole card is the transport. The glyph is presentation only and
        /// carries no accessibility of its own.
        case tile
        /// Its own button, because the tile around it does something else: a
        /// tap on a folded card opens the gallery, so playback needs a control
        /// the tile's button cannot swallow. It must therefore be drawn OUTSIDE
        /// that button rather than inside its label.
        case control
    }

    let materialID: UUID
    /// The one player of the surface drawing this. Passed in, never created
    /// here — see the type's note on exclusivity.
    let player: WorkboardAudioCardPlayer
    /// The recording's OWN availability. A folded card asks about the
    /// companion, never about the picture it sits on.
    ///
    /// The AVAILABILITY and not a `Bool`: "cannot play" is two different
    /// answers — bytes on their way through iCloud, and bytes this device no
    /// longer holds — and a transport handed only the boolean drew the waiting
    /// glyph over both. Playability is then derived here rather than at each
    /// call site, so no surface can offer a control the policy refuses.
    var availability: WorkboardMaterialAvailability = .available
    /// A hidden-but-mounted workbench must not start audio.
    var isEnabled: Bool = true
    var activation: Activation = .tile
    var dimension: CGFloat = 40
    var placement: WorkboardAudioTransportPlacement = .card
    var loadPayload: (UUID) async throws -> Data? = { id in
        try await ConversationStore.shared.loadWorkMaterialPayload(id: id)
    }

    var body: some View {
        switch activation {
        case .tile:
            glyph.accessibilityHidden(true)
        case .control:
            Button(action: toggle) { glyph }
                .pointerIconButton(size: dimension, shape: .roundedRect)
                // Not dimmed and not disabled: a recording whose bytes are not
                // here states that in its glyph, exactly as the rest of the
                // card family states availability instead of greying out.
                .allowsHitTesting(isEnabled && isPlayable)
                // The surrounding card carries "Play Recording" / "Pause
                // Recording" as custom actions — the same arrangement as the
                // ellipsis affordance, whose rows are all reachable there.
                .accessibilityHidden(true)
        }
    }

    /// Bytes this device cannot read are not a transport. The board's one
    /// permission policy names the readable cases, so a state added later fails
    /// closed rather than opening a control over nothing.
    private var isPlayable: Bool {
        WorkboardCardActionPolicy.allows(.play, when: availability)
    }

    private var glyph: some View {
        Image(systemName: Self.symbolName(phase: player.phase, availability: availability))
            .appReviewBusy(player.phase == .loading || player.phase == .playing || player.phase == .paused)
            .font(.system(size: max(13, dimension * 0.44), weight: .semibold))
            .foregroundStyle(glyphTint)
            .frame(width: dimension, height: dimension)
            .background(
                glyphBackground,
                in: RoundedRectangle(cornerRadius: dimension * 0.3, style: .continuous)
            )
    }

    private var glyphTint: Color {
        switch placement {
        case .card: return isPlayable ? AppColors.brandAmber : AppColors.textTertiary
        case .scrim: return isPlayable ? Color.white : Color.white.opacity(0.7)
        }
    }

    private var glyphBackground: Color {
        switch placement {
        case .card: return AppColors.backgroundSecondary
        case .scrim: return Color.black.opacity(0.45)
        }
    }

    private func toggle() {
        guard isEnabled, isPlayable else { return }
        let id = materialID
        let load = loadPayload
        player.toggle { try await load(id) }
    }

    /// The glyph for a phase. Bytes this device cannot read are not a transport
    /// at all, so they say what they are waiting for rather than offering play
    /// — and WHICH wait they are: the availability's own glyph separates a
    /// recording arriving from iCloud from one whose bytes have to be pointed
    /// at again, which a single cloud symbol reported as the same thing.
    static func symbolName(
        phase: WorkboardAudioPhase,
        availability: WorkboardMaterialAvailability
    ) -> String {
        guard WorkboardCardActionPolicy.allows(.play, when: availability) else {
            return WorkboardCardFacePolicy.availabilityGlyphName(for: availability)
        }
        switch phase {
        case .playing: return "pause.fill"
        case .loading: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .blocked: return "speaker.slash.fill"
        case .idle, .paused: return "play.fill"
        }
    }

    /// What the next activation DOES — including the loading phase, where it
    /// cancels the payload read rather than starting playback.
    static func actionTitle(for phase: WorkboardAudioPhase) -> LocalizedStringResource {
        switch WorkboardAudioCardPresentation.transportAction(for: phase) {
        case .play:
            return LocalizedStringResource("workboard.audio.play", defaultValue: "Play")
        case .pause:
            return LocalizedStringResource("workboard.audio.pause", defaultValue: "Pause")
        case .cancelLoading:
            return LocalizedStringResource(
                "workboard.audio.cancelLoading",
                defaultValue: "Cancel Loading"
            )
        }
    }

    static func actionSymbol(for phase: WorkboardAudioPhase) -> String {
        switch WorkboardAudioCardPresentation.transportAction(for: phase) {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .cancelLoading: return "xmark"
        }
    }

    /// What the transport is DOING, for the surfaces that speak it rather than
    /// draw it. `nil` for an idle transport, which is doing nothing worth
    /// saying.
    ///
    /// A refusal is the reason this exists: `failed` and `blocked` both leave
    /// the same "Play" action offered again, so a surface that omits them tells
    /// a VoiceOver user nothing about why the recording did not start.
    static func statusLabel(for phase: WorkboardAudioPhase) -> LocalizedStringResource? {
        switch phase {
        case .idle:
            return nil
        case .loading:
            return LocalizedStringResource("workboard.audio.loading", defaultValue: "Loading")
        case .playing:
            return LocalizedStringResource("workboard.audio.playing", defaultValue: "Playing")
        case .paused:
            return LocalizedStringResource("workboard.audio.paused", defaultValue: "Paused")
        case .failed:
            return LocalizedStringResource(
                "workboard.audio.failed",
                defaultValue: "This recording couldn’t be played"
            )
        case .blocked:
            return LocalizedStringResource(
                "workboard.audio.busy",
                defaultValue: "Audio is in use right now"
            )
        }
    }

    /// The elapsed/duration clock, from the one key every surface reads it with.
    static func clockText(elapsed: TimeInterval, duration: TimeInterval) -> String {
        String.localizedStringWithFormat(
            String(localized: LocalizedStringResource(
                "workboard.audio.position",
                defaultValue: "%1$@ of %2$@"
            )),
            WorkboardAudioTiming.label(elapsed),
            WorkboardAudioTiming.label(duration)
        )
    }
}

/// The transport's other half: how far through the clip it is, and the clock.
///
/// Separate from the control because the two are placed differently on every
/// surface — the audio card puts the glyph at the top of its tile and the track
/// below the name, the companion band puts the glyph beside the words and the
/// track under them — while saying the same thing in the same words.
///
/// It draws NOTHING until a clip has decoded: before that its length is
/// genuinely unknown, and an empty track beside "0:00 of 0:00" would state a
/// fact the surface does not have.
struct WorkboardAudioProgressTrack: View {
    let player: WorkboardAudioCardPlayer
    var placement: WorkboardAudioTransportPlacement = .card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if player.duration > 0 {
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(trackTint)
                        Capsule(style: .continuous)
                            .fill(fillTint)
                            .frame(width: proxy.size.width * player.fraction)
                    }
                }
                .frame(height: 4)
                .animation(reduceMotion ? nil : .linear(duration: 0.1), value: player.fraction)
                Text(verbatim: WorkboardAudioTransport.clockText(
                    elapsed: player.elapsed,
                    duration: player.duration
                ))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(clockTint)
                .lineLimit(1)
            }
        }
    }

    private var trackTint: Color {
        switch placement {
        case .card: return AppColors.backgroundSecondary
        case .scrim: return Color.white.opacity(0.25)
        }
    }

    private var fillTint: Color {
        switch placement {
        case .card: return AppColors.brandAmber
        case .scrim: return Color.white
        }
    }

    private var clockTint: Color {
        switch placement {
        case .card: return AppColors.textTertiary
        case .scrim: return Color.white.opacity(0.85)
        }
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
    /// Open the recording outside the transport (Quick Look / share). Offered
    /// only for bytes this device can read, and only when the board gave the
    /// card somewhere to open them.
    var onOpen: (() -> Void)? = nil
    /// Hand the recording to the system's share UI. Offered under the SAME
    /// permission as Open — both read the card's bytes — so a recording this
    /// device cannot play is never shareable from it either.
    var onShare: (() -> Void)? = nil
    /// Repair a recording whose local bytes are gone. When it is absent the
    /// availability corner states the fact instead of naming an action the card
    /// cannot perform.
    var onReattach: (() -> Void)? = nil
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

    /// The footprint every card on the desk draws into. The board grants one
    /// slot size, so a row still carrying a stored `small` or `large` renders
    /// exactly like its neighbours instead of reinstating a second density.
    private var layoutSize: WorkMaterialCardSize { .standard }

    /// ONE drawing, at one footprint, with the words the shared face policy
    /// decided. The board grants every card the same slot, so this card has no
    /// density to pick between.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                transport(dimension: 40)
                availabilityChip
                // The menu affordance owns this corner: keep content clear.
                Spacer(minLength: 26)
            }
            faceText
            progressBar
            transportStatus
            Spacer(minLength: 0)
            WorkboardMaterialNotesIndicator(material: material)
                .foregroundStyle(AppColors.textSecondary)
            cardFooter
        }
    }

    /// The transcript carries the weight.
    ///
    /// A recording's title IS its transcript's lead line — the publication lane
    /// writes it there — so a card that drew the name above the words said the
    /// same sentence twice. The face suppresses the heading in exactly that
    /// case and the words become the card; with no words the name stands on its
    /// own, which is all an undecoded clip can honestly offer.
    @ViewBuilder
    private var faceText: some View {
        if let heading = face.heading {
            Text(verbatim: heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let excerpt = face.excerpt {
                Text(verbatim: excerpt)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let excerpt = face.excerpt {
            Text(verbatim: excerpt)
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Why a tap produced no audio. It is drawn BESIDE the words rather than
    /// instead of them: a refusal is about the transport, and losing the
    /// transcript to explain it would take away the only thing on the card
    /// that says which recording this is.
    @ViewBuilder
    private var transportStatus: some View {
        if player.phase == .failed {
            Text(LocalizedStringResource(
                "workboard.audio.failed",
                defaultValue: "This recording couldn’t be played"
            ))
            .font(.caption)
            .foregroundStyle(AppColors.warning)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if player.phase == .blocked {
            // Not a broken recording — something else holds audio — so it is
            // stated in the ordinary caption tint, not as a fault.
            Text(busyCopy)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One card, one face, shared with the mosaic tile, the list row and the
    /// spoken label.
    private var face: WorkboardCardFace {
        WorkboardCardFacePolicy.face(for: material)
    }

    /// The play/pause affordance. Not a control of its own — the card is the
    /// button — so it is drawn in the transport's `tile` activation, which
    /// carries no accessibility and lets the card's own label state the phase.
    private func transport(dimension: CGFloat) -> some View {
        WorkboardAudioTransport(
            materialID: material.id,
            player: player,
            availability: material.availability,
            activation: .tile,
            dimension: dimension,
            loadPayload: loadPayload
        )
    }

    /// The same track the companion band draws, which is why it is not stated
    /// here: a card and a band showing one recording must agree about how far
    /// through it is.
    private var progressBar: some View {
        WorkboardAudioProgressTrack(player: player)
    }

    private var clockText: String {
        WorkboardAudioTransport.clockText(elapsed: player.elapsed, duration: player.duration)
    }

    /// Why a tap produced no audio when the recording itself is fine.
    private var busyCopy: LocalizedStringResource {
        LocalizedStringResource(
            "workboard.audio.busy",
            defaultValue: "Audio is in use right now"
        )
    }

    /// The demoted row. A recording's length is deliberately absent: nothing
    /// on the record measures it, and the clock the transport shows exists only
    /// once a clip has actually been decoded.
    private var cardFooter: some View {
        HStack(spacing: 6) {
            if let meta = face.meta {
                Text(verbatim: meta)
            }
            Spacer(minLength: 5)
            if face.showsAge {
                Text(material.createdAt, format: .relative(presentation: .named))
            }
        }
        .font(.caption2)
        .foregroundStyle(AppColors.textTertiary)
        .lineLimit(1)
    }

    /// The same availability vocabulary the other cards carry: a note waiting
    /// for iCloud says so and cannot be played, a note whose local bytes are
    /// gone offers the repair when the board wired one and otherwise states
    /// plainly that the bytes are elsewhere.
    @ViewBuilder
    private var availabilityChip: some View {
        if let chip = availabilityChipKind {
            if chip.isAction, let onReattach {
                Button(action: onReattach) { chipContent(chip) }
                    .pointerIconButton(
                        size: WorkboardMetrics.touchTarget,
                        shape: .capsule,
                        horizontalPadding: 4
                    )
            } else {
                chipContent(chip)
            }
        }
    }

    private func chipContent(_ chip: WorkboardAudioCardChip) -> some View {
        HStack(spacing: 3) {
            Image(systemName: chip.glyphName)
            Text(chip.label)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(chip.tint)
        // The card's own label carries the availability; a second reading of
        // the chip would repeat it. The reattach ACTION stays reachable as a
        // custom action on the card, which a nested control inside an
        // `.ignore`d element would not be.
        .accessibilityHidden(true)
    }

    private var availabilityChipKind: WorkboardAudioCardChip? {
        WorkboardAudioCardPresentation.chip(
            for: material.availability,
            hasReattachAction: onReattach != nil
        )
    }

    /// Bytes that are not readable on this device cannot be played on it. The
    /// board's one permission policy names the readable cases, so a state added
    /// later fails closed rather than opening a transport over nothing.
    private var isPlayable: Bool {
        WorkboardCardActionPolicy.allows(.play, when: material.availability)
    }

    private var shareAction: (() -> Void)? {
        WorkboardCardActionPolicy.allows(.open, when: material.availability) ? onShare : nil
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
                Label(transportActionTitle, systemImage: transportActionSymbol)
            }
        }
        if showsOpenAction {
            Button(action: openDetails) {
                Label(
                    LocalizedStringResource("workboard.material.open", defaultValue: "Open"),
                    systemImage: "arrow.up.forward.app"
                )
            }
        }
        if let shareAction {
            Button(action: shareAction) {
                Label(
                    LocalizedStringResource("workboard.material.share", defaultValue: "Share"),
                    systemImage: "square.and.arrow.up"
                )
            }
        }
        if availabilityChipKind?.isAction == true, let onReattach {
            Button(action: onReattach) {
                Label(
                    LocalizedStringResource(
                        "workboard.material.reattach.action",
                        defaultValue: "Reattach or Replace"
                    ),
                    systemImage: "paperclip"
                )
            }
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
        if showsOpenAction {
            Button(
                LocalizedStringResource("workboard.material.open", defaultValue: "Open"),
                action: openDetails
            )
        }
        // The ellipsis menu is hidden from VoiceOver, so Share reaches the
        // person here or not at all.
        if let shareAction {
            Button(
                LocalizedStringResource("workboard.material.share", defaultValue: "Share"),
                action: shareAction
            )
        }
        // The chip is drawn inside an element whose children are ignored, so
        // the repair reaches VoiceOver as a custom action or not at all.
        if availabilityChipKind?.isAction == true, let onReattach {
            Button(
                LocalizedStringResource(
                    "workboard.material.reattach.action",
                    defaultValue: "Reattach or Replace"
                ),
                action: onReattach
            )
        }
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

    /// What the next activation DOES — including the loading phase, where it
    /// cancels the payload read rather than starting playback.
    private var transportActionTitle: LocalizedStringResource {
        WorkboardAudioTransport.actionTitle(for: player.phase)
    }

    private var transportActionSymbol: String {
        WorkboardAudioTransport.actionSymbol(for: player.phase)
    }

    private var showsOpenAction: Bool {
        WorkboardAudioCardPresentation.showsOpenAction(
            availability: material.availability,
            hasOpenAction: onOpen != nil
        )
    }

    /// The label says what the card IS and what tapping it does; the value says
    /// what it is doing. Splitting them is what lets VoiceOver re-read the state
    /// after a tap without repeating the name and the transcript.
    private func openDetails() {
        // The native preview can own playback, so relinquish this card's
        // player (including an in-flight load) before handing over.
        player.deactivate()
        onOpen?()
    }

    private var accessibilityLabel: Text {
        // The kind's own copy, never a second name for the same thing: the
        // enum owns what a voice note is called everywhere else on the board.
        // Everything after it is the FACE the tile draws, said once — a name
        // that repeats the transcript is suppressed there, so it can no longer
        // be spoken and then spoken again.
        var parts = [String(localized: material.kind.title)]
        if isPlayable {
            parts.append(String(localized: transportActionTitle))
        }
        parts.append(contentsOf: face.spokenParts)
        if WorkboardMaterialNotesIndicator.isVisible(for: material) {
            parts.append(String(localized: WorkboardMaterialNotesIndicator.title))
        }
        if boardCount > 0, boardPosition > 0 {
            parts.append(Self.boardPositionLabel(position: boardPosition, count: boardCount))
        }
        return Text(parts.joined(separator: ". "))
    }

    private var accessibilityValue: Text {
        var parts: [String] = []
        if let chip = availabilityChipKind {
            parts.append(String(localized: chip.label))
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
        case .blocked:
            parts.append(String(localized: busyCopy))
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

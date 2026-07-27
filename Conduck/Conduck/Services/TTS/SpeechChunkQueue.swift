// SPDX-License-Identifier: Apache-2.0

// Conduck
// SpeechChunkQueue.swift
//
// The UNIFIED chunked-TTS playback engine — ONE implementation shared by every
// speak surface (iOS/iPadOS/macOS chat + CarPlay via `ReplyVoice`, macOS
// menu-bar arrival speak via `ReplyVoice.shared`, Apple Watch via
// `WatchReplySpeaker`). Compiles into BOTH the `Conduck` target and the
// `ConduckWatch Watch App` target (AVFoundation is available on every surface).
//
// WHAT IT DOES: given the chunks from `SpeechSegmenter`, it fetches chunk
// audio ahead of playback (bounded lookahead) and plays chunks STRICTLY in
// order, so the first spoken word arrives after synthesizing only the small
// head chunk while the tail synthesizes underneath the audio already playing.
// Chunk 2's fetch launches concurrently with chunk 1's, so it gets chunk 1's
// synth time PLUS its playback time as runway — that concurrency, not an
// explicit startup buffer, is what keeps the seams gapless.
//
// CONTRACT (mirrors the single-blob path's load-bearing invariants):
//   - `onFinished` fires EXACTLY ONCE, only after the FINAL chunk finishes.
//     Never on cancel. Callers wire it into their existing exactly-once
//     completion funnel (`ReplyVoice`'s one-shot latch / `WatchReplySpeaker`'s
//     `fireCompletion`).
//   - `onFirstAudio` fires at most once, when the FIRST audio actually starts
//     — the queue models ONE utterance to the UI (`ThreadSpeaker` stays
//     `.loading` until this, `.playing` across every chunk; there is no
//     "chunk 2 of 4" state).
//   - `onFallback(remainingText, firstAudioFired)` fires at most once, INSTEAD
//     of `onFinished`, when a chunk's synthesis fails: pending fetches are
//     abandoned and the caller speaks the UNPLAYED remainder via Apple —
//     never re-speaking played chunks, never going silent mid-reply. The
//     remainder is `segments[k...].joined()`, loss-free by the segmenter's
//     concatenation guarantee. Deferred while user-paused (audio must never
//     start under a pause).
//   - `pause()`/`resume()` span the whole queue: pausing mid-chunk pauses the
//     player in place (position preserved, no re-synthesis); pausing between
//     chunks parks the queue so a landing fetch does NOT auto-start audio.
//   - OPTIONAL `seamStallTimeout` (nil default = byte-identical behavior):
//     when playback finishes chunk k and chunk k+1 is still fetching, a grace
//     timer bounds the silent seam — expiry routes through the SAME
//     failed-chunk fallback above (Apple speaks `segments[k+1...]`), so a
//     wedged tail fetch can't strand the turn mid-reply. Head waits never arm
//     it (pre-first-audio stalls are the surface watchdog's job), and a
//     user-paused/parked queue never runs the timer (audio must never start
//     under a pause; `resume()` re-arms).
//   - `cancel()` is a hard stop — kills every fetch and player, fires nothing.
//   - AUDIO SESSION: never touches category/activation. Chunks play on
//     whatever session the surface already holds (iOS `ChatPlaybackSession`,
//     the Watch's one-per-turn activation) — same invariant as `SpeechPlayer`.
//   - PRIVACY: never logs chunk text, audio bytes, or errors. Audio Data
//     stays in memory only and is released once its chunk has played.
//
// FAILURE MODEL: a failed fetch at index k poisons k and everything after it
// (`failedIndex`), but chunks BEFORE k that are fetched or fetching still play
// — the switch to Apple happens exactly at the first unplayable chunk. A
// chunk that DIES MID-CLIP (`didFinish(successfully: false)` or a decode
// error) is a chunk FAILURE, not a completion: Apple speaks the remainder
// FROM that chunk (it may repeat the part that already played — audio-time →
// text mapping is unreliable, so content preservation wins over
// de-duplication; the tail is never silently discarded).

import Foundation
import AVFoundation

// MARK: - Cloud-player status heuristic (shared)

extension PlaybackStatus {
    /// Real playback state of a cloud-audio `AVAudioPlayer` — THE single copy
    /// of the resumable-vs-done heuristic (used by `AVChunkPlayer` here and by
    /// `WatchReplySpeaker`'s single-blob arm, so the tuned end tolerance can
    /// never drift between the chunked and whole-blob paths). A non-playing
    /// player mid-clip is a resumable OS pause (position preserved, `play()`
    /// continues); one at (or past) the end is `.inactive` — with a generous
    /// 0.3 s end tolerance so an optimistic compressed-file `duration` can't
    /// misread a done clip as resumable and ghost-replay it.
    @MainActor
    init(cloudPlayer player: AVAudioPlayer) {
        if player.isPlaying {
            self = .active
        } else if player.duration.isFinite, player.duration > 0,
                  player.currentTime > 0,
                  player.currentTime < player.duration - 0.3 {
            self = .pausedResumable
        } else {
            self = .inactive
        }
    }
}

// MARK: - Per-chunk player seam

/// One prepared, playable audio clip. Production is `AVChunkPlayer`; tests
/// substitute a fake so the queue's ordering/terminal logic is driven with no
/// audio hardware. Each chunk gets its OWN player object — per-player delegate
/// identity makes a stale terminal from a superseded chunk structurally inert.
@MainActor
protocol ChunkPlaying: AnyObject {
    /// Preroll buffers so a later `play()` starts with no decode hitch —
    /// called the moment the chunk's data lands, while earlier audio plays.
    func prepare()
    /// Begin playback. `onFinish` fires exactly once when the clip ends, with
    /// `success == true` ONLY on a natural, successful finish
    /// (`didFinish(successfully: true)`); a mid-clip decode error or
    /// `didFinish(successfully: false)` reports `false` — the queue treats
    /// that as a chunk failure (→ Apple speaks the remainder INCLUDING this
    /// chunk; never a silent tail). Returns false if playback could not start
    /// (session not ready) — the queue treats that as a chunk failure too.
    func play(onFinish: @escaping @MainActor @Sendable (_ success: Bool) -> Void) -> Bool
    /// Pause preserving position; `resume()` continues from the same point.
    func pause()
    func resume()
    /// Hard stop — releases the clip WITHOUT firing `onFinish`.
    func stop()
    /// Real playback state (drives the Watch dim-cut reconcile).
    var status: PlaybackStatus { get }
}

/// Vends a `ChunkPlaying` per chunk. Production wraps `AVAudioPlayer`; tests
/// inject controllable fakes.
@MainActor
protocol ChunkPlayerProviding {
    /// Decode `data` into a playable clip. Throws when undecodable — the
    /// queue treats that as a chunk failure (→ Apple fallback for the
    /// remainder, mirroring the single-blob path's typed
    /// `.failed(.undecodable)` outcome; a spoken reply must never go silent).
    func makePlayer(data: Data) throws -> ChunkPlaying
}

/// Production per-chunk player: one `AVAudioPlayer` + its own delegate, so
/// terminal callbacks can never cross chunks. Rides the caller's audio
/// session — NEVER calls setCategory/setActive (see file header).
@MainActor
final class AVChunkPlayer: NSObject, ChunkPlaying, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    /// Nil-then-called by `fireFinish(_:)` — the same exactly-once funnel shape
    /// as `SpeechPlayer`'s, scoped to one chunk. Carries the success flag.
    private var onFinish: (@MainActor @Sendable (Bool) -> Void)?

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
    }

    func prepare() { player.prepareToPlay() }

    func play(onFinish: @escaping @MainActor @Sendable (Bool) -> Void) -> Bool {
        self.onFinish = onFinish
        guard player.play() else {
            self.onFinish = nil
            return false
        }
        return true
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func stop() {
        onFinish = nil
        player.stop()
    }

    var status: PlaybackStatus {
        PlaybackStatus(cloudPlayer: player)
    }

    private func fireFinish(_ success: Bool) {
        let pending = onFinish
        onFinish = nil
        pending?(success)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // `successfully: false` = the clip died on a decoder error — a chunk
        // FAILURE, never a bare success (the silent-tail bug).
        Task { @MainActor in self.fireFinish(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        // Mid-clip decode error — a chunk FAILURE terminal (the queue hands
        // this chunk + the remainder to Apple). Never log the payload.
        Task { @MainActor in self.fireFinish(false) }
    }
}

/// Production factory.
@MainActor
struct AVChunkPlayerFactory: ChunkPlayerProviding {
    func makePlayer(data: Data) throws -> ChunkPlaying {
        try AVChunkPlayer(data: data)
    }
}

// MARK: - SpeechChunkQueue

/// One spoken turn's chunk pipeline: bounded-lookahead fetch, strict in-order
/// playback, queue-wide pause/resume, exactly-once terminal. Built per turn by
/// the surface engine (`ReplyVoice` / `WatchReplySpeaker`) and discarded at
/// the terminal; the engine's own supersede/cancel machinery tears it down.
@MainActor
final class SpeechChunkQueue {

    /// At most this many chunk fetches in flight at once, and never further
    /// than this many chunks beyond the one currently playing. Two is enough:
    /// chunk k+1's runway is chunk k's whole playback; prefetching deeper
    /// only spikes provider rate-limit exposure and holds more audio in
    /// memory for no smoothness gain.
    private static let lookahead = 2

    private enum ChunkState {
        case unfetched
        case fetching
        case ready(ChunkPlaying)
        /// Handed to `playingPlayer` (set at play START, not finish) — the
        /// state's job is dropping the array's player reference so a played
        /// clip's audio Data is released and the `.ready` teardown loops can
        /// never touch the live player. NOT a completion marker.
        case consumed
        case failed
    }

    private let segments: [String]
    private let fetch: @MainActor (Int, String) async throws -> Data
    private let players: ChunkPlayerProviding
    private let onFirstAudio: @MainActor () -> Void
    private let onFinished: @MainActor () -> Void
    private let onFallback: @MainActor (_ remainingText: String, _ firstAudioFired: Bool) -> Void

    /// OPTIONAL seam-stall grace (see file header). Nil (iOS/CarPlay via
    /// `ReplyVoice`) = no timer, byte-identical behavior; the Watch passes a
    /// bound because its single-attempt `WatchTTSClient` has no retry loop to
    /// self-heal a wedged tail fetch and the surface's first-audio watchdog
    /// disarms once the head speaks.
    private let seamStallTimeout: Duration?

    /// The live grace timer while playback is parked at a seam waiting on a
    /// still-fetching chunk. Armed only post-first-audio, disarmed the moment
    /// a chunk starts / on `pause()` / at every terminal.
    private var seamStallTask: Task<Void, Never>?

    private var states: [ChunkState]
    private var fetchTasks: [Int: Task<Void, Never>] = [:]

    /// Index of the chunk currently playing, or — when nothing is playing —
    /// the next chunk to play. Only ever advances.
    private var currentIndex = 0
    private var playingPlayer: ChunkPlaying?

    /// Lowest chunk index whose synthesis failed. Everything from here on is
    /// unplayable cloud-side; playback hands off to Apple when it gets here.
    private var failedIndex: Int?

    /// USER pause (via the surface's `pause()`). Parks the queue between
    /// chunks so a landing fetch can't start audio under the pause. A
    /// system pause (Watch ambient dim) never sets this — the OS pauses the
    /// player directly and `resume()` handles both identically.
    private var isPaused = false

    private var firstAudioFired = false

    /// Set at every terminal (finished / fallback / cancel). All callbacks
    /// and late fetch completions are inert afterwards.
    private var terminated = false

    /// - Parameters:
    ///   - segments: the chunk texts (from `SpeechSegmenter`; count >= 2 —
    ///     single-chunk turns use the surface's existing one-POST path).
    ///   - fetch: synthesize one chunk's audio. iOS/macOS wraps the
    ///     turn-start TTS snapshot + `TTSFetching`; the Watch wraps
    ///     `WatchTTSClient`. Runs on the main actor (the await hops
    ///     internally, same as the single-blob path).
    ///   - players: per-chunk player factory (production: `AVChunkPlayerFactory`).
    ///   - seamStallTimeout: optional mid-turn seam grace (nil = no timer —
    ///     iOS/CarPlay keep the fetch's own transport timeout as the only
    ///     bound; the Watch passes ~10 s). See the file-header contract.
    ///   - onFirstAudio: first audible chunk started (→ `.startedPlaying`).
    ///   - onFinished: final chunk finished — the turn's ONLY success terminal.
    ///   - onFallback: chunk `k` unplayable — speak `remainingText` via Apple.
    ///     `firstAudioFired` tells the caller whether the start signal already
    ///     fired (don't re-emit `.startedPlaying` from the Apple leg).
    init(
        segments: [String],
        fetch: @escaping @MainActor (Int, String) async throws -> Data,
        players: ChunkPlayerProviding,
        seamStallTimeout: Duration? = nil,
        onFirstAudio: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor () -> Void,
        onFallback: @escaping @MainActor (_ remainingText: String, _ firstAudioFired: Bool) -> Void
    ) {
        self.segments = segments
        self.fetch = fetch
        self.players = players
        self.seamStallTimeout = seamStallTimeout
        self.onFirstAudio = onFirstAudio
        self.onFinished = onFinished
        self.onFallback = onFallback
        self.states = Array(repeating: .unfetched, count: segments.count)
    }

    // MARK: - Public API

    /// Kick off the pipeline: launches the head chunk's fetch AND the next
    /// one concurrently (that immediate second launch is what buys the tail
    /// its synth runway — see file header).
    func start() {
        topUpFetches()
    }

    /// Pause the turn in place. Mid-chunk: the player pauses (position kept).
    /// Between chunks: the queue parks — a chunk that becomes ready will NOT
    /// auto-start until `resume()`. A parked queue must not run the seam-stall
    /// timer either (its expiry starts Apple audio, and audio must never start
    /// under a pause) — `resume()` re-arms via `advanceIfPossible`.
    func pause() {
        isPaused = true
        disarmSeamStall()
        playingPlayer?.pause()
    }

    /// Resume from wherever the pause landed: continue the paused player, or
    /// start the next ready chunk, or (if it's still fetching) un-park so it
    /// auto-starts on arrival. Also resumes a player the SYSTEM paused (Watch
    /// ambient dim) even though `pause()` was never called — `ThreadSpeaker`'s
    /// reconcile only flips UI state, then calls `resume()` on the engine.
    func resume() {
        isPaused = false
        if let player = playingPlayer {
            player.resume()
        } else {
            advanceIfPossible()
        }
    }

    /// Hard stop: cancel every fetch, stop any playback, fire NO callbacks.
    /// The surface's supersede/cancel path owns this (its own completion
    /// contract already guarantees the abandoned turn stays silent).
    func cancel() {
        terminated = true
        disarmSeamStall()
        for task in fetchTasks.values { task.cancel() }
        fetchTasks = [:]
        playingPlayer?.stop()
        playingPlayer = nil
        releaseReadyPlayers()
    }

    /// Real playback state for the Watch dim-cut reconcile.
    ///   - Terminal → `.inactive`.
    ///   - USER-paused → `.pausedResumable` (a paused turn is resumable by
    ///     construction, whether the pause landed mid-chunk or in a gap).
    ///   - Playing a chunk → the player's truth, EXCEPT: a mid-queue player
    ///     that reads `.inactive` (OS-paused inside the 0.3 s end tolerance)
    ///     reports `.pausedResumable` — the single-blob heuristic's cost
    ///     asymmetry FLIPS here: for a blob, a near-end `.inactive` loses
    ///     nothing, but mid-queue it would make the reconcile silently cancel
    ///     every remaining chunk. Worst case of the override is a ≤0.3 s
    ///     replay of one chunk tail, after which the queue advances normally.
    ///     The FINAL chunk keeps the blob semantics (about to finish, nothing
    ///     behind it to lose).
    ///   - Fetching / between chunks → `.active` (the queue is alive, audio
    ///     imminent — reconcile must not kill it). Known edge: an ambient-dim
    ///     suspension landing exactly in a gap is invisible here; reporting
    ///     paused instead would break tap-to-pause during ordinary gaps, a
    ///     far more common event than a dim-cut inside the one wrist seam.
    var playbackStatus: PlaybackStatus {
        if terminated { return .inactive }
        if isPaused { return .pausedResumable }
        if let player = playingPlayer {
            let status = player.status
            if case .inactive = status, currentIndex < segments.count - 1 {
                return .pausedResumable
            }
            return status
        }
        return .active
    }

    // MARK: - Pipeline

    /// Keep the fetch pipeline full: at most `lookahead` fetches in flight,
    /// never beyond `currentIndex + lookahead`, never past a failed index
    /// (everything from there falls back to Apple anyway).
    private func topUpFetches() {
        guard !terminated else { return }
        let windowEnd = min(currentIndex + Self.lookahead, segments.count - 1)
        let bound = failedIndex ?? Int.max
        var index = currentIndex
        while fetchTasks.count < Self.lookahead, index <= windowEnd {
            if index < bound, case .unfetched = states[index] {
                launchFetch(index)
            }
            index += 1
        }
    }

    private func launchFetch(_ index: Int) {
        states[index] = .fetching
        fetchTasks[index] = Task { @MainActor in
            do {
                let data = try await fetch(index, segments[index])
                guard !Task.isCancelled, !terminated else { return }
                fetchTasks[index] = nil
                do {
                    let player = try players.makePlayer(data: data)
                    player.prepare()
                    states[index] = .ready(player)
                    advanceIfPossible()
                    topUpFetches()
                } catch {
                    // Undecodable audio — a chunk failure, same as a fetch
                    // throw. Never log the bytes or error.
                    handleFetchFailure(at: index)
                }
            } catch {
                guard !Task.isCancelled, !terminated else { return }
                fetchTasks[index] = nil
                handleFetchFailure(at: index)
            }
        }
    }

    private func handleFetchFailure(at index: Int) {
        states[index] = .failed
        failedIndex = min(failedIndex ?? index, index)
        // Chunks past the failure point will never play — abandon their
        // fetches and drop any audio already fetched for them. Chunks BEFORE
        // it keep fetching/playing; the Apple handoff happens exactly when
        // playback reaches the failed index.
        if let bound = failedIndex {
            for (i, task) in fetchTasks where i >= bound {
                task.cancel()
                fetchTasks[i] = nil
            }
            for i in bound..<segments.count {
                if case .ready(let player) = states[i] {
                    player.stop()
                    states[i] = .failed
                }
            }
        }
        advanceIfPossible()
    }

    /// The one place playback advances. No-ops while a chunk is playing,
    /// while user-paused (fallback included — audio must never start under a
    /// pause; `resume()` re-enters here), or after a terminal.
    private func advanceIfPossible() {
        guard !terminated, playingPlayer == nil, !isPaused else { return }
        if let failed = failedIndex, currentIndex >= failed {
            triggerFallback(from: currentIndex)
            return
        }
        guard currentIndex < segments.count else {
            finish()
            return
        }
        if case .ready(let player) = states[currentIndex] {
            startPlaying(player, at: currentIndex)
        } else {
            // Still fetching — playback resumes when it lands. The optional
            // seam-stall grace bounds this silent wait.
            armSeamStallIfNeeded()
        }
    }

    private func startPlaying(_ player: ChunkPlaying, at index: Int) {
        disarmSeamStall()   // the seam wait (if any) just ended
        playingPlayer = player
        let started = player.play(onFinish: { [weak self] success in
            self?.chunkFinished(at: index, success: success)
        })
        guard started else {
            // Couldn't start (session not ready) — unplayable here means
            // unplayable for every later chunk too: hand the remainder to
            // Apple (mirrors the single-blob "play() == false" fallback).
            playingPlayer = nil
            states[index] = .failed
            triggerFallback(from: index)
            return
        }
        states[index] = .consumed  // player owned by `playingPlayer` from here
        if !firstAudioFired {
            firstAudioFired = true
            onFirstAudio()
        }
        topUpFetches()
    }

    private func chunkFinished(at index: Int, success: Bool) {
        guard !terminated, index == currentIndex else { return }
        playingPlayer = nil
        guard success else {
            // The chunk died mid-clip (`successfully: false` / decode error) —
            // a chunk FAILURE, not a completion. Apple speaks the remainder
            // FROM this chunk: it may repeat the part that already played
            // (audio-time → text mapping is unreliable, so no truncation is
            // attempted), but it never silently discards the unspoken tail.
            // Routed through `handleFetchFailure` (not `triggerFallback`
            // directly) so the fallback inherits the `advanceIfPossible`
            // pause deferral STRUCTURALLY — audio must never start under a
            // user pause, even though a paused player emits no terminals
            // today — plus the ≥index fetch cleanup.
            handleFetchFailure(at: index)
            return
        }
        currentIndex += 1
        advanceIfPossible()
        topUpFetches()
    }

    private func finish() {
        guard !terminated else { return }
        terminated = true
        disarmSeamStall()
        onFinished()
    }

    private func triggerFallback(from index: Int) {
        guard !terminated else { return }
        terminated = true
        disarmSeamStall()
        for task in fetchTasks.values { task.cancel() }
        fetchTasks = [:]
        releaseReadyPlayers()
        let remaining = segments[index...].joined()
        onFallback(remaining, firstAudioFired)
    }

    // MARK: - Seam-stall grace

    /// Arm the grace timer for the CURRENT seam wait, if configured. Armed only
    /// when playback is genuinely parked on a not-yet-ready chunk AND audio has
    /// already started (`firstAudioFired` — a pre-first-audio stall is the
    /// surface engine's first-audio watchdog's job, not the queue's), never
    /// while user-paused, and never re-armed over a live timer (the repeated
    /// `advanceIfPossible` calls from landing lookahead fetches must not reset
    /// the deadline). Expiry treats the awaited chunk as failed and routes
    /// through the EXISTING fallback machinery — played chunks are never
    /// re-spoken, `onFinished` never fires.
    private func armSeamStallIfNeeded() {
        guard let timeout = seamStallTimeout,
              seamStallTask == nil,
              firstAudioFired,
              !terminated, !isPaused,
              currentIndex < segments.count else { return }
        let index = currentIndex
        seamStallTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.seamStallTask = nil
            // Re-verify the wait is still the SAME stuck seam (all MainActor-
            // serialized, so a disarm that ran first already cancelled us —
            // these guards are belt-and-braces against any missed edge).
            guard !self.terminated, !self.isPaused,
                  self.playingPlayer == nil,
                  self.currentIndex == index else { return }
            self.handleFetchFailure(at: index)
        }
    }

    /// Disarm sites: a chunk starts playing (the wait ended), `pause()` (a
    /// parked queue must not run the timer), and every terminal. All
    /// main-actor, so arm/fire/disarm are serialized.
    private func disarmSeamStall() {
        seamStallTask?.cancel()
        seamStallTask = nil
    }

    private func releaseReadyPlayers() {
        for (i, state) in states.enumerated() {
            if case .ready(let player) = state {
                player.stop()
                states[i] = .failed
            }
        }
    }
}

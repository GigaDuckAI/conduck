// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayVADPolicy.swift
//
// The two pure pieces of the CarPlay end-of-speech policy, kept out of
// `EndOfSpeechDetector` so both can be exercised without loading a CoreML model
// or opening an audio session. No platform import and no `#if os(iOS)` gate:
// nothing here is CarPlay-specific in the code itself, only in its intended use
// (same arrangement as `CarPlayConversationLabel`).
//
// `SpeechCorroborationGate` is the MINIMUM-SPEECH gate. FluidAudio's streaming
// entry point reads only `negativeThreshold`, `negativeThresholdOffset`,
// `speechPadding` and `minSilenceDuration` off its segmentation config (the
// entry threshold comes from the manager's own `VadConfig.defaultThreshold`);
// its `minSpeechDuration`, `maxSpeechDuration` and `silenceThresholdForSplit`
// settings apply to the batch segmenter and are ignored on the streaming path.
// So a SINGLE 256 ms chunk of road noise crossing the threshold is enough to
// make the library declare speech, and the missing minimum-speech rule has to
// be built here.
//
// It is deliberately driven by RAW per-chunk probabilities and never by the
// library's triggered/in-speech state. Entry at `threshold` releases only at
// `threshold - 0.15`, and that release is then held for the whole
// `minSilenceDuration` — so after a one-chunk blip the library still reports
// "in speech" for several quiet chunks. State-based corroboration would
// therefore auto-approve the exact blip this gate exists to reject.
//
// Accepted trade-off, stated honestly: a genuine but very short utterance that
// yields only ONE chunk at or above the threshold is discarded. That is not
// limited to exotic ultra-short speech — a ~260 ms "yes" can straddle two chunk
// boundaries and still produce a single qualifying chunk. The failure is soft:
// the microphone is still live, the session is still alive, and the user
// repeats themselves. It is strictly better than the alternative it replaces,
// where a blip ended the capture, produced an empty transcript, and killed the
// session.

import Foundation

/// Consecutive-qualifying-chunk gate over raw VAD probabilities.
///
/// Feed every chunk probability in via `observe(probability:)` in arrival
/// order. The gate reports the moment an episode becomes corroborated; the
/// caller treats that as "speech really started" and cancels its no-speech
/// kill timer.
struct SpeechCorroborationGate: Equatable {

    /// What one observation did to the gate.
    enum Observation: Equatable {
        /// Below threshold (or not a finite number) — the run resets to zero.
        case belowThreshold
        /// At or above threshold, but the run is still short of
        /// `requiredConsecutiveChunks`.
        case qualifying
        /// This chunk completed the run. Reported EXACTLY ONCE per gate: every
        /// later observation reports `.alreadyCorroborated`, so a caller can
        /// wire an at-most-once "speech started" callback straight to it.
        case corroborated
        /// The gate was already corroborated before this observation.
        case alreadyCorroborated
    }

    /// Two consecutive qualifying chunks ≈ 512 ms of above-threshold audio.
    /// One is a blip; three would start rejecting ordinary short answers.
    static let defaultRequiredConsecutiveChunks = 2

    /// Entry probability a chunk must reach to count. The CarPlay preset passes
    /// `Constants.carPlayVADThreshold`.
    let threshold: Float

    /// How many consecutive qualifying chunks corroborate an episode.
    let requiredConsecutiveChunks: Int

    /// Length of the current run of qualifying chunks. Zero once corroborated
    /// (the run has done its job) and zero after any below-threshold chunk.
    /// Read by the expiry-boundary grace: a run in progress when the no-speech
    /// timer fires means speech may have started just inside the deadline.
    private(set) var consecutiveQualifyingChunks = 0

    /// Whether this gate has corroborated an episode. Latches for the life of
    /// the gate — one gate is built per listen.
    private(set) var isCorroborated = false

    init(
        threshold: Float,
        requiredConsecutiveChunks: Int = SpeechCorroborationGate.defaultRequiredConsecutiveChunks
    ) {
        self.threshold = threshold
        self.requiredConsecutiveChunks = max(1, requiredConsecutiveChunks)
    }

    /// `true` while a qualifying run is under way but not yet long enough. The
    /// no-speech timeout defers by one chunk quantum when this is set, so a
    /// first qualifying frame arriving a hair before the deadline is not lost
    /// to it.
    var hasPendingQualifyingChunks: Bool {
        !isCorroborated && consecutiveQualifyingChunks > 0
    }

    /// Observe one chunk probability.
    ///
    /// Non-finite probabilities (NaN, which a broken compute path produces)
    /// count as below threshold and break the run — they are never evidence of
    /// speech. Whether they are evidence of a BROKEN pipeline is a separate
    /// question, answered by `CapturePipelineHealth`.
    @discardableResult
    mutating func observe(probability: Float) -> Observation {
        guard probability.isFinite, probability >= threshold else {
            consecutiveQualifyingChunks = 0
            return isCorroborated ? .alreadyCorroborated : .belowThreshold
        }
        guard !isCorroborated else { return .alreadyCorroborated }

        consecutiveQualifyingChunks += 1
        guard consecutiveQualifyingChunks >= requiredConsecutiveChunks else {
            return .qualifying
        }
        isCorroborated = true
        consecutiveQualifyingChunks = 0
        return .corroborated
    }
}

/// What a `minSilenceDuration` in seconds actually costs at the microphone.
///
/// The streaming VAD consumes fixed 4096-sample frames at 16 kHz, so every
/// silence duration is rounded UP to a whole number of 256 ms chunks — and the
/// first silent chunk contributes nothing to the library's silence counter,
/// which adds one more. Two settings inside the same 256 ms band therefore
/// behave identically: the dial has dead zones, and picking a value without
/// this arithmetic in hand is guesswork.
enum CarPlayVADQuantization {

    /// One streaming frame: 4096 samples at 16 kHz.
    static let chunkDuration: TimeInterval = 0.256

    /// Trailing silence the user actually experiences before end-of-speech
    /// fires, for a given `minSilenceDuration` setting.
    ///
    /// `felt = (ceil(minSilence / 0.256) + 1) × 0.256`
    ///
    /// | `minSilence` | felt |
    /// |---|---|
    /// | (0.512, 0.768] | 1.024 s |
    /// | (0.768, 1.024] | 1.280 s |
    /// | (1.024, 1.280] | 1.536 s |
    /// | (1.280, 1.536] | 1.792 s |
    /// | (1.536, 1.792] | 2.048 s |
    ///
    /// The intervals are half-open on the LEFT, so a setting sitting exactly on
    /// a 256 ms multiple belongs to the band below it. A bare `ceil` in binary
    /// floating point does not reliably agree — `0.768 / 0.256` can land a
    /// hair above 3 — so the quotient is nudged down by a tolerance far smaller
    /// than any interval anyone would configure.
    static func feltEndOfSpeechDelay(minSilence: TimeInterval) -> TimeInterval {
        guard minSilence > 0 else { return chunkDuration }
        let quotient = minSilence / chunkDuration
        let chunks = ceil(quotient - 1e-9) + 1
        return chunks * chunkDuration
    }
}

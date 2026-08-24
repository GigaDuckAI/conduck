// SPDX-License-Identifier: Apache-2.0

// Conduck
// CapturePipelineHealth.swift
//
// Answers ONE question, asked at the moment a CarPlay listen times out with no
// corroborated speech: was the driver quiet, or did the capture pipeline break?
// Those two look identical from the state machine's seat — nothing happened —
// and they need opposite answers. A quiet driver gets the ordinary sign-off; a
// dead microphone gets told the microphone is dead, because "Talk to you
// later." for a wedged HFP route sends someone away believing they were heard.
//
// Three pieces, deliberately separated:
//   - `CapturePipelineCounters` — a plain value: what the tap, the converter and
//     the VAD did during one tap epoch.
//   - `CapturePipelineHealthCollector` — the thread-safe accumulator. It is
//     written from the audio tap thread, from the VAD task, and read from the
//     main-actor timer, so every access goes through one lock.
//   - `CapturePipelineHealth.classify` — pure: counters in, verdict out. All of
//     the judgement lives here and none of it needs audio to test.
//
// EPOCH SCOPE is load-bearing. The engine-configuration-change path reinstalls
// the tap mid-listen. Cumulative lifetime totals would let one healthy
// conversion from before the reconfiguration mask a pipeline that died after
// it, so the collector is reset at each tap install and the verdict describes
// only the CURRENT epoch. The other edge of that same knife: an epoch that
// began moments before the window closed has empty counters because it is new,
// not because anything is wrong, so an epoch younger than
// `minimumEvidenceWindow` convicts nobody.
//
// Honest limit, so nobody reads more into a verdict than it carries: a dead
// hands-free path that emits comfort noise or dither is indistinguishable from
// a genuinely quiet cabin by these signals. It falls through to
// `genuinelyQuiet`. Conservative on purpose — a false "microphone broken" line
// spoken at a driver who simply had nothing to say is the worse error.

import Foundation
import os

/// What one tap epoch of a CarPlay listen observed. All counters are
/// monotonic within an epoch and reset together.
struct CapturePipelineCounters: Sendable, Equatable {

    /// Buffers delivered by the engine's input tap.
    var tapBuffersReceived = 0

    /// Conversions from the native input format to 16 kHz mono Float32 that
    /// produced a buffer.
    var converterSuccesses = 0

    /// Conversions that produced nothing — a converter error, a degenerate
    /// input format, or a failed output allocation. All three mean the same
    /// thing downstream: no samples reached the VAD or the file.
    var converterFailures = 0

    /// Total converted samples across every successful conversion.
    var convertedSampleCount = 0

    /// Largest absolute sample amplitude seen across every converted sample.
    /// Exactly `0` after real conversions is the signature of a hands-free
    /// microphone that has been handed to us but is delivering digital zeros.
    var peakAmplitude: Float = 0

    /// Samples handed to the VAD's input stream by the tap.
    var vadSamplesEnqueued = 0

    /// Whole VAD frames those samples add up to. Derived by the collector,
    /// which knows the frame size, so the classifier does not have to.
    var vadFullFramesEnqueued = 0

    /// Frames the VAD actually ran inference on.
    var vadChunksProcessed = 0

    /// Largest probability the VAD returned.
    var maxProbability: Float = 0

    /// Whether any probability came back NaN or infinite — the signature of a
    /// broken compute path rather than of silence.
    var sawNonFiniteProbability = false

    /// Whether the streaming task threw.
    var vadTaskFailed = false

    /// Live mirror of `SpeechCorroborationGate.consecutiveQualifyingChunks`,
    /// republished on every chunk so the main actor can see whether a
    /// qualifying run is in progress. NOT an epoch health counter — it
    /// describes the gate's current state, so a tap reinstall leaves it alone.
    var consecutiveQualifyingChunks = 0

    /// Whether the corroboration gate has confirmed an episode in this listen.
    ///
    /// Published from the VAD task BEFORE it hops to the main actor to announce
    /// the same fact, because that hop can be overtaken by an already-enqueued
    /// no-speech timeout. In that window the run mirror above has already reset
    /// to zero (corroboration ends the run) and the main actor has not yet
    /// learned anything, so this is the only evidence left that someone is
    /// talking. Like the mirror, it belongs to the listen rather than to the
    /// tap epoch and survives a reinstall.
    var didCorroborateSpeech = false

    /// How long the current tap epoch had been running when this snapshot was
    /// taken. Not evidence about the pipeline — evidence about how much
    /// evidence there is. See `CapturePipelineHealth.classify`.
    var epochDuration: TimeInterval = 0
}

/// Why a listen ended with no corroborated speech.
enum CapturePipelineVerdict: String, Sendable, Equatable {
    /// No audio is reaching us: the tap delivered nothing at all, or it
    /// delivered real converted samples that are all digital zero.
    case micSilent
    /// Audio is arriving but nothing can be converted to the VAD's format.
    case formatBroken
    /// Audio converted fine, but the detector never produced usable
    /// probabilities.
    case vadBroken
    /// Everything worked. Nobody spoke.
    case genuinelyQuiet

    /// Whether this verdict means the pipeline failed (as opposed to the cabin
    /// simply being quiet). Drives which line the session speaks on its way out.
    var isBroken: Bool { self != .genuinelyQuiet }
}

/// The pure verdict function.
enum CapturePipelineHealth {

    /// How long a tap epoch has to have run before its counters may convict.
    ///
    /// Two reachable ways a young epoch lies. A tap reinstalled a fraction of a
    /// second before the deadline has received no buffers yet — one buffer
    /// period is 256 ms at 16 kHz and 512 ms at an 8 kHz hands-free rate, plus
    /// the engine restart. And a hands-free link that has just renegotiated
    /// commonly delivers a short run of literal digital-zero buffers while the
    /// codec spins up: those convert successfully and carry a peak of exactly
    /// zero, which is the signature the dead-microphone arm looks for. Two
    /// seconds clears both.
    ///
    /// It costs nothing in the ordinary case: an epoch normally lasts the whole
    /// 15 s or 30 s listen. The only verdicts it suppresses are ones about a
    /// pipeline that broke in the last two seconds before the window closed —
    /// and those sign off as quiet, which is the direction this type errs in
    /// everywhere else.
    static let minimumEvidenceWindow: TimeInterval = 2

    /// Classify one epoch's counters.
    ///
    /// ORDER MATTERS and the guardrails are the point:
    ///
    /// 1. `micSilent` — zero tap buffers, or converted samples that are
    ///    uniformly zero. The zero-peak arm requires `converterSuccesses > 0`
    ///    AND `convertedSampleCount > 0`: without that precondition a failing
    ///    converter, whose peak is simply never updated, would masquerade as a
    ///    dead microphone and be reported as the wrong fault.
    /// 2. `formatBroken` — buffers arrived, every conversion failed.
    /// 3. `vadBroken` — a whole frame was enqueued and the VAD ran nothing, or
    ///    a probability came back non-finite, or the task threw.
    /// 4. `genuinelyQuiet` — everything else.
    ///
    /// FINITE ALL-ZERO PROBABILITIES ARE NOT BROKEN. A run of zeros is what a
    /// quiet cabin looks like, and a quiet driver must never hear that the
    /// microphone failed. They are worth a suspicious-telemetry log line at the
    /// call site; they are not worth a verdict.
    ///
    /// AND NEITHER IS AN EPOCH TOO YOUNG TO HAVE SEEN ANYTHING — the arm that
    /// runs before all of them. An engine reconfiguration reinstalls the tap
    /// mid-listen and starts a fresh epoch, so an epoch that began a moment
    /// before the deadline has empty counters for the same reason a stopwatch
    /// reads zero the instant it starts. Convicting on that says the microphone
    /// is broken to a driver whose HFP link merely resettled, which is the one
    /// sentence this type must never get wrong.
    static func classify(_ counters: CapturePipelineCounters) -> CapturePipelineVerdict {
        if counters.epochDuration < minimumEvidenceWindow {
            return .genuinelyQuiet
        }
        if counters.tapBuffersReceived == 0 {
            return .micSilent
        }
        if counters.converterSuccesses > 0,
           counters.convertedSampleCount > 0,
           counters.peakAmplitude == 0 {
            return .micSilent
        }
        if counters.converterSuccesses == 0, counters.converterFailures > 0 {
            return .formatBroken
        }
        if counters.vadFullFramesEnqueued > 0, counters.vadChunksProcessed == 0 {
            return .vadBroken
        }
        if counters.sawNonFiniteProbability || counters.vadTaskFailed {
            return .vadBroken
        }
        return .genuinelyQuiet
    }

    /// Whether an epoch's probabilities were all finite zeros despite the VAD
    /// having run. Not a fault — see `classify` — but worth logging, because it
    /// is also what a silently mis-compiled model looks like.
    static func hasSuspiciousAllZeroProbabilities(_ counters: CapturePipelineCounters) -> Bool {
        counters.vadChunksProcessed > 0
            && !counters.sawNonFiniteProbability
            && counters.maxProbability == 0
    }
}

/// Thread-safe accumulator for one listen.
///
/// Touched from three places with no ordering between them — the audio tap's
/// render thread, the VAD's streaming task, and the main-actor no-speech timer
/// — so the whole value sits behind one unfair lock and every mutation is a
/// single locked read-modify-write. The lock is held only for arithmetic on a
/// small struct, which is short enough to be safe on the audio thread.
final class CapturePipelineHealthCollector: Sendable {

    /// Counters plus the moment the current tap epoch began. The instant lives
    /// here rather than in `CapturePipelineCounters` so the value the classifier
    /// judges stays a plain set of numbers; `snapshot()` turns it into
    /// `epochDuration` on the way out. `ContinuousClock` because this is a
    /// duration between two points in one process — a wall clock that the user
    /// or the network moves would make an epoch look older or younger than it is.
    private struct LockedState: Sendable {
        var counters = CapturePipelineCounters()
        var epochStart = ContinuousClock.now
    }

    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    init() {}

    /// Start a new tap epoch: the listen is starting, or the tap has just been
    /// reinstalled after an engine reconfiguration.
    ///
    /// The two corroboration fields deliberately survive — they describe the
    /// live gate, which belongs to the listen and is not rebuilt by a
    /// reconfiguration. The epoch clock restarts with the counters, which is
    /// what lets `classify` tell an empty epoch from a young one.
    func beginTapEpoch() {
        state.withLock { locked in
            let pending = locked.counters.consecutiveQualifyingChunks
            let corroborated = locked.counters.didCorroborateSpeech
            locked.counters = CapturePipelineCounters()
            locked.counters.consecutiveQualifyingChunks = pending
            locked.counters.didCorroborateSpeech = corroborated
            locked.epochStart = .now
        }
    }

    /// One buffer arrived from the input tap, before any conversion.
    func recordTapBuffer() {
        state.withLock { $0.counters.tapBuffersReceived += 1 }
    }

    /// A conversion produced samples. `peak` is the largest absolute amplitude
    /// in this buffer.
    func recordConversion(sampleCount: Int, peak: Float) {
        state.withLock { locked in
            locked.counters.converterSuccesses += 1
            locked.counters.convertedSampleCount += sampleCount
            if peak.isFinite, peak > locked.counters.peakAmplitude {
                locked.counters.peakAmplitude = peak
            }
        }
    }

    /// A conversion produced nothing.
    func recordConversionFailure() {
        state.withLock { $0.counters.converterFailures += 1 }
    }

    /// Samples were handed to the VAD's input stream. `frameSampleCount` is the
    /// detector's frame size, which is what turns a sample count into a whole
    /// frame count here rather than in the classifier.
    func recordVADSamplesEnqueued(_ count: Int, frameSampleCount: Int) {
        guard count > 0, frameSampleCount > 0 else { return }
        state.withLock { locked in
            locked.counters.vadSamplesEnqueued += count
            locked.counters.vadFullFramesEnqueued =
                locked.counters.vadSamplesEnqueued / frameSampleCount
        }
    }

    /// The VAD ran inference on one frame and returned `probability`.
    func recordVADChunk(probability: Float) {
        state.withLock { locked in
            locked.counters.vadChunksProcessed += 1
            if probability.isFinite {
                if probability > locked.counters.maxProbability {
                    locked.counters.maxProbability = probability
                }
            } else {
                locked.counters.sawNonFiniteProbability = true
            }
        }
    }

    /// The streaming task threw.
    func recordVADTaskFailure() {
        state.withLock { $0.counters.vadTaskFailed = true }
    }

    /// Republish the corroboration gate's current run length.
    func recordCorroborationRun(_ length: Int) {
        state.withLock { $0.counters.consecutiveQualifyingChunks = length }
    }

    /// The gate corroborated an episode. Called from the VAD task BEFORE it
    /// announces the same thing on the main actor, so a no-speech timeout that
    /// runs in between still finds the evidence — see `didCorroborateSpeech`.
    func recordCorroboratedSpeech() {
        state.withLock { $0.counters.didCorroborateSpeech = true }
    }

    /// Consistent snapshot for classification and logging, stamped with the age
    /// of the current tap epoch.
    func snapshot() -> CapturePipelineCounters {
        state.withLock { locked in
            var counters = locked.counters
            let elapsed = locked.epochStart.duration(to: .now).components
            counters.epochDuration =
                TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
            return counters
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import os.log

/// End-of-speech detection for the CarPlay GigaNote flow.
///
/// Pure VAD consumer wrapping FluidAudio's `VadManager` (Silero VAD via CoreML,
/// ANE-optimized). The owning capture pipeline drives audio in via
/// `processFixedBuffer(_:)` — buffers MUST already be at 16 kHz mono Float32,
/// non-interleaved (Silero's required input). This class accumulates exact
/// 4096-sample frames (256 ms @ 16 kHz, Silero's required chunk size) and
/// fires `onEndOfSpeech` once Silero declares the user has stopped speaking —
/// but only for an episode a `SpeechCorroborationGate` has confirmed was more
/// than one loud chunk. Language-agnostic — same model works for all 13 Voxtral
/// languages without locale binding.
///
/// The capture-side conversion (native input format → 16 kHz Float32) is owned
/// by `CarPlayRecordingService`, not this class. That moves the converter
/// alongside the route-tolerant `AVAudioFile`, so when CarPlay's HFP route
/// negotiation completes mid-recording (an `AVAudioEngineConfigurationChange`
/// event), only one converter has to be rebuilt — and the file format on disk
/// stays stable across the reconfig.
///
/// Why FluidAudio rather than Apple `SpeechDetector`: `SpeechAnalyzer` rejects
/// detector-only module lists at runtime and forces pairing with
/// `SpeechTranscriber`, which would trigger an `SFSpeechRecognizer`
/// authorization prompt and pull on-device speech models per locale (×13 for
/// our language set). We don't need transcription on-device — Voxtral handles
/// transcription server-side. FluidAudio is pure VAD: no permission prompt, no
/// privacy taxonomy concerns.
///
/// TUNING. There are exactly two dials, both in `Constants`, and both are read
/// by the single caller (`CarPlayRecordingService.startListening`):
///
/// - `Constants.carPlayVADThreshold` (0.65) — the probability a 256 ms chunk
///   must reach to count as speech. Higher rejects more road and cabin noise
///   and starts dropping quiet talkers; lower does the reverse. The library
///   releases at threshold − 0.15, so 0.65 in means 0.50 out.
/// - `Constants.carPlayVADMinSilence` (1.5 s) — how much silence ends a turn.
///   Raise it if the car cuts people off mid-thought; lower it if the session
///   lingers after they finish. Its effect is QUANTIZED into 256 ms steps and
///   costs one extra chunk on top, so two nearby values can behave
///   identically — compute what a candidate actually buys with
///   `CarPlayVADQuantization.feltEndOfSpeechDelay(minSilence:)`, whose doc
///   comment carries the step table. At 1.5 s the felt endpoint is 1.792 s.
///
/// The minimum-speech side of the tuning is NOT a library setting — see
/// `SpeechCorroborationGate` and the `init` note below.
@MainActor
final class EndOfSpeechDetector {
    typealias Callback = @MainActor () -> Void

    /// Model-load failures surfaced out of `start()`.
    enum LoadError: Error {
        /// The bundled Silero `.mlmodelc` did not resolve in `Bundle.main`.
        ///
        /// Deliberately fail-closed: FluidAudio's *other* `VadManager` init
        /// (`init(config:)`, async) resolves the model by DOWNLOADING it from
        /// `huggingface.co` — a host the user never configured. Conduck's
        /// egress posture is Apple + user-configured endpoints only, so that
        /// initializer is never called from this app and this error takes its
        /// place. A build that trips this is broken (`VadModelBundleTests`
        /// fails the suite before it can ship); the CarPlay session then ends
        /// via the documented silent `startListening` setup-bailout path
        /// rather than phoning home from the car.
        case vadModelMissingFromBundle
    }

    private let onEndOfSpeech: Callback
    private let onSpeechStart: Callback?
    /// VAD speech threshold — `Constants.carPlayVADThreshold`. Drives BOTH the
    /// library's own entry decision and the corroboration gate below, so the
    /// two can never disagree about what "loud enough" means.
    private let resolvedThreshold: Float
    /// Resolved end-of-speech segmentation config (carries `minSilenceDuration`).
    private let segmentationConfig: VadSegmentationConfig
    /// Pipeline-health counters for the owning capture session, if it supplied
    /// one. Written from the tap thread and the streaming task; read by the
    /// owner's main-actor no-speech timer. Optional so the detector stays
    /// constructible without one.
    private let health: CapturePipelineHealthCollector?
    /// Marked `nonisolated` so the audio-render-thread tap callback in
    /// `processFixedBuffer` can log without an actor hop. `Logger` is
    /// `Sendable` and free-thread-safe.
    nonisolated private static let log = Logger(subsystem: Constants.identityNamespace, category: "CarPlayVAD")

    /// Audio-thread-touched state. Set once in `start()` before the owner
    /// installs its tap; cleared in `stop()` after the owner removes the tap.
    /// Sequential by contract — `processFixedBuffer` is invoked from the
    /// engine's I/O thread which serializes its own callbacks.
    private nonisolated(unsafe) var bufferContinuation: AsyncStream<[Float]>.Continuation?
    private nonisolated(unsafe) var didLogFirstBuffer = false

    private var processingTask: Task<Void, Never>?
    private var didFire = false
    private var didStart = false

    /// CarPlay preset init. `threshold` and `minSilence` both come from
    /// `Constants` (`carPlayVADThreshold`, `carPlayVADMinSilence`) so the CarPlay
    /// tuning lives in one place.
    ///
    /// Only `minSilenceDuration` is overridden on the segmentation config, and
    /// only `minSilenceDuration` has any effect here. Do not read the remaining
    /// `VadSegmentationConfig.default` fields as though they were in force:
    /// FluidAudio's STREAMING entry point reads only `negativeThreshold`,
    /// `negativeThresholdOffset`, `speechPadding` and `minSilenceDuration` off
    /// that config, and ignores `minSpeechDuration`, `maxSpeechDuration` and
    /// `silenceThresholdForSplit` — those belong to the batch segmenter, which
    /// this class never calls.
    ///
    /// The ENTRY threshold is not on that config at all: the streaming state
    /// machine takes it from `VadConfig.defaultThreshold`, which `loadManager()`
    /// sets from `threshold` below. `negativeThreshold` is left nil on purpose,
    /// because setting it does not only move the release point — the library
    /// derives the entry threshold back out of it
    /// (`min(1, negativeThreshold + negativeThresholdOffset)`), which would
    /// silently desynchronise the library's entry decision from
    /// `SpeechCorroborationGate`'s. With it nil, entry is `threshold` and
    /// release is `threshold - negativeThresholdOffset` (0.15).
    ///
    /// In particular there is NO library-side minimum-speech rule protecting us
    /// from a single noisy chunk; that job belongs to
    /// `SpeechCorroborationGate`, applied in `start()`.
    init(
        threshold: Float,
        minSilence: TimeInterval,
        health: CapturePipelineHealthCollector? = nil,
        onSpeechStart: Callback? = nil,
        onEndOfSpeech: @escaping Callback
    ) {
        self.resolvedThreshold = threshold
        var config = VadSegmentationConfig.default
        config.minSilenceDuration = minSilence
        self.segmentationConfig = config
        self.health = health
        self.onSpeechStart = onSpeechStart
        self.onEndOfSpeech = onEndOfSpeech
    }

    /// Load the VAD model and start the streaming-detection task. The owning
    /// capture pipeline awaits this before installing its input tap, so
    /// `processFixedBuffer` will not fire until setup is complete.
    ///
    /// Throws on model-load failure. A throw ENDS the CarPlay session: the sole
    /// caller (`CarPlayRecordingService.startListening`) treats it as a setup
    /// bailout and calls `endSession(speak: nil)` — silent by design, because
    /// speaking an error over a wedged audio session escalates it (see
    /// `docs/ai-context/spec.md`). Recording never starts, so the 300 s
    /// recorder cap is not the backstop here; the only throwing paths are a
    /// broken build (`LoadError.vadModelMissingFromBundle`) and a CoreML
    /// compile/load failure, both of which mean there is no working VAD to
    /// degrade to.
    ///
    /// Idempotent: calling twice is a no-op.
    func start() async throws {
        guard !didStart else { return }
        didStart = true
        didFire = false
        didLogFirstBuffer = false

        let manager = try loadManager()
        try Task.checkCancellation()

        let (sequence, continuation) = AsyncStream<[Float]>.makeStream()
        self.bufferContinuation = continuation

        // Capture the resolved segmentation config locally so the detached
        // streaming task uses the right `minSilenceDuration` without hopping
        // back to `self`.
        let segmentationConfig = self.segmentationConfig
        let health = self.health
        let threshold = self.resolvedThreshold

        processingTask = Task { [weak self] in
            do {
                var state = await manager.makeStreamState()
                // The minimum-speech gate, built per listen and owned entirely
                // by this task. Raw probabilities only — see
                // `SpeechCorroborationGate` for why the library's triggered
                // state cannot be used for this.
                var corroboration = SpeechCorroborationGate(threshold: threshold)
                var accumulator: [Float] = []
                accumulator.reserveCapacity(VadManager.chunkSize * 2)
                let frameSize = VadManager.chunkSize
                var chunkIndex = 0
                var discardedBlips = 0

                Self.log.info("VAD task started; frame size = \(frameSize, privacy: .public)")

                for await chunk in sequence {
                    accumulator.append(contentsOf: chunk)

                    while accumulator.count >= frameSize {
                        let frame = Array(accumulator.prefix(frameSize))
                        accumulator.removeFirst(frameSize)

                        let result = try await manager.processStreamingChunk(
                            frame,
                            state: state,
                            config: segmentationConfig,
                            returnSeconds: true,
                            timeResolution: 2
                        )
                        state = result.state
                        health?.recordVADChunk(probability: result.probability)

                        // First few raw probabilities help us tell `.cpuOnly`
                        // working (sane non-zero numbers) from a still-broken
                        // compute path (always 0/NaN).
                        if chunkIndex < 5 {
                            Self.log.info("VAD probability chunk \(chunkIndex, privacy: .public): \(result.probability, privacy: .public)")
                            chunkIndex += 1
                        }

                        // The corroboration gate runs on EVERY chunk, not only
                        // on library events: FluidAudio may never emit a second
                        // `.speechStart` inside one episode, so a blip that has
                        // already been discarded must still be able to be
                        // followed by real speech in the same episode.
                        let observation = corroboration.observe(probability: result.probability)
                        health?.recordCorroborationRun(corroboration.consecutiveQualifyingChunks)
                        if case .corroborated = observation {
                            // Publish BEFORE the main-actor hop below. The hop
                            // can be overtaken by a no-speech timeout already
                            // queued on that actor, and corroborating ends the
                            // qualifying run — so between these two lines the
                            // run mirror reads zero and the main actor still
                            // believes nobody has spoken. The timeout reads this
                            // flag as well, which is what stops it signing off
                            // over a driver mid-word.
                            health?.recordCorroboratedSpeech()
                            Self.log.info("VAD speech corroborated (p=\(result.probability, privacy: .public))")
                            await MainActor.run { [weak self] in
                                self?.onSpeechStart?()
                            }
                        }

                        guard let event = result.event else { continue }
                        switch event.kind {
                        case .speechStart:
                            Self.log.info("VAD .speechStart at \(event.time ?? 0, privacy: .public)s (p=\(result.probability, privacy: .public))")
                        case .speechEnd:
                            Self.log.info("VAD .speechEnd at \(event.time ?? 0, privacy: .public)s (p=\(result.probability, privacy: .public))")
                            // Uncorroborated episode: a blip, not a turn. Log
                            // and DISCARD — do not latch `didFire`, do not end
                            // the turn, and above all do not `return`: the
                            // stream keeps flowing and the gate keeps looking
                            // for a qualifying pair. The owner's no-speech kill
                            // timer counts on undisturbed through this.
                            guard corroboration.isCorroborated else {
                                discardedBlips += 1
                                Self.log.notice("VAD episode discarded as an uncorroborated blip (#\(discardedBlips, privacy: .public)); still listening")
                                continue
                            }
                            await MainActor.run {
                                guard let self, !self.didFire else { return }
                                self.didFire = true
                                self.onEndOfSpeech()
                            }
                            return
                        }
                    }
                }
            } catch {
                // Domain + code, never `localizedDescription` — a CoreML or
                // cancellation error's localized string can carry file paths and
                // is a `.public` interpolation, so it would land in the unified
                // log verbatim. Same shape both share extensions use.
                if !(error is CancellationError) {
                    health?.recordVADTaskFailure()
                }
                Self.log.error("VAD task failed: \((error as NSError).domain, privacy: .public) code \((error as NSError).code, privacy: .public)")
            }
        }
    }

    /// Feed one already-converted capture buffer into the VAD pipeline. Safe
    /// to call from the engine's I/O thread.
    ///
    /// Contract: buffer MUST be 16 kHz mono Float32 non-interleaved. Buffers
    /// at any other format are dropped with a one-time error log so we don't
    /// silently feed garbage to Silero.
    ///
    /// Caller must remove its input tap **before** calling `stop()`, so this
    /// method cannot fire concurrently with teardown.
    nonisolated func processFixedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let bufferContinuation else { return }
        guard buffer.format.sampleRate == 16000,
              buffer.format.channelCount == 1,
              buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let channelData = buffer.floatChannelData?[0] else {
            if !didLogFirstBuffer {
                didLogFirstBuffer = true
                Self.log.error("TAP: rejected buffer at \(buffer.format.sampleRate, privacy: .public)Hz \(buffer.format.channelCount, privacy: .public)ch — expected 16 kHz mono Float32")
            }
            return
        }

        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            Self.log.info("TAP: first buffer frames=\(buffer.frameLength, privacy: .public)")
        }

        let samples = Array(UnsafeBufferPointer(
            start: channelData,
            count: Int(buffer.frameLength)
        ))
        // Counted at the ENQUEUE, not at the frame boundary: "samples went in
        // and no inference came out" is exactly the signature of a streaming
        // task that never started or wedged, which is what the `vadBroken`
        // verdict is looking for.
        health?.recordVADSamplesEnqueued(samples.count, frameSampleCount: VadManager.chunkSize)
        bufferContinuation.yield(samples)
    }

    /// Stop and tear down. Idempotent — safe to call from cancelTurn,
    /// successful end-of-turn, teardown, error paths, and the 5-min cap path.
    func stop() {
        processingTask?.cancel()
        processingTask = nil

        bufferContinuation?.finish()
        bufferContinuation = nil
    }

    // MARK: - Model loading

    /// Load the Silero `.mlmodelc` from the app bundle — the ONLY way this app
    /// obtains the VAD model. A missing resource throws
    /// `LoadError.vadModelMissingFromBundle`; we never reach for FluidAudio's
    /// download-on-demand init.
    ///
    /// Why fail closed rather than degrade: the only alternative resolver
    /// FluidAudio offers fetches the model from `huggingface.co`, so "degrade
    /// gracefully" would mean a silent third-party request from a car. Conduck
    /// claims every outbound byte goes to Apple or to an endpoint the user
    /// configured; keeping the downloading initializer out of the call graph is
    /// what makes that claim checkable by a reader of this file. The
    /// precondition is a packaging defect, not a runtime condition —
    /// `VadModelBundleTests` fails the suite if the resource ever leaves the
    /// bundle, so this branch is unreachable in any build that ships.
    ///
    /// Synchronous — every step is local (bundle lookup + CoreML compile-load).
    /// Nothing here suspends, and nothing here does I/O beyond reading the app's
    /// own bundle.
    private func loadManager() throws -> VadManager {
        if let modelURL = Bundle.main.url(
            forResource: "silero-vad-unified-256ms-v6.0.0",
            withExtension: "mlmodelc"
        ) {
            // iOS Simulator does not virtualise MPSGraph; default `.all`
            // makes CoreML "load" the model but inference silently produces
            // zero/NaN probabilities. `.cpuAndNeuralEngine` matches
            // FluidAudio's HuggingFace-path default (VadConfig.computeUnits).
            let configuration = MLModelConfiguration()
            #if targetEnvironment(simulator)
            configuration.computeUnits = .cpuOnly
            #else
            configuration.computeUnits = .cpuAndNeuralEngine
            #endif
            let mlModel = try MLModel(contentsOf: modelURL, configuration: configuration)
            Self.log.info("VAD model loaded from app bundle")
            return VadManager(
                config: VadConfig(defaultThreshold: resolvedThreshold),
                vadModel: mlModel
            )
        }

        // No fallback by construction. `VadManager(config:)` (the async init)
        // would download the model from `huggingface.co`; it is never called
        // from Conduck, so no code path in this app can originate a request to
        // a host the user did not configure.
        Self.log.error("VAD model missing from app bundle — failing closed (no runtime download)")
        throw LoadError.vadModelMissingFromBundle
    }
}
#endif

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
/// fires `onEndOfSpeech` once Silero declares the user has stopped speaking.
/// Language-agnostic — same model works for all 13 Voxtral languages without
/// locale binding.
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
/// Sensitivity defaults to `.medium`. Memory-taking is pause-tolerant by
/// nature; if cabin testing shows it cuts off mid-thought (false-positive
/// silence), drop to `.low`. If it lingers too long after speech ends, raise
/// to `.high`.
@MainActor
final class EndOfSpeechDetector {
    typealias Callback = @MainActor () -> Void

    enum SensitivityLevel {
        case low, medium, high

        fileprivate var threshold: Float {
            switch self {
            case .low: return 0.6
            case .medium: return 0.5
            case .high: return 0.4
            }
        }
    }

    private let onEndOfSpeech: Callback
    private let onSpeechStart: Callback?
    /// Resolved VAD speech threshold. Either a `SensitivityLevel`'s threshold
    /// (the in-app default path) or an explicit override (the CarPlay preset —
    /// higher threshold to reject road/cabin noise).
    private let resolvedThreshold: Float
    /// Resolved end-of-speech segmentation config (carries `minSilenceDuration`).
    /// Defaults to FluidAudio's `.default`; the CarPlay preset overrides
    /// `minSilenceDuration` so a conversational pause doesn't prematurely end
    /// a turn in a noisy cabin.
    private let segmentationConfig: VadSegmentationConfig
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

    /// CarPlay preset init. Takes an explicit speech `threshold` (higher than
    /// the in-app default to reject road/cabin noise) and a `minSilence` (the
    /// end-of-speech segmentation pause). Both come from `Constants` so the
    /// CarPlay tuning lives in one place (`spec.md "Per-Surface Behavior → Apple CarPlay"`).
    init(
        threshold: Float,
        minSilence: TimeInterval,
        onSpeechStart: Callback? = nil,
        onEndOfSpeech: @escaping Callback
    ) {
        self.resolvedThreshold = threshold
        // Override only `minSilenceDuration`; keep every other segmentation
        // default (min-speech, padding, max-speech) so the preset is a
        // surgical tweak, not a wholesale config replacement.
        var config = VadSegmentationConfig.default
        config.minSilenceDuration = minSilence
        self.segmentationConfig = config
        self.onSpeechStart = onSpeechStart
        self.onEndOfSpeech = onEndOfSpeech
    }

    /// Load the VAD model and start the streaming-detection task. The owning
    /// capture pipeline awaits this before installing its input tap, so
    /// `processFixedBuffer` will not fire until setup is complete.
    ///
    /// Throws on model-load failure. Caller treats throws as non-fatal — the
    /// 5-min hard cap on the recorder still terminates the turn even with a
    /// dead VAD.
    ///
    /// Idempotent: calling twice is a no-op.
    func start() async throws {
        guard !didStart else { return }
        didStart = true
        didFire = false
        didLogFirstBuffer = false

        let manager = try await loadManager()
        try Task.checkCancellation()

        let (sequence, continuation) = AsyncStream<[Float]>.makeStream()
        self.bufferContinuation = continuation

        // Capture the resolved segmentation config locally so the detached
        // streaming task uses the right `minSilenceDuration` (in-app default
        // vs. CarPlay preset) without hopping back to `self`.
        let segmentationConfig = self.segmentationConfig

        processingTask = Task { [weak self] in
            do {
                var state = await manager.makeStreamState()
                var hasFiredSpeechStart = false
                var accumulator: [Float] = []
                accumulator.reserveCapacity(VadManager.chunkSize * 2)
                let frameSize = VadManager.chunkSize
                var chunkIndex = 0

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

                        // First few raw probabilities help us tell `.cpuOnly`
                        // working (sane non-zero numbers) from a still-broken
                        // compute path (always 0/NaN).
                        if chunkIndex < 5 {
                            Self.log.info("VAD probability chunk \(chunkIndex, privacy: .public): \(result.probability, privacy: .public)")
                            chunkIndex += 1
                        }

                        guard let event = result.event else { continue }
                        switch event.kind {
                        case .speechStart:
                            let isFirst = !hasFiredSpeechStart
                            hasFiredSpeechStart = true
                            Self.log.info("VAD .speechStart at \(event.time ?? 0, privacy: .public)s (p=\(result.probability, privacy: .public))")
                            if isFirst {
                                await MainActor.run { [weak self] in
                                    self?.onSpeechStart?()
                                }
                            }
                        case .speechEnd:
                            Self.log.info("VAD .speechEnd at \(event.time ?? 0, privacy: .public)s (p=\(result.probability, privacy: .public))")
                            guard hasFiredSpeechStart else { continue }
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
                Self.log.error("VAD task failed: \(error.localizedDescription, privacy: .public)")
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

    /// Load the Silero `.mlmodelc` from the app bundle. Falls back to the
    /// runtime HuggingFace download path only if the bundled resource is
    /// missing — which would indicate a build-config bug, but we degrade
    /// gracefully so the rest of the turn still works.
    private func loadManager() async throws -> VadManager {
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

        Self.log.error("VAD model missing from app bundle; falling back to runtime download")
        return try await VadManager(
            config: VadConfig(defaultThreshold: resolvedThreshold)
        )
    }
}
#endif

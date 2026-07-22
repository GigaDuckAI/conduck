// Conduck
// STTInProcessRunner.swift
//
// Foundation protocol for in-process (non-network) STT providers (Apple
// Native STT as a provider). The first conformance is the iOS 26
// `AppleSpeechRunner`, which `STTProvider.appleOnDevice.inProcessRunner`
// points at (`AppleSpeechRunner.self`).
//
// File IS compiled into the Watch target (alongside `STTProvider.swift`
// via `PBXFileSystemSynchronizedBuildFileExceptionSet`) so the shared
// `STTProvider.inProcessRunner: STTInProcessRunner.Type?` field resolves.
// Watch never INVOKES it — no `SpeechAnalyzer` on watchOS — and runs
// the audio-relay path to iPhone instead.

import Foundation

/// Runner protocol for in-process STT providers (Apple on-device etc.).
/// Static-method shape mirrors `STTProbe` — preserves stack-trace clarity
/// over closure-based dispatch, and lets `STTProvider` hold a metatype
/// (`STTInProcessRunner.Type?`) without needing an existential.
///
/// Conformances are stateless (e.g. an enum case-less type or a struct
/// with no stored properties) — any per-call state (audio file handles,
/// downloader progress, locale negotiation) lives inside the static
/// method's task scope.
protocol STTInProcessRunner: Sendable {
    /// Transcribe `audioFileURL` in-process. Returns the same
    /// `STTResponse` shape that network providers return, so callers
    /// (`STTClient.transcribe`) can route results identically.
    ///
    /// - Parameters:
    ///   - audioFileURL: Local file URL — runner reads via `AVAudioFile`,
    ///     never loads the entire payload into RAM (multi-minute clips
    ///     would otherwise blow the simulator process's memory limit).
    ///   - language: BCP-47 / ISO 639 hint; nil → caller defers locale
    ///     selection to the runner (typically `Locale.current`).
    static func transcribe(audioFileURL: URL, language: String?) async throws -> STTResponse
}

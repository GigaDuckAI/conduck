// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleModelInstaller.swift
//
// Workstream A — the in-place "self-heal" helper for the mic spine. The mic tap
// IS the consent to set up voice: when the active provider is Apple on-device
// and the engine's per-locale model isn't installed, the composer downloads it
// IN PLACE (quiet progress) and auto-retries the SAME recording — the user never
// leaves the chat to fix it. This file owns the AssetInventory ceremony, lifted
// from `SettingsViewModel.downloadAppleModel` (the explicit Settings download)
// and made engine-aware so the install target ALWAYS matches the engine the hot
// path will transcribe with.
//
// Engine-correctness invariant: `isReady` and `install` build the engine-EXACT
// module (DictationTranscriber for `.dictation` with the SAME init params as
// `AppleSpeechRunner`'s dictation branch; SpeechTranscriber(locale:preset:
// .transcription) for `.highQuality`) and resolve the locale via the shared
// `AppleSpeechRunner.resolve` — so the model we check / fetch is exactly the one
// the runner's `ensureModelUsable` will demand at transcribe time.
//
// PLATFORM GATE: like `AppleSpeechRunner.swift` / `AppleSpeechTester.swift`, the
// Watch target's synchronized group compiles this file regardless of exception
// listings, and watchOS ships no `Speech` symbols — so the WHOLE body is wrapped
// in `#if !os(watchOS)` to compile to an empty translation unit on Watch.

#if !os(watchOS)

import Foundation
import Speech

/// Engine-aware install/readiness for Apple on-device STT models. Stateless enum
/// (no stored properties) — every call resolves the locale + builds the module
/// fresh, matching the `AppleSpeechRunner` contract. `Sendable` for free.
enum AppleModelInstaller {

    // MARK: - Readiness probe

    /// True iff the engine-correct model for `language` is already installed.
    /// Resolves the locale via the shared `AppleSpeechRunner.resolve` (so the
    /// probe target matches the transcribe target); an unsupported explicit
    /// non-English language returns false — there is nothing to install, and the
    /// hot path will throw `appleSpeechLanguageUnsupported` (a genuine hard
    /// failure), so the self-heal must NOT try to download for it.
    static func isReady(engine requestedEngine: AppleOnDeviceEngineMode, language: String?) async -> Bool {
        // Clamp a `.highQuality` request the device can't run down to `.dictation`
        // so a synced-but-unsupported choice (sub-A16) probes the model the runner
        // will actually use, never one that can never install.
        let engine = AppleOnDeviceEngineMode.effectiveEngine(
            requested: requestedEngine, hqAvailable: SpeechTranscriber.isAvailable
        )
        let resolved: Locale
        switch await AppleSpeechRunner.resolve(preferredLanguage: language, engine: engine) {
        case .supported(let loc):
            resolved = loc
        case .unsupported:
            return false
        }
        let module = makeModule(engine: engine, locale: resolved)
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    // MARK: - Install

    /// Download + install the engine-correct model for `language`, reporting
    /// `0…1` progress via `onProgress` (always called on the MainActor). Mirrors
    /// `SettingsViewModel.downloadAppleModel`'s AssetInventory ceremony: build the
    /// installation request, observe `request.progress.fractionCompleted` via KVO,
    /// `downloadAndInstall()`, then best-effort `reserve` the locale so iOS doesn't
    /// purge the just-installed model under disk pressure.
    ///
    /// Throws on ANY failure (unsupported language, request-build failure, or a
    /// failed download) so the caller can fall through to the inline hard-failure
    /// path — a self-heal that can't complete must surface "Couldn't set up voice",
    /// never silently swallow.
    ///
    /// Returns the RESOLVED `Locale` actually targeted (already-installed and
    /// fresh-download paths alike) so a caller (e.g. `SettingsViewModel`) can
    /// record the canonical target key + own its ledger/reserve bookkeeping — the
    /// installer stays a pure primitive and never writes app state.
    @discardableResult
    static func install(
        engine requestedEngine: AppleOnDeviceEngineMode,
        language: String?,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Locale {
        // Same clamp as `isReady` — install the model the runner will use, never a
        // `.highQuality` model the device can't run.
        let engine = AppleOnDeviceEngineMode.effectiveEngine(
            requested: requestedEngine, hqAvailable: SpeechTranscriber.isAvailable
        )
        let resolved: Locale
        switch await AppleSpeechRunner.resolve(preferredLanguage: language, engine: engine) {
        case .supported(let loc):
            resolved = loc
        case .unsupported:
            // Nothing to install — the language isn't on-device at all. Surface
            // it as the genuine hard failure (the runner would throw the same).
            throw AppError.appleSpeechLanguageUnsupported
        }

        let module = makeModule(engine: engine, locale: resolved)

        let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        guard let request else {
            // Nil request = nothing to install (already on disk per Apple docs).
            // Best-effort pin so it survives disk pressure, then we're ready.
            try? await AssetInventory.reserve(locale: resolved)
            return resolved
        }

        // Observe `Progress.fractionCompleted` via Foundation KVO. The token is
        // retained for the lifetime of the install (the `await` below blocks until
        // it completes or throws); invalidated on return (mirrors
        // `SettingsViewModel.downloadAppleModel:1077`).
        let progress = request.progress
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { prog, _ in
            let fraction = prog.fractionCompleted
            Task { @MainActor in
                onProgress(fraction)
            }
        }
        defer { observation.invalidate() }

        try await request.downloadAndInstall()
        // Best-effort reserve so a disk-pressure purge can't silently revert the
        // just-healed model to `.notDownloaded` mid-session. Never blocks the
        // (already usable) model — a failed reserve is non-fatal.
        try? await AssetInventory.reserve(locale: resolved)
        return resolved
    }

    // MARK: - Module construction

    /// Build the engine-correct `SpeechModule` for `locale`. MUST stay in lockstep
    /// with `AppleSpeechRunner.transcribe(...engine:)`'s per-engine construction so
    /// the install / readiness target is the exact module the runner transcribes
    /// with: DictationTranscriber's detailed init with `transcriptionOptions:
    /// [.punctuation]` (dictation branch), SpeechTranscriber(preset: .transcription)
    /// (high-quality branch).
    private static func makeModule(
        engine: AppleOnDeviceEngineMode,
        locale: Locale
    ) -> any SpeechModule {
        switch engine {
        case .dictation:
            return DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [],
                attributeOptions: []
            )
        case .highQuality:
            return SpeechTranscriber(locale: locale, preset: .transcription)
        }
    }
}

/// Test seam over the install primitive so `SettingsViewModel.prepareStandardEngine`
/// can be unit-tested without touching live `AssetInventory` / `Speech` (the sim
/// ships no speech assets, so live behaviour isn't deterministic). Production uses
/// `LiveAppleModelInstaller` (forwards to the static `AppleModelInstaller`); tests
/// inject a stub that returns a fixed `Locale`, throws, or drives `onProgress`.
protocol AppleModelInstalling: Sendable {
    func install(
        engine: AppleOnDeviceEngineMode,
        language: String?,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Locale
}

struct LiveAppleModelInstaller: AppleModelInstalling {
    func install(
        engine: AppleOnDeviceEngineMode,
        language: String?,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Locale {
        try await AppleModelInstaller.install(engine: engine, language: language, onProgress: onProgress)
    }
}

/// Fire-and-forget "warm the Standard on-device model" entry point for surfaces
/// with NO `SettingsViewModel` in scope (onboarding, Action Button setup,
/// CarPlay, app launch / foreground). Gates on Apple on-device being the active
/// STT provider AND Speech Recognition ALREADY authorized — never kicks a
/// download before consent. `AssetInventory` requests are idempotent, so this
/// can't destructively race a VM-side `prepareStandardEngine`. Best-effort:
/// swallows failure (the in-app mic self-heal + the Settings "Preparing…" flow
/// stay the visible repair paths).
enum AppleSpeechPreparer {
    static func prepareStandardIfAuthorized() async {
        guard await SettingsManager.shared.getActiveSTTProvider().transport == .inProcess else { return }
        guard AppleSpeechRunner.currentAuthorizationStatus() == .authorized else { return }
        let language = await SettingsManager.shared.getPreferredLanguage()
        _ = try? await AppleModelInstaller.install(engine: .dictation, language: language) { _ in }
    }
}

#endif // !os(watchOS)

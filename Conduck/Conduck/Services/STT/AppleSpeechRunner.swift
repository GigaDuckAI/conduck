// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleSpeechRunner.swift
//
// Apple Native STT — the 6th STT provider.
// First conformance of `STTInProcessRunner` — wraps Apple's WWDC25
// `SpeechAnalyzer` + `SpeechTranscriber` (iOS / iPadOS / macOS / CarPlay
// 26+). NOT compiled into the Watch target — watchOS ships no Speech
// framework symbols; the Watch surface relays audio to iPhone via
// `AppleSpeechRelayCoordinator` instead.
//
// Privacy invariant (see the spec's Privacy & Security section): we never log audio bytes, never
// surface the file URL in user-facing strings. Errors map to existing
// `AppError` cases — no new "appleSpeechRuntimeFailure" case; the spec
// folded that into `audioProcessingFailed` because the user-visible
// recovery is identical ("record new audio").
//
// TCC safety net (Gemini-accepted critique): `transcribe` re-checks
// `SFSpeechRecognizer.authorizationStatus()` synchronously even though
// Settings already requested authorization. The user can revoke Speech
// Recognition in iOS Settings → Conduck between Settings-time and
// transcribe-time; a silent failure here would be a privacy regression.
// A denial throws `speechPermissionDenied` (51) — its OWN case, split
// from `sttAuthFailed` (8) so a TCC revocation never masquerades as a
// rejected cloud key (the recovery is a Settings toggle, not a re-paste).
//
// PLATFORM GATE: this file's PBXFileSystemSynchronizedBuildFileExceptionSet
// entry (intended to exclude it from the `ConduckWatch Watch App`
// target) is non-functional in the Xcode 26 synchronized-groups model
// — the Watch target ends up compiling every file in the Conduck
// folder regardless of exception listings (verified empirically: the
// Watch target's SwiftFileList contains AppleSpeechRunner.swift even
// with the exception in place). Rather than hack the pbxproj to force
// the exclusion, wrap the entire body in `#if !os(watchOS)` so the
// file compiles to an empty translation unit on Watch. `STTProvider`
// already gates `AppleSpeechRunner.self` behind the same `#if`, so no
// type-reference from the Watch surface ever needs this symbol.

#if !os(watchOS)

import Foundation
import Speech
import AVFoundation

/// Apple on-device STT runner. Stateless enum — all per-call state lives
/// inside the static method's task scope, matching the `STTInProcessRunner`
/// contract (no stored properties; no actor isolation; Apple's own
/// `SpeechAnalyzer` is itself a class that handles its own concurrency).
///
/// `STTInProcessRunner` requires `Sendable`, which enums get for free.
enum AppleSpeechRunner: STTInProcessRunner {

    // MARK: - Locale resolution
    //
    // QA finding: passing the full
    // `Locale.current.identifier` (e.g. `en_DE` for an English speaker on
    // a German-region device) to the engine's `supportedLocale
    // (equivalentTo:)` returns nil unless Apple ships an exact region
    // variant — Apple's matcher does NOT fall back from `en_DE` to `en_US`.
    // Both `DictationTranscriber` and `SpeechTranscriber` expose the same
    // matcher; `resolve` routes to whichever the active engine mode uses.
    //
    // Multilingual (2026-06): `resolve` replaces the old always-floors
    // `normalize`. The `en_US` floor is now applied ONLY for the auto/device
    // case and for explicit *English* variants. An explicit *non-English*
    // language Apple doesn't support returns `.unsupported` instead of
    // silently flooring to English — otherwise the Settings UI would show
    // "model ready" and the hot path would transcribe (say) Irish audio with
    // the English model, producing wrong text and no error. The Settings UI
    // (`checkAppleModelStatus` / `downloadAppleModel`) and the hot path below
    // both call `resolve`, so the install target and the transcribe target
    // always agree.

    /// Outcome of resolving an Apple on-device STT target locale.
    enum Resolution: Sendable, Equatable {
        /// Apple supports this locale; use it as the install / transcribe target.
        case supported(Locale)
        /// Apple does NOT support the explicitly-requested non-English language
        /// on-device (no English floor applies). Callers route to a cloud
        /// provider / surface `appleSpeechLanguageUnsupported` rather than
        /// transcribing with the wrong model.
        case unsupported(requested: Locale)
    }

    /// Resolve the Apple STT target for a user language preference.
    ///
    /// - `preferredLanguage`: the user's explicit hint (ISO / BCP-47, e.g.
    ///   `"de"`, `"zh-Hant"`), or `nil`/empty for auto-detect.
    ///
    /// Order:
    /// - **Explicit** pref: exact `supportedLocale(equivalentTo:)` on the full
    ///   tag (preserves script) → language(+script)-only retry → then an
    ///   English variant floors to `en_US`, a non-English one is `.unsupported`.
    /// - **Auto** (nil/empty): match the device locale (unchanged legacy
    ///   behaviour — English-localized app ⇒ `Locale.current` ⇒ English),
    ///   `en_US` floor as the last resort. Never `.unsupported`, so the default
    ///   path can't dead-end (and existing English installs never regress).
    static func resolve(
        preferredLanguage: String?,
        engine: AppleOnDeviceEngineMode = .dictation
    ) async -> Resolution {
        if let pref = preferredLanguage, !pref.isEmpty {
            let requested = Locale(identifier: pref)
            if let match = await supportedMatch(for: requested, engine: engine) {
                return .supported(match)
            }
            if requested.language.languageCode?.identifier == "en" {
                return .supported(Locale(identifier: "en_US"))
            }
            return .unsupported(requested: requested)
        }
        if let match = await supportedMatch(for: Locale.current, engine: engine) {
            return .supported(match)
        }
        return .supported(Locale(identifier: "en_US"))
    }

    /// Two-step Apple support probe: exact full-tag match, then a
    /// language(+script)-only retry (drops region, KEEPS script so
    /// `zh-Hant` does not collapse to `zh`). Returns the Apple-blessed
    /// locale, or nil if Apple supports neither. Probes the ACTIVE engine's
    /// supported-locale set — `DictationTranscriber` and `SpeechTranscriber`
    /// can cover different languages, so the install/transcribe target must
    /// agree with the engine actually used.
    private static func supportedMatch(
        for locale: Locale,
        engine: AppleOnDeviceEngineMode
    ) async -> Locale? {
        if let exact = await engineSupportedLocale(equivalentTo: locale, engine: engine) {
            return exact
        }
        guard let code = locale.language.languageCode?.identifier, !code.isEmpty else {
            return nil
        }
        let reducedID: String
        if let script = locale.language.script?.identifier {
            reducedID = "\(code)-\(script)"
        } else {
            reducedID = code
        }
        return await engineSupportedLocale(equivalentTo: Locale(identifier: reducedID), engine: engine)
    }

    /// Engine-routed `supportedLocale(equivalentTo:)` — Apple's blessed fuzzy
    /// matcher, called on whichever transcriber the active mode uses.
    private static func engineSupportedLocale(
        equivalentTo locale: Locale,
        engine: AppleOnDeviceEngineMode
    ) async -> Locale? {
        switch engine {
        case .dictation:
            return await DictationTranscriber.supportedLocale(equivalentTo: locale)
        case .highQuality:
            return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }
    }

    /// First Apple-SUPPORTED, NON-English locale among the user's preferred
    /// languages — the onboarding "device language" offer. Returns nil when
    /// English is the top preference (English user → no language choice) or
    /// when no supported non-English preference exists. Scans past an
    /// unsupported non-English top preference (e.g. Hindi) to a supported
    /// lower one. NOTE: this drives only whether the onboarding picker is
    /// SHOWN + its default selection; it does not change auto-resolve
    /// behaviour (which stays `Locale.current`-based via `resolve`).
    static func deviceSpokenLanguageOffer(
        engine: AppleOnDeviceEngineMode = .highQuality
    ) async -> Locale? {
        for tag in Locale.preferredLanguages {
            let loc = Locale(identifier: tag)
            if loc.language.languageCode?.identifier == "en" {
                return nil
            }
            if let match = await supportedMatch(for: loc, engine: engine),
               match.language.languageCode?.identifier != "en" {
                return match
            }
        }
        return nil
    }

    // MARK: - Transcribe (hot path)

    /// Transcribe `audioFileURL` on-device via `SpeechAnalyzer`.
    ///
    /// Flow:
    /// 1. Synchronous TCC re-check (user could have revoked Speech
    ///    Recognition between Settings-time check and now).
    /// 2. Locale negotiation — exact match first, then language-only
    ///    fallback via `SpeechTranscriber.supportedLocale(equivalentTo:)`
    ///    (Apple's blessed fuzzy-matcher).
    /// 3. AssetInventory check — model must be `.installed`. Never
    ///    auto-download in the hot path (Settings UI owns explicit
    ///    download; auto-download would silently spend the user's
    ///    Wi-Fi quota mid-recording).
    /// 4. Open audio via `AVAudioFile`.
    /// 5. Format negotiation via `SpeechAnalyzer.bestAvailableAudioFormat`
    ///    — convert with `AVAudioConverter` if file format differs.
    /// 6. `analyzer.analyzeSequence(from: file)` for batch transcription,
    ///    then `finalizeAndFinish` to flush partial results.
    /// 7. Collect finalized text segments (not volatile partials);
    ///    concatenate into a single `String`.
    static func transcribe(audioFileURL: URL, language: String?) async throws -> STTResponse {
        // Hot path: ONE provider, two engines — read the user's persisted choice
        // (default `.dictation`, the keyboard-grade engine that needs no download).
        // Read straight from settings rather than threading it through
        // `activeSTTSnapshot()`: the mode is a non-secret preference (none of the
        // key/URL-mismatch risk the atomic snapshot guards), and reading it in the
        // runner means EVERY surface — in-app composer, CarPlay, the headless App
        // Intent, and the iPhone-side Watch relay — picks up the active engine with
        // zero call-site plumbing.
        let storedEngine = await SettingsManager.shared.getAppleOnDeviceEngineMode()
        return try await transcribe(audioFileURL: audioFileURL, language: language, engine: storedEngine)
    }

    /// Engine-EXPLICIT transcribe. The hot path resolves the persisted mode and
    /// funnels through here; the Settings → Voice → Apple "Try it" test passes the
    /// engine it is VISIBLY testing. Threading the engine explicitly (rather than
    /// re-reading the persisted value) closes a class of bug for the test surface:
    /// the result can't be attributed to the wrong engine when the just-flipped
    /// KVS value hasn't propagated yet, and a future A/B "feel the difference"
    /// compare can run either engine WITHOUT mutating the user's active choice.
    /// Production behaviour is unchanged — same capability coercion, same flow.
    static func transcribe(
        audioFileURL: URL,
        language: String?,
        engine requestedEngine: AppleOnDeviceEngineMode
    ) async throws -> STTResponse {
        // 1. TCC re-check. `SFSpeechRecognizer.authorizationStatus()`
        // is a non-prompting lookup — the prompting variant is
        // `requestAuthorization(_:)`. Apple still routes the new
        // SpeechAnalyzer framework through the legacy TCC entry per
        // verified Apple constraints.
        // Denial = `speechPermissionDenied` (51), NOT `sttAuthFailed` (8):
        // the user must flip the Speech Recognition toggle in Settings,
        // and the Watch relay decodes the numeric slot to pick its phrase.
        let auth = SFSpeechRecognizer.authorizationStatus()
        guard auth == .authorized else {
            throw AppError.speechPermissionDenied
        }

        // 2. Capability floor. `SpeechTranscriber` (the high-quality engine) needs
        // A16+ hardware (`isAvailable`); `DictationTranscriber` has no floor. The
        // mode syncs across the user's devices via iCloud KVS, so a `.highQuality`
        // choice made on a capable phone can arrive on one below the floor (where
        // Settings hides the switch but the synced value persists). Let the device's
        // real capability win — fall back to the always-available dictation engine
        // rather than dead-ending with a confusing `appleSpeechModelNotInstalled`
        // for a model that was never installable here.
        let engine: AppleOnDeviceEngineMode =
            (requestedEngine == .highQuality && !SpeechTranscriber.isAvailable) ? .dictation : requestedEngine

        // 3. Locale resolution via the shared, engine-aware resolver. The
        // Settings UI calls the same `resolve` with the same engine, so the
        // install target and the transcribe target always agree. An explicit
        // non-English language the engine doesn't support throws
        // `appleSpeechLanguageUnsupported` rather than transcribing with the
        // English model; the auto path floors to the device/English locale.
        let resolvedLocale: Locale
        switch await Self.resolve(preferredLanguage: language, engine: engine) {
        case .supported(let loc):
            resolvedLocale = loc
        case .unsupported:
            throw AppError.appleSpeechLanguageUnsupported
        }

        // 4. Open the audio file. Let `AVAudioFile` throw on corrupt /
        // truncated payload; map to `audioInvalid` ("Couldn't read
        // that audio. Record again.").
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioFileURL)
        } catch {
            throw AppError.audioInvalid
        }

        // 4b. Duration cap. Cloud providers are bounded upstream by
        // `maxAudioSize` (bytes); this in-process path has no byte gate,
        // so an unbounded input (e.g. the Shortcuts `Record Audio` step,
        // which Conduck cannot cap) would grind `SpeechAnalyzer` for
        // hours. A zero/invalid sample rate skips the check — let the
        // analyzer surface its own error rather than false-reject.
        let sampleRate = audioFile.fileFormat.sampleRate
        if sampleRate > 0,
           Double(audioFile.length) / sampleRate > Constants.appleMaxAudioSeconds {
            throw AppError.audioTooLarge
        }

        // 5. Build the active engine's transcriber, verify its model is
        // installed + can ingest audio (reactive `appleSpeechModelNotInstalled`
        // — Settings owns download; the hot path NEVER auto-fetches, which
        // would silently spend the user's Wi-Fi mid-recording), then run batch
        // file analysis and collect finalized text. `.results` lives on the
        // CONCRETE transcriber type (no shared protocol exposes it), so each
        // engine branch owns its collector; the analyzer drive is shared.
        //
        // VERIFIED against the shipping iOS 26.5 SDK swiftinterface:
        //   • `DictationTranscriber.Preset` ships phrase / shortDictation /
        //     progressiveShortDictation / longDictation / progressiveLong /
        //     timeIndexedLongDictation. We use the detailed init with
        //     `transcriptionOptions: [.punctuation]` (NOT a preset) so emoji +
        //     etiquette replacements stay OFF — clean prose for an AI prompt.
        //   • `SpeechTranscriber.Preset` has NO `.offlineTranscription`
        //     (stale beta naming in Apple sample code) — `.transcription` is
        //     the concise finalized-batch preset.
        //   • `DictationTranscriber` has NO `isAvailable` (no hardware floor);
        //     `SpeechTranscriber.isAvailable` gates the A16+ high-quality path
        //     (checked in Settings before the user can switch to it).
        switch engine {
        case .dictation:
            let transcriber = DictationTranscriber(
                locale: resolvedLocale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [],
                attributeOptions: []
            )
            try await Self.ensureModelUsable(transcriber)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collector = Task<String, Error> {
                var pieces: [String] = []
                do {
                    for try await result in transcriber.results where result.isFinal {
                        pieces.append(String(result.text.characters))
                    }
                } catch {
                    throw AppError.audioProcessingFailed
                }
                return pieces.joined(separator: " ")
            }
            let text = try await Self.drive(analyzer: analyzer, collector: collector, audioFile: audioFile)
            return STTResponse(text: text, language: resolvedLocale.identifier)

        case .highQuality:
            let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .transcription)
            try await Self.ensureModelUsable(transcriber)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collector = Task<String, Error> {
                var pieces: [String] = []
                do {
                    for try await result in transcriber.results where result.isFinal {
                        pieces.append(String(result.text.characters))
                    }
                } catch {
                    throw AppError.audioProcessingFailed
                }
                return pieces.joined(separator: " ")
            }
            let text = try await Self.drive(analyzer: analyzer, collector: collector, audioFile: audioFile)
            return STTResponse(text: text, language: resolvedLocale.identifier)
        }
    }

    // MARK: - Shared analysis helpers

    /// Assert the engine's model is installed AND can ingest audio. Both
    /// failures map to `appleSpeechModelNotInstalled` — the user-visible
    /// recovery is identical (the model isn't ready for this language). Takes
    /// `any SpeechModule` so it serves both transcriber types.
    private static func ensureModelUsable(_ module: any SpeechModule) async throws {
        let status = await AssetInventory.status(forModules: [module])
        guard status == .installed else {
            throw AppError.appleSpeechModelNotInstalled
        }
        // Format negotiation: nil means no installed model can ingest any
        // format for this module (defensive — should not occur post installed-
        // check). Treat as model-missing.
        guard await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) != nil else {
            throw AppError.appleSpeechModelNotInstalled
        }
    }

    /// Drive `SpeechAnalyzer` over the audio file end-to-end, then wait for the
    /// caller's finalized-results `collector` to drain. Engine-agnostic — the
    /// analyzer + collector are built per-branch (concrete transcriber types);
    /// this shared drive flushes via `finalizeAndFinish(through:)` so the
    /// results stream terminates cleanly.
    private static func drive(
        analyzer: SpeechAnalyzer,
        collector: Task<String, Error>,
        audioFile: AVAudioFile
    ) async throws -> String {
        do {
            let lastSample = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSample {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw AppError.audioProcessingFailed
        }
        do {
            return try await collector.value
        } catch let appError as AppError {
            throw appError
        } catch {
            throw AppError.audioProcessingFailed
        }
    }

    // MARK: - Authorization

    /// Direct passthrough to `SFSpeechRecognizer.authorizationStatus()`.
    /// Non-prompting lookup — safe to call during view rendering
    /// without triggering a permission dialog.
    static func currentAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Async wrapper around the callback-based
    /// `SFSpeechRecognizer.requestAuthorization`. Prompts the user
    /// (first call only — subsequent calls return the existing status
    /// without re-prompting). Used by `STTClient.headProbe` Apple
    /// branch at Settings-set-active time.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

#endif // !os(watchOS)

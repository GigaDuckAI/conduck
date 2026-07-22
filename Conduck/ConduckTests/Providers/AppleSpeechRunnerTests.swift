// Conduck
// AppleSpeechRunnerTests.swift
//
// Deterministic tests for the AppleSpeechRunner wiring — does NOT
// require the on-device model to be installed; does NOT assert any
// specific TCC state (test sims vary). Coverage:
//   1. Static authorization-status lookup returns a valid SFSpeech
//      authorization-status raw value.
//   2. STTProvider.appleOnDevice registry entry is wired to the
//      AppleSpeechRunner metatype (regression guard against accidental
//      revert to an earlier no-op placeholder).
//   3. STTProvider.appleOnDevice declares `.inProcess` transport.
//   4. Calling `transcribe(...)` against a non-existent file throws an
//      AppError (NOT a silent success / NOT a non-AppError). Tolerant
//      to both .audioInvalid (TCC authorized, file-open failed) and
//      .speechPermissionDenied (TCC denied) — both are valid contractual
//      outcomes for "bogus input, no model run."
//
// PLATFORM GATE: Watch test target inclusion follows the same
// membership-exceptions-non-functional trap noted on the runner
// itself. Wrap entire file in `#if !os(watchOS)` so the Watch target
// (if it ever runs these tests) compiles to an empty translation unit.

#if !os(watchOS)

import XCTest
import Speech
@testable import Conduck

final class AppleSpeechRunnerTests: XCTestCase {

    // MARK: - Authorization status

    func testCurrentAuthorizationStatusReturnsValidCase() {
        // Non-prompting lookup — value is one of the
        // SFSpeechRecognizerAuthorizationStatus cases. Actual status
        // varies per test environment; we don't assert .authorized.
        let status = AppleSpeechRunner.currentAuthorizationStatus()
        let validRawValues: Set<Int> = [0, 1, 2, 3]
        XCTAssertTrue(
            validRawValues.contains(status.rawValue),
            "Expected a valid SFSpeechRecognizerAuthorizationStatus raw value, got \(status.rawValue)"
        )
    }

    // MARK: - Provider wiring (regression guard)

    func testInProcessProviderRoutesToAppleSpeechRunner() {
        // Registry-level sanity: the appleOnDevice provider's
        // inProcessRunner metatype is AppleSpeechRunner.self (not nil).
        // Catches accidental regression to an earlier no-op placeholder where
        // inProcessRunner was nil and STTClient threw
        // appleSpeechModelNotInstalled unconditionally.
        XCTAssertNotNil(STTProvider.appleOnDevice.inProcessRunner)
        XCTAssertTrue(
            STTProvider.appleOnDevice.inProcessRunner == AppleSpeechRunner.self,
            "appleOnDevice.inProcessRunner must be AppleSpeechRunner.self"
        )
    }

    func testInProcessTransportIsRecognized() {
        XCTAssertEqual(STTProvider.appleOnDevice.transport, .inProcess)
    }

    // MARK: - Error mapping (deterministic — does not require model)

    // MARK: - Locale resolution (multilingual, 2026-06)
    //
    // `resolve` replaced the always-floors `normalize`. The load-bearing
    // contract — and the bug fix — is that an explicit *non-English*
    // language is NEVER silently floored to English: it resolves to the
    // Apple locale when supported, else `.unsupported` (so the UI can route
    // to a cloud provider and the hot path throws rather than transcribing
    // with the wrong model). English variants + the nil/auto path keep the
    // `en_US` floor so the default can't dead-end.
    //
    // SIM ROBUSTNESS: `SpeechTranscriber.supportedLocale(equivalentTo:)` may
    // return nil for EVERY locale on a simulator with no speech assets
    // staged (the same limitation behind the "doesn't support this language"
    // onboarding screenshot). So we do NOT assert "German is supported" —
    // we assert the *invariants that hold regardless of asset availability*:
    // English always floors to `.supported(en)`, an unsupported non-English
    // code is `.unsupported` with its language preserved, auto never
    // dead-ends, and a real supported language (de) is never turned into
    // English.

    func testResolveExplicitEnglishVariantAlwaysSupported() async {
        // `en-ZZ` is not a real region; even if Apple's matcher returns nil,
        // the English floor must still yield `.supported` English. This is
        // unconditional (independent of sim asset staging).
        switch await AppleSpeechRunner.resolve(preferredLanguage: "en-ZZ") {
        case .supported(let loc):
            XCTAssertEqual(loc.language.languageCode?.identifier, "en",
                           "English variant must floor to an English locale, got \(loc.identifier)")
        case .unsupported(let requested):
            XCTFail("English must never be .unsupported, got unsupported(\(requested.identifier))")
        }
    }

    func testResolveExplicitUnsupportedNonEnglishIsUnsupported() async {
        // `zz` is a non-English code Apple ships no model for. It must NOT
        // floor to English — that would silently transcribe with the wrong
        // model. Resolver short-circuits to `.unsupported`, language kept.
        switch await AppleSpeechRunner.resolve(preferredLanguage: "zz") {
        case .supported(let loc):
            XCTFail("Unsupported non-English must not floor to English, got supported(\(loc.identifier))")
        case .unsupported(let requested):
            XCTAssertEqual(requested.language.languageCode?.identifier, "zz",
                           "Requested language must be preserved on .unsupported, got \(requested.identifier)")
        }
    }

    func testResolveAutoNeverUnsupported() async {
        // nil/auto floors to the device/English locale — the default path
        // must never dead-end (existing English installs must not regress).
        switch await AppleSpeechRunner.resolve(preferredLanguage: nil) {
        case .supported:
            break // expected
        case .unsupported(let requested):
            XCTFail("Auto-resolve must never be .unsupported, got unsupported(\(requested.identifier))")
        }
    }

    func testResolveGermanNeverBecomesEnglish() async {
        // The core bug fix: German must resolve to German (when Apple
        // supports it on this device) or `.unsupported(de)` (sim with no
        // assets) — but NEVER silently to English.
        switch await AppleSpeechRunner.resolve(preferredLanguage: "de") {
        case .supported(let loc):
            XCTAssertEqual(loc.language.languageCode?.identifier, "de",
                           "Supported German must resolve to a German locale, got \(loc.identifier)")
        case .unsupported(let requested):
            XCTAssertEqual(requested.language.languageCode?.identifier, "de",
                           "Unsupported German must keep German (never English), got \(requested.identifier)")
        }
    }

    func testResolveHighQualityEngineHonoursEnglishFloorAndUnsupported() async {
        // The `engine:` param routes to the high-quality `SpeechTranscriber`
        // supported set instead of `DictationTranscriber`. The English-floor +
        // non-English-unsupported invariants must hold identically — this locks
        // that the engine param is threaded, not ignored.
        switch await AppleSpeechRunner.resolve(preferredLanguage: "en-ZZ", engine: .highQuality) {
        case .supported(let loc):
            XCTAssertEqual(loc.language.languageCode?.identifier, "en",
                           "English variant must floor to English (highQuality), got \(loc.identifier)")
        case .unsupported(let requested):
            XCTFail("English must never be .unsupported (highQuality), got \(requested.identifier)")
        }
        switch await AppleSpeechRunner.resolve(preferredLanguage: "zz", engine: .highQuality) {
        case .supported(let loc):
            XCTFail("Unsupported non-English must not floor to English (highQuality), got \(loc.identifier)")
        case .unsupported(let requested):
            XCTAssertEqual(requested.language.languageCode?.identifier, "zz",
                           "Requested language must be preserved on .unsupported (highQuality)")
        }
    }

    func testTranscribeWithMissingFileURLThrows() async {
        // Pass a URL pointing to a non-existent file. Expected
        // outcomes (both valid per the runner's contract):
        //   - .speechPermissionDenied: TCC not authorized in the test
        //     env; runner throws before reaching the file-open step.
        //   - .audioInvalid: TCC authorized, AVAudioFile open fails
        //     because the file does not exist.
        //   - .audioProcessingFailed: unlikely but theoretically
        //     possible if locale resolution fails first (e.g. the
        //     test sim's current locale has no Apple model).
        //   - .appleSpeechModelNotInstalled: TCC authorized but the
        //     resolved locale's model is not installed on the sim.
        // Contract: SOME AppError must be thrown — silent success or
        // a non-AppError throw would be a regression.
        let bogusURL = URL(fileURLWithPath: "/tmp/conduck-test-nonexistent-\(UUID().uuidString).m4a")
        do {
            _ = try await AppleSpeechRunner.transcribe(audioFileURL: bogusURL, language: "en")
            XCTFail("Expected throw for missing file, got silent success")
        } catch let error as AppError {
            // AppError is not Equatable; compare on the stable
            // `errorCode` slot (see AppError.from(errorCode:message:)).
            let acceptableCodes: Set<Int> = [
                AppError.speechPermissionDenied.errorCode,
                AppError.audioInvalid.errorCode,
                AppError.audioProcessingFailed.errorCode,
                AppError.appleSpeechModelNotInstalled.errorCode,
            ]
            XCTAssertTrue(
                acceptableCodes.contains(error.errorCode),
                "Expected one of {speechPermissionDenied, audioInvalid, audioProcessingFailed, appleSpeechModelNotInstalled}, got code \(error.errorCode)"
            )
        } catch {
            XCTFail("Expected AppError, got \(type(of: error)): \(error)")
        }
    }

    func testTranscribeWithUnsupportedLanguageThrows() async {
        // An explicit non-English language Apple can't transcribe on-device
        // must throw — `appleSpeechLanguageUnsupported` when TCC is authorized
        // (the resolver short-circuits before the model check), or
        // `speechPermissionDenied` when TCC is denied in the test env (the
        // TCC re-check runs first). Either is a valid contractual outcome —
        // what matters is it NEVER silently transcribes with the English model.
        let bogusURL = URL(fileURLWithPath: "/tmp/conduck-test-nonexistent-\(UUID().uuidString).m4a")
        do {
            _ = try await AppleSpeechRunner.transcribe(audioFileURL: bogusURL, language: "zz")
            XCTFail("Expected throw for unsupported language, got silent success")
        } catch let error as AppError {
            let acceptableCodes: Set<Int> = [
                AppError.appleSpeechLanguageUnsupported.errorCode,
                AppError.speechPermissionDenied.errorCode,
            ]
            XCTAssertTrue(
                acceptableCodes.contains(error.errorCode),
                "Expected {appleSpeechLanguageUnsupported, speechPermissionDenied}, got code \(error.errorCode)"
            )
        } catch {
            XCTFail("Expected AppError, got \(type(of: error)): \(error)")
        }
    }
}

#endif // !os(watchOS)

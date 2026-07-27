// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelAppleLanguageTests.swift
//
// Multilingual Apple on-device STT (2026-06): the model download/status
// target derives from the global `preferredLanguage` via the shared resolver,
// surfaced through `appleTargetKey` + `appleModelStates`. These tests pin the
// VM-level contract that the resolver tests (AppleSpeechRunnerTests) can't see:
// that `checkAppleModelStatus` routes an explicit unsupported language to a
// non-retryable structural failure and keys state by the canonical resolved
// locale.
//
// DETERMINISM: `checkAppleModelStatus` reads `self.preferredLanguage`
// SYNCHRONOUSLY when forming the `resolve(preferredLanguage:)` call (the arg
// is evaluated before the first `await` suspends), so setting the property and
// calling the method with NO intervening await captures the value before the
// init's fire-and-forget `loadSettings` Task can interleave. The unsupported
// path also short-circuits BEFORE any `AssetInventory` query, so it holds on a
// bare simulator with no speech assets staged.
//
// PLATFORM GATE: `#if !os(watchOS)` — `AssetInventory` / `SpeechTranscriber`
// ship no watchOS symbols (same trap as the runner + its tests).

#if !os(watchOS)

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelAppleLanguageTests: XCTestCase {

    /// Explicit unsupported non-English preference → the Apple row shows a
    /// non-retryable "unsupported" failure keyed by the requested locale, and
    /// `appleTargetKey` points at it. This is the bug-fix guard: a non-English
    /// language Apple can't transcribe must NOT masquerade as a ready English
    /// model.
    func testUnsupportedPreferredLanguageSurfacesStructuralFailure() async {
        let vm = SettingsViewModel()
        vm.preferredLanguage = "zz"          // non-English, no Apple model — ever
        await vm.checkAppleModelStatus()     // no await between set + call → "zz" captured

        XCTAssertEqual(vm.appleTargetKey, Locale(identifier: "zz").identifier,
                       "appleTargetKey must point at the requested unsupported locale.")
        guard case .failed(_, let retryable)? = vm.appleModelStates[vm.appleTargetKey] else {
            return XCTFail("Expected .failed for unsupported language, got \(String(describing: vm.appleModelStates[vm.appleTargetKey]))")
        }
        XCTAssertFalse(retryable, "Unsupported-language failure must be non-retryable (structural — nothing to download).")
    }

    /// English-variant preference floors to an English target key (never
    /// `.unsupported`), so existing English installs don't regress when the
    /// download target starts following `preferredLanguage`.
    func testEnglishPreferredLanguageTargetsEnglish() async {
        let vm = SettingsViewModel()
        vm.preferredLanguage = "en-ZZ"       // bogus region, still English
        await vm.checkAppleModelStatus()

        XCTAssertEqual(Locale(identifier: vm.appleTargetKey).language.languageCode?.identifier, "en",
                       "English variant must target an English locale, got \(vm.appleTargetKey).")
    }
}

#endif // !os(watchOS)

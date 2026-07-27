// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleStandardPrepareTests.swift
//
// Unit coverage for the proactive Standard (.dictation) on-device prepare added
// to fix the first-run asset-readiness race. Deterministic — the live
// AssetInventory/Speech path is NOT exercised here (the sim ships no speech
// assets, so real install isn't deterministic); instead `SettingsViewModel`'s
// install seam (`appleModelInstaller`) is stubbed so the state-machine + the
// effective-engine clamp + the Try-voice gate are testable without hardware.
// Real install/download behaviour is a founder-gated signed-device QA pass.
//
// PLATFORM GATE: `#if !os(watchOS)` — the prepare path + `AppleModelInstalling`
// seam are non-watch (no Speech symbols on the wrist).

#if !os(watchOS)

import XCTest
@testable import Conduck

@MainActor
final class AppleStandardPrepareTests: XCTestCase {

    // MARK: - Stub installer (the injected seam)

    /// Records how many times `install` ran (single-flight assertion) and yields a
    /// fixed success/failure. An `actor` so the call count is race-free even though
    /// `install` is `async` (the protocol requirement is `async`, satisfied here).
    private actor StubInstaller: AppleModelInstalling {
        enum Outcome { case success(Locale), unsupported, generic }
        let outcome: Outcome
        private(set) var installCount = 0
        init(_ outcome: Outcome) { self.outcome = outcome }

        func install(
            engine: AppleOnDeviceEngineMode,
            language: String?,
            onProgress: @escaping @MainActor @Sendable (Double) -> Void
        ) async throws -> Locale {
            installCount += 1
            switch outcome {
            case .success(let loc): return loc
            case .unsupported: throw AppError.appleSpeechLanguageUnsupported
            case .generic: throw AppError.audioProcessingFailed
            }
        }
    }

    // MARK: - Pure effective-engine clamp (no hardware)

    func testEffectiveEngineClamp() {
        // High quality is honoured only when available; everything else passes through.
        XCTAssertEqual(AppleOnDeviceEngineMode.effectiveEngine(requested: .highQuality, hqAvailable: true), .highQuality)
        XCTAssertEqual(AppleOnDeviceEngineMode.effectiveEngine(requested: .highQuality, hqAvailable: false), .dictation)
        XCTAssertEqual(AppleOnDeviceEngineMode.effectiveEngine(requested: .dictation, hqAvailable: true), .dictation)
        XCTAssertEqual(AppleOnDeviceEngineMode.effectiveEngine(requested: .dictation, hqAvailable: false), .dictation)
    }

    // MARK: - Try-voice gate (fresh VM defaults to .dictation → effective = .dictation)

    func testTestCanRecordGatesOnStandardReadiness() {
        let vm = SettingsViewModel()
        // Fresh VM: engine = .default (.dictation) ⇒ effectiveAppleEngine == .dictation
        // regardless of hardware, so the gate keys purely off appleStandardModelState.
        vm.appleStandardModelState = .installed
        XCTAssertTrue(vm.appleTestCanRecord, "Standard installed → can record.")
        vm.appleStandardModelState = .notDownloaded
        XCTAssertFalse(vm.appleTestCanRecord, "Standard not ready → cannot record (no firing into a cold model).")
        vm.appleStandardModelState = .downloading(progress: 0.5)
        XCTAssertFalse(vm.appleTestCanRecord, "Preparing → cannot record yet.")
        vm.appleStandardModelState = .failed(message: "x", retryable: true)
        XCTAssertFalse(vm.appleTestCanRecord, "Failed → cannot record.")
    }

    // MARK: - prepareStandardEngine state transitions (via the seam)

    func testPrepareSuccessInstallsAndSetsTarget() async {
        let vm = SettingsViewModel()
        vm.appleModelInstaller = StubInstaller(.success(Locale(identifier: "de_DE")))
        let ok = await vm.prepareStandardEngine()
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.appleStandardModelState, .installed)
        XCTAssertEqual(vm.appleStandardTargetKey, Locale(identifier: "de_DE").identifier,
                       "Target key must follow the resolved locale the installer returned.")
    }

    func testPrepareUnsupportedIsNonRetryableFailure() async {
        let vm = SettingsViewModel()
        vm.appleModelInstaller = StubInstaller(.unsupported)
        let ok = await vm.prepareStandardEngine()
        XCTAssertFalse(ok)
        guard case .failed(_, let retryable) = vm.appleStandardModelState else {
            return XCTFail("Expected .failed, got \(vm.appleStandardModelState)")
        }
        XCTAssertFalse(retryable, "Unsupported language is structural → non-retryable.")
    }

    func testPrepareGenericErrorIsRetryableFailure() async {
        let vm = SettingsViewModel()
        vm.appleModelInstaller = StubInstaller(.generic)
        let ok = await vm.prepareStandardEngine()
        XCTAssertFalse(ok)
        guard case .failed(_, let retryable) = vm.appleStandardModelState else {
            return XCTFail("Expected .failed, got \(vm.appleStandardModelState)")
        }
        XCTAssertTrue(retryable, "A transient failure must offer a working retry.")
    }

    func testConcurrentPreparesAreSingleFlight() async {
        let vm = SettingsViewModel()
        let stub = StubInstaller(.success(Locale(identifier: "en_US")))
        vm.appleModelInstaller = stub
        // Two concurrent callers: the second must join the in-flight task, not
        // kick a second install.
        async let a = vm.prepareStandardEngine()
        async let b = vm.prepareStandardEngine()
        _ = await (a, b)
        let count = await stub.installCount
        XCTAssertEqual(count, 1, "Single-flight: concurrent prepares share ONE install.")
        XCTAssertEqual(vm.appleStandardModelState, .installed)
    }
}

#endif // !os(watchOS)

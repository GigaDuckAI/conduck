// SPDX-License-Identifier: Apache-2.0

// Conduck
// VoicePermissions.swift
//
// Permission-UX rework (mic + Speech Recognition) — a TESTABLE seam over the
// two TCC prompts every voice path needs. Centralizes the request logic so the
// onboarding "Enable Voice" priming step (B baseline) and the record-start
// fallback preflights (A fallback — InAppAudioRecorder / DictationService /
// Setup Guide) all call ONE place instead of scattering
// `AVAudioApplication`/`SFSpeechRecognizer` calls across surfaces.
//
// Speech Recognition is requested ONLY when the active STT provider is Apple
// on-device (`transport == .inProcess`) AND its TCC status is still
// `.notDetermined` — a cloud provider never needs it, and a determined status
// (authorized / denied / restricted) must not re-prompt. That decision is
// extracted into the PURE `shouldRequestSpeech(providerIsInProcess:status:)`
// helper so the matrix is unit-testable without touching live TCC.
//
// Watch ships no Speech framework symbols (`AppleSpeechRunner` is
// `#if !os(watchOS)`), and the Watch surface relays audio to the iPhone for
// transcription — so the speech path is gated off Watch. Microphone request
// stays universal.

import Foundation
import AVFoundation

#if !os(watchOS)
import Speech
#endif

/// Microphone + Speech-Recognition permission requests, behind a testable seam.
/// Stateless enum — every call resolves the current provider / status at call
/// time (the active STT provider can change between sessions).
enum VoicePermissions {

    /// Request microphone access. Mirrors `AudioRecorder.startRecording()`'s
    /// `await AVAudioApplication.requestRecordPermission()` — the modern
    /// non-deprecated entry point. Returns the grant outcome; callers treat a
    /// denial as soft (advance / surface a "enable later" note), never a hard
    /// block, per the onboarding non-blocking contract.
    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    #if !os(watchOS)
    /// PURE decision helper for the speech-recognition preflight — true iff the
    /// active STT provider is Apple on-device AND its TCC status is still
    /// undecided. Extracted so the inProcess × {authorized, notDetermined,
    /// denied, restricted} matrix is unit-testable with no live TCC. A cloud
    /// provider (`providerIsInProcess == false`) never needs Speech Recognition;
    /// an already-determined status must not re-prompt.
    static func shouldRequestSpeech(
        providerIsInProcess: Bool,
        status: SFSpeechRecognizerAuthorizationStatus
    ) -> Bool {
        providerIsInProcess && status == .notDetermined
    }

    /// Ensure Speech Recognition is requested for the ACTIVE STT provider, then
    /// return the resulting (or pre-existing) status.
    ///
    /// - Apple on-device active + `.notDetermined` → prompt via
    ///   `AppleSpeechRunner.requestAuthorization()` and return the outcome.
    /// - Cloud provider active, OR already determined → no prompt; return the
    ///   current `SFSpeechRecognizer.authorizationStatus()`.
    ///
    /// Callers use the result to decide whether a record/headless path can
    /// proceed (`.authorized` / `.notDetermined`) or must surface the
    /// `speechPermissionDenied` repair path (`.denied` / `.restricted`).
    static func ensureSpeechRecognitionForActiveProvider() async -> SFSpeechRecognizerAuthorizationStatus {
        // Never PROMPT under XCTest: `SFSpeechRecognizer.requestAuthorization`
        // blocks on a system prompt that can't appear in the unsigned test host,
        // hanging any suite that drives a record path. Return the non-prompting
        // status (`.notDetermined` in tests → callers proceed, never bail).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return AppleSpeechRunner.currentAuthorizationStatus()
        }
        let provider = await SettingsManager.shared.getActiveSTTProvider()
        let status = AppleSpeechRunner.currentAuthorizationStatus()
        if shouldRequestSpeech(providerIsInProcess: provider.transport == .inProcess, status: status) {
            return await AppleSpeechRunner.requestAuthorization()
        }
        return status
    }
    #endif
}

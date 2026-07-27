// SPDX-License-Identifier: Apache-2.0

// Conduck
// VoicePermissionsTests.swift
//
// Pure-decision coverage for the permission-UX rework seams. No live TCC, no
// AVFoundation/Speech prompts — just the extracted decision helpers:
//   - `VoicePermissions.shouldRequestSpeech(providerIsInProcess:status:)` —
//     speech is requested ONLY for an Apple on-device provider that is still
//     `.notDetermined`.
//   - `ActionButtonStepView.shouldDeclareReady(providerIsInProcess:status:)` —
//     the Setup-Guide readiness gate: a headless trigger may NOT be declared
//     ready when Apple on-device STT is active but Speech Recognition is
//     denied/restricted (the headless path can't prompt at runtime).

import XCTest
import Speech
@testable import Conduck

final class VoicePermissionsTests: XCTestCase {

    // MARK: - shouldRequestSpeech matrix

    /// Apple on-device (inProcess) × every status: request ONLY when undecided.
    func testShouldRequestSpeechInProcess() {
        XCTAssertTrue(VoicePermissions.shouldRequestSpeech(providerIsInProcess: true, status: .notDetermined))
        XCTAssertFalse(VoicePermissions.shouldRequestSpeech(providerIsInProcess: true, status: .authorized))
        XCTAssertFalse(VoicePermissions.shouldRequestSpeech(providerIsInProcess: true, status: .denied))
        XCTAssertFalse(VoicePermissions.shouldRequestSpeech(providerIsInProcess: true, status: .restricted))
    }

    /// Cloud provider (NOT inProcess) × every status: never request.
    func testShouldRequestSpeechCloudNeverRequests() {
        XCTAssertFalse(VoicePermissions.shouldRequestSpeech(providerIsInProcess: false, status: .notDetermined))
        XCTAssertFalse(VoicePermissions.shouldRequestSpeech(providerIsInProcess: false, status: .authorized))
        XCTAssertFalse(VoicePermissions.shouldRequestSpeech(providerIsInProcess: false, status: .denied))
        XCTAssertFalse(VoicePermissions.shouldRequestSpeech(providerIsInProcess: false, status: .restricted))
    }

    /// Spelled-out single true cell — the ONLY combination that prompts.
    func testOnlyInProcessNotDeterminedRequests() {
        let statuses: [SFSpeechRecognizerAuthorizationStatus] = [.notDetermined, .denied, .restricted, .authorized]
        for inProcess in [true, false] {
            for status in statuses {
                let expected = inProcess && status == .notDetermined
                XCTAssertEqual(
                    VoicePermissions.shouldRequestSpeech(providerIsInProcess: inProcess, status: status),
                    expected,
                    "inProcess=\(inProcess) status=\(status.rawValue)"
                )
            }
        }
    }

    // MARK: - Setup-Guide readiness gate

    /// Apple on-device active: denied/restricted Speech BLOCKS readiness;
    /// authorized/notDetermined are ready (the preflight requests notDetermined first).
    func testReadinessGateInProcess() {
        XCTAssertTrue(ActionButtonStepView.shouldDeclareReady(providerIsInProcess: true, status: .authorized))
        XCTAssertTrue(ActionButtonStepView.shouldDeclareReady(providerIsInProcess: true, status: .notDetermined))
        XCTAssertFalse(ActionButtonStepView.shouldDeclareReady(providerIsInProcess: true, status: .denied))
        XCTAssertFalse(ActionButtonStepView.shouldDeclareReady(providerIsInProcess: true, status: .restricted))
    }

    /// Cloud STT active: always ready regardless of Speech status (it's never used).
    func testReadinessGateCloudAlwaysReady() {
        for status in [ActionButtonStepView.SpeechReadinessStatus.notDetermined, .denied, .restricted, .authorized] {
            XCTAssertTrue(
                ActionButtonStepView.shouldDeclareReady(providerIsInProcess: false, status: status),
                "cloud must be ready for status \(status)"
            )
        }
    }

    /// The negative invariant the founder cares about: a DENIED Speech for an
    /// active Apple provider must NOT declare the headless trigger ready.
    func testDeniedSpeechDoesNotDeclareReady() {
        XCTAssertFalse(ActionButtonStepView.shouldDeclareReady(providerIsInProcess: true, status: .denied))
    }
}

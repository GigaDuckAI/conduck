// Conduck
// AppErrorTroubleshootableTests.swift
//
// Truth-table coverage for `AppError.isTroubleshootable` — the SINGLE source of
// truth behind every "Troubleshoot" affordance (`DiagnosticsFocus` gates on it).
// It is a DENY-LIST (a newly-added code is troubleshootable by default), so the
// value of this test is pinning the exact set that must stay FALSE: a regression
// that dropped a case from the deny-list would silently start offering a useless
// "Troubleshoot" button for a local-audio / self-evident-content failure the
// Diagnostics screen can't reason about.

import XCTest
@testable import Conduck

final class AppErrorTroubleshootableTests: XCTestCase {

    // MARK: - Deny-list — MUST be false

    /// The complete, exhaustive deny-list. If a case is added/removed here it is
    /// a deliberate product decision, and this list must move with it. Every one
    /// of these is a failure Diagnostics can't help with: local audio problems
    /// (invalid / missing / too-large / processing-failed / mic-busy), self-evident
    /// content/usage errors (no speech, image too large, chat too long, blocked
    /// text), or a settings-load fault.
    func testDenyListCasesAreNotTroubleshootable() {
        let denyList: [(name: String, error: AppError)] = [
            ("audioInvalid",                .audioInvalid),
            ("audioMissingData",            .audioMissingData),
            ("settingsLoadFailed",          .settingsLoadFailed),
            ("noSpeechDetected",            .noSpeechDetected),
            ("audioTooLarge",               .audioTooLarge),
            ("audioProcessingFailed",       .audioProcessingFailed),
            ("audioMicBusy",                .audioMicBusy),
            ("remoteAgentVisionUnsupported", .remoteAgentVisionUnsupported),
            ("remoteAgentImageTooLarge",    .remoteAgentImageTooLarge),
            ("remoteAgentContextTooLong",   .remoteAgentContextTooLong),
            ("ttsContentBlocked",           .ttsContentBlocked),
        ]
        for kase in denyList {
            XCTAssertFalse(kase.error.isTroubleshootable,
                           "\(kase.name) is on the Diagnostics deny-list and MUST NOT be troubleshootable — the screen can't help with it.")
        }
    }

    // MARK: - Representative troubleshootable set — MUST be true

    /// A representative slice of the environmental class Diagnostics CAN reason
    /// about: connection / gateway / auth / cert / model / rate-limit / permission
    /// / file-transfer / STT / TTS transport. These must stay troubleshootable so
    /// the "Troubleshoot" affordance appears for the failures a user can actually
    /// self-diagnose from the screen.
    func testEnvironmentalCasesAreTroubleshootable() {
        let troubleshootable: [(name: String, error: AppError)] = [
            ("remoteAgentUnreachable",      .remoteAgentUnreachable),
            ("remoteAgentAuthFailed",       .remoteAgentAuthFailed),
            ("remoteAgentCertMismatch",     .remoteAgentCertMismatch),
            ("remoteAgentModelUnavailable", .remoteAgentModelUnavailable),
            ("remoteAgentRateLimited",      .remoteAgentRateLimited),
            ("fileTransferUploadFailed",    .fileTransferUploadFailed),
            ("speechPermissionDenied",      .speechPermissionDenied),
            ("sttProviderUnreachable",      .sttProviderUnreachable),
            ("noInternetConnection",        .noInternetConnection),
            ("ttsUnauthorized",             .ttsUnauthorized),
        ]
        for kase in troubleshootable {
            XCTAssertTrue(kase.error.isTroubleshootable,
                          "\(kase.name) is an environmental failure Diagnostics can reason about — it MUST be troubleshootable.")
        }
    }
}

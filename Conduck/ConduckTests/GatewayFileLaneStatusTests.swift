// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayFileLaneStatusTests.swift
//
// Unit coverage for `SettingsViewModel.fileLaneStatus(for:)` — the first-class
// "Files and outputs" row status on the redesigned gateway editor. The helper
// is PURE (reads only published VM dicts + the backend registry; no Keychain /
// SettingsManager / network), so this suite runs fully on the unsigned headless
// sim. It folds three signals the row depends on: capability (`.unsupported`
// hides the row for OpenRouter), the coarse `fileTransferSetupState`, and — for
// a saved-but-not-ready gateway — the failure signal from the staged
// `fileTransferTestResults` (last test ran & failed → `.needsAttention`,
// never-tested → `.saved`). A not-yet-set-up gateway is `.recommended` on the
// built-in full agents and `.optional` on customs.

import XCTest
@testable import Conduck

@MainActor
final class GatewayFileLaneStatusTests: XCTestCase {

    private func makeVM(for refs: [RemoteAgentRef]) -> SettingsViewModel {
        let vm = SettingsViewModel()
        for ref in refs {
            vm.fileServerURLStrings[ref] = nil
            vm.fileServerURLPresent[ref] = nil
            vm.fileServerCredentialPresent[ref] = nil
            vm.fileServerValidationStates[ref] = nil
            vm.fileTransferTestResults[ref] = nil
            vm.fileTransferTestSignatures.removeValue(forKey: ref)
            vm.fileServerPersistedURLStrings.removeValue(forKey: ref)
            vm.fileServerPersistedPins.removeValue(forKey: ref)
            vm.fileServerCredentialGenerations.removeValue(forKey: ref)
            vm.fileTransferAvailableRefSet.remove(ref)
        }
        return vm
    }

    private func configureSaved(_ vm: SettingsViewModel, _ ref: RemoteAgentRef) {
        // "Saved" = a PERSISTED URL (the mirror), not merely a typed buffer, plus a
        // stored credential — matches `fileTransferSetupState`'s derivation.
        vm.fileServerURLPresent[ref] = true
        vm.fileServerCredentialPresent[ref] = true
        vm.fileServerPersistedURLStrings[ref] = "https://files.example:8444"
    }

    /// Stamp a test verdict AS IF it probed the ref's persisted tuple —
    /// `.needsAttention` requires the failure's signature to match the saved
    /// config (a failed DRAFT probe must not paint the persisted lane red).
    private func stampVerdict(_ vm: SettingsViewModel, _ ref: RemoteAgentRef, result: FileTransferTestResult) {
        vm.fileTransferTestResults[ref] = result
        vm.fileTransferTestSignatures[ref] = vm.persistedFileTransferSignature(for: ref)
    }

    // MARK: - Capability

    /// OpenRouter is a hosted model with no file lane → row hidden, regardless
    /// of any (impossible) saved state.
    func testOpenRouterAlwaysUnsupported() {
        let ref: RemoteAgentRef = .builtin(.openrouter)
        let vm = makeVM(for: [ref])
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .unsupported)
        configureSaved(vm, ref)
        vm.fileTransferAvailableRefSet.insert(ref)
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .unsupported)
    }

    // MARK: - Not set up → recommended (built-ins) vs optional (custom)

    func testOpenClawMissingIsRecommended() {
        let ref: RemoteAgentRef = .builtin(.openclaw)
        let vm = makeVM(for: [ref])
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .recommended)
    }

    func testHermesMissingIsRecommended() {
        let ref: RemoteAgentRef = .builtin(.hermes)
        let vm = makeVM(for: [ref])
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .recommended)
    }

    func testCustomMissingIsOptional() {
        let ref: RemoteAgentRef = .custom(UUID())
        let vm = makeVM(for: [ref])
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .optional)
    }

    // MARK: - Saved (not yet tested) vs needs attention (tested & failed)

    func testSavedButUntestedIsSaved() {
        let ref: RemoteAgentRef = .builtin(.openclaw)
        let vm = makeVM(for: [ref])
        configureSaved(vm, ref)
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .saved)
    }

    func testSavedWithFailedTestIsNeedsAttention() {
        let ref: RemoteAgentRef = .builtin(.openclaw)
        let vm = makeVM(for: [ref])
        configureSaved(vm, ref)
        // The real "needs attention" signal is a staged test that RAN and failed
        // (write/read/delete) FOR THE PERSISTED TUPLE, surfaced via the
        // signature-stamped fileTransferTestResults — NOT
        // fileServerValidationStates (which only carries the URL-save verdict).
        stampVerdict(vm, ref, result: FileTransferTestResult(
            reachedStage: .write, success: false, failure: nil
        ))
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .needsAttention)
    }

    /// A failed probe of an edited DRAFT tuple (signature ≠ persisted) must NOT
    /// paint the persisted lane red — the saved config never failed a test.
    func testFailedDraftProbeDoesNotFlagPersistedLane() {
        let ref: RemoteAgentRef = .builtin(.openclaw)
        let vm = makeVM(for: [ref])
        configureSaved(vm, ref)
        vm.fileTransferTestResults[ref] = FileTransferTestResult(
            reachedStage: .write, success: false, failure: nil
        )
        vm.fileTransferTestSignatures[ref] = FileTransferTestSignature(
            url: "https://draft-edit.example:9999", pin: "", credentialGeneration: 0
        )
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .saved)
    }

    /// A passing staged test that hasn't yet flipped availability is NOT
    /// "needs attention" (success == true → fall through to .saved/.ready).
    func testSavedWithPassingResultIsNotNeedsAttention() {
        let ref: RemoteAgentRef = .builtin(.openclaw)
        let vm = makeVM(for: [ref])
        configureSaved(vm, ref)
        stampVerdict(vm, ref, result: FileTransferTestResult(
            reachedStage: .read, success: true, failure: nil
        ))
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .saved)
    }

    /// A custom gateway uses the same saved/failed split.
    func testCustomSavedWithFailedTestIsNeedsAttention() {
        let ref: RemoteAgentRef = .custom(UUID())
        let vm = makeVM(for: [ref])
        configureSaved(vm, ref)
        stampVerdict(vm, ref, result: FileTransferTestResult(
            reachedStage: .auth, success: false, failure: nil
        ))
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .needsAttention)
    }

    // MARK: - Ready

    func testReadyWhenAvailable() {
        let ref: RemoteAgentRef = .builtin(.openclaw)
        let vm = makeVM(for: [ref])
        configureSaved(vm, ref)
        vm.fileTransferAvailableRefSet.insert(ref)
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .ready)
    }

    /// A passing WebDAV probe proves the server moved a test file up and back
    /// down. It does not prove the agent's workspace or tool policy — and,
    /// load-bearing here, it does not prove the RETURN direction either, because
    /// this badge is derived from PERSISTED state and the only listing outcome
    /// that persists is the structural refusal. A green badge claiming "listed a
    /// folder" would go on claiming it after relaunch on a lane whose listing
    /// probe had merely timed out.
    func testReadyPresentationClaimsOnlyWhatItDurablyKnows() {
        let status = GatewayFileLaneStatus.ready
        XCTAssertEqual(status.shortLabel.map { String(localized: $0) }, "Server tested")
        XCTAssertEqual(status.pageTitle.map { String(localized: $0) }, "File server tested")
        XCTAssertEqual(
            status.meaning.map { String(localized: $0) },
            "Conduck uploaded and retrieved a test file."
        )
        XCTAssertFalse(
            (status.meaning.map { String(localized: $0) } ?? "").contains("both ways"),
            "the green badge may never assert a direction nothing durable measured")
        XCTAssertEqual(status.systemImage, "checkmark.circle.fill")
    }

    /// The third badge: neither green nor red, amber, and it says which half
    /// works before it says which does not.
    func testUploadsOnlyPresentationNamesBothHalves() {
        let status = GatewayFileLaneStatus.readyUploadsOnly
        XCTAssertEqual(status.shortLabel.map { String(localized: $0) }, "Uploads only")
        XCTAssertEqual(status.tint, AppColors.warning,
                       "never the success tint — the lane is half of what the user set up")
        let meaning = status.meaning.map { String(localized: $0) } ?? ""
        XCTAssertTrue(meaning.contains("read it back"), "what works comes first")
        XCTAssertTrue(meaning.contains("can't list folders"), "then what does not")
        XCTAssertTrue(meaning.contains("on the server"),
                      "and where the files still are — nothing has been lost, only auto-delivery")
    }

    func testEveryVisibleStatusHasACompactPagePresentation() {
        for status in [
            GatewayFileLaneStatus.ready,
            .readyUploadsOnly,
            .needsAttention,
            .saved,
            .recommended,
            .optional
        ] {
            XCTAssertNotNil(status.pageTitle)
            XCTAssertNotNil(status.meaning)
            XCTAssertNotNil(status.systemImage)
        }
        XCTAssertNil(GatewayFileLaneStatus.unsupported.pageTitle)
        XCTAssertNil(GatewayFileLaneStatus.unsupported.systemImage)
    }

    /// `.saved` states the REMEDY, never a claim about history. A lane whose staged
    /// test FAILED lands back here (the commit revokes availability), and once the
    /// session's result is gone it is indistinguishable from a lane nobody ever
    /// tested — so "not tested yet" was a claim the app could not back, while "test
    /// required" is true in both cases.
    func testTheSavedStatusStatesTheRemedyNotTheHistory() throws {
        let short = String(localized: try XCTUnwrap(GatewayFileLaneStatus.saved.shortLabel))
        let title = String(localized: try XCTUnwrap(GatewayFileLaneStatus.saved.pageTitle))
        XCTAssertEqual(short, "Test required")
        XCTAssertEqual(title, "File server test required")
        for copy in [short, title] {
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("not tested"),
                           "a previously-failed lane derives this same state: \(copy)")
        }
    }

    /// Ready wins even if a stale `.invalid` lingers — availability is the
    /// authoritative "usable" signal (a later passing test cleared the failure).
    func testReadyOutranksStaleInvalid() {
        let ref: RemoteAgentRef = .builtin(.hermes)
        let vm = makeVM(for: [ref])
        configureSaved(vm, ref)
        vm.fileServerValidationStates[ref] = .invalid(message: "old failure")
        vm.fileTransferAvailableRefSet.insert(ref)
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .ready)
    }

    // MARK: - Isolation

    func testPerRefIsolation() {
        let openclaw: RemoteAgentRef = .builtin(.openclaw)
        let hermes: RemoteAgentRef = .builtin(.hermes)
        let vm = makeVM(for: [openclaw, hermes])
        configureSaved(vm, openclaw)
        vm.fileTransferAvailableRefSet.insert(openclaw)
        XCTAssertEqual(vm.fileLaneStatus(for: openclaw), .ready)
        XCTAssertEqual(vm.fileLaneStatus(for: hermes), .recommended)
    }
}

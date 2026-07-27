// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileTransferDraftVerdictTests.swift
//
// Unit coverage for the signature-keyed draft-verdict machinery behind the
// file-transfer editor's Test Connection / Save split:
//   - `fileTransferDraftSignature(for:)` — canonical URL + normalized pin +
//     credential generation, nil for an unprobeable draft;
//   - `persistedFileTransferSignature(for:)` — the saved tuple, from the
//     persisted mirrors;
//   - `displayedFileTransferTestResult(for:)` — a staged verdict displays ONLY
//     while the draft still matches the tuple it probed (editing orphans it;
//     restoring the exact tuple legitimately resurrects it; a credential
//     rotation kills it via the generation bump);
//   - `cancelFileTransferEdit(for:)` — buffers revert to the mirrors and a
//     staged DRAFT verdict is retired, while a persisted-matching verdict
//     survives the discard.
//
// All helpers are PURE (published VM dicts only — no Keychain / SettingsManager
// / network), so this suite runs fully on the unsigned headless sim.

import XCTest
@testable import Conduck

@MainActor
final class FileTransferDraftVerdictTests: XCTestCase {

    private let ref: RemoteAgentRef = .builtin(.openclaw)

    private func makeVM() -> SettingsViewModel {
        let vm = SettingsViewModel()
        vm.fileServerURLStrings[ref] = nil
        vm.fileServerURLPresent[ref] = nil
        vm.fileServerCredentialPresent[ref] = nil
        vm.fileServerCertFingerprints.removeValue(forKey: ref)
        vm.fileServerPersistedURLStrings.removeValue(forKey: ref)
        vm.fileServerPersistedPins.removeValue(forKey: ref)
        vm.fileServerCredentialGenerations.removeValue(forKey: ref)
        vm.fileTransferTestResults.removeValue(forKey: ref)
        vm.fileTransferTestSignatures.removeValue(forKey: ref)
        vm.fileTransferAvailableRefSet.remove(ref)
        return vm
    }

    private func passResult() -> FileTransferTestResult {
        FileTransferTestResult(reachedStage: .read, success: true, failure: nil, folderCapable: true)
    }

    private func failResult() -> FileTransferTestResult {
        FileTransferTestResult(reachedStage: .write, success: false, failure: nil, folderCapable: true)
    }

    // MARK: - Draft signature derivation

    func testDraftSignatureNilForEmptyURL() {
        let vm = makeVM()
        XCTAssertNil(vm.fileTransferDraftSignature(for: ref))
    }

    func testDraftSignatureNilForHTTPURL() {
        let vm = makeVM()
        vm.fileServerURLStrings[ref] = "http://plain.example:8444"
        XCTAssertNil(vm.fileTransferDraftSignature(for: ref))
    }

    func testDraftSignatureNilForGarbagePin() {
        let vm = makeVM()
        vm.fileServerURLStrings[ref] = "https://files.example:8444"
        vm.fileServerCertFingerprints[ref] = "not-a-fingerprint"
        XCTAssertNil(vm.fileTransferDraftSignature(for: ref))
    }

    func testDraftSignatureNormalizesPinCaseAndColons() {
        let vm = makeVM()
        let hex = String(repeating: "ab", count: 32) // 64 hex chars
        let colonized = stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 2)]).uppercased()
        }.joined(separator: ":")
        vm.fileServerURLStrings[ref] = "https://files.example:8444"
        vm.fileServerCertFingerprints[ref] = colonized
        XCTAssertEqual(vm.fileTransferDraftSignature(for: ref)?.pin, hex)
    }

    func testDraftSignatureTracksCredentialGeneration() {
        let vm = makeVM()
        vm.fileServerURLStrings[ref] = "https://files.example:8444"
        XCTAssertEqual(vm.fileTransferDraftSignature(for: ref)?.credentialGeneration, 0)
        vm.fileServerCredentialGenerations[ref] = 3
        XCTAssertEqual(vm.fileTransferDraftSignature(for: ref)?.credentialGeneration, 3)
    }

    // MARK: - Persisted signature

    func testPersistedSignatureNilWithoutPersistedURL() {
        let vm = makeVM()
        // A typed buffer alone must not produce a persisted signature.
        vm.fileServerURLStrings[ref] = "https://files.example:8444"
        XCTAssertNil(vm.persistedFileTransferSignature(for: ref))
    }

    func testPersistedSignatureFromMirrors() {
        let vm = makeVM()
        vm.fileServerURLPresent[ref] = true
        vm.fileServerPersistedURLStrings[ref] = "https://files.example:8444"
        vm.fileServerPersistedPins[ref] = String(repeating: "0", count: 64)
        let signature = vm.persistedFileTransferSignature(for: ref)
        XCTAssertEqual(signature?.url, "https://files.example:8444")
        XCTAssertEqual(signature?.pin, String(repeating: "0", count: 64))
        XCTAssertEqual(signature?.credentialGeneration, 0)
    }

    /// The persisted signature canonicalizes its pin the same way the draft
    /// does — a store that somehow holds a colon-formatted pin must not make a
    /// pristine editor read dirty (or block a live-tuple verdict) forever.
    func testPersistedSignatureNormalizesPin() {
        let vm = makeVM()
        vm.fileServerURLPresent[ref] = true
        vm.fileServerPersistedURLStrings[ref] = "https://files.example:8444"
        vm.fileServerPersistedPins[ref] = "AB:" + String(repeating: "0", count: 62)
        XCTAssertEqual(
            vm.persistedFileTransferSignature(for: ref)?.pin,
            "ab" + String(repeating: "0", count: 62)
        )
    }

    /// A pristine editor (buffers hydrated from the mirrors) has draft ==
    /// persisted — the invariant that lets a pristine re-test apply to
    /// availability immediately.
    func testPristineDraftMatchesPersistedSignature() {
        let vm = makeVM()
        vm.fileServerURLPresent[ref] = true
        vm.fileServerPersistedURLStrings[ref] = "https://files.example:8444"
        vm.fileServerURLStrings[ref] = "https://files.example:8444"
        XCTAssertNotNil(vm.fileTransferDraftSignature(for: ref))
        XCTAssertEqual(vm.fileTransferDraftSignature(for: ref), vm.persistedFileTransferSignature(for: ref))
    }

    // MARK: - Displayed verdict gating

    private func stageMatchingVerdict(_ vm: SettingsViewModel, result: FileTransferTestResult) {
        vm.fileServerURLStrings[ref] = "https://files.example:8444"
        guard let signature = vm.fileTransferDraftSignature(for: ref) else {
            return XCTFail("draft signature should exist")
        }
        vm.fileTransferTestResults[ref] = result
        vm.fileTransferTestSignatures[ref] = signature
    }

    func testVerdictDisplaysWhileDraftMatches() {
        let vm = makeVM()
        stageMatchingVerdict(vm, result: passResult())
        XCTAssertEqual(vm.displayedFileTransferTestResult(for: ref)?.success, true)
    }

    func testVerdictHidesAfterURLEdit() {
        let vm = makeVM()
        stageMatchingVerdict(vm, result: passResult())
        vm.fileServerURLStrings[ref] = "https://files.example:9999"
        XCTAssertNil(vm.displayedFileTransferTestResult(for: ref))
    }

    func testVerdictHidesAfterPinEdit() {
        let vm = makeVM()
        stageMatchingVerdict(vm, result: passResult())
        vm.fileServerCertFingerprints[ref] = String(repeating: "f", count: 64)
        XCTAssertNil(vm.displayedFileTransferTestResult(for: ref))
    }

    /// Restoring the exact tested tuple legitimately resurrects the verdict —
    /// it is signature-keyed fact about that tuple, not edit history.
    func testVerdictResurrectsWhenExactTupleRestored() {
        let vm = makeVM()
        stageMatchingVerdict(vm, result: passResult())
        vm.fileServerURLStrings[ref] = "https://files.example:9999"
        XCTAssertNil(vm.displayedFileTransferTestResult(for: ref))
        vm.fileServerURLStrings[ref] = "https://files.example:8444"
        XCTAssertEqual(vm.displayedFileTransferTestResult(for: ref)?.success, true)
    }

    /// A credential rotation bumps the generation — a verdict earned against
    /// the OLD password must never describe the new one, even though URL and
    /// pin are unchanged.
    func testVerdictHidesAfterCredentialGenerationBump() {
        let vm = makeVM()
        stageMatchingVerdict(vm, result: passResult())
        vm.fileServerCredentialGenerations[ref] = 1
        XCTAssertNil(vm.displayedFileTransferTestResult(for: ref))
    }

    // MARK: - Cancel / discard

    func testCancelRevertsBuffersToMirrors() {
        let vm = makeVM()
        vm.fileServerURLPresent[ref] = true
        vm.fileServerPersistedURLStrings[ref] = "https://files.example:8444"
        vm.fileServerPersistedPins[ref] = String(repeating: "0", count: 64)
        vm.fileServerURLStrings[ref] = "https://edited.example:1111"
        vm.fileServerCertFingerprints[ref] = String(repeating: "f", count: 64)

        vm.cancelFileTransferEdit(for: ref)

        XCTAssertEqual(vm.fileServerURLStrings[ref], "https://files.example:8444")
        XCTAssertEqual(vm.fileServerCertFingerprints[ref], String(repeating: "0", count: 64))
    }

    func testCancelClearsStagedDraftVerdict() {
        let vm = makeVM()
        // Persisted tuple A (URL + credential); staged FAILED verdict for
        // draft tuple B.
        vm.fileServerURLPresent[ref] = true
        vm.fileServerCredentialPresent[ref] = true
        vm.fileServerPersistedURLStrings[ref] = "https://files.example:8444"
        vm.fileServerURLStrings[ref] = "https://draft.example:9999"
        guard let draftSignature = vm.fileTransferDraftSignature(for: ref) else {
            return XCTFail("draft signature should exist")
        }
        vm.fileTransferTestResults[ref] = failResult()
        vm.fileTransferTestSignatures[ref] = draftSignature

        vm.cancelFileTransferEdit(for: ref)

        // The abandoned draft's failure must not linger as "Needs attention"
        // against a persisted tuple it never probed.
        XCTAssertNil(vm.fileTransferTestResults[ref])
        XCTAssertNil(vm.fileTransferTestSignatures[ref])
        XCTAssertEqual(vm.fileLaneStatus(for: ref), .saved)
    }

    func testCancelKeepsPersistedMatchingVerdict() {
        let vm = makeVM()
        vm.fileServerURLPresent[ref] = true
        vm.fileServerPersistedURLStrings[ref] = "https://files.example:8444"
        vm.fileServerURLStrings[ref] = "https://files.example:8444"
        guard let signature = vm.fileTransferDraftSignature(for: ref) else {
            return XCTFail("draft signature should exist")
        }
        vm.fileTransferTestResults[ref] = failResult()
        vm.fileTransferTestSignatures[ref] = signature

        vm.cancelFileTransferEdit(for: ref)

        // A verdict about the LIVE tuple survives a discard — it still
        // describes exactly what is persisted.
        XCTAssertNotNil(vm.fileTransferTestResults[ref])
        XCTAssertEqual(vm.fileTransferTestSignatures[ref], signature)
    }
}

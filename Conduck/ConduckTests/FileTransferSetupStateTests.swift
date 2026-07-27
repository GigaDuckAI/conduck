// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileTransferSetupStateTests.swift
//
// Unit coverage for `SettingsViewModel.fileTransferSetupState(for:)` — the
// three-state axis (`.missing` / `.savedNeedsTest` / `.ready`) the redesigned
// `FileTransferSetupGuideView` lays out around. The helper is PURE: it reads
// only the already-published VM dictionaries (`fileServerURLPresent` — the
// PERSISTED-URL mirror, NOT the live typed buffer — and
// `fileServerCredentialPresent`) and the availability set, with NO Keychain /
// SettingsManager / network I/O — so this suite runs fully on the unsigned
// headless sim (no XCTSkip needed). We set the backing state directly and
// assert the derived enum.

import XCTest
@testable import Conduck

@MainActor
final class FileTransferSetupStateTests: XCTestCase {

    private let ref: RemoteAgentRef = .builtin(.openclaw)

    private func makeVM() -> SettingsViewModel {
        let vm = SettingsViewModel()
        // Start from a clean per-ref slate (a fresh VM may have loaded ambient
        // state on init — we own these dicts for the ref under test).
        vm.fileServerURLStrings[ref] = nil
        vm.fileServerURLPresent[ref] = nil
        vm.fileServerCredentialPresent[ref] = nil
        vm.fileTransferAvailableRefSet.remove(ref)
        return vm
    }

    func testMissingWhenNothingSet() {
        let vm = makeVM()
        XCTAssertEqual(vm.fileTransferSetupState(for: ref), .missing)
    }

    func testMissingWithURLButNoCredential() {
        let vm = makeVM()
        vm.fileServerURLPresent[ref] = true
        XCTAssertEqual(vm.fileTransferSetupState(for: ref), .missing)
    }

    func testMissingWithCredentialButNoURL() {
        let vm = makeVM()
        vm.fileServerCredentialPresent[ref] = true
        XCTAssertEqual(vm.fileTransferSetupState(for: ref), .missing)
    }

    /// The item-5 regression: a URL the user TYPED but never saved lives only in
    /// the live `fileServerURLStrings` buffer, not the persisted mirror — it must
    /// NOT read as "saved" (it vanishes on relaunch), even with a credential.
    func testUnsavedURLBufferDoesNotReadAsSaved() {
        let vm = makeVM()
        vm.fileServerURLStrings[ref] = "https://typed-but-never-saved.example"
        vm.fileServerCredentialPresent[ref] = true
        // Mirror stays false — nothing persisted.
        XCTAssertEqual(vm.fileTransferSetupState(for: ref), .missing)
    }

    func testSavedNeedsTestWithURLAndCredentialButNotAvailable() {
        let vm = makeVM()
        vm.fileServerURLPresent[ref] = true
        vm.fileServerCredentialPresent[ref] = true
        XCTAssertEqual(vm.fileTransferSetupState(for: ref), .savedNeedsTest)
    }

    func testReadyWhenAvailable() {
        let vm = makeVM()
        vm.fileServerURLPresent[ref] = true
        vm.fileServerCredentialPresent[ref] = true
        vm.fileTransferAvailableRefSet.insert(ref)
        XCTAssertEqual(vm.fileTransferSetupState(for: ref), .ready)
    }

    /// `.ready` short-circuits on the availability set — it strictly implies a
    /// saved snapshot in practice (the test can only pass once one exists), so
    /// availability is the authoritative "usable" signal.
    func testReadyShortCircuitsAvailabilitySet() {
        let vm = makeVM()
        vm.fileTransferAvailableRefSet.insert(ref)
        XCTAssertEqual(vm.fileTransferSetupState(for: ref), .ready)
    }

    /// Per-ref isolation: configuring one gateway never leaks state onto another.
    func testPerRefIsolation() {
        let vm = makeVM()
        let other: RemoteAgentRef = .builtin(.hermes)
        vm.fileServerURLPresent[ref] = true
        vm.fileServerCredentialPresent[ref] = true
        vm.fileTransferAvailableRefSet.insert(ref)
        XCTAssertEqual(vm.fileTransferSetupState(for: other), .missing)
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelCredentialPurgeTests.swift
//
// Credential-lifecycle regressions from the pre-publication security review.
// Three independent locks, all on `SettingsViewModel`:
//
//  1. FORGET GATEWAY IS A TERMINAL PER-REF WIPE. `clearRemoteAgent(for:)` must
//     take the file-server lane bound to the same ref with it (URL, credential,
//     cert pin, `available`). A surviving lane re-arms `fileTransferReadySnapshot`
//     against the OLD server on a built-in's next reconfigure (built-in refs are
//     reused), and on a deleted CUSTOM the slots are orphaned with no UI able to
//     reach them.
//
//  2. FILE-SERVER URL USERINFO IS REJECTED, NOT PERSISTED. The file-server URL is
//     dual-written to App-Group defaults AND iCloud KVS, so `https://u:p@host`
//     would put a plaintext password in a store the privacy invariant reserves
//     for non-secrets. Conduck mints + owns this credential and sets its own
//     `Authorization: Basic` header, so userinfo is unambiguously user error —
//     rejected with named copy rather than silently stripped.
//
//  3. CLEARING THE ACTIVE PRESET'S KEY FALLS THE ACTIVE POINTERS BACK TO APPLE.
//     A paired Watch keeps its OWN copy of every cloud STT key it was broadcast
//     (non-sync Keychain) and routes wrist captures purely on `activePresetID`.
//     If the cleared preset stayed active, the wrist would keep uploading audio
//     under the key the user just cleared. The fallback emits the positive
//     `apple-on-device` envelope, which re-routes the wrist to the relay.
//
// Test isolation follows `SettingsViewModelPairingImportTests`: iCloud suspended
// for the suite (the `.shared` singleton dual-writes KVS; a signed-in sim leaks
// cross-suite state into the absence assertions), then an explicit wipe of every
// slot these paths touch in setUp AND tearDown.
//
// Signing gate: anything that must OBSERVE a credential/key in the Keychain
// routes through a probe that `XCTSkip`s on an unsigned build (no
// application-identifier entitlement → `SecItem*` returns
// errSecMissingEntitlement). The non-secret halves run everywhere.
//
// Privacy: synthetic fixtures only (`*.example.test`, fake hex) — never logged.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelCredentialPurgeTests: XCTestCase {

    /// App Groups UserDefaults — same suite the actor uses internally.
    private let defaults = TestStores.defaults

    private let openclaw: RemoteAgentRef = .builtin(.openclaw)

    /// A cloud STT preset with a sibling cloud TTS provider that shares its
    /// Keychain slot (`mistral-tts.sharedKeySTTPresetID == "mistral-voxtral"`) —
    /// so one clear can be observed against BOTH active pointers.
    private let cloudPresetID = "mistral-voxtral"
    private let cloudTTSProviderID = "mistral-tts"

    /// Synthetic 64-hex SPKI fingerprint (the normalizer requires exactly 64 hex).
    private let pinHex = String(repeating: "cd", count: 32)

    override func setUp() async throws {
        try await super.setUp()
        await SettingsManager.shared.setICloudSyncSuspendedForTesting(true)
        await wipeAll()
    }

    override func tearDown() async throws {
        await wipeAll()
        // Restore — the flag lives on the shared singleton and the next suite
        // (e.g. SettingsManagerICloudSyncTests) needs the mirror live.
        await SettingsManager.shared.setICloudSyncSuspendedForTesting(false)
        try await super.tearDown()
    }

    private func wipeAll() async {
        // Customs first — `deleteCustomGateway` clears each one's per-ref gateway
        // slots AND the roster row.
        for gateway in await SettingsManager.shared.customGateways() {
            await SettingsManager.shared.deleteCustomGateway(id: gateway.id)
        }
        defaults.removeObject(forKey: Constants.customGatewaysRegistryKey)
        TestStores.kvs.removeObject(forKey: Constants.customGatewaysRegistryKey)

        defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        TestStores.kvs.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveSessionKey)

        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend)
            await wipeRefSlots(ref)
        }

        // Active STT / TTS pointers back to their defaults (both dual-written).
        for key in [Constants.sttActivePresetIDKVSKey, Constants.ttsActiveProviderIDKVSKey] {
            defaults.removeObject(forKey: key)
            TestStores.kvs.removeObject(forKey: key)
        }
    }

    /// Remove every per-ref slot the gateway + file lane own, in BOTH stores.
    private func wipeRefSlots(_ ref: RemoteAgentRef) async {
        // EVERY per-ref key family, not just the ones a Forget used to touch.
        // The short list is what let `remoteAgent.model.*`, the transport hint,
        // the last-success record, the image-history policy and the two
        // folder-probe markers accumulate as orphans: a slot absent from this
        // wipe is a slot no purge test can notice being left behind.
        for key in [
            Constants.remoteAgentURLKey(for: ref),
            Constants.remoteAgentCertFingerprintKey(for: ref),
            Constants.remoteAgentAuthSchemeKey(for: ref),
            Constants.remoteAgentModelKey(for: ref),
            Constants.remoteAgentTransportHintKey(for: ref),
            Constants.remoteAgentLastChatSuccessKey(for: ref),
            Constants.imageHistoryPolicyKey(for: ref),
            Constants.fileServerURLKey(for: ref),
            Constants.fileServerCertFingerprintKey(for: ref),
            Constants.fileTransferAvailableKey(for: ref),
            Constants.fileServerFolderCapableKey(for: ref),
            Constants.fileServerTestedLocallyKey(for: ref),
            Constants.fileServerFolderProbeRevisionKey(for: ref),
            Constants.fileServerFolderProbeAttemptKey(for: ref)
        ] {
            defaults.removeObject(forKey: key)
            TestStores.kvs.removeObject(forKey: key)
        }
        try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
        try? await SettingsManager.shared.clearFileServerCredential(for: ref)
    }

    /// Fresh VM with the init-load drained, so a late async reload can't wipe an
    /// in-memory mirror mid-test (mirrors `SettingsViewModelPairingImportTests`).
    private func makeVM() async -> SettingsViewModel {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        return vm
    }

    /// Probe the file-server credential Keychain slot, skipping on an unsigned
    /// build (errSecMissingEntitlement).
    private func requireFileServerKeychainOrSkip(for ref: RemoteAgentRef) async throws {
        do {
            try await SettingsManager.shared.setFileServerCredential("probe-credential", for: ref)
            try await SettingsManager.shared.clearFileServerCredential(for: ref)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    /// Probe the STT key Keychain slot, skipping on an unsigned build. Uses a
    /// throwaway preset id so a live key for a real preset can never be clobbered.
    private func requireSTTKeychainOrSkip() async throws {
        let probePreset = "purge-tests-probe-preset"
        do {
            try await SettingsManager.shared.setAPIKey("probe-key", forPresetID: probePreset)
            try await SettingsManager.shared.clearAPIKey(forPresetID: probePreset)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
    }

    /// Stand a ready-looking file lane up on `ref` WITHOUT the credential (so the
    /// non-secret assertions can run unsigned).
    private func seedNonSecretFileLane(on ref: RemoteAgentRef) async {
        await SettingsManager.shared.setFileServerURL(
            URL(string: "https://files.old-host.example.test:8444")!, for: ref
        )
        await SettingsManager.shared.setFileServerCertFingerprint(pinHex, for: ref)
        await SettingsManager.shared.setFileTransferAvailable(true, for: ref)
        await SettingsManager.shared.setFileServerTestedLocally(true, for: ref)
    }

    // MARK: - 1. Forget gateway purges the file lane (built-in — non-secret half)

    func testForgetBuiltinGatewayPurgesNonSecretFileLane() async throws {
        await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://gw.old-host.example.test:18789")!, for: openclaw
        )
        await seedNonSecretFileLane(on: openclaw)

        let vm = await makeVM()
        XCTAssertTrue(vm.fileTransferAvailableRefSet.contains(openclaw),
                      "Precondition: the seeded lane must read as available before the Forget.")

        await vm.clearRemoteAgent(for: openclaw)

        let fileServerURL3 = await SettingsManager.shared.getFileServerURL(for: openclaw)
        XCTAssertNil(fileServerURL3,
                     "Forget gateway must erase the file-server URL — a built-in ref is REUSED, so a surviving URL re-arms the lane against the old server.")
        let fileTransferAvailable2 = await SettingsManager.shared.getFileTransferAvailable(for: openclaw)
        XCTAssertFalse(fileTransferAvailable2,
                       "Forget gateway must revoke file-transfer readiness.")
        let fileServerCertFingerprint2 = await SettingsManager.shared.getFileServerCertFingerprint(for: openclaw)
        XCTAssertNil(fileServerCertFingerprint2,
                     "Forget gateway must erase the per-device cert pin.")
        let fileServerTestedLocally = await SettingsManager.shared.getFileServerTestedLocally(for: openclaw)
        XCTAssertFalse(fileServerTestedLocally,
                       "Forget gateway must forfeit local test proof, so a re-add can't inherit stale provenance.")
        XCTAssertFalse(vm.fileTransferAvailableRefSet.contains(openclaw),
                       "The VM's availability mirror must drop the ref too — one idiom, not two stores.")
        XCTAssertEqual(vm.fileServerURLStrings[openclaw], "",
                       "The editor's URL buffer must not keep showing the forgotten server.")
        XCTAssertFalse(vm.fileServerCredentialPresent[openclaw] ?? true,
                       "The credential-present mirror must read absent after a Forget.")
    }

    // MARK: - 1b. Forget gateway purges the credential (signing-gated)

    func testForgetBuiltinGatewayPurgesFileServerCredentialOrSkipUnsigned() async throws {
        try await requireFileServerKeychainOrSkip(for: openclaw)

        await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://gw.old-host.example.test:18789")!, for: openclaw
        )
        await seedNonSecretFileLane(on: openclaw)
        try await SettingsManager.shared.setFileServerCredential(
            "feedfacecafebeeffeedfacecafebeef", for: openclaw
        )
        let fileServerCredential2 = await SettingsManager.shared.getFileServerCredential(for: openclaw)
        XCTAssertNotNil(fileServerCredential2,
                        "Precondition: the credential must be stored before the Forget.")

        let vm = await makeVM()
        await vm.clearRemoteAgent(for: openclaw)

        let fileServerCredential = await SettingsManager.shared.getFileServerCredential(for: openclaw)
        XCTAssertNil(fileServerCredential,
                     "Forget gateway must delete the file-server credential from the Keychain — it is synchronizable, so a survivor persists on every device the user owns with no UI able to reach it.")
        let fileTransferSnapshot = await SettingsManager.shared.fileTransferSnapshot(for: openclaw)
        XCTAssertNil(fileTransferSnapshot,
                     "With URL and credential both gone there must be no assemblable snapshot at all.")
    }

    // MARK: - 1c. Deleting a CUSTOM gateway purges its file lane

    func testForgetCustomGatewayPurgesNonSecretFileLane() async throws {
        let vm = await makeVM()
        guard let draftID = vm.newCustomGatewayDraftID() else {
            return XCTFail("Custom-gateway draft mint must succeed on an empty roster.")
        }
        let customRef = RemoteAgentRef.custom(draftID)
        // Explicit per-ref teardown: `wipeAll()` deletes the roster row but a
        // custom's file-lane slots are keyed by its UUID suffix, which nothing
        // else enumerates once the row is gone — so an early XCTFail here must
        // not leave residue for the next test.
        addTeardownBlock {
            for key in [
                Constants.fileServerURLKey(for: customRef),
                Constants.fileServerCertFingerprintKey(for: customRef),
                Constants.fileTransferAvailableKey(for: customRef),
                Constants.fileServerTestedLocallyKey(for: customRef)
            ] {
                TestStores.defaults.removeObject(forKey: key)
                TestStores.kvs.removeObject(forKey: key)
            }
            try? await SettingsManager.shared.clearFileServerCredential(for: customRef)
        }

        // Persist just enough of the gateway half that the ref is a real roster
        // row, then stand up the file lane on the SAME suffix.
        _ = await SettingsManager.shared.upsertCustomGateway(
            CustomGateway(id: draftID, name: "Purge Test", model: nil, colorID: nil, monogram: nil)
        )
        await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://custom.example.test:18789")!, for: customRef
        )
        await seedNonSecretFileLane(on: customRef)

        await vm.clearRemoteAgent(for: customRef)

        let fileServerURL2 = await SettingsManager.shared.getFileServerURL(for: customRef)
        XCTAssertNil(fileServerURL2,
                     "Deleting a custom gateway must erase its file-server URL — the suffix is a fresh UUID each time, so a survivor is orphaned forever.")
        let fileTransferAvailable = await SettingsManager.shared.getFileTransferAvailable(for: customRef)
        XCTAssertFalse(fileTransferAvailable,
                       "Deleting a custom gateway must revoke file-transfer readiness.")
        let fileServerCertFingerprint = await SettingsManager.shared.getFileServerCertFingerprint(for: customRef)
        XCTAssertNil(fileServerCertFingerprint,
                     "Deleting a custom gateway must erase its cert pin.")
    }

    // MARK: - 2. File-server URL userinfo

    func testURLCarriesUserinfoClassification() {
        XCTAssertTrue(SettingsViewModel.urlCarriesUserinfo(
            URL(string: "https://conduck:9f3ac1b0e7d2@files.example.test/agent")!
        ), "user:password@ must be detected.")
        XCTAssertTrue(SettingsViewModel.urlCarriesUserinfo(
            URL(string: "https://conduck@files.example.test/agent")!
        ), "A bare username is still userinfo.")
        XCTAssertFalse(SettingsViewModel.urlCarriesUserinfo(
            URL(string: "https://files.example.test:8444/agent")!
        ), "A plain host URL carries no userinfo.")
        XCTAssertFalse(SettingsViewModel.urlCarriesUserinfo(
            URL(string: "https://files.example.test/a@b")!
        ), "An '@' in the PATH is not userinfo — the check must parse, not scan for a literal.")
    }

    func testFileServerURLWithUserinfoIsRejectedAndNeverPersisted() async throws {
        let vm = await makeVM()
        let hostile = "https://conduck:9f3ac1b0e7d2f4a6@files.example.test:8444/agent"

        await vm.validateAndSaveFileTransferConfig(urlString: hostile, for: openclaw)

        let fileServerURL = await SettingsManager.shared.getFileServerURL(for: openclaw)
        XCTAssertNil(fileServerURL,
                     "A userinfo URL must never reach App-Group defaults / iCloud KVS — that would put a plaintext password in a non-secret store.")
        XCTAssertNil(defaults.string(forKey: Constants.fileServerURLKey(for: openclaw)),
                     "Nothing may be written to the raw defaults slot either.")
        guard case .invalid(let message)? = vm.fileServerValidationStates[openclaw] else {
            return XCTFail("A userinfo URL must publish an .invalid validation state.")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("username"),
                      "The rejection must NAME the problem (username/password in the URL), not reuse the generic https:// hint — a silent strip or a wrong hint leaves the user debugging a 401.")
        XCTAssertNotEqual(vm.fileServerPersistedURLStrings[openclaw], hostile,
                          "The persisted-URL mirror must not adopt a rejected string.")
    }

    func testFileServerDraftSignatureRefusesUserinfo() async throws {
        let vm = await makeVM()
        vm.fileServerURLStrings[openclaw] = "https://conduck:secret@files.example.test:8444"
        XCTAssertNil(vm.fileTransferDraftSignature(for: openclaw),
                     "A draft the save path rejects must not be Testable either — otherwise a passing verdict is earned against a tuple the commit refuses.")

        vm.fileServerURLStrings[openclaw] = "https://files.example.test:8444"
        XCTAssertNotNil(vm.fileTransferDraftSignature(for: openclaw),
                        "A clean https URL must still produce a draft signature.")
    }

    // MARK: - 3. Clearing a key falls the active pointers back to Apple

    func testClearingActivePresetKeyFallsPointersBackToAppleOrSkipUnsigned() async throws {
        try await requireSTTKeychainOrSkip()

        let preset = cloudPresetID
        try await SettingsManager.shared.setAPIKey("synthetic-key", forPresetID: preset)
        addTeardownBlock {
            try? await SettingsManager.shared.clearAPIKey(forPresetID: preset)
        }
        await SettingsManager.shared.setActivePresetID(preset)
        await SettingsManager.shared.setActiveTTSProviderID(cloudTTSProviderID)

        let vm = await makeVM()
        try await vm.clearKey(for: preset)

        let activePresetID2 = await SettingsManager.shared.getActivePresetID()
        XCTAssertEqual(activePresetID2,
                       Constants.sttActivePresetIDDefault,
                       "Clearing the ACTIVE preset's key must fall the STT pointer back to apple-on-device — otherwise a paired Watch keeps uploading audio under the cleared key, which it holds in its own non-sync Keychain.")
        let activeTTSProviderID = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(activeTTSProviderID,
                       Constants.ttsActiveProviderIDDefault,
                       "The cloud TTS provider reads the SAME vendor slot, so its pointer must fall back too.")
        XCTAssertEqual(vm.activePresetID, Constants.sttActivePresetIDDefault,
                       "The VM mirror must follow the store.")
        XCTAssertEqual(vm.activeTTSProviderID, Constants.ttsActiveProviderIDDefault,
                       "The VM TTS mirror must follow the store.")

        // The positive Apple envelope is what re-routes the wrist to the relay.
        let envelope = await SettingsManager.shared.currentBroadcastEnvelope()
        XCTAssertEqual(envelope?.presetID, Constants.sttActivePresetIDDefault,
                       "The broadcast must carry an EXPLICIT apple-on-device presetID — the Watch must never have to infer keyless from an absent key.")
        XCTAssertNil(envelope?.apiKey, "The Apple envelope carries no STT key.")
    }

    func testClearingInactivePresetKeyLeavesActivePointerAloneOrSkipUnsigned() async throws {
        try await requireSTTKeychainOrSkip()

        let preset = cloudPresetID
        let otherPreset = "openai-gpt4o-transcribe"
        try await SettingsManager.shared.setAPIKey("synthetic-key", forPresetID: otherPreset)
        try await SettingsManager.shared.setAPIKey("synthetic-key", forPresetID: preset)
        addTeardownBlock {
            try? await SettingsManager.shared.clearAPIKey(forPresetID: preset)
            try? await SettingsManager.shared.clearAPIKey(forPresetID: otherPreset)
        }
        await SettingsManager.shared.setActivePresetID(preset)

        let vm = await makeVM()
        try await vm.clearKey(for: otherPreset)

        let activePresetID = await SettingsManager.shared.getActivePresetID()
        XCTAssertEqual(activePresetID, preset,
                       "Clearing an INACTIVE preset's key must not deactivate the user's chosen provider — the fallback is scoped to the pointer that actually depended on the cleared slot.")
    }

    // MARK: - 3b. The confirmation must be able to NAME the TTS fallback

    /// The two pointers move INDEPENDENTLY, and the Clear-key confirmation
    /// derives what it promises from `clearingKeyResetsTTSPointer` — the same
    /// predicate `clearKey(for:)` acts on. Pure truth table: a confirmation
    /// derived from a DIFFERENT rule than the action is a user consenting to
    /// something they were not told.
    func testTTSFallbackPredicateMatchesTheVendorKeySlot() {
        XCTAssertTrue(SettingsViewModel.clearingKeyResetsTTSPointer(
            activeTTSProviderID: cloudTTSProviderID, clearedPresetID: cloudPresetID),
                      "The cloud TTS provider reads the cleared vendor's shared key slot, so its pointer moves.")
        XCTAssertFalse(SettingsViewModel.clearingKeyResetsTTSPointer(
            activeTTSProviderID: cloudTTSProviderID, clearedPresetID: "openai-gpt4o-transcribe"),
                       "A DIFFERENT vendor's key slot must not be reported as a consequence.")
        XCTAssertFalse(SettingsViewModel.clearingKeyResetsTTSPointer(
            activeTTSProviderID: Constants.ttsActiveProviderIDDefault, clearedPresetID: cloudPresetID),
                       "Apple TTS reads no key slot (`sharedKeySTTPresetID == nil`) — nothing to fall back FROM.")
    }

    /// THE BRANCH THE COPY USED TO MISS: dictating through one vendor while
    /// LISTENING through another. The cleared vendor's row renders
    /// `.storedInactive` (it is not the active STT preset), so a confirmation
    /// keyed on the row state alone says only "will stop working" — while the
    /// clear silently switches the user's reply voice to Apple.
    func testInactiveSTTRowStillReportsAndPerformsTheTTSFallbackOrSkipUnsigned() async throws {
        try await requireSTTKeychainOrSkip()

        let voiceVendorPreset = cloudPresetID              // key cleared here
        let dictationPreset = "openai-gpt4o-transcribe"    // stays active for STT
        try await SettingsManager.shared.setAPIKey("synthetic-key", forPresetID: voiceVendorPreset)
        try await SettingsManager.shared.setAPIKey("synthetic-key", forPresetID: dictationPreset)
        addTeardownBlock {
            try? await SettingsManager.shared.clearAPIKey(forPresetID: voiceVendorPreset)
            try? await SettingsManager.shared.clearAPIKey(forPresetID: dictationPreset)
        }
        await SettingsManager.shared.setActivePresetID(dictationPreset)
        await SettingsManager.shared.setActiveTTSProviderID(cloudTTSProviderID)

        let vm = await makeVM()

        // The row the user is looking at is INACTIVE …
        guard case .storedInactive = vm.rowState(for: voiceVendorPreset) else {
            return XCTFail("Precondition: the vendor whose key is cleared must not be the active STT preset.")
        }
        // … and yet clearing it moves a pointer, which the confirmation reads
        // off this predicate.
        XCTAssertTrue(vm.clearingKeyResetsActiveTTS(for: voiceVendorPreset),
                      "An inactive STT row can still own the active VOICE — the confirmation must be told so it can name the switch.")
        XCTAssertFalse(vm.clearingKeyResetsActiveTTS(for: dictationPreset),
                       "The vendor doing the dictation owns no TTS pointer here.")

        try await vm.clearKey(for: voiceVendorPreset)

        let activeTTS = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(activeTTS, Constants.ttsActiveProviderIDDefault,
                       "The promise the confirmation makes must be the one the action keeps.")
        let activeSTT = await SettingsManager.shared.getActivePresetID()
        XCTAssertEqual(activeSTT, dictationPreset,
                       "The STT pointer had no dependency on the cleared slot and must not move.")
    }
}

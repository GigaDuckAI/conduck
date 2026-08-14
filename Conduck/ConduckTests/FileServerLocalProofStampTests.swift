// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileServerLocalProofStampTests.swift
//
// Locks the DEVICE-LOCAL PROOF that arms the silent, upgrade-only file-transfer
// probes — `fileServer.testedLocally.<suffix>` together with the identity stamp
// beside it, `fileServer.testedLocallyStamp.<suffix>`.
//
// The bare flag is keyed by gateway SLOT, so on its own it records that this
// device staged-tested this slot, not that it tested the server currently in it.
// A peer that repoints the slot syncs a new URL and credential in through the
// inbound KVS mirror, which grants no local proof — and, with nothing but the
// flag, revokes none either, so both probes could fire at a host this device has
// never opened a connection to. The folder probe WRITES (a nested PUT), which is
// how that reaches a stranger's server and raises an unexplained iOS
// Local-Network prompt. The stamp is what closes it.
//
// What is pinned here:
//   • A stamp taken against the tested lane is honoured, and it SURVIVES A
//     RELAUNCH — the property `identitySignature` cannot have, because its
//     `Hasher` seed is process-random.
//   • Three moves revoke the proof, each on its own: a repointed URL (delivered
//     the way a peer really delivers it, through `handleICloudChange`), a
//     rotated credential, and a changed or removed certificate pin.
//   • MISSING STAMP IS UNPROVEN. A flag with no stamp — the one-time migration
//     seed's, or one written by a build that predates the stamp — arms nothing
//     and is never back-filled on read.
//   • The stamp is device-local provenance: neither `handleICloudChange` nor
//     `performInitialSync` will mirror or hydrate one, and Forget clears it.
//   • It is a digest, never a readable secret: no credential, fingerprint or URL
//     appears in the stored value.
//
// Isolated in-memory `SettingsManager` per test — no shared singleton, no App
// Group, no KVS of the founder's. Synthetic URLs / credentials / fingerprints
// only, and nothing is ever logged.

import XCTest
@testable import Conduck

final class FileServerLocalProofStampTests: XCTestCase {

    private let ref = RemoteAgentRef.custom(UUID())

    private let url = URL(string: "https://files.example.test")!
    private let repointedURL = URL(string: "https://stranger.example.test")!
    private let credential = String(repeating: "a", count: 32)
    private let rotatedCredential = String(repeating: "b", count: 32)
    private let pin = String(repeating: "c", count: 64)
    private let rotatedPin = String(repeating: "d", count: 64)

    private func makeManager(
        defaults: InMemoryDefaultsStore = InMemoryDefaultsStore(),
        kvs: InMemoryUbiquitousStore = InMemoryUbiquitousStore(),
        secrets: InMemorySecretStore = InMemorySecretStore()
    ) -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: defaults,
            ubiquitous: kvs,
            secrets: secrets,
            cloudAvailable: true
        ))
    }

    /// Stage a configured lane and earn the proof the production way: the
    /// credential lands first, then ONE commit hop writes the tuple and records
    /// the pass against it. Nothing here reaches around the setters, so the
    /// stamp is whatever production would have written.
    private func earnProof(
        on manager: SettingsManager,
        url: URL,
        credential: String,
        pin: String? = nil
    ) async {
        try? await manager.setFileServerCredential(credential, for: ref)
        await manager.commitFileTransferConfig(
            url: url, pin: pin, folderCapable: nil, available: true, for: ref)
    }

    /// The lane as it stands now — what an arming site holds when it asks.
    private func readySnapshot(
        _ manager: SettingsManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SettingsManager.FileTransferSnapshot {
        let snapshot = await manager.fileTransferReadySnapshot(for: ref)
        return try XCTUnwrap(snapshot, "the lane must be configured and ready for a proof question to mean anything",
                             file: file, line: line)
    }

    private var stampKey: String { Constants.fileServerTestedLocallyStampKey(for: ref) }
    private var flagKey: String { Constants.fileServerTestedLocallyKey(for: ref) }
    private var urlKey: String { Constants.fileServerURLKey(for: ref) }
    private var availableKey: String { Constants.fileTransferAvailableKey(for: ref) }
    private var seededGuardKey: String { Constants.fileServerTestedLocallySeededKey }

    // MARK: - The key literals

    /// Pinned independently of `Constants` so a rename that would orphan real
    /// user provenance breaks a test instead of silently re-homing the key. The
    /// stamp's suffix deliberately does NOT sit under the flag's prefix
    /// (`testedLocallyStamp.` is not `testedLocally.`), which is why the
    /// gateway-owned purge list carries it as its own entry.
    func testStampKeyLiteralIsStableAndDistinctFromTheFlag() {
        let suffix = ref.storageKeySuffix
        let stamp = stampKey
        let flag = flagKey
        XCTAssertEqual(stamp, "fileServer.testedLocallyStamp." + suffix)
        XCTAssertEqual(flag, "fileServer.testedLocally." + suffix)
        XCTAssertFalse(stamp.hasPrefix("fileServer.testedLocally."),
                       "the trailing dot is what keeps the flag's prefix from swallowing the stamp — "
                       + "a purge or ban list must name the stamp itself")
        XCTAssertTrue(SettingsManager.gatewayOwnedKeyPrefixes.contains("fileServer.testedLocallyStamp."),
                      "a deleted custom gateway must not leave its proof stamp behind for a uuid nobody reissues")
    }

    // MARK: - The proof is honoured against the lane it was measured on

    func testAPassAgainstTheCurrentLaneIsProof() async throws {
        let manager = makeManager()
        await earnProof(on: manager, url: url, credential: credential, pin: pin)

        let snapshot = try await readySnapshot(manager)
        let proven = await manager.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertTrue(proven, "the device that just passed a staged test against this exact server holds the proof")
    }

    /// THE REASON THE STAMP EXISTS RATHER THAN `identitySignature`: it has to
    /// mean the same thing on the next launch. `identitySignature` is a `Hasher`
    /// output, seeded randomly per process, so a stored copy would compare
    /// unequal to itself after a relaunch and silently disarm every probe.
    func testProofSurvivesARelaunch() async throws {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        // The secret store is shared across both managers because the credential
        // is half of what makes a lane configured at all — a relaunch that forgot
        // the Keychain would model a device wipe, not a relaunch.
        let secrets = InMemorySecretStore()
        let first = makeManager(defaults: defaults, kvs: kvs, secrets: secrets)
        await earnProof(on: first, url: url, credential: credential, pin: pin)

        let relaunched = makeManager(defaults: defaults, kvs: kvs, secrets: secrets)
        let snapshot = try await readySnapshot(relaunched)
        let proven = await relaunched.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertTrue(proven, "a proof that evaporates at launch would disarm the silent upgrades forever")
    }

    // MARK: - Three moves revoke it

    /// THE GAP, driven the way it really arrives: a peer repoints the slot, the
    /// new URL syncs in through the inbound mirror, and that mirror deliberately
    /// grants no local proof. Without the stamp the OLD proof stood, and both
    /// probes would have fired at a server this device has never seen.
    func testARepointedURLRevokesTheProof() async throws {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)
        await earnProof(on: manager, url: url, credential: credential, pin: pin)

        // The peer's push, delivered exactly as `LiveKVSChangeSource` would.
        let key = urlKey
        kvs.set(repointedURL.absoluteString, forKey: key)
        await manager.handleICloudChange(KVSChange(reason: .serverChange, changedKeys: [key]))

        let snapshot = try await readySnapshot(manager)
        XCTAssertEqual(snapshot.baseURL, repointedURL, "the mirror must have landed the peer's URL — otherwise this proves nothing")

        let proven = await manager.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertFalse(proven, "no automated write may reach a host this device has never opened a connection to")

        // And the difference between the two reads, stated outright: the flag is
        // keyed by SLOT and survives the repoint untouched. A caller that reaches
        // for it instead re-opens the whole gap.
        let rawFlag = await manager.getFileServerTestedLocally(for: ref)
        XCTAssertTrue(rawFlag, "the slot-scoped flag is unchanged — which is precisely why it may not arm a probe")
    }

    /// A peer rotating the credential reaches this device silently, through
    /// iCloud Keychain, with no local revoke hop to notice it.
    func testARotatedCredentialRevokesTheProof() async throws {
        let manager = makeManager()
        await earnProof(on: manager, url: url, credential: credential, pin: pin)

        try? await manager.setFileServerCredential(rotatedCredential, for: ref)

        let snapshot = try await readySnapshot(manager)
        XCTAssertEqual(snapshot.credential, rotatedCredential)
        let proven = await manager.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertFalse(proven, "a password the tested server never accepted is a connection nobody proved")
    }

    /// The pin is device-local and `durableLaneID` excludes it, which is exactly
    /// why the stamp folds it back in: the pin is what the probe's transport
    /// rides on, so a device whose pin moved has not proven the connection it is
    /// about to make.
    func testAChangedCertificatePinRevokesTheProof() async throws {
        let manager = makeManager()
        await earnProof(on: manager, url: url, credential: credential, pin: pin)

        await manager.setFileServerCertFingerprint(rotatedPin, for: ref)

        let snapshot = try await readySnapshot(manager)
        let proven = await manager.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertFalse(proven, "a different pin is a different trust decision, so the old measurement no longer covers it")
    }

    /// Removing the pin moves the same way for the same reason — the lane drops
    /// back to plain system trust, which is not the connection that was tested.
    func testARemovedCertificatePinRevokesTheProof() async throws {
        let manager = makeManager()
        await earnProof(on: manager, url: url, credential: credential, pin: pin)

        await manager.setFileServerCertFingerprint(nil, for: ref)

        let snapshot = try await readySnapshot(manager)
        XCTAssertNil(snapshot.certFingerprintHex)
        let proven = await manager.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertFalse(proven, "loosening trust is a change of identity as much as tightening it")
    }

    // MARK: - Missing stamp is unproven, and never back-filled

    /// A build that predates the stamp leaves a bare flag behind. It arms
    /// nothing: the app is pre-launch, so the whole cost is one Test Connection,
    /// and that is the conservative outcome the arming rule exists to produce.
    func testAFlagWithNoStampIsNotProof() async throws {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        try? await manager.setFileServerCredential(credential, for: ref)
        await manager.setFileServerURL(url, for: ref)
        await manager.setFileTransferAvailable(true, for: ref)
        // Park the one-time seed, then write the legacy shape directly: the flag
        // alone, exactly as an older build stored it.
        defaults.set(true, forKey: seededGuardKey)
        defaults.set(true, forKey: flagKey)

        let snapshot = try await readySnapshot(manager)
        let proven = await manager.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertFalse(proven, "a proof that cannot name the server it measured is not a proof")
    }

    /// And the read leaves it that way. Back-filling on first read would stamp
    /// whichever server happens to occupy the slot at that moment — the exact
    /// unproven server the rule keeps probes away from — so asking twice must
    /// never turn a `false` into a `true`.
    func testAskingDoesNotBackFillTheStamp() async throws {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        try? await manager.setFileServerCredential(credential, for: ref)
        await manager.setFileServerURL(url, for: ref)
        await manager.setFileTransferAvailable(true, for: ref)
        defaults.set(true, forKey: seededGuardKey)
        defaults.set(true, forKey: flagKey)

        let snapshot = try await readySnapshot(manager)
        _ = await manager.isFileServerLocallyProven(snapshot, for: ref)

        XCTAssertNil(defaults.string(forKey: stampKey),
                     "the read is a question, not a grant")
        let second = await manager.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertFalse(second, "and the answer must not have changed by being asked")
    }

    /// The one-time migration seed reconstructs the FLAG from a pre-mirror local
    /// `available=true`. That is a real fact about the slot, and the pairing
    /// export reads it — but the boolean carries no server identity, so the seed
    /// can stamp nothing and a seeded ref arms no probe.
    func testTheMigrationSeedGrantsNoStamp() async throws {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        try? await manager.setFileServerCredential(credential, for: ref)
        // Pre-mirror state: URL + available, written before the flag existed.
        defaults.set(url.absoluteString, forKey: urlKey)
        defaults.set(true, forKey: availableKey)

        let seededFlag = await manager.getFileServerTestedLocally(for: ref)
        XCTAssertTrue(seededFlag, "the seed still recognises a pass that could only have happened here")

        let snapshot = try await readySnapshot(manager)
        let proven = await manager.isFileServerLocallyProven(snapshot, for: ref)
        XCTAssertFalse(proven, "…but it cannot say WHICH server, so it may not arm a silent probe")
        XCTAssertNil(defaults.string(forKey: stampKey),
                     "the seed must not invent a stamp for whatever lane happens to be configured now")
    }

    // MARK: - Device-local: never mirrored, never hydrated, dropped by Forget

    /// The inbound mirror scans an EXPLICIT prefix allowlist, never a blanket
    /// `fileServer.` — so even a push naming the stamp must not land. Mirroring
    /// one in would hand this device a peer's proof for a host it has opened no
    /// connection to, which is the arming the stamp exists to refuse.
    func testTheStampIsNeverMirroredInbound() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)

        let key = stampKey
        kvs.set(String(repeating: "0", count: 64), forKey: key)
        await manager.handleICloudChange(KVSChange(reason: .serverChange, changedKeys: [key]))

        XCTAssertNil(defaults.string(forKey: key),
                     "a peer's proof stamp must never become this device's")
    }

    /// The cold-launch hydration is the other half of the same allowlist, and a
    /// key banned from one list but not the other syncs on live changes yet is
    /// missing on a fresh install — so the fresh-device path is asserted
    /// separately rather than inferred from the mirror above.
    func testTheStampIsNeverHydratedOnAColdLaunch() async {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = makeManager(defaults: defaults, kvs: kvs)

        let key = stampKey
        kvs.set(String(repeating: "0", count: 64), forKey: key)
        await manager.performInitialSync()

        XCTAssertNil(defaults.string(forKey: key),
                     "a fresh install must start unproven — it has met no server yet")
    }

    /// "Forget file transfer" runs through `revokeFileTransferReadiness`, the
    /// single choke point every identity mutation calls. Both halves of the
    /// proof go, so a later re-add cannot inherit provenance that would mis-arm
    /// a probe before the new config is re-tested.
    func testForgetClearsBothHalvesOfTheProof() async throws {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        await earnProof(on: manager, url: url, credential: credential, pin: pin)
        XCTAssertNotNil(defaults.string(forKey: stampKey),
                        "the pass must have stamped something for the clear to be meaningful")

        await manager.revokeFileTransferReadiness(for: ref)

        XCTAssertNil(defaults.object(forKey: flagKey),
                     "Forget must forfeit the device-local flag")
        XCTAssertNil(defaults.string(forKey: stampKey),
                     "…and the stamp with it — half a proof must never outlive the pass it belonged to")
    }

    // MARK: - It is a digest, not a readable secret

    /// Privacy: the stamp is persisted in App-Group defaults, which is a place a
    /// credential and a certificate fingerprint may not appear. It is a SHA-256
    /// over both, so the stored value reveals neither.
    func testTheStampRevealsNothingItWasComputedFrom() async throws {
        let defaults = InMemoryDefaultsStore()
        let manager = makeManager(defaults: defaults)
        await earnProof(on: manager, url: url, credential: credential, pin: pin)

        let stored = try XCTUnwrap(defaults.string(forKey: stampKey))
        XCTAssertEqual(stored.count, 64, "SHA-256 as lowercase hex")
        XCTAssertTrue(stored.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertFalse(stored.contains(credential), "the credential is Keychain-only and stays there")
        XCTAssertFalse(stored.contains(pin), "the fingerprint has its own key; it may not be readable from this one")
        XCTAssertFalse(stored.contains(url.host() ?? "files.example.test"), "no URL in a stored provenance field")
    }

    /// Two lanes that differ in ANY of the three fields must stamp differently —
    /// otherwise a revoke would silently be a no-op. Asserted on the snapshot's
    /// computed property directly, so a change to the encoding that collapsed
    /// two lanes together fails here rather than in the field.
    func testTheStampSeparatesLanesOnAllThreeFields() {
        func snapshot(url: URL, credential: String, pin: String?) -> SettingsManager.FileTransferSnapshot {
            SettingsManager.FileTransferSnapshot(
                baseURL: url,
                username: Constants.fileServerUsername,
                credential: credential,
                certFingerprintHex: pin,
                available: true,
                folderCapable: true
            )
        }
        let base = snapshot(url: url, credential: credential, pin: pin)

        XCTAssertEqual(base.localProofStamp,
                       snapshot(url: url, credential: credential, pin: pin).localProofStamp,
                       "the same lane must stamp the same, or nothing could ever match")
        XCTAssertNotEqual(base.localProofStamp,
                          snapshot(url: repointedURL, credential: credential, pin: pin).localProofStamp)
        XCTAssertNotEqual(base.localProofStamp,
                          snapshot(url: url, credential: rotatedCredential, pin: pin).localProofStamp)
        XCTAssertNotEqual(base.localProofStamp,
                          snapshot(url: url, credential: credential, pin: rotatedPin).localProofStamp)
        XCTAssertNotEqual(base.localProofStamp,
                          snapshot(url: url, credential: credential, pin: nil).localProofStamp)

        // The verdict fields are excluded on the same terms `identitySignature`
        // excludes them: they are measured ABOUT this identity, so folding one in
        // would make a lane change identity the moment a probe told us something
        // — and revoke the very proof that authorised the probe.
        let narrowed = SettingsManager.FileTransferSnapshot(
            baseURL: url,
            username: Constants.fileServerUsername,
            credential: credential,
            certFingerprintHex: pin,
            available: true,
            folderCapable: false,
            returnCapable: false)
        XCTAssertEqual(base.localProofStamp, narrowed.localProofStamp,
                       "a capability verdict is not part of the server's identity")
    }
}

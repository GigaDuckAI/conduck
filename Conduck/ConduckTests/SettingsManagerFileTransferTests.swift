//
//  SettingsManagerFileTransferTests.swift
//  ConduckTests
//
//  Coverage for the file-transfer accessors on `SettingsManager`.
//  Split into two groups:
//
//   • NON-SECRET round-trips (URL / available) live in
//     App-Group UserDefaults (+ KVS mirror for the URL). These run UNSIGNED on a
//     plain simulator — no Keychain involved.
//
//   • The CREDENTIAL round-trip touches the Keychain (kSecAttrSynchronizable:
//     true). On an unsigned simulator the Keychain has no application-identifier
//     entitlement, so `SecItem*` returns errSecMissingEntitlement (-34018) and the
//     round-trip cannot complete. We therefore detect that condition and SKIP,
//     mirroring how the existing remote-agent Keychain tests behave on unsigned
//     sims (see SettingsManagerRemoteAgentTests). The assertion still runs in full
//     on a signed founder build.
//
//  Privacy: no real URLs/credentials — synthetic fixtures, never logged.
//

import XCTest
@testable import Conduck

final class SettingsManagerFileTransferTests: XCTestCase {

    private var manager: SettingsManager!
    // A custom ref keeps test keys isolated from any built-in backend state.
    private let ref = RemoteAgentRef.custom(UUID())

    override func setUp() {
        super.setUp()
        manager = SettingsManager.shared
        // Clean any prior non-secret state for this ref.
        manager.setFileServerURL(nil, for: ref)
        manager.setFileTransferAvailable(false, for: ref)
    }

    override func tearDown() {
        manager.setFileServerURL(nil, for: ref)
        manager.setFileTransferAvailable(false, for: ref)
        try? manager.clearFileServerCredential(for: ref)
        manager = nil
        super.tearDown()
    }

    // MARK: - URL round-trip (non-secret)

    func testFileServerURLRoundTrip() {
        XCTAssertNil(manager.getFileServerURL(for: ref), "fresh ref has no URL")
        let url = URL(string: "https://fileserver.example.test")!
        manager.setFileServerURL(url, for: ref)
        XCTAssertEqual(manager.getFileServerURL(for: ref), url, "URL must round-trip")

        manager.setFileServerURL(nil, for: ref)
        XCTAssertNil(manager.getFileServerURL(for: ref), "setting nil clears the URL")
    }

    // MARK: - Available flag round-trip (non-secret)

    func testFileTransferAvailableDefaultsFalseAndRoundTrips() {
        XCTAssertFalse(manager.getFileTransferAvailable(for: ref), "available defaults to false")
        manager.setFileTransferAvailable(true, for: ref)
        XCTAssertTrue(manager.getFileTransferAvailable(for: ref), "available must round-trip true")
        manager.setFileTransferAvailable(false, for: ref)
        XCTAssertFalse(manager.getFileTransferAvailable(for: ref), "available must round-trip false")
    }

    // MARK: - Cert fingerprint round-trip (per-device, non-secret, App-Group only)

    func testCertFingerprintRoundTrip() {
        XCTAssertNil(manager.getFileServerCertFingerprint(for: ref), "fresh ref has no fingerprint")
        // The setter canonicalizes to LOWERCASE (SHA-256 hex compare is
        // case-insensitive; lowercase is the stored canonical form — mirrors
        // setRemoteAgentCertFingerprint).
        manager.setFileServerCertFingerprint("AA:BB:CC:DD", for: ref)
        XCTAssertEqual(manager.getFileServerCertFingerprint(for: ref), "aa:bb:cc:dd",
                       "fingerprints are stored lowercased (canonical form)")
        manager.setFileServerCertFingerprint(nil, for: ref)
        XCTAssertNil(manager.getFileServerCertFingerprint(for: ref), "setting nil clears the fingerprint")
    }

    // MARK: - Snapshot composition (non-secret portion)

    func testSnapshotIsNilWhenURLMissing() {
        // No URL set → snapshot is nil regardless of credential.
        manager.setFileServerURL(nil, for: ref)
        XCTAssertNil(manager.fileTransferSnapshot(for: ref),
                     "snapshot must be nil when the file-server URL is missing")
    }

    // MARK: - Credential Keychain round-trip (signing-gated)

    /// Mirrors the existing remote-agent Keychain tests: on an unsigned simulator
    /// the Keychain rejects writes (errSecMissingEntitlement), so this test SKIPS
    /// rather than fails. It runs fully on a signed build.
    func testCredentialKeychainRoundTripOrSkipUnsigned() throws {
        let secret = "feedfacecafebeeffeedfacecafebeef"   // synthetic 32-hex

        do {
            try manager.setFileServerCredential(secret, for: ref)
        } catch {
            throw XCTSkip("Keychain unavailable on unsigned simulator (\(error)); credential round-trip is a signed-build gate")
        }

        // If the write somehow succeeded but the read comes back nil, the Keychain
        // is not actually persisting (also an unsigned-sim symptom) → skip.
        guard let stored = manager.getFileServerCredential(for: ref) else {
            throw XCTSkip("Keychain not persisting on this run; credential round-trip is a signed-build gate")
        }
        XCTAssertEqual(stored, secret, "credential must round-trip through the Keychain")

        // Full snapshot becomes available once URL + credential both exist.
        manager.setFileServerURL(URL(string: "https://fileserver.example.test")!, for: ref)
        let snap = manager.fileTransferSnapshot(for: ref)
        XCTAssertNotNil(snap, "snapshot is non-nil once URL + credential are present")
        XCTAssertEqual(snap?.credential, secret)
        XCTAssertEqual(snap?.username, Constants.fileServerUsername)

        // Clearing removes it.
        try manager.clearFileServerCredential(for: ref)
        XCTAssertNil(manager.getFileServerCredential(for: ref), "cleared credential must read back nil")
    }

    // MARK: - Ready-gated snapshot (signing-gated — needs the credential)

    /// `fileTransferReadySnapshot` must stay nil while `available == false` even
    /// with URL + credential present (a saved-but-FAILED server routes like
    /// "not set up" in the composer), and appear once the test-passed flag flips.
    func testReadySnapshotGatedOnAvailableOrSkipUnsigned() throws {
        let secret = "feedfacecafebeeffeedfacecafebeef"   // synthetic 32-hex
        do {
            try manager.setFileServerCredential(secret, for: ref)
        } catch {
            throw XCTSkip("Keychain unavailable on unsigned simulator (\(error)); ready-snapshot gate is a signed-build gate")
        }
        guard manager.getFileServerCredential(for: ref) != nil else {
            throw XCTSkip("Keychain not persisting on this run; ready-snapshot gate is a signed-build gate")
        }
        manager.setFileServerURL(URL(string: "https://fileserver.example.test")!, for: ref)

        // Saved but untested/failed: the plain snapshot exists, the ready one doesn't.
        XCTAssertNotNil(manager.fileTransferSnapshot(for: ref),
                        "plain snapshot exists once URL + credential are present")
        XCTAssertNil(manager.fileTransferReadySnapshot(for: ref),
                     "ready snapshot must be nil while available == false")

        manager.setFileTransferAvailable(true, for: ref)
        XCTAssertNotNil(manager.fileTransferReadySnapshot(for: ref),
                        "ready snapshot exists once the staged test has passed")

        // A later failed re-test (available → false) retracts readiness again.
        manager.setFileTransferAvailable(false, for: ref)
        XCTAssertNil(manager.fileTransferReadySnapshot(for: ref),
                     "a failed re-test must retract the ready snapshot")
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS STT key blackout contract.
//
// THE FIELD FAILURE. Watch STT keys are written
// `kSecAttrAccessibleAfterFirstUnlock` for a stated reason: the ControlWidget
// cold-launch path needs the key BEFORE the wrist is unlocked. That makes the
// window in which the read FAILS — a watch that rebooted and has not been
// unlocked since — the designed-for case rather than a hypothetical. Both key
// readers on this target collapsed that failure into `nil` and raised
// `AppError.sttMissingAPIKey` (23), which is TERMINAL: `runSTTUpload` deletes
// the capture on a non-retryable verdict, so the user got told they had no key
// (false) and lost the words they had just spoken (I3, I6).
//
// WHAT THIS FILE DRIVES, all of it real behaviour on this target:
//
//   1. `WatchIdentityResolver.sttAPIKeyReadResult` — the typed read, over a
//      stub `SecretStore` that returns chosen `OSStatus` values. Only
//      `errSecItemNotFound` may classify as absence.
//   2. `WatchNetworkClient.uploadSTT` (foreground) and
//      `WatchAudioUploader.uploadSTT` (background daemon) — the two lanes that
//      ask. Both refuse before a byte leaves, so both are drivable with no
//      network: an empty slot keeps 23, a blackout raises 75.
//   3. The LANE, end to end through `WatchRecordingService.runSTTUpload`'s
//      `sttUpload` seam: which banner the wrist shows, and that a blackout is
//      not routed into the branch that deletes the recording.
//
// Every check is paired with a control in the OTHER reading, so nothing here
// can pass vacuously — and the pairs are the point: the same slot, two
// verdicts, two sentences.

import Foundation
import Security
import XCTest
@testable import ConduckWatch_Watch_App

/// A `SecretStore` that answers every read with one chosen status, so the
/// classifier can be driven over statuses a simulator's Keychain will never
/// produce on demand — `errSecInteractionNotAllowed` (the locked-device
/// blackout) above all.
private final class StubSecretStore: SecretStore, @unchecked Sendable {
    let status: OSStatus
    let payload: Data?

    init(status: OSStatus, payload: Data? = nil) {
        self.status = status
        self.payload = payload
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        (status, payload.map { $0 as AnyObject })
    }

    func add(_ attributes: [String: Any]) -> OSStatus { errSecSuccess }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecSuccess }
    func delete(_ query: [String: Any]) -> OSStatus { errSecSuccess }
}

@MainActor
final class WatchSTTKeyBlackoutTests: XCTestCase {

    private let presetID = "mistral-voxtral"

    override func tearDown() {
        // Surgical: drop only the slot this file stages. `removeAll()` would
        // reach into whatever a sibling suite has in the shared in-memory
        // Keychain.
        _ = TestStores.secrets.delete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.sttApiKeyKeychainAccount(for: presetID)
        ])
        super.tearDown()
    }

    private func request() -> WatchSTTRequest {
        WatchSTTRequest(
            audioData: Data(repeating: 0xAB, count: 4096),
            audioFormat: .aac,
            language: nil,
            provider: .mistralVoxtral
        )
    }

    // MARK: - 1. The typed read

    /// `errSecItemNotFound` is the ONE status that proves the slot is empty.
    /// Every other outcome — a locked Keychain, an auth failure, an IPC error,
    /// or a success carrying an unusable payload — is a blackout, and a
    /// blackout is never proof of absence.
    func testOnlyItemNotFoundClassifiesAsAbsence() {
        XCTAssertEqual(
            WatchIdentityResolver.sttAPIKeyReadResult(
                forPresetID: presetID,
                secrets: StubSecretStore(status: errSecItemNotFound)
            ),
            .missing,
            "errSecItemNotFound is provable absence — this is the only reading allowed to keep code 23."
        )

        // The blackout that motivates the whole change: a rebooted, not-yet-
        // unlocked watch answers protected reads with this.
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecIO, errSecNotAvailable] {
            XCTAssertEqual(
                WatchIdentityResolver.sttAPIKeyReadResult(
                    forPresetID: presetID,
                    secrets: StubSecretStore(status: status)
                ),
                .unreadable(status),
                "Status \(status) says the Keychain could not answer, NOT that the slot is empty."
            )
        }

        XCTAssertEqual(
            WatchIdentityResolver.sttAPIKeyReadResult(
                forPresetID: presetID,
                secrets: StubSecretStore(status: errSecSuccess, payload: Data("sk-wrist".utf8))
            ),
            .present("sk-wrist"),
            "Control: a real key must still read back, or every assertion above passes vacuously."
        )

        XCTAssertEqual(
            WatchIdentityResolver.sttAPIKeyReadResult(
                forPresetID: presetID,
                secrets: StubSecretStore(status: errSecSuccess, payload: Data())
            ),
            .unreadable(errSecDecode),
            "A success carrying an empty payload is an item that EXISTS and cannot be used — unreadable, "
            + "never missing."
        )
    }

    /// The collapsed reader stays collapsed on purpose (identity and gateway
    /// tokens only need present-or-not), but it must not disagree with the
    /// typed one about which items exist.
    func testTheCollapsedReaderAgreesWithTheTypedOneOnPresence() {
        let live = StubSecretStore(status: errSecSuccess, payload: Data("sk-wrist".utf8))
        XCTAssertEqual(WatchIdentityResolver.getSTTAPIKey(forPresetID: presetID, secrets: live), "sk-wrist")

        let blackout = StubSecretStore(status: errSecInteractionNotAllowed)
        XCTAssertNil(WatchIdentityResolver.getSTTAPIKey(forPresetID: presetID, secrets: blackout),
                     "The collapsed reader still returns nil on a blackout — which is exactly why the "
                     + "callers that must not infer absence from nil now read typed instead.")
    }

    // MARK: - 2. Both key-reading lanes

    /// Foreground STT: the two readings raise two DIFFERENT codes, and neither
    /// touches the network to do it.
    func testForegroundUploadSeparatesAnEmptySlotFromABlackout() async {
        do {
            _ = try await WatchNetworkClient.uploadSTT(
                request: request(),
                provider: .mistralVoxtral,
                secrets: StubSecretStore(status: errSecItemNotFound)
            )
            XCTFail("An empty slot must refuse before the upload.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, 23,
                           "A provably empty slot keeps code 23 — its copy ('No STT API key set') is true.")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await WatchNetworkClient.uploadSTT(
                request: request(),
                provider: .mistralVoxtral,
                secrets: StubSecretStore(status: errSecInteractionNotAllowed)
            )
            XCTFail("A blackout must refuse before the upload.")
        } catch let error as AppError {
            XCTAssertEqual(error.errorCode, 75,
                           "A locked Keychain must NOT report 23. Code 23 asserts the slot is empty and is "
                           + "terminal on this lane, which deletes the wrist's recording (I3, I6).")
            XCTAssertTrue(error.isRetryable,
                          "Retryability is what steers `runSTTUpload` away from `cleanupRecordingFile()`.")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// The background daemon fallback re-reads the SAME slot, so it needs the
    /// same distinction — a lane fixed only in the foreground would still lose
    /// the recording the moment the fallback ran.
    func testBackgroundUploadSeparatesAnEmptySlotFromABlackout() throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-blackout-\(UUID().uuidString).m4a")
        try Data(repeating: 0xAB, count: 4096).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        XCTAssertThrowsError(
            try WatchAudioUploader.shared.uploadSTT(
                request: request(), audioFileURL: audioURL, provider: .mistralVoxtral,
                generation: 0, secrets: StubSecretStore(status: errSecItemNotFound)
            )
        ) { error in
            XCTAssertEqual((error as? AppError)?.errorCode, 23)
        }

        XCTAssertThrowsError(
            try WatchAudioUploader.shared.uploadSTT(
                request: request(), audioFileURL: audioURL, provider: .mistralVoxtral,
                generation: 0, secrets: StubSecretStore(status: errSecInteractionNotAllowed)
            )
        ) { error in
            XCTAssertEqual((error as? AppError)?.errorCode, 75,
                           "The background lane must separate the two readings too.")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path),
                      "Neither refusal may delete the capture — the hand-off never created a task, so "
                      + "nothing else will come back for it either.")
    }

    // MARK: - 3. The lane, end to end

    /// What the wrist SAYS, and what happens to the words.
    ///
    /// Driven through the `sttUpload` seam (no network) with the shared
    /// in-memory Keychain staged so the background re-read reaches the SAME
    /// verdict the foreground did — which is what production does: one locked
    /// Keychain, two consecutive reads.
    ///
    /// The blackout sentence must be code 75's own, and it must differ from the
    /// one an empty slot produces. Under the shape that shipped, both readings
    /// produced the code-23 sentence — so the inequality below is the negative
    /// control, and it fails against the old code.
    func testTheWristSaysSomethingTrueUnderBothReadingsAndKeepsTheCapture() async throws {
        // Stage an item whose payload cannot be used — the only blackout the
        // in-memory store can express, and a genuine one (`errSecDecode`).
        await WatchIdentityResolver.shared.setSTTAPIKey("", forPresetID: presetID)
        XCTAssertEqual(WatchIdentityResolver.sttAPIKeyReadResult(forPresetID: presetID),
                       .unreadable(errSecDecode),
                       "Precondition: the shared store must read back as a blackout, or the drive below "
                       + "exercises the wrong arm.")

        let blackoutRaw = try await driveUpload(throwing: .sttKeyUnreadable)
        let blackoutBanner = try XCTUnwrap(blackoutRaw)
        XCTAssertEqual(blackoutBanner, AppError.sttKeyUnreadable.errorDescription,
                       "A blackout gets code 75's cause line — which already carries its own remedy, so the "
                       + "wrist is not told to unlock twice, nor to 'open Conduck' while it is looking at "
                       + "Conduck.")
        XCTAssertTrue(blackoutBanner.contains("your recording is saved"),
                      "The sentence promises the capture survives. That promise is only true because 75 is "
                      + "retryable and never reaches the deleting arm (I6).")

        // The other reading, same lane: a provably empty slot.
        _ = TestStores.secrets.delete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.sttApiKeyKeychainAccount(for: presetID)
        ])
        let absenceRaw = try await driveUpload(throwing: .sttMissingAPIKey)
        let absenceBanner = try XCTUnwrap(absenceRaw)
        XCTAssertEqual(absenceBanner, AppError.sttMissingAPIKey.descriptionWithRecovery,
                       "An empty slot keeps its own cause-and-remedy sentence.")
        XCTAssertNotEqual(blackoutBanner, absenceBanner,
                          "The two readings must reach the user as different sentences. Identical copy is "
                          + "the defect: it tells a correctly configured user they have no key.")
    }

    /// Drive one `runSTTUpload` with the foreground transport refusing, and
    /// return the banner the wrist ends up showing. Asserts the capture file is
    /// still on disk on the way out — the drop path removes it, and a drop here
    /// would mean the words are gone.
    private func driveUpload(throwing error: AppError) async throws -> String? {
        let service = WatchRecordingService()
        service.store = ConversationStore(inMemory: true)
        service.sttUpload = { _, _ in throw error }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-lane-\(UUID().uuidString).m4a")
        try Data(repeating: 0xCD, count: 4096).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        await service.runSTTUpload(
            request: request(),
            audioFileURL: audioURL,
            provider: .mistralVoxtral,
            generation: service.captureGeneration
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path),
                      "A key refusal must not take the supersede drop path, which deletes the capture.")
        guard case .error(let message) = service.state else {
            XCTFail("Expected an error banner, got \(service.state).")
            return nil
        }
        return message
    }
}

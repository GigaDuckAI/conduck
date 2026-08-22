// SPDX-License-Identifier: Apache-2.0

// Conduck
// PinOnPlainHTTPFenceTests.swift
//
// A certificate pin on a plain-`http` endpoint is MEANINGLESS: no TLS handshake
// happens, so no challenge ever reaches `RemoteAgentTrustEvaluator` and the
// saved fingerprint is compared against nothing. The combination must fail
// CLOSED and be NAMED.
//
// Honouring the address and quietly dropping the pin is the one forbidden
// outcome — it leaves the user believing a protection is in force that is not,
// and it is the exact inverse of the app's standing doctrine that a pin can only
// tighten and never be waived. The pair is refused on WRITE and on READ, in all
// three lanes that persist an endpoint URL — the gateway, the agent file server
// and the BYO custom voice endpoint — and the storage-side fences are pinned
// here. A lane that grows a pin field and skips this is the whole defect.
//
// Isolated in-memory `SettingsManager` per test — no shared singleton, no App
// Group, no KVS of the founder's.

import XCTest
@testable import Conduck

final class PinOnPlainHTTPFenceTests: XCTestCase {

    private let ref = RemoteAgentRef.custom(UUID())
    private let pin = String(repeating: "ab", count: 32)

    private func makeManager() -> SettingsManager {
        SettingsManager(dependencies: .inMemory(
            defaults: InMemoryDefaultsStore(),
            ubiquitous: InMemoryUbiquitousStore(),
            secrets: InMemorySecretStore(),
            cloudAvailable: true
        ))
    }

    // MARK: - The file lane's tuple writer

    /// `commitFileTransferConfig` is the ONE storage-side writer that commits URL
    /// and pin together, so it is the one place a write-side pin fence belongs.
    /// Refusing before ANY write is what keeps the old tuple intact rather than
    /// leaving half a change committed.
    func testCommitFileTransferConfigRefusesAPinOnAPlainHTTPURL() async {
        let manager = makeManager()
        await manager.commitFileTransferConfig(
            url: URL(string: "http://192.168.1.10:8444")!,
            pin: pin,
            folderCapable: nil,
            available: true,
            for: ref
        )
        let storedURL = await manager.getFileServerURL(for: ref)
        let storedPin = await manager.getFileServerCertFingerprint(for: ref)
        XCTAssertNil(storedURL, "Neither half of the tuple may land — not the URL, not the pin.")
        XCTAssertNil(storedPin)
    }

    /// The fence is about the PAIR. The same local plain-http address with NO pin
    /// is a perfectly good configuration and must commit — otherwise the carve-out
    /// this whole change exists for would be unreachable on the file lane.
    func testCommitFileTransferConfigAcceptsAPlainHTTPURLWithNoPin() async {
        let manager = makeManager()
        await manager.commitFileTransferConfig(
            url: URL(string: "http://192.168.1.10:8444")!,
            pin: nil,
            folderCapable: nil,
            available: true,
            for: ref
        )
        let storedURL = await manager.getFileServerURL(for: ref)
        XCTAssertEqual(storedURL?.absoluteString, "http://192.168.1.10:8444")
    }

    // MARK: - The read fence (the backstop)

    /// The pair this build cannot create, but a version-skewed peer can sync in
    /// through KVS. Written through the two SEPARATE setters — which is exactly
    /// how a peer's write arrives, and why there is no per-setter fence: a guard
    /// in either one refuses half a change and commits the other.
    func testFileTransferSnapshotDropsAPinnedPlainHTTPLane() async throws {
        let manager = makeManager()
        await manager.setFileServerURL(URL(string: "http://192.168.1.10:8444")!, for: ref)
        try await manager.setFileServerCredential("cred-test-000", for: ref)
        let unpinned = await manager.fileTransferSnapshot(for: ref)
        XCTAssertNotNil(unpinned, "Precondition: URL + credential with no pin resolves.")

        await manager.setFileServerCertFingerprint(pin, for: ref)
        let pinned = await manager.fileTransferSnapshot(for: ref)
        XCTAssertNil(pinned,
                     "A pin that can never be compared must route to the not-configured path, exactly as an inadmissible URL already does.")
    }

    /// And the same fingerprint over https resolves normally — the fence is the
    /// combination, never the pin on its own.
    func testFileTransferSnapshotKeepsAPinnedHTTPSLane() async throws {
        let manager = makeManager()
        await manager.setFileServerURL(URL(string: "https://files.example.test:8444")!, for: ref)
        try await manager.setFileServerCredential("cred-test-000", for: ref)
        await manager.setFileServerCertFingerprint(pin, for: ref)
        let snapshot = await manager.fileTransferSnapshot(for: ref)
        XCTAssertEqual(snapshot?.certFingerprintHex, pin)
    }

    // MARK: - The BYO custom voice lane (STT + TTS share one URL, key and pin)

    /// The third lane, and the one most easily forgotten: its editor exposes an
    /// Advanced ▸ fingerprint field and its URL field now accepts plain http, so
    /// the pair is typeable here exactly as it is on the gateway. Both directions
    /// of the lane resolve through one base URL and one pin, so one fence at the
    /// config builders covers transcription and synthesis together.
    func testCustomVoiceConfigsDropAPinnedPlainHTTPEndpoint() async {
        let manager = makeManager()
        let uuid = UUID()
        await manager.setCustomSTTURL(URL(string: "http://192.168.1.10:11434")!, for: uuid)

        let unpinnedSTT = await manager.customSTTConfig(for: uuid)
        XCTAssertNotNil(unpinnedSTT.url, "Precondition: a plain-http LAN endpoint with no pin is a good configuration.")

        await manager.setCustomSTTCertFingerprint(pin, for: uuid)
        let pinnedSTT = await manager.customSTTConfig(for: uuid)
        let pinnedTTS = await manager.customTTSConfig(for: uuid)
        XCTAssertNil(pinnedSTT.url,
                     "A pin that can never be compared must route to the not-configured path, never be silently ignored.")
        XCTAssertNil(pinnedSTT.certFingerprint, "The TUPLE is refused — the pin does not survive alone either.")
        XCTAssertNil(pinnedTTS.url, "The TTS direction shares the base URL and the pin, so it takes the same verdict.")
        XCTAssertNil(pinnedTTS.certFingerprint)
    }

    /// The same fingerprint over https resolves normally on both directions —
    /// the fence is the combination, never the pin.
    func testCustomVoiceConfigsKeepAPinnedHTTPSEndpoint() async {
        let manager = makeManager()
        let uuid = UUID()
        await manager.setCustomSTTURL(URL(string: "https://voice.example.test")!, for: uuid)
        await manager.setCustomSTTCertFingerprint(pin, for: uuid)
        let stt = await manager.customSTTConfig(for: uuid)
        let tts = await manager.customTTSConfig(for: uuid)
        XCTAssertEqual(stt.certFingerprint, pin)
        XCTAssertNotNil(stt.url)
        XCTAssertEqual(tts.certFingerprint, pin)
        XCTAssertNotNil(tts.url)
    }

    /// And an unpinned plain-http voice endpoint keeps working, which is the
    /// whole point of the carve-out — Ollama on the LAN is the load-bearing case.
    func testCustomVoiceConfigsAcceptAnUnpinnedPlainHTTPEndpoint() async {
        let manager = makeManager()
        let uuid = UUID()
        await manager.setCustomSTTURL(URL(string: "http://192.168.1.10:11434")!, for: uuid)
        let stt = await manager.customSTTConfig(for: uuid)
        let tts = await manager.customTTSConfig(for: uuid)
        XCTAssertEqual(stt.url?.absoluteString, "http://192.168.1.10:11434/v1/audio/transcriptions")
        XCTAssertEqual(tts.url?.absoluteString, "http://192.168.1.10:11434/v1/audio/speech")
        XCTAssertNil(stt.certFingerprint)
    }
}

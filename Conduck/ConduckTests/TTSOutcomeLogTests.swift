// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSOutcomeLogTests.swift
//
// The device-local TTS outcome ring (`TTSOutcomeLog`): capacity pruning,
// corrupt-blob resilience, and the opaque config signature's stability rules.
// Every case drives a THROWAWAY UserDefaults suite, never the real App Group
// ring, and the signature checks are pure (no Keychain, no actor).

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class TTSOutcomeLogTests: XCTestCase {

    // MARK: - Capacity pruning (oldest dropped)

    /// Recording past capacity keeps only the most-recent `capacity` events, the
    /// oldest silently dropped — the ring must never grow into a usage journal.
    func testRecordingPastCapacityDropsOldestEvents() {
        let log = makeThrowawayOutcomeLog(capacity: 16)
        for i in 0..<20 {
            log.record(surface: .chat, stage: .fetch, outcome: .failedLoud,
                       errorCode: i, keyState: .present, configSignature: "sig")
        }
        let events = log.events()
        XCTAssertEqual(events.count, 16, "The ring is pruned to its capacity of 16.")
        XCTAssertEqual(events.map(\.errorCode), Array(4..<20),
                       "The oldest 4 events (0…3) are dropped; 4…19 survive in order.")
    }

    // MARK: - Corrupt-blob resilience

    /// A garbage blob under the ring key decodes to NOTHING (never a crash), and
    /// the next `record` silently supersedes it with a clean single-event ring.
    func testCorruptBlobDecodesToEmptyThenIsSuperseded() {
        let suite = InMemoryDefaultsStore()
        suite.set(Data("this is not valid json".utf8), forKey: TTSOutcomeLog.defaultsKey)
        let log = TTSOutcomeLog(defaults: suite)

        XCTAssertEqual(log.events(), [], "A corrupt/undecodable blob yields an empty event list.")

        log.record(surface: .chat, stage: .apple, outcome: .gaveUp,
                   keyState: .notRequired, configSignature: "sig")
        XCTAssertEqual(log.events().count, 1, "The next record supersedes the corrupt blob.")
    }

    // MARK: - Config signature stability

    /// The signature deliberately EXCLUDES the custom-endpoint URL (a truncated
    /// unsalted digest over a low-entropy URL would be dictionary-testable): two
    /// snapshots differing ONLY in their custom-config URL must share a signature.
    func testConfigSignatureIgnoresCustomEndpointURL() {
        let cfgA = CustomTTSConfig(url: URL(string: "https://alpha.example/v1")!,
                                   model: "kokoro-82m", auth: .none, certFingerprint: nil)
        let cfgB = CustomTTSConfig(url: URL(string: "https://beta.different.example/v1")!,
                                   model: "kokoro-82m", auth: .none, certFingerprint: nil)
        let snapA = snapshot(customConfig: cfgA)
        let snapB = snapshot(customConfig: cfgB)

        XCTAssertEqual(TTSOutcomeLog.configSignature(for: snapA),
                       TTSOutcomeLog.configSignature(for: snapB),
                       "Only the endpoint URL differs → the signature must be identical (URL excluded).")
    }

    /// A different voice IS a different synthesis request, so it must yield a
    /// different signature (the "same config or different?" question the ring
    /// exists to answer).
    func testConfigSignatureChangesWithVoice() {
        let cfg = CustomTTSConfig(url: URL(string: "https://alpha.example/v1")!,
                                  model: "kokoro-82m", auth: .none, certFingerprint: nil)
        let nova = snapshot(voice: "nova", customConfig: cfg)
        let shimmer = snapshot(voice: "shimmer", customConfig: cfg)

        XCTAssertNotEqual(TTSOutcomeLog.configSignature(for: nova),
                          TTSOutcomeLog.configSignature(for: shimmer),
                          "A different voice must change the config signature.")
    }

    // MARK: - Helper

    private func snapshot(voice: String? = "nova", customConfig: CustomTTSConfig?) -> TTSSnapshot {
        TTSSnapshot(
            providerID: "custom-openai-tts_endpoint",
            apiKey: nil,
            keyState: .notRequired,
            voice: voice,
            customModel: nil,
            customConfig: customConfig
        )
    }
}
#endif

// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract tests.
//
// These lock logic that lives ONLY in the watchOS target and is therefore
// invisible to ConduckTests (whose TEST_HOST is the iOS/macOS app). They run on
// the watch simulator via the ConduckWatchTests target.
//
// 1. WatchSessionManager.applyEnvelopePayload — the iPhone→Watch settings APPLY
//    contract (Gemini-flagged blind spot: the phone ASSEMBLES the broadcast
//    envelope, tested on iOS; the wrist APPLIES it, untested until now). A new
//    setting the phone adds to the envelope must hydrate here, and the
//    monotonic-timestamp high-water-mark must discard stale/out-of-order
//    deliveries (the queue-drain-at-wake replay hazard).
// 2. AppleRelayPendingQueue.Entry — the ADDITIVE-Codable persistence contract: a
//    legacy on-disk blob (predating providerID / conversationID / requestID /
//    lastAttemptAt) must still decode (nil new fields), or every queued relay
//    survives an app update only to fail to decode and silently vanish.
//
// Envelopes carry apiKey == nil so the apply path skips the Keychain write
// (signing-gated) and commits the non-secret state directly — see
// WatchSessionManager.applyEnvelopePayload's keyless branch.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchSettingsApplyAndQueueTests: XCTestCase {

    // MARK: - iPhone→Watch settings APPLY contract (+ monotonic stale guard)

    func testSTTEnvelopeApplyHydratesNonSecretFieldsAndAdvancesHighWaterMark() async {
        let reader = WatchSettingsReader.shared
        // Strictly newer than any high-water-mark a prior test left (the reader is
        // a process singleton), so this envelope always applies.
        let ts = reader.lastEnvelopeTimestamp + 1000

        let envelope = STTBroadcastEnvelope(
            presetID: "openai-gpt4o-transcribe",
            apiKey: nil,                      // keyless path — no Keychain write
            customModel: "whisper-large-v3",
            ttsProviderID: "openai-tts",
            ttsApiKey: nil,
            ttsVoice: "alloy",
            ttsCustomModel: nil,
            timestamp: ts
        )
        await WatchSessionManager.shared.applyEnvelopePayload(
            [Constants.sttActivePresetEnvelopeKey: envelope.encodedDict()]
        )

        XCTAssertEqual(reader.activePresetID, "openai-gpt4o-transcribe",
                       "Apply must hydrate the active STT preset from the envelope.")
        XCTAssertEqual(reader.activeCustomModel, "whisper-large-v3",
                       "Apply must hydrate the per-preset model override.")
        XCTAssertEqual(reader.activeTTSProviderID, "openai-tts",
                       "Apply must hydrate the active TTS provider from the envelope's TTS triple.")
        XCTAssertEqual(reader.ttsVoice, "alloy",
                       "Apply must hydrate the TTS voice.")
        XCTAssertEqual(reader.lastEnvelopeTimestamp, ts,
                       "Apply must advance the monotonic high-water-mark to the applied envelope's timestamp.")
    }

    // MARK: - One-time first-run welcome flag (Watch-local, App-Group only)

    func testOnboardingSeenFlagDefaultsFalseThenLatchesTrue() {
        let reader = WatchSettingsReader.shared
        let appGroup = UserDefaults(suiteName: Constants.appGroupID)!
        // The reader is a process singleton and the flag is App-Group-backed, so
        // isolate from any prior run: start clean and restore clean at the end.
        appGroup.removeObject(forKey: Constants.watchOnboardingSeenKey)

        XCTAssertFalse(reader.hasSeenOnboarding(),
                       "A never-written flag must read as unseen so the welcome shows on the very first launch.")

        reader.markOnboardingSeen()
        XCTAssertTrue(reader.hasSeenOnboarding(),
                      "markOnboardingSeen() must latch the flag so the welcome never shows again.")

        appGroup.removeObject(forKey: Constants.watchOnboardingSeenKey)
    }

    func testStaleAndEqualTimestampSTTEnvelopesAreDiscarded() async {
        let reader = WatchSettingsReader.shared
        let fresh = reader.lastEnvelopeTimestamp + 1000

        func apply(presetID: String, timestamp: TimeInterval) async {
            let env = STTBroadcastEnvelope(
                presetID: presetID, apiKey: nil, customModel: nil,
                ttsProviderID: nil, ttsApiKey: nil, ttsVoice: nil, ttsCustomModel: nil,
                timestamp: timestamp
            )
            await WatchSessionManager.shared.applyEnvelopePayload(
                [Constants.sttActivePresetEnvelopeKey: env.encodedDict()]
            )
        }

        // Establish a known fresh state.
        await apply(presetID: "elevenlabs-scribe-v2", timestamp: fresh)
        XCTAssertEqual(reader.activePresetID, "elevenlabs-scribe-v2")
        XCTAssertEqual(reader.lastEnvelopeTimestamp, fresh)

        // Strictly older → discarded.
        await apply(presetID: "mistral-voxtral", timestamp: fresh - 1)
        XCTAssertEqual(reader.activePresetID, "elevenlabs-scribe-v2",
                       "A stale (older-timestamp) envelope must be discarded — active preset unchanged.")
        XCTAssertEqual(reader.lastEnvelopeTimestamp, fresh,
                       "High-water-mark must not regress on a stale envelope.")

        // Equal timestamp → discarded (guard is strict `>`).
        await apply(presetID: "gemini-3-1-flash-lite", timestamp: fresh)
        XCTAssertEqual(reader.activePresetID, "elevenlabs-scribe-v2",
                       "An equal-timestamp envelope must be discarded (strict-greater guard).")

        // Strictly newer → applies.
        await apply(presetID: "apple-on-device", timestamp: fresh + 1)
        XCTAssertEqual(reader.activePresetID, "apple-on-device",
                       "A strictly-newer envelope must apply.")
        XCTAssertEqual(reader.lastEnvelopeTimestamp, fresh + 1)
    }

    // MARK: - AppleRelayPendingQueue.Entry additive-Codable persistence contract

    func testEntryDecodesLegacyBlobWithNilAdditiveFields() throws {
        // A persisted v1 blob predating the additive fields (only the original
        // three keys). It MUST decode with the newer fields nil — otherwise a
        // queued relay silently vanishes across an app update.
        let legacyJSON = #"{"audioFilePath":"/var/clip.m4a","language":"en","enqueuedAt":1234.5}"#
        let entry = try JSONDecoder().decode(
            AppleRelayPendingQueue.Entry.self, from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(entry.audioFilePath, "/var/clip.m4a")
        XCTAssertEqual(entry.language, "en")
        XCTAssertEqual(entry.enqueuedAt, 1234.5)
        XCTAssertNil(entry.providerID, "Legacy blob → providerID nil (additive).")
        XCTAssertNil(entry.conversationID, "Legacy blob → conversationID nil (additive).")
        XCTAssertNil(entry.requestID, "Legacy blob → requestID nil (additive).")
        XCTAssertNil(entry.lastAttemptAt, "Legacy blob → lastAttemptAt nil (additive).")
    }

    func testEntryFullRoundTripPreservesEveryField() throws {
        let entry = AppleRelayPendingQueue.Entry(
            audioFilePath: "/var/a.m4a",
            language: nil,
            enqueuedAt: 10,
            providerID: "custom-openai",
            conversationID: "11112222-3333-4444-5555-666677778888",
            requestID: "req-1",
            lastAttemptAt: 42
        )
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(AppleRelayPendingQueue.Entry.self, from: data)
        XCTAssertEqual(back, entry, "A full Entry must round-trip every field unchanged.")
    }

    // MARK: - Watch-effective default change clears the local active pointer

    /// The envelope's `defaultBackendRef` is the WATCH-EFFECTIVE default (the
    /// iPhone folds in any Watch override). When an accepted newer envelope
    /// CHANGES it, the Watch must clear its OWN active-conversation pointer
    /// (mirrors the iPhone setter's local clear → next headless capture mints
    /// fresh on the new default). A same-value re-delivery must NOT clear.
    func testNewerEffectiveDefaultChangeClearsLocalActivePointer() async {
        let reader = WatchSettingsReader.shared
        // The multi-envelope accept gate compares against the REMOTE-AGENT
        // high-water (distinct from the STT `lastEnvelopeTimestamp`).
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 1000
        func sub(_ ref: String, _ ts: TimeInterval) -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: ref, url: URL(string: "https://\(ref).example.test")!,
                name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
                certFingerprintHex: nil, activeSessionID: nil, timestamp: ts
            )
        }
        func envelope(default ref: String, _ ts: TimeInterval) -> RemoteAgentMultiBroadcastEnvelope {
            RemoteAgentMultiBroadcastEnvelope(
                backends: [sub("openclaw", ts), sub("hermes", ts)],
                defaultBackendRef: ref, timestamp: ts, sessionPolicy: nil
            )
        }

        // Effective default = openclaw.
        XCTAssertTrue(reader.updateRemoteAgents(multi: envelope(default: "openclaw", base)),
                      "A newer multi-envelope must be accepted.")

        // Seed a live wrist quick-capture pointer.
        let convID = UUID()
        reader.recordActiveConversation(convID)
        XCTAssertEqual(reader.resolveActiveConversationID(), convID,
                       "Pointer must be live before the default changes.")

        // Same effective default, newer timestamp → pointer SURVIVES.
        XCTAssertTrue(reader.updateRemoteAgents(multi: envelope(default: "openclaw", base + 1)))
        XCTAssertEqual(reader.resolveActiveConversationID(), convID,
                       "A same-value effective-default re-delivery must NOT clear the pointer.")

        // Changed effective default (→ hermes) → pointer CLEARED.
        XCTAssertTrue(reader.updateRemoteAgents(multi: envelope(default: "hermes", base + 2)))
        XCTAssertNil(reader.resolveActiveConversationID(),
                     "A changed Watch-effective default must clear the wrist's active-conversation pointer.")

        reader.clearActiveConversation()   // leave the singleton clean for sibling tests
    }

    /// Per-ref file-transfer readiness rides each sub-envelope's
    /// `fileTransferAvailable` and the stored map is REPLACED atomically per
    /// multi-envelope: a ref that goes not-ready (or drops out entirely) in a
    /// newer envelope must NOT retain its stale `true`. Load-bearing — the
    /// wrist reads this to gate the per-turn file-delivery instruction on its
    /// spoken converse turns, and a stale `true` would splice a promise the
    /// gateway can no longer honor.
    func testPerRefFileTransferReadinessReplacedAtomically() async {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 3000
        func sub(_ ref: String, ready: Bool, _ ts: TimeInterval) -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: ref, url: URL(string: "https://\(ref).example.test")!,
                name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
                certFingerprintHex: nil, fileTransferAvailable: ready,
                activeSessionID: nil, timestamp: ts
            )
        }

        // First envelope: openclaw ready, hermes not.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub("openclaw", ready: true, base), sub("hermes", ready: false, base)],
            defaultBackendRef: "openclaw", timestamp: base, sessionPolicy: nil)))
        XCTAssertTrue(reader.remoteAgentFileTransferReady(for: "openclaw"),
                      "openclaw's ready sub-envelope must set readiness true")
        XCTAssertFalse(reader.remoteAgentFileTransferReady(for: "hermes"),
                       "hermes's not-ready sub-envelope must read false")

        // Newer envelope: openclaw now NOT ready, and hermes OMITTED entirely.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub("openclaw", ready: false, base + 1)],
            defaultBackendRef: "openclaw", timestamp: base + 1, sessionPolicy: nil)))
        XCTAssertFalse(reader.remoteAgentFileTransferReady(for: "openclaw"),
                       "openclaw's readiness must flip to false — the map is replaced, not merged")
        XCTAssertFalse(reader.remoteAgentFileTransferReady(for: "hermes"),
                       "an OMITTED ref must not retain a stale value (absent → false)")
    }

    /// The Watch-effective `SessionContinuationPolicy` rides the multi-envelope's
    /// `sessionPolicy` slot (replacing the old live-KVS courier). On accepting a
    /// newer envelope carrying it, `sessionContinuationPolicy()` must read it back
    /// from the App-Group cache; an envelope WITHOUT it (old iPhone) must leave the
    /// prior cached value intact (back-compat).
    func testSessionPolicyCourierCachesToWatchReader() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 2000
        func sub(_ ref: String, _ ts: TimeInterval) -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: ref, url: URL(string: "https://\(ref).example.test")!,
                name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
                certFingerprintHex: nil, activeSessionID: nil, timestamp: ts
            )
        }
        func envelope(_ policy: String?, _ ts: TimeInterval) -> RemoteAgentMultiBroadcastEnvelope {
            RemoteAgentMultiBroadcastEnvelope(
                backends: [sub("openclaw", ts)], defaultBackendRef: "openclaw",
                timestamp: ts, sessionPolicy: policy
            )
        }

        // Envelope carries minutes15 → reader reflects it.
        XCTAssertTrue(reader.updateRemoteAgents(multi: envelope("minutes15", base)))
        XCTAssertEqual(reader.sessionContinuationPolicy(), .minutes15,
                       "Watch must apply the couriered session policy.")

        // Envelope carries minutes60 → reader updates.
        XCTAssertTrue(reader.updateRemoteAgents(multi: envelope("minutes60", base + 1)))
        XCTAssertEqual(reader.sessionContinuationPolicy(), .minutes60)

        // Old-iPhone envelope (nil sessionPolicy) → prior cached value SURVIVES.
        XCTAssertTrue(reader.updateRemoteAgents(multi: envelope(nil, base + 2)))
        XCTAssertEqual(reader.sessionContinuationPolicy(), .minutes60,
                       "A nil sessionPolicy must not wipe the cached policy (back-compat).")

        reader.clearActiveConversation()
    }
}

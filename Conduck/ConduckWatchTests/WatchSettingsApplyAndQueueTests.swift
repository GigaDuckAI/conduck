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

    /// `WatchSettingsReader` is a process singleton over ONE in-memory
    /// App-Group double shared by every test in the run, so the gateway cases
    /// below have to restore clean the way the rest of this file does per-test.
    /// Chief offender: the teardown marker, which permanently suppresses
    /// cold-launch config hydration for every test that follows.
    ///
    /// This clears the DURABLE side only. The reader caches its roster and its
    /// retirement records in memory, and nothing here reaches those — so a case
    /// asserting about retirement must scope its assertions to its own uuid
    /// rather than to a count or an `isEmpty`.
    override func tearDown() {
        let appGroup = TestStores.defaults
        appGroup.removeObject(forKey: Constants.retiredGatewayBadgesKey)
        appGroup.removeObject(forKey: Constants.customGatewaysRegistryKey)
        // Mirrors `WatchSettingsReader.remoteAgentTornDownKey`, which is private.
        appGroup.removeObject(forKey: "watch.remoteAgentTornDown")
        super.tearDown()
    }

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
        let appGroup = TestStores.defaults
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

    /// The per-ref file-LANE IDENTITY rides each sub-envelope's
    /// `fileTransferLaneID` and is replaced atomically per multi-envelope, same
    /// as readiness. This identity is the ONLY thing that makes a wrist turn
    /// recoverable: the wrist stamps it onto the reply it persists, and the
    /// retroactive output scan a capable device runs on thread-open revisits
    /// only rows that carry one. It cannot be derived here — the file-server
    /// credential never syncs to the wrist — so a dropped courier means a turn
    /// that is invisible to the scan forever, not merely late.
    func testPerRefFileLaneIdentityCouriersAndReplacesAtomically() async {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 4000
        let laneA = String(repeating: "ab", count: 32)   // 64 lowercase hex
        let laneB = String(repeating: "cd", count: 32)
        func sub(_ ref: String, lane: String?, _ ts: TimeInterval) -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: ref, url: URL(string: "https://\(ref).example.test")!,
                name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
                certFingerprintHex: nil, fileTransferAvailable: lane != nil,
                fileTransferLaneID: lane, activeSessionID: nil, timestamp: ts
            )
        }

        // Two gateways, each with its OWN lane.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub("openclaw", lane: laneA, base), sub("hermes", lane: laneB, base)],
            defaultBackendRef: "openclaw", timestamp: base, sessionPolicy: nil)))
        XCTAssertEqual(reader.remoteAgentFileLane(for: "openclaw").laneID, laneA,
                       "each ref must resolve ITS OWN couriered lane")
        XCTAssertEqual(reader.remoteAgentFileLane(for: "hermes").laneID, laneB,
                       "refs must never borrow each other's lane identity")

        // openclaw is repointed (new lane), hermes drops out entirely.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub("openclaw", lane: laneB, base + 1)],
            defaultBackendRef: "openclaw", timestamp: base + 1, sessionPolicy: nil)))
        XCTAssertEqual(reader.remoteAgentFileLane(for: "openclaw").laneID, laneB,
                       "a repointed lane must overwrite, not merge — a stale id would stamp turns wrong")
        XCTAssertNil(reader.remoteAgentFileLane(for: "hermes").laneID,
                     "an OMITTED ref must lose its lane (the map is replaced, not merged)")

        // Readiness withdrawn while an id is still on the wire: the pair is torn,
        // so the wrist refuses the identity. A turn that doesn't carry the
        // file-delivery instruction must not be stamped as if it did.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [RemoteAgentBroadcastEnvelope(
                backendRef: "openclaw", url: URL(string: "https://openclaw.example.test")!,
                name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
                certFingerprintHex: nil, fileTransferAvailable: false,
                fileTransferLaneID: laneA, activeSessionID: nil, timestamp: base + 2)],
            defaultBackendRef: "openclaw", timestamp: base + 2, sessionPolicy: nil)))
        let lane = reader.remoteAgentFileLane(for: "openclaw")
        XCTAssertFalse(lane.ready)
        XCTAssertNil(lane.laneID,
                     "readiness false must suppress the identity — instruction and stamp describe one lane")
    }

    /// OLD iPHONE (single envelope only) → NEW WATCH. A pre-multi sender can
    /// neither vouch for a file lane nor announce that one went away, so
    /// accepting its envelope must RETIRE any lane a newer sender had couriered.
    /// Provenance fails closed: a missing lane costs a chip, a stale one would
    /// authorize a probe the current sender knows nothing about.
    func testLegacySingleEnvelopeClearsCourieredLaneIdentity() async {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 5000
        let laneA = String(repeating: "ef", count: 32)

        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [RemoteAgentBroadcastEnvelope(
                backendRef: "openclaw", url: URL(string: "https://openclaw.example.test")!,
                name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
                certFingerprintHex: nil, fileTransferAvailable: true,
                fileTransferLaneID: laneA, activeSessionID: nil, timestamp: base)],
            defaultBackendRef: "openclaw", timestamp: base, sessionPolicy: nil)))
        XCTAssertEqual(reader.remoteAgentFileLane(for: "openclaw").laneID, laneA,
                       "precondition: a multi-gateway sender couriered a lane")

        XCTAssertTrue(reader.updateRemoteAgent(
            backend: .openclaw,
            url: URL(string: "https://openclaw.example.test")!,
            fingerprint: nil,
            sessionID: nil,
            timestamp: base + 1
        ))
        XCTAssertNil(reader.remoteAgentFileLane(for: "openclaw").laneID,
                     "a legacy single envelope must retire every couriered lane identity")
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

    // MARK: - Teardown (`clearAll`)

    /// A teardown envelope is what "the user forgot their last gateway on the
    /// iPhone" looks like on the wire. Before it existed the iPhone sent NOTHING
    /// in that state, so the wrist kept a live route — URL, auth scheme, roster
    /// and Keychain token — to a gateway the user believed they had
    /// disconnected, indefinitely and across relaunches.
    func testTeardownEnvelopePurgesEveryPerRefRouteAndTheRoster() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 6000
        let customID = UUID()
        let customRef = RemoteAgentRef.custom(customID).rawString
        func sub(_ ref: String, name: String?, _ ts: TimeInterval) -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: ref, url: URL(string: "https://\(ref.replacingOccurrences(of: "_", with: "-")).example.test")!,
                name: name, model: nil, colorID: "indigo", monogram: "LI", token: "t",
                certFingerprintHex: nil, activeSessionID: nil, timestamp: ts
            )
        }

        // A populated wrist: one built-in + one custom.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub("openclaw", name: nil, base), sub(customRef, name: "LiteLLM", base)],
            defaultBackendRef: "openclaw", timestamp: base, sessionPolicy: nil)))
        XCTAssertNotNil(reader.remoteAgentURLs["openclaw"])
        XCTAssertNotNil(reader.remoteAgentURLs[customRef])
        XCTAssertEqual(reader.customGateways.count, 1)

        // Teardown.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [], defaultBackendRef: "openclaw", timestamp: base + 1,
            sessionPolicy: nil, clearAll: true)))

        XCTAssertTrue(reader.remoteAgentURLs.isEmpty,
                      "Routing dies here: `remoteAgentConfig(for:)` gates on this map, so an emptied map is what makes a forgotten gateway unreachable from the wrist.")
        XCTAssertTrue(reader.customGateways.isEmpty)
        XCTAssertNil(reader.remoteAgentURL,
                     "The legacy single-config mirror must go too — it is a second, older path to the same forgotten address.")
        XCTAssertNil(reader.remoteAgentBackendRef)
        XCTAssertNil(reader.remoteAgentCertFingerprint)
    }

    /// The teardown must clear the active-conversation pointer UNCONDITIONALLY.
    /// The ordinary rule only clears it when the effective default CHANGES — and
    /// a teardown carries the iPhone's fallback default, which is usually the
    /// same ref already stored. Left behind, a later reconfigure of that reused
    /// built-in ref could revive the old thread against a different server.
    func testTeardownClearsActiveConversationEvenWhenTheDefaultRefIsUnchanged() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 7000
        let sub = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw", url: URL(string: "https://openclaw.example.test")!,
            name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
            certFingerprintHex: nil, activeSessionID: nil, timestamp: base
        )
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub], defaultBackendRef: "openclaw", timestamp: base, sessionPolicy: nil)))
        reader.recordActiveConversation(UUID())
        XCTAssertNotNil(reader.resolveActiveConversationID())

        // Same defaultBackendRef as before — only `clearAll` differs.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [], defaultBackendRef: "openclaw", timestamp: base + 1,
            sessionPolicy: nil, clearAll: true)))

        XCTAssertNil(reader.resolveActiveConversationID(),
                     "A teardown leaves no thread to continue.")
    }

    /// An empty `backends` array WITHOUT the flag must be inert. The decoder
    /// drops malformed sub-dicts for forward-compat, so this is also what a
    /// future per-backend schema looks like to an older Watch — reading it as
    /// teardown would turn a compatibility gap into credential destruction.
    func testEmptyBackendsWithoutTheFlagDoesNotPurge() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 8000
        let sub = RemoteAgentBroadcastEnvelope(
            backendRef: "hermes", url: URL(string: "https://hermes.example.test")!,
            name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
            certFingerprintHex: nil, activeSessionID: nil, timestamp: base
        )
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub], defaultBackendRef: "hermes", timestamp: base, sessionPolicy: nil)))

        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [], defaultBackendRef: "hermes", timestamp: base + 1, sessionPolicy: nil)))

        XCTAssertNotNil(reader.remoteAgentURL,
                        "No flag, no destruction — the legacy mirror survives an unflagged empty envelope.")
    }

    /// Staleness still wins. A teardown that lost the race to a newer envelope
    /// must be rejected BEFORE it destroys anything — which is why the session
    /// manager commits this call first and only clears Keychain tokens if it
    /// returned true.
    func testStaleTeardownIsRejected() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 9000
        let sub = RemoteAgentBroadcastEnvelope(
            backendRef: "openclaw", url: URL(string: "https://openclaw.example.test")!,
            name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
            certFingerprintHex: nil, activeSessionID: nil, timestamp: base + 5
        )
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub], defaultBackendRef: "openclaw", timestamp: base + 5, sessionPolicy: nil)))

        XCTAssertFalse(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [], defaultBackendRef: "openclaw", timestamp: base + 1,
            sessionPolicy: nil, clearAll: true)),
            "An out-of-order teardown must be refused.")
        XCTAssertNotNil(reader.remoteAgentURLs["openclaw"],
                        "…and must leave the newer envelope's routing untouched.")

        reader.clearActiveConversation()
    }

    // MARK: - Retired gateway badges (derived, never couriered)

    /// The wrist learns a custom was forgotten the same way it learns anything
    /// else about gateways — the ref stops appearing in the envelope. That
    /// reconciliation loop is therefore also where it DERIVES the badge
    /// tombstone: the iPhone never ships one, because a monogram can carry
    /// personal or organization identity and syncing it would follow the user
    /// into their next iCloud account.
    func testADroppedCustomLeavesItsBadgeBehind() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 11000
        let customID = UUID()
        let customRef = RemoteAgentRef.custom(customID).rawString
        func sub(_ ref: String, name: String?, _ ts: TimeInterval) -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: ref, url: URL(string: "https://gw.example.test")!,
                name: name, model: nil, colorID: "green", monogram: nil, token: "t",
                certFingerprintHex: nil, activeSessionID: nil, timestamp: ts
            )
        }

        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub("openclaw", name: nil, base), sub(customRef, name: "LiteLLM", base)],
            defaultBackendRef: "openclaw", timestamp: base, sessionPolicy: nil)))
        XCTAssertEqual(
            RemoteAgentRefMetadata.monogram(for: .custom(customID), customs: reader.gatewayBadgeRoster),
            "LI"
        )

        // The custom is gone from the next envelope — a Forget on the iPhone.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub("openclaw", name: nil, base + 1)],
            defaultBackendRef: "openclaw", timestamp: base + 1, sessionPolicy: nil)))

        XCTAssertFalse(reader.customGateways.contains { $0.id == customID },
                       "The live roster is the routing + Ask-chooser index — a forgotten gateway must leave it.")
        XCTAssertEqual(
            RemoteAgentRefMetadata.monogram(for: .custom(customID), customs: reader.gatewayBadgeRoster),
            "LI",
            "…but its conversations, which sync here via CloudKit, keep the tag that told them apart."
        )
        XCTAssertNil(reader.remoteAgentConfig(for: customRef),
                     "Keeping the badge must not keep a route.")
    }

    /// A gateway that comes BACK is not a forgotten one. A retirement can be
    /// derived from a roster that only looked shrunken, and without this the
    /// record would hold one of `Constants.maxRetiredGatewayBadges` slots for
    /// the life of the install even though nothing could ever render it.
    func testARestoredCustomReleasesItsRetirementRecord() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 12000
        let customID = UUID()
        let customRef = RemoteAgentRef.custom(customID).rawString
        func sub(_ ref: String, name: String?, _ ts: TimeInterval) -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: ref, url: URL(string: "https://gw.example.test")!,
                name: name, model: nil, colorID: "green", monogram: nil, token: "t",
                certFingerprintHex: nil, activeSessionID: nil, timestamp: ts
            )
        }

        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub(customRef, name: "LiteLLM", base)],
            defaultBackendRef: "openclaw", timestamp: base, sessionPolicy: nil)))
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub("openclaw", name: nil, base + 1)],
            defaultBackendRef: "openclaw", timestamp: base + 1, sessionPolicy: nil)))
        // Scoped to THIS uuid, never a count: the reader is a process singleton
        // and its retirement list is in-memory, so records from earlier tests in
        // the run are still there.
        XCTAssertTrue(reader.retiredGatewayBadges.contains { $0.id == customID })

        // It reappears — a stale roster caught up, or the user re-added it.
        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [sub(customRef, name: "LiteLLM", base + 2)],
            defaultBackendRef: "openclaw", timestamp: base + 2, sessionPolicy: nil)))

        XCTAssertFalse(reader.retiredGatewayBadges.contains { $0.id == customID },
                       "The record must be released, not merely masked by the live entry.")
        XCTAssertEqual(
            reader.gatewayBadgeRoster.filter { $0.id == customID }.count, 1,
            "…and the roster must not carry the gateway twice."
        )
    }

    /// A custom sub-envelope with no name is dropped from the ROSTER as
    /// malformed, yet its per-ref route is still installed. That gap is why a
    /// teardown cannot enumerate the roster to find what to purge: it would
    /// leave this ref's bearer token on the wrist behind a Forget the user
    /// believes wiped everything. `remoteAgentURLs` is the complete index.
    func testANamelessCustomRoutesWithoutJoiningTheRoster() {
        let reader = WatchSettingsReader.shared
        let base = reader.lastRemoteAgentEnvelopeTimestamp + 13000
        let customRef = RemoteAgentRef.custom(UUID()).rawString

        XCTAssertTrue(reader.updateRemoteAgents(multi: RemoteAgentMultiBroadcastEnvelope(
            backends: [RemoteAgentBroadcastEnvelope(
                backendRef: customRef, url: URL(string: "https://nameless.example.test")!,
                name: nil, model: nil, colorID: nil, monogram: nil, token: "t",
                certFingerprintHex: nil, activeSessionID: nil, timestamp: base
            )],
            defaultBackendRef: "openclaw", timestamp: base, sessionPolicy: nil)))

        XCTAssertFalse(reader.customGateways.contains { $0.ref.rawString == customRef },
                       "A nameless custom is malformed for display purposes and stays out of the roster.")
        XCTAssertNotNil(reader.remoteAgentURLs[customRef],
                        "…but it IS routable, so any purge that enumerates only the roster misses it.")
    }
}

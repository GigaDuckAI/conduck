// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsManagerICloudSyncTests.swift
//
// Locks the INBOUND iCloud-KVS mirror — the untested third leg of the
// "synced in THREE places" contract (App Groups `defaults` / iCloud KVS /
// `handleiCloudChange`). The dual-write setters and the durable reads have
// sibling coverage (SettingsManagerTTSTests, SettingsManagerRemoteAgentTests,
// STTCustomModelTests); what was NEVER exercised is `handleiCloudChange(_:)`,
// which mirrors a REMOTE KVS push from a second device into this device's App
// Groups `defaults` so the synchronous durable reads reflect the cloud value.
//
// How the mirror is driven headlessly: `handleiCloudChange` reads
// `NSUbiquitousKeyValueStore.default` and writes App Groups `defaults`. In
// process, `NSUbiquitousKeyValueStore.set(_:forKey:)` round-trips its local
// cache regardless of iCloud SIGN-IN (no account needed), so a test can stage
// the "remote" value in KVS, then hand the actor a SYNTHESIZED
// `NSUbiquitousKeyValueStore.didChangeExternallyNotification` carrying the
// server-change reason + changed-keys list. No real network, no real iCloud
// account, no Keychain — pure UserDefaults + in-process KVS. The downstream
// reads (`getActivePresetID` / `getActiveTTSProviderID` / `getTTSVoice`) all
// consult `defaults` FIRST, so the mirror's effect is observable even when the
// headless sim is signed out of iCloud (`iCloudAvailable == false`).
//
// ⚠️ MUST RUN SIGNED — do NOT pass `CODE_SIGNING_ALLOWED=NO` to `xcodebuild
// test`. The KVS local-cache round-trip above requires the app to carry the
// `com.apple.developer.ubiquity-kvstore-identifier` entitlement; an unsigned
// build embeds no entitlement, so `NSUbiquitousKeyValueStore` goes inert
// (`set` then `string` returns nil) and EVERY inbound-mirror assertion here
// fails with a phantom nil — looks like a real regression, isn't one. The
// default ad-hoc "Sign to Run Locally" identity needs no cert on a simulator
// and supplies the entitlement. (`/review-work`'s compile check may stay
// unsigned; the test GATE may not.) iCloud SIGN-IN is still not required —
// only code SIGNING is.
//
// Contracts locked here:
//   1. A server-change push for a synced key mirrors into `defaults` and the
//      durable read reflects it (preferred-language, active preset, active TTS
//      provider, per-provider voice override).
//   2. The default-gateway pointer is DEVICE-LOCAL: a remote KVS push of the
//      default key is IGNORED (no mirror into defaults, no cross-device active-
//      conversation-pointer clear). The setters write App Groups ONLY (never
//      KVS), and the Watch override is App-Group-only too (never leaks to
//      iPad/Mac).
//   3. A non-server change reason (quota/account) is ignored — no mirror.
//   4. `currentBroadcastEnvelope()`: Apple-on-device STT → STT fields nil; the
//      `hasSTTKey || hasTTSKey` guard returns nil when neither key is present.
//   5. `setActivePresetID` / `setActiveTTSProviderID` round-trip + defaults.
//
// Test isolation: drives the live `SettingsManager.shared` singleton, so every
// test wipes the touched keys in BOTH stores in setUp + tearDown (the
// SettingsManagerReadAloudTests / RemoteAgentMigrationTests pattern).

import XCTest
@testable import Conduck

final class SettingsManagerICloudSyncTests: XCTestCase {

    /// App Groups UserDefaults — same suite the actor uses internally.
    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    /// The live iCloud KVS — the actor reads `NSUbiquitousKeyValueStore.default`,
    /// so the test must stage "remote" values into the SAME instance.
    private let kvs = NSUbiquitousKeyValueStore.default

    // The pinned literals this file asserts against — independently grepped from
    // production source so a rename of the constant breaks the test.
    private let activePresetKey = "stt.activePresetID"          // Constants.sttActivePresetIDKVSKey
    private let activeTTSKey = "tts.activeProviderID"           // Constants.ttsActiveProviderIDKVSKey
    private let preferredLanguageKVSKey = "stt.preferredLanguage" // Constants.sttPreferredLanguageKVSKey
    private let preferredLanguageLocalKey = "preferred_language" // Constants.preferredLanguageKey
    private let defaultBackendKey = "remoteAgent.defaultBackend" // Constants.remoteAgentDefaultBackendKVSKey
    private let watchDefaultKey = "remoteAgent.watchDefaultBackend" // Constants.remoteAgentWatchDefaultBackendKey
    private let sessionPolicyKey = "remoteAgent.sessionPolicy"   // Constants.sessionContinuationPolicyKey
    private let watchSessionPolicyKey = "watch.sessionContinuationPolicyOverride" // Constants.watchSessionContinuationPolicyOverrideKey
    private let deviceLocalMigratedKey = "remoteAgentDefaultBackendDeviceLocalMigrated" // Constants.remoteAgentDefaultBackendDeviceLocalMigratedKey
    private let activeConvIDKey = "remoteAgent.activeConversationID"        // Constants.remoteAgentActiveConversationIDKey
    private let activeConvActivityKey = "remoteAgent.activeConversationActivity" // Constants.remoteAgentActiveConversationActivityKey
    private let appleEngineModeKey = "stt.appleOnDeviceEngineMode" // Constants.appleOnDeviceEngineModeKVSKey

    // File-server key literals (independently pinned, same rationale). The
    // custom suffix uses a FIXED uuid so wipe() always clears it.
    private let fileServerURLKeyOpenclaw = "fileServer.url.openclaw"                 // Constants.fileServerURLKey
    private let fileServerURLKeyCustom = "fileServer.url.custom_11111111-2222-3333-4444-555555555555"
    private let fileServerAvailableKeyOpenclaw = "fileServer.available.openclaw"     // Constants.fileTransferAvailableKey
    private let fileServerFolderCapableKeyOpenclaw = "fileServer.folderCapable.openclaw" // Constants.fileServerFolderCapableKey
    private let fileServerCertKeyOpenclaw = "fileServer.certFingerprint.openclaw"    // Constants.fileServerCertFingerprintKey
    private let fileServerKeepInlineKeyOpenclaw = "fileServer.keepImagesInline.openclaw" // Constants.fileServerKeepImagesInlineKey (legacy, mirror-banned)
    private let fileServerTestedLocallyKeyOpenclaw = "fileServer.testedLocally.openclaw" // Constants.fileServerTestedLocallyKey
    private let fileServerSeededFlagKey = "fileServer.testedLocallySeeded"           // Constants.fileServerTestedLocallySeededKey
    private let fileServerProbeRevisionKeyOpenclaw = "fileServer.folderProbeRevision.openclaw" // Constants.fileServerFolderProbeRevisionKey
    private let fileServerProbeAttemptKeyOpenclaw = "fileServer.folderProbeAttempt.openclaw"   // Constants.fileServerFolderProbeAttemptKey

    override func setUp() async throws {
        try await super.setUp()
        wipe()
    }

    override func tearDown() async throws {
        wipe()
        try await super.tearDown()
    }

    private func wipe() {
        for key in [
            activePresetKey, activeTTSKey, preferredLanguageLocalKey,
            preferredLanguageKVSKey, defaultBackendKey, watchDefaultKey,
            sessionPolicyKey, watchSessionPolicyKey,
            deviceLocalMigratedKey,
            activeConvIDKey, activeConvActivityKey,
            appleEngineModeKey,
            Constants.ttsVoiceKey(for: "openai-tts"),
            // File-server mirror + seed + probe-bookkeeping keys (tests below).
            fileServerURLKeyOpenclaw, fileServerURLKeyCustom,
            fileServerAvailableKeyOpenclaw, fileServerFolderCapableKeyOpenclaw,
            fileServerCertKeyOpenclaw, fileServerKeepInlineKeyOpenclaw,
            fileServerTestedLocallyKeyOpenclaw, fileServerSeededFlagKey,
            fileServerProbeRevisionKeyOpenclaw, fileServerProbeAttemptKeyOpenclaw,
        ] {
            defaults.removeObject(forKey: key)
            kvs.removeObject(forKey: key)
        }
    }

    /// Synthesize the `NSUbiquitousKeyValueStore.didChangeExternallyNotification`
    /// the actor's launch observer normally forwards, then feed it directly to
    /// `handleiCloudChange`. `reason` defaults to a server change (the only
    /// reason — alongside initial-sync — the handler acts on).
    private func makeKVSNotification(
        changedKeys: [String],
        reason: Int = Int(NSUbiquitousKeyValueStoreServerChange)
    ) -> Notification {
        Notification(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs,
            userInfo: [
                NSUbiquitousKeyValueStoreChangeReasonKey: reason,
                NSUbiquitousKeyValueStoreChangedKeysKey: changedKeys,
            ]
        )
    }

    // MARK: - Inbound mirror: synced-key value lands in the durable read

    func testInboundActivePresetMirrorsIntoDurableRead() async {
        // A second device picked a cloud STT preset → a remote KVS push arrives.
        kvs.set("openrouter-stt", forKey: activePresetKey)

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [activePresetKey])
        )

        // The handler must have mirrored the remote value into App Groups
        // `defaults` under the SAME literal so the synchronous durable read
        // (`getActivePresetID`, which consults `defaults` first) reflects it.
        XCTAssertEqual(defaults.string(forKey: activePresetKey), "openrouter-stt",
                       "Inbound active-preset push must mirror into App Groups defaults under the same key.")
        let read = await SettingsManager.shared.getActivePresetID()
        XCTAssertEqual(read, "openrouter-stt",
                       "getActivePresetID must reflect the mirrored cloud value (defaults-first read).")
    }

    func testInboundActiveTTSProviderMirrorsIntoDurableRead() async {
        kvs.set("elevenlabs-tts", forKey: activeTTSKey)

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [activeTTSKey])
        )

        let read = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(read, "elevenlabs-tts",
                       "getActiveTTSProviderID must reflect the mirrored cloud TTS-provider value.")
    }

    func testInboundPreferredLanguageMirrorsAndEmptyClears() async {
        // Remote sets a language hint under the KVS key; it mirrors to the
        // DIFFERENT local key (`preferred_language`) the durable read uses.
        kvs.set("de", forKey: preferredLanguageKVSKey)
        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [preferredLanguageKVSKey])
        )
        let read = await SettingsManager.shared.getPreferredLanguage()
        XCTAssertEqual(read, "de",
                       "Inbound preferred-language push must mirror into the local read key.")

        // Remote clears the hint → the handler removes the local mirror, so the
        // durable read falls back to nil (auto-detect).
        kvs.removeObject(forKey: preferredLanguageKVSKey)
        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [preferredLanguageKVSKey])
        )
        let cleared = await SettingsManager.shared.getPreferredLanguage()
        XCTAssertNil(cleared,
                     "A remote clear of the language hint must remove the local mirror → nil (auto-detect).")
    }

    func testInboundTTSVoiceOverrideMirrorsViaPrefixScan() async {
        // The per-provider voice key (`tts.voice.<id>`) is mirrored by a
        // prefix-scan branch — assert the durable per-provider read reflects it.
        let voiceKey = Constants.ttsVoiceKey(for: "openai-tts")
        kvs.set("nova", forKey: voiceKey)

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [voiceKey])
        )

        let read = await SettingsManager.shared.getTTSVoice(forProviderID: "openai-tts")
        XCTAssertEqual(read, "nova",
                       "Inbound tts.voice.<id> push must mirror via the prefix-scan branch into the durable read.")
    }

    // MARK: - Non-server change reason is ignored

    func testNonServerChangeReasonDoesNotMirror() async {
        kvs.set("openrouter-stt", forKey: activePresetKey)

        // A quota-violation reason must NOT trigger the mirror — those re-fire
        // all keys spuriously and the handler guards against them.
        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(
                changedKeys: [activePresetKey],
                reason: Int(NSUbiquitousKeyValueStoreQuotaViolationChange)
            )
        )

        XCTAssertNil(defaults.string(forKey: activePresetKey),
                     "A quota-violation change reason must be ignored — no mirror into defaults.")
    }

    // MARK: - Default-gateway pointer is DEVICE-LOCAL (no KVS sync)

    func testRemoteDefaultBackendChangeIsIgnoredDeviceLocal() async {
        // Pre-state: this device is bound to openclaw locally with a live
        // active-conversation pointer (a headless-capture thread).
        defaults.set(RemoteAgentBackend.openclaw.rawValue, forKey: defaultBackendKey)
        defaults.set("conv-123", forKey: activeConvIDKey)
        defaults.set(42.0, forKey: activeConvActivityKey)

        // A second device re-points its OWN default to hermes → remote push. The
        // default is DEVICE-LOCAL now, so this device must IGNORE it entirely.
        kvs.set(RemoteAgentBackend.hermes.rawValue, forKey: defaultBackendKey)
        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [defaultBackendKey])
        )

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), RemoteAgentBackend.openclaw.rawValue,
                       "A remote default-backend KVS push must NOT mirror into defaults (device-local).")
        // No cross-device steering — this device's quick-capture pointer survives.
        XCTAssertEqual(defaults.string(forKey: activeConvIDKey), "conv-123",
                       "A remote default-backend change must NOT clear this device's active-conversation pointer.")
        XCTAssertEqual(defaults.object(forKey: activeConvActivityKey) as? Double, 42.0,
                       "A remote default-backend change must leave the activity stamp intact.")
    }

    func testSetDefaultRefWritesAppGroupOnlyNeverKVS() async {
        await SettingsManager.shared.setDefaultRemoteAgentRef(.builtin(.hermes))

        XCTAssertEqual(defaults.string(forKey: defaultBackendKey), RemoteAgentBackend.hermes.rawValue,
                       "Device-local default must be written to App Groups defaults.")
        XCTAssertNil(kvs.string(forKey: defaultBackendKey),
                     "Device-local default must NEVER be written to iCloud KVS (each device owns its own).")
    }

    func testWatchOverrideIsAppGroupOnlyNeverKVS() async {
        // The Watch override is iPhone-written, App-Group ONLY — it must not leak
        // to iPad/Mac via KVS. (Assert the raw write before any self-heal read.)
        await SettingsManager.shared.setWatchDefaultOverrideRef(.builtin(.hermes))

        XCTAssertEqual(defaults.string(forKey: watchDefaultKey), RemoteAgentBackend.hermes.rawValue,
                       "Watch default override must be written to App Groups defaults.")
        XCTAssertNil(kvs.string(forKey: watchDefaultKey),
                     "Watch default override must NEVER be written to iCloud KVS.")

        // Clearing (Follow iPhone) removes the key.
        await SettingsManager.shared.setWatchDefaultOverrideRef(nil)
        XCTAssertNil(defaults.string(forKey: watchDefaultKey),
                     "Clearing the Watch override (Follow iPhone) must remove the App-Group key.")
    }

    // MARK: - Session-continuation policy is PER-DEVICE (no KVS sync)

    func testSetSessionPolicyWritesAppGroupOnlyNeverKVS() async {
        // The policy is now genuinely per-device: App Groups only. The Watch
        // follows the iPhone via the broadcast envelope's `sessionPolicy` slot,
        // not KVS — so the setter must NOT write iCloud KVS (which would sync the
        // value across the user's iOS devices, re-globalizing it).
        await SettingsManager.shared.setSessionContinuationPolicy(.minutes60)

        XCTAssertEqual(defaults.string(forKey: sessionPolicyKey),
                       SessionContinuationPolicy.minutes60.rawValue,
                       "Per-device policy must be written to App Groups defaults.")
        XCTAssertNil(kvs.string(forKey: sessionPolicyKey),
                     "Per-device policy must NEVER be written to iCloud KVS (the Watch gets it via the envelope).")
    }

    func testWatchSessionPolicyOverrideIsAppGroupOnlyNeverKVS() async {
        // The Watch policy override is iPhone-written, App-Group ONLY — it must
        // not leak to iPad/Mac via KVS, mirroring the Watch default-gateway override.
        await SettingsManager.shared.setWatchSessionContinuationPolicyOverride(.minutes15)

        XCTAssertEqual(defaults.string(forKey: watchSessionPolicyKey),
                       SessionContinuationPolicy.minutes15.rawValue,
                       "Watch policy override must be written to App Groups defaults.")
        XCTAssertNil(kvs.string(forKey: watchSessionPolicyKey),
                     "Watch policy override must NEVER be written to iCloud KVS.")

        // Effective policy = the override while set.
        let effectiveWithOverride = await SettingsManager.shared.watchEffectiveSessionContinuationPolicy()
        XCTAssertEqual(effectiveWithOverride, .minutes15,
                       "watchEffectiveSessionContinuationPolicy must return the override when set.")

        // Clearing (Follow iPhone) removes the key and falls back to the iPhone's policy.
        await SettingsManager.shared.setSessionContinuationPolicy(.minutes60)
        await SettingsManager.shared.setWatchSessionContinuationPolicyOverride(nil)
        XCTAssertNil(defaults.string(forKey: watchSessionPolicyKey),
                     "Clearing the Watch override (Follow iPhone) must remove the App-Group key.")
        let effectiveFollow = await SettingsManager.shared.watchEffectiveSessionContinuationPolicy()
        XCTAssertEqual(effectiveFollow, .minutes60,
                       "With no override, the Watch-effective policy follows the iPhone's per-device policy.")
    }

    // MARK: - currentBroadcastEnvelope: keyless states

    func testBroadcastEnvelopeNilWhenNoKeyOnEitherSide() async {
        // STT = a cloud preset with NO key in Keychain, TTS = Apple (keyless).
        // The `hasSTTKey || hasTTSKey` guard must return nil — there is nothing
        // worth shipping to the Watch. No Keychain write needed: a never-written
        // slot reads nil, which is exactly the keyless state we assert (so this
        // runs unsigned, no XCTSkip).
        await SettingsManager.shared.setActivePresetID("openrouter-stt")
        await SettingsManager.shared.setActiveTTSProviderID("apple-tts")

        let envelope = await SettingsManager.shared.currentBroadcastEnvelope()
        XCTAssertNil(envelope,
                     "Keyless cloud STT + keyless Apple TTS → the hasSTTKey||hasTTSKey guard must return nil.")
    }

    func testBroadcastEnvelopeAppleSTTHasNilSTTFields() async {
        // Apple on-device STT is keyless → the envelope ships (so the Watch
        // knows to relay audio to the iPhone) with STT apiKey nil. TTS = Apple
        // (also keyless) so the whole thing stays Keychain-free.
        await SettingsManager.shared.setActivePresetID("apple-on-device")
        await SettingsManager.shared.setActiveTTSProviderID("apple-tts")

        let envelope = await SettingsManager.shared.currentBroadcastEnvelope()
        let unwrapped = try? XCTUnwrap(envelope)
        // Apple STT always ships an envelope (privacy: the Watch must learn Apple
        // is active and stop sending audio+key to a deselected cloud provider).
        XCTAssertNotNil(unwrapped,
                        "Apple-on-device STT must ALWAYS broadcast an envelope (even keyless) so the Watch re-points.")
        XCTAssertEqual(unwrapped?.presetID, "apple-on-device")
        XCTAssertNil(unwrapped?.apiKey, "Apple on-device STT carries no key → STT apiKey must be nil.")
        XCTAssertEqual(unwrapped?.ttsProviderID, "apple-tts")
        XCTAssertNil(unwrapped?.ttsApiKey, "Apple TTS is keyless → TTS apiKey must be nil.")
    }

    // MARK: - Setters: round-trip + defaults

    func testSetActivePresetIDRoundTripsAndDefaultsToAppleOnDevice() async {
        let initial = await SettingsManager.shared.getActivePresetID()
        XCTAssertEqual(initial, "apple-on-device",
                       "Fresh-install default active STT preset must be apple-on-device.")
        XCTAssertEqual(Constants.sttActivePresetIDDefault, "apple-on-device",
                       "The locked default-preset literal must stay apple-on-device.")

        await SettingsManager.shared.setActivePresetID("openrouter-stt")
        let read = await SettingsManager.shared.getActivePresetID()
        XCTAssertEqual(read, "openrouter-stt", "Active preset must round-trip through App Groups defaults.")
        XCTAssertEqual(defaults.string(forKey: activePresetKey), "openrouter-stt",
                       "The setter's durable App-Group leg must be written under the locked key literal.")
    }

    func testSetAppleOnDeviceEngineModeRoundTripsAndDefaultsToDictation() async {
        let initial = await SettingsManager.shared.getAppleOnDeviceEngineMode()
        XCTAssertEqual(initial, .dictation,
                       "Fresh-install on-device engine mode must default to keyboard dictation.")
        XCTAssertEqual(AppleOnDeviceEngineMode.default, .dictation,
                       "The default engine-mode literal must stay dictation.")

        await SettingsManager.shared.setAppleOnDeviceEngineMode(.highQuality)
        let read = await SettingsManager.shared.getAppleOnDeviceEngineMode()
        XCTAssertEqual(read, .highQuality, "Engine mode must round-trip through App Groups defaults.")
        XCTAssertEqual(defaults.string(forKey: appleEngineModeKey), "highQuality",
                       "The setter's durable App-Group leg must be written under the locked key literal.")
    }

    func testSetActiveTTSProviderIDRoundTripsAndDefaultsToAppleTTS() async {
        let initial = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(initial, "apple-tts",
                       "Fresh-install default active TTS provider must be apple-tts.")
        XCTAssertEqual(Constants.ttsActiveProviderIDDefault, "apple-tts",
                       "The locked default-TTS-provider literal must stay apple-tts.")

        await SettingsManager.shared.setActiveTTSProviderID("elevenlabs-tts")
        let read = await SettingsManager.shared.getActiveTTSProviderID()
        XCTAssertEqual(read, "elevenlabs-tts", "Active TTS provider must round-trip through App Groups defaults.")
        XCTAssertEqual(defaults.string(forKey: activeTTSKey), "elevenlabs-tts",
                       "The setter's durable App-Group leg must be written under the locked key literal.")
    }

    // MARK: - Inbound mirror: file-server config (url / available / folderCapable)

    func testInboundFileServerURLMirrorsViaPrefixScanBuiltinAndCustom() async throws {
        // A second device configures the file lane → its dual-write setter
        // pushes `fileServer.url.<suffix>` to KVS. Suffixes are dynamic
        // (built-in raw values AND custom_<uuid>), so the handler must
        // prefix-scan, not enumerate.
        kvs.set("https://files.example.ts.net", forKey: fileServerURLKeyOpenclaw)
        kvs.set("https://other.example.ts.net", forKey: fileServerURLKeyCustom)
        // Environment gate, not a product assert: the sim's kvsd store caps at
        // 1024 RECORDS (live keys + deletion tombstones — a signed-out sim never
        // compacts them, so months of suite churn can fill it; live keys then
        // read fine while every NEW key is silently dropped). If this trips, the
        // rig is poisoned — shut the sim down and delete
        // `data/Containers/Data/InternalDaemon/*/com.apple.kvs/com.apple.KeyValueService-Production.sqlite*`
        // (kvsd recreates it empty), then re-run.
        try XCTSkipUnless(kvs.string(forKey: fileServerURLKeyCustom) != nil,
                          "Sim kvsd store is full (1024-record cap incl. tombstones) — reset it, see comment.")

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [fileServerURLKeyOpenclaw, fileServerURLKeyCustom])
        )

        XCTAssertEqual(defaults.string(forKey: fileServerURLKeyOpenclaw), "https://files.example.ts.net",
                       "Inbound file-server URL push must mirror into App Groups defaults (built-in suffix).")
        XCTAssertEqual(defaults.string(forKey: fileServerURLKeyCustom), "https://other.example.ts.net",
                       "The prefix scan must reach dynamic custom_<uuid> suffixes too.")
    }

    func testInboundFileServerURLRemovalClearsDurableRead() async {
        // Device A forgets the lane → the KVS key is removed; a stale local
        // mirror must not keep resurrecting the dead URL.
        defaults.set("https://stale.example.ts.net", forKey: fileServerURLKeyOpenclaw)

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [fileServerURLKeyOpenclaw])
        )

        XCTAssertNil(defaults.string(forKey: fileServerURLKeyOpenclaw),
                     "A removed/empty cloud URL must clear the local mirror, not survive it.")
    }

    func testInboundFileServerAvailableAndFolderCapableBoolsMirror() async {
        // `available=true` from a peer's passing staged test + the peer's
        // definitive `folderCapable=false` verdict must BOTH land in defaults —
        // the durable reads (`getFileTransferAvailable` /
        // `getFileServerFolderCapable`) consult defaults ONLY, no KVS fallback.
        kvs.set(true, forKey: fileServerAvailableKeyOpenclaw)
        kvs.set(false, forKey: fileServerFolderCapableKeyOpenclaw)

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [fileServerAvailableKeyOpenclaw,
                                              fileServerFolderCapableKeyOpenclaw])
        )

        XCTAssertEqual(defaults.object(forKey: fileServerAvailableKeyOpenclaw) as? Bool, true,
                       "Inbound available=true must mirror (the cross-device enable this mirror exists for).")
        XCTAssertEqual(defaults.object(forKey: fileServerFolderCapableKeyOpenclaw) as? Bool, false,
                       "Inbound folderCapable must mirror the VALUE (false), so both devices mint matching flat keys.")
        let capable = await SettingsManager.shared.getFileServerFolderCapable(for: .builtin(.openclaw))
        XCTAssertFalse(capable, "The durable folderCapable read must reflect the mirrored false, not the default true.")
    }

    func testInboundFileServerCertFingerprintAndLegacyKeyAreNeverMirrored() async {
        // The cert pin is a PER-DEVICE TOFU artefact (never synced by design) and
        // `keepImagesInline` is the retired legacy bool (mirror-banned). Even a
        // hostile/buggy KVS push naming them must not land in defaults — the
        // handler scans three EXPLICIT prefixes, never blanket `fileServer.`.
        kvs.set("ab12", forKey: fileServerCertKeyOpenclaw)
        kvs.set(true, forKey: fileServerKeepInlineKeyOpenclaw)

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [fileServerCertKeyOpenclaw,
                                              fileServerKeepInlineKeyOpenclaw])
        )

        XCTAssertNil(defaults.object(forKey: fileServerCertKeyOpenclaw),
                     "The per-device cert pin must NEVER be written by the inbound mirror.")
        XCTAssertNil(defaults.object(forKey: fileServerKeepInlineKeyOpenclaw),
                     "The retired keepImagesInline legacy key must stay mirror-banned.")
    }

    func testInboundFileServerMirrorAcceptsInitialSyncReason() async {
        // First launch on a fresh device delivers InitialSyncChange, not
        // ServerChange — the file-server mirror must act on both (it is the
        // fresh-install hydration path).
        kvs.set(true, forKey: fileServerAvailableKeyOpenclaw)

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [fileServerAvailableKeyOpenclaw],
                                reason: Int(NSUbiquitousKeyValueStoreInitialSyncChange))
        )

        XCTAssertEqual(defaults.object(forKey: fileServerAvailableKeyOpenclaw) as? Bool, true,
                       "InitialSyncChange must hydrate the file-server flags like a server change.")
    }

    // MARK: - testedLocally seed (device-local provenance for the silent re-probe)

    func testSeedMarksPreMirrorLocalAvailableAsTestedLocally() async {
        // Pre-mirror world: a local available=true could ONLY have come from a
        // staged test run on THIS device. The one-time seed converts that into
        // the explicit testedLocally marker.
        await SettingsManager.shared.resetTestedLocallySeedForTesting()
        defaults.set(true, forKey: fileServerAvailableKeyOpenclaw)

        let tested = await SettingsManager.shared.getFileServerTestedLocally(for: .builtin(.openclaw))

        XCTAssertTrue(tested, "A pre-mirror local available=true must seed testedLocally=true.")
        XCTAssertTrue(defaults.bool(forKey: fileServerSeededFlagKey),
                      "The seed must set its once-ever guard flag.")
    }

    func testMirroredAvailableDoesNotMarkTestedLocally() async {
        // The seed runs BEFORE the mirror writes inside handleiCloudChange, so
        // an available=true that arrives FROM A PEER must not be mistaken for
        // local proof — testedLocally gates automated probes at the peer's
        // server, and adoption is not proof.
        await SettingsManager.shared.resetTestedLocallySeedForTesting()
        kvs.set(true, forKey: fileServerAvailableKeyOpenclaw)

        await SettingsManager.shared.handleiCloudChange(
            makeKVSNotification(changedKeys: [fileServerAvailableKeyOpenclaw])
        )

        XCTAssertEqual(defaults.object(forKey: fileServerAvailableKeyOpenclaw) as? Bool, true,
                       "The mirror itself must still land available=true.")
        let tested = await SettingsManager.shared.getFileServerTestedLocally(for: .builtin(.openclaw))
        XCTAssertFalse(tested, "A synced-only peer must NOT be classified as locally tested.")
    }

    func testSetFileServerTestedLocallyIsAppGroupOnlyNeverKVS() async {
        // Device-local provenance: the flag must never ride KVS (a peer's
        // testedLocally is meaningless on this device).
        await SettingsManager.shared.resetTestedLocallySeedForTesting()
        defaults.set(true, forKey: fileServerSeededFlagKey) // seed already done → pure setter test

        await SettingsManager.shared.setFileServerTestedLocally(true, for: .builtin(.openclaw))

        XCTAssertTrue(defaults.bool(forKey: fileServerTestedLocallyKeyOpenclaw),
                      "setFileServerTestedLocally(true) must write the App-Group flag.")
        XCTAssertNil(kvs.object(forKey: fileServerTestedLocallyKeyOpenclaw),
                     "testedLocally must NEVER be written to iCloud KVS.")

        await SettingsManager.shared.setFileServerTestedLocally(false, for: .builtin(.openclaw))
        XCTAssertNil(defaults.object(forKey: fileServerTestedLocallyKeyOpenclaw),
                     "setFileServerTestedLocally(false) must remove the flag (clean forget).")
    }

    // MARK: - revokeFileTransferReadiness (the single config-mutation choke point)

    func testRevokeFileTransferReadinessClearsFlagsAndProbeMarkers() async {
        // Stage a fully-earned lane: available (dual-stored), local proof, and
        // a recorded silent-probe verdict + attempt.
        defaults.set(true, forKey: fileServerSeededFlagKey) // park the seed — pure revoke test
        await SettingsManager.shared.setFileTransferAvailable(true, for: .builtin(.openclaw))
        await SettingsManager.shared.setFileServerTestedLocally(true, for: .builtin(.openclaw))
        await SettingsManager.shared.setFolderProbeRevision(1, for: .builtin(.openclaw))
        await SettingsManager.shared.setFolderProbeAttempt(Date(timeIntervalSince1970: 1_700_000_000),
                                                           for: .builtin(.openclaw))

        await SettingsManager.shared.revokeFileTransferReadiness(for: .builtin(.openclaw))

        // Readiness drops on BOTH legs — the KVS false is the whole point
        // (peers must see the revocation no later than any new config value).
        XCTAssertEqual(defaults.object(forKey: fileServerAvailableKeyOpenclaw) as? Bool, false,
                       "Revocation must write available=false to App Groups.")
        XCTAssertEqual(kvs.object(forKey: fileServerAvailableKeyOpenclaw) as? Bool, false,
                       "Revocation must dual-write available=false to iCloud KVS.")
        // Local proof + probe bookkeeping are forfeited: a changed identity
        // makes both meaningless for the replacement server, and a surviving
        // revision marker would permanently disarm the silent re-probe there.
        XCTAssertNil(defaults.object(forKey: fileServerTestedLocallyKeyOpenclaw),
                     "Revocation must forfeit the device-local test proof.")
        XCTAssertNil(defaults.object(forKey: fileServerProbeRevisionKeyOpenclaw),
                     "Revocation must clear the silent-probe revision marker.")
        XCTAssertNil(defaults.object(forKey: fileServerProbeAttemptKeyOpenclaw),
                     "Revocation must clear the silent-probe attempt timestamp.")
    }
}

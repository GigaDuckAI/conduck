// SPDX-License-Identifier: Apache-2.0

// Conduck
// LockedKeychainKVSLiteralsTests.swift
//
// LOCKS the on-disk STORAGE key literals — Keychain account slots, iCloud KVS
// keys, and App-Group UserDefaults keys — against INDEPENDENT hardcoded
// strings. These literals are set-once identity: renaming any one of them
// silently orphans every install's stored secrets / preferences (a dropped
// `.lowercased()` on a per-uuid key strands the value; a renamed STT preset ID
// orphans that vendor's Keychain key; a changed KVS key drops cross-device
// sync). The sibling registry tests pin many of these as `helper(id) ==
// "stt.apiKey.\(id)"` — a TAUTOLOGY that can never catch a format rename. This
// file replaces that with verbatim literal pins copied from
// `Utilities/Constants.swift` (+ STT/TTS archetype IDs), so a rename here FAILS
// the build's intent rather than passing silently.
//
// Pure value pins — no Keychain write, no network, no Core Data. Every
// assertion compares a `Constants.*` helper/constant to a HARDCODED literal.
//
// Style mirrors STTProviderRegistryTests (plain XCTestCase, synchronous tests).

import XCTest
@testable import Conduck

final class LockedKeychainKVSLiteralsTests: XCTestCase {

    /// Fixed UUID for per-uuid key shapes. Its lowercased uuidString is
    /// "8e4e2d0a-1b7c-4f4e-9d1a-2c3b4a5d6e7f" — computed by hand from the
    /// uppercase form below, NOT via `.uuidString.lowercased()` (that would
    /// recreate the very transform under test).
    private let fixedUUID = UUID(uuidString: "8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F")!
    private let fixedUUIDLowerString = "8e4e2d0a-1b7c-4f4e-9d1a-2c3b4a5d6e7f"

    // MARK: - STT API-key Keychain account (one per locked archetype)

    func testSTTApiKeyKeychainAccountLiteralsPerArchetype() {
        // Each STT preset ID is LOCKED (Keychain account suffix depends on it).
        // Pin the FULL account literal, not
        // "stt.apiKey." + id (which would be a tautology against the helper).
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "openai-gpt4o-transcribe"),
                       "stt.apiKey.openai-gpt4o-transcribe",
                       "OpenAI STT Keychain account literal changed — orphans existing OpenAI keys.")
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "elevenlabs-scribe-v2"),
                       "stt.apiKey.elevenlabs-scribe-v2",
                       "ElevenLabs STT Keychain account literal changed — orphans existing ElevenLabs keys.")
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "gemini-3-1-flash-lite"),
                       "stt.apiKey.gemini-3-1-flash-lite",
                       "Gemini STT Keychain account literal changed — orphans existing Gemini keys.")
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "mistral-voxtral"),
                       "stt.apiKey.mistral-voxtral",
                       "Mistral Voxtral V1 Keychain account literal changed — breaks zero-migration for Voxtral users.")
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "openrouter-stt"),
                       "stt.apiKey.openrouter-stt",
                       "OpenRouter STT Keychain account literal changed — orphans existing OpenRouter voice keys.")
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "custom-openai"),
                       "stt.apiKey.custom-openai",
                       "Custom-OpenAI STT Keychain account literal changed — orphans the BYO endpoint key.")
        XCTAssertEqual(Constants.sttApiKeyKeychainAccount(for: "apple-on-device"),
                       "stt.apiKey.apple-on-device",
                       "Apple-on-device Keychain account literal changed (reserved even though Apple writes no slot).")
    }

    // MARK: - Per-uuid custom STT/TTS keys (the high-value lowercased-uuid pins)

    func testCustomSTTURLKeyPerUUIDIsDottedAndLowercased() {
        // HIGH VALUE: a dropped `.lowercased()` here silently orphans every
        // stored custom-endpoint URL. Assert the EXACT dotted + lowercased form.
        XCTAssertEqual(Constants.customSTTURLKey(for: fixedUUID),
                       "stt.custom.url." + fixedUUIDLowerString,
                       "Per-uuid custom STT URL key must be 'stt.custom.url.<lowercased-uuid>' — a dropped .lowercased() orphans stored URLs.")
    }

    func testCustomSTTCertFingerprintKeyPerUUID() {
        XCTAssertEqual(Constants.customSTTCertFingerprintKey(for: fixedUUID),
                       "stt.custom.certFingerprint." + fixedUUIDLowerString,
                       "Per-uuid custom STT cert-fingerprint key literal changed.")
    }

    func testCustomSTTModelKeyPerUUID() {
        XCTAssertEqual(Constants.customSTTModelKey(for: fixedUUID),
                       "stt.custom.model." + fixedUUIDLowerString,
                       "Per-uuid custom STT model key literal changed.")
    }

    func testCustomSTTAuthSchemeKeyPerUUID() {
        XCTAssertEqual(Constants.customSTTAuthSchemeKey(for: fixedUUID),
                       "stt.custom.authScheme." + fixedUUIDLowerString,
                       "Per-uuid custom STT auth-scheme key literal changed.")
    }

    func testCustomTTSModelKeyPerUUID() {
        XCTAssertEqual(Constants.customTTSModelKey(for: fixedUUID),
                       "tts.custom.model." + fixedUUIDLowerString,
                       "Per-uuid custom TTS model key literal changed.")
    }

    // MARK: - Singleton custom STT/TTS keys (migration-read base literals)

    func testSingletonCustomVoiceKeyLiterals() {
        XCTAssertEqual(Constants.customSTTURLKey, "stt.custom.url",
                       "Singleton custom STT URL key (migration-read form) changed.")
        XCTAssertEqual(Constants.customSTTCertFingerprintKey, "stt.custom.certFingerprint",
                       "Singleton custom STT cert-fingerprint key changed.")
        XCTAssertEqual(Constants.customSTTModelKey, "stt.custom.model",
                       "Singleton custom STT model key changed.")
        XCTAssertEqual(Constants.customSTTAuthSchemeKey, "stt.custom.authScheme",
                       "Singleton custom STT auth-scheme key changed.")
        XCTAssertEqual(Constants.customTTSModelKey, "tts.custom.model",
                       "Singleton custom TTS model key changed.")
    }

    // MARK: - Remote-agent per-REF Keychain account + URL + cert keys

    func testRemoteAgentPerBackendKeyLiterals() {
        // Built-in suffix == RemoteAgentBackend raw value (locked). Pin the full
        // literal for each backend; a rename of the raw value or the prefix
        // orphans that gateway's stored token/URL/cert.
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        let hermes = RemoteAgentRef.builtin(.hermes)
        let openrouter = RemoteAgentRef.builtin(.openrouter)

        XCTAssertEqual(Constants.remoteAgentTokenKeychainAccount(for: openclaw),
                       "remoteAgent.token.openclaw",
                       "OpenClaw token Keychain account literal changed.")
        XCTAssertEqual(Constants.remoteAgentTokenKeychainAccount(for: hermes),
                       "remoteAgent.token.hermes",
                       "Hermes token Keychain account literal changed.")
        XCTAssertEqual(Constants.remoteAgentTokenKeychainAccount(for: openrouter),
                       "remoteAgent.token.openrouter",
                       "OpenRouter token Keychain account literal changed.")

        XCTAssertEqual(Constants.remoteAgentURLKey(for: openclaw),
                       "remoteAgent.url.openclaw",
                       "OpenClaw per-ref URL key literal changed.")
        XCTAssertEqual(Constants.remoteAgentURLKey(for: hermes),
                       "remoteAgent.url.hermes",
                       "Hermes per-ref URL key literal changed.")
        XCTAssertEqual(Constants.remoteAgentURLKey(for: openrouter),
                       "remoteAgent.url.openrouter",
                       "OpenRouter per-ref URL key literal changed.")

        XCTAssertEqual(Constants.remoteAgentCertFingerprintKey(for: openclaw),
                       "remoteAgent.certFingerprint.openclaw",
                       "OpenClaw per-ref cert-fingerprint key literal changed.")
        XCTAssertEqual(Constants.remoteAgentCertFingerprintKey(for: hermes),
                       "remoteAgent.certFingerprint.hermes",
                       "Hermes per-ref cert-fingerprint key literal changed.")
        XCTAssertEqual(Constants.remoteAgentCertFingerprintKey(for: openrouter),
                       "remoteAgent.certFingerprint.openrouter",
                       "OpenRouter per-ref cert-fingerprint key literal changed.")
    }

    func testRemoteAgentBackendOverloadMatchesRefForBuiltins() {
        // The `for backend:` overload must be byte-identical to the `for ref:`
        // overload for built-ins (back-compat) — pin its literal too.
        XCTAssertEqual(Constants.remoteAgentTokenKeychainAccount(for: RemoteAgentBackend.openclaw),
                       "remoteAgent.token.openclaw",
                       "Per-backend OpenClaw token account literal changed.")
        XCTAssertEqual(Constants.remoteAgentURLKey(for: RemoteAgentBackend.hermes),
                       "remoteAgent.url.hermes",
                       "Per-backend Hermes URL key literal changed.")
        XCTAssertEqual(Constants.remoteAgentCertFingerprintKey(for: RemoteAgentBackend.openrouter),
                       "remoteAgent.certFingerprint.openrouter",
                       "Per-backend OpenRouter cert-fingerprint key literal changed.")
    }

    func testRemoteAgentCustomRefKeyLiteralsAreLowercasedUUID() {
        // Custom suffix == "custom_" + lowercased uuid. The token slot is
        // Keychain; URL + cert are UserDefaults/KVS. A dropped `.lowercased()`
        // or a changed `custom_` prefix orphans the custom gateway's config.
        let custom = RemoteAgentRef.custom(fixedUUID)
        let expectedSuffix = "custom_" + fixedUUIDLowerString

        XCTAssertEqual(Constants.remoteAgentTokenKeychainAccount(for: custom),
                       "remoteAgent.token." + expectedSuffix,
                       "Custom gateway token Keychain account literal/format changed.")
        XCTAssertEqual(Constants.remoteAgentURLKey(for: custom),
                       "remoteAgent.url." + expectedSuffix,
                       "Custom gateway URL key literal/format changed.")
        XCTAssertEqual(Constants.remoteAgentCertFingerprintKey(for: custom),
                       "remoteAgent.certFingerprint." + expectedSuffix,
                       "Custom gateway cert-fingerprint key literal/format changed.")
        XCTAssertEqual(Constants.remoteAgentModelKey(for: custom),
                       "remoteAgent.model." + expectedSuffix,
                       "Custom gateway model key literal/format changed.")
        XCTAssertEqual(Constants.remoteAgentAuthSchemeKey(for: custom),
                       "remoteAgent.authScheme." + expectedSuffix,
                       "Custom gateway auth-scheme key literal/format changed.")
        XCTAssertEqual(Constants.remoteAgentTransportHintKey(for: custom),
                       "remoteAgent.transportHint." + expectedSuffix,
                       "Custom gateway transport-hint key literal/format changed.")
    }

    func testRemoteAgentLegacySingleSlotLiterals() {
        // Legacy single-slot literals are RETAINED for migration-read — pin them.
        XCTAssertEqual(Constants.remoteAgentTokenKeychainAccount, "remoteAgent.token",
                       "Legacy single-slot token Keychain account literal changed — breaks multi-gateway migration read.")
        XCTAssertEqual(Constants.remoteAgentURLKey, "remoteAgent.url",
                       "Legacy single-slot URL key literal changed.")
        XCTAssertEqual(Constants.remoteAgentCertFingerprintKey, "remoteAgent.certFingerprint",
                       "Legacy single-slot cert-fingerprint key literal changed.")
        XCTAssertEqual(Constants.remoteAgentBackendKey, "remoteAgent.backend",
                       "Legacy backend-selection key literal changed.")
    }

    // MARK: - TTS KVS keys

    func testTTSActiveProviderAndOverrideKeyLiterals() {
        XCTAssertEqual(Constants.ttsActiveProviderIDKVSKey, "tts.activeProviderID",
                       "TTS active-provider KVS key literal changed — drops cross-device active-voice sync.")
        XCTAssertEqual(Constants.ttsVoiceKey(for: "openai-tts"), "tts.voice.openai-tts",
                       "TTS per-provider voice key must be 'tts.voice.<id>'.")
        XCTAssertEqual(Constants.ttsVoiceKey(for: "elevenlabs-tts"), "tts.voice.elevenlabs-tts",
                       "TTS per-provider voice key must be 'tts.voice.<id>'.")
        XCTAssertEqual(Constants.ttsCustomModelKey(for: "openai-tts"), "tts.customModel.openai-tts",
                       "TTS per-provider model-override key must be 'tts.customModel.<id>'.")
        XCTAssertEqual(Constants.ttsCustomModelKey(for: "mistral-tts"), "tts.customModel.mistral-tts",
                       "TTS per-provider model-override key must be 'tts.customModel.<id>'.")
    }

    // MARK: - STT KVS keys (active preset + per-preset model + preferred language)

    func testSTTKVSKeyLiterals() {
        XCTAssertEqual(Constants.sttActivePresetIDKVSKey, "stt.activePresetID",
                       "Active-STT-preset KVS key literal changed — drops cross-device active-STT sync.")
        XCTAssertEqual(Constants.sttPreferredLanguageKVSKey, "stt.preferredLanguage",
                       "STT preferred-language KVS key literal changed.")
        XCTAssertEqual(Constants.sttCustomModelKey(for: "mistral-voxtral"), "stt.customModel.mistral-voxtral",
                       "STT per-preset model-override key must be 'stt.customModel.<id>'.")
    }

    // MARK: - Default-backend pointer + session/onLaunch KVS keys

    func testDefaultBackendAndSessionKVSKeyLiterals() {
        XCTAssertEqual(Constants.remoteAgentDefaultBackendKVSKey, "remoteAgent.defaultBackend",
                       "Default-backend pointer KVS key literal changed — new conversations lose their gateway binding default.")
        XCTAssertEqual(Constants.customGatewaysRegistryKey, "remoteAgent.customGateways",
                       "Custom-gateways roster KVS key literal changed — drops all custom gateways across devices.")
        XCTAssertEqual(Constants.retiredGatewayBadgesKey, "remoteAgent.retiredGatewayBadges",
                       "Retired-badge key literal changed — every forgotten gateway's conversations go blank. App-Group ONLY: this key must never appear in KVS.")
        XCTAssertEqual(Constants.remoteAgentLastUsedBackendKey, "remoteAgent.lastUsedBackend",
                       "Last-used gateway key literal changed — new chats silently stop continuing where the user left off. App-Group ONLY: this key must never appear in KVS.")
        XCTAssertEqual(Constants.sessionContinuationPolicyKey, "remoteAgent.sessionPolicy",
                       "Session-continuation-policy KVS key literal changed.")
        XCTAssertEqual(Constants.onLaunchModeKey, "remoteAgent.onLaunchMode",
                       "On-launch-mode KVS key literal changed.")
    }

    // MARK: - Read-state keys (legacy marker prefixes + the account cutover pair)

    func testReadStateKeyLiterals() {
        // The two LEGACY marker prefixes. Read-and-drain-only — nothing writes a
        // new one — but they are still on every installed device, and
        // `ReadStateStore`'s construction sweep finds them by these exact
        // strings. A rename makes the sweep find nothing: the read markers never
        // fold into their conversation records (so a year of already-read
        // threads arrives bold on the next launch) and the failure markers are
        // never retired (so they sit in the App-Group domain forever).
        XCTAssertEqual(Constants.conversationReadStatePrefix, "conversations.readState.",
                       "Legacy read-marker key PREFIX changed — the drain finds nothing and already-read threads go bold.")
        XCTAssertEqual(Constants.conversationFailureSeenPrefix, "conversations.failureSeen.",
                       "Legacy failure-marker key PREFIX changed — the retirement sweep finds nothing.")

        // The account cutover's LOCAL MIRROR. The name says "epoch" because that
        // is what it held on every already-installed device; the meaning is the
        // account cutover. Renaming it resets every installed device to an
        // unstamped cutover, and everything older than its next launch arrives
        // bold on every surface at once.
        XCTAssertEqual(Constants.conversationReadStateEpochKey, "conversations.readState.epoch",
                       "Account-cutover local mirror key changed — every installed device resets to an unstamped cutover.")

        // The account cutover's iCloud KVS key — the one read-state value that
        // travels through KVS rather than through the conversation record.
        // Renaming it splits the fleet in two: devices on either name meet a
        // different register and stop converging, with no visible symptom beyond
        // dots that disagree.
        XCTAssertEqual(Constants.conversationReadCutoverKVSKey, "conversations.readCutover",
                       "Account-cutover KVS key changed — devices on the old and new names stop converging.")

        // The mirror and the register are DISTINCT keys in DISTINCT stores.
        // Collapsing them to one literal would be harmless today and a trap the
        // moment either store grows a prefix scan over the other's namespace.
        XCTAssertNotEqual(Constants.conversationReadStateEpochKey, Constants.conversationReadCutoverKVSKey,
                          "The cutover's local mirror and its KVS register must stay distinct keys.")

        // The KVS key must NOT sit under the legacy marker prefix. That prefix's
        // sweep deletes every key beneath it that does not parse as a UUID
        // marker, so a cutover key nested there would be swept as an orphan.
        XCTAssertFalse(Constants.conversationReadCutoverKVSKey.hasPrefix(Constants.conversationReadStatePrefix),
                       "The cutover KVS key must not sit under the legacy marker prefix — the orphan sweep would delete it.")
    }

    // MARK: - Image-history policy keys

    func testImageHistoryPolicyKeyLiterals() {
        XCTAssertEqual(Constants.imageHistoryPolicyKeyPrefix, "imageHistory.policy.",
                       "Image-history-policy key PREFIX changed — the handleICloudChange prefix-scan and per-ref key would drift.")
        // Per-ref key for a built-in: prefix + raw value.
        XCTAssertEqual(Constants.imageHistoryPolicyKey(for: .builtin(.openclaw)),
                       "imageHistory.policy.openclaw",
                       "Per-ref image-history-policy key (built-in) literal changed.")
        // Per-ref key for a custom: prefix + 'custom_' + lowercased uuid.
        XCTAssertEqual(Constants.imageHistoryPolicyKey(for: .custom(fixedUUID)),
                       "imageHistory.policy.custom_" + fixedUUIDLowerString,
                       "Per-ref image-history-policy key (custom) literal/format changed.")
    }

    // MARK: - File-server per-ref keys

    func testFileServerPerRefKeyLiterals() {
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        let custom = RemoteAgentRef.custom(fixedUUID)
        let customSuffix = "custom_" + fixedUUIDLowerString

        // Built-in (suffix == raw value).
        XCTAssertEqual(Constants.fileServerURLKey(for: openclaw), "fileServer.url.openclaw",
                       "File-server per-ref URL key (built-in) literal changed.")
        XCTAssertEqual(Constants.fileServerCertFingerprintKey(for: openclaw), "fileServer.certFingerprint.openclaw",
                       "File-server cert-fingerprint key (built-in) literal changed.")
        XCTAssertEqual(Constants.fileTransferAvailableKey(for: openclaw), "fileServer.available.openclaw",
                       "File-server availability flag key (built-in) literal changed.")
        XCTAssertEqual(Constants.fileServerCredentialKeychainAccount(for: openclaw), "fileServer.credential.openclaw",
                       "File-server credential Keychain account (built-in) literal changed.")
        XCTAssertEqual(Constants.fileServerFolderCapableKey(for: openclaw), "fileServer.folderCapable.openclaw",
                       "File-server folder-capable flag key (built-in) literal changed.")
        XCTAssertEqual(Constants.fileServerKeepImagesInlineKey(for: openclaw), "fileServer.keepImagesInline.openclaw",
                       "Legacy file-server keep-images-inline key (built-in) literal changed — breaks lazy migration to ImageHistoryPolicy.")
        XCTAssertEqual(Constants.fileServerAutoDeliverKey(for: openclaw), "fileServer.autoDeliver.openclaw",
                       "File-server auto-deliver permission key (built-in) literal changed.")
        XCTAssertEqual(Constants.fileServerFilenamePolicyKey(for: openclaw), "fileServer.filenamePolicy.openclaw",
                       "File-server filename-policy key (built-in) literal changed.")

        // Custom (suffix == 'custom_' + lowercased uuid) — guards the lowercasing.
        XCTAssertEqual(Constants.fileServerURLKey(for: custom), "fileServer.url." + customSuffix,
                       "File-server per-ref URL key (custom) literal/format changed.")
        XCTAssertEqual(Constants.fileServerCredentialKeychainAccount(for: custom), "fileServer.credential." + customSuffix,
                       "File-server credential Keychain account (custom) literal/format changed.")
        XCTAssertEqual(Constants.fileServerAutoDeliverKey(for: custom), "fileServer.autoDeliver." + customSuffix,
                       "File-server auto-deliver permission key (custom) literal/format changed.")
        XCTAssertEqual(Constants.fileServerFilenamePolicyKey(for: custom), "fileServer.filenamePolicy." + customSuffix,
                       "File-server filename-policy key (custom) literal/format changed.")

        // Prefixes are single-sourced because the inbound KVS mirror scans by
        // prefix; a drifted prefix would stop mirroring silently rather than
        // failing to compile.
        XCTAssertEqual(Constants.fileServerAutoDeliverKeyPrefix, "fileServer.autoDeliver.",
                       "File-server auto-deliver key PREFIX changed — the KVS mirror scan keys on it.")
        XCTAssertEqual(Constants.fileServerFilenamePolicyKeyPrefix, "fileServer.filenamePolicy.",
                       "File-server filename-policy key PREFIX changed — the KVS mirror scan keys on it.")

        // Non-keyed file-server constants.
        XCTAssertEqual(Constants.fileServerUsername, "conduck",
                       "File-server basic-auth username literal changed — the client and conduck-connect (which provisions the server) would disagree.")
        XCTAssertEqual(Constants.fileServerFilenamePolicyPreserve, "preserve",
                       "The only filename-policy value changed — a stored value would stop resolving on upgraded devices.")
    }
}

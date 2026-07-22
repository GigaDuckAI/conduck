// Conduck
// LockedRawValueLiteralsTests.swift
//
// LOCKS the storage/wire-level string + numeric literals that several
// subsystems persist and route on: enum raw values and ID prefixes. Every
// source file under test carries a "DO NOT RENAME / LOCKED" comment because a
// rename silently ORPHANS existing data (persisted `Conversation.backend`,
// Keychain account suffixes, KVS active-provider values, per-ref storage keys).
// A plain `==`-against-the-symbol test cannot catch that rename — it would just
// follow the symbol. So EVERY assertion here pins against a HARDCODED literal
// copied verbatim from source (exact casing, separators, lowercased UUIDs).
//
// Pure value types, no network / Keychain / Core Data — fully deterministic.
//
// Sources:
//   - Services/RemoteAgent/RemoteAgentBackend.swift
//   - Services/RemoteAgent/RemoteAgentRef.swift
//   - Services/STT/STTProvider.swift
//   - Services/TTS/TTSProvider.swift
//   - Models/OnLaunchMode.swift
//   - Models/SessionContinuationPolicy.swift
//   - Models/MenuBarInputMode.swift
//   - Models/ImageHistoryPolicy.swift

import XCTest
@testable import Conduck

final class LockedRawValueLiteralsTests: XCTestCase {

    // A fixed UUID so the custom-ref / custom-preset assertions are reproducible.
    // Canonical `uuidString` is UPPERCASE; `rawString` lowercases it, so the
    // expected serialized form is the hand-computed lowercased value below.
    private let fixedUUID = UUID(uuidString: "8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F")!
    private let fixedUUIDLowercased = "8e4e2d0a-1b7c-4f4e-9d1a-2c3b4a5d6e7f"

    // MARK: - RemoteAgentBackend raw values + allCases

    func testRemoteAgentBackendRawValuesLocked() {
        XCTAssertEqual(RemoteAgentBackend.openclaw.rawValue, "openclaw")
        XCTAssertEqual(RemoteAgentBackend.hermes.rawValue, "hermes")
        XCTAssertEqual(RemoteAgentBackend.openrouter.rawValue, "openrouter")
    }

    func testRemoteAgentBackendAllCasesLocked() {
        // Order-independent: the set of persisted raw values is the contract;
        // adding/removing a backend (or renaming one) breaks this.
        let raws = Set(RemoteAgentBackend.allCases.map(\.rawValue))
        XCTAssertEqual(raws, ["openclaw", "hermes", "openrouter"])
        XCTAssertEqual(RemoteAgentBackend.allCases.count, 3)
    }

    func testRemoteAgentBackendRawValueRoundTrip() {
        // The inverse parse from the persisted literal must reconstruct the case
        // (Conversation.backend / KVS read path depends on this).
        XCTAssertEqual(RemoteAgentBackend(rawValue: "openclaw"), .openclaw)
        XCTAssertEqual(RemoteAgentBackend(rawValue: "hermes"), .hermes)
        XCTAssertEqual(RemoteAgentBackend(rawValue: "openrouter"), .openrouter)
        XCTAssertNil(RemoteAgentBackend(rawValue: "custom_abc"))
    }

    // MARK: - RemoteAgentRef prefix + rawString serialization

    func testRemoteAgentRefCustomPrefixLocked() {
        XCTAssertEqual(RemoteAgentRef.customPrefix, "custom_")
    }

    func testRemoteAgentRefBuiltinRawStringEqualsBackendRawValue() {
        // Built-ins serialize to the EXISTING backend raw value (back-compat:
        // existing stored Conversation.backend strings keep parsing/routing).
        XCTAssertEqual(RemoteAgentRef.builtin(.openclaw).rawString, "openclaw")
        XCTAssertEqual(RemoteAgentRef.builtin(.hermes).rawString, "hermes")
        XCTAssertEqual(RemoteAgentRef.builtin(.openrouter).rawString, "openrouter")
    }

    func testRemoteAgentRefCustomRawStringIsPrefixPlusLowercasedUUID() {
        XCTAssertEqual(
            RemoteAgentRef.custom(fixedUUID).rawString,
            "custom_" + fixedUUIDLowercased
        )
        // Pin the fully assembled literal too — the prefix + lowercase contract
        // is what every persisted custom key depends on.
        XCTAssertEqual(
            RemoteAgentRef.custom(fixedUUID).rawString,
            "custom_8e4e2d0a-1b7c-4f4e-9d1a-2c3b4a5d6e7f"
        )
    }

    func testRemoteAgentRefStorageKeySuffixEqualsRawString() {
        // Per-ref Keychain account + URL/cert suffixes ARE the rawString — zero
        // migration. Built-ins keep their exact "openclaw"/"hermes" suffixes.
        XCTAssertEqual(RemoteAgentRef.builtin(.hermes).storageKeySuffix, "hermes")
        XCTAssertEqual(
            RemoteAgentRef.custom(fixedUUID).storageKeySuffix,
            "custom_" + fixedUUIDLowercased
        )
    }

    func testRemoteAgentRefRawStringInverseParse() {
        // Built-in literals reconstruct as .builtin.
        XCTAssertEqual(RemoteAgentRef(rawString: "openclaw"), .builtin(.openclaw))
        XCTAssertEqual(RemoteAgentRef(rawString: "hermes"), .builtin(.hermes))
        XCTAssertEqual(RemoteAgentRef(rawString: "openrouter"), .builtin(.openrouter))

        // A "custom_<uuid>" literal reconstructs as .custom with the SAME uuid.
        XCTAssertEqual(
            RemoteAgentRef(rawString: "custom_" + fixedUUIDLowercased),
            .custom(fixedUUID)
        )

        // Garbage / non-UUID custom suffix / bare prefix → nil (caller maps to
        // remoteAgentNotConfigured — no silent reroute).
        XCTAssertNil(RemoteAgentRef(rawString: "not-a-ref"))
        XCTAssertNil(RemoteAgentRef(rawString: "custom_not-a-uuid"))
        XCTAssertNil(RemoteAgentRef(rawString: "custom_"))
        XCTAssertNil(RemoteAgentRef(rawString: ""))
    }

    // MARK: - STT / TTS custom preset prefixes

    func testSTTCustomPresetPrefixLocked() {
        // Trailing "_" introduces the uuid; DISJOINT from the bare legacy id
        // "custom-openai" and from the TTS prefix (which puts "-tts" before "_").
        XCTAssertEqual(STTProvider.customPresetPrefix, "custom-openai_")
    }

    func testSTTCustomEndpointIDIsPrefixPlusLowercasedUUID() {
        XCTAssertEqual(
            STTProvider.customEndpointID(for: fixedUUID),
            "custom-openai_" + fixedUUIDLowercased
        )
    }

    func testTTSCustomProviderPrefixLocked() {
        // The "-tts" segment sits between the base and the uuid-introducing "_".
        XCTAssertEqual(TTSProvider.customProviderPrefix, "custom-openai-tts_")
    }

    func testTTSCustomEndpointIDIsPrefixPlusLowercasedUUID() {
        XCTAssertEqual(
            TTSProvider.customEndpointID(for: fixedUUID),
            "custom-openai-tts_" + fixedUUIDLowercased
        )
    }

    func testSTTAndTTSCustomPrefixesAreDisjoint() {
        // A TTS preset id must NOT parse as an STT endpoint uuid and vice versa
        // (the load-bearing namespace separation: "_" vs "-tts_").
        let sttID = STTProvider.customEndpointID(for: fixedUUID)
        let ttsID = TTSProvider.customEndpointID(for: fixedUUID)
        XCTAssertEqual(STTProvider.customEndpointUUID(fromPresetID: sttID), fixedUUID)
        XCTAssertNil(STTProvider.customEndpointUUID(fromPresetID: ttsID),
                     "A TTS provider id must not be read as an STT custom endpoint id.")
        XCTAssertEqual(TTSProvider.customEndpointUUID(fromProviderID: ttsID), fixedUUID)
        // The bare legacy ids carry no uuid suffix → reject.
        XCTAssertNil(STTProvider.customEndpointUUID(fromPresetID: "custom-openai"))
        XCTAssertNil(TTSProvider.customEndpointUUID(fromProviderID: "custom-openai-tts"))
    }

    // MARK: - OnLaunchMode

    func testOnLaunchModeRawValuesLocked() {
        XCTAssertEqual(OnLaunchMode.startNewConversation.rawValue, "startNewConversation")
        XCTAssertEqual(OnLaunchMode.resumeLastConversation.rawValue, "resumeLastConversation")
        XCTAssertEqual(Set(OnLaunchMode.allCases.map(\.rawValue)),
                       ["startNewConversation", "resumeLastConversation"])
    }

    // MARK: - SessionContinuationPolicy

    func testSessionContinuationPolicyRawValuesLocked() {
        XCTAssertEqual(SessionContinuationPolicy.alwaysNew.rawValue, "alwaysNew")
        XCTAssertEqual(SessionContinuationPolicy.minutes15.rawValue, "minutes15")
        XCTAssertEqual(SessionContinuationPolicy.minutes30.rawValue, "minutes30")
        XCTAssertEqual(SessionContinuationPolicy.minutes60.rawValue, "minutes60")
        XCTAssertEqual(SessionContinuationPolicy.alwaysContinue.rawValue, "alwaysContinue")
        XCTAssertEqual(
            Set(SessionContinuationPolicy.allCases.map(\.rawValue)),
            ["alwaysNew", "minutes15", "minutes30", "minutes60", "alwaysContinue"]
        )
        XCTAssertEqual(SessionContinuationPolicy.allCases.count, 5)
    }

    func testSessionContinuationPolicyTTLSecondsMapping() {
        // The two extremes are nil (handled by branch, not arithmetic — see the
        // source type-level note); the timed cases pin exact second windows.
        XCTAssertNil(SessionContinuationPolicy.alwaysNew.ttlSeconds)
        XCTAssertNil(SessionContinuationPolicy.alwaysContinue.ttlSeconds)
        XCTAssertEqual(SessionContinuationPolicy.minutes15.ttlSeconds, 900)
        XCTAssertEqual(SessionContinuationPolicy.minutes30.ttlSeconds, 1800)
        XCTAssertEqual(SessionContinuationPolicy.minutes60.ttlSeconds, 3600)
    }

    // MARK: - MenuBarInputMode

    func testMenuBarInputModeRawValuesLocked() {
        XCTAssertEqual(MenuBarInputMode.voice.rawValue, "voice")
        XCTAssertEqual(MenuBarInputMode.text.rawValue, "text")
        XCTAssertEqual(Set(MenuBarInputMode.allCases.map(\.rawValue)), ["voice", "text"])
    }

    // MARK: - ImageHistoryPolicy

    func testImageHistoryPolicyRawValuesLocked() {
        XCTAssertEqual(ImageHistoryPolicy.recent.rawValue, "recent")
        XCTAssertEqual(ImageHistoryPolicy.extended.rawValue, "extended")
        XCTAssertEqual(ImageHistoryPolicy.all.rawValue, "all")
        XCTAssertEqual(Set(ImageHistoryPolicy.allCases.map(\.rawValue)),
                       ["recent", "extended", "all"])
    }

    func testImageHistoryPolicyFromRawValueTolerantDefault() {
        // Exact-match raws parse to their case.
        XCTAssertEqual(ImageHistoryPolicy.from(rawValue: "recent"), .recent)
        XCTAssertEqual(ImageHistoryPolicy.from(rawValue: "extended"), .extended)
        XCTAssertEqual(ImageHistoryPolicy.from(rawValue: "all"), .all)

        // nil / unrecognized → .default (.recent) — forward-compat fail-safe.
        XCTAssertEqual(ImageHistoryPolicy.from(rawValue: nil), .recent)
        XCTAssertEqual(ImageHistoryPolicy.from(rawValue: "future-level"), .recent)
        XCTAssertEqual(ImageHistoryPolicy.from(rawValue: ""), .recent)
        XCTAssertEqual(ImageHistoryPolicy.default, .recent)
    }

    func testImageHistoryPolicyInlineWindowValues() {
        // recent = 3, extended = 10, all = nil (unlimited). Pinned to literals;
        // these gate prior-turn inline-image cost.
        XCTAssertEqual(ImageHistoryPolicy.recent.inlineWindow, 3)
        XCTAssertEqual(ImageHistoryPolicy.extended.inlineWindow, 10)
        XCTAssertNil(ImageHistoryPolicy.all.inlineWindow)
    }

    func testImageHistoryPolicyOrphanInlineWindowValues() {
        // Both finite levels share the orphan grace window (Constants
        // .imageOrphanInlineWindow == 10); .all never expires (nil).
        XCTAssertEqual(ImageHistoryPolicy.recent.orphanInlineWindow, 10)
        XCTAssertEqual(ImageHistoryPolicy.extended.orphanInlineWindow, 10)
        XCTAssertNil(ImageHistoryPolicy.all.orphanInlineWindow)
    }
}

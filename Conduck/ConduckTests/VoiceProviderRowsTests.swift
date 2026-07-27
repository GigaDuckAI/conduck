// SPDX-License-Identifier: Apache-2.0

// Conduck
// VoiceProviderRowsTests.swift
//
// Cloud Text-to-Speech — the merged "Voice" row derivation
// (`SettingsViewModel.voiceProviderRows`). Drives the `@MainActor` view-model
// directly via its already-loaded observable snapshots (storedPresetIDs /
// activePresetID / activeTTSProviderID) — NO Keychain, NO actor hop in the
// derivation under test (the whole point: the SwiftUI `body` must do none).
//
// Covers the two load-bearing invariants:
//   1. A SHARED key flips BOTH the STT and TTS "configured" pills (one slot,
//      both directions).
//   2. The STT-active and TTS-active pointers are INDEPENDENT (a vendor can be
//      active for one direction, the other, both, or neither).

import XCTest
@testable import Conduck

@MainActor
final class VoiceProviderRowsTests: XCTestCase {

    /// A single named custom endpoint seeded into every VM so the dynamic
    /// custom row renders (Phase B). Tests that exercise the custom row use its
    /// `custom_<uuid>` vendor id.
    private let customEndpoint = CustomVoiceEndpoint(id: UUID(), name: "Whisper box")
    private var customVendorID: String { "custom_" + customEndpoint.id.uuidString.lowercased() }
    private var customPresetID: String { STTProvider.customEndpointID(for: customEndpoint.id) }

    /// Build a VM and seed only the snapshots the derivation reads. We do NOT
    /// call `loadSettings()` (which would hit the actor + Keychain) — the
    /// derivation is pure over these observable fields. The custom endpoint is
    /// always seeded into the roster so the dynamic custom row renders.
    private func makeViewModel(
        storedPresetIDs: Set<String>,
        activeSTT: String,
        activeTTS: String
    ) -> SettingsViewModel {
        let vm = SettingsViewModel()
        vm.storedPresetIDs = storedPresetIDs
        vm.activePresetID = activeSTT
        vm.activeTTSProviderID = activeTTS
        vm.customVoiceEndpoints = [customEndpoint]
        return vm
    }

    private func row(_ vm: SettingsViewModel, _ vendorID: String) -> VoiceProviderRow? {
        vm.voiceProviderRows.first(where: { $0.vendorID == vendorID })
    }

    func testRowOrderIsAppleFirst() {
        let vm = makeViewModel(storedPresetIDs: [], activeSTT: "apple-on-device", activeTTS: "apple-tts")
        XCTAssertEqual(vm.voiceProviderRows.first?.vendorID, "apple")
        // 6 built-ins (Apple + 5 cloud: OpenAI, Mistral, ElevenLabs, Gemini,
        // OpenRouter — Qwen unlisted) + 1 seeded custom endpoint = 7.
        XCTAssertEqual(vm.voiceProviderRows.count, 7)
        // Pin the built-in vendor composition (the trailing row is the seeded
        // custom endpoint): a built-in vendor add/remove must be an intentional
        // edit here. A set tolerates middle-order churn while locking membership.
        XCTAssertEqual(
            Set(vm.voiceProviderRows.dropLast().map(\.vendorID)),
            ["apple", "openai", "mistral", "elevenlabs", "gemini", "openrouter"],
            "Built-in voice vendors are LOCKED (incl. OpenRouter)."
        )
        XCTAssertEqual(vm.voiceProviderRows.last?.vendorID, customVendorID,
                       "The custom endpoint row renders last, after the built-ins.")
    }

    /// A SHARED key flips BOTH pills: storing the OpenAI key (one slot) marks
    /// the OpenAI vendor configured for STT AND TTS.
    func testSharedKeyFlipsBothConfiguredPills() {
        let vm = makeViewModel(
            storedPresetIDs: ["openai-gpt4o-transcribe"],
            activeSTT: "apple-on-device",
            activeTTS: "apple-tts"
        )
        let openai = try! XCTUnwrap(row(vm, "openai"))
        XCTAssertTrue(openai.sttConfigured, "Stored shared key → STT configured.")
        XCTAssertTrue(openai.ttsConfigured, "The SAME stored key → TTS configured (shared slot).")
        XCTAssertFalse(openai.sttActive, "Active STT is Apple here.")
        XCTAssertFalse(openai.ttsActive, "Active TTS is Apple here.")
    }

    /// The two active pointers are INDEPENDENT: OpenAI active for STT while
    /// ElevenLabs active for TTS — each pill reflects its own pointer.
    func testTwoIndependentActivePointers() {
        let vm = makeViewModel(
            storedPresetIDs: ["openai-gpt4o-transcribe", "elevenlabs-scribe-v2"],
            activeSTT: "openai-gpt4o-transcribe",
            activeTTS: "elevenlabs-tts"
        )
        let openai = try! XCTUnwrap(row(vm, "openai"))
        let eleven = try! XCTUnwrap(row(vm, "elevenlabs"))

        XCTAssertTrue(openai.sttActive, "OpenAI is the active STT provider.")
        XCTAssertFalse(openai.ttsActive, "OpenAI is NOT the active TTS provider.")

        XCTAssertTrue(eleven.ttsActive, "ElevenLabs is the active TTS provider.")
        XCTAssertFalse(eleven.sttActive, "ElevenLabs is NOT the active STT provider.")

        // Both configured (each has its own shared key stored).
        XCTAssertTrue(openai.sttConfigured && openai.ttsConfigured)
        XCTAssertTrue(eleven.sttConfigured && eleven.ttsConfigured)
    }

    /// Gemini ships BOTH directions on one key: with the shared Gemini key
    /// stored, the row reports STT + TTS configured, and its TTS direction is
    /// `.available` (TTS via `gemini-3.1-flash-tts-preview`).
    func testGeminiTTSConfiguredWithSharedKey() {
        let vm = makeViewModel(
            storedPresetIDs: ["gemini-3-1-flash-lite"],
            activeSTT: "apple-on-device",
            activeTTS: "apple-tts"
        )
        let gemini = try! XCTUnwrap(row(vm, "gemini"))
        XCTAssertTrue(gemini.sttConfigured, "Gemini STT is configured with its key.")
        XCTAssertTrue(gemini.ttsConfigured, "Gemini TTS reads the SAME shared key → configured.")
        XCTAssertTrue(gemini.ttsAvailable, "Gemini TTS is shipped (`.available`).")
    }

    /// The custom BYO endpoint exposes a TTS direction (shared server).
    func testCustomTTSIsAvailable() {
        let vm = makeViewModel(storedPresetIDs: [], activeSTT: "apple-on-device", activeTTS: "apple-tts")
        let custom = try! XCTUnwrap(row(vm, customVendorID))
        XCTAssertTrue(custom.ttsAvailable, "Custom endpoint serves TTS via /v1/audio/speech.")
    }

    /// The custom endpoint's readiness flips BOTH pills together: STT-configured
    /// for a custom row reads `isCustomSTTReady(for:)` (URL + key/keyless), and
    /// the TTS pill derives from the same signal. Seed a ready endpoint (URL +
    /// masked key) and assert both pills are TRUE and track together.
    func testCustomReadyFlipsBothPillsTogether() {
        let vm = makeViewModel(
            storedPresetIDs: [customPresetID],
            activeSTT: "apple-on-device",
            activeTTS: "apple-tts"
        )
        // Make the endpoint READY: stored URL + masked key tail.
        vm.customSTTURLStrings[customEndpoint.id] = "https://whisper.example.test"
        vm.customSTTMaskedTails[customEndpoint.id] = "••••wxyz"
        let custom = try! XCTUnwrap(row(vm, customVendorID))
        XCTAssertTrue(custom.sttConfigured, "A ready custom endpoint (URL + key) is STT-configured.")
        XCTAssertEqual(custom.ttsConfigured, custom.sttConfigured,
                       "Custom STT and TTS configured pills must track together (shared key + endpoint).")
    }

    /// A custom endpoint with a key but NO URL is NOT configured (readiness gates
    /// on the URL, unlike the stored-key cloud path).
    func testCustomKeyWithoutURLIsNotConfigured() {
        let vm = makeViewModel(storedPresetIDs: [], activeSTT: "apple-on-device", activeTTS: "apple-tts")
        vm.customSTTMaskedTails[customEndpoint.id] = "••••wxyz"   // key, but no URL
        let custom = try! XCTUnwrap(row(vm, customVendorID))
        XCTAssertFalse(custom.sttConfigured, "A custom endpoint needs a URL too — a key alone is not configured.")
        XCTAssertFalse(custom.ttsConfigured)
    }

    /// Apple is active for both directions on a fresh install (the defaults).
    func testAppleActiveForBothOnDefaults() {
        let vm = makeViewModel(storedPresetIDs: [], activeSTT: "apple-on-device", activeTTS: "apple-tts")
        let apple = try! XCTUnwrap(row(vm, "apple"))
        XCTAssertTrue(apple.sttActive)
        XCTAssertTrue(apple.ttsActive)
        XCTAssertTrue(apple.ttsAvailable)
    }
}

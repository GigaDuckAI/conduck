// Conduck
// STTBroadcastEnvelopeTests.swift
//
// Covers the WCSession
// atomic-state envelope: dict round-trip, defensive decode (missing /
// wrong-type fields → nil), and the monotonic-timestamp comparison
// primitive the Watch uses to discard older envelopes.

import XCTest
@testable import Conduck

final class STTBroadcastEnvelopeTests: XCTestCase {

    func testEnvelopeEncodeDictRoundTrip() {
        let original = STTBroadcastEnvelope(
            presetID: "openai-gpt4o-transcribe",
            apiKey: "sk-test",
            timestamp: 12345.6
        )

        let dict = original.encodedDict()
        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("decode(from:) returned nil for valid dict")
            return
        }

        XCTAssertEqual(decoded.presetID, original.presetID)
        XCTAssertEqual(decoded.apiKey, original.apiKey)
        XCTAssertEqual(decoded.timestamp, original.timestamp, accuracy: 0.0001)
    }

    func testEnvelopeDecodeRejectsMissingFields() {
        // `apiKey` is optional in the wire schema (keyless
        // providers like Apple on-device broadcast no `"apiKey"` key).
        // Required fields are presetID + timestamp; missing those still
        // yields nil. The "presetID + apiKey, no timestamp" case stays
        // a hard reject because timestamp drives the Watch's monotonic
        // discard logic.
        XCTAssertNil(STTBroadcastEnvelope.decode(from: [:]),
                     "Empty dict must yield nil (defensive — receiver treats as 'ignore envelope').")
        XCTAssertNil(STTBroadcastEnvelope.decode(from: ["presetID": "x"]),
                     "Missing timestamp must yield nil.")
        XCTAssertNil(STTBroadcastEnvelope.decode(from: ["presetID": "x", "apiKey": "y"]),
                     "Missing timestamp must yield nil even when apiKey is present.")
    }

    func testEnvelopeDecodeRejectsWrongTypes() {
        // presetID must be String, not Int
        let dict: [String: Any] = [
            "presetID": 42,
            "apiKey": "x",
            "timestamp": 0.0,
        ]
        XCTAssertNil(STTBroadcastEnvelope.decode(from: dict),
                     "Wrong-typed presetID must yield nil rather than crash.")
    }

    func testEnvelopeTimestampMonotonicOrdering() {
        let older = STTBroadcastEnvelope(presetID: "a", apiKey: "k", timestamp: 100.0)
        let newer = STTBroadcastEnvelope(presetID: "b", apiKey: "k", timestamp: 200.0)

        XCTAssertLessThan(older.timestamp, newer.timestamp,
                          "Watch uses `timestamp <= lastEnvelopeTimestamp` to discard out-of-order drains; ordering primitive must work.")
    }

    // MARK: - nullable apiKey for keyless providers

    func testEnvelopeWithNilAPIKeyOmitsKeyInDict() {
        // Keyless providers (Apple on-device) MUST broadcast with no
        // `"apiKey"` key in the dict — an empty-string sentinel would
        // round-trip as `Optional.some("")` rather than `nil` and drift
        // the keyless detection on the Watch side.
        let envelope = STTBroadcastEnvelope(
            presetID: "apple-on-device",
            apiKey: nil,
            timestamp: 1.0
        )
        let dict = envelope.encodedDict()
        XCTAssertNil(dict["apiKey"],
                     "Nil-apiKey envelopes must omit the `\"apiKey\"` key entirely from the dict.")
        XCTAssertEqual(dict["presetID"] as? String, "apple-on-device")
        XCTAssertEqual(dict["timestamp"] as? TimeInterval, 1.0)
    }

    func testEnvelopeWithNilAPIKeyRoundTrips() {
        let original = STTBroadcastEnvelope(
            presetID: "apple-on-device",
            apiKey: nil,
            timestamp: 42.5
        )
        let dict = original.encodedDict()
        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("Nil-apiKey envelope must decode successfully — presetID + timestamp are present.")
            return
        }
        XCTAssertEqual(decoded.presetID, "apple-on-device")
        XCTAssertNil(decoded.apiKey, "Round-tripped apiKey must remain nil, NOT promote to empty string.")
        XCTAssertEqual(decoded.timestamp, 42.5, accuracy: 0.0001)
    }

    func testEnvelopeDecodeFromDictWithoutAPIKeyYieldsNilAPIKey() {
        // Forward-compat: a dict shipped from an iOS 26+ device with a
        // keyless provider active arrives on a Watch with no `"apiKey"`
        // entry. Decode must succeed (presetID + timestamp present) and
        // yield `apiKey == nil`.
        let dict: [String: Any] = [
            "presetID": "apple-on-device",
            "timestamp": 7.0,
        ]
        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("Envelope with no `apiKey` key must still decode.")
            return
        }
        XCTAssertEqual(decoded.presetID, "apple-on-device")
        XCTAssertNil(decoded.apiKey)
        XCTAssertEqual(decoded.timestamp, 7.0, accuracy: 0.0001)
    }

    func testEnvelopeDecodeWithStringAPIKeyYieldsNonNilAPIKey() {
        // Back-compat: existing cloud providers continue to broadcast
        // an `"apiKey"` key with a String value; decode must round-trip
        // unchanged.
        let dict: [String: Any] = [
            "presetID": "mistral-voxtral",
            "apiKey": "sk-cloud-key",
            "timestamp": 9.0,
        ]
        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("Cloud-provider envelope (with apiKey String) must decode.")
            return
        }
        XCTAssertEqual(decoded.apiKey, "sk-cloud-key")
    }

    // MARK: - Custom-STT V1.x — Feature 1 customModel field

    /// A per-provider custom model override rides the envelope to the Watch so
    /// the wrist resolves `provider.effectiveModel(customModel:)` against the
    /// SAME override the iPhone uses. Must round-trip through the dict.
    func testEnvelopeCustomModelRoundTrips() {
        let original = STTBroadcastEnvelope(
            presetID: "qwen3-asr-flash",
            apiKey: "sk-qwen",
            customModel: "qwen3-asr-realtime",
            timestamp: 11.0
        )
        let dict = original.encodedDict()
        XCTAssertEqual(dict["customModel"] as? String, "qwen3-asr-realtime",
                       "A non-nil customModel must be present in the encoded dict.")

        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("Envelope with a customModel must decode (presetID + timestamp present).")
            return
        }
        XCTAssertEqual(decoded.customModel, "qwen3-asr-realtime",
                       "Round-tripped customModel must survive unchanged.")
        XCTAssertEqual(decoded.presetID, "qwen3-asr-flash")
        XCTAssertEqual(decoded.apiKey, "sk-qwen")
    }

    /// Nil customModel (no override) MUST omit the `"customModel"` key entirely
    /// — an empty-string sentinel would round-trip as `Optional.some("")` and
    /// pin the Watch to an invalid empty model. Forward/back-compat: an older
    /// Watch decode that never reads the key is unaffected.
    func testEnvelopeNilCustomModelOmitsKeyInDict() {
        let envelope = STTBroadcastEnvelope(
            presetID: "mistral-voxtral",
            apiKey: "sk-test",
            customModel: nil,
            timestamp: 1.0
        )
        let dict = envelope.encodedDict()
        XCTAssertNil(dict["customModel"],
                     "Nil-customModel envelopes must OMIT the `\"customModel\"` key — no empty-string sentinel.")
    }

    /// The pre-existing 3-arg construction (presetID/apiKey/timestamp, no
    /// customModel) must still compile and default customModel to nil — proving
    /// the new field is additive and won't break the persisted v1 wire shape.
    func testEnvelopeWithoutCustomModelArgDefaultsToNil() {
        let envelope = STTBroadcastEnvelope(
            presetID: "openai-gpt4o-transcribe",
            apiKey: "sk-test",
            timestamp: 2.0
        )
        XCTAssertNil(envelope.customModel,
                     "The additive customModel field must default to nil when the legacy 3-arg init is used.")
        XCTAssertNil(envelope.encodedDict()["customModel"],
                     "A default-nil customModel must omit the dict key (forward-compat with older Watch decoders).")
    }

    /// Forward-compat: a dict from an older iOS build carries no `"customModel"`
    /// key. Decode must succeed and yield `customModel == nil` (NOT crash, NOT
    /// promote to empty string).
    func testEnvelopeDecodeWithoutCustomModelYieldsNil() {
        let dict: [String: Any] = [
            "presetID": "mistral-voxtral",
            "apiKey": "sk-cloud-key",
            "timestamp": 3.0,
        ]
        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("Envelope with no customModel key must still decode.")
            return
        }
        XCTAssertNil(decoded.customModel,
                     "Missing customModel key must decode to nil (tolerant optional).")
    }

    // MARK: - cloud TTS — ttsProviderID / ttsApiKey / ttsVoice fields

    /// The active TTS triple rides the SAME envelope as the STT triple so the
    /// Watch sees a coherent snapshot. All three must round-trip through the dict.
    func testEnvelopeTTSFieldsRoundTrip() {
        let original = STTBroadcastEnvelope(
            presetID: "apple-on-device",
            apiKey: nil,
            customModel: nil,
            ttsProviderID: "openai-tts",
            ttsApiKey: "sk-tts-shared",
            ttsVoice: "nova",
            timestamp: 21.0
        )
        let dict = original.encodedDict()
        XCTAssertEqual(dict["ttsProviderID"] as? String, "openai-tts")
        XCTAssertEqual(dict["ttsApiKey"] as? String, "sk-tts-shared")
        XCTAssertEqual(dict["ttsVoice"] as? String, "nova")

        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("Envelope with TTS fields must decode (presetID + timestamp present).")
            return
        }
        XCTAssertEqual(decoded.ttsProviderID, "openai-tts")
        XCTAssertEqual(decoded.ttsApiKey, "sk-tts-shared")
        XCTAssertEqual(decoded.ttsVoice, "nova")
        XCTAssertEqual(decoded.presetID, "apple-on-device")
    }

    /// Nil TTS fields (no active cloud TTS / keyless Apple / no voice override)
    /// MUST omit the keys entirely — same omit-when-nil pattern as customModel,
    /// so a legacy Watch decode is unaffected + no empty-string sentinel.
    func testEnvelopeNilTTSFieldsOmitKeysInDict() {
        let envelope = STTBroadcastEnvelope(
            presetID: "mistral-voxtral",
            apiKey: "sk-stt",
            ttsProviderID: "apple-tts",
            ttsApiKey: nil,
            ttsVoice: nil,
            timestamp: 1.0
        )
        let dict = envelope.encodedDict()
        XCTAssertEqual(dict["ttsProviderID"] as? String, "apple-tts",
                       "A present ttsProviderID must encode.")
        XCTAssertNil(dict["ttsApiKey"], "Nil ttsApiKey must OMIT the key (keyless Apple TTS).")
        XCTAssertNil(dict["ttsVoice"], "Nil ttsVoice must OMIT the key (no override).")
    }

    /// The pre-TTS construction (no TTS args) must still compile and default all
    /// three TTS fields to nil — proving the new fields are additive and don't
    /// break the persisted wire shape.
    func testEnvelopeWithoutTTSArgsDefaultsToNil() {
        let envelope = STTBroadcastEnvelope(
            presetID: "openai-gpt4o-transcribe",
            apiKey: "sk-test",
            timestamp: 2.0
        )
        XCTAssertNil(envelope.ttsProviderID)
        XCTAssertNil(envelope.ttsApiKey)
        XCTAssertNil(envelope.ttsVoice)
        let dict = envelope.encodedDict()
        XCTAssertNil(dict["ttsProviderID"])
        XCTAssertNil(dict["ttsApiKey"])
        XCTAssertNil(dict["ttsVoice"])
    }

    /// Back-compat: a LEGACY dict (no TTS keys at all — shipped by a pre-TTS iOS
    /// build) must decode fine with all three TTS fields nil. This is the
    /// load-bearing "older sender → newer receiver" case.
    func testEnvelopeDecodeLegacyDictWithoutTTSKeysYieldsNilTTSFields() {
        let dict: [String: Any] = [
            "presetID": "mistral-voxtral",
            "apiKey": "sk-cloud-key",
            "customModel": "voxtral-mini-latest",
            "timestamp": 5.0,
        ]
        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("Legacy dict (no TTS keys) must still decode.")
            return
        }
        XCTAssertEqual(decoded.presetID, "mistral-voxtral")
        XCTAssertEqual(decoded.apiKey, "sk-cloud-key")
        XCTAssertEqual(decoded.customModel, "voxtral-mini-latest")
        XCTAssertNil(decoded.ttsProviderID, "Legacy dict → ttsProviderID nil (Watch falls back to default).")
        XCTAssertNil(decoded.ttsApiKey)
        XCTAssertNil(decoded.ttsVoice)
    }

    /// Wrong-typed TTS fields must degrade to nil, not fail the whole decode
    /// (tolerant `as? String`).
    func testEnvelopeDecodeWrongTypedTTSFieldsYieldNil() {
        let dict: [String: Any] = [
            "presetID": "openai-gpt4o-transcribe",
            "apiKey": "sk",
            "ttsProviderID": 99,        // wrong type
            "ttsApiKey": ["x"],          // wrong type
            "timestamp": 6.0,
        ]
        guard let decoded = STTBroadcastEnvelope.decode(from: dict) else {
            XCTFail("Wrong-typed TTS fields must NOT fail the whole decode.")
            return
        }
        XCTAssertNil(decoded.ttsProviderID)
        XCTAssertNil(decoded.ttsApiKey)
    }
}

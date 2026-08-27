// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTBackgroundMetadataAndAuthTests.swift
//
// Locks three STT wire-contract invariants that the multi-provider STT stack
// depends on, against the EXACT current source shapes:
//
//   1. `STTBackgroundTaskMetadata` Codable recovery — the cross-launch envelope
//      stored in `URLSessionTask.taskDescription`. The whole reason it is
//      JSON-over-`taskDescription` (not delimiter-packed) is that audio paths
//      can contain `|`; this pins that a `|`-bearing path survives a round-trip,
//      AND that an OLDER encoded form lacking `pinnedFingerprintHex` decodes
//      with that field == nil (tolerant-optional) instead of throwing.
//   2. `STTAuthScheme.apply(to:apiKey:)` header behavior — `.none` writes NO
//      auth header at all, `.bearer` writes `Authorization: Bearer <key>`, and
//      `.headerName` writes the key verbatim under the named (lowercase-spec)
//      header. Vendor-mandated header names must not be title-cased.
//   3. `STTProvider.withCustom(id:dynamicEndpointKey:)` synthesis — the per-uuid
//      custom provider overrides ONLY `id` + `dynamicEndpointKey`; every other
//      field rides through unchanged from the `customOpenAICompat` template.
//      Also pins `customEndpointID(for:)` lowercasing of the uuid.
//
// All deterministic + headless — no network, no Keychain, no Core Data.

import XCTest
@testable import Conduck

final class STTBackgroundMetadataAndAuthTests: XCTestCase {

    // A fixed uuid so the per-endpoint id / lowercasing assertion is reproducible.
    private let fixedUUID = UUID(uuidString: "8E4E2D0A-1B7C-4F4E-9D1A-2C3B4A5D6E7F")!

    // MARK: - STTBackgroundTaskMetadata round-trip

    /// Encode → decode preserves all three fields, including a path that
    /// contains the `|` character (the exact case the JSON-over-`taskDescription`
    /// choice exists to survive — a delimiter-packed encoding would split here).
    func testMetadataRoundTripPreservesAllFieldsIncludingPipeInPath() throws {
        let original = STTBackgroundTaskMetadata(
            audioPath: "/var/mobile/Containers/Data/audio|clip|01.m4a",
            providerID: "custom-openai",
            pinnedFingerprintHex: "aa11bb22cc33"
        )

        let encoded = try original.encodedString()
        let decoded = try STTBackgroundTaskMetadata.decode(encoded)

        XCTAssertEqual(decoded.audioPath, "/var/mobile/Containers/Data/audio|clip|01.m4a",
                       "A `|`-bearing audio path must survive the JSON round-trip verbatim.")
        XCTAssertEqual(decoded.providerID, "custom-openai")
        XCTAssertEqual(decoded.pinnedFingerprintHex, "aa11bb22cc33")
    }

    /// An OLDER encoded `taskDescription` JSON that predates the
    /// `pinnedFingerprintHex` field must decode WITHOUT throwing, with the field
    /// recovered as nil (tolerant-optional via synthesized Codable). Constructed
    /// as a literal legacy JSON object — NOT re-encoded from the current type.
    func testLegacyMetadataWithoutPinnedFingerprintDecodesAsNil() throws {
        let legacyJSON = #"{"audioPath":"/tmp/legacy.m4a","providerID":"mistral-voxtral"}"#

        let decoded = try STTBackgroundTaskMetadata.decode(legacyJSON)

        XCTAssertEqual(decoded.audioPath, "/tmp/legacy.m4a")
        XCTAssertEqual(decoded.providerID, "mistral-voxtral")
        XCTAssertNil(decoded.pinnedFingerprintHex,
                     "A legacy envelope without the key must decode as nil, never throw (additive optional).")
    }

    // MARK: - STTAuthScheme.apply(to:apiKey:)

    /// `.none` is a no-op — neither an `Authorization` header nor any other
    /// auth header is written. Asserts the header is ABSENT (not merely empty).
    func testAuthSchemeNoneWritesNoHeader() {
        var request = URLRequest(url: URL(string: "https://example.test/v1/audio/transcriptions")!)
        STTAuthScheme.none.apply(to: &request, apiKey: "ignored-key")

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     ".none must not write an Authorization header.")
        // No stray headers of any kind from a no-op scheme.
        XCTAssertNil(request.allHTTPHeaderFields,
                     ".none must leave the request's header set untouched (nil).")
    }

    /// `.bearer` writes `Authorization: Bearer <key>` verbatim.
    func testAuthSchemeBearerWritesAuthorizationBearerHeader() {
        var request = URLRequest(url: URL(string: "https://example.test/v1/audio/transcriptions")!)
        STTAuthScheme.bearer.apply(to: &request, apiKey: "sk-test-123")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
    }

    /// `.headerName` writes the key verbatim under the named header, leaving the
    /// header name exactly as supplied (vendor-mandated lowercase preserved) and
    /// writing NO `Authorization` header.
    func testAuthSchemeHeaderNameWritesKeyUnderNamedHeader() {
        var request = URLRequest(url: URL(string: "https://example.test/v1/speech-to-text")!)
        STTAuthScheme.headerName("xi-api-key").apply(to: &request, apiKey: "el-secret-xyz")

        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-secret-xyz",
                       "The key must ride under the exact named header.")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     ".headerName must not also write an Authorization header.")
    }

    // MARK: - STTProvider.withCustom(id:dynamicEndpointKey:)

    /// Synthesizing a per-uuid custom provider overrides ONLY `id` and
    /// `dynamicEndpointKey`; every other wire-shape field must ride through
    /// unchanged from the `customOpenAICompat` template.
    func testWithCustomCarriesEveryNonIDNonKeyFieldFromTemplate() {
        let template = STTProvider.customOpenAICompat
        let newID = "custom-openai_\(fixedUUID.uuidString.lowercased())"
        let newKey = "stt.custom.url.\(fixedUUID.uuidString.lowercased())"

        let synth = template.withCustom(id: newID, dynamicEndpointKey: newKey)

        // The two overridden fields.
        XCTAssertEqual(synth.id, newID)
        XCTAssertEqual(synth.dynamicEndpointKey, newKey)

        // Everything else rides through unchanged from the template.
        XCTAssertEqual(synth.transcribeURL, template.transcribeURL)
        XCTAssertEqual(synth.probeURL, template.probeURL)
        XCTAssertEqual(synth.model, template.model)
        XCTAssertEqual(synth.auth, template.auth)                       // STTAuthScheme: Equatable
        XCTAssertEqual(synth.transport, template.transport)            // Transport: Equatable
        XCTAssertEqual(synth.maxAudioBytes, template.maxAudioBytes)
        XCTAssertEqual(synth.maxAudioSeconds, template.maxAudioSeconds)
        XCTAssertEqual(synth.multipartFieldNames, template.multipartFieldNames) // Equatable
        XCTAssertEqual(synth.responseShape, template.responseShape)            // Equatable

        // Metatype fields — assert nil for this template (JSON/in-process families
        // are unused by the OpenAI-compatible multipart custom endpoint).
        XCTAssertNil(synth.jsonBodyFactory, "Custom OpenAI-compatible endpoint is multipart — no JSON body factory.")
        XCTAssertNil(synth.inProcessRunner, "Custom endpoint is a network provider — no in-process runner.")

        // `STTStatusMap` is NOT Equatable (it wraps an Error-returning closure),
        // so pin it by BEHAVIOR: the template uses `.openAICompat`, whose 429 is a
        // transient rate-limit (`.sttTooManyRequests`) — distinct from the
        // billing-fatal `.sttQuotaExceeded` that Mistral/Gemini map 429 to. This
        // catches a status-map swap that an identity check could not.
        guard case .sttTooManyRequests = synth.statusMap.map(429, nil) else {
            return XCTFail("Synthesized provider must carry the openAICompat status map (429 → sttTooManyRequests).")
        }
        XCTAssertNil(synth.statusMap.map(200, nil), "2xx must map to no error.")
    }

    /// `customEndpointID(for:)` builds `custom-openai_<uuid-lowercased>`. Pins
    /// the locked prefix literal AND the lowercasing of the uuid (the fixed uuid
    /// is upper-cased in its source literal; the id must be all-lowercase tail).
    func testCustomEndpointIDLowercasesUUIDWithLockedPrefix() {
        let id = STTProvider.customEndpointID(for: fixedUUID)

        XCTAssertEqual(id, "custom-openai_8e4e2d0a-1b7c-4f4e-9d1a-2c3b4a5d6e7f",
                       "Per-endpoint STT id is the locked `custom-openai_` prefix + lowercased uuid.")
    }
}

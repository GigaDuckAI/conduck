// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract tests.
//
// Locks the `WatchTTSClient` glue that ConduckTests cannot see (the enum is a
// Watch-target-only member; its composed layers — body factories, status maps,
// the shared `decodeAudio` chokepoint — are already covered on the fast iOS
// suite). Three contracts, all network-free:
//   1. Apple-sentinel refusal — `apple-tts` (nil `bodyFactory`) must throw
//      `ttsSynthesisFailed` before any request is built (the sentinel is
//      played on-device; reaching the client is a routing regression).
//   2. BYO-endpoint refusal — any `dynamicEndpointKey != nil` provider must
//      throw `ttsCustomEndpointNotConfigured` (Watch custom TTS is
//      iOS/macOS-only; a registry change must not route wrist TTS to an
//      unreachable/wrong endpoint).
//   3. `mapTransportError` — the pure URLError → AppError mapping, mirroring
//      the iOS `TTSClient` contract (TTSClientTests' transport cases) so the
//      surfaced cause can't drift between surfaces.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchTTSClientGuardTests: XCTestCase {

    // MARK: - Guard clauses (throw before any network use)

    func testAppleSentinelThrowsSynthesisFailed() async {
        do {
            _ = try await WatchTTSClient.synthesize(
                text: "x", provider: .appleTTS, voice: nil, apiKey: "key"
            )
            XCTFail("Expected ttsSynthesisFailed for the Apple sentinel")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsSynthesisFailed.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(type(of: error))")
        }
    }

    func testDynamicEndpointProviderThrowsCustomEndpointNotConfigured() async {
        // A synthesized per-uuid custom TTS provider — the shape the phone can
        // broadcast as the active provider after a registry/settings change.
        let provider = TTSProvider.lookup(id: TTSProvider.customEndpointID(for: UUID()))
        XCTAssertNotNil(provider.dynamicEndpointKey,
                        "Precondition: the synthesized custom provider is dynamic-endpoint.")
        do {
            _ = try await WatchTTSClient.synthesize(
                text: "x", provider: provider, voice: nil, apiKey: "key"
            )
            XCTFail("Expected ttsCustomEndpointNotConfigured for a BYO endpoint on the wrist")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsCustomEndpointNotConfigured.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(type(of: error))")
        }
    }

    func testLegacyCustomProviderAlsoRefused() async {
        // The bare legacy `custom-openai-tts` singleton carries a
        // `dynamicEndpointKey` too — same wrist refusal.
        do {
            _ = try await WatchTTSClient.synthesize(
                text: "x", provider: .customOpenAITTS, voice: nil, apiKey: "key"
            )
            XCTFail("Expected ttsCustomEndpointNotConfigured for the legacy custom provider")
        } catch let e as AppError {
            XCTAssertEqual(e.errorCode, AppError.ttsCustomEndpointNotConfigured.errorCode)
        } catch {
            XCTFail("Expected AppError, got \(type(of: error))")
        }
    }

    // MARK: - Transport error mapping (pure)

    /// Mirrors TTSClientTests' transport cases: `.timedOut` → `requestTimeout`
    /// (the watchdog/fallback forensics must name a timeout as a timeout),
    /// offline codes → `noInternetConnection`, everything else → the generic
    /// `ttsProviderUnreachable`.
    func testMapTransportErrorContract() {
        XCTAssertEqual(WatchTTSClient.mapTransportError(URLError(.timedOut)).errorCode,
                       AppError.requestTimeout.errorCode)
        XCTAssertEqual(WatchTTSClient.mapTransportError(URLError(.notConnectedToInternet)).errorCode,
                       AppError.noInternetConnection.errorCode)
        XCTAssertEqual(WatchTTSClient.mapTransportError(URLError(.networkConnectionLost)).errorCode,
                       AppError.noInternetConnection.errorCode)
        XCTAssertEqual(WatchTTSClient.mapTransportError(URLError(.cannotConnectToHost)).errorCode,
                       AppError.ttsProviderUnreachable.errorCode)
        XCTAssertEqual(WatchTTSClient.mapTransportError(URLError(.dnsLookupFailed)).errorCode,
                       AppError.ttsProviderUnreachable.errorCode)
        XCTAssertEqual(WatchTTSClient.mapTransportError(URLError(.cancelled)).errorCode,
                       AppError.ttsProviderUnreachable.errorCode)
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// OpenRouterAttributionTests.swift
//
// Locks the OpenRouter app-attribution contract at the two auth seams every
// request builder routes through (`RemoteAgentAuthScheme.apply(to:token:)` and
// `STTAuthScheme.apply(to:apiKey:)`), because attribution is invisible in
// normal use: a dropped header does not fail a request, it just quietly stops
// OpenRouter attributing the traffic to Conduck's app page and rankings entry.
// Only a test notices.
//
// Two halves, and the second is the safety-critical one:
//
//   1. PRESENCE — a request bound for OpenRouter carries all three headers with
//      their exact values, under EVERY auth case (`.bearer` and keyless
//      `.none` alike), because attribution follows the destination host, not
//      the scheme. Auth itself must be unchanged by the addition.
//   2. CONFINEMENT — every OTHER destination carries none of them. The host
//      gate is exact-match, so a lookalike (`openrouter.ai.example.com`,
//      `notopenrouter.ai`) is somebody else's server and gets nothing, while a
//      differently-cased spelling of the real host still matches. This is what
//      keeps app identity off the user's own gateway and off non-OpenRouter
//      speech vendors.
//
// Plus a drift guard: the host the helper gates on must equal the host of the
// `.openrouter` descriptor's fixed endpoint, so changing the base URL can never
// silently unhook attribution from the endpoint actually being dialed.
//
// All deterministic + headless — no network, no Keychain, no stores.

import XCTest
@testable import Conduck

final class OpenRouterAttributionTests: XCTestCase {

    // Real OpenRouter destinations, composed the way the clients compose them.
    private let openRouterChatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let openRouterTranscribeURL = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!

    private let refererHeader = "HTTP-Referer"
    private let titleHeader = "X-OpenRouter-Title"
    private let categoriesHeader = "X-OpenRouter-Categories"

    /// All three attribution headers present with their exact expected values.
    private func assertAttributed(
        _ request: URLRequest,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(request.value(forHTTPHeaderField: refererHeader), "https://conduck.com",
                       "\(message): HTTP-Referer is REQUIRED — it is the app's identity on OpenRouter.",
                       file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: titleHeader), "Conduck",
                       "\(message): the title header carries the PRODUCT name.",
                       file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: categoriesHeader), "personal-agent,general-chat",
                       "\(message): categories must match OpenRouter's recognized vocabulary.",
                       file: file, line: line)
    }

    /// None of the three headers present — the confinement half.
    private func assertNotAttributed(
        _ request: URLRequest,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(request.value(forHTTPHeaderField: refererHeader),
                     "\(message): app identity must not reach a non-OpenRouter host.",
                     file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: titleHeader),
                     "\(message): app identity must not reach a non-OpenRouter host.",
                     file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: categoriesHeader),
                     "\(message): app identity must not reach a non-OpenRouter host.",
                     file: file, line: line)
    }

    // MARK: - Gateway seam — presence

    func testGatewayBearerToOpenRouterKeepsAuthAndAddsAllThreeHeaders() {
        var request = URLRequest(url: openRouterChatURL)
        RemoteAgentAuthScheme.bearer.apply(to: &request, token: "sk-or-test-123")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test-123",
                       "Attribution must not disturb the auth header it rides beside.")
        assertAttributed(request, "Bearer gateway request to OpenRouter")
    }

    func testGatewayKeylessToOpenRouterStillAttributedWithNoAuthHeader() {
        // Attribution is a property of the DESTINATION, not of the auth scheme:
        // a keyless request to OpenRouter is still a request to OpenRouter.
        var request = URLRequest(url: openRouterChatURL)
        RemoteAgentAuthScheme.none.apply(to: &request, token: "must-be-ignored")

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "Keyless (.none) must remain keyless — no Authorization header.")
        assertAttributed(request, "Keyless gateway request to OpenRouter")
    }

    // MARK: - Gateway seam — confinement

    func testGatewayRequestToUsersOwnServerCarriesNoAttribution() {
        var request = URLRequest(url: URL(string: "https://gateway.example.com/v1/chat/completions")!)
        RemoteAgentAuthScheme.bearer.apply(to: &request, token: "user-token")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token",
                       "The user's own gateway still authenticates normally.")
        assertNotAttributed(request, "Self-hosted gateway")
    }

    func testHostMatchIsCaseInsensitive() {
        var request = URLRequest(url: URL(string: "https://OpenRouter.AI/api/v1/models")!)
        RemoteAgentAuthScheme.bearer.apply(to: &request, token: "sk-or-test-123")

        assertAttributed(request, "Mixed-case spelling of the real OpenRouter host")
    }

    func testLookalikeHostsAreNotAttributed() {
        // The gate is EXACT equality, never a suffix match: both of these are
        // registrable by somebody else.
        for lookalike in ["https://openrouter.ai.example.com/api/v1/chat/completions",
                          "https://notopenrouter.ai/api/v1/chat/completions",
                          "https://evil-openrouter.ai/api/v1/chat/completions"] {
            var request = URLRequest(url: URL(string: lookalike)!)
            RemoteAgentAuthScheme.bearer.apply(to: &request, token: "sk-or-test-123")
            assertNotAttributed(request, "Lookalike host \(lookalike)")
        }
    }

    // MARK: - Voice seam

    func testSTTBearerToOpenRouterIsAttributed() {
        var request = URLRequest(url: openRouterTranscribeURL)
        STTAuthScheme.bearer.apply(to: &request, apiKey: "sk-or-voice-456")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-voice-456",
                       "The voice seam's own auth header must survive unchanged.")
        assertAttributed(request, "OpenRouter transcription request")
    }

    func testSTTHeaderNameSchemeToElevenLabsIsNotAttributed() {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        STTAuthScheme.headerName("xi-api-key").apply(to: &request, apiKey: "el-secret-xyz")

        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-secret-xyz",
                       "The vendor's own key header must survive unchanged.")
        assertNotAttributed(request, "ElevenLabs")
    }

    func testSTTNoneSchemeToNonOpenRouterHostStaysBare() {
        // `.none` is the in-process (Apple) scheme; a request that somehow
        // carries it must gain neither auth nor attribution off-host.
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/audio/transcriptions")!)
        STTAuthScheme.none.apply(to: &request, apiKey: "")

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     ".none must write no auth header.")
        assertNotAttributed(request, "Non-OpenRouter host under .none")
    }

    // MARK: - Header value contract

    func testCategoriesAreAtMostTwoRecognizedLowercaseTokens() {
        // OpenRouter accepts at most TWO categories per request and drops what
        // it does not recognize — a third token would be silently discarded, so
        // the cap is pinned here rather than discovered on their dashboard.
        let tokens = Constants.openRouterAttributionCategories.split(separator: ",").map(String.init)

        XCTAssertLessThanOrEqual(tokens.count, 2,
                                 "OpenRouter honors at most two categories per request.")
        XCTAssertFalse(tokens.isEmpty, "The categories header must not be empty.")
        for token in tokens {
            XCTAssertEqual(token, token.trimmingCharacters(in: .whitespaces),
                           "No stray whitespace around '\(token)' — the list is comma-separated, not comma-space.")
            XCTAssertFalse(token.isEmpty, "No empty category token.")
            XCTAssertTrue(token.allSatisfy { $0.isLowercase && $0.isLetter || $0 == "-" },
                          "Category '\(token)' must be lowercase-hyphen — OpenRouter's vocabulary is.")
        }
    }

    func testRefererIsTheConduckOriginWithNoTrailingSlash() {
        // Derived from `websiteURL` so the two can never name different origins.
        XCTAssertEqual(Constants.openRouterAttributionReferer, "https://conduck.com")
        XCTAssertTrue(Constants.websiteURL.hasPrefix(Constants.openRouterAttributionReferer),
                      "The Referer must be the origin of the app's own website URL.")
        XCTAssertFalse(Constants.openRouterAttributionReferer.hasSuffix("/"),
                       "The header carries an ORIGIN, not a page.")
    }

    // MARK: - Drift guard

    func testHelperGatesOnTheHostTheOpenRouterDescriptorActuallyDials() {
        // If the fixed endpoint ever moves, attribution must move with it —
        // otherwise every request would silently stop being attributed.
        let metadata = RemoteAgentBackendRegistry.lookup(id: .openrouter)
        guard case .fixed(let endpointURL) = metadata.endpoint else {
            return XCTFail("OpenRouter's endpoint policy must be .fixed — it is app-supplied, never typed.")
        }

        XCTAssertEqual(OpenRouterAttribution.attributedHost, endpointURL.host()?.lowercased(),
                       "The attribution host gate must track the descriptor's fixed endpoint host.")
        XCTAssertEqual(OpenRouterAttribution.attributedHost,
                       URL(string: Constants.openRouterBaseURLString)?.host()?.lowercased(),
                       "…and the locked base URL, which is the single source both derive from.")
        XCTAssertNotNil(OpenRouterAttribution.attributedHost,
                        "A nil gate would silently disable attribution everywhere.")
    }

    func testHeaderNamesAreTheExactOnesOpenRouterReads() {
        // Verified against openrouter.ai/docs/app-attribution. These names are a
        // third party's contract — a typo attributes nothing and fails silently.
        XCTAssertEqual(OpenRouterAttribution.refererHeader, "HTTP-Referer")
        XCTAssertEqual(OpenRouterAttribution.titleHeader, "X-OpenRouter-Title")
        XCTAssertEqual(OpenRouterAttribution.categoriesHeader, "X-OpenRouter-Categories")
    }
}

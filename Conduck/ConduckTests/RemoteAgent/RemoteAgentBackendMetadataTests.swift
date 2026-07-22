// Conduck
// RemoteAgentBackendMetadataTests.swift
//
// Settings: Personal AI. Parity guard for the
// `RemoteAgentBackendRegistry` UI layer: every `RemoteAgentBackend` enum
// case must have a metadata entry in `allKnown`, and `all` must filter
// Hermes out until `FeatureFlags.remoteAgentHermesEnabled` flips.
// Mirrors `STTProviderRegistryTests` shape.

import XCTest
@testable import Conduck

final class RemoteAgentBackendMetadataTests: XCTestCase {

    // MARK: - Parity (every enum case has metadata)

    func testAllKnownMatchesEnumAllCases() {
        let metadataIDs = Set(RemoteAgentBackendRegistry.allKnown.map { $0.id })
        let enumIDs = Set(RemoteAgentBackend.allCases)
        XCTAssertEqual(
            metadataIDs, enumIDs,
            "RemoteAgentBackendRegistry.allKnown must contain exactly one metadata entry per RemoteAgentBackend case. " +
            "Mismatched: \(metadataIDs.symmetricDifference(enumIDs)). " +
            "Missing metadata = UI crash on backend switch; orphan metadata = stale entry to remove."
        )
    }

    // MARK: - Backend picker gating (Hermes flag)

    func testAllReflectsBackendFlagState() {
        // `all` is the flag-filtered picker list. OpenClaw is always on; Hermes
        // and OpenRouter each gate on their own feature flag, preserving
        // `allKnown` order. The gate is the flag, not a date — if a flag flips
        // off, the picker drops that backend.
        let ids = RemoteAgentBackendRegistry.all.map { $0.id }
        var expected: [RemoteAgentBackend] = [.openclaw]
        if FeatureFlags.remoteAgentHermesEnabled { expected.append(.hermes) }
        if FeatureFlags.remoteAgentOpenRouterEnabled { expected.append(.openrouter) }
        XCTAssertEqual(ids, expected,
                       "The Personal AI picker must list exactly the flag-enabled backends, in allKnown order.")
    }

    // MARK: - Lookup fallback

    func testLookupReturnsMetadataForEveryBackend() {
        for backend in RemoteAgentBackend.allCases {
            let metadata = RemoteAgentBackendRegistry.lookup(id: backend)
            XCTAssertEqual(metadata.id, backend,
                           "lookup(id:) must return metadata with matching id — UI relies on metadata.displayName for the active backend even when the Settings flag-filter hides that backend from the picker.")
        }
    }

    // MARK: - Metadata shape sanity

    func testOpenClawMetadataPlaceholdersAreHTTPS() throws {
        let openclaw = RemoteAgentBackendRegistry.lookup(id: .openclaw)
        XCTAssertTrue(openclaw.urlPlaceholder.lowercased().hasPrefix("https://"),
                      "URL placeholder must be `https://...` — ATS posture requires HTTPS; placeholder shouldn't suggest http://.")
        XCTAssertFalse(openclaw.tokenPlaceholder.isEmpty,
                       "Token placeholder must surface non-empty hint text for the SecureField.")
    }

    // MARK: - Connection-probe policy (Test-Connection false-green fix)

    func testConnectionProbePolicyPerBackend() {
        // OpenRouter validates the KEY against an auth-gated endpoint (/v1/key)
        // because its /v1/models is PUBLIC and returns 200 for any/no key. Self-
        // hosted backends list models (/v1/models IS auth-gated there). The
        // "API key valid" success label keys off `probesAuthDirectly`.
        let openrouter = RemoteAgentBackendRegistry.lookup(id: .openrouter)
        XCTAssertEqual(openrouter.connectionProbe, .authValidated(path: Constants.openRouterKeyProbePath))
        XCTAssertEqual(openrouter.verdictProbePath, "/v1/key")
        XCTAssertTrue(openrouter.probesAuthDirectly)

        for backend in [RemoteAgentBackend.openclaw, .hermes] {
            let metadata = RemoteAgentBackendRegistry.lookup(id: backend)
            XCTAssertEqual(metadata.connectionProbe, .modelList,
                           "Self-hosted \(backend) must keep the /v1/models verdict probe (auth-gated there).")
            XCTAssertEqual(metadata.verdictProbePath, Constants.remoteAgentModelsProbePath)
            XCTAssertFalse(metadata.probesAuthDirectly)
        }
    }

    // MARK: - Key-shape hint (soft 401 diagnosis)

    /// A hosted provider mints keys in a known shape, so a truncated paste — the
    /// commonest cause of a 401 here — is detectable client-side. A self-hosted
    /// user mints their OWN token, so there is no shape to expect and the hint must
    /// stay `nil` (a false "that looks malformed" on a valid token is worse than
    /// no hint at all).
    func testTokenPrefixHintOnlyExistsForHostedBackends() {
        let openrouter = RemoteAgentBackendRegistry.lookup(id: .openrouter)
        XCTAssertEqual(openrouter.tokenPrefixHint, "sk-or-")
        XCTAssertTrue(openrouter.tokenPlaceholder.hasPrefix(openrouter.tokenPrefixHint!),
                      "The placeholder teaches the shape the hint enforces — they must agree.")

        for backend in [RemoteAgentBackend.openclaw, .hermes] {
            let metadata = RemoteAgentBackendRegistry.lookup(id: backend)
            XCTAssertNil(metadata.tokenPrefixHint,
                         "Self-hosted \(backend) tokens are user-minted — no expected shape.")
        }
    }
}

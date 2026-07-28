// SPDX-License-Identifier: Apache-2.0

// Conduck — watchOS-only contract test.
//
// Locks the Watch converse lane's pin RESOLUTION, the wrist twin of
// `RemoteAgentTrustPolicyTests`' host-blind lock on
// `RemoteAgentTrustEvaluator.converseTaskPin(for:metadata:)`.
//
// WHY IT MATTERS: the Watch converse `URLSession` is a BACKGROUND session, so it
// always follows redirects and never delivers `willPerformHTTPRedirection` (SDK
// contract). Its trust callback is therefore the ONLY point at which the wrist
// can push back on a cross-host hop, and a pin resolved from the CHALLENGE HOST
// resolves nil for a redirect target — degrading exactly that hop to ordinary
// system trust and letting a compromised gateway replay the conversation history
// and the bearer header to any host holding a publicly-trusted certificate.
// Resolution keyed by the TASK's ref cannot fail that way: the ref is stamped at
// enqueue and the same pin applies to every challenge the task raises.
//
// The end-to-end "the evaluator cancels the redirect host's challenge" step needs
// a live redirecting server (no public `SecTrust` constructor); this locks the
// layer that IS reachable in-process — that the resolver takes a REF and never a
// host, and that it reads the per-ref value the iPhone couriered.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchConversePinResolutionTests: XCTestCase {

    private let pin = String(repeating: "ab", count: 32)   // 64-hex

    /// The pin is looked up by REF — the value `WatchAudioUploader` recovers from
    /// the task's own `RemoteAgentBackgroundMetadata.backendRawValue`, which also
    /// chose the URL and token — so it applies to every challenge that task
    /// raises, including a redirect target's.
    func testPinResolvesForTheRefTheTurnWasDispatchedFor() {
        let reader = WatchSettingsReader.shared
        // Strictly newer than any high-water-mark a prior test left (the reader is
        // a process singleton), so this envelope always applies.
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 1000
        XCTAssertTrue(
            reader.updateRemoteAgent(
                backend: .openclaw,
                url: URL(string: "https://gateway.example.test")!,
                fingerprint: pin,
                sessionID: nil,
                timestamp: ts
            ),
            "A strictly-newer envelope must apply."
        )

        XCTAssertEqual(
            reader.remoteAgentCertFingerprint(forRef: RemoteAgentRef.builtin(.openclaw).rawString),
            pin,
            "The couriered per-ref pin must resolve for the ref the turn was dispatched for. Resolution takes NO host — that is what makes a cross-host redirect fail closed (the target's cert can't match → the evaluator cancels) instead of silently falling back to default ATS."
        )
    }

    /// A ref with no couriered pin resolves nil → default ATS, the recommended
    /// posture for a publicly-trusted gateway. The single-config legacy mirror
    /// must NOT leak into a ref it does not describe: it would pin one gateway to
    /// another's certificate and break every turn to it.
    func testUnconfiguredRefResolvesToNoPin() {
        let reader = WatchSettingsReader.shared
        let ts = reader.lastRemoteAgentEnvelopeTimestamp + 1000
        XCTAssertTrue(
            reader.updateRemoteAgent(
                backend: .openclaw,
                url: URL(string: "https://gateway.example.test")!,
                fingerprint: pin,
                sessionID: nil,
                timestamp: ts
            ),
            "A strictly-newer envelope must apply."
        )

        XCTAssertNil(
            reader.remoteAgentCertFingerprint(forRef: "custom_00000000-0000-0000-0000-000000000000"),
            "A ref the Watch holds no pin for must resolve nil → default ATS, never another ref's pin."
        )
    }
}

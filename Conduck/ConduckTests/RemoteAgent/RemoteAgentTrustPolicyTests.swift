// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentTrustPolicyTests.swift
//
// Locks the two POLICY decisions `RemoteAgentTrustEvaluator` carries beyond the
// SPKI digest math (which `RemoteAgentFingerprintTests` owns):
//
//   1. REDIRECT policy — a cross-host (or scheme-downgrading) 3xx is REFUSED;
//      a same-host one is followed unchanged. Directly callable:
//      `willPerformHTTPRedirection` takes only Foundation values. (The
//      server-trust BRANCH ORDER is locked in `RemoteAgentFingerprintTests`,
//      which drives `decide(serverTrust:)` with a fixture-built `SecTrust`.)
//   2. PIN RESOLUTION — `storedConversePin(for:)` / `converseTaskPin(...)` read
//      the DURABLE per-ref pin and apply it HOST-BLIND, so a redirect target's
//      cert is compared against the pin (→ cancel) instead of degrading that hop
//      to default ATS. A host-scoped pin fails OPEN exactly when it matters.
//
// The end-to-end "the evaluator actually cancels the redirect host's challenge"
// step still needs a live redirecting server + a signed run (no public SecTrust
// constructor); these tests lock every layer that IS reachable in-process.

import XCTest
@testable import Conduck

final class RemoteAgentTrustPolicyTests: XCTestCase {

    private var defaults: InMemoryDefaultsStore { TestStores.defaults }

    private let gatewayHost = "gateway.example.test"
    private let pin = String(repeating: "ab", count: 32)   // 64-hex

    override func setUp() {
        super.setUp()
        clearPins()
    }

    override func tearDown() {
        clearPins()
        super.tearDown()
    }

    private func clearPins() {
        for ref in [RemoteAgentRef.builtin(.openclaw), .builtin(.hermes)] {
            defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey(for: ref))
            defaults.removeObject(forKey: Constants.remoteAgentURLKey(for: ref))
        }
    }

    // MARK: - Redirect policy

    /// A redirect that leaves the host is refused (`completionHandler(nil)`), so
    /// URLSession completes the task with the 3xx itself instead of replaying the
    /// body + `Authorization` header at a host the user never configured.
    func testCrossHostRedirectIsRefused() {
        let followed = redirectDecision(
            from: "https://\(gatewayHost)/v1/chat/completions",
            to: "https://collector.attacker.test/collect"
        )
        XCTAssertNil(followed,
                     "A cross-host 3xx MUST be refused — following it replays the request body and bearer header to an unconfigured host with the pin no longer in scope.")
    }

    /// Same-host redirects stay allowed: a reverse proxy canonicalising a path or
    /// a WebDAV collection move is ordinary, and refusing it would break working
    /// deployments for no security gain.
    func testSameHostRedirectIsFollowed() {
        let target = "https://\(gatewayHost)/api/v1/chat/completions"
        let followed = redirectDecision(
            from: "https://\(gatewayHost)/v1/chat/completions",
            to: target
        )
        XCTAssertEqual(followed?.url?.absoluteString, target,
                       "A same-host redirect must be followed with the new request unchanged.")
    }

    /// Host comparison is case-insensitive — DNS hostnames are, and a case-only
    /// difference must not read as a cross-host hop and kill a working gateway.
    func testSameHostRedirectIsFollowedRegardlessOfCase() {
        let target = "https://GATEWAY.example.TEST/v1/chat/completions"
        let followed = redirectDecision(
            from: "https://\(gatewayHost)/v1/chat/completions",
            to: target
        )
        XCTAssertEqual(followed?.url?.absoluteString, target,
                       "Host equality must be case-insensitive; a case-only difference is the same host.")
    }

    /// https is mandatory app-wide (`http://` is rejected at Settings save), so a
    /// 3xx must never be able to downgrade the hop — even back to the same host.
    func testSchemeDowngradeOnSameHostIsRefused() {
        let followed = redirectDecision(
            from: "https://\(gatewayHost)/v1/chat/completions",
            to: "http://\(gatewayHost)/v1/chat/completions"
        )
        XCTAssertNil(followed,
                     "A redirect to http:// must be refused — https is an architectural invariant, not a preference.")
    }

    /// The comparison is ORIGIN, not host: the same name on a different port is a
    /// different service, and a self-hosted gateway on `:18789` next to an
    /// unrelated service on `:443` is the normal deployment here.
    func testPortChangeOnSameHostIsRefused() {
        let followed = redirectDecision(
            from: "https://\(gatewayHost)/v1/chat/completions",
            to: "https://\(gatewayHost):8443/v1/chat/completions"
        )
        XCTAssertNil(followed,
                     "A port change is a cross-ORIGIN hop and must be refused — comparing host alone would wave `:443` → `:8443` through.")
    }

    /// …but an explicit default port must still read as the SAME origin, or an
    /// ordinary canonicalising redirect would be refused for no reason.
    func testExplicitDefaultPortIsTheSameOrigin() {
        XCTAssertTrue(
            RemoteAgentTrustEvaluator.sameOrigin(
                URL(string: "https://\(gatewayHost)/a")!,
                URL(string: "https://\(gatewayHost):443/b")!
            ),
            "`URL.port` is nil for a default port, so it MUST be resolved against the scheme before comparing."
        )
        XCTAssertFalse(
            RemoteAgentTrustEvaluator.sameOrigin(
                URL(string: "https://\(gatewayHost)/a")!,
                URL(string: "https://\(gatewayHost):8443/a")!
            ),
            "A non-default port is a different origin."
        )
        XCTAssertFalse(
            RemoteAgentTrustEvaluator.sameOrigin(
                URL(string: "https://\(gatewayHost)/a")!,
                URL(string: "http://\(gatewayHost)/a")!
            ),
            "A scheme change is a different origin (and separately refused as a downgrade)."
        )
    }

    // MARK: - Pin resolution (durable + host-blind)

    func testStoredConversePinReadsDurablePerRefValue() {
        let ref = RemoteAgentRef.builtin(.openclaw)
        defaults.set(pin, forKey: Constants.remoteAgentCertFingerprintKey(for: ref))
        XCTAssertEqual(RemoteAgentTrustEvaluator.storedConversePin(for: ref), pin,
                       "The pin must be read LIVE from App-Group defaults so a re-pin between compose and send is honoured.")
    }

    func testStoredConversePinTreatsEmptyStringAsNoPin() {
        let ref = RemoteAgentRef.builtin(.hermes)
        defaults.set("", forKey: Constants.remoteAgentCertFingerprintKey(for: ref))
        XCTAssertNil(RemoteAgentTrustEvaluator.storedConversePin(for: ref),
                     "An empty stored pin means 'no pin' → default ATS, the recommended posture for a publicly-trusted gateway.")
    }

    /// FAIL-CLOSED lock: the resolved pin is NOT host-scoped. A background
    /// converse task cannot refuse a redirect (background sessions always follow
    /// them and never call `willPerformHTTPRedirection`), so the trust callback is
    /// the only interception point — and returning nil for the redirect host would
    /// silently degrade that hop to default ATS.
    func testConverseTaskPinAppliesToAChallengeHostThatIsNotTheConfiguredHost() {
        let ref = RemoteAgentRef.builtin(.openclaw)
        defaults.set(pin, forKey: Constants.remoteAgentCertFingerprintKey(for: ref))
        defaults.set("https://\(gatewayHost)", forKey: Constants.remoteAgentURLKey(for: ref))

        let resolved = RemoteAgentTrustEvaluator.converseTaskPin(
            for: serverTrustChallenge(host: "collector.attacker.test"),
            metadata: metadata(refRawValue: ref.rawString)
        )
        XCTAssertEqual(resolved, pin,
                       "The pin must apply to a FOREIGN challenge host too — that is what makes a cross-host redirect fail closed (cert can't match → cancel) instead of falling back to system trust.")
    }

    func testConverseTaskPinReturnsNilWhenNoPinIsStored() {
        let ref = RemoteAgentRef.builtin(.openclaw)
        defaults.set("https://\(gatewayHost)", forKey: Constants.remoteAgentURLKey(for: ref))
        XCTAssertNil(
            RemoteAgentTrustEvaluator.converseTaskPin(
                for: serverTrustChallenge(host: gatewayHost),
                metadata: metadata(refRawValue: ref.rawString)
            ),
            "No stored pin → nil → default ATS. An unpinned gateway must never traverse the pin path."
        )
    }

    /// A `taskDescription` written before `refRawValue` existed (an in-flight task
    /// enqueued pre-upgrade) must degrade to default ATS, not crash or mis-pin.
    func testConverseTaskPinReturnsNilWithoutARef() {
        defaults.set(pin, forKey: Constants.remoteAgentCertFingerprintKey(for: .builtin(.openclaw)))
        XCTAssertNil(
            RemoteAgentTrustEvaluator.converseTaskPin(
                for: serverTrustChallenge(host: gatewayHost),
                metadata: metadata(refRawValue: nil)
            ),
            "No recoverable ref → nil (pre-upgrade blob tolerance)."
        )
    }

    /// Non-server-trust challenges never reach the pin path — a pinned user must
    /// not accidentally block, say, an HTTP-auth 401 retry.
    func testConverseTaskPinIgnoresNonServerTrustChallenges() {
        let ref = RemoteAgentRef.builtin(.openclaw)
        defaults.set(pin, forKey: Constants.remoteAgentCertFingerprintKey(for: ref))
        let space = URLProtectionSpace(
            host: gatewayHost, port: 443, protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: NoopChallengeSender()
        )
        XCTAssertNil(
            RemoteAgentTrustEvaluator.converseTaskPin(
                for: challenge,
                metadata: metadata(refRawValue: ref.rawString)
            ),
            "Only server-trust challenges traverse the pinning path."
        )
    }

    // MARK: - Helpers

    /// Drive the evaluator's redirect delegate and return the `URLRequest` it
    /// decided to follow (nil = refused).
    private func redirectDecision(from responseURL: String, to newURL: String) -> URLRequest? {
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil)
        // An unresumed data task is a legitimate `URLSessionTask` and never
        // touches the network; the delegate only reads its request URLs as a
        // fallback when the response carries no URL.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: responseURL)!)
        let response = HTTPURLResponse(
            url: URL(string: responseURL)!, statusCode: 307,
            httpVersion: "HTTP/1.1", headerFields: ["Location": newURL]
        )!

        var decided: URLRequest?
        let done = expectation(description: "redirect decision")
        evaluator.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: newURL)!)
        ) { request in
            decided = request
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        return decided
    }

    private func serverTrustChallenge(host: String) -> URLAuthenticationChallenge {
        // `serverTrust` is nil here, which is fine: `converseTaskPin` is a pure
        // resolution helper over the protection space + metadata and never
        // touches the trust object (the compare happens in the delegate).
        let space = URLProtectionSpace(
            host: host, port: 443, protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: NoopChallengeSender()
        )
    }

    private func metadata(refRawValue: String?) -> RemoteAgentBackgroundMetadata {
        RemoteAgentBackgroundMetadata(
            bodyPath: "/dev/null",
            conversationID: UUID().uuidString,
            backendRawValue: RemoteAgentBackend.openclaw.rawValue,
            refRawValue: refRawValue
        )
    }
}

/// `URLAuthenticationChallenge`'s public initializer demands a sender; the
/// resolution helpers under test never message it. `nonisolated` because the
/// module defaults to MainActor isolation and `URLAuthenticationChallengeSender`'s
/// requirements are not (same reason `BackgroundTransferCancellationRelay` is).
private nonisolated final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { }
    func cancel(_ challenge: URLAuthenticationChallenge) { }
}

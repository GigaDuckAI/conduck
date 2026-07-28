// SPDX-License-Identifier: Apache-2.0

// Conduck
// TrustWindowTaskAttributionTests.swift
//
// Locks WHICH TASK a trust verdict belongs to.
//
// `RemoteAgentFingerprintTests` already proves the attempt window is CLEARED at
// every task boundary, which closes the stale-verdict shape for a lane that
// issues one request at a time. It cannot close the other one: Apple's own
// `NSURLSession.h` says a server-trust challenge is CONNECTION-level and "will
// apply to more than one request on a given connection", so a challenge is not
// automatically about the task that opened the window last. Two tasks created
// back to back, a challenge answered for the FIRST, and a plain `-999` on the
// second was enough to explain the second failure with the first task's
// certificate verdict — a stale-signal bug the clearing boundary cannot see.
//
// So the window is STAMPED with its task and a challenge writes only into the
// window stamped for the task that raised it. This file pins that, plus the two
// consequences of it: a challenge for the CURRENT task is still recorded (the
// gate must not silence the ordinary case), and a challenge with NO task at all
// is still recorded (the five per-challenge lanes build an evaluator that never
// becomes a session delegate, so it never opens a window to disagree with).
//
// It also pins the ObjC selector routing the stamp depends on. The stamp is only
// reachable from the TASK-level challenge handler, and a session-level handler
// takes precedence over it — so the session-level Swift entry point (which the
// per-challenge lanes still call directly) is `@nonobjc`. Removing that attribute
// is not a security regression and would not fail any behavioural test; it would
// silently route every challenge to the arm that cannot name a task. Hence a
// direct assertion on `responds(to:)`.
//
// Deterministic + headless: a real `SecTrust` over the bundled fixture
// certificate, real `URLSessionTask`s that are never resumed, no network.

import XCTest
@testable import Conduck

final class TrustWindowTaskAttributionTests: XCTestCase {

    /// 64 hex chars no certificate will ever hash to, so the pin compare always
    /// disagrees and the evaluator always has a verdict worth misattributing.
    private static let impossiblePin = String(repeating: "ab", count: 32)

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - The stamp

    func testAChallengeAnsweredForAnEarlierTaskDoesNotLandInTheCurrentTasksWindow() throws {
        let trust = try fixtureTrust()
        let evaluator = makeEvaluator()

        let taskA = makeTask()
        let taskB = makeTask()
        XCTAssertNotEqual(taskA.taskIdentifier, taskB.taskIdentifier,
                          "Precondition: URLSession numbers tasks uniquely within a session, which is what the stamp compares.")

        // Both windows open before either challenge is answered — the shape a
        // connection-level challenge produces, and the shape the clearing
        // boundary alone cannot tell apart from a retry.
        evaluator.urlSession(session, didCreateTask: taskA)
        evaluator.urlSession(session, didCreateTask: taskB)

        XCTAssertEqual(evaluator.decide(serverTrust: trust, taskIdentifier: taskA.taskIdentifier), .cancel,
                       "The refusal itself is unconditional: an older task's challenge is still ANSWERED, and answered the same way. Only the bookkeeping is scoped.")

        XCTAssertEqual(evaluator.attemptSignals, .empty,
                       "B never raised a challenge, so B's window must hold nothing. Recording A's refusal here is what let B's unrelated failure be explained by A's certificate.")
        XCTAssertEqual(evaluator.classifyTransportError(.cancelled), .cancelled,
                       "B ending in a bare -999 — a user cancel, a teardown — must read as a cancel. Reading A's verdict here raises the app's most alarming message over a connection nothing objected to.")
        XCTAssertEqual(evaluator.classifyTransportError(.secureConnectionFailed), .unreachable,
                       "Same for a generic -1200: with no verdict of its own, B's failure is transient and retryable.")
        XCTAssertNil(evaluator.presentedFingerprintHex,
                     "The presented digest is stamped like every verdict — a leaf A saw must not be reported as B's.")
    }

    func testAChallengeForTheCurrentTaskIsStillRecorded() throws {
        // The counterpart, and the reason the gate cannot simply be "record
        // nothing when two tasks exist": scoping must not throw away a verdict
        // that DOES belong to the task being classified.
        let trust = try fixtureTrust()
        let evaluator = makeEvaluator()

        let taskA = makeTask()
        let taskB = makeTask()
        evaluator.urlSession(session, didCreateTask: taskA)
        evaluator.urlSession(session, didCreateTask: taskB)

        XCTAssertEqual(evaluator.decide(serverTrust: trust, taskIdentifier: taskB.taskIdentifier), .cancel)

        XCTAssertTrue(evaluator.attemptSignals.pinRejected)
        XCTAssertTrue(evaluator.attemptSignals.challengeRefused)
        XCTAssertEqual(evaluator.classifyTransportError(.cancelled), .certMismatch,
                       "A pin that disagreed on THIS task's own challenge is exactly what -999 means here, and it is the one signal that says the connection may be intercepted.")
    }

    func testAChallengeWithNoTaskIsRecordedBecauseThatLaneOpensNoWindow() throws {
        // `BackgroundFileTransfer`, `BackgroundRemoteAgent`,
        // `CarPlayConverseUploader`, `STTClient+Background` and
        // `WatchAudioUploader` build an evaluator PER CHALLENGE and read it
        // synchronously inside that challenge. Such an evaluator is never a
        // session delegate, so it never receives `didCreateTask` and has no
        // second task its verdict could be confused with. Gating it on a task
        // identifier it cannot supply would silence every one of those lanes.
        let trust = try fixtureTrust()
        let evaluator = makeEvaluator()

        XCTAssertEqual(evaluator.decide(serverTrust: trust), .cancel)

        XCTAssertTrue(evaluator.attemptSignals.pinRejected,
                      "No window was ever opened, so there is nothing for this challenge to disagree with and it must record normally.")
        XCTAssertEqual(evaluator.classifyTransportError(.cancelled), .certMismatch)
    }

    func testVerdictsFromSeveralChallengesOnOneTaskAccumulate() throws {
        // One task can raise more than one challenge — a same-origin redirect hop
        // re-handshakes. A later hop the system ACCEPTS must not erase the
        // objection an earlier hop recorded, or a refusal would be forgotten the
        // moment the next hop was waved through.
        let trust = try fixtureTrust()
        let systemTrusts = FlippingVerdict(sequence: [false, true])
        let evaluator = RemoteAgentTrustEvaluator(
            pinnedFingerprintHex: nil,
            evaluateSystemTrust: { _ in systemTrusts.next() })
        let task = makeTask()
        evaluator.urlSession(session, didCreateTask: task)

        XCTAssertEqual(evaluator.decide(serverTrust: trust, taskIdentifier: task.taskIdentifier),
                       .performDefaultHandling)
        XCTAssertTrue(evaluator.attemptSignals.systemTrustRejected,
                      "Hop 1: the advisory evaluation objected.")

        XCTAssertEqual(evaluator.decide(serverTrust: trust, taskIdentifier: task.taskIdentifier),
                       .performDefaultHandling)
        XCTAssertTrue(evaluator.attemptSignals.systemTrustRejected,
                      "Hop 2 passed, but verdicts OR together within one window — the task as a whole did meet a chain this device objected to, and that is what explains its failure.")
    }

    /// A `@Sendable` stub that answers a scripted sequence, then repeats its last
    /// answer. The injected closure cannot capture a mutable local, so the state
    /// lives behind a lock.
    private final class FlippingVerdict: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [Bool]
        private var last: Bool
        init(sequence: [Bool]) {
            remaining = sequence
            last = sequence.last ?? false
        }
        func next() -> Bool {
            lock.withLock {
                guard !remaining.isEmpty else { return last }
                last = remaining.removeFirst()
                return last
            }
        }
    }

    // MARK: - The routing the stamp depends on

    func testTheEvaluatorExposesOnlyTheTaskLevelChallengeSelector() {
        // A session-level `URLSession:didReceiveChallenge:completionHandler:`
        // takes precedence over the task-level handler for server-trust
        // challenges. The evaluator implements both Swift entry points — the
        // task-level one for URLSession, the session-level one for the five lanes
        // that call it directly — so the session-level one is `@nonobjc`.
        //
        // Nothing else can catch this: with the attribute removed the app still
        // pins, still refuses, still classifies. It just stops knowing which task
        // it was talking about, and every test above would keep passing because
        // they drive `decide` directly.
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: nil)

        XCTAssertFalse(
            evaluator.responds(to: NSSelectorFromString("URLSession:didReceiveChallenge:completionHandler:")),
            "The session-level selector must stay hidden from the Objective-C runtime, or URLSession routes every server-trust challenge to the arm that cannot name a task and the window stamp becomes decoration.")
        XCTAssertTrue(
            evaluator.responds(to: NSSelectorFromString("URLSession:task:didReceiveChallenge:completionHandler:")),
            "The task-level handler is the one URLSession must find. Without it there is no pinning at all — challenges fall through to default handling and the failure looks exactly like success.")
    }

    // MARK: - Helpers

    private func makeEvaluator() -> RemoteAgentTrustEvaluator {
        // System trust stubbed to PASS so the branch order reaches the pin
        // compare — the fixture certificate is self-signed, so a real evaluation
        // would fail closed before any digest work and every verdict below would
        // be `systemTrustRejected` instead of the pin verdict under test.
        RemoteAgentTrustEvaluator(pinnedFingerprintHex: Self.impossiblePin,
                                  evaluateSystemTrust: { _ in true })
    }

    /// A real, unresumed task — created only so URLSession mints an identifier.
    private func makeTask() -> URLSessionTask {
        session.dataTask(with: URL(string: "https://gateway.example.test/v1/models")!)
    }

    private func fixtureTrust() throws -> SecTrust {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "test-cert", withExtension: "der"),
                                "Fixture test-cert.der missing from the test bundle Resources")
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: url) as CFData),
                                 "Failed to parse the fixture as a DER certificate")
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust)
        XCTAssertEqual(status, errSecSuccess, "SecTrustCreateWithCertificates failed (\(status))")
        return try XCTUnwrap(trust)
    }
}

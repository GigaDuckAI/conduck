// Conduck
// MacForegroundReplyLandingTests.swift
//
// Deterministic ordering coverage for the macOS foreground reply path. A held
// output probe must not delay reply persistence or release of the awaiting UI.

#if os(iOS) || os(macOS)

import XCTest
@testable import Conduck

private actor ReplyLandingProbeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
final class MacForegroundReplyLandingTests: XCTestCase {
    private func agentRecord(id: UUID = UUID()) -> MessageRecord {
        MessageRecord(
            id: id,
            role: "agent",
            text: "reply",
            createdAt: Date(),
            sourceDevice: "mac"
        )
    }

    func testSlowOutputProbeStartsOnlyAfterPersistAndUIReleaseAndDoesNotDelayReturn() async throws {
        let id = UUID()
        let record = agentRecord(id: id)
        let gate = ReplyLandingProbeGate()
        let probeStarted = expectation(description: "output probe started")
        let patchFinished = expectation(description: "output patch finished")
        var events: [String] = []

        let result = try await MacForegroundReplyLanding.persistThenScheduleOutputs(
            dependencies: .init(
                persist: {
                    events.append("persist")
                    return record
                },
                afterPersistBeforeRelease: { persisted in
                    XCTAssertEqual(persisted.id, id)
                    events.append("after-persist")
                },
                reconcileOutputs: { messageID in
                    XCTAssertEqual(messageID, id)
                    events.append("probe-start")
                    probeStarted.fulfill()
                    await gate.wait()
                    events.append("patch")
                    patchFinished.fulfill()
                }
            ),
            releaseAwaitingUI: {
                events.append("release")
            }
        )

        // The helper returned while the injected probe is still blocked. This
        // is the timing guarantee: persistence + UI release do not await probes.
        XCTAssertEqual(result.id, id)
        XCTAssertEqual(events, ["persist", "after-persist", "release"])

        await fulfillment(of: [probeStarted], timeout: 1.0)
        XCTAssertEqual(
            Array(events.prefix(4)),
            ["persist", "after-persist", "release", "probe-start"]
        )
        XCTAssertFalse(events.contains("patch"),
                       "the held probe must not have patched before the gate opens")

        await gate.open()
        await fulfillment(of: [patchFinished], timeout: 1.0)
        XCTAssertEqual(events.last, "patch")
    }

    func testPersistenceFailurePropagatesBeforeSuccessEffectsReleaseOrOutputScan() async {
        struct PersistFailure: Error {}
        var events: [String] = []

        do {
            _ = try await MacForegroundReplyLanding.persistThenScheduleOutputs(
                dependencies: .init(
                    persist: {
                        events.append("persist")
                        throw PersistFailure()
                    },
                    afterPersistBeforeRelease: { _ in
                        events.append("success-effects")
                    },
                    reconcileOutputs: { _ in
                        events.append("output-scan")
                    }
                ),
                releaseAwaitingUI: {
                    events.append("success-release")
                }
            )
            XCTFail("persistence error must propagate into the existing send failure handler")
        } catch is PersistFailure {
            events.append("failure-handler")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // The outer send/retry task owns its normal defer-based UI release after
        // failure handling; the success helper must not clear provenance, raise
        // arrival effects, schedule output work, or swallow the store error.
        events.append("outer-release")
        XCTAssertEqual(events, ["persist", "failure-handler", "outer-release"])
    }

    func testProcessWideClaimIsHeldBeforePersistenceThroughReconcile() async throws {
        let id = UUID()
        let record = agentRecord(id: id)
        XCTAssertTrue(OutputScanClaimRegistry.shared.claim(id))
        defer { OutputScanClaimRegistry.shared.release(id) }

        let reconciled = expectation(description: "reconciled")
        _ = try await MacForegroundReplyLanding.persistThenScheduleOutputs(
            dependencies: .init(
                persist: {
                    XCTAssertTrue(
                        OutputScanClaimRegistry.shared.isClaimed(id),
                        "the direct path must claim before persistence posts a reload"
                    )
                    return record
                },
                afterPersistBeforeRelease: { _ in },
                reconcileOutputs: { messageID in
                    XCTAssertEqual(messageID, id)
                    XCTAssertTrue(
                        OutputScanClaimRegistry.shared.isClaimed(id),
                        "the claim must remain held through reconciliation"
                    )
                    OutputScanClaimRegistry.shared.release(id)
                    reconciled.fulfill()
                }
            ),
            releaseAwaitingUI: {}
        )

        await fulfillment(of: [reconciled], timeout: 1.0)
        XCTAssertFalse(OutputScanClaimRegistry.shared.isClaimed(id))
    }

    func testClaimRejectsConcurrentOwnerAndCanBeReleasedAfterFailure() {
        let id = UUID()
        XCTAssertTrue(OutputScanClaimRegistry.shared.claim(id))
        XCTAssertFalse(
            OutputScanClaimRegistry.shared.claim(id),
            "direct and retro scans cannot own the same message concurrently"
        )

        // Mirrors the production catch path when persistence throws.
        OutputScanClaimRegistry.shared.release(id)
        XCTAssertFalse(OutputScanClaimRegistry.shared.isClaimed(id))
        XCTAssertTrue(
            OutputScanClaimRegistry.shared.claim(id),
            "a failed owner must release so a later recovery pass can retry"
        )
        OutputScanClaimRegistry.shared.release(id)
    }
}

#endif

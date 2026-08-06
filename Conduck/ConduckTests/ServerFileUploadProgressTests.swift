// SPDX-License-Identifier: Apache-2.0

// Conduck
// ServerFileUploadProgressTests.swift
//
// Locks `StagedAttachment.ServerFileUploadState.nextUploading(from:progress:)`,
// the guard that decides whether an upload-progress callback is allowed to
// write to the composer's staged array.
//
// Why it is worth a suite: every write mutates the host's `@State`, which
// invalidates the whole composer and re-runs the attachment strip's body, and
// `URLSession` reports progress once per body-data callback — hundreds of times
// for a large file. Two properties carry the weight:
//
//   - QUANTIZED: a write that would not move the rendered bar is skipped, so the
//     mutation count is bounded by `progressBuckets` instead of by the network.
//   - TERMINAL-ABSORBING + MONOTONIC: each callback hops onto the main actor in
//     its own unstructured `Task` and those carry NO ordering guarantee, so a
//     late one must not be able to overwrite `.uploaded` / `.failed` /
//     `.refused` with `.uploading`, nor drag the bar backwards.
//
// `StagedAttachment` is platform-agnostic but lives in the iOS/macOS composer
// layer, so this suite runs on the iOS-sim destination.

#if os(iOS) || os(macOS)

import XCTest
@testable import Conduck

final class ServerFileUploadProgressTests: XCTestCase {

    private typealias State = StagedAttachment.ServerFileUploadState

    // MARK: - Quantization

    func testProgressWithinTheSameBucketIsSkipped() {
        // Both land in the same whole-percent bucket, so the bar would not move.
        XCTAssertNil(State.nextUploading(from: .uploading(progress: 0.50), progress: 0.5049),
                     "A sub-bucket advance must not write — the write is a composer-wide invalidation and the rendered bar is unchanged.")
    }

    func testProgressCrossingABucketWrites() {
        guard case .uploading(let value)? = State.nextUploading(from: .uploading(progress: 0.50), progress: 0.51) else {
            return XCTFail("Crossing a bucket boundary must produce a write")
        }
        XCTAssertEqual(value, 0.51, accuracy: 0.0001,
                       "The written value is the QUANTIZED progress, so the next comparison comes from the same lattice.")
    }

    func testTheWholeUploadIsBoundedByTheBucketCount() {
        // Simulate a chatty upload: many more callbacks than buckets. The number
        // of accepted writes must track the buckets, not the callbacks.
        var state: State? = .uploading(progress: 0)
        var writes = 0
        for step in 0...1000 {
            let progress = Double(step) / 1000.0
            if let next = State.nextUploading(from: state, progress: progress) {
                state = next
                writes += 1
            }
        }
        XCTAssertEqual(writes, Int(State.progressBuckets),
                       "1001 callbacks must collapse to one write per bucket; an unbounded count is the churn this guard exists to stop.")
    }

    // MARK: - Terminal-absorbing

    func testALateCallbackCannotOverwriteAnUploadedState() {
        XCTAssertNil(State.nextUploading(from: .uploaded(storedKey: "abc__file.pdf"), progress: 0.4),
                     "A landed storedKey must never appear to un-land because an out-of-order progress callback arrived after it.")
    }

    func testALateCallbackCannotOverwriteAFailedState() {
        XCTAssertNil(State.nextUploading(from: .failed, progress: 0.9),
                     "A failed tile must keep its Retry affordance; reverting it to .uploading would show a spinner for an upload that is not running.")
    }

    func testALateCallbackCannotOverwriteARefusedState() {
        XCTAssertNil(State.nextUploading(from: .refused(reason: "r", detail: "d"), progress: 0.9),
                     "A terminal refusal states a cause and deliberately offers no Retry; a progress write would erase both.")
    }

    func testNilStateNeverStartsAnUpload() {
        XCTAssertNil(State.nextUploading(from: nil, progress: 0.5),
                     "Only a tile already staged as .uploading may advance — progress must not resurrect a tile that has no upload state.")
    }

    // MARK: - Monotonic

    func testProgressCannotGoBackwards() {
        XCTAssertNil(State.nextUploading(from: .uploading(progress: 0.80), progress: 0.20),
                     "Callbacks have no ordering guarantee, so a stale lower value must be dropped rather than rewinding the bar.")
    }

    func testEqualProgressIsNotRewritten() {
        XCTAssertNil(State.nextUploading(from: .uploading(progress: 0.42), progress: 0.42),
                     "A duplicate callback is a pure no-op.")
    }

    // MARK: - Clamping

    func testOutOfRangeProgressIsClamped() {
        guard case .uploading(let high)? = State.nextUploading(from: .uploading(progress: 0.5), progress: 4.2) else {
            return XCTFail("An over-range value must still advance to the ceiling")
        }
        XCTAssertEqual(high, 1.0, accuracy: 0.0001, "Progress above 1 clamps to a full bar, never past it.")

        XCTAssertNil(State.nextUploading(from: .uploading(progress: 0.5), progress: -3),
                     "A negative value is below the current bucket and must be dropped by the monotonic guard.")
    }
}

#endif

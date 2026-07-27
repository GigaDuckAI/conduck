// SPDX-License-Identifier: Apache-2.0

// Conduck
// BackgroundFileTransferCancellationTests.swift

import XCTest
@testable import Conduck

final class BackgroundFileTransferCancellationTests: XCTestCase {
    private nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        func reset() {
            lock.lock()
            value = 0
            lock.unlock()
        }
        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private nonisolated final class HangingURLProtocol: URLProtocol {
        static let startCalls = Counter()

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.startCalls.increment()
            // Intentionally never complete. URLSessionTask.cancel() must drive
            // the delegate's terminal callback.
        }

        override func stopLoading() {
            // URLSession owns the terminal callback; this protocol has no
            // private work to cancel.
        }
    }

    private nonisolated final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        var isInstalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            precondition(self.continuation == nil)
            self.continuation = continuation
            lock.unlock()
        }

        /// Mirrors the delegate's terminal ownership: take + resume at most
        /// once, even if a duplicate terminal callback is attempted.
        func resume(throwing error: Error) -> Bool {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            guard let continuation else { return false }
            continuation.resume(throwing: error)
            return true
        }
    }

    private nonisolated final class TerminalDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let relay: BackgroundTransferCancellationRelay
        let waiter: ContinuationBox
        let terminalCalls: Counter

        init(
            relay: BackgroundTransferCancellationRelay,
            waiter: ContinuationBox,
            terminalCalls: Counter
        ) {
            self.relay = relay
            self.waiter = waiter
            self.terminalCalls = terminalCalls
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            guard relay.claimTerminalCompletion() else { return }
            terminalCalls.increment()
            _ = waiter.resume(throwing: error ?? CancellationError())
        }
    }

    func testCancellationBeforeInstallPreventsUnderlyingTransferStart() {
        let relay = BackgroundTransferCancellationRelay()
        relay.cancel()

        XCTAssertFalse(relay.install {
            XCTFail("a pre-cancelled relay must not install or start I/O")
        })
    }

    func testCancellationAfterInstallCancelsUnderlyingTransferExactlyOnce() {
        let relay = BackgroundTransferCancellationRelay()
        let calls = Counter()

        XCTAssertTrue(relay.install {
            calls.increment()
        })

        relay.cancel()
        relay.cancel()

        XCTAssertEqual(calls.current, 1)
    }

    func testParentCancellationWaitsForDelegateTerminalCompletionAndCannotDoubleResume() async {
        let relay = BackgroundTransferCancellationRelay()
        let underlyingCancellationCalls = Counter()
        let parentCompletionCalls = Counter()
        let waiter = ContinuationBox()

        XCTAssertTrue(relay.install {
            underlyingCancellationCalls.increment()
        })

        let parent = Task<Void, Error> {
            defer { parentCompletionCalls.increment() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiter.install(continuation)
                }
            } onCancel: {
                relay.cancel()
            }
        }

        for _ in 0..<1_000 where !waiter.isInstalled {
            await Task.yield()
        }
        XCTAssertTrue(waiter.isInstalled)

        parent.cancel()

        XCTAssertEqual(
            underlyingCancellationCalls.current,
            1,
            "parent cancellation must only cancel the underlying URLSession task"
        )
        XCTAssertEqual(
            parentCompletionCalls.current,
            0,
            "the parent must remain suspended until the delegate terminal callback"
        )

        XCTAssertTrue(relay.claimTerminalCompletion())
        XCTAssertTrue(waiter.resume(throwing: CancellationError()))

        XCTAssertFalse(
            relay.claimTerminalCompletion(),
            "a duplicate delegate terminal callback must not claim completion"
        )
        XCTAssertFalse(
            waiter.resume(throwing: CancellationError()),
            "a duplicate terminal callback must not resume the continuation twice"
        )

        do {
            try await parent.value
            XCTFail("the cancelled parent must throw CancellationError")
        } catch is CancellationError {
            // Expected: the delegate terminal callback owns the one resume.
        } catch {
            XCTFail("unexpected cancellation error: \(type(of: error))")
        }

        XCTAssertEqual(parentCompletionCalls.current, 1)
    }

    func testRealURLSessionCancellationCompletesThroughDelegateBeforeParent() async {
        HangingURLProtocol.startCalls.reset()

        let relay = BackgroundTransferCancellationRelay()
        let waiter = ContinuationBox()
        let terminalCalls = Counter()
        let parentCompletionCalls = Counter()
        let parentObservedTerminal = Counter()
        let delegate = TerminalDelegate(
            relay: relay,
            waiter: waiter,
            terminalCalls: terminalCalls
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let request = URLRequest(url: URL(string: "https://cancellation.example.test/upload")!)
        let underlyingTask = session.dataTask(with: request)
        XCTAssertTrue(relay.install { [weak underlyingTask] in
            underlyingTask?.cancel()
        })

        let parent = Task<Void, Error> {
            defer {
                if terminalCalls.current == 1 {
                    parentObservedTerminal.increment()
                }
                parentCompletionCalls.increment()
            }
            try await withTaskCancellationHandler {
                do {
                    try await withCheckedThrowingContinuation { continuation in
                        waiter.install(continuation)
                        underlyingTask.resume()
                    }
                } catch {
                    try Task.checkCancellation()
                    throw error
                }
                try Task.checkCancellation()
            } onCancel: {
                relay.cancel()
            }
        }

        for _ in 0..<1_000 where HangingURLProtocol.startCalls.current == 0 {
            await Task.yield()
        }
        XCTAssertEqual(HangingURLProtocol.startCalls.current, 1)

        parent.cancel()

        do {
            try await parent.value
            XCTFail("the cancelled parent must throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(type(of: error))")
        }

        XCTAssertEqual(terminalCalls.current, 1)
        XCTAssertEqual(parentCompletionCalls.current, 1)
        XCTAssertEqual(
            parentObservedTerminal.current,
            1,
            "URLSession didComplete must claim terminal completion before the parent returns"
        )

        // A duplicate delegate callback cannot claim or resume again.
        delegate.urlSession(
            session,
            task: underlyingTask,
            didCompleteWithError: URLError(.cancelled)
        )
        XCTAssertEqual(terminalCalls.current, 1)
        XCTAssertEqual(parentCompletionCalls.current, 1)
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// MockURLProtocol.swift
//
// Test infrastructure for the `RemoteAgentClient` round-trip tests.
// Installed into a `URLSessionConfiguration.ephemeral` per test:
//
//   let config = URLSessionConfiguration.ephemeral
//   config.protocolClasses = [MockURLProtocol.self]
//   let session = URLSession(configuration: config)
//
// Per-test, set `MockURLProtocol.requestHandler = { req in (response, body) }`
// to script the gateway response (status code + body). Reset in `tearDown`
// so handlers do not leak across tests.
//
// `requestHandler` is ONE static shared by every suite in the process, so a
// load can outlive the test that started it: a test that cancels its task at
// once (`testAGenuineCancelPropagatesUnwrapped`) still leaves a `URLProtocol`
// whose `startLoading` may run after that test's `tearDown` cleared the handler
// — measured on CI at 3.6 s late, when the test host's main thread was busy
// and the NEXT test had not yet reached its `setUp`. An `XCTFail` from that
// stray load is attributed to whichever test is running at the moment, so a
// nil handler is treated as "this load outlived its test" and fails as a
// cancel, never as an assertion. A test that forgot to script a response
// still fails, on its own assertions, because its send throws.

import Foundation
import XCTest

final class MockURLProtocol: URLProtocol {

    /// Per-test request handler. Receives the URLRequest the client sent,
    /// returns the (HTTPURLResponse, Data) pair the test wants surfaced.
    /// `nil` = no handler installed. Every test sets this before it sends;
    /// a load that finds it nil fails as a cancel (see the header) rather
    /// than hanging or blaming the test that happens to be running.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            // A stray load from a finished test, or a test that never scripted
            // a response. Either way the caller sees a cancel; only the second
            // case reaches an assertion, and it is that test's own.
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No async work to cancel.
    }
}

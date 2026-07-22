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

import Foundation
import XCTest

final class MockURLProtocol: URLProtocol {

    /// Per-test request handler. Receives the URLRequest the client sent,
    /// returns the (HTTPURLResponse, Data) pair the test wants surfaced.
    /// `nil` = no handler installed (every test must set this in setUp;
    /// `startLoading` calls `XCTFail` if it's nil to surface the contract
    /// violation rather than silently hang).
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            XCTFail("MockURLProtocol.requestHandler not set — every test must install a handler in setUp")
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
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

// Conduck — pure classification tests for the background converse completion
// (the wrist's single reply-arrival path when the app is suspended).
// `WatchConverseCompletionVerdict.make` is the extracted decision;
// `WatchAudioUploader.handleConverseCompletion` executes it as a thin adapter.
//
// Deliberately NOT re-tested here: `ConverseResponse` decode internals
// (ConverseWireTests) and `WatchNetworkFailureCopy` wording
// (WatchObservabilityTests) — this suite locks branch classification and
// ordering only: cancel disambiguation via registry presence, transport vs
// HTTP vs decode, the missing-response guard, and the
// anti-phantom-reply conversationID guard.

import XCTest
@testable import ConduckWatch_Watch_App

@MainActor
final class WatchConverseCompletionVerdictTests: XCTestCase {

    private let cid = UUID()

    private func metadata(conversationID: String? = nil, stamps: Bool? = nil) -> RemoteAgentBackgroundMetadata {
        RemoteAgentBackgroundMetadata(
            bodyPath: "/tmp/converse-body.json",
            conversationID: conversationID ?? cid.uuidString,
            backendRawValue: "openclaw",
            stampsActiveConversation: stamps
        )
    }

    private func replyBody(_ text: String) -> Data {
        Data(#"{"choices":[{"message":{"content":"\#(text)"}}]}"#.utf8)
    }

    // MARK: - Happy path

    func testHappyReplyDecodesWithStampVerdict() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(stamps: true), httpStatus: 200,
            body: replyBody("Hi there"), transportError: nil, registryEntryPresent: true
        )
        guard case .reply(let text, let conversationID, let stamps) = verdict else {
            return XCTFail("Expected .reply, got \(verdict)")
        }
        XCTAssertEqual(text, "Hi there")
        XCTAssertEqual(conversationID, cid)
        XCTAssertTrue(stamps)
    }

    /// Old in-flight metadata blobs decode `stampsActiveConversation` nil —
    /// they must never stamp the quick-capture pointer.
    func testNilStampVerdictDefaultsToNoStamp() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(stamps: nil), httpStatus: 200,
            body: replyBody("ok"), transportError: nil, registryEntryPresent: true
        )
        guard case .reply(_, _, let stamps) = verdict else {
            return XCTFail("Expected .reply, got \(verdict)")
        }
        XCTAssertFalse(stamps)
    }

    // MARK: - Cancel disambiguation (registry presence)

    func testLiveCancelIsSilentCleanup() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: true
        )
        guard case .cleanupOnly = verdict else {
            return XCTFail("A live in-process cancel must drop silently, got \(verdict)")
        }
    }

    func testCrossLaunchCancelSurfacesFailure() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.cancelled), registryEntryPresent: false
        )
        guard case .failure(.cancelledAcrossLaunch, let conversationID) = verdict else {
            return XCTFail("A resurrected task's .cancelled must surface a failure, got \(verdict)")
        }
        XCTAssertEqual(conversationID, cid)
    }

    // MARK: - Transport / HTTP / decode branches

    /// The field case: NSURLErrorDomain -1001 against the gateway.
    func testTimedOutTransportClassifies() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: nil,
            transportError: URLError(.timedOut), registryEntryPresent: true
        )
        guard case .failure(.transport(let error), let conversationID) = verdict else {
            return XCTFail("Expected .transport failure, got \(verdict)")
        }
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
        XCTAssertEqual(conversationID, cid)
    }

    func testMissingHTTPResponseGuards() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: nil, body: replyBody("orphan"),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.missingHTTPResponse, let conversationID) = verdict else {
            return XCTFail("No HTTPURLResponse must classify as missingHTTPResponse, got \(verdict)")
        }
        XCTAssertEqual(conversationID, cid)
    }

    func testMappedHTTPStatusClassifies() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 500, body: replyBody("ignored"),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.httpStatus(let status), let conversationID) = verdict else {
            return XCTFail("A status-mapped code must classify as httpStatus, got \(verdict)")
        }
        XCTAssertEqual(status, 500)
        XCTAssertEqual(conversationID, cid)
    }

    func testUndecodableBodyClassifies() {
        let garbage = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 200, body: Data("not json".utf8),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.undecodableReply, _) = garbage else {
            return XCTFail("Garbage 2xx body must classify as undecodableReply, got \(garbage)")
        }
        // Empty choices decodes but carries no reply — same class.
        let emptyChoices = WatchConverseCompletionVerdict.make(
            metadata: metadata(), httpStatus: 200, body: Data(#"{"choices":[]}"#.utf8),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.undecodableReply, _) = emptyChoices else {
            return XCTFail("Empty choices must classify as undecodableReply, got \(emptyChoices)")
        }
    }

    // MARK: - anti-phantom-reply

    func testGarbageMetadataYieldsAntiPhantomFailure() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: nil, httpStatus: 200, body: replyBody("homeless reply"),
            transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.noConversationID, let conversationID) = verdict else {
            return XCTFail("A decoded reply with no metadata home must be a soft failure, got \(verdict)")
        }
        XCTAssertNil(conversationID)
    }

    func testNonUUIDConversationIDYieldsAntiPhantomFailure() {
        let verdict = WatchConverseCompletionVerdict.make(
            metadata: metadata(conversationID: "not-a-uuid"), httpStatus: 200,
            body: replyBody("homeless reply"), transportError: nil, registryEntryPresent: true
        )
        guard case .failure(.noConversationID, _) = verdict else {
            return XCTFail("A non-UUID conversationID must be a soft failure, got \(verdict)")
        }
    }
}

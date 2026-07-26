// Conduck
// BackgroundFileTransferPinDurabilityTests.swift
//
// Locks the file-lane cert-pin resolution: the TASK-CARRIED pin the trust
// handler applies host-blind, the legacy host lookup it falls back to, and the
// origin compare behind the lane's redirect refusal.
//
// The file transfer runs on a background `URLSession` with
// `sessionSendsLaunchEvents = true`: iOS may terminate the app mid-upload and
// RELAUNCH it to finish (`handleBackgroundSessionEvents`). The in-memory
// `inFlight` registry — the snapshot source the trust callback prefers — is
// empty in that relaunched process, so the pin has to be resolvable from durable
// storage or the resumed connection silently degrades to default ATS, i.e. the
// user's pin stops applying across a relaunch.
//
// The snapshot fast path stays authoritative while the enqueueing process lives
// (that is what `FileTransferSnapshot.identitySignature` guards); these tests
// cover the fallback, which is a pure App-Group defaults lookup. Whether the
// trust challenge fires at all in a relaunched process needs a signed device
// with a mid-upload memory-pressure kill.

import XCTest
@testable import Conduck

final class BackgroundFileTransferPinDurabilityTests: XCTestCase {

    private var defaults: UserDefaults {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }

    private let host = "files.example.test"
    private let pin = String(repeating: "9f", count: 32)   // 64-hex
    private let customID = UUID()

    private var refs: [RemoteAgentRef] {
        [.builtin(.openclaw), .builtin(.hermes), .custom(customID)]
    }

    override func setUp() {
        super.setUp()
        clearFileLaneKeys()
    }

    override func tearDown() {
        clearFileLaneKeys()
        super.tearDown()
    }

    private func clearFileLaneKeys() {
        for ref in refs {
            defaults.removeObject(forKey: Constants.fileServerURLKey(for: ref))
            defaults.removeObject(forKey: Constants.fileServerCertFingerprintKey(for: ref))
        }
        defaults.removeObject(forKey: Constants.customGatewaysRegistryKey)
    }

    func testResolvesABuiltinRefsPinByHost() {
        let ref = RemoteAgentRef.builtin(.openclaw)
        defaults.set("https://\(host)/dav", forKey: Constants.fileServerURLKey(for: ref))
        defaults.set(pin, forKey: Constants.fileServerCertFingerprintKey(for: ref))

        XCTAssertEqual(BackgroundFileTransfer.durableFileServerPin(forHost: host), pin,
                       "A relaunched transfer must recover the pin from App-Group defaults — the in-flight snapshot died with the old process.")
    }

    func testResolvesACustomGatewayRefsPinByHost() {
        // Custom gateways store their file-lane URL/pin in the SAME per-ref slots
        // as built-ins, so the lookup must enumerate the roster too.
        let roster = [CustomGateway(id: customID, name: "Workshop")]
        defaults.set(try! JSONEncoder().encode(roster), forKey: Constants.customGatewaysRegistryKey)
        let ref = RemoteAgentRef.custom(customID)
        defaults.set("https://\(host)/dav", forKey: Constants.fileServerURLKey(for: ref))
        defaults.set(pin, forKey: Constants.fileServerCertFingerprintKey(for: ref))

        XCTAssertEqual(BackgroundFileTransfer.durableFileServerPin(forHost: host), pin,
                       "A custom gateway's file-server pin must survive a relaunch too.")
    }

    func testHostMatchIsCaseInsensitive() {
        let ref = RemoteAgentRef.builtin(.hermes)
        defaults.set("https://FILES.Example.TEST/dav", forKey: Constants.fileServerURLKey(for: ref))
        defaults.set(pin, forKey: Constants.fileServerCertFingerprintKey(for: ref))

        XCTAssertEqual(BackgroundFileTransfer.durableFileServerPin(forHost: host), pin,
                       "DNS hostnames are case-insensitive; a case-only difference must not lose the pin.")
    }

    func testUnknownHostResolvesToNoPin() {
        let ref = RemoteAgentRef.builtin(.openclaw)
        defaults.set("https://\(host)/dav", forKey: Constants.fileServerURLKey(for: ref))
        defaults.set(pin, forKey: Constants.fileServerCertFingerprintKey(for: ref))

        XCTAssertNil(BackgroundFileTransfer.durableFileServerPin(forHost: "someone-else.example.test"),
                     "A host no configured ref points at has no pin — the lookup is a per-host registry, not a guard.")
    }

    // MARK: - Task-carried pin (the host-blind path)

    /// The pin rides the task's `taskDescription`, so it resolves with NO host
    /// input at all — which is the point: a redirect target the user never
    /// configured still has to present the pinned key.
    func testTaskCarriedPinResolvesWithoutAnyHostLookup() {
        let metadata = FileTransferBackgroundMetadata(
            storedKey: "abc12345__notes.pdf",
            refSuffix: "",
            direction: .upload,
            pinnedFingerprintHex: pin)
        XCTAssertEqual(BackgroundFileTransfer.taskPin(taskDescription: metadata.encoded()), pin,
                       "The enqueue-time pin must be recoverable from the task envelope alone.")
        // No file-lane defaults are set in this test, so the legacy host lookup
        // would answer nil for EVERY host — including the configured one.
        XCTAssertNil(BackgroundFileTransfer.durableFileServerPin(forHost: host))
    }

    /// A pre-update envelope (written before the field existed) decodes with a
    /// nil pin rather than failing to decode — the handler then falls back to the
    /// legacy host lookup.
    func testEnvelopeWithoutPinFieldStillDecodes() {
        let legacy = #"{"storedKey":"abc12345__notes.pdf","refSuffix":"","direction":"upload"}"#
        let decoded = FileTransferBackgroundMetadata.decoded(from: legacy)
        XCTAssertEqual(decoded?.storedKey, "abc12345__notes.pdf",
                       "An envelope written before the pin field existed must still decode.")
        XCTAssertNil(decoded?.pinnedFingerprintHex)
        XCTAssertNil(BackgroundFileTransfer.taskPin(taskDescription: legacy))
    }

    /// An unpinned lane (Tailscale Serve / Let's Encrypt — the recommended
    /// posture) must stay on default ATS, not pin to the empty string.
    func testUnpinnedLaneCarriesNoTaskPin() {
        let metadata = FileTransferBackgroundMetadata(
            storedKey: "abc12345__notes.pdf",
            refSuffix: "",
            direction: .download,
            pinnedFingerprintHex: nil)
        XCTAssertNil(BackgroundFileTransfer.taskPin(taskDescription: metadata.encoded()))

        let empty = FileTransferBackgroundMetadata(
            storedKey: "abc12345__notes.pdf",
            refSuffix: "",
            direction: .download,
            pinnedFingerprintHex: "")
        XCTAssertNil(BackgroundFileTransfer.taskPin(taskDescription: empty.encoded()),
                     "An empty stored pin means 'no pin', not 'pin to the empty string'.")
    }

    func testTaskPinIsNilWithoutAnEnvelope() {
        XCTAssertNil(BackgroundFileTransfer.taskPin(taskDescription: nil))
        XCTAssertNil(BackgroundFileTransfer.taskPin(taskDescription: "not json"))
    }

    // MARK: - Redirect policy (the origin compare this lane shares)

    /// The lane's redirect refusal delegates to the app's ONE origin compare, so
    /// lock the cases that matter for a file transfer: a host swap and a scheme
    /// downgrade are refused; a same-origin canonicalisation is followed.
    func testCrossOriginRedirectTargetsAreNotSameOrigin() {
        let source = URL(string: "https://\(host)/dav/notes.pdf")!
        XCTAssertFalse(RemoteAgentTrustEvaluator.sameOrigin(
            source, URL(string: "https://attacker.example.test/dav/notes.pdf")!),
            "A host swap must not read as the same origin — that hop replays the file bytes and the Basic credential.")
        XCTAssertFalse(RemoteAgentTrustEvaluator.sameOrigin(
            source, URL(string: "http://\(host)/dav/notes.pdf")!),
            "A scheme downgrade must not read as the same origin.")
        XCTAssertFalse(RemoteAgentTrustEvaluator.sameOrigin(
            source, URL(string: "https://\(host):8443/dav/notes.pdf")!),
            "A different port is a different service.")
        XCTAssertTrue(RemoteAgentTrustEvaluator.sameOrigin(
            source, URL(string: "https://\(host)/dav/notes.pdf/")!),
            "A same-origin canonicalising redirect stays allowed.")
    }

    func testConfiguredHostWithNoPinResolvesToNoPin() {
        // The recommended posture (Tailscale Serve / Let's Encrypt) is a
        // publicly-trusted file server with NO pin → default ATS.
        let ref = RemoteAgentRef.builtin(.openclaw)
        defaults.set("https://\(host)/dav", forKey: Constants.fileServerURLKey(for: ref))
        defaults.set("", forKey: Constants.fileServerCertFingerprintKey(for: ref))

        XCTAssertNil(BackgroundFileTransfer.durableFileServerPin(forHost: host),
                     "An empty stored pin means 'no pin', not 'pin to the empty string'.")
    }
}

// Conduck
// OfficialIdentityLockTests.swift
//
// Drift guard: under the OFFICIAL
// build identity (`CONDUCK_IDENTITY_NAMESPACE = ai.gigaduck.agentrelay`) every
// derived identity value MUST be byte-identical to the shipping identifiers —
// bundle-adjacent persistent IDs (App Group, CloudKit container, Keychain
// service, background-URLSession identifiers) are set-once Apple identity and
// may NEVER drift. The literals below are FROZEN: do not "fix" a failure here
// by editing the expectation — a mismatch means an official persistent
// identifier changed, which is a bug in the derivation, the xcconfig layer, or
// the Info.plist plumbing.
//
// Skipped entirely under any other (community) identity — a community build
// legitimately resolves different values; its correctness is covered by the
// derivation itself (namespace + frozen suffix).

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class OfficialIdentityLockTests: XCTestCase {

    /// The frozen official identity namespace. Every assertion below is gated
    /// on the build actually RESOLVING to this namespace.
    private static let officialNamespace = "ai.gigaduck.agentrelay"

    private func skipUnlessOfficial() throws {
        try XCTSkipUnless(
            Constants.identityNamespace == Self.officialNamespace,
            "Official-identity lock — not applicable under a non-official (community) build identity"
        )
    }

    // MARK: - Root + plist-fed values

    func testIdentityNamespaceIsFrozenOfficialValue() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(Constants.identityNamespace, "ai.gigaduck.agentrelay")
    }

    func testAppGroupIDIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(Constants.appGroupID, "group.ai.gigaduck.agentrelay")
    }

    func testICloudCloudKitContainerIDIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(Constants.iCloudCloudKitContainerID, "iCloud.ai.gigaduck.agentrelay")
    }

    // MARK: - Namespace + frozen-suffix derivations

    func testKeychainServiceNameIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(Constants.keychainServiceName, "ai.gigaduck.agentrelay.user-identity")
    }

    func testConverseSessionIdentifierIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(
            Constants.remoteAgentConverseSessionIdentifier,
            "ai.gigaduck.agentrelay.converse"
        )
    }

    func testWatchConverseSessionIdentifierIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(
            Constants.remoteAgentWatchConverseSessionIdentifier,
            "ai.gigaduck.agentrelay.watch.converse"
        )
    }

    func testCarPlayConverseSessionIdentifierIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(
            Constants.remoteAgentCarPlayConverseSessionIdentifier,
            "ai.gigaduck.agentrelay.carplay.converse"
        )
    }

    func testFileTransferSessionIdentifierIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(
            Constants.fileTransferSessionIdentifier,
            "ai.gigaduck.agentrelay.filetransfer"
        )
    }

    func testSTTBackgroundSessionIdentifierIsFrozen() throws {
        try skipUnlessOfficial()
        XCTAssertEqual(BackgroundSTT.sessionIdentifier, "ai.gigaduck.agentrelay.stt")
    }

    // MARK: - Lockstep invariants (registration ↔ session identity)

    /// The `.backgroundTask(.urlSession(...))` registrations in `ConduckApp`
    /// reference these same constants — a session-identity split here would
    /// silently break system-relaunch delivery, so pin the pairings too.
    func testBackgroundSessionIdentifiersAreDistinct() throws {
        try skipUnlessOfficial()
        let ids = [
            BackgroundSTT.sessionIdentifier,
            Constants.remoteAgentConverseSessionIdentifier,
            Constants.remoteAgentWatchConverseSessionIdentifier,
            Constants.remoteAgentCarPlayConverseSessionIdentifier,
            Constants.fileTransferSessionIdentifier,
        ]
        XCTAssertEqual(Set(ids).count, ids.count, "background URLSession identifiers must never collide")
    }
}
#endif

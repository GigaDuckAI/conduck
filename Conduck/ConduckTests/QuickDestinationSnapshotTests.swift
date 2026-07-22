// Conduck
// QuickDestinationSnapshotTests.swift
//
// The capture-time destination snapshot's two CONTRACTS, asserted as pure
// value-type tests (no coordinator, no store):
//   1. `stampsQuickPointer` — the provenance rule per destination case. This
//      is the routing invariant the whole popover/window lane split protects:
//      implicit destinations (automatic + the picker's "New chat") re-stamp
//      the per-device quick pointer; an explicit EXISTING-thread pick is a
//      one-shot detour and must NOT retarget future captures.
//   2. `Equatable` — `refreshQuickDestination` and the arm-task both replace
//      the snapshot wholesale; equality is what lets callers (and future
//      diffing) treat "same destination, same metadata" as a no-op.
//
// macOS-gated like the types under test (`MenuBarCoordinator.swift` is
// `#if os(macOS)`), mirroring `ConversationDetailViewModelMacReplyBannerTests`.

#if os(macOS)

import XCTest
@testable import Conduck

final class QuickDestinationSnapshotTests: XCTestCase {

    private func snapshot(_ destination: QuickDestination) -> QuickDestinationSnapshot {
        QuickDestinationSnapshot(
            destination: destination,
            titleSnippet: nil,
            gatewayName: "OpenClaw",
            lastActivityAt: nil
        )
    }

    // MARK: - Stamping rule per case

    func testAutomaticExistingStampsPointer() {
        XCTAssertTrue(snapshot(.automatic(existing: UUID())).stampsQuickPointer,
                      "Automatic continue is the implicit lane — it must re-stamp the pointer.")
    }

    func testAutomaticMintStampsPointer() {
        XCTAssertTrue(snapshot(.automatic(existing: nil)).stampsQuickPointer,
                      "Automatic fresh-mint is the implicit lane — the new thread becomes the pointer.")
    }

    func testExplicitNewStampsPointer() {
        XCTAssertTrue(snapshot(.explicitNew(nil)).stampsQuickPointer,
                      "An explicit New-chat pick fast-forwards what automatic would do next — it stamps.")
    }

    func testExplicitNewWithGatewayStampsPointer() {
        XCTAssertTrue(snapshot(.explicitNew(.builtin(.hermes))).stampsQuickPointer,
                      "A New-chat pick on a specific gateway is still the implicit lane — it stamps regardless of which gateway it mints on.")
        XCTAssertTrue(snapshot(.explicitNew(.custom(UUID()))).stampsQuickPointer,
                      "Same for a custom gateway.")
    }

    func testExplicitConversationDoesNotStampPointer() {
        XCTAssertFalse(snapshot(.explicitConversation(UUID())).stampsQuickPointer,
                       "An explicit existing-thread pick is a one-shot detour — it must NOT retarget the quick lane.")
    }

    // MARK: - Equality

    func testEqualSnapshotsCompareEqual() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = QuickDestinationSnapshot(
            destination: .explicitConversation(id),
            titleSnippet: "Grocery plan",
            gatewayName: "Hermes",
            lastActivityAt: date
        )
        let b = QuickDestinationSnapshot(
            destination: .explicitConversation(id),
            titleSnippet: "Grocery plan",
            gatewayName: "Hermes",
            lastActivityAt: date
        )
        XCTAssertEqual(a, b)
    }

    func testDifferentDestinationsCompareNotEqual() {
        let id = UUID()
        XCTAssertNotEqual(snapshot(.automatic(existing: id)),
                          snapshot(.explicitConversation(id)),
                          "Same target id, different CASE — automatic vs explicit changes the stamping rule, so they must not compare equal.")
        XCTAssertNotEqual(snapshot(.automatic(existing: nil)), snapshot(.explicitNew(nil)))
        XCTAssertNotEqual(snapshot(.explicitNew(nil)), snapshot(.explicitNew(.builtin(.hermes))),
                          "New-chat on the default vs on a named gateway are different mint targets — they must not compare equal.")
        XCTAssertNotEqual(snapshot(.automatic(existing: UUID())),
                          snapshot(.automatic(existing: UUID())))
    }

    func testDifferentMetadataComparesNotEqual() {
        var a = snapshot(.explicitNew(nil))
        var b = snapshot(.explicitNew(nil))
        XCTAssertEqual(a, b)
        b.gatewayName = "Hermes"
        XCTAssertNotEqual(a, b)
        b = a
        b.titleSnippet = "x"
        XCTAssertNotEqual(a, b)
        a.lastActivityAt = Date(timeIntervalSince1970: 1)
        XCTAssertNotEqual(a, b)
    }
}

#endif

// SPDX-License-Identifier: Apache-2.0

// Historical labels must never turn uncertain sync absence into a deletion,
// merge connections by name, or change the roster used for routing.

import XCTest
@testable import Conduck

@MainActor
final class UsageGatewayIdentityTests: XCTestCase {
    func testExplicitRemovalPreservesNameWhileDerivedAbsenceStaysUncertain() {
        let gateway = CustomGateway(id: UUID(), name: "Pi (Luna)")
        let derived = RetiredGatewayBadge.freeze(gateway, at: .now)!
        let removed = RetiredGatewayBadge.freeze(gateway, at: .now, explicitRemoval: true)!
        XCTAssertEqual(UsageGatewayIdentitySnapshot(retired: [derived])
            .display(for: gateway.ref.rawString).status, .unavailable)
        let snapshot = UsageGatewayIdentitySnapshot(retired: [removed])
        XCTAssertEqual(snapshot.display(for: gateway.ref.rawString).name, "Pi (Luna)")
        XCTAssertEqual(snapshot.display(for: gateway.ref.rawString).status, .removed)
        XCTAssertEqual(UsageGatewayLabel.name(for: gateway.ref.rawString, roster: snapshot.roster),
                       snapshot.display(for: gateway.ref.rawString).label)
        XCTAssertEqual([CustomGateway]().unioningRetired([removed]).first?.name,
                       RemoteAgentRefMetadata.genericCustomName)
    }

    func testRecreatedNameIsSeparateAndRestoredIDWinsOverRetirement() {
        let old = CustomGateway(id: UUID(), name: "Same name")
        let replacement = CustomGateway(id: UUID(), name: "Same name")
        let retired = RetiredGatewayBadge.freeze(old, at: .now, explicitRemoval: true)!
        let recreated = UsageGatewayIdentitySnapshot(live: [replacement], retired: [retired])
        XCTAssertEqual(recreated.roster.count, 2)
        XCTAssertEqual(recreated.display(for: old.ref.rawString).status, .removed)
        XCTAssertNil(recreated.display(for: replacement.ref.rawString).status)
        let restored = UsageGatewayIdentitySnapshot(
            live: [CustomGateway(id: old.id, name: "Renamed")], retired: [retired])
        XCTAssertEqual(restored.roster.count, 1)
        XCTAssertEqual(restored.display(for: old.ref.rawString).label, "Renamed")
    }

    func testLegacyAndNeverSeenGatewaysAreUnavailableNotRemoved() {
        let id = UUID()
        let legacy = RetiredGatewayBadge(id: id, monogram: "PI", colorID: "pink", retiredAt: .now)
        let snapshot = UsageGatewayIdentitySnapshot(retired: [legacy])
        for ref in [RemoteAgentRef.custom(id), .custom(UUID())] {
            let display = snapshot.display(for: ref.rawString)
            XCTAssertEqual(display.status, .unavailable)
            XCTAssertEqual(display.name, RemoteAgentRefMetadata.genericCustomName)
            XCTAssertEqual(UsageGatewayLabel.name(for: ref.rawString, roster: snapshot.roster), display.label)
        }
        XCTAssertNil(snapshot.display(for: "hermes").status,
                     "Missing custom settings do not prove anything about built-in setup.")
        XCTAssertNil(snapshot.display(for: nil).status)
    }
}

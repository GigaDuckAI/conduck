// SPDX-License-Identifier: Apache-2.0

// Conduck
// RetiredGatewayBadgeTests.swift
//
// Forgetting a custom gateway keeps its badge — the asymmetry this closes is
// that a forgotten BUILT-IN keeps its colour and letters for free (compiled
// into `RemoteAgentBackend.shortCode` + the reserved palette), while a
// forgotten CUSTOM lost them, because the roster entry that held the monogram
// and colour WAS the identity. Conversations keep their `custom_<uuid>` binding
// forever, so those rows went permanently blank.
//
// Two properties carry the design and are what these tests defend:
//
//  1. RETIREMENT IS DERIVED, NEVER REPLICATED. The record is App-Group only.
//     Syncing it would publish a monogram (which can carry organization or
//     personal identity) and a timestamp into whatever iCloud account the
//     device signs into next, and a restored backup would resurrect records the
//     user believed erased. Peers instead reach the same conclusion from an
//     event they already receive — the gateway vanishing from the synced roster.
//
//  2. RETIRED ENTRIES ARE DISPLAY-ONLY. `customGateways()` stays the routing /
//     picker / cap / configured-ref / share-target index. Only
//     `gatewayBadgeRoster()` unions the forgotten ones, so a consumer that does
//     not know about retirement structurally cannot receive one.
//
// iCloud is suspended for the suite (the `.shared` singleton dual-writes KVS).
// Keychain-free: fixtures are keyless gateways, so this runs unsigned.
//
// Privacy: synthetic fixtures only — never logged.

import XCTest
@testable import Conduck

final class RetiredGatewayBadgeTests: XCTestCase {

    private let defaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        await SettingsManager.shared.setICloudSyncSuspendedForTesting(true)
        await wipeAll()
    }

    override func tearDown() async throws {
        await wipeAll()
        await SettingsManager.shared.setICloudSyncSuspendedForTesting(false)
        try await super.tearDown()
    }

    private func wipeAll() async {
        for gateway in await SettingsManager.shared.customGateways() {
            await SettingsManager.shared.deleteCustomGateway(id: gateway.id)
        }
        defaults.removeObject(forKey: Constants.customGatewaysRegistryKey)
        TestStores.kvs.removeObject(forKey: Constants.customGatewaysRegistryKey)
        defaults.removeObject(forKey: Constants.retiredGatewayBadgesKey)
        defaults.removeObject(forKey: Constants.remoteAgentUserClearedAllKey)
    }

    @discardableResult
    private func addCustom(name: String, monogram: String? = nil, colorID: String? = "pink") async -> UUID {
        let id = UUID()
        await SettingsManager.shared.upsertCustomGateway(
            CustomGateway(id: id, name: name, model: nil, colorID: colorID, monogram: monogram)
        )
        await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://custom.example.test")!, for: .custom(id)
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: .custom(id))
        return id
    }

    // MARK: - Freezing

    func testRetiringFreezesMonogramAndColourBeforeTheNameIsErased() async {
        let id = await addCustom(name: "LiteLLM", colorID: "indigo")

        await SettingsManager.shared.retireCustomGatewayBadge(id: id)
        await SettingsManager.shared.deleteCustomGateway(id: id)

        let retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertEqual(retired.count, 1)
        XCTAssertEqual(retired.first?.monogram, "LI",
                       "The monogram is DERIVED from the name here, so freezing after the delete would capture nothing.")
        XCTAssertEqual(retired.first?.colorID, "indigo")
    }

    func testRetiringPrefersAnExplicitMonogramOverTheDerivedOne() async {
        let id = await addCustom(name: "LiteLLM", monogram: "ZZ")

        await SettingsManager.shared.retireCustomGatewayBadge(id: id)

        let retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertEqual(retired.first?.monogram, "ZZ")
    }

    func testAnUnknownColourIsFrozenToAConcretePaletteSlot() async {
        let id = await addCustom(name: "Alpha", colorID: nil)

        await SettingsManager.shared.retireCustomGatewayBadge(id: id)

        let colorID = await SettingsManager.shared.retiredGatewayBadges().first?.colorID
        XCTAssertNotNil(colorID)
        XCTAssertTrue(RemoteAgentBadgePalette.customPalette.contains { $0.id == colorID },
                      "Storing nil would leave the hue to a runtime fallback — 'frozen' has to survive a palette reorder.")
    }

    func testAGatewayWithNoRenderableMonogramIsNotRetired() async {
        let id = await addCustom(name: "!!!", monogram: nil)

        await SettingsManager.shared.retireCustomGatewayBadge(id: id)

        let retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertTrue(retired.isEmpty,
                      "`GatewayBadge` renders nothing for an empty monogram, so such a record could never draw — it would only consume a cap slot.")
    }

    func testRetiringTwiceKeepsTheOriginalRecord() async {
        let id = await addCustom(name: "LiteLLM")
        await SettingsManager.shared.retireCustomGatewayBadge(id: id, at: Date(timeIntervalSince1970: 1000))

        await SettingsManager.shared.retireCustomGatewayBadge(id: id, at: Date(timeIntervalSince1970: 9999))

        let retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertEqual(retired.count, 1, "Idempotent — a peer's roster sync arriving after the local Forget must not double-record.")
        XCTAssertEqual(retired.first?.retiredAt, Date(timeIntervalSince1970: 1000))
    }

    // MARK: - Display vs routing separation

    func testForgottenGatewayAppearsOnlyInTheBadgeRoster() async {
        let id = await addCustom(name: "LiteLLM")
        await SettingsManager.shared.retireCustomGatewayBadge(id: id)
        await SettingsManager.shared.deleteCustomGateway(id: id)

        let active = await SettingsManager.shared.customGateways()
        let badge = await SettingsManager.shared.gatewayBadgeRoster()
        let configured = await SettingsManager.shared.configuredRemoteAgentRefs()

        XCTAssertTrue(active.isEmpty,
                      "The live roster feeds routing, the picker and the cap — a forgotten gateway must never be selectable.")
        XCTAssertEqual(badge.count, 1)
        XCTAssertFalse(configured.contains(.custom(id)))
        XCTAssertEqual(
            RemoteAgentRefMetadata.monogram(for: .custom(id), customs: badge), "LI",
            "This is the whole point: the conversation row can draw its tag again."
        )
    }

    func testForgottenGatewayDoesNotConsumeACapSlot() async {
        var ids: [UUID] = []
        for index in 0..<Constants.maxCustomGateways {
            ids.append(await addCustom(name: "Gateway \(index)"))
        }
        await SettingsManager.shared.retireCustomGatewayBadge(id: ids[0])
        await SettingsManager.shared.deleteCustomGateway(id: ids[0])

        let count = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(count, Constants.maxCustomGateways - 1,
                       "Retirement is a display record, not a live gateway — forgetting one must free a slot.")
    }

    func testAnActiveGatewayWinsAUUIDCollision() async {
        let id = await addCustom(name: "LiteLLM", monogram: "LI")
        await SettingsManager.shared.retireCustomGatewayBadge(id: id)
        // Recreated under the same uuid, new identity.
        await SettingsManager.shared.upsertCustomGateway(
            CustomGateway(id: id, name: "LiteLLM v2", model: nil, colorID: "mint", monogram: "L2")
        )

        let badge = await SettingsManager.shared.gatewayBadgeRoster()

        XCTAssertEqual(badge.filter { $0.id == id }.count, 1)
        XCTAssertEqual(RemoteAgentRefMetadata.monogram(for: .custom(id), customs: badge), "L2",
                       "A live gateway is not a memory of one.")
    }

    // MARK: - Derived retirement (how a peer's Forget arrives)

    func testAVanishedGatewayIsRetiredFromARosterShrink() async {
        let id = await addCustom(name: "LiteLLM", colorID: "green")
        let previous = await SettingsManager.shared.customGateways()

        // What a peer device's Forget looks like locally: the roster arrives
        // without it. No tombstone is ever couriered.
        await SettingsManager.shared.retireVanishedCustomGateways(previous: previous, current: [])

        let retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertEqual(retired.first?.monogram, "LI")
        XCTAssertEqual(retired.first?.colorID, "green",
                       "Read from the OUTGOING entry — after the overwrite the identity is gone.")
    }

    func testASurvivingGatewayIsNotRetired() async {
        let id = await addCustom(name: "LiteLLM")
        let roster = await SettingsManager.shared.customGateways()

        await SettingsManager.shared.retireVanishedCustomGateways(previous: roster, current: roster)

        let retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertTrue(retired.isEmpty)
        XCTAssertNotNil(roster.first(where: { $0.id == id }))
    }

    // MARK: - Retention

    func testRetentionKeepsTheNewestAndDropsTheOldest() async {
        // One more gateway than the retention cap, created and forgotten one at
        // a time — the only way it can actually happen, since `maxCustomGateways`
        // bounds how many can exist AT ONCE and each Forget frees its slot.
        var ids: [UUID] = []
        for index in 0...Constants.maxRetiredGatewayBadges {
            let id = await addCustom(name: "Gateway \(index)", monogram: "G\(index % 10)")
            await SettingsManager.shared.retireCustomGatewayBadge(
                id: id, at: Date(timeIntervalSince1970: TimeInterval(index))
            )
            await SettingsManager.shared.deleteCustomGateway(id: id)
            ids.append(id)
        }

        let retired = await SettingsManager.shared.retiredGatewayBadges()

        XCTAssertEqual(retired.count, Constants.maxRetiredGatewayBadges)
        XCTAssertFalse(retired.contains { $0.id == ids[0] },
                       "Oldest retirement is evicted first — so a conversation older than the cap can still lose its badge.")
        XCTAssertTrue(retired.contains { $0.id == ids[ids.count - 1] })
    }

    func testRetiringWithADateOlderThanTheWholeArchiveReportsFailure() async {
        // Fill the archive with records newer than the one we are about to add.
        for index in 0..<Constants.maxRetiredGatewayBadges {
            let id = await addCustom(name: "Gateway \(index)", monogram: "G\(index % 10)")
            await SettingsManager.shared.retireCustomGatewayBadge(
                id: id, at: Date(timeIntervalSince1970: TimeInterval(1000 + index))
            )
            await SettingsManager.shared.deleteCustomGateway(id: id)
        }
        let id = await addCustom(name: "Ancient", monogram: "AN")

        let retired = await SettingsManager.shared.retireCustomGatewayBadge(
            id: id, at: Date(timeIntervalSince1970: 1)
        )

        XCTAssertFalse(retired,
                       "The trim evicts it in the same call that inserted it, so reporting success would tell the caller a badge exists that never will.")
        let list = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertFalse(list.contains { $0.id == id })
    }

    // MARK: - A gateway that comes back is not a forgotten one

    func testRecreatingAGatewayReleasesItsRetirementRecord() async {
        let id = await addCustom(name: "LiteLLM")
        await SettingsManager.shared.retireCustomGatewayBadge(id: id)
        await SettingsManager.shared.deleteCustomGateway(id: id)
        var retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertEqual(retired.count, 1)

        await SettingsManager.shared.upsertCustomGateway(
            CustomGateway(id: id, name: "LiteLLM v2", model: nil, colorID: "mint", monogram: "L2")
        )

        retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertTrue(retired.isEmpty,
                      "A retirement derived from a roster that only LOOKED shrunken — an iCloud initial-sync change older than a gateway this device just created — must release its slot, not sit there masked for the life of the install.")
    }

    func testAStaleRosterShrinkSelfCorrectsWhenTheRosterCatchesUp() async {
        await addCustom(name: "LiteLLM")
        let roster = await SettingsManager.shared.customGateways()

        // What a stale iCloud roster looks like: the gateway is missing…
        await SettingsManager.shared.retireVanishedCustomGateways(previous: roster, current: [])
        var retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertEqual(retired.count, 1)

        // …and then the real roster arrives and names it again.
        await SettingsManager.shared.retireVanishedCustomGateways(previous: [], current: roster)

        retired = await SettingsManager.shared.retiredGatewayBadges()
        XCTAssertTrue(retired.isEmpty)
    }

    // MARK: - The badge comes back, the name does not

    func testAForgottenGatewayReadsLikeAnyOtherUnnamedOne() async {
        let id = await addCustom(name: "LiteLLM")
        await SettingsManager.shared.retireCustomGatewayBadge(id: id)
        await SettingsManager.shared.deleteCustomGateway(id: id)

        let badge = await SettingsManager.shared.gatewayBadgeRoster()
        let neverKnown = RemoteAgentRef.custom(UUID())

        XCTAssertEqual(
            RemoteAgentRefMetadata.displayName(for: .custom(id), customs: badge),
            RemoteAgentRefMetadata.displayName(for: neverKnown, customs: badge),
            "Retirement restores the TAG, not the name. A label invented at the moment of forgetting would read as a tautology in the recovery banner ('Gateway X is no longer available') and put a placeholder in the Watch thread header."
        )
    }

    // MARK: - It is not synced

    func testRetiredBadgesAreNeverWrittenToICloud() async {
        let id = await addCustom(name: "LiteLLM")

        await SettingsManager.shared.retireCustomGatewayBadge(id: id)

        XCTAssertNil(TestStores.kvs.data(forKey: Constants.retiredGatewayBadgesKey),
                     "A monogram can carry personal or organization identity — publishing it would leak into the next iCloud account signed in on this device.")
        XCTAssertNotNil(defaults.data(forKey: Constants.retiredGatewayBadgesKey),
                        "…but it must be durable locally.")
    }
}

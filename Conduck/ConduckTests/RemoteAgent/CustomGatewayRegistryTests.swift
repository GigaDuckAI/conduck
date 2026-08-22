// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomGatewayRegistryTests.swift
//
// Custom-gateways. The `SettingsManager` custom-gateway ROSTER (the JSON list
// under `Constants.customGatewaysRegistryKey`). These exercise the roster CRUD
// + the ADD-only cap enforcement — all UserDefaults-backed (App Group), so they
// run UNSIGNED (no Keychain). The per-ref token/url/cert side effects of delete
// are signing-gated and covered separately on the signed founder run.
//
// Isolation: the actor is a `static let shared` singleton, so each test wipes
// the registry + default-pointer keys — in BOTH App-Group defaults and iCloud
// KVS, since `persistCustomGateways` dual-writes — in setUp/tearDown (mirrors
// `SettingsManagerRemoteAgentTests`). `await` is hoisted out of `XCTAssert`
// autoclosures (which don't support concurrency).

import XCTest
@testable import Conduck

final class CustomGatewayRegistryTests: XCTestCase {

    private let defaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        wipe()
    }

    override func tearDown() async throws {
        wipe()
        try await super.tearDown()
    }

    private func wipe() {
        let kvs = TestStores.kvs
        for key in [
            Constants.customGatewaysRegistryKey,
            Constants.remoteAgentDefaultBackendKVSKey,
        ] {
            defaults.removeObject(forKey: key)
            kvs.removeObject(forKey: key)
        }
    }

    private func gateway(_ name: String, model: String? = nil) -> CustomGateway {
        CustomGateway(id: UUID(), name: name, model: model)
    }

    /// Persist a roster STRAIGHT into the App-Group JSON, bypassing the capped
    /// `upsertCustomGateway` write path — the only way to stage a roster the
    /// compiled cap would never let `upsert` build.
    private func seedPersistedRoster(_ list: [CustomGateway]) {
        guard let data = try? JSONEncoder().encode(list) else {
            return XCTFail("roster encode failed")
        }
        defaults.set(data, forKey: Constants.customGatewaysRegistryKey)
    }

    func testEmptyInitially() async {
        let list = await SettingsManager.shared.customGateways()
        XCTAssertTrue(list.isEmpty)
        let count = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(count, 0)
    }

    func testUpsertAddsAndReadsBack() async {
        let g = gateway("Home vLLM", model: "llama3")
        let ok = await SettingsManager.shared.upsertCustomGateway(g)
        XCTAssertTrue(ok)
        let fetched = await SettingsManager.shared.customGateway(id: g.id)
        XCTAssertEqual(fetched?.name, "Home vLLM")
        XCTAssertEqual(fetched?.model, "llama3")
        let count = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(count, 1)
    }

    func testPersistedRosterRoundTripsThroughJSON() async {
        let g = gateway("Persisted", model: "m")
        _ = await SettingsManager.shared.upsertCustomGateway(g)
        // The actor holds no in-memory cache — a second read re-decodes the
        // UserDefaults JSON, proving the roster persists.
        let again = await SettingsManager.shared.customGateways()
        XCTAssertEqual(again.first?.id, g.id)
        XCTAssertEqual(again.first?.model, "m")
    }

    func testUpdateSameIDDoesNotIncreaseCount() async {
        var g = gateway("A")
        _ = await SettingsManager.shared.upsertCustomGateway(g)
        g.name = "A renamed"
        let ok = await SettingsManager.shared.upsertCustomGateway(g)
        XCTAssertTrue(ok)
        let count = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(count, 1)
        let fetched = await SettingsManager.shared.customGateway(id: g.id)
        XCTAssertEqual(fetched?.name, "A renamed")
    }

    func testCapRejectsBeyondMax() async {
        for index in 0..<Constants.maxCustomGateways {
            let ok = await SettingsManager.shared.upsertCustomGateway(gateway("G\(index)"))
            XCTAssertTrue(ok, "Add #\(index) within the cap must succeed")
        }
        let overflow = await SettingsManager.shared.upsertCustomGateway(gateway("Overflow"))
        XCTAssertFalse(overflow, "Adding beyond maxCustomGateways must be rejected")
        let count = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(count, Constants.maxCustomGateways)
    }

    func testUpdateAtCapStillSucceeds() async {
        var first: CustomGateway?
        for index in 0..<Constants.maxCustomGateways {
            let g = gateway("G\(index)")
            if index == 0 { first = g }
            _ = await SettingsManager.shared.upsertCustomGateway(g)
        }
        // Update (not add) an existing entry while at the cap — must NOT trip it.
        guard var g = first else { return XCTFail("seed missing") }
        g.model = "updated"
        let ok = await SettingsManager.shared.upsertCustomGateway(g)
        XCTAssertTrue(ok)
        let count = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(count, Constants.maxCustomGateways)
    }

    func testDeleteRemovesFromRosterAndFreesSlot() async {
        var ids: [UUID] = []
        for index in 0..<Constants.maxCustomGateways {
            let g = gateway("G\(index)")
            ids.append(g.id)
            _ = await SettingsManager.shared.upsertCustomGateway(g)
        }
        await SettingsManager.shared.deleteCustomGateway(id: ids[0])
        let countAfterDelete = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(countAfterDelete, Constants.maxCustomGateways - 1)
        let deleted = await SettingsManager.shared.customGateway(id: ids[0])
        XCTAssertNil(deleted)
        // Freed slot → a fresh add succeeds again.
        let readd = await SettingsManager.shared.upsertCustomGateway(gateway("New"))
        XCTAssertTrue(readd)
    }

    func testCapConstantIsThree() {
        XCTAssertEqual(Constants.maxCustomGateways, 3)
    }

    /// The cap is enforced on ADD only — every reader decodes the persisted array
    /// whole. A roster synced down from a future, higher-cap build must therefore
    /// survive intact on an older binary: nothing truncates it, updates still
    /// land, and only NEW adds are refused until a delete frees a slot.
    func testOverCapRosterReadsFullyAndRejectsOnlyNewAdds() async {
        let overCap = Constants.maxCustomGateways + 2
        let seeded = (0..<overCap).map { gateway("Synced\($0)", model: "m\($0)") }
        seedPersistedRoster(seeded)

        let list = await SettingsManager.shared.customGateways()
        XCTAssertEqual(list.map(\.id), seeded.map(\.id),
                       "Readers must return EVERY persisted entry in order — never truncate to the compiled cap.")
        let count = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(count, overCap)

        // UPDATE bypasses the cap even while the roster sits above it.
        guard var first = seeded.first else { return XCTFail("seed missing") }
        first.model = "updated"
        let updated = await SettingsManager.shared.upsertCustomGateway(first)
        XCTAssertTrue(updated, "Updating an existing entry must succeed on an over-cap roster.")
        let refetched = await SettingsManager.shared.customGateway(id: first.id)
        XCTAssertEqual(refetched?.model, "updated")
        let countAfterUpdate = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(countAfterUpdate, overCap, "An update must neither grow nor shrink the over-cap roster.")

        let overflow = await SettingsManager.shared.upsertCustomGateway(gateway("Overflow"))
        XCTAssertFalse(overflow, "Adding to an over-cap roster must be rejected.")

        // Delete back below the cap — `overCap - 3 == maxCustomGateways - 1`.
        for entry in seeded.suffix(3) {
            await SettingsManager.shared.deleteCustomGateway(id: entry.id)
        }
        let countAfterDeletes = await SettingsManager.shared.customGatewayCount()
        XCTAssertEqual(countAfterDeletes, Constants.maxCustomGateways - 1)
        let readd = await SettingsManager.shared.upsertCustomGateway(gateway("New"))
        XCTAssertTrue(readd, "A freed slot below the cap accepts a fresh add again.")
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// SyncedGatewayNameSanitationTests.swift
//
// A custom gateway's display name is validated on the pairing-import path
// (`PairingPayload`), but the roster also reaches this device as a JSON blob
// from iCloud KVS — mirrored verbatim into App Groups — and from the Watch
// courier. That name then goes straight to notification titles, list rows and
// VoiceOver labels, where a bidi override reorders the sentence around it and a
// control scalar forges extra lines.
//
// The contract pinned here, in two halves:
//
//   * A name carrying a RENDERING-CONTROL scalar falls back to the generic fixed
//     copy every nameless custom gateway already resolves to, and the ROUTING
//     CONFIG IS KEPT. Dropping the record over a bad label would make every
//     conversation bound to that gateway start refusing — a worse outcome than a
//     renamed row. The denylist is scalars that control rendering, never
//     scripts: non-ASCII names are ordinary and must pass through verbatim.
//   * An OVER-LONG name is TRUNCATED, never replaced, and the bound is counted
//     in the same unit the local save's own cap uses — CHARACTERS. A grapheme
//     cluster spans many scalars, so a scalar ceiling set at the local cap's
//     value would condemn ordinary emoji, Devanagari and Thai names the editor
//     itself saved. That matters beyond rendering: the roster WRITE paths read
//     through the same resolver, so editing gateway B would rewrite gateway A's
//     name permanently.
//
// Drives an isolated `SettingsManager(dependencies: .inMemory())` and seeds the
// roster JSON straight into a store, which is exactly the shape the inbound
// mirror produces.

import XCTest
@testable import Conduck

final class SyncedGatewayNameSanitationTests: XCTestCase {

    private struct Rig {
        let manager: SettingsManager
        let defaults: InMemoryDefaultsStore
        let kvs: InMemoryUbiquitousStore
    }

    private func makeRig(cloudAvailable: Bool = false) -> Rig {
        let defaults = InMemoryDefaultsStore()
        let kvs = InMemoryUbiquitousStore()
        let manager = SettingsManager(
            dependencies: .inMemory(
                defaults: defaults,
                ubiquitous: kvs,
                secrets: InMemorySecretStore(),
                cloudAvailable: cloudAvailable
            )
        )
        return Rig(manager: manager, defaults: defaults, kvs: kvs)
    }

    /// Write a roster the way a peer device's push lands here: raw JSON into the
    /// App-Group blob, never through the local write path.
    private func seedRosterIntoDefaults(_ rig: Rig, _ list: [CustomGateway]) throws {
        let data = try JSONEncoder().encode(list)
        rig.defaults.set(data, forKey: Constants.customGatewaysRegistryKey)
    }

    /// The same blob in the iCloud copy only — the fresh-device / reinstall read.
    private func seedRosterIntoKVS(_ rig: Rig, _ list: [CustomGateway]) throws {
        let data = try JSONEncoder().encode(list)
        rig.kvs.set(data, forKey: Constants.customGatewaysRegistryKey)
    }

    private func syncedGateway(named name: String) -> CustomGateway {
        CustomGateway(id: UUID(), name: name, model: "gpt-4o-mini", colorID: nil, monogram: "WB")
    }

    // MARK: - Hostile names fall back, and keep their configuration

    func testBidiOverrideNameFallsBackToFixedCopy() async throws {
        let rig = makeRig()
        let gateway = syncedGateway(named: "Prod\u{202E}yawetag")
        try seedRosterIntoDefaults(rig, [gateway])

        let roster = await rig.manager.customGateways()
        let stored = try XCTUnwrap(roster.first)
        XCTAssertEqual(stored.name, RemoteAgentRefMetadata.genericCustomName)
        XCTAssertEqual(
            RemoteAgentRefMetadata.displayName(for: stored.ref, customs: roster),
            RemoteAgentRefMetadata.genericCustomName,
            "the label every surface resolves must be the fixed copy"
        )

        // The record itself — the routing identity — is intact.
        XCTAssertEqual(stored.id, gateway.id)
        XCTAssertEqual(stored.model, gateway.model)
        XCTAssertEqual(stored.monogram, gateway.monogram)
        let byID = await rig.manager.customGateway(id: gateway.id)
        XCTAssertNotNil(byID, "a bad label must never delete the gateway")
    }

    func testHostileNameDoesNotCostTheGatewayItsConfiguration() async throws {
        let rig = makeRig()
        let gateway = syncedGateway(named: "Prod\u{0007}\u{001B}[31m")
        try seedRosterIntoDefaults(rig, [gateway])
        let ref = RemoteAgentRef.custom(gateway.id)
        await rig.manager.setRemoteAgentURL(URL(string: "https://gw.example.com")!, for: ref)
        try await rig.manager.setRemoteAgentToken("token", for: ref)

        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.first?.name, RemoteAgentRefMetadata.genericCustomName)

        let configured = await rig.manager.configuredRemoteAgentRefs()
        XCTAssertTrue(configured.contains(ref), "the gateway still routes; only its label changed")
        let url = await rig.manager.getRemoteAgentURL(for: ref)
        XCTAssertNotNil(url)
    }

    func testEveryHostileScalarClassIsRefused() async throws {
        let hostile: [(String, String)] = [
            ("NUL", "Prod\u{0000}"),
            ("ESC", "Prod\u{001B}"),
            ("LF", "Prod\nStaging"),
            ("CR", "Prod\rStaging"),
            ("DEL", "Prod\u{007F}"),
            ("C1 NEL", "Prod\u{0085}"),
            ("LRM", "Prod\u{200E}"),
            ("RLO", "Prod\u{202E}"),
            ("LRI isolate", "Prod\u{2066}"),
            ("PDI isolate", "Prod\u{2069}"),
            ("LINE SEPARATOR", "Prod\u{2028}"),
            ("PARAGRAPH SEPARATOR", "Prod\u{2029}")
        ]

        for (label, name) in hostile {
            let rig = makeRig()
            try seedRosterIntoDefaults(rig, [syncedGateway(named: name)])
            let roster = await rig.manager.customGateways()
            XCTAssertEqual(
                roster.first?.name,
                RemoteAgentRefMetadata.genericCustomName,
                "\(label) must not reach a rendered label"
            )
        }
    }

    // MARK: - Over-length is TRUNCATED, never replaced

    /// Length alone is not evidence of hostility, so an over-long name is
    /// trimmed rather than swapped for the fixed copy. This is not cosmetic: the
    /// roster write-back means a replacement would be PERMANENT, applied the next
    /// time the roster is persisted for any reason — including an edit to a
    /// different gateway.
    func testOverLongNameIsTruncatedNotReplaced() async throws {
        let atBound = String(repeating: "a", count: 120)
        let overBound = String(repeating: "a", count: 121)

        let keeping = makeRig()
        try seedRosterIntoDefaults(keeping, [syncedGateway(named: atBound)])
        let kept = await keeping.manager.customGateways()
        XCTAssertEqual(kept.first?.name, atBound, "a long-but-bounded name is untouched")

        let trimming = makeRig()
        try seedRosterIntoDefaults(trimming, [syncedGateway(named: overBound)])
        let trimmed = await trimming.manager.customGateways()
        XCTAssertEqual(trimmed.first?.name, atBound, "trimmed to the bound, not replaced")
    }

    /// The bound is counted in CHARACTERS, because that is the unit
    /// `SettingsViewModel.saveRemoteAgent`'s own `prefix(40)` cap uses. A ZWJ
    /// emoji is ONE Character and FOUR scalars, so 31 of them is a name this app
    /// itself can persist while blowing straight past any 120-SCALAR ceiling —
    /// which would have renamed it, and then written that rename back over the
    /// user's real name on the next roster save.
    func testEmojiZWJSequenceNameTheAppCanSaveSurvivesVerbatim() async throws {
        let name = String(repeating: "👩🏽‍💻", count: 31)
        XCTAssertEqual(name.count, 31, "31 grapheme clusters — inside the 40 a local save keeps")
        XCTAssertEqual(name.unicodeScalars.count, 124, "…and past a 120-scalar ceiling")

        let rig = makeRig()
        try seedRosterIntoDefaults(rig, [syncedGateway(named: name)])
        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.first?.name, name, "a name the editor itself can save must never be renamed")
    }

    /// The same trap in a script people actually name gateways in: a Devanagari
    /// conjunct with a vowel sign is ONE Character and FOUR scalars, so 40 of
    /// them — exactly the local save's cap — is 160 scalars.
    func testDevanagariNameAtTheLocalSaveCapSurvivesVerbatim() async throws {
        let name = String(repeating: "क्षि", count: 40)
        XCTAssertEqual(name.count, 40, "exactly the 40 Characters a local save keeps")
        XCTAssertEqual(name.unicodeScalars.count, 160)

        let rig = makeRig()
        try seedRosterIntoDefaults(rig, [syncedGateway(named: name)])
        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.first?.name, name)
    }

    /// Editing gateway B rewrites the whole roster through the same resolver, so
    /// a length rule in the wrong unit would rename gateway A permanently, with
    /// nothing the user did pointing at it.
    func testEditingOneGatewayDoesNotRenameAnother() async throws {
        let rig = makeRig()
        let longName = String(repeating: "👩🏽‍💻", count: 31)
        let neighbour = syncedGateway(named: longName)
        let edited = syncedGateway(named: "Staging")
        try seedRosterIntoDefaults(rig, [neighbour, edited])

        var renamed = edited
        renamed.name = "Staging EU"
        let accepted = await rig.manager.upsertCustomGateway(renamed)
        XCTAssertTrue(accepted)

        let roster = await rig.manager.customGateways()
        let stored = try XCTUnwrap(roster.first(where: { $0.id == neighbour.id }))
        XCTAssertEqual(stored.name, longName, "the untouched gateway keeps the name the user gave it")
    }

    // MARK: - Ordinary names are untouched

    func testNonASCIINamesPassThroughVerbatim() async throws {
        let names = ["Küchen-Gateway", "日本語ゲートウェイ", "🚀 Prod", "بوابة", "Gate  way"]
        for name in names {
            let rig = makeRig()
            try seedRosterIntoDefaults(rig, [syncedGateway(named: name)])
            let roster = await rig.manager.customGateways()
            XCTAssertEqual(roster.first?.name, name, "\(name) is an ordinary name and must survive")
        }
    }

    // MARK: - The iCloud-KVS read path is fenced too

    func testKVSFallbackRosterIsSanitized() async throws {
        let rig = makeRig(cloudAvailable: true)
        let gateway = syncedGateway(named: "Prod\u{202E}yawetag")
        // Only the iCloud copy exists — the fresh-device / reinstall read path.
        try seedRosterIntoKVS(rig, [gateway])

        let roster = await rig.manager.customGateways()
        XCTAssertEqual(roster.first?.id, gateway.id)
        XCTAssertEqual(roster.first?.name, RemoteAgentRefMetadata.genericCustomName)
    }
}

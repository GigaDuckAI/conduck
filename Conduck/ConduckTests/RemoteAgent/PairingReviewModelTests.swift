// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingReviewModelTests.swift
//
// The import review card's CONTENT, as a pure function of the payload plus the
// local-state facts (`PairingReviewModel.make`). The card is the consent step
// for a bearer credential whose whole payload is attacker-selectable, so what it
// says has to be provably derived from what will be stored — these tests are
// that proof.
//
// The lifecycle around the card (nothing persists before Connect, dismissal
// leaves no draft, the re-read at Connect) lives with the sheet; the VM-side
// gathering of these facts is covered in `SettingsViewModelPairingImportTests`.
//
// Payloads are built locally (JSONSerialization → base64 → `PairingPayload.parse`)
// so a fixture can never drift from the real parser. No network anywhere.

import XCTest
@testable import Conduck

@MainActor
final class PairingReviewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makePayload(
        kind: String = "openclaw",
        name: String? = nil,
        url: String = "https://gw.example.test:18789",
        fileServer: [String: Any]? = nil,
        transport: String? = nil
    ) throws -> PairingPayload {
        var gateway: [String: Any] = ["kind": kind, "url": url, "token": "tok-review-test"]
        if let name { gateway["name"] = name }
        var dict: [String: Any] = ["v": 1, "gateway": gateway]
        if let fileServer { dict["fileServer"] = fileServer }
        if let transport { dict["transport"] = transport }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let string = "conduck-setup:v1:" + data.base64EncodedString()
        return try XCTUnwrap(
            try? PairingPayload.parse(string).get(),
            "Fixture pairing string must parse — the fixture builder and the parser have drifted."
        )
    }

    private func makeModel(
        payload: PairingPayload,
        existingGatewayURL: URL? = nil,
        existingFileServerDestination: String? = nil,
        targetName: String? = nil,
        anyGatewayConfigured: Bool = false
    ) -> PairingReviewModel {
        PairingReviewModel.make(
            payload: payload,
            existingGatewayURL: existingGatewayURL,
            existingFileServerDestination: existingFileServerDestination,
            targetName: targetName,
            anyGatewayConfigured: anyGatewayConfigured
        )
    }

    // MARK: - The destination is the one that will be stored

    /// The card must render the EFFECTIVE base URL — the same normalization
    /// `saveRemoteAgent` applies on commit. Rendering the raw payload URL would
    /// show the user a destination the app is not going to use.
    func testDestinationIsTheNormalizedBaseURLNotTheRawPayloadURL() throws {
        let payload = try makePayload(url: "https://gw.example.test:18789/v1/chat/completions")
        let model = makeModel(payload: payload)

        XCTAssertEqual(model.gatewayDestination, "https://gw.example.test:18789")
        XCTAssertEqual(
            model.gatewayDestination,
            SettingsViewModel.normalizedGatewayBaseURL(payload.url).absoluteString,
            "The rendered destination must be exactly the normalization the save path applies."
        )
    }

    /// Host alone is not enough. Two gateways on the SAME host and different
    /// ports are different backends, and a card that showed only the host would
    /// render them identically — which is precisely the confusion a look-alike
    /// code would exploit.
    func testSameHostDifferentPortsRenderDifferently() throws {
        let a = makeModel(payload: try makePayload(url: "https://gw.example.test:443"))
        let b = makeModel(payload: try makePayload(url: "https://gw.example.test:9443"))

        XCTAssertNotEqual(a.gatewayDestination, b.gatewayDestination)
        XCTAssertTrue(b.gatewayDestination.contains(":9443"))
    }

    /// Same for a tenant/path prefix on one origin — the prefix survives
    /// normalization (only a terminal `/v1…` is stripped) and must be visible.
    func testSameOriginDifferentPathsRenderDifferently() throws {
        let a = makeModel(payload: try makePayload(url: "https://gw.example.test/tenant-a"))
        let b = makeModel(payload: try makePayload(url: "https://gw.example.test/tenant-b"))

        XCTAssertNotEqual(a.gatewayDestination, b.gatewayDestination)
        XCTAssertTrue(a.gatewayDestination.hasSuffix("/tenant-a"))
    }

    /// Percent-encoding is preserved rather than decoded for display. A decoded
    /// path can carry bidi and control characters that reorder what the user
    /// reads; the encoded form is both safe and byte-equal to what is stored.
    func testPercentEncodingIsPreservedNotDecoded() throws {
        let payload = try makePayload(url: "https://gw.example.test/%E2%80%AEtenant")
        let model = makeModel(payload: payload)

        XCTAssertTrue(model.gatewayDestination.contains("%E2%80%AE"),
                      "The card must not decode a path into renderable control characters.")
        XCTAssertFalse(model.gatewayDestination.contains("\u{202E}"))
    }

    // MARK: - Replacing

    func testFreshTargetHasNothingToReplace() throws {
        let model = makeModel(payload: try makePayload())

        XCTAssertNil(model.previousGatewayDestination)
        XCTAssertFalse(model.replacesExistingGateway)
        XCTAssertFalse(model.gatewayDestinationChanges)
    }

    func testOverwriteToADifferentAddressReportsAChange() throws {
        let model = makeModel(
            payload: try makePayload(url: "https://new.example.test"),
            existingGatewayURL: URL(string: "https://old.example.test")
        )

        XCTAssertEqual(model.previousGatewayDestination, "https://old.example.test")
        XCTAssertTrue(model.replacesExistingGateway)
        XCTAssertTrue(model.gatewayDestinationChanges)
    }

    /// Re-importing a code for the address already saved is still an overwrite —
    /// the token and certificate settings are replaced. It is reported as a
    /// replacement WITHOUT a change, so the card can say so without rendering a
    /// meaningless "old → new" of one identical address.
    func testReimportingTheSameAddressReplacesWithoutChanging() throws {
        let model = makeModel(
            payload: try makePayload(url: "https://gw.example.test:18789"),
            existingGatewayURL: URL(string: "https://gw.example.test:18789")
        )

        XCTAssertTrue(model.replacesExistingGateway)
        XCTAssertFalse(model.gatewayDestinationChanges)
    }

    // MARK: - File lane

    func testIncomingFileBlockIsAlwaysShownEvenOnTheGatewaysOwnHost() throws {
        // Same host as the gateway, different port — the case a "hide it when
        // it's the same host" rule would wrongly suppress.
        let payload = try makePayload(
            url: "https://gw.example.test:18789",
            fileServer: ["url": "https://gw.example.test:9443", "credential": "cred"]
        )
        let model = makeModel(payload: payload)

        guard case .incoming(let destination, let replacing) = model.fileLane else {
            return XCTFail("Expected an incoming file lane, got \(String(describing: model.fileLane)).")
        }
        XCTAssertEqual(destination, "https://gw.example.test:9443")
        XCTAssertNil(replacing)
    }

    func testIncomingFileBlockNamesTheLaneItReplaces() throws {
        let payload = try makePayload(
            fileServer: ["url": "https://files-new.example.test", "credential": "cred"]
        )
        let model = makeModel(
            payload: payload,
            existingFileServerDestination: "https://files-old.example.test"
        )

        guard case .incoming(_, let replacing) = model.fileLane else {
            return XCTFail("Expected an incoming file lane.")
        }
        XCTAssertEqual(replacing, "https://files-old.example.test")
    }

    /// A gateway-only code leaves an existing lane untouched. Saying nothing
    /// would read as "my file transfer is gone", so the surviving lane is named.
    func testGatewayOnlyCodeSaysTheExistingLaneIsKept() throws {
        let model = makeModel(
            payload: try makePayload(),
            existingFileServerDestination: "https://files.example.test"
        )

        guard case .keepsExisting(let destination) = model.fileLane else {
            return XCTFail("Expected a kept file lane, got \(String(describing: model.fileLane)).")
        }
        XCTAssertEqual(destination, "https://files.example.test")
    }

    func testNoBlockAndNoExistingLaneOmitsTheRowEntirely() throws {
        XCTAssertNil(makeModel(payload: try makePayload()).fileLane)
    }

    // MARK: - The card carries no certificate claim

    /// The card is a pure function of the payload plus local state, and a
    /// certificate field embedded in a hand-crafted code must not change ANY of
    /// it. The parser ignores such a field; this proves the ignoring is total —
    /// the model built from a code carrying one is identical, so there is no
    /// remaining route by which a code's certificate assertion reaches a screen
    /// or a comparison.
    func testACodeCarryingACertificateFieldProducesTheIdenticalCard() throws {
        let plain = try makePayload(
            url: "https://gw.example.test:18789",
            fileServer: ["url": "https://gw.example.test:9443", "credential": "cred"]
        )
        let withSmuggledClaim = try makePayload(
            url: "https://gw.example.test:18789",
            fileServer: [
                "url": "https://gw.example.test:9443",
                "credential": "cred",
                "certFP": String(repeating: "cd", count: 32)
            ]
        )
        XCTAssertEqual(makeModel(payload: plain), makeModel(payload: withSmuggledClaim))
    }

    // MARK: - Naming and the default pointer

    /// A brand-new custom has no local name. The only one available is the one
    /// the CODE chose, and rendering it would hand whoever wrote the code a
    /// caption on the screen that exists to be trusted.
    func testABrandNewCustomIsNameless() throws {
        let payload = try makePayload(kind: "custom", name: "Totally Legit Company Gateway")
        let model = makeModel(payload: payload, targetName: nil)

        XCTAssertNil(model.targetName)
    }

    func testAKnownTargetUsesItsLocalName() throws {
        let payload = try makePayload(kind: "custom", name: "attacker-chosen")
        let model = makeModel(payload: payload, targetName: "My Work Gateway")

        XCTAssertEqual(model.targetName, "My Work Gateway")
    }

    func testFirstGatewayEverAlsoBecomesTheDefault() throws {
        XCTAssertTrue(makeModel(payload: try makePayload(), anyGatewayConfigured: false).becomesDefault)
        XCTAssertFalse(makeModel(payload: try makePayload(), anyGatewayConfigured: true).becomesDefault)
    }

    // MARK: - Equality drives the re-read at Connect

    /// The sheet compares the reviewed card with a freshly built one before it
    /// acts. That comparison is only as good as this equality: a destination
    /// that moved underneath must not compare equal.
    func testACardBuiltOverADifferentDestinationIsNotEqual() throws {
        let payload = try makePayload()
        let reviewed = makeModel(payload: payload)
        let afterAPeerChangedTheSlot = makeModel(
            payload: payload,
            existingGatewayURL: URL(string: "https://someone-elses.example.test")
        )

        XCTAssertNotEqual(reviewed, afterAPeerChangedTheSlot)
    }

    func testAnUnchangedRebuildIsEqual() throws {
        let payload = try makePayload(
            fileServer: ["url": "https://files.example.test", "credential": "cred"]
        )
        XCTAssertEqual(
            makeModel(payload: payload, existingGatewayURL: URL(string: "https://old.example.test")),
            makeModel(payload: payload, existingGatewayURL: URL(string: "https://old.example.test"))
        )
    }
}

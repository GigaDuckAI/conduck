// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingVectorsConformanceTests.swift
//
// Proves the app's pairing-code parser agrees with the `import` column of the
// conformance vectors `conduck-connect` publishes
// (`tests/fixtures/pairing-vectors.json`, vendored here as
// `PairingVectorsFixture`). The wizard MINTS codes; this app RECEIVES them;
// the fixture is the one place both sides' expectations are written down, so
// a disagreement here is a wire-contract break, not a unit failure.
//
// What is asserted, and what deliberately is not:
//
//   * The IMPORT column only. `mint` / `mintReason` grade `--check-code`, the
//     wizard's stricter validator for a code destined for ANOTHER device, and
//     the app implements no such tier. Several vectors are `import: accept`
//     with `mint: fail` on purpose — see "Looser than the validator" below.
//   * Every code goes through `PairingPayload.parse(_:)` — the SAME entry the
//     scanner (`PairingScannerView`) and the paste path
//     (`PairingImportFlow.handleCode`) call, with no pre-processing. Nothing
//     here re-implements parsing: an accept vector's `expected` JSON is encoded
//     the way the minter encodes it (base64 of the JSON behind the
//     `conduck-setup:v1:` prefix) and handed over whole; the `exact` entries
//     are parsed VERBATIM.
//   * For an accept vector: kind, url, auth scheme, token, model and the
//     fileServer block must match `expected` field by field; the transport
//     hint must match too.
//   * For a refuse vector: the parser must reject it, and where the fixture's
//     reason category maps onto exactly one `PairingParseError` case, that
//     case. Five categories have no single app-side counterpart — the
//     validator's self-only tier, its folded `file-server-url-invalid`, and
//     three shapes the app imports outright (a `/v1` tail, a token under
//     `auth: none`, a null conditional field) — so for those only the
//     rejection is asserted; the gap is written down at
//     `unmappedCategories`, and a NEW category in a future fixture revision
//     fails `testEveryRefuseCategoryIsMappedOrARecordedGap` rather than
//     silently degrading to rejection-only.
//
// LOOSER THAN THE VALIDATOR — why the loopback vectors MUST import. The
// VALIDATOR (`--check-code`) refuses a code carrying 127.0.0.1 / `localhost` /
// `::1` as one minted for a phone, because a phone can never reach the
// gateway's own loopback — the minter itself (`--emit-code`) still writes such
// a code, and the fixture's `minter: mints` on those rows pins that. The APP
// accepts it too, deliberately: Conduck also runs on macOS, and a Mac that
// hosts its own gateway (Ollama on `localhost:11434`, an OpenClaw bound to
// `127.0.0.1`) pairs against exactly that address. `EndpointURLPolicy` admits
// loopback as a host only the local network can reach, so the app-side
// verdict is `accept`, and `testVectorsTheValidatorRefusesToMintStillImport`
// pins it — a future "tighten the parser to match the validator" would break
// the same-Mac setup, and it must fail here first.
//
// Pure parser: the tests inherit the test target's MainActor default isolation
// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) and do no async work; no store
// is touched, so no annotation is needed beyond that inheritance. Placeholder
// secrets only (`not-a-real-…`), example/private hosts only — nothing in the
// fixture is real.

import XCTest
@testable import Conduck

final class PairingVectorsConformanceTests: XCTestCase {

    // MARK: - Fixture access

    private struct Fixture {
        let revision: Int
        let accept: [[String: Any]]
        let exact: [[String: Any]]
        let refuse: [[String: Any]]
    }

    private func loadFixture() throws -> Fixture {
        let data = try XCTUnwrap(PairingVectorsFixture.json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(object as? [String: Any], "Fixture root must be a JSON object.")
        return Fixture(
            revision: try XCTUnwrap(root["revision"] as? Int, "Fixture must carry an integer `revision`."),
            accept: try XCTUnwrap(root["accept"] as? [[String: Any]], "`accept` must be an array of objects."),
            exact: try XCTUnwrap(root["exact"] as? [[String: Any]], "`exact` must be an array of objects."),
            refuse: try XCTUnwrap(root["refuse"] as? [[String: Any]], "`refuse` must be an array of objects.")
        )
    }

    private func id(of entry: [String: Any]) -> String {
        entry["id"] as? String ?? "<no id>"
    }

    /// The literal scheme prefix + version, hand-written rather than borrowed
    /// from the parser (whose constant is private) — the same independence
    /// `LockedNetworkAndPairingLiteralsTests` keeps.
    private static let codePrefix = "conduck-setup:v1:"

    /// Build a code the way the minter does: the prefix, then base64 of the
    /// JSON object. Key order is free (the parser reads a dictionary), which is
    /// exactly the fixture's "conformance is semantic" clause.
    private func encodeCode(_ expected: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: expected)
        return Self.codePrefix + data.base64EncodedString()
    }

    /// The bytes a fixture code carries after the prefix. Fixture self-check
    /// only — the parser is never handed this; it always gets the whole code.
    private func decodedBody(ofCode code: String) -> Data? {
        guard code.hasPrefix(Self.codePrefix) else { return nil }
        var base64 = String(code.dropFirst(Self.codePrefix.count))
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    // MARK: - Field-by-field agreement with `expected`

    /// Every field the import path acts on, compared against the fixture's
    /// `expected` object. Literal kind / auth strings are matched here on
    /// purpose (not via `RemoteAgentBackend(rawValue:)`) so a raw-value rename
    /// in the app cannot pass by renaming both sides at once.
    private func assertPayload(
        _ payload: PairingPayload,
        matches expected: [String: Any],
        id: String
    ) throws {
        let gateway = try XCTUnwrap(expected["gateway"] as? [String: Any],
                                    "[\(id)] expected.gateway must be an object.")

        // kind (+ name for custom)
        let kindRaw = try XCTUnwrap(gateway["kind"] as? String,
                                    "[\(id)] expected.gateway.kind must be a string.")
        switch kindRaw {
        case "openclaw":
            XCTAssertEqual(payload.kind, .builtin(.openclaw), "[\(id)] kind")
        case "hermes":
            XCTAssertEqual(payload.kind, .builtin(.hermes), "[\(id)] kind")
        case "custom":
            let name = try XCTUnwrap(gateway["name"] as? String,
                                     "[\(id)] a custom vector must carry expected.gateway.name.")
            XCTAssertEqual(payload.kind, .custom(name: name), "[\(id)] custom name")
        default:
            XCTFail("[\(id)] fixture names a kind this suite does not map: \(kindRaw)")
        }

        // url — compared as the string the fixture wrote; `URL.absoluteString`
        // round-trips every form the fixture uses (bracketed IPv6 included).
        let urlString = try XCTUnwrap(gateway["url"] as? String,
                                      "[\(id)] expected.gateway.url must be a string.")
        XCTAssertEqual(payload.url.absoluteString, urlString, "[\(id)] gateway url")

        // auth + token — an ABSENT auth reads as bearer (fail closed), which is
        // what the `auth-omitted-stricter-than-app` vector exists to pin.
        let authRaw = (gateway["auth"] as? String) ?? "bearer"
        switch authRaw {
        case "bearer":
            XCTAssertEqual(payload.authScheme, RemoteAgentAuthScheme.bearer, "[\(id)] auth scheme")
            let token = try XCTUnwrap(gateway["token"] as? String,
                                      "[\(id)] a bearer vector must carry expected.gateway.token.")
            XCTAssertEqual(payload.token, token, "[\(id)] bearer token")
        case "none":
            XCTAssertEqual(payload.authScheme, RemoteAgentAuthScheme.none, "[\(id)] auth scheme")
            XCTAssertNil(payload.token, "[\(id)] a keyless payload carries no token")
        default:
            XCTFail("[\(id)] fixture names an auth scheme this suite does not map: \(authRaw)")
        }

        // model — the PARSER keeps it for every kind; only the importer limits
        // it to custom gateways (`bearer-https-hermes-with-model` documents
        // that split). nil on both sides when the fixture omits it.
        XCTAssertEqual(payload.model, gateway["model"] as? String, "[\(id)] model")

        // fileServer — present iff the fixture has the block; the url and the
        // credential are compared. No revision-1 vector states folderCapable /
        // autoDeliver / filenamePolicy, so the delivery properties are not
        // compared here (they would be nil against nil on every row).
        if let fileServerValue = expected["fileServer"] {
            let fsDict = try XCTUnwrap(fileServerValue as? [String: Any],
                                       "[\(id)] expected.fileServer must be an object.")
            let fileServer = try XCTUnwrap(payload.fileServer,
                                           "[\(id)] expected.fileServer is present → payload.fileServer must be.")
            XCTAssertEqual(fileServer.url.absoluteString, fsDict["url"] as? String, "[\(id)] fileServer url")
            XCTAssertEqual(fileServer.credential, fsDict["credential"] as? String, "[\(id)] fileServer credential")
        } else {
            XCTAssertNil(payload.fileServer, "[\(id)] no expected.fileServer → payload.fileServer must be nil.")
        }

        // transport — a hint, compared by raw value.
        XCTAssertEqual(payload.transport?.rawValue, expected["transport"] as? String, "[\(id)] transport hint")
    }

    // MARK: - Refuse-category → `PairingParseError` mapping

    /// The fixture's reason vocabulary → the ONE `PairingParseError` case the
    /// app raises for it. nil = no single app-side counterpart; such a category
    /// must be listed in `unmappedCategories` or the vocabulary guard fails.
    private static func expectedParseError(forCategory category: String) -> PairingParseError? {
        switch category {
        case "not-a-setup-code":
            return .notAPairingCode
        case "unsupported-version":
            return .unsupportedVersion
        case "malformed-base64", "malformed-json",
             "missing-required-field", "field-wrong-type", "field-value-not-allowed",
             "bearer-token-missing", "custom-name-missing",
             "text-too-long", "control-characters-in-text",
             "url-userinfo-present", "url-host-invalid":
            return .malformed
        case "url-scheme-not-allowed", "plain-http-host-not-local-only":
            return .insecureURL
        default:
            return nil
        }
    }

    /// Categories with NO single app-side case. Each is a documented gap, not
    /// an oversight — rejection alone is asserted for a vector in one of these,
    /// unless `expectedParseErrorForGapVector` pins the row's own reason.
    private static let unmappedCategories: Set<String> = [
        // The validator's self-only tier (127/8, ::1, localhost, 0.0.0.0, ::).
        // The app has no such tier: loopback IMPORTS (file header), and the one
        // refuse vector in this category (`plain-http-unspecified`, 0.0.0.0) is
        // refused by the app for a DIFFERENT reason — `LocalNetworkHost` classes
        // 0.0.0.0/8 as remote, so the parser answers `.insecureURL` (asserted
        // by id below).
        "address-only-reachable-from-the-gateway-itself",
        // The validator folds every file-server URL defect except self-only
        // into one reason; the app splits them exactly as it splits the gateway
        // URL — userinfo → `.malformed`, plain http to a public name →
        // `.insecureURL`.
        "file-server-url-invalid",
        // Three shapes the app IMPORTS — they appear only as `mintReason` on
        // accept rows (`…-stricter-than-app`), never in the refuse table: the
        // parser stores a `/v1` tail as written, drops a token under
        // `auth: none`, and reads null as absent. Listed so a future refuse
        // row in one of them fails the vocabulary guard loudly.
        "gateway-url-ends-in-v1",
        "keyless-code-carries-token",
        "null-instead-of-omitted",
    ]

    /// For a recorded-gap category the CATEGORY names no single parser case,
    /// but a specific ROW still has one definite answer, and that answer is
    /// asserted so the comment above cannot drift from the parser: 0.0.0.0 over
    /// plain http is `.insecureURL` because the host classes as remote, not
    /// because the app knows anything about the validator's self-only tier.
    private static let expectedParseErrorForGapVector: [String: PairingParseError] = [
        "plain-http-unspecified": .insecureURL,
    ]

    // MARK: - The vectors the vendored copy must carry

    // A table that is merely non-empty with unique ids would let a re-paste of a
    // future canonical file drop a vector — say `name-too-long`, the only row
    // exercising the 120-scalar name cap — with every test still green. The ids
    // are pinned by name so that removing one is an explicit edit here, never a
    // side effect of a paste. Adding vectors needs no edit: the sets are asserted
    // as SUBSETS of what the fixture carries.

    /// Every accept vector of revision 1, by id. A re-paste that DROPS one fails
    /// `testVendoredRevisionMatchesTheEmbeddedFixture` until this list is edited
    /// on purpose — coverage cannot shrink silently.
    private static let requiredAcceptIDs: Set<String> = [
        "bearer-https-openclaw",
        "bearer-https-hermes-tailscale",
        "bearer-https-hermes-with-model",
        "bearer-https-custom-with-model",
        "custom-unicode-name",
        "keyless-plain-http-private-ip",
        "keyless-plain-http-dot-local",
        "bearer-plain-http-ipv6-ula",
        "https-with-file-server",
        "custom-without-name-takes-the-minter-default",
        "unknown-extra-top-level-key",
        "unknown-nested-key",
        "self-only-loopback-https",
        "self-only-localhost-plain-http",
        "self-only-ipv6-loopback-https",
        "self-only-file-server-loopback",
        "auth-omitted-stricter-than-app",
        "token-with-newline-stricter-than-app",
        "oversize-line-stricter-than-app",
        "gateway-url-ends-in-v1-stricter-than-app",
        "keyless-code-carries-token-stricter-than-app",
        "model-null-stricter-than-app",
    ]

    /// Every exact (byte-pinned) vector of revision 1, by id.
    private static let requiredExactIDs: Set<String> = [
        "exact-bearer-https-openclaw",
        "exact-keyless-plain-http-private-ip",
        "exact-custom-unicode-name",
    ]

    /// Every refuse vector of revision 1, by id.
    private static let requiredRefuseIDs: Set<String> = [
        "wrong-prefix",
        "unsupported-version-segment",
        "bad-base64",
        "base64-empty",
        "json-not-an-object",
        "missing-v",
        "non-integer-v",
        "v-is-2",
        "gateway-not-an-object",
        "unknown-kind",
        "auth-unknown-without-token",
        "bearer-without-token",
        "bearer-with-empty-token",
        "custom-without-name",
        "custom-with-whitespace-name",
        "name-too-long",
        "control-character-in-name",
        "bidi-override-in-model",
        "userinfo-in-gateway-url",
        "url-scheme-not-allowed",
        "url-without-host",
        "plain-http-dotted-domain",
        "plain-http-single-label",
        "plain-http-cgnat",
        "plain-http-unspecified",
        "userinfo-in-file-server-url",
        "file-server-plain-http-public-name",
        "file-server-missing-credential",
        "file-server-empty-credential",
    ]

    // MARK: - 1. The vendored copy is current and well-formed

    /// A LOCAL consistency check, not a staleness check: the pin in
    /// `PairingVectorsFixture` is asserted against the embedded `revision`, so
    /// a paste that forgot the pin, or a pin bumped without a paste, fails here
    /// before any vector is graded. (Both values live in the vendored file, so
    /// a canonical file that moved on while nobody re-pasted stays green — see
    /// the fixture header.) Also refuses a hollow fixture (empty table,
    /// duplicate id) and one that lost a vector this revision carried (the
    /// `required…IDs` sets above), so a bad paste cannot pass vacuously.
    func testVendoredRevisionMatchesTheEmbeddedFixture() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.revision, PairingVectorsFixture.vendoredRevision,
                       "The vendored copy's embedded `revision` (\(fixture.revision)) and `vendoredRevision` (\(PairingVectorsFixture.vendoredRevision)) disagree — set `vendoredRevision` to the pasted file's `revision`.")

        XCTAssertFalse(fixture.accept.isEmpty, "The accept table must not be empty.")
        XCTAssertFalse(fixture.exact.isEmpty, "The exact table must not be empty.")
        XCTAssertFalse(fixture.refuse.isEmpty, "The refuse table must not be empty.")

        let ids = (fixture.accept + fixture.exact + fixture.refuse).map(id(of:))
        XCTAssertEqual(Set(ids).count, ids.count, "Vector ids must be unique across all three tables.")
        XCTAssertFalse(ids.contains("<no id>"), "Every vector must carry an id.")

        // Nothing this revision carried has gone missing. A vector dropped from
        // the canonical file is a decision, and it is made here by editing the
        // required set — not by a paste.
        let acceptIDs = Set(fixture.accept.map(id(of:)))
        let exactIDs = Set(fixture.exact.map(id(of:)))
        let refuseIDs = Set(fixture.refuse.map(id(of:)))
        XCTAssertTrue(Self.requiredAcceptIDs.isSubset(of: acceptIDs),
                      "Accept vectors missing from the vendored copy: \(Self.requiredAcceptIDs.subtracting(acceptIDs).sorted())")
        XCTAssertTrue(Self.requiredExactIDs.isSubset(of: exactIDs),
                      "Exact vectors missing from the vendored copy: \(Self.requiredExactIDs.subtracting(exactIDs).sorted())")
        XCTAssertTrue(Self.requiredRefuseIDs.isSubset(of: refuseIDs),
                      "Refuse vectors missing from the vendored copy: \(Self.requiredRefuseIDs.subtracting(refuseIDs).sorted())")
    }

    // MARK: - 2. Accept vectors import and match `expected`

    /// Every accept vector, encoded the way the minter encodes it, parses
    /// through the app's import entry and lands on the fields the fixture
    /// says. `mint` is ignored here on purpose — see the file header.
    func testEveryAcceptVectorImportsAndMatchesExpected() throws {
        let fixture = try loadFixture()

        for entry in fixture.accept {
            let id = id(of: entry)
            XCTAssertEqual(entry["import"] as? String, "accept",
                           "[\(id)] every row of the accept table must say import: accept.")
            do {
                let expected = try XCTUnwrap(entry["expected"] as? [String: Any],
                                             "[\(id)] an accept vector must carry `expected`.")
                let code = try encodeCode(expected)

                switch PairingPayload.parse(code) {
                case .failure(let error):
                    XCTFail("[\(id)] the app REFUSED a vector the fixture marks import: accept — \(error)")
                case .success(let payload):
                    try assertPayload(payload, matches: expected, id: id)
                }
            } catch {
                XCTFail("[\(id)] could not be graded: \(error)")
            }
        }
    }

    // MARK: - 3. Exact codes parse verbatim

    /// The three byte-pinned codes are handed to the parser EXACTLY as the
    /// fixture prints them (no re-encoding), and each must decode to the
    /// fixture's stated `json` and land on the fields that JSON describes.
    func testExactCodesParseVerbatimAndDecodeToTheirStatedJSON() throws {
        let fixture = try loadFixture()

        for entry in fixture.exact {
            let id = id(of: entry)
            do {
                let code = try XCTUnwrap(entry["code"] as? String, "[\(id)] an exact vector must carry `code`.")
                let jsonText = try XCTUnwrap(entry["json"] as? String, "[\(id)] an exact vector must carry `json`.")

                // Fixture self-check: the code carries exactly the stated JSON.
                let body = try XCTUnwrap(decodedBody(ofCode: code), "[\(id)] the exact code must be prefix + base64.")
                XCTAssertEqual(body, jsonText.data(using: .utf8), "[\(id)] the exact code must decode to its stated `json` bytes.")

                let expected = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
                    "[\(id)] `json` must be a JSON object."
                )

                switch PairingPayload.parse(code) {
                case .failure(let error):
                    XCTFail("[\(id)] the app REFUSED a byte-pinned code the minter prints — \(error)")
                case .success(let payload):
                    try assertPayload(payload, matches: expected, id: id)
                }
            } catch {
                XCTFail("[\(id)] could not be graded: \(error)")
            }
        }
    }

    // MARK: - 4. Looser than the validator — loopback and the stricter-than-app rows

    /// Every accept vector the VALIDATOR refuses (`mint: fail`) must still
    /// IMPORT. The load-bearing rows are the self-only ones — loopback /
    /// `localhost` / `::1`, including on the file-server URL — which
    /// `--check-code` refuses in a code for a phone (the minter still writes
    /// them) but which a Mac pairing against its own gateway needs (file
    /// header, "Looser than the validator"). The other
    /// rows pin the app's tolerant decode: a missing `auth` reads as bearer, a
    /// token is only required to be non-empty, the payload has no size bound,
    /// a `/v1` tail is stored as written, a token under `auth: none` is
    /// dropped, and a null conditional field reads as absent. Tightening any
    /// of these to match the validator is a product decision, and it must
    /// fail here first.
    func testVectorsTheValidatorRefusesToMintStillImport() throws {
        let fixture = try loadFixture()

        let validatorRefused = fixture.accept.filter { ($0["mint"] as? String) == "fail" }
        XCTAssertFalse(validatorRefused.isEmpty,
                       "The fixture should carry mint: fail / import: accept rows — the divergence this test exists for.")

        // Named, not counted: a future revision that dropped one of the three
        // while keeping the count would otherwise still pass.
        let selfOnlyIDs = Set(validatorRefused
            .filter { ($0["mintReason"] as? String) == "address-only-reachable-from-the-gateway-itself" }
            .map(id(of:)))
        let loopbackTrio: Set<String> = [
            "self-only-loopback-https",          // 127.0.0.1
            "self-only-localhost-plain-http",    // localhost
            "self-only-ipv6-loopback-https",     // ::1
        ]
        XCTAssertTrue(loopbackTrio.isSubset(of: selfOnlyIDs),
                      "The loopback trio (127.0.0.1 / localhost / ::1) must be present as import: accept rows; missing: \(loopbackTrio.subtracting(selfOnlyIDs).sorted())")

        for entry in validatorRefused {
            let id = id(of: entry)
            XCTAssertEqual(entry["import"] as? String, "accept",
                           "[\(id)] a mint: fail row in the accept table still says import: accept.")
            do {
                let expected = try XCTUnwrap(entry["expected"] as? [String: Any])
                let code = try encodeCode(expected)
                switch PairingPayload.parse(code) {
                case .failure(let error):
                    XCTFail("[\(id)] the app must import what the validator refuses (mintReason: \(entry["mintReason"] as? String ?? "?")) — got \(error)")
                case .success(let payload):
                    try assertPayload(payload, matches: expected, id: id)
                }
            } catch {
                XCTFail("[\(id)] could not be graded: \(error)")
            }
        }
    }

    /// Base64 with MORE padding than its length needs still imports: the parser
    /// re-pads to a multiple of four and `Data(base64Encoded:)` then ignores any
    /// run of trailing `=` (measured on this toolchain: `eyJ2IjoxfQ==` followed
    /// by one to four extra `=` all decode to `{"v":1}`). `--check-code` refuses
    /// that shape as `malformed-base64` — its padding rule is exact, the safe
    /// direction for a tool that can only refuse — so this is one more place the
    /// validator is stricter than the app, pinned here because the validator's
    /// documentation states the divergence and a parser tightened to match it
    /// would have to change this test first. The probe code is the fixture's own
    /// byte-pinned openclaw code with `=` appended, so nothing here is invented.
    func testOverPaddedBase64StillImportsUnlikeTheValidator() throws {
        let fixture = try loadFixture()
        let exact = try XCTUnwrap(fixture.exact.first { id(of: $0) == "exact-bearer-https-openclaw" },
                                  "The byte-pinned openclaw code must be present.")
        let code = try XCTUnwrap(exact["code"] as? String)
        XCTAssertTrue(code.hasSuffix("="), "The probe needs a code that already ends in padding.")
        for extra in ["=", "==", "===", "===="] {
            switch PairingPayload.parse(code + extra) {
            case .failure(let error):
                XCTFail("The app REFUSED an over-padded code (\(extra.count) extra `=`) — either the parser was tightened to the validator's exact-padding rule, or Foundation's base64 decoder on this toolchain stopped ignoring a run of trailing `=`; find out which, then update MANUAL.md's stricter-than-app list and this pin together. Got \(error)")
            case .success(let payload):
                XCTAssertEqual(payload.kind, .builtin(.openclaw), "over-padded (+\(extra)) kind")
                XCTAssertEqual(payload.url.absoluteString, "https://ai.example.com", "over-padded (+\(extra)) url")
            }
        }
    }

    // MARK: - 5. Refuse vectors are rejected

    /// Every refuse vector is handed to the parser verbatim and must be
    /// rejected. Where the category maps to one `PairingParseError` case, that
    /// case is asserted; for a recorded-gap category, rejection alone. A
    /// vector that also states its decoded `payload` is self-checked: the code
    /// must decode to exactly that text, so the row grades the code it claims to.
    func testEveryRefuseVectorIsRejected() throws {
        let fixture = try loadFixture()

        for entry in fixture.refuse {
            let id = id(of: entry)
            XCTAssertEqual(entry["import"] as? String, "refuse",
                           "[\(id)] every row of the refuse table must say import: refuse.")
            do {
                let code = try XCTUnwrap(entry["code"] as? String, "[\(id)] a refuse vector must carry `code`.")
                let category = try XCTUnwrap(entry["reason"] as? String, "[\(id)] a refuse vector must carry `reason`.")

                if let payloadText = entry["payload"] as? String {
                    XCTAssertEqual(decodedBody(ofCode: code), payloadText.data(using: .utf8),
                                   "[\(id)] the code must decode to its stated `payload` text.")
                }

                switch PairingPayload.parse(code) {
                case .success:
                    XCTFail("[\(id)] the app ACCEPTED a vector the fixture marks import: refuse (\(category)).")
                case .failure(let error):
                    if let expectedError = Self.expectedParseError(forCategory: category) {
                        XCTAssertEqual(error, expectedError,
                                       "[\(id)] category \(category) maps to \(expectedError), the parser said \(error).")
                    } else if let expectedError = Self.expectedParseErrorForGapVector[id] {
                        // Recorded-gap category, but THIS row's reason is known.
                        XCTAssertEqual(error, expectedError,
                                       "[\(id)] is refused for its own reason (\(expectedError)), the parser said \(error) — the recorded-gap note above is stale.")
                    }
                    // Any other recorded-gap row: rejection is the whole assertion.
                }
            } catch {
                XCTFail("[\(id)] could not be graded: \(error)")
            }
        }
    }

    // MARK: - 6. The mapping covers the fixture's whole vocabulary

    /// A category the fixture uses must be either mapped to a parser case or
    /// listed as a recorded gap — so a NEW category arriving with a future
    /// revision fails loudly instead of quietly being graded rejection-only.
    func testEveryRefuseCategoryIsMappedOrARecordedGap() throws {
        let fixture = try loadFixture()

        let categories = Set(fixture.refuse.compactMap { $0["reason"] as? String })
        XCTAssertFalse(categories.isEmpty, "The refuse table must name at least one reason category.")

        for category in categories.sorted() {
            let mapped = Self.expectedParseError(forCategory: category) != nil
            let recordedGap = Self.unmappedCategories.contains(category)
            XCTAssertTrue(mapped || recordedGap,
                          "Refuse category '\(category)' is neither mapped to a PairingParseError case nor listed in unmappedCategories.")
            XCTAssertFalse(mapped && recordedGap,
                           "Refuse category '\(category)' is both mapped and listed as a gap — pick one.")
        }
    }
}

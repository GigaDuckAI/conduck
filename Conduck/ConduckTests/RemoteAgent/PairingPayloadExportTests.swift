// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingPayloadExportTests.swift
//
// Locks `PairingPayloadExport.serialize` to the `conduck-connect` wizard's
// python emission (`spec.md` "Pairing payload v1"). The three GOLDEN VECTORS
// are byte-for-byte fixtures produced by the shell emitter for known inputs —
// any drift (key order, escaping, base64) fails here. Plus: the python-style
// string escaper's unit cases, structural omission rules, the OpenRouter export
// guard, and a full export→parse round-trip proving the emitter and
// `PairingPayload.parse` stay byte-compatible.
//
// The serializer, escaper and structural rules are pure logic — no signing, no
// Keychain (they are static; the OpenRouter guard trips before any actor read).
// The `makePayload` cases that assert WHICH delivery properties a real export
// states do touch the store, so they skip on an unsigned host the way every
// Keychain-dependent suite here does, and clean their own per-ref keys. Synthetic
// tokens only.

import XCTest
@testable import Conduck

final class PairingPayloadExportTests: XCTestCase {

    // MARK: - Fixtures

    /// V1 — minimal openclaw, bearer, tailscale transport, file lane.
    private func vector1() -> PairingPayloadExport.Payload {
        PairingPayloadExport.Payload(
            gateway: PairingPayloadExport.Gateway(
                kind: .builtin(.openclaw),
                url: "https://gw.tail1234.ts.net:8443",
                authScheme: .bearer,
                token: "tok_ABC123",
                model: nil
            ),
            transport: "tailscale",
            fileServer: PairingPayloadExport.FileServer(
                url: "https://gw.tail1234.ts.net:9443",
                credential: "a1b2c3d4e5f60718"
            )
        )
    }

    private let vector1Expected = "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJvcGVuY2xhdyIsInVybCI6Imh0dHBzOi8vZ3cudGFpbDEyMzQudHMubmV0Ojg0NDMiLCJhdXRoIjoiYmVhcmVyIiwidG9rZW4iOiJ0b2tfQUJDMTIzIn0sInRyYW5zcG9ydCI6InRhaWxzY2FsZSIsImZpbGVTZXJ2ZXIiOnsidXJsIjoiaHR0cHM6Ly9ndy50YWlsMTIzNC50cy5uZXQ6OTQ0MyIsImNyZWRlbnRpYWwiOiJhMWIyYzNkNGU1ZjYwNzE4In19"

    /// V2 — maximal custom: unicode name, "/"+"="+"+" in the token, model,
    /// cloudflare transport. Exercises escaping + every optional key.
    private func vector2() -> PairingPayloadExport.Payload {
        PairingPayloadExport.Payload(
            gateway: PairingPayloadExport.Gateway(
                // "My Böx — lab": ö = U+00F6, em dash = U+2014 (spelled out so the
                // fixture can't drift to an en dash / precomposed variant).
                kind: .custom(name: "My B\u{00F6}x \u{2014} lab"),
                url: "https://ai.example.com",
                authScheme: .bearer,
                token: "sk-test/77+q==",
                model: "llama-3.3-70b"
            ),
            transport: "cloudflare",
            fileServer: PairingPayloadExport.FileServer(
                url: "https://ai.example.com:8444",
                credential: "deadbeefcafe0123"
            )
        )
    }

    private let vector2Expected = "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJ1cmwiOiJodHRwczovL2FpLmV4YW1wbGUuY29tIiwiYXV0aCI6ImJlYXJlciIsIm5hbWUiOiJNeSBCXHUwMGY2eCBcdTIwMTQgbGFiIiwidG9rZW4iOiJzay10ZXN0Lzc3K3E9PSIsIm1vZGVsIjoibGxhbWEtMy4zLTcwYiJ9LCJ0cmFuc3BvcnQiOiJjbG91ZGZsYXJlIiwiZmlsZVNlcnZlciI6eyJ1cmwiOiJodHRwczovL2FpLmV4YW1wbGUuY29tOjg0NDQiLCJjcmVkZW50aWFsIjoiZGVhZGJlZWZjYWZlMDEyMyJ9fQ=="

    /// V3 — keyless custom, no lane, no model. No token key; no fileServer key.
    private func vector3() -> PairingPayloadExport.Payload {
        PairingPayloadExport.Payload(
            gateway: PairingPayloadExport.Gateway(
                kind: .custom(name: "Ollama box"),
                url: "https://ollama.lan.example.com",
                authScheme: .none,
                token: nil,
                model: nil
            ),
            transport: "public",
            fileServer: nil
        )
    }

    private let vector3Expected = "conduck-setup:v1:eyJ2IjoxLCJnYXRld2F5Ijp7ImtpbmQiOiJjdXN0b20iLCJ1cmwiOiJodHRwczovL29sbGFtYS5sYW4uZXhhbXBsZS5jb20iLCJhdXRoIjoibm9uZSIsIm5hbWUiOiJPbGxhbWEgYm94In0sInRyYW5zcG9ydCI6InB1YmxpYyJ9"

    /// Strip the prefix, base64-decode, and return the raw minified JSON for
    /// structural inspection.
    private func decodedJSON(_ setupCode: String) -> String {
        XCTAssertTrue(setupCode.hasPrefix(PairingPayloadExport.stringPrefix))
        let base64 = String(setupCode.dropFirst(PairingPayloadExport.stringPrefix.count))
        guard let data = Data(base64Encoded: base64),
              let json = String(data: data, encoding: .utf8) else {
            XCTFail("base64/utf8 decode failed")
            return ""
        }
        return json
    }

    // MARK: - Golden vectors (byte-exact)

    func testVector1ByteExact() {
        XCTAssertEqual(PairingPayloadExport.serialize(vector1()), vector1Expected)
    }

    func testVector2ByteExact() {
        XCTAssertEqual(PairingPayloadExport.serialize(vector2()), vector2Expected)
    }

    func testVector3ByteExact() {
        XCTAssertEqual(PairingPayloadExport.serialize(vector3()), vector3Expected)
    }

    // MARK: - python-style string escaping

    func testEscaping_slashNotEscaped() {
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a/b"), "\"a/b\"")
        // The V2 token carries "/", "+", "=" — none are JSON-special, all verbatim.
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("sk-test/77+q=="), "\"sk-test/77+q==\"")
    }

    func testEscaping_nonASCII() {
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{00F6}"), "\"\\u00f6\"")   // ö
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{2014}"), "\"\\u2014\"")   // em dash
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("My B\u{00F6}x \u{2014} lab"),
                       "\"My B\\u00f6x \\u2014 lab\"")
    }

    func testEscaping_astralSurrogatePair() {
        // U+1F600 😀 → UTF-16 surrogate pair d83d/de00, each \u-escaped lowercase.
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{1F600}"), "\"\\ud83d\\ude00\"")
    }

    func testEscaping_quotesBackslashControls() {
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a\tb"), "\"a\\tb\"")
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("a\rb"), "\"a\\rb\"")
    }

    func testEscaping_delAndLowControl() {
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{7F}"), "\"\\u007f\"")   // DEL (>0x7E)
        XCTAssertEqual(PairingPayloadExport.pythonJSONString("\u{01}"), "\"\\u0001\"")   // SOH (<0x20)
    }

    // MARK: - Structural omission rules

    func testFileServerOmittedWhenLaneAbsent() {
        let json = decodedJSON(PairingPayloadExport.serialize(vector3()))
        XCTAssertFalse(json.contains("fileServer"))
        // ...and present when the lane exists.
        XCTAssertTrue(decodedJSON(PairingPayloadExport.serialize(vector1())).contains("\"fileServer\""))
    }

    func testKeylessOmitsTokenKey() {
        let json = decodedJSON(PairingPayloadExport.serialize(vector3()))
        XCTAssertFalse(json.contains("\"token\""))
        XCTAssertTrue(json.contains("\"auth\":\"none\""))
        // Bearer keeps the token key.
        XCTAssertTrue(decodedJSON(PairingPayloadExport.serialize(vector1())).contains("\"token\":\"tok_ABC123\""))
    }

    func testNameKeyCustomOnly() {
        // Custom carries a name; a built-in never does.
        XCTAssertTrue(decodedJSON(PairingPayloadExport.serialize(vector3())).contains("\"name\":\"Ollama box\""))
        XCTAssertFalse(decodedJSON(PairingPayloadExport.serialize(vector1())).contains("\"name\""))
    }

    func testModelOmittedWhenNilOrEmpty() {
        XCTAssertFalse(decodedJSON(PairingPayloadExport.serialize(vector1())).contains("\"model\""))
        XCTAssertTrue(decodedJSON(PairingPayloadExport.serialize(vector2())).contains("\"model\":\"llama-3.3-70b\""))
    }

    /// A locally stored certificate pin is a per-device tightening the user typed
    /// in for a certificate THIS device already trusts. Emitting it would push
    /// that private narrowing onto another device as though it were a fact about
    /// the server — and break that device on ordinary certificate renewal. The
    /// wire format has no field for it, and no representable payload can produce
    /// one.
    func testNoVectorEverEmitsACertificateField() {
        for code in [vector1(), vector2(), vector3()].map(PairingPayloadExport.serialize) {
            XCTAssertFalse(decodedJSON(code).contains("certFP"),
                           "A setup code must never carry a certificate digest.")
        }
    }

    // MARK: - fileServer emitted only when url AND credential both non-empty

    // The serializer must honor the wizard's `if FS_URL and FS_CRED` truthiness
    // for EVERY representable input, not just the ones `makePayload` builds: a
    // non-nil FileServer with an empty url (or empty credential) omits the whole
    // block, byte-identically to `fileServer == nil`. Base payload = vector1's
    // gateway/transport with the lane swapped, so "block absent" is pinned
    // against the same reference bytes the golden vectors assert.

    func testFileServerEmptyURLOmitsBlock() {
        let base = vector1()
        let nilLane = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: nil
            )
        )
        let emptyURL = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: PairingPayloadExport.FileServer(
                    url: "",
                    credential: "a1b2c3d4e5f60718"
                )
            )
        )
        XCTAssertEqual(emptyURL, nilLane)
        XCTAssertFalse(decodedJSON(emptyURL).contains("fileServer"))
    }

    func testFileServerEmptyCredentialOmitsBlock() {
        let base = vector1()
        let nilLane = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: nil
            )
        )
        let emptyCred = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: PairingPayloadExport.FileServer(
                    url: "https://gw.tail1234.ts.net:9443",
                    credential: ""
                )
            )
        )
        XCTAssertEqual(emptyCred, nilLane)
        XCTAssertFalse(decodedJSON(emptyCred).contains("fileServer"))
    }

    // MARK: - File-lane delivery properties

    /// A lane that states none of the three delivery properties must serialize to
    /// the bytes the wizard produces — which is exactly what the golden vectors
    /// already pin, so this asserts the keys are ABSENT rather than emitted as
    /// `null`. Absence is what makes the addition compatible in both directions:
    /// the wizard states none of them, and an older importer sees a block it
    /// already understands.
    func testDeliveryPropertiesOmittedWhenUnstated() {
        let json = decodedJSON(PairingPayloadExport.serialize(vector1()))
        XCTAssertFalse(json.contains("folderCapable"))
        XCTAssertFalse(json.contains("autoDeliver"))
        XCTAssertFalse(json.contains("filenamePolicy"))
        XCTAssertFalse(json.contains("null"),
                       "Conditional fields are omitted, never emitted as null (PAYLOAD.md).")
    }

    /// A stated lane emits all three, in the fixed order the block documents, after
    /// `credential`. Key order is asserted as one substring so a reordering — which
    /// a tolerant parser would swallow — still fails here, the same way the golden
    /// vectors pin the rest of the emission. The serializer states whatever the
    /// payload holds; WHICH values a real export puts there is `makePayload`'s rule,
    /// asserted separately.
    func testDeliveryPropertiesEmittedInFixedOrderWhenStated() {
        let base = vector1()
        let code = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: PairingPayloadExport.FileServer(
                    url: "https://gw.tail1234.ts.net:9443",
                    credential: "a1b2c3d4e5f60718",
                    folderCapable: false,
                    autoDeliver: false,
                    filenamePolicy: "preserve"
                )
            )
        )
        XCTAssertTrue(decodedJSON(code).contains(
            "\"credential\":\"a1b2c3d4e5f60718\",\"folderCapable\":false,\"autoDeliver\":false,\"filenamePolicy\":\"preserve\""
        ), "fileServer key order is part of the wire shape: url, credential, folderCapable, autoDeliver, filenamePolicy.")
    }

    /// A setup code describes a SERVER; readiness is the scanning device's own proof
    /// that IT can reach, trust and authenticate against that server. No field
    /// carries it, and no representable payload can invent one — the same doctrine
    /// that keeps a certificate pin off the wire.
    func testNoRepresentablePayloadEmitsAReadinessField() {
        let base = vector1()
        let maximalLane = PairingPayloadExport.serialize(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: PairingPayloadExport.FileServer(
                    url: "https://gw.tail1234.ts.net:9443",
                    credential: "a1b2c3d4e5f60718",
                    folderCapable: true,
                    autoDeliver: true,
                    filenamePolicy: "preserve"
                )
            )
        )
        for code in [vector1(), vector2(), vector3()].map(PairingPayloadExport.serialize) + [maximalLane] {
            XCTAssertFalse(decodedJSON(code).contains("available"),
                           "A setup code must never assert that a file lane is ready.")
            XCTAssertFalse(decodedJSON(code).contains("testedLocally"))
        }
    }

    // MARK: - makePayload: WHICH delivery properties a real export states

    /// The ref these cases configure. A built-in keeps the fixture to per-ref slots
    /// this file can clear itself — no roster row, no draft lifecycle.
    private static let exportRef = RemoteAgentRef.builtin(.hermes)

    /// Configure a keyless gateway + a file lane on `exportRef`, skipping on a host
    /// whose Keychain refuses the access-group write (unsigned build) — same posture
    /// as the pairing-import suite's `requireFileServerKeychainOrSkip`.
    private func seedExportableLaneOrSkip() async throws {
        let ref = Self.exportRef
        do {
            try await SettingsManager.shared.setFileServerCredential("a1b2c3d4e5f60718", for: ref)
        } catch {
            throw XCTSkip("Keychain access-group write requires a signed build (unsigned: \(error)).")
        }
        _ = await SettingsManager.shared.setRemoteAgentURL(
            URL(string: "https://gw.example.test:18789"), for: ref
        )
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: ref)
        await SettingsManager.shared.commitFileTransferConfig(
            url: URL(string: "https://gw.example.test:8443")!,
            pin: nil,
            folderCapable: nil,
            available: false,
            for: ref
        )
    }

    /// Clear every per-ref slot the export fixtures write. Runs whether the case
    /// passed or failed, so a left-over lane can't leak into the pure cases (or into
    /// another suite reading the same ref).
    private func clearExportedLane() async {
        let ref = Self.exportRef
        for key in [
            Constants.remoteAgentURLKey(for: ref),
            Constants.remoteAgentAuthSchemeKey(for: ref),
            Constants.fileServerURLKey(for: ref),
            Constants.fileTransferAvailableKey(for: ref),
            Constants.fileServerFolderCapableKey(for: ref),
            Constants.fileServerAutoDeliverKey(for: ref),
            Constants.fileServerFilenamePolicyKey(for: ref),
            Constants.fileServerTestedLocallyKey(for: ref),
            // The stamp that binds that flag to a server. It rides the shared
            // singleton like everything else here, so a leftover would follow
            // this ref into whichever suite runs next.
            Constants.fileServerTestedLocallyStampKey(for: ref)
        ] {
            TestStores.defaults.removeObject(forKey: key)
            TestStores.kvs.removeObject(forKey: key)
        }
        try? await SettingsManager.shared.clearFileServerCredential(for: ref)
    }

    /// The everyday lane — never locally tested, permission at its default — states
    /// NOTHING. A code that repeats the app's own defaults carries no information,
    /// and `folderCapable:true` from an unprobed lane would be a claim about the
    /// server made on no evidence at all.
    func testMakePayloadStatesNothingForADefaultUntestedLane() async throws {
        try await seedExportableLaneOrSkip()
        addTeardownBlock { await self.clearExportedLane() }

        let payload = try await PairingPayloadExport.makePayload(for: Self.exportRef)
        XCTAssertEqual(payload.fileServer?.url, "https://gw.example.test:8443")
        XCTAssertNil(payload.fileServer?.folderCapable,
                     "An unprobed lane has no verdict to publish.")
        XCTAssertNil(payload.fileServer?.autoDeliver,
                     "The default permission is what the importer already assumes.")
        XCTAssertNil(payload.fileServer?.filenamePolicy)
    }

    /// A MEASURED `folderCapable:false` is the one capability worth carrying: the
    /// app's default is true, so a scanning device that isn't told would mint nested
    /// keys against a server that rejects them. `testedLocally` is the gate rather
    /// than `available`, because that is the flag meaning "a staged Test Connection
    /// ran HERE" — `available` can arrive from a peer through iCloud KVS, and it
    /// drops on a later reachability failure that leaves the folder verdict standing.
    func testMakePayloadStatesAMeasuredFolderIncapability() async throws {
        try await seedExportableLaneOrSkip()
        addTeardownBlock { await self.clearExportedLane() }
        let ref = Self.exportRef

        await SettingsManager.shared.setFileServerFolderCapable(false, for: ref)

        await SettingsManager.shared.setFileServerTestedLocally(false, for: ref)
        var payload = try await PairingPayloadExport.makePayload(for: ref)
        XCTAssertNil(payload.fileServer?.folderCapable,
                     "Without a local measurement there is nothing to state, whatever the stored flag happens to say.")

        await SettingsManager.shared.setFileServerTestedLocally(true, for: ref)
        payload = try await PairingPayloadExport.makePayload(for: ref)
        XCTAssertEqual(payload.fileServer?.folderCapable, false,
                       "A locally measured false must travel — it is the same answer on any device.")
    }

    /// A RESTRICTED permission travels; the permissive default does not. The importer
    /// refuses to let a code grant the permission, so emitting `true` would put a
    /// claim on the wire that nothing will ever honour.
    func testMakePayloadStatesOnlyARestrictedAutoDeliver() async throws {
        try await seedExportableLaneOrSkip()
        addTeardownBlock { await self.clearExportedLane() }
        let ref = Self.exportRef

        await SettingsManager.shared.commitFileDeliveryPolicy(autoDeliver: false, for: ref)
        var payload = try await PairingPayloadExport.makePayload(for: ref)
        XCTAssertEqual(payload.fileServer?.autoDeliver, false)

        await SettingsManager.shared.commitFileDeliveryPolicy(autoDeliver: true, for: ref)
        payload = try await PairingPayloadExport.makePayload(for: ref)
        XCTAssertNil(payload.fileServer?.autoDeliver,
                     "A code never states the permissive default — the importer would refuse it anyway.")
    }

    /// No export, under any stored state, may put a readiness claim on the wire. The
    /// exporter's own lane is deliberately seeded READY here, which is the state a
    /// naive implementation would leak.
    func testMakePayloadNeverStatesReadinessEvenFromAReadyLane() async throws {
        try await seedExportableLaneOrSkip()
        addTeardownBlock { await self.clearExportedLane() }
        let ref = Self.exportRef

        await SettingsManager.shared.commitFileTransferVerdict(
            available: true, folderCapable: true, for: ref
        )
        let code = try await PairingPayloadExport.makeSetupCode(for: ref)
        XCTAssertFalse(decodedJSON(code).contains("available"),
                       "Readiness is this device's proof about itself; it must never ride a setup code.")
        XCTAssertFalse(decodedJSON(code).contains("certFP"))
    }

    // MARK: - Export → parse round-trip (byte-compatibility with the parser)

    func testRoundTripVector1() {
        assertRoundTrips(vector1(), expected: PairingPayload(
            kind: .builtin(.openclaw),
            url: URL(string: "https://gw.tail1234.ts.net:8443")!,
            authScheme: .bearer,
            token: "tok_ABC123",
            model: nil,
            fileServer: PairingPayload.FileServer(
                url: URL(string: "https://gw.tail1234.ts.net:9443")!,
                credential: "a1b2c3d4e5f60718"
            ),
            transport: .tailscale
        ))
    }

    func testRoundTripVector2() {
        assertRoundTrips(vector2(), expected: PairingPayload(
            kind: .custom(name: "My B\u{00F6}x \u{2014} lab"),
            url: URL(string: "https://ai.example.com")!,
            authScheme: .bearer,
            token: "sk-test/77+q==",
            model: "llama-3.3-70b",
            fileServer: PairingPayload.FileServer(
                url: URL(string: "https://ai.example.com:8444")!,
                credential: "deadbeefcafe0123"
            ),
            transport: .cloudflare
        ))
    }

    func testRoundTripVector3() {
        assertRoundTrips(vector3(), expected: PairingPayload(
            kind: .custom(name: "Ollama box"),
            url: URL(string: "https://ollama.lan.example.com")!,
            authScheme: .none,
            token: nil,
            model: nil,
            fileServer: nil,
            transport: .publicCert
        ))
    }

    /// The emitter and the parser must agree about the delivery properties, in both
    /// the stated and the unstated shape — a round-trip is the only assertion that
    /// catches a key name drifting on one side only.
    func testRoundTripCarriesStatedDeliveryProperties() {
        let base = vector1()
        assertRoundTrips(
            PairingPayloadExport.Payload(
                gateway: base.gateway,
                transport: base.transport,
                fileServer: PairingPayloadExport.FileServer(
                    url: "https://gw.tail1234.ts.net:9443",
                    credential: "a1b2c3d4e5f60718",
                    folderCapable: false,
                    autoDeliver: false,
                    filenamePolicy: "preserve"
                )
            ),
            expected: PairingPayload(
                kind: .builtin(.openclaw),
                url: URL(string: "https://gw.tail1234.ts.net:8443")!,
                authScheme: .bearer,
                token: "tok_ABC123",
                model: nil,
                fileServer: PairingPayload.FileServer(
                    url: URL(string: "https://gw.tail1234.ts.net:9443")!,
                    credential: "a1b2c3d4e5f60718",
                    folderCapable: false,
                    autoDeliver: false,
                    filenamePolicy: "preserve"
                ),
                transport: .tailscale
            )
        )
    }

    /// The unstated shape round-trips to all-nil — "the code said nothing", which is
    /// what the importer needs in order to leave the destination's own stored values
    /// alone instead of resetting them to a default the code never named. Vector 1's
    /// lane already carries no properties, so this is the OLD-payload path too.
    func testRoundTripOfAnUnstatedLaneYieldsNoClaims() {
        guard case .success(let parsed) = PairingPayload.parse(
            PairingPayloadExport.serialize(vector1())
        ) else {
            XCTFail("vector 1 must re-parse")
            return
        }
        XCTAssertNotNil(parsed.fileServer)
        XCTAssertNil(parsed.fileServer?.folderCapable)
        XCTAssertNil(parsed.fileServer?.autoDeliver)
        XCTAssertNil(parsed.fileServer?.filenamePolicy)
    }

    private func assertRoundTrips(
        _ payload: PairingPayloadExport.Payload,
        expected: PairingPayload,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let code = PairingPayloadExport.serialize(payload)
        switch PairingPayload.parse(code) {
        case .success(let parsed):
            XCTAssertEqual(parsed, expected, file: file, line: line)
        case .failure(let error):
            XCTFail("exported code failed to re-parse: \(error)", file: file, line: line)
        }
    }

    // MARK: - OpenRouter export guard

    func testOpenRouterExportRefused() async {
        do {
            _ = try await PairingPayloadExport.makePayload(for: .builtin(.openrouter))
            XCTFail("OpenRouter must never be exportable")
        } catch let error as PairingPayloadExport.ExportError {
            XCTAssertEqual(error, .notExportable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

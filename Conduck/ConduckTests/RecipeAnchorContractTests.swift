// SPDX-License-Identifier: Apache-2.0

// Conduck
// RecipeAnchorContractTests.swift
//
// LOCAL FREEZE CHECK for `RecipeAnchor` — the app half of an app↔website
// contract. The CANONICAL cross-check lives in the monorepo website build,
// whose postbuild guard parses `RecipeAnchor.swift` alongside
// `website/src/lib/setup-anchors.ts` and fails if the two disagree. THIS file
// cannot see the website at all: the app repo is standalone and public, and a
// test that needed a sibling checkout would either skip silently in this repo's
// own CI or fail for everyone who clones only the app.
//
// So what this file freezes is the app's SIDE of the contract, hardcoded, so a
// change to it is visible in a diff here rather than only in a different repo's
// build log:
//
//   1. The fragment SET, as literal strings. `allCases` raw values must equal a
//      hand-written list — symbol == symbol would be a tautology that a rename
//      passes straight through, and a rename is precisely the failure mode
//      (an installed app keeps emitting the old fragment forever).
//   2. The code → fragment map, EXHAUSTIVELY over every code the taxonomy
//      emits, INCLUDING the deliberate nils. A code that silently GAINS a link
//      is as much a defect as one that loses it: it lands a stuck user on a
//      page about certificates when their problem is an unconfigured gateway.
//   3. Lane collapse — the four members of each certificate family agree — and
//      that distinct families stay distinct.
//   4. The exact rendered URL per case, character for character, base included.
//      A missing or doubled slash is a 404, and a 404 is the one outcome worse
//      than no link at all. THIS IS THE ONLY GUARD ON THE CONCATENATED URL
//      anywhere in either repo: the website's guard checks the base and the
//      fragment set SEPARATELY and never the join, so nothing outside this file
//      would notice `base + "/#" + fragment`. Asserted twice on purpose — once
//      against literals, once derived from the base and the raw value, because
//      a literal table can be silently "repaired" to match a broken change.
//   5. Every mapped code is `isTroubleshootable`. The link rides on surfaces
//      that a non-troubleshootable code never reaches, so a mapping outside
//      that set would be dead weight nobody would notice was dead.
//
// APPEND-ONLY. Once a public build emits these fragments, a raw value may be
// added but never renamed or removed. Editing this file to match a rename is
// the wrong repair — the rename is the defect.

import XCTest
@testable import Conduck

final class RecipeAnchorContractTests: XCTestCase {

    // MARK: - 1. The frozen fragment set

    /// The app-linked anchors, spelled out. Mirrors `APP_LINKED_ANCHORS` in
    /// `website/src/lib/setup-anchors.ts`.
    private static let frozenFragments: Set<String> = [
        "cert-untrusted",
        "pin-mismatch",
        "pin-key-unsupported",
        "plain-http-blocked",
        "unreachable",
        "timeout",
        "auth",
        "tailscale-serve",
    ]

    func testTheFragmentSetIsFrozen() {
        XCTAssertEqual(Set(RecipeAnchor.allCases.map(\.rawValue)), Self.frozenFragments,
                       "A fragment was renamed, added or removed. Installed apps keep emitting the fragment they were built with, so a rename turns a shipped link into a page that scrolls nowhere — and the website's own guard will fail too.")
        XCTAssertEqual(RecipeAnchor.allCases.count, Self.frozenFragments.count,
                       "Two cases share a raw value.")
    }

    func testEveryFragmentIsKebabCase() {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz-")
        for anchor in RecipeAnchor.allCases {
            XCTAssertTrue(anchor.rawValue.unicodeScalars.allSatisfy(allowed.contains),
                          "\(anchor.rawValue) is not lowercase kebab-case; the site's anchor guard rejects it.")
            XCTAssertFalse(anchor.rawValue.hasPrefix("-"), "\(anchor.rawValue) starts with a hyphen.")
            XCTAssertFalse(anchor.rawValue.hasSuffix("-"), "\(anchor.rawValue) ends with a hyphen.")
        }
    }

    // MARK: - 2. The exhaustive code table

    /// EVERY numeric code the taxonomy emits, with the fragment it must map to
    /// — `nil` where the page deliberately has nothing to offer. Both halves
    /// are assertions: a nil row failing means a code silently GAINED a link.
    private static let codeTable: [(code: Int, fragment: String?)] = [
        (1,  nil),                     // networkError — generic carrier
        (2,  nil),                     // invalidURL — the address is malformed, not refused
        (3,  nil),                     // noInternetConnection — device-local
        (4,  nil),                     // requestTimeout — lane-ambiguous (STT/TTS/gateway)
        (5,  nil),                     // persistentNetworkFailure — device-local
        (6,  nil),                     // invalidResponse
        (7,  nil),                     // decodingError
        (8,  nil),                     // sttAuthFailed — the provider's key, not a gateway
        (9,  nil),                     // invalidRequest
        (10, nil),                     // apiFailure — catch-all
        (11, nil),                     // audioInvalid
        (12, nil),                     // remoteAgentNotConfigured — config, in-app remedy
        (13, nil),                     // sttQuotaExceeded
        (14, nil),                     // audioMissingData
        (15, nil),                     // settingsLoadFailed
        (16, nil),                     // sttTooManyRequests
        (17, nil),                     // sttServerError
        (18, nil),                     // appleSpeechModelNotInstalled
        (19, "unreachable"),           // remoteAgentUnreachable
        (20, nil),                     // sttProviderUnreachable — lane-ambiguous
        (21, nil),                     // noSpeechDetected
        (22, nil),                     // audioTooLarge
        (23, nil),                     // sttMissingAPIKey
        (24, nil),                     // audioProcessingFailed
        (25, nil),                     // sttDecodingFailure
        (26, "auth"),                  // remoteAgentAuthFailed
        // 27 — reserved gap, never reused.
        (28, "timeout"),               // remoteAgentTimeout
        (29, nil),                     // remoteAgentServerError — the server answered
        (30, "pin-mismatch"),          // remoteAgentCertMismatch
        (31, nil),                     // remoteAgentInvalidResponse
        (32, nil),                     // remoteAgentVisionUnsupported
        (33, nil),                     // remoteAgentImageTooLarge
        (34, nil),                     // sttCustomEndpointNotConfigured — config
        (35, "pin-mismatch"),          // sttCustomCertMismatch
        (36, nil),                     // ttsProviderUnreachable — lane-ambiguous
        (37, nil),                     // ttsSynthesisFailed
        (38, nil),                     // ttsEmptyAudio
        (39, nil),                     // ttsUnauthorized
        (40, nil),                     // ttsRateLimited
        (41, nil),                     // ttsContentBlocked
        (42, nil),                     // ttsCustomEndpointNotConfigured — config
        (43, "pin-mismatch"),          // ttsCustomCertMismatch
        (44, nil),                     // fileTransferNotConfigured — config
        (45, "unreachable"),           // fileTransferUnreachable
        (46, "auth"),                  // fileTransferAuthFailed
        (47, "pin-mismatch"),          // fileTransferCertMismatch
        (48, nil),                     // fileTransferServerError — the server answered
        (49, nil),                     // fileTransferUploadFailed
        (50, nil),                     // fileTransferFileUnavailable
        (51, nil),                     // speechPermissionDenied
        (52, nil),                     // remoteAgentOutOfCredits
        (53, nil),                     // audioMicBusy
        (54, nil),                     // appleSpeechLanguageUnsupported
        (55, nil),                     // remoteAgentModelUnavailable
        (56, nil),                     // remoteAgentContextTooLong
        (57, nil),                     // remoteAgentRateLimited
        (58, nil),                     // remoteAgentEndpointUnexpectedResponse — endpoint shape
        (59, nil),                     // remoteAgentEndpointNotFound — endpoint shape
        (60, nil),                     // remoteAgentModelRequired — endpoint shape
        (61, nil),                     // fileTransferNotAFileServer
        (62, nil),                     // remoteAgentEndpointWrongEnvelope — endpoint shape
        (63, "cert-untrusted"),        // remoteAgentCertUntrusted
        (64, "cert-untrusted"),        // sttCustomCertUntrusted
        (65, "cert-untrusted"),        // ttsCustomCertUntrusted
        (66, "cert-untrusted"),        // fileTransferCertUntrusted
        (67, "pin-key-unsupported"),   // remoteAgentCertKeyUnpinnable
        (68, "pin-key-unsupported"),   // sttCustomCertKeyUnpinnable
        (69, "pin-key-unsupported"),   // ttsCustomCertKeyUnpinnable
        (70, "pin-key-unsupported"),   // fileTransferCertKeyUnpinnable
        (71, nil),                     // remoteAgentUnexpectedStatus — the server answered
        (72, nil),                     // remoteAgentServiceUnavailable — the server answered
        (73, "unreachable"),           // remoteAgentNotEstablished
        (74, nil),                     // remoteAgentDefaultNeedsSetup — config
        (75, nil),                     // sttKeyUnreadable
        (76, nil),                     // turnStoppedBeforeSend — nothing was attempted
        (77, "plain-http-blocked"),    // insecureConnectionBlocked
        (99, nil),                     // unknown — catch-all
    ]

    func testEveryCodeMapsExactlyAsFrozen() {
        for (code, fragment) in Self.codeTable {
            XCTAssertEqual(RecipeAnchor(errorCode: code)?.rawValue, fragment,
                           "Code \(code) should map to \(fragment.map { "#\($0)" } ?? "no link").")
        }
    }

    /// The reserved gap and codes outside the taxonomy get no link — a link is
    /// opt-in, so an unrecognised code must fall through rather than default
    /// into a section.
    func testUnmappedCodesGetNoLink() {
        for code in [0, 27, 78, 98, 100, -1, Int.max] {
            XCTAssertNil(RecipeAnchor(errorCode: code),
                         "Code \(code) has no place on the recipe page.")
        }
    }

    /// The table above must actually cover the taxonomy, or a NEW code could be
    /// added with no row and no failure here.
    func testTheCodeTableCoversEveryCodeTheTaxonomyEmits() {
        let tabled = Set(Self.codeTable.map(\.code))
        // 27 is the reserved gap: `from(errorCode:)` deliberately does not
        // resurrect it, and `testUnmappedCodesGetNoLink` covers it instead.
        let expected = Set(1...77).subtracting([27]).union([99])
        XCTAssertEqual(tabled, expected,
                       "A code was added to (or removed from) AppError without a row here.")
    }

    // MARK: - 3. Lane collapse, and families stay apart

    func testEachCertificateFamilyCollapsesToOneSection() {
        // Gateway / custom STT / custom TTS / file server — four lanes, one
        // cause, one recipe. A user has one server to fix either way.
        XCTAssertEqual(Set([63, 64, 65, 66].compactMap { RecipeAnchor(errorCode: $0) }),
                       [.certUntrusted])
        XCTAssertEqual(Set([30, 35, 43, 47].compactMap { RecipeAnchor(errorCode: $0) }),
                       [.pinMismatch])
        XCTAssertEqual(Set([67, 68, 69, 70].compactMap { RecipeAnchor(errorCode: $0) }),
                       [.pinKeyUnsupported])
        XCTAssertEqual(Set([19, 45, 73].compactMap { RecipeAnchor(errorCode: $0) }),
                       [.unreachable])
        XCTAssertEqual(Set([26, 46].compactMap { RecipeAnchor(errorCode: $0) }),
                       [.auth])
    }

    /// The three certificate verdicts are separate sections on purpose: their
    /// remedies are unrelated (get a trusted cert / re-check a pin / reissue
    /// the key), and merging any two would send half the readers to the wrong
    /// instructions.
    func testTheThreeCertificateVerdictsStayDistinct() {
        let distinct: Set<RecipeAnchor> = [.certUntrusted, .pinMismatch, .pinKeyUnsupported]
        XCTAssertEqual(distinct.count, 3)
    }

    /// A timeout must not collapse into unreachable: only the timeout section
    /// carries the warning that the gateway may still be working, so retrying
    /// can duplicate work the user pays for.
    func testTimeoutIsNotFoldedIntoUnreachable() {
        XCTAssertEqual(RecipeAnchor(errorCode: 28), .timeout)
        XCTAssertNotEqual(RecipeAnchor(errorCode: 28), RecipeAnchor(errorCode: 19))
    }

    // MARK: - 4. The rendered URL, exactly

    func testEveryAnchorRendersItsExactURL() {
        let expected: [RecipeAnchor: String] = [
            .certUntrusted:     "https://conduck.com/setup/tls/#cert-untrusted",
            .pinMismatch:       "https://conduck.com/setup/tls/#pin-mismatch",
            .pinKeyUnsupported: "https://conduck.com/setup/tls/#pin-key-unsupported",
            .plainHTTPBlocked:  "https://conduck.com/setup/tls/#plain-http-blocked",
            .unreachable:       "https://conduck.com/setup/tls/#unreachable",
            .timeout:           "https://conduck.com/setup/tls/#timeout",
            .auth:              "https://conduck.com/setup/tls/#auth",
            .tailscaleServe:    "https://conduck.com/setup/tls/#tailscale-serve",
        ]
        XCTAssertEqual(Set(expected.keys), Set(RecipeAnchor.allCases),
                       "Every case needs a URL row here.")
        for anchor in RecipeAnchor.allCases {
            XCTAssertEqual(anchor.url.absoluteString, expected[anchor],
                           "\(anchor.rawValue)'s URL drifted. A wrong base or a doubled slash is a 404, which is worse than no link.")
        }
    }

    /// The base is what the website's guard compares against, trailing slash
    /// included — `/setup/tls` without it would redirect at best.
    func testTheBaseURLIsTheContractedOne() {
        XCTAssertEqual(Constants.connectRecipesURL, "https://conduck.com/setup/tls/")
        XCTAssertTrue(Constants.connectRecipesURL.hasSuffix("/"),
                      "The trailing slash is part of the contract.")
    }

    /// The same claim as the table above, DERIVED rather than transcribed.
    ///
    /// It earns its place because the table cannot defend itself: a future
    /// editor who changes how `url` is assembled and then "fixes the failing
    /// test" by updating all eight literals leaves the table green and the
    /// links broken. This one has no literals to update — it reads the base and
    /// the raw value and asserts the JOIN, so the only way to silence it is to
    /// delete the rule outright, which is visible in a diff.
    func testTheURLIsExactlyBaseThenOneHashThenTheFragment() {
        for anchor in RecipeAnchor.allCases {
            let rendered = anchor.url.absoluteString
            let parts = rendered.components(separatedBy: "#")
            XCTAssertEqual(parts.count, 2,
                           "\(anchor.rawValue): expected exactly one '#' in \(rendered).")
            guard parts.count == 2 else { continue }
            XCTAssertEqual(parts[0], Constants.connectRecipesURL,
                           "\(anchor.rawValue): everything before the '#' must be the base verbatim — no doubled or missing slash.")
            XCTAssertEqual(parts[1], anchor.rawValue,
                           "\(anchor.rawValue): everything after the '#' must be the raw value verbatim — no separator, prefix or escaping between them.")
        }
    }

    // MARK: - 5. The link only rides surfaces the code can reach

    func testEveryMappedCodeIsTroubleshootable() {
        for (code, fragment) in Self.codeTable where fragment != nil {
            let error = AppError.from(errorCode: code, message: nil)
            XCTAssertTrue(error.isTroubleshootable,
                          "Code \(code) carries a recipe link but is excluded from Troubleshoot, so the link would never be seen.")
        }
    }
}

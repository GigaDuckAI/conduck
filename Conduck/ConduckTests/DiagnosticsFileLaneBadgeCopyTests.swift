// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsFileLaneBadgeCopyTests.swift
//
// The Diagnostics file-server row must state whether Conduck will ROUTE files to this
// server, not merely what some past test concluded.
//
// THE BUG IT EXISTS FOR. The row rendered a green "Verified" on a freshly-opened
// Diagnostics screen where the user had run nothing. That badge reads a PERSISTED flag
// (`fileServer.available.<suffix>`) which, for a paired install, was last written by the
// staged test inside the pairing sheet — possibly months earlier, possibly on another
// device via iCloud KVS. "Verified" is a past-tense claim about an event, rendered on a
// screen whose entire job is present-tense health, and the user reasonably read it as
// "checked just now".
//
// The same flag gates routing (`SettingsManager.fileTransferReadySnapshot(for:)` returns
// nil without it), so the honest sentence is about uploads being enabled or disabled.
// The mirror-image defect was "Configured — not tested", which meant attachments were
// silently not being sent and never said so.
//
// TWO AXES. Routing (`FileLaneState.uploadRoutingEnabled`) and evidence
// (`FileLaneState.Badge`) are independent — an armed lane can be failing its latest
// check — so the copy states both. The cross-products that would read absurdly
// ("Uploads disabled — server can't list folders") are prevented twice over: the real
// derivation only yields a caveat under `.verified`, which implies routing, AND the
// mapping refuses to spell a caveat sentence when routing is off, so a caller passing
// the pair directly still cannot produce the contradiction.
//
// The assertions are on the pure static mapping rather than on `body`, matching
// `GatewaySetupSuccessFileRowTests` — a `View`'s body is the one place copy cannot be
// read back.
//
// Deterministic + headless: no view is instantiated, nothing is stored, nothing probed.

import SwiftUI
import XCTest
@testable import Conduck

final class DiagnosticsFileLaneBadgeCopyTests: XCTestCase {

    private func text(
        routing: Bool,
        _ badge: FileLaneState.Badge,
        caveat: DiagnosticsRunner.FileLaneReturnCaveat? = nil
    ) -> String {
        String(localized: DiagnosticsContent.fileLaneBadgeDisplay(
            routingEnabled: routing, badge: badge, caveat: caveat).text)
    }

    private func tint(
        routing: Bool,
        _ badge: FileLaneState.Badge,
        caveat: DiagnosticsRunner.FileLaneReturnCaveat? = nil
    ) -> Color {
        DiagnosticsContent.fileLaneBadgeDisplay(
            routingEnabled: routing, badge: badge, caveat: caveat).tint
    }

    // MARK: - THE REGRESSION

    /// The word that started this. No file-lane state may claim verification, on any
    /// axis combination — it is the past-tense event word the screen cannot support.
    func testNoFileLaneStateEverSaysVerified() {
        let badges: [FileLaneState.Badge] =
            [.notSetUp, .configuredNotTested, .testing, .verified, .unconfirmed, .failed]
        let caveats: [DiagnosticsRunner.FileLaneReturnCaveat?] = [nil, .uploadsOnly, .returnUnchecked]
        for badge in badges {
            for caveat in caveats {
                for routing in [true, false] {
                    let copy = text(routing: routing, badge, caveat: caveat)
                    XCTAssertFalse(copy.localizedCaseInsensitiveContains("verified"),
                                   "\(badge)/\(String(describing: caveat))/routing=\(routing) says: \(copy)")
                }
            }
        }
    }

    // MARK: - Routing is the subject

    func testAnArmedTestedLaneSaysUploadsAreEnabled() {
        XCTAssertEqual(text(routing: true, .verified), "Uploads enabled")
        XCTAssertEqual(tint(routing: true, .verified), AppColors.success)
    }

    /// The state that was silently broken: set up, never proven, and Conduck will not
    /// send a byte to it. The badge must say so, and the fallback detail must spell out
    /// the consequence — nothing else on the screen does.
    func testAnUntestedLaneSaysUploadsAreDisabledAndWhy() throws {
        XCTAssertEqual(text(routing: false, .configuredNotTested), "Uploads disabled — test required")
        let detail = try XCTUnwrap(DiagnosticsContent.fileLaneFallbackDetail(.configuredNotTested))
        XCTAssertEqual(String(localized: detail),
                       "Conduck won't upload files to this server until a server test passes.")
    }

    /// "Test required", never "not tested yet". A lane whose staged test FAILED derives
    /// exactly this badge after a relaunch (session results dropped, availability
    /// false), so it is indistinguishable from one nobody ever tested — the app must
    /// not claim a history it cannot know.
    func testTheUntestedLaneMakesNoClaimAboutHistory() {
        let copy = text(routing: false, .configuredNotTested)
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("not tested"),
                       "a previously-FAILED lane derives this same state — 'not tested' is unknowable")
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("yet"))
    }

    /// Only `.configuredNotTested` gets a static detail. Every other state either has a
    /// real remedy from `DiagnosticsExplainer` or a reach sentence of its own, and a
    /// second static line would just restate the badge.
    func testNoOtherStateCarriesAFallbackDetail() {
        for badge: FileLaneState.Badge in [.notSetUp, .testing, .verified, .unconfirmed, .failed] {
            XCTAssertNil(DiagnosticsContent.fileLaneFallbackDetail(badge), "\(badge) must not add a static line")
        }
    }

    // MARK: - The armed-but-failing lane — the state the old copy could not express

    /// A previously-passing lane whose reach probe now fails is STILL routing uploads
    /// (the sweep's reach probe is non-mutating). "Still" makes that persistence the
    /// subject, so a red row is not read as "Conduck stopped sending".
    func testAnArmedLaneFailingItsCheckSaysUploadsAreStillEnabled() {
        XCTAssertEqual(text(routing: true, .failed), "Uploads still enabled — last check failed")
        XCTAssertEqual(text(routing: false, .failed), "Uploads disabled — last check failed")
        XCTAssertNotEqual(text(routing: true, .failed), text(routing: false, .failed),
                          "an armed failing lane and a disarmed one are different situations")
    }

    /// Red for both — the check genuinely failed, and uploads still being armed makes
    /// it more urgent, not less.
    func testAFailingLaneIsRedWhetherOrNotItIsStillArmed() {
        XCTAssertEqual(tint(routing: true, .failed), AppColors.error)
        XCTAssertEqual(tint(routing: false, .failed), AppColors.error)
    }

    /// "Connection check", not "writes": the reach probe never attempted a write, so
    /// calling the WRITES unconfirmed would discount a staged pass the lane may still
    /// be carrying.
    func testAnInconclusiveCheckNamesTheCheckNotTheWrites() {
        XCTAssertEqual(text(routing: true, .unconfirmed),
                       "Uploads still enabled — last check inconclusive")
        XCTAssertEqual(text(routing: false, .unconfirmed),
                       "Uploads disabled — last check inconclusive")
        XCTAssertFalse(text(routing: true, .unconfirmed).localizedCaseInsensitiveContains("write"))
    }

    // MARK: - Routing drives the prefix, never the badge case

    /// The prefix must track the routing axis alone. If a future edit keys it off the
    /// badge instead, these pairs collapse and the row starts lying about one of them.
    func testTheRoutingPrefixIsDrivenByRoutingNotByTheBadge() {
        for badge: FileLaneState.Badge in [.failed, .unconfirmed] {
            XCTAssertTrue(text(routing: true, badge).hasPrefix("Uploads still enabled"), "\(badge)")
            XCTAssertTrue(text(routing: false, badge).hasPrefix("Uploads disabled"), "\(badge)")
        }
    }

    /// `.testing` and `.notSetUp` describe no routing state worth prefixing — one is
    /// transient, the other has no server at all.
    func testTransientAndUnconfiguredStatesTakeNoRoutingPrefix() {
        XCTAssertEqual(text(routing: false, .testing), "Testing…")
        XCTAssertEqual(text(routing: false, .notSetUp), "Not set up")
        XCTAssertEqual(text(routing: true, .testing), "Testing…", "routing must not leak into a transient row")
    }

    // MARK: - Caveats

    /// A half-lane is amber and names what works first, then what does not. Both caveats
    /// are reachable only under `.verified`, which implies routing — so both say
    /// "enabled", and the absurd "Uploads disabled — server can't list folders" cannot
    /// be constructed through the real derivation.
    func testTheUploadOnlyLaneIsQualifiedRatherThanSealed() {
        XCTAssertEqual(text(routing: true, .verified, caveat: .uploadsOnly),
                       "Uploads enabled — server can't list folders")
        XCTAssertEqual(tint(routing: true, .verified, caveat: .uploadsOnly), AppColors.warning)
        XCTAssertNotEqual(text(routing: true, .verified, caveat: .uploadsOnly),
                          text(routing: true, .verified),
                          "a half lane and a whole lane must never render the same sentence")
    }

    func testAnUncheckedReturnDirectionLosesTheSeal() {
        XCTAssertEqual(text(routing: true, .verified, caveat: .returnUnchecked),
                       "Uploads enabled — returns unchecked")
        XCTAssertEqual(tint(routing: true, .verified, caveat: .returnUnchecked), AppColors.warning,
                       "'couldn't check' has to come off the green as much as 'it cannot'")
    }

    /// A caveat can never put the word "enabled" over a lane that is not routing —
    /// even though the real derivation cannot produce that pair. The guard lives in
    /// the mapping, not only in prose two files away, so a future caller passing the
    /// combination gets a sensible sentence instead of a self-contradicting one.
    func testACaveatIsIgnoredWhenRoutingIsOff() {
        for caveat: DiagnosticsRunner.FileLaneReturnCaveat in [.uploadsOnly, .returnUnchecked] {
            for badge: FileLaneState.Badge in [.configuredNotTested, .failed, .notSetUp] {
                let copy = text(routing: false, badge, caveat: caveat)
                XCTAssertFalse(copy.contains("Uploads enabled"),
                               "\(badge)/\(caveat) with routing off claims uploads work: \(copy)")
                XCTAssertEqual(copy, text(routing: false, badge),
                               "with routing off the badge's own sentence stands, caveat or not")
            }
        }
    }

    // MARK: - The disabled lane is a finding, not a resting state

    /// Amber and a warning glyph, not the resting grey it used to wear. A set-up file
    /// server that silently receives nothing is a half-finished setup; dressing it as
    /// neutral is what let the summary say "Checks passed" over it.
    func testTheDisabledLaneIsStyledAsSomethingToActOn() {
        XCTAssertEqual(tint(routing: false, .configuredNotTested), AppColors.warning)
        XCTAssertEqual(DiagnosticsContent.fileLaneBadgeDisplay(
            routingEnabled: false, badge: .configuredNotTested, caveat: nil).glyph,
            "exclamationmark.triangle.fill")

        // A gateway with no file server at all stays neutral — nothing is broken.
        XCTAssertEqual(tint(routing: false, .notSetUp), AppColors.textTertiary)
    }

    /// A test in flight must show as such, even on a lane that is already armed —
    /// that was the state whose spinner never appeared, because the routing check
    /// outranked `.running` and the row kept its green seal for the whole probe.
    func testATestInFlightOutranksTheArmedGreen() {
        XCTAssertEqual(text(routing: true, .testing), "Testing…")
        XCTAssertEqual(tint(routing: true, .testing), AppColors.textSecondary)
    }
}

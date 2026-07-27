// SPDX-License-Identifier: Apache-2.0

// Conduck
// PhoneSessionResendTests.swift
//
// Coverage for `PhoneSessionManager.resendPreflight` — the pure decision
// function behind Settings ▸ Apple Watch ▸ "Send Settings to Apple Watch".
// The full state matrix (activation × paired × installed) plus the precedence
// order (activation → pairing → install). No live WCSession is touched: the
// function is pure over its three inputs.
//
// `#if os(iOS)` matches `PhoneSessionManager` itself, which is iOS-only
// (`WatchConnectivity` does not exist on macOS). Without the guard the WHOLE
// ConduckTests target fails to build for the macOS destination on an
// unresolvable module dependency, which takes every other test down with it —
// including the live-TLS pinning suite, which can only run there.

#if os(iOS)

import WatchConnectivity
import XCTest
@testable import Conduck

final class PhoneSessionResendTests: XCTestCase {

    // MARK: - Clear-to-send

    func testActivatedPairedInstalledMayProceed() {
        XCTAssertNil(
            PhoneSessionManager.resendPreflight(
                activationState: .activated, isPaired: true, isWatchAppInstalled: true
            ),
            "activated + paired + installed is the only clear-to-send combination (nil)."
        )
    }

    // MARK: - Activation gate (highest precedence)

    func testNotActivatedYieldsActivationPending() {
        for paired in [true, false] {
            for installed in [true, false] {
                XCTAssertEqual(
                    PhoneSessionManager.resendPreflight(
                        activationState: .notActivated, isPaired: paired, isWatchAppInstalled: installed
                    ),
                    .activationPending,
                    "notActivated must block as .activationPending regardless of paired=\(paired) installed=\(installed)."
                )
            }
        }
    }

    func testInactiveYieldsActivationPending() {
        for paired in [true, false] {
            for installed in [true, false] {
                XCTAssertEqual(
                    PhoneSessionManager.resendPreflight(
                        activationState: .inactive, isPaired: paired, isWatchAppInstalled: installed
                    ),
                    .activationPending,
                    "inactive must block as .activationPending regardless of paired=\(paired) installed=\(installed)."
                )
            }
        }
    }

    // MARK: - Pairing gate (once activated)

    func testActivatedNotPairedYieldsNotPaired() {
        // Not-paired outranks the install check — a not-paired Watch can't have
        // the app installed, but the function must report the pairing block
        // regardless of the installed flag.
        for installed in [true, false] {
            XCTAssertEqual(
                PhoneSessionManager.resendPreflight(
                    activationState: .activated, isPaired: false, isWatchAppInstalled: installed
                ),
                .notPaired,
                "activated + not paired must block as .notPaired (installed=\(installed))."
            )
        }
    }

    // MARK: - Install gate (lowest precedence)

    func testActivatedPairedNotInstalledYieldsNotInstalled() {
        XCTAssertEqual(
            PhoneSessionManager.resendPreflight(
                activationState: .activated, isPaired: true, isWatchAppInstalled: false
            ),
            .watchAppNotInstalled,
            "activated + paired + not installed must block as .watchAppNotInstalled."
        )
    }

    // MARK: - Precedence order (activation before pairing before install)

    func testActivationOutranksPairingAndInstall() {
        // Every downstream gate also failing — activation still wins.
        XCTAssertEqual(
            PhoneSessionManager.resendPreflight(
                activationState: .notActivated, isPaired: false, isWatchAppInstalled: false
            ),
            .activationPending,
            "activation failure must be reported ahead of pairing and install failures."
        )
    }

    func testPairingOutranksInstall() {
        // Activation ok, both pairing and install failing — pairing wins.
        XCTAssertEqual(
            PhoneSessionManager.resendPreflight(
                activationState: .activated, isPaired: false, isWatchAppInstalled: false
            ),
            .notPaired,
            "pairing failure must be reported ahead of the install failure."
        )
    }
}

#endif

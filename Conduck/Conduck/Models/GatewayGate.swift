// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayGate.swift
//
// Which surface may open, as pure functions over the gateway roster.
//
// There are TWO questions here, and answering one with the other is the bug this
// file exists to prevent:
//
//   canSendAnywhere      "can this device send at all?"  Asked by every surface
//                        that lets the user CHOOSE a gateway before sending —
//                        the iPhone root, the iPad library, the Mac window. Each
//                        mounts a picker that seeds itself to a gateway that is
//                        actually configured (`NewChatGatewaySeed`), so a stored
//                        default that cannot send costs those surfaces nothing.
//
//   isQuickCaptureReady  "can the menu-bar quick lane send?"  Asked by the one
//                        surface with NO picker: a hotkey capture always mints on
//                        the persisted default (Decision F — a gateway picked for
//                        the next window chat must not re-aim a capture, and the
//                        converse). So there the default itself has to be
//                        send-able, or the capture dead-ends after the user has
//                        already spoken.
//
// The second is strictly stronger than the first, and the gap between them is a
// REAL state, not a transient. `SettingsManager.resolveDefaultGateway()` names
// the shapes it takes: a stored pointer at a gateway that is not set up HERE
// (`.defaultUnavailable`), no chosen default at all on a device where several
// gateways work (`.selectionRequired`), a pointer parked on a built-in by
// `deleteCustomGateway` so the user chooses their next gateway rather than
// inheriting one, or a peer device's Forget arriving over iCloud. In every one
// the honest reading is "five gateways work, the default among them does not" —
// never "no AI is set up". Answering the first question with the second renders
// the beginner "Bring your own AI" empty state on a device with five verified
// gateways, with the toolbar blanked so there is no way back.
//
// REJECTED, and do not re-propose: resolving a FALLBACK gateway when the default
// cannot send, so a capture never dead-ends. It reads as an obvious kindness and
// is none:
//   - The natural second rung is the last-used gateway, whose own accessor says
//     "A HINT, NEVER A ROUTING AUTHORITY … do not hand this to anything that
//     dispatches" — and last-used is written by the WINDOW picker, so the fallback
//     would let a gateway chosen for a window chat silently re-aim the next hotkey
//     capture, which is Decision F inverted.
//   - The third rung, "any configured gateway", is ordered by `RemoteAgentBackend
//     .allCases` — the user's words would go to whichever server is declared first
//     in a Swift file, possibly the deliberately second-class hosted lane.
//   - The candidate set comes from the fail-closed send-ability predicate, so
//     before first unlock every `.bearer` gateway reads as gone and a headless
//     capture would land on whichever keyless gateway survived the blackout.
//   - And it reaches the outcome `deleteCustomGateway`'s comment names as the
//     regression it exists to prevent — "silently moving every subsequent message
//     to a different server" — while leaving no stored pointer to audit it by.
// A capture that cannot be delivered is refused BEFORE it is recorded, and the
// surfaces say which gateway is missing. Fail closed, then explain.
//
// Pure and parameter-fed for the same reason as the sibling `NewChatGatewaySeed`:
// `MenuBarCoordinator` is `#if os(macOS)` and the authoritative suite runs on the
// iOS Simulator, so a predicate written inline there is never compiled by a test,
// let alone run by one. Logic the views cannot reach lives here, where it can be
// locked down. Callers feed both answers from ONE `NewChatPickerSnapshot` turn so
// the window and the popover can never describe different moments.

import Foundation

enum GatewayGate {

    /// Whether ANY gateway on this device can send right now.
    ///
    /// Deliberately says nothing about WHICH one: the surfaces that ask this all
    /// mount a picker, and the picker's own seed ladder decides that.
    static func canSendAnywhere(configured: [RemoteAgentRef]) -> Bool {
        !configured.isEmpty
    }

    /// Whether the menu-bar quick lane can MINT — i.e. whether the gateway a
    /// hotkey capture would start a fresh chat on can actually take the turn.
    ///
    /// It is half of the lane's readiness, not all of it. A capture that
    /// CONTINUES a live quick-lane conversation never reaches the default, so
    /// `MenuBarCoordinator` asks `SharedInboxRouting.liveQuickCaptureCanContinue`
    /// first and only falls back to this verdict — the same order the router
    /// itself resolves in, and the same order the Shortcut pre-flight and the
    /// wrist use. Keep that composition at the call site: this function is pure
    /// over a resolution and has no pointer to consult.
    ///
    /// A projection of the RESOLUTION rather than a set-membership test, because
    /// membership cannot express every state the pointer can be in: with no
    /// default chosen at all the resolution projects to the built-in fallback,
    /// which may itself be configured, so a membership test would answer "ready"
    /// for a device whose next capture has nowhere honest to go. `canSend` is
    /// true only where the pointer is a member of the configured set by
    /// construction — exactly the guarantee a lane with no picker and no pre-send
    /// confirmation needs.
    static func isQuickCaptureReady(resolution: DefaultGatewayResolution) -> Bool {
        resolution.canSend
    }
}

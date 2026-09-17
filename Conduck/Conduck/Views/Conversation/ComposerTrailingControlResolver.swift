// SPDX-License-Identifier: Apache-2.0

// Conduck
// ComposerTrailingControlResolver.swift
//
// The ONE place that decides what the composer's morphing trailing control is
// on a given body pass — glyph, tint, meaning, enabled, pulsing — for both the
// compact (iPhone) bar and the regular (iPad card) layout.
//
// PURE AND FOUNDATION-ONLY, so the priority order is unit-testable with no
// view (mirrors `LiveTurnPhaseResolver`). The view maps `Tint` to `AppColors`,
// attaches the in-flight token to a `.stop` intent on the SAME body pass, and
// keeps the single-Button / single-Image identity `CaptureCircleButton` needs.
//
// Priority, top wins:
//   1. a turn this device can stop       → Stop, neutral, enabled
//   2. a send accepted but not yet live  → Send, brand, INERT   ← the hold
//   3. (compact) recording               → Stop, error-red, pulses
//   4. (compact) transcribing/preparing  → working glyph, inert
//   5. (regular) always Send             → the card has its own mic
//   6. a draft                           → Send
//   7. otherwise                         → Mic
//
// Rule 2 exists because the VM's `onLocalAcceptance` fires several awaits
// before `beginInFlight`: the host clears the draft on that callback while no
// Stop token exists yet. Without the hold the control walked arrow → mic →
// Stop on every send. The hold is an INERT Send, never a Stop: a Stop with no
// token behind it is a control that does nothing, and a late tap on it would
// land on `cancelInFlight(expecting: nil)`.
//
// Known gap, deliberately left: a turn this device can SEE but not stop (a
// share-drain or CarPlay upload — the wait indicator without `canStop`)
// renders the ordinary mic. Pre-existing and rare on the phone.

import Foundation

/// Where the in-app recorder is, reduced to what the trailing control cares
/// about.
enum ComposerCapturePhase: Equatable, Sendable {
    case idle, recording, processing, preparingVoice, error
}

/// Which bar arrangement is asking: compact carries the mic/send morph inline;
/// the regular iPad card has a separate persistent mic, so its trailing control
/// never shows one.
enum ComposerTrailingLayout: Equatable, Sendable {
    case compact, regular
}

/// The resolved look and meaning of the trailing control for one body pass.
struct ComposerTrailingControl: Equatable, Sendable {
    /// SF Symbol names — one per meaning, so the glyph morph has a stable set.
    enum Glyph: String, Sendable {
        case mic = "mic.fill"
        case stop = "stop.fill"
        case send = "arrow.up"
        case working = "ellipsis"
    }

    /// Disc fill, named by role; the view maps it to `AppColors`.
    enum Tint: Equatable, Sendable { case brand, error, neutral, inert }

    /// What a tap MEANS. `.none` is an inert control — the view wires no action.
    enum Intent: Equatable, Sendable { case stop, send, mic, none }

    let glyph: Glyph
    let tint: Tint
    let intent: Intent
    let isEnabled: Bool
    /// True only while recording — drives the halo behind the disc.
    let pulses: Bool
}

enum ComposerTrailingControlResolver {
    /// - Parameter isSubmitting: the send has been tapped and is not yet
    ///   visibly live — the bar's own submission window OR the VM's
    ///   accepted-but-not-dispatched window (`isPreparingLiveTurn`).
    /// - Parameter canStop: `canStopLiveTurn` — a turn this device holds a
    ///   cancel handle to. Outranks everything, including the hold.
    /// - Parameter isSendDisabled: the composer's full send gate (in flight,
    ///   loading attachment, capture active, submitting…).
    /// - Parameter isMicDisabled: transcribing or preparing voice.
    static func resolve(
        capture: ComposerCapturePhase,
        hasDraft: Bool,
        hasAttachments: Bool,
        isSubmitting: Bool,
        canStop: Bool,
        isSendDisabled: Bool,
        isMicDisabled: Bool,
        layout: ComposerTrailingLayout
    ) -> ComposerTrailingControl {
        if canStop {
            return .init(glyph: .stop, tint: .neutral, intent: .stop, isEnabled: true, pulses: false)
        }
        if isSubmitting {
            return .init(glyph: .send, tint: .brand, intent: .none, isEnabled: false, pulses: false)
        }
        switch layout {
        case .regular:
            let ready = (hasDraft || hasAttachments) && !isSendDisabled
            return .init(glyph: .send, tint: ready ? .brand : .inert, intent: .send, isEnabled: ready, pulses: false)
        case .compact:
            switch capture {
            case .recording:
                return .init(glyph: .stop, tint: .error, intent: .mic, isEnabled: !isMicDisabled, pulses: true)
            case .processing, .preparingVoice:
                return .init(glyph: .working, tint: .inert, intent: .none, isEnabled: false, pulses: false)
            case .idle, .error:
                break
            }
            if hasDraft {
                return .init(
                    glyph: .send,
                    tint: isSendDisabled ? .inert : .brand,
                    intent: .send,
                    isEnabled: !isSendDisabled,
                    pulses: false
                )
            }
            return .init(
                glyph: .mic,
                tint: isMicDisabled ? .inert : .brand,
                intent: .mic,
                isEnabled: !isMicDisabled,
                pulses: false
            )
        }
    }
}

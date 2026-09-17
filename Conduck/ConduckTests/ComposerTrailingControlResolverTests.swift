// SPDX-License-Identifier: Apache-2.0

// Conduck
// ComposerTrailingControlResolverTests.swift
//
// The composer's trailing control state machine, pinned as a pure function.
// The headline case is the one the founder saw: a typed send must never pass
// through the mic on its way to the in-flight Stop.

import XCTest
@testable import Conduck

final class ComposerTrailingControlResolverTests: XCTestCase {

    private func resolve(
        capture: ComposerCapturePhase = .idle,
        hasDraft: Bool = false,
        hasAttachments: Bool = false,
        isSubmitting: Bool = false,
        canStop: Bool = false,
        isSendDisabled: Bool = false,
        isMicDisabled: Bool = false,
        layout: ComposerTrailingLayout = .compact
    ) -> ComposerTrailingControl {
        ComposerTrailingControlResolver.resolve(
            capture: capture,
            hasDraft: hasDraft,
            hasAttachments: hasAttachments,
            isSubmitting: isSubmitting,
            canStop: canStop,
            isSendDisabled: isSendDisabled,
            isMicDisabled: isMicDisabled,
            layout: layout
        )
    }

    func testASendNeverPassesThroughTheMic() {
        // Tick 1: the tap. A draft, nothing submitted yet.
        let tapped = resolve(hasDraft: true)
        // Tick 2: accepted locally — the host cleared the draft, the send gate
        // is closed, no Stop token exists yet. This is where the old ladder
        // showed a mic.
        let accepted = resolve(hasDraft: false, isSubmitting: true, isSendDisabled: true)
        // Tick 3: `beginInFlight` — stoppable.
        let live = resolve(hasDraft: false, isSubmitting: false, canStop: true, isSendDisabled: true)

        XCTAssertEqual([tapped, accepted, live].map(\.glyph), [.send, .send, .stop])
        XCTAssertEqual([tapped, accepted, live].map(\.tint), [.brand, .brand, .neutral])
    }

    func testTheSubmittingHoldIsInertAndDoesNotGrey() {
        let held = resolve(isSubmitting: true, isSendDisabled: true)
        XCTAssertEqual(held.glyph, .send)
        XCTAssertEqual(held.tint, .brand, "the hold keeps the send look; grey-then-amber-then-grey was the whiplash")
        XCTAssertFalse(held.isEnabled)
        XCTAssertEqual(held.intent, .none, "no token exists yet, so nothing is safe to do")
        XCTAssertFalse(held.pulses)
    }

    func testStopOutranksTheHold() {
        let control = resolve(isSubmitting: true, canStop: true, isSendDisabled: true)
        XCTAssertEqual(control.glyph, .stop)
        XCTAssertEqual(control.intent, .stop)
        XCTAssertTrue(control.isEnabled, "the in-flight Stop is always the cancel control")
    }

    func testStopOutranksEveryCapturePhaseOnBothLayouts() {
        // A live turn's cancel control wins over the mic's own states, and it
        // never pulses (the halo is the recording cue, not the in-flight one).
        for phase in [ComposerCapturePhase.idle, .recording, .processing, .preparingVoice, .error] {
            for layout in [ComposerTrailingLayout.compact, .regular] {
                let control = resolve(capture: phase, hasDraft: true, canStop: true,
                                      isSendDisabled: true, isMicDisabled: true, layout: layout)
                XCTAssertEqual(control.glyph, .stop, "\(phase) / \(layout)")
                XCTAssertEqual(control.tint, .neutral, "\(phase) / \(layout)")
                XCTAssertEqual(control.intent, .stop, "\(phase) / \(layout)")
                XCTAssertTrue(control.isEnabled, "\(phase) / \(layout)")
                XCTAssertFalse(control.pulses, "\(phase) / \(layout)")
            }
        }
    }

    func testTheHoldOutranksEveryCapturePhase() {
        // Capture cannot be active while a send is being accepted (the gate
        // refuses it), but the priority is pinned so a stray phase can never
        // surface a mic or a stop-recording control mid-hold.
        for phase in [ComposerCapturePhase.idle, .recording, .processing, .preparingVoice, .error] {
            let control = resolve(capture: phase, isSubmitting: true, isSendDisabled: true, isMicDisabled: true)
            XCTAssertEqual(control.glyph, .send, "\(phase)")
            XCTAssertEqual(control.intent, .none, "\(phase)")
            XCTAssertFalse(control.isEnabled, "\(phase)")
        }
    }

    func testRecordingOutranksADraft() {
        // Typing mid-capture must not hide the stop-recording control.
        let control = resolve(capture: .recording, hasDraft: true, isSendDisabled: true)
        XCTAssertEqual(control.glyph, .stop)
        XCTAssertEqual(control.tint, .error)
        XCTAssertEqual(control.intent, .mic, "the mic action handles stop-recording")
        XCTAssertTrue(control.isEnabled)
        XCTAssertTrue(control.pulses)
    }

    func testTranscribingIsNotTappable() {
        for phase in [ComposerCapturePhase.processing, .preparingVoice] {
            let control = resolve(capture: phase, hasDraft: true, isSendDisabled: true, isMicDisabled: true)
            XCTAssertEqual(control.glyph, .working, "\(phase)")
            XCTAssertEqual(control.tint, .inert, "\(phase)")
            XCTAssertFalse(control.isEnabled, "\(phase)")
            XCTAssertEqual(control.intent, .none, "\(phase)")
        }
    }

    func testAnAttachmentOnlyComposerKeepsTheMic() {
        // Key UX decision #1: the trailing control stays the mic so a staged
        // photo can be voice-captioned; the subdued send handles caption-less.
        let control = resolve(hasAttachments: true)
        XCTAssertEqual(control.glyph, .mic)
        XCTAssertEqual(control.intent, .mic)
        XCTAssertTrue(control.isEnabled)
    }

    func testADraftShowsSendAndTheGateOnlyGreysIt() {
        let ready = resolve(hasDraft: true)
        XCTAssertEqual(ready.glyph, .send)
        XCTAssertEqual(ready.tint, .brand)
        XCTAssertTrue(ready.isEnabled)

        let gated = resolve(hasDraft: true, isSendDisabled: true)
        XCTAssertEqual(gated.glyph, .send)
        XCTAssertEqual(gated.tint, .inert)
        XCTAssertFalse(gated.isEnabled)
        XCTAssertEqual(gated.intent, .send)
    }

    func testAnErrorStateOffersTheMicAgain() {
        let control = resolve(capture: .error)
        XCTAssertEqual(control.glyph, .mic)
        XCTAssertTrue(control.isEnabled)
    }

    func testTheRegularLayoutNeverShowsAMic() {
        // The iPad card has its own persistent mic to the left of this control.
        let empty = resolve(layout: .regular)
        XCTAssertEqual(empty.glyph, .send)
        XCTAssertFalse(empty.isEnabled)
        XCTAssertEqual(empty.tint, .inert)

        let attachmentOnly = resolve(hasAttachments: true, layout: .regular)
        XCTAssertEqual(attachmentOnly.glyph, .send)
        XCTAssertTrue(attachmentOnly.isEnabled, "an image-only turn is a valid send")

        let recording = resolve(capture: .recording, isSendDisabled: true, layout: .regular)
        XCTAssertEqual(recording.glyph, .send)
        XCTAssertFalse(recording.pulses, "the halo belongs to the card's own mic")

        let held = resolve(isSubmitting: true, isSendDisabled: true, layout: .regular)
        XCTAssertEqual(held.tint, .brand)
        XCTAssertFalse(held.isEnabled)
    }

    func testPulseIsRecordingOnly() {
        for phase in [ComposerCapturePhase.idle, .processing, .preparingVoice, .error] {
            XCTAssertFalse(resolve(capture: phase).pulses, "\(phase)")
        }
        XCTAssertFalse(resolve(canStop: true).pulses)
        XCTAssertFalse(resolve(hasDraft: true).pulses)
    }
}

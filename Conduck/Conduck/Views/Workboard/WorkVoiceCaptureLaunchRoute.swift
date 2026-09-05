// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkVoiceCaptureLaunchRoute.swift
//
// Turns "a Shortcut asked for a voice note" into "the recorder is on screen".
//
// An App Intent cannot present a sheet. `RecordWorkNoteIntent` runs in the
// foreground precisely so the app can, and the request then has to survive the
// gap between the ask and the desk actually mounting — a cold launch has no
// observer registered when the notification is posted, so the post alone would
// be dropped. The flag is therefore set BEFORE the notification goes out and
// read again when the canvas appears, which is the same staged-request shape
// `GatewayFixRoute` uses for a broken default.
//
// CONSUMABLE, exactly once: the desk mounts on more than one platform root and
// both an `.onReceive` and an `.onAppear` consult this, so two readers
// suspended on the same request would otherwise each open a recorder.
//
// IN-MEMORY, NEVER PERSISTED, deliberately: a request that outlived the process
// and opened a recorder days later would be a surprise, not a service. The
// person's intent is the note they are making right now.
//
// No re-validation, unlike `GatewayFixRoute.consumeIfStillBroken`: that route
// describes a STATE that can heal itself between the ask and the landing, while
// this one describes an ACT the person asked for. Nothing about the desk can
// make "record a note" the wrong answer by the time the canvas appears.

import Foundation

extension Notification.Name {
    /// Posted when something headless wants the app, once foregrounded, to
    /// present Work's voice capture. The desk surface consumes the route
    /// itself; this only removes the delay while the app is already alive.
    static let showWorkboardVoiceCapture = Notification.Name("showWorkboardVoiceCapture")
}

/// A pending "start a Work voice note" request, waiting for whichever desk
/// surface mounts first.
///
/// An instance rather than an enum of statics so a test can exercise the
/// consume-once rule without leaking a request into the singleton every other
/// test in the process shares.
@MainActor
final class WorkVoiceCaptureLaunchRoute {
    static let shared = WorkVoiceCaptureLaunchRoute()

    private var pending = false

    /// Ask for the recorder. SET-THEN-POST: the flag has to be true before the
    /// notification goes out, or a surface that mounts between the two ends up
    /// with neither signal.
    func request() {
        pending = true
        NotificationCenter.default.post(name: .showWorkboardVoiceCapture, object: nil)
    }

    /// One-shot read-and-clear. Call it from BOTH an `.onReceive` of
    /// `.showWorkboardVoiceCapture` AND the desk's appearance: a warm app hears
    /// the post and a cold launch never does, and a surface that handles only
    /// one of the two silently drops half the requests.
    func consume() -> Bool {
        guard pending else { return false }
        pending = false
        return true
    }
}

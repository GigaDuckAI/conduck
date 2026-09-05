// SPDX-License-Identifier: Apache-2.0

// Conduck
// RecordWorkNoteIntent.swift
//
// The launcher for Work's voice capture, and deliberately NOTHING else. It owns
// no recorder, no microphone lease and no publication: it reveals the desk and
// asks it to present the capture surface the in-app button already presents, so
// the whole durable lane — record, publish the recording BEFORE the speech hop,
// attach the transcript after — stays in one place with one set of failure
// paths.
//
// FOREGROUND, because a recorder without a screen is a recorder nobody can stop.
// The person has to see the level, the elapsed time and a way to finish, and an
// App Intent cannot present any of that itself. `ConverseIntent(destination:
// .work)` already covers the headless case — audio a shortcut ALREADY recorded,
// plus an optional screenshot — so this intent is the launcher and never a
// second capture pipeline.
//
// The request is staged rather than posted-and-hoped: `WorkVoiceCaptureLaunchRoute`
// holds a consumable flag so a cold launch, whose desk mounts after the
// notification is long gone, still lands on the recorder. The route is asked
// BEFORE the desk is revealed, which is the same set-then-post rule the route
// itself follows one level down: `.showWorkboard` can mount a desk
// synchronously, and a desk that mounts before the flag is set would read an
// empty route and open on nothing.

#if !os(watchOS)
import AppIntents
import Foundation

struct RecordWorkNoteIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource(
        "intent.workRecordNote.title",
        defaultValue: "Record a Note to Work"
    )

    static var description = IntentDescription(
        LocalizedStringResource(
            "intent.workRecordNote.description",
            defaultValue: "Open Work and start recording a voice note. Nothing is sent to an AI."
        )
    )

    /// Foreground only — there is no headless half of this intent to fall back
    /// to, so declaring `.background` would only promise a mode that cannot do
    /// the one thing the intent is for.
    static var supportedModes: IntentModes = [.foreground]

    /// `@MainActor` so the route and the reveal happen in ONE main-actor turn,
    /// the way the wrist's `RecordNoteIntent` runs. An `await` between them
    /// would let a desk mount in the gap — harmless today, because the flag is
    /// already set by then, but the ordering this intent depends on would stop
    /// being visible in the code that depends on it.
    @MainActor
    func perform() async throws -> some IntentResult {
        // Sets the pending flag and posts `.showWorkboardVoiceCapture` itself —
        // the warm signal and the cold-launch one are the same request, and the
        // route is what keeps them from being two.
        WorkVoiceCaptureLaunchRoute.shared.request()
        // Then reveal. `.showWorkboard` opens the `main` window on the Mac and
        // switches the top-level destination everywhere, so the capture surface
        // ends up on a desk that is the visible place rather than in front of
        // whatever was.
        NotificationCenter.default.post(name: .showWorkboard, object: nil)
        return .result()
    }
}
#endif

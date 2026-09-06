// SPDX-License-Identifier: Apache-2.0

// Conduck
// QuitGuard.swift
//
// The pure verdict behind macOS `applicationShouldTerminate`: quit silently, or
// ask — with copy naming what is still in flight. Pure so the decision and its
// wording are testable without driving AppKit modality.
//
// WHAT THE LIVE COUNT IS, AND IS NOT. `AppDelegate` feeds this
// `InFlightTurnRegistry.liveCount` — conversations this PROCESS holds a claim
// on. Deliberately NOT the two things that look equivalent and are not:
//   • `Message.status == "sending"` in Core Data — a `sending` row may have been
//     written by another device and mirrored here, so a Mac that never sent
//     anything would nag on every ⌘Q, forever.
//   • `MenuBarCoordinator.quickViewModel?.isAwaitingReply` — the quick lane
//     only; a window-lane turn or a share drain would slip straight through.
//
// macOS is the surface where this matters: its converse hop is a FOREGROUND
// URLSession, so quitting mid-turn destroys the reply with nothing left to
// resolve it. That is the whole reason the alert exists, and also the reason its
// copy promises nothing about the answer being saved.

#if os(macOS)

import Foundation

enum QuitGuard {

    /// Everything the alert renders. A value, not a view: the wording is part of
    /// the decision (it names what is in flight), so it is asserted in tests
    /// rather than eyeballed on screen.
    struct Prompt: Equatable, Sendable {
        /// Conversations holding at least one live claim. Always ≥ 1 here.
        let liveCount: Int
        /// Display title of the sole live thread — nil when several are live, or
        /// when the title could not be resolved synchronously.
        let threadTitle: String?
        /// Gateway display name for the sole live thread, same nil rules.
        let gatewayName: String?

        /// Names what is still running. Three shapes, never assembled from
        /// fragments — each is one whole localized sentence.
        var messageText: String {
            if liveCount == 1, let threadTitle, let gatewayName {
                return String(
                    localized: "quitGuard.single.named.title",
                    defaultValue: "\(gatewayName) is still working on “\(threadTitle)”"
                )  // xcstrings: session-continuation
            }
            if liveCount == 1 {
                return String(
                    localized: "quitGuard.single.title.v2",
                    defaultValue: "Your AI is still answering"
                )  // xcstrings: session-continuation
            }
            return String(
                localized: "quitGuard.multiple.title",
                defaultValue: "\(liveCount) conversations are still waiting on answers"
            )  // xcstrings: session-continuation
        }

        /// Deliberately says NOTHING about the message being saved. The user
        /// turn is durable, but the REPLY is what quitting destroys — promising
        /// safety here would make the alert feel dismissible, which is the one
        /// thing it must not be.
        var informativeText: String {
            String(
                localized: "quitGuard.body",
                defaultValue: "Quitting now ends the request. The answer can't be recovered — you'd have to ask again."
            )  // xcstrings: session-continuation
        }

        /// The DESTRUCTIVE choice. Rendered first and with no key equivalent so
        /// a lost answer is unreachable by muscle memory.
        var quitButtonTitle: String { QuitGuard.quitAnywayTitle }

        /// The safe choice, and the one Esc lands on.
        var keepWaitingButtonTitle: String {
            String(
                localized: "quitGuard.button.keepWaiting",
                defaultValue: "Keep Waiting"
            )  // xcstrings: session-continuation
        }
    }

    /// The DESTRUCTIVE choice, shared by both prompts. Rendered first and with
    /// no key equivalent so a loss is unreachable by muscle memory. One
    /// definition because it is one sentence: the alert that follows it differs,
    /// what the button does does not.
    static var quitAnywayTitle: String {
        String(
            localized: "quitGuard.button.quit",
            defaultValue: "Quit Anyway"
        )  // xcstrings: session-continuation
    }

    /// The choice a capture with nowhere durable to be puts to the person.
    ///
    /// A different loss from the one above, with a different remedy. No gateway
    /// is involved and nothing is in flight, so waiting cannot help: the desk
    /// write and the retry queue have BOTH already refused these bytes, and the
    /// recording exists only in this process's memory. Quitting deletes it. The
    /// alternative is the Try Again its own capture surface is already showing —
    /// which is why this is a question and not a silent refusal: a ⌘Q that
    /// simply did nothing would leave the person with no way out and no idea
    /// why.
    struct UnsavedCapturePrompt: Equatable, Sendable {
        /// Captures whose only copy is in memory. Always ≥ 1 here.
        let count: Int

        /// CAPTURE-neutral, because the count is. A capture is a recording, a
        /// screenshot, or both, and the artifact left with nowhere durable to
        /// be is whichever one the desk and the queue both refused — often the
        /// picture, while the recording is already playable on the desk. Naming
        /// the recording there offered to keep something that was never at
        /// risk and said nothing about what actually was.
        var messageText: String {
            count == 1
                ? String(
                    localized: "quitGuard.unsaved.single.title.v2",
                    defaultValue: "A capture hasn’t reached your desk"
                )  // xcstrings: work-capture
                : String(
                    localized: "quitGuard.unsaved.multiple.title.v2",
                    defaultValue: "\(count) captures haven’t reached your desk"
                )  // xcstrings: work-capture
        }

        /// Names the loss and the way out in one line. It promises nothing about
        /// recovery after the quit, because there is none — the bytes are in
        /// memory and nowhere else.
        var informativeText: String {
            String(
                localized: "quitGuard.unsaved.body.v2",
                defaultValue: "Quitting now loses what was captured. Try Again is still on the capture."
            )  // xcstrings: work-capture
        }

        var quitButtonTitle: String { QuitGuard.quitAnywayTitle }

        /// The safe choice, and the one Esc lands on.
        var keepButtonTitle: String {
            String(
                localized: "quitGuard.unsaved.button.keep.v2",
                defaultValue: "Keep the Capture"
            )  // xcstrings: work-capture
        }
    }

    enum UnsavedCaptureVerdict: Equatable, Sendable {
        case quitNow
        case ask(UnsavedCapturePrompt)
    }

    /// - Parameter unsavedCount: `InAppAudioRecorder.unsavedWorkCaptureCount` —
    ///   captures whose durable homes have all been tried and refused. NOT the
    ///   in-flight publication count, which is answered by waiting instead.
    /// - Parameter powerOffInProgress: wins unconditionally, exactly as above —
    ///   nobody is present to answer, and a modal panel would hold the power-off
    ///   until macOS times the app out.
    static func unsavedCaptureVerdict(
        unsavedCount: Int,
        powerOffInProgress: Bool
    ) -> UnsavedCaptureVerdict {
        guard !powerOffInProgress else { return .quitNow }
        guard unsavedCount > 0 else { return .quitNow }
        return .ask(UnsavedCapturePrompt(count: unsavedCount))
    }

    enum Verdict: Equatable, Sendable {
        /// Terminate with zero UI — the overwhelmingly common quit.
        case quitNow
        case ask(Prompt)
    }

    /// - Parameter liveCount: `InFlightTurnRegistry.liveCount`.
    /// - Parameter singleThreadTitle: title of the sole live thread; ignored
    ///   unless exactly one conversation is live.
    /// - Parameter singleGatewayName: gateway name for that thread, same rule.
    /// - Parameter powerOffInProgress: a logout / restart / shutdown is running.
    ///   A modal panel would block the system power-off until macOS times the
    ///   app out, so this wins unconditionally — the user is not present to
    ///   answer, and the OS is not waiting politely.
    static func verdict(
        liveCount: Int,
        singleThreadTitle: String?,
        singleGatewayName: String?,
        powerOffInProgress: Bool
    ) -> Verdict {
        guard !powerOffInProgress else { return .quitNow }
        guard liveCount > 0 else { return .quitNow }
        // Thread metadata is meaningless once more than one turn is live, and a
        // blank string is not a name — normalize both away so the copy branches
        // read on presence alone.
        let title = liveCount == 1 ? nonEmpty(singleThreadTitle) : nil
        let gateway = liveCount == 1 ? nonEmpty(singleGatewayName) : nil
        return .ask(Prompt(liveCount: liveCount, threadTitle: title, gatewayName: gateway))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

#endif

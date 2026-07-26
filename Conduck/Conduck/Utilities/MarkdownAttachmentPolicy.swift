// Conduck
// MarkdownAttachmentPolicy.swift
//
// The render policy for UNTRUSTED Markdown. Agent reply text is attacker-shaped
// in Conduck's threat model (a hostile gateway, or a prompt-injected agent on a
// benign one), and Textual's Markdown renderers (`StructuredText`, `InlineText`)
// hand two things straight to the system unless told otherwise. Both are closed
// by ONE modifier, `.appliesUntrustedMarkdownPolicy()` — a single token for a
// render site to remember, and `MarkdownAttachmentPolicyDriftGuardTests` fails
// if a render site ever ships without it.
//
// 1 — MARKUP ATTACHMENTS (the automatic half). Textual resolves every markup
// image / custom-emoji URL through an environment attachment loader, and its
// DEFAULT loader (`.image()` → `URLAttachmentLoader` → Textual's shared
// `ImageLoader`) fetches that URL over the network. Left at the default, a reply
// containing `![](https://tracker/pixel.png)` issues an unconditional GET to an
// arbitrary third-party host the moment the bubble renders — outside every
// Conduck networking path, so with no certificate pinning, no auth scheme, no
// logging discipline and no response-size ceiling.
//
// That breaks the zero-outbound invariant and turns anything the agent reads
// (a shared web page, a PDF, tool output) into an injectable IP-address and
// read-receipt beacon — worst for the self-hoster who chose Conduck precisely
// so traffic never leaves their own network.
//
// Conduck has no legitimate remote-markup-attachment case: agent-produced
// files arrive over the file-transfer download path as attachment chips, never
// as markup URLs. So both loaders refuse every URL. Textual resolves
// attachments with `try?` and skips a nil result, leaving the original run
// intact — the reply renders the image's alt text instead.
//
// 2 — LINK TAPS (the deliberate half). A tap on a rendered link calls the
// environment's `openURL` with whatever destination the markup named: Foundation's
// Markdown parser copies the target verbatim into the `.link` attribute, and
// Textual forwards it (`UITextInteractionView.handleTap` on iOS, and on macOS
// `NSTextInteractionView.mouseDown` — the click that STARTS a text selection).
// Markdown link text is chosen independently of its target, so
// `[https://apple.com](anything://…)` renders as a trustworthy label, and the
// default action hands a non-web scheme (`shortcuts:`, `tel:`, `file:`, any
// installed app's deep link) to `UIApplication.open` / `NSWorkspace.open` on one
// tap with the real destination never shown. `UntrustedLinkPolicy` gates that:
// web + mail pass through, and everything else stops to show the destination —
// asking when the destination can be shown in FULL, refusing when it can't.
//
// This is a policy over the two knobs Textual exposes to the app (its attachment
// loaders and the `openURL` action) — NOT a Markdown sanitizer. What the parser
// and the renderer do internally with untrusted text is out of its reach.

import Foundation
import SwiftUI
import Textual

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The `Attachment` type `DeniedAttachmentLoader` declares but never produces.
///
/// `AttachmentLoader` requires a concrete `Attachment` associated type even for
/// a loader that only ever throws, so this is a zero-size placeholder: never
/// constructed, never rendered.
struct UnresolvedMarkupAttachment: Textual.Attachment {
    var description: String { "" }

    @MainActor var body: some View { EmptyView() }

    func sizeThatFits(
        _: ProposedViewSize,
        in _: TextEnvironmentValues
    ) -> CGSize { .zero }

    static func == (_: Self, _: Self) -> Bool { true }

    func hash(into hasher: inout Hasher) { hasher.combine(0) }
}

/// An `AttachmentLoader` that resolves nothing, so no markup URL is ever fetched.
struct DeniedAttachmentLoader: AttachmentLoader {
    typealias Attachment = UnresolvedMarkupAttachment

    /// Thrown for every URL. Textual's `try?` turns it into "no attachment".
    struct Refused: Error {}

    func attachment(
        for _: URL,
        text _: String,
        environment _: ColorEnvironmentValues
    ) async throws -> UnresolvedMarkupAttachment {
        throw Refused()
    }
}

// MARK: - Link taps

/// What a tap on a link inside untrusted Markdown is allowed to do.
///
/// `decision(for:)` and `handleTap(on:presenting:)` are pure and presenter-free,
/// so the whole contract is unit-testable without a window
/// (`UntrustedLinkPolicyTests`).
enum UntrustedLinkPolicy {

    /// The verdict for one tapped destination. `nonisolated` so the pure
    /// `decision(for:)` contract can be compared from any isolation.
    nonisolated enum Decision: Equatable {
        /// Hand to the system open handler as-is.
        case open
        /// Show the real destination in full, then open only if the user agrees.
        case confirm
        /// Tell the user Conduck won't open it, and don't.
        case refuse(Refusal)
        /// Swallow the tap.
        case ignore
    }

    /// Why a destination is refused outright rather than offered.
    nonisolated enum Refusal: Equatable {
        /// `javascript:` / `data:` — the "destination" IS a payload rather than a
        /// place, so there is nothing a person can check by reading it. No agent
        /// answer needs them, so there is no case worth the Open button.
        case activeContent
        /// Longer than can be shown in one alert. Consent would be uninformed:
        /// padding the query pushes the decisive part (`…&name=Wipe`) out of
        /// view, so a truncated prompt authorises what the user cannot see.
        case tooLongToShow
    }

    /// One pending alert: the destination plus the verdict that raised it.
    /// Only `.confirm` / `.refuse` ever reach here.
    nonisolated struct Prompt: Equatable {
        let url: URL
        let decision: Decision

        /// True when the alert offers to open. A refusal is acknowledge-only.
        var offersOpen: Bool { decision == .confirm }
    }

    /// Schemes a tap follows with no interstitial. Each one lands somewhere that
    /// discloses the true destination ITSELF and cannot act without a further
    /// deliberate step: `http`/`https` open a browser showing the URL in its
    /// address bar (or, for a universal link, the app that owns that exact
    /// OS-verified domain — still the destination the URL names, and still the
    /// trust decision the user made by tapping a link to that domain), and
    /// `mailto` opens a compose window the user must still send.
    ///
    /// Deliberately absent: `tel`/`sms`/`facetime` (one tap would dial or
    /// pre-fill a message — premium-rate abuse, and no agent answer needs them),
    /// `file` (LaunchServices opens local content in its default app) and every
    /// app-specific scheme (`shortcuts:` runs a shortcut by name). None of those
    /// is BLOCKED — a self-hosted agent may legitimately answer with
    /// `obsidian://` or `vscode://` — they just have to say where they go first.
    nonisolated static let passThroughSchemes: Set<String> = ["http", "https", "mailto"]

    /// Schemes that carry content instead of naming a place (see
    /// `Refusal.activeContent`).
    nonisolated static let activeContentSchemes: Set<String> = ["javascript", "data"]

    /// The longest destination an alert can put in front of someone in full. Past
    /// it the tap is refused rather than confirmed — the length is a POLICY limit,
    /// not a display convenience. Comfortably above every real app link
    /// (`obsidian://open?vault=…&file=…`, `vscode://file/…`, a meeting URL).
    nonisolated static let maxConfirmableDestinationLength = 240

    /// The allow/ask/refuse/ignore verdict for `url`. Pure — no UI, no side effects.
    nonisolated static func decision(for url: URL) -> Decision {
        // A schemeless target is the one case that stays silent. Agents routinely
        // answer with a bare host path (`[poem.md](/Users/…/poem.md)`), Markdown
        // parses that as a relative link with no scheme, and the system open
        // handler already does nothing with it. Asking would be a dead end: the
        // user taps Open and nothing happens.
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .ignore }
        if passThroughSchemes.contains(scheme) { return .open }
        if activeContentSchemes.contains(scheme) { return .refuse(.activeContent) }
        guard url.absoluteString.count <= maxConfirmableDestinationLength else {
            return .refuse(.tooLongToShow)
        }
        return .confirm
    }

    /// The `openURL` handler installed on untrusted Markdown. `present` is the
    /// surface's own alert presenter — per platform in the modifier below, and a
    /// recorder in the tests.
    ///
    /// `.open` MUST return `.systemAction`: `.handled` also compiles and reads
    /// like "allowed", but it silently swallows the tap, which would break every
    /// legitimate link in every reply. Conversely a prompted tap MUST return
    /// `.handled` and NOT `.systemAction` — the alert owns the outcome, so
    /// handing the URL to the system too would open it whatever the user answers.
    @MainActor static func handleTap(
        on url: URL,
        presenting present: @MainActor (Prompt) -> Void
    ) -> OpenURLAction.Result {
        let verdict = decision(for: url)
        switch verdict {
        case .open:
            return .systemAction
        case .ignore:
            return .discarded
        case .confirm, .refuse:
            present(Prompt(url: url, decision: verdict))
            return .handled
        }
    }

    // MARK: Alert content

    fileprivate static func title(for prompt: Prompt) -> String {
        prompt.offersOpen
            ? String(localized: LocalizedStringResource(
                "markdownLink.confirm.title",
                defaultValue: "Open this link outside Conduck?"
            ))
            : String(localized: LocalizedStringResource(
                "markdownLink.refused.title",
                defaultValue: "Conduck won't open this link"
            ))
    }

    fileprivate static func message(for prompt: Prompt) -> String {
        switch prompt.decision {
        case .confirm:
            // The FULL destination — `decision(for:)` already refused anything
            // too long to show, so nothing here is elided.
            return String(format: String(localized: LocalizedStringResource(
                "markdownLink.confirm.message",
                defaultValue: "This isn't a web link — it asks another app on your device to handle:\n\n%@\n\nThe link's text was written by your AI and can say anything, so open it only if you expected this."
            )), prompt.url.absoluteString)

        case .refuse(.activeContent):
            return String(format: String(localized: LocalizedStringResource(
                "markdownLink.refused.activeContent.message",
                defaultValue: "This link carries content of its own instead of naming a place to go (%@:), so there's nothing you could check before it opens. Conduck doesn't open those."
            )), prompt.url.scheme ?? "")

        case .refuse(.tooLongToShow):
            return String(format: String(localized: LocalizedStringResource(
                "markdownLink.refused.tooLong.message",
                defaultValue: "This isn't a web link, and its destination runs to %1$d characters — too long to show you in full. Conduck won't open a destination you can't check first. It starts with:\n\n%2$@"
            )), prompt.url.absoluteString.count, truncatedDestination(for: prompt.url))

        case .open, .ignore:
            // Unreachable: `handleTap` only prompts for `.confirm` / `.refuse`.
            return ""
        }
    }

    /// A bounded look at a destination that is too long to show whole. Only used
    /// where the alert offers NO way to open it — a truncated destination must
    /// never be something the user can act on.
    fileprivate static func truncatedDestination(for url: URL) -> String {
        String(url.absoluteString.prefix(maxConfirmableDestinationLength)) + "…"
    }

    fileprivate static var openButtonTitle: String {
        String(localized: LocalizedStringResource(
            "markdownLink.confirm.open",
            defaultValue: "Open"
        ))
    }

    fileprivate static var cancelButtonTitle: String {
        String(localized: LocalizedStringResource(
            "markdownLink.confirm.cancel",
            defaultValue: "Cancel"
        ))
    }

    fileprivate static var acknowledgeButtonTitle: String {
        String(localized: LocalizedStringResource(
            "markdownLink.refused.acknowledge",
            defaultValue: "OK"
        ))
    }

    #if os(macOS)
    /// macOS presents app-modally rather than through SwiftUI: the menu-bar
    /// popover reply is hosted in a raw `NSHostingController` OUTSIDE the scene
    /// graph and cannot present a SwiftUI alert at all, and the same
    /// `ConversationThreadView` renders in both that popover and the main window
    /// — so the presentation must not depend on which host it landed in.
    fileprivate static func presentAppModal(_ prompt: Prompt) {
        // Deferred one turn of the main actor so the modal run loop starts AFTER
        // AppKit finishes dispatching the `mouseDown` Textual opened the link
        // from (`NSTextInteractionView.mouseDown`, which sets its drag anchor
        // right after calling `openURL`). Running `runModal()` inside that event
        // would start a nested run loop mid-dispatch, before the view had
        // finished handling its own click. The modal may still swallow the
        // matching `mouseUp`, which is harmless: `mouseDragged` only fires while
        // a button is held and the next `mouseDown` reassigns the anchor.
        Task { @MainActor in
            // The menu-bar surface isn't necessarily frontmost (same rationale as
            // `RegionCaptureController.runPermissionAlert`). A `.transient`
            // popover may close behind the alert; its reply is retained and
            // returns on reopen.
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title(for: prompt)
            alert.informativeText = message(for: prompt)

            if prompt.offersOpen {
                // NO key equivalent on Open: AppKit makes the first button the
                // Return-key default, and a security interstitial must not be
                // accepted by muscle memory. Esc stays wired to Cancel (NSAlert
                // does that itself only for a button titled the English "Cancel").
                alert.addButton(withTitle: openButtonTitle).keyEquivalent = ""
                alert.addButton(withTitle: cancelButtonTitle).keyEquivalent = "\u{1b}"
            } else {
                alert.addButton(withTitle: acknowledgeButtonTitle)
            }

            // ONE `runModal()` — it blocks until answered, and calling it twice
            // would show the alert again.
            let response = alert.runModal()
            if prompt.offersOpen, response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(prompt.url)
            }
        }
    }
    #endif
}

// MARK: - The modifier

/// Carries BOTH halves of the policy, so a render site has one token to apply and
/// the drift guard has one token to count.
private struct UntrustedMarkdownPolicy: ViewModifier {

    #if os(macOS)
    func body(content: Content) -> some View {
        denyingAttachments(content)
            .environment(\.openURL, OpenURLAction { url in
                // `assumeIsolated`, not a hop: `OpenURLAction`'s handler type
                // carries no isolation, but the action is `@MainActor` API and
                // every caller (Textual's tap / `mouseDown`) is on the main
                // thread — and the verdict has to be RETURNED, not awaited.
                MainActor.assumeIsolated {
                    UntrustedLinkPolicy.handleTap(
                        on: url,
                        presenting: UntrustedLinkPolicy.presentAppModal
                    )
                }
            })
    }
    #else
    /// The pending alert, held HERE rather than app-wide or in a parent.
    ///
    /// Scene-local by construction: this modifier instance lives in the view tree
    /// of the window that was tapped, so an iPad showing two Conduck windows asks
    /// in the right one. A global window search cannot recover that —
    /// `UIWindow.isKeyWindow` is key-within-its-SCENE, and
    /// `UIApplicationSupportsMultipleScenes` is on, so two side-by-side scenes
    /// each have one. Keeping it inside the modifier (not in a parent) also means
    /// the whole policy still travels with the one token the drift guard counts.
    ///
    /// Cost, accepted: mutating this re-evaluates the modifier and re-touches the
    /// wrapped `StructuredText` — the churn the Equatable `AgentMarkdownBody` leaf
    /// exists to avoid. (SwiftUI may re-evaluate a body whenever it likes; what is
    /// bounded is the mutation.) Only two user acts write it — a link tap and the
    /// alert's dismissal — and neither can land mid-selection: Textual's iOS link
    /// path is a `UITapGestureRecognizer` that requires the selection gestures to
    /// fail, so a selection drag never reaches `openURL`. This is also why the
    /// policy keeps no other state.
    @State private var prompt: UntrustedLinkPolicy.Prompt?

    func body(content: Content) -> some View {
        denyingAttachments(content)
            .environment(\.openURL, OpenURLAction { url in
                MainActor.assumeIsolated {
                    UntrustedLinkPolicy.handleTap(on: url, presenting: { prompt = $0 })
                }
            })
            .alert(
                Text(prompt.map(UntrustedLinkPolicy.title(for:)) ?? ""),
                isPresented: Binding(
                    get: { prompt != nil },
                    set: { if !$0 { prompt = nil } }
                )
            ) {
                if let prompt {
                    if prompt.offersOpen {
                        Button(UntrustedLinkPolicy.cancelButtonTitle, role: .cancel) {
                            self.prompt = nil
                        }
                        // Opens through UIKit, not the environment action: the
                        // environment here is the POLICED one, and re-entering the
                        // policy would prompt about the URL the user just approved.
                        Button(UntrustedLinkPolicy.openButtonTitle) {
                            self.prompt = nil
                            UIApplication.shared.open(prompt.url)
                        }
                    } else {
                        Button(UntrustedLinkPolicy.acknowledgeButtonTitle) {
                            self.prompt = nil
                        }
                    }
                }
            } message: {
                if let prompt {
                    Text(UntrustedLinkPolicy.message(for: prompt))
                }
            }
    }
    #endif

    /// Shared by both platform bodies so the fetch-refusal can never be fixed on
    /// one platform and forgotten on the other.
    private func denyingAttachments(_ content: Content) -> some View {
        content
            .textual.imageAttachmentLoader(DeniedAttachmentLoader())
            .textual.emojiAttachmentLoader(DeniedAttachmentLoader())
    }
}

extension View {
    /// Applies the whole untrusted-Markdown policy to this subtree: markup
    /// attachment URLs are refused (nothing is fetched), and link taps are gated
    /// by `UntrustedLinkPolicy`. Apply to EVERY Textual renderer that shows
    /// agent-authored Markdown — `StructuredText` and `InlineText` both read
    /// these same attachment loaders and this same `openURL` action.
    func appliesUntrustedMarkdownPolicy() -> some View {
        modifier(UntrustedMarkdownPolicy())
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayReadinessView.swift
//
// Guided gateway-setup READINESS beat (between the lane fork and the helper
// step). The helper that follows CONNECTS to a gateway — it does NOT install
// one — so this screen makes the prerequisite explicit: your AI has to be up
// and reachable already. Without it, the helper's "I don't install gateways"
// behavior reads as a failure rather than the expected hand-off.
//
// Lane-specific (`GatewaySetupLane`) in title, body AND action shape:
//
//   .fullAgent — "Is your server running?" over OpenClaw / Hermes on an
//     always-on machine. Its "Don't have one yet? Get OpenClaw or Hermes"
//     sentence IS this lane's answer for the user who has nothing, so the screen
//     needs no second action: one filled "Yes, it's running" CTA in the pinned
//     footer, and `onAdapterEscape` is never passed.
//
//   .custom — "Is your AI running as a server?" over the user's own OpenAI-compatible
//     server. Its body card is TWO SHORT LINES because the answers sit below it: a
//     premise carrying an `InfoTipButton`, and one reassurance. The product examples
//     — Ollama, LM Studio — ride the first answer card instead, where the choice is
//     actually made. The answer is TWO `OnboardingChoiceCard`s in the scrollable
//     content, the same pattern the chooser and the fork use: the cards ARE the
//     actions, so the footer is empty.
//
// The custom lane sorts on ONE axis: does an OpenAI-compatible server EXIST, or
// is the user's AI a script / something they built. Reachability is deliberately
// NOT part of that question — the helper step immediately after this one is what
// creates it ("Sets up a secure link to your devices"; the user picks Tailscale, a
// free public link, Cloudflare, or their own HTTPS). Gating on reachability here
// sends the commonest self-hoster of all — Ollama on `localhost`, honestly unable
// to claim their phone can reach it — down the adapter lane, which solves a problem
// they do not have. Hence the second body line: it retires the objection out loud
// rather than letting it decide the answer.
//
// Terminal access on the server's machine is likewise absent from the cards: BOTH
// answers end at the helper step (the adapter brief continues there too), so it
// sorts nothing. It is stated where it applies — the heads-up and commands steps.
//
// Why the two cards carry EQUAL weight (no `emphasis:`, no filled-vs-bordered
// pairing) and why "I'm not sure" rides the second card: answering yes wrongly is
// the EXPENSIVE mistake — it sends the user to a terminal to run a pairing command
// against a server that isn't there. The second card costs one screen they can back
// out of, and the adapter brief it opens leads with "Your AI stays exactly as it
// is", which reads fine to someone who arrived merely uncertain. So the screen makes
// the cheap failure the easy one to fall into, and neither card is styled as the
// consolation prize.
//
// The premise takes a TIP, not a link to the site's compatibility section — for a
// different reason per platform, and neither wants a link. On iPhone/iPad the
// heads-up step one screen earlier has already handed over the lane's site page, so
// a second link is the same handoff twice. On macOS there IS no heads-up step (the
// fork routes straight here), but there is also nothing to hand off: that page
// exists to move someone to a computer, and a Mac user is at one. Either way a link
// here ejects the reader to Safari mid-question, before they have answered anything.
// (This step is never an ENTRY step: the chooser, `.selfHosted`, and an unconfigured
// `.custom` quick connect all open on the lane fork, so it always arrives with a
// back-stack behind it and a Back arrow of its own.)
//
// Like every guided sub-step, the container paints the gradient + Back/Close
// chrome; this view renders only the mascot / title / body card (plus the custom
// lane's cards) and pins the full-agent lane's CTA via `.onboardingStepLayout`.

import SwiftUI

struct GatewayReadinessView: View {
    let lane: GatewaySetupLane
    let proceed: () -> Void

    /// The custom lane's SECOND answer — "not yet, or I'm not sure": the user who
    /// built their OWN AI (e.g. with an AI coding tool) and stalls here because that
    /// AI is not an HTTP server, and the user who simply can't tell. The container
    /// passes a non-nil closure ONLY for `.custom` (→ the adapter step); `.fullAgent`
    /// leaves it `nil` and answers "no" through its inline "Get OpenClaw" sentence.
    var onAdapterEscape: (() -> Void)? = nil

    /// Lane-specific screen title. The full-agent lane can presume a server (the
    /// lane IS "run OpenClaw or Hermes"), so it asks whether that server is up. The
    /// custom lane can't presume one at all, so it asks the question its two answers
    /// actually sort on: is the user's AI server-shaped in the first place.
    private var title: LocalizedStringKey {
        switch lane {
        case .fullAgent:
            return "Is your server running?" // xcstrings: gateway-readiness
        case .custom:
            return "Is your AI running as a server?" // xcstrings: gateway-readiness
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-detective")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title
            Text(title)
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            bodyCard

            // The custom lane answers with cards, in the scrollable content; the
            // full-agent lane answers with the pinned footer CTA below.
            if lane == .custom {
                customAnswerCards
            }
        }
        .onboardingStepLayout {
            footer
        }
    }

    // MARK: - Body card (lane-specific copy)

    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch lane {
            case .fullAgent:
                Text("You'll need OpenClaw or Hermes already running on an always-on computer — a Mac mini, a Raspberry Pi, or a small cloud server. The next step won't install it for you.") // xcstrings: gateway-readiness
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only the full-agent lane has products to recommend; the custom
                // lane (user-supplied server) has none. One normal sentence with
                // ONLY the words "OpenClaw" and "Hermes" tappable — inline markdown
                // links whose URLs come from the registry.
                Text(getServerSentence)
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .tint(.blue)
                    .fixedSize(horizontal: false, vertical: true)

            case .custom:
                // Two short lines only. The card is deliberately minimal on this
                // lane because the two answer cards sit below it: every row here
                // pushes them further under the fold, and on a phone an answer the
                // user has to scroll to find is worse than an unstated requirement.
                //
                // Line 1 — the premise, stated in the same word the rest of the lane
                // uses ("server", as on the chooser, the commands step and the
                // gateway editor's own tips). NOT "gateway": this was the only screen
                // in the flow spelling it that way, and it is the techiest word a
                // first-timer meets here. The definition — including what
                // "OpenAI-compatible" and https mean for them — lives in the tip, so
                // the screen stays two lines and the reader opts in to the detail.
                //
                // The tip button is a SIBLING of the text, never inside a choice card:
                // `OnboardingChoiceCard` claims its whole row, and a nested tip would
                // hand its taps to the card's action (`InfoTipButton`'s placement
                // contract). No `Spacer` after it — the enclosing VStack is already
                // leading-aligned, and a flexible spacer competes with the Text for
                // width and wraps the sentence earlier than it needs to.
                HStack(spacing: 0) {
                    Text("Conduck needs your AI running as a server.") // xcstrings: gateway-readiness
                        .onboardingScaledFont(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    InfoTipButton(tip: GatewayFieldTips.runningAsServer)
                }

                // Line 2 — the objection this screen exists to disarm. Someone running
                // Ollama on `localhost` can answer the title honestly and still fear
                // the "yes" card, because their phone plainly cannot reach that
                // address today; without this line they take the adapter branch, which
                // is the wrong lane for them. "this device", not "this phone" — the
                // guided flow reaches readiness on macOS too (where the iOS-only
                // heads-up step is skipped), and it matches the gateway editor's own
                // URL tip.
                Text("It doesn't have to be reachable from this device yet — the next step sets that up.") // xcstrings: gateway-readiness
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    /// The "don't have one yet?" sentence as a markdown `AttributedString`, with
    /// only "OpenClaw" and "Hermes" as inline tappable links. URLs are pulled from
    /// the registry and substituted into the localized template, so the link
    /// targets stay in one place. Falls back to plain (unlinked) text if the
    /// markdown ever fails to parse.
    private var getServerSentence: AttributedString {
        let openclaw = RemoteAgentBackendRegistry.lookup(id: .openclaw).docsURL.absoluteString
        let hermes = RemoteAgentBackendRegistry.lookup(id: .hermes).docsURL.absoluteString
        let template = String(localized: LocalizedStringResource(
            "gatewaySetup.readiness.getServer",
            defaultValue: "Don't have one yet? Get [OpenClaw](%1$@) or [Hermes](%2$@)."
        ))
        let markdown = String(format: template, openclaw, hermes)
        return (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString("Don't have one yet? Get OpenClaw or Hermes.")
    }

    // MARK: - Custom-lane answers (equal-weight cards, in-content)

    /// The custom lane's two answers, as the chooser/fork choice cards rather than
    /// a filled CTA over a bordered runner-up: an unsure user must not be nudged
    /// toward "yes" (see the file header). Both cards stay at the default weight —
    /// no `emphasis:`, no badge — so the only steer is reading order.
    private var customAnswerCards: some View {
        VStack(spacing: 12) {
            // Answers the title's question. "already running" is permissive on
            // purpose — the bar is that the server EXISTS, not that it is exposed,
            // holds a certificate, or answers from outside its own machine; the
            // helper step handles all three. The examples are two names a first-timer
            // plausibly recognizes (LM Studio earns its slot over a proxy like
            // LiteLLM by being the one with a window and buttons), and the trailing
            // clause carries everyone else. The glyph matches the tip's `server.rack`
            // so the definition and the answer it qualifies read as one thing.
            OnboardingChoiceCard(
                icon: "server.rack",
                title: "Yes — it's already running", // xcstrings: gateway-readiness
                subtitle: "Ollama, LM Studio, or a server you set up yourself.", // xcstrings: gateway-readiness
                action: proceed
            )
            .accessibilityIdentifier("guidedSetup.readiness.proceed")

            // `cpu` (the chooser's glyph for "an AI you built") against the first
            // card's `server.rack`: the difference between the two answers is
            // whether there is a server around the AI at all — which is the whole
            // axis this step sorts on. "No" rather than "Not yet" so the pair reads
            // as the two answers to the title; "or I'm not sure" keeps uncertainty
            // landing on the cheap, reversible branch.
            if let onAdapterEscape {
                OnboardingChoiceCard(
                    icon: "cpu",
                    title: "No, or I'm not sure", // xcstrings: gateway-readiness
                    subtitle: "You built your own AI, or it's a script — not a server.", // xcstrings: gateway-readiness
                    action: onAdapterEscape
                )
                .accessibilityIdentifier("guidedSetup.readiness.adapterEscape")
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Pinned footer (full-agent lane only)

    /// The full-agent lane's single filled CTA. The custom lane's actions are the
    /// cards above, so its footer is empty — the scaffold then yields the whole
    /// viewport to the content, exactly as on the chooser and fork steps.
    @ViewBuilder
    private var footer: some View {
        switch lane {
        case .fullAgent:
            Button(action: proceed) {
                Text("Yes, it's running") // xcstrings: gateway-readiness
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textEmphasis)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .primaryCTAButton()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Constants.Layout.horizontalPadding)
            .accessibilityIdentifier("guidedSetup.readiness.proceed")

        case .custom:
            EmptyView()
        }
    }
}

#Preview("Full agent") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayReadinessView(lane: .fullAgent, proceed: {})
    }
}

// The custom lane without an escape closure — not what the container ships, but
// it proves the "yes" card still stands alone if `onAdapterEscape` is ever nil.
#Preview("Custom — no escape") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayReadinessView(lane: .custom, proceed: {})
    }
}

// The custom lane as the container ships it: both answers, equal weight.
#Preview("Custom — adapter escape") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayReadinessView(lane: .custom, proceed: {}, onAdapterEscape: {})
    }
}

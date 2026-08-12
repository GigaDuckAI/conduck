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
//   .custom — "Can Conduck reach your AI?" over the user's own OpenAI-compatible
//     server. Its body card is TWO LINES (lead + a link to the site's compatibility
//     section) because the answers sit below it: the product examples — Ollama,
//     LiteLLM — ride the first answer card instead, where the choice is actually
//     made, and are said once per viewport. The answer is TWO `OnboardingChoiceCard`s
//     in the scrollable content, the same pattern the chooser and the fork use: the
//     cards ARE the actions, so the footer is empty.
//
// Why the custom lane's two cards carry EQUAL weight (no `emphasis:`, no
// filled-vs-bordered pairing) and why "I'm not sure" rides the second card:
// answering yes wrongly is the EXPENSIVE mistake — it sends the user to a
// terminal to run a pairing command against a server that isn't there. The
// second card costs one screen they can back out of, and the adapter brief it
// opens leads with "Your AI stays exactly as it is", which reads fine to someone
// who arrived merely uncertain. So the screen makes the cheap failure the easy
// one to fall into, and neither card is styled as the consolation prize.
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
    /// lane IS "run OpenClaw or Hermes"); the custom lane can't, so it asks for the
    /// actual requirement — reachability — instead of presuming the thing exists.
    private var title: LocalizedStringKey {
        switch lane {
        case .fullAgent:
            return "Is your server running?" // xcstrings: gateway-readiness
        case .custom:
            return "Can Conduck reach your AI?" // xcstrings: gateway-readiness
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
                // Two lines only — a lead naming WHAT (an OpenAI-compatible gateway)
                // + WHERE (a server you run), then the learn-more link. The card is
                // deliberately SHORT on this lane because the two answer cards sit
                // below it: every row here pushes them further under the fold, and on
                // a phone an answer the user has to scroll to find is worse than an
                // unstated requirement. What the lane needs (chat now, files later)
                // the lead sentence and the cards already carry.
                Text("Conduck connects to an OpenAI-compatible gateway on a server you run — a VPS, a Mac mini, a Raspberry Pi.") // xcstrings: gateway-readiness
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Learn-more — the custom lane's analog of the full-agent lane's
                // "Get OpenClaw or Hermes" sentence, pointing at the site's
                // compatibility section (the durable OpenAI-API rule + what works),
                // NOT the install walkthrough. It names no products: the answer
                // cards below name them at the point the choice is made, and saying
                // them twice in one viewport reads as padding.
                Text(customLearnMore)
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .tint(.blue)
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

    /// The custom lane's "learn more" sentence as a markdown `AttributedString`,
    /// with only the call-to-read phrase linked to the site's compatibility section
    /// (`setupGuideURL` + `#compatibility`). Plain-text fallback if the markdown
    /// fails to parse. The product examples live on the answer cards, not here.
    ///
    /// Key is `…custom.compat.open`, NOT the retired `…custom.compat`: rewording an
    /// existing catalog key's `defaultValue:` never shows at runtime — the catalog
    /// entry wins — so a reworded string MUST take a new key or it silently keeps
    /// rendering the old text.
    private var customLearnMore: AttributedString {
        let url = Constants.setupGuideURL + "#compatibility"
        let template = String(localized: LocalizedStringResource(
            "gatewaySetup.readiness.custom.compat.open",
            defaultValue: "Not sure what counts? [See what Conduck can talk to](%1$@)."
        ))
        let markdown = String(format: template, url)
        return (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString("Not sure what counts? See what Conduck can talk to.")
    }

    // MARK: - Custom-lane answers (equal-weight cards, in-content)

    /// The custom lane's two answers, as the chooser/fork choice cards rather than
    /// a filled CTA over a bordered runner-up: an unsure user must not be nudged
    /// toward "yes" (see the file header). Both cards stay at the default weight —
    /// no `emphasis:`, no badge — so the only steer is reading order.
    private var customAnswerCards: some View {
        VStack(spacing: 12) {
            // Answers the title's question — REACHABLE, not merely running. A server
            // that is up on a box this device cannot route to is the case that used
            // to slip through a bare "Yes, it's running" and land the user in the
            // terminal step anyway, which is the expensive failure this screen exists
            // to prevent.
            OnboardingChoiceCard(
                icon: "server.rack",
                title: "Yes — it's running and I can reach it", // xcstrings: gateway-readiness
                subtitle: "Ollama, LiteLLM, or a server you already run.", // xcstrings: gateway-readiness
                action: proceed
            )
            .accessibilityIdentifier("guidedSetup.readiness.proceed")

            // `cpu` (the chooser's glyph for "an AI you built") against the first
            // card's `server.rack`: the difference between the two answers is
            // whether there is a server around the AI at all.
            if let onAdapterEscape {
                OnboardingChoiceCard(
                    icon: "cpu",
                    title: "Not yet, or I'm not sure", // xcstrings: gateway-readiness
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

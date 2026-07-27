// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayReadinessView.swift
//
// Guided gateway-setup READINESS beat (between the lane fork and the helper
// step). The helper that follows CONNECTS to a gateway — it does NOT install
// one — so this screen makes the prerequisite explicit: your server has to be
// up and reachable already. Without it, the helper's "I don't install gateways"
// behavior reads as a failure rather than the expected hand-off.
//
// Lane-specific (`GatewaySetupLane`): the full-agent lane points at OpenClaw /
// Hermes on an always-on machine and offers a "Get OpenClaw" docs link for the
// user who has nothing yet; the custom lane points at the user's own
// OpenAI-compatible server and links the site's compatibility section (which
// carries the product examples — Ollama, LiteLLM — so the in-app rows stay light).
//
// Like every guided sub-step, the container paints the gradient + Back/Close
// chrome; this view only renders the mascot / title / body card and pins its
// single primary CTA via `.onboardingStepLayout`.

import SwiftUI

struct GatewayReadinessView: View {
    let lane: GatewaySetupLane
    let proceed: () -> Void

    /// The custom-lane escape hatch: for the user who built their OWN AI (e.g. with
    /// an AI coding tool) and stalls here because that AI is not an HTTP server. The
    /// container passes a non-nil closure ONLY for `.custom` (→ the adapter step);
    /// the `.fullAgent` lane leaves it `nil` and the footer renders exactly as before.
    var onAdapterEscape: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-detective")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title
            Text("Is your server running?") // xcstrings: gateway-readiness
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            bodyCard
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
                // The bring-your-own-gateway lane is the one beat that diverges from
                // the OpenClaw/Hermes lane: a ONE-LINE lead naming WHAT (an
                // OpenAI-compatible gateway) + WHERE (a server you run), two light
                // requirement rows (a floor + an optional — capabilities are framed
                // OPEN, never a fixed product need), and a learn-more link that
                // carries the product examples (Ollama, LiteLLM) so the rows stay
                // scannable.
                Text("Conduck connects to an OpenAI-compatible gateway on a server you run — a VPS, a Mac mini, a Raspberry Pi.") // xcstrings: gateway-readiness
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    infoRow("bubble.left.and.bubble.right", LocalizedStringResource(
                        "gatewaySetup.readiness.custom.req.chat",
                        defaultValue: "Required — OpenAI-compatible chat"))
                    infoRow("folder", LocalizedStringResource(
                        "gatewaySetup.readiness.custom.req.files",
                        defaultValue: "Optional — a file server for attachments"))
                }

                // Learn-more — the custom lane's analog of the full-agent lane's
                // "Get OpenClaw or Hermes" sentence. Carries the product examples
                // and points at the site's compatibility section (the durable
                // OpenAI-API rule + what works), NOT the install walkthrough.
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
    /// carrying the product examples (Ollama, LiteLLM) with only the call-to-read
    /// phrase linked to the site's compatibility section (`setupGuideURL` +
    /// `#compatibility`). Plain-text fallback if the markdown fails to parse.
    private var customLearnMore: AttributedString {
        let url = Constants.setupGuideURL + "#compatibility"
        let template = String(localized: LocalizedStringResource(
            "gatewaySetup.readiness.custom.compat",
            defaultValue: "Ollama, LiteLLM, something else? [See what Conduck can talk to](%1$@)."
        ))
        let markdown = String(format: template, url)
        return (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString("Ollama, LiteLLM, something else? See what Conduck can talk to.")
    }

    /// One requirement row: an SF Symbol in a fixed-width gutter + a short phrase —
    /// matching `GatewayHelperTrustView.capabilityRow` exactly: an accent-tinted
    /// icon beside neutral `textSecondary` copy (the `AccentGlyphActionLabelStyle`
    /// vocabulary — a calm blue pop, never amber, which is reserved for the flow's
    /// one true caution).
    private func infoRow(_ symbol: String, _ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 22, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Pinned footer (single primary CTA)

    private var footer: some View {
        VStack(spacing: 12) {
            Button(action: proceed) {
                Text("Yes, it's running") // xcstrings: gateway-readiness
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textEmphasis)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("guidedSetup.readiness.proceed")

            // Custom-lane-only escape for the user whose self-built AI is not an
            // HTTP server yet. A BORDERED secondary (the primer's "Set up manually"
            // chrome) — not accent text, so the footer keeps exactly one blue and
            // this still reads as a real, pressable alternative. Non-nil only for
            // `.custom`; the full-agent lane never renders it.
            if let onAdapterEscape {
                Button(action: onAdapterEscape) {
                    Text("I built my own AI — it's not a server yet") // xcstrings: gateway-readiness
                        .onboardingScaledFont(.headline)
                        .foregroundColor(AppColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AppColors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("guidedSetup.readiness.adapterEscape")
            }
        }
        .padding(.horizontal, Constants.Layout.horizontalPadding)
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

#Preview("Custom") {
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

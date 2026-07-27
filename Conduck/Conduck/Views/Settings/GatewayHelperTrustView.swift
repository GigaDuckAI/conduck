// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayHelperTrustView.swift
//
// Guided-setup sub-step (between the readiness step and the commands step) that
// introduces the `conduck-connect` helper and sets trust / network expectations
// BEFORE the user is shown any commands to copy-paste. The reasoning: the next
// screen asks the user to download and run a script against their own server, so
// this screen answers "what is this, what does it do, and is it trustworthy?"
// up front. Structure (NOT a wall of prose): a lead line that NAMES + links the
// helper to its auditable source, three scannable capability rows, a demoted
// connection-options line, and a SURFACED confident safety statement — no
// collapsed "is it safe?" question (surfacing the question primes doubt; a calm
// declarative statement plus a tap-to-read-the-source link build more trust).
//
// Lane-agnostic copy: both lanes (full-agent + custom) run the same helper, so
// the body text is identical. `lane` is carried only to keep the sub-step view
// contract uniform across the guided flow (see `GatewaySetupLane`).

import SwiftUI

/// Guided-setup step that primes the user on the `conduck-connect` helper and
/// the trust model, then hands control back to the container via `proceed`.
struct GatewayHelperTrustView: View {
    /// Which self-hosted lane the flow is walking. Copy is the same for both
    /// lanes today; kept for a uniform sub-step contract (`GatewaySetupLane`).
    let lane: GatewaySetupLane
    /// Advance to the commands step.
    let proceed: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-suit")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title
            Text(LocalizedStringResource(
                "gatewaySetup.helperTrust.title",
                defaultValue: "Create your setup code"
            ))
                .onboardingScaledFont(.title2, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 32)

            // What it does — a one-line lead that NAMES + links the helper, then
            // three scannable capability rows. The link on "conduck-connect" is the
            // strongest trust signal (one tap to the auditable source), placed at the
            // exact moment the helper is named. Replaces the old three-grey-paragraph
            // wall with a lead + an icon column the eye can scan.
            VStack(alignment: .leading, spacing: 16) {
                Text(leadSentence)
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .tint(.blue)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    capabilityRow("magnifyingglass", LocalizedStringResource(
                        "gatewaySetup.helperTrust.does.check",
                        defaultValue: "Checks your server is reachable"
                    ))
                    capabilityRow("lock.shield", LocalizedStringResource(
                        "gatewaySetup.helperTrust.does.link",
                        defaultValue: "Sets up a secure link to your devices"
                    ))
                    capabilityRow("qrcode", LocalizedStringResource(
                        "gatewaySetup.helperTrust.does.code",
                        defaultValue: "Prints a code to bring back here"
                    ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onboardingCardPadding()
            .glassCardBackground()
            .padding(.horizontal, 32)

            // Connection options — demoted to a single fine-print line: the user
            // can't act on this choice yet (the script offers the menu interactively
            // with trade-offs), so it sets expectations without competing with the
            // action above.
            Text(LocalizedStringResource(
                "gatewaySetup.helperTrust.connect",
                defaultValue: "You'll pick how it connects — a private Tailscale link, a free public link (no domain or router setup), Cloudflare, or your own HTTPS."
            ))
                .onboardingScaledFont(.footnote)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)

            // Safety — surfaced as a confident statement, NOT a collapsed "Is it
            // safe?" question (the question primes doubt). The green seal carries the
            // trust; the quiet lock carries the one instruction the user must act on.
            VStack(alignment: .leading, spacing: 12) {
                safetyRow(
                    "checkmark.seal.fill",
                    color: AppColors.success,
                    LocalizedStringResource(
                        "gatewaySetup.helperTrust.safe.confident",
                        defaultValue: "Open source and local — it runs only on your computer, asks before every change it makes, and sends us nothing."
                    )
                )
                safetyRow(
                    "lock.fill",
                    color: AppColors.textTertiary,
                    LocalizedStringResource(
                        "gatewaySetup.helperTrust.safe.keepPrivate",
                        defaultValue: "Your setup code carries your gateway token — keep it private."
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
        }
        .onboardingStepLayout {
            // Pinned footer — single primary CTA into the commands step, in the
            // shared onboarding primary-button style (plain button, accent fill).
            Button(action: proceed) {
                Text(LocalizedStringResource(
                    "gatewaySetup.helperTrust.cta",
                    defaultValue: "Show me the command"
                ))
                    .onboardingScaledFont(.headline)
                    .foregroundColor(AppColors.textEmphasis)
                    .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Constants.Layout.horizontalPadding)
        }
    }

    // MARK: - Lead sentence (names + links the helper)

    /// Lead sentence with ONLY "conduck-connect" as an inline tappable link to the
    /// public, auditable source repo — the strongest trust signal, at the exact
    /// moment the helper is named. Mirrors `GatewayReadinessView.getServerSentence`:
    /// a localized markdown template with the URL substituted, plain-text fallback
    /// if the markdown ever fails to parse.
    private var leadSentence: AttributedString {
        let url = Constants.conduckConnectRepoURL.absoluteString
        let template = String(localized: LocalizedStringResource(
            "gatewaySetup.helperTrust.lead",
            defaultValue: "Run [conduck-connect](%1$@), a small open-source helper, on that computer."
        ))
        let markdown = String(format: template, url)
        return (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString("Run conduck-connect, a small open-source helper, on that computer.")
    }

    // MARK: - Rows

    /// One "what it does" capability row: an accent-tinted SF Symbol + a short
    /// phrase, with a fixed icon width so the phrases left-align into a clean
    /// column — the `AccentGlyphActionLabelStyle` vocabulary (blue glyph, neutral
    /// text), matching the readiness step's requirement rows. Never amber — that's
    /// reserved for the flow's one true caution on the adapter step.
    private func capabilityRow(_ symbol: String, _ text: LocalizedStringResource) -> some View {
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

    /// One safety row: a meaning-bearing SF Symbol (green seal = trust, quiet lock =
    /// the keep-private instruction) + a footnote-weight statement.
    private func safetyRow(_ symbol: String, color: Color, _ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(color)
                .frame(width: 22, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .onboardingScaledFont(.footnote)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayHelperTrustView(lane: .fullAgent, proceed: {})
    }
}

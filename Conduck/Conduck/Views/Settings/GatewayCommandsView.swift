// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayCommandsView.swift
//
// Guided-setup step that shows the one-paste `conduck-connect` command to run on
// the user's always-on server, then hands off to scan/paste the resulting setup
// code. Renders the SHORT one-paste command (download to disk then `bash`, same
// form as the per-gateway editor's quick connect). Every lane uses `--setup`;
// the script reports detected gateways and asks which one to configure.
//
// The command card leads on every platform and the neutral what-happens-next
// panel carries the come-back-here cue. (The "easier from a computer" pointer —
// the lane-correct site page — was already given once, by the guided flow's
// heads-up step; this screen repeats no handoff.) The footer stays the screen's
// single FILLED CTA on every platform — this step is visited twice, and on the
// return visit (QR code in hand) that button is the sole completion door.
//
// The container owns routing; this view only reports the "scan or paste" tap.
// Mirrors `GatewayChooserStepView`'s mascot + title + `.onboardingStepLayout`
// structure.

import SwiftUI

/// Step between the chooser and the scan/paste import: "run this on your server."
struct GatewayCommandsView: View {
    /// Move on to scanning / pasting the setup code the command printed.
    let onScanOrPaste: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-pointing")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title names the step's real job — running the command on the server.
            // The in-app mechanics (copy here, or grab it from the site on a
            // computer) are the content below, not the title.
            Text(LocalizedStringResource(
                "gateway.commands.title.run",
                defaultValue: "Run the setup command"
            ))
            .onboardingScaledFont(.title2, weight: .bold)
            .foregroundStyle(AppColors.textEmphasis)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 16) {
                // Lead = the only NEW info vs the prior steps: WHERE it goes (a
                // terminal). "always-on computer" + "what conduck-connect is" were
                // both established on the helper-trust screen; not repeated here.
                Text(LocalizedStringResource(
                    "gateway.commands.intro.paste",
                    defaultValue: "Run it in a terminal on that server."
                ))
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                // The command itself (wrapped, bordered in-card copy) — the
                // centerpiece on every platform.
                ConduckConnectCommandBlock()

                // Terminal→app hand-off: what conduck-connect prints (a QR code /
                // setup code) and the action that finishes setup. A NEUTRAL panel —
                // it's sequencing, not a warning, so it carries no amber.
                handoffCallout
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
        }
        .onboardingStepLayout {
            footer
        }
    }

    // MARK: - Pinned footer (single primary CTA)

    private var footer: some View {
        Button(action: onScanOrPaste) {
            // Names the RETURN action plainly. The old "I've run it — …" read as a
            // state assertion (the button claiming the user did something); the
            // handoff line above already carries the "do this after" sequencing.
            // macOS has no camera — it can only paste the printed code, not scan.
            #if os(macOS)
            ctaLabel(LocalizedStringResource(
                "gateway.commands.cta.paste.mac",
                defaultValue: "Paste setup code"
            ))
            #else
            ctaLabel(LocalizedStringResource(
                "gateway.commands.cta.paste",
                defaultValue: "Scan or paste setup code"
            ))
            #endif
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Constants.Layout.horizontalPadding)
    }

    /// Shared primary-CTA chrome — only the label text differs per platform.
    private func ctaLabel(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .onboardingScaledFont(.headline)
            .foregroundColor(AppColors.textEmphasis)
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
            .padding(.vertical, 16)
            .background(Color.accentColor)
            .cornerRadius(14)
    }

    // MARK: - Terminal → app hand-off panel (neutral)

    /// What comes back from the terminal: a platform icon + the bold outcome (what
    /// conduck-connect prints) + the action that finishes setup — including the
    /// come-back-to-this-device cue on iOS, where the user has likely walked off to
    /// a computer. A NEUTRAL glass panel, not amber: this is sequencing, not a
    /// warning (amber is reserved for the flow's one true caution). iOS can scan
    /// the QR or paste; macOS (no camera) pastes the code — mirrors the footer
    /// CTA's platform gate and the script's own "scan the QR or paste this code /
    /// on Mac, paste the code".
    private var handoffCallout: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: handoffIcon)
                .onboardingScaledFont(.title3)
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(handoffOutcome)
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(handoffAction)
                    .onboardingScaledFont(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCardBackground()
        .accessibilityElement(children: .combine)
    }

    private var handoffIcon: String {
        #if os(macOS)
        return "doc.on.clipboard"
        #else
        return "qrcode.viewfinder"
        #endif
    }

    /// What the script prints — a QR + code on iOS (both usable), the code only on
    /// macOS (no camera, so the QR is irrelevant and omitted to avoid confusion).
    private var handoffOutcome: LocalizedStringResource {
        #if os(macOS)
        return LocalizedStringResource(
            "gateway.commands.handoff.outcome.mac",
            defaultValue: "conduck-connect ends with a setup code")
        #else
        return LocalizedStringResource(
            "gateway.commands.handoff.outcome",
            defaultValue: "conduck-connect ends with a QR code and a setup code")
        #endif
    }

    private var handoffAction: LocalizedStringResource {
        #if os(macOS)
        return LocalizedStringResource(
            "gateway.commands.handoff.action.mac",
            defaultValue: "Then paste it to finish.")
        #else
        // "Come back here" — the return cue for the user who ran the command from
        // a computer (the flow's heads-up step sent them there).
        return LocalizedStringResource(
            "gateway.commands.handoff.action.return",
            defaultValue: "Come back here and scan or paste it to finish.")
        #endif
    }
}

#Preview("Full agent lane") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayCommandsView(onScanOrPaste: {})
    }
}

#Preview("Custom lane") {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayCommandsView(onScanOrPaste: {})
    }
}

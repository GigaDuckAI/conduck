// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConduckConnectCommandBlock.swift
//
// Shared "run conduck-connect on your server" block. ONE presentation from one
// command source (`conduckConnectSetupCommandShort`):
//   • HERO — a full-width terminal-pane card with the command
//     WRAPPED (never truncated) + an IN-CARD copy button (the guided Commands
//     step's focal action) + a "what it does" caption. Used by `GatewayCommandsView`.
//
// Copy always lifts the raw single-line command (`copyCommand`), so wrapping is
// display-only and never corrupts what lands on the clipboard. Built on GitHub's
// stable `releases/latest` URL so it never names a version.

import SwiftUI

struct ConduckConnectCommandBlock: View {
    /// The shell text this block renders + copies — the short `--setup`
    /// one-paste command (`-O` download-to-disk then `bash`, never a blind pipe).
    private var setupCommand: String {
        Constants.conduckConnectSetupCommandShort
    }

    /// Transient "Copied" confirmation on the Copy button.
    @State private var didCopy: Bool = false

    /// `true` when this block renders inside the onboarding scaffold on a
    /// regular surface (iPad/macOS) — bumps the shell-text padding a notch.
    @Environment(\.onboardingRegularSurface) private var regularSurface

    var body: some View {
        heroForm
    }

    // MARK: - Guided Commands step

    private var heroForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroCard
            VStack(alignment: .leading, spacing: 6) {
                // "What it does" — restored from the old intro prose to here, where
                // it earns its place: a `curl … && bash` line is opaque, so naming
                // its two halves (download from Releases, then run) is trust-relevant
                // at the exact moment the user reads the raw command.
                Text(LocalizedStringResource(
                    "gateway.setupCommand.heroCaption",
                    defaultValue: "Downloads conduck-connect.sh from GitHub Releases, then runs it."
                ))
                .onboardingScaledFont(.footnote)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                gitHubLink
            }
        }
    }

    /// Terminal-pane card: a header row (terminal glyph + the IN-CARD copy button,
    /// the screen's focal action) over the WRAPPED, full command.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                heroCopyButton
            }
            Text(verbatim: setupCommand)
                .onboardingScaledFont(.subheadline, design: .monospaced)
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(regularSurface ? 16 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
        )
    }

    private var heroCopyButton: some View {
        Button {
            copyCommand()
        } label: {
            Label(
                didCopy
                    ? LocalizedStringResource("gateway.setupCommand.copied", defaultValue: "Copied")
                    : LocalizedStringResource("gateway.setupCommand.copyShort", defaultValue: "Copy"),
                systemImage: didCopy ? "checkmark" : "doc.on.doc"
            )
            .onboardingScaledFont(.subheadline, weight: .semibold)
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.remoteAgent.copyConnectCommand")
    }

    // MARK: - Shared GitHub link

    /// Audit affordance — points at the exact downloaded artifact's Releases page.
    /// Worded as an invitation ("View …"), not an instruction ("Read it first").
    private var gitHubLink: some View {
        Link(destination: Constants.conduckConnectReleasesURL) {
            HStack(spacing: 4) {
                Text(LocalizedStringResource(
                    "gateway.setupCommand.viewGitHub",
                    defaultValue: "View the script on GitHub"
                ))
                Image(systemName: "arrow.up.right")
                    .font(.caption)
            }
            .onboardingScaledFont(.subheadline, weight: .semibold)
            .foregroundStyle(.tint)
        }
    }

    /// Copy to the system clipboard through the shared helper — the setup command
    /// is NON-secret (a public download-and-run line, no token), so the plain
    /// unbounded `Pasteboard.copy` is correct here. Secrets take
    /// `Pasteboard.copySensitive` instead; routing both through `Pasteboard`
    /// keeps that choice visible at the call site rather than hidden in a
    /// per-file `#if` duplicate.
    private func copyCommand() {
        Pasteboard.copy(setupCommand)
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { withAnimation { didCopy = false } }
        }
    }
}

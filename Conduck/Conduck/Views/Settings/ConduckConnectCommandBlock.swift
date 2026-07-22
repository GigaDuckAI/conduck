// Conduck
// ConduckConnectCommandBlock.swift
//
// Shared "run conduck-connect on your server" block. TWO presentations off one
// command source (`conduckConnectSetupCommandShort(generic:)`, lane-aware via
// `generic`):
//   • COMPACT (default) — a horizontally-scrolling one-line strip + a below-card
//     Copy button + the GitHub link. Used by the per-gateway editor's quick-connect
//     disclosure (`GatewayGuidedConnectContent`); unchanged.
//   • HERO (`hero: true`) — a full-width terminal-pane card with the command
//     WRAPPED (never truncated) + an IN-CARD copy button (the guided Commands
//     step's focal action) + a "what it does" caption. Used by `GatewayCommandsView`.
//
// Copy always lifts the raw single-line command (`copyCommand`), so wrapping is
// display-only and never corrupts what lands on the clipboard. Built on GitHub's
// stable `releases/latest` URL so it never names a version.

import SwiftUI

struct ConduckConnectCommandBlock: View {
    /// Render + copy the generic lane's command (`conduck-connect.sh --generic`)
    /// instead of the auto-detecting form. Defaults `false`.
    var generic: Bool = false

    /// Hero presentation for the guided "Commands" wizard step: a wrapped,
    /// full-width terminal-pane card with an IN-CARD copy button (the screen's
    /// focal action) + a "what it does" caption. Default `false` keeps the COMPACT
    /// form (horizontal-scroll strip + below-card copy) the per-gateway editor's
    /// quick-connect disclosure renders — that caller is unchanged.
    var hero: Bool = false

    /// The shell text this block renders + copies — the short lane-aware one-paste
    /// command (`-O` download-to-disk then `bash`, never a blind pipe).
    private var setupCommand: String {
        Constants.conduckConnectSetupCommandShort(generic: generic)
    }

    /// Transient "Copied" confirmation on the Copy button.
    @State private var didCopy: Bool = false

    /// `true` when this block renders inside the onboarding scaffold on a
    /// regular surface (iPad/macOS) — bumps the shell-text padding a notch.
    /// `false` elsewhere (iPhone, and the per-gateway editor hint outside the
    /// scaffold), so those callers render unchanged.
    @Environment(\.onboardingRegularSurface) private var regularSurface

    var body: some View {
        if hero { heroForm } else { compactForm }
    }

    // MARK: - Compact form (per-gateway editor disclosure) — unchanged

    private var compactForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            compactCommandBlock
            compactCopyButton
            gitHubLink
                .padding(.top, 2)
        }
    }

    /// Shell text — `verbatim`, never localized, selectable, horizontally scrollable.
    private var compactCommandBlock: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(verbatim: setupCommand)
                .onboardingScaledFont(.caption, design: .monospaced)
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(regularSurface ? 12 : 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
        )
    }

    private var compactCopyButton: some View {
        Button {
            copyCommand()
        } label: {
            ZStack(alignment: .leading) {
                // Invisible widest-state sizer: reserves a stable width so the
                // button doesn't shrink when "Copy command" → "Copied".
                Label(
                    LocalizedStringResource("gateway.setupCommand.copy", defaultValue: "Copy command"),
                    systemImage: "doc.on.doc"
                )
                .hidden()

                Label(
                    didCopy
                        ? LocalizedStringResource("gateway.setupCommand.copied", defaultValue: "Copied")
                        : LocalizedStringResource("gateway.setupCommand.copy", defaultValue: "Copy command"),
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
            }
            .onboardingScaledFont(.subheadline, weight: .semibold)
            .labelStyle(AccentGlyphActionLabelStyle())
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.remoteAgent.copyConnectCommand")
    }

    // MARK: - Hero form (guided Commands step)

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
    /// the screen's focal action) over the WRAPPED, full command. Bigger corner +
    /// padding than the compact strip so it reads as the screen's centerpiece.
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

    /// Copy to the system clipboard. Same cross-platform split the rest of the
    /// app uses (`FileTransferSetupGuideView.writeToPasteboard`, `ConversationDetailViewModel.copy`).
    private func copyCommand() {
        let command = setupCommand
        #if canImport(UIKit)
        UIPasteboard.general.string = command
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        #endif
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { withAnimation { didCopy = false } }
        }
    }
}

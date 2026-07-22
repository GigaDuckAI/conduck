// Conduck
// GatewayCredentialHelpSheet.swift
//
// The PROVENANCE answer for a user configuring a self-hosted gateway BY HAND:
// where, on the server they run, the URL and the token actually come from. This is
// the #1 thing a manual user is stuck on — the guided lane never asks, because
// `conduck-connect` reads these same files itself and prints a setup code.
//
// Rendered ENTIRELY from `GatewayCredentialSource` (config path · token key ·
// default port · health route · caveats) — never from an `if backend == .openclaw`
// branch. A future self-hosted backend gets a help sheet by filling in one
// descriptor field. The descriptor deliberately carries only STABLE facts; the
// version-fragile material (compose invocations, unit names) stays behind the
// setup-guide link.
//
// The caveats are the sharp edge: each is a lane-specific trap that produces a
// PLAUSIBLE-looking-but-wrong credential (OpenClaw's Docker `.env` token is only a
// setup seed and drifts from the value the gateway checks). They get the amber
// treatment because a user who hits one is otherwise stranded with a token that
// looks right and fails auth.

import SwiftUI

struct GatewayCredentialHelpSheet: View {
    /// The lane names itself where naming it MEANS something — inside `source.tokenBody`
    /// ("OpenClaw generated a token for you…" / "Hermes does not generate a token…"),
    /// written out per descriptor. The shared sentences take no name: interpolating one
    /// into a `LocalizedStringResource` here is what produced a sheet that printed the
    /// literal text `\(displayName)` (the catalog stored the Swift source instead of a
    /// `%@` placeholder, and the catalog value always beats `defaultValue:`).
    let source: GatewayCredentialSource

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro
                    tokenCard
                    addressCard
                    ForEach(Array(source.caveats.enumerated()), id: \.offset) { _, caveat in
                        caveatCallout(caveat)
                    }
                    troubleshootingLink
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(LocalizedStringResource(
                "settings.remoteAgent.credentialHelp.title",
                defaultValue: "Where do I find these?"
            )))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource(
                        "settings.remoteAgent.credentialHelp.done",
                        defaultValue: "Done"
                    )) {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        Text(LocalizedStringResource(
            "settings.remoteAgent.credentialHelp.intro",
            defaultValue: "Both values belong to the server you run. You're looking for them on that machine, not on this device."
        ))
        .font(.subheadline)
        .foregroundStyle(AppColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The token: which file, which key inside it — and, from the descriptor, whether the
    /// user is HUNTING for a value the gateway already made or SETTING one it never will.
    /// A shared "copy the value stored under this key" is only true of the first kind.
    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(
                systemImage: "key",
                title: LocalizedStringResource(
                    "settings.remoteAgent.credentialHelp.token.header",
                    defaultValue: "The bearer token"
                )
            )
            Text(source.tokenBody)
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            codeLine(source.configPath)
            labelledCodeLine(
                label: LocalizedStringResource(
                    "settings.remoteAgent.credentialHelp.token.keyLabel",
                    defaultValue: "Key"
                ),
                code: source.tokenKey
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCardBackground()
    }

    /// The address: the port it listens on + a liveness route. What that route
    /// PROVES is per-lane (`source.healthBody`): OpenClaw's `/healthz` answers even
    /// with the AI endpoint off, but Hermes's `/v1/health` is gated by the same
    /// switch as the API server, so a non-answer means the API server is off.
    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(
                systemImage: "network",
                title: LocalizedStringResource(
                    "settings.remoteAgent.credentialHelp.address.header",
                    defaultValue: "The gateway URL"
                )
            )
            Text(LocalizedStringResource(
                "settings.remoteAgent.credentialHelp.address.body",
                defaultValue: "It's the https address of that same server. Unless you changed it, the port is:"
            ))
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            codeLine(String(source.defaultPort))

            Text(source.healthBody)
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            codeLine(source.healthPath)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCardBackground()
    }

    /// A lane-specific trap. Amber (not red): nothing is broken yet — this is the
    /// mistake the user is ABOUT to make.
    private func caveatCallout(_ caveat: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(AppColors.brandAmber)
                .accessibilityHidden(true)
            Text(caveat)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.brandAmber.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.brandAmber.opacity(0.25), lineWidth: 1)
        )
    }

    /// The website's troubleshooting section — the deeper, freely-updatable layer
    /// this sheet deliberately doesn't try to duplicate.
    @ViewBuilder
    private var troubleshootingLink: some View {
        if let url = URL(string: Constants.setupGuideURL + "#troubleshooting") {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Text(LocalizedStringResource(
                        "settings.remoteAgent.credentialHelp.troubleshooting",
                        defaultValue: "Still won't connect? Read the setup guide"
                    ))
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - Row primitives

    private func cardHeader(systemImage: String, title: LocalizedStringResource) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
    }

    /// Verbatim, selectable, monospaced — the same treatment `ConduckConnectCommandBlock`
    /// gives shell text. Horizontally scrollable so a long path is never truncated
    /// into a value the user might mistype.
    private func codeLine(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
        )
    }

    private func labelledCodeLine(label: LocalizedStringResource, code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppColors.textTertiary)
            codeLine(code)
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomGatewayHelpSheet.swift
//
// The custom lane's answer to the self-hosted lanes' credential-help sheet —
// with a deliberately DIFFERENT promise. OpenClaw/Hermes can say "where do I
// FIND these" because their `GatewayCredentialSource` knows the config file and
// token key by name; an arbitrary server has no such descriptor, and a button
// that promises discovery then answers "consult your server's docs" would teach
// the reader that help affordances here sometimes say nothing — a tax on the
// sheets that DO deliver. So this sheet promises EXPLANATION ("what do I
// enter") and keeps it with first-party facts only: Conduck's own URL contract,
// where auth can live in general, and the adapter path for an AI that isn't a
// server yet.
//
// The split is by the user's CURRENT CAPABILITY (already have an
// OpenAI-compatible API vs not a server yet), not by which framework they
// picked: the correct answer is the same across LiteLLM/Ollama/vLLM/…, and
// per-framework facts (master-key flags, default auth) drift with third-party
// releases — stale "help" is worse than none. Framework names appear as
// recognition examples only; Test Connection stays the authority.
//
// The adapter card shares `GatewayAdapterBriefView.clipboardBrief` (and the
// same build-guide + contract URLs) rather than carrying its own copy of the
// brief — two briefs would drift. It deliberately does NOT embed that view itself: it
// belongs to the guided flow's state machine ("My adapter is running —
// continue"), the wrong navigation contract inside an editor sheet.

import SwiftUI

struct CustomGatewayHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Transient "Copied" confirmation on the copy button (same pattern as
    /// `GatewayAdapterBriefView` / `ConduckConnectCommandBlock`).
    @State private var didCopy: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro
                    apiServerCard
                    adapterCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(LocalizedStringResource(
                "settings.remoteAgent.customHelp.title",
                defaultValue: "What do I enter?"
            )))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource(
                        "settings.remoteAgent.customHelp.done",
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
            "settings.remoteAgent.customHelp.intro",
            defaultValue: "Both values describe your own server. Pick the situation that matches yours."
        ))
        .font(.subheadline)
        .foregroundStyle(AppColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Path 1: an OpenAI-compatible API already exists (a framework OR a
    /// finished adapter — same answer either way). Only Conduck-owned facts:
    /// reachable-from-this-device, base address, where a password CAN live.
    /// The local-port trap is part of the URL story, told where the URL is
    /// explained — not a stray warning at the sheet's end.
    private var apiServerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(
                systemImage: "server.rack",
                title: LocalizedStringResource(
                    "settings.remoteAgent.customHelp.api.header",
                    defaultValue: "I already run an OpenAI-compatible server"
                )
            )
            Text(LocalizedStringResource(
                "settings.remoteAgent.customHelp.api.examples",
                defaultValue: "LiteLLM, Ollama, vLLM, LM Studio — or an adapter you built."
            ))
            .font(.footnote)
            .foregroundStyle(AppColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            subLabel(LocalizedStringResource(
                "settings.remoteAgent.customHelp.api.url.label",
                defaultValue: "Gateway URL"
            ))
            bodyText(LocalizedStringResource(
                "settings.remoteAgent.customHelp.api.url.body",
                defaultValue: "The https:// address your server is reachable at from this device — a Tailscale name, a domain, or a LAN address. Paste just the base address; Conduck adds /v1/… itself."
            ))
            codeLine("https://my-server.tail1234.ts.net:8000")
            // The second sentence is the difference between a working setup and
            // a 403 nobody can read: a server that checks the `Host` header
            // refuses every request a tunnel forwards unchanged, and the failure
            // surfaces as an auth-shaped error with no credential in sight.
            // Ollama is the example, not the subject, per this sheet's
            // framework-names-are-examples-only rule.
            //
            // "May need", not "must" — the check is CONDITIONAL, and a flat
            // imperative would send an operator hunting for a knob their front
            // does not have. Ollama runs it only while bound to a loopback
            // address (publishing on a non-loopback bind skips it outright) and
            // accepts a `Host` that is a local IP or ends in `.local` /
            // `.internal`; meanwhile Tailscale Serve — the very transport this
            // card's example URL shows — forwards the inbound `Host` unchanged
            // and offers no rewrite. Name the constraint, not a cure: which cure
            // applies is a per-framework fact, and those drift.
            //
            // `.v2` because the catalog value wins over `defaultValue:`, so
            // extending the existing key would ship the shorter string.
            bodyText(LocalizedStringResource(
                "settings.remoteAgent.customHelp.api.url.portNote.v2",
                defaultValue: "A framework's own port (Ollama's 11434, for example) is usually a private, http-only door on the machine itself — Conduck needs the https address that door is published at. Some servers, Ollama among them, also check the Host header — the name a request says it is addressed to — and refuse anything still carrying the public name, so whatever publishes it may need to rewrite that to the local one."
            ))

            subLabel(LocalizedStringResource(
                "settings.remoteAgent.customHelp.api.token.label",
                defaultValue: "Bearer token"
            ))
            bodyText(LocalizedStringResource(
                "settings.remoteAgent.customHelp.api.token.body",
                defaultValue: "Whatever password that address checks before answering — set in your framework's config, or by a proxy in front of it. If your server deliberately has no password on a private network, turn off “Requires a bearer token” instead."
            ))

            Text(LocalizedStringResource(
                "settings.remoteAgent.customHelp.api.test",
                defaultValue: "Test Connection checks that Conduck can reach this address, authenticate, and read its model list. To exercise the chat wire too, download the script on that machine with \(Constants.conduckConnectDownloadCommand) and run bash conduck-connect.sh --check-server. After a PASS, the interactive script can continue into setup."
            ))
            .font(.footnote)
            .foregroundStyle(AppColors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCardBackground()
    }

    /// Path 2: the user's AI is not an HTTP server yet → the adapter story.
    /// Same brief, build-guide URL, and contract URL as the guided flow's escape
    /// hatch. The copy CTA gets its own row; the two site links stack vertically
    /// below it — a third item in a horizontal row compresses on compact iPhones.
    private var adapterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(
                systemImage: "laptopcomputer",
                title: LocalizedStringResource(
                    "settings.remoteAgent.customHelp.adapter.header",
                    defaultValue: "My AI isn't a server yet"
                )
            )
            bodyText(LocalizedStringResource(
                "settings.remoteAgent.customHelp.adapter.body",
                defaultValue: "If you built your own AI and it can't answer web requests yet, it needs a small front door — an adapter — that Conduck can knock on. The AI coding tool you built it with can write that adapter for you: copy the instructions and paste them into that tool."
            ))

            Button(action: copyBrief) {
                Label(
                    didCopy
                        ? LocalizedStringResource("gateway.setupCommand.copied", defaultValue: "Copied")
                        : LocalizedStringResource(
                            "settings.remoteAgent.customHelp.adapter.copy",
                            defaultValue: "Copy adapter instructions"
                        ),
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("settings.remoteAgent.customHelp.copyBrief")
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                docLink(
                    LocalizedStringResource(
                        "settings.remoteAgent.customHelp.adapter.guide",
                        defaultValue: "See how it works"
                    ),
                    urlString: Constants.adapterBuildGuideURL
                )
                docLink(
                    LocalizedStringResource(
                        "settings.remoteAgent.customHelp.adapter.contract",
                        defaultValue: "Read the adapter contract"
                    ),
                    urlString: Constants.adapterContractURL
                )
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCardBackground()
    }

    /// One outbound documentation link (title + external-arrow glyph), shared by
    /// the adapter card's build-guide and contract rows.
    private func docLink(_ title: LocalizedStringResource, urlString: String) -> some View {
        Group {
            if let url = URL(string: urlString) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(title)
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                }
                .pointerLink()
            }
        }
    }

    // MARK: - Row primitives (mirror `GatewayCredentialHelpSheet`)

    private func cardHeader(systemImage: String, title: LocalizedStringResource) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .labelStyle(AccentGlyphActionLabelStyle())
    }

    private func subLabel(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppColors.textPrimary)
            .padding(.top, 4)
    }

    private func bodyText(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Verbatim, monospaced example — the same treatment
    /// `GatewayCredentialHelpSheet.codeLine` gives literal values.
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

    // MARK: - Clipboard

    /// Copy the SHARED adapter brief (single source: `GatewayAdapterBriefView`)
    /// with the same 2-second "Copied" confirmation as its other call sites.
    private func copyBrief() {
        let text = GatewayAdapterBriefView.clipboardBrief
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { withAnimation { didCopy = false } }
        }
    }
}

#Preview {
    CustomGatewayHelpSheet()
}

// Conduck
// GatewayGuidedConnectContent.swift
//
// Chrome-neutral "Guided setup" body for the per-gateway editor
// (`RemoteAgentConfigBody`). It is the EXPANDED content of the collapsed
// "Guided setup" disclosure that sits at the TOP of every SELF-HOSTED gateway
// detail (OpenClaw / Hermes / custom) — collapsed by default so a pro who types
// the connection fields by hand never sees it.
//
// Self-hosted only (the gateway is already known). A top one-line explainer
// (names conduck-connect as "our setup helper script") then a single linear
// two-step flow: STEP 1 — set up the server with the conduck-connect one-paste
// command (shared `ConduckConnectCommandBlock`); STEP 2 — bring the printed code
// back via the single compact scan/paste CTA. There is exactly ONE scan/paste
// entry point (the step-2 button) — no duplicate top "fast path"
// link. Hosted-model built-ins (OpenRouter) have NO guided setup here — there is
// no server to run and no pairing; their "get an API key" link lives in the
// editor's Connection footer (`RemoteAgentConfigBody.connectionFooterView`).
//
// Emits a PLAIN `VStack` (no Section / card chrome) so the host applies its own
// background — the editor wraps it in a Form `Section`/`DisclosureGroup`. The
// scan/paste action is owned by the host (it raises the locked-target
// `PairingImportSheet`) and passed in as `onScanOrPaste`; the privacy-bearing
// setup code is handled entirely inside that sheet, never here.

import SwiftUI

struct GatewayGuidedConnectContent: View {
    /// Render + copy the generic lane's command (`conduck-connect --generic`)
    /// and the matching "checks your server" blurb, instead of the auto-detecting
    /// full-agent form. Custom refs pass `true`; OpenClaw/Hermes pass `false`.
    /// Mirrors `ConduckConnectCommandBlock(generic:)` / `GatewayCommandsView`.
    var generic: Bool = false

    /// Raise the host's locked-target pairing-import sheet to bring a printed
    /// `conduck-connect` setup code back.
    let onScanOrPaste: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Top explainer — names the tool ("our setup helper script") and the
            // two-step round trip in one line, above the numbered steps.
            Text(LocalizedStringResource(
                "settings.remoteAgent.guided.intro",
                defaultValue: "conduck-connect is our setup helper script. Run it on your server, then bring back the setup code it prints."
            ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // STEP 1 — set up the always-on server. The shared block owns the
            // one-paste command + Copy + GitHub link.
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.guided.step1.title",
                    defaultValue: "1. Set up your server"
                ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                // Lane-aware: the generic (custom) lane's command only CHECKS an
                // existing OpenAI-compatible server (it can't turn on an endpoint it
                // doesn't own), while the full-agent lane turns the chat endpoint on.
                Text(generic
                    ? LocalizedStringResource(
                        "settings.remoteAgent.guided.noCode.body.generic",
                        defaultValue: "It checks your server, exposes it over HTTPS, and optionally sets up file transfer."
                    )
                    : LocalizedStringResource(
                        "settings.remoteAgent.guided.noCode.body",
                        defaultValue: "It turns on the chat endpoint, exposes it over HTTPS, and optionally sets up file transfer."
                    ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ConduckConnectCommandBlock(generic: generic)
                    .padding(.top, 2)
            }

            // STEP 2 — bring the printed code back. ONE entry point: a compact
            // `.bordered` button (matches the editor's Test Connection form),
            // tinted neutral gray (icon + text) to match the Copy command button
            // and render the same on iOS and macOS. Platform-gated wording: the
            // Mac pastes the printed code, it can't scan the QR with itself.
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringResource(
                    "settings.remoteAgent.guided.step2.title",
                    defaultValue: "2. Bring the code back"
                ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)

                HStack {
                    Button(action: onScanOrPaste) {
                        #if os(iOS)
                        Label(
                            LocalizedStringResource("settings.pairing.entry.scanOrPaste", defaultValue: "Scan or paste setup code"),
                            systemImage: "qrcode.viewfinder"
                        )
                        .font(.subheadline.weight(.semibold))
                        // Shared standard treatment: blue glyph + neutral text on a
                        // grey bordered pill (matches Copy command / Test Connection).
                        .labelStyle(AccentGlyphActionLabelStyle())
                        #else
                        Label(
                            LocalizedStringResource("settings.pairing.entry.paste", defaultValue: "Paste setup code"),
                            systemImage: "doc.on.clipboard"
                        )
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(AccentGlyphActionLabelStyle())
                        #endif
                    }
                    // Same plain utility form as the Copy command button — grey
                    // bordered pill with the shared blue-glyph label style.
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.remoteAgent.pairingImport")
                    Spacer()
                }
                .padding(.top, 2)

                // macOS is paste-only (no camera) — point Mac users at their phone
                // or iPad to scan the QR that conduck-connect prints instead.
                #if os(macOS)
                Text(LocalizedStringResource(
                    "settings.remoteAgent.guided.macScanHint",
                    defaultValue: "Or open Conduck on your iPhone or iPad and scan the QR code there."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
        }
        // Top breathing room so the intro doesn't crowd the "Quick connect"
        // disclosure label above it — matches the File-transfer expanded body.
        .padding(.top, 14)
        .padding(.bottom, 2)
    }
}

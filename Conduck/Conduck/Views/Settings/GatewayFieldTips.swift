// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayFieldTips.swift
//
// Single source of truth for every `InfoTipButton`'s popover copy — the gateway
// editor's field tips, the file-transfer rows, and the guided flow's one
// concept tip. Mirrors `GatewayGroupCopy`: a pure `enum` of constants, shared
// iOS + macOS, so the two shells can't drift and a copy change lands in one
// place.
//
// Register: plain, warm, concrete. A tip says what the thing IS and what Conduck
// does with it — never restates the label, never leads with jargon, never assumes
// the reader has run a server before. Where a row is a security decision (the
// token, the pin) the tip says where the value lives and what leaves the device.

import SwiftUI

enum GatewayFieldTips {

    /// Gateway URL — the address of the server the user runs.
    static let url = GatewayFieldTip(
        symbol: "link",
        accessibilityLabel: LocalizedStringResource(
            "settings.remoteAgent.tip.url.a11y",
            defaultValue: "About Gateway URL"
        ),
        title: LocalizedStringResource(
            "settings.remoteAgent.tip.url.title",
            defaultValue: "Gateway URL"
        ),
        message: LocalizedStringResource(
            "settings.remoteAgent.tip.url.message",
            defaultValue: "The web address of the server you run — the machine your AI actually lives on. Conduck sends your messages there and nowhere else. It must start with https, and it must be reachable from this device: a Tailscale address works anywhere this device runs Tailscale; a home-network address only at home."
        )
    )

    /// Bearer token — the self-hosted lanes' password. ONE tip for all three of them
    /// (OpenClaw · Hermes · custom), so it may only assert what is true of all three:
    /// what the value IS and what Conduck does with it.
    ///
    /// It deliberately says NOTHING about where the user's own token came from —
    /// that answer is lane-specific (OpenClaw generates one at install; Hermes and a
    /// custom server expect one the user invents), and a tip that generalizes it is
    /// wrong on two lanes out of three. PROVENANCE is `GatewayCredentialHelpSheet`'s
    /// whole job, answered per lane from `GatewayCredentialSource`. Nor does this
    /// point at that sheet's button: the button is visible in the same section and
    /// says what it does, and a custom gateway has no button to point at.
    static let bearerToken = GatewayFieldTip(
        symbol: "key.fill",
        accessibilityLabel: LocalizedStringResource(
            "settings.remoteAgent.tip.bearerToken.a11y",
            defaultValue: "About Bearer token"
        ),
        title: LocalizedStringResource(
            "settings.remoteAgent.tip.bearerToken.title",
            defaultValue: "Bearer token"
        ),
        message: LocalizedStringResource(
            "settings.remoteAgent.tip.bearerToken.message",
            defaultValue: "A password your gateway checks before it will answer, so only your devices can reach your AI. Conduck keeps it in the Keychain and sends it to your gateway and nowhere else."
        )
    )

    /// API key — the hosted lane (OpenRouter): a vendor-issued credential.
    static let apiKey = GatewayFieldTip(
        symbol: "key.horizontal.fill",
        accessibilityLabel: LocalizedStringResource(
            "settings.remoteAgent.tip.apiKey.a11y",
            defaultValue: "About API key"
        ),
        title: LocalizedStringResource(
            "settings.remoteAgent.tip.apiKey.title",
            defaultValue: "API key"
        ),
        message: LocalizedStringResource(
            "settings.remoteAgent.tip.apiKey.message",
            defaultValue: "The key from your OpenRouter account — it identifies you and it's what gets billed. Conduck keeps it in the Keychain and sends it only to OpenRouter. Create one on the OpenRouter site, then paste it here."
        )
    )

    /// The bearer/keyless toggle — the one row where turning something OFF has a
    /// security consequence, so the tip names it.
    static let requiresToken = GatewayFieldTip(
        symbol: "lock.open.fill",
        accessibilityLabel: LocalizedStringResource(
            "settings.remoteAgent.tip.requiresToken.a11y",
            defaultValue: "About Requires a bearer token"
        ),
        title: LocalizedStringResource(
            "settings.remoteAgent.tip.requiresToken.title",
            defaultValue: "Requires a bearer token"
        ),
        message: LocalizedStringResource(
            "settings.remoteAgent.tip.requiresToken.message",
            defaultValue: "Leave this on unless your gateway is deliberately set up without a password. Off means Conduck sends no password at all — anyone who can reach the address can use your AI. That's only safe on a private network like Tailscale or your own LAN."
        )
    )

    /// Default for new chats — the one tip that annotates a SECTION rather than a
    /// field, because the thing needing explanation is the relationship between
    /// this setting and the sticky last-used gateway, not the row's value.
    ///
    /// Deliberately does NOT claim the setting drives Apple Watch, CarPlay or the
    /// share sheet: the Watch Ask flow and CarPlay both have their own choosers,
    /// and the share sheet pre-selects the first configured gateway rather than
    /// this one. Naming only the Action Button and Shortcuts keeps it true.
    static let defaultForNewChats = GatewayFieldTip(
        symbol: "clock.arrow.circlepath",
        accessibilityLabel: LocalizedStringResource(
            "settings.personalAI.tip.newChats.a11y",
            defaultValue: "About New chats use"
        ),
        title: LocalizedStringResource(
            "settings.personalAI.tip.newChats.title",
            defaultValue: "Where new chats start"
        ),
        message: LocalizedStringResource(
            "settings.personalAI.tip.newChats.message",
            defaultValue: "A new chat on this device continues on the gateway you last used, so you don’t have to pick it again each time. This setting is where the first one starts, and where the Action Button and Shortcuts send when nothing asked you to choose."
        )
    )

    /// Model — which brain answers. Self-hosted lanes never see this row.
    static let model = GatewayFieldTip(
        symbol: "cpu",
        accessibilityLabel: LocalizedStringResource(
            "settings.remoteAgent.tip.model.a11y",
            defaultValue: "About Model"
        ),
        title: LocalizedStringResource(
            "settings.remoteAgent.tip.model.title",
            defaultValue: "Model"
        ),
        message: LocalizedStringResource(
            "settings.remoteAgent.tip.model.message.v2",
            defaultValue: "Which AI answers you — the exact name your gateway or provider knows it by, such as “llama3”. Test Connection fills in the choices it can see."
        )
    )

    /// Image history — a cost/latency lever, so the tip is framed in money and speed.
    static let imageHistory = GatewayFieldTip(
        symbol: "photo.stack",
        accessibilityLabel: LocalizedStringResource(
            "settings.remoteAgent.tip.imageHistory.a11y",
            defaultValue: "About Image history"
        ),
        title: LocalizedStringResource(
            "settings.remoteAgent.tip.imageHistory.title",
            defaultValue: "Image history"
        ),
        message: LocalizedStringResource(
            "settings.remoteAgent.tip.imageHistory.message",
            defaultValue: "How many of the pictures you've already sent get re-sent with each new message, so the AI can still see them. More images means it remembers more, but every turn gets slower and costs more. Older pictures beyond the limit are still referred to by name."
        )
    )

    // MARK: - File transfer
    //
    // The two rows in `FileTransferSetupContent`. Keys carry the `fileTransfer.`
    // prefix, not `settings.remoteAgent.` — that section localizes everything under
    // it (and the tips live here only so all field-tip copy has ONE home).

    /// Server password — the credential Conduck mints for the file server. The helper
    /// sentence under the field says HOW to hand it over; the tip says what it IS,
    /// where it lives, and what leaves the device (the register this file sets for
    /// any security value).
    static let fileServerPassword = GatewayFieldTip(
        symbol: "key.horizontal.fill",
        accessibilityLabel: LocalizedStringResource(
            "fileTransfer.tip.credential.a11y",
            defaultValue: "About Server password"
        ),
        title: LocalizedStringResource(
            "fileTransfer.tip.credential.title",
            defaultValue: "Server password"
        ),
        message: LocalizedStringResource(
            "fileTransfer.tip.credential.message",
            defaultValue: "A password Conduck invents for your file server, so only your devices can put files on it — not anyone who happens to find the address. Conduck signs in as “conduck” with this password, keeps it in the Keychain, and sends it to your file server and nowhere else. Your server has to be told the same password, or it turns the upload away."
        )
    )

    /// File-server URL — the CONCEPT gap, not the format gap. The footer already says
    /// what to paste; the question a first-time reader actually has is why a second
    /// server exists at all.
    static let fileServerURL = GatewayFieldTip(
        symbol: "externaldrive.fill",
        accessibilityLabel: LocalizedStringResource(
            "fileTransfer.tip.url.a11y",
            defaultValue: "About File-server URL"
        ),
        title: LocalizedStringResource(
            "fileTransfer.tip.url.title",
            defaultValue: "File-server URL"
        ),
        message: LocalizedStringResource(
            "fileTransfer.tip.url.message",
            defaultValue: "Your gateway carries the conversation, but it has nowhere to put a file. So files go to a second small service you run alongside it — a file server — and your agent picks them up from there. This is that service's address, which is why it's a different address and port from the gateway's. Conduck uploads straight to it; the file passes through no one else."
        )
    )

    // MARK: - Guided setup
    //
    // The custom lane's readiness step. Not an editor field — the one place in the
    // guided flow where a word the screen can't avoid ("server") needs a definition,
    // and the tip is what keeps that definition OFF the screen: the step sorts two
    // answers, and a paragraph explaining the premise pushes them under the fold.
    // Keys carry the `gatewaySetup.readiness.` prefix of the step that shows it; it
    // lives here so all tip copy has ONE home.

    /// What "a server" means, for someone who has never run one. Says the two
    /// requirements the app actually enforces — the OpenAI-compatible chat API, and
    /// https — but pairs each with the reason it isn't a wall: the API is what AI
    /// servers already speak, and the setup step can supply the https.
    ///
    /// Deliberately names no products: the answer cards below it carry Ollama and
    /// LM Studio, at the point the choice is made. The tip owns the RULE, the cards
    /// own the EXAMPLES.
    static let runningAsServer = GatewayFieldTip(
        symbol: "server.rack",
        accessibilityLabel: LocalizedStringResource(
            "gatewaySetup.readiness.tip.server.a11y",
            defaultValue: "About running as a server"
        ),
        title: LocalizedStringResource(
            "gatewaySetup.readiness.tip.server.title",
            defaultValue: "Running as a server"
        ),
        message: LocalizedStringResource(
            "gatewaySetup.readiness.tip.server.message",
            defaultValue: "A program that stays on and answers requests at a web address — not something you start, use, and close when you're done. It has to speak the OpenAI-compatible chat API, which is what most AI servers already use. Conduck only connects over https, and the setup step can put that in front of your server for you."
        )
    )

    // MARK: - Shared

    /// Server certificate — ONE tip for both trust rows (gateway Connection +
    /// file server), so it only says what is true of both: what the row decides
    /// and what each value means. The jargon (fingerprint, SPKI) stays
    /// quarantined in `CertificateTrustSheet`.
    static let serverCertificate = GatewayFieldTip(
        symbol: "checkmark.shield",
        accessibilityLabel: LocalizedStringResource(
            "settings.remoteAgent.tip.serverCertificate.a11y",
            defaultValue: "About Server certificate"
        ),
        title: LocalizedStringResource(
            "settings.remoteAgent.tip.serverCertificate.title",
            defaultValue: "Server certificate"
        ),
        message: LocalizedStringResource(
            "settings.remoteAgent.tip.serverCertificate.message.v2",
            defaultValue: "Every https server shows a certificate to prove who it is before Conduck sends anything. Automatic means your device already recognizes it — right for most setups. Conduck refuses a certificate your device doesn't recognize, so a server that made its own needs a real one instead. Pinning is an optional extra: open this row to name one exact certificate and nothing else is accepted."
        )
    )
}

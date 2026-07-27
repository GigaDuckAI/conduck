// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayAdapterBriefView.swift
//
// Guided-setup escape hatch reached ONLY from the custom lane's readiness step
// ("Is your server running?") — for the user who built their OWN AI (e.g. with
// an AI coding tool) and stalls there because that AI is not an HTTP server yet.
//
// The reset this screen delivers: you don't rebuild anything. Your AI stays as
// it is; it just needs a tiny OpenAI-compatible "front door" (an adapter) so
// Conduck can talk to it — and the AI coding tool you built yours with can write
// that adapter for you. The bordered copy action leads on every platform; a
// learn-more sentence links the human build guide and the contract page. (The
// "easier from a computer" expectation was already set once, by the guided
// flow's heads-up step — this screen carries no handoff card of its own.) The
// copied brief (`clipboardBrief`) delegates to the hosted build brief — narrowed
// to stop before exposure/pairing, which this flow owns — with a self-contained
// fallback for tools without web access; the full normative contract lives on
// the website (`Constants.adapterContractURL`). It hands over the executable
// adapter-CHECK commands (the AI's job) and never the pairing command (the
// user's job — prose names the step, no invocation). The footer is the screen's
// single filled CTA — the way forward once the adapter is up.
//
// Like every guided sub-step, the container (`GuidedGatewaySetupView`) paints the
// gradient + Back/Close chrome and owns routing; this view renders only the
// mascot / title / content and pins its footer via `.onboardingStepLayout`.
// `proceed` advances to the helper step (the container wires it to `.helper`);
// Back returns to the readiness step it escaped from.

import SwiftUI

struct GatewayAdapterBriefView: View {
    /// Advance to the helper step — the user's adapter is up and they're ready to
    /// run `conduck-connect` in front of it. The container wires this to `.helper`.
    let proceed: () -> Void

    /// Transient "Copied" confirmation on the copy-instructions button (same
    /// pattern as `ConduckConnectCommandBlock`).
    @State private var didCopy: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            // Character — the coder: your AI-coding tool writes the adapter.
            Image("conduck-laptop")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Title — same register + styling as the fork step's title.
            Text(LocalizedStringResource(
                "gatewaySetup.adapter.title",
                defaultValue: "Keep your AI. Add an adapter."
            ))
            .onboardingScaledFont(.title2, weight: .bold)
            .foregroundStyle(AppColors.textEmphasis)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 32)

            bodyCard

            copyButton

            // Inline learn-more — the human build guide + the durable normative
            // contract live on the site; the copied brief is the in-app ask. All
            // platforms: this is the screen's one quiet route to both URLs.
            Text(adapterContractSentence)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .tint(.blue)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
        }
        .onboardingStepLayout {
            footer
        }
    }

    // MARK: - Body card

    /// The mental-model reset: your AI is untouched; it just needs a small front
    /// door, and you don't build it by hand. Two paragraphs plus the one security
    /// instruction as a calm in-card lock row — the flow's single semantic use of
    /// amber, deliberately WITHOUT a filled/stroked hazard box (the old callout
    /// out-shouted the screen's actions and read scarier than the fact warrants).
    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringResource(
                "gatewaySetup.adapter.body1",
                defaultValue: "Your AI stays exactly as it is. It just needs a small front door — an adapter — that receives Conduck's messages, hands them to your AI, and sends the answer back."
            ))
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(LocalizedStringResource(
                "gatewaySetup.adapter.body2",
                defaultValue: "You don't have to build it yourself: copy the instructions below and paste them into the AI coding tool you built yours with. It will do the rest."
            ))
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            cautionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    /// The one instruction the user must carry: an adapter that runs a full agent
    /// turn can trigger that agent's tools, so keep it private + require a token.
    /// A quiet amber lock row inside the card — noticeable, not alarming.
    private var cautionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "lock.shield")
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.brandAmber)
                .frame(width: 22, alignment: .center)
                .accessibilityHidden(true)
            Text(LocalizedStringResource(
                "gatewaySetup.adapter.caution.row",
                defaultValue: "It can trigger your AI's tools — keep it private and require a token."
            ))
            .onboardingScaledFont(.footnote)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Copy-instructions action (bordered secondary, in-content)

    /// Bordered secondary (the primer's "Set up manually" chrome): copying the
    /// brief is this screen's in-content action, but the single filled CTA is the
    /// footer's way-forward — one blue per screen. The copy glyph carries the
    /// accent (`AccentGlyphActionLabelStyle`, the editor's "Test Connection"
    /// treatment: blue icon, neutral title) so the button reads as a copy action
    /// without becoming a second all-blue CTA. Leads the actions on every
    /// platform.
    private var copyButton: some View {
        Button(action: copyBrief) {
            Label {
                Text(didCopy
                    ? LocalizedStringResource("gateway.setupCommand.copied", defaultValue: "Copied")
                    : LocalizedStringResource("gatewaySetup.adapter.copy", defaultValue: "Copy instructions for my AI"))
            } icon: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .labelStyle(AccentGlyphActionLabelStyle())
            .onboardingScaledFont(.headline)
            .frame(maxWidth: Constants.Layout.buttonMaxWidth)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppColors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        // 32 — the CONTENT rail, matching the cards above. The footer's
        // `Layout.horizontalPadding` (16 on iOS) is the FOOTER's rail; using it
        // here made this button jut 16pt past the card on each side, the most
        // visible ragged edge in the flow.
        .padding(.horizontal, 32)
        .accessibilityIdentifier("guidedSetup.adapter.copy")
    }

    // MARK: - Pinned footer (single filled CTA)

    /// The way forward — the screen's ONE filled accent button, matching every
    /// other guided step's footer. The in-content copy action stays bordered.
    private var footer: some View {
        Button(action: proceed) {
            Text(LocalizedStringResource(
                "gatewaySetup.adapter.continue",
                defaultValue: "My adapter is running — continue"
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
        .accessibilityIdentifier("guidedSetup.adapter.continue")
    }

    // MARK: - Learn-more sentence (markdown links, mirrors readiness customLearnMore)

    /// "Want more context?" as a markdown `AttributedString` with two linked
    /// phrases — the human build guide (what the AI tool will do) first, then the
    /// full adapter contract. Plain text fallback if the markdown ever fails to
    /// parse. (Key renamed from `gatewaySetup.adapter.learnMore` — rewording an
    /// existing catalog key's `defaultValue:` never shows at runtime.)
    private var adapterContractSentence: AttributedString {
        let template = String(localized: LocalizedStringResource(
            "gatewaySetup.adapter.learnMoreLinks",
            defaultValue: "Want more context? [See how it works](%1$@), or [read the full adapter contract](%2$@)."
        ))
        let markdown = String(
            format: template,
            Constants.adapterBuildGuideURL,
            Constants.adapterContractURL
        )
        return (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString("Want more context? See conduck.com/setup/adapter/build.")
    }

    // MARK: - Clipboard

    /// Copy the brief to the system clipboard — same platform-gated pasteboard
    /// approach as `ConduckConnectCommandBlock.copyCommand`, with the same 2-second
    /// "Copied" confirmation.
    private func copyBrief() {
        let text = Self.clipboardBrief
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

    // MARK: - Clipboard brief (the ask pasted into an AI tool)

    /// The instructions the user copies into the AI coding tool that built their
    /// agent. Pointer-first: it delegates to the hosted build brief (single
    /// source, never stales on a contract revision) — deliberately NARROWED to
    /// stop before that brief's exposure/pairing steps, because this guided flow
    /// owns those via `conduck-connect` — with a self-contained fallback list for
    /// tools without web access, aligned to contract revision 1.3. The full
    /// contract is at `Constants.adapterContractURL`; both raw `.md` URLs are
    /// hardcoded inline below. `internal` so a content-lock test can read it via
    /// `@testable import`.
    ///
    /// **Workflow-ownership boundary — the load-bearing rule of this string.**
    /// This text is pasted into an AUTONOMOUS coding agent, so what it can act on
    /// is exactly what it is handed. It therefore carries the adapter-check
    /// invocations in COMPLETE runnable form (download, `CONDUCK_TOKEN`, explicit
    /// loopback URL — a bare `--check-adapter` blocks on an interactive URL/token
    /// prompt, which is fatal for a non-interactive agent) and carries NO pairing
    /// invocation at all: exposure and pairing are named in prose only. First-person
    /// phrasing ("I'll handle that") is intent, not a control; the actual control is
    /// that the command is absent. `GatewayAdapterBriefTests` locks both halves.
    static let clipboardBrief: String = """
    Build a "Conduck adapter v1" for my existing AI agent, so the Conduck app can talk to it.

    Best path — if you have web access, read and follow the build brief:
    https://conduck.com/setup/adapter/build.md
    This request deliberately narrows that workflow: do steps 1-9 only — through the build gate (the adapter check exits 0 against the real engine on loopback), then the supervisor install, then re-run both check profiles against the supervised adapter. Download the checker once, then run it with the port and bearer token you configured:
    curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh
    CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter http://127.0.0.1:8480
    CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter --deep http://127.0.0.1:8480
    In an interactive terminal, a PASS may ask whether to continue with setup; answer no during these build checks. STOP before step 10 (expose and pair): run the adapter check only — do NOT set up HTTPS, expose anything to a network, or pair a device. Exposure and pairing are not yours to run: I'll handle them myself through Conduck's guided setup afterwards. The full wire contract is https://conduck.com/setup/adapter/v1.md — record the document revision you build against.

    First, inspect my project — don't guess. If it ALREADY runs a long-lived HTTP server with the two routes below, tell me and skip the build.

    If you can't fetch those URLs, these core requirements are enough:
    1. Keep my agent exactly as it is. Add a separate, small HTTP service in front of it.
    2. GET /v1/models -> 200 with {"data":[{"id":"<agent-name>"}]} within 15 seconds, no cold starts on this route. Auth-protected like everything else.
    3. POST /v1/chat/completions (OpenAI chat format; the final messages element is always the current turn and always role "user"; the body carries the complete current message window on every request — it is bounded and may slide, so run each request as a fresh, self-contained conversation and never de-duplicate by message content; "content" may be a string or an array of text and image_url parts) -> run ONE complete agent turn — including any tools — and return 200 with {"choices":[{"message":{"role":"assistant","content":"<final answer text>"}}]}. Never return tool_calls; never stream — even if a request says "stream": true, answer with one synchronous JSON body (Conduck itself always sends "stream": false); never return an empty "content" string (error instead); finish within 285 seconds or cancel the work — terminating the whole child process tree — and return an error.
    4. Images: on the current turn (the final messages element), forward images if my agent accepts them, and never silently drop one — if my agent can't take images, reject with 400 and code "image_unsupported". For EARLIER messages, never reject a request because an earlier message contains an image — forward it, or replace it in-position with exactly this text: "An image was attached in this earlier message, but this adapter cannot inspect it. Do not infer its contents."
    5. Errors are {"error":{"message":"...","type":"...","code":"..."}} with a non-2xx status. Use these codes where they fit: image_unsupported, model_not_found (400 — a "model" value matching nothing you advertise), context_too_long, image_too_large, overloaded, upstream_timeout, upstream_failure. Be lenient otherwise: tolerate a present OR absent "model" field and ignore unknown extra fields (never reject on them). Always respond with Content-Type: application/json and STRICT standard JSON — never NaN or Infinity anywhere in the body (Python's json.dumps allows them by default; the app rejects the whole response).
    6. Require "Authorization: Bearer <token>" on every request, including /v1/models (long random token, stored outside the code), and check it before any other work. Bind to 127.0.0.1 only. Accept request bodies of at least 50 MiB — an image turn legitimately arrives that big.
    7. Safety: never pass chat text through a shell; tool approvals fail closed (no auto-approve-everything); never log message content or tokens.

    If you can reach GitHub but not conduck.com, you can still run the automated conformance check — download it and pass the URL and token explicitly, never bare (with no URL it waits at an interactive prompt and a non-interactive run dies there):
    curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh
    CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter http://127.0.0.1:8480
    CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter --deep http://127.0.0.1:8480

    Either path: STOP once the adapter runs and is verified on loopback. If a PASS offers to continue with setup, answer no. Do NOT set up HTTPS or expose it to any network — exposure and pairing are mine to run, and I'll do them myself through Conduck's guided setup afterwards.
    """
}

#Preview {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewayAdapterBriefView(proceed: {})
    }
}

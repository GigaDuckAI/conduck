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
        .choiceCardButton(cornerRadius: 14)
        // The card style makes the button itself greedy, so re-apply the pill's
        // own width cap OUTSIDE it — otherwise the capped pill would sit flush
        // left in the wider content rail instead of centered under the cards.
        .frame(maxWidth: Constants.Layout.buttonMaxWidth)
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
        .primaryCTAButton()
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
    /// stop before that brief's exposure and pairing, because this guided flow
    /// owns those via `conduck-connect` — with a self-contained fallback list for
    /// tools without web access, aligned to contract revision 1.10. The full
    /// contract is at `Constants.adapterContractURL`; both raw `.md` URLs are
    /// hardcoded inline below. `internal` so a content-lock test can read it via
    /// `@testable import`.
    ///
    /// **That revision number is the app's ONLY pinned contract literal, and it is
    /// load-bearing.** The fallback list is a copy of the contract's adapter half,
    /// so it goes stale silently — a copy has no way to notice its source moved.
    /// Every bump means re-reading the published contract's changelog and deciding
    /// what, if anything, in the list below has to move; the number records that
    /// the reading happened, not merely that a contract exists.
    /// `GatewayAdapterBriefTests` compares it against the site's `CONTRACT_REVISION`
    /// when the website source is checked out beside the app, so keep the phrase
    /// "aligned to contract revision <n.n>" intact — the test matches on it.
    ///
    /// Revision 1.7 rewrote the file lane's outbound half and moved NOTHING in this
    /// list, which is the expected shape rather than a lucky escape: 1.7 changes no
    /// request or response shape on either chat route, and the lane it does change
    /// is a property of the AGENT and its file server (the agent now creates the
    /// folder Conduck names, and naming a file in reply prose delivers nothing),
    /// while this brief only ever asks for adapter code. The lane reaches the user
    /// through `conduck-connect` and the engine's own standing instructions, so
    /// importing it here would hand an autonomous coding agent work that is not its
    /// to do — the same boundary the exposure/pairing rule below draws.
    ///
    /// Revision 1.8 is purely additive — one new "Optional response metadata"
    /// section — and it DOES move one thing here: item 10 below. The fields are
    /// permanently optional and no adapter becomes nonconforming by omitting
    /// them, so nothing in items 1-9 changes and the conformance checker does
    /// not test them. They are carried anyway because the two SHOULDs are
    /// adapter-code decisions best made while the adapter is being written: a
    /// `usage` figure covering one model call out of several is worse than none
    /// (nothing downstream can tell them apart), and a truncated reply with no
    /// `finish_reason` is indistinguishable from a finished one. An offline
    /// build that never hears the recommendation reports nothing forever.
    ///
    /// Revision 1.9 is clarifications only and moves TWO things here, both
    /// additive clauses. Item 4 gains the file-channel forwarding route: an
    /// engine whose only image input is a file-reading tool or attachment
    /// argument still counts as accepting images — the checker has always
    /// graded that as forwarding — so an offline build no longer declines
    /// images it could forward. Item 9 gains the in-prompt file-reference
    /// hazard: an engine that expands `@path`-style references inside message
    /// text is a file-read primitive the no-shell rule does not close. The
    /// rest of 1.9 moves nothing: `CI=1` in the contract's own self-test block
    /// (this string always carried it), the rclone `--dir-cache-time` flag
    /// (file lane — out of scope here by the 1.7 boundary above), and the
    /// `429`/`503` and `401`-before-`404` harmonizations (items 5 and 6 never
    /// pinned those statuses).
    ///
    /// Revision 1.10 is clarifications plus one additive error code, and it
    /// moves small clauses in EIGHT items, all additive: item 2 (the models
    /// route stays answerable while a chat turn runs), item 3 (turns that
    /// answer by DOING — a no-words turn is the empty-content error, rendered
    /// tool calls get stripped, and a framework "success" whose text is an
    /// error message becomes an error response — both named as a 502), item 4
    /// (an `image_url` that is not an inline data: URI is malformed — 400,
    /// never fetched; and the verbatim neutral-carrier sentence for an
    /// image-only message when the engine refuses an empty prompt), item 5
    /// (`body_too_large` joins the vocabulary; parse strictly inbound too),
    /// item 6 (accepting the 50 MiB floor does not oblige forwarding it to an
    /// engine that measurably dies on it), item 7 (the simplest conforming
    /// reuse policy — `Connection: close` on every response — stated
    /// outright), item 9 (the `@path` rule, taken to its conservative end —
    /// where disabling fails, confine and disclose; the contract's middle
    /// branch, an escaping the model never sees, is deliberately not carried
    /// into this list, because an offline builder cannot test that the
    /// escaping is invisible), item 10 (an agent loop stopped at its step cap
    /// reports "length" when the cap is what ended the answer). The rest of
    /// 1.10 moves nothing here: the pairing-payload spec and `--emit-code`
    /// (this guided flow owns pairing — naming a minting command in an
    /// autonomous agent's brief would cross the same boundary the absent
    /// `--setup` guards), the file-lane username/permissions/cwd rules plus
    /// the adapter-supplied/mode-gated file-tool patterns and the
    /// escalation-argument trap (out of scope by the 1.7 boundary above), the
    /// self-test `PORT` variable (this string pins `8480` deliberately — the
    /// operator chose the port in this flow), the chunked-body/`411`
    /// resolution (Conduck's own chat POSTs always carry `Content-Length`, so
    /// a builder of this string never meets the case), the few-seconds bound
    /// on an early `429`/`503` (items 5 and 6 never pinned queueing behavior
    /// — the 1.9 entry records the same reason), the earlier-image-disclosure
    /// legitimacy note (item 4 already states forward-or-disclose for earlier
    /// messages unconditionally, vision or not), and the checker
    /// `revision=`-comparison explanation (this guided flow runs the check
    /// itself; the string already tells the agent to record the revision it
    /// builds against).
    ///
    /// **Workflow-ownership boundary — the load-bearing rule of this string.**
    /// This text is pasted into an AUTONOMOUS coding agent, so what it can act on
    /// is exactly what it is handed. It therefore carries the adapter-check
    /// invocations in COMPLETE runnable form (download, `CI=1`, `CONDUCK_TOKEN`,
    /// explicit loopback URL — a bare `--check-adapter` blocks on an interactive
    /// URL/token prompt, and without `CI=1` a PASS hangs asking whether to continue
    /// into pairing, AFTER printing its result, so the run looks finished) and
    /// carries NO pairing invocation at all: exposure and pairing are named in prose
    /// only. First-person phrasing ("I'll handle that") is intent, not a control;
    /// the actual control is that the command is absent. The boundary is stated in
    /// WORDS, never as the hosted brief's step numbers — that numbering lives in
    /// another repo, nothing here guards it, and a shifted number once cut the
    /// operator handoff (the port and token this flow needs on its NEXT screen) out
    /// of scope. `GatewayAdapterBriefTests` locks these.
    static let clipboardBrief: String = """
    Build a "Conduck adapter v1" for my existing AI agent, so the Conduck app can talk to it.

    Best path — if you have web access, read and follow the build brief:
    https://conduck.com/setup/adapter/build.md
    This request deliberately narrows that workflow: build the adapter and get both check profiles to exit 0 against the real engine on loopback, install it under a supervisor, then re-run both profiles against the supervised instance. Download the checker once, then run it with the port and bearer token you configured:
    curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh
    CI=1 CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter http://127.0.0.1:8480
    CI=1 CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter --deep http://127.0.0.1:8480
    With CI=1 set, no check will ask; if one somehow does, answer no. Then hand me the port, bearer token, working folder and supervisor details, and STOP — do NOT set up HTTPS, expose anything to a network, or pair a device. Exposure and pairing are not yours to run: I'll handle them myself through Conduck's guided setup afterwards. The full wire contract is https://conduck.com/setup/adapter/v1.md — record the document revision you build against.

    First, inspect my project — don't guess. If it ALREADY runs a long-lived HTTP server with the two routes below, tell me and skip the build.

    If you can't fetch those URLs, these core requirements are enough:
    1. Keep my agent exactly as it is. Add a separate, small HTTP service in front of it.
    2. GET /v1/models -> 200 with {"data":[{"id":"<agent-name>"}]} within 15 seconds, no cold starts on this route and no waiting behind a chat turn (answer it outside any queue you serialize chat through). Auth-protected like everything else.
    3. POST /v1/chat/completions (OpenAI chat format; the final messages element is always the current turn and always role "user"; consecutive messages MAY share a role — two "user" messages in a row is a real shape, so accept it and, if your engine needs strict alternation, combine each run of same-role messages in order rather than dropping or reordering any; the body carries the complete current message window on every request — it is bounded and may slide, so run each request as a fresh, self-contained conversation and never de-duplicate by message content; "content" may be a string or an array of text and image_url parts) -> run ONE complete agent turn — including any tools — and return 200 with {"choices":[{"message":{"role":"assistant","content":"<final answer text>"}}]}. Never return tool_calls; never stream — answer with ONE synchronous JSON body however the request asks: do not branch on "stream": true, and do not branch on the Accept header either (no request earns a stream, and the conformance check asks both ways; Conduck itself always sends "stream": false, but never rely on that); never return an empty "content" string (error instead) — and an engine that did the work but produced no words is that same error (a 502): never write the answer yourself. If the engine renders tool calls or reasoning into its message text, strip that machinery and return the last message that still contains an actual answer. Check the engine's own success signal too: a framework "success" whose text is an error message must become an error response (a 502), never a confident 200. Finish within 285 seconds or cancel the work — terminating the whole child process tree — and return an error.
    4. Images: on the current turn (the final messages element), forward images if my agent accepts them, and never silently drop one — if my agent can't take images, reject with 400 and code "image_unsupported". An image_url that is not an inline data: URI is malformed: reject with 400 and never fetch it. An image-only message is valid — its text part arrives empty; if my agent refuses an empty prompt, put exactly this sentence in the empty text's place and nothing more: "The user sent an image with no accompanying text." An agent whose only image input is a file-reading tool or an attachment argument still counts as accepting images: write the decoded image to a per-turn temp file it can read and hand it the path (delete the file when the turn ends) — only the image's position among the text parts is lost, never the image. For EARLIER messages, never reject a request because an earlier message contains an image — forward it, or replace it in-position with exactly this text: "An image was attached in this earlier message, but this adapter cannot inspect it. Do not infer its contents."
    5. Errors are {"error":{"message":"...","type":"...","code":"..."}} with a non-2xx status. Use these codes where they fit: image_unsupported, model_not_found (400 — a "model" value matching nothing you advertise), context_too_long, image_too_large, body_too_large (413 refused from Content-Length alone, where you can't know an image is to blame), overloaded, upstream_timeout, upstream_failure. Be lenient otherwise: tolerate a present OR absent "model" field and ignore unknown extra fields (never reject on them). Always respond with Content-Type: application/json and STRICT standard JSON — never NaN or Infinity anywhere in the body (Python's json.dumps allows them by default; the app rejects the whole response), and parse strictly on the way in too (json.loads accepts NaN by default).
    6. Require "Authorization: Bearer <token>" on every request, including /v1/models (long random token, stored outside the code), and check it before any other work. Bind to 127.0.0.1 only. Accept request bodies of at least 50 MiB — an image turn legitimately arrives that big. Accepting that much is not forwarding it: if my engine demonstrably dies on a near-cap request, decline with 400 and code "context_too_long" instead of passing it on.
    7. If you answer a request before reading its body to the end (a 401, a 413), either drain the remainder or close the connection — never leave it and read the next request off the same one. Loopback curl cannot catch this; behind a pooling HTTPS front it corrupts later requests that are themselves fine. Simplest conforming policy: send Connection: close on every response — nothing here needs keep-alive.
    8. Install it under a supervisor (launchd, systemd, or equivalent) so it survives restarts and logouts, then re-run both checks against the SUPERVISED instance — a supervisor changes the environment, working directory and user, so a green foreground run proves nothing about it.
    9. Safety: never pass chat text through a shell; if the engine expands @path-style file references inside prompt text, disable that (it lets chat content read files with no shell involved), and if it cannot be disabled, confine the engine so chat can only reach files you would hand it anyway — and say so when you hand back; tool approvals fail closed (no auto-approve-everything); never log message content or tokens.
    10. Optional, but do it if you can: alongside "choices", report top-level "model" and "id", a "usage" object with prompt_tokens / completion_tokens / total_tokens, and a "finish_reason" on the single choices entry. All four are optional and omitting them is fully conformant. Report a number only when you actually have it — never a placeholder zero — and make "usage" cover the WHOLE turn (every model call the agent made answering it, tool loops and sub-agents included), since a figure covering one call out of several is worse than no figure. If the engine stopped on an output limit, say so with "finish_reason": "length" — an agent loop that stopped at its own step cap counts too, but only when the cap is what cut the answer short, not when it merely closed the loop after a complete answer.

    If you can reach GitHub but not conduck.com, you can still run the automated conformance check — download it and pass the URL and token explicitly, never bare (with no URL it waits at an interactive prompt and a non-interactive run dies there):
    curl -fsSLO https://github.com/gigaduckai/conduck-connect/releases/latest/download/conduck-connect.sh
    CI=1 CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter http://127.0.0.1:8480
    CI=1 CONDUCK_TOKEN="$TOKEN" bash conduck-connect.sh --check-adapter --deep http://127.0.0.1:8480

    Either path: STOP once the supervised adapter is verified on loopback and you've handed me its port and token. Do NOT set up HTTPS or expose it to any network — exposure and pairing are mine to run, and I'll do them myself through Conduck's guided setup afterwards.
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

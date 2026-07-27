// Conduck
// PairingImportSheet.swift
//
// ONE shared iOS + macOS sheet that turns a `conduck-connect` setup code into a
// configured gateway (and optionally its file server) in one pass. Supports a
// free target (the payload's own kind picks/mints it) or a LOCKED target
// (`lockedTarget`, the per-ref editor entry) where a kind-mismatched code is
// refused by the plan and `onImported` lets the host re-hydrate its
// buffered-editor snapshot. Presented from `GuidedGatewaySetupView`, which every
// gateway-list and per-ref entry point routes into.
//
// RENDERING ONLY. The lifecycle — phases, generation guarding, draft ownership,
// the trust gate, the commit gate — lives in `PairingImportFlow`, because those
// are the parts that needed to be testable and could not be while they sat in
// `@State`. This file owns layout, dismissal, and the camera viewport; it makes
// no decisions of its own.
//
// State machine (see `PairingImportFlow`): input → REVIEW → TRUST RESOLUTION →
// running → done. REVIEW is the consent step: scanning performs no network
// request, nothing reaches storage before Connect, and the card is re-read and
// compared immediately before the commit.
//
// PRIVACY (spec.md "Privacy & Security"): the pasted/scanned string embeds the
// gateway bearer token + file-server credential. It is NEVER logged, echoed into
// error text, or displayed — every error string comes from the typed
// `PairingParseError` → key mapping, the plan's typed blocks, or the `AppError`
// taxonomy (which never carries secrets). The paste buffer is cleared on dismiss.

import SwiftUI

struct PairingImportSheet: View {

    /// Fired after `dismiss()` when the user, sitting on a TERMINAL non-cert
    /// gateway failure, picks "Fix it manually" — lets the host route to the
    /// per-ref/manual editor. nil → the affordance is hidden.
    private let onOpenManualSettings: (() -> Void)?

    @State private var flow: PairingImportFlow

    /// CAPTURED ONCE. `State(initialValue:)` runs on every re-render but SwiftUI
    /// keeps the FIRST flow, so `lockedTarget`, `onImported` and `onConnected` are
    /// frozen at first presentation — unlike the plain View properties they
    /// replaced, which were re-read every render.
    ///
    /// Safe for both of today's inputs, and the reason is worth stating because
    /// nothing in the type system enforces it:
    ///   - `lockedTarget` comes from `GuidedGatewaySetupView.quickConnectTarget`,
    ///     derived from its `initialPath` init parameter — immutable for that
    ///     view's lifetime, so there is no later value to miss.
    ///   - the hooks capture `@State` storage in the presenting view, which is
    ///     stable across re-renders, so a closure from the first render still
    ///     writes to the live state.
    /// A future host that passes a target which CHANGES while the sheet is open
    /// must push the update into the flow rather than rely on re-init.
    @MainActor
    init(
        viewModel: SettingsViewModel,
        lockedTarget: RemoteAgentRef? = nil,
        onImported: ((RemoteAgentRef) -> Void)? = nil,
        onConnected: ((RemoteAgentRef) -> Void)? = nil,
        onOpenManualSettings: (() -> Void)? = nil
    ) {
        self.onOpenManualSettings = onOpenManualSettings
        _flow = State(initialValue: PairingImportFlow(
            environment: SettingsViewModelPairingEnvironment(viewModel: viewModel),
            lockedTarget: lockedTarget,
            onImported: onImported,
            onConnected: onConnected
        ))
    }

    #if os(iOS)
    /// Flipped when the scanner viewport failed to start — falls back to the
    /// paste-only hint. Purely a View concern (the camera is not in the flow).
    @State private var scannerFailed: Bool = false
    #endif

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        @Bindable var flow = flow
        return NavigationStack {
            Form {
                switch flow.phase {
                case .input:
                    inputSections
                case .review:
                    reviewSections
                case .running, .done:
                    progressSections
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(Text(LocalizedStringResource(
                "settings.pairing.sheet.title",
                defaultValue: "Import setup code"
            )))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Also live during `.review` — a card with no way out but
                    // Connect is not a consent step. `.running`/`.done` keep their
                    // own exits (the run must not be interrupted; Done dismisses).
                    if flow.phase == .input || flow.phase == .review {
                        Button(role: .cancel) {
                            // A resolution may be in flight and a roster draft may
                            // exist — invalidate both, or the import persists
                            // after the user cancelled.
                            flow.invalidatePendingImport()
                            dismiss()
                        } label: {
                            Text(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel"))
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if flow.phase == .done {
                        Button {
                            dismiss()
                        } label: {
                            Text(LocalizedStringResource("settings.secret.done", defaultValue: "Done"))
                                .fontWeight(.semibold)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .alert(
                Text(LocalizedStringResource(
                    "settings.pairing.trust.consent.title",
                    defaultValue: "Trust this server's certificate?"
                )),
                isPresented: $flow.showingPinConsentAlert,
                presenting: flow.pinConsentContext
            ) { context in
                Button {
                    flow.acceptPinConsent(context)
                } label: {
                    Text(LocalizedStringResource("settings.pairing.trust.consent.confirm",
                                                 defaultValue: "Trust & Connect"))
                }
                Button(role: .cancel) {
                    // Back to the card, draft intact — declining a certificate
                    // exception is not the same as abandoning the import, and the
                    // destination is still there to re-read.
                    flow.returnToReview(notice: nil)
                } label: {
                    Text(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel"))
                }
            } message: { context in
                Text(pinConsentMessage(for: context))
            }
            .alert(
                // Deliberately generic: two of the five blocks are NOT a mismatch
                // (the code named no key; the key type can't be pinned), and a
                // title claiming otherwise would misdescribe them.
                Text(LocalizedStringResource(
                    "settings.pairing.trust.blocked.title",
                    defaultValue: "Can't verify this server"
                )),
                isPresented: $flow.showingTrustBlockAlert,
                presenting: flow.trustBlockContext
            ) { context in
                if let override = context.override {
                    Button(role: .destructive) {
                        flow.acceptTrustOverride(context, override: override)
                    } label: {
                        Text(overrideButtonTitle(for: override))
                    }
                }
                Button(role: .cancel) {
                    // Carry the refusal back onto the card. Dropping it would
                    // return the user to a screen that looks exactly as it did
                    // before Connect, with nothing to explain why nothing
                    // happened — and Connect one tap away again.
                    flow.returnToReview(notice: .refused(blockReason(for: context)))
                } label: {
                    Text(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel"))
                }
            } message: { context in
                Text(trustBlockMessage(for: context))
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        // Block interactive swipe-dismiss while the stages are executing — a
        // mid-run dismissal could race the persistence Task. Once `.done`,
        // dismissal is allowed again (Done / Cancel).
        .interactiveDismissDisabled(flow.phase == .running)
        .onDisappear {
            // Covers swipe-dismiss and window close during a trust probe — the
            // Cancel button is not the only way out.
            flow.invalidatePendingImport()
            flow.handleDisappear()
        }
    }

    // MARK: - Input step

    @ViewBuilder
    private var inputSections: some View {
        #if os(iOS)
        scannerSection
        #endif
        pasteSection
    }

    #if os(iOS)
    /// Live QR viewport on top when the camera can scan; the paste-instead hint
    /// otherwise. Gated again on `canImport(VisionKit)` because the scanner type
    /// itself only exists behind that guard.
    @ViewBuilder
    private var scannerSection: some View {
        #if canImport(VisionKit)
        Section {
            if PairingScannerView.isAvailableForScanning && !scannerFailed {
                PairingScannerView(
                    onCode: { code in flow.handleCode(code) },
                    onUnavailable: { scannerFailed = true },
                    // A scanned Conduck code that won't parse (unsupported version
                    // / damaged): show the SAME typed error the paste path shows,
                    // inline, while the camera keeps scanning for a good code.
                    onRejected: { error in flow.noteScannerRejection(error) }
                )
                .id(flow.scannerGeneration)
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } else {
                scannerUnavailableHint
            }
        } footer: {
            if PairingScannerView.isAvailableForScanning && !scannerFailed {
                Text(LocalizedStringResource(
                    "settings.pairing.scanner.prompt",
                    defaultValue: "Point the camera at the QR code from conduck-connect."
                ))
            }
        }
        #else
        Section { scannerUnavailableHint }
        #endif
    }

    private var scannerUnavailableHint: some View {
        Text(LocalizedStringResource(
            "settings.pairing.scanner.unavailable",
            defaultValue: "Camera scanning isn't available here. Paste the code instead."
        ))
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
    }
    #endif

    /// Paste field + Import button (the whole input step on macOS). The
    /// placeholder is VERBATIM — `"conduck-setup:v1:…"` is wire syntax, not prose,
    /// so it is deliberately not localized.
    private var pasteSection: some View {
        @Bindable var flow = flow
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                TextField(text: $flow.pastedCode, prompt: Text(verbatim: "conduck-setup:v1:…")) {
                    Text(LocalizedStringResource(
                        "settings.pairing.entry.paste",
                        defaultValue: "Paste setup code"
                    ))
                }
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                #if os(iOS)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

                if let inlineError = flow.inlineError {
                    Text(inlineError)
                        .font(.footnote)
                        .foregroundStyle(AppColors.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    flow.handleCode(flow.pastedCode)
                } label: {
                    Text(LocalizedStringResource("settings.pairing.paste.import", defaultValue: "Import"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(flow.planning || flow.pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Review step
    //
    // Everything rendered here is either derived from the URL that will actually
    // be stored, or read from local state. No field the code's author chose as
    // prose appears — not the gateway `name`, not `model`, not the transport
    // label. That is what makes the card worth reading: a hostile code can move
    // the destination, but it cannot write the caption above it.

    @ViewBuilder
    private var reviewSections: some View {
        if let context = flow.reviewContext {
            destinationSection(context.model)
            consequenceSection
            if let notice = context.notice {
                noticeSection(notice)
            }
            actionSection(context.model)
        }
    }

    private func destinationSection(_ model: PairingReviewModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                reviewRow(
                    label: String(localized: "settings.pairing.review.messages",
                                  defaultValue: "Messages go to"),
                    value: model.gatewayDestination,
                    monospaced: true
                )

                if let previous = model.previousGatewayDestination {
                    if model.gatewayDestinationChanges {
                        reviewRow(label: replacingLabel(model), value: previous, monospaced: true)
                    } else {
                        // Same address, so there is nothing to compare — but the
                        // token and certificate settings are still being
                        // overwritten, and silence would read as "nothing changes
                        // here".
                        reviewRow(
                            label: replacingLabel(model),
                            value: String(localized: "settings.pairing.review.replacing.sameAddress",
                                          defaultValue: "The same address. The saved key and certificate settings are replaced."),
                            monospaced: false
                        )
                    }
                }

                if let fileLane = model.fileLane {
                    switch fileLane {
                    case .incoming(let destination, let replacing):
                        reviewRow(
                            label: String(localized: "settings.pairing.review.files",
                                          defaultValue: "Files go to"),
                            value: destination,
                            monospaced: true,
                            caption: replacing.flatMap { previous in
                                previous == destination ? nil : String(
                                    format: String(localized: "settings.pairing.review.files.replacing",
                                                   defaultValue: "Replacing %@"),
                                    previous
                                )
                            }
                        )
                    case .keepsExisting(let destination):
                        reviewRow(
                            label: String(localized: "settings.pairing.review.files.kept",
                                          defaultValue: "Files keep going to"),
                            value: destination,
                            monospaced: true,
                            caption: String(localized: "settings.pairing.review.files.kept.caption",
                                            defaultValue: "This code doesn't set up file transfer, so your current setup stays.")
                        )
                    }
                }

                reviewRow(
                    label: String(localized: "settings.pairing.review.certificate",
                                  defaultValue: "Certificate"),
                    value: certificateText(model.certificate),
                    monospaced: false
                )

                if model.becomesDefault {
                    reviewRow(
                        label: String(localized: "settings.pairing.review.default",
                                      defaultValue: "New chats"),
                        value: String(localized: "settings.pairing.review.default.value",
                                      defaultValue: "Will use this gateway — it's your first one."),
                        monospaced: false
                    )
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(LocalizedStringResource("settings.pairing.review.header",
                                         defaultValue: "Where this code points"))
        }
    }

    /// "Replacing OpenClaw" when the target's name comes from LOCAL state, plain
    /// "Replacing" otherwise. A brand-new custom has no local name, and the only
    /// one available is the one the CODE chose — which is exactly the string this
    /// card refuses to render.
    private func replacingLabel(_ model: PairingReviewModel) -> String {
        guard let name = model.targetName else {
            return String(localized: "settings.pairing.review.replacing",
                          defaultValue: "Replacing")
        }
        return String(
            format: String(localized: "settings.pairing.review.replacing.named",
                           defaultValue: "Replacing %@"),
            name
        )
    }

    /// The certificate row states the CLAIM, never the outcome — the check runs
    /// against the live server after Connect (`PairingTrustDecision`), and
    /// predicting its verdict here would be a guess on the one screen that exists
    /// to be trustworthy.
    ///
    /// The second sentence of the named case is load-bearing. "This code names a
    /// key" invites the reasonable inference that future connections stay bound to
    /// that key — but a matching claim on an already-trusted certificate resolves
    /// to `useOrdinaryTrust` and stores NO pin at all, deliberately, so the server
    /// can renew normally. Saying only the first half would over-promise
    /// durability on the row whose whole subject is durability.
    ///
    /// Neither string names WHICH server: the claim can belong to the gateway, the
    /// file server, or both with two different keys, and the destination rows
    /// directly above already say which servers are involved.
    private func certificateText(_ certificate: PairingReviewModel.Certificate) -> String {
        switch certificate {
        case .standardChecks:
            return String(localized: "settings.pairing.review.certificate.standard",
                          defaultValue: "Standard checks. This code doesn't name a particular key to expect.")
        case .namesSpecificKey:
            return String(localized: "settings.pairing.review.certificate.named",
                          defaultValue: "This code names the exact key to expect. Conduck checks it against the key the server presents before saving anything. If the certificate is already trusted on its own, that's a one-off check; if it isn't, Conduck asks before trusting the key from then on.")
        }
    }

    /// What accepting grants. Deliberately about what the AGENT can do, not about
    /// what the setup wizard configured: on a default install the file tools are
    /// already on and the wizard changes nothing, so "we didn't enable it" would be
    /// true and misleading at once. Equally deliberately hedged — a custom gateway
    /// may be a plain model proxy with no tools at all.
    private var consequenceSection: some View {
        Section {
            AmberCallout(
                systemImage: "exclamationmark.shield",
                title: LocalizedStringResource(
                    "settings.pairing.review.warning.title",
                    defaultValue: "Check this before you connect"
                ),
                message: LocalizedStringResource(
                    "settings.pairing.review.warning.body",
                    defaultValue: "Messages and files you send through this gateway go to this server. Anyone with this code can use every capability the gateway permits — depending on its configuration that may include running tools, and reading or changing files in its shared folder. Continue only if you recognize this address and trust whoever gave you the code."
                )
            )
            // The callout draws its own amber container — a second Form-row
            // background behind it would read as a box inside a box.
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func noticeSection(_ notice: PairingImportFlow.ReviewNotice) -> some View {
        Section {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: noticeGlyph(notice))
                    .foregroundStyle(noticeColor(notice))
                    .accessibilityHidden(true)
                Text(noticeText(notice))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private func noticeText(_ notice: PairingImportFlow.ReviewNotice) -> String {
        switch notice {
        case .destinationChanged:
            return String(localized: "settings.pairing.review.notice.changed",
                          defaultValue: "This gateway's settings changed while you were looking at this screen. Nothing was connected — the details above are the current ones. Check them again before you continue.")
        case .refused(let reason), .unreachable(let reason):
            return reason
        }
    }

    private func noticeGlyph(_ notice: PairingImportFlow.ReviewNotice) -> String {
        switch notice {
        case .destinationChanged: return "arrow.triangle.2.circlepath"
        case .refused: return "xmark.shield"
        case .unreachable: return "wifi.exclamationmark"
        }
    }

    private func noticeColor(_ notice: PairingImportFlow.ReviewNotice) -> Color {
        switch notice {
        case .destinationChanged, .unreachable: return AppColors.warning
        case .refused: return AppColors.error
        }
    }

    private func actionSection(_ model: PairingReviewModel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    flow.connect()
                } label: {
                    HStack(spacing: 8) {
                        if flow.planning { ProgressView().controlSize(.small) }
                        // An overwrite says so on the button. The deleted alert had
                        // a destructive "Replace"; folding it into the card kept
                        // every fact but would have dropped that signal, and the
                        // action really is destructive to a saved setup.
                        Text(model.replacesExistingGateway
                             ? String(localized: "settings.pairing.review.replaceAndConnect",
                                      defaultValue: "Replace & Connect")
                             : String(localized: "settings.pairing.review.connect",
                                      defaultValue: "Connect"))
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(flow.planning)

                Button {
                    flow.useDifferentCode()
                } label: {
                    Text(LocalizedStringResource("settings.pairing.review.different",
                                                 defaultValue: "Use a different code"))
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(flow.planning)
            }
            .padding(.vertical, 4)
        }
    }

    /// One label/value pair. Vertical, not `LabeledContent`: a URL is the point of
    /// this screen and a trailing-aligned value would truncate the host, port or
    /// path prefix — exactly the parts a look-alike destination differs in.
    @ViewBuilder
    private func reviewRow(
        label: String,
        value: String,
        monospaced: Bool,
        caption: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Certificate alert copy

    private func pinConsentMessage(for context: PairingImportFlow.PinConsentContext) -> String {
        let subject: String = {
            if context.lanes.contains(.gateway) && context.lanes.contains(.fileServer) {
                return String(localized: "settings.pairing.trust.consent.both",
                              defaultValue: "The gateway and its file server use certificates")
            }
            if context.lanes.contains(.fileServer) {
                return String(localized: "settings.pairing.trust.consent.file",
                              defaultValue: "The file server uses a certificate")
            }
            return String(localized: "settings.pairing.trust.consent.gateway",
                          defaultValue: "This gateway uses a certificate")
        }()
        // "matching what this code names" rather than "the same key": with both
        // lanes involved these may be two DIFFERENT certificates, each matching
        // its own claim.
        return String(
            format: String(
                localized: "settings.pairing.trust.consent.body",
                defaultValue: "%@ that no one else vouches for, matching what this setup code names. Conduck will trust those exact keys from now on — and only those."
            ),
            subject
        )
    }

    /// The override button's title says what it will DO, because the two override
    /// actions differ in kind: one keeps standard verification, the other starts
    /// trusting an unvouched-for key permanently.
    private func overrideButtonTitle(for override: PairingTrustOverride) -> String {
        switch override {
        case .proceedUnderOrdinaryTrust:
            return String(localized: "settings.pairing.trust.blocked.override.ignoreClaim",
                          defaultValue: "Ignore the code's key")
        case .pinPresentedKey:
            return String(localized: "settings.pairing.trust.blocked.override.pin",
                          defaultValue: "Trust this server anyway")
        }
    }

    /// What proceeding would concretely do — appended to every block message that
    /// offers an override. Pinning shows the fingerprint, because the user cannot
    /// meaningfully consent to trusting a key they were never shown.
    private func overrideDisclosure(for override: PairingTrustOverride) -> String {
        switch override {
        case .proceedUnderOrdinaryTrust:
            return String(
                localized: "settings.pairing.trust.blocked.disclosure.ignoreClaim",
                defaultValue: "\n\nContinuing ignores the key this code names and uses standard certificate checks instead, which this server already passes."
            )
        case .pinPresentedKey(let fingerprintHex):
            return String(
                format: String(
                    localized: "settings.pairing.trust.blocked.disclosure.pin",
                    defaultValue: "\n\nContinuing trusts the key this server is presenting, permanently and exclusively:\n%@"
                ),
                fingerprintHex
            )
        }
    }

    /// The refusal, plus — when proceeding is possible — exactly what proceeding
    /// would do. A "Connect anyway" button whose consequence is unstated is not
    /// informed consent.
    private func trustBlockMessage(for context: PairingImportFlow.TrustBlockContext) -> String {
        blockReason(for: context) + (context.override.map(overrideDisclosure(for:)) ?? "")
    }

    /// Per-block copy. Each case has a different remedy, so each gets its own
    /// sentence rather than one generic refusal.
    private func blockReason(for context: PairingImportFlow.TrustBlockContext) -> String {
        let subject = context.lane == .gateway
            ? String(localized: "settings.pairing.trust.subject.gateway", defaultValue: "The gateway")
            : String(localized: "settings.pairing.trust.subject.file", defaultValue: "The file server")

        switch context.block {
        case .pinContradictsLiveServer:
            return String(
                format: String(
                    localized: "settings.pairing.trust.block.contradiction",
                    defaultValue: "%@ has a valid certificate, but its key is not the one this setup code names. That can mean something on the network is inspecting the connection, or that the code is out of date."
                ), subject)

        case .untrustedAndPinMismatch:
            return String(
                format: String(
                    localized: "settings.pairing.trust.block.untrustedMismatch",
                    defaultValue: "%@'s certificate isn't trusted, and its key is not the one this setup code names. Get a fresh code from whoever set the server up."
                ), subject)

        case .unverifiablePin:
            return String(
                format: String(
                    localized: "settings.pairing.trust.block.unverifiable",
                    defaultValue: "This setup code names a specific key for %@, but Conduck couldn't read the key the server presented, so it can't check them against each other."
                ), subject.lowercased())

        case .untrustedWithoutClaim:
            return String(
                format: String(
                    localized: "settings.pairing.trust.block.noClaim",
                    defaultValue: "%@'s certificate isn't trusted, and this setup code doesn't say which key to expect. A code for a self-signed server normally includes it."
                ), subject)

        case .untrustedWithoutPinnableKey:
            return String(
                format: String(
                    localized: "settings.pairing.trust.block.unpinnable",
                    defaultValue: "%@'s certificate isn't trusted and uses a key type Conduck can't pin. Reissue it with RSA 2048/3072/4096 or EC P-256/P-384."
                ), subject)
        }
    }

    // MARK: - Progress step (staged checklist)

    @ViewBuilder
    private var progressSections: some View {
        if flow.activePayload?.transport == .tailscale {
            tailscaleCalloutSection
        }
        Section {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(flow.visibleStages, id: \.self) { stage in
                    stageRow(stage)
                }
                // `phase == .done` = the run has PAUSED on the amber row. Gating
                // on it keeps the card off screen during a trust-and-retry re-run,
                // which clears `presentedUntrustedFP` before the stage flips back
                // to `.running`.
                if flow.stageStatus[.gateway] == .untrustedCert, flow.phase == .done {
                    tofuCard
                }
            }
            .padding(.vertical, 4)
        }

        // Recovery path: a TERMINAL non-cert gateway failure (NOT
        // `.untrustedCert`, which keeps its own trust-and-retry). The save already
        // committed, so these actions never re-persist the config.
        if flow.phase == .done, flow.gatewayFailedTerminally {
            recoverySection
        }
    }

    /// Three recovery actions below the checklist after a terminal gateway
    /// failure. None re-run Stage 1 (save) — the config is already persisted.
    private var recoverySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringResource(
                    "settings.pairing.recovery.prompt",
                    defaultValue: "Your settings were saved, but the connection couldn't be verified."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    flow.retryStages()
                } label: {
                    Label(
                        LocalizedStringResource("settings.pairing.recovery.retry",
                                                defaultValue: "Try again"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)

                Button {
                    flow.backToInstructions()
                } label: {
                    Text(LocalizedStringResource("settings.pairing.recovery.back",
                                                 defaultValue: "Back to instructions"))
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                if onOpenManualSettings != nil {
                    Button {
                        dismiss()
                        onOpenManualSettings?()
                    } label: {
                        Text(LocalizedStringResource("settings.pairing.recovery.manual",
                                                     defaultValue: "Fix it manually"))
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Tailnet heads-up shown ABOVE the checklist: the connection test will fail
    /// unless this device is on the same tailnet.
    ///
    /// The Private Relay line earns its place because that failure is
    /// INDISTINGUISHABLE from a dead gateway at every layer the user can see:
    /// Tailscale reports connected, its own DNS screen reports "Using Tailscale
    /// DNS", and the tunnel genuinely carries traffic — but the relay resolves a
    /// `.ts.net` name on the public internet, which for a tailnet-only serve
    /// yields a Funnel ingress address that answers on no port the app uses. Both
    /// checklist rows then fail as unreachable and send the user to inspect a
    /// healthy gateway. Private Relay is ON by default for iCloud+, and Tailscale
    /// is the transport this app recommends, so the intersection is common rather
    /// than exotic.
    private var tailscaleCalloutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "network")
                        .foregroundStyle(AppColors.warning)
                    Text(LocalizedStringResource(
                        "settings.pairing.tailscale.note",
                        defaultValue: "This gateway is on a tailnet. Install the Tailscale app on this device and sign in to the same tailnet, or the connection test will fail."
                    ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(AppColors.warning)
                    Text(LocalizedStringResource(
                        "settings.pairing.tailscale.privateRelay",
                        defaultValue: "Already signed in and it still fails? Turn off iCloud Private Relay — Settings › your name › iCloud › Private Relay. It can take over name lookups even while Tailscale says it is connected, so this gateway's address is looked up on the public internet instead of inside your tailnet."
                    ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link(destination: Constants.tailscaleAppStoreURL) {
                    Text(LocalizedStringResource(
                        "settings.pairing.tailscale.appStore",
                        defaultValue: "Get Tailscale"
                    ))
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(AppColors.warning.opacity(0.10))
    }

    @ViewBuilder
    private func stageRow(_ stage: PairingImportFlow.StageID) -> some View {
        let status = flow.stageStatus[stage] ?? .pending
        HStack(alignment: .top, spacing: 10) {
            statusGlyph(for: status)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(stageTitle(stage))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                if let detail = detailText(for: status) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailColor(for: status))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func statusGlyph(for status: PairingImportFlow.StageStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(AppColors.textTertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColors.success)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(AppColors.error)
        case .untrustedCert:
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(AppColors.warning)
        }
    }

    private func stageTitle(_ stage: PairingImportFlow.StageID) -> LocalizedStringResource {
        switch stage {
        case .save:
            return LocalizedStringResource("settings.pairing.stage.save",
                                           defaultValue: "Save configuration")
        case .gateway:
            return LocalizedStringResource("settings.pairing.stage.gatewayTest",
                                           defaultValue: "Gateway connection")
        case .file:
            return LocalizedStringResource("settings.pairing.stage.fileTest",
                                           defaultValue: "File transfer")
        }
    }

    private func detailText(for status: PairingImportFlow.StageStatus) -> String? {
        switch status {
        case .failed(let message):
            return message
        case .untrustedCert:
            // Reuses the gateway TOFU title — same situation, same words.
            return String(localized: "settings.remoteAgent.tofu.title",
                          defaultValue: "Untrusted certificate")
        case .pending, .running, .passed:
            return nil
        }
    }

    private func detailColor(for status: PairingImportFlow.StageStatus) -> Color {
        switch status {
        case .failed:
            return AppColors.error
        case .untrustedCert:
            return AppColors.warning
        default:
            return AppColors.textTertiary
        }
    }

    // MARK: - TOFU disclosure (what the tap actually pins)
    //
    // `trustAndRetry()` writes a PERMANENT per-device pin, and a pin REPLACES
    // chain validation — so the one tap that reaches it is the whole trust
    // decision. It therefore has to say what is being pinned before the tap, not
    // after. One-tap TOFU (no separate review sheet) is the blessed pattern here —
    // `STTTestSuiteResultView` ships the same shape — and this card mirrors it:
    // explanatory body copy + the captured SPKI fingerprint inline + the action.
    // The fingerprint is a PUBLIC value, so rendering it leaks nothing.
    //
    // The contradiction line is the signal a user can actually act on. A
    // `conduck-connect` payload that carries `certFP` (or declares the self-signed
    // transport) means the wizard expected an untrusted cert here, and a pin
    // already set makes this state unreachable anyway
    // (`classifyTransportError(hasPin: true, …)` never returns `.untrustedCert`).
    // So reaching TOFU during an import of a payload with NO `certFP` means the
    // wizard read the gateway's cert as publicly trusted while this device rejects
    // it — a disagreement worth naming, because interception is one of the things
    // that produces it.
    @ViewBuilder
    private var tofuCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fingerprint = flow.presentedUntrustedFP, !fingerprint.isEmpty {
                Text(LocalizedStringResource(
                    "settings.pairing.tofu.body",
                    defaultValue: "This gateway presented a self-signed certificate this device doesn't recognize. Trusting it pins this exact certificate on this device — from then on Conduck accepts only this one."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if flow.unexpectedSelfSignedCert {
                    Text(LocalizedStringResource(
                        "settings.pairing.tofu.unexpected",
                        defaultValue: "Your setup code expected a publicly-trusted certificate here, not a self-signed one. On an untrusted network that can mean something is intercepting the connection. Re-run the setup on your server to confirm before you trust this."
                    ))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(fingerprint)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                trustRetryButton
            } else {
                // No pinnable fingerprint (key algorithm outside the V1 SPKI prefix
                // table) — there is nothing to pin, so offer no action and name the
                // two ways out instead of leaving a dead row.
                Text(LocalizedStringResource(
                    "settings.pairing.tofu.noFingerprint",
                    defaultValue: "This gateway uses a self-signed certificate with an unsupported key type. Pin it manually in the gateway's Server certificate row, or give the server a publicly-trusted certificate."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 30)   // aligns under the stage row's title column
    }

    private var trustRetryButton: some View {
        Button {
            flow.trustAndRetry()
        } label: {
            Label(
                LocalizedStringResource("settings.pairing.trustRetry",
                                        defaultValue: "Trust certificate & retry"),
                systemImage: "checkmark.shield.fill"
            )
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
    }
}

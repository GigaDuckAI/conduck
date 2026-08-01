// SPDX-License-Identifier: Apache-2.0

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

    /// Fired after `dismiss()` when the user, sitting on a failed gateway stage,
    /// picks "Fix it manually" — lets the host route to the per-ref/manual
    /// editor. nil → the affordance is hidden.
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
            .navigationTitle(Text(sheetTitle))
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
                    "settings.pairing.trust.blocked.title",
                    defaultValue: "Can't verify this server"
                )),
                isPresented: $flow.showingTrustBlockAlert,
                presenting: flow.trustBlockContext
            ) { context in
                // No "Connect anyway". Every refusal here is terminal — a pin
                // cannot make an untrusted chain acceptable to the system, so a
                // proceed button would either lie or produce a gateway that fails
                // every request afterwards.
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
                Text(blockReason(for: context))
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

    private var sheetTitle: LocalizedStringResource {
        if flow.phase == .review {
            return LocalizedStringResource(
                "settings.pairing.review.sheetTitle",
                defaultValue: "Review setup code"
            )
        }
        return LocalizedStringResource(
            "settings.pairing.sheet.title",
            defaultValue: "Import setup code"
        )
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
            consequenceSection(context.model)
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
                    value: model.gatewayDestination,
                    monospaced: true,
                    caption: model.becomesDefault ? String(
                        localized: "settings.pairing.review.default.value",
                        defaultValue: "New chats will use this gateway."
                    ) : nil,
                    warning: temporaryTunnelWarning(for: model.gatewayDestination)
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
                            },
                            warning: temporaryTunnelWarning(for: destination)
                        )
                    case .keepsExisting(let destination):
                        reviewRow(
                            label: String(localized: "settings.pairing.review.files.kept",
                                          defaultValue: "Files keep going to"),
                            value: destination,
                            monospaced: true,
                            caption: String(localized: "settings.pairing.review.files.kept.caption",
                                            defaultValue: "This code doesn't set up file transfer, so your current setup stays."),
                            warning: temporaryTunnelWarning(for: destination)
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(LocalizedStringResource("settings.pairing.review.header",
                                         defaultValue: "Gateway"))
        }
    }

    private func temporaryTunnelWarning(for destination: String) -> String? {
        guard EndpointURLPolicy.isCloudflareQuickTunnelURLString(destination) else {
            return nil
        }
        return String(localized: LocalizedStringResource(
            "settings.pairing.review.temporaryTunnel",
            defaultValue: "Temporary address — it changes when the tunnel restarts."
        ))
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

    /// What accepting grants, split into two short scan-friendly facts. The access
    /// bullet is payload-aware: a gateway-only code does not make the user parse a
    /// file-transfer warning for a lane that is absent, while a lane that arrives
    /// or survives an overwrite keeps the shared-files consequence visible.
    private func consequenceSection(_ model: PairingReviewModel) -> some View {
        let accessBullet = model.fileLane == nil
            ? LocalizedStringResource(
                "settings.pairing.review.warning.access.tools",
                defaultValue: "Anyone with this code may connect with the same access, which may include tools."
            )
            : LocalizedStringResource(
                "settings.pairing.review.warning.access.files",
                defaultValue: "Anyone with this code may connect with the same access, which may include tools and shared files."
            )

        return Section {
            PairingSafetyCallout(
                systemImage: "exclamationmark.shield",
                title: LocalizedStringResource(
                    "settings.pairing.review.warning.title",
                    defaultValue: "Before you connect"
                ),
                bullets: [
                    LocalizedStringResource(
                        "settings.pairing.review.warning.trust",
                        defaultValue: "Only continue if you trust the person who shared this code."
                    ),
                    accessBullet
                ]
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
        case .refused(let reason):
            return reason
        }
    }

    private func noticeGlyph(_ notice: PairingImportFlow.ReviewNotice) -> String {
        switch notice {
        case .destinationChanged: return "arrow.triangle.2.circlepath"
        case .refused: return "xmark.shield"
        }
    }

    private func noticeColor(_ notice: PairingImportFlow.ReviewNotice) -> Color {
        switch notice {
        case .destinationChanged: return AppColors.warning
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
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.large)
                .disabled(flow.planning)

                Button {
                    flow.useDifferentCode()
                } label: {
                    Text(LocalizedStringResource("settings.pairing.review.different",
                                                 defaultValue: "Use another code"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(flow.planning)
            }
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    /// One label/value pair. Vertical, not `LabeledContent`: a URL is the point of
    /// this screen and a trailing-aligned value would truncate the host, port or
    /// path prefix — exactly the parts a look-alike destination differs in.
    @ViewBuilder
    private func reviewRow(
        label: String? = nil,
        value: String,
        monospaced: Bool,
        caption: String? = nil,
        warning: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let warning {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .accessibilityHidden(true)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(AppColors.warning)
            }
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

    /// The refusal, and the remedy — which is always on the SERVER. There is no
    /// override to disclose: an app may tighten certificate checks and never
    /// loosen them, so no button here could make this connection work.
    ///
    /// Only the first sentence is local, because only it is lane-specific: an
    /// import touches two servers and the user needs to know WHICH one was
    /// refused. The remedy comes from `CertificateTrustCopy`, shared with every
    /// other surface that can reach this state — three wordings would drift into
    /// three different remedies for one cause.
    private func blockReason(for context: PairingImportFlow.TrustBlockContext) -> String {
        let subject = context.lane == .gateway
            ? String(localized: "settings.pairing.trust.subject.gateway", defaultValue: "The gateway")
            : String(localized: "settings.pairing.trust.subject.file", defaultValue: "The file server")

        switch context.block {
        case .certificateNotPubliclyTrusted:
            return String(
                format: String(
                    localized: "settings.pairing.trust.block.notTrusted",
                    defaultValue: "%1$@'s certificate isn't one this device trusts, so Conduck won't connect to it. %2$@"
                ), subject, CertificateTrustCopy.untrustedRemedy)
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
            }
            .padding(.vertical, 4)
        }

        // Recovery path: the gateway stage failed. The save already committed,
        // so these actions never re-persist the config.
        if flow.phase == .done, flow.gatewayStageFailed {
            recoverySection
        }
    }

    /// Recovery actions below the checklist after a failed gateway stage. None
    /// re-run Stage 1 (save) — the config is already persisted.
    ///
    /// "Try again" is gated on `flow.gatewayFailureIsRetryable`, the same
    /// `AppError.isRetryable` question every other failure surface asks
    /// (`DeclinedTurnPresentation.offersRetry`, `StagedAttachment.failure(for:)`,
    /// `ServerFileDownloadChip.acceptsTap`). A certificate this device refuses,
    /// a rejected token or a URL that isn't an AI endpoint sends the identical
    /// probe into the identical refusal, so a prominent retry there is a promise
    /// the app cannot keep — and it buries the stage row's remedy, which is the
    /// real way out. The other two actions stay: they lead somewhere on every
    /// failure.
    private var recoverySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                // Two prompts, because one sentence cannot honestly cover both.
                // "Couldn't be verified" reads as a blip that might clear on its
                // own, which is true of an unreachable gateway and false of a
                // refusal — and the sheet has no retry to soften the terminal
                // one with, so understating it would leave the user waiting for
                // a problem that will never clear.
                Text(flow.gatewayFailureIsRetryable
                     ? LocalizedStringResource(
                        "settings.pairing.recovery.prompt",
                        defaultValue: "Your settings were saved, but the connection couldn't be verified.")
                     : LocalizedStringResource(
                        "settings.pairing.recovery.prompt.terminal",
                        defaultValue: "Your settings were saved, but the connection was refused for the reason above. Trying again would reach the same answer, so fix that first."))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if flow.gatewayFailureIsRetryable {
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
                }

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
        case .failed(let message, _):
            return message
        case .pending, .running, .passed:
            return nil
        }
    }

    private func detailColor(for status: PairingImportFlow.StageStatus) -> Color {
        switch status {
        case .failed:
            return AppColors.error
        default:
            return AppColors.textTertiary
        }
    }
}

/// A compact, properly hanging-indented alternative to a paragraph callout.
/// Each risk stays independently scannable and wraps under its own text rather
/// than under the bullet glyph.
private struct PairingSafetyCallout: View {
    let systemImage: String
    let title: LocalizedStringResource
    let bullets: [LocalizedStringResource]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(AppColors.brandAmber)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(bullets.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(verbatim: "•")
                            .accessibilityHidden(true)
                        Text(bullets[index])
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .accessibilityElement(children: .combine)
                }
            }

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
}

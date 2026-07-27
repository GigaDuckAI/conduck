// Conduck
// PairingImportSheet.swift
//
// ONE shared iOS + macOS sheet that turns a `conduck-connect` setup code into a
// configured gateway (and optionally its file server) in one pass. Presented
// from three hosts:
//   - `PersonalAISettingsView` (iOS gateway list) — scan OR paste, free target.
//   - `MacPersonalAICategory` (macOS gateway list) — paste only, free target.
//   - `RemoteAgentConfigBody` (per-ref editor, both platforms) — target LOCKED
//     to the open ref (`lockedTarget`); a kind-mismatched code is refused by
//     `planPairingImport`, and on success `onImported` lets the host re-hydrate
//     its buffered-editor snapshot.
//
// State machine: input → (overwrite alert) → running → done. The running/done
// step renders a tiny staged checklist (Save configuration → Gateway connection
// → File server) styled like `STTTestSuiteResultView`'s stage rows, with the
// gateway TOFU convention surfaced as an amber "Trust certificate & retry"
// affordance.
//
// PRIVACY (spec.md "Privacy & Security"): the pasted/scanned string embeds the
// gateway bearer token + file-server credential. It is NEVER logged, echoed
// into error text, or displayed — every error string comes from the typed
// `PairingParseError` → key mapping, the plan's typed blocks, or the `AppError`
// taxonomy (which never carries secrets). The paste buffer is cleared on every
// dismiss.

import SwiftUI

struct PairingImportSheet: View {
    @Bindable var viewModel: SettingsViewModel

    /// When non-nil the import may ONLY land on this ref (per-ref editor
    /// entry). nil → the payload's own kind picks/mints the target.
    var lockedTarget: RemoteAgentRef? = nil

    /// Fired (once) after a dismiss that follows a successful save, carrying the
    /// ref the import actually landed on (`activeTarget`) — the resolved locked
    /// target, an existing custom gateway the payload matched, or a freshly
    /// minted custom ref. Fires for EVERY successful import, locked-target or
    /// free-target, so a free-target host (the gateway list / guided setup) can
    /// react to an in-session connect — not just the per-ref editor re-hydrating
    /// its buffers. Hosts that don't need the ref ignore it (`{ _ in … }`).
    var onImported: ((RemoteAgentRef) -> Void)? = nil

    /// Fired (once, on dismiss) ONLY when the gateway connection stage actually
    /// PASSED — i.e. the import is verified-connected, not merely saved. Guided
    /// setup uses this to decide whether to advance to its "Connected" success
    /// screen; a save that fails the connection test (or pauses on an unresolved
    /// self-signed cert) must NOT show success. Distinct from `onImported`, which
    /// fires on any successful SAVE (the editor uses it to rehydrate its buffers).
    var onConnected: ((RemoteAgentRef) -> Void)? = nil

    /// Fired after `dismiss()` when the user, sitting on a TERMINAL non-cert
    /// gateway failure, picks "Fix it manually" — lets the host route to the
    /// per-ref/manual editor so they can fix the config by hand. nil → the
    /// affordance is hidden (hosts that have nowhere to send the user omit it).
    var onOpenManualSettings: (() -> Void)? = nil

    // MARK: - State machine

    private enum Phase: Equatable {
        case input      // scanner / paste field
        case running    // stages executing
        case done       // stages finished (pass or fail) — Done dismisses
    }

    /// The staged checklist — its rows mirror `STTTestSuiteResultView`'s
    /// glyph + title + detail shape, with an extra amber `untrustedCert` state
    /// carrying the trust-and-retry affordance.
    private enum StageID: Int, CaseIterable {
        case save, gateway, file
    }

    private enum StageStatus: Equatable {
        case pending
        case running
        case passed
        /// Detail is taxonomy-/key-derived only — never payload content.
        case failed(String?)
        case untrustedCert
    }

    /// Everything the overwrite alert needs, captured when the plan asks for
    /// confirmation. `freshlyMinted` → alert-cancel must discard the draft the
    /// plan minted for a brand-new custom gateway.
    private struct OverwriteContext {
        let payload: PairingPayload
        let target: RemoteAgentRef
        let existingURL: String
        let newURL: String
        let freshlyMinted: Bool
    }

    @State private var phase: Phase = .input
    @State private var pastedCode: String = ""
    @State private var inlineError: String?
    @State private var planning: Bool = false

    @State private var overwriteContext: OverwriteContext?
    @State private var showingOverwriteAlert: Bool = false

    /// Set once the plan resolves — drive the stage run + the trust retry.
    @State private var activePayload: PairingPayload?
    @State private var activeTarget: RemoteAgentRef?

    @State private var stageStatus: [StageID: StageStatus] = [:]
    /// The presented self-signed fingerprint from an `.untrustedCert` outcome —
    /// nil when none is pending OR the cert's key type yielded no fingerprint
    /// (then there is nothing to pin and the retry affordance is hidden).
    @State private var presentedUntrustedFP: String?

    /// True once Stage 1 (save) passed — gates the `onImported` hook.
    @State private var saveSucceeded: Bool = false
    /// True once Stage 2 (gateway connection) PASSED — gates the `onConnected`
    /// hook (verified connection, not just a save). Reset per import attempt and
    /// re-evaluated on every gateway-stage run (incl. trust-and-retry / retry).
    @State private var gatewayConnected: Bool = false
    /// Latches so each host hook fires EXACTLY once — set when the hook fires
    /// eagerly the moment its condition becomes true (save succeeded /
    /// verified-connected), so `handleDisappear` (kept as a fallback) can never
    /// double-fire. Reset per import attempt in `beginImport`.
    @State private var importedHookFired: Bool = false
    @State private var connectedHookFired: Bool = false

    #if os(iOS)
    /// Flipped when the scanner viewport failed to start — falls back to the
    /// paste-only hint.
    @State private var scannerFailed: Bool = false
    /// Bumped whenever a scanned code is REJECTED back to the input phase
    /// (parse error, blocked plan, overwrite-cancel). The scanner's one-shot
    /// latch + `stopScanning()` would otherwise leave a frozen viewport —
    /// `.id(scannerGeneration)` recreates it so the camera scans again.
    @State private var scannerGeneration: Int = 0
    #endif

    /// Re-arm the scanner viewport after a rejected code. No-op on macOS.
    private func restartScanner() {
        #if os(iOS)
        scannerGeneration += 1
        #endif
    }

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .input:
                    inputSections
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
                    if phase == .input {
                        Button(role: .cancel) {
                            dismiss()
                        } label: {
                            Text(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel"))
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .done {
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
                Text(overwriteAlertTitle),
                isPresented: $showingOverwriteAlert,
                presenting: overwriteContext
            ) { context in
                Button(role: .destructive) {
                    beginImport(context.payload, target: context.target)
                } label: {
                    Text(LocalizedStringResource("settings.pairing.overwrite.confirm", defaultValue: "Replace"))
                }
                Button(role: .cancel) {
                    cancelOverwrite(context)
                } label: {
                    Text(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel"))
                }
            } message: { context in
                Text(overwriteAlertMessage(for: context))
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        // Block interactive swipe-dismiss while the stages are executing — a
        // mid-run dismissal could race the unstructured persistence Task. Once
        // `.done`, dismissal is allowed again (Done / Cancel).
        .interactiveDismissDisabled(phase == .running)
        .onDisappear { handleDisappear() }
    }

    /// Title for the overwrite alert — computed from the pending context (the
    /// alert modifier's title can't take the `presenting` value directly).
    private var overwriteAlertTitle: String {
        let name = overwriteContext.map { viewModel.displayName(for: $0.target) } ?? ""
        return String(
            format: String(localized: "settings.pairing.overwrite.title",
                           defaultValue: "Replace %@ settings?"),
            name
        )
    }

    /// Body for the overwrite alert. Appends a reassurance line when the incoming
    /// GATEWAY-ONLY code (no `fileServer` block) will LEAVE the target's existing
    /// file-transfer setup untouched — the deliberate keep-existing rule, which
    /// otherwise gives the user zero signal that their file lane survives.
    private func overwriteAlertMessage(for context: OverwriteContext) -> String {
        var message = String(
            format: String(localized: "settings.pairing.overwrite.message",
                           defaultValue: "This gateway is already set up.\nCurrent: %@\nNew: %@"),
            context.existingURL,
            context.newURL
        )
        if context.payload.fileServer == nil, targetHasConfiguredFileLane(context.target) {
            message += "\n" + String(
                localized: "settings.pairing.overwrite.keepsFileTransfer",
                defaultValue: "File transfer: keeps your current setup."
            )
        }
        return message
    }

    /// True when `target` already has a saved file-transfer lane (URL +
    /// credential), so a gateway-only overwrite preserves it. `.recommended` /
    /// `.optional` (nothing saved) and `.unsupported` (no lane) read false.
    private func targetHasConfiguredFileLane(_ target: RemoteAgentRef) -> Bool {
        switch viewModel.fileLaneStatus(for: target) {
        case .ready, .needsAttention, .saved: return true
        case .recommended, .optional, .unsupported: return false
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
    /// otherwise. Gated again on `canImport(VisionKit)` because the scanner
    /// type itself only exists behind that guard.
    @ViewBuilder
    private var scannerSection: some View {
        #if canImport(VisionKit)
        Section {
            if PairingScannerView.isAvailableForScanning && !scannerFailed {
                PairingScannerView(
                    onCode: { code in handleCode(code) },
                    onUnavailable: { scannerFailed = true },
                    // A scanned Conduck code that won't parse (unsupported version /
                    // damaged): show the SAME typed error the paste path shows, inline,
                    // while the camera keeps scanning for a good code.
                    onRejected: { error in inlineError = message(for: error) }
                )
                .id(scannerGeneration)
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
    /// placeholder is VERBATIM — `"conduck-setup:v1:…"` is wire syntax, not
    /// prose, so it is deliberately not localized.
    private var pasteSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                TextField(text: $pastedCode, prompt: Text(verbatim: "conduck-setup:v1:…")) {
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

                if let inlineError {
                    Text(inlineError)
                        .font(.footnote)
                        .foregroundStyle(AppColors.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    handleCode(pastedCode)
                } label: {
                    Text(LocalizedStringResource("settings.pairing.paste.import", defaultValue: "Import"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(planning || pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Parse → plan

    /// Entry for BOTH the scanner (pre-validated) and the paste Import button.
    /// Parses, then asks the VM to plan the import against `lockedTarget`.
    private func handleCode(_ raw: String) {
        guard phase == .input, !planning else { return }
        inlineError = nil

        switch PairingPayload.parse(raw) {
        case .failure(let error):
            inlineError = message(for: error)
            restartScanner()
        case .success(let payload):
            planning = true
            Task {
                let plan = await viewModel.planPairingImport(payload, lockedTarget: lockedTarget)
                planning = false
                apply(plan, payload: payload)
            }
        }
    }

    private func apply(_ plan: PairingImportPlan, payload: PairingPayload) {
        switch plan {
        case .blocked(.customGatewayCapReached):
            inlineError = String(localized: "settings.pairing.error.capReached",
                                 defaultValue: "You've reached the custom-gateway limit. Delete one in Settings to import another.")
            restartScanner()

        case .blocked(.kindMismatch(let expectedDisplayName)):
            inlineError = String(
                format: String(localized: "settings.pairing.error.kindMismatch",
                               defaultValue: "This setup code is for %@. Import it from the gateway list instead."),
                expectedDisplayName
            )
            restartScanner()

        case .needsOverwriteConfirm(let target, let existingURL, let newURL):
            // A brand-new custom (free-target import) means the plan minted a
            // draft for it — alert-cancel must discard that draft again.
            let freshlyMinted: Bool = {
                guard lockedTarget == nil, case .custom = payload.kind else { return false }
                return true
            }()
            overwriteContext = OverwriteContext(
                payload: payload,
                target: target,
                existingURL: existingURL,
                newURL: newURL,
                freshlyMinted: freshlyMinted
            )
            showingOverwriteAlert = true

        case .ready(let target):
            beginImport(payload, target: target)
        }
    }

    private func cancelOverwrite(_ context: OverwriteContext) {
        if context.freshlyMinted {
            viewModel.discardPairingDraft(context.target)
        }
        overwriteContext = nil
        restartScanner()
    }

    /// User-facing copy per typed parse error — the ONLY error surface for a
    /// bad code (never any part of the input itself).
    private func message(for error: PairingParseError) -> String {
        switch error {
        case .notAPairingCode:
            return String(localized: "settings.pairing.error.notCode",
                          defaultValue: "That doesn't look like a Conduck setup code.")
        case .unsupportedVersion:
            return String(localized: "settings.pairing.error.version",
                          defaultValue: "This setup code needs a newer Conduck. Update the app, or re-run conduck-connect.")
        case .malformed:
            return String(localized: "settings.pairing.error.malformed",
                          defaultValue: "This setup code is damaged or incomplete. Re-run conduck-connect to get a fresh one.")
        case .insecureURL:
            return String(localized: "settings.pairing.error.insecureURL",
                          defaultValue: "Setup codes must use https:// URLs.")
        }
    }

    // MARK: - Stage run

    private func beginImport(_ payload: PairingPayload, target: RemoteAgentRef) {
        overwriteContext = nil
        activePayload = payload
        activeTarget = target
        stageStatus = [:]
        presentedUntrustedFP = nil
        // Reset per-attempt outcome so a re-import (e.g. after "Back to
        // instructions") re-evaluates cleanly and the dismiss hooks fire for the
        // LATEST attempt, not a stale earlier one.
        saveSucceeded = false
        gatewayConnected = false
        importedHookFired = false
        connectedHookFired = false
        phase = .running
        Task { await runStages(payload, target: target) }
    }

    private func runStages(_ payload: PairingPayload, target: RemoteAgentRef) async {
        // Stage 1 — persist the configuration. Three-way outcome: see
        // `PairingImportOutcome` (the gateway half can commit even when the
        // file-server credential write fails).
        stageStatus[.save] = .running
        switch await viewModel.executePairingImport(payload, target: target) {
        case .failed:
            stageStatus[.save] = .failed(String(
                localized: "settings.pairing.error.saveFailed",
                defaultValue: "Couldn't save this configuration securely. Try again."
            ))
            // A free-target custom import minted a roster draft in the plan
            // step — nothing persisted, so drop it (else a phantom empty row
            // lingers in the gateway list until the next state reload).
            if lockedTarget == nil, case .custom = payload.kind {
                viewModel.discardPairingDraft(target)
            }
            phase = .done
            return
        case .committedGatewayOnly:
            saveSucceeded = true
            stageStatus[.save] = .passed
            // The file-server half rolled back at save time — mark its stage
            // failed up front; `runFileStageIfNeeded` sees the terminal state
            // and never probes a config that isn't there.
            stageStatus[.file] = .failed(String(
                localized: "settings.pairing.error.fileCredentialFailed",
                defaultValue: "Couldn't save the file-server credential securely. The gateway itself was set up — re-run the import to add the file server."
            ))
        case .committed:
            saveSucceeded = true
            stageStatus[.save] = .passed
        }

        // The `.failed` arm returned above, so the save has committed here —
        // fire `onImported` EAGERLY (not deferred to dismiss), closing the race
        // where a swipe-dismiss mid-run skips it. Latched, so the fallback in
        // `handleDisappear` never re-fires it.
        fireImportedHookIfNeeded()

        // Stage 2 (+3) — connectivity proof on the just-saved config.
        await runGatewayStage(payload, target: target)
        phase = .done
    }

    /// Stage 2 — gateway connection test. On `.untrustedCert` the run PAUSES
    /// (amber row + trust-and-retry); the file stage only follows a terminal
    /// gateway outcome (pass or hard fail — the file server is independent).
    private func runGatewayStage(_ payload: PairingPayload, target: RemoteAgentRef) async {
        stageStatus[.gateway] = .running
        presentedUntrustedFP = nil
        let outcome = await viewModel.runPairingGatewayTest(payload, target: target)
        switch outcome {
        case .passed:
            gatewayConnected = true
            stageStatus[.gateway] = .passed
            // Verified-connected — fire `onConnected` EAGERLY (also from a
            // trust-and-retry / retry that finally passes). Latched, so the
            // `handleDisappear` fallback never re-fires it.
            fireConnectedHookIfNeeded()
            await runFileStageIfNeeded(payload, target: target)
        case .untrustedCert(let fingerprint):
            gatewayConnected = false
            presentedUntrustedFP = fingerprint
            stageStatus[.gateway] = .untrustedCert
        case .failed(let message):
            gatewayConnected = false
            stageStatus[.gateway] = .failed(message)
            await runFileStageIfNeeded(payload, target: target)
        }
    }

    /// Stage 3 — only when the payload carried a file-server block. Drives the
    /// VM's existing staged file-transfer test and reads its published result.
    /// A stage already terminally failed (the `.committedGatewayOnly` rollback)
    /// is never re-probed — its config was rolled back at save time.
    private func runFileStageIfNeeded(_ payload: PairingPayload, target: RemoteAgentRef) async {
        guard payload.fileServer != nil else { return }
        if case .failed = stageStatus[.file] ?? .pending { return }
        stageStatus[.file] = .running
        await viewModel.runFileTransferTest(for: target)
        let result = viewModel.fileTransferTestResults[target]
        if result?.success == true {
            stageStatus[.file] = .passed
        } else {
            stageStatus[.file] = .failed(result?.failure?.errorDescription)
        }
    }

    /// Pin the presented self-signed fingerprint for the target, then re-run
    /// the gateway stage (the pinned cert now validates).
    private func trustAndRetry() {
        guard let fingerprint = presentedUntrustedFP,
              let payload = activePayload,
              let target = activeTarget else { return }
        presentedUntrustedFP = nil
        phase = .running
        Task {
            await SettingsManager.shared.setRemoteAgentCertFingerprint(fingerprint, for: target)
            await runGatewayStage(payload, target: target)
            phase = .done
        }
    }

    /// Recovery "Try again": re-run ONLY the connectivity stages on the
    /// already-saved config (Stage 1 save is NOT redone). Resets the gateway
    /// (and file, if present) rows to pending and re-drives `runGatewayStage`,
    /// which itself chains the file stage on a terminal gateway outcome and
    /// still pauses on a fresh `.untrustedCert`.
    private func retryStages() {
        guard let payload = activePayload, let target = activeTarget else { return }
        stageStatus[.gateway] = .pending
        if payload.fileServer != nil { stageStatus[.file] = .pending }
        presentedUntrustedFP = nil
        phase = .running
        Task {
            await runGatewayStage(payload, target: target)
            phase = .done
        }
    }

    /// Recovery "Back to instructions": return to the paste/scan input without
    /// disturbing the saved config. Re-arms the scanner and clears any stale
    /// inline error.
    private func backToInstructions() {
        inlineError = nil
        phase = .input
        restartScanner()
    }

    // MARK: - Progress step (staged checklist)

    @ViewBuilder
    private var progressSections: some View {
        if activePayload?.transport == .tailscale {
            tailscaleCalloutSection
        }
        Section {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(visibleStages, id: \.self) { stage in
                    stageRow(stage)
                }
                // `phase == .done` = the run has PAUSED on the amber row. Gating
                // on it keeps the card off screen during a trust-and-retry
                // re-run, which clears `presentedUntrustedFP` before the stage
                // flips back to `.running`.
                if stageStatus[.gateway] == .untrustedCert, phase == .done {
                    tofuCard
                }
            }
            .padding(.vertical, 4)
        }

        // Recovery path: a TERMINAL non-cert gateway failure (NOT
        // `.untrustedCert`, which keeps its own trust-and-retry). The save
        // already committed, so these actions never re-persist the config.
        if phase == .done, gatewayFailedTerminally {
            recoverySection
        }
    }

    /// True iff the gateway stage ended in a hard `.failed` (drives the
    /// recovery section). `.untrustedCert` and `.passed`/`.running`/`.pending`
    /// all read false — recovery never shadows the trust-retry or a success.
    private var gatewayFailedTerminally: Bool {
        if case .failed = stageStatus[.gateway] ?? .pending { return true }
        return false
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
                    retryStages()
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
                    backToInstructions()
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

    private var visibleStages: [StageID] {
        activePayload?.fileServer != nil ? [.save, .gateway, .file] : [.save, .gateway]
    }

    /// Tailnet heads-up shown ABOVE the checklist: the connection test will
    /// fail unless this device is on the same tailnet.
    ///
    /// The Private Relay line earns its place because that failure is
    /// INDISTINGUISHABLE from a dead gateway at every layer the user can see:
    /// Tailscale reports connected, its own DNS screen reports "Using Tailscale
    /// DNS", and the tunnel genuinely carries traffic — but the relay resolves a
    /// `.ts.net` name on the public internet, which for a tailnet-only serve
    /// yields a Funnel ingress address that answers on no port the app uses.
    /// Both checklist rows then fail as unreachable and send the user to inspect
    /// a healthy gateway. Private Relay is ON by default for iCloud+, and
    /// Tailscale is the transport this app recommends, so the intersection is
    /// common rather than exotic.
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
    private func stageRow(_ stage: StageID) -> some View {
        let status = stageStatus[stage] ?? .pending
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
    private func statusGlyph(for status: StageStatus) -> some View {
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

    private func stageTitle(_ stage: StageID) -> LocalizedStringResource {
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

    private func detailText(for status: StageStatus) -> String? {
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

    private func detailColor(for status: StageStatus) -> Color {
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
    // after. One-tap TOFU (no separate review sheet) is the blessed pattern here
    // — `STTTestSuiteResultView` ships the same shape — and this card mirrors it:
    // explanatory body copy + the captured SPKI fingerprint inline + the action.
    // The fingerprint is a PUBLIC value, so rendering it leaks nothing.
    //
    // The contradiction line is the signal a user can actually act on. A
    // `conduck-connect` payload that carries `certFP` (or declares the
    // self-signed transport) means the wizard expected an untrusted cert here,
    // and a pin already set makes this state unreachable anyway
    // (`classifyTransportError(hasPin: true, …)` never returns `.untrustedCert`).
    // So reaching TOFU during an import of a payload with NO `certFP` means the
    // wizard read the gateway's cert as publicly trusted while this device
    // rejects it — a disagreement worth naming, because interception is one of
    // the things that produces it.
    @ViewBuilder
    private var tofuCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fingerprint = presentedUntrustedFP, !fingerprint.isEmpty {
                Text(LocalizedStringResource(
                    "settings.pairing.tofu.body",
                    defaultValue: "This gateway presented a self-signed certificate this device doesn't recognize. Trusting it pins this exact certificate on this device — from then on Conduck accepts only this one."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if unexpectedSelfSignedCert {
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
                // No pinnable fingerprint (key algorithm outside the V1 SPKI
                // prefix table) — there is nothing to pin, so offer no action
                // and name the two ways out instead of leaving a dead row.
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

    /// True when the pairing payload gave no reason to expect a self-signed
    /// certificate — no `certFP` AND a transport other than `.selfsigned`.
    /// `conduck-connect` computes and emits `certFP` for any self-signed gateway
    /// it detects, so its absence means the wizard saw a trusted chain.
    private var unexpectedSelfSignedCert: Bool {
        guard let payload = activePayload else { return false }
        return payload.certFP == nil && payload.transport != .selfsigned
    }

    private var trustRetryButton: some View {
        Button {
            trustAndRetry()
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

    // MARK: - Dismiss

    /// Fire `onImported` exactly once, for ANY target (locked OR free/minted),
    /// passing the ref the import landed on (`activeTarget`). Fires the moment a
    /// save succeeds (from `runStages`) and again as a fallback from
    /// `handleDisappear`; the `importedHookFired` latch makes the second call a
    /// no-op. There is no `lockedTarget` gate — a free-target host (gateway list,
    /// guided setup) needs the in-session connect signal too, and locked-target
    /// hosts still fire (now with a ref they can ignore).
    private func fireImportedHookIfNeeded() {
        guard saveSucceeded, !importedHookFired, let target = activeTarget else { return }
        importedHookFired = true
        onImported?(target)
    }

    /// Fire `onConnected` exactly once, only when the gateway stage actually
    /// PASSED (verified connection, not a mere save). Fires eagerly from
    /// `runGatewayStage` and as a fallback from `handleDisappear`; the
    /// `connectedHookFired` latch de-dupes. Guided setup keys its "Connected"
    /// success screen on this — a save that never verifies must not fire it.
    private func fireConnectedHookIfNeeded() {
        guard gatewayConnected, !connectedHookFired, let target = activeTarget else { return }
        connectedHookFired = true
        onConnected?(target)
    }

    /// Runs on EVERY dismissal path (Done, toolbar Cancel, swipe-down): clears
    /// the secret-bearing paste buffer, then fires each host hook as a FALLBACK
    /// (both are normally fired eagerly during the stage run). The latches make a
    /// second call here a no-op, so a hook can never double-fire.
    private func handleDisappear() {
        pastedCode = ""
        fireImportedHookIfNeeded()
        fireConnectedHookIfNeeded()
    }
}

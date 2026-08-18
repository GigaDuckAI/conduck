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
// PRIVACY (docs/ai-context/spec.md): the pasted/scanned string embeds the
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

    /// Picks which of the code field's two renderings is on screen: the real
    /// `TextField` while it holds focus, the masked read-only stand-in at rest.
    /// Purely a View concern — the flow owns the string itself.
    @FocusState private var codeFieldFocused: Bool

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        @Bindable var flow = flow
        return NavigationStack {
            // `PlatformSettingsForm`: ONE section tree, rendered as hand-drawn
            // `SettingsCard`s on macOS (where it also supplies the scroll
            // surface and the window gutter a `Form` gives for free) and as the
            // grouped `Form` everywhere else. Each row below
            // carries its own inset via a `SettingsCard` row primitive, because
            // the card adds none — and `.listRowInsets` / `.listRowBackground`
            // reach nothing there, since a card row is not a `List` row.
            PlatformSettingsForm {
                switch flow.phase {
                case .input:
                    inputSections
                case .review:
                    reviewSections
                case .running, .done:
                    progressSections
                }
            }
            .scrollContentBackground(.hidden)
            // App-wide standard: a Form hosting text input must let a drag
            // dismiss the keyboard, or the iOS user is trapped behind it.
            .scrollDismissesKeyboard(.interactively)
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
                    confirmationAction
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

    /// The sheet's trailing action. `.done` offers Done everywhere; on macOS the
    /// INPUT step also puts Import here, because `.confirmationAction`
    /// bottom-docks inside a macOS sheet — with Import inline instead, `Cancel`
    /// occupied the default-button slot and the primary action sat somewhere
    /// else entirely. iOS keeps Import inline and thumb-reachable, the shape the
    /// review card's `actionSection` already uses.
    @ViewBuilder
    private var confirmationAction: some View {
        if flow.phase == .done {
            Button {
                dismiss()
            } label: {
                Text(LocalizedStringResource("settings.secret.done", defaultValue: "Done"))
                    .fontWeight(.semibold)
            }
            .keyboardShortcut(.defaultAction)
        } else {
            #if os(macOS)
            if flow.phase == .input {
                Button {
                    submitPastedCode()
                } label: {
                    Text(LocalizedStringResource(
                        "settings.pairing.paste.import",
                        defaultValue: "Import"
                    ))
                        .fontWeight(.semibold)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImportPastedCode)
            }
            #endif
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

    /// Paste field + paste control + Import (the whole input step on macOS). The
    /// placeholder is VERBATIM — `"conduck-setup:v1:…"` is wire syntax, not prose,
    /// so it is deliberately not localized.
    private var pasteSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    codeField
                    pasteControl
                }

                if let inlineError = flow.inlineError {
                    Text(inlineError)
                        .font(.footnote)
                        .foregroundStyle(AppColors.error)
                        .fixedSize(horizontal: false, vertical: true)
                }

                #if os(iOS)
                Button {
                    submitPastedCode()
                } label: {
                    Text(LocalizedStringResource("settings.pairing.paste.import", defaultValue: "Import"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(!canImportPastedCode)
                #endif
            }
            .padding(.vertical, 4)
            // The row treatment sits on the VStack, which is invariant across
            // the code field's live/masked swap — hanging it off either
            // rendering instead would rebuild the row on every focus change and
            // put the focus hand-off at risk.
            .settingsCardPassiveRow()
            .onChange(of: flow.pastedCode) { previous, current in
                // ⌘V into the field is the ordinary gesture on macOS, where the
                // sheet hands the field first responder on open. It leaves focus
                // in place, so without this the masked rendering would not
                // appear until the user happened to click elsewhere — and seeing
                // what landed is the reason the mask exists.
                //
                // Fires only on the short → maskable transition, so it cannot
                // interrupt someone editing an already-long value: a single
                // change that jumps a short string to full-code length is a
                // paste, never typing. Nobody types 400 characters of base64.
                guard
                    PairingPayload.maskedForDisplay(previous) == previous,
                    PairingPayload.maskedForDisplay(current) != current
                else { return }
                codeFieldFocused = false
            }
        }
    }

    /// The code entry, in one of two renderings.
    ///
    /// FOCUSED (or short/empty) it is an ordinary `TextField`, so ⌘A, ⌘C, ⌘V,
    /// undo, the right-click menu and drag-and-drop all behave exactly as the
    /// platform's own text fields do — none of which survives a hand-rolled
    /// read-only substitute, which is why the mask is a resting state rather
    /// than a replacement.
    ///
    /// AT REST holding a long code it renders masked: a code runs 380-550
    /// characters, so one line shows an unreadable slice of the middle, while
    /// the head and tail are what tell the user a COMPLETE code landed rather
    /// than one truncated by a wrapped terminal.
    @ViewBuilder
    private var codeField: some View {
        @Bindable var flow = flow
        if let masked = maskedPastedCode {
            maskedCodeField(masked)
        } else {
            TextField(text: $flow.pastedCode, prompt: Text(verbatim: "conduck-setup:v1:…")) {
                Text(LocalizedStringResource(
                    "settings.pairing.entry.paste",
                    defaultValue: "Paste setup code"
                ))
            }
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
            .focused($codeFieldFocused)
            #if os(iOS)
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            // Single-line, so `.onSubmit` is reliable here — the `axis: .vertical`
            // caveat documented in `iOSMessageComposerBar` does not apply.
            .submitLabel(.go)
            .onSubmit { submitPastedCode() }
        }
    }

    /// The masked rendering to show INSTEAD of the live field, or nil to keep the
    /// field editable. Nil while focused (the user is working in it) and whenever
    /// the code is short enough that masking would change nothing — so a
    /// half-typed or non-pairing string stays fully visible, which is exactly the
    /// case where reading the actual characters is how the user spots the problem.
    private var maskedPastedCode: String? {
        guard !codeFieldFocused else { return nil }
        let trimmed = flow.pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let masked = PairingPayload.maskedForDisplay(trimmed)
        return masked == trimmed ? nil : masked
    }

    /// At rest: the masked code styled to read as the field it stands in for,
    /// plus a clear button. Activating it hands focus back to the real field.
    private func maskedCodeField(_ masked: String) -> some View {
        HStack(spacing: 6) {
            Button {
                codeFieldFocused = true
            } label: {
                Text(masked)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    // Defensive: the mask is short, but a narrow window at an
                    // accessibility text size can still overflow it, and losing
                    // the tail from the end would undo the point of masking.
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .settingsRowButton()
            .accessibilityLabel(Text(LocalizedStringResource(
                "settings.pairing.entry.masked.a11y",
                defaultValue: "Setup code entered. Activate to edit it."
            )))

            Button {
                flow.pastedCode = ""
                codeFieldFocused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppColors.textTertiary)
            }
            .pointerIconButton(shape: .circle)
            .accessibilityLabel(Text(LocalizedStringResource(
                "settings.pairing.entry.clear",
                defaultValue: "Clear setup code"
            )))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppColors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AppColors.border, lineWidth: 1)
                )
        )
    }

    /// Paste-from-clipboard, split by platform for a behavioural reason rather
    /// than a cosmetic one: on iOS SwiftUI's `PasteButton` treats the tap itself
    /// as the consent, so it reads the clipboard WITHOUT the system
    /// "pasted from" alert a manual `UIPasteboard` read raises, and it disables
    /// itself when the clipboard holds no text. macOS has no paste-consent
    /// model, so a plain button over `Pasteboard.read()` is the native shape and
    /// matches the surrounding controls.
    @ViewBuilder
    private var pasteControl: some View {
        #if os(iOS)
        PasteButton(payloadType: String.self) { pasted in
            guard let first = pasted.first else { return }
            acceptPasted(first)
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.capsule)
        #else
        Button {
            guard let pasted = Pasteboard.read() else { return }
            acceptPasted(pasted)
        } label: {
            Label {
                Text(LocalizedStringResource(
                    "settings.pairing.entry.pasteAction",
                    defaultValue: "Paste"
                ))
            } icon: {
                Image(systemName: "doc.on.clipboard")
            }
            .font(.subheadline)
        }
        .buttonStyle(.bordered)
        #endif
    }

    /// Clipboard text becomes the draft, then focus is RESIGNED so the masked
    /// rendering is what the user lands on — looking at what arrived is the
    /// whole reason to paste here. Import stays an explicit action.
    private func acceptPasted(_ pasted: String) {
        flow.pastedCode = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        codeFieldFocused = false
    }

    private var canImportPastedCode: Bool {
        !flow.planning
            && !flow.pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Both Import affordances and the field's Return key land here. Re-entry is
    /// harmless: `handleCode` refuses unless the phase is still `.input` and no
    /// plan is already in flight, so Return racing the default button is a no-op.
    private func submitPastedCode() {
        guard canImportPastedCode else { return }
        codeFieldFocused = false
        flow.handleCode(flow.pastedCode)
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
            .settingsCardPassiveRow()
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
            // Deliberately the ONE row here with no `SettingsCard` row
            // primitive, for that same box-inside-a-box reason: the callout
            // already claims the full width and already carries its own 14pt
            // inset, so letting it fill the card's bleed makes the amber panel
            // read as the card rather than as a box floating in one. The card's
            // clip supplies the corners.
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
            .settingsCardPassiveRow()
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
                .settingsRowButton(alignment: .center)
                .foregroundStyle(Color.accentColor)
                .disabled(flow.planning)
            }
            .frame(maxWidth: .infinity)
            // Two stacked call-to-action buttons, so the row itself is passive:
            // each button owns its own affordance, and a row-level wash would
            // promise a third action the band does not have. It also supplies
            // the inset the `.listRowInsets` below gives the other platforms —
            // that modifier reaches nothing on a `SettingsCard` row.
            .settingsCardPassiveRow()
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
            // The stages stay inside ONE `VStack`, so the card sees a single
            // row: a stage appearing or disappearing mid-run then moves nothing
            // the card's between-rows separators are keyed on.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(flow.visibleStages, id: \.self) { stage in
                    stageRow(stage)
                }
            }
            .padding(.vertical, 4)
            .settingsCardPassiveRow()
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
            // A prompt plus up to three bordered recovery buttons: each control
            // is its own target, so the row supplies inset and height floor and
            // no wash.
            .settingsCardPassiveRow()
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
                .pointerLink()
            }
            .padding(.vertical, 4)
            .settingsCardPassiveRow()
            // The amber wash the `.listRowBackground` below paints on the other
            // platforms. A `SettingsCard` row is not a `List` row, so that
            // modifier reaches nothing on macOS; the passive row above has
            // already claimed the card's full bleed, so a `.background` here
            // tints exactly the same band.
            #if os(macOS)
            .background(AppColors.warning.opacity(0.10))
            #endif
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
        if case .running = status {
            ProgressView().controlSize(.small)
        } else if let symbol = status.glyphSystemImage {
            Image(systemName: symbol)
                .foregroundStyle(status.glyphTint)
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
        status.detail
    }

    private func detailColor(for status: PairingImportFlow.StageStatus) -> Color {
        status.detailTint
    }
}

// MARK: - StageStatus row presentation

/// The checklist row's glyph, tint and detail line, derived from the status
/// alone.
///
/// ON THE STATUS RATHER THAN INSIDE THE VIEW, for the reason
/// `GatewayFileLaneStatus` keeps its own label/meaning/tint here: a decision
/// buried in a `private` view method cannot be asserted without rendering the
/// sheet, and this particular decision — whether a pass draws a green tick or an
/// amber triangle — is one the spec constrains and a test has to be able to
/// pin.
extension PairingImportFlow.StageStatus {

    /// SF Symbol for the leading glyph. Nil for `.running`, whose slot holds a
    /// spinner instead of a symbol.
    ///
    /// FOUR ANSWERS FOR FOUR STATES, and the fourth is the whole point: a pass
    /// carrying a caveat draws the AMBER TRIANGLE, never the green tick. Same
    /// symbol and same tint as `FileTransferStageChecklist`'s `.unsupported` row
    /// and the `readyUploadsOnly` badge on the gateway editor and the File
    /// transfer page — a user meets this one fact on three screens during one
    /// setup, and a green seal here would leave this sheet the only surface
    /// claiming both directions on a server that has one.
    var glyphSystemImage: String? {
        switch self {
        case .pending: return "circle"
        case .running: return nil
        case .passed(let caveat): return caveat == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var glyphTint: Color {
        switch self {
        case .pending, .running: return AppColors.textTertiary
        case .passed(let caveat): return caveat == nil ? AppColors.success : AppColors.warning
        case .failed: return AppColors.error
        }
    }

    /// The sentence under the row title. A caveat is rendered VERBATIM, not
    /// re-worded here: it arrives as `PairingImportFlow.uploadOnlyCaveat`, built
    /// from the same string key the File transfer page's own checklist uses, so
    /// the two checklists a user sees during one setup describe the same server
    /// in the same words.
    var detail: String? {
        switch self {
        case .failed(let message, _): return message
        case .passed(let caveat): return caveat
        case .pending, .running: return nil
        }
    }

    /// A caveat is not a failure, so it stays out of the red the failure text
    /// uses — `FileTransferStageChecklist.detailTint` draws the same distinction
    /// for the same sentence. Secondary rather than tertiary because this line is
    /// the only thing on screen naming a limitation the user has to live with,
    /// and the tertiary tint reads as incidental.
    var detailTint: Color {
        switch self {
        case .failed: return AppColors.error
        case .passed(let caveat): return caveat == nil ? AppColors.textTertiary : AppColors.textSecondary
        case .pending, .running: return AppColors.textTertiary
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

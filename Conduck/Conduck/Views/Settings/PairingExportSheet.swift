// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingExportSheet.swift
//
// The INVERSE of `PairingImportSheet`: an already-paired device RE-SHOWS its
// `conduck-setup:v1` code (QR + paste string) so a NEW device (e.g. an Android
// phone with a byte-compatible importer) can scan it without re-running
// `conduck-connect` on the server. The code is built by `PairingPayloadExport`
// from the ref's stored config; this sheet only reveals it — behind a step-up
// auth gate, with aggressive auto-blanking.
//
// Deliberately called a SETUP CODE (a reusable password), never a "link" or a
// "single-use" / "expiring" code — it keeps working until the user rotates the
// token on their gateway. The warning copy says exactly that.
//
// PRIVACY (non-negotiable, spec.md "Privacy & Security"): the code embeds the gateway
// token + file-server credential. It is NEVER logged, and it lives in memory
// ONLY while revealed — cleared on auto-hide (~60 s), on resign-active /
// background, on screen capture (iOS), and on dismiss. Nothing is written to
// disk; no analytics. The QR + paste string are `.privacySensitive()` so the
// system redacts them in app-switcher snapshots.
//
// Cross-platform (iOS + macOS): one shared SwiftUI impl. macOS relies on the
// auth gate + auto-hide (no reliable screen-capture API); iOS adds
// `UIScreen.isCaptured` blanking. Face ID needs `NSFaceIDUsageDescription`
// (Conduck/Info.plist).

import SwiftUI
import LocalAuthentication
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif

struct PairingExportSheet: View {
    @Bindable var viewModel: SettingsViewModel
    let ref: RemoteAgentRef

    // MARK: - Phase

    private enum Phase: Equatable {
        /// Step-up auth prompt in flight (or about to start).
        case authenticating
        /// The device has no passcode/biometrics — confirm before revealing.
        case noLockConfirm
        /// QR + code visible.
        case revealed
        /// Hidden — an explicit tap re-authenticates and re-reveals.
        case locked(LockReason)
    }

    private enum LockReason: Equatable {
        case expired          // ~60 s auto-hide
        case backgrounded     // app resigned active
        case authFailed       // biometric / passcode failed or cancelled
        case couldNotPrepare  // building the code failed (token unreadable, …)
    }

    @State private var phase: Phase = .authenticating

    /// The setup code — held ONLY while revealed; cleared on every lock/dismiss.
    /// Never logged, never persisted.
    @State private var setupCode: String?
    @State private var qrImage: CGImage?
    @State private var preflightWarning = false
    @State private var showsTextCode = false
    @State private var copied = false
    @State private var prepareFailure: PairingExportFailure?
    @State private var autoHideTask: Task<Void, Never>?

    /// The in-flight auth + reveal Task. Held so a backgrounding can CANCEL it:
    /// otherwise an auth started before the app leaves the screen could commit
    /// `setupCode` / `phase = .revealed` while backgrounded and re-surface the
    /// code with no re-auth. Cancelled + nilled by `lock` / `blankEverything`.
    @State private var revealTask: Task<Void, Never>?

    /// Drives the no-lock confirmation alert. A DEDICATED flag, not a
    /// `phase`-derived binding: `reveal()` flips `phase` asynchronously, so a
    /// binding keyed on `phase == .noLockConfirm` would still read true when the
    /// alert closes on confirm and wrongly dismiss the whole sheet.
    @State private var showingNoLockAlert = false

    #if os(iOS)
    /// Screen is being recorded / mirrored — blank the sensitive content while true.
    @State private var screenCaptured = false

    /// Whether any connected window scene's screen is being captured / mirrored.
    /// Scans the connected scenes rather than the iOS-26-deprecated `UIScreen.main`.
    private static func anyScreenCaptured() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }
    #endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Auto-hide window — long enough to scan from another device, short enough
    /// that a walked-away-from screen doesn't sit exposed.
    private static let autoHideSeconds: UInt64 = 60

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .authenticating:
                    authenticatingSection
                case .noLockConfirm:
                    preparingPlaceholderSection
                case .revealed:
                    revealedSections
                case .locked(let reason):
                    lockedSection(reason)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(Text(LocalizedStringResource(
                "settings.pairing.export.title",
                defaultValue: "Gateway setup code"
            )))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: {
                        Text(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel"))
                    }
                }
            }
            .alert(
                Text(LocalizedStringResource(
                    "settings.pairing.export.noLock.title",
                    defaultValue: "This device has no lock"
                )),
                isPresented: $showingNoLockAlert
            ) {
                Button(role: .destructive) {
                    revealTask = Task { await reveal() }
                } label: {
                    Text(LocalizedStringResource(
                        "settings.pairing.export.noLock.confirm",
                        defaultValue: "Show code anyway"
                    ))
                }
                Button(role: .cancel) { dismiss() } label: {
                    Text(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel"))
                }
            } message: {
                Text(LocalizedStringResource(
                    "settings.pairing.export.noLock.message",
                    defaultValue: "Conduck couldn't ask for Face ID, Touch ID, or a passcode, so anyone holding this device can reveal a code that grants full access to your gateway. Set a device passcode for real protection."
                ))
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .onAppear { beginReveal() }
        .onDisappear { blankEverything() }
        .onChange(of: scenePhase) { _, newPhase in
            // Two distinct signals, deliberately handled differently:
            //
            // 1. A REVEALED screen blanks on ANY non-active phase (.inactive
            //    included). The biometric overlay itself flips scenePhase to
            //    .inactive during auth, so this is tolerant of .inactive: while
            //    revealed we'd rather over-blank than expose a walked-away screen.
            // 2. A real DEPARTURE from the app always passes through .background
            //    (the Face ID overlay only ever reaches .inactive, never
            //    .background). So on .background we lock REGARDLESS of phase —
            //    including .authenticating / .noLockConfirm — to slam shut an
            //    auth-in-flight or a pending no-lock bypass alert that could
            //    otherwise commit a reveal while the app is backgrounded. The
            //    only exception is an already-locked screen (nothing to close).
            if newPhase == .background {
                if case .locked = phase { return }
                showingNoLockAlert = false   // a pending bypass alert must not survive
                lock(.backgrounded)
            } else if newPhase != .active, case .revealed = phase {
                lock(.backgrounded)
            }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            screenCaptured = Self.anyScreenCaptured()
        }
        #endif
    }

    // MARK: - Sections

    private var authenticatingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringResource(
                    "settings.pairing.export.authenticating",
                    defaultValue: "Confirming it's you…"
                ))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.vertical, 4)
        }
    }

    /// Neutral placeholder shown behind the no-lock confirmation alert.
    private var preparingPlaceholderSection: some View {
        Section {
            Text(LocalizedStringResource(
                "settings.pairing.export.preparing",
                defaultValue: "Preparing your setup code…"
            ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var revealedSections: some View {
        warningSection
        if preflightWarning {
            preflightWarningSection
        }
        qrSection
        textCodeSection
    }

    /// The security warning — read BEFORE the code. A setup code is a reusable
    /// password; it must be treated like one.
    private var warningSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.brandAmber)
                    .accessibilityHidden(true)
                Text(LocalizedStringResource(
                    "settings.pairing.export.warning",
                    defaultValue: "This setup code is a reusable password. It contains your gateway token — anyone who scans or photographs it gets full access to this gateway, and to its file server if this code includes one. A photo or copy keeps working until you rotate the token on the gateway. If a device is lost, rotate the gateway token and the file-server password on your server, then re-pair your remaining devices."
                ))
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            Text(String(
                format: String(localized: "settings.pairing.export.forGateway",
                               defaultValue: "For %@"),
                viewModel.displayName(for: ref)
            ))
        }
    }

    /// Soft, NON-blocking preflight warning — the gateway didn't answer just now.
    private var preflightWarningSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.warning)
                    .accessibilityHidden(true)
                Text(LocalizedStringResource(
                    "settings.pairing.export.preflightWarning",
                    defaultValue: "Your gateway didn't answer just now, so this code may not work yet — your device may simply be offline. You can still show it."
                ))
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(AppColors.warning.opacity(0.10))
    }

    private var qrSection: some View {
        Section {
            VStack(spacing: 12) {
                qrContent
                Text(LocalizedStringResource(
                    "settings.pairing.export.scanHint",
                    defaultValue: "On your new device, open Conduck and go to Settings → Personal AI → Import setup code, then scan this."
                ))
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var qrContent: some View {
        #if os(iOS)
        if screenCaptured {
            capturedPlaceholder
        } else {
            qrImageView
        }
        #else
        qrImageView
        #endif
    }

    @ViewBuilder
    private var qrImageView: some View {
        if let qrImage {
            Image(decorative: qrImage, scale: 1.0)
                .interpolation(.none)   // crisp module edges when scaled
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .frame(width: 240, height: 240)
                .padding(16)            // white quiet zone around the modules
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .privacySensitive()
                .accessibilityLabel(Text(LocalizedStringResource(
                    "settings.pairing.export.qr.a11y",
                    defaultValue: "Gateway setup QR code"
                )))
        } else {
            ProgressView()
                .frame(width: 240, height: 240)
        }
    }

    #if os(iOS)
    private var capturedPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(AppColors.textTertiary)
            Text(LocalizedStringResource(
                "settings.pairing.export.captured",
                defaultValue: "Hidden while your screen is being recorded."
            ))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 240, height: 240)
        .padding(16)
        .background(AppColors.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    #endif

    /// Separately-gated paste-string reveal (the Mac import path) + copy.
    @ViewBuilder
    private var textCodeSection: some View {
        Section {
            if showsTextCode, let setupCode {
                #if os(iOS)
                if screenCaptured {
                    Text(LocalizedStringResource(
                        "settings.pairing.export.captured",
                        defaultValue: "Hidden while your screen is being recorded."
                    ))
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                } else {
                    textCodeBody(setupCode)
                }
                #else
                textCodeBody(setupCode)
                #endif
            } else {
                Button {
                    showsTextCode = true
                } label: {
                    Label(
                        LocalizedStringResource(
                            "settings.pairing.export.showText",
                            defaultValue: "Show text code"
                        ),
                        systemImage: "text.alignleft"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        } footer: {
            Text(LocalizedStringResource(
                "settings.pairing.export.textFooter",
                defaultValue: "Paste this into Conduck on a Mac, or on any device where scanning won't work."
            ))
        }
    }

    private func textCodeBody(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppColors.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .privacySensitive()
            Button {
                Pasteboard.copySensitive(code)
                copied = true
            } label: {
                Label(
                    copied
                        ? LocalizedStringResource("settings.pairing.export.copied", defaultValue: "Copied")
                        : LocalizedStringResource("settings.pairing.export.copy", defaultValue: "Copy code"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func lockedSection(_ reason: LockReason) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(AppColors.textSecondary)
                    Text(lockedTitle(reason))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                }
                Text(lockedMessage(reason))
                    .font(.footnote)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    beginReveal()
                } label: {
                    Label(
                        LocalizedStringResource(
                            "settings.pairing.export.showAgain",
                            defaultValue: "Show code"
                        ),
                        systemImage: "qrcode"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brandAmber)
            }
            .padding(.vertical, 4)
        }
    }

    private func lockedTitle(_ reason: LockReason) -> LocalizedStringResource {
        switch reason {
        case .couldNotPrepare:
            return LocalizedStringResource(
                "settings.pairing.export.couldNotPrepare.title",
                defaultValue: "Couldn't prepare the code"
            )
        default:
            return LocalizedStringResource(
                "settings.pairing.export.hidden.title",
                defaultValue: "Code hidden"
            )
        }
    }

    private func lockedMessage(_ reason: LockReason) -> LocalizedStringResource {
        switch reason {
        case .expired:
            return LocalizedStringResource(
                "settings.pairing.export.hidden.expired",
                defaultValue: "The code was hidden for safety. Show it again when you're ready to scan."
            )
        case .backgrounded:
            return LocalizedStringResource(
                "settings.pairing.export.hidden.backgrounded",
                defaultValue: "The code was hidden when Conduck left the screen. Show it again to keep scanning."
            )
        case .authFailed:
            return LocalizedStringResource(
                "settings.pairing.export.hidden.authFailed",
                defaultValue: "Conduck couldn't confirm it's you. Try again to reveal the code."
            )
        case .couldNotPrepare:
            return prepareFailure == .tokenUnavailable
                ? LocalizedStringResource(
                    "settings.pairing.export.couldNotPrepare.token",
                    defaultValue: "Conduck couldn't read this gateway's token — unlock your device and try again, or re-enter the token in the gateway's settings."
                )
                : LocalizedStringResource(
                    "settings.pairing.export.couldNotPrepare.generic",
                    defaultValue: "Conduck couldn't build a setup code for this gateway. Check it's fully configured, then try again."
                )
        }
    }

    // MARK: - Reveal flow

    /// Fresh `LAContext` per reveal (no caching). If the device genuinely has no
    /// passcode set, route to the no-lock confirmation alert instead of failing
    /// shut. Any OTHER inability to evaluate (system failure, managed
    /// restriction) must NOT offer a bypass — it locks with `.authFailed`.
    private func beginReveal() {
        autoHideTask?.cancel()
        autoHideTask = nil
        let context = LAContext()
        var authError: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        if context.canEvaluatePolicy(policy, error: &authError) {
            phase = .authenticating
            let reason = String(localized: "settings.pairing.export.auth.reason",
                                defaultValue: "Reveal your gateway setup code")
            revealTask = Task {
                let ok = await evaluate(context, policy: policy, reason: reason)
                if ok {
                    await reveal()
                } else {
                    lock(.authFailed)
                }
            }
        } else if authError?.domain == LAErrorDomain,
                  authError?.code == LAError.passcodeNotSet.rawValue {
            // ONLY "no passcode configured" earns the bypass path — the device
            // truly has no lock, so a step-up gate is impossible. Never log or
            // interpolate the error (never-log discipline).
            phase = .noLockConfirm
            showingNoLockAlert = true
        } else {
            // Every other reason (system inability, managed restriction, or a
            // nil error) fails CLOSED — do not offer a bypass. `.authFailed`'s
            // copy ("Conduck couldn't confirm it's you. Try again…") fits.
            lock(.authFailed)
        }
    }

    private func evaluate(_ context: LAContext, policy: LAPolicy, reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                // Never inspect / log the error — it can name the auth surface but
                // carries no payload; a bare success bool is all we need.
                continuation.resume(returning: success)
            }
        }
    }

    /// Build the code, render the QR, kick off the non-blocking preflight, and
    /// arm the auto-hide.
    private func reveal() async {
        preflightWarning = false
        showsTextCode = false
        copied = false
        prepareFailure = nil
        #if os(iOS)
        screenCaptured = Self.anyScreenCaptured()
        #endif

        let result = await viewModel.preparePairingExportCode(for: ref)
        // A reveal CANCELLED mid-auth (e.g. the app was backgrounded while the
        // biometric prompt was up) must never mount the code — bail before
        // touching any secret-bearing state.
        guard !Task.isCancelled else { return }
        switch result {
        case .ready(let code):
            setupCode = code
            qrImage = Self.makeQRCode(from: code)
            phase = .revealed
        case .failed(let failure):
            prepareFailure = failure
            lock(.couldNotPrepare)
            return
        }

        // Non-blocking preflight — reveal already happened; the warning appears
        // if the gateway didn't answer. Guard on still-revealed so a late probe
        // can't paint a warning over a hidden/re-locked screen.
        Task {
            let result = await viewModel.preflightPairingExport(for: ref)
            if case .revealed = phase {
                preflightWarning = (result == .unreachable)
            }
        }

        startAutoHide()
    }

    private func startAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: Self.autoHideSeconds * 1_000_000_000)
            if Task.isCancelled { return }
            lock(.expired)
        }
    }

    /// Clear the secret-bearing state and drop to a locked placeholder that an
    /// explicit tap re-reveals (re-authenticating).
    private func lock(_ reason: LockReason) {
        revealTask?.cancel()
        revealTask = nil
        autoHideTask?.cancel()
        autoHideTask = nil
        setupCode = nil
        qrImage = nil
        showsTextCode = false
        copied = false
        if reason != .couldNotPrepare { prepareFailure = nil }
        phase = .locked(reason)
    }

    /// Dismiss-time teardown: cancel the timer and wipe the code from memory.
    private func blankEverything() {
        revealTask?.cancel()
        revealTask = nil
        autoHideTask?.cancel()
        autoHideTask = nil
        setupCode = nil
        qrImage = nil
    }

    // MARK: - QR generation

    private static let ciContext = CIContext()

    /// Render a `conduck-setup:` string to a crisp black-on-white QR bitmap.
    /// Correction level M; pre-scaled 12× so `.interpolation(.none)` stays sharp
    /// at any display size. Returns nil only if CoreImage can't encode the bytes.
    private static func makeQRCode(from string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }
}

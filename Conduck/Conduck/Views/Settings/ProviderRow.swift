// SPDX-License-Identifier: Apache-2.0

// Conduck
// ProviderRow.swift
//
// One row per STT provider in the Settings 5-row picker.
// Owns 5 visual states (empty / stored-inactive / stored-active / validating
// / invalid). Active row gets the `brandAmber` accent + an "Active" badge;
// other rows expose a "Set as Active" radio-style affordance.
//
// Privacy: the raw API key only enters the View via the `SecureField` and
// flows out through `onPasteKey`. It is NEVER stored back into the row's
// own state. `maskedTail` only ever sees the persisted key (passed in via
// `state`), and even there reveals only the last 4 chars.
//
// User-facing literals are marked with `// xcstrings` for the
// localization sweep.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Row State

/// The 5 visual states a `ProviderRow` can render. Owned by the parent View
/// (a `ForEach` over `STTProviderRegistry.all` inside `SettingsView`) which
/// derives each row's state from `SettingsViewModel.rowState(for:)`.
enum ProviderRowState: Equatable {
    /// No key stored for this provider yet — prompt with a SecureField.
    case empty
    /// Key stored but this provider is NOT the active preset — show masked
    /// tail + "Set as Active" + "Clear key".
    case storedInactive(maskedTail: String)
    /// Key stored AND this provider IS the active preset — show masked tail
    /// + "Active" badge + "Clear key".
    case storedActive(maskedTail: String)
    /// Validation probe in flight — spinner + "Checking…".
    case validating
    /// Validation failed — red error message + "Try again" affordance.
    case invalid(message: String)
}

// MARK: - Masked-Tail Helper

/// Render a privacy-preserving display string for a stored API key. Reveals
/// only the last 4 chars; pads with bullets so total length is fixed.
/// Defense-in-depth: keys with <8 chars (almost certainly typos or
/// placeholders) render as all-bullets so we don't leak the entire string.
func maskedTail(_ key: String) -> String {
    guard key.count >= 8 else {
        return String(repeating: "•", count: max(key.count, 1))
    }
    return "••••••••" + String(key.suffix(4))
}

// MARK: - ProviderConfigBody (shared)

/// The full per-provider configuration surface — header (name + active
/// badge) · cloud-key OR Apple-model state body · pricing/language/quirk
/// footer · Apple "Manage in iOS Settings" confirmation alert. Extracted
/// from `ProviderRow` so the iOS `STTProviderDetailView` (3rd-level push)
/// renders the identical config without cloning the cloud/Apple branch.
///
/// Stateless w.r.t. persistence; owns only the transient SecureField
/// buffer + delete-confirm alert flag (both UI-local, never persisted).
struct ProviderConfigBody: View {

    /// Which slice of the config surface to render. The capability-first vendor
    /// detail mounts `.access` (the shared key) in its Provider Access section
    /// and `.capabilitySTT` (activation + test + advanced) in its Speech-to-Text
    /// section, so the old 3-button `storedRow` cluster is REDISTRIBUTED across
    /// two sections (no overflow). `.full` keeps the legacy single-block layout
    /// for the macOS flat `SettingsView` picker + the `#Preview`.
    enum Mode {
        /// Header + key surface (cloud SecureField/Validate&Save/masked tail +
        /// Clear-on-own-line / Apple model lifecycle) + footer. No activation,
        /// no Test, no Advanced.
        case access
        /// Test connection + Advanced model override. No key surface.
        case capabilitySTT
        /// Everything in one block (legacy flat picker + preview).
        case full
    }

    var mode: Mode = .full

    let metadata: STTProviderMetadata
    let state: ProviderRowState
    let onPasteKey: (String) -> Void
    let onSetActive: () -> Void
    let onClear: () -> Void

    /// Does clearing this vendor's key ALSO fall the active TTS pointer back to
    /// the Apple voice — i.e. is the active TTS provider reading this vendor's
    /// shared key slot? Feeds `clearKeyConfirmMessage` only.
    ///
    /// A separate input rather than something derived from `state`, because
    /// `state` answers the STT question and the two pointers move
    /// independently: the vendor can be the active VOICE while some other
    /// provider does the dictation, which renders as `.storedInactive` while
    /// clearing still switches the user's reply voice. Callers pass
    /// `SettingsViewModel.clearingKeyResetsActiveTTS(for:)`, the same predicate
    /// `clearKey(for:)` acts on. Defaults to `false` so the previews and the
    /// legacy `.full` picker (neither renders Clear key) compile unchanged.
    var clearAlsoResetsTTS: Bool = false

    var appleModelState: AppleModelInstallState? = nil
    var onDownloadAppleModel: (() -> Void)? = nil
    var onDeleteAppleModel: (() -> Void)? = nil

    /// Re-test a STORED key against its auth endpoint (Apple = TCC re-check).
    /// nil → no "Test Connection" affordance (e.g. the legacy inline
    /// `ProviderRow` preview / `SettingsView`).
    var onTest: (() -> Void)? = nil
    /// Inline re-test outcome shown beneath the stored row. nil / `.unset` →
    /// nothing rendered. Kept separate from `state` so a failed re-test does
    /// NOT collapse the row back to the paste-a-key UI.
    var retestState: KeyValidationState? = nil

    // MARK: - Custom model override (Feature 1) — optional parameters
    //
    // Surfaced ONLY in the `.storedInactive` / `.storedActive` arms AND only
    // for network providers (`!metadata.isOnDevice`). Additive (nil-defaulted)
    // so the existing call sites (`SettingsView` inline preview) compile
    // unchanged.

    /// The provider's currently-stored model override (nil = none → default).
    /// Seeds the Advanced `TextField`'s buffer.
    var currentCustomModel: String? = nil
    /// The provider's pinned default model string — used as the Advanced field
    /// placeholder so the View never imports the wire registry.
    var defaultModelPlaceholder: String? = nil
    /// Save callback for the Advanced model field. nil → the Advanced section
    /// is withheld (no way to persist).
    var onSaveCustomModel: ((String) -> Void)? = nil

    // MARK: - Rich Test Connection (Feature 3) — optional parameters

    /// Cloud "Record a test" surface, injected by the capability-first vendor
    /// detail. When non-nil it REPLACES the cheap "Test Connection" button in the
    /// `.capabilitySTT` section (a real record→transcribe audition supersedes the
    /// hollow key-check; the cheap check still lives in Provider Access). Nil →
    /// the legacy Test Connection action renders (`.full` mode, `#Preview`).
    /// `AnyView` keeps `ProviderConfigBody` decoupled from `CloudSTTTester`.
    var sttRecordTest: AnyView? = nil

    /// Local buffer for the SecureField in `.empty` / `.invalid` states.
    /// Cleared after `onPasteKey` fires. Never persisted; the only consumer
    /// is the parent ViewModel's validate-and-save path.
    @State private var pendingKey: String = ""

    /// Confirmation alert state for the Apple "Manage in iOS Settings"
    /// CTA. Apple has no public uninstall API — the alert directs the
    /// user to the iOS Settings → General → iPhone Storage system path.
    @State private var showingDeleteConfirm: Bool = false

    /// Confirmation flag for the Provider Access "Clear key" destructive control.
    @State private var showingClearConfirm: Bool = false

    /// Local buffer for the Advanced model-override `TextField` (the shared
    /// `AdvancedModelDisclosure`). Seeded from `currentCustomModel` on appear;
    /// persisted via `onSaveCustomModel` on submit / tap. Never persisted directly.
    @State private var pendingCustomModel: String = ""

    // MARK: - Apple model "Manage" affordance (platform-aware copy)
    //
    // iOS exposes the on-device model lifecycle through Settings → General →
    // iPhone Storage, so the iOS alert deep-links there. macOS manages the
    // model automatically with no reliable per-model deletion target, so the
    // macOS alert is informational-only — no action button that would
    // dead-no-op (the prior shared copy named "iPhone Storage" + an
    // iOS-gated open, which did nothing on Mac).

    private var appleManageLabel: LocalizedStringResource {
        #if os(macOS)
        // xcstrings: apple-voice-trim
        LocalizedStringResource("settings.stt.provider.apple.delete.macos", defaultValue: "About on-device storage")
        #else
        // xcstrings: apple-voice-trim
        LocalizedStringResource("settings.stt.provider.apple.delete", defaultValue: "Manage in Settings")
        #endif
    }

    private var appleManageAlertTitle: LocalizedStringResource {
        #if os(macOS)
        // xcstrings: apple-voice-trim
        LocalizedStringResource("settings.stt.provider.apple.deleteAlert.title.macos", defaultValue: "On-device speech model")
        #else
        // xcstrings: apple-voice-trim
        LocalizedStringResource("settings.stt.provider.apple.deleteAlert.title", defaultValue: "Manage in Settings?")
        #endif
    }

    private var appleManageAlertMessage: LocalizedStringResource {
        #if os(macOS)
        // xcstrings: apple-voice-trim
        LocalizedStringResource("settings.stt.provider.apple.deleteAlert.message.macos", defaultValue: "macOS manages the on-device speech model automatically and reclaims its space when needed. There's nothing to remove here.")
        #else
        // xcstrings: apple-voice-trim
        LocalizedStringResource("settings.stt.provider.apple.deleteAlert.message", defaultValue: "iOS manages the on-device model. To remove it, open Settings, then go to General → iPhone Storage → Conduck.")
        #endif
    }

    var body: some View {
        Group {
            switch mode {
            case .full:    fullBody
            case .access:  accessBody
            case .capabilitySTT: capabilityBody
            }
        }
        .onAppear { pendingCustomModel = currentCustomModel ?? "" }
        .onChange(of: currentCustomModel) { _, newValue in
            // Keep the buffer in sync when the persisted value changes out from
            // under the field (e.g. an iCloud KVS push / a reload).
            pendingCustomModel = newValue ?? ""
        }
        .padding(.vertical, 6)
        .alert(appleManageAlertTitle, isPresented: $showingDeleteConfirm) {
            #if os(iOS)
            // xcstrings: apple-voice-trim
            Button(LocalizedStringResource("settings.stt.provider.apple.deleteAlert.openSettings", defaultValue: "Open Settings")) {
                onDeleteAppleModel?()
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(LocalizedStringResource("settings.stt.provider.apple.deleteAlert.cancel", defaultValue: "Cancel"), role: .cancel) { } // xcstrings
            #else
            // macOS: informational-only (system-managed; no per-model delete
            // target to deep-link to) — a single dismiss, never a dead action.
            // xcstrings: apple-voice-trim
            Button(LocalizedStringResource("settings.stt.provider.apple.deleteAlert.ok", defaultValue: "OK"), role: .cancel) { }
            #endif
        } message: {
            Text(appleManageAlertMessage)
        }
    }

    // MARK: - Mode bodies

    /// Legacy single-block layout (macOS flat picker + `#Preview`). Key + STT in
    /// one column; the stored arm shows the redistributed-aware combined controls
    /// via `storedControls(isActive:)`.
    @ViewBuilder
    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                headerRow
                if !metadata.isOnDevice {
                    RecommendedModelLine(model: defaultModelPlaceholder)
                }
            }
            if metadata.isOnDevice {
                appleStateBody
            } else {
                stateBody
                advancedModelSection
            }
        }
    }

    /// PROVIDER ACCESS slice — the shared key, stated once. Cloud: SecureField +
    /// Validate&Save + Get-a-key (empty) OR masked tail + check + Clear-on-own-
    /// line (stored). Apple: the on-device model-lifecycle block. No activation,
    /// no Test, no Advanced — those belong to the capability section. The
    /// recommended-model caption + the language/quirk footer are STT-specific →
    /// they moved to the Speech-to-Text section (`.capabilitySTT`), so Provider
    /// Access reads as the bare shared-key surface (the section's own "One key —
    /// both directions" footer is supplied by the parent view).
    @ViewBuilder
    private var accessBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if metadata.isOnDevice {
                appleAccessBody
            } else {
                accessStateBody
            }
        }
    }

    /// SPEECH-TO-TEXT slice — recommended-model caption + Test connection (single
    /// action) + Advanced model override. No key surface (that's in Provider
    /// Access). Apple gets the same Test (its model lifecycle is in `.access`);
    /// Apple has no cloud model caption, so the recommended-model line is
    /// cloud-only.
    @ViewBuilder
    private var capabilityBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !metadata.isOnDevice {
                RecommendedModelLine(model: defaultModelPlaceholder)
            }
            // Activation is NOT here anymore — it lives only in the top Voice
            // selectors → chooser (the single activation surface). This section is
            // pure config: the cloud "Record a test" audition (or, for callers
            // that don't inject it, the legacy Test Connection) + the per-direction
            // model override.
            if let sttRecordTest {
                sttRecordTest
            } else {
                testConnectionAction
                retestStatusLine
            }
            if !metadata.isOnDevice {
                advancedModelSection
            }
        }
    }

    // MARK: Header (name + active badge)

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(metadata.displayName)
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            if case .storedActive = state {
                Text(LocalizedStringResource("settings.stt.provider.activeBadge", defaultValue: "Active")) // xcstrings
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.background)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(AppColors.brandAmber)
                    )
            }
            Spacer()
        }
    }

    // MARK: State-specific body

    @ViewBuilder
    private var stateBody: some View {
        switch state {
        case .empty:
            entryFields(buttonLabel: LocalizedStringResource("settings.stt.provider.validateAndSave", defaultValue: "Validate & Save")) // xcstrings

        case .storedInactive(let masked):
            storedRow(masked: masked, isActive: false)

        case .storedActive(let masked):
            storedRow(masked: masked, isActive: true)

        case .validating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringResource("settings.stt.provider.checking", defaultValue: "Checking…")) // xcstrings
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }

        case .invalid(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.error)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.error)
                        .multilineTextAlignment(.leading)
                }
                entryFields(buttonLabel: LocalizedStringResource("settings.stt.provider.tryAgain", defaultValue: "Try again")) // xcstrings
            }
        }
    }

    // MARK: Provider Access state body (cloud — key once)
    //
    // The `.access` slice's cloud key surface. Empty/invalid/validating reuse
    // `stateBody`'s controls; the stored arm shows masked tail + check, then the
    // quiet destructive "Clear key" on its OWN line (never crammed beside Set-
    // Active/Test — those moved to the capability section).

    @ViewBuilder
    private var accessStateBody: some View {
        switch state {
        case .empty, .invalid, .validating:
            stateBody
        case .storedInactive(let masked), .storedActive(let masked):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                    Text(masked)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                }
                clearKeyControl
            }
        }
    }

    /// The quiet destructive "Clear key" control on its own line. Confirmation
    /// copy states it stops BOTH directions for the vendor.
    @ViewBuilder
    private var clearKeyControl: some View {
        Button(role: .destructive) {
            showingClearConfirm = true
        } label: {
            Label(LocalizedStringResource("settings.stt.provider.clearKey", defaultValue: "Clear key"),
                  systemImage: "trash")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppColors.error)
        .confirmationDialog(
            LocalizedStringResource("settings.voice.access.clearKey.title", defaultValue: "Clear this key?"),
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button(LocalizedStringResource("settings.stt.provider.clearKey", defaultValue: "Clear key"),
                   role: .destructive) {
                onClear()
            }
            Button(LocalizedStringResource("settings.stt.provider.apple.deleteAlert.cancel", defaultValue: "Cancel"),
                   role: .cancel) { }
        } message: {
            clearKeyConfirmMessage
        }
    }

    /// The STT half of the fallback question: is THIS preset the active one?
    private var clearResetsSTTPointer: Bool {
        if case .storedActive = state { return true }
        return false
    }

    /// Confirmation copy for Clear key. Clearing a vendor's key falls BOTH
    /// active pointers that read its shared key slot back to Apple — STT to
    /// `apple-on-device`, TTS to `apple-tts` (see
    /// `SettingsViewModel.clearKey(for:)`; that fallback is what stops a paired
    /// Watch from continuing to upload under the cleared key). The two pointers
    /// move INDEPENDENTLY, so the copy branches on both: a user can be listening
    /// to this vendor's voice while dictating through another, and a
    /// confirmation that doesn't name the switch it is about to make is consent
    /// to something the user was not told.
    ///
    /// `clearResetsSTTPointer` answers the STT half off `state`;
    /// `clearAlsoResetsTTS` answers the TTS half, derived by the same predicate
    /// `clearKey(for:)` acts on.
    @ViewBuilder
    private var clearKeyConfirmMessage: some View {
        switch (clearResetsSTTPointer, clearAlsoResetsTTS) {
        case (true, true):
            Text(LocalizedStringResource(
                "settings.voice.access.clearKey.message.active",
                defaultValue: "Speech-to-text and text-to-speech for \(metadata.displayName) will stop working until you add a key again. Conduck switches speech-to-text back to Apple on-device and the reply voice back to the Apple voice, on this device and on your Apple Watch."
            ))
        case (true, false):
            Text(LocalizedStringResource(
                "settings.voice.access.clearKey.message.activeSTT",
                defaultValue: "Speech-to-text and text-to-speech for \(metadata.displayName) will stop working until you add a key again. Conduck switches speech-to-text back to Apple on-device, on this device and on your Apple Watch."
            ))
        case (false, true):
            Text(LocalizedStringResource(
                "settings.voice.access.clearKey.message.activeTTS",
                defaultValue: "Speech-to-text and text-to-speech for \(metadata.displayName) will stop working until you add a key again. Conduck reads replies in the Apple voice instead, on this device and on your Apple Watch."
            ))
        case (false, false):
            Text(LocalizedStringResource(
                "settings.voice.access.clearKey.message",
                defaultValue: "Speech-to-text and text-to-speech for \(metadata.displayName) will stop working until you add a key again."
            ))
        }
    }

    // MARK: Apple Provider Access body (on-device model lifecycle only)
    //
    // The `.access` slice for Apple: the model download / "On-device · Ready" /
    // download-failed lifecycle. Activation + Test live in the capability slice,
    // so this drops the Set-Active / Manage / Test buttons that the `.full`
    // `appleStateBody` carries inline.

    @ViewBuilder
    private var appleAccessBody: some View {
        switch appleModelState ?? .notDownloaded {
        case .notDownloaded:
            HStack(spacing: 12) {
                Button {
                    onDownloadAppleModel?()
                } label: {
                    Label(LocalizedStringResource("settings.stt.provider.apple.download", defaultValue: "Download model (~100 MB per language)"), // xcstrings: apple-voice-trim
                          systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brandAmber)
                Spacer()
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(AppColors.brandAmber)
                Text(String(localized: "Downloading… \(Int(progress * 100))%"))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .installed:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                    Text(LocalizedStringResource("settings.stt.provider.apple.ready", defaultValue: "On-device · Ready"))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                }
                Button {
                    showingDeleteConfirm = true
                } label: {
                    Label(appleManageLabel, systemImage: "gear")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.textSecondary)
            }
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.error)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.error)
                        .multilineTextAlignment(.leading)
                }
                if retryable {
                    Button {
                        onDownloadAppleModel?()
                    } label: {
                        Label(LocalizedStringResource("settings.stt.provider.tryAgain", defaultValue: "Try again"),
                              systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.brandAmber)
                }
            }
        }
    }

    // MARK: Capability section — activation + Test (single actions)
    //
    // The redistributed Set-Active + Test, each on its own line (≤ one prominent
    // + one quiet per line). Activation reads as a row; Test connection is the
    // section's single quiet action.

    /// "Test connection" — the section's single action (cheap key-check via the
    /// caller's `onTest`). Legacy fallback for `.capabilitySTT` callers that don't
    /// inject a record-test slot (cloud screens now do). Quiet neutral `.bordered`.
    @ViewBuilder
    private var testConnectionAction: some View {
        if let onTest {
            Button {
                onTest()
            } label: {
                Label(LocalizedStringResource("settings.remoteAgent.testConnection.button", defaultValue: "Test Connection"),
                      systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Advanced — per-provider model override (Feature 1)
    //
    // A collapsed DisclosureGroup with a plain model `TextField`, shown for
    // every network provider (the parent withholds `onSaveCustomModel` for
    // Apple via `isOnDevice`, so Apple never renders it). Visible in ALL key
    // states — including before a key is entered — so the model can be set
    // during initial setup, it stays consistent with the custom-endpoint config
    // (which always shows its model field), and it's reachable on the unsigned
    // simulator (where the Keychain wall blocks a key from ever being stored).
    // The override is non-secret App-Group state, independent of the key. The
    // placeholder is the provider's default model string, passed down so the
    // View never imports the wire registry.

    @ViewBuilder
    private var advancedModelSection: some View {
        if let onSaveCustomModel {
            // The SHARED disclosure — the STT + TTS model fields read identically.
            // The pending buffer + appear/change seeding live on this view
            // (`pendingCustomModel`), so the binding drives the shared subview.
            AdvancedModelDisclosure(
                placeholder: defaultModelPlaceholder ?? "",
                pendingModel: $pendingCustomModel,
                onSave: onSaveCustomModel
            )
        }
    }

    // MARK: Empty / Invalid — SecureField + submit button

    @ViewBuilder
    private func entryFields(buttonLabel: LocalizedStringResource) -> some View {
        SecureField(String(localized: metadata.keyPlaceholder), text: $pendingKey)
            // No `.textContentType(.password)` — an API key isn't a website
            // login; that content type wrongly summons the Passwords autofill
            // bar + "save password?" prompt. `SecureField` masks regardless.
            #if os(iOS)
            .autocapitalization(.none)
            #endif
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .submitLabel(.go)
            .onSubmit {
                // Return submits the key (mirrors the Validate & Save button).
                let candidate = pendingKey
                guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                pendingKey = ""
                onPasteKey(candidate)
            }

        HStack {
            Button {
                let candidate = pendingKey
                pendingKey = ""
                onPasteKey(candidate)
            } label: {
                Label(buttonLabel, systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.brandAmber)
            .disabled(pendingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()

            Link(destination: metadata.consoleURL) {
                HStack(spacing: 3) {
                    Text(LocalizedStringResource("settings.stt.provider.getKey", defaultValue: "Get a key")) // xcstrings
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: Apple on-device body
    //
    // Branches on `appleModelState` rather than `state` — Apple has no
    // SecureField + "Get a key" affordance. Active-badge tinting still
    // flows through `state` so the header row's "Active" pill renders
    // correctly when the user has set Apple as the active preset.

    @ViewBuilder
    private var appleStateBody: some View {
        switch appleModelState ?? .notDownloaded {
        case .notDownloaded:
            HStack(spacing: 12) {
                Button {
                    onDownloadAppleModel?()
                } label: {
                    Label(LocalizedStringResource("settings.stt.provider.apple.download", defaultValue: "Download model (~100 MB per language)"), // xcstrings: apple-voice-trim
                          systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.brandAmber)
                Spacer()
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(AppColors.brandAmber)
                // xcstrings
                Text(String(localized: "Downloading… \(Int(progress * 100))%"))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .installed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text(LocalizedStringResource("settings.stt.provider.apple.ready", defaultValue: "On-device · Ready")) // xcstrings
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
            }
            // One button per line (see `storedRow`) — stacked so the Apple
            // installed row never overflows at iPhone width.
            if case .storedActive = state {
                // Already active — no "Set as Active" button; the header's
                // "Active" badge already signals state.
                EmptyView()
            } else {
                HStack {
                    Button {
                        onSetActive()
                    } label: {
                        Label(LocalizedStringResource("settings.stt.provider.setActive", defaultValue: "Set as Active"), // xcstrings
                              systemImage: "circle.inset.filled")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.brandAmber)
                    Spacer()
                }
            }
            HStack {
                Button {
                    showingDeleteConfirm = true
                } label: {
                    Label(appleManageLabel, systemImage: "gear")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            if onTest != nil {
                HStack {
                    Button {
                        onTest?()
                    } label: {
                        Label(LocalizedStringResource("settings.remoteAgent.testConnection.button", defaultValue: "Test Connection"),
                              systemImage: "checkmark.shield")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
            retestStatusLine
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.error)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.error)
                        .multilineTextAlignment(.leading)
                }
                // Structural failures (language unsupported) have no
                // retry path — withhold the button so the user isn't
                // sent into a second download-failed error.
                if retryable {
                    Button {
                        onDownloadAppleModel?()
                    } label: {
                        Label(LocalizedStringResource("settings.stt.provider.tryAgain", defaultValue: "Try again"), // xcstrings
                              systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.brandAmber)
                }
            }
        }
    }

    // MARK: Stored — masked tail + active/clear controls

    @ViewBuilder
    private func storedRow(masked: String, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColors.success)
            Text(masked)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
        }

        // One button per line — at iPhone width three `.bordered` buttons in a
        // single `HStack` overflow + balloon (the headline bug). Stacked, each
        // sizes to its label and never wraps. (The capability-first detail puts
        // these in separate sections; `.full` keeps them here for the flat
        // picker + preview, but still one-per-line.)
        if !isActive {
            HStack {
                Button {
                    onSetActive()
                } label: {
                    Label(LocalizedStringResource("settings.stt.provider.setActive", defaultValue: "Set as Active"), // xcstrings
                          systemImage: "circle.inset.filled")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.brandAmber)
                Spacer()
            }
        }

        if onTest != nil {
            HStack {
                Button {
                    onTest?()
                } label: {
                    Label(LocalizedStringResource("settings.remoteAgent.testConnection.button", defaultValue: "Test Connection"),
                          systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(AppColors.brandAmber)
                Spacer()
            }
        }

        HStack {
            Button(role: .destructive) {
                onClear()
            } label: {
                Label(LocalizedStringResource("settings.stt.provider.clearKey", defaultValue: "Clear key"), // xcstrings
                      systemImage: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        retestStatusLine
    }

    // MARK: Re-test status (inline; never replaces the stored row)

    @ViewBuilder
    private var retestStatusLine: some View {
        switch retestState {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringResource("settings.remoteAgent.testConnection.checking", defaultValue: "Checking…"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .valid:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Text(LocalizedStringResource("settings.remoteAgent.testConnection.success", defaultValue: "Connected"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
        case .invalid(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppColors.error)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.error)
                    .multilineTextAlignment(.leading)
            }
        case .unset, .none:
            EmptyView()
        }
    }

}

// Verifies the redistributed stored states render with no oval-button overflow:
// Provider Access (masked tail + Clear on its own line) + Speech-to-Text
// (activation row + single Test action). This is the iPhone-width case that
// used to balloon three `.bordered` buttons into one row.
#Preview("Capability split (stored)") {
    Form {
        Section("Provider Access") {
            ProviderConfigBody(
                mode: .access,
                metadata: STTProviderRegistry.openAI,
                state: .storedInactive(maskedTail: "••••••••OTwA"),
                onPasteKey: { _ in },
                onSetActive: {},
                onClear: {},
                defaultModelPlaceholder: "gpt-4o-transcribe"
            )
        }
        Section("Speech-to-Text") {
            ProviderConfigBody(
                mode: .capabilitySTT,
                metadata: STTProviderRegistry.openAI,
                state: .storedInactive(maskedTail: "••••••••OTwA"),
                onPasteKey: { _ in },
                onSetActive: {},
                onClear: {},
                onTest: {},
                defaultModelPlaceholder: "gpt-4o-transcribe",
                onSaveCustomModel: { _ in }
            )
        }
    }
    .formStyle(.grouped)
}

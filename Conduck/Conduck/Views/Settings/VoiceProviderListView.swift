// Conduck
// VoiceProviderListView.swift
//
// iOS Settings master-detail — 2nd level. The unified "Voice" sub-screen
// pushed from the Settings root "Voice" row. Pure speech CONFIG, two sections:
//   1. "Voice Setup" — the Speech-to-Text selector, the Text-to-Speech selector,
//      and a "Providers & Keys" row drilling into `VoiceProvidersListView` (the
//      provider library: built-ins + custom endpoints + the Add row). The
//      library lives off this screen so Voice stays short.
//   2. "Spoken Replies" — the notification-open auto-speak toggle, its mirror
//      seeded from the `SettingsManager` actor. (The Apple-Watch speak toggle
//      lives in the Apple Watch settings screen, not here.)
// The global Language hint lives in the STT chooser (`VoiceActiveProviderPicker`),
// not on this screen.
//
// Navigation: the screen's `navigationDestination(item: $route)` handles the
// per-direction chooser (`.chooser`) and the providers drill-in (`.providers`).
// The per-vendor detail (`.vendor`) is reached via a SCOPED String destination
// declared in TWO sibling places that never coexist — inside the chooser
// (`chooserVendorRoute`, for "Set up…") and inside `VoiceProvidersListView`
// (its own `vendorRoute`, for library rows) — so there is never a duplicate
// destination for `String` on one stack.
//
// iOS-only: master-detail is scoped to iOS/iPadOS (macOS uses MacVoiceCategory).

#if os(iOS)
import SwiftUI

/// A typed navigation route for the Voice home: a per-direction chooser
/// (`.chooser`), the provider library drill-in (`.providers`), or a direct
/// vendor-detail push (`.vendor`, the key-readiness banner's Add/Manage Key —
/// a TYPED case, not another `String` destination, so it can't collide with
/// the chooser's / library's scoped String destinations). One
/// `navigationDestination` keyed on this.
private enum VoiceRoute: Hashable {
    case chooser(VoiceDirection)
    case providers
    case vendor(String)
}

struct VoiceProviderListView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Drives the chooser + providers-library pushes off the selector / drill-in rows.
    @State private var route: VoiceRoute?

    /// Scoped vendor-detail push from the CHOOSER's "Set up…" deep-link only.
    /// Mounted on the chooser content (never the parent), so it can't collide
    /// with the providers-library's own vendor destination.
    @State private var chooserVendorRoute: String?

    /// Mirror of the notification-open spoken-reply preference, seeded from the
    /// `SettingsManager` actor in `.task`. Writes are local-first (state, then
    /// a fire-and-forget actor persist) — the `MacGeneralCategory` dock-icon
    /// idiom. (The Apple-Watch speak toggle moved to the Apple Watch screen.)
    @State private var speakReplyOnNotificationOpen = false

    var body: some View {
        Form {
            keyReadinessSection
            voiceSetupSection
            spokenRepliesSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(LocalizedStringResource(
            "settings.voice.detail.title",
            defaultValue: "Voice"
        )))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $route) { route in
            switch route {
            case .chooser(let direction):
                chooser(for: direction)
            case .providers:
                VoiceProvidersListView(viewModel: viewModel)
            case .vendor(let id):
                vendorDetail(for: id)
            }
        }
        .task {
            // Resolve the Apple row's on-disk install status so its pill +
            // tap-readiness reflect reality, not the optimistic default.
            await viewModel.checkAppleModelStatus()
            // Fresh device-local key probe on every visit — landing here is
            // the moment the readiness banner must reflect reality.
            await viewModel.refreshActiveTTSKeyProbe()
            // Seed the spoken-reply mirrors from the actor (both default OFF
            // until the stored values land).
            speakReplyOnNotificationOpen = await SettingsManager.shared.getSpeakReplyOnNotificationOpen()
        }
    }

    // MARK: - Key readiness (device-local, active TTS provider)

    /// The convergence-UX banner — present ONLY while the active TTS
    /// provider's key probes `.missing`/`.unreadable` on THIS device. See
    /// `TTSKeyReadinessBanner` for the copy contract.
    @ViewBuilder
    private var keyReadinessSection: some View {
        if let banner = viewModel.ttsKeyReadinessBanner {
            Section {
                TTSKeyReadinessBanner(
                    model: banner,
                    isRechecking: viewModel.isRecheckingTTSKey,
                    onCheckAgain: {
                        Task { await viewModel.recheckActiveTTSKey() }
                    },
                    onOpenVendor: banner.vendorID.map { id in
                        { route = .vendor(id) }
                    }
                )
            }
        }
    }

    // MARK: - Voice Setup (STT + TTS selectors + Providers & Keys)

    /// ONE unified card: the Speech-to-Text selector, the Text-to-Speech
    /// selector, and the Providers & Keys drill-in (the most important setup
    /// task, now top-level instead of buried at the bottom). The global Language
    /// hint lives in the STT chooser; the old TTS "Apple fallback" footer is
    /// dropped — the TTS chooser's own footer already restates it.
    private var voiceSetupSection: some View {
        Section {
            Button {
                route = .chooser(.stt)
            } label: {
                VoiceDirectionSelectorRow(
                    direction: .stt,
                    activeVendorName: viewModel.activeSTTVendorShortName
                )
            }
            .buttonStyle(.plain)

            Button {
                route = .chooser(.tts)
            } label: {
                VoiceDirectionSelectorRow(
                    direction: .tts,
                    activeVendorName: viewModel.activeTTSVendorShortName
                )
            }
            .buttonStyle(.plain)

            Button {
                route = .providers
            } label: {
                HStack(spacing: 12) {
                    Label(
                        LocalizedStringResource("settings.voice.providersKeys.label", defaultValue: "Providers & Keys"),
                        systemImage: "key.horizontal"
                    )
                    .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    providersKeysSummary
                        .foregroundStyle(AppColors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text(LocalizedStringResource(
                "settings.voice.setup.header",
                defaultValue: "Voice Setup"
            ))
        }
    }

    // MARK: - Spoken Replies (per-surface auto-speak toggles)

    /// A single notification-open auto-speak toggle. (The Apple-Watch speak
    /// toggle moved to the Apple Watch settings screen — a wrist-only behavior
    /// belongs there, not buried under Voice.)
    ///   - Notification-open — THIS device only (App Groups, never KVS; an iPad
    ///     can stay silent while the iPhone speaks).
    /// Header + label + footer read as ONE package: "Spoken Replies" sets the
    /// topic, so the toggle label only answers *when* ("When I open the
    /// notification") and the footer says *what* gets spoken. Framed around the
    /// notification (not an enumerated input list) so it reads identically on
    /// iPhone + iPad — iPad has no Action Button, so naming entry points would
    /// fork the copy and drift as we add headless triggers. The footer stays
    /// idiom-variant + scope-stating ("on this iPhone" / "on this iPad").
    @ViewBuilder
    private var spokenRepliesSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { speakReplyOnNotificationOpen },
                set: { newValue in
                    speakReplyOnNotificationOpen = newValue
                    Task { await SettingsManager.shared.setSpeakReplyOnNotificationOpen(newValue) }
                }
            )) {
                Text(LocalizedStringResource(
                    "settings.voice.readAloud.notificationOpen.v3",
                    defaultValue: "When I open the notification"
                ))
                .foregroundStyle(AppColors.textPrimary)
            }
            .tint(AppColors.brandAmber)
        } header: {
            Text(LocalizedStringResource(
                "settings.voice.readAloud.header",
                defaultValue: "Spoken Replies"
            ))
        } footer: {
            if DeviceCapabilities.isiPad {
                Text(LocalizedStringResource(
                    "settings.voice.readAloud.footer.ipad.v2",
                    defaultValue: "When a reply arrives as a notification, opening it reads the reply aloud on this iPad."
                ))
            } else {
                Text(LocalizedStringResource(
                    "settings.voice.readAloud.footer.v4",
                    defaultValue: "When a reply arrives as a notification, opening it reads the reply aloud on this iPhone."
                ))
            }
        }
    }

    /// Trailing summary for the Providers & Keys row — a configured-count.
    private var providersKeysSummary: Text {
        let count = viewModel.configuredVoiceVendorCount
        if count == 0 {
            return Text(LocalizedStringResource("settings.voice.providersKeys.summary.none", defaultValue: "None configured"))
        }
        return Text(LocalizedStringResource("settings.voice.providersKeys.summary.count", defaultValue: "\(count) configured"))
    }

    /// The native display name for the active language hint — `LanguageList`'s
    /// native name, or the localized "Auto-detect" when unset. Passed to the
    /// STT chooser's `VoiceLanguageHint`.
    private var languageDisplayName: String {
        guard let code = viewModel.preferredLanguage, !code.isEmpty else {
            return String(localized: "Auto-detect") // xcstrings
        }
        return LanguageList.nativeName(for: code)
    }

    // MARK: - Per-direction chooser

    @ViewBuilder
    private func chooser(for direction: VoiceDirection) -> some View {
        VoiceActiveProviderPicker(
            direction: direction,
            options: viewModel.directionOptions(for: direction),
            onActivate: { vendorID in
                guard let vendor = VoiceVendorRegistry.lookup(id: vendorID, customEndpoints: viewModel.customVoiceEndpoints) else { return }
                Task {
                    switch direction {
                    case .stt:
                        if vendor.isOnDevice {
                            // Apple — `validateAndSave("")` owns the TCC + active-flip.
                            if let presetID = vendor.sttPresetID {
                                await viewModel.validateAndSave(key: "", for: presetID)
                            }
                        } else if let presetID = vendor.sttPresetID {
                            await viewModel.setActive(presetID)
                        }
                    case .tts:
                        if let ttsID = vendor.ttsProviderID {
                            await viewModel.setActiveTTS(providerID: ttsID)
                        }
                    }
                    route = nil   // pop back to the home screen
                }
            },
            onSetUp: { vendorID in
                // Push the vendor detail via the chooser's OWN scoped destination.
                chooserVendorRoute = vendorID
            },
            // Global Language hint — STT only; TTS passes nil (double-guarded).
            languageHint: direction == .stt
                ? VoiceLanguageHint(
                    displayName: languageDisplayName,
                    code: Binding(
                        get: { viewModel.preferredLanguage ?? "" },
                        set: { newValue in
                            Task {
                                await viewModel.savePreferredLanguage(newValue.isEmpty ? nil : newValue)
                            }
                        }
                    )
                )
                : nil
        )
        .navigationDestination(item: $chooserVendorRoute) { id in
            vendorDetail(for: id)
        }
    }

    /// Per-vendor config detail builder, shared by the chooser's "Set up…" push.
    @ViewBuilder
    private func vendorDetail(for id: String) -> some View {
        if let vendor = VoiceVendorRegistry.lookup(id: id, customEndpoints: viewModel.customVoiceEndpoints) {
            VoiceProviderDetailView(viewModel: viewModel, vendor: vendor)
        }
    }
}

// MARK: - Providers & Keys library (drill-in sub-screen)

/// The provider library — built-in vendors + custom endpoints + the Add row —
/// pushed from the Voice screen's "Providers & Keys" row. Owns its OWN vendor-
/// detail destination (scoped here, never on the parent Voice screen) so the
/// parent chooser keeps its own; the two are sibling pushes that never coexist.
/// Whole-row tap → the per-vendor config detail (`VoiceProviderDetailView`);
/// activation lives ONLY in the parent's top selectors, never a library row.
private struct VoiceProvidersListView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Scoped vendor-detail push for the library rows + the Add row.
    @State private var vendorRoute: String?

    var body: some View {
        Form {
            providerSection
            customEndpointSection
            reliabilitySection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(LocalizedStringResource(
            "settings.voice.providersKeys.label",
            defaultValue: "Providers & Keys"
        )))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $vendorRoute) { id in
            if let vendor = VoiceVendorRegistry.lookup(id: id, customEndpoints: viewModel.customVoiceEndpoints) {
                VoiceProviderDetailView(viewModel: viewModel, vendor: vendor)
            }
        }
        .task {
            // Apple row install status (mirrors the parent Voice screen) so the
            // library's Apple row reads on-disk reality.
            await viewModel.checkAppleModelStatus()
        }
    }

    // MARK: - Vendor list

    /// Built-in vendors only (`!isCustom`). The user-added custom endpoints live
    /// in their own `customEndpointSection` below, separated by the Form's section
    /// divider so they read as a distinct group rather than another built-in row.
    private var providerSection: some View {
        Section {
            ForEach(viewModel.voiceProviderRows.filter { !$0.isCustom }) { row in
                vendorRow(row)
            }
        } header: {
            Text(LocalizedStringResource(
                "settings.voice.section.header",
                defaultValue: "Providers"
            ))
        } footer: {
            Text(LocalizedStringResource(
                "settings.voice.list.footer",
                defaultValue: "One key per provider unlocks both speech-to-text and text-to-speech. Tap a provider to add a key or manage it."
            ))
        }
    }

    /// User-added custom OpenAI-compatible endpoints (`isCustom`) + the "Add
    /// custom endpoint" row. The header shows even with zero customs, so the Add
    /// row always has context.
    private var customEndpointSection: some View {
        Section {
            ForEach(viewModel.voiceProviderRows.filter { $0.isCustom }) { row in
                vendorRow(row)
            }
            addCustomEndpointRow
        } header: {
            Text(LocalizedStringResource(
                "settings.voice.section.customHeader",
                defaultValue: "Custom endpoints"
            ))
        }
    }

    /// The shared collapsed "About reliability" disclosure — last section, no
    /// header (background reading, not a setting). See
    /// `VoiceReliabilityDisclosure` for the copy rationale.
    private var reliabilitySection: some View {
        Section {
            VoiceReliabilityDisclosure()
        }
    }

    /// "+ Add custom endpoint" — at the cap it's VISIBLE but disabled (never
    /// silently vanish, never error-after-filling). Tap → mint a draft → push
    /// the editor bound to its uuid (`custom_<uuid>` vendor route).
    @ViewBuilder
    private var addCustomEndpointRow: some View {
        let canAdd = viewModel.customVoiceEndpointCount < Constants.maxCustomVoiceEndpoints
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let id = viewModel.newCustomVoiceEndpointDraftID() {
                    vendorRoute = VoiceVendorRegistry.customVendorPrefix + id.uuidString.lowercased()
                }
            } label: {
                Label {
                    Text(canAdd
                        ? LocalizedStringResource("settings.voice.custom.add", defaultValue: "Add custom endpoint")
                        : LocalizedStringResource("settings.voice.custom.addAtCap", defaultValue: "Add custom endpoint (limit reached)"))
                } icon: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(canAdd ? AppColors.brandAmber : AppColors.textTertiary)
                }
                .font(.body)
                .foregroundStyle(canAdd ? AppColors.textPrimary : AppColors.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityIdentifier("settings.voice.addCustomEndpoint")
            if !canAdd {
                Text(LocalizedStringResource(
                    "settings.voice.custom.capHint",
                    defaultValue: "Delete an endpoint above to add another."
                ))
                    .font(.caption2)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func vendorRow(_ row: VoiceProviderRow) -> some View {
        // Whole-row tap → vendor config detail. Status is DISCRETE: a configured
        // vendor gets a quiet green check + full-weight name; an un-set vendor
        // gets nothing + a dimmed name (absence is the signal). Active state is
        // NOT shown here — it lives only in the top selectors. No leading radio,
        // no colored capsule, no row tint.
        let configured = [.ready, .keySaved].contains(viewModel.credentialState(for: row.vendorID))
        Button {
            vendorRoute = row.vendorID
        } label: {
            HStack(spacing: 12) {
                Text(row.displayName)
                    .font(.body)
                    .foregroundStyle(configured ? AppColors.textPrimary : AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                SettingsStatusMark(configured: configured)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
#endif

// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleVoicePicker.swift
//
// The Apple on-device voice choice in Settings (iOS + macOS):
//   - `AppleVoiceSummaryRow` — one row in the Apple vendor's Text-to-Speech
//     section: "Voice", the current choice, and a warning line when the
//     picked voice will not play. Tapping it pushes the picker.
//   - `AppleVoicePickerView` — "Automatic" (the system default voice) plus
//     every installed voice for the device language, grouped Premium →
//     Enhanced → Standard. Tapping a row picks it AND plays a sample, so the
//     list doubles as an audition; rows wait while a sample plays.
//
// Shared iOS + macOS: ONE `Section` tree rendered by `PlatformSettingsForm`,
// rows styled with `.settingsCardRowButton()` and the amber leading check of
// `VoiceActiveProviderPicker`. The pick is device-local and never syncs — see
// `Services/TTS/AppleVoice.swift`. Apple has no supported link into its voice
// download screen, so the footer names the path instead.

import SwiftUI
import AVFoundation

// MARK: - Summary row (Apple TTS section)

struct AppleVoiceSummaryRow: View {
    @Bindable var viewModel: SettingsViewModel
    let onOpen: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(LocalizedStringResource("settings.voice.apple.voice.row", defaultValue: "Voice"))
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                    Text(summary)
                        .foregroundStyle(AppColors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                if viewModel.appleVoicePickUnavailable {
                    Label(
                        LocalizedStringResource(
                            "settings.voice.apple.voice.row.unavailable",
                            defaultValue: "Voice unavailable — using the system voice"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(AppColors.warning)
                }
            }
            .contentShape(Rectangle())
        }
        .settingsCardRowButton()
        .task { viewModel.refreshAppleVoices() }
        // Back from downloading or deleting a voice in the system settings.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.refreshAppleVoices() }
        }
    }

    private var summary: String {
        guard viewModel.appleVoicePickID != nil else {
            return String(localized: "settings.voice.apple.voice.automatic", defaultValue: "Automatic")
        }
        guard let voice = viewModel.appleVoicePick else {
            return String(localized: "settings.voice.apple.voice.summary.missing", defaultValue: "Not installed")
        }
        return AppleVoiceLabels.summary(for: voice)
    }
}

// MARK: - Picker screen

struct AppleVoicePickerView: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.scenePhase) private var scenePhase

    /// The row whose sample is playing — drives its spinner.
    @State private var auditioningID: String?
    /// Distinguishes "Automatic" from "no row" in `auditioningID`.
    private static let automaticRowID = "__automatic__"

    private var isPlaying: Bool {
        viewModel.ttsPreviewStates[TTSProvider.appleTTS.id] == .checking
    }

    var body: some View {
        PlatformSettingsForm {
            Section {
                row(
                    id: Self.automaticRowID,
                    title: String(localized: "settings.voice.apple.voice.automatic", defaultValue: "Automatic"),
                    subtitle: String(
                        localized: "settings.voice.apple.voice.automatic.subtitle",
                        defaultValue: "Your device's default voice"
                    ),
                    selected: viewModel.appleVoicePickID == nil,
                    unavailable: false
                ) {
                    await viewModel.selectAppleVoice(nil)
                }
            } footer: {
                statusFooter
            }

            ForEach(qualityGroups, id: \.quality) { group in
                Section {
                    ForEach(group.voices) { voice in
                        row(
                            id: voice.identifier,
                            title: voice.name,
                            subtitle: AppleVoiceLabels.language(for: voice),
                            selected: viewModel.appleVoicePickID == voice.identifier,
                            unavailable: viewModel.appleVoicePickID == voice.identifier
                                && viewModel.appleVoicePickUnavailable
                        ) {
                            await viewModel.selectAppleVoice(voice.identifier)
                        }
                    }
                } header: {
                    Text(AppleVoiceLabels.sectionTitle(for: group.quality))
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text(downloadHint)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .navigationTitle(Text(LocalizedStringResource("settings.voice.apple.voice.title", defaultValue: "Voice")))
        .navigationBarTitleDisplayMode(.inline)
        #else
        .macSettingsSubScreenChrome(
            title: String(localized: "settings.voice.apple.voice.title", defaultValue: "Voice")
        )
        #endif
        .task { viewModel.refreshAppleVoices() }
        // Downloads finish, and deletions land, while the user is in the
        // system Settings app — re-read on the way back and on the system's
        // own change signal. A changed voice list also expires an unavailable
        // mark by itself (`AppleVoicePreferences`), picker open or not.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.refreshAppleVoices() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: AVSpeechSynthesizer.availableVoicesDidChangeNotification
        )) { _ in
            viewModel.refreshAppleVoices()
        }
    }

    // MARK: - Rows

    private func row(
        id: String,
        title: String,
        subtitle: String,
        selected: Bool,
        unavailable: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            auditioningID = id
            Task {
                await action()
                if auditioningID == id { auditioningID = nil }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppColors.brandAmber)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 18, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                if auditioningID == id && isPlaying {
                    ProgressView().controlSize(.small)
                } else if unavailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "settings.voice.apple.voice.row.unavailable.a11y",
                            defaultValue: "Unavailable"
                        )))
                }
            }
            .contentShape(Rectangle())
        }
        .settingsCardRowButton()
        // One sample at a time: a second tap would supersede the first
        // preview mid-flight and strand its result.
        .disabled(isPlaying)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Footers

    @ViewBuilder
    private var statusFooter: some View {
        if case .invalid(let message) = viewModel.ttsPreviewStates[TTSProvider.appleTTS.id] {
            Text(message)
                .font(.caption)
                .foregroundStyle(AppColors.error)
        } else if viewModel.appleVoicePickUnavailable {
            Text(SettingsViewModel.appleVoiceUnavailableMessage)
                .font(.caption)
                .foregroundStyle(AppColors.warning)
        } else {
            Text(LocalizedStringResource(
                "settings.voice.apple.voice.footer",
                defaultValue: "Tap a voice to hear it. Your choice applies to replies in your device's language on this device."
            ))
            .font(.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
    }

    private var downloadHint: LocalizedStringResource {
        #if os(macOS)
        LocalizedStringResource(
            "settings.voice.apple.voice.download.mac",
            defaultValue: "For more natural voices, download Enhanced or Premium voices in System Settings → Accessibility → Read & Speak, using the info button next to System Voice. Siri voices aren't available to other apps."
        )
        #else
        LocalizedStringResource(
            "settings.voice.apple.voice.download.ios",
            defaultValue: "For more natural voices, download Enhanced or Premium voices in Settings → Accessibility → Read & Speak → Voices. Siri voices aren't available to other apps."
        )
        #endif
    }

    // MARK: - Grouping

    private struct QualityGroup {
        let quality: AppleVoiceDescriptor.Quality
        let voices: [AppleVoiceDescriptor]
    }

    /// Premium → Enhanced → Standard, each non-empty; the options are
    /// already sorted best-first by `AppleVoiceCatalog.candidates`.
    private var qualityGroups: [QualityGroup] {
        [AppleVoiceDescriptor.Quality.premium, .enhanced, .standard].compactMap { quality in
            let voices = viewModel.appleVoiceOptions.filter { $0.quality == quality }
            return voices.isEmpty ? nil : QualityGroup(quality: quality, voices: voices)
        }
    }
}

// MARK: - Labels

enum AppleVoiceLabels {

    /// "Ava (Premium)", "Daniel (Enhanced)", or the bare name for a standard
    /// voice.
    static func summary(for voice: AppleVoiceDescriptor) -> String {
        switch voice.quality {
        case .premium:
            return String(
                localized: "settings.voice.apple.voice.summary.premium",
                defaultValue: "\(voice.name) (Premium)"
            )
        case .enhanced:
            return String(
                localized: "settings.voice.apple.voice.summary.enhanced",
                defaultValue: "\(voice.name) (Enhanced)"
            )
        case .standard:
            return voice.name
        }
    }

    /// The voice's language in the user's own language ("English (United
    /// Kingdom)") — tells an en-GB user which voices are American.
    static func language(for voice: AppleVoiceDescriptor) -> String {
        Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
    }

    static func sectionTitle(for quality: AppleVoiceDescriptor.Quality) -> LocalizedStringResource {
        switch quality {
        case .premium:
            return LocalizedStringResource("settings.voice.apple.voice.section.premium", defaultValue: "Premium")
        case .enhanced:
            return LocalizedStringResource("settings.voice.apple.voice.section.enhanced", defaultValue: "Enhanced")
        case .standard:
            return LocalizedStringResource("settings.voice.apple.voice.section.standard", defaultValue: "Standard")
        }
    }
}

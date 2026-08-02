// SPDX-License-Identifier: Apache-2.0

// Conduck
// VoiceActiveProviderPicker.swift
//
// Capability-first Voice home — the per-direction provider chooser pushed from a
// `VoiceDirectionSelectorRow`. Lists every vendor for one direction (`.stt` /
// `.tts`):
//   - configured        → tappable; amber check on the current active one.
//                          Tap → `onActivate(vendorID)` then pop.
//   - not configured     → "Set up…" → `onSetUp(vendorID)` pushes that vendor's
//                          detail (NEVER silently activates a keyless cloud row).
//   - not capable (Soon) → disabled "Soon" row (Qwen TTS).
//   - Apple              → always present + keyless → always activatable.
//
// Shared iOS + macOS: one grouped-`Form` branch serves both platforms (macOS
// adopts the iOS idiom for consistency; only the iOS-only nav-bar display mode
// is gated). The caller owns activation (`setActive`/`setActiveTTS`) and the
// deep-link; this view derives nothing and does no actor hop.

import SwiftUI

/// Optional Language-hint config, passed by the caller for the `.stt` direction
/// ONLY (TTS passes `nil`). Keeps the picker presentational — the caller owns
/// the display-name derivation + the persistence binding; the picker just owns
/// the row + its sheet. The TTS chooser never receives one (double-guarded with
/// the `direction == .stt` body check).
struct VoiceLanguageHint {
    let displayName: String      // caller precomputes (LanguageList.nativeName | "Auto-detect")
    let code: Binding<String>    // existing get/set → savePreferredLanguage
}

struct VoiceActiveProviderPicker: View {
    let direction: VoiceDirection
    let options: [VoiceDirectionOption]
    /// Activate a configured vendor for this direction (then pop).
    let onActivate: (String) -> Void
    /// Deep-link into an unconfigured vendor's detail to set it up.
    let onSetUp: (String) -> Void
    /// Global STT language hint — supplied ONLY for `.stt`; `nil` for `.tts`.
    var languageHint: VoiceLanguageHint? = nil

    /// Language-hint picker sheet (relocated from the Voice home screen). Strictly
    /// local @State so it never collides with the chooser's vendor-detail push.
    @State private var showingLanguagePicker = false

    private var navTitle: LocalizedStringResource {
        switch direction {
        case .stt:
            return LocalizedStringResource("settings.voice.chooser.stt.title", defaultValue: "Speech-to-Text")
        case .tts:
            return LocalizedStringResource("settings.voice.chooser.tts.title", defaultValue: "Text-to-Speech")
        }
    }

    private var footer: LocalizedStringResource {
        switch direction {
        case .stt:
            return LocalizedStringResource(
                "settings.voice.chooser.stt.footer",
                defaultValue: "Pick which provider listens. Providers without a key open their setup screen."
            )
        case .tts:
            return LocalizedStringResource(
                "settings.voice.chooser.tts.footer",
                defaultValue: "Pick which provider speaks replies. Apple is the offline fallback when a provider is unavailable."
            )
        }
    }

    var body: some View {
        // Single grouped-Form branch on BOTH platforms (macOS adopts the iOS
        // idiom for consistency); only the iOS-only nav-bar display mode is gated.
        Form {
            Section {
                ForEach(options) { option in
                    optionRow(option)
                }
            } footer: {
                Text(footer)
            }

            // STT-only Language hint — its OWN section below the provider list.
            // Double-guarded: the caller passes `nil` for `.tts`, AND this body
            // gates on `direction == .stt`, so TTS can NEVER show it.
            if direction == .stt, let hint = languageHint {
                Section {
                    languageRow(hint)
                } footer: {
                    Text(LocalizedStringResource(
                        "settings.voice.chooser.stt.language.footer",
                        defaultValue: "Applies to every speech-to-text provider."
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .navigationTitle(Text(navTitle))
        .navigationBarTitleDisplayMode(.inline)
        #else
        // macOS: own in-pane header (no native title-bar toolbar) so the Settings
        // sidebar never shifts on push. See `MacSettingsSubScreenChrome`.
        .macSettingsSubScreenChrome(title: String(localized: navTitle))
        #endif
        .sheet(isPresented: $showingLanguagePicker) {
            if let hint = languageHint {
                LanguagePickerView(selectedLanguageCode: hint.code)
                    #if os(macOS)
                    .frame(minWidth: 500, minHeight: 600)
                    #endif
            }
        }
    }

    // MARK: - Language hint row (STT chooser only)

    /// Globe `Label` + secondary native display name + tertiary chevron — lifted
    /// verbatim from the old Voice-home `languageRow`. Tapping opens the shared
    /// `LanguagePickerView` sheet.
    private func languageRow(_ hint: VoiceLanguageHint) -> some View {
        Button {
            showingLanguagePicker = true
        } label: {
            HStack {
                Label(LocalizedStringResource("settings.language.hint.label", defaultValue: "Language hint"),
                      systemImage: "globe")
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text(hint.displayName)
                    .foregroundStyle(AppColors.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        // `horizontalPadding: 0` keeps the row's text flush with the inert
        // "Soon" rows in the list above, which are not Buttons and get no style.
        .settingsRowButton(horizontalPadding: 0)
    }

    // MARK: - Option row (shared markup)

    @ViewBuilder
    private func optionRow(_ option: VoiceDirectionOption) -> some View {
        if !option.capable {
            // Disabled "Soon" — direction not shipped for this vendor.
            HStack(spacing: 12) {
                leadingCheck(false)
                Text(option.displayName)
                    .foregroundStyle(AppColors.textTertiary)
                Spacer()
                Text(LocalizedStringResource("settings.voice.pill.coming", defaultValue: "Soon"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .contentShape(Rectangle())
        } else if option.configured || option.isOnDevice {
            // Configured (or keyless Apple) → activate on tap. The selected row
            // carries the single amber check (sanctioned — this IS the picker).
            Button {
                onActivate(option.vendorID)
            } label: {
                HStack(spacing: 12) {
                    leadingCheck(option.active)
                    Text(option.displayName)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .settingsRowButton(horizontalPadding: 0)
        } else {
            // Not configured → deep-link to setup; never silently activates.
            Button {
                onSetUp(option.vendorID)
            } label: {
                HStack(spacing: 12) {
                    leadingCheck(false)
                    Text(option.displayName)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text(LocalizedStringResource("settings.voice.chooser.setUp", defaultValue: "Set up…"))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .settingsRowButton(horizontalPadding: 0)
        }
    }

    /// Fixed-width leading slot: an amber checkmark on the selected row, an empty
    /// slot otherwise (keeps names aligned — the iOS Settings picker idiom, no
    /// radio circles).
    private func leadingCheck(_ selected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(AppColors.brandAmber)
            .opacity(selected ? 1 : 0)
            .frame(width: 18, alignment: .leading)
    }
}

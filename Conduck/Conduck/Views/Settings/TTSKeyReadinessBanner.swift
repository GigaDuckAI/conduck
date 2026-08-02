// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSKeyReadinessBanner.swift
//
// The Voice screen's device-local key-readiness notice — the honest-signal
// half of the TTS convergence UX. Shown ONLY when the ACTIVE text-to-speech
// provider needs a key this device can't currently produce:
//   - `.missing`   — no key on THIS device (typed on another device and still
//                    riding iCloud Keychain, or never entered). Observation-
//                    phrased: sync progress is never asserted as fact (the app
//                    has no visibility into iCloud Keychain's queue).
//   - `.unreadable` — a key slot exists but the Keychain couldn't return it
//                    (locked pre-first-unlock, auth/IPC failure). Distinct
//                    copy + a "Manage Key" action (re-checking can't repair
//                    malformed data; the recovery path is the key surface).
// Both states also state the CONSEQUENCE plainly: spoken replies use Apple's
// built-in voice meanwhile (the chat contract's silent fallback, made loud).
//
// Shared iOS + macOS (mounted by `VoiceProviderListView` and
// `MacVoiceCategory`); the device word forks per idiom inside this file.

import SwiftUI

// MARK: - Presentation model

/// The banner's render input, derived from the view model's secret-free
/// `ActiveTTSKeyProbe`. Nil (no banner) whenever the active provider needs no
/// key or the key probes `.present`.
struct TTSKeyReadinessBannerModel: Equatable {
    let keyState: APIKeyState
    let providerDisplayName: String
    /// The vendor route target for Add Key / Manage Key — the vendor's config
    /// detail already owns the paste + validate surface.
    let vendorID: String?
}

@MainActor
extension SettingsViewModel {
    /// Banner derivation — pure over already-loaded state (no actor hop in
    /// `body`). Only the two locally-repairable key states surface; everything
    /// else (healthy, keyless, not-yet-probed) renders nothing.
    var ttsKeyReadinessBanner: TTSKeyReadinessBannerModel? {
        guard let probe = activeTTSKeyProbe, probe.isDegraded else { return nil }
        let vendor = VoiceVendorRegistry.vendor(
            forTTSProviderID: probe.providerID,
            customEndpoints: customVoiceEndpoints
        )
        return TTSKeyReadinessBannerModel(
            keyState: probe.keyState,
            providerDisplayName: vendor?.shortDisplayName ?? probe.providerID,
            vendorID: vendor?.id
        )
    }
}

// MARK: - Banner view

struct TTSKeyReadinessBanner: View {
    let model: TTSKeyReadinessBannerModel
    let isRechecking: Bool
    let onCheckAgain: () -> Void
    /// Push the vendor's config detail (Add Key when missing, Manage Key when
    /// unreadable). Nil when the vendor couldn't be resolved — the action row
    /// then shows Check Again only.
    let onOpenVendor: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "key.slash")
                    .foregroundStyle(AppColors.brandAmber)
            }

            Text(consequence)
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.keyState == .missing {
                Text(LocalizedStringResource(
                    "settings.voice.keyReadiness.syncHint",
                    defaultValue: "If you added the key on another device, it may not have reached this device yet."
                ))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                Button {
                    onCheckAgain()
                } label: {
                    if isRechecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(LocalizedStringResource(
                            "settings.voice.keyReadiness.checkAgain",
                            defaultValue: "Check Again"
                        ))
                    }
                }
                // `.borderless` on macOS draws bare tinted text with no bezel, so
                // the live area is the ~17pt glyph run itself. The icon primitive
                // gives a padded band plus a hover wash without adding a bezel;
                // the explicit amber reproduces exactly what `.borderless` drew
                // from the row's `.tint`, which a custom ButtonStyle's label does
                // not inherit. Safe to hard-code because the tint is this view's
                // OWN (`.tint(AppColors.brandAmber)` on the body below) rather
                // than something a host supplies — no caller can set a different
                // one. Disabled dimming comes from the style. iOS keeps
                // `.borderless` — there the style is the only thing tinting the
                // label and touch already hits the row.
                #if os(macOS)
                .pointerIconButton(horizontalPadding: 8)
                .foregroundStyle(AppColors.brandAmber)
                #else
                .buttonStyle(.borderless)
                #endif
                .disabled(isRechecking)

                if let onOpenVendor {
                    Button {
                        onOpenVendor()
                    } label: {
                        Text(model.keyState == .missing
                            ? LocalizedStringResource(
                                "settings.voice.keyReadiness.addKey",
                                defaultValue: "Add Key")
                            : LocalizedStringResource(
                                "settings.voice.keyReadiness.manageKey",
                                defaultValue: "Manage Key"))
                    }
                    // Same treatment as Check Again above.
                    #if os(macOS)
                    .pointerIconButton(horizontalPadding: 8)
                    .foregroundStyle(AppColors.brandAmber)
                    #else
                    .buttonStyle(.borderless)
                    #endif
                }
            }
            .font(.subheadline)
            .tint(AppColors.brandAmber)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.voice.keyReadinessBanner")
    }

    // MARK: - Copy (device-idiom forked)

    private var title: String {
        let name = model.providerDisplayName
        switch model.keyState {
        case .missing:
            #if os(macOS)
            return String(
                localized: "settings.voice.keyReadiness.missing.title.mac",
                defaultValue: "The \(name) key isn't available on this Mac yet."
            )
            #else
            if DeviceCapabilities.isiPad {
                return String(
                    localized: "settings.voice.keyReadiness.missing.title.ipad",
                    defaultValue: "The \(name) key isn't available on this iPad yet."
                )
            }
            return String(
                localized: "settings.voice.keyReadiness.missing.title.iphone",
                defaultValue: "The \(name) key isn't available on this iPhone yet."
            )
            #endif
        default:
            #if os(macOS)
            return String(
                localized: "settings.voice.keyReadiness.unreadable.title.mac",
                defaultValue: "Conduck couldn't read the \(name) key on this Mac right now."
            )
            #else
            if DeviceCapabilities.isiPad {
                return String(
                    localized: "settings.voice.keyReadiness.unreadable.title.ipad",
                    defaultValue: "Conduck couldn't read the \(name) key on this iPad right now."
                )
            }
            return String(
                localized: "settings.voice.keyReadiness.unreadable.title.iphone",
                defaultValue: "Conduck couldn't read the \(name) key on this iPhone right now."
            )
            #endif
        }
    }

    private var consequence: String {
        switch model.keyState {
        case .missing:
            return String(
                localized: "settings.voice.keyReadiness.missing.body",
                defaultValue: "When Conduck speaks a reply here, it uses Apple's built-in voice until the key becomes available."
            )
        default:
            return String(
                localized: "settings.voice.keyReadiness.unreadable.body",
                defaultValue: "Spoken replies use Apple's built-in voice for now."
            )
        }
    }
}

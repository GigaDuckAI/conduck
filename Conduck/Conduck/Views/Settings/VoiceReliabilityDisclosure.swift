// Conduck
// VoiceReliabilityDisclosure.swift
//
// Voice Settings — the shared "About reliability" disclosure shown at the
// bottom of the Providers & Keys library (iOS `VoiceProvidersListView` +
// macOS `MacVoiceProvidersList`). One reusable subview so the two platforms
// read IDENTICALLY (the `AdvancedModelDisclosure` extraction pattern).
//
// Collapsed by default — one quiet line for the many users who never hit a
// provider rate limit; the expanded copy exists for the one who hears a long
// reply switch to the built-in voice partway through and comes looking.
//
// The copy is deliberately EVERGREEN: no provider names, no tier names, no
// numbers. Conduck has no telemetry and cannot track when a provider changes
// its limits, so any specific claim ("provider X's free tier allows N
// requests") would rot undetectably. It states (1) WHY replies are fetched in
// several requests (latency — playback starts before the whole reply is
// synthesized), (2) the one symptom a limit produces, (3) whose knob fixes it
// (the provider's usage tier), and (4) the reassurance that replies always
// finish via the built-in-voice fallback.

import SwiftUI

/// A collapsed "About reliability" disclosure for the provider library screens.
struct VoiceReliabilityDisclosure: View {
    /// Collapsed by default — background reading, not a setting.
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(LocalizedStringResource(
                "settings.voice.reliability.body",
                defaultValue: "Long spoken replies fetch audio from your provider in several small requests, so playback starts quickly instead of waiting for the whole reply. Some providers limit how often audio can be requested — most commonly on free usage tiers. If a long reply switches to the built-in voice partway through, that's usually why; a higher usage tier at your provider prevents it. Replies always finish: Conduck falls back to the built-in voice whenever needed."
            ))
            .font(.footnote)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringResource(
                    "settings.voice.reliability.label",
                    defaultValue: "About reliability"
                ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                Text(LocalizedStringResource(
                    "settings.voice.reliability.labelHint",
                    defaultValue: "How spoken replies use your provider"
                ))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
            }
            .tappableDisclosureLabel($expanded)
        }
        .accessibilityIdentifier("settings.voice.reliabilityDisclosure")
    }
}

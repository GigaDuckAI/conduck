// SPDX-License-Identifier: Apache-2.0

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
//
// TWO IMPLEMENTATIONS, one set of strings. iOS keeps `DisclosureGroup`, where
// the whole row already toggles and hit-tests. macOS hand-rolls the expander
// and OWNS the chevron, because `DisclosureGroup` renders its chevron in a slot
// OUTSIDE the label: the label can therefore never span the row, and the row's
// leading gutter measures 21.5pt against the 10pt of the provider rows it sits
// under, so the row cannot be one uniform target while the DisclosureGroup owns
// the layout. Drawing the chevron inside a `Button` label makes the whole row
// that target AND lines it up with its neighbours — and unlike the tap gesture
// a `DisclosureGroup` label needs on macOS (`tappableDisclosureLabel`), a real
// `Button` carries keyboard activation, VoiceOver activation and a pressed
// state.

import SwiftUI

/// A collapsed "About reliability" disclosure for the provider library screens.
struct VoiceReliabilityDisclosure: View {
    /// Collapsed by default — background reading, not a setting.
    @State private var expanded: Bool = false

    var body: some View {
        #if os(macOS)
        // Row + expanded copy stacked with ZERO spacing: this whole view is one
        // row of a `SettingsCard`, so the button's own frame supplies the live
        // area and the copy below hangs off it.
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        // Driven from inside the action's `withAnimation`, so
                        // the turn rides that same transaction as the reveal
                        // below — no second animation modifier to drift out of
                        // step with it.
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        // Decoration: `disclosureLabel` already names the row,
                        // and an unlabelled glyph would otherwise be announced.
                        .accessibilityHidden(true)
                    disclosureLabel
                    Spacer()
                }
            }
            .settingsCardRowButton()
            // The button's own label reads as "About reliability, How spoken
            // replies use your provider" — deliberately NOT overridden with an
            // `.accessibilityLabel`, which would drop the subtitle. The hint
            // carries the one thing the label can't: what activating does.
            .accessibilityHint(Text(expanded ? "Collapse" : "Expand")) // xcstrings: voice-reliability

            if expanded {
                expandedCopy
                    // The copy is a passive continuation of the row, not a row
                    // of its own, so it carries the card's inset itself to line
                    // up with the button label above it.
                    .padding(.horizontal, SettingsCardMetrics.rowInset)
                    .padding(.bottom, 12)
            }
        }
        .accessibilityIdentifier("settings.voice.reliabilityDisclosure")
        #else
        DisclosureGroup(isExpanded: $expanded) {
            expandedCopy
        } label: {
            disclosureLabel
                .tappableDisclosureLabel($expanded)
        }
        .accessibilityIdentifier("settings.voice.reliabilityDisclosure")
        #endif
    }

    /// Title over hint — the row's two-line label, identical on both platforms.
    private var disclosureLabel: some View {
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
    }

    /// The expanded copy, shared by both branches so the string exists once.
    /// Platform-specific insets are applied by the call site, not here.
    private var expandedCopy: some View {
        Text(LocalizedStringResource(
            "settings.voice.reliability.body",
            defaultValue: "Long spoken replies fetch audio from your provider in several small requests, so playback starts quickly instead of waiting for the whole reply. Some providers limit how often audio can be requested — most commonly on free usage tiers. If a long reply switches to the built-in voice partway through, that's usually why; a higher usage tier at your provider prevents it. Replies always finish: Conduck falls back to the built-in voice whenever needed."
        ))
        .font(.footnote)
        .foregroundStyle(AppColors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

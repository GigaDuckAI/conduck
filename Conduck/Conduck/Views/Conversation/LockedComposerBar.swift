// Conduck
// LockedComposerBar.swift
//
// Composer-shaped CTA shown in place of the live composer when no AI gateway is
// configured. Onboarding defers gateway setup, so the user lands in the app
// unconfigured. Rather than a live text+mic field that errors on send
// (`remoteAgentNotConfigured`) — making the user discover the requirement via a
// failure — the composer becomes a single tappable button that routes to
// Settings → Personal AI. It PREVIEWS the composer affordance (so the screen
// reads as a chat client, not a settings panel) while making the error path
// impossible.
//
// Deliberately NOT a disabled / greyed text field: it stays at normal contrast
// and is exposed to VoiceOver as one ENABLED button (a disabled field is skipped
// by VoiceOver and reads as "broken" rather than "locked"). No cursor, no text
// entry, no recording, no attachment affordance, and the trailing circle uses a
// setup-forward symbol — never the live mic/send glyph — so it isn't misread as
// "tap to record".
//
// iOS-only (mirrors the `#if os(iOS)` composer it replaces). macOS / menu-bar
// fully replace their pane with the unconfigured empty state, so there is no live
// composer to gate there.

import SwiftUI

#if os(iOS)
struct LockedComposerBar: View {
    /// Fired on any tap — routes to Settings → Personal AI (the same destination
    /// as the unconfigured empty state's hero CTA).
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
                // Field-shaped placeholder with a leading lock glyph so it reads
                // gated, not empty. Matches the real composer field's fill +
                // corner radius (see `iOSMessageComposerBar.composerField`).
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textTertiary)
                    // Reads as FIELD STATUS, not a second CTA. The hero button
                    // owns the action ("Connect Your AI"); this line's only
                    // remaining job is explaining why the field is dead — an
                    // imperative here would just re-issue the same instruction in
                    // a slot that normally describes what you'd type.
                    Text(LocalizedStringResource(
                        "composer.locked.placeholder",
                        defaultValue: "Setup required to send messages"
                    ))
                    .foregroundStyle(AppColors.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    AppColors.cardBackgroundElevated,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

                // Setup-forward trailing affordance — a 44pt amber disc with a
                // forward arrow. NOT the mic (`mic.fill`) / send (`arrow.up`)
                // glyph, so it isn't read as "tap to record / send".
                ZStack {
                    Circle()
                        .fill(AppColors.brandAmber)
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Cap + center on the same readable column as the real composer.
            .frame(maxWidth: Constants.Layout.chatContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        // Expose the WHOLE bar as one enabled button; hide the decorative
        // field / glyph / circle children from VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        // The whole bar is one enabled button, so VoiceOver must announce the
        // ACTION (the label), with the reason as the hint — the sighted layout
        // conveys the action through the amber arrow disc, which VoiceOver can't see.
        .accessibilityLabel(Text(LocalizedStringResource(
            "composer.locked.a11yLabel",
            defaultValue: "Open AI setup"
        )))
        .accessibilityHint(Text(LocalizedStringResource(
            "composer.locked.a11yHint",
            defaultValue: "Setup is required before you can send messages."
        )))
        .accessibilityIdentifier("composer.locked")
    }
}
#endif

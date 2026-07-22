//
//  UnconfiguredEmptyState.swift
//  Conduck
//
//  The "no personal AI configured yet" state — the first screen a new user meets.
//

import SwiftUI

/// The SINGLE copy source for the unconfigured state. Every surface (iPhone /
/// iPad / Mac window / Mac menu-bar popover / locked composer) reads its strings
/// from here, so they cannot drift into four different phrasings of one screen
/// again.
///
/// Each element does exactly ONE job, and no job twice:
///
/// | element | job |
/// |---|---|
/// | nav title | where you are (`chat.title.unconfigured` → the app name) |
/// | headline | the concept — Conduck ships without an AI |
/// | body | the two lanes — self-hosted server vs hosted model |
/// | button | the act |
/// | locked composer | why the field is dead (a status, NOT a second CTA) |
///
/// Two things are deliberately ABSENT. **"Gateway"**: an implementation noun that
/// lumps "a server I run" and "a hosted model" under one technical term, and it
/// was the first noun a brand-new user met. It stays in Settings, where the user
/// has context for it. **"Syncs to your other devices"**: the guided chooser's
/// pinned footer already promises it on the very next screen, and it is not
/// unconditionally true (URL + token ride iCloud; certificate trust stays
/// device-local).
enum UnconfiguredCopy {
    /// The concept. The one genuinely surprising fact about Conduck — it does not
    /// come with an AI — which corrects the assumption every other chat app has
    /// trained users into. This is the only line a scanner reads, so it carries
    /// the proposition rather than echoing the button.
    static let headline = LocalizedStringResource(
        "unconfigured.empty.headline",
        defaultValue: "Bring your own AI"
    )

    /// The two lanes. Names NO vendor: "OpenRouter" is an unexplained noun to
    /// anyone who has not heard of it (and reads as a required third-party
    /// signup), while the chooser — one tap away — names it anyway. Avoids "an AI
    /// you own", which is false for the hosted lane: the user owns the key and the
    /// choice of model, not the model.
    static let body = LocalizedStringResource(
        "unconfigured.empty.body",
        defaultValue: "Choose how Conduck connects: use a server you control or a hosted model with your own API key."
    )

    /// The act — states the outcome and fits every lane. Not "Get Started" (says
    /// nothing, and onboarding just said it) and not "Choose Your AI" (implies a
    /// model catalogue, wrong for a self-hoster who already picked their stack).
    static let button = LocalizedStringResource(
        "unconfigured.empty.button",
        defaultValue: "Connect Your AI"
    )

    /// Menu-bar-only tail sentence. The popover is driven by a global shortcut, so
    /// it owes the user that key — no other surface has one, which is the ONLY
    /// sanctioned per-surface copy divergence.
    static func menuBarShortcutHint(_ shortcut: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "unconfigured.empty.menuBarShortcut",
            defaultValue: "After setup, press \(shortcut) to talk."
        )
    }
}

/// Hero unconfigured empty state — iPhone, iPad, and the Mac window.
///
/// The Mac menu-bar popover does NOT reuse this view: it is a compact surface with
/// no room for a mascot and it owes the user a shortcut hint. It composes
/// `UnconfiguredCopy` into its own layout instead — shared strings, own shape.
struct UnconfiguredEmptyState: View {
    /// Shuffle-bag pose, owned by the host (`hostMascot`).
    let mascot: String
    var mascotHeight: CGFloat = 150
    /// Routes to guided setup — the same destination as the locked composer bar.
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            EmptyStateMascot(pose: mascot, height: mascotHeight)

            Text(UnconfiguredCopy.headline)
                .font(.title2.weight(.bold))
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(UnconfiguredCopy.body)
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Cap the MEASURE, not the line breaks. Uncapped, the paragraph
                // inherits the full surface width — ~1200pt on an 11" iPad — and
                // rags mid-clause, which reads as broken layout. A hard-coded
                // newline would only re-break on the 13" iPad and at large Dynamic
                // Type; a width cap wraps correctly at every size.
                .frame(maxWidth: Constants.Layout.emptyStateBodyMaxWidth)
                .padding(.horizontal, 32)

            Button(action: action) {
                Text(UnconfiguredCopy.button)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.brandAmber)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

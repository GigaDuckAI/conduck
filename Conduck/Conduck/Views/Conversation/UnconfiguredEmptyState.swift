// SPDX-License-Identifier: Apache-2.0

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

    /// The OTHER unconfigured state, and the reason this type has two: gateways
    /// work here, but the one the menu-bar quick lane sends to does not. Only the
    /// popover can reach it — every other surface offers a gateway picker and so
    /// asks `GatewayGate.canSendAnywhere` instead.
    ///
    /// Kept beside the beginner copy rather than hidden in the popover, because
    /// the two are read as alternatives and the failure mode is showing the wrong
    /// one: the pitch above tells a user with five verified gateways that they
    /// have no AI, which is both false and unactionable — nothing on that screen
    /// mentions the default.
    enum DefaultNeedsSetup {
        /// Names the SITUATION and leaves the act to the button — the shape the
        /// beginner arm above already uses ("Bring your own AI" → "Connect Your
        /// AI"). It states no fault, because there is none: the default is not
        /// reachable from this Mac, which happens when a gateway is forgotten on
        /// another device and equally when its key has not finished syncing. Not
        /// "isn't set up" — that names a chore, and only one of those two
        /// situations has one.
        static let headline = LocalizedStringResource(
            "unconfigured.defaultNeedsSetup.headline.v2",
            defaultValue: "Your default AI isn't available here"
        )

        /// Answers the question the user is actually asking — "but I set these
        /// up?" — before asking them to do anything. Scoped to the menu bar
        /// because that is the only surface affected; the window keeps working,
        /// and claiming otherwise sends them hunting a bug that isn't there.
        ///
        /// "From the menu bar", never "quick captures": the lane's internal name
        /// (Decision F's "quick lane") appears nowhere in the shipped product, and
        /// this is the one sentence whose whole job is to explain why THIS window
        /// can't send when the app plainly works. It also stays true for all four
        /// doors — ⌘⇧1, ⌘⇧2, the context-menu start, and the compose box — which
        /// "captures" does not cover.
        ///
        /// "AI" throughout, never "gateway": the prohibition at the top of this
        /// file applies here too, and one object should not pick up three names
        /// inside one paragraph. "This Mac's" is literal, not hedging — the
        /// default pointer is device-local and does not sync.
        static let body = LocalizedStringResource(
            "unconfigured.defaultNeedsSetup.body.v2",
            defaultValue: "From the menu bar, Conduck sends to this Mac's default AI — and this Mac can't reach that one. Your other AIs still work; pick one of them as the default."
        )

        /// Names the OUTCOME, like every other button on these surfaces
        /// ("Connect Your AI"), rather than the door it opens. The destination is
        /// the same Personal AI screen; the act there is choosing, not connecting.
        static let button = LocalizedStringResource(
            "unconfigured.defaultNeedsSetup.button",
            defaultValue: "Choose Default AI"
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

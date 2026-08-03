// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MacAboutCategory.swift
//
// macOS Settings → About category. Version string + Send Feedback (mailto via
// the shared `openFeedbackEmailMac`) + Privacy Policy / Terms of Service links.
//
// Sections are hand-drawn `SettingsCard`s (`MacSettingsCard.swift`), so every
// row is live edge to edge; the inset comes from each row's own style, inside
// its live frame. Nothing here pads a row from the outside — see that file's
// one rule.

import SwiftUI

struct MacAboutCategory: View {
    // Open Source Licenses opens in a sheet (native + simple — no restructuring
    // of `MacSettingsView`'s category swap), wrapping the shared `LicensesView`
    // in its own `NavigationStack` so its detail pushes work inside the modal.
    @State private var showingLicenses = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: SettingsCardMetrics.sectionSpacing) {
                    versionSection
                    aboutLinksSection
                    communitySection
                }

                // Free-floating sign-off — kept OUT of the card stack so it
                // renders on the window bg rather than inside a card (grey box).
                AboutThankYouFooter()
                    .padding(.top, 28)
                    .padding(.bottom, 24)
            }
            .padding(28)
            // The shared settings content rail — the same column every other
            // Settings category reads at, so switching categories never changes
            // the measure. On the stack INSIDE the `ScrollView` (capping the
            // ScrollView itself would strand a wide window's margins as dead,
            // unscrollable glass) and after that stack's own padding, so the
            // gutter sits inside the capped column.
            .macSettingsRail()
        }
        .sheet(isPresented: $showingLicenses) {
            NavigationStack {
                LicensesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                showingLicenses = false
                            } label: {
                                Text(LocalizedStringResource("settings.mac.done",
                                                             defaultValue: "Done"))
                            }
                        }
                    }
            }
            .frame(width: 640, height: 680)
        }
    }

    // MARK: - Version (app icon + name + version)

    private var versionSection: some View {
        SettingsCard {
            // Passive content, not a control: the PASSIVE row primitive, so
            // there is no hover wash on something a click does nothing to. It
            // supplies the inset the card withholds, from inside the row's own
            // frame — the same inset the neighbouring cards' button rows take
            // from their style.
            AppIdentityHeader()
                .settingsCardPassiveRow()
        } header: {
            Text(LocalizedStringResource("settings.mac.about.title", defaultValue: "About"))
        }
    }

    // MARK: - About links (feedback / legal) — unlabeled housekeeping

    private var aboutLinksSection: some View {
        SettingsCard {
            Button {
                openFeedbackEmailMac()
            } label: {
                rowLabel("Send Feedback", systemImage: "envelope", trailing: "arrow.up.right") // xcstrings
            }
            .settingsCardRowButton()

            // `Link`, not `Button` — no `ButtonStyle` reaches it, so these rows
            // take `.settingsCardRowLink()`: the same full-bleed live area, row
            // inset and wash `.settingsCardRowButton()` gives the `Button` rows
            // above and below, and deliberately the same ARROW cursor. These are
            // rows, not inline prose links, and the pointing hand here would
            // make one card answer the pointer three different ways. `.plain`
            // stays for the link chrome it already suppressed.
            Link(destination: URL(string: Constants.websiteURL)!) {
                rowLabel("Visit conduck.com", systemImage: "globe", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)
            .settingsCardRowLink()

            Link(destination: URL(string: Constants.privacyPolicyURL)!) {
                rowLabel("Privacy Policy", systemImage: "hand.raised", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)
            .settingsCardRowLink()

            Link(destination: URL(string: Constants.termsOfServiceURL)!) {
                rowLabel("Terms of Service", systemImage: "doc.text", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)
            .settingsCardRowLink()

            // Internal sheet (not an external link) — trailing chevron signals
            // in-app content. Apache-2.0 §4 / MIT notice preservation.
            Button {
                showingLicenses = true
            } label: {
                rowLabel(
                    LocalizedStringKey("settings.about.licenses.title"),
                    systemImage: "doc.plaintext",
                    trailing: "chevron.forward"
                )
            }
            .settingsCardRowButton()
        }
    }

    // MARK: - Community (Discord) — honestly labeled; not a support desk

    private var communitySection: some View {
        SettingsCard {
            Link(destination: URL(string: Constants.discordInviteURL)!) {
                HStack {
                    Label {
                        Text(verbatim: "Discord") // brand name — not localized
                            .foregroundStyle(AppColors.textPrimary)
                    } icon: {
                        Image("discord-logo")
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 16)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                // Hand-rolled twin of `rowLabel`'s frame + shape, for the same
                // reason: this label IS the `Link`'s live region.
                .frame(maxWidth: .infinity, minHeight: SettingsCardMetrics.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settingsCardRowLink()
        } header: {
            Text("Community") // xcstrings
        }
    }

    private func rowLabel(_ title: LocalizedStringKey, systemImage: String, trailing: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(AppColors.textPrimary)
            Spacer()
            Image(systemName: trailing)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
        // Claims the whole row from INSIDE the label, which is the only place
        // that reaches a `Link`. A `Link`'s live region is its label's laid-out
        // frame, and `.settingsCardRowLink()` frames the `Link` from OUTSIDE —
        // so the modifier's 48pt row governs the wash and the hover, while the
        // label's own ~22pt line box would govern the click, leaving ~13pt of
        // washed-but-dead band top and bottom. The `Spacer()` closes that gap
        // horizontally; this closes it vertically. Costs the `Button` rows
        // nothing: `.settingsCardRowButton()` imposes the same 48pt floor and
        // the same full width one level out.
        .frame(maxWidth: .infinity, minHeight: SettingsCardMetrics.rowMinHeight)
        // Both halves are required — a filled frame stays dead over its
        // `Spacer()` until this declares the frame hittable. The `Button` rows
        // get the same guarantee from `.settingsCardRowButton()`, whose
        // `.contentShape` sits inside the style body and therefore inside the
        // button's own region.
        .contentShape(Rectangle())
    }
}
#endif

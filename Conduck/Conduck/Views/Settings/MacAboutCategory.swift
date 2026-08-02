// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MacAboutCategory.swift
//
// macOS Settings → About category. Version string + Send Feedback (mailto via
// the shared `openFeedbackEmailMac`) + Privacy Policy / Terms of Service links.

import SwiftUI

struct MacAboutCategory: View {
    // Open Source Licenses opens in a sheet (native + simple — no restructuring
    // of `MacSettingsView`'s category swap), wrapping the shared `LicensesView`
    // in its own `NavigationStack` so its detail pushes work inside the modal.
    @State private var showingLicenses = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Form {
                    versionSection
                    aboutLinksSection
                    communitySection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)

                // Free-floating sign-off — kept OUT of the grouped Form so it
                // renders without a Section card (grey box) on the window bg.
                AboutThankYouFooter()
                    .padding(.top, 28)
                    .padding(.bottom, 24)
            }
            .padding(28)
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
        Section {
            AppIdentityHeader()
        } header: {
            Text(LocalizedStringResource("settings.mac.about.title", defaultValue: "About"))
        }
    }

    // MARK: - About links (feedback / legal) — unlabeled housekeeping

    private var aboutLinksSection: some View {
        Section {
            Button {
                openFeedbackEmailMac()
            } label: {
                rowLabel("Send Feedback", systemImage: "envelope", trailing: "arrow.up.right") // xcstrings
            }
            .settingsRowButton()

            // `Link`, not `Button` — no `ButtonStyle` reaches it, so these rows
            // take `.settingsRowLink()`: the same full-width live area and wash
            // `.settingsRowButton()` gives the `Button` rows above and below, and
            // deliberately the same ARROW cursor. These are rows, not inline
            // prose links, and the pointing hand here would make one card answer
            // the pointer three different ways. `.plain` stays for the link
            // chrome it already suppressed.
            Link(destination: URL(string: Constants.websiteURL)!) {
                rowLabel("Visit conduck.com", systemImage: "globe", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)
            .settingsRowLink()

            Link(destination: URL(string: Constants.privacyPolicyURL)!) {
                rowLabel("Privacy Policy", systemImage: "hand.raised", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)
            .settingsRowLink()

            Link(destination: URL(string: Constants.termsOfServiceURL)!) {
                rowLabel("Terms of Service", systemImage: "doc.text", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)
            .settingsRowLink()

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
            .settingsRowButton()
        }
    }

    // MARK: - Community (Discord) — honestly labeled; not a support desk

    private var communitySection: some View {
        Section {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settingsRowLink()
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
        // Load-bearing for the `Link` rows: they get no `ButtonStyle`, so this
        // is what makes the `Spacer()` gap hittable there. The `Button` rows
        // get the same guarantee from `.settingsRowButton()`.
        .contentShape(Rectangle())
    }
}
#endif

#if os(macOS)
// Conduck
// MacAboutCategory.swift
//
// macOS Settings → About category. Version string + Send Feedback (mailto via
// the shared `openFeedbackEmailMac`) + Privacy Policy / Terms of Service links.

import SwiftUI

struct MacAboutCategory: View {
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
            .buttonStyle(.plain)

            Link(destination: URL(string: Constants.websiteURL)!) {
                rowLabel("Visit conduck.com", systemImage: "globe", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)

            Link(destination: URL(string: Constants.privacyPolicyURL)!) {
                rowLabel("Privacy Policy", systemImage: "hand.raised", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)

            Link(destination: URL(string: Constants.termsOfServiceURL)!) {
                rowLabel("Terms of Service", systemImage: "doc.text", trailing: "arrow.up.right") // xcstrings
            }
            .buttonStyle(.plain)
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
        .contentShape(Rectangle())
    }
}
#endif

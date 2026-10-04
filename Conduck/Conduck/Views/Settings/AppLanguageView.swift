// SPDX-License-Identifier: Apache-2.0

// A native-name chooser is readable before the user chooses a UI language.
// Locale updates redraw existing views without recreating their identity,
// preserving drafts, navigation and any in-flight capture.

import SwiftUI

struct AppLanguageEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.locale, AppLanguageStore.shared.language.locale)
    }
}

extension View {
    func appLanguageEnvironment() -> some View { modifier(AppLanguageEnvironment()) }
}

struct AppLanguageGate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if AppLanguageStore.shared.selection == nil {
                AppLanguageWelcomeView()
            } else {
                content()
            }
        }
        .appLanguageEnvironment()
    }
}

struct AppLanguageWelcomeView: View {
    @State private var language = AppLanguage.suggested()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "globe").font(.system(size: 48)).foregroundStyle(.tint)
                Text(LocalizedStringResource("appLanguage.welcome.title", defaultValue: "Choose your language", locale: language.locale, bundle: .atURL(AppLocalization.bundle(for: language, in: .main).bundleURL)))
                    .font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text(LocalizedStringResource("appLanguage.welcome.detail", defaultValue: "You can change this anytime in Settings.", locale: language.locale, bundle: .atURL(AppLocalization.bundle(for: language, in: .main).bundleURL)))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Picker(selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(verbatim: option.nativeName).tag(option)
                    }
                } label: {
                    Text(LocalizedStringResource("appLanguage.label", defaultValue: "App language", locale: language.locale, bundle: .atURL(AppLocalization.bundle(for: language, in: .main).bundleURL)))
                }
                .pickerStyle(.inline)
                Button {
                    AppLanguageStore.shared.select(language)
                } label: {
                    Text(LocalizedStringResource("appLanguage.continue", defaultValue: "Continue", locale: language.locale, bundle: .atURL(AppLocalization.bundle(for: language, in: .main).bundleURL)))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(32)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, language.locale)
        .accessibilityIdentifier("app-language-welcome")
    }
}

struct AppLanguageSettingsSection: View {
    @State private var language = AppLanguageStore.shared.language

    var body: some View {
        Section {
            Picker(selection: Binding(get: { language }, set: { choice in
                language = choice
                AppLanguageStore.shared.select(choice)
            })) {
                ForEach(AppLanguage.allCases) { option in
                    Text(verbatim: option.nativeName).tag(option)
                }
            } label: {
                Text(LocalizedStringResource("appLanguage.label", defaultValue: "App language", locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle))
            }
            .pickerStyle(.menu)
        } header: {
            Text(LocalizedStringResource("appLanguage.section", defaultValue: "Language", locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle))
        } footer: {
            Text(LocalizedStringResource("appLanguage.settings.detail", defaultValue: "Applies to this device. Apple Watch and CarPlay use the connected iPhone’s language.", locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle))
        }
        .onReceive(NotificationCenter.default.publisher(for: .appLanguageDidChange)) { _ in
            language = AppLanguageStore.shared.language
        }
    }
}

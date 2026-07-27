// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Searchable language picker with common languages highlighted
struct LanguagePickerView: View {
    @Binding var selectedLanguageCode: String
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Auto-detect — clears the hint back to nil (provider
                // auto-detect / device locale). Hidden during search: it
                // isn't a language one would search for, and it's the only
                // way back to the unset state once a language is picked.
                if searchText.isEmpty {
                    Section {
                        autoDetectRow
                    }
                }

                // Common languages section
                Section {
                    ForEach(LanguageList.commonLanguages) { language in
                        languageRow(language)
                    }
                } header: {
                    Text("Common Languages") // xcstrings
                }

                // All languages section
                Section {
                    ForEach(filteredLanguages) { language in
                        languageRow(language)
                    }
                } header: {
                    Text("All Languages") // xcstrings
                }
            }
            .searchable(text: $searchText, prompt: "Search languages") // xcstrings
            .navigationTitle("Spoken language") // xcstrings
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { // xcstrings
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// "Auto-detect" row — sets the hint to empty (→ `nil` via the caller's
    /// binding) so the active provider reverts to its default behavior. The
    /// subtitle states what "Auto" actually means per engine, since Apple
    /// on-device does NOT detect language — it falls back to the device locale.
    @ViewBuilder
    private var autoDetectRow: some View {
        Button {
            selectedLanguageCode = ""
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-detect") // xcstrings: existing catalog key
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text("Sets the language for on-device transcription; cloud providers also auto-detect.") // xcstrings: apple-multilingual
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if selectedLanguageCode.isEmpty {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func languageRow(_ language: Language) -> some View {
        Button {
            selectedLanguageCode = language.code
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if language.name != language.nativeName {
                        Text(language.nativeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if language.code == selectedLanguageCode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredLanguages: [Language] {
        if searchText.isEmpty {
            return LanguageList.allLanguages
        }

        return LanguageList.allLanguages.filter { language in
            language.name.localizedCaseInsensitiveContains(searchText) ||
            language.nativeName.localizedCaseInsensitiveContains(searchText) ||
            language.code.localizedCaseInsensitiveContains(searchText)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var selectedCode = "en"

        var body: some View {
            LanguagePickerView(selectedLanguageCode: $selectedCode)
        }
    }

    return PreviewWrapper()
}

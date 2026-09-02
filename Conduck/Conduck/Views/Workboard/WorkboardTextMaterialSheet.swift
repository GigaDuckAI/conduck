// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardTextMaterialSheet.swift
//
// The one material a person composes rather than imports: a reference link,
// reached from the capture composer's attach menu. A typed thought is already a
// note card through the desk's pinned composer, which is the desk's only note
// route — a second composer would be a second door onto the same card.

import SwiftUI

struct WorkboardTextMaterialSheet: View {
    private enum Field: Hashable { case title, value }

    let onAdd: (WorkboardMaterialImport) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var value = ""
    @State private var validationMessage: LocalizedStringResource?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: titlePrompt),
                        text: $title
                    )
                    .focused($focusedField, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .value }
                    .accessibilityLabel(Text(titlePrompt))
                    TextField(
                        String(localized: LocalizedStringResource(
                            "workboard.material.link.url",
                            defaultValue: "https://example.com"
                        )),
                        text: $value
                    )
                    .textContentType(.URL)
                    .focused($focusedField, equals: .value)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "workboard.material.link.url.label",
                        defaultValue: "Web address"
                    )))
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(AppColors.error)
                    }
                } header: {
                    Text(LocalizedStringResource(
                        "workboard.material.link.title",
                        defaultValue: "Reference Link"
                    ))
                    .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text(LocalizedStringResource(
                        "workboard.material.link.footer",
                        defaultValue: "The address is saved as text. Conduck does not fetch the page in the background."
                    ))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(LocalizedStringResource(
                "workboard.material.addLink",
                defaultValue: "Add Link"
            ))
            .workboardInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.add", defaultValue: "Add"), action: add)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .workboardDesktopSheetFrame(minWidth: 360, minHeight: 260)
        .onAppear { focusedField = .value }
    }

    private var titlePrompt: LocalizedStringResource {
        LocalizedStringResource(
            "workboard.material.link.name",
            defaultValue: "Link name (optional)"
        )
    }

    private func add() {
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleanValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            validationMessage = LocalizedStringResource(
                "workboard.material.link.invalid",
                defaultValue: "Enter a complete http or https address."
            )
            focusedField = .value
            AccessibilityAnnouncer.announce(LocalizedStringResource(
                "workboard.material.link.invalid",
                defaultValue: "Enter a complete http or https address."
            ))
            return
        }
        onAdd(WorkboardMaterialImport(
            kind: .link,
            name: cleanTitle.isEmpty ? (url.host ?? cleanValue) : cleanTitle,
            detail: url.host,
            textContent: cleanValue,
            urlString: cleanValue
        ))
        dismiss()
    }
}

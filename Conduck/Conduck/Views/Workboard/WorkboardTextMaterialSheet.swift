// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardTextMaterialSheet.swift
//
// The two typed materials a person composes rather than imports: a reference
// link and a standalone note. Reached from the capture composer's attach menu on
// every Work surface.

import SwiftUI

enum WorkboardMaterialComposerKind: String, Identifiable {
    case link
    case note

    var id: String { rawValue }
}

struct WorkboardTextMaterialSheet: View {
    private enum Field: Hashable { case title, value }

    let kind: WorkboardMaterialComposerKind
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
                    if kind == .link {
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
                    } else {
                        TextEditor(text: $value)
                            .frame(minHeight: 160)
                            .focused($focusedField, equals: .value)
                            .accessibilityLabel(Text(LocalizedStringResource(
                                "workboard.material.note.body",
                                defaultValue: "Note text"
                            )))
                    }
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(AppColors.error)
                    }
                } header: {
                    Text(kind == .link
                        ? LocalizedStringResource("workboard.material.link.title", defaultValue: "Reference Link")
                        : LocalizedStringResource("workboard.material.note.title", defaultValue: "Standalone Note"))
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text(kind == .link
                        ? LocalizedStringResource("workboard.material.link.footer", defaultValue: "The address is saved as text. Conduck does not fetch the page in the background.")
                        : LocalizedStringResource("workboard.material.note.footer", defaultValue: "Use a note when a thought should remain a separate, reusable material."))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(kind == .link
                ? LocalizedStringResource("workboard.material.addLink", defaultValue: "Add Link")
                : LocalizedStringResource("workboard.material.addNote", defaultValue: "Add Note"))
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
        .workboardDesktopSheetFrame(minWidth: 360, minHeight: kind == .note ? 360 : 260)
        .onAppear { focusedField = .value }
    }

    private var titlePrompt: LocalizedStringResource {
        kind == .link
            ? LocalizedStringResource("workboard.material.link.name", defaultValue: "Link name (optional)")
            : LocalizedStringResource("workboard.material.note.name", defaultValue: "Note title (optional)")
    }

    private func add() {
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .link:
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
        case .note:
            let fallback = String(localized: LocalizedStringResource(
                "workboard.material.note.defaultName",
                defaultValue: "Note"
            ))
            onAdd(WorkboardMaterialImport(
                kind: .note,
                name: cleanTitle.isEmpty ? fallback : cleanTitle,
                textContent: cleanValue
            ))
        }
        dismiss()
    }
}

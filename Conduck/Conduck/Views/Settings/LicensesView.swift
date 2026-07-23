// Conduck
// LicensesView.swift
//
// Open Source Licenses — ONE shared implementation for BOTH iOS/iPadOS and
// macOS (house rule: unified cross-platform impl, never per-surface forks).
// This screen satisfies a standing legal obligation (Apache-2.0 §4 notice
// preservation for Conduck's own source + the MIT/Apache notices for the
// bundled Swift packages and the vendored Silero model): the three legal
// documents that ship in every official build MUST be viewable in-app.
//
// The documents are byte-identical copies of the submodule-root LICENSE /
// NOTICE / THIRD_PARTY_NOTICES.md, bundled under `Resources/Legal/` and drift-
// pinned by `LegalNoticesResourceTests`. They load lazily from `Bundle.main`;
// a missing resource degrades to a visible "could not load" line, never a
// crash.
//
// Presentation differs by shell, NOT the view: iOS pushes `LicensesView` onto
// the About screen's existing `NavigationStack`; macOS presents it in a sheet
// wrapped in its own `NavigationStack` (see `MacAboutCategory`). The view owns
// no stack of its own so both hosts drive navigation.

import SwiftUI

// MARK: - Document model

/// The three bundled legal documents, in display order. Each names its
/// `Resources/Legal/` bundle resource (synced-folder resources land flat at
/// the bundle root, so lookup is by name + extension, not sub-path).
enum LegalDocument: String, CaseIterable, Identifiable {
    case license
    case notice
    case thirdParty

    var id: String { rawValue }

    /// Bundle resource base name + extension for `Bundle.main.url(forResource:withExtension:)`.
    var resource: (name: String, ext: String) {
        switch self {
        case .license:    return ("LICENSE", "txt")
        case .notice:     return ("NOTICE", "txt")
        case .thirdParty: return ("THIRD_PARTY_NOTICES", "md")
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .license:
            return LocalizedStringResource("settings.about.licenses.conduck.title",
                                           defaultValue: "Conduck License")
        case .notice:
            return LocalizedStringResource("settings.about.licenses.notice.title",
                                           defaultValue: "Notice")
        case .thirdParty:
            return LocalizedStringResource("settings.about.licenses.thirdparty.title",
                                           defaultValue: "Third-Party Notices")
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .license:
            return LocalizedStringResource("settings.about.licenses.conduck.subtitle",
                                           defaultValue: "Apache License 2.0")
        case .notice:
            return LocalizedStringResource("settings.about.licenses.notice.subtitle",
                                           defaultValue: "Attribution notice")
        case .thirdParty:
            return LocalizedStringResource("settings.about.licenses.thirdparty.subtitle",
                                           defaultValue: "Bundled open-source components")
        }
    }
}

// MARK: - Root list

/// Three rows — the Conduck license, the NOTICE file, and the third-party
/// notices — each pushing a full-text detail view. Hosts NO `NavigationStack`
/// (the iOS About stack / the macOS sheet's stack owns navigation).
struct LicensesView: View {
    var body: some View {
        // Grouped Form (not a plain List): renders the same card look as the
        // rest of Settings on macOS and a grouped list on iOS, and its footer
        // wraps — a plain macOS List truncates the footer to one line.
        Form {
            Section {
                ForEach(LegalDocument.allCases) { doc in
                    NavigationLink {
                        LegalDocumentDetailView(document: doc)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title)
                            Text(doc.subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                Text(LocalizedStringResource(
                    "settings.about.licenses.footer",
                    defaultValue: "Conduck's own source and placeholder artwork are licensed under the Apache License 2.0. Bundled third-party components keep their own licenses, reproduced here."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(LocalizedStringResource(
            "settings.about.licenses.title", defaultValue: "Open Source Licenses")))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Full-text detail

/// Renders one legal document as selectable, scrollable monospaced text. The
/// file is read from `Bundle.main` on first appearance (these are long texts —
/// no reason to load until opened); a missing/unreadable resource shows a
/// plain "could not load" line rather than crashing.
struct LegalDocumentDetailView: View {
    let document: LegalDocument

    @State private var text: String?
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            Group {
                if let text {
                    Text(text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if loadFailed {
                    Text(LocalizedStringResource(
                        "settings.about.licenses.loadError",
                        defaultValue: "This document could not be loaded."))
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle(Text(document.title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: document.id) {
            guard text == nil, !loadFailed else { return }
            load()
        }
    }

    private func load() {
        let (name, ext) = document.resource
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let loaded = try? String(contentsOf: url, encoding: .utf8) else {
            loadFailed = true
            return
        }
        text = loaded
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        LicensesView()
    }
}
#endif

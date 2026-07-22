#if os(macOS)
// Conduck
// MacDiagnosticsCategory.swift
//
// macOS Settings → Diagnostics category. The same `DiagnosticsContent` the
// iOS/iPad screens use, wrapped in the standard macOS category shell
// (ScrollView + grouped Form + padding — mirrors `MacGeneralCategory`). The
// `DiagnosticsRunner` is injected from `MacSettingsView` (not self-owned) so it
// OUTLIVES a sidebar tab-switch: the `detail` `switch` tears this view down on
// every category change, so a self-owned runner would re-seed from empty and the
// amber Copy button would flicker on return. The persistent runner renders the
// checklist fully-formed instead.

import SwiftUI

struct MacDiagnosticsCategory: View {
    let runner: DiagnosticsRunner

    var body: some View {
        ScrollView {
            Form {
                DiagnosticsContent(runner: runner)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(28)
        }
    }
}
#endif

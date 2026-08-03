// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MacDiagnosticsCategory.swift
//
// macOS Settings → Diagnostics category. The same `DiagnosticsContent` the
// iOS/iPad screens use, mounted bare: that view owns its own
// `PlatformSettingsForm`, whose macOS branch already supplies the whole category
// shell — the scroll surface, the 28pt window gutter, the shared
// `MacSettingsRail` reading column, and the hand-drawn `SettingsCard` per
// section. Wrapping it in a second `ScrollView` or padding here would double
// every one of those, so this view adds nothing but the runner.
//
// The `DiagnosticsRunner` is injected from `MacSettingsView` (not self-owned) so
// it OUTLIVES a sidebar tab-switch: the `detail` `switch` tears this view down on
// every category change, so a self-owned runner would re-seed from empty and the
// amber Copy button would flicker on return. The persistent runner renders the
// checklist fully-formed instead.

import SwiftUI

struct MacDiagnosticsCategory: View {
    let runner: DiagnosticsRunner

    var body: some View {
        DiagnosticsContent(runner: runner)
    }
}
#endif

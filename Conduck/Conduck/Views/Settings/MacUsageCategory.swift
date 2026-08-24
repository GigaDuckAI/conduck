// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// MacUsageCategory.swift
//
// macOS Settings → Usage category. The same `UsageDashboardContent` the iPhone
// and iPad screens use, mounted bare: that view owns its own
// `PlatformSettingsForm`, whose macOS branch already supplies the whole category
// shell — the scroll surface, the window gutter, the shared `MacSettingsRail`
// reading column, and the hand-drawn `SettingsCard` per section. Wrapping it in
// a second `ScrollView` or padding here would double every one of those, so this
// view adds nothing but the model and the drill-down stack.
//
// THE `NavigationStack` IS THIS HOST'S JOB; the ROUTE REGISTRATION IS NOT. The
// iPhone push and the iPad detail arrive inside a stack their host already owns,
// while this category has none — so the stack is supplied here and nowhere else.
// The three usage routes are registered exactly once, on `UsageDashboardContent`
// itself, which every host mounts: registering them a second time here would
// hand the same stack two destinations for one type, and SwiftUI resolves that
// by silently keeping one of them. Every pushed screen wears
// `.macSettingsSubScreenChrome(title:)` from inside itself, so the window's title
// bar stays empty and the Settings sidebar never shifts on push.
//
// The `UsageDashboardModel` is injected from `MacSettingsView` (not self-owned)
// so it OUTLIVES a sidebar tab-switch: the `detail` `switch` tears this view
// down on every category change, and a self-owned model would refetch and
// re-aggregate the whole attempt ledger each time the user came back to Usage.
// The persistent model renders its already-loaded summary instead — and the
// drill-downs read their slices from that same instance, so the range picked on
// the overview is the range they describe.

import SwiftUI

struct MacUsageCategory: View {
    let model: UsageDashboardModel

    var body: some View {
        NavigationStack {
            UsageDashboardContent(model: model)
        }
    }
}
#endif

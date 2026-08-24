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
// view adds nothing but the model.
//
// The `UsageDashboardModel` is injected from `MacSettingsView` (not self-owned)
// so it OUTLIVES a sidebar tab-switch: the `detail` `switch` tears this view
// down on every category change, and a self-owned model would refetch and
// re-aggregate the whole attempt ledger each time the user came back to Usage.
// The persistent model renders its already-loaded summary instead.

import SwiftUI

struct MacUsageCategory: View {
    let model: UsageDashboardModel

    var body: some View {
        UsageDashboardContent(model: model)
    }
}
#endif

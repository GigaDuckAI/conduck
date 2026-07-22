// Conduck
// RemoteAgentDetailView.swift
//
// iOS Settings: per-backend Personal AI gateway detail, pushed from the gateway
// LIST (`PersonalAISettingsView`). Mounts the shared `RemoteAgentConfigBody` for
// the row's backend — PURE CONFIG (URL + token + Test + Forget + trust surfaces).
// Choosing the DEFAULT gateway is NOT here — it lives only in the top "Default
// for new chats" selector → `DefaultGatewayPicker`.
//
// `guidedHost` threads the window/stack-root guided-setup presentation down for
// the editor's Quick connect deep-link; surfaces without one (the Watch
// companion settings) omit it and the editor hides that zone.
//
// iOS-only: macOS Personal AI routes through `MacPersonalAICategory` (its own
// `NavigationStack` into the same `RemoteAgentConfigBody`).

#if os(iOS)
import SwiftUI

struct RemoteAgentDetailView: View {
    @Bindable var viewModel: SettingsViewModel
    let ref: RemoteAgentRef
    var guidedHost: Binding<GuidedGatewayHostState>? = nil

    var body: some View {
        RemoteAgentConfigBody(viewModel: viewModel, ref: ref, guidedHost: guidedHost)
            .navigationTitle(Text(viewModel.displayName(for: ref)))
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

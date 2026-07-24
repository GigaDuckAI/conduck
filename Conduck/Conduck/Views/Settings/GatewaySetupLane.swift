// Conduck
// GatewaySetupLane.swift
//
// Shared primitives for the redesigned guided gateway-setup flow
// (`GuidedGatewaySetupView` + its sub-step views). Kept in one tiny file so the
// container, every sub-step view, and the host wiring (iOS `PersonalAISettingsView`,
// macOS `MainWindowView` → `MacSettingsView` → `MacPersonalAICategory`) all compile
// against ONE source of truth without cross-unit edit collisions.

import SwiftUI

/// Which self-hosted lane the guided flow is walking. Both lanes share the SAME
/// sub-step views (fork → readiness → helper → commands → success); they differ
/// only in copy, help-page context, and the manual-fallback target. Both run the
/// same `conduck-connect.sh --setup` command. The hosted-model (OpenRouter) lane is NOT a
/// `GatewaySetupLane` — it has its own dedicated step view.
enum GatewaySetupLane: Hashable {
    /// OpenClaw / Hermes — a full personal-AI server (tools, memory, files).
    case fullAgent
    /// Any OpenAI-compatible endpoint the user runs (Ollama / vLLM / LiteLLM…).
    case custom

    /// Whether lane-specific copy and links should describe a custom server.
    var isCustom: Bool { self == .custom }
}

/// One guided-flow presentation: destination + presence as a SINGLE value.
/// iOS/iPadOS bind this to `.fullScreenCover(item:)`, whose content closure is
/// handed THIS value — so the cover can never build against a destination that
/// hasn't committed yet. (A two-field shape — a Bool switch plus a separate
/// `initialPath` — races on iOS 26: the first present builds content before the
/// path write lands and opens the chooser instead of the deep-link; deferring
/// the switch-flip a runloop tick does not reliably close that race either.)
/// The fresh `id` per present also gives each open a fresh cover identity, so
/// step `@State` never leaks between runs.
struct GuidedGatewayPresentation: Identifiable {
    let id = UUID()
    /// Where the guided flow opens (`nil` == the chooser).
    let initialPath: GatewayPath?
}

/// Drives the guided-setup presentation from a window-root container. On macOS the
/// guided flow is a FULL-WINDOW overlay owned by `MainWindowView` (a `.sheet` is
/// always an inset panel and can't go edge-to-edge), threaded down through
/// `MacSettingsView` to `MacPersonalAICategory`; iOS/iPadOS use a
/// `.fullScreenCover(item:)` hosted at their settings NavigationStack root. Either
/// way the Personal AI screen only TRIGGERS the flow — it owns no hand-off state.
struct GuidedGatewayHostState {
    /// The active presentation — non-nil while the guided flow is showing.
    /// iOS/iPadOS hosts bind `$….presentation` as the cover item; macOS
    /// `if let`s it for the window overlay. Triggers go through
    /// `present(initialPath:)` / `dismiss()`, never field writes.
    var presentation: GuidedGatewayPresentation? = nil

    /// Whether the guided flow is showing. Read-only on purpose — presenting
    /// must go through `present(initialPath:)` so destination and presence
    /// commit as one value.
    var isPresented: Bool { presentation != nil }

    /// Open the guided flow at `initialPath` (`nil` == the chooser).
    mutating func present(initialPath: GatewayPath? = nil) {
        presentation = GuidedGatewayPresentation(initialPath: initialPath)
    }

    /// Close the guided flow.
    mutating func dismiss() { presentation = nil }
}

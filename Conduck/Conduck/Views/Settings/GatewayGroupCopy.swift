// Conduck
// GatewayGroupCopy.swift
//
// Single source of truth for the Personal AI screen's section header + footer
// copy — shared iOS + macOS so the two platform shells can't drift. Each entry
// is a `LocalizedStringResource` with an explicit `defaultValue:`; the platform
// files reference these instead of inlining the strings, so a copy change lands
// in one place on both surfaces.
//
// Pure constants — no View. (The "New chats use" selector header reuses the
// existing key directly in each file.)

import SwiftUI

/// Header/footer copy for the Personal AI gateway groups, shared across the iOS
/// `PersonalAISettingsView` and the macOS `MacPersonalAICategory`.
enum GatewayGroupCopy {
    /// "Connect" — the permanent setup-affordance section header.
    static let connectHeader = LocalizedStringResource(
        "settings.personalAI.connect.header",
        defaultValue: "Connect"
    )

    /// "Full agent gateways" — self-hosted built-ins (OpenClaw / Hermes).
    static let fullAgentHeader = LocalizedStringResource(
        "settings.personalAI.fullAgent.header",
        defaultValue: "Full agent gateways"
    )
    static let fullAgentFooter = LocalizedStringResource(
        "settings.personalAI.fullAgent.footer",
        defaultValue: "Tools, memory, file attachments."
    )

    /// "Hosted model" — OpenRouter (no server, no tools/files).
    static let hostedModelHeader = LocalizedStringResource(
        "settings.personalAI.hostedModel.header",
        defaultValue: "Hosted model"
    )
    static let hostedModelFooter = LocalizedStringResource(
        "settings.personalAI.hostedModel.footer",
        defaultValue: "No server needed. No tools or file access."
    )

    /// "Custom gateways" — any OpenAI-compatible endpoint, including a self-built
    /// AI behind an adapter (the self-builder must recognize themselves here).
    static let customFooter = LocalizedStringResource(
        "settings.personalAI.custom.footer",
        defaultValue: "Any OpenAI-compatible endpoint (LiteLLM, Ollama, vLLM…) — or an AI you built, behind a small adapter."
    )
}

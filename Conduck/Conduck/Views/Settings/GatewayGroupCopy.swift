// SPDX-License-Identifier: Apache-2.0

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
    static var connectHeader: LocalizedStringResource { LocalizedStringResource(
        "settings.personalAI.connect.header",
        defaultValue: "Connect"
    , locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle) }

    /// The self-hosted built-ins (OpenClaw / Hermes), named by what is TRUE of
    /// them rather than by a category the reader has to place their own software
    /// into. "Full agent gateways" asked a user to decide whether the thing they
    /// run counts as a "full agent" and whether it counts as a "gateway" —
    /// before they had opened it — and set "model" and "gateway" beside each
    /// other as sibling category names for one kind of thing.
    static var fullAgentHeader: LocalizedStringResource { LocalizedStringResource(
        "settings.personalAI.fullAgent.header.v2",
        defaultValue: "Runs on your own server"
    , locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle) }
    static var fullAgentFooter: LocalizedStringResource { LocalizedStringResource(
        "settings.personalAI.fullAgent.footer",
        defaultValue: "Tools and file attachments. Conduck sends each chat's context with every message."
    , locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle) }

    /// OpenRouter — the lane where the user stands nothing up.
    static var hostedModelHeader: LocalizedStringResource { LocalizedStringResource(
        "settings.personalAI.hostedModel.header.v2",
        defaultValue: "No server needed"
    , locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle) }
    static var hostedModelFooter: LocalizedStringResource { LocalizedStringResource(
        "settings.personalAI.hostedModel.footer.v2",
        defaultValue: "Conduck talks straight to the provider. No tools, no file transfer."
    , locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle) }

    /// The user-defined endpoints. The one fact Conduck can assert about this
    /// bucket: the address came from the user. It is HETEROGENEOUS by
    /// construction — Ollama, LiteLLM, vLLM or a home-built adapter — so a
    /// header naming a capability would be false for some of them.
    static var customHeader: LocalizedStringResource { LocalizedStringResource(
        "settings.personalAI.section.customHeader.v2",
        defaultValue: "You supply the address"
    , locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle) }

    /// Footer for the custom section — any OpenAI-compatible endpoint, including
    /// a self-built AI behind an adapter (the self-builder must recognize
    /// themselves here).
    static var customFooter: LocalizedStringResource { LocalizedStringResource(
        "settings.personalAI.custom.footer",
        defaultValue: "Any OpenAI-compatible endpoint (LiteLLM, Ollama, vLLM…) — or an AI you built, behind a small adapter."
    , locale: AppLocalization.locale, bundle: AppLocalization.resourceBundle) }
}

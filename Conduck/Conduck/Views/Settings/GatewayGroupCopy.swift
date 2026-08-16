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
    static let connectHeader = LocalizedStringResource(
        "settings.personalAI.connect.header",
        defaultValue: "Connect"
    )

    /// The self-hosted built-ins (OpenClaw / Hermes), named by what is TRUE of
    /// them rather than by a category the reader has to place their own software
    /// into. "Full agent gateways" asked a user to decide whether the thing they
    /// run counts as a "full agent" and whether it counts as a "gateway" —
    /// before they had opened it — and set "model" and "gateway" beside each
    /// other as sibling category names for one kind of thing.
    static let fullAgentHeader = LocalizedStringResource(
        "settings.personalAI.fullAgent.header.v2",
        defaultValue: "Runs on your own server"
    )
    static let fullAgentFooter = LocalizedStringResource(
        "settings.personalAI.fullAgent.footer",
        defaultValue: "Tools and file attachments. Conduck sends each chat's context with every message."
    )

    /// OpenRouter — the lane where the user stands nothing up.
    static let hostedModelHeader = LocalizedStringResource(
        "settings.personalAI.hostedModel.header.v2",
        defaultValue: "No server needed"
    )
    static let hostedModelFooter = LocalizedStringResource(
        "settings.personalAI.hostedModel.footer.v2",
        defaultValue: "Conduck talks straight to the provider. No tools, no file transfer."
    )

    /// The user-defined endpoints. The one fact Conduck can assert about this
    /// bucket: the address came from the user. It is HETEROGENEOUS by
    /// construction — Ollama, LiteLLM, vLLM or a home-built adapter — so a
    /// header naming a capability would be false for some of them.
    static let customHeader = LocalizedStringResource(
        "settings.personalAI.section.customHeader.v2",
        defaultValue: "You supply the address"
    )

    /// The per-row capability line, on the SAME axis as the headers above and as
    /// `RemoteAgentFailureContext` — the snapshot the error layer dispatches its
    /// recovery copy on. One axis for both means the picker and the failure
    /// message can never disagree about what a lane is.
    static func capabilitySubtitle(for ref: RemoteAgentRef) -> LocalizedStringResource {
        guard ref.isBuiltin else {
            return LocalizedStringResource(
                "settings.personalAI.row.capability.custom",
                defaultValue: "Your address · your model"
            )
        }
        if ref.failureContext.hidesURLField {
            return LocalizedStringResource(
                "settings.personalAI.row.capability.hostedModel",
                defaultValue: "No server · chat only"
            )
        }
        return LocalizedStringResource(
            "settings.personalAI.row.capability.selfHostedAgent",
            defaultValue: "Your server · tools and files"
        )
    }

    /// Footer for the custom section — any OpenAI-compatible endpoint, including
    /// a self-built AI behind an adapter (the self-builder must recognize
    /// themselves here).
    static let customFooter = LocalizedStringResource(
        "settings.personalAI.custom.footer",
        defaultValue: "Any OpenAI-compatible endpoint (LiteLLM, Ollama, vLLM…) — or an AI you built, behind a small adapter."
    )
}

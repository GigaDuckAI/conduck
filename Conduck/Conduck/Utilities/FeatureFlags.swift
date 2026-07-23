//
//  FeatureFlags.swift
//  Conduck
//
//  Feature flags for controlling feature availability.
//

import Foundation

enum FeatureFlags {
    /// GigaNote feature is disabled — Conduck is a transcription-only
    /// shell. A future Conversation store (`Conversation`/`Message`
    /// two-level Core Data + CloudKit schema) for the agent round-trip surface
    /// would re-evaluate whether to add a separate notes-style flag.
    /// Onboarding feature rows + Mode rows gate on this flag.
    static let notesEnabled = false

    /// Hermes backend availability in the Personal AI Settings picker.
    /// The old server-session gates (concurrent-write, attachment,
    /// named-conversation × multimodal replay) DISSOLVED under client-owned
    /// history — Hermes reuses the identical stateless `RemoteAgentClient`
    /// path (`spec.md` Remote Agent Round-Trip → Hermes). Verified
    /// against a self-hosted Hermes instance: green at the wire level
    /// (GET /v1/models 200, model-omitted accepted, full-history turn
    /// returned "42").
    /// Multi-device CloudKit remains a signed-device verification gate,
    /// same as OpenClaw's.
    ///
    /// The network layer (`RemoteAgentStatusMap`, `RemoteAgentClient`) does
    /// not consume this flag — it treats Hermes as a first-class backend
    /// regardless. The Settings UI consumes it to surface the Hermes row
    /// in the Personal AI picker (shows "Coming soon" while `false`).
    static let remoteAgentHermesEnabled = true

    /// OpenRouter backend availability in the Personal AI Settings list.
    /// OpenRouter is a third-party HOSTED-MODEL backend (not the user's own
    /// server) offered as a low-friction "try any model" on-ramp — see
    /// `RemoteAgentBackendMetadata` (`category == .hostedModel`). Like
    /// `remoteAgentHermesEnabled`, the network layer treats it as a first-class
    /// backend regardless of this flag; the Settings UI consumes it to surface
    /// the OpenRouter row under the "Hosted models" section.
    static let remoteAgentOpenRouterEnabled = true
}

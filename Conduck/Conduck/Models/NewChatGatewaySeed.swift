// SPDX-License-Identifier: Apache-2.0

// Conduck
// NewChatGatewaySeed.swift
//
// Which gateway a NEW chat's picker opens on, as a pure function.
//
// The rule in one line: continue where you left off, fall back to the setting.
// A new chat pre-selects the gateway the last conversation on this device was
// actually started on; when there is no such gateway, or it is no longer
// configured, the device-local "Default for new chats" takes over.
//
// This is a PRE-SELECTION, never a route. The conversation seals its gateway at
// mint (`ConversationStore.createConversation(backend:)`) and every send routes on
// that sealed value — so the worst a wrong answer here can do is show the user the
// wrong name before they send, never deliver a thread to a server they did not
// choose. That is why an unconfigured suggestion is filtered rather than trusted.
//
// It lives in its own file for two reasons. The ladder is consumed by two SwiftUI
// views that cannot be unit-tested (`ContentView.refreshGatewayRoster` and
// `MainWindowView.refreshConfiguredBackends`), and it was previously duplicated
// verbatim in both — where the copies could drift apart silently.

import Foundation

/// Everything the new-chat picker needs, sampled in ONE `SettingsManager` actor
/// turn. Read piecemeal these values can disagree with each other: a refresh
/// that samples the default, suspends, and resumes after Settings re-pointed it
/// would seed a gateway the user had already moved away from.
struct NewChatPickerSnapshot: Sendable {
    /// Gateways that are fully set up right now, in stable picker order. The
    /// SAME array `resolution` was classified against, not a second read.
    let configuredRefs: [RemoteAgentRef]
    /// Roster backing the gateway badges (monogram + colour). Unions retired
    /// customs, so a forgotten gateway still resolves to a real name.
    let badgeRoster: [CustomGateway]
    /// This device's "Default for new chats" — exactly `resolution.ref`, kept as
    /// its own field so the seed ladder and its callers need no rewrite. Like
    /// that projection, it may name a gateway `resolution` forbids sending on.
    let defaultRef: RemoteAgentRef
    /// The gateway the last conversation here started on, if any.
    let lastUsedRef: RemoteAgentRef?
    /// The full eight-way verdict for this device's default, from the SAME turn.
    /// Anything that MINTS reads this, never `defaultRef` alone.
    let resolution: DefaultGatewayResolution
    /// A repair this device performed and has not yet told the user about.
    let pendingAdoptionNotice: DefaultGatewayAdoptionNotice?

    /// True when the stored pointer is one the APP parked rather than one the
    /// user chose — the Forget re-point parks on a built-in when several
    /// gateways survive, so the user chooses their next one instead of
    /// inheriting it. A surface that names the default must drop the name here:
    /// the user never picked this gateway, and calling it "your default AI" one
    /// step after they forgot a different one is an accusation about a choice
    /// they did not make.
    ///
    /// READ THROUGH `resolution`, never stored beside it. A stored twin is a
    /// second fact that can be sampled from a different moment, or filled in
    /// with the wrong value by a caller building a snapshot by hand; derived, it
    /// is the same fact the verdict already carries.
    var defaultPointerIsParked: Bool { resolution.pointerIsParked }
}

enum NewChatGatewaySeed {

    /// The gateway a fresh chat's picker should open on.
    ///
    /// Preference order — last-used, then the default, then any configured gateway:
    /// each candidate must actually be configured to win, so a suggestion pointing
    /// at a gateway the user forgot (or that a peer's sync removed) degrades to the
    /// next answer instead of presenting a selection that cannot send.
    ///
    /// The final fallback returns `persistedDefault` even though it is not in
    /// `configured` — reached only when NOTHING is configured, where the picker is
    /// hidden anyway and the caller needs a non-optional value to hold.
    ///
    /// This ladder may still land on `configured.first` when NO default has been
    /// chosen at all (`DefaultGatewayResolution.selectionRequired`), and that is
    /// correct: a pre-selection is a highlighted row, not a decision, and the
    /// surfaces say separately that no default is chosen. Do not "fix" it by
    /// teaching the ladder about the resolution — a picker with nothing
    /// highlighted is worse than one highlighted row the user can change.
    static func resolve(
        configured: [RemoteAgentRef],
        lastUsed: RemoteAgentRef?,
        persistedDefault: RemoteAgentRef
    ) -> RemoteAgentRef {
        if let lastUsed, configured.contains(lastUsed) { return lastUsed }
        if configured.contains(persistedDefault) { return persistedDefault }
        return configured.first ?? persistedDefault
    }
}

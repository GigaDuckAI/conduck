// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationHistoryAssembler.swift
//
// THE single history-assembly choke point for all six converse dispatch
// surfaces (in-app send + retry, headless `ConverseIntent`, CarPlay, Watch,
// share drainer). Owns the full fetch → image-byte-resolution → policy-lookup →
// `ConverseRequest.priorTurns` chain so every surface produces the SAME wire
// history for the same stored conversation.
//
// Why it exists: `priorTurns` is a pure synchronous mapper — the async hops
// (store fetch, `loadAttachmentData`, the per-gateway image-history policy)
// previously lived PER-CALLER, and three of the six callers (headless
// intent, CarPlay, Watch) skipped the image resolution entirely, sending
// image-blind history (a model re-reading those turns saw bare text where it
// once saw pixels). Centralizing the resolution closes that drift class:
// `priorTurns` has exactly ONE production caller — this assembler — and a
// future caller that bypasses it degrades HONESTLY (the `priorTurns` floor
// splices a disk ref or an unavailable note), never silently.
//
// CROSS-TARGET: a Watch-target membership exception (pbxproj `63E4A001…` set,
// alongside `ConversationStore.swift` / `ConverseRequest.swift` /
// `DataURIBuilder.swift`). Pure Foundation + the app's own cross-target types —
// NO UIKit / AppKit. `SettingsManager` is main-target-only, so the
// image-history-policy lookup is `#if !os(watchOS)`-gated (see below).
//
// MEMORY DISCIPLINE: full image bytes are loaded on demand per message via
// `ConversationStore.loadAttachmentData(for:)` and immediately folded into
// base64 data-URIs — the snapshots themselves never carry image bytes.

import Foundation

/// Stateless namespace — fetches a conversation's stored turns, resolves each
/// prior turn's image bytes into `image_url` data-URIs, looks up the bound
/// gateway's image-history policy, and maps the lot through
/// `ConverseRequest.priorTurns`.
enum ConversationHistoryAssembler {

    /// Assemble the wire-ready prior-turn history for `conversationID`.
    ///
    /// - Parameters:
    ///   - conversationID: the conversation whose stored turns are assembled.
    ///     Also supplies the `folder` (its UUID string) for the disk-reference
    ///     splices.
    ///   - excludingUserMessageID: the JUST-APPENDED user turn's id — its
    ///     attachments are never resolved into the prior-turn image map (the
    ///     current turn's images ride separately via
    ///     `newUserImageDataURIs`, never as history).
    ///   - excludingNewUserText: the just-captured user text —
    ///     `priorTurns` drops a trailing stored user turn matching it (the
    ///     request assembler re-appends the new turn itself; the stored copy
    ///     must not be sent twice).
    ///   - boundRef: the conversation's bound gateway ref, driving the
    ///     per-gateway `ImageHistoryPolicy`. `nil` (or any ref on watchOS) →
    ///     the default policy (`.recent`).
    ///   - store: injectable for tests; production passes `.shared`.
    ///
    /// THROWING (`fetchMessages` rethrows) so callers that surface store errors
    /// keep doing so; callers with a non-throwing posture wrap in `try?`. The
    /// per-message byte loads are individually `try?`-tolerant — one
    /// unreadable attachment degrades that turn (the `priorTurns` honesty
    /// floor takes over), it never fails the whole assembly.
    /// `@concurrent` + `nonisolated` — load-bearing, not decoration. This enum
    /// carries no isolation annotation, so under the targets' MainActor default
    /// isolation it (and every unannotated helper it calls) would be main-actor
    /// bound: the per-message `DataURIBuilder.jpegDataURI` base64 pass below runs
    /// once per historical image on EVERY send, and on the main actor that is a
    /// composer freeze that grows with the conversation. The store and settings
    /// hops inside remain genuine actor calls either way.
    @concurrent
    nonisolated static func assemble(
        conversationID: UUID,
        excludingUserMessageID: UUID?,
        excludingNewUserText: String?,
        boundRef: RemoteAgentRef?,
        dispatchFileLaneID: String? = nil,
        store: ConversationStore = .shared
    ) async throws -> [ConverseRequest.Message] {
        let allMessages = try await store.fetchMessages(for: conversationID)

        // Resolve each prior turn's USER-side image bytes into data-URIs.
        // The `!isServerReference` predicate is deliberate: agent-reply OUTPUT
        // chips carry an image MIME with EMPTY local data (the bytes live on
        // the user's file-server) and previously polluted the map — minting a
        // degenerate empty `image_url` part and consuming an inline-window
        // slot. Empty `Data` elements (e.g. a not-yet-synced CloudKit asset)
        // are likewise dropped; a turn only enters the map with ≥1 real URI,
        // so `priorTurns`' honesty floor handles the rest.
        var dataURIsByMessageID: [UUID: [String]] = [:]
        for message in allMessages where message.id != excludingUserMessageID {
            let hasUserImages = message.attachments.contains { $0.isImage && !$0.isServerReference }
            guard hasUserImages else { continue }
            guard let bytes = try? await store.loadAttachmentData(for: message.id) else { continue }
            let uris = bytes
                .filter { !$0.isEmpty }
                .map { DataURIBuilder.jpegDataURI(from: $0) }
            if !uris.isEmpty {
                dataURIsByMessageID[message.id] = uris
            }
        }

        // Per-gateway image-history policy (Recent / Extended / All). A nil /
        // unresolvable ref falls back to the default policy (`.recent`).
        #if !os(watchOS)
        var policy: ImageHistoryPolicy = .default
        if let boundRef {
            policy = await SettingsManager.shared.getImageHistoryPolicy(for: boundRef)
        }
        #else
        // DELIBERATE DEFERRAL: the policy lives in App-Group UserDefaults on
        // iOS (`SettingsManager` is main-target-only) and is never broadcast
        // to the Watch, so the wrist always runs the default policy. Callers
        // still pass their ref — zero call-site churn if the policy ever
        // broadcasts.
        _ = boundRef
        let policy: ImageHistoryPolicy = .default
        #endif

        let assembled = ConverseRequest.priorTurns(
            from: allMessages,
            excludingNewUserText: excludingNewUserText,
            dataURIsByMessageID: dataURIsByMessageID,
            folder: conversationID.uuidString,
            imagePolicy: policy,
            dispatchFileLaneID: dispatchFileLaneID
        )

        // Compat mode ("Keep chatting without photos"): when this
        // conversation's persisted flag is on, every historical image part is
        // replaced IN PLACE with the canonical contract disclosure — a
        // POST-pass over the policy-routed turns, so it touches exactly the
        // parts that would have gone on the wire (reference/expired turns are
        // already text). Outbound-only: the store and UI keep the images.
        // Applied here — the single history choke point — so all converse
        // surfaces (send, retry, share drain, intent, CarPlay) behave
        // identically. FAIL-CLOSED: the flag read THROWS on a store hiccup
        // (callers' `try?` then sends EMPTY history — no images leak), never
        // silently defaults to unsubstituted — this is the safety switch a
        // user flipped to escape a history-rejecting gateway.
        let hideEarlierPhotos = try await store.fetchConversation(id: conversationID)?
            .hideEarlierPhotos ?? false
        guard hideEarlierPhotos else { return assembled }
        return ConverseRequest.substitutingHistoricalImages(in: assembled)
    }
}

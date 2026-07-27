// SPDX-License-Identifier: Apache-2.0

// Conduck
// SharedInboxRouting.swift
//
// Share-Extension — the SINGLE resolve-or-mint routing helper shared by
// BOTH the headless `ConverseIntent` (entry-1 Shortcut) AND the future
// `SharedInboxDrainer`. It encapsulates the per-conversation routing
// logic that was previously inlined in `ConverseIntent.runConverseHop`:
//
//   resolve the active-conversation pointer (TTL-gated by the user's
//   SessionContinuationPolicy) → IF a real `Conversation` row exists locally,
//   route by ITS bound backend (no silent reroute to default) →
//   ELSE snapshot+validate the DEFAULT backend BEFORE minting a fresh thread.
//
// Extracted to ONE function so the rule can never drift between the two callers.
// It also takes an
// explicit `overrideConversationID` (the share manifest's "New conversation"
// user override) that, when present AND resolvable to a local row, is used
// directly — bypassing the pointer.
//
// KNOWN BENIGN RACE (documented, NOT coordinated): Swift actors are reentrant
// across `await`, so routing through `SettingsManager` does NOT serialize the
// mint. If the drainer and a near-simultaneous `ConverseIntent` both resolve
// "no pointer" they can each mint a fresh conversation → two near-identical
// threads. Worst case is annoying, NOT data loss (no turn is dropped; both get
// a valid bound ref). We deliberately ACCEPT + document this rather than add a
// coordinator actor / lock (a real fix needs an explicit mint lock — out of
// scope, over-engineered for the failure cost).

import Foundation

/// Stateless namespace for the shared resolve-or-mint routing decision. Every
/// member is `static` (no instances) — it holds no state, just the branch.
enum SharedInboxRouting {

    /// The resolved routing target: which conversation a turn appends to, the
    /// gateway snapshot to send it through, and the (non-empty) bearer token.
    /// Returned together so the caller never re-resolves any piece.
    struct Resolved: Sendable {
        let conversationID: UUID
        let snapshot: SettingsManager.RemoteAgentSnapshot
        /// Non-empty bearer token (validated before return — a configured
        /// backend with URL-but-no-token throws `.remoteAgentNotConfigured`).
        let token: String
        /// The resolved routing ref (built-in OR custom). The Share-Extension
        /// drainer needs it to look up the PER-GATEWAY file-server snapshot
        /// (`SettingsManager.fileTransferSnapshot(for:)`) when a shared binary
        /// must take the upload path. `ConverseIntent` ignores it.
        let ref: RemoteAgentRef
    }

    /// Resolve (or mint) the conversation a capture/share turn should land on,
    /// and the gateway it routes through. Behavior-preserving extraction of the
    /// `ConverseIntent.runConverseHop` inline block, EXTENDED for the Share-
    /// Extension "Send to" picker (the user can target an EXISTING conversation,
    /// or start a NEW conversation on a specific gateway). Precedence — first
    /// match wins:
    ///
    ///   1. `overrideConversationID` set AND names a local `Conversation` row →
    ///      route by THAT row's bound backend (append to the chosen thread).
    ///   2. `overrideConversationID` set but the row is GONE (deleted between the
    ///      share + the drain) → do NOT silently fall through to default: if
    ///      `selectedBackendRef` is present AND still configured (non-nil snapshot
    ///      with a non-empty token), MINT a fresh conversation on that ref;
    ///      otherwise THROW `.remoteAgentNotConfigured` (the drainer fails the
    ///      share — notify + delete — never reroute the user's pick to an
    ///      unrelated gateway).
    ///   3. `newConversationGatewayRef` set AND configured → MINT a fresh
    ///      conversation bound to that ref (the picker's "New conversation in
    ///      <Gateway>" choice).
    ///   4. `newConversationGatewayRef` set but the gateway is gone/unconfigured →
    ///      THROW (drainer fails the share — preserve the locked
    ///      no-silent-reroute invariant).
    ///   5. Neither set (legacy / headless capture / no explicit target) →
    ///      the EXISTING pointer-driven behavior: resolve the active-conversation
    ///      pointer (TTL-gated by `SessionContinuationPolicy`); if it names a
    ///      local row, route by ITS backend; else snapshot+validate the DEFAULT
    ///      backend BEFORE minting a fresh thread.
    ///
    /// In every case the bound/target backend's snapshot must resolve AND carry a
    /// non-empty token, else `AppError.remoteAgentNotConfigured` is thrown (no
    /// silent reroute to the default gateway).
    ///
    /// - Parameters:
    ///   - overrideConversationID: the share manifest's "existing conversation"
    ///     pick (or any explicit thread id). `nil` → no existing-thread target.
    ///   - newConversationGatewayRef: the share manifest's "New conversation in
    ///     <Gateway>" pick (a `RemoteAgentRef.rawString`). `nil` → not a
    ///     new-on-gateway target.
    ///   - selectedBackendRef: the bound-gateway hint captured at share time for
    ///     the chosen EXISTING conversation (a `RemoteAgentRef.rawString`), used
    ///     as the mint fallback when that conversation was deleted before the
    ///     drain (precedence #2). `nil` → no fallback hint.
    ///   - settings / store: injectable for tests; production passes the
    ///     `.shared` singletons.
    static func resolveOrMint(
        overrideConversationID: UUID? = nil,
        newConversationGatewayRef: String? = nil,
        selectedBackendRef: String? = nil,
        settings: SettingsManager = .shared,
        store: ConversationStore = .shared
    ) async throws -> Resolved {
        // --- Precedence #1: an explicit EXISTING-conversation target ---
        if let overrideID = overrideConversationID {
            if let record = try? await store.fetchConversation(id: overrideID) {
                // The row exists → route by ITS bound backend (append).
                return try await resolveExistingRow(record, settings: settings)
            }
            // --- Precedence #2: the chosen conversation is GONE ---
            // Do NOT fall through to the default gateway (that would silently
            // reroute the user's pick). If we captured the conversation's bound
            // gateway at share time AND it is still configured, mint a fresh
            // thread on that SAME gateway; otherwise throw (drainer fails it).
            if let backendRaw = selectedBackendRef,
               let ref = RemoteAgentRef(rawString: backendRaw) {
                return try await mintOnRef(ref, settings: settings, store: store)
            }
            // No usable fallback hint → not-configured → the drainer fails it.
            throw AppError.remoteAgentNotConfigured
        }

        // --- Precedence #3 + #4: an explicit NEW-conversation-on-gateway target ---
        if let newRefRaw = newConversationGatewayRef {
            guard let ref = RemoteAgentRef(rawString: newRefRaw) else {
                // A malformed ref string can't be routed → throw (drainer fails it).
                throw AppError.remoteAgentNotConfigured
            }
            // #3 configured → mint; #4 gone/unconfigured → `mintOnRef` throws.
            return try await mintOnRef(ref, settings: settings, store: store)
        }

        // --- Precedence #5: legacy / no explicit target → pointer-driven ---
        // Quick-capture pointer resolution (TTL + default-gateway re-check).
        // A pointer that names a not-yet-imported / remotely-deleted row, OR a
        // row bound to a gateway that is no longer the default, is treated
        // exactly like "no pointer" (fall through to mint on the default —
        // never append to a ghost or to a re-pointed gateway's old thread).
        if let record = await resolveQuickCaptureConversation(settings: settings, store: store) {
            return try await resolveExistingRow(record, settings: settings)
        }

        // No live pointer → snapshot + validate the DEFAULT backend BEFORE minting
        // (a default with URL-but-no-token takes the not-configured path WITHOUT
        // leaving a stray empty thread).
        let defaultRef = await settings.defaultRemoteAgentRef()
        return try await mintOnRef(defaultRef, settings: settings, store: store)
    }

    /// Quick-capture pointer resolution with the default-gateway guard: a
    /// TTL-fresh pointer continues ONLY a conversation bound to the CURRENT
    /// default gateway; a mismatch (default re-pointed since the stamp, e.g.
    /// remotely via the KVS mirror) resolves nil → the caller mints fresh on
    /// the default. Returns the fetched record so callers skip a re-fetch.
    static func resolveQuickCaptureConversation(
        now: Date = Date(),
        settings: SettingsManager = .shared,
        store: ConversationStore = .shared
    ) async -> ConversationRecord? {
        guard let pointerID = await settings.resolveActiveConversationID(now: now),
              let record = try? await store.fetchConversation(id: pointerID) else {
            return nil
        }
        let defaultRef = await settings.defaultRemoteAgentRef()
        guard record.backend == defaultRef.rawString else { return nil }
        return record
    }

    // MARK: - Shared helpers

    /// Route by an EXISTING conversation row's bound backend. Nil snapshot
    /// (unknown raw OR unconfigured) OR empty token → not-configured (no
    /// silent reroute to the default gateway).
    private static func resolveExistingRow(
        _ record: ConversationRecord,
        settings: SettingsManager
    ) async throws -> Resolved {
        guard let snapshot = await settings.remoteAgentSnapshot(forConversationBackend: record.backend) else {
            throw AppError.remoteAgentNotConfigured
        }
        // Keyless (`.none`) routes with no token; `.bearer` requires a non-empty
        // token (fail closed — a nil token, e.g. a transient Keychain read
        // failure, is NOT treated as a silent keyless downgrade).
        let token = snapshot.token ?? ""
        if snapshot.authScheme.requiresToken, token.isEmpty {
            throw AppError.remoteAgentNotConfigured
        }
        // The stored backend resolved a snapshot, so its rawString is a valid
        // ref; guard defensively (a malformed raw that somehow snapshotted is
        // not-configured rather than a crash).
        guard let ref = RemoteAgentRef(rawString: record.backend) else {
            throw AppError.remoteAgentNotConfigured
        }
        return Resolved(conversationID: record.id, snapshot: snapshot, token: token, ref: ref)
    }

    /// Snapshot + validate `ref`'s token BEFORE minting a fresh conversation on
    /// it, then mint. A ref that is unknown / unconfigured / token-less throws
    /// `.remoteAgentNotConfigured` WITHOUT leaving a stray empty thread behind
    /// (the validate-before-mint order is load-bearing). Used by every mint path
    /// (default, new-on-gateway, deleted-conversation fallback) so the rule is
    /// identical across them.
    private static func mintOnRef(
        _ ref: RemoteAgentRef,
        settings: SettingsManager,
        store: ConversationStore
    ) async throws -> Resolved {
        guard let snapshot = await settings.remoteAgentSnapshot(for: ref) else {
            throw AppError.remoteAgentNotConfigured
        }
        // Keyless (`.none`) routes with no token; `.bearer` requires a non-empty
        // token (fail closed — a nil token, e.g. a transient Keychain read
        // failure, is NOT treated as a silent keyless downgrade).
        let token = snapshot.token ?? ""
        if snapshot.authScheme.requiresToken, token.isEmpty {
            throw AppError.remoteAgentNotConfigured
        }
        // Snapshot + token validated — only NOW mint the conversation (binds to
        // the ref's rawString — built-in OR custom).
        let fresh = try await store.createConversation(backend: ref.rawString)
        return Resolved(conversationID: fresh.id, snapshot: snapshot, token: token, ref: ref)
    }
}

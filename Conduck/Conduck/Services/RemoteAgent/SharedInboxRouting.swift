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
// Precedence #5 — the pointer-driven lane, the one with no picker in front of it
// — switches on `DefaultGatewayResolution` rather than on a bare ref, because
// the same nil snapshot means several different things and only one of them may
// say "your default is broken". A pointer at a gateway that is not set up HERE
// while others work throws code 74 and NAMES the broken one; a device with no
// chosen default at all throws 74 unnamed; a genuinely empty device and an
// abandoned half-setup keep code 12 and its existing copy; and a reading the
// Keychain cannot be trusted for accuses nobody and simply falls through to fail
// closed. `MintRole` carries that distinction into `mintOnRef`.
//
// ONE SNAPSHOT TURN drives that whole decision. Two reads of the default would
// describe two different moments — and under the resolver the default accessor
// can PERSIST an adoption, so a second read is not even free. The pointer check
// therefore takes the ref it was handed rather than fetching its own.
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

    /// Why a mint is happening, and therefore which not-configured verdict it
    /// owes the user. The same nil snapshot means three different things
    /// depending on how we arrived, and only one of them may say "your default
    /// is broken".
    private enum MintRole {
        /// The user NAMED this gateway (share-sheet pick, deleted-conversation
        /// fallback hint). "Your default isn't set up" would be a lie here — the
        /// default may be perfectly healthy and simply not the target.
        case explicitPick

        /// The stored default pointer, on a reading we can trust. Names the
        /// gateway so the user can fix the right one; the name is a DISPLAY
        /// NAME, never a URL.
        case defaultPointer(displayName: String?)

        /// The stored default pointer on a reading we CANNOT trust — a Keychain
        /// blackout looks identical to a deleted token from here. Fails closed
        /// with the existing, non-accusatory verdict rather than blaming a
        /// default that may be perfectly healthy behind a locked Keychain.
        case defaultPointerUnverified

        var notConfiguredError: AppError {
            switch self {
            case .explicitPick, .defaultPointerUnverified:
                return .remoteAgentNotConfigured
            case .defaultPointer(let displayName):
                return .remoteAgentDefaultNeedsSetup(gatewayName: displayName)
            }
        }
    }

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
                // `.explicitPick`: this ref came from the user's own share-time
                // choice, not from the default pointer, so a failure here says
                // nothing about the default.
                return try await mintOnRef(ref, role: .explicitPick, settings: settings, store: store)
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
            // `.explicitPick` for the same reason as #2: the user named it.
            return try await mintOnRef(ref, role: .explicitPick, settings: settings, store: store)
        }

        // --- Precedence #5: legacy / no explicit target → pointer-driven ---
        // ONE snapshot turn feeds both the pointer check and the mint decision,
        // so the two describe the same instant.
        let snap = await settings.newChatPickerSnapshot()

        // Quick-capture pointer resolution (TTL + default-gateway re-check).
        // A pointer that names a not-yet-imported / remotely-deleted row, OR a
        // row bound to a gateway that is no longer the default, is treated
        // exactly like "no pointer" (fall through to mint on the default —
        // never append to a ghost or to a re-pointed gateway's old thread).
        if let record = await resolveQuickCaptureConversation(
            defaultRef: snap.defaultRef, settings: settings, store: store) {
            return try await resolveExistingRow(record, settings: settings)
        }

        // No live pointer → the verdict decides what happens and what is said.
        switch snap.resolution {
        case .usable, .adopted, .bootstrapped:
            // The pointer can send. Snapshot + validate BEFORE minting, so a
            // gateway that lost its token between the resolve and the mint takes
            // the not-configured path WITHOUT leaving a stray empty thread.
            // `.explicitPick` semantics: there is nothing to accuse here, and a
            // nil snapshot at this point is a race we describe honestly.
            return try await mintOnRef(snap.resolution.ref, role: .explicitPick,
                                       settings: settings, store: store)

        case .defaultUnavailable(let pointer, _, let pointerIsParked):
            // The roster genuinely offers alternatives. NAME the pointer — a
            // DISPLAY NAME, never a URL — and let the user fix it in one tap.
            // Nothing is minted and nothing is re-pointed.
            //
            // A REFUSAL is one of the few places left that names an unavailable
            // default: the user acted, so an unnamed "something didn't work" would
            // be worse than the name. The quiet surfaces (the chat window, the
            // catalog rows) stay silent precisely so this one can speak.
            //
            // A pointer the APP parked after a Forget carries no name: the user
            // never chose that gateway, so "your default AI, X" would blame them
            // for a placeholder. The unnamed copy is the true sentence there,
            // and the pre-flight that guards this lane says the same thing.
            guard !pointerIsParked else {
                throw AppError.remoteAgentDefaultNeedsSetup(gatewayName: nil)
            }
            throw AppError.remoteAgentDefaultNeedsSetup(
                gatewayName: RemoteAgentRefMetadata.displayName(for: pointer, customs: snap.badgeRoster))

        case .selectionRequired:
            // No pointer, and the device cannot honestly infer one. There is no
            // gateway to name, so the unnamed copy carries it: "Conduck doesn't
            // know which AI to use for new chats."
            throw AppError.remoteAgentDefaultNeedsSetup(gatewayName: nil)

        case .nothingConfigured, .setupUnfinished:
            // Nothing can send and the reading IS trustworthy. Code 12's
            // existing copy is accurate for both — one is the honest first run,
            // the other an abandoned setup, and neither has an alternative to
            // offer.
            throw AppError.remoteAgentNotConfigured

        case .readingUnreliable:
            // Nothing can send AND the reading cannot be trusted: some gateway
            // meets every non-Keychain requirement and is waiting only on a
            // token that does not read back (an after-first-unlock blackout, or
            // a half-arrived iCloud Keychain sync). Refuse nothing, accuse
            // nothing, persist nothing — fall through and let the send fail
            // closed with code 12 exactly as it does on a genuinely empty
            // device. If the reading was wrong, that costs the user nothing.
            return try await mintOnRef(snap.resolution.ref, role: .defaultPointerUnverified,
                                       settings: settings, store: store)
        }
    }

    /// Quick-capture pointer resolution with the default-gateway guard: a
    /// TTL-fresh pointer continues ONLY a conversation bound to the CURRENT
    /// default gateway; a mismatch (default re-pointed since the stamp, e.g.
    /// remotely via the KVS mirror) resolves nil → the caller mints fresh on
    /// the default. Returns the fetched record so callers skip a re-fetch.
    ///
    /// - Parameter defaultRef: the default pointer to compare against. A caller
    ///   that already holds a `NewChatPickerSnapshot` passes its ref so the
    ///   pointer check and the mint decision describe the SAME instant — and so
    ///   the default is resolved once, which matters because resolving it can
    ///   persist an adoption. `nil` reads it here, for the menu-bar callers that
    ///   hold no snapshot.
    static func resolveQuickCaptureConversation(
        now: Date = Date(),
        defaultRef: RemoteAgentRef? = nil,
        settings: SettingsManager = .shared,
        store: ConversationStore = .shared
    ) async -> ConversationRecord? {
        guard let pointerID = await settings.resolveActiveConversationID(now: now),
              let record = try? await store.fetchConversation(id: pointerID) else {
            return nil
        }
        // Spelled out rather than `??` — the right-hand side of a nil-coalesce is
        // an autoclosure, which cannot carry the `await`.
        let effective: RemoteAgentRef
        if let defaultRef {
            effective = defaultRef
        } else {
            effective = await settings.defaultRemoteAgentRef()
        }
        guard record.backend == effective.rawString else { return nil }
        return record
    }

    /// Whether a capture taken RIGHT NOW would land on an existing conversation
    /// this device can actually send on — precedence #5's pointer arm, asked as a
    /// yes/no and answered by the same two helpers `resolveOrMint` uses.
    ///
    /// It exists for the pre-flight (`CheckNetworkIntent`), which refuses before
    /// the microphone on the DEFAULT pointer's verdict. A capture that continues
    /// a live conversation never touches the default, so a verdict about the
    /// default must not refuse it — and the only way the two can be certain to
    /// agree is to ask the same question through the same code. A second copy of
    /// the rule is exactly how they drift.
    ///
    /// PER-CONVERSATION BINDING IS UNTOUCHED. This answers false whenever the
    /// pointer's conversation is bound to a gateway that is not set up here, so
    /// the refusal a bound-but-unconfigured gateway earns stands exactly as it
    /// does with no pointer at all. Nothing is minted, nothing is re-pointed,
    /// nothing is persisted: both helpers only read.
    ///
    /// - Parameter defaultRef: the default to compare the pointer against, from
    ///   the caller's own snapshot, so the pre-flight and the router describe the
    ///   same instant.
    static func liveQuickCaptureCanContinue(
        now: Date = Date(),
        defaultRef: RemoteAgentRef? = nil,
        settings: SettingsManager = .shared,
        store: ConversationStore = .shared
    ) async -> Bool {
        guard let record = await resolveQuickCaptureConversation(
            now: now, defaultRef: defaultRef, settings: settings, store: store) else {
            return false
        }
        return (try? await resolveExistingRow(record, settings: settings)) != nil
    }

    // MARK: - Shared helpers

    /// Route by an EXISTING conversation row's bound backend. Nil snapshot
    /// (unknown raw OR unconfigured) OR empty token → not-configured (no
    /// silent reroute to the default gateway).
    ///
    /// All three refusals here stay `.remoteAgentNotConfigured`, and that is
    /// deliberate. A conversation that already has turns is BOUND to its
    /// gateway: routing is per-conversation, and a bound ref that is not set up
    /// on this device must refuse with its existing meaning and its existing
    /// code. `.remoteAgentDefaultNeedsSetup` must NEVER appear on this path — it
    /// offers to fix the default for new chats, which would read as an offer to
    /// re-point a thread the app is forbidden to re-point. Cloning the chat onto
    /// another gateway is the only exit, and the user makes that choice.
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
    /// WITHOUT leaving a stray empty thread behind (the validate-before-mint
    /// order is load-bearing). Used by every mint path (default,
    /// new-on-gateway, deleted-conversation fallback) so the rule is identical
    /// across them.
    ///
    /// - Parameter role: WHY this mint is happening, and therefore which
    ///   not-configured verdict the user is owed. Every mint path funnels
    ///   through here, so the error cannot be a property of the function — it
    ///   has to be a property of the arrival.
    private static func mintOnRef(
        _ ref: RemoteAgentRef,
        role: MintRole,
        settings: SettingsManager,
        store: ConversationStore
    ) async throws -> Resolved {
        guard let snapshot = await settings.remoteAgentSnapshot(for: ref) else {
            throw role.notConfiguredError
        }
        // Keyless (`.none`) routes with no token; `.bearer` requires a non-empty
        // token (fail closed — a nil token, e.g. a transient Keychain read
        // failure, is NOT treated as a silent keyless downgrade).
        let token = snapshot.token ?? ""
        if snapshot.authScheme.requiresToken, token.isEmpty {
            throw role.notConfiguredError
        }
        // Snapshot + token validated — only NOW mint the conversation (binds to
        // the ref's rawString — built-in OR custom).
        let fresh = try await store.createConversation(backend: ref.rawString)
        return Resolved(conversationID: fresh.id, snapshot: snapshot, token: token, ref: ref)
    }
}

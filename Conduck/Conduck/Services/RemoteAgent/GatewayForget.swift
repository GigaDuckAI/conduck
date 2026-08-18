// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayForget.swift
//
// The ONE Forget. Everything a gateway leaves behind, removed in the one order
// that is safe: file lane first, badge retired, last-used cleared, the Watch
// default override dropped, customs routed through `deleteCustomGateway`,
// auxiliary slots cleared, the default re-pointed, the Watch teardown latch
// armed, the active session cleared.
//
// The order is not cosmetic. The file lane goes first because
// `revokeFileTransferReadiness` writes `available=false` to iCloud KVS, and that
// revocation must reach the peers no later than the gateway teardown — otherwise
// a peer can pair a reconfigured gateway with a Ready the FORGOTTEN server
// earned. A custom's badge is frozen before its roster entry is deleted, because
// the roster entry is the only place its monogram and colour exist and
// conversations keep their `custom_<uuid>` binding forever.
//
// It lives outside `SettingsViewModel` as the single storage-side owner of the
// teardown. Two independently written forget paths is exactly how a gateway comes
// back from the dead, and this sequence is long enough — credential wipe, badge
// freeze, peer revocation, lane teardown — that a second copy would drift. Its
// only caller today reaches it through a view model, which still refreshes its
// own mirrors afterwards; that is not a reason to fold the storage side back in.
//
// A destructive credential wipe hangs off THIS explicit user intent and never
// off a shared rollback helper: `deleteCustomGateway` and
// `clearRemoteAgentAuthScheme` both double as the token-write-FAILURE rollback
// for a brand-new save, and a 32-hex credential destroyed by a transient
// Keychain error is unrecoverable — the user would have to re-provision their
// server.

import Foundation

@MainActor
enum GatewayForget {

    /// Forget `ref` completely. Storage side only — the caller refreshes any
    /// view-model mirrors it owns.
    static func perform(ref: RemoteAgentRef) async {
        // Refined pointer-clear: drop the active-conversation pointer ONLY when
        // it is bound to the ref being forgotten. Capture BEFORE the slot wipe.
        let activeConvBackend = await activeConversationBackendRawValue()
        let shouldClearPointer = SettingsViewModel.shouldClearActivePointer(
            activeConvBackend: activeConvBackend,
            changedRef: ref
        )

        // File lane FIRST (invalidate-first ordering, same doctrine as
        // `clearFileTransferConfig` itself): `available=false` must reach iCloud
        // KVS no later than the gateway teardown, so no peer can pair a
        // reconfigured gateway with a Ready the forgotten server earned.
        await wipeFileLane(for: ref)

        // Forgetting a gateway retires it as the new-chat pre-selection. Both
        // kinds need this explicitly: the built-in branch below only re-points the
        // default when the forgotten gateway WAS the default, so a forgotten
        // non-default built-in would otherwise leave the pointer behind — and
        // built-in refs are reused when the user sets that lane up again, so the
        // stale pointer would come back to life naming a different server.
        //
        // HERE, not inside `deleteCustomGateway`, for the same reason the badge
        // retire and the file-lane wipe above are: that method doubles as the
        // failed-save rollback for a brand-new draft, and clearing there would
        // discard a perfectly good pointer whenever an unrelated save failed.
        await SettingsManager.shared.clearLastUsedRemoteAgentRefIfPointing(at: ref)

        // The Watch default override obeys the same rule, for the same reason,
        // and needs the same both-kinds treatment. `watchDefaultOverrideRef()`
        // ignores-but-retains a dangling override on purpose (a fail-closed
        // Keychain read is not evidence of intent), so nothing else drops it —
        // and a reused built-in ref would bring it back to life against a
        // DIFFERENT server the next time the user configures that lane, routing
        // every wrist capture there silently. The custom branch below clears it
        // again inside `deleteCustomGateway`, which owns that clear because it is
        // also reached from the Settings row delete; this call is what covers the
        // built-in branch.
        await SettingsManager.shared.clearWatchDefaultOverrideIfPointing(at: ref)

        if case .custom(let id) = ref {
            // Freeze the badge FIRST — the roster entry about to be deleted is
            // the only place the monogram and colour exist, and the monogram is
            // usually derived from the name. Conversations bound to this gateway
            // keep their `custom_<uuid>` binding forever, so without this they
            // would render a blank gap where their colour tag used to be, while
            // a forgotten BUILT-IN keeps its badge for free.
            //
            // Attached HERE and not inside `deleteCustomGateway`, for the same
            // reason the file-lane wipe above is: that method doubles as the
            // failed-save rollback for a brand-new draft, and retiring there
            // would leave a tombstone for a gateway that never existed.
            await SettingsManager.shared.retireCustomGatewayBadge(id: id)
            // `deleteCustomGateway` clears the per-ref url/token/cert slots +
            // the roster entry + re-points the default if it pointed here — the
            // whole "forget a custom" operation. Don't double-wipe the per-ref
            // slots here.
            await SettingsManager.shared.deleteCustomGateway(id: id)
        } else {
            try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
            await SettingsManager.shared.setRemoteAgentURL(nil, for: ref)
            await SettingsManager.shared.setRemoteAgentCertFingerprint(nil, for: ref)
            await SettingsManager.shared.clearRemoteAgentAuthScheme(for: ref)
            // Wipe the per-ref model slot too (hosted built-ins like OpenRouter)
            // so a reconfigured backend never inherits a stale model. No-op for
            // self-hosted built-ins — they never write the slot.
            await SettingsManager.shared.setRemoteAgentModel(nil, for: ref)
            // Image-history policy, transport hint, last-success record, and the
            // retired single-config slot. Without these, Forget leaves per-ref
            // keys behind that read as evidence the gateway still exists.
            await SettingsManager.shared.clearAuxiliaryRemoteAgentSlots(for: ref)
            // ONE re-point rule, shared with the custom branch inside
            // `deleteCustomGateway`, so the two cannot drift: a SINGLE surviving
            // send-able gateway is adopted and announced; two or more park on a
            // built-in so the user chooses their next gateway rather than
            // inheriting one. It no-ops unless the RAW stored pointer named the
            // forgotten ref, which is why nothing here has to capture it first.
            await SettingsManager.shared.repointDefaultAfterForget(of: ref)
        }

        // Arm the Watch teardown latch when this Forget left the device with no
        // gateway evidence at all. This is the ONLY place the intent exists:
        // the broadcast composer sees an empty configured set, which is also
        // what a pre-sync or locked-Keychain read looks like, so it can never
        // distinguish "the user deleted everything" from "this process cannot
        // see anything yet". Without the latch the wrist keeps a live route —
        // URL, auth scheme and Keychain token — to a gateway the user believes
        // they disconnected, across relaunches, because Forget is local to the
        // phone and the token stays valid at the server.
        //
        // The test spans CONFIGURED plus PARTIALLY-configured, never
        // `configuredRemoteAgentRefs()` alone: arming must not depend on the
        // fail-closed bearer predicate, or a Forget performed while ANOTHER
        // gateway's token is momentarily unreadable would courier a teardown
        // that destroys it on the wrist.
        //
        // Nor `removableRemoteAgentRefs()`, which is deliberately WIDER — it
        // counts auxiliary residue (a transport hint, an image-history policy)
        // that a Forget can leave behind. Residue is not a gateway, and gating
        // on it would leave the latch permanently unarmed on exactly the device
        // that has some, so the wrist would never be told.
        let stillConfigured = await SettingsManager.shared.configuredRemoteAgentRefs()
        let stillPartial = await SettingsManager.shared.partiallyConfiguredRemoteAgentRefs()
        if stillConfigured.isEmpty, stillPartial.isEmpty {
            await SettingsManager.shared.setUserClearedAllGateways(true)
        }

        // The active SESSION pointer is global; a forgotten gateway invalidates
        // any session that might have been minted against it. Clear globally
        // (Decision A) — defensive, matches the prior single-config behavior.
        await SettingsManager.shared.setRemoteAgentActiveSession(nil)

        if shouldClearPointer {
            await SettingsManager.shared.clearActiveConversation()
        }
    }

    /// The STORAGE half of forgetting a ref's file-server lane. Split out so the
    /// guide's standalone "Forget file transfer" action and the whole-gateway
    /// Forget above share one wipe rather than two that can drift.
    ///
    /// Readiness first (invalidate-first ordering, single actor choke point):
    /// `available=false` must reach KVS no later than the config teardown below,
    /// and Forget also forfeits local test proof + probe markers so a later re-add
    /// cannot inherit stale provenance that would mis-arm the silent re-probe
    /// before the new config is re-tested.
    static func wipeFileLane(for ref: RemoteAgentRef) async {
        await SettingsManager.shared.revokeFileTransferReadiness(for: ref)
        try? await SettingsManager.shared.clearFileServerCredential(for: ref)
        await SettingsManager.shared.setFileServerURL(nil, for: ref)
        await SettingsManager.shared.setFileServerCertFingerprint(nil, for: ref)
        // Reset capability to its default (folder-capable true, re-probed on
        // the next Test Connection). The image-history policy is deliberately
        // NOT touched: it is gateway-scoped (lives in the gateway editor's
        // Advanced section, applies to server-less endpoints too), not part of
        // the file-transfer config this action forgets.
        await SettingsManager.shared.setFileServerFolderCapable(true, for: ref)
    }

    /// Resolve the backend raw value the CURRENTLY-active conversation is bound
    /// to, or nil when there is no active conversation pointer (or the record
    /// can't be fetched). The pointer itself is global; the backend binding lives
    /// on the `ConversationRecord`.
    private static func activeConversationBackendRawValue() async -> String? {
        guard let id = await SettingsManager.shared.currentActiveConversationID() else {
            return nil
        }
        let record = try? await ConversationStore.shared.fetchConversation(id: id)
        return record?.backend
    }
}

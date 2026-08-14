// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModel+PairingImport.swift
//
// Pairing-import lifecycle for a parsed `PairingPayload` (QR scan / pasted
// `conduck-setup:` string): plan → (optional overwrite confirm) → execute
// (persist-only) → optional gateway test. The UI (onboarding + Settings
// import sheet) drives the four entry points below; ALL persistence funnels
// through the existing single commit point `saveRemoteAgent(ref:name:stagedToken:)`
// so the import path can never drift from the editor's save semantics
// (https-only guard, explicit auth-scheme persist, fail-closed token write,
// session/pointer hygiene, roster upsert).
//
// PRIVACY (non-negotiable — spec.md "Privacy & Security"): the payload embeds the
// gateway bearer token and the file-server credential. NEVER log / print /
// retain the payload, the token, the credential, or any derived string;
// failure messages reuse the existing `AppError` recovery copy, which never
// embeds secrets or URLs.

import Foundation

/// Why a pairing import cannot proceed at the resolved target at all — the
/// sheet surfaces these as terminal states (no retry at this target).
enum PairingImportBlock: Equatable {
    /// Custom payload + no free roster slot (`Constants.maxCustomGateways`).
    case customGatewayCapReached
    /// The payload's kind doesn't match the locked target (e.g. the user
    /// opened "Set up Hermes" but scanned an OpenClaw / custom code).
    /// `expectedDisplayName` is the payload's natural display name — the
    /// built-in's `displayName` or the custom payload's user-given name — so
    /// the sheet can say "this code is for X".
    case kindMismatch(expectedDisplayName: String)
}

/// The resolved plan for importing a parsed pairing payload — computed by
/// `planPairingImport(_:lockedTarget:)` BEFORE anything is persisted.
enum PairingImportPlan: Equatable {
    /// Target resolved and its URL slot is empty — import directly.
    case ready(target: RemoteAgentRef)
    /// Target resolved but already holds a configured URL — the sheet must
    /// ask before `executePairingImport` overwrites it. Both URLs are
    /// surfaced so the user can compare what they're replacing.
    case needsOverwriteConfirm(target: RemoteAgentRef, existingURL: String, newURL: String)
    /// Import cannot proceed at this target.
    case blocked(PairingImportBlock)
}

/// Outcome of `executePairingImport`. Three-state because the GATEWAY half
/// commits atomically through `saveRemoteAgent`, but an optional file-server
/// credential lands in a SEPARATE Keychain write — when that second write
/// fails, the gateway is already fully configured and must be reported as
/// such (never as "nothing saved": the user would retry into their own
/// overwrite-confirm and the Settings list would contradict the error).
enum PairingImportOutcome: Equatable {
    /// Everything in the payload persisted.
    case committed
    /// Gateway persisted; the file-server half was rolled back because its
    /// credential could not be written to the Keychain.
    case committedGatewayOnly
    /// Nothing persisted (a `saveRemoteAgent` guard rejected the commit).
    case failed
}

/// Outcome of the optional post-import connectivity test
/// (`runPairingGatewayTest`). Mirrors the editor's Test Connection states but
/// as a returned value (the pairing sheet owns its own presentation, not the
/// per-ref validation row).
enum PairingGatewayTestOutcome: Equatable {
    case passed
    /// Probe failed — `message` is the existing user-facing `AppError`
    /// recovery copy (never embeds the token or URL) and `error` is the
    /// taxonomy entry that produced it. An untrusted certificate lands here
    /// like any other failure: there is no first-contact affordance to route it
    /// to, because a pin cannot make an untrusted chain acceptable to the
    /// system.
    ///
    /// THE ERROR TRAVELS WITH THE MESSAGE, and that is the load-bearing part. A
    /// message alone is prose — it cannot tell a gateway that is merely down
    /// from a certificate this device refuses, so the sheet's recovery section
    /// offered "Try again" on a verdict that reaches the identical answer every
    /// attempt. Every other failure surface gates on `AppError.isRetryable`
    /// (`DeclinedTurnPresentation.offersRetry`, `StagedAttachment.failure(for:)`,
    /// `ServerFileDownloadChip.acceptsTap`); carrying the error here is what
    /// lets this one do the same instead of special-casing certificates.
    ///
    /// `nil` only where no typed error stands behind the copy — unknown is not
    /// terminal, so it keeps the retry.
    case failed(message: String, error: AppError?)

    /// `AppError` is `LocalizedError`, NOT `Equatable` (its `Error`-carrying
    /// cases can't synthesize `==`), so compare the failure by its stable
    /// numeric `errorCode` — the same shape `FileTransferTestResult` uses, and
    /// for the same reason: this value stays `Equatable` for tests without
    /// forcing an `AppError: Equatable` conformance across the whole taxonomy.
    static func == (lhs: PairingGatewayTestOutcome, rhs: PairingGatewayTestOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.passed, .passed):
            return true
        case let (.failed(lhsMessage, lhsError), .failed(rhsMessage, rhsError)):
            return lhsMessage == rhsMessage && lhsError?.errorCode == rhsError?.errorCode
        case (.passed, .failed), (.failed, .passed):
            return false
        }
    }
}

extension SettingsViewModel {

    // MARK: - Plan

    /// Resolve where a parsed payload would land and whether the user must
    /// confirm an overwrite first. Persists NOTHING except (for an unlocked
    /// custom payload) an in-memory roster DRAFT minted via
    /// `newCustomGatewayDraftID()` — discard it with `discardPairingDraft(_:)`
    /// if the user backs out before `executePairingImport`.
    ///
    /// `lockedTarget` pins the destination (the per-gateway "Import setup
    /// code" entry points): a payload whose kind doesn't match it is
    /// `.blocked(.kindMismatch)` — a builtin payload only matches ITS OWN
    /// builtin ref; a custom payload matches any custom ref (it imports into
    /// that existing gateway, no new roster entry).
    func planPairingImport(_ payload: PairingPayload, lockedTarget: RemoteAgentRef?) async -> PairingImportPlan {
        let target: RemoteAgentRef
        switch payload.kind {
        case .builtin(let backend):
            if let lockedTarget {
                guard lockedTarget == .builtin(backend) else {
                    return .blocked(.kindMismatch(expectedDisplayName: backend.displayName))
                }
                target = lockedTarget
            } else {
                target = .builtin(backend)
            }
        case .custom(let name):
            if let lockedTarget {
                guard case .custom = lockedTarget else {
                    return .blocked(.kindMismatch(expectedDisplayName: name))
                }
                // Import into the locked existing custom — no new roster entry.
                target = lockedTarget
            } else {
                // Mint a fresh draft slot (in-memory only — nothing persists
                // until `executePairingImport` runs `saveRemoteAgent`). Nil =
                // the cap-of-`Constants.maxCustomGateways` is reached.
                guard let id = newCustomGatewayDraftID() else {
                    return .blocked(.customGatewayCapReached)
                }
                target = .custom(id)
            }
        }

        // Overwrite check AFTER resolution. A freshly minted draft has no
        // stored URL, so it can never trip this.
        if let existing = await SettingsManager.shared.getRemoteAgentURL(for: target) {
            return .needsOverwriteConfirm(
                target: target,
                existingURL: existing.absoluteString,
                newURL: payload.url.absoluteString
            )
        }
        return .ready(target: target)
    }

    // MARK: - Review (what the user is shown before anything is written)

    /// Gather the facts the import review card renders for `payload` landing on
    /// `target`. Reads only — like `planPairingImport`, it writes nothing.
    ///
    /// Deliberately re-readable and `Equatable` in its result: the card is built
    /// once when the code is scanned and again when Connect is tapped, and the
    /// two are compared. If a peer device's iCloud sync, a second window, or the
    /// user's own edit changed the destination in between, the reviewed screen no
    /// longer describes what would happen — so the sheet re-presents instead of
    /// executing a decision the user made about different facts.
    ///
    /// - Parameter freshlyMinted: true when `planPairingImport` minted a brand-new
    ///   custom draft for this import. Such a target has no local name yet, and
    ///   the only name available is the one the CODE chose — which is exactly
    ///   what the card refuses to render, so it stays nameless.
    func pairingReview(
        for payload: PairingPayload,
        target: RemoteAgentRef,
        freshlyMinted: Bool
    ) async -> PairingReviewModel {
        // Every fact below is read from the STORE, not from this view model's
        // caches. The card is not only what the user reads — it is also the
        // snapshot the commit is checked against, and a second window or a
        // peer's iCloud sync lands in storage BEFORE the cached reload reaches
        // this view model. A snapshot built from caches would therefore compare
        // equal to itself while the thing it describes had already moved.
        let existingGatewayURL = await SettingsManager.shared.getRemoteAgentURL(for: target)
        let storedFileServerURL = await SettingsManager.shared.getFileServerURL(for: target)
        let configuredRefs = await SettingsManager.shared.configuredRemoteAgentRefs()

        // "Configured" means URL *and* credential. Credential presence is the one
        // signal with no cheap store read (it lives in the Keychain), so it stays
        // the cached mirror — but pairing it with a STORED url means a stale
        // cache can only under-claim, never promise a lane that isn't there.
        let existingFileServerDestination: String? = {
            guard fileServerCredentialPresent[target] == true else { return nil }
            return storedFileServerURL?.absoluteString
        }()

        // Local identity only. A built-in's name is the app's own; a custom's is
        // read from the persisted roster rather than the cached one, for the same
        // freshness reason. A freshly minted draft has neither — see `targetName`.
        var targetName: String? = nil
        if !freshlyMinted {
            switch target {
            case .builtin(let backend):
                targetName = backend.displayName
            case .custom(let id):
                targetName = await SettingsManager.shared.customGateway(id: id)?.name
            }
        }

        return PairingReviewModel.make(
            payload: payload,
            existingGatewayURL: existingGatewayURL,
            existingFileServerDestination: existingFileServerDestination,
            targetName: targetName,
            anyGatewayConfigured: !configuredRefs.isEmpty
        )
    }

    // MARK: - Discard (cancel before execute)

    /// Drop the unsaved custom DRAFT a `planPairingImport` minted — called
    /// when the user cancels at the overwrite/confirm stage. Routes through
    /// `cancelRemoteAgentEdit(ref:)`, whose draft path drops the in-memory
    /// roster row + per-ref buffers ONLY when the ref never reached the store
    /// (so a persisted gateway passed as `target` is left intact — its
    /// buffers are simply re-hydrated from storage). No-op for built-ins.
    ///
    /// Fire-and-forget by design: the store-authority check is an actor hop,
    /// but the sheet's cancel path is synchronous UI. The removal lands on
    /// the main actor within the same run-loop turn after the hop.
    func discardPairingDraft(_ target: RemoteAgentRef) {
        guard case .custom = target else { return }
        Task { await cancelRemoteAgentEdit(ref: target) }
    }

    // MARK: - Execute (persist-only — zero network)

    /// Persist the payload into `target`'s slots. Zero network — the optional
    /// connectivity probe is `runPairingGatewayTest`, invoked separately so a
    /// dead gateway still imports (matching the editor's "Save commits even
    /// if untested" posture). See `PairingImportOutcome` — a file-server
    /// credential write failing AFTER the gateway committed reports
    /// `.committedGatewayOnly`, never a total failure.
    ///
    /// Default rule: the first-gateway-ever bootstrap lives in `saveRemoteAgent`
    /// (the shared commit point), so an import of the first gateway makes it the
    /// default exactly like a manual save; a later import never touches the
    /// user's default pointer.
    /// - Parameters:
    ///   - resolvedGatewayPin: the certificate pin to persist for the gateway —
    ///     `nil` for ordinary system trust. This is the DECIDED value from
    ///     `resolvePairingTrust`. Keeping it a parameter is what makes "no pin
    ///     from a setup code ever reaches storage" readable at the call site
    ///     rather than inferable from the payload type: this method takes its
    ///     pins from a decision, and a payload has no certificate field to
    ///     offer one from.
    ///   - resolvedFileServerPin: the same, for the file-server lane.
    func executePairingImport(
        _ payload: PairingPayload,
        target: RemoteAgentRef,
        resolvedGatewayPin: String?,
        resolvedFileServerPin: String?
    ) async -> PairingImportOutcome {
        // Seed the per-ref editor buffers `saveRemoteAgent` commits from.
        // The auth scheme MUST be seeded before the save — especially for a
        // keyless payload, where an unseeded buffer would fall back to
        // `.bearer` and fail the token guard.
        remoteAgentURLStrings[target] = payload.url.absoluteString
        remoteAgentAuthSchemes[target] = payload.authScheme
        // The DECIDED pin — see the parameter docs. Empty clears any pin the
        // slot held, which is right: an import replaces the gateway wholesale,
        // and a pin the user typed for the OLD certificate would fail TLS
        // against the new one.
        remoteAgentCertFingerprints[target] = resolvedGatewayPin ?? ""
        var customName: String? = nil
        if case .custom(let name) = payload.kind {
            customName = name
            // Seed the model ONLY when the payload carries one — a re-import
            // into a locked existing target (Quick connect) must not clear a
            // hand-set model just because the code omitted the optional field.
            if let model = payload.model {
                remoteAgentModelStrings[target] = model
            }
        }

        // Single commit point — roster upsert (custom) → URL → auth scheme →
        // token (fail-closed) → cert pin → session/pointer hygiene.
        // A payload token stages as `.typed`; none stages `.stored` (keeps any
        // already-saved token — e.g. re-importing a keyless payload's URL tweak).
        let stagedToken: StagedRemoteAgentToken = {
            guard let token = payload.token, !token.isEmpty else { return .stored }
            return .typed(token)
        }()
        guard await saveRemoteAgent(ref: target, name: customName, stagedToken: stagedToken) else {
            return .failed
        }

        // Transport hint — App-Group only (per-device guidance; nil removes,
        // so re-importing a payload without a hint clears a stale one).
        await SettingsManager.shared.setRemoteAgentTransportHint(payload.transport?.rawValue, for: target)

        // Optional file-server block.
        var outcome: PairingImportOutcome = .committed
        if let fileServer = payload.fileServer {
            // Fail-closed order: the import REPLACES the file-server tuple, so
            // an already-earned Ready drops BEFORE any tuple write — locally
            // AND in iCloud KVS, so neither this device nor a peer can pair
            // the incoming server with a verdict the OLD server earned. Then
            // the CREDENTIAL lands first — if that Keychain write fails,
            // nothing else was touched and the old URL/pin/credential stay a
            // complete, consistent tuple (no half-state to roll back; local
            // test proof still describes that intact old tuple, so it is
            // deliberately NOT forfeited on that path). Only after the
            // credential proves out does ONE actor hop commit URL + pin —
            // which also forfeits the old lane's local test proof and
            // silent-probe markers (identity changed; see
            // `commitFileTransferConfig`).
            await dropFileTransferAvailability(for: target)
            do {
                try await SettingsManager.shared.setFileServerCredential(fileServer.credential, for: target)
            } catch {
                // File-server half skipped entirely; the gateway half is
                // already committed and stays (see `PairingImportOutcome`).
                outcome = .committedGatewayOnly
            }
            if outcome == .committed {
                // File-server pin: the DECIDED value, which `resolvePairingTrust`
                // only ever resolves to nil. Still routed through the SAME
                // normalization the save path uses, so a future decision that
                // does yield a pin cannot land in a form the persisted mirror
                // and the draft signature disagree about.
                let rawPin: String? = resolvedFileServerPin
                let pin: String?
                if case .valid(let hex) = Self.normalizeCertFingerprint(rawPin) {
                    pin = hex
                } else {
                    pin = nil
                }
                // The lane's delivery properties ride in from the code; its
                // READINESS does not. `available: false` is unconditional and has no
                // payload input — the code describes a SERVER, and readiness is this
                // device's own proof that IT can reach, trust and authenticate
                // against that server. The scanning device may be off the network the
                // code was minted on (a tailnet-only lane is the ordinary case) and
                // evaluates the certificate chain in its own trust store, so it earns
                // Ready with its own staged Test Connection. The wire format carries
                // no readiness field for exactly this reason.
                //
                // Each field is nil-means-unchanged in the commit hop, and the parser
                // hands nil for an absent or off-shape key — so a code minted before
                // these keys existed leaves the destination's own stored values (and
                // their defaults) exactly as they were, rather than resetting them to
                // something the code never said.
                //
                // `autoDeliver` is MONOTONIC: a code may restrict the permission,
                // never grant it. A setup code is attacker-craftable and the review
                // card the user approves names the destination, not the permissions —
                // so honouring a `true` would let a scanned code quietly switch
                // automatic delivery back on for a gateway where the user (later, a
                // seat policy) had switched it off, and the user would have approved
                // a screen that never mentioned it. Nothing is lost by refusing:
                // `true` is already the stored default, so the only state a `true`
                // could change is the one deliberate `false` this rule protects.
                let grantedAutoDeliver = fileServer.autoDeliver == false ? false : nil
                // `folderCapable` IS APPLIED IN BOTH DIRECTIONS, and the asymmetry
                // with the line above is deliberate rather than an oversight. The
                // exporter states only the `false` verdict, so a positive value can
                // only reach here from a hand-crafted code — and that is still
                // harmless, for three reasons that do not hold for `autoDeliver`:
                //
                //   * KIND. This is a MEASUREMENT of the server (does it accept a
                //     nested PUT), not a permission granted to the gateway. There
                //     is no privilege in it to escalate — the worst a wrong `true`
                //     buys an attacker is uploads that fail against a server that
                //     rejects nested keys, on the user's own machine.
                //   * SCOPE. The value it overwrites describes the server this very
                //     commit is REPLACING, url and credential and all, so a `true`
                //     overrides nothing the user still owns. `autoDeliver` survives
                //     a server swap precisely because it is about the gateway
                //     rather than about whatever host it currently points at.
                //   * SELF-CORRECTION. The import deliberately leaves the lane
                //     not-ready (`available: false`), so the user must run a staged
                //     Test Connection before anything uses it — and that test's
                //     nested probe writes this same key from its own measurement.
                //     Nothing re-derives a permission, which is why `autoDeliver`
                //     gets no second chance to be corrected.
                //
                // Clamping it to `false`-only would change nothing for a real code
                // (the exporter emits nil for the default) while quietly turning a
                // two-valued measurement channel into a one-valued one — a trap for
                // the day a `conduck-connect` has reason to state the positive.
                await SettingsManager.shared.commitFileTransferConfig(
                    url: fileServer.url,
                    pin: pin,
                    folderCapable: fileServer.folderCapable,
                    available: false,
                    autoDeliver: grantedAutoDeliver,
                    filenamePolicy: fileServer.filenamePolicy,
                    for: target
                )

                // Refresh the VM's file-server buffers + persisted mirrors the
                // way the setup guide's Save does. Availability stays false
                // until the staged Test Connection passes (Decision C). The
                // credential is a NEW password — bump its generation and retire
                // any verdict the old one earned.
                fileServerURLStrings[target] = fileServer.url.absoluteString
                fileServerPersistedURLStrings[target] = fileServer.url.absoluteString
                fileServerURLPresent[target] = true
                fileServerCredentialPresent[target] = true
                noteFileServerCredentialRotated(for: target)
                if let pin {
                    fileServerCertFingerprints[target] = pin
                    fileServerPersistedPins[target] = pin
                } else {
                    fileServerCertFingerprints.removeValue(forKey: target)
                    fileServerPersistedPins.removeValue(forKey: target)
                }
                fileServerValidationStates[target] = .valid
                // The commit above reset the stored listing verdict to unknown
                // (`commitFileTransferConfig` defaults to `.resetToUnknown`,
                // because a new tuple makes the old server's verdict meaningless),
                // so the published mirror the badge renders has to drop with it —
                // exactly as the credential rotation and Forget paths do. Without
                // this, a code repointing a previously upload-only gateway at a
                // fully capable server keeps showing the amber "Uploads only" on
                // every surface that reads the badge until the next relaunch
                // reloads the mirror from a store that no longer says it.
                //
                // `remove`, never a read-back: the write just happened on this
                // actor, and unknown resolves to CAPABLE — the direction that
                // claims no limitation nobody has measured.
                fileTransferUploadOnlyRefSet.remove(target)
            }
        }

        // (First-gateway default bootstrap is handled inside `saveRemoteAgent`
        // above — it fires for `.committedGatewayOnly` too, since the gateway
        // half commits there.)
        return outcome
    }

    // MARK: - Post-import gateway test (optional)

    /// Probe the just-imported gateway (`GET /v1/models` via the existing
    /// `testConnection` path). Reads the PERSISTED config for `target` and ONLY
    /// the persisted config — matching `retestRemoteAgent`'s stored-credential
    /// posture.
    ///
    /// NO PAYLOAD FALLBACK, and that is the load-bearing part. Probing the
    /// payload's own URL/token when the stored slot reads empty proves the
    /// SERVER is reachable while proving nothing about what was saved, so a
    /// gateway whose commit came up short would still earn a green "Connected"
    /// — and the editor behind it would read not-configured. This stage is the
    /// only read-back the flow performs, so it is where a short save has to
    /// surface. `payload` is therefore deliberately UNREAD here — it stays in
    /// the signature because it is the `PairingImportEnvironment` seam's shape
    /// (and the test double's), not because this method may consult it.
    ///
    /// Privacy: the token never leaves this method — no log, no retention,
    /// and failure copy is the existing secret-free `AppError` recovery text.
    func runPairingGatewayTest(_ payload: PairingPayload, target: RemoteAgentRef) async -> PairingGatewayTestOutcome {
        // Status-map carrier — identical mapping to `validateRemoteAgent`:
        // a custom rides `.openclaw` (the unified map applies to all).
        let carrierBackend: RemoteAgentBackend = {
            if case .builtin(let backend) = target { return backend }
            return .openclaw
        }()

        let authScheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: target)
        // Terminal, not retryable: `retryStages()` re-runs the connectivity
        // stages but never Stage 1, so a re-probe reads the same short storage
        // and reaches the same verdict. The remedy is re-running the import,
        // so the copy says that — same treatment `.committedGatewayOnly` gets.
        let storageIncomplete = PairingGatewayTestOutcome.failed(
            message: String(localized: "settings.pairing.error.saveNotReadable",
                            defaultValue: "This gateway didn't save completely. Re-run the import to set it up again."),
            error: .remoteAgentNotConfigured
        )
        guard let url = await SettingsManager.shared.getRemoteAgentURL(for: target) else {
            return storageIncomplete
        }
        let token: String
        if authScheme.requiresToken {
            guard let stored = await SettingsManager.shared.getRemoteAgentToken(for: target),
                  !stored.isEmpty else {
                return storageIncomplete
            }
            token = stored
        } else {
            token = ""
        }
        let fingerprint = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: target)

        do {
            let outcome = try await RemoteAgentClient.shared.testConnection(
                backend: carrierBackend,
                url: url,
                token: token,
                authScheme: authScheme,
                fingerprint: fingerprint
            )
            if case .untrustedCert = outcome {
                // Terminal, not an offer. A pin cannot rescue a chain the system
                // rejected — App Transport Security permits tightening trust
                // evaluation, never loosening it — so there is nothing to propose
                // and the message names the server-side remedy instead. Shared
                // wording, not a local string: this is the same cause the editor
                // and the voice-endpoint test suite report, and one cause the user
                // meets three ways must not come with three different remedies.
                // The code rides along so the sheet reads the same terminality
                // every other surface reads, rather than inferring it from the
                // wording.
                return .failed(message: CertificateTrustCopy.untrustedRefusalWithRemedy,
                               error: .remoteAgentCertUntrusted)
            }
            // Reflect the pass into the per-ref validation row so the
            // Settings detail screen shows green without a separate re-test.
            // A passing pairing probe IS a live test against the saved config, so
            // mark it live-validated too — otherwise the editor's status-honesty
            // rule renders a bare `.valid` as the neutral "Saved", not the green
            // "Connected", on the redesign's PRIMARY (pairing) happy path.
            remoteAgentValidationStates[target] = .valid
            remoteAgentLiveValidated.insert(target)
            return .passed
        } catch let error as AppError {
            // Shared mapping with the editor's Test Connection
            // (`SettingsViewModel.friendlyGatewayMessage`) — a private copy here
            // would drift and re-swallow every failure added after it.
            return .failed(message: SettingsViewModel.friendlyGatewayMessage(for: error),
                           error: error)
        } catch {
            // No typed error behind this copy, so no terminality claim either —
            // the sheet keeps its retry, because unknown is not terminal.
            return .failed(message: String(localized: "Unexpected error. Try again."),
                           error: nil)
        }
    }
}

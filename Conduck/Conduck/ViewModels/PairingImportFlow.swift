// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingImportFlow.swift
//
// The pairing-import lifecycle, extracted from `PairingImportSheet` so it can be
// DRIVEN BY A TEST.
//
// WHY THIS TYPE EXISTS. The security properties of an inbound setup code are not
// properties of any single function — they are properties of a sequence:
// scanning must not reach the network, nothing may persist before the user
// consents, every way of leaving must clean up after itself, and a decision made
// about one destination must never be executed against another. All of that used
// to live inside a SwiftUI `View` as `@State` and private methods, where it could
// not be constructed, driven, or observed. Two real concurrency bugs shipped into
// review from that blind spot: an unguarded `await` that persisted after Cancel,
// and a cancellation checkpoint whose Task was never retained, so it could never
// fire. Both were found by reading, because nothing could test them.
//
// Everything here is therefore state + transitions with the world behind
// `PairingImportEnvironment`. The View above it renders this object and owns only
// what SwiftUI must: layout, dismissal, and the camera viewport.
//
// PRIVACY (spec.md "Privacy & Security"): the scanned/pasted string embeds the
// gateway bearer token + file-server credential. It is NEVER logged, echoed into
// error text, or displayed — every message comes from the typed
// `PairingParseError` mapping, the plan's typed blocks, or the `AppError`
// taxonomy. `pastedCode` is cleared on dismiss.

import Foundation

/// Everything the flow needs from the outside world, as one seam.
///
/// Exists so a test can assert on the SEQUENCE — that scanning called nothing
/// that touches the network, that a cancelled import never reached `execute`,
/// that a changed destination blocked the commit. A flow talking to
/// `SettingsViewModel` directly could only be tested by performing real imports.
@MainActor
protocol PairingImportEnvironment: AnyObject {
    func plan(_ payload: PairingPayload, lockedTarget: RemoteAgentRef?) async -> PairingImportPlan
    func review(_ payload: PairingPayload, target: RemoteAgentRef, freshlyMinted: Bool) async -> PairingReviewModel
    func resolveTrust(_ payload: PairingPayload,
                      accepted: [PairingTrustLane: PairingTrustOverride]) async -> PairingTrustResolution
    func execute(_ payload: PairingPayload, target: RemoteAgentRef,
                 gatewayPin: String?, fileServerPin: String?) async -> PairingImportOutcome
    func runGatewayTest(_ payload: PairingPayload, target: RemoteAgentRef) async -> PairingGatewayTestOutcome
    func runFileTest(for target: RemoteAgentRef) async -> PairingFileTestResult
    func pinCertificate(_ fingerprintHex: String, for target: RemoteAgentRef) async
    func discardDraft(_ target: RemoteAgentRef)
}

struct PairingFileTestResult: Equatable, Sendable {
    let passed: Bool
    /// Taxonomy-derived copy only — never payload content.
    let failureMessage: String?
}

@MainActor
@Observable
final class PairingImportFlow {

    // MARK: - Phases

    enum Phase: Equatable {
        case input      // scanner / paste field
        case review     // destination + consequences, nothing written yet
        case running    // stages executing
        case done       // stages finished (pass or fail) — Done dismisses
    }

    /// The staged checklist — rows mirror `STTTestSuiteResultView`'s glyph +
    /// title + detail shape, with an extra amber `untrustedCert` state carrying
    /// the trust-and-retry affordance.
    enum StageID: Int, CaseIterable {
        case save, gateway, file
    }

    enum StageStatus: Equatable {
        case pending
        case running
        case passed
        /// Detail is taxonomy-/key-derived only — never payload content.
        case failed(String?)
        case untrustedCert
    }

    /// Something the user must be told on the review card that is NOT part of the
    /// destination itself. Each arm exists because the alternative was a message
    /// the user could never see: a refusal or an unreachable-server retry raised
    /// from an alert vanishes the moment the alert is dismissed, leaving a card
    /// that looks exactly as it did before they tapped Connect.
    enum ReviewNotice: Equatable {
        /// The reviewed facts changed before Connect executed. The card now shows
        /// the NEW facts and deliberately did not act on the old ones.
        case destinationChanged
        /// A trust refusal the user backed out of, kept on screen so the reason
        /// survives the alert that carried it.
        case refused(String)
        /// A named certificate could not be checked because the server was not
        /// reachable — a retry, not a bad code.
        case unreachable(String)
    }

    /// The import awaiting consent. Nothing in it has been persisted;
    /// `freshlyMinted` marks the in-memory roster draft the plan minted for a
    /// brand-new custom, which every exit path must discard.
    ///
    /// `model` is compared against a freshly built one before committing, so it
    /// is the snapshot the user's decision was actually made about.
    struct ReviewContext: Equatable {
        let payload: PairingPayload
        let target: RemoteAgentRef
        let freshlyMinted: Bool
        var model: PairingReviewModel
        var notice: ReviewNotice?
    }

    /// A certificate exception the user must accept BEFORE anything persists.
    /// `gatewayPin`/`fileServerPin` are the exact values that would be stored.
    struct PinConsentContext: Equatable {
        let payload: PairingPayload
        let target: RemoteAgentRef
        let gatewayPin: String?
        let fileServerPin: String?
        let lanes: [PairingTrustLane]
        let freshlyMinted: Bool
    }

    /// An import refused on trust grounds. `override` is nil when no mechanism to
    /// proceed exists at all (see `PairingTrustOverride`) — the alert then offers
    /// no "Connect anyway", because the button could not work.
    ///
    /// The CONCRETE override is retained, not just "an override is possible": the
    /// retry re-probes, and consent has to be bound to the exact action the user
    /// was shown. `accepted` carries forward overrides agreed on earlier lanes so
    /// two blocked lanes can both be resolved instead of re-blocking each other.
    struct TrustBlockContext: Equatable {
        let payload: PairingPayload
        let target: RemoteAgentRef
        let lane: PairingTrustLane
        let block: PairingTrustBlock
        let override: PairingTrustOverride?
        let accepted: [PairingTrustLane: PairingTrustOverride]
        let freshlyMinted: Bool
    }

    // MARK: - Observed state

    private(set) var phase: Phase = .input
    var pastedCode: String = ""
    private(set) var inlineError: String?
    /// An await is in flight on the path to persistence — disables the actions
    /// that would start a second one.
    private(set) var planning: Bool = false

    private(set) var reviewContext: ReviewContext?

    var pinConsentContext: PinConsentContext?
    var showingPinConsentAlert: Bool = false
    var trustBlockContext: TrustBlockContext?
    var showingTrustBlockAlert: Bool = false

    /// Set once the plan resolves — drives the stage run + the trust retry.
    private(set) var activePayload: PairingPayload?
    private(set) var activeTarget: RemoteAgentRef?

    private(set) var stageStatus: [StageID: StageStatus] = [:]
    /// The presented self-signed fingerprint from an `.untrustedCert` outcome —
    /// nil when none is pending OR the cert's key type yielded no fingerprint
    /// (then there is nothing to pin and the retry affordance is hidden).
    private(set) var presentedUntrustedFP: String?

    /// Bumped whenever a scanned code is REJECTED back to the input phase. The
    /// scanner's one-shot latch + `stopScanning()` would otherwise leave a frozen
    /// viewport — the View keys `.id()` on this so the camera scans again.
    private(set) var scannerGeneration: Int = 0

    // MARK: - Internal bookkeeping

    /// Identity of the in-flight import attempt, spanning EVERY unstructured
    /// await on the path to persistence — planning, building the review card,
    /// re-reading it at Connect, re-reading it again at commit, and the trust
    /// probe. Bumped by anything that abandons the attempt (Cancel, dismissal, a
    /// superseding attempt), so a Task can tell after its await that the result it
    /// is holding belongs to an import nobody is waiting for any more.
    ///
    /// Without this, tapping Import and then Cancel still persisted the URL, token
    /// and pin when the probe eventually returned. Task cancellation alone is NOT
    /// sufficient: a cancelled probe classifies as `.unreachable(.cancelled)`, and
    /// the no-claim rule deliberately proceeds on unreachable.
    private var operationGeneration: Int = 0

    /// The target of an import that has been RESOLVED but not yet persisted — set
    /// the moment the review card appears and cleared only by `beginImport`
    /// (persistence has started, the draft is real now) or by an exit path.
    ///
    /// It deliberately stays set while the certificate alerts are on screen: a
    /// window closed out from under a consent alert must still discard the draft,
    /// and clearing it when the probe returned would leave exactly that gap.
    private var pendingTrustTarget: RemoteAgentRef?
    private var pendingTrustFreshlyMinted: Bool = false

    /// The in-flight pre-persistence Task, retained so abandoning the import can
    /// CANCEL it rather than merely ignore its result.
    ///
    /// `operationGeneration` alone is not enough: `resolveTrust` probes two lanes
    /// in sequence, and a generation guard that only runs after it returns would
    /// let a cancelled resolution finish the gateway probe and then open a second
    /// connection to an attacker-selected file host. Cancel has to stop the
    /// outbound work, not just discard its answer. The guard stays — cancellation
    /// is best-effort and races the checkpoints.
    private var resolutionTask: Task<Void, Never>?

    /// True once Stage 1 (save) passed — gates the `onImported` hook.
    private var saveSucceeded: Bool = false
    /// True once Stage 2 (gateway connection) PASSED — gates the `onConnected`
    /// hook (verified connection, not just a save).
    private var gatewayConnected: Bool = false
    /// Latches so each host hook fires EXACTLY once — set when the hook fires
    /// eagerly the moment its condition becomes true, so the `handleDisappear`
    /// fallback can never double-fire.
    private var importedHookFired: Bool = false
    private var connectedHookFired: Bool = false

    // MARK: - Configuration

    private let environment: PairingImportEnvironment
    /// When non-nil the import may ONLY land on this ref (per-ref editor entry).
    /// nil → the payload's own kind picks/mints the target.
    let lockedTarget: RemoteAgentRef?
    private let onImported: ((RemoteAgentRef) -> Void)?
    private let onConnected: ((RemoteAgentRef) -> Void)?

    init(
        environment: PairingImportEnvironment,
        lockedTarget: RemoteAgentRef? = nil,
        onImported: ((RemoteAgentRef) -> Void)? = nil,
        onConnected: ((RemoteAgentRef) -> Void)? = nil
    ) {
        self.environment = environment
        self.lockedTarget = lockedTarget
        self.onImported = onImported
        self.onConnected = onConnected
    }

    // MARK: - Derived view state

    var visibleStages: [StageID] {
        activePayload?.fileServer != nil ? [.save, .gateway, .file] : [.save, .gateway]
    }

    /// True iff the gateway stage ended in a hard `.failed` (drives the recovery
    /// section). `.untrustedCert` and `.passed`/`.running`/`.pending` all read
    /// false — recovery never shadows the trust-retry or a success.
    var gatewayFailedTerminally: Bool {
        if case .failed = stageStatus[.gateway] ?? .pending { return true }
        return false
    }

    /// True when the pairing payload gave no reason to expect a self-signed
    /// certificate — no `certFP` AND a transport other than `.selfsigned`.
    /// `conduck-connect` computes and emits `certFP` for any self-signed gateway
    /// it detects, so its absence means the wizard saw a trusted chain.
    var unexpectedSelfSignedCert: Bool {
        guard let payload = activePayload else { return false }
        return payload.certFP == nil && payload.transport != .selfsigned
    }

    /// A brand-new custom (free-target) import means the plan minted an in-memory
    /// roster draft — every path that abandons the import must discard it again,
    /// or a phantom empty row lingers in the gateway list.
    func isFreshlyMinted(_ payload: PairingPayload) -> Bool {
        guard lockedTarget == nil, case .custom = payload.kind else { return false }
        return true
    }

    // MARK: - Parse → plan → review

    /// Entry for BOTH the scanner (pre-validated) and the paste Import button.
    ///
    /// Performs NO network request on any path: parsing is pure, planning and the
    /// review build are local reads. The first server contact is `connect()`.
    func handleCode(_ raw: String) {
        guard phase == .input, !planning else { return }
        inlineError = nil

        switch PairingPayload.parse(raw) {
        case .failure(let error):
            inlineError = Self.message(for: error)
            restartScanner()
        case .success(let payload):
            // One generation guard covers BOTH awaits below. Planning mints the
            // roster draft for a free-target custom import, so an unguarded
            // resume could orphan a draft and then go on to present a card for an
            // import the user already walked away from.
            operationGeneration &+= 1
            let generation = operationGeneration
            let freshlyMinted = isFreshlyMinted(payload)
            planning = true
            resolutionTask = Task { [environment, lockedTarget] in
                let plan = await environment.plan(payload, lockedTarget: lockedTarget)

                // Build the card in the SAME task rather than after a hop back to
                // the view: a second unstructured Task would need its own guard,
                // and the window between them is exactly where a cancelled import
                // used to keep going.
                //
                // `.ready` and `.needsOverwriteConfirm` converge deliberately — an
                // overwrite is not a different DECISION, it is the same decision
                // with more at stake, and the card states what is being replaced
                // from a fresh read rather than from the plan's snapshot. That
                // also removes the old alert's bypass, where confirming a
                // replacement skipped straight past every check the direct path
                // ran.
                let resolved: (target: RemoteAgentRef, model: PairingReviewModel)?
                switch plan {
                case .ready(let target), .needsOverwriteConfirm(let target, _, _):
                    resolved = (target, await environment.review(
                        payload, target: target, freshlyMinted: freshlyMinted
                    ))
                case .blocked:
                    // `.blocked` never mints (the cap case fails before minting; a
                    // kind mismatch implies a locked target, which never mints),
                    // so there is nothing to clean up on this arm.
                    resolved = nil
                }

                guard generation == self.operationGeneration else {
                    // Abandoned mid-flight. This Task is the only holder of the
                    // minted target, so it owns the cleanup.
                    if freshlyMinted, let target = resolved?.target {
                        environment.discardDraft(target)
                    }
                    return
                }
                self.planning = false

                if let resolved {
                    self.enterReview(payload, target: resolved.target,
                                     freshlyMinted: freshlyMinted, model: resolved.model)
                } else if case .blocked(let block) = plan {
                    self.showBlocked(block)
                }
            }
        }
    }

    /// A code that cannot land at any target — terminal, back to the input step.
    private func showBlocked(_ block: PairingImportBlock) {
        switch block {
        case .customGatewayCapReached:
            inlineError = String(localized: "settings.pairing.error.capReached",
                                 defaultValue: "You've reached the custom-gateway limit. Delete one in Settings to import another.")
        case .kindMismatch(let expectedDisplayName):
            inlineError = String(
                format: String(localized: "settings.pairing.error.kindMismatch",
                               defaultValue: "This setup code is for %@. Import it from the gateway list instead."),
                expectedDisplayName
            )
        }
        restartScanner()
    }

    // MARK: - Review step (consent — still nothing written, still no network)

    /// Show the card. Claiming `pendingTrustTarget` HERE, not at Connect, is what
    /// makes every exit from the card — toolbar Cancel, swipe-dismiss, window
    /// close — discard the roster draft the plan minted.
    private func enterReview(
        _ payload: PairingPayload,
        target: RemoteAgentRef,
        freshlyMinted: Bool,
        model: PairingReviewModel
    ) {
        pendingTrustTarget = target
        pendingTrustFreshlyMinted = freshlyMinted
        reviewContext = ReviewContext(
            payload: payload, target: target,
            freshlyMinted: freshlyMinted, model: model, notice: nil
        )
        inlineError = nil
        phase = .review
    }

    /// Connect — the first action in this whole flow that is allowed to touch the
    /// network, and (past the trust gate) storage.
    ///
    /// Re-reads the card before acting. The user consented to a specific
    /// destination; if a peer's iCloud sync or a second window changed what is
    /// stored at this target since, the reviewed screen no longer describes what
    /// would happen, so the new facts are presented and the tap is spent on
    /// showing them rather than on executing.
    func connect() {
        guard phase == .review, let context = reviewContext, !planning else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        planning = true
        resolutionTask = Task { [environment] in
            let fresh = await environment.review(
                context.payload, target: context.target, freshlyMinted: context.freshlyMinted
            )
            guard generation == self.operationGeneration else { return }
            self.planning = false

            guard fresh == context.model else {
                self.presentChangedFacts(fresh, context: context)
                return
            }
            self.resolveTrustThenImport(
                context.payload, target: context.target, freshlyMinted: context.freshlyMinted
            )
        }
    }

    /// The FINAL gate — re-read the card one last time and commit only if it still
    /// matches what the user consented to.
    ///
    /// `connect()` compares before probing, but everything between then and here
    /// is unbounded: a two-lane probe takes as long as the network takes, and a
    /// certificate alert takes as long as the person takes. A card that said
    /// "replacing old.example" must not quietly overwrite production.example
    /// because another window moved the slot while an alert sat open.
    ///
    /// What remains after this is the few actor hops between this read and the
    /// write inside `saveRemoteAgent` — no human deliberation, no network. Fully
    /// closing that needs a compare-and-swap at the shared commit point itself,
    /// where it would cover the manual editor equally; that is deliberately not
    /// smuggled in here.
    private func commitIfUnchanged(
        _ payload: PairingPayload,
        target: RemoteAgentRef,
        gatewayPin: String?,
        fileServerPin: String?
    ) {
        guard let context = reviewContext else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        planning = true
        resolutionTask = Task { [environment] in
            let fresh = await environment.review(
                payload, target: target, freshlyMinted: context.freshlyMinted
            )
            guard generation == self.operationGeneration else { return }
            self.planning = false

            guard fresh == context.model else {
                self.presentChangedFacts(fresh, context: context)
                return
            }
            self.beginImport(payload, target: target,
                             gatewayPin: gatewayPin, fileServerPin: fileServerPin)
        }
    }

    /// The reviewed facts moved. Show the NEW ones and spend the tap on saying so
    /// — the consent that was given was about different facts, and re-asking is
    /// the only honest use of it.
    private func presentChangedFacts(_ fresh: PairingReviewModel, context: ReviewContext) {
        pinConsentContext = nil
        showingPinConsentAlert = false
        trustBlockContext = nil
        showingTrustBlockAlert = false
        reviewContext = ReviewContext(
            payload: context.payload, target: context.target,
            freshlyMinted: context.freshlyMinted,
            model: fresh, notice: .destinationChanged
        )
        phase = .review
    }

    /// Back to the card from a certificate alert — one step back, not out. The
    /// draft and the reviewed context survive; only the in-flight resolution is
    /// superseded, so a probe still running cannot land on a screen the user has
    /// already left.
    func returnToReview(notice: ReviewNotice?) {
        operationGeneration &+= 1
        resolutionTask?.cancel()
        resolutionTask = nil
        planning = false
        pinConsentContext = nil
        showingPinConsentAlert = false
        trustBlockContext = nil
        showingTrustBlockAlert = false
        guard reviewContext != nil else {
            // Unreachable — every resolution starts from a card. Fail toward the
            // input step rather than presenting an empty one.
            phase = .input
            restartScanner()
            return
        }
        reviewContext?.notice = notice
        phase = .review
    }

    /// "Use a different code" — abandon this import entirely (draft included) and
    /// go back to scanning/pasting, without leaving the sheet.
    func useDifferentCode() {
        invalidatePendingImport()
        inlineError = nil
        phase = .input
        restartScanner()
    }

    /// Accept a certificate exception and commit — through the final gate, not
    /// straight to persistence: an alert can sit open for as long as the person
    /// takes, and the destination they agreed to may have moved meanwhile.
    func acceptPinConsent(_ context: PinConsentContext) {
        commitIfUnchanged(context.payload, target: context.target,
                          gatewayPin: context.gatewayPin, fileServerPin: context.fileServerPin)
    }

    /// Accept a "Connect anyway" override on a blocked lane.
    ///
    /// Re-resolves with this lane's override accepted, so the pin that gets stored
    /// is re-derived from a FRESH probe rather than from the stale signals behind
    /// the alert. The EXACT accepted action is carried so a server that changed in
    /// between cannot silently convert this consent into a different one — and
    /// prior lanes' acceptances are carried forward so two blocked lanes can both
    /// resolve.
    func acceptTrustOverride(_ context: TrustBlockContext, override: PairingTrustOverride) {
        var accepted = context.accepted
        accepted[context.lane] = override
        resolveTrustThenImport(
            context.payload, target: context.target,
            freshlyMinted: context.freshlyMinted, acceptedOverrides: accepted
        )
    }

    // MARK: - Trust resolution (runs BEFORE anything persists)

    /// Probe both lanes unpinned, decide, and only then import.
    ///
    /// This is the single gate every import path funnels through. Nothing here
    /// writes to defaults, iCloud, or the Keychain; `beginImport` is reached only
    /// with pins that have been checked against the key the server actually
    /// presented.
    private func resolveTrustThenImport(
        _ payload: PairingPayload,
        target: RemoteAgentRef,
        freshlyMinted: Bool,
        acceptedOverrides: [PairingTrustLane: PairingTrustOverride] = [:]
    ) {
        // Supersede any resolution already in flight, then claim this identity.
        // `pendingTrustTarget` is already this target (claimed at `enterReview`)
        // and is deliberately NOT cleared when the probe returns — see its docs.
        operationGeneration &+= 1
        let generation = operationGeneration
        pendingTrustTarget = target
        pendingTrustFreshlyMinted = freshlyMinted
        planning = true
        // Retained: this is THE task that talks to the network, so it is the one
        // an abandonment most needs to be able to cancel. Leaving it unretained
        // would make the cancellation checkpoint inside `resolveTrust` unreachable
        // — the very probe it exists to stop.
        resolutionTask = Task { [environment] in
            let resolution = await environment.resolveTrust(payload, accepted: acceptedOverrides)

            // Abandoned while the probe was in flight (Cancel, swipe-dismiss, or a
            // superseding resolution). Whoever invalidated us owns the cleanup,
            // including the roster draft — do NOT persist, and do NOT raise an
            // alert for an import nobody is waiting for.
            guard generation == self.operationGeneration else { return }
            self.planning = false

            switch resolution {
            case .proceed(let gatewayPin, let fileServerPin):
                self.commitIfUnchanged(payload, target: target,
                                       gatewayPin: gatewayPin, fileServerPin: fileServerPin)

            case .needsPinConsent(let gatewayPin, let fileServerPin, let lanes):
                self.pinConsentContext = PinConsentContext(
                    payload: payload, target: target,
                    gatewayPin: gatewayPin, fileServerPin: fileServerPin,
                    lanes: lanes, freshlyMinted: freshlyMinted
                )
                self.showingPinConsentAlert = true

            case .blocked(let lane, let block, let override):
                self.trustBlockContext = TrustBlockContext(
                    payload: payload, target: target, lane: lane, block: block,
                    override: override, accepted: acceptedOverrides,
                    freshlyMinted: freshlyMinted
                )
                self.showingTrustBlockAlert = true

            case .unverifiableWhileUnreachable(let lane, _):
                // A claim that could not be checked because the server was not
                // reachable. Importing would persist an unverified pin — the exact
                // thing this gate exists to prevent — so this is a retry, not a
                // failure of the code. It lands on the CARD, not in the paste
                // field's inline error: that field is only rendered in the input
                // step, so an unreachable verdict used to be written somewhere the
                // user could not see it.
                self.returnToReview(notice: .unreachable(String(
                    format: String(
                        localized: "settings.pairing.trust.unreachable",
                        defaultValue: "Couldn't reach %@ to check its certificate against this code. Try again when you can reach it."
                    ),
                    lane == .gateway
                        ? String(localized: "settings.pairing.trust.subject.gateway.inline",
                                 defaultValue: "the gateway")
                        : String(localized: "settings.pairing.trust.subject.file.inline",
                                 defaultValue: "the file server")
                )))
            }
        }
    }

    /// Invalidate an in-flight import and clean up everything it created.
    ///
    /// Called from the paths that abandon the import outright — toolbar Cancel,
    /// disappearance (swipe-dismiss / window close), and "Use a different code".
    /// Takes no context because those paths have none in hand: the pending target
    /// is whatever the review step claimed.
    func invalidatePendingImport() {
        operationGeneration &+= 1
        resolutionTask?.cancel()
        resolutionTask = nil
        if let target = pendingTrustTarget, pendingTrustFreshlyMinted {
            environment.discardDraft(target)
        }
        pendingTrustTarget = nil
        pendingTrustFreshlyMinted = false
        planning = false
        pinConsentContext = nil
        showingPinConsentAlert = false
        trustBlockContext = nil
        showingTrustBlockAlert = false
        reviewContext = nil
    }

    // MARK: - Stage run (the first writes happen here)

    /// - Parameters:
    ///   - gatewayPin/fileServerPin: the RESOLVED certificate pins — `nil` meaning
    ///     ordinary system trust. Never the payload's claimed values.
    private func beginImport(
        _ payload: PairingPayload,
        target: RemoteAgentRef,
        gatewayPin: String?,
        fileServerPin: String?
    ) {
        pinConsentContext = nil
        showingPinConsentAlert = false
        trustBlockContext = nil
        showingTrustBlockAlert = false
        reviewContext = nil
        // Persistence starts here, so the "unpersisted draft to clean up" state
        // ends here: from now on `runStages` owns the rollback (its `.failed` arm
        // discards the draft itself).
        pendingTrustTarget = nil
        pendingTrustFreshlyMinted = false
        resolutionTask = nil
        activePayload = payload
        activeTarget = target
        stageStatus = [:]
        presentedUntrustedFP = nil
        // Reset per-attempt outcome so a re-import re-evaluates cleanly and the
        // dismiss hooks fire for the LATEST attempt, not a stale earlier one.
        saveSucceeded = false
        gatewayConnected = false
        importedHookFired = false
        connectedHookFired = false
        phase = .running
        stageTask = Task {
            await runStages(payload, target: target,
                            gatewayPin: gatewayPin, fileServerPin: fileServerPin)
        }
    }

    /// The post-persistence stage run, retained so a test can await it.
    private(set) var stageTask: Task<Void, Never>?

    private func runStages(
        _ payload: PairingPayload,
        target: RemoteAgentRef,
        gatewayPin: String?,
        fileServerPin: String?
    ) async {
        // Stage 1 — persist the configuration. Three-way outcome: see
        // `PairingImportOutcome` (the gateway half can commit even when the
        // file-server credential write fails).
        stageStatus[.save] = .running
        switch await environment.execute(payload, target: target,
                                         gatewayPin: gatewayPin, fileServerPin: fileServerPin) {
        case .failed:
            stageStatus[.save] = .failed(String(
                localized: "settings.pairing.error.saveFailed",
                defaultValue: "Couldn't save this configuration securely. Try again."
            ))
            // A free-target custom import minted a roster draft in the plan step —
            // nothing persisted, so drop it (else a phantom empty row lingers in
            // the gateway list until the next state reload).
            if isFreshlyMinted(payload) {
                environment.discardDraft(target)
            }
            phase = .done
            return
        case .committedGatewayOnly:
            saveSucceeded = true
            stageStatus[.save] = .passed
            // The file-server half rolled back at save time — mark its stage
            // failed up front; `runFileStageIfNeeded` sees the terminal state and
            // never probes a config that isn't there.
            stageStatus[.file] = .failed(String(
                localized: "settings.pairing.error.fileCredentialFailed",
                defaultValue: "Couldn't save the file-server credential securely. The gateway itself was set up — re-run the import to add the file server."
            ))
        case .committed:
            saveSucceeded = true
            stageStatus[.save] = .passed
        }

        // The `.failed` arm returned above, so the save has committed here — fire
        // `onImported` EAGERLY (not deferred to dismiss), closing the race where a
        // swipe-dismiss mid-run skips it. Latched, so the `handleDisappear`
        // fallback can never re-fire it.
        fireImportedHookIfNeeded()

        // Stage 2 (+3) — connectivity proof on the just-saved config.
        await runGatewayStage(payload, target: target)
        phase = .done
    }

    /// Stage 2 — gateway connection test. On `.untrustedCert` the run PAUSES
    /// (amber row + trust-and-retry); the file stage only follows a terminal
    /// gateway outcome (pass or hard fail — the file server is independent).
    private func runGatewayStage(_ payload: PairingPayload, target: RemoteAgentRef) async {
        stageStatus[.gateway] = .running
        presentedUntrustedFP = nil
        switch await environment.runGatewayTest(payload, target: target) {
        case .passed:
            gatewayConnected = true
            stageStatus[.gateway] = .passed
            fireConnectedHookIfNeeded()
            await runFileStageIfNeeded(payload, target: target)
        case .untrustedCert(let fingerprint):
            gatewayConnected = false
            presentedUntrustedFP = fingerprint
            stageStatus[.gateway] = .untrustedCert
        case .failed(let message):
            gatewayConnected = false
            stageStatus[.gateway] = .failed(message)
            await runFileStageIfNeeded(payload, target: target)
        }
    }

    /// Stage 3 — only when the payload carried a file-server block. A stage
    /// already terminally failed (the `.committedGatewayOnly` rollback) is never
    /// re-probed — its config was rolled back at save time.
    private func runFileStageIfNeeded(_ payload: PairingPayload, target: RemoteAgentRef) async {
        guard payload.fileServer != nil else { return }
        if case .failed = stageStatus[.file] ?? .pending { return }
        stageStatus[.file] = .running
        let result = await environment.runFileTest(for: target)
        stageStatus[.file] = result.passed ? .passed : .failed(result.failureMessage)
    }

    /// Pin the presented self-signed fingerprint for the target, then re-run the
    /// gateway stage (the pinned cert now validates).
    func trustAndRetry() {
        guard let fingerprint = presentedUntrustedFP,
              let payload = activePayload,
              let target = activeTarget else { return }
        presentedUntrustedFP = nil
        phase = .running
        stageTask = Task { [environment] in
            await environment.pinCertificate(fingerprint, for: target)
            await self.runGatewayStage(payload, target: target)
            self.phase = .done
        }
    }

    /// Recovery "Try again": re-run ONLY the connectivity stages on the
    /// already-saved config (Stage 1 save is NOT redone).
    func retryStages() {
        guard let payload = activePayload, let target = activeTarget else { return }
        stageStatus[.gateway] = .pending
        if payload.fileServer != nil { stageStatus[.file] = .pending }
        presentedUntrustedFP = nil
        phase = .running
        stageTask = Task {
            await self.runGatewayStage(payload, target: target)
            self.phase = .done
        }
    }

    /// Recovery "Back to instructions": return to the paste/scan input without
    /// disturbing the saved config.
    func backToInstructions() {
        inlineError = nil
        phase = .input
        restartScanner()
    }

    // MARK: - Host hooks

    /// Fire `onImported` exactly once, for ANY target (locked OR free/minted).
    private func fireImportedHookIfNeeded() {
        guard saveSucceeded, !importedHookFired, let target = activeTarget else { return }
        importedHookFired = true
        onImported?(target)
    }

    /// Fire `onConnected` exactly once, only when the gateway stage actually
    /// PASSED (verified connection, not a mere save).
    private func fireConnectedHookIfNeeded() {
        guard gatewayConnected, !connectedHookFired, let target = activeTarget else { return }
        connectedHookFired = true
        onConnected?(target)
    }

    /// Runs on EVERY dismissal path: clears the secret-bearing paste buffer, then
    /// fires each host hook as a FALLBACK. The latches make a second call a no-op.
    func handleDisappear() {
        pastedCode = ""
        fireImportedHookIfNeeded()
        fireConnectedHookIfNeeded()
    }

    private func restartScanner() {
        scannerGeneration &+= 1
    }

    /// User-facing copy per typed parse error — the ONLY error surface for a bad
    /// code (never any part of the input itself).
    static func message(for error: PairingParseError) -> String {
        switch error {
        case .notAPairingCode:
            return String(localized: "settings.pairing.error.notCode",
                          defaultValue: "That doesn't look like a Conduck setup code.")
        case .unsupportedVersion:
            return String(localized: "settings.pairing.error.version",
                          defaultValue: "This setup code needs a newer Conduck. Update the app, or re-run conduck-connect.")
        case .malformed:
            return String(localized: "settings.pairing.error.malformed",
                          defaultValue: "This setup code is damaged or incomplete. Re-run conduck-connect to get a fresh one.")
        case .insecureURL:
            return String(localized: "settings.pairing.error.insecureURL",
                          defaultValue: "Setup codes must use https:// URLs.")
        }
    }

    /// Surface a scanner-rejected code with the same typed copy the paste path
    /// uses, while the camera keeps scanning.
    func noteScannerRejection(_ error: PairingParseError) {
        inlineError = Self.message(for: error)
    }
}

// MARK: - The real environment

/// `SettingsViewModel` behind the flow's seam. Pure forwarding: every decision
/// lives either in the flow or in the view model, never here, so this adapter
/// cannot become a third place where import behaviour is defined.
@MainActor
final class SettingsViewModelPairingEnvironment: PairingImportEnvironment {
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    func plan(_ payload: PairingPayload, lockedTarget: RemoteAgentRef?) async -> PairingImportPlan {
        await viewModel.planPairingImport(payload, lockedTarget: lockedTarget)
    }

    func review(_ payload: PairingPayload, target: RemoteAgentRef, freshlyMinted: Bool) async -> PairingReviewModel {
        await viewModel.pairingReview(for: payload, target: target, freshlyMinted: freshlyMinted)
    }

    func resolveTrust(_ payload: PairingPayload,
                      accepted: [PairingTrustLane: PairingTrustOverride]) async -> PairingTrustResolution {
        await viewModel.resolvePairingTrust(payload, acceptedOverrides: accepted)
    }

    func execute(_ payload: PairingPayload, target: RemoteAgentRef,
                 gatewayPin: String?, fileServerPin: String?) async -> PairingImportOutcome {
        await viewModel.executePairingImport(payload, target: target,
                                             resolvedGatewayPin: gatewayPin,
                                             resolvedFileServerPin: fileServerPin)
    }

    func runGatewayTest(_ payload: PairingPayload, target: RemoteAgentRef) async -> PairingGatewayTestOutcome {
        await viewModel.runPairingGatewayTest(payload, target: target)
    }

    func runFileTest(for target: RemoteAgentRef) async -> PairingFileTestResult {
        await viewModel.runFileTransferTest(for: target)
        let result = viewModel.fileTransferTestResults[target]
        return PairingFileTestResult(
            passed: result?.success == true,
            failureMessage: result?.failure?.errorDescription
        )
    }

    func pinCertificate(_ fingerprintHex: String, for target: RemoteAgentRef) async {
        await SettingsManager.shared.setRemoteAgentCertFingerprint(fingerprintHex, for: target)
    }

    func discardDraft(_ target: RemoteAgentRef) {
        viewModel.discardPairingDraft(target)
    }
}

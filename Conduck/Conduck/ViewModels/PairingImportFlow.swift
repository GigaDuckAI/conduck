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
// PRIVACY (docs/ai-context/spec.md): the scanned/pasted string embeds the
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
    func resolveTrust(_ payload: PairingPayload) async -> PairingTrustResolution
    func execute(_ payload: PairingPayload, target: RemoteAgentRef,
                 gatewayPin: String?, fileServerPin: String?) async -> PairingImportOutcome
    func runGatewayTest(_ payload: PairingPayload, target: RemoteAgentRef) async -> PairingGatewayTestOutcome
    func runFileTest(for target: RemoteAgentRef) async -> PairingFileTestResult
    func discardDraft(_ target: RemoteAgentRef)
}

struct PairingFileTestResult: Equatable, Sendable {
    let passed: Bool
    /// The lane passed FOR UPLOADS and the server stated it cannot list a folder,
    /// so nothing the agent writes can come back on its own.
    ///
    /// A SECOND AXIS RATHER THAN A THIRD VALUE OF `passed`, for the reason
    /// `FileTransferTestResult` keeps its own two apart: the byte round-trip is
    /// proven either way, and folding the two would make a screen choose between
    /// a green seal and a red cross when both are false in one direction.
    ///
    /// It exists so the sheet does not have to be the one surface that claims
    /// both directions on a server that has one — the spec's rule is that no
    /// screen reporting on this lane shows an unqualified pass for it.
    let uploadsOnly: Bool
    /// Taxonomy-derived copy only — never payload content.
    let failureMessage: String?
    /// Whether re-running this stage can reach a different verdict. Rides
    /// `AppError.isRetryable`, resolved where the `AppError` still exists rather
    /// than re-derived from `failureMessage` later — a message is prose, and the
    /// one thing no consumer can recover from it is whether the server refused
    /// permanently. Both stages report it because the checklist renders both
    /// through one `StageStatus`, so the taxonomy would otherwise be discarded
    /// at two boundaries instead of one. No typed error → `true`: unknown is not
    /// terminal.
    let retryable: Bool

    /// Explicit memberwise init so `uploadsOnly` can default to false — an
    /// absent second axis means "nothing narrowed", never "narrowed", matching
    /// the polarity every other reader of this verdict uses.
    init(
        passed: Bool,
        uploadsOnly: Bool = false,
        failureMessage: String?,
        retryable: Bool
    ) {
        self.passed = passed
        self.uploadsOnly = uploadsOnly
        self.failureMessage = failureMessage
        self.retryable = retryable
    }
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
    /// title + detail shape.
    enum StageID: Int, CaseIterable {
        case save, gateway, file
    }

    enum StageStatus: Equatable {
        case pending
        case running
        /// The stage did what it set out to do. `caveat` is a sentence naming a
        /// capability the stage PROVED ABSENT while everything it grades passed —
        /// today only the file stage's upload-only lane, whose server accepts
        /// writes and reads and structurally refuses to list a folder.
        ///
        /// AN ASSOCIATED VALUE RATHER THAN A FOURTH CASE, so that every existing
        /// `case .passed:` pattern keeps compiling and no surface can silently
        /// inherit a "nothing to report" it never asked for: a stage that grows a
        /// partial state has to say `caveat: nil` to stay unqualified.
        ///
        /// Non-nil is NOT a failure. There is nothing to retry — the server
        /// answered, permanently and correctly — and the lane is fully usable in
        /// the direction the stage proved, so a red cross would tell a user whose
        /// import worked that it did not.
        ///
        /// RENDERING IT IS `PairingImportSheet`'S JOB: a non-nil caveat draws the
        /// amber triangle and the sentence, matching `FileTransferStageChecklist`'s
        /// `.unsupported` row — the surface a user meets the same fact on minutes
        /// later — while a nil one keeps the plain green tick.
        case passed(caveat: String?)
        /// Detail is taxonomy-/key-derived only — never payload content.
        ///
        /// `retryable` rides `AppError.isRetryable`, mirroring
        /// `ServerFileDownloadChip`'s `failed(message:retryable:)`: a row that
        /// knows only its message cannot tell a gateway that is merely down from
        /// a certificate this device refuses, and the recovery section below the
        /// checklist has to. A failure with no typed error behind it stays
        /// retryable — unknown is not terminal.
        case failed(String?, retryable: Bool)
    }

    /// Something the user must be told on the review card that is NOT part of the
    /// destination itself. Each arm exists because the alternative was a message
    /// the user could never see: a refusal raised from an alert vanishes the
    /// moment the alert is dismissed, leaving a card that looks exactly as it did
    /// before they tapped Connect.
    enum ReviewNotice: Equatable {
        /// The reviewed facts changed before Connect executed. The card now shows
        /// the NEW facts and deliberately did not act on the old ones.
        case destinationChanged
        /// A trust refusal the user dismissed, kept on screen so the reason
        /// survives the alert that carried it.
        case refused(String)
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

    /// An import refused on trust grounds. There is deliberately no "Connect
    /// anyway": every block reason is terminal (see `PairingTrustBlock`), so the
    /// alert explains and offers only Cancel.
    struct TrustBlockContext: Equatable {
        let payload: PairingPayload
        let target: RemoteAgentRef
        let lane: PairingTrustLane
        let block: PairingTrustBlock
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

    var trustBlockContext: TrustBlockContext?
    var showingTrustBlockAlert: Bool = false

    /// Set once the plan resolves — drives the stage run.
    private(set) var activePayload: PairingPayload?
    private(set) var activeTarget: RemoteAgentRef?

    private(set) var stageStatus: [StageID: StageStatus] = [:]

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
    /// Without this, tapping Import and then Cancel still persisted the URL and
    /// token when the probe eventually returned. Task cancellation alone is NOT
    /// sufficient: a cancelled probe classifies as `.unreachable(.cancelled)`, and
    /// an unreachable server deliberately still imports.
    private var operationGeneration: Int = 0

    /// The target of an import that has been RESOLVED but not yet persisted — set
    /// the moment the review card appears and cleared only by `beginImport`
    /// (persistence has started, the draft is real now) or by an exit path.
    ///
    /// It deliberately stays set while the trust-refusal alert is on screen: a
    /// window closed out from under that alert must still discard the draft, and
    /// clearing it when the probe returned would leave exactly that gap.
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

    /// True iff the gateway stage ended in a `.failed` (drives the recovery
    /// section). `.passed`/`.running`/`.pending` all read false — recovery never
    /// shadows a success or an in-flight probe.
    ///
    /// Deliberately says nothing about WHY it failed: "Back to instructions" and
    /// "Fix it manually" are the right offer for every failure, terminal or not.
    /// Only the retry affordance needs the distinction — see
    /// `gatewayFailureIsRetryable`.
    var gatewayStageFailed: Bool {
        if case .failed = stageStatus[.gateway] ?? .pending { return true }
        return false
    }

    /// Whether re-running the connectivity stages can reach a different verdict.
    /// The SINGLE gate on the recovery section's "Try again", so the sheet
    /// answers the same question every other failure surface answers from
    /// `AppError.isRetryable` — a certificate this device won't accept, a
    /// rejected token or a URL that isn't an AI endpoint sends the identical
    /// probe into the identical refusal, and a button that can only fail again
    /// is a promise the app cannot keep.
    ///
    /// True when the gateway stage has not failed at all, so this is only ever
    /// consulted alongside `gatewayStageFailed`.
    var gatewayFailureIsRetryable: Bool {
        if case .failed(_, let retryable) = stageStatus[.gateway] ?? .pending { return retryable }
        return true
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

    // MARK: - Trust resolution (runs BEFORE anything persists)

    /// Probe both lanes unpinned, decide, and only then import.
    ///
    /// This is the single gate every import path funnels through. Nothing here
    /// writes to defaults, iCloud, or the Keychain; `beginImport` is reached only
    /// after a live probe found this device already trusts the server.
    private func resolveTrustThenImport(
        _ payload: PairingPayload,
        target: RemoteAgentRef,
        freshlyMinted: Bool
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
            let resolution = await environment.resolveTrust(payload)

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

            case .blocked(let lane, let block):
                self.trustBlockContext = TrustBlockContext(
                    payload: payload, target: target, lane: lane, block: block,
                    freshlyMinted: freshlyMinted
                )
                self.showingTrustBlockAlert = true

            case .abandoned:
                // The resolution cancelled itself between lanes. Normally the
                // guard above has already dropped this attempt; reaching here
                // means cancellation raced it, so fall back to the card rather
                // than persist a decision that was never finished.
                self.returnToReview(notice: nil)
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
        trustBlockContext = nil
        showingTrustBlockAlert = false
        reviewContext = nil
    }

    // MARK: - Stage run (the first writes happen here)

    /// - Parameters:
    ///   - gatewayPin/fileServerPin: the RESOLVED certificate pins, which today
    ///     are always `nil` — ordinary system trust. Threaded through rather than
    ///     assumed so the value that reaches storage is one a decision produced.
    private func beginImport(
        _ payload: PairingPayload,
        target: RemoteAgentRef,
        gatewayPin: String?,
        fileServerPin: String?
    ) {
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
            // Retryable: the message says so, and re-running the import is the
            // remedy. The recovery section never sees it — a failed save ends
            // the run before the gateway stage — but the row must not claim a
            // terminality it does not have.
            stageStatus[.save] = .failed(String(
                localized: "settings.pairing.error.saveFailed",
                defaultValue: "Couldn't save this configuration securely. Try again."
            ), retryable: true)
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
            stageStatus[.save] = .passed(caveat: nil)
            // The file-server half rolled back at save time — mark its stage
            // failed up front; `runFileStageIfNeeded` sees the terminal state and
            // never probes a config that isn't there.
            // Not retryable: `retryStages()` never redoes Stage 1, so re-running
            // the connectivity stages cannot write the credential this rolled
            // back. The remedy is in the message — re-run the whole import.
            stageStatus[.file] = .failed(String(
                localized: "settings.pairing.error.fileCredentialFailed",
                defaultValue: "Couldn't save the file-server credential securely. The gateway itself was set up — re-run the import to add the file server."
            ), retryable: false)
        case .committed:
            saveSucceeded = true
            stageStatus[.save] = .passed(caveat: nil)
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

    /// Stage 2 — gateway connection test. The file stage follows either terminal
    /// gateway outcome (pass or fail — the file server is independent).
    private func runGatewayStage(_ payload: PairingPayload, target: RemoteAgentRef) async {
        stageStatus[.gateway] = .running
        switch await environment.runGatewayTest(payload, target: target) {
        case .passed:
            gatewayConnected = true
            stageStatus[.gateway] = .passed(caveat: nil)
            fireConnectedHookIfNeeded()
            await runFileStageIfNeeded(payload, target: target)
        case .failed(let message, let error):
            gatewayConnected = false
            // The taxonomy decides the retry affordance, not the copy: `nil`
            // means no typed error stood behind the message, and unknown is not
            // terminal.
            stageStatus[.gateway] = .failed(message, retryable: error?.isRetryable ?? true)
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
        stageStatus[.file] = result.passed
            ? .passed(caveat: result.uploadsOnly ? Self.uploadOnlyCaveat : nil)
            : .failed(result.failureMessage, retryable: result.retryable)
    }

    /// The sentence a passing-but-upload-only file stage carries. Shares its
    /// STRING KEY with the File transfer page's own staged checklist, so the two
    /// checklists a user sees during one setup cannot describe the same server
    /// in two different ways.
    static var uploadOnlyCaveat: String {
        String(localized: LocalizedStringResource(
            "fileTransfer.test.stage.listing.unsupported",
            defaultValue: "This server can't list folders. Sending files to the agent works; files the agent creates can't come back on their own."))
    }

    /// Recovery "Try again": re-run ONLY the connectivity stages on the
    /// already-saved config (Stage 1 save is NOT redone).
    func retryStages() {
        guard let payload = activePayload, let target = activeTarget else { return }
        stageStatus[.gateway] = .pending
        if payload.fileServer != nil { stageStatus[.file] = .pending }
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
            // FIRST SENTENCE VERBATIM from the typed-address refusal
            // (`SettingsViewModel.plainHTTPRemoteMessage`) — one cause, one
            // wording. The remedy differs because the address is not the user's
            // to edit here: it points at the one place that can mint a code this
            // parser accepts, matching how `.malformed` already ends.
            //
            // A NEW key, not a reworded one: the catalog value wins over
            // `defaultValue:`, so rewording an existing key would ship its old
            // string (`.v3` because the `.v2` wording said "iOS" — wrong on
            // the Mac).
            return String(localized: "settings.pairing.error.insecureURL.v3",
                          defaultValue: "Apple allows plain http:// only to an address on your own network. Re-run conduck-connect with the server's IP address, or put it behind https://.")
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

    func resolveTrust(_ payload: PairingPayload) async -> PairingTrustResolution {
        await viewModel.resolvePairingTrust(payload)
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

    /// Cause AND remedy. The gateway stage in this same sheet renders the full
    /// remedy (`friendlyGatewayMessage`), so a one-sentence file stage next to
    /// it reads as a second, smaller problem rather than the same class of
    /// failure — and the sheet has no Troubleshoot chip to reach the fix.
    func runFileTest(for target: RemoteAgentRef) async -> PairingFileTestResult {
        await viewModel.runFileTransferTest(for: target)
        let result = viewModel.fileTransferTestResults[target]
        let failure = result?.failure
        return PairingFileTestResult(
            // `success`, not `success && returnCapable`. A lane whose server
            // cannot list a folder still moves every byte this stage exists to
            // prove, and a red X here would tell a user whose import worked that
            // it did not — offering a "Try again" that cannot reach a different
            // answer, because the server stated a structural refusal.
            //
            // The caveat rides the SECOND axis rather than being dropped here:
            // the spec's rule is that every screen reporting on this lane says
            // which half of it the user has, and a sheet that graded the stage
            // green and said nothing was the one screen showing an unqualified
            // seal for a server that can only send. `isUploadOnly` is the shared
            // derivation (`success && !returnCapable`), never re-derived locally.
            passed: result?.success == true,
            uploadsOnly: result?.isUploadOnly == true,
            failureMessage: failure?.descriptionWithRecovery(for: target),
            retryable: failure?.isRetryable ?? true
        )
    }

    func discardDraft(_ target: RemoteAgentRef) {
        viewModel.discardPairingDraft(target)
    }
}

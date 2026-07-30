// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsRunner.swift
//
// Orchestrator for the local Diagnostics screen — the keystone that seeds and
// drives the `[DiagnosticCheck]` checklist a `DiagnosticsView` renders. Owns the
// TIER boundary that keeps prompting / billing / mutation off the auto-run path
// (`DiagnosticTier`):
//   - `runAutoReads()`      → LOCAL reads ONLY (config shape, permission STATUS,
//                             network path, iCloud account status). Zero network
//                             to user infrastructure, zero TCC prompts, zero cost.
//   - `runConnectionChecks()` → the ONLY place the gateway reachability probe +
//                             the cloud-STT auth probe + the per-lane file reach
//                             probe fire — the sweep (barrier) phase of the
//                             user-tapped "Test everything" run (may POST /
//                             raise the Local Network prompt).
//   - `runTranscriptionTest()` / `runVoicePreview()` / `runFileTransferTest()`
//                             → billable / mutating; explicit button only. The
//                             Watch health pull (free, non-billable) rides the
//                             "Test everything" fan-out + its per-row
//                             `runWatchHealthCheck()` button.
//
// Concurrency model: each action is independently NON-RE-ENTRANT — it guards on
// its own in-flight flag (`isTestingConnections` / `isTranscribing` /
// per-ref `fileTransferTestRunning`, or the `.preparing`/`.playing` preview
// state) and resets it unconditionally, so a second tap while it runs is a no-op.
// Independent
// actions NEVER cross-invalidate each other. `runAutoReads()` runs exactly once
// (an `autoReadStarted` latch neutralizes the SwiftUI `.task`-on-Group multi-fire).
// Late-completing work that outlives the view harmlessly mutates a no-longer-
// observed runner — no generation token needed.
//
// Privacy: every value that reaches a check `title`/`detail` or `copyBlock()` is
// allowlisted — provider KIND / archetype, counts, enum names, taxonomy-derived
// fixes. NEVER a URL, token, key, fingerprint, custom gateway name, endpoint
// label, raw provider error, or file path. `copyBlock()` PHYSICALLY never calls
// `getAPIKey` / `getRemoteAgentToken` / `getRemoteAgentURL` / a fingerprint
// accessor — it composes from primitives captured during the local reads.

import AVFoundation
import Foundation
import Network
import Observation
import SwiftUI   // Transaction / withTransaction — disable the row-insert animation on a structural re-derive
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
// WCSession pairing-state reads for the Watch link row (iOS-only APIs).
import WatchConnectivity
#endif

#if os(macOS)
// CGPreflightScreenCaptureAccess for the Screen Recording capability row.
import CoreGraphics
#endif

#if !os(watchOS)
// Speech is `@available(watchOS, unavailable)` — imported only for the
// non-prompting `SFSpeechRecognizerAuthorizationStatus` STATUS read.
import Speech
#endif

/// Voice-preview playback state for the "Speak a sample" affordance.
/// One failed send, reduced to report-safe tokens. Every field is a closed
/// vocabulary by the time it reaches this type, which is what makes the copy
/// block's allowlist enforceable BY CONSTRUCTION rather than by review: there is
/// no raw URL, UUID, host, token or server text anywhere in it to leak.
struct FailedSendFact: Equatable, Sendable {
    /// A locked builtin raw value (`openclaw`), or the anonymous
    /// `custom-gateway#N` ordinal — never `custom_<uuid>`. `custom-gateway#?`
    /// when the bound gateway is gone (no ordinal exists to name it).
    let backendToken: String
    /// `AppError.errorCode`, or nil on a legacy row that recorded none.
    let code: Int?
    /// A FROZEN `AdapterWireCode` raw value, or `none`/`other`. The wire string
    /// arrives from the server, so an unrecognised one collapses to `other`
    /// rather than being echoed.
    let wireToken: String
    /// Base device only (`phone`/`watch`/`mac`/`carplay`) — the `-text`/`-voice`
    /// modality suffix is dropped.
    let deviceToken: String
    /// TURN-CREATION time. There is no `failedAt` on the record, so this is the
    /// age of the turn, not of the failure — the emitted label must not imply
    /// otherwise.
    let createdAt: Date
}

/// One scoped gateway re-probe: which gateway, and when. Carries no outcome —
/// the gateway's own `checks` row already holds that, and duplicating it here is
/// how the row and the stamp would drift.
struct ScopedGatewayCheck: Equatable, Sendable {
    let ref: RemoteAgentRef
    let date: Date
}

enum DiagnosticVoicePreviewState: Equatable {
    case idle
    case preparing
    case playing
    case done
    case failed(String)
}

// MARK: - Watch health transport (seam — the WCSession round trip is fake-able)

/// What one watch health round trip produced — either the tolerantly-decoded
/// wire reply or the no-response reason. The transport maps its own failure
/// modes (not activated / errorHandler / deadline) so the runner never touches
/// WCSession types directly.
enum WatchHealthTransportResult: Sendable, Equatable {
    case reply(WatchHealthWireReply)
    case noResponse(WatchHealthNoResponseReason)
}

/// Transport seam for the phone → watch `diagnostics-pull` round trip (mirrors
/// the Watch's `SettingsPullTransport` posture: the session gate AND the
/// `sendMessage` exchange both live behind it, so ConduckTests can fake the
/// whole reachability-dependent path).
protocol WatchHealthTransport: Sendable {
    func query(timeout: TimeInterval) async -> WatchHealthTransportResult
}

#if os(iOS)
/// Production transport: one `sendMessage` round trip raced against a local
/// deadline. NOT a task-group race — a child parked in the continuation would
/// hold the group past the deadline (the `TaskDeadline` trap); instead the
/// deadline task and the two WCSession handlers all funnel through the
/// lock-backed `LockedOnce`, so the continuation resumes exactly once no
/// matter which path fires first (or twice, concurrently). The wire dict is
/// decoded into the `Sendable` `WatchHealthWireReply` ON the framework queue —
/// the raw `[String: Any]` never crosses an isolation boundary.
struct WCSessionWatchHealthTransport: WatchHealthTransport {
    func query(timeout: TimeInterval) async -> WatchHealthTransportResult {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            return .noResponse(.transportError(code: WCError.Code.sessionNotActivated.rawValue))
        }
        return await withCheckedContinuation { continuation in
            let once = LockedOnce()
            let deadlineTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, once.claim() else { return }
                continuation.resume(returning: .noResponse(.timedOut))
            }
            WCSession.default.sendMessage(
                [AppleSpeechRelayCoordinator.Wire.kindKey: Constants.watchDiagnosticsPullMessageKind],
                replyHandler: { dict in
                    let wire = WatchHealthWireReply(dict: dict)
                    guard once.claim() else { return }
                    deadlineTask.cancel()
                    continuation.resume(returning: .reply(wire))
                },
                errorHandler: { error in
                    // Numeric `WCError` code only (allowlist-safe primitive) —
                    // covers unreachable, an old Watch build without the
                    // responder (delivery failure), and transport errors alike.
                    let code = (error as NSError).code
                    guard once.claim() else { return }
                    deadlineTask.cancel()
                    continuation.resume(returning: .noResponse(.transportError(code: code)))
                }
            )
        }
    }
}
#else
/// Watch queries are an iOS-only concept — the macOS runner never builds a
/// `sync.watch` row, so this stub exists only to keep the init signature
/// platform-uniform. Always "no response".
struct UnsupportedWatchHealthTransport: WatchHealthTransport {
    func query(timeout: TimeInterval) async -> WatchHealthTransportResult {
        .noResponse(.transportError(code: 0))
    }
}
#endif

@MainActor
@Observable
final class DiagnosticsRunner {

    // MARK: - Published state

    /// Ordered checklist. Category order is connection → voice → capabilities →
    /// sync; within connection the focused/bound gateway rows sort first, each with
    /// its per-gateway file-server lane rendered beneath it in the view (the lanes
    /// themselves live in `fileLanes`, outside `checks`).
    private(set) var checks: [DiagnosticCheck] = []

    /// Set when `runConnectionChecks()` completes (in-app `Date()` is fine here;
    /// it is NOT used as a run-generation token).
    private(set) var lastChecked: Date?

    private(set) var isTestingConnections = false
    private(set) var connectionChecksHaveRun = false

    /// The "Test everything" orchestration (`runAllTests()`) is in flight — the
    /// single outer flag the summary/top-button read. Brackets the whole run
    /// (sweep + fan-out); `isTestingConnections` is only ever true INSIDE it.
    private(set) var isRunningAllTests = false

    /// In-flight guards for the explicit paid/mutating actions. Exposed
    /// `private(set)` so the view can disable each button while its action runs.
    private(set) var isTranscribing = false
    /// The permission row whose explicit Allow action is currently presenting
    /// or resolving an OS prompt. It participates in `isBusy` so a whole-setup
    /// sweep cannot start underneath a permission dialog.
    private(set) var permissionRequestInFlight: DiagnosticPermission?
    /// Current authorization states backing the actionable permission rows. The
    /// Speech state is meaningful only while Apple on-device STT is active (the
    /// row is absent for cloud STT). Notifications additionally tracks the
    /// authorized-but-alerts-off state, which needs an Open Settings action.
    private(set) var microphonePermissionState: DiagnosticPermissionState = .unknown
    private(set) var speechRecognitionPermissionState: DiagnosticPermissionState = .unknown
    private(set) var notificationPermissionState: DiagnosticPermissionState = .unknown
    private(set) var screenRecordingPermissionState: DiagnosticPermissionState = .unknown
    private var notificationAlertsAreSuppressed = false
    /// Refs whose staged (mutating) file-server write test is in flight — one
    /// entry per gateway currently testing (mirrors
    /// `SettingsViewModel.fileTransferTestRunning`). The per-lane inline button
    /// disables while its ref is in the set.
    private(set) var fileTransferTestRunning: Set<RemoteAgentRef> = []

    /// Refs whose SCOPED gateway re-probe is in flight — the per-gateway "Check
    /// again" action. Free and non-mutating (the same `/v1/models`-class probe the
    /// sweep runs), so unlike the file/transcription tests it needs no cost
    /// warning; it is tracked per ref for the same reason: one gateway's button
    /// disables without freezing the others.
    private(set) var gatewayRecheckRunning: Set<RemoteAgentRef> = []

    /// The most recent scoped gateway re-probe (ref + when). Transient and
    /// deliberately NOT persisted: it exists so a user who rechecks one gateway
    /// sees that THAT probe just ran, without the full-sweep stamp lying about
    /// rows nobody touched. Cleared on every rebuild — a config change makes it
    /// meaningless.
    private(set) var lastScopedGatewayCheck: ScopedGatewayCheck?

    /// The staged write-test result PER GATEWAY (reuses the file-server engine
    /// type) — drives that lane's `FileTransferStageChecklist`.
    private(set) var fileTransferResults: [RemoteAgentRef: FileTransferTestResult] = [:]

    private(set) var voicePreview: DiagnosticVoicePreviewState = .idle

    /// Watch health (iOS) — the LAST GOOD reply's facts. Deliberately preserved
    /// across a failed refresh ("Last checked <relative> — couldn't refresh"
    /// beats erasing useful evidence) and across `refreshConfig()` rebuilds
    /// (held outside `checks`, the `fileLanes` pattern).
    private(set) var watchHealth: WatchHealthState?
    /// Outcome of the MOST RECENT watch health query (nil = never queried).
    /// Drives the failure line when the newest query didn't produce a report.
    private(set) var watchHealthLastOutcome: WatchHealthQueryOutcome?
    /// The per-row "Check" action is in flight (its button spinner + `isBusy`).
    private(set) var isCheckingWatch = false

    /// True when ANY test (the full run OR a single per-row action) is in flight.
    /// The top "Test everything" button + `runAllTests()`'s own guard read this so a
    /// full run can't start while a manual row test is running, and vice-versa —
    /// closing the race where the sweep's file-reach probe and a row write test both
    /// write the same lane's `reachAuth`. (Row buttons gate on `isRunningAllTests`
    /// only, NOT this, so two DIFFERENT per-row tests can still run concurrently.)
    var isBusy: Bool {
        isRunningAllTests || isTestingConnections || isTranscribing
            || !fileTransferTestRunning.isEmpty || !gatewayRecheckRunning.isEmpty
            || isCheckingWatch
            || permissionRequestInFlight != nil
            || voicePreview == .preparing || voicePreview == .playing
    }

    /// Everything amber-or-red the screen currently shows, in one number — the
    /// summary's source of truth. Counts failed/warning check rows PLUS the
    /// states held OUTSIDE `checks`: the Active-setup provider warnings, each
    /// file lane's failure/unconfirmed badge, and the Watch health block's
    /// denied-permission lines (only while the live Watch row renders them) — so
    /// a green "Checks passed" can never sit above a visible amber line.
    var attentionCount: Int {
        var count = 0
        for check in checks {
            switch check.status {
            case .failed, .warning: count += 1
            default: break
            }
        }
        if let setup = activeVoiceSetup {
            if setup.sttStatus == .warning { count += 1 }
            if setup.ttsStatus == .warning { count += 1 }
        }
        count += fileLanes.filter(\.needsAttention).count
        // Watch amber lines render only under the LIVE row form with the same
        // state the view shows (fresh reply, or the preserved last-good facts).
        if checks.first(where: { $0.id == Self.watchCheckID })?.status == .passed,
           let outcome = watchHealthLastOutcome {
            let rendered: WatchHealthState? = {
                if case .reply(let state) = outcome { return state }
                return watchHealth
            }()
            count += rendered?.attentionCount ?? 0
        }
        return count
    }

    /// Gate for the green "Checks passed" verdict: the real sweep has run at
    /// least once, nothing is in flight, and no row is still settling. Config
    /// reads alone must never mint a green verdict — an untested setup isn't a
    /// passing one.
    var checksSettledGreen: Bool {
        connectionChecksHaveRun && !isBusy && !checks.contains { $0.status == .running }
    }

    /// The gateway the failing conversation is bound to (banner deep-link source).
    /// Mutable so a PERSISTENT Settings-hosted runner can be re-focused via
    /// `setFocus(ref:code:)` (the menu-bar popover's Troubleshoot hand-off, which
    /// can't present its own sheet). The sheet-owned runners set it once at init.
    private(set) var focusedRef: RemoteAgentRef?
    /// The `AppError` numeric code that opened this screen (banner deep-link).
    private(set) var focusedErrorCode: Int?

    /// Plain-English cause + fix for the deep-linked failure (computed in `init`).
    private(set) var focusedExplanation: (title: String, cause: String, fix: String)?

    /// The active STT + TTS providers, named the same way the Voice Setup screen
    /// names them, with configuration readiness used only to surface warnings.
    /// Held OUTSIDE `checks` so a user-named custom endpoint never reaches
    /// `copyBlock()` (the allowlist). Nil when the Voice section is hidden.
    private(set) var activeVoiceSetup: VoiceSetupState?

    /// Per-gateway file-server lane display state — one entry per FILE-CAPABLE
    /// gateway (`openrouter` excluded via `fileTransferSupported`), configured or
    /// not. Held OUTSIDE `checks` like `activeVoiceSetup` so a user-named custom
    /// gateway never reaches `copyBlock()`. See `FileLaneState`.
    private(set) var fileLanes: [FileLaneState] = []

    /// Ordered per-gateway display model (UI-only) — one entry per CONFIGURED
    /// gateway (incl. non-file-capable `openrouter`), focused/active-sorted to match
    /// the Connection check order. Carries the real display NAME (a custom gateway's
    /// user label, or the "Custom gateway N" fallback), held OUTSIDE `checks` so the
    /// name never reaches `copyBlock()`. The view titles each gateway row from it,
    /// pairs the live status from `checks` (by `connectionCheckID`), and renders the
    /// nested file-server sub-row from `fileLanes` (by `ref`). See `GatewayDisplayEntry`.
    private(set) var gatewayDisplayOrder: [GatewayDisplayEntry] = []

    /// Config signatures captured on the last rebuild — the guard that decides
    /// whether a live re-derive may CARRY a prior probe/test result. Provider (or
    /// key-presence) change ⇒ the STT/TTS test rows RESET rather than keep a
    /// result bound to the provider that produced it. `presetID|hasKey` shape.
    private var activeSTTSignature = ""
    private var activeTTSSignature = ""

    /// Section visibility — resolved from local config reads in `runAutoReads()`
    /// (the actor accessors require `await`, so these start `false` and light up
    /// once the first local read lands; `@Observable` re-renders reactively).
    var showsVoiceSection = false
    var showsSyncSection = false
    /// The network-path row is supporting evidence, not a useful standing green
    /// result. Show it only when the device appears offline or Low Data Mode may
    /// constrain transfers; the underlying fact remains in Copy Diagnostics.
    private(set) var showsNetworkConnectionIssue = false
    /// Capabilities and Permissions visibility — true whenever ANY `.capability`
    /// check exists. Notifications and Microphone are always built (iOS + macOS),
    /// while Speech Recognition and macOS Screen Recording remain relevance-gated.
    var showsCapabilitySection = false

    // MARK: - Non-re-entrancy latches

    /// Auto-read runs exactly ONCE — neutralizes the SwiftUI `.task`-on-Group
    /// multi-fire. Set synchronously before the first `await`.
    private var autoReadStarted = false
    /// True once `runAutoReads()` has finished seeding the checklist;
    /// `runConnectionChecks()` gates on it.
    private var didAutoRead = false

    // Independent actions never cross-invalidate: each explicit action guards on
    // its OWN in-flight flag (above) and any late-completing unstructured work
    // that outlives the view harmlessly mutates a no-longer-observed runner.

    /// Per-ref file-lane config signature captured on the last rebuild — gates
    /// carry-over of the reach/auth probe result (a lane whose URL/credential/pin
    /// changed RESETS its probe result rather than keeping a stale one) AND drops a
    /// stale reach outcome that lands after the lane changed mid-probe.
    private var fileLaneSignatures: [RemoteAgentRef: String] = [:]

    /// Per-ref gateway config signature (url + token + scheme + pin, hashed) —
    /// the gateway rows' equivalent of `fileLaneSignatures`: gates result
    /// carry-over on a re-derive AND drops a probe outcome that lands after the
    /// gateway's config changed mid-probe.
    private var gatewaySignatures: [RemoteAgentRef: String] = [:]

    /// Single latch around BOTH the initial `runAutoReads` phase-2 connectivity
    /// probe AND `reprobeConnectivity`, so a foreground re-derive can't race a
    /// second probe against the first one still landing (Codex catch 4).
    private var connectivityProbeInFlight = false

    // MARK: - Captured facts for `copyBlock()` (allowlisted primitives only)

    private var factAppVersion = "?"
    private var factAppBuild = "?"
    private var factOSName = "?"
    private var factOSVersion = "?"
    private var factDeviceClass = "?"
    private var factNetworkReachable = false
    private var factNetworkInterface = "unknown"
    private var factNetworkExpensive = false
    private var factNetworkConstrained = false
    private var factSTTArchetype = "none"
    private var factTTSArchetype = "none"
    private var factSTTKeyCount = 0
    private var factGatewayKinds: [String] = []
    private var factCustomGatewayCount = 0
    private var factPartialGatewayCount = 0
    private var factAuthBearerCount = 0
    private var factAuthNoneCount = 0
    /// Phase-D silent-failure facts (allowlisted primitives). Low Power Mode
    /// rides `factBackgroundRefresh` as its `(lpm)` suffix, not a field here.
    private var factCamera = "n/a"
    private var factShareInboxStuck = 0
    private var factShareTargetsHealthy = "n/a"
    private var factPendingRetry = "none"
    private var factStorage = "unknown"
    /// Chunk-2 capability facts (platform-scoped; `"n/a"` where inapplicable).
    private var factBackgroundRefresh = "n/a"
    private var factScreenRecording = "n/a"
    private var factWatch = "n/a"
    /// Settings-courier delivery facts (iOS; bucketed dates + filtered counts).
    private var factWatchBroadcast = "n/a"
    private var factICloudStatus = "unknown"
    private var factUbiquityPresent = false
    private var factSyncEventCount = 0
    private var factSyncErrorCount = 0
    private var factMicPermission = "unknown"
    private var factSpeechPermission = "unknown"
    private var factNotificationPermission = "unknown"
    /// Whether Speech-Recognition permission is even in play (only when the active
    /// STT provider is Apple on-device). Drives the "not used" qualifier in the
    /// copy block so `Speech: authorized` doesn't read as a live dependency when
    /// the row itself is `[n/a]`.
    private var factSpeechApplicable = false
    /// Recent TTS outcome ring events (the device-local forensic log) captured at
    /// read time for the copy block. Rendered as privacy-safe tokens ONLY (surface /
    /// outcome / stage / bucketed error code / typed key state / opaque config
    /// signature / relative age) — never text, keys, URLs, or voice names.
    private var factTTSOutcomes: [TTSOutcomeEvent] = []

    /// Recent FAILED chat turns, already reduced to report-safe tokens at capture
    /// time (the raw `custom_<uuid>` and the raw wire string stop at the
    /// redaction boundary and never reach a stored field). Fixes the report's
    /// worst property: `copyBlock()` iterates probe results only, so it could read
    /// all-green while every real send was failing.
    private var factFailedSends: [FailedSendFact] = []

    /// Per-gateway "a real chat turn completed from THIS device under the CURRENT
    /// config" — the one claim no probe can make. Read through the accessor that
    /// compares config signatures, so a gateway edited since its last success
    /// correctly reads as unproven rather than carrying a stale green.
    private(set) var chatSuccesses: [RemoteAgentRef: Date] = [:]

    /// Report-safe form of `chatSuccesses`: anonymized gateway token + bucketed
    /// age, in the gateway rows' display order.
    private var factChatSuccesses: [(token: String, at: Date)] = []

    /// Watch health transport — production defaults to the platform impl;
    /// ConduckTests inject a fake to drive the round trip deterministically.
    private let watchHealthTransport: any WatchHealthTransport

    /// The phone-side patience budget for one watch health round trip —
    /// matches the Watch's own settings-pull `maxWait` default.
    static let watchHealthQueryTimeout: TimeInterval = 5

    /// The Apple Watch row's frozen check id — shared with the view's
    /// special-case dispatch (Check button + health sub-block) so the runner/
    /// view coupling can't fork on a typo.
    static let watchCheckID = "sync.watch"

    // MARK: - Init

    init(
        focusedRef: RemoteAgentRef? = nil,
        focusedErrorCode: Int? = nil,
        watchHealthTransport: (any WatchHealthTransport)? = nil
    ) {
        self.focusedRef = focusedRef
        self.focusedErrorCode = focusedErrorCode
        #if os(iOS)
        self.watchHealthTransport = watchHealthTransport ?? WCSessionWatchHealthTransport()
        #else
        self.watchHealthTransport = watchHealthTransport ?? UnsupportedWatchHealthTransport()
        #endif
        if let code = focusedErrorCode {
            self.focusedExplanation = Self.makeFocusedExplanation(ref: focusedRef, code: code)
        }
    }

    /// Plain-English (title, cause, fix) for a focused failure — shared by `init`
    /// and `setFocus`. The title is a KIND label only (built-in display name or
    /// the generic "Custom gateway"), never a user's name; it needs no roster, so
    /// it's correct even before `runAutoReads()` completes.
    private static func makeFocusedExplanation(ref: RemoteAgentRef?, code: Int) -> (title: String, cause: String, fix: String) {
        let explained = DiagnosticsExplainer.explain(code: code)
        let title: String
        if let ref {
            switch ref {
            case .builtin(let backend): title = "\(backend.displayName) \(Self.gatewayWord)"
            case .custom: title = Self.customGatewayTitle
            }
        } else {
            title = String(localized: "diagnostics.focused.generic", defaultValue: "Last request")
        }
        return (title, explained.cause, explained.fix)
    }

    /// Re-focus an ALREADY-BUILT runner on a specific failure — the macOS
    /// menu-bar popover's Troubleshoot hand-off, which routes through the
    /// PERSISTENT Settings-hosted runner because it can't present its own sheet.
    /// Recomputes the focused card and bumps the failing gateway's row to the
    /// front of Connection. MUST be called BEFORE the Diagnostics category is
    /// shown so the focused card is present on the first paint (setting it while
    /// the screen is visible would insert the card mid-layout — the flicker).
    func setFocus(ref: RemoteAgentRef?, code: Int) {
        focusedRef = ref
        focusedErrorCode = code
        focusedExplanation = Self.makeFocusedExplanation(ref: ref, code: code)

        // Self-cleaning: drop any prior `.focused` tag so a re-focus can never leave
        // two rows tagged `.focused` (idempotent even if called on an already-focused
        // runner). Today's only caller runs before `runAutoReads` populates `checks`,
        // so this is a no-op in the wired path — a guard against future reuse.
        for i in checks.indices where checks[i].role == .focused { checks[i].role = nil }

        // Promote the failing gateway's row (if it exists) to lead Connection and
        // tag it `.focused`.
        guard let ref, let idx = checks.firstIndex(where: { $0.id == Self.connectionCheckID(for: ref) }) else { return }
        checks[idx].role = .focused
        let row = checks.remove(at: idx)
        checks.insert(row, at: 0)   // Connection is the first category; index 0 leads it.
        // Keep the UI-only display order in lock-step so gateway rows render in the
        // same focused-first order the view reads their status from.
        if let gIdx = gatewayDisplayOrder.firstIndex(where: { $0.ref == ref }) {
            let entry = gatewayDisplayOrder.remove(at: gIdx)
            gatewayDisplayOrder.insert(entry, at: 0)
        }
    }

    // MARK: - Tier 1: local reads (NO network to user infra, NO prompts)

    /// Read every LOCAL config/permission fact (no network, no prompt, no bill)
    /// and (re)build the checklist scaffold from it. Shared by the once-latched
    /// `runAutoReads()` (`carryOver: false`) and the live `refreshConfig()`
    /// (`carryOver: true`). On `carryOver` a freshly-built row keeps its prior
    /// status/detail ONLY when its input signature is unchanged (`carryOverResults`),
    /// so a provider switch RESETS the STT/TTS test rows while gateway/network/sync
    /// results survive. The two SLOW probes (network path + CloudKit account status)
    /// are NOT run here — they stay in `runAutoReads`'s phase 2 / behind "Test
    /// connections"; on `carryOver` their rows carry their last outcome.
    private func performLocalReadsAndRebuild(carryOver: Bool) async {
        // --- Local config-shape reads (Keychain / defaults; no network) --------
        let manager = SettingsManager.shared
        let refs = await manager.configuredRemoteAgentRefs()
        let defaultRef = await manager.defaultRemoteAgentRef()
        let sttSnapshot = await manager.activeSTTSnapshot()
        let ttsSnapshot = await manager.activeTTSSnapshot()
        let storedKeys = await manager.presetIDsWithStoredKey()
        let roster = await manager.customVoiceEndpoints()
        let customGateways = await manager.customGateways()
        // Single canonical per-custom ordinal (config/input order) — the SAME `N`
        // the copy block's `custom-gateway#N` tag + `file[custom-gateway#N]` line
        // use, reused for the gateway rows' `reportLabel` AND the on-screen
        // "Custom gateway N" display fallback, so screen and report never disagree.
        let customOrdinals = Self.customOrdinals(refs)

        var authSchemes: [RemoteAgentAuthScheme] = []
        // Per-ref gateway config signature (hash of url + token + scheme + pin) —
        // gates gateway-row result carry-over exactly like the file-lane and voice
        // signatures: fixing a mistyped token (which posts
        // `.settingsDidChangeRemotely` but changes no URL) RESETS the stale
        // `.failed` row instead of carrying it to the next full run.
        var newGatewaySignatures: [RemoteAgentRef: String] = [:]
        for ref in refs {
            authSchemes.append(await manager.getRemoteAgentAuthScheme(for: ref))
            if let snap = await manager.remoteAgentSnapshot(for: ref) {
                newGatewaySignatures[ref] = Self.gatewaySignature(
                    url: snap.url,
                    token: snap.token,
                    authScheme: snap.authScheme,
                    fingerprint: snap.certFingerprintHex
                )
            }
        }

        // Partially-configured gateways — URL synced here but not send-able
        // (bearer token / required model missing on THIS device). Fail-closed
        // `configuredRemoteAgentRefs()` silently drops these, and a healthy
        // sibling gateway masks the drop entirely — the one cross-device-skew
        // case the "No Personal AI configured" row can't catch. The focused
        // ref is excluded when its own dedicated row (`focused.missing`) is
        // about to say the same thing more specifically.
        var partialRefs = await manager.partiallyConfiguredRemoteAgentRefs()
        if let focusedRef, !refs.contains(focusedRef) {
            partialRefs.removeAll { $0 == focusedRef }
        }
        let partialGatewayCount = partialRefs.count

        // Phase-D silent-failure reads — all local + cheap (dir listing /
        // metadata decode / volume capacity), no network, no prompt.
        let stuckShareCount = await SharedInboxDrainer.shared.diagnosticStuckCount()
        let shareTargetsHealthy = Self.shareTargetsSnapshotHealthy(hasGateways: !refs.isEmpty)
        let pendingRetry = await PendingRetryStore.shared.diagnosticSnapshot()
        let storageFreeBytes = Self.appGroupFreeBytes()
        // Recent FAILED sends — the same singleton-diagnostic-accessor idiom as
        // the two reads above, and deliberately on THIS tier: a local Core Data
        // read, no egress, no billing, so it refreshes on every rebuild and is
        // idempotent by construction. Over-fetched then deduped, because a run of
        // identical retries against one gateway would otherwise crowd out a second
        // gateway that is also failing.
        let failedSends = Self.redactFailedSends(
            await ConversationStore.shared.recentFailedTurnSummaries(limit: 20),
            customOrdinals: customOrdinals
        )
        // Per-ref chat-success records. The accessor itself drops a record whose
        // config signature no longer matches, so an edited gateway reads as
        // unproven here without this loop knowing the invalidation rules.
        var newChatSuccesses: [RemoteAgentRef: Date] = [:]
        for ref in refs {
            if let success = await manager.getGatewayChatSuccess(for: ref) {
                newChatSuccesses[ref] = success.at
            }
        }
        // Report form: the anonymous ordinal, never a user's gateway name.
        let chatSuccessFacts: [(token: String, at: Date)] = refs.compactMap { ref in
            guard let at = newChatSuccesses[ref] else { return nil }
            let token: String = {
                switch ref {
                case .builtin(let backend): return backend.rawValue
                case .custom: return "custom-gateway#\(customOrdinals[ref] ?? 0)"
                }
            }()
            return (token: token, at: at)
        }

        // --- Per-gateway file lanes (the founder's ask: file server is PER
        // gateway) — one lane per FILE-CAPABLE gateway (`openrouter` excluded via
        // `fileTransferSupported`), configured or not. `configured` is a cheap
        // local read (URL in defaults + credential in Keychain both present);
        // `writeVerified` reflects the persisted staged-test pass. The reach/auth
        // probe result (set only by "Test connections") is CARRIED across a live
        // re-derive iff the lane's config signature is unchanged.
        var newFileLanes: [FileLaneState] = []
        var newFileLaneSignatures: [RemoteAgentRef: String] = [:]
        for ref in refs where Self.isFileCapable(ref) {
            let snap = await manager.fileTransferSnapshot(for: ref)
            let signature = Self.fileLaneSignature(snap)
            var reachAuth: DiagnosticStatus = .notRun
            var detail: String?
            if carryOver,
               let prior = fileLanes.first(where: { $0.ref == ref }),
               fileLaneSignatures[ref] == signature {
                reachAuth = prior.reachAuth
                detail = prior.detail
            } else if carryOver {
                // Lane config changed (or is new): the staged-checklist drill-down
                // must reset WITH the badge — else the old config's PUT→GET→DELETE
                // passes keep rendering under a fresh "not tested" lane.
                fileTransferResults[ref] = nil
            }
            newFileLanes.append(FileLaneState(
                ref: ref,
                displayName: Self.gatewayDisplayName(ref, customGateways: customGateways, ordinal: customOrdinals[ref]),
                backendKind: Self.gatewayKind(ref),
                configured: snap != nil,
                reachAuth: reachAuth,
                writeVerified: snap?.available ?? false,
                detail: detail,
                customOrdinal: customOrdinals[ref]
            ))
            newFileLaneSignatures[ref] = signature
        }

        // --- Permission STATUS reads (no prompt) -------------------------------
        let micStatus = AVAudioApplication.shared.recordPermission
        let micName = Self.recordPermissionName(micStatus)
        let micPermissionState = Self.recordPermissionState(micStatus)
        let micCheckStatus = micPermissionState.diagnosticStatus(failureCode: nil)

        var speechName = "unavailable"
        var speechCheckStatus: DiagnosticStatus = .notApplicable
        var speechPermissionState: DiagnosticPermissionState = .unknown
        var speechApplicable = false
        #if !os(watchOS)
        let speechStatus = AppleSpeechRunner.currentAuthorizationStatus()
        speechName = Self.speechStatusName(speechStatus)
        speechPermissionState = Self.speechPermissionState(speechStatus)
        // The Speech-Recognition permission only matters when the active STT
        // provider is Apple on-device (in-process); otherwise it is N/A.
        speechApplicable = (sttSnapshot.provider.transport == .inProcess)
        speechCheckStatus = speechApplicable
            ? speechPermissionState.diagnosticStatus(failureCode: AppError.speechPermissionDenied.errorCode)
            : .notApplicable
        #endif

        // Notification authorization STATUS — a pure read (never `ensureRequested`,
        // which would prompt on the auto-run path). This is the SILENT single point
        // of failure for every headless feedback path (Shortcut / background send /
        // share-drain deliver results only as local notifications), so a denial
        // belongs on the checklist beside mic + speech.
        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        let notifName = Self.notificationStatusName(notifSettings)
        let notifPermissionState = Self.notificationPermissionState(notifSettings)
        let notifAlertsSuppressed = Self.notificationAlertsSuppressed(notifSettings)
        let notifCheckStatus = Self.notificationCheckStatus(notifSettings)

        // --- Chunk-2 capability reads (platform-scoped local reads, no prompt) ---
        // Background App Refresh (iOS/iPadOS) stays as a copy-block fact only.
        // Conduck's durable work uses background URLSession rather than
        // BGAppRefreshTask, so the broad system setting is not strong enough
        // evidence for a user-facing pass/fail row.
        #if os(iOS)
        let lowPowerOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        let bgStatus = UIApplication.shared.backgroundRefreshStatus
        factBackgroundRefresh = Self.backgroundRefreshName(bgStatus) + (lowPowerOn ? "(lpm)" : "")
        #endif

        // Camera (iOS) — the attachment picker's camera path. Self-gating
        // relevance without a flag: the row appears ONLY on `.denied`, which
        // provably implies the user attempted the camera once (the prompt is
        // the only path to a denial). `.restricted` is deliberately row-less —
        // Screen-Time/MDM restriction exists WITHOUT any camera attempt, so a
        // row would permanently nag users who never touched the feature (it
        // still travels in the copy block as `Camera: restricted`, and the
        // picker's own UI explains a live restricted attempt). `.warning`,
        // never red: the camera is optional (photo-library and file
        // attachments still work).
        var cameraRow: DiagnosticCheck?
        #if os(iOS)
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        factCamera = Self.cameraStatusName(cameraStatus)
        if UIImagePickerController.isSourceTypeAvailable(.camera), cameraStatus == .denied {
            cameraRow = DiagnosticCheck(
                id: "capability.camera",
                title: String(localized: "diagnostics.capability.camera", defaultValue: "Camera"),
                category: .capability,
                tier: .autoRead,
                status: .warning,
                detail: String(localized: "diagnostics.capability.camera.denied", defaultValue: "Turn on Camera access for Conduck in Settings to attach photos you take."),
                role: nil, reportLabel: nil
            )
        }
        #endif

        // Screen Recording (macOS) — for ⌘⇧2 "Screenshot & Ask". Relevance-gated
        // on `screenRecordingCaptureAttemptedKey` (written once the feature works
        // or its system ask has fired — i.e. once Conduck exists in the Settings
        // pane this row deep-links), so it never becomes a permanent scary row
        // for users who never screenshot. The gate deliberately reads the bool
        // ALONE — after a re-signed install the row must stay visible and read
        // denied until the new code signature is granted (TCC consent is per
        // signature). `CGPreflightScreenCaptureAccess()` is a clean local read.
        var screenRecordingRow: DiagnosticCheck?
        #if os(macOS)
        let screenAttempted = (UserDefaults(suiteName: Constants.appGroupID)?
            .bool(forKey: Constants.screenRecordingCaptureAttemptedKey)) ?? false
        if screenAttempted {
            let granted = CGPreflightScreenCaptureAccess()
            screenRecordingPermissionState = granted ? .allowed : .denied
            factScreenRecording = granted ? "authorized" : "denied"
            screenRecordingRow = DiagnosticCheck(
                id: "capability.screenRecording",
                title: String(localized: "diagnostics.capability.screenRecording", defaultValue: "Screen Recording"),
                category: .capability,
                tier: .autoRead,
                status: granted ? .passed : .warning,
                detail: granted
                    ? String(localized: "diagnostics.capability.screenRecording.ok", defaultValue: "Screenshot & Ask can capture your screen.")
                    : String(localized: "diagnostics.capability.screenRecording.denied", defaultValue: "Turn on Screen Recording for Conduck in System Settings to use ⌘⇧2 Screenshot & Ask. If it is already on, turn it off and on again, then quit and reopen Conduck."),
                role: nil, reportLabel: nil
            )
        } else {
            screenRecordingPermissionState = .unknown
        }
        #endif

        // Share to Conduck (iOS + macOS) — the share-extension pipeline's two
        // silent failure modes, one row, hidden when healthy: STUCK inbox items
        // (drainer-classified — a live in-flight long turn never counts) and a
        // missing/undecodable picker snapshot while gateways are configured
        // (the appex would show an empty "Send to" list). `.warning` — recovery
        // is opening the app / a settings change; nothing is lost.
        var shareInboxRow: DiagnosticCheck?
        factShareInboxStuck = stuckShareCount
        factShareTargetsHealthy = shareTargetsHealthy.map { $0 ? "ok" : "broken" } ?? "n/a"
        if stuckShareCount > 0 || shareTargetsHealthy == false {
            var shareDetails: [String] = []
            if stuckShareCount > 0 {
                shareDetails.append(String(localized: "diagnostics.capability.shareInbox.stuck", defaultValue: "\(stuckShareCount) shared item(s) have been waiting to import for a while — opening a conversation usually clears them."))
            }
            if shareTargetsHealthy == false {
                shareDetails.append(String(localized: "diagnostics.capability.shareInbox.targetsBroken", defaultValue: "The share sheet's target list couldn't be read — sharing to Conduck may show an empty picker. It regenerates when you open the app or change a setting."))
            }
            shareInboxRow = DiagnosticCheck(
                id: "capability.shareInbox",
                title: String(localized: "diagnostics.capability.shareInbox", defaultValue: "Share to Conduck"),
                category: .capability,
                tier: .autoRead,
                status: .warning,
                detail: shareDetails.joined(separator: " "),
                role: nil, reportLabel: nil
            )
        }

        // Storage (all platforms) — probed on the App-Group volume (where the
        // store, share inbox, and attachment staging live). Hidden when healthy
        // OR unknown (nil probe ≠ healthy, but an "unknown" row is pure noise —
        // the copy block still carries the bucket). Amber both tiers: low
        // storage is recoverable, a red would over-bubble it.
        var storageRow: DiagnosticCheck?
        factStorage = Self.storageBucket(freeBytes: storageFreeBytes)
        if let storageState = Self.storageRowState(freeBytes: storageFreeBytes) {
            storageRow = DiagnosticCheck(
                id: "capability.storage",
                title: String(localized: "diagnostics.capability.storage", defaultValue: "Storage"),
                category: .capability,
                tier: .autoRead,
                status: storageState.status,
                detail: storageState.detail,
                role: nil, reportLabel: nil
            )
        }

        // Apple Watch link (iOS/iPadOS) — is the watch talking to the phone? INFO,
        // not red: hide if not paired; WARN only when Conduck is missing from the
        // wrist; a paired-but-unreachable watch is merely asleep (settings queue
        // via `transferUserInfo`), so it stays informational. The master switch is
        // checked FIRST — a user who turned Watch sync off deliberately gets a
        // neutral "turned off" row (Diagnostics can now explain it), never a
        // misleading connectivity readout. The detail additionally carries the
        // last-turn recency (never/relative — the row can no longer read green
        // while a Watch conversation has never once worked) and a courier line
        // when the most recent settings broadcast FAILED to deliver.
        var watchRow: DiagnosticCheck?
        #if os(iOS)
        if WCSession.isSupported(), WCSession.default.isPaired {
            let watchStatus: DiagnosticStatus
            let watchDetail: String
            if !PhoneSessionManager.shared.isWatchEnabled {
                factWatch = "paired,disabled"
                factWatchBroadcast = "n/a"
                watchStatus = .notApplicable
                watchDetail = String(localized: "diagnostics.sync.watch.disabled", defaultValue: "Watch sync is turned off in Settings ▸ Apple Watch.")
            } else {
                let installed = WCSession.default.isWatchAppInstalled
                let reachable = WCSession.default.isReachable
                let lastTurn = PhoneSessionManager.shared.lastSuccessfulWatchTurn
                let watchState = Self.watchRowState(installed: installed, reachable: reachable, lastTurn: lastTurn)
                // Settings-courier delivery stamps (marker-filtered — relay
                // traffic never moves them; see PhoneSessionManager). A failure
                // NEWER than the last success appends a plain-English line;
                // status stays informational (spec: INFO not red).
                let groupDefaults = UserDefaults(suiteName: Constants.appGroupID)
                let courierSuccessAt = groupDefaults?.double(forKey: Constants.watchBroadcastLastSuccessAtKey) ?? 0
                let courierFailureAt = groupDefaults?.double(forKey: Constants.watchBroadcastLastFailureAtKey) ?? 0
                let outstandingCouriers = Self.outstandingSettingsCourierCount()
                watchStatus = watchState.status
                watchDetail = installed && Self.courierFailureIsCurrent(successAt: courierSuccessAt, failureAt: courierFailureAt)
                    ? watchState.detail + " " + String(localized: "diagnostics.sync.watch.courierFailing", defaultValue: "Recent settings updates to the watch haven't gone through.")
                    : watchState.detail
                factWatch = "paired,installed=\(installed),reachable=\(reachable),turn=\(Self.watchTurnRecency(lastTurn))"
                factWatchBroadcast = "lastSuccess=\(Self.stampRecency(courierSuccessAt)) lastFailure=\(Self.stampRecency(courierFailureAt)) outstanding=\(outstandingCouriers)"
            }
            // ONE construction for both branches — the frozen id/title/category/
            // tier can never fork between the disabled and live row forms.
            watchRow = DiagnosticCheck(
                id: Self.watchCheckID,
                title: String(localized: "diagnostics.sync.watch", defaultValue: "Apple Watch"),
                category: .sync,
                tier: .autoRead,
                status: watchStatus,
                detail: watchDetail,
                role: nil, reportLabel: nil
            )
        } else {
            // Un-paired mid-session: reset the facts so a later copy block
            // can't keep reporting the departed watch behind the
            // `factWatch != "n/a"` gate.
            factWatch = "n/a"
            factWatchBroadcast = "n/a"
        }
        #endif

        // --- Fast iCloud + ring-buffer reads (local; NO CloudKit round-trip) ---
        // The ubiquity token + event ring buffer are synchronous local reads. The
        // two SLOW calls — the `NWPathMonitor` first delivery and the CloudKit
        // account-status `refresh()` — are deferred to PHASE 2 (end of this method)
        // so they never hold the checklist empty on first open. Otherwise the
        // amber Copy button renders high (empty sections above it), then jumps to
        // the bottom when the probes land — the "first-open flicker".
        let ubiquityPresent = FileManager.default.ubiquityIdentityToken != nil
        let syncLines = CloudSyncMonitor.recentSyncEventLines()
        let syncErrorCount = syncLines.filter { $0.contains("FAIL") }.count

        // --- Capture allowlisted facts for the copy block (fast fields) --------
        // `factNetwork*` + a refined `factICloudStatus` land in phase 2.
        factAppVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        factAppBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let platform = Self.platformIdentity()
        factOSName = platform.osName
        factDeviceClass = platform.deviceClass
        let v = ProcessInfo.processInfo.operatingSystemVersion
        factOSVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        factSTTArchetype = DiagnosticsExplainer.archetype(forProviderID: sttSnapshot.presetID)
        factTTSArchetype = DiagnosticsExplainer.archetype(forProviderID: ttsSnapshot.providerID)
        factSTTKeyCount = storedKeys.filter { $0 != "apple-on-device" }.count
        factGatewayKinds = refs.map(Self.gatewayKind)
        factCustomGatewayCount = refs.filter { $0.customID != nil }.count
        factPartialGatewayCount = partialGatewayCount
        factAuthBearerCount = authSchemes.filter { $0 == RemoteAgentAuthScheme.bearer }.count
        factAuthNoneCount = authSchemes.filter { $0 == RemoteAgentAuthScheme.none }.count
        factUbiquityPresent = ubiquityPresent
        factSyncEventCount = syncLines.count
        factSyncErrorCount = syncErrorCount
        // Device-local forensic ring (@MainActor, local read — no outbound).
        factTTSOutcomes = TTSOutcomeLog.shared.events()
        factFailedSends = failedSends
        chatSuccesses = newChatSuccesses
        factChatSuccesses = chatSuccessFacts
        factMicPermission = micName
        factSpeechPermission = speechName
        factSpeechApplicable = speechApplicable
        factNotificationPermission = notifName
        // Provisional — phase 2 refines it once the CloudKit account status lands.
        // On a live re-derive we DON'T re-run the CloudKit refresh, so keep the
        // value phase 2 already resolved rather than reverting to the token guess.
        if !carryOver {
            factICloudStatus = ubiquityPresent ? "available" : "unknown"
        }

        // --- Active-provider names (SAME source of truth as Voice Setup) -------
        // `shortDisplayName` → "Apple" / "OpenAI" / a custom endpoint's user name.
        let sttOnDevice = (sttSnapshot.provider.transport == .inProcess)
        let ttsOnDevice = (ttsSnapshot.providerID == TTSProvider.appleTTS.id)
        let sttName = VoiceVendorRegistry.vendor(forSTTPresetID: sttSnapshot.presetID, customEndpoints: roster)?.shortDisplayName
            ?? VoiceVendorRegistry.apple.shortDisplayName
        let ttsName = VoiceVendorRegistry.vendor(forTTSProviderID: ttsSnapshot.providerID, customEndpoints: roster)?.shortDisplayName
            ?? VoiceVendorRegistry.apple.shortDisplayName
        // Keyless BYO endpoints (auth `.none`, the LAN/Tailscale self-hoster case)
        // are correctly configured WITHOUT a key — the "missing key" warning must
        // not fire for them (mirrors `runVoicePreview`'s keyless guard).
        let sttKeylessConfigured = sttSnapshot.customConfig?.auth == STTAuthScheme.none
            && sttSnapshot.customConfig?.url != nil
        let ttsKeylessConfigured = ttsSnapshot.customConfig?.auth == STTAuthScheme.none
            && ttsSnapshot.customConfig?.url != nil
        let sttSetupStatus = Self.providerConfigStatus(isInProcess: sttOnDevice, apiKey: sttSnapshot.apiKey, keylessEndpointConfigured: sttKeylessConfigured)
        let ttsSetupStatus = Self.providerConfigStatus(isInProcess: ttsOnDevice, apiKey: ttsSnapshot.apiKey, keylessEndpointConfigured: ttsKeylessConfigured, keyState: ttsSnapshot.keyState)

        // Signatures that gate result carry-over on a live re-derive. They capture
        // the probe INPUTS (provider id + key + model + the resolved BYO-endpoint
        // config + TTS voice), not just presence — so FIXING a typo'd key OR a
        // custom endpoint's URL/auth/pin (each posts `.settingsDidChangeRemotely`)
        // changes the signature and RESETS the stale result instead of carrying it.
        // Hashed so no secret is stored in a comparable field.
        let newSTTSignature = Self.voiceSignature(
            id: sttSnapshot.presetID, apiKey: sttSnapshot.apiKey, model: sttSnapshot.customModel,
            endpoint: sttSnapshot.customConfig.map { Self.endpointComponent(url: $0.url, model: $0.model, auth: $0.auth, pin: $0.certFingerprint) }
        )
        let newTTSSignature = Self.voiceSignature(
            id: ttsSnapshot.providerID, apiKey: ttsSnapshot.apiKey, model: ttsSnapshot.customModel,
            endpoint: ttsSnapshot.customConfig.map { Self.endpointComponent(url: $0.url, model: $0.model, auth: $0.auth, pin: $0.certFingerprint) },
            voice: ttsSnapshot.voice
        )

        // --- Section visibility (sync widened in phase 2 if iCloud is down) ----
        // Mic-visibility fix (a bug): also show the Voice section when mic is
        // DENIED (or Apple-speech denied/restricted) — exactly the fresh Apple-STT
        // user with no keys who just tapped "Don't Allow" would otherwise never see
        // the red mic row. `.undetermined` stays hidden (no nagging a user who
        // never asked). `speechCheckStatus` is `.failed` only when Apple on-device
        // STT is active AND speech is denied/restricted.
        let micDenied = (micStatus == .denied)
        var speechDenied = false
        #if !os(watchOS)
        if case .failed = speechCheckStatus { speechDenied = true }
        #endif
        let voiceConfigured = Self.shouldShowVoiceSection(
            hasStoredKeys: !storedKeys.isEmpty,
            sttInProcess: sttSnapshot.provider.transport == .inProcess,
            ttsIsApple: ttsSnapshot.providerID == TTSProvider.appleTTS.id,
            micGranted: micStatus == .granted,
            micDenied: micDenied,
            speechDeniedOrRestricted: speechDenied,
            hasPendingRetry: pendingRetry != nil
        )
        // Sync section shows for iCloud OR a paired Watch. Don't drop a
        // phase-2-widened sync section on a live re-derive.
        let newShowsSync = ubiquityPresent || (watchRow != nil) || (carryOver && showsSyncSection)

        // --- Build the checklist scaffold --------------------------------------
        // On the once-latched auto-read the layout LOCKS here (first paint = final
        // layout — the flicker fix). On a live re-derive the same builder runs and
        // `carryOverResults` restores prior probe/test outcomes, so an unchanged
        // config rebuilds to an identical array (no visible change).
        var built: [DiagnosticCheck] = []

        // Connection: gateway rows (focused/active-ordered) then the network row.
        // The SAME sorted order drives both the `checks` rows and the UI-only
        // `gatewayDisplayOrder` (which carries the real names), so the view renders
        // gateways in the identical order it reads their status from — and every
        // `fileLanes.ref` is a subset of these refs, so a lane can never orphan.
        let sortedGateways = sortedGatewayRefs(refs: refs, defaultRef: defaultRef)
        built.append(contentsOf: buildGatewayRows(sorted: sortedGateways, customOrdinals: customOrdinals))
        let newGatewayDisplayOrder = sortedGateways.map { entry in
            GatewayDisplayEntry(
                ref: entry.ref,
                displayName: Self.gatewayDisplayName(entry.ref, customGateways: customGateways, ordinal: customOrdinals[entry.ref]),
                connectionCheckID: Self.connectionCheckID(for: entry.ref)
            )
        }

        // No-send-able-gateway rows — make the all-green-but-broken Connection
        // section honest. `configuredRemoteAgentRefs()` is fail-closed, so an empty
        // set ALSO catches cross-device token skew (a ref with a synced URL but no
        // bearer token in the synced Keychain is dropped).
        if refs.isEmpty {
            built.append(DiagnosticCheck(
                id: "connection.gateway.none",
                title: String(localized: "diagnostics.connection.gateway.none", defaultValue: "No Personal AI configured"),
                category: .connection,
                tier: .autoRead,
                status: .failed(code: AppError.remoteAgentNotConfigured.errorCode),
                detail: String(localized: "diagnostics.connection.gateway.none.detail", defaultValue: "Add your Personal AI gateway in Settings — every request needs one on this device."),
                role: nil, reportLabel: nil
            ))
        } else if let focusedRef, !refs.contains(focusedRef) {
            // The Troubleshoot deep-link's OWN gateway is not send-able here (token
            // skew / deleted) even though another gateway is healthy — the partial-
            // skew case that matters most. Name the KIND only, never a user name.
            let kindTitle: String
            switch focusedRef {
            case .builtin(let backend): kindTitle = "\(backend.displayName) \(Self.gatewayWord)"
            case .custom: kindTitle = Self.customGatewayTitle
            }
            built.append(DiagnosticCheck(
                id: "connection.gateway.focused.missing",
                title: kindTitle,
                category: .connection,
                tier: .autoRead,
                status: .failed(code: AppError.remoteAgentNotConfigured.errorCode),
                detail: String(localized: "diagnostics.connection.gateway.focused.missing.detail", defaultValue: "This gateway isn't set up on this device — finish adding it in Settings, or Clone the conversation to a configured gateway."),
                role: .focused, reportLabel: nil
            ))
        }

        // Partial-config row — a URL synced here without its key/model. Shown
        // EVEN beside healthy gateways (the masking is the point); anonymous
        // count only, never a name/URL.
        if partialGatewayCount > 0 {
            built.append(DiagnosticCheck(
                id: "connection.gateway.partial",
                title: String(localized: "diagnostics.connection.gateway.partial", defaultValue: "Gateway missing its key or model"),
                category: .connection,
                tier: .autoRead,
                status: .warning,
                detail: partialGatewayCount == 1
                    ? String(localized: "diagnostics.connection.gateway.partial.one", defaultValue: "A gateway synced to this device is missing its key or model here — open Settings and re-enter it, or re-pair.")
                    : String(localized: "diagnostics.connection.gateway.partial.many", defaultValue: "\(partialGatewayCount) gateways synced to this device are missing their key or model here — open Settings and re-enter them, or re-pair."),
                role: nil, reportLabel: nil
            ))
        }

        built.append(DiagnosticCheck(
            id: "connection.network",
            title: String(localized: "diagnostics.connection.network", defaultValue: "Network connection"),
            category: .connection,
            tier: .autoRead,
            status: .running,
            detail: nil,
            role: nil,
            reportLabel: nil
        ))
        // Capabilities — OS permissions the app relies on, grouped away from the
        // gateway send-paths. Notifications carry every headless result (a denial
        // here is why Shortcut/background replies would arrive silently), so the
        // row is always built on iOS + macOS. Background App Refresh is retained
        // only as a copy-block fact because it cannot certify Conduck's background
        // URLSession delivery path.
        built.append(DiagnosticCheck(
            id: "connection.notifications",
            title: String(localized: "diagnostics.connection.notifications", defaultValue: "Notifications"),
            category: .capability,
            tier: .autoRead,
            status: notifCheckStatus,
            detail: Self.notificationDetail(notifSettings),
            role: nil,
            reportLabel: nil
        ))
        if let cameraRow { built.append(cameraRow) }

        // Voice. The generic provider-config rows are GONE — the provider blocks
        // (`activeVoiceSetup`) name the provider instead. The cloud key probe stays
        // with STT; OS permissions are built in Capabilities and Permissions.
        // When the active STT is a user-named custom endpoint, the rows carry the
        // anonymous `custom-stt#N` report label (canonical roster-order ordinal —
        // the report can say WHICH endpoint failed without ever naming it).
        let customSTTLabel = Self.customSTTOrdinal(activePresetID: sttSnapshot.presetID, roster: roster)
            .map { "custom-stt#\($0)" }
        if !sttOnDevice {
            built.append(DiagnosticCheck(
                id: "voice.stt.auth",
                // A keyless BYO endpoint has no key to validate — the probe still
                // checks the endpoint answers at the auth layer, so the row is
                // titled for what it actually tests.
                title: sttKeylessConfigured
                    ? String(localized: "diagnostics.voice.stt.auth.keyless", defaultValue: "Transcription endpoint")
                    : String(localized: "diagnostics.voice.stt.auth", defaultValue: "Transcription key"),
                category: .voice,
                tier: .networkCheck,
                status: .notRun,
                detail: nil, role: nil, reportLabel: customSTTLabel
            ))
        }
        built.append(DiagnosticCheck(
            id: "voice.stt.test",
            title: String(localized: "diagnostics.voice.stt.test", defaultValue: "Transcription test"),
            category: .voice,
            tier: .explicitPaid,
            status: .notRun, detail: nil, role: nil, reportLabel: customSTTLabel
        ))
        built.append(DiagnosticCheck(
            id: "voice.tts.preview",
            title: String(localized: "diagnostics.voice.tts.preview", defaultValue: "Voice preview"),
            category: .voice,
            tier: .explicitPaid,
            status: .notRun, detail: nil, role: nil, reportLabel: nil
        ))
        // Mic + Speech Recognition live in VOICE (task-oriented troubleshooting:
        // every prerequisite for recording/transcription sits beside the
        // functional test), not in Capabilities. Their visibility is therefore
        // Voice-section-gated: `.undetermined` with no other Voice relevance stays
        // hidden (no nagging a user who never asked), while a denial force-shows
        // the section via `shouldShowVoiceSection`.
        built.append(DiagnosticCheck(
            id: "voice.mic.permission",
            title: String(localized: "diagnostics.voice.mic", defaultValue: "Microphone"),
            category: .voice,
            tier: .autoRead,
            status: micCheckStatus,
            detail: Self.microphonePermissionDetail(micPermissionState),
            role: nil, reportLabel: nil
        ))
        if speechApplicable {
            built.append(DiagnosticCheck(
                id: "voice.speech.permission",
                title: String(localized: "diagnostics.voice.speech", defaultValue: "Speech recognition"),
                category: .voice,
                tier: .autoRead,
                status: speechCheckStatus,
                detail: Self.speechPermissionDetail(speechPermissionState),
                role: nil, reportLabel: nil
            ))
        }

        // Parked failed-transcription retry (hidden when none) — a recording is
        // waiting in the single retry slot with a 10-minute TTL; the row names
        // the REMAINING time (not the full TTL) and the platform's recovery
        // surface. A missing audio file (metadata orphan) is called out — the
        // row must not promise a retry that would immediately fail. Presence
        // FORCE-SHOWS the Voice section (`hasPendingRetry` above).
        if let pendingRetry {
            let remaining = Self.pendingRetryRemainingMinutes(createdAt: pendingRetry.createdAt)
            factPendingRetry = pendingRetry.audioFileExists
                ? "parked(code \(pendingRetry.lastErrorCode.map(String.init) ?? "none"), \(remaining)m left)"
                : "orphaned"
            let retryDetail: String
            if !pendingRetry.audioFileExists {
                retryDetail = String(localized: "diagnostics.voice.pendingRetry.orphaned", defaultValue: "A failed transcription left a retry behind, but its recording file is missing — record again.")
            } else {
                #if os(macOS)
                retryDetail = String(localized: "diagnostics.voice.pendingRetry.mac", defaultValue: "A recording from a failed transcription is waiting — retry it from the menu-bar voice window within the next \(remaining) min.")
                #else
                retryDetail = String(localized: "diagnostics.voice.pendingRetry.ios", defaultValue: "A recording from a failed transcription is waiting — retry it from the composer within the next \(remaining) min.")
                #endif
            }
            built.append(DiagnosticCheck(
                id: "voice.pendingRetry",
                title: String(localized: "diagnostics.voice.pendingRetry", defaultValue: "Recording waiting to retry"),
                category: .voice,
                tier: .autoRead,
                status: .warning,
                detail: retryDetail,
                role: nil, reportLabel: nil
            ))
        } else {
            factPendingRetry = "none"
        }

        // Files. The per-gateway file lanes live OUTSIDE `checks` (in `fileLanes`)
        // so a custom gateway NAME can't reach `copyBlock()` — no `files.*` row is
        // seeded here; the view renders one row per `FileLaneState`.

        // Capability (macOS): the Screen-Recording row is relevance-gated.
        if let screenRecordingRow { built.append(screenRecordingRow) }
        // Capability (both): silent-failure rows, hidden when healthy.
        if let shareInboxRow { built.append(shareInboxRow) }
        if let storageRow { built.append(storageRow) }

        // Sync. `sync.icloud` seeds from the fast ubiquity token. Signed-in is the
        // common case. On the once-latched auto-read a `.running` placeholder covers
        // the not-present case until phase 2's account-status refresh resolves it. On
        // a LIVE re-derive (no phase 2) a now-absent token means signed-OUT — seed a
        // warning rather than a stuck spinner, and (via `carryOverResults`) DON'T
        // carry the prior "Signed in" green over it.
        let iCloudStatus: DiagnosticStatus
        let iCloudDetail: String?
        if ubiquityPresent {
            iCloudStatus = .passed
            iCloudDetail = String(localized: "diagnostics.sync.ok", defaultValue: "Signed in to iCloud.")
        } else if carryOver {
            iCloudStatus = .warning
            iCloudDetail = String(localized: "diagnostics.sync.unknown", defaultValue: "iCloud account status unavailable.")
        } else {
            iCloudStatus = .running
            iCloudDetail = nil
        }
        built.append(DiagnosticCheck(
            id: "sync.icloud",
            title: String(localized: "diagnostics.sync.icloud", defaultValue: "iCloud sync"),
            category: .sync,
            tier: .autoRead,
            status: iCloudStatus,
            detail: iCloudDetail,
            role: nil, reportLabel: nil
        ))
        // Status/detail derived by the shared `syncEventsRowState` helper: a single
        // historical FAIL that CloudKit already retried past is normal cold-start
        // noise, so the row only warns when sync looks CURRENTLY stuck (an unbroken
        // failure tail); recovered errors stay green so a healthy setup never cries
        // wolf. The raw error count still travels in `copyBlock()` for support.
        let syncEventsState = Self.syncEventsRowState(syncLines)
        built.append(DiagnosticCheck(
            id: "sync.events",
            title: String(localized: "diagnostics.sync.events", defaultValue: "Recent sync activity"),
            category: .sync,
            tier: .autoRead,
            status: syncEventsState.status,
            detail: syncEventsState.detail,
            role: nil, reportLabel: nil
        ))
        // Apple Watch link (iOS) — informational device-reach row.
        if let watchRow { built.append(watchRow) }

        // On a live re-derive, restore prior probe/test results whose input is
        // unchanged (gateway/network always; sync.icloud only while still signed in;
        // STT/TTS tests only if the provider signature matches) — see `carryOverResults`.
        // The per-gateway file lanes carry their reach/auth result independently in
        // the fan-out above (signature-gated), so they are NOT threaded here.
        if carryOver {
            // A gateway row carries only while its per-ref signature is unchanged —
            // a token/URL/scheme/pin edit resets the stale result like the voice
            // and file-lane signatures do.
            let unchangedGatewayCheckIDs = Set(refs.filter { ref in
                newGatewaySignatures[ref] != nil && newGatewaySignatures[ref] == gatewaySignatures[ref]
            }.map(Self.connectionCheckID))
            carryOverResults(
                into: &built,
                from: checks,
                sttUnchanged: newSTTSignature == activeSTTSignature,
                ttsUnchanged: newTTSSignature == activeTTSSignature,
                ubiquitySignedIn: ubiquityPresent,
                unchangedGatewayCheckIDs: unchangedGatewayCheckIDs
            )
        }

        // The voice-preview DISPLAY state (the enum the view renders under the
        // Preview button) resets with the TTS signature exactly like the check
        // row — else a green "Played a sample" survives a provider switch. An
        // in-flight preview is left alone; `runVoicePreview`'s own signature
        // guard drops its late result instead.
        if carryOver, newTTSSignature != activeTTSSignature,
           voicePreview != .preparing, voicePreview != .playing {
            voicePreview = .idle
        }

        // Prune write-test drill-downs for gateways that no longer have a lane.
        fileTransferResults = fileTransferResults.filter { newFileLaneSignatures[$0.key] != nil }

        // Retire the scoped-recheck stamp in LOCKSTEP with the gateway row it
        // describes: the row carries its probe result forward while its signature
        // is unchanged, so clearing the stamp on every rebuild (foreground, appear,
        // a remote settings post) would leave a green row above a vanished
        // "checked just now". Both drop together when the gateway's config moves or
        // the gateway goes away.
        if let stamped = lastScopedGatewayCheck,
           newGatewaySignatures[stamped.ref] == nil
               || newGatewaySignatures[stamped.ref] != gatewaySignatures[stamped.ref] {
            lastScopedGatewayCheck = nil
        }

        // --- Commit (disable the row-insert animation on a structural change) ---
        fileLanes = newFileLanes
        gatewayDisplayOrder = newGatewayDisplayOrder
        fileLaneSignatures = newFileLaneSignatures
        gatewaySignatures = newGatewaySignatures
        activeSTTSignature = newSTTSignature
        activeTTSSignature = newTTSSignature
        microphonePermissionState = micPermissionState
        speechRecognitionPermissionState = speechPermissionState
        notificationPermissionState = notifPermissionState
        notificationAlertsAreSuppressed = notifAlertsSuppressed
        activeVoiceSetup = voiceConfigured
            ? VoiceSetupState(sttName: sttName, sttStatus: sttSetupStatus, ttsName: ttsName, ttsStatus: ttsSetupStatus)
            : nil
        showsVoiceSection = voiceConfigured
        showsSyncSection = newShowsSync
        // Category-driven: Capabilities shows whenever any `.capability` row exists
        // (Notifications always does on iOS/macOS; the macOS Screen-Recording row
        // stays individually relevance-gated). Computed from the built list so it
        // can't drift from what the section will actually render.
        showsCapabilitySection = built.contains { $0.category == .capability }
        if carryOver, built.map(\.id) != checks.map(\.id) {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) { checks = built }
        } else {
            checks = built
        }
    }

    /// Seed the checklist from LOCAL reads exactly ONCE (the `autoReadStarted`
    /// latch neutralizes the SwiftUI `.task`-on-Group multi-fire), then run the
    /// two SLOW local probes (network path + CloudKit account status) IN PLACE —
    /// PHASE 2 — so the first paint is already the final layout (the flicker fix).
    /// Zero calls to the user's gateway / STT server / file server, no billable
    /// call, no TCC prompt.
    func runAutoReads() async {
        guard !autoReadStarted else { return }
        autoReadStarted = true

        await performLocalReadsAndRebuild(carryOver: false)
        didAutoRead = true

        // --- PHASE 2: slow local connectivity probes, applied IN PLACE ----------
        // Latched so a foreground `reprobeConnectivity` can't race THIS first
        // probe (Codex catch 4). Reset unconditionally.
        connectivityProbeInFlight = true
        await performConnectivityProbe()
        connectivityProbeInFlight = false
    }

    /// The two SLOW local connectivity probes — `NWPathMonitor`'s first delivery +
    /// the CloudKit account-status refresh — applied IN PLACE (mutate only their
    /// own rows: a spinner → check/warning, so nothing reflows and the Copy button
    /// never moves). Still local-only (no user-infra egress, no prompt) — the tier
    /// guarantee is unchanged; only the timing moved. Re-run on explicit Refresh /
    /// Test connections + foreground so a recovered network / fixed iCloud sign-in
    /// is re-detected without a relaunch.
    private func performConnectivityProbe() async {
        let net = await Self.probeNetworkPath()
        factNetworkReachable = net.reachable
        factNetworkInterface = net.interface
        factNetworkExpensive = net.expensive
        factNetworkConstrained = net.constrained
        showsNetworkConnectionIssue = !net.reachable || net.constrained
        var networkDetail = net.reachable
            ? String(localized: "diagnostics.connection.network.ok", defaultValue: "Reachable over \(net.interface).")
            : String(localized: "diagnostics.connection.network.down", defaultValue: "No network connection detected.")
        // Low Data Mode note — detail only, status stays `.passed` (a deliberate
        // user setting must not read as a fault; it merely limits background
        // transfers/large attachments). `isExpensive` stays copy-block-only.
        if net.reachable, net.constrained {
            networkDetail += " " + String(localized: "diagnostics.connection.network.constrained", defaultValue: "Low Data Mode is on — background transfers and large attachments may be limited.")
        }
        setStatus(
            "connection.network",
            net.reachable ? .passed : .failed(code: AppError.noInternetConnection.errorCode),
            detail: networkDetail
        )

        await CloudSyncMonitor.shared.refresh()
        let iCloudUnavailable = CloudSyncMonitor.shared.iCloudUnavailable
        let iCloudReason = CloudSyncMonitor.shared.unavailableReason
        if iCloudUnavailable { showsSyncSection = true }   // surface even if signed out
        let syncStatus: DiagnosticStatus
        let syncDetail: String
        if iCloudUnavailable, let reason = iCloudReason {
            syncStatus = .warning
            syncDetail = String(localized: reason.settingsMessage)
        } else if factUbiquityPresent {
            syncStatus = .passed
            syncDetail = String(localized: "diagnostics.sync.ok", defaultValue: "Signed in to iCloud.")
        } else {
            syncStatus = .warning
            syncDetail = String(localized: "diagnostics.sync.unknown", defaultValue: "iCloud account status unavailable.")
        }
        setStatus("sync.icloud", syncStatus, detail: syncDetail)
        factICloudStatus = {
            if iCloudUnavailable, let reason = iCloudReason {
                return "unavailable(\(Self.iCloudReasonName(reason)))"
            }
            return factUbiquityPresent ? "available" : "unknown"
        }()
    }

    /// Re-run the two slow connectivity probes on explicit Refresh / foreground.
    /// Latched (`connectivityProbeInFlight`) so a foreground trigger firing DURING
    /// the initial `runAutoReads` phase-2 no-ops rather than racing a second probe;
    /// the in-flight probe lands the fresh network/iCloud status either way.
    private func reprobeConnectivity() async {
        guard didAutoRead, !connectivityProbeInFlight else { return }
        connectivityProbeInFlight = true
        defer { connectivityProbeInFlight = false }
        await performConnectivityProbe()
    }

    /// Live re-derive (config + permissions) AND a connectivity re-probe — the
    /// foreground / Refresh path. `.settingsDidChangeRemotely` stays on the plain
    /// `refreshConfig()` (config-only, cheap, no connectivity probe).
    func refreshConfigAndConnectivity() async {
        await refreshConfig()
        await reprobeConnectivity()
    }

    /// Live re-derive: re-read the LOCAL config + permission snapshot and rebuild
    /// the checklist (carrying prior probe/test outcomes whose input is unchanged),
    /// so a provider the user just switched — or a permission just flipped in system
    /// Settings — reflects WITHOUT relaunching. No network re-probe, no billing, no
    /// prompt. Wired to the Diagnostics screen's appear / foreground / Refresh button
    /// and to `.settingsDidChangeRemotely`. An unchanged config rebuilds to an
    /// identical checklist (no visible change). Before the first `runAutoReads()`
    /// has seeded the list it defers to it (covers the first-appear ordering).
    func refreshConfig() async {
        guard didAutoRead else {
            await runAutoReads()
            return
        }
        await performLocalReadsAndRebuild(carryOver: true)
    }

    /// Restore prior status/detail onto freshly-rebuilt rows whose result is still
    /// valid. A row carries its prior outcome IFF its input is unchanged:
    /// - `gateway.*` / `connection.network` → their value comes from a probe a local
    ///   re-read can't reproduce, so carry whenever the row id survives (a removed
    ///   gateway's id just won't exist);
    /// - `sync.icloud` → carry the phase-2-refined status only while STILL signed in;
    ///   a now-absent ubiquity token means signed-OUT, so keep the fresh warning seed
    ///   rather than a stale green "Signed in to iCloud";
    /// - `voice.stt.auth` / `voice.stt.test` → carry only if the STT signature is
    ///   unchanged, else the fresh `.notRun` stands (a result bound to the OLD
    ///   provider/key must not linger — the "Heard: …" from OpenAI after switching to
    ///   Apple, or a `.failed` key that the user has since fixed);
    /// - `voice.tts.preview` → carry only if the TTS signature is unchanged.
    /// Permission rows (mic/speech/notifications) + `sync.events` are NEVER carried —
    /// the fresh snapshot already holds their current value. Per-gateway file lanes
    /// live outside `checks` and carry their reach/auth result in the fan-out
    /// (signature-gated), so they are not handled here.
    private func carryOverResults(
        into built: inout [DiagnosticCheck],
        from prior: [DiagnosticCheck],
        sttUnchanged: Bool,
        ttsUnchanged: Bool,
        ubiquitySignedIn: Bool,
        unchangedGatewayCheckIDs: Set<String>
    ) {
        let priorByID = Dictionary(prior.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in built.indices {
            guard let old = priorByID[built[i].id] else { continue }
            let id = built[i].id
            let carry: Bool
            if id.hasPrefix("gateway.") {
                carry = unchangedGatewayCheckIDs.contains(id)
            } else if id == "connection.network" {
                carry = true
            } else if id == "sync.icloud" {
                carry = ubiquitySignedIn
            } else if id == "voice.stt.auth" || id == "voice.stt.test" {
                carry = sttUnchanged
            } else if id == "voice.tts.preview" {
                carry = ttsUnchanged
            } else {
                carry = false
            }
            if carry {
                built[i].status = old.status
                built[i].detail = old.detail
            }
        }
    }

    // MARK: - "Test everything" (top button — sweep + every real test, SILENT)

    /// The single top-button action: run the cheap sweep, then every real
    /// pass/fail test — the mutating file write test on each configured lane and
    /// the paid STT transcription — so a self-hoster proves their whole setup in
    /// one tap. Deliberately does NOT call `runVoicePreview()`: voice PLAYBACK is a
    /// physical-world side effect (the device speaks aloud) and stays its own tap.
    ///
    /// No preflight gate: each callee is SELF-STAGING — the write test re-checks
    /// reachability→auth→write→read from scratch (fails fast on a down server, no
    /// wasted mutation) and the transcription makes the real call whose own error
    /// IS the diagnostic. A "skip unless the sweep's reachAuth passed" gate would be
    /// redundant AND wrong (it would skip a keyless custom STT, and a `.warning`
    /// file lane — the exact ambiguous lane the write test exists to resolve).
    func runAllTests() async {
        // Block if ANY test (full or a manual per-row action) is already running,
        // so the sweep can't race an in-flight row test on the same lane's state.
        guard !isBusy else { return }
        isRunningAllTests = true
        defer { isRunningAllTests = false }

        // Barrier: the sweep settles the gateway rows + `voice.stt.auth` + each
        // file lane's `reachAuth`. Await it FULLY before the fan-out so a write
        // test's `reachAuth` overwrite can't race the sweep's file-reach probe.
        await runConnectionChecks()

        // Fan out the real tests concurrently — each touches DISJOINT state (its
        // own lane's `reachAuth`; transcription's `voice.stt.test` row; the watch
        // leg's `watchHealth`) so there is no cross-write, and each lights its own
        // per-row spinner as it runs. The Watch health leg lives HERE, not in the
        // sweep barrier: it needs no ordering against the file probes, and inside
        // the barrier a reachable-but-slow wrist would hold every write test +
        // the transcription hostage for its full 5 s budget.
        let writeRefs = Self.lanesToWrite(fileLanes)
        await withTaskGroup(of: Void.self) { group in
            for ref in writeRefs {
                group.addTask { await self.runFileTransferTest(for: ref) }
            }
            group.addTask { await self.runTranscriptionTest() }
            #if os(iOS)
            group.addTask { await self.sweepWatchHealthLeg() }
            #endif
        }

        // Re-stamp AFTER the fan-out (the sweep stamped it at its own, earlier end)
        // so "Last checked" reflects when the whole run finished.
        lastChecked = Date()
    }

    // MARK: - Tier 2: explicit connection sweep (network / auth probes)

    /// The ONLY place the gateway reachability probe + the cloud-STT auth probe
    /// run. Both can hit the user's server (and raise the Local Network prompt or
    /// a POST-based probe) — acceptable because the user tapped. Apple / in-process
    /// STT is SKIPPED for the auth probe (its `headProbe` path would prompt TCC).
    func runConnectionChecks() async {
        // Non-re-entrant: a second tap while a probe is in flight is a no-op.
        // Guard + set the flag synchronously (before any `await`) so a concurrent
        // second entry early-returns; reset UNCONDITIONALLY on exit.
        guard !isTestingConnections else { return }
        isTestingConnections = true
        defer { isTestingConnections = false }

        // First tap seeds the checklist; every later tap re-reads the LOCAL config
        // + permissions first, so "Refresh" updates the notification/permission
        // rows and the "Active setup" block, not just the network probes.
        if !didAutoRead { await runAutoReads() } else { await refreshConfig() }

        let manager = SettingsManager.shared
        let refs = await manager.configuredRemoteAgentRefs()

        // Capture the STT signature the auth probe is about to run against, so a
        // provider changed mid-probe (a `.settingsDidChangeRemotely` re-derive
        // during the `await` below) can't false-green the NEW provider's key row.
        let sttSigAtProbe = activeSTTSignature
        // Same guard for the gateway rows: each outcome applies only if that
        // gateway's signature hasn't moved since dispatch (keyed by check id).
        let gatewaySigsAtProbe = Dictionary(uniqueKeysWithValues: gatewaySignatures.map {
            (Self.connectionCheckID(for: $0.key), $0.value)
        })

        // Gather probe inputs with LOCAL reads before dispatching the concurrent
        // probes (the snapshot url/token/fingerprint flow ONLY onto the probe
        // request — never into a check detail or the copy block). `isLocalHost` is
        // a locality BOOL (never the host string) that gates the Local-Network hint.
        var gatewayInputs: [GatewayProbeInput] = []
        for ref in refs {
            guard let input = await Self.makeGatewayProbeInput(for: ref, manager: manager) else { continue }
            gatewayInputs.append(input)
        }

        // Per-gateway file-server reach+auth probe inputs — one per CONFIGURED
        // file-capable lane. NON-mutating (a single 404-probe GET); updates ONLY
        // the lane's `reachAuth`, NEVER `fileTransferAvailable`.
        var fileReachInputs: [FileReachProbeInput] = []
        for lane in fileLanes where lane.configured {
            guard let snap = await manager.fileTransferSnapshot(for: lane.ref) else { continue }
            let transportHint = await manager.getRemoteAgentTransportHint(for: lane.ref)
            let hostClass = HostReachabilityClass.classify(snap.baseURL.host, transportHint: transportHint)
            fileReachInputs.append(FileReachProbeInput(
                ref: lane.ref,
                snapshot: snap,
                signature: fileLaneSignatures[lane.ref] ?? "",
                isLocalHost: hostClass.suggestsLocalNetworkPermission
            ))
        }

        // Cloud-STT auth probe input (skip in-process Apple entirely). The
        // resolved BYO-endpoint config travels WITH the probe so a custom
        // endpoint is probed at ITS url/auth/pin — never the legacy singleton
        // slots, never a hardcoded bearer, never an unpinned session.
        let sttSnapshot = await manager.activeSTTSnapshot()
        var sttInput: STTProbeInput?
        if sttSnapshot.provider.transport != .inProcess {
            sttInput = STTProbeInput(
                checkID: "voice.stt.auth",
                apiKey: sttSnapshot.apiKey ?? "",
                provider: sttSnapshot.provider,
                customConfig: sttSnapshot.customConfig
            )
        }

        // Mark the rows about to be probed as running.
        for input in gatewayInputs { setStatus(input.checkID, .running) }
        if let sttInput { setStatus(sttInput.checkID, .running) }
        for input in fileReachInputs { setFileLaneReachAuth(ref: input.ref, .running, detail: nil) }

        // Run every probe concurrently, off the main actor; collect Sendable results.
        let results: [ConnectionProbeResult] = await withTaskGroup(of: ConnectionProbeResult.self) { group in
            for input in gatewayInputs {
                group.addTask { .gatewayOrSTT(await Self.probeGateway(input), isLocalHost: input.isLocalHost) }
            }
            if let sttInput {
                group.addTask { .gatewayOrSTT(await Self.probeSTT(sttInput), isLocalHost: false) }
            }
            for input in fileReachInputs {
                group.addTask {
                    let outcome = await FileServerClient.probeReachability(snapshot: input.snapshot)
                    return .fileLane(ref: input.ref, outcome: outcome, signature: input.signature, isLocalHost: input.isLocalHost)
                }
            }
            var acc: [ConnectionProbeResult] = []
            for await r in group { acc.append(r) }
            return acc
        }

        // Local-Network hint gate: only meaningful when the internet itself is up
        // (a local host failing while online points at the LAN grant, not the WAN).
        let networkPassed = checks.first(where: { $0.id == "connection.network" })?.status == .passed

        for result in results {
            switch result {
            case .gatewayOrSTT(let outcome, let isLocalHost):
                // Drop a stale STT-auth outcome if the active provider changed while
                // the probe was in flight — the fresh `.notRun` row must not be
                // overwritten with the OLD provider's result. Gateway outcomes are
                // provider-agnostic; a removed gateway's `setStatus` simply no-ops.
                if outcome.checkID == "voice.stt.auth", activeSTTSignature != sttSigAtProbe { continue }
                // Drop a stale gateway outcome the same way: the config that was
                // probed is no longer the config the row represents.
                if outcome.checkID.hasPrefix("gateway.") {
                    let currentSigs = Dictionary(uniqueKeysWithValues: gatewaySignatures.map {
                        (Self.connectionCheckID(for: $0.key), $0.value)
                    })
                    if currentSigs[outcome.checkID] != gatewaySigsAtProbe[outcome.checkID] { continue }
                }
                var detail = outcome.detail
                if case .failed = outcome.status, isLocalHost, networkPassed {
                    detail = Self.appendLocalNetworkHint(detail)
                }
                setStatus(outcome.checkID, outcome.status, detail: detail)
            case .fileLane(let ref, let outcome, let signature, let isLocalHost):
                // Drop a stale reach outcome if the lane's config changed mid-probe.
                guard fileLaneSignatures[ref] == signature else { continue }
                var (status, detail) = Self.fileReachStatus(outcome)
                if outcome == .unreachable, isLocalHost, networkPassed {
                    detail = Self.appendLocalNetworkHint(detail)
                }
                setFileLaneReachAuth(ref: ref, status, detail: detail)
            }
        }
        lastChecked = Date()
        connectionChecksHaveRun = true
        // A full sweep re-probed every gateway, so the single-gateway stamp is
        // now redundant noise beside a fresher whole-run stamp.
        lastScopedGatewayCheck = nil

        // Re-probe network + iCloud on the explicit tap so a recovered network /
        // fixed iCloud sign-in reflects without a relaunch. Coalesces via the
        // `connectivityProbeInFlight` latch if the initial phase-2 is still landing.
        await reprobeConnectivity()
    }

    /// Build ONE gateway's probe input from live local reads. The SINGLE
    /// construction site, shared by the sweep and by `recheckGateway(for:)` —
    /// `Why:` the two paths must not drift on `probePath` / `bodyShape` (the pair
    /// that decides which envelope a 2xx body is validated against) or on the
    /// locality bool that gates the Local-Network hint. Nil when the ref has no
    /// snapshot (removed, or not send-able on this device).
    ///
    /// The url/token/fingerprint flow ONLY onto the probe request — never into a
    /// check detail or the copy block.
    private static func makeGatewayProbeInput(
        for ref: RemoteAgentRef,
        manager: SettingsManager
    ) async -> GatewayProbeInput? {
        guard let snapshot = await manager.remoteAgentSnapshot(for: ref) else { return nil }
        let carrierBackend: RemoteAgentBackend = {
            if case .builtin(let backend) = ref { return backend }
            return .openclaw
        }()
        let descriptor = RemoteAgentBackendRegistry.lookup(id: carrierBackend)
        let transportHint = await manager.getRemoteAgentTransportHint(for: ref)
        let hostClass = HostReachabilityClass.classify(snapshot.url.host, transportHint: transportHint)
        return GatewayProbeInput(
            checkID: Self.connectionCheckID(for: ref),
            backend: carrierBackend,
            url: snapshot.url,
            token: snapshot.token ?? "",
            authScheme: snapshot.authScheme,
            fingerprint: snapshot.certFingerprintHex,
            probePath: descriptor.verdictProbePath,
            bodyShape: descriptor.verdictBodyShape,
            isLocalHost: hostClass.suggestsLocalNetworkPermission
        )
    }

    /// Re-probe ONE gateway. The action a Troubleshoot-landed user actually needs:
    /// `runAllTests()` is the only other route forward, and it writes a probe file
    /// into EVERY configured file lane and runs a BILLABLE transcription —
    /// diagnosing one broken gateway must do neither.
    ///
    /// Scoped by construction: no file-lane write, no transcription, no
    /// connectivity re-probe, and it does NOT restamp `lastChecked` — that stamp
    /// means "the whole sweep ran", so restamping it here would claim freshness
    /// for rows nobody re-probed. The scoped result gets its own transient stamp
    /// (`lastScopedGatewayCheck`) instead.
    func recheckGateway(for ref: RemoteAgentRef) async {
        // Same reason `runFileTransferTest` refuses during the sweep: the sweep is
        // writing this row too, so last-writer-wins could show the stale result
        // over the fresh one. `isTestingConnections` is true ONLY inside the sweep.
        guard !isTestingConnections else { return }
        // Non-re-entrant PER REF — a second tap on the same gateway while its probe
        // is in flight is a no-op; a different gateway can probe concurrently.
        guard !gatewayRecheckRunning.contains(ref) else { return }
        gatewayRecheckRunning.insert(ref)
        defer { gatewayRecheckRunning.remove(ref) }

        let manager = SettingsManager.shared
        guard let input = await Self.makeGatewayProbeInput(for: ref, manager: manager),
              let dispatchSignature = await Self.liveGatewaySignature(for: ref, manager: manager)
        else { return }

        setStatus(input.checkID, .running)
        let outcome = await Self.probeGateway(input)

        // Drop the outcome if the gateway's config moved while the probe ran.
        // Compared against the LIVE persisted config rather than the runner's
        // rebuild state: the runner's `gatewaySignatures` only moves when a
        // rebuild happens, so an edit in another window (or an inbound KVS
        // update) could leave it stale and let the OLD credentials' verdict green
        // the NEW config. A false green is not harmless just because this path
        // persists nothing — it is the whole answer the user acts on.
        guard let liveSignature = await Self.liveGatewaySignature(for: ref, manager: manager),
              liveSignature == dispatchSignature
        else {
            setStatus(input.checkID, .notRun, detail: nil)
            return
        }

        var detail = outcome.detail
        let networkPassed = checks.first(where: { $0.id == "connection.network" })?.status == .passed
        if case .failed = outcome.status, input.isLocalHost, networkPassed {
            detail = Self.appendLocalNetworkHint(detail)
        }
        setStatus(outcome.checkID, outcome.status, detail: detail)
        lastScopedGatewayCheck = ScopedGatewayCheck(ref: ref, date: Date())
    }

    /// The live per-ref gateway signature, read fresh from persisted config.
    /// `Hasher` is fine here (dispatch and apply happen in ONE process, one run);
    /// it would NOT be fine for anything durable across launches.
    private static func liveGatewaySignature(
        for ref: RemoteAgentRef,
        manager: SettingsManager
    ) async -> String? {
        guard let snap = await manager.remoteAgentSnapshot(for: ref) else { return nil }
        return Self.gatewaySignature(
            url: snap.url,
            token: snap.token,
            authScheme: snap.authScheme,
            fingerprint: snap.certFingerprintHex
        )
    }

    /// Update one file lane's reach/auth field (+ detail). Setting `detail: nil`
    /// clears a prior failure detail while the lane re-probes.
    private func setFileLaneReachAuth(ref: RemoteAgentRef, _ status: DiagnosticStatus, detail: String?) {
        guard let i = fileLanes.firstIndex(where: { $0.ref == ref }) else { return }
        fileLanes[i].reachAuth = status
        fileLanes[i].detail = detail
    }

    // MARK: - Watch health query (free, non-billable — fan-out leg + per-row Check)

    /// One watch health round trip → outcome. The wait is an `await` on the
    /// transport's continuation, so the main actor is never blocked (under the
    /// target's default MainActor isolation this static — like the transport
    /// protocol — still RUNS on the main actor; only the wire decode inside the
    /// WCSession replyHandler executes on the framework queue). A version-less
    /// reply decodes to `.unsupported` — never an all-unknown "report". NEVER
    /// mutates the `sync.watch` row's status: the query claim stays narrow
    /// ("the Watch app responded + its local state"), not "the watch works
    /// end-to-end".
    private static func probeWatchHealth(transport: any WatchHealthTransport) async -> WatchHealthQueryOutcome {
        switch await transport.query(timeout: watchHealthQueryTimeout) {
        case .noResponse(let reason):
            return .noResponse(reason)
        case .reply(let wire):
            guard wire.version != nil else { return .unsupported }
            let phoneTs = UserDefaults(suiteName: Constants.appGroupID)?
                .double(forKey: Constants.watchBroadcastLastAgentEnvelopeTsKey) ?? 0
            let agentTs = wire.agentEnvelopeTs ?? 0
            let freshness: WatchSettingsFreshness = wire.agentEnvelopeTs == nil
                ? .unknown
                : WatchHealthState.settingsFreshness(watchAgentTs: agentTs, phoneAgentTs: phoneTs)
            return .reply(WatchHealthState(
                appVersion: wire.appVersion,
                appBuild: wire.appBuild,
                osVersion: wire.osVersion,
                agentEnvelopeTs: agentTs,
                settingsFreshness: freshness,
                relayQueueDepth: wire.relayQueueDepth,
                micPermission: wire.micPermission,
                notificationPermission: wire.notificationPermission,
                receivedAt: Date()
            ))
        }
    }

    /// Apply a query outcome: the last outcome always lands; the decoded facts
    /// land ONLY on a real reply — a failed refresh PRESERVES the previous
    /// snapshot, so the view renders "couldn't refresh" over the last-known
    /// facts instead of erasing evidence.
    private func applyWatchHealthOutcome(_ outcome: WatchHealthQueryOutcome) {
        watchHealthLastOutcome = outcome
        if case .reply(let state) = outcome {
            watchHealth = state
        }
    }

    /// The "Test everything" fan-out's Watch leg — eligibility re-checked here
    /// (paired + installed + enabled) so the run only queries a wrist that has a
    /// live row; fail-soft when asleep (the outcome records no-response, the
    /// row's status never changes).
    #if os(iOS)
    private func sweepWatchHealthLeg() async {
        guard WCSession.isSupported(),
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled,
              PhoneSessionManager.shared.isWatchEnabled else { return }
        let outcome = await Self.probeWatchHealth(transport: watchHealthTransport)
        applyWatchHealthOutcome(outcome)
    }
    #endif

    /// The per-row "Check" action — re-runs the Watch health leg alone (free,
    /// non-billable, no TCC prompt; needs the wrist awake). Non-re-entrant, and
    /// blocked during a full run (whose fan-out queries the same wrist — two
    /// concurrent outcomes would last-writer-win pointlessly).
    func runWatchHealthCheck() async {
        guard !isCheckingWatch, !isRunningAllTests else { return }
        isCheckingWatch = true
        defer { isCheckingWatch = false }
        let transport = watchHealthTransport
        let outcome = await Self.probeWatchHealth(transport: transport)
        applyWatchHealthOutcome(outcome)
    }

    // MARK: - Explicit permission actions

    func permissionState(for permission: DiagnosticPermission) -> DiagnosticPermissionState {
        switch permission {
        case .microphone: return microphonePermissionState
        case .speechRecognition: return speechRecognitionPermissionState
        case .notifications: return notificationPermissionState
        case .screenRecording: return screenRecordingPermissionState
        }
    }

    func permissionAction(for permission: DiagnosticPermission) -> DiagnosticPermissionAction? {
        if permission == .notifications {
            return Self.notificationDiagnosticAction(
                permissionState: notificationPermissionState,
                alertsSuppressed: notificationAlertsAreSuppressed
            )
        }
        return permissionState(for: permission).action
    }

    /// Present an OS permission prompt ONLY from the permission row's explicit
    /// Allow button. A determined denial is repaired through System Settings in
    /// the view; `VoicePermissions` itself also refuses to re-prompt determined
    /// Speech Recognition states. Rebuild the local checklist immediately after
    /// the prompt resolves so the row/button changes in place.
    func requestPermission(_ permission: DiagnosticPermission) async {
        guard !isBusy, permissionAction(for: permission) == .allow else { return }
        if permission == .speechRecognition,
           !checks.contains(where: { $0.id == "voice.speech.permission" }) {
            return
        }

        permissionRequestInFlight = permission
        defer { permissionRequestInFlight = nil }

        switch permission {
        case .microphone:
            _ = await VoicePermissions.requestMicrophone()
        case .speechRecognition:
            #if !os(watchOS)
            _ = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
            #endif
        case .notifications:
            await NotificationPermissions.ensureRequested()
        case .screenRecording:
            // Never re-prompt from Diagnostics: TCC consent is per code
            // signature and resettable, so whether the system dialog would
            // appear is unknowable — the capture flow owns the ask
            // (rationale-first). The visible repair action here is therefore
            // always Open Settings, never Allow.
            return
        }
        await refreshConfig()
    }

    // MARK: - Tier 3: paid / mutating (explicit button only)

    /// Real transcription of the bundled probe clip through the active STT
    /// provider (billable for cloud providers). Uses the provider-aware
    /// `STTClient.transcribe` — NOT `STTConnectionTestSuite` (which hardcodes
    /// OpenAI multipart and false-fails Qwen/Gemini/ElevenLabs).
    func runTranscriptionTest() async {
        // Same sub-render double-tap window guard as `runFileTransferTest`: a tap
        // that got in before the row button re-rendered disabled must not start a
        // second PAID call during the full run's sweep phase. (`isTestingConnections`
        // is true only inside the sweep — the run's own post-sweep fan-out calls
        // this with the flag already cleared, so it is NOT blocked.)
        guard !isTestingConnections else { return }
        // Non-re-entrant: guard on its own in-flight flag; reset unconditionally.
        guard !isTranscribing else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        // Drop the outcome if the active STT changed mid-test — the rebuilt
        // fresh row must not be overwritten with the OLD provider's result
        // (the sweep's auth probe has the same guard).
        let sigAtStart = activeSTTSignature

        setStatus("voice.stt.test", .running)

        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        guard let clipURL = Self.copyBundledProbeClip() else {
            let code = AppError.invalidResponse.errorCode
            setStatus("voice.stt.test", .failed(code: code), detail: DiagnosticsExplainer.explain(code: code).fix)
            return
        }

        do {
            // `transcribe` deletes `audioFileURL` on every exit path — we pass a
            // throwaway copy, never the read-only bundle resource.
            let response = try await STTClient.shared.transcribe(
                audioFileURL: clipURL,
                apiKey: snapshot.apiKey ?? "",
                language: nil,
                provider: snapshot.provider,
                customModel: snapshot.customModel,
                customConfig: snapshot.customConfig
            )
            guard activeSTTSignature == sigAtStart else { return }
            let heard = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            setStatus(
                "voice.stt.test",
                .passed,
                detail: String(localized: "diagnostics.voice.stt.heard", defaultValue: "Heard: \(heard)")
            )
        } catch {
            guard activeSTTSignature == sigAtStart else { return }
            let code = (error as? AppError)?.errorCode ?? AppError.unknown(error).errorCode
            setStatus("voice.stt.test", .failed(code: code), detail: DiagnosticsExplainer.explain(code: code).fix)
        }
    }

    /// Play a short spoken sample through the active TTS provider (billable for
    /// cloud). Preflights the missing-key case EXACTLY like `ReplyVoice.routePreview`
    /// so a keyed cloud provider with no key fails LOUD instead of silently
    /// succeeding via the Apple fallback.
    func runVoicePreview() async {
        // The full run never calls this (playback is a physical side effect), so
        // a tap that raced in before the button re-rendered disabled must not
        // speak-and-bill DURING a run — the runner-level guard the file test and
        // transcription have.
        guard !isRunningAllTests else { return }
        // Non-re-entrant: a tap while a sample is preparing/playing is a no-op.
        guard voicePreview != .preparing, voicePreview != .playing else { return }
        voicePreview = .preparing
        // Drop the outcome if the active TTS changed mid-preview — the display
        // enum and the check row must not carry the OLD provider's result.
        let sigAtStart = activeTTSSignature
        setStatus("voice.tts.preview", .running)

        let snapshot = await SettingsManager.shared.activeTTSSnapshot()

        // Preflight on the TYPED key state (the snapshot resolved key + state from
        // ONE Keychain read). `.present` / `.notRequired` proceed — `.notRequired`
        // already covers the Apple sentinel AND a keyless (`auth == .none`) BYO
        // endpoint. A `.missing` or `.unreadable` key on a keyed cloud provider
        // fails LOUD rather than silently substituting Apple and false-passing;
        // the two states get DISTINCT copy (missing = enter it; unreadable = the
        // Keychain is locked). Both record the forensic preflight event.
        switch snapshot.keyState {
        case .present, .notRequired:
            break
        case .missing, .unreadable:
            let message = snapshot.keyState == .missing
                ? String(
                    localized: "diagnostics.voice.preview.missingKey",
                    defaultValue: "Add your voice provider's key in Settings to preview this voice."
                )
                : String(
                    localized: "diagnostics.voice.preview.keyUnreadable",
                    defaultValue: "The voice key couldn't be read from the Keychain — unlock the device and try again."
                )
            TTSOutcomeLog.shared.record(
                surface: .diagnostics,
                stage: .key,
                outcome: .failedLoud,
                errorCode: nil,
                keyState: snapshot.keyState,
                configSignature: TTSOutcomeLog.configSignature(for: snapshot)
            )
            voicePreview = .failed(message)
            setStatus("voice.tts.preview", .failed(code: AppError.ttsUnauthorized.errorCode), detail: message)
            return
        }

        #if os(macOS)
        // User-initiated speech — silence any other macOS speaker before it starts
        // (mirrors `SettingsViewModel.previewTTS`). `previewSample` itself
        // supersedes any in-flight turn on the shared instance.
        SpeechExclusivity.shared.claim(ReplyVoice.shared)
        #endif

        voicePreview = .playing
        let outcome: Result<Void, AppError> = await withCheckedContinuation { continuation in
            ReplyVoice.shared.previewSample(
                providerID: snapshot.providerID,
                voice: snapshot.voice,
                customModel: snapshot.customModel,
                apiKey: snapshot.apiKey,
                customConfig: snapshot.customConfig,
                recordSurface: .diagnostics
            ) { result in
                continuation.resume(returning: result)
            }
        }

        // Set the terminal preview state UNCONDITIONALLY — never leave it stuck
        // at `.playing`. A mid-preview provider change resolves to `.idle`
        // instead of stamping the OLD provider's result on the fresh row.
        guard activeTTSSignature == sigAtStart else {
            voicePreview = .idle
            return
        }
        switch outcome {
        case .success:
            voicePreview = .done
            setStatus("voice.tts.preview", .passed)
        case .failure(let error):
            let fix = DiagnosticsExplainer.explain(code: error.errorCode).fix
            voicePreview = .failed(fix)
            setStatus("voice.tts.preview", .failed(code: error.errorCode), detail: fix)
        }
    }

    /// Run the staged file-server test (reachability → auth → write → read) for a
    /// SPECIFIC gateway and persist availability + folder-capability EXACTLY like
    /// `SettingsViewModel.runFileTransferTest(for:)`, so a failed Diagnostics test
    /// downgrades `fileTransferAvailable` (no stale-green composer affordance).
    /// The ONLY thing that sets `writeVerified` — the reach/auth probe never does.
    func runFileTransferTest(for ref: RemoteAgentRef) async {
        // Don't let a manual write test start DURING the full run's sweep phase (a
        // sub-render double-tap window before the row button re-renders disabled):
        // the sweep is writing this lane's `reachAuth` too, so last-writer-wins
        // could show the reach result over the write-verified green. `isTestingConnections`
        // is true ONLY inside `runAllTests`'s sweep — the run's OWN post-sweep
        // fan-out calls this with the flag already cleared, so it is NOT blocked;
        // manual per-lane use (no sweep running) is likewise unaffected.
        guard !isTestingConnections else { return }
        // Non-re-entrant PER REF: a second tap on the same lane while its test is
        // in flight is a no-op; a different lane can test concurrently.
        guard !fileTransferTestRunning.contains(ref) else { return }
        fileTransferTestRunning.insert(ref)
        defer { fileTransferTestRunning.remove(ref) }

        setFileLaneWriteRunning(ref: ref)

        guard let snapshot = await SettingsManager.shared.fileTransferSnapshot(for: ref) else {
            let result = FileTransferTestResult(
                reachedStage: .reachability,
                success: false,
                failure: .fileTransferNotConfigured
            )
            fileTransferResults[ref] = result
            await SettingsManager.shared.setFileTransferAvailable(false, for: ref)
            let code = AppError.fileTransferNotConfigured.errorCode
            updateFileLaneAfterWrite(ref: ref, success: false, code: code)
            return
        }

        let signatureAtDispatch = Self.fileLaneSignature(snapshot)
        let result = await FileServerClient.runConnectionTest(snapshot: snapshot)

        // Drop the outcome if the lane's config changed while the test ran —
        // otherwise the OLD server's verdict gets persisted onto the NEW config
        // (incl. `fileTransferAvailable`, which gates real transfers app-wide).
        // Compared against the LIVE persisted config, not the runner's rebuild
        // state, because persistence is what's at stake.
        let liveSnapshot = await SettingsManager.shared.fileTransferSnapshot(for: ref)
        guard Self.fileLaneSignature(liveSnapshot) == signatureAtDispatch else { return }

        fileTransferResults[ref] = result
        // Same persistence contract as the Settings-side test: set availability
        // ONLY on a full pass; clear on any failure; persist folder-capability
        // only on a pass (the nested probe runs only after read passes).
        if result.success {
            // Folder-capability BEFORE availability true: the file-server keys
            // mirror to iCloud KVS, so a peer must never observe `available=true`
            // paired with a stale default-true folderCapable when the definitive
            // verdict was flat-only.
            await SettingsManager.shared.setFileServerFolderCapable(result.folderCapable, for: ref)
            await SettingsManager.shared.setFileTransferAvailable(true, for: ref)
            // This device proved the lane locally — arm the silent, upgrade-only
            // folder re-probe (synced-only peers stay disarmed). A fresh staged
            // verdict supersedes any recorded silent-probe outcome, so the
            // markers drop with it (re-arms the upgrade-only probe).
            await SettingsManager.shared.setFileServerTestedLocally(true, for: ref)
            await SettingsManager.shared.clearFolderProbeMarkers(for: ref)
            updateFileLaneAfterWrite(ref: ref, success: true, code: nil)
        } else {
            await SettingsManager.shared.setFileTransferAvailable(false, for: ref)
            let code = result.failure?.errorCode ?? AppError.fileTransferUploadFailed.errorCode
            updateFileLaneAfterWrite(ref: ref, success: false, code: code)
        }
    }

    /// Mark a lane's write test as running (spinner on that row) — clears any prior
    /// detail so a stale failure fix doesn't linger under the spinner.
    private func setFileLaneWriteRunning(ref: RemoteAgentRef) {
        guard let i = fileLanes.firstIndex(where: { $0.ref == ref }) else { return }
        fileLanes[i].reachAuth = .running
        fileLanes[i].detail = nil
    }

    /// Apply a staged-write-test outcome to its lane: on success mark verified
    /// (green), on failure record the taxonomy fix. `writeVerified` is set ONLY
    /// here + on the local read of `snapshot.available`.
    private func updateFileLaneAfterWrite(ref: RemoteAgentRef, success: Bool, code: Int?) {
        guard let i = fileLanes.firstIndex(where: { $0.ref == ref }) else { return }
        fileLanes[i].writeVerified = success
        if success {
            fileLanes[i].reachAuth = .passed
            fileLanes[i].detail = String(localized: "diagnostics.files.write.ok", defaultValue: "File uploads verified — a test file wrote and read back.")
        } else {
            let resolved = code ?? AppError.fileTransferUploadFailed.errorCode
            fileLanes[i].reachAuth = .failed(code: resolved)
            fileLanes[i].detail = DiagnosticsExplainer.explain(code: resolved).fix
        }
    }

    /// Per-lane file facts for the copy block — DERIVED from `fileLanes` so the
    /// copied report ALWAYS matches the screen. `Why:` a reach probe / write test
    /// mutates `fileLanes` live (never a separate snapshot), so a stored copy would
    /// print `reachAuth=not-run` after the user watched a lane go red/green.
    /// Allowlist-safe: backend kind + bools + probe-state name + anonymous custom
    /// ordinal only; NEVER a name/URL (`displayName` is never read here).
    private var factFileLanes: [(kind: String, configured: Bool, reachAuth: String, verified: Bool)] {
        fileLanes.map { lane in
            // Read the lane's CANONICAL config-order ordinal (set from
            // `customOrdinals` at build) instead of recomputing here — so the
            // `custom-gateway#N` in the report always matches the gateway row's
            // `reportLabel` AND the on-screen "Custom gateway N", by construction.
            let kind = lane.backendKind == "custom"
                ? "custom-gateway#\(lane.customOrdinal ?? 0)"
                : lane.backendKind
            return (kind: kind, configured: lane.configured, reachAuth: Self.statusFactName(lane.reachAuth), verified: lane.writeVerified)
        }
    }

    /// Watch-health facts for the copy block — DERIVED live from the query
    /// state (like `factFileLanes`) so the report always matches the screen.
    /// Allowlist-safe: freshness/permission enum names, counts, versions, and
    /// the numeric `WCError` code — never message text.
    private var factWatchHealth: String {
        guard let outcome = watchHealthLastOutcome else { return "not-run" }
        switch outcome {
        case .unsupported:
            return "unsupported"
        case .noResponse(.timedOut):
            return "no-response(timeout)"
        case .noResponse(.transportError(let code)):
            return "no-response(wc \(code))"
        case .reply(let state):
            var parts = ["settings=\(state.settingsFreshness.rawValue)"]
            if let depth = state.relayQueueDepth { parts.append("relayQueue=\(depth)") }
            if let mic = state.micPermission { parts.append("mic=\(mic)") }
            if let notif = state.notificationPermission { parts.append("notif=\(notif)") }
            if let version = state.appVersion, let build = state.appBuild {
                parts.append("v=\(version)(\(build))")
            }
            if let os = state.osVersion { parts.append("os=\(os)") }
            return parts.joined(separator: " ")
        }
    }

    // MARK: - Copyable report (allowlist enforced by construction)

    /// A privacy-safe, support-shareable summary. Composes ONLY from the
    /// allowlisted facts captured during local reads + the per-check pass/fail
    /// (with `code <n> (<slug>)` on failure). PHYSICALLY never reads a secret
    /// accessor (`getAPIKey` / `getRemoteAgentToken` / `getRemoteAgentURL` /
    /// fingerprint) — every field is a primitive already in hand.
    func copyBlock() -> String {
        var lines: [String] = []
        lines.append("Conduck Diagnostics")
        lines.append("App \(factAppVersion) (\(factAppBuild))")
        lines.append("OS \(factOSName) \(factOSVersion) · \(factDeviceClass)")
        var networkQualifiers = [factNetworkInterface]
        if factNetworkConstrained { networkQualifiers.append("constrained") }
        if factNetworkExpensive { networkQualifiers.append("expensive") }
        lines.append("Network: \(factNetworkReachable ? "reachable" : "offline") (\(networkQualifiers.joined(separator: ", ")))")
        lines.append("STT: \(factSTTArchetype) · keys=\(factSTTKeyCount)")
        lines.append("TTS: \(factTTSArchetype)")

        let kinds = factGatewayKinds.isEmpty ? "none" : factGatewayKinds.joined(separator: ", ")
        lines.append("Gateways: \(kinds) · customs=\(factCustomGatewayCount) · partial=\(factPartialGatewayCount)")
        lines.append("Auth: bearer×\(factAuthBearerCount), none×\(factAuthNoneCount)")
        // Per-gateway file lanes — backend KIND (or anonymous `custom-gateway#N`
        // ordinal) + bools + probe-state name only; NEVER a name/URL.
        if factFileLanes.isEmpty {
            lines.append("File lanes: none")
        } else {
            for lane in factFileLanes {
                lines.append("file[\(lane.kind)]: configured=\(lane.configured) reachAuth=\(lane.reachAuth) verified=\(lane.verified)")
            }
        }
        lines.append("iCloud: \(factICloudStatus) · token=\(factUbiquityPresent)")
        lines.append("Sync: \(factSyncEventCount) events, \(factSyncErrorCount) errors")
        lines.append("BgRefresh: \(factBackgroundRefresh) · ScreenRec: \(factScreenRecording) · Watch: \(factWatch)")
        // Watch courier + live-query facts (iOS with a paired watch only —
        // `factWatch == "n/a"` means no watch row exists, so these lines would
        // be noise).
        if factWatch != "n/a" {
            lines.append("Watch courier: \(factWatchBroadcast)")
            lines.append("Watch health: \(factWatchHealth)")
        }
        // On cloud STT the Speech-Recognition permission is irrelevant (the row is
        // `[n/a]`) — qualify it so a support reader doesn't take `Speech: authorized`
        // as a live dependency.
        let speechField = factSpeechApplicable
            ? factSpeechPermission
            : "not used (\(factSpeechPermission))"
        lines.append("Mic: \(factMicPermission) · Speech: \(speechField) · Notif: \(factNotificationPermission) · Camera: \(factCamera)")
        lines.append("ShareInbox: stuck=\(factShareInboxStuck) targets=\(factShareTargetsHealthy) · PendingRetry: \(factPendingRetry) · Storage: \(factStorage)")

        // TTS outcomes — the device-local forensic ring (privacy-safe tokens ONLY:
        // surface / outcome / stage / bucketed error code / typed key state /
        // opaque config signature / relative age — NEVER text, keys, URLs, or
        // voice/model names). Count line + the newest up-to-5 events, newest first.
        if factTTSOutcomes.isEmpty {
            lines.append("TTS outcomes: none")
        } else {
            lines.append("TTS outcomes: \(factTTSOutcomes.count)")
            let now = Date()
            for event in factTTSOutcomes.suffix(5).reversed() {
                let code = event.errorCode.map(String.init) ?? "none"
                let age = Self.relativeAge(now.timeIntervalSince(event.timestamp))
                lines.append("tts-outcome: \(event.surface.rawValue) \(event.outcome.rawValue)/\(event.stage.rawValue) code=\(code) key=\(event.keyState) sig=\(event.configSignature) age=\(age)")
            }
        }

        // Proven chat, per gateway. The counterweight to every probe line above:
        // those say "reachable and signed in", this says "a turn actually
        // completed from this device". Absence is NEUTRAL, never a failure — a
        // fresh pairing has nothing here and nothing is wrong.
        if factChatSuccesses.isEmpty {
            lines.append("Chat proven: none on this device")
        } else {
            let now = Date()
            let proven = factChatSuccesses.map { "\($0.token) \(Self.relativeAge(now.timeIntervalSince($0.at)))" }
            lines.append("Chat proven: \(proven.joined(separator: ", "))")
        }

        // Recent FAILED sends — the one section that reports what actually
        // happened on the wire rather than what a probe thinks. Without it a
        // report can read entirely green while chat has never once worked, which
        // is precisely the report that gets pasted into a help request.
        //
        // Labelled "Recent failed sends", NEVER "current failures": these rows
        // persist, so a fixed problem stays listed and must not be read as
        // evidence about the configuration in force right now. `age` is the age of
        // the TURN (no `failedAt` is recorded), which is why the label says turn.
        if factFailedSends.isEmpty {
            lines.append("Recent failed sends: none")
        } else {
            lines.append("Recent failed sends: \(factFailedSends.count) distinct")
            let now = Date()
            for fact in factFailedSends {
                let code = fact.code.map { "\($0) (\(DiagnosticsExplainer.slug(forCode: $0)))" } ?? "none"
                let age = Self.relativeAge(now.timeIntervalSince(fact.createdAt))
                lines.append("send-failure: \(fact.backendToken) code=\(code) wire=\(fact.wireToken) device=\(fact.deviceToken) turn-age=\(age)")
            }
        }

        lines.append("--")
        for check in checks {
            var marker: String
            switch check.status {
            case .passed:
                marker = "[pass]"
            case .failed(let code):
                if let code {
                    marker = "[fail code \(code) (\(DiagnosticsExplainer.slug(forCode: code)))]"
                } else {
                    marker = "[fail]"
                }
            case .warning:
                marker = "[warn]"
            case .notApplicable:
                marker = "[n/a]"
            case .notRun:
                marker = "[skip]"
            case .running:
                marker = "[…]"
            }
            var tags: [String] = []
            if let role = check.role { tags.append(role.rawValue) }
            if let label = check.reportLabel { tags.append(label) }
            let tagSuffix = tags.isEmpty ? "" : " (\(tags.joined(separator: " ")))"
            lines.append("\(marker) \(check.title)\(tagSuffix)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Check mutation

    /// Detail is assigned UNCONDITIONALLY — a nil clears the prior text, so a
    /// re-run that turns a row green (or spins it `.running`) never leaves the
    /// OLD failure's fix instruction stranded beneath the new state.
    private func setStatus(_ id: String, _ status: DiagnosticStatus, detail: String? = nil) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index].status = status
        checks[index].detail = detail
    }

    // MARK: - Gateway rows

    /// Sort configured gateways into display order (focused/bound first, then the
    /// active/default, then the rest in config order) with each ref's role. The
    /// single ordering shared by the gateway `checks` rows and `gatewayDisplayOrder`.
    private func sortedGatewayRefs(refs: [RemoteAgentRef], defaultRef: RemoteAgentRef) -> [(ref: RemoteAgentRef, role: DiagnosticRole?)] {
        var items: [(priority: Int, index: Int, ref: RemoteAgentRef, role: DiagnosticRole?)] = []
        for (index, ref) in refs.enumerated() {
            let role: DiagnosticRole?
            if ref == focusedRef {
                role = .focused
            } else if ref == defaultRef {
                role = .active
            } else {
                role = nil
            }
            let priority: Int
            switch role {
            case .focused: priority = 0
            case .active: priority = 1
            case nil: priority = 2
            }
            items.append((priority, index, ref, role))
        }
        return items
            .sorted { ($0.priority, $0.index) < ($1.priority, $1.index) }
            .map { ($0.ref, $0.role) }
    }

    /// Build the gateway connection rows from the shared sorted order. Titles stay
    /// GENERIC (built-in kind title / `customGatewayTitle`) — the real custom name
    /// lives only in `gatewayDisplayOrder`, so `copyBlock()` (which reads
    /// `check.title`) never sees it. `reportLabel` carries the anonymous
    /// `custom-gateway#N` ordinal (the same `N` used everywhere else).
    private func buildGatewayRows(sorted: [(ref: RemoteAgentRef, role: DiagnosticRole?)], customOrdinals: [RemoteAgentRef: Int]) -> [DiagnosticCheck] {
        sorted.map { item in
            let reportLabel: String? = item.ref.customID != nil
                ? "custom-gateway#\(customOrdinals[item.ref] ?? 0)"
                : nil
            let title: String
            switch item.ref {
            case .builtin(let backend):
                title = "\(backend.displayName) \(Self.gatewayWord)"
            case .custom:
                title = Self.customGatewayTitle
            }
            return DiagnosticCheck(
                id: Self.connectionCheckID(for: item.ref),
                title: title,
                category: .connection,
                tier: .networkCheck,
                status: .notRun,
                detail: nil,
                role: item.role,
                reportLabel: reportLabel
            )
        }
    }

    /// Stable per-custom ordinal in config/input order — the SAME `N` the copy
    /// block's `custom-gateway#N` tag + `file[custom-gateway#N]` line use, so the
    /// on-screen "Custom gateway N" fallback (shown when a custom's roster name is
    /// missing/empty) and the pasted report never disagree for a given ref.
    /// Reduce persisted failed turns to report-safe facts: dedupe, then take the
    /// newest few.
    ///
    /// **Dedupe is not cosmetic.** A single broken gateway produces a run of
    /// identical failures in one conversation, so an undeduped "newest 5" is five
    /// copies of one fact — and the report then hides the OTHER gateway that is
    /// also failing, which is the case the section exists to expose. Collapsed on
    /// (gateway, code, wire, device): same gateway failing the same way from the
    /// same surface is ONE finding, however many times the user retried.
    ///
    /// Redaction happens HERE, at the boundary, not at emit time — so no raw
    /// `custom_<uuid>` or server-supplied wire string is ever held in runner state
    /// to be leaked by a later formatting change.
    static func redactFailedSends(
        _ summaries: [ConversationStore.FailedTurnSummary],
        customOrdinals: [RemoteAgentRef: Int],
        keeping: Int = 5
    ) -> [FailedSendFact] {
        var seen: Set<String> = []
        var out: [FailedSendFact] = []
        for summary in summaries.sorted(by: { $0.createdAt > $1.createdAt }) {
            let backendToken: String = {
                guard let raw = summary.backend,
                      let ref = RemoteAgentRef(rawString: raw) else { return "unknown" }
                switch ref {
                case .builtin(let backend):
                    // Locked raw values (`openclaw`/`hermes`/`openrouter`) — a
                    // closed vocabulary, safe to name.
                    return backend.rawValue
                case .custom:
                    // The ONE canonical ordinal, so a report line and the
                    // on-screen "Custom gateway N" always agree. A gateway the
                    // user has since deleted has no ordinal — say so rather than
                    // inventing one, and never fall back to the UUID.
                    guard let ordinal = customOrdinals[ref] else { return "custom-gateway#?" }
                    return "custom-gateway#\(ordinal)"
                }
            }()
            let wireToken: String = {
                guard let raw = summary.failureWireCode else { return "none" }
                // Validated through the frozen vocabulary: an unrecognised code is
                // arbitrary server text, so it collapses rather than echoing.
                return AdapterWireCode(rawValue: raw)?.rawValue ?? "other"
            }()
            let deviceToken: String = {
                guard let raw = summary.sourceDevice, !raw.isEmpty else { return "unknown" }
                return MessageRowFormatters.baseDevice(from: raw)
            }()
            let key = "\(backendToken)|\(summary.failureCode.map(String.init) ?? "-")|\(wireToken)|\(deviceToken)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(FailedSendFact(
                backendToken: backendToken,
                code: summary.failureCode,
                wireToken: wireToken,
                deviceToken: deviceToken,
                createdAt: summary.createdAt
            ))
            if out.count == keeping { break }
        }
        return out
    }

    static func customOrdinals(_ refs: [RemoteAgentRef]) -> [RemoteAgentRef: Int] {
        var map: [RemoteAgentRef: Int] = [:]
        var n = 0
        for ref in refs where ref.customID != nil {
            n += 1
            map[ref] = n
        }
        return map
    }

    /// 1-based roster-order ordinal of the ACTIVE custom STT endpoint — the `N`
    /// in the copy block's anonymous `custom-stt#N` tag. Nil when the active STT
    /// is not a custom endpoint (built-in cloud / Apple) or the roster doesn't
    /// contain it (just-deleted endpoint still active for one rebuild).
    static func customSTTOrdinal(activePresetID: String, roster: [CustomVoiceEndpoint]) -> Int? {
        guard let idx = roster.firstIndex(where: { $0.sttPresetID == activePresetID }) else { return nil }
        return idx + 1
    }

    /// The refs "Test everything" runs the mutating write test on — every
    /// CONFIGURED file lane (any reach state; the write test self-stages), skipping
    /// only the not-set-up ones (nothing to write to).
    static func lanesToWrite(_ lanes: [FileLaneState]) -> [RemoteAgentRef] {
        lanes.filter(\.configured).map(\.ref)
    }

    private static func connectionCheckID(for ref: RemoteAgentRef) -> String {
        switch ref {
        case .builtin(let backend):
            return "gateway.\(backend.rawValue)"
        case .custom(let id):
            return "gateway.custom.\(id.uuidString.lowercased())"
        }
    }

    private static func gatewayKind(_ ref: RemoteAgentRef) -> String {
        switch ref {
        case .builtin(let backend): return backend.rawValue
        case .custom: return "custom"
        }
    }

    /// Whether `ref`'s backend has a file-server lane (`openrouter` — hosted model,
    /// no working directory — does not; customs are OpenAI-compatible servers that
    /// MAY have file tools, so file-capable). Single source: the backend descriptor.
    private static func isFileCapable(_ ref: RemoteAgentRef) -> Bool {
        switch ref {
        case .builtin(let backend): return RemoteAgentBackendRegistry.lookup(id: backend).fileTransferSupported
        case .custom: return true
        }
    }

    /// UI-only friendly name for a file lane (built-in display name or the user's
    /// custom gateway label). NEVER reaches `copyBlock()` — `FileLaneState` lives
    /// outside `checks`.
    static func gatewayDisplayName(_ ref: RemoteAgentRef, customGateways: [CustomGateway], ordinal: Int?) -> String {
        switch ref {
        case .builtin(let backend):
            return "\(backend.displayName) \(gatewayWord)"
        case .custom(let id):
            if let name = customGateways.first(where: { $0.id == id })?.name,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
            // Roster name missing/empty → the numbered fallback the founder asked
            // for. `ordinal` is the canonical config-order `N` (see `customOrdinals`),
            // so it matches the copy block's `custom-gateway#N`.
            if let ordinal {
                return String(localized: "diagnostics.gateway.customNumbered", defaultValue: "Custom gateway \(ordinal)")
            }
            return customGatewayTitle
        }
    }

    /// Carry-over / stale-drop signature for a file lane. A URL/credential/pin
    /// change flips it, RESETTING the reach/auth result rather than carrying a
    /// stale one. Delegates to `FileTransferSnapshot.identitySignature` — the
    /// single definition of lane identity, shared with the capability
    /// refresher's apply-guard. `"none"` when unconfigured.
    private static func fileLaneSignature(_ snapshot: SettingsManager.FileTransferSnapshot?) -> String {
        snapshot?.identitySignature ?? "none"
    }

    // MARK: - Off-actor probe workers (run on the global executor)

    private struct GatewayProbeInput: Sendable {
        let checkID: String
        let backend: RemoteAgentBackend
        let url: URL
        let token: String
        let authScheme: RemoteAgentAuthScheme
        let fingerprint: String?
        let probePath: String
        /// The envelope the probe's 2xx body must carry. Travels WITH `probePath`
        /// — the two are a pair (`/v1/models` → a `data` array; OpenRouter's
        /// `/v1/key` → a `data` object), and passing the path without the shape
        /// would validate OpenRouter's key response against the model-list shape
        /// and fail a perfectly healthy key.
        let bodyShape: RemoteAgentProbeBodyShape
        /// Locality BOOL (never the host) — gates the Local-Network hint on a
        /// failed probe of a private/`.local`/tailnet host while online.
        let isLocalHost: Bool
    }

    /// Input for the per-gateway NON-mutating file-server reach+auth probe.
    private struct FileReachProbeInput: Sendable {
        let ref: RemoteAgentRef
        let snapshot: SettingsManager.FileTransferSnapshot
        /// The lane's config signature at dispatch — a mismatch on apply drops the
        /// outcome (the lane changed mid-probe).
        let signature: String
        let isLocalHost: Bool
    }

    private struct STTProbeInput: Sendable {
        let checkID: String
        let apiKey: String
        let provider: STTProvider
        /// Resolved BYO-endpoint config (nil for the frozen cloud providers) —
        /// carries the per-uuid URL, effective auth scheme, and cert pin the
        /// probe must honor, exactly like the real transcribe path.
        let customConfig: CustomSTTConfig?
    }

    private struct ProbeOutcome: Sendable {
        let checkID: String
        let status: DiagnosticStatus
        let detail: String?
    }

    /// Sum type collected from the single sweep task group — gateway + STT auth
    /// outcomes and file-lane reach outcomes run concurrently and are applied to
    /// their distinct destinations (`checks` vs `fileLanes`).
    private enum ConnectionProbeResult: Sendable {
        case gatewayOrSTT(ProbeOutcome, isLocalHost: Bool)
        case fileLane(ref: RemoteAgentRef, outcome: FileReachabilityOutcome, signature: String, isLocalHost: Bool)
    }

    /// Map a file-server reach+auth outcome to a lane status + plain-English
    /// detail. NOTHING here returns `.passed`: the reach probe is a single ranged
    /// GET where a 404 is the pass signal, so it greens a read-only nginx, a
    /// wrong base path, or a server that 404s before auth. A green check is a
    /// claim that uploads work, and only the staged write test (`runConnectionTest`
    /// — PUT → GET with byte equality → DELETE) can back it. The best this probe
    /// can honestly say is "nothing is obviously broken yet".
    private static func fileReachStatus(_ outcome: FileReachabilityOutcome) -> (DiagnosticStatus, String?) {
        switch outcome {
        case .reachAuthOK:
            return (.warning, String(localized: "diagnostics.files.reach.ok.v2", defaultValue: "File host reachable and sign-in looks OK, but this check can't prove uploads land. Run the file-server test to confirm."))
        case .authFailed:
            let code = AppError.fileTransferAuthFailed.errorCode
            return (.failed(code: code), DiagnosticsExplainer.explain(code: code).fix)
        case .suspicious:
            return (.warning, String(localized: "diagnostics.files.reach.suspicious", defaultValue: "Reached the file host, but the response was unexpected. Run the file-server test to confirm."))
        case .inconclusive:
            return (.warning, String(localized: "diagnostics.files.reach.inconclusive", defaultValue: "Couldn't confirm the file host. Run the file-server test."))
        case .unreachable:
            let code = AppError.fileTransferUnreachable.errorCode
            return (.failed(code: code), DiagnosticsExplainer.explain(code: code).fix)
        case .certUntrusted:
            // Its own code, so the row shows the certificate remedy instead of
            // the unreachable row's "check your file-server is running" — the
            // host answered, so that instruction leads nowhere.
            let code = AppError.fileTransferCertUntrusted.errorCode
            return (.failed(code: code), DiagnosticsExplainer.explain(code: code).fix)
        case .certMismatch:
            // Kept apart from `.certUntrusted` for the same reason the staged
            // test keeps them apart: this device TRUSTED the certificate and the
            // pinned key still disagreed, which is the one outcome that means the
            // connection may be intercepted. Sending that user after a trusted
            // certificate points them at something they already have.
            let code = AppError.fileTransferCertMismatch.errorCode
            return (.failed(code: code), DiagnosticsExplainer.explain(code: code).fix)
        case .certKeyUnpinnable:
            // Third certificate outcome, its own row: this device trusted the
            // chain and the pin was never compared, so neither the certificate
            // remedy above nor the interception warning applies.
            let code = AppError.fileTransferCertKeyUnpinnable.errorCode
            return (.failed(code: code), DiagnosticsExplainer.explain(code: code).fix)
        }
    }

    /// Append the soft Local-Network-permission hint (iOS only) to a failure
    /// detail. Never asserts "denied" (Apple exposes no readable status) and never
    /// leaks the host — the caller has already reduced locality to a bool.
    private static func appendLocalNetworkHint(_ detail: String?) -> String? {
        #if os(iOS)
        let hint = String(localized: "diagnostics.hint.localNetwork", defaultValue: "If this is a local address, check Conduck's Local Network permission in Settings.")
        guard let detail, !detail.isEmpty else { return hint }
        return "\(detail) \(hint)"
        #else
        return detail
        #endif
    }

    private static func probeGateway(_ input: GatewayProbeInput) async -> ProbeOutcome {
        do {
            let outcome = try await RemoteAgentClient.shared.testConnection(
                backend: input.backend,
                url: input.url,
                token: input.token,
                authScheme: input.authScheme,
                fingerprint: input.fingerprint,
                probePath: input.probePath,
                bodyShape: input.bodyShape
            )
            switch outcome {
            case .ok:
                // Green, but SCOPED green — and the scope is the whole point. This
                // probe asks the gateway for its model list; it never sends a turn.
                // A user reading a bare green row concludes "chat works", then hits
                // a wrong model / model-required / vision-unsupported failure on
                // their first real message with nothing on this screen having
                // hinted at it. Same honesty shape as the file lane's reach probe,
                // which likewise refuses to let a cheap check speak for the
                // expensive one it cannot perform.
                return ProbeOutcome(
                    checkID: input.checkID,
                    status: .passed,
                    detail: String(
                        localized: "diagnostics.gateway.reach.ok",
                        defaultValue: "Reachable and signed in. This checks the model list — sending a message is the only thing that proves chat works."
                    )
                )
            case .okNoModels:
                // The route is real and speaks the protocol — but a gateway
                // advertising zero models cannot answer a turn, so this is a
                // warning, not a green check. (Commonest on a fresh Ollama with
                // nothing pulled yet.)
                return ProbeOutcome(
                    checkID: input.checkID,
                    status: .warning,
                    detail: String(
                        localized: "diagnostics.gateway.noModels",
                        defaultValue: "Your gateway answered, but lists no models. Load a model on the server."
                    )
                )
            case .untrustedCert:
                // FAILED, not `.warning`: a warning reads as "works, but tidy
                // this up later", and there is no later — this device refuses
                // the certificate on every attempt until the SERVER is given a
                // publicly-trusted one. Routed through the code so the row
                // shows the same remedy every other lane shows.
                let code = AppError.remoteAgentCertUntrusted.errorCode
                return ProbeOutcome(
                    checkID: input.checkID,
                    status: .failed(code: code),
                    detail: DiagnosticsExplainer.explain(code: code).fix
                )
            }
        } catch {
            let code = (error as? AppError)?.errorCode ?? AppError.unknown(error).errorCode
            return ProbeOutcome(
                checkID: input.checkID,
                status: .failed(code: code),
                detail: DiagnosticsExplainer.explain(code: code).fix
            )
        }
    }

    private static func probeSTT(_ input: STTProbeInput) async -> ProbeOutcome {
        // No key → surface missing-key without a doomed round-trip — but ONLY
        // when the endpoint's effective auth actually requires one. A keyless
        // BYO endpoint (auth `.none`) probes legitimately with an empty key;
        // the probe then answers "does the endpoint accept requests?".
        let keyRequired = (input.customConfig?.auth ?? STTAuthScheme.bearer) != STTAuthScheme.none
        if input.apiKey.isEmpty && keyRequired {
            let code = AppError.sttMissingAPIKey.errorCode
            return ProbeOutcome(
                checkID: input.checkID,
                status: .failed(code: code),
                detail: DiagnosticsExplainer.explain(code: code).fix
            )
        }
        do {
            try await STTClient.shared.headProbe(apiKey: input.apiKey, provider: input.provider, customConfig: input.customConfig)
            return ProbeOutcome(checkID: input.checkID, status: .passed, detail: nil)
        } catch {
            let code = (error as? AppError)?.errorCode ?? AppError.unknown(error).errorCode
            return ProbeOutcome(
                checkID: input.checkID,
                status: .failed(code: code),
                detail: DiagnosticsExplainer.explain(code: code).fix
            )
        }
    }

    // MARK: - Network path (one-shot NWPathMonitor; local OS state, no prompt)

    private static func probeNetworkPath() async -> (reachable: Bool, interface: String, expensive: Bool, constrained: Bool) {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: Constants.identityNamespace + ".diagnostics.netcheck")
            // Single-fire latch — a second `pathUpdateHandler` delivery must not
            // double-resume the continuation (which would `fatalError`). The
            // lock-backed latch is stronger than this single-serial-queue caller
            // strictly needs — one primitive, no unguarded-flag trap to copy.
            let resumeOnce = LockedOnce()
            monitor.pathUpdateHandler = { [monitor] path in
                // A second delivery can never double-resume the continuation.
                guard resumeOnce.claim() else { return }
                monitor.cancel()
                let reachable = path.status == .satisfied
                let interface: String
                if path.usesInterfaceType(.wifi) {
                    interface = "wifi"
                } else if path.usesInterfaceType(.cellular) {
                    interface = "cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    interface = "ethernet"
                } else if path.usesInterfaceType(.loopback) {
                    interface = "loopback"
                } else if reachable {
                    interface = "other"
                } else {
                    interface = "none"
                }
                // Already in hand on the same path: `isConstrained` = Low Data
                // Mode (a deliberate user setting — detail note, NEVER a warn);
                // `isExpensive` = cellular/hotspot (neutral copy-block metadata).
                continuation.resume(returning: (reachable, interface, path.isExpensive, path.isConstrained))
            }
            monitor.start(queue: queue)
        }
    }

    // MARK: - Static copy / status helpers

    private static let gatewayWord = String(localized: "diagnostics.gatewayWord", defaultValue: "gateway")
    private static let customGatewayTitle = String(localized: "diagnostics.gateway.custom", defaultValue: "Custom gateway")

    /// The setup-row status for a voice provider. When the TYPED `keyState` is
    /// supplied (the TTS path, from `TTSSnapshot`) it is the authoritative source —
    /// it honors the snapshot invariant (`apiKey` non-nil ⇔ `.present`) and, unlike
    /// a bare `apiKey == nil` test, tells a genuinely-MISSING key apart from a
    /// temporarily-UNREADABLE one (a locked Keychain). Both remain `.warning`
    /// (severity unchanged — a not-yet-usable key is a "needs attention", not a
    /// hard failure), but the two carry DISTINCT explanatory copy: `.missing`
    /// points at Voice settings, `.unreadable` at unlocking the device. Callers
    /// without a typed state (the STT tuple path) pass `keyState: nil` and keep the
    /// legacy `apiKey`-presence behavior.
    private static func providerConfigStatus(
        isInProcess: Bool,
        apiKey: String?,
        keylessEndpointConfigured: Bool = false,
        keyState: APIKeyState? = nil
    ) -> DiagnosticStatus {
        if isInProcess { return .passed }               // Apple on-device is always available.
        if keylessEndpointConfigured { return .passed } // Keyless BYO endpoint with a URL — no key to miss.
        if let keyState {
            switch keyState {
            case .present, .notRequired: return .passed
            case .missing, .unreadable: return .warning
            }
        }
        return (apiKey?.isEmpty == false) ? .passed : .warning
    }

    /// Whether the Voice section is visible. Pure so the mic-visibility fix is
    /// unit-testable without a live TCC permission: the section shows when a voice
    /// provider is configured OR mic is GRANTED (existing) OR mic is DENIED / Apple-
    /// speech denied-or-restricted (the fix — the fresh Apple-STT user who tapped
    /// "Don't Allow" must SEE the red mic row). `.undetermined` does NOT force it
    /// (no nagging a user who never asked).
    static func shouldShowVoiceSection(
        hasStoredKeys: Bool,
        sttInProcess: Bool,
        ttsIsApple: Bool,
        micGranted: Bool,
        micDenied: Bool,
        speechDeniedOrRestricted: Bool,
        hasPendingRetry: Bool = false
    ) -> Bool {
        // `hasPendingRetry` force-shows the section: the parked-retry row lives
        // in Voice, and a recording waiting to expire must never hide behind
        // the section's configured/permission heuristics.
        hasStoredKeys
            || !sttInProcess
            || !ttsIsApple
            || micGranted
            || micDenied
            || speechDeniedOrRestricted
            || hasPendingRetry
    }

    /// Compact relative age (`s`/`m`/`h`/`d`) for a ring event in the copy block —
    /// a single largest-unit bucket (12m, 3h, 2d), never a precise timestamp
    /// (coarse enough to answer "how recent?" without becoming a usage timeline).
    private static func relativeAge(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }

    /// Short allowlist-safe name for a `DiagnosticStatus` in the copy block (no
    /// code — the per-check lines already carry the taxonomy code).
    private static func statusFactName(_ status: DiagnosticStatus) -> String {
        switch status {
        case .passed: return "pass"
        case .warning: return "warn"
        case .failed: return "fail"
        case .notApplicable: return "n/a"
        case .notRun: return "not-run"
        case .running: return "running"
        }
    }

    #if os(iOS)
    private static func backgroundRefreshName(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "available"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private static func cameraStatusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// Watch link state. INFO, not red (spec-locked): warn ONLY when Conduck is
    /// missing from the wrist; a paired-but-unreachable watch is merely asleep
    /// (settings queue via `transferUserInfo`), so it stays green. The detail
    /// carries the last-turn recency: "never" gets an explicit end-to-end nudge
    /// (phrased as THIS iPHONE's observation — the phone can undercount if it
    /// was offline when the watch reported), a known turn gets its relative
    /// date. Status is derived from installed/reachable ALONE — a watch the
    /// user stopped wearing is not a fault. Static + non-private for tests.
    static func watchRowState(installed: Bool, reachable: Bool, lastTurn: Date?) -> (status: DiagnosticStatus, detail: String) {
        if !installed {
            return (.warning, String(localized: "diagnostics.sync.watch.notInstalled", defaultValue: "Conduck isn't installed on your Apple Watch — install it from the Watch app to use it on the wrist."))
        }
        let base = reachable
            ? String(localized: "diagnostics.sync.watch.reachable", defaultValue: "Apple Watch is connected.")
            : String(localized: "diagnostics.sync.watch.asleep", defaultValue: "Apple Watch is paired — it'll sync when it's awake and nearby.")
        let recency: String
        if let lastTurn {
            let relative = lastTurn.formatted(.relative(presentation: .named))
            recency = String(localized: "diagnostics.sync.watch.lastTurn", defaultValue: "Last Watch reply landed \(relative).")
        } else {
            recency = String(localized: "diagnostics.sync.watch.neverTurn", defaultValue: "This iPhone hasn't observed a successful Watch reply yet — record once from the wrist to confirm end-to-end.")
        }
        return (.passed, "\(base) \(recency)")
    }

    /// Bucket the last-successful-Watch-turn recency for the copy block (never a
    /// raw timestamp): `recent` (<7d) / `stale` (older) / `never`.
    static func watchTurnRecency(_ lastTurn: Date?) -> String {
        guard let lastTurn else { return "never" }
        return lastTurn.timeIntervalSinceNow > -7 * 24 * 60 * 60 ? "recent" : "stale"
    }

    /// Bucket a broadcast-outcome stamp (`timeIntervalSinceReferenceDate`; 0 =
    /// never) for the copy block: `recent` (<24h) / `stale` / `never`.
    static func stampRecency(_ stamp: Double, now: Date = Date()) -> String {
        guard stamp > 0 else { return "never" }
        let age = now.timeIntervalSinceReferenceDate - stamp
        return age < 24 * 60 * 60 ? "recent" : "stale"
    }

    /// Whether the newest settings-courier outcome is a FAILURE (a failure stamp
    /// exists and is newer than any success) — the predicate behind the row's
    /// "updates haven't gone through" line. Pure for tests.
    static func courierFailureIsCurrent(successAt: Double, failureAt: Double) -> Bool {
        failureAt > 0 && failureAt > successAt
    }

    /// Outstanding queued `transferUserInfo` couriers that are SETTINGS
    /// broadcasts (marker-filtered — relay transcript replies also ride this
    /// queue and must not count as "settings updates waiting").
    private static func outstandingSettingsCourierCount() -> Int {
        WCSession.default.outstandingUserInfoTransfers.filter {
            ($0.userInfo[Constants.watchBroadcastKindKey] as? String) == Constants.watchBroadcastKindSettings
        }.count
    }
    #endif

    /// Carry-over signature for a voice direction — a `id#<hash>` fingerprint of the
    /// probe INPUTS (provider id + key + model). The hash keeps the raw key out of a
    /// comparable field; the `#<hash>` still flips when the key/model is edited on the
    /// active provider, so a stale probe result is reset rather than carried. Stable
    /// within one process (the only scope a runner compares across).
    private static func voiceSignature(id: String, apiKey: String?, model: String?, endpoint: String? = nil, voice: String? = nil) -> String {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(apiKey)
        hasher.combine(model)
        hasher.combine(endpoint)
        hasher.combine(voice)
        return "\(id)#\(hasher.finalize())"
    }

    /// The BYO-endpoint slice of a voice signature — everything the real call
    /// honors (URL, dedicated model, effective auth, cert pin), so editing any
    /// of them invalidates a carried result.
    private static func endpointComponent(url: URL?, model: String, auth: STTAuthScheme, pin: String?) -> String {
        "\(url?.absoluteString ?? "")|\(model)|\(String(describing: auth))|\(pin ?? "")"
    }

    /// Per-ref gateway signature — the gateway rows' `fileLaneSignature`
    /// equivalent. Hashed so neither the token nor the URL lands in a
    /// comparable stored field.
    private static func gatewaySignature(url: URL, token: String?, authScheme: RemoteAgentAuthScheme, fingerprint: String?) -> String {
        var hasher = Hasher()
        hasher.combine(url.absoluteString)
        hasher.combine(token)
        hasher.combine(String(describing: authScheme))
        hasher.combine(fingerprint)
        return "\(hasher.finalize())"
    }

    private static func recordPermissionName(_ status: AVAudioApplication.recordPermission) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    private static func recordPermissionState(_ status: AVAudioApplication.recordPermission) -> DiagnosticPermissionState {
        switch status {
        case .granted: return .allowed
        case .undetermined: return .notRequested
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }

    private static func microphonePermissionDetail(_ state: DiagnosticPermissionState) -> String? {
        switch state {
        case .allowed:
            return nil
        case .notRequested:
            return String(localized: "diagnostics.permission.notRequested", defaultValue: "Not requested yet.")
        case .denied:
            return String(localized: "diagnostics.voice.mic.denied", defaultValue: "Microphone access is off for Conduck.")
        case .restricted:
            // AVAudioApplication currently exposes no restricted case; keep the
            // shared-state branch honest if Apple adds one later.
            return String(localized: "diagnostics.voice.mic.restricted", defaultValue: "Microphone access is controlled by Screen Time or device management.")
        case .unknown:
            return String(localized: "diagnostics.permission.statusUnavailable", defaultValue: "Permission status unavailable.")
        }
    }

    #if !os(watchOS)
    private static func speechStatusName(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private static func speechPermissionState(_ status: SFSpeechRecognizerAuthorizationStatus) -> DiagnosticPermissionState {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unknown
        }
    }

    private static func speechPermissionDetail(_ state: DiagnosticPermissionState) -> String? {
        switch state {
        case .allowed:
            return nil
        case .notRequested:
            return String(localized: "diagnostics.permission.notRequested", defaultValue: "Not requested yet.")
        case .denied:
            return String(localized: "stt.error.speechPermissionDenied", defaultValue: "Speech Recognition is turned off for Conduck.")
        case .restricted:
            return String(localized: "diagnostics.voice.speech.restricted", defaultValue: "Speech Recognition is controlled by Screen Time or device management.")
        case .unknown:
            return String(localized: "diagnostics.permission.statusUnavailable", defaultValue: "Permission status unavailable.")
        }
    }
    #endif

    /// Whether the notification config would deliver a headless reply SILENTLY
    /// despite being authorized — alerts turned off (banners/alerts disabled).
    /// This is the failure the row exists to catch beyond an outright denial.
    private static func notificationAlertsSuppressed(_ s: UNNotificationSettings) -> Bool {
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return s.alertSetting == .disabled
        default:
            return false
        }
    }

    private static func notificationStatusName(_ s: UNNotificationSettings) -> String {
        let base: String
        switch s.authorizationStatus {
        case .authorized: base = "authorized"
        case .provisional: base = "provisional"
        case .ephemeral: base = "ephemeral"
        case .denied: base = "denied"
        case .notDetermined: base = "notDetermined"
        @unknown default: base = "unknown"
        }
        // Surface the authorized-but-silenced case in the copy block for support.
        return notificationAlertsSuppressed(s) ? "\(base)(alerts-off)" : base
    }

    private static func notificationPermissionState(_ s: UNNotificationSettings) -> DiagnosticPermissionState {
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notRequested
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }

    private static func notificationCheckStatus(_ s: UNNotificationSettings) -> DiagnosticStatus {
        // The row exists to catch cases where a headless reply arrives with NO
        // visible alert: an outright denial, OR authorized-but-alerts-off (which
        // still delivers silently — a false-green if we checked auth alone).
        // Not-determined is neutral with an explicit Allow action: it is neither
        // a failure nor permission to claim that notifications work.
        notificationDiagnosticStatus(
            permissionState: notificationPermissionState(s),
            alertsSuppressed: notificationAlertsSuppressed(s)
        )
    }

    /// Pure notification-row rules — isolated from live UNUserNotificationCenter
    /// state so the truthful not-requested/denied/alerts-off matrix is testable.
    static func notificationDiagnosticStatus(
        permissionState: DiagnosticPermissionState,
        alertsSuppressed: Bool
    ) -> DiagnosticStatus {
        switch permissionState {
        case .notRequested: return .notRun
        case .denied, .restricted, .unknown: return .warning
        case .allowed: return alertsSuppressed ? .warning : .passed
        }
    }

    static func notificationDiagnosticAction(
        permissionState: DiagnosticPermissionState,
        alertsSuppressed: Bool
    ) -> DiagnosticPermissionAction? {
        if alertsSuppressed { return .openSettings }
        return permissionState.action
    }

    private static func notificationDetail(_ s: UNNotificationSettings) -> String {
        switch s.authorizationStatus {
        case .denied:
            return String(localized: "diagnostics.notifications.denied", defaultValue: "Turn on notifications in system Settings — otherwise Shortcut and background replies arrive silently.")
        case .notDetermined:
            return String(localized: "diagnostics.permission.notRequested", defaultValue: "Not requested yet.")
        case .authorized, .provisional, .ephemeral:
            if notificationAlertsSuppressed(s) {
                return String(localized: "diagnostics.notifications.alertsOff", defaultValue: "Notifications are allowed but alerts are off — Shortcut and background replies won't show. Turn on alerts in system Settings.")
            }
            return String(localized: "diagnostics.notifications.ok", defaultValue: "Shortcut and background replies can notify you.")
        @unknown default:
            return String(localized: "diagnostics.permission.statusUnavailable", defaultValue: "Permission status unavailable.")
        }
    }

    // MARK: - Phase-D silent-failure helpers (pure where possible — unit-tested)

    /// Free space on the App-Group volume via
    /// `volumeAvailableCapacityForImportantUsage` (the capacity class for
    /// user-initiated writes — may include system-reclaimable space). Nil =
    /// UNKNOWN (mis-provisioned container / query error) — never "healthy".
    private static func appGroupFreeBytes() -> Int64? {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ) else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// (status, detail) for the storage row, or nil = row hidden (healthy ≥
    /// 500 MB, or unknown — an "unknown" row is noise; the copy block still
    /// carries the bucket). Amber both tiers: low storage is recoverable, a
    /// red would over-bubble it.
    static func storageRowState(freeBytes: Int64?) -> (status: DiagnosticStatus, detail: String)? {
        guard let freeBytes else { return nil }
        let mb = freeBytes / (1024 * 1024)
        if mb >= 500 { return nil }
        if mb < 100 {
            return (.warning, String(localized: "diagnostics.capability.storage.critical", defaultValue: "Storage is critically low (\(mb) MB free) — attachments, shared items, and sync can fail. Free up space."))
        }
        return (.warning, String(localized: "diagnostics.capability.storage.low", defaultValue: "Storage is low (\(mb) MB free) — attachments, shared items, and sync may fail."))
    }

    /// Copy-block bucket for the storage probe: ok / low / critical / unknown.
    static func storageBucket(freeBytes: Int64?) -> String {
        guard let freeBytes else { return "unknown" }
        let mb = freeBytes / (1024 * 1024)
        if mb < 100 { return "critical" }
        if mb < 500 { return "low" }
        return "ok"
    }

    /// Whole minutes left before a parked retry's 10-minute TTL expires
    /// (rounded up; floor 0). Pure — unit-tested at the TTL boundary.
    static func pendingRetryRemainingMinutes(createdAt: Date, now: Date = Date()) -> Int {
        let remaining = 600 - now.timeIntervalSince(createdAt)
        return max(0, Int((remaining / 60).rounded(.up)))
    }

    /// Share-sheet picker snapshot health: nil = no gateways configured (no
    /// expectation the file exists), true = exists + decodes, false = missing
    /// or undecodable while ≥1 gateway is configured (the appex would render
    /// an empty/fallback picker).
    private static func shareTargetsSnapshotHealthy(hasGateways: Bool) -> Bool? {
        guard hasGateways else { return nil }
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ) else { return false }
        let url = groupURL
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Constants.shareTargetsSnapshotFileName)
        guard let data = try? Data(contentsOf: url) else { return false }
        return ShareTargetsSnapshot.decode(data) != nil
    }

    /// (status, detail) for the `sync.events` row from the newest-last event log —
    /// shared by every `performLocalReadsAndRebuild` pass. Warns ONLY when the
    /// tail is an unbroken failure run ("currently stuck"); a recovered error stays
    /// green so a healthy setup never cries wolf.
    private static func syncEventsRowState(_ syncLines: [String]) -> (status: DiagnosticStatus, detail: String) {
        let errorCount = syncLines.filter { $0.contains("FAIL") }.count
        // "Stuck" = the (up to 3-event) tail is an unbroken failure run. A log
        // shorter than the window still counts — two failures and no success
        // EVER is a current streak, not "recovered".
        let recentTail = syncLines.suffix(3)
        let stuck = !recentTail.isEmpty && recentTail.allSatisfy { $0.contains("FAIL") }
        let lastFailed = syncLines.last?.contains("FAIL") == true
        let detail: String
        if stuck {
            detail = String(localized: "diagnostics.sync.events.stuck", defaultValue: "Recent sync attempts are failing — check iCloud and your connection.")
        } else if lastFailed {
            // A trailing failure that hasn't reached streak length yet — say so;
            // "recovered" is only true when the newest event succeeded.
            detail = String(localized: "diagnostics.sync.events.latestFailed", defaultValue: "\(syncLines.count) recent sync events; the most recent attempt failed.")
        } else if errorCount > 0 {
            detail = String(localized: "diagnostics.sync.events.recovered", defaultValue: "\(syncLines.count) recent sync events; \(errorCount) earlier errors recovered.")
        } else {
            detail = String(localized: "diagnostics.sync.events.ok", defaultValue: "\(syncLines.count) recent sync events.")
        }
        return (stuck ? .warning : .passed, detail)
    }

    private static func iCloudReasonName(_ reason: CloudSyncMonitor.Reason) -> String {
        switch reason {
        case .noAccount: return "noAccount"
        case .restricted: return "restricted"
        case .quotaExceeded: return "quotaExceeded"
        }
    }

    private static func platformIdentity() -> (osName: String, deviceClass: String) {
        #if os(macOS)
        return ("macOS", "Mac")
        #elseif os(iOS)
        #if canImport(UIKit)
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .pad { return ("iPadOS", "iPad") }
        return ("iOS", "iPhone")
        #else
        return ("iOS", "iPhone")
        #endif
        #else
        return ("unknown", "unknown")
        #endif
    }

    /// Copy the bundled spoken probe clip to a throwaway temp file so the
    /// `STTClient.transcribe` deferred-delete never touches the read-only bundle
    /// resource. Returns nil if the asset is missing.
    private static func copyBundledProbeClip() -> URL? {
        guard let asset = Bundle.main.url(forResource: "stt-probe-spoken", withExtension: "m4a") else {
            return nil
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-stt-probe-\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: asset, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}

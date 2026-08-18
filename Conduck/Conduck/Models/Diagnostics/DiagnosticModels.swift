// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticModels.swift
//
// Value types for the local Diagnostics screen — the on-device health
// checklist that consolidates the app's connection/voice/file/sync tests.
//
// Deliberately dumb data: a `DiagnosticsRunner` produces `[DiagnosticCheck]`,
// `DiagnosticCheckRow` renders each. No behavior lives here.
//
// Privacy: a check's `detail`/`title` carry only plain-English, allowlisted
// text (provider KIND, counts, taxonomy-derived fixes) — never a URL, token,
// key, fingerprint, custom label, or raw provider error string.

import Foundation

/// Which section of the Diagnostics screen a check belongs to.
enum DiagnosticCategory: String, Sendable, CaseIterable {
    case connection
    case voice
    case sync
    /// OS permissions/capabilities the app relies on — Microphone, conditional
    /// Speech Recognition, Notifications, and the relevance-gated macOS Screen
    /// Recording grant behind ⌘⇧2 "Screenshot & Ask".
    case capability
}

/// The OS grants with explicit repair actions in Diagnostics. Kept as a small,
/// typed vocabulary so the view never dispatches permission behavior from a
/// fragile check-id string.
enum DiagnosticPermission: Sendable, Equatable, Hashable {
    case microphone
    case speechRecognition
    case notifications
    /// macOS exposes Screen Recording as a Boolean preflight rather than a
    /// multi-state authorization value. Diagnostics only shows this row after
    /// Screenshot & Ask has already attempted the system request, so an
    /// unavailable grant repairs through System Settings rather than re-prompting.
    case screenRecording
}

/// The action a permission row can honestly offer for its current TCC state.
/// Once access is denied Apple will not show the system prompt again, so the
/// repair action must switch from `.allow` to `.openSettings`.
enum DiagnosticPermissionAction: Sendable, Equatable {
    case allow
    case openSettings
}

/// Platform-neutral permission state for the shared iOS/iPadOS/macOS
/// Diagnostics UI. `.restricted` deliberately has no action: Screen Time or
/// device management owns that state, not the app or the user-facing prompt.
enum DiagnosticPermissionState: Sendable, Equatable {
    case allowed
    case notRequested
    case denied
    case restricted
    case unknown

    var action: DiagnosticPermissionAction? {
        switch self {
        case .notRequested: return .allow
        case .denied: return .openSettings
        case .allowed, .restricted, .unknown: return nil
        }
    }

    /// Map the permission state into the existing diagnostics glyph/report
    /// vocabulary. Not-yet-requested is neutral (`.notRun`), not an attention
    /// item; denied/restricted is a real failure. Speech Recognition supplies
    /// its stable AppError code, while microphone uses nil because it has no
    /// dedicated taxonomy slot.
    func diagnosticStatus(failureCode: Int?) -> DiagnosticStatus {
        switch self {
        case .allowed: return .passed
        case .notRequested: return .notRun
        case .denied, .restricted: return .failed(code: failureCode)
        case .unknown: return .warning
        }
    }
}

/// When a check runs — the guardrail that keeps prompting / billing / mutation
/// off the auto-run path.
enum DiagnosticTier: Sendable, Equatable {
    /// Instant local read (config shape, permission status, network path,
    /// iCloud account status). Runs automatically on screen open.
    case autoRead
    /// Cheap but hits the user's server or a provider (gateway reachability,
    /// cloud-STT auth). Can trigger the Local Network prompt or a POST-based
    /// billable probe, so it fires only inside the user-tapped "Test everything"
    /// run (`runConnectionChecks()`, the sweep phase) — never on screen open.
    case networkCheck
    /// A real, billable provider call (spoken-clip transcription, voice
    /// preview). Explicit button only; never auto-run. (The mutating file
    /// write test is modeled per-lane on `FileLaneState`, not as a check tier.)
    case explicitPaid
}

/// A check's outcome. `failed` carries the `AppError` numeric code so the row
/// can render the taxonomy-derived plain-English fix via `DiagnosticsExplainer`.
enum DiagnosticStatus: Sendable, Equatable {
    case running
    case passed
    /// Configured but needs attention (e.g. a denied-but-recoverable permission).
    case warning
    case failed(code: Int?)
    /// Not part of this configuration (e.g. a network test against Apple
    /// on-device STT, which never leaves the device).
    case notApplicable
    /// An explicit paid/mutating test the user hasn't tapped yet, or a
    /// permission the user has not requested yet (neutral, with an Allow action).
    case notRun
}

/// Role marker — orders the focused gateway first and tags rows in the
/// copyable report so a multi-gateway user can tell which red row is which.
enum DiagnosticRole: String, Sendable {
    case focused   // the gateway the failing conversation is bound to
    case active    // the app's default/active provider
}

/// One row in the Diagnostics checklist.
struct DiagnosticCheck: Identifiable, Sendable, Equatable {
    /// Stable key — `ForEach` id and the focus target for the banner deep-link
    /// (e.g. `"gateway.openclaw"`, `"gateway.custom.<uuid>"`, `"voice.stt.auth"`).
    let id: String
    /// Plain-English, allowlisted label (e.g. "OpenClaw", "Microphone"). A
    /// gateway row is titled with the INSTANCE — its display name, no trailing
    /// common noun; the runner assembles no naming phrase at runtime.
    let title: String
    let category: DiagnosticCategory
    let tier: DiagnosticTier
    var status: DiagnosticStatus
    /// One-line plain-English detail or fix. For `.failed`, the runner fills
    /// this from `DiagnosticsExplainer.explain(code:)`.
    var detail: String?
    var role: DiagnosticRole?
    /// Anonymous, stable-in-this-report ordinal for the copy block
    /// (`"custom-gateway#1"`, `"custom-stt#1"`) — nil for singletons. Never
    /// carries identifying data.
    var reportLabel: String?
}

/// Display state for the Diagnostics provider blocks — names the active STT + TTS
/// providers (mirroring the Voice Setup screen) and flags missing configuration.
/// Lives OUTSIDE the `[DiagnosticCheck]` list ON PURPOSE: the
/// provider name can be a user-named custom endpoint, and the copy-block
/// allowlist forbids user labels in the shareable summary — keeping it off
/// `checks` guarantees it never reaches `copyBlock()`.
struct VoiceSetupState: Equatable, Sendable {
    /// Friendly provider name, e.g. "Apple", "OpenAI", or the user's custom
    /// endpoint name — the SAME string the Voice Setup screen shows. UI-only.
    let sttName: String
    /// `.passed` when configured (on-device, or cloud with a key); `.warning`
    /// when a cloud provider is missing its key. This is not a live health test.
    let sttStatus: DiagnosticStatus
    let ttsName: String
    let ttsStatus: DiagnosticStatus
    /// Typed reason behind a `.warning` TTS status, so the row can say which
    /// problem it is. `.missing` = the provider has no key here (finish setup);
    /// `.unreadable` = the Keychain refused the read, usually a locked device —
    /// telling that user to "finish setup" sends them to re-enter a key that is
    /// already there. Nil when the status is not a warning, or when the caller
    /// has no typed state.
    let ttsKeyState: APIKeyState?
}

/// Display state for ONE gateway's file-server lane in the Diagnostics "Files"
/// section. Lives OUTSIDE the `[DiagnosticCheck]` list ON PURPOSE (like
/// `VoiceSetupState`): `displayName` can be a user-named custom gateway, and the
/// copy-block allowlist forbids user labels — keeping the lane off `checks`
/// guarantees the name never reaches `copyBlock()` (only the anonymous
/// `backendKind` + ordinal travel in the report).
///
/// The three test tiers map to DISTINCT fields so a reach/auth pass NEVER reads
/// as "attachments work":
///   - `configured` — a URL + credential are stored (cheap local read, `.autoRead`).
///   - `reachAuth` — the NON-mutating reach+auth probe (the "Test everything"
///     sweep) tops out at `.warning` ("reachable, sign-in looks OK — unconfirmed"):
///     it is a single ranged GET whose pass signal a read-only server or a wrong
///     base path can fake, so it never earns a green. `.failed` = auth rejected /
///     unreachable. `.passed` is set ONLY by the staged write test, which writes it
///     in the same hop as `writeVerified`. That pairing survives a rebuild only
///     because `DiagnosticsRunner.mayCarryLaneEvidence` refuses to carry evidence
///     across a readiness change — `fileLaneSignature` is the lane's IDENTITY and
///     an availability flip does not move it, so without that guard a `.passed`
///     could outlive the flag that earned it. `badge` still answers safely if one
///     ever does (routing decides, evidence does not).
///   - `writeVerified` — the staged PUT→GET→DELETE write test passed (explicit
///     button), or a previously-verified lane (`snapshot.available`). The ONLY
///     signal that certifies attachments actually work.
struct FileLaneState: Identifiable, Equatable, Sendable {
    /// The gateway this lane belongs to (`ForEach` id).
    let ref: RemoteAgentRef
    var id: RemoteAgentRef { ref }
    /// Friendly gateway name (built-in display name or the user's custom label).
    /// UI-ONLY — never copied into the report.
    let displayName: String
    /// Anonymous backend archetype for the copy block (`"openclaw"` / `"hermes"`
    /// / `"custom"`) — allowlist-safe (no user label).
    let backendKind: String
    /// A URL + credential are both stored for this ref.
    let configured: Bool
    /// Non-mutating reach+auth probe outcome. `.notRun` until the sweep runs.
    var reachAuth: DiagnosticStatus
    /// The staged write test passed (this session) OR the lane was already
    /// verified on open (`snapshot.available`) — attachments certified working.
    var writeVerified: Bool
    /// One-line plain-English detail (a probe result / failure fix). Never a host.
    var detail: String?
    /// The custom gateway's canonical config-order ordinal (`nil` for built-ins) —
    /// the SAME `N` as the copy block's `custom-gateway#N`. `factFileLanes` reads it
    /// instead of recomputing, so the "single canonical ordinal" holds by
    /// construction (robust to a future per-custom file-capability toggle) rather
    /// than by the coincidence that every custom is currently file-capable.
    var customOrdinal: Int? = nil

    /// Whether Conduck will actually ROUTE uploads to this lane right now — the
    /// exact condition `SettingsManager.fileTransferReadySnapshot(for:)` gates on,
    /// named once so the badge and the row's copy read the same concept instead of
    /// each re-deriving it.
    ///
    /// `configured &&` is not redundant: routing needs a complete snapshot as well
    /// as the flag, and a directly-constructed `configured: false, writeVerified:
    /// true` lane (reachable in tests) must not claim uploads are enabled.
    var uploadRoutingEnabled: Bool { configured && writeVerified }

    /// The single derived badge state — the ONE source of truth the view (glyph +
    /// tint + label) and the summary (`attention`) both read, so they can't drift.
    enum Badge: Equatable, Sendable {
        case notSetUp             // file-capable gateway, no file server configured (NEUTRAL)
        case configuredNotTested  // URL + credential stored, never probed/tested
        case testing              // a probe / write test is in flight
        case verified             // staged write test passed / persisted available
        case unconfirmed          // reach probe done — "sign-in looks OK", write unverified
        case failed               // reach auth rejected / unreachable, or write test failed
    }

    /// Derive the badge. A FRESH reach/write FAILURE (or unconfirmed) is checked
    /// BEFORE the persisted `writeVerified` flag — else a lane verified in a past
    /// session whose server later goes down (or whose credential rotated) would
    /// show a stale-green "Uploads enabled — test passed" over a host the just-run
    /// "Test connections" proved broken, and slip past the summary's attention
    /// count (it renders "Uploads still enabled — latest check failed"). `writeVerified`
    /// wins only when the current reach state is not a failure/warning.
    ///
    /// **`.verified` IMPLIES `uploadRoutingEnabled`, by construction.** The row's
    /// copy states routing ("Uploads enabled / disabled") beside the evidence, and
    /// that sentence is only safe if a green seal can never sit over a lane the
    /// store will refuse to upload to. The converse deliberately does NOT hold: a
    /// fresh `.failed`/`.warning` outranks the flag, so an ARMED lane can badge
    /// `.failed` — which is the whole point, since "still enabled, latest check
    /// failed" is the state a user most needs told.
    var badge: Badge {
        switch reachAuth {
        case .failed: return .failed
        case .warning: return .unconfirmed
        // AHEAD of the routing check, not after it. An ALREADY-ARMED lane is the
        // common case for a re-test, and ranking the persisted flag first left
        // `.running` unreachable for exactly those lanes: the row kept its green
        // seal for the whole probe instead of showing the spinner
        // `setFileLaneWriteRunning` exists to raise, then jumped straight to red if
        // the test failed. A test in flight outranks what the last one concluded.
        case .running: return .testing
        default: break
        }
        if uploadRoutingEnabled { return .verified }
        // Everything left means routing is OFF. `.passed` lands here only if a
        // carried pass ever outlived its availability, which
        // `DiagnosticsRunner.mayCarryLaneEvidence` now prevents upstream — it is
        // folded into this arm rather than given its own, so there is no branch
        // asserting a state the code cannot reach. Either way the answer is the
        // same and it is the honest one: another passing staged test is both the
        // description and the remedy.
        return configured ? .configuredNotTested : .notSetUp
    }

    /// Whether this lane registers in the Diagnostics summary's attention count.
    ///
    /// `.configuredNotTested` COUNTS. It looks like a resting state and is not — it
    /// means a file server is set up and Conduck will not send a byte to it, which
    /// is the silent outage this whole row exists to surface. Leaving it neutral let
    /// the summary mint a green "Checks passed" directly above "Uploads disabled —
    /// test required", so the one line a user reads first contradicted the one line
    /// that mattered. `.notSetUp` stays neutral: no server, nothing broken.
    var needsAttention: Bool {
        badge == .failed || badge == .unconfirmed || badge == .configuredNotTested
    }
}

/// Ordered per-gateway DISPLAY entry for the Diagnostics "Connection" section —
/// one per configured gateway (incl. non-file-capable `openrouter`), sorted
/// focused/active-first to match the connection check order. Lives OUTSIDE the
/// `[DiagnosticCheck]` list ON PURPOSE (like `FileLaneState` / `VoiceSetupState`):
/// `displayName` can be a user-named custom gateway, and the copy-block allowlist
/// forbids user labels — keeping the name here guarantees it never reaches
/// `copyBlock()`. The view titles the gateway row from `displayName`, pairs the
/// live status/glyph from the `checks` row identified by `connectionCheckID`, and
/// renders the nested "File server" sub-row from the `FileLaneState` matched by `ref`.
struct GatewayDisplayEntry: Identifiable, Equatable, Sendable {
    /// The gateway this entry represents (`ForEach` id; pairs to a `FileLaneState`).
    let ref: RemoteAgentRef
    var id: RemoteAgentRef { ref }
    /// Friendly gateway name — a built-in display name, the user's custom label, or
    /// the "Custom gateway N" fallback. UI-ONLY — never copied into the report.
    let displayName: String
    /// The `checks` row id (`gateway.<kind>`) whose live connection status/glyph
    /// this gateway reads — the copy-safe, generic-titled source of truth.
    let connectionCheckID: String
}

/// UI-only companion to the `connection.defaultGateway` row: the same verdict the
/// row carries, plus the REAL gateway names the row's copy-safe title/detail are
/// forbidden to hold. Same device as `GatewayDisplayEntry` / `FileLaneState` —
/// held outside `checks` so `copyBlock()` can never paste a user's own label.
struct DefaultGatewayStandingState: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The stored pointer is a member of the configured set. Say nothing.
        case ready
        /// Ready, AND Conduck moved the pointer here itself because this was the
        /// only gateway that could send. Informational, never a finding.
        case autoAdopted
        /// A pointer is stored, it cannot send, and the roster offers alternatives.
        /// THE reported bug.
        case broken
        /// No pointer is stored and the device cannot honestly infer one. Not a
        /// repair, not an accusation — a question only the user can answer.
        case notChosen
    }
    let kind: Kind
    /// The default gateway's display name. Empty under `.notChosen`, where there
    /// is no gateway to name — the copy for that case names none.
    let defaultName: String
    /// The projected default ref. Under `.notChosen` this is the built-in
    /// compatibility fallback and MUST NOT be treated as a user choice.
    let defaultRef: RemoteAgentRef
    /// Every gateway that CAN send, in Connection row order — the Fix sheet's menu.
    let candidates: [GatewayDisplayEntry]
    /// For `.autoAdopted`: the gateway that was replaced, named from the adoption
    /// notice's captured name (the replaced gateway may be a custom that is gone).
    let replacedName: String?
    /// `.broken` and `.notChosen` are the two states whose only exit is the user
    /// picking a gateway — the two that earn the "Choose Gateway" button.
    var offersFix: Bool { kind == .broken || kind == .notChosen }
}

/// A privacy-safe pointer to a failure that a "Troubleshoot" affordance opens
/// the Diagnostics screen focused on. Carries ONLY an `AppError` numeric code +
/// the (internal, non-identifying) gateway ref — never a message, URL, model,
/// key, or path. The failable init is the ONE filter that decides whether a
/// Troubleshoot affordance appears: it returns `nil` for errors Diagnostics
/// can't help with (`AppError.isTroubleshootable == false`) and for a nil code
/// (a plain notice, e.g. a dropped attachment). Every error surface builds its
/// focus through this init, so the "when does Troubleshoot show?" rule lives in
/// exactly one place.
struct DiagnosticsFocus: Equatable {
    let errorCode: Int
    let ref: RemoteAgentRef?

    init?(errorCode: Int?, ref: RemoteAgentRef?) {
        guard let errorCode,
              AppError.from(errorCode: errorCode, message: nil).isTroubleshootable else {
            return nil
        }
        self.errorCode = errorCode
        self.ref = ref
    }
}

// MARK: - Watch health query (phone → watch `diagnostics-pull`)

/// Tolerantly-decoded reply of the phone → watch `diagnostics-pull` message.
/// Every field is Optional — a missing/mistyped key decodes to nil (an older
/// Watch build simply omits keys it doesn't know), NEVER a decode failure.
/// `nonisolated`: constructed inside the WCSession replyHandler on the
/// framework's queue (the `SendablePlistPayload` posture — decode into a
/// `Sendable` value AT the transport boundary; the raw `[String: Any]` never
/// crosses an isolation boundary).
nonisolated struct WatchHealthWireReply: Sendable, Equatable {
    let version: Int?
    let appVersion: String?
    let appBuild: String?
    let osVersion: String?
    let sttEnvelopeTs: Double?
    let agentEnvelopeTs: Double?
    let relayQueueDepth: Int?
    let micPermission: String?
    let notificationPermission: String?
    let companionReachable: Bool?

    init(dict: [String: Any]) {
        typealias Key = Constants.WatchDiagnosticsReplyKey
        version = dict[Key.version] as? Int
        appVersion = dict[Key.appVersion] as? String
        appBuild = dict[Key.appBuild] as? String
        osVersion = dict[Key.osVersion] as? String
        sttEnvelopeTs = dict[Key.sttEnvelopeTs] as? Double
        agentEnvelopeTs = dict[Key.agentEnvelopeTs] as? Double
        relayQueueDepth = dict[Key.relayQueueDepth] as? Int
        micPermission = dict[Key.micPermission] as? String
        notificationPermission = dict[Key.notificationPermission] as? String
        companionReachable = dict[Key.companionReachable] as? Bool
    }
}

/// The Watch's settings-courier standing, derived by comparing the Watch's
/// PERSISTED agent-envelope high-water against the newest envelope timestamp
/// the phone ever assembled for the wrist. Deliberately narrow: the phone
/// re-mints a timestamp on EVERY assembly (even for identical settings) and
/// the Watch's STT high-water is in-memory (resets on relaunch), so the
/// verdict compares ONLY the persisted agent high-water and the UI reports
/// observationally ("last accepted <relative>", "N updates queued") — never
/// a bald "settings are up to date" claim.
enum WatchSettingsFreshness: String, Sendable, Equatable {
    /// Watch accepted the newest envelope the phone has minted.
    case current
    /// The phone has minted a newer envelope than the Watch has accepted
    /// (usually: queued couriers waiting for the wrist to wake).
    case behind
    /// The Watch has never accepted a remote-agent envelope.
    case never
    /// No basis to compare (the phone never assembled one, or the Watch
    /// omitted the field).
    case unknown
}

/// Why the watch health query produced no report.
enum WatchHealthNoResponseReason: Sendable, Equatable {
    /// The query hit the phone-side deadline with no reply.
    case timedOut
    /// WCSession's errorHandler fired (unreachable / old Watch build without
    /// the responder / transport failure). Carries the `WCError` numeric code —
    /// an allowlist-safe primitive for the copy block, never message text.
    case transportError(code: Int)
}

/// Outcome of the most recent watch health query. Held OUTSIDE `checks` (the
/// `fileLanes` pattern) — it survives `refreshConfig()` rebuilds by
/// construction and never reaches `copyBlock()`'s per-check lines except as
/// the dedicated allowlisted facts.
enum WatchHealthQueryOutcome: Sendable, Equatable {
    /// A versioned reply arrived — the decoded facts.
    case reply(WatchHealthState)
    /// A reply arrived WITHOUT `diag.v` (an empty `[:]` from a build that
    /// doesn't know the kind) — not a health report.
    case unsupported
    case noResponse(WatchHealthNoResponseReason)
}

/// Display state for the Watch health sub-block — the decoded reply facts
/// plus the freshness verdict computed against the phone-side envelope stamp.
struct WatchHealthState: Sendable, Equatable {
    let appVersion: String?
    let appBuild: String?
    let osVersion: String?
    /// The Watch's persisted agent-envelope high-water (0 = never).
    let agentEnvelopeTs: Double
    let settingsFreshness: WatchSettingsFreshness
    let relayQueueDepth: Int?
    /// Enum-name strings from the Watch's own permission reads (nil = the
    /// Watch omitted the field — older build).
    let micPermission: String?
    let notificationPermission: String?
    let receivedAt: Date

    /// Amber facts the summary's attention count must include (a green
    /// "Checks passed" must not sit above a visible denied-permission line).
    var attentionCount: Int {
        var count = 0
        if micPermission == "denied" { count += 1 }
        if notificationPermission == "denied" { count += 1 }
        return count
    }

    /// Derive the freshness verdict. Pure — unit-tested directly.
    /// `watchAgentTs` = the Watch's persisted high-water (0 = never accepted);
    /// `phoneAgentTs` = the newest envelope ts the phone assembled (0 = never
    /// assembled one / unknown).
    static func settingsFreshness(watchAgentTs: Double, phoneAgentTs: Double) -> WatchSettingsFreshness {
        if watchAgentTs <= 0 { return .never }
        guard phoneAgentTs > 0 else { return .unknown }
        return watchAgentTs >= phoneAgentTs ? .current : .behind
    }
}

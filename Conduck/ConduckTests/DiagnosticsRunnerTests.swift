// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticsRunnerTests.swift
//
// Guardrail coverage for the Diagnostics orchestrator: the copyable report is
// paste-safe (no URL/token/key material AND no provider names), opening the
// screen never fires the network connection checks, the banner deep-link
// resolves a plain-English explanation, and the LIVE config re-derive
// (`refreshConfig`) reflects a provider switch without a relaunch while leaving
// the locked layout untouched when nothing changed.
//
// Isolation: the active-STT pointer is a non-secret App-Group + KVS value, so
// setUp/tearDown wipe it (the runner reads the `SettingsManager.shared`
// singleton). No Keychain writes → runs on the unsigned sim.

import XCTest
@testable import Conduck

@MainActor
final class DiagnosticsRunnerTests: XCTestCase {

    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    override func setUp() async throws {
        try await super.setUp()
        wipeVoiceSettings()
    }

    override func tearDown() async throws {
        wipeVoiceSettings()
        try await super.tearDown()
    }

    /// Reset the active STT + TTS pointers to the fresh-install default (Apple)
    /// so every test starts from a known provider. Wipes both stores the dual-write
    /// setters touch (KVS is inert on the unsigned sim, wiped anyway for the signed
    /// founder-gate run).
    private func wipeVoiceSettings() {
        for key in [Constants.sttActivePresetIDKVSKey, Constants.ttsActiveProviderIDKVSKey] {
            defaults.removeObject(forKey: key)
            NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
        }
    }

    // MARK: - Paste-safety

    /// After the local auto-reads run, the copy block must contain no URL, host,
    /// bearer header, or key material. The builder composes only from allowlisted
    /// primitives, so a regression that piped a secret in would trip a needle.
    func testCopyBlockNeverLeaksSecrets() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let block = runner.copyBlock()

        XCTAssertFalse(block.isEmpty, "copy block should never be empty")
        for needle in ["http", "://", "Bearer "] {
            XCTAssertFalse(block.contains(needle), "copy block leaked '\(needle)':\n\(block)")
        }
    }

    /// The "Active setup" provider names live OUTSIDE `checks`, so the copy block
    /// must NOT carry the setup-row titles — the guard that a future refactor
    /// folding the setup rows into `checks` (and thus leaking a user-named custom
    /// endpoint) is caught. The provider archetype still travels via `STT:`/`TTS:`.
    func testCopyBlockOmitsActiveSetupRows() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let block = runner.copyBlock()
        XCTAssertFalse(block.contains("Speech-to-Text"),
                       "copy block must not carry the Active-setup row (allowlist):\n\(block)")
        XCTAssertFalse(block.contains("Text-to-Speech"),
                       "copy block must not carry the Active-setup row (allowlist):\n\(block)")
        XCTAssertTrue(block.contains("STT:") && block.contains("TTS:"),
                      "copy block must still carry the sanitized STT/TTS archetype:\n\(block)")
    }

    /// The permission line must carry the `Notif:` token — a denied notification
    /// permission is the silent single point of failure for every headless
    /// feedback path, so its status has to travel in the support report.
    func testCopyBlockIncludesNotifToken() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let block = runner.copyBlock()
        XCTAssertTrue(block.contains("Notif:"),
                      "copy block must include the notification-permission token:\n\(block)")
    }

    // MARK: - Auto-run guardrails

    /// Opening the screen (auto-reads) must NOT run the network connection checks —
    /// those fire only on the explicit "Test connections" tap.
    func testAutoReadsDoesNotRunConnectionChecks() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        XCTAssertFalse(runner.connectionChecksHaveRun,
                       "auto-reads must not run the network connection checks")
        XCTAssertNil(runner.lastChecked,
                     "lastChecked is stamped only by the explicit connection checks")
    }

    /// SwiftUI attaches the auto-read `.task` to a `Group`, which fans out to every
    /// child section — so `runAutoReads()` must be idempotent (a second call is a
    /// no-op) or it would re-seed the checklist and thrash on every section mount.
    func testRunAutoReadsIsIdempotent() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let firstCount = runner.checks.count
        await runner.runAutoReads()   // second call must early-return (run-once)
        XCTAssertEqual(runner.checks.count, firstCount,
                       "runAutoReads must run once; a repeat call must not re-seed checks")
        XCTAssertFalse(runner.connectionChecksHaveRun)
    }

    // MARK: - Banner deep-link

    /// A runner constructed with a focused error code exposes a non-empty
    /// plain-English explanation for it (drives the focused card).
    func testFocusedErrorCodeYieldsExplanation() {
        // 26 = remoteAgentAuthFailed (a config-fixable code).
        let runner = DiagnosticsRunner(focusedRef: nil, focusedErrorCode: 26)
        XCTAssertNotNil(runner.focusedExplanation)
        XCTAssertFalse(runner.focusedExplanation?.cause.isEmpty ?? true)
        XCTAssertFalse(runner.focusedExplanation?.fix.isEmpty ?? true)
    }

    /// No focus → no focused card.
    func testNoFocusYieldsNoExplanation() {
        let runner = DiagnosticsRunner()
        XCTAssertNil(runner.focusedExplanation)
    }

    // MARK: - Active setup + speech-row gating (Apple default)

    /// With a voice provider configured, the "Active setup" block names both active
    /// providers using the SAME source of truth as the Voice Setup screen (cloud STT
    /// makes the Voice section visible; TTS stays the Apple default here).
    func testActiveSetupNamesActiveProviders() async {
        await SettingsManager.shared.setActivePresetID("openai-gpt4o-transcribe")
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let setup = runner.activeVoiceSetup
        XCTAssertNotNil(setup, "a configured voice setup must populate the Active-setup block")
        XCTAssertEqual(setup?.sttName, "OpenAI", "the STT name must match the active provider")
        XCTAssertEqual(setup?.ttsName, "Apple", "default TTS is Apple")
    }

    /// A cloud provider with no key must surface as a setup `.warning`. This is the
    /// summary's ONLY coverage for TTS (unlike STT, TTS has no probe row), so if this
    /// regresses the summary would show a green "Checks passed" over an amber row.
    func testCloudProviderMissingKeyIsSetupWarning() async {
        await SettingsManager.shared.setActiveTTSProviderID("openai-tts")   // cloud TTS, no key
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        XCTAssertEqual(runner.activeVoiceSetup?.ttsStatus, .warning,
                       "a cloud provider with no key is a setup warning")
    }

    /// Apple on-device STT: the Speech-recognition row applies (it's the on-device
    /// permission) and the cloud key-probe row does NOT (there's no cloud key).
    func testSpeechRowPresentAndKeyRowAbsentForAppleSTT() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let ids = Set(runner.checks.map(\.id))
        XCTAssertTrue(ids.contains("voice.speech.permission"),
                      "Apple on-device STT ⇒ the speech-recognition row applies")
        // Spec: Mic + Speech stay in VOICE — every prerequisite for
        // recording/transcription sits beside the functional test.
        XCTAssertEqual(runner.checks.first(where: { $0.id == "voice.mic.permission" })?.category, .voice)
        XCTAssertEqual(runner.checks.first(where: { $0.id == "voice.speech.permission" })?.category, .voice)
        XCTAssertFalse(ids.contains("voice.stt.auth"),
                       "Apple on-device STT has no cloud key to probe ⇒ no key row")
    }

    // MARK: - Live config re-derive (the stale-Voice-section bug)

    /// The core regression (the founder's exact bug): switching the active STT
    /// provider must reflect in the Diagnostics Voice section WITHOUT a relaunch.
    /// A cloud TTS keeps the Voice section visible across the switch so the test
    /// isolates the STT re-derive. Cloud STT → the key-probe row + the "OpenAI"
    /// name; switching to Apple on-device → the on-device speech row + "Apple".
    func testRefreshConfigReDerivesVoiceOnProviderSwitch() async {
        await SettingsManager.shared.setActiveTTSProviderID("openai-tts")   // keeps Voice visible throughout
        await SettingsManager.shared.setActivePresetID("openai-gpt4o-transcribe")

        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        XCTAssertEqual(runner.activeVoiceSetup?.sttName, "OpenAI")
        XCTAssertEqual(runner.activeVoiceSetup?.sttStatus, .warning,
                       "a cloud provider with no key is a config warning")
        var ids = Set(runner.checks.map(\.id))
        XCTAssertTrue(ids.contains("voice.stt.auth"), "cloud STT ⇒ the key-probe row")
        XCTAssertFalse(ids.contains("voice.speech.permission"), "cloud STT ⇒ no on-device speech row")

        // Switch to Apple on-device STT (the founder's action) and re-derive.
        await SettingsManager.shared.setActivePresetID("apple-on-device")
        await runner.refreshConfig()

        XCTAssertEqual(runner.activeVoiceSetup?.sttName, "Apple",
                       "the setup block must re-derive the newly-active provider — no relaunch")
        ids = Set(runner.checks.map(\.id))
        XCTAssertTrue(ids.contains("voice.speech.permission"),
                      "Apple on-device STT ⇒ the speech-recognition row appears")
        XCTAssertFalse(ids.contains("voice.stt.auth"),
                       "Apple on-device STT ⇒ the cloud key-probe row disappears")
    }

    /// Layout-lock guardrail: with the config UNCHANGED, `refreshConfig()` rebuilds
    /// the checklist to an identical structure — same row count, same section
    /// flags — so the amber Copy button never travels (the flicker the phase-1/
    /// phase-2 split exists to prevent).
    func testRefreshConfigPreservesLayoutWhenConfigUnchanged() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()

        let idsBefore = runner.checks.map(\.id)
        let voiceBefore = runner.showsVoiceSection
        let syncBefore  = runner.showsSyncSection
        let capabilityBefore = runner.showsCapabilitySection
        XCTAssertGreaterThan(idsBefore.count, 0,
                             "runAutoReads should seed a non-empty checklist (else the invariant is vacuous)")

        await runner.refreshConfig()   // no config change ⇒ identical rebuild

        XCTAssertEqual(runner.checks.map(\.id), idsBefore,
                       "an unchanged-config refresh must rebuild the same rows in the same order")
        XCTAssertEqual(runner.showsVoiceSection, voiceBefore,
                       "an unchanged-config refresh must not flip section visibility (voice)")
        XCTAssertEqual(runner.showsSyncSection, syncBefore,
                       "an unchanged-config refresh must not flip section visibility (sync)")
        XCTAssertEqual(runner.showsCapabilitySection, capabilityBefore,
                       "an unchanged-config refresh must not flip section visibility (capabilities)")
    }

    // MARK: - v1.3: no-send-able-gateway row

    /// The "No Personal AI configured" row appears EXACTLY when
    /// `configuredRemoteAgentRefs()` is empty — making the all-green-but-broken
    /// Connection section honest (and catching cross-device token skew, since the
    /// refs set is fail-closed). Invariant-based so it's robust to whatever gateway
    /// state the sim happens to carry.
    func testGatewayNoneRowAppearsIffNoConfiguredGateway() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let refs = await SettingsManager.shared.configuredRemoteAgentRefs()
        let hasNoneRow = runner.checks.contains { $0.id == "connection.gateway.none" }
        XCTAssertEqual(hasNoneRow, refs.isEmpty,
                       "the 'no Personal AI' row appears exactly when no gateway is configured")
    }

    // MARK: - v1.3: mic-visibility fix (pure gate)

    /// Permission-row actions must match Apple's TCC contract: only an
    /// undetermined grant can prompt; a denial must route to Settings; managed
    /// restrictions and unknown states cannot offer a misleading repair button.
    func testPermissionStateActionAndStatusMatrix() {
        XCTAssertEqual(DiagnosticPermissionState.notRequested.action, .allow)
        XCTAssertEqual(DiagnosticPermissionState.denied.action, .openSettings)
        XCTAssertNil(DiagnosticPermissionState.allowed.action)
        XCTAssertNil(DiagnosticPermissionState.restricted.action)
        XCTAssertNil(DiagnosticPermissionState.unknown.action)

        XCTAssertEqual(
            DiagnosticPermissionState.notRequested.diagnosticStatus(failureCode: nil),
            .notRun,
            "a permission the user has never requested is neutral, not an attention item"
        )
        XCTAssertEqual(
            DiagnosticPermissionState.denied.diagnosticStatus(failureCode: 51),
            .failed(code: 51),
            "a denied applicable permission is a real failed diagnostic"
        )
        XCTAssertEqual(
            DiagnosticPermissionState.restricted.diagnosticStatus(failureCode: 51),
            .failed(code: 51),
            "a managed restriction still blocks the capability even though no button can repair it"
        )

        XCTAssertEqual(
            DiagnosticsRunner.notificationDiagnosticStatus(
                permissionState: .notRequested,
                alertsSuppressed: false
            ),
            .notRun,
            "unrequested notifications cannot claim a green pass"
        )
        XCTAssertEqual(
            DiagnosticsRunner.notificationDiagnosticAction(
                permissionState: .notRequested,
                alertsSuppressed: false
            ),
            .allow
        )
        XCTAssertEqual(
            DiagnosticsRunner.notificationDiagnosticAction(
                permissionState: .allowed,
                alertsSuppressed: true
            ),
            .openSettings,
            "authorized-but-silent notifications need Settings repair"
        )
    }

    /// The bug this fixes: the fresh Apple-STT user with no keys who taps "Don't
    /// Allow" on mic must SEE the Voice section (else the red mic row is hidden).
    /// `.undetermined` stays hidden (no nagging a user who never asked).
    func testVoiceSectionRevealedByDeniedMicNotByUndetermined() {
        // Fresh Apple install, mic UNDETERMINED → hidden.
        XCTAssertFalse(DiagnosticsRunner.shouldShowVoiceSection(
            hasStoredKeys: false, sttInProcess: true, ttsIsApple: true,
            micGranted: false, micDenied: false, speechDeniedOrRestricted: false),
            "a fresh Apple user who never touched voice sees no Voice section")
        // Same user taps "Don't Allow" → VISIBLE (the fix).
        XCTAssertTrue(DiagnosticsRunner.shouldShowVoiceSection(
            hasStoredKeys: false, sttInProcess: true, ttsIsApple: true,
            micGranted: false, micDenied: true, speechDeniedOrRestricted: false),
            "a denied mic must reveal the Voice section")
        // Apple-speech denied/restricted likewise reveals it.
        XCTAssertTrue(DiagnosticsRunner.shouldShowVoiceSection(
            hasStoredKeys: false, sttInProcess: true, ttsIsApple: true,
            micGranted: false, micDenied: false, speechDeniedOrRestricted: true),
            "denied speech recognition must reveal the Voice section")
        // A configured cloud STT shows it regardless of mic (existing behavior).
        XCTAssertTrue(DiagnosticsRunner.shouldShowVoiceSection(
            hasStoredKeys: true, sttInProcess: false, ttsIsApple: true,
            micGranted: false, micDenied: false, speechDeniedOrRestricted: false))
    }

    // MARK: - v1.3: per-gateway file lanes

    /// The founder's ask: a file server is PER gateway. A file-capable gateway
    /// (OpenClaw) fans out to its OWN file lane; a non-file-capable one (OpenRouter)
    /// does not. Uses a KEYLESS gateway (URL + `.none` scheme) so no Keychain write
    /// is needed on the unsigned sim. Saves + restores prior gateway state so the
    /// sim isn't left mutated.
    func testFileLaneFansOutPerFileCapableGateway() async {
        let ref = RemoteAgentRef.builtin(.openclaw)
        let priorURL = await SettingsManager.shared.getRemoteAgentURL(for: ref)
        let priorScheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: ref)

        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: ref)   // keyless → no Keychain
        await SettingsManager.shared.setRemoteAgentURL(URL(string: "https://openclaw.example.test")!, for: ref)

        let runner = DiagnosticsRunner()
        await runner.runAutoReads()

        let openclawLane = runner.fileLanes.first { $0.ref == ref }
        XCTAssertNotNil(openclawLane, "a file-capable gateway (OpenClaw) fans out to its own file lane")
        XCTAssertEqual(openclawLane?.configured, false, "no file server set → configured == false (neutral, not a warning)")
        XCTAssertEqual(openclawLane?.writeVerified, false, "a config/reach read never sets writeVerified")
        XCTAssertFalse(runner.fileLanes.contains { $0.ref == .builtin(.openrouter) },
                       "OpenRouter is not file-capable → no file lane")
        XCTAssertTrue(runner.gatewayDisplayOrder.contains { $0.ref == ref },
                      "the file-capable gateway has a display entry, so its file lane renders nested under it in Connection")

        // Restore prior state (URL nil-safe; scheme back to its prior value).
        await SettingsManager.shared.setRemoteAgentURL(priorURL, for: ref)
        await SettingsManager.shared.setRemoteAgentAuthScheme(priorScheme, for: ref)
    }

    /// The reach probe never produces `reachAuth == .passed` (it tops out at
    /// `.warning` — a ranged GET can't prove uploads work); only the staged
    /// write test sets `.passed`, always together with `writeVerified`. The
    /// badge folds an out-of-band `.passed` to `.verified` so it can never
    /// render weaker than the state that produced it, and a reach-OK lane
    /// derives the amber `.unconfirmed` without registering as verified.
    func testFileLaneReachStatesDeriveHonestBadges() {
        let reachOK = FileLaneState(
            ref: .builtin(.openclaw), displayName: "OpenClaw gateway", backendKind: "openclaw",
            configured: true, reachAuth: .warning, writeVerified: false, detail: nil)
        XCTAssertEqual(reachOK.badge, .unconfirmed, "reach-OK is 'Unconfirmed' until the write test verifies")
        XCTAssertTrue(reachOK.needsAttention)

        let passed = FileLaneState(
            ref: .builtin(.openclaw), displayName: "OpenClaw gateway", backendKind: "openclaw",
            configured: true, reachAuth: .passed, writeVerified: false, detail: nil)
        XCTAssertEqual(passed.badge, .verified, "`.passed` exists only via the write test — folds to verified")
        XCTAssertFalse(passed.needsAttention)
    }

    /// The code-review HIGH finding: a lane VERIFIED in a past session
    /// (`writeVerified == true`) whose reach probe now FAILS must show `.failed`
    /// (and register attention) — the fresh failure must override the stale green,
    /// else the summary reads "Checks passed" over a broken file host.
    func testFileLaneFreshFailureOverridesStaleVerified() {
        let failed = FileLaneState(
            ref: .builtin(.openclaw), displayName: "OpenClaw gateway", backendKind: "openclaw",
            configured: true, reachAuth: .failed(code: 46), writeVerified: true, detail: nil)
        XCTAssertEqual(failed.badge, .failed, "a fresh reach failure overrides a stale writeVerified flag")
        XCTAssertTrue(failed.needsAttention, "the summary must count a now-broken previously-verified lane")

        let unconfirmed = FileLaneState(
            ref: .builtin(.openclaw), displayName: "OpenClaw gateway", backendKind: "openclaw",
            configured: true, reachAuth: .warning, writeVerified: true, detail: nil)
        XCTAssertEqual(unconfirmed.badge, .unconfirmed)
        XCTAssertTrue(unconfirmed.needsAttention)
    }

    /// The neutral states stay neutral (no attention): a verified lane at rest, a
    /// configured-but-untested lane, and an unconfigured file-capable gateway.
    func testFileLaneNeutralStatesDoNotRegisterAttention() {
        let verified = FileLaneState(ref: .builtin(.openclaw), displayName: "x", backendKind: "openclaw",
            configured: true, reachAuth: .notRun, writeVerified: true, detail: nil)
        XCTAssertEqual(verified.badge, .verified)
        XCTAssertFalse(verified.needsAttention)

        let configured = FileLaneState(ref: .builtin(.openclaw), displayName: "x", backendKind: "openclaw",
            configured: true, reachAuth: .notRun, writeVerified: false, detail: nil)
        XCTAssertEqual(configured.badge, .configuredNotTested)
        XCTAssertFalse(configured.needsAttention)

        let notSetUp = FileLaneState(ref: .builtin(.openclaw), displayName: "x", backendKind: "openclaw",
            configured: false, reachAuth: .notRun, writeVerified: false, detail: nil)
        XCTAssertEqual(notSetUp.badge, .notSetUp)
        XCTAssertFalse(notSetUp.needsAttention, "an unconfigured file-capable gateway is NEUTRAL, not a warning")
    }

    // MARK: - "Test everything" — which file lanes get the write test

    /// `runAllTests()` writes to EVERY configured file lane regardless of the
    /// sweep's reach state (the write test self-stages its own reachability), and
    /// skips the not-set-up lanes (nothing to write to). No preflight gate on
    /// `reachAuth == .passed` — that would false-skip a `.warning`/keyless lane,
    /// which is exactly the ambiguous lane the write test exists to resolve.
    func testLanesToWriteReturnsEveryConfiguredLane() {
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        let custom1 = RemoteAgentRef.custom(UUID())
        let custom2 = RemoteAgentRef.custom(UUID())
        let hermes = RemoteAgentRef.builtin(.hermes)   // configured: false below

        let lanes = [
            FileLaneState(ref: openclaw, displayName: "OpenClaw gateway", backendKind: "openclaw",
                          configured: true, reachAuth: .passed, writeVerified: false, detail: nil),
            FileLaneState(ref: custom1, displayName: "LiteLLM", backendKind: "custom",
                          configured: true, reachAuth: .warning, writeVerified: false, detail: nil),
            FileLaneState(ref: custom2, displayName: "Other", backendKind: "custom",
                          configured: true, reachAuth: .failed(code: 46), writeVerified: false, detail: nil),
            FileLaneState(ref: hermes, displayName: "Hermes gateway", backendKind: "hermes",
                          configured: false, reachAuth: .notRun, writeVerified: false, detail: nil),
        ]

        let refs = DiagnosticsRunner.lanesToWrite(lanes)
        XCTAssertEqual(refs, [openclaw, custom1, custom2],
                       "every configured lane (passed/warning/failed alike) is written, in order")
        XCTAssertFalse(refs.contains(hermes), "the not-set-up lane has nothing to write to")
    }

    // MARK: - v1.3: copy block still safe with the new facts

    /// The copy block carries the new per-lane file facts + the capability facts
    /// line + the Phase-D silent-failure facts, and STILL leaks no URL / host /
    /// token / custom-gateway raw prefix.
    func testCopyBlockCarriesNewFactsAndStaysSafe() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let block = runner.copyBlock()
        XCTAssertTrue(block.contains("File lanes:") || block.contains("file["),
                      "copy block carries the per-lane file facts:\n\(block)")
        XCTAssertTrue(block.contains("BgRefresh:"),
                      "copy block carries the capability facts line:\n\(block)")
        XCTAssertTrue(block.contains("Camera:"),
                      "copy block carries the camera permission fact:\n\(block)")
        XCTAssertTrue(block.contains("partial="),
                      "copy block carries the partially-configured gateway count:\n\(block)")
        XCTAssertTrue(block.contains("ShareInbox:") && block.contains("PendingRetry:") && block.contains("Storage:"),
                      "copy block carries the silent-failure facts line:\n\(block)")
        for needle in ["http", "://", "Bearer ", "custom_"] {
            XCTAssertFalse(block.contains(needle), "copy block leaked '\(needle)':\n\(block)")
        }
    }

    /// The partial-config row appears EXACTLY when the fail-closed configured
    /// set dropped a URL-bearing ref (no focus in play here, so the row's count
    /// and the settings query agree 1:1). Invariant-based like the gateway-none
    /// test — robust to whatever gateway state the sim carries.
    func testPartialGatewayRowMatchesSettingsQuery() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let partial = await SettingsManager.shared.partiallyConfiguredRemoteAgentRefs()
        let hasRow = runner.checks.contains { $0.id == "connection.gateway.partial" }
        XCTAssertEqual(hasRow, !partial.isEmpty,
                       "the partial-gateway row appears exactly when a URL-without-key ref exists")
    }

    /// Code-review HIGH catch: a fixed-endpoint (hosted-model) built-in's URL
    /// is app-fixed, so URL presence is NOT user evidence — an UNTOUCHED
    /// OpenRouter (no stored token, no stored model) must never read as
    /// "partially configured", else every fresh install shows a permanent
    /// amber "Gateway missing its key" row.
    func testUntouchedFixedEndpointGatewayIsNeverPartial() async throws {
        let ref = RemoteAgentRef.builtin(.openrouter)
        let token = await SettingsManager.shared.getRemoteAgentToken(for: ref)
        let model = await SettingsManager.shared.getRemoteAgentModel(for: ref)
        guard (token ?? "").isEmpty, (model ?? "").isEmpty else {
            throw XCTSkip("sim carries OpenRouter state — the untouched invariant doesn't apply")
        }
        let partial = await SettingsManager.shared.partiallyConfiguredRemoteAgentRefs()
        XCTAssertFalse(partial.contains(ref),
                       "an untouched fixed-endpoint built-in must never be 'partial'")
    }

    // MARK: - v1.4: per-gateway Connection display order + capabilities regroup

    /// `gatewayDisplayOrder` covers EXACTLY the configured gateways (so a
    /// non-file-capable gateway still gets a Connection row) AND every `fileLanes`
    /// entry has a matching display entry (Codex catch — a lane can never
    /// render-hide while `attentionCount` still counts it). The lane set is a strict
    /// subset of the display order (file-capable gateways only). Keyless ref (no
    /// Keychain) + save/restore.
    func testGatewayDisplayOrderCoversConfiguredGatewaysAndOwnsEveryLane() async {
        let openclaw = RemoteAgentRef.builtin(.openclaw)
        let priorURL = await SettingsManager.shared.getRemoteAgentURL(for: openclaw)
        let priorScheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: openclaw)
        await SettingsManager.shared.setRemoteAgentAuthScheme(.none, for: openclaw)   // keyless → no Keychain
        await SettingsManager.shared.setRemoteAgentURL(URL(string: "https://openclaw.example.test")!, for: openclaw)

        let runner = DiagnosticsRunner()
        await runner.runAutoReads()

        let configured = await SettingsManager.shared.configuredRemoteAgentRefs()
        let orderRefs = Set(runner.gatewayDisplayOrder.map(\.ref))
        // The display order is EXACTLY the configured refs — so any configured
        // gateway, file-capable or not, gets a Connection row.
        XCTAssertEqual(orderRefs, Set(configured),
                       "the display order covers exactly the configured gateways (file-capable or not)")
        XCTAssertTrue(orderRefs.contains(openclaw),
                      "a configured gateway appears in the display order")
        // Every file lane's gateway has a display entry (completeness), and the lane
        // set is a subset (file-capable only — OpenRouter is excluded).
        XCTAssertTrue(Set(runner.fileLanes.map(\.ref)).isSubset(of: orderRefs),
                      "every file lane must have a gateway display entry")
        XCTAssertTrue(runner.fileLanes.contains { $0.ref == openclaw },
                      "a file-capable configured gateway fans out to a lane")
        XCTAssertFalse(runner.fileLanes.contains { $0.ref == .builtin(.openrouter) },
                       "OpenRouter is not file-capable → never a file lane")
        for entry in runner.gatewayDisplayOrder {
            XCTAssertTrue(runner.checks.contains { $0.id == entry.connectionCheckID },
                          "every gateway display entry must pair to a live connection check")
        }

        await SettingsManager.shared.setRemoteAgentURL(priorURL, for: openclaw)
        await SettingsManager.shared.setRemoteAgentAuthScheme(priorScheme, for: openclaw)
    }

    /// The numbered fallback ("Custom gateway N") uses the CANONICAL config-order
    /// ordinal (the SAME `N` the copy block's `custom-gateway#N` uses), and a named
    /// custom shows its real name. Pure — no sim gateway config.
    func testCustomGatewayNameAndNumberedFallbackUseCanonicalOrdinal() {
        let id1 = UUID(), id2 = UUID()
        let ref1 = RemoteAgentRef.custom(id1)
        let ref2 = RemoteAgentRef.custom(id2)
        // Ordinals are config/input order — independent of the focused/active sort.
        let ordinals = DiagnosticsRunner.customOrdinals([.builtin(.openclaw), ref1, ref2])
        XCTAssertEqual(ordinals[ref1], 1)
        XCTAssertEqual(ordinals[ref2], 2)

        // Named custom → real name.
        XCTAssertEqual(
            DiagnosticsRunner.gatewayDisplayName(ref1, customGateways: [CustomGateway(id: id1, name: "LiteLLM")], ordinal: 1),
            "LiteLLM")
        // Missing roster name → the numbered fallback with the canonical N.
        XCTAssertEqual(
            DiagnosticsRunner.gatewayDisplayName(ref2, customGateways: [], ordinal: ordinals[ref2]),
            "Custom gateway 2", "an unnamed custom falls back to its canonical ordinal")
        // Whitespace-only name → numbered fallback too.
        XCTAssertEqual(
            DiagnosticsRunner.gatewayDisplayName(ref2, customGateways: [CustomGateway(id: id2, name: "   ")], ordinal: 2),
            "Custom gateway 2", "a whitespace-only name falls back to the numbered form")
        // A built-in never uses the fallback.
        XCTAssertEqual(
            DiagnosticsRunner.gatewayDisplayName(.builtin(.openclaw), customGateways: [], ordinal: nil),
            "OpenClaw gateway")
    }

    /// Notifications is the standing OS capability row. Background App Refresh
    /// is deliberately copy-block-only: Conduck uses background URLSession, so
    /// the broad system setting cannot honestly certify user-facing readiness.
    func testNotificationsIsCapabilityAndBackgroundRefreshIsNotVisible() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()

        let notif = runner.checks.first { $0.id == "connection.notifications" }
        XCTAssertNotNil(notif, "the notifications check is always built")
        XCTAssertEqual(notif?.category, .capability,
                       "Notifications is grouped under Capabilities, not Connection")
        XCTAssertFalse(runner.checks.contains { $0.id == "connection.backgroundRefresh" },
                       "Background App Refresh must not render as a user-facing pass/fail row")
        XCTAssertTrue(runner.showsCapabilitySection,
                      "the Capabilities section is standing (Notifications always present)")
        XCTAssertFalse(runner.checks.contains { $0.category == .connection && $0.id == "connection.notifications" },
                       "no Connection check may carry the moved-out notifications id")
    }

    // MARK: - Recent failed sends → the copy block (redaction by construction)

    private func failedTurn(
        code: Int? = 19,
        wire: String? = nil,
        device: String? = "phone",
        backend: String?,
        ageSeconds: TimeInterval = 60
    ) -> ConversationStore.FailedTurnSummary {
        ConversationStore.FailedTurnSummary(
            failureCode: code,
            failureWireCode: wire,
            sourceDevice: device,
            backend: backend,
            createdAt: Date().addingTimeInterval(-ageSeconds)
        )
    }

    /// A custom gateway is named by its CANONICAL config-order ordinal, never by
    /// the `custom_<uuid>` the conversation actually stores. The ordinal is shared
    /// with the on-screen "Custom gateway N" so the report and the screen can't
    /// disagree.
    func testCustomGatewayFailureCarriesTheOrdinalNotTheUUID() {
        let uuid = UUID()
        let ref = RemoteAgentRef.custom(uuid)
        let facts = DiagnosticsRunner.redactFailedSends(
            [failedTurn(backend: ref.rawString)],
            customOrdinals: [ref: 2]
        )
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.backendToken, "custom-gateway#2")
        XCTAssertFalse(facts.first!.backendToken.contains(uuid.uuidString),
                       "a gateway UUID must never reach a report fact")
        XCTAssertFalse(facts.first!.backendToken.contains("custom_"),
                       "the raw ref prefix must not survive redaction")
    }

    /// A gateway the user has since DELETED has no ordinal. Say so — never fall
    /// back to the UUID, and never silently borrow another gateway's number.
    func testDeletedCustomGatewayIsAnonymousRatherThanIdentified() {
        let ref = RemoteAgentRef.custom(UUID())
        let facts = DiagnosticsRunner.redactFailedSends(
            [failedTurn(backend: ref.rawString)],
            customOrdinals: [:]
        )
        XCTAssertEqual(facts.first?.backendToken, "custom-gateway#?")
    }

    /// `failureWireCode` is server-supplied text. Only the FROZEN vocabulary may be
    /// echoed; anything else collapses to `other`, so a gateway cannot inject
    /// arbitrary content into a report the user pastes into a help request.
    func testUnknownWireCodeCollapsesInsteadOfEchoing() {
        let hostile = "https://evil.example/leak?token=abc123"
        let facts = DiagnosticsRunner.redactFailedSends(
            [failedTurn(wire: hostile, backend: RemoteAgentRef.builtin(.openclaw).rawString)],
            customOrdinals: [:]
        )
        XCTAssertEqual(facts.first?.wireToken, "other")
        for needle in ["http", "://", "evil.example", "abc123"] {
            XCTAssertFalse(facts.first!.wireToken.contains(needle),
                           "the report fact must not echo server text (\(needle))")
        }
    }

    func testFrozenWireCodeIsPreserved() {
        let facts = DiagnosticsRunner.redactFailedSends(
            [failedTurn(wire: "model_not_found", backend: RemoteAgentRef.builtin(.hermes).rawString)],
            customOrdinals: [:]
        )
        XCTAssertEqual(facts.first?.wireToken, "model_not_found")
        XCTAssertEqual(facts.first?.backendToken, "hermes",
                       "builtin raw values are a closed vocabulary, safe to name")
    }

    /// The `-text`/`-voice` modality suffix is dropped: the report says WHICH
    /// device, not how the user spoke to it.
    func testSourceDeviceReducesToItsBaseToken() {
        let facts = DiagnosticsRunner.redactFailedSends(
            [failedTurn(device: "watch-voice", backend: RemoteAgentRef.builtin(.openclaw).rawString)],
            customOrdinals: [:]
        )
        XCTAssertEqual(facts.first?.deviceToken, "watch")
    }

    /// The dedupe is load-bearing, not cosmetic. One broken gateway produces a run
    /// of identical failures; without collapsing them the newest-five would be five
    /// copies of one fact AND would hide a second gateway that is also failing —
    /// the exact case this section exists to expose.
    func testIdenticalRepeatsCollapseSoASecondGatewayStaysVisible() {
        let openclaw = RemoteAgentRef.builtin(.openclaw).rawString
        let hermes = RemoteAgentRef.builtin(.hermes).rawString
        var summaries: [ConversationStore.FailedTurnSummary] = []
        // Six retries against one gateway, newest first…
        for i in 0..<6 {
            summaries.append(failedTurn(backend: openclaw, ageSeconds: TimeInterval(i * 10)))
        }
        // …and one older failure on a DIFFERENT gateway, which must survive.
        summaries.append(failedTurn(code: 29, backend: hermes, ageSeconds: 5000))

        let facts = DiagnosticsRunner.redactFailedSends(summaries, customOrdinals: [:])
        XCTAssertEqual(facts.count, 2, "identical repeats collapse to one finding per gateway")
        XCTAssertEqual(facts.map(\.backendToken), ["openclaw", "hermes"],
                       "newest-first order survives the dedupe")
    }

    /// Different codes on the SAME gateway are different findings — collapsing
    /// those would hide a second, distinct fault.
    func testDifferentCodesOnOneGatewayStayDistinct() {
        let openclaw = RemoteAgentRef.builtin(.openclaw).rawString
        let facts = DiagnosticsRunner.redactFailedSends(
            [failedTurn(code: 19, backend: openclaw, ageSeconds: 10),
             failedTurn(code: 29, backend: openclaw, ageSeconds: 20)],
            customOrdinals: [:]
        )
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts.map(\.code), [19, 29])
    }

    func testEmittedFactsAreCappedAtFive() {
        let facts = DiagnosticsRunner.redactFailedSends(
            (0..<12).map { failedTurn(code: $0 + 1, backend: RemoteAgentRef.builtin(.openclaw).rawString, ageSeconds: TimeInterval($0)) },
            customOrdinals: [:]
        )
        XCTAssertEqual(facts.count, 5, "the report stays bounded")
        XCTAssertEqual(facts.first?.code, 1, "and keeps the NEWEST five")
    }

    /// A row whose backend is missing or unparseable still reports — an
    /// unattributed failure is worth knowing about — but names nothing it can't
    /// prove.
    func testUnparseableBackendIsReportedAsUnknown() {
        let facts = DiagnosticsRunner.redactFailedSends(
            [failedTurn(backend: "not-a-ref"), failedTurn(code: 20, backend: nil)],
            customOrdinals: [:]
        )
        XCTAssertEqual(facts.count, 2)
        XCTAssertTrue(facts.allSatisfy { $0.backendToken == "unknown" })
    }

    /// The whole report, end to end, with a hostile failure row present: the
    /// existing allowlist assertions must still hold with the new section in it.
    func testCopyBlockWithFailedSendsStaysPasteSafe() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let block = runner.copyBlock()
        for needle in ["http", "://", "Bearer ", "custom_"] {
            XCTAssertFalse(block.contains(needle),
                           "the copy block must not contain \(needle) — the failed-send section included")
        }
        XCTAssertTrue(block.contains("Recent failed sends:"),
                      "the section is unconditional: 'none' is itself a useful support fact")
    }

    // MARK: - Scoped per-gateway recheck

    /// A recheck of a gateway that isn't configured must be a clean no-op — no
    /// stamp, no row invented. The focused card gates on configured refs, but the
    /// runner must not depend on the view for that.
    func testRecheckOfAnUnconfiguredGatewayLeavesNoStamp() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        await runner.recheckGateway(for: .custom(UUID()))
        XCTAssertNil(runner.lastScopedGatewayCheck,
                     "an unconfigured ref has no snapshot to probe, so nothing may be stamped")
        XCTAssertFalse(runner.isBusy, "the in-flight set must be cleared on every exit path")
    }

    /// The scoped stamp must NOT masquerade as a full run: `lastChecked` is the
    /// whole-sweep stamp and a one-gateway probe may never move it.
    func testScopedRecheckNeverRestampsTheFullRun() async {
        let runner = DiagnosticsRunner()
        await runner.runAutoReads()
        let before = runner.lastChecked
        await runner.recheckGateway(for: .custom(UUID()))
        XCTAssertEqual(runner.lastChecked, before,
                       "a single-gateway probe must not claim freshness for rows nobody re-probed")
    }
}

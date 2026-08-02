// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsManager.swift
//
// Settings manager: reads/writes app configuration plus a Keychain
// reader/writer for the active STT preset's API key, with
// `kSecAttrAccessibleAfterFirstUnlock` (Watch ControlWidget cold-launch
// access requires key availability pre-unlock).
//
// API-shape note (preferredLanguage / activePresetID):
// Swift actors can't cleanly expose `var x: T { get set }` cross-actor
// (cross-actor property access can't be both async AND settable). This type
// exposes method pairs instead — implementation follows.
//
// Privacy invariant (load-bearing — see the spec.md "Privacy & Security" section): the API key is NEVER
// logged, printed, or surfaced in error messages. The only consumer of the
// raw key string is the Mistral wire-format request inside `STTClient`.

import Foundation
import CryptoKit
import Security
#if !os(watchOS)
// Speech framework is `@available(watchOS, unavailable)`. Imported only on
// platforms where Apple on-device STT lives — required for the TCC-status
// branch in `presetIDsWithStoredKey()`.
import Speech
#endif

/// Fully-resolved configuration for the BYO custom OpenAI-compatible STT
/// endpoint (`STTProvider.customOpenAICompat`). Resolved as a single value in
/// one actor hop inside `SettingsManager.activeSTTSnapshot()` so the foreground
/// transcribe path observes a consistent url / model / auth / pin — never a
/// half-edited combination during a Settings-side change (mirrors the
/// `RemoteAgentSnapshot` atomicity posture).
///
/// `url` is the FULL transcribe URL (base + `/v1/audio/transcriptions`), nil
/// when the user hasn't configured a base URL yet. `auth` is the EFFECTIVE
/// scheme (`.bearer` / `.none`), which overrides the immutable
/// `STTProvider.auth`. `certFingerprint` is the optional per-device pin (nil →
/// default ATS / system trust). Privacy: never logged or surfaced in errors.
struct CustomSTTConfig: Sendable {
    /// Full transcribe URL (base + `/v1/audio/transcriptions`); nil when the
    /// base URL is not configured. Resolved via `customSTTTranscribeURL()`.
    let url: URL?

    /// Effective model tag (default `"whisper-1"`).
    let model: String

    /// Effective auth scheme — `.bearer` (default) or `.none` (keyless local
    /// server). Overrides the immutable `STTProvider.auth`.
    let auth: STTAuthScheme

    /// Optional pinned SHA-256 leaf-cert fingerprint (lowercase hex). Nil →
    /// default ATS chain validation.
    let certFingerprint: String?
}

/// Fully-resolved configuration for the BYO custom OpenAI-compatible TTS
/// endpoint (`TTSProvider.customOpenAITTS`). The TTS sibling of `CustomSTTConfig`,
/// resolved in one actor hop inside `SettingsManager.activeTTSSnapshot()`. The
/// endpoint base URL, key, cert pin, and auth scheme are SHARED with custom STT
/// (`stt.custom.*` + `stt.apiKey.custom-openai`) — `url` is the FULL synthesis
/// URL (base + `/v1/audio/speech`), `auth` is the EFFECTIVE scheme overriding the
/// immutable `TTSProvider.auth`, and `certFingerprint` is the same per-device pin
/// custom STT uses. Only `model` is TTS-specific (`tts.custom.model`, default
/// `"tts-1"`) — `/v1/audio/speech` requires a `model` that varies per server.
/// Privacy: never logged or surfaced in errors.
struct CustomTTSConfig: Sendable {
    /// Full synthesis URL (base + `/v1/audio/speech`); nil when the shared base
    /// URL is not configured. Resolved via `customTTSSpeechURL()`.
    let url: URL?

    /// Effective model tag (default `"tts-1"`). Overrides `TTSProvider.model`.
    let model: String

    /// Effective auth scheme — `.bearer` (default) or `.none` (keyless local
    /// server). Shared with custom STT; overrides the immutable `TTSProvider.auth`.
    let auth: STTAuthScheme

    /// Optional pinned SHA-256 leaf-cert fingerprint (lowercase hex). Shared with
    /// custom STT. Nil → default ATS chain validation.
    let certFingerprint: String?
}

/// Owns Conduck's user settings: identity, STT API key (Keychain), and
/// cross-device preferences (iCloud KVS). Singleton actor — all access
/// awaited from outside.
actor SettingsManager {
    // MARK: - Singleton

    static let shared = SettingsManager()

    /// App Groups UserDefaults — shared between main app, Widget, and Watch
    /// targets so any reader sees the latest values without a round-trip.
    private let defaults: any DefaultsStore

    /// iCloud Key-Value Store for cross-device sync.
    private let iCloudStore: any UbiquitousStore

    /// Keychain. Every secret read/write/delete goes through here.
    private let secrets: any SecretStore

    /// iCloud account presence (`ubiquityIdentityToken` in production).
    private let cloudAvailability: any CloudAvailability

    #if DEBUG
    /// Test-only: suspend ALL iCloud KVS participation — the read-fallback
    /// (`iCloudAvailable`) AND the inbound `handleICloudChange` mirror — so a suite
    /// driving the live `.shared` singleton is immune to cross-suite KVS residue and
    /// real-iCloud ServerChange echoes when the sim is signed into iCloud. Defaults
    /// off; non-suspending suites + production are unaffected. Mirrors the existing
    /// `…ForTesting` seams.
    private var iCloudSyncSuspendedForTesting = false
    func setICloudSyncSuspendedForTesting(_ suspended: Bool) {
        iCloudSyncSuspendedForTesting = suspended
    }

    /// Test-only: re-arm the one-time `testedLocally` seed
    /// (`ensureFileServerTestedLocallySeeded`). The in-process latch otherwise
    /// consumes the seed on first touch, making seed assertions order-dependent
    /// across a suite run. Callers must ALSO wipe
    /// `Constants.fileServerTestedLocallySeededKey` from App-Group defaults —
    /// this resets only the in-memory latch.
    func resetTestedLocallySeedForTesting() {
        didAttemptTestedLocallySeed = false
    }
    #endif

    /// Whether iCloud is available on this device. Cheap check — `nil`
    /// token means the user is signed out of iCloud OR the entitlement is
    /// mis-provisioned. Either way we degrade to local-only.
    private var iCloudAvailable: Bool {
        #if DEBUG
        if iCloudSyncSuspendedForTesting { return false }
        #endif
        return cloudAvailability.isAvailable
    }

    /// In-process latch so the iCloud-Keychain migration is attempted at most
    /// once per actor instance (= once per process). Actor isolation makes this
    /// flag race-free. This is ONLY a per-process re-read avoidance — the real
    /// once-ever guard is the persistent App Groups `keychainSyncMigratedKey`
    /// flag checked inside `migrateSecretsToICloudKeychain()`, which holds across
    /// launches AND across the separate Shortcuts-intent / CarPlay processes.
    private var didAttemptKeychainMigration = false

    /// In-process latch so the single-slot → per-backend remote-agent migration
    /// (`migrateRemoteAgentToPerBackend()`) is attempted at most once per actor
    /// instance (= once per process). Mirrors `didAttemptKeychainMigration`. The
    /// real once-ever guard is the persistent `remoteAgentMultiGatewayMigratedKey`
    /// flag checked inside the migration; this latch only avoids re-reading that
    /// flag on every per-backend read.
    private var didAttemptRemoteAgentMigration = false

    /// In-process latch so the single-custom → roster migration
    /// (`migrateCustomVoiceEndpoint()`) is attempted at most once per actor
    /// instance (= once per process). Mirrors `didAttemptRemoteAgentMigration`.
    /// The real once-ever guard is the persistent `customVoiceEndpointMigratedKey`
    /// flag checked inside the migration.
    private var didAttemptCustomVoiceEndpointMigration = false

    /// In-process latch so the synced → device-local default-backend migration
    /// (`migrateDefaultBackendToDeviceLocal()`) is attempted at most once per
    /// actor instance. Mirrors `didAttemptRemoteAgentMigration`. The real
    /// once-ever guard is the persistent
    /// `remoteAgentDefaultBackendDeviceLocalMigratedKey` flag inside it.
    private var didAttemptDefaultBackendDeviceLocalMigration = false

    /// - Parameter dependencies: the three stores plus cloud availability and
    ///   the KVS change feed. Production passes `.processDefault`; a test builds
    ///   an isolated `.inMemory()` bundle so nothing it writes can reach the
    ///   real App Group, iCloud KVS, or Keychain.
    init(dependencies: SettingsDependencies = .processDefault) {
        self.defaults = dependencies.defaults
        self.iCloudStore = dependencies.ubiquitous
        self.secrets = dependencies.secrets
        self.cloudAvailability = dependencies.cloudAvailability

        // Register for iCloud KVS external change notifications
        // UNCONDITIONALLY — no `ubiquityIdentityToken` gate. The token is nil
        // while signed out OF iCLOUD at process start, but a user who signs in
        // later must not need an app relaunch before sync resumes; an observer
        // on a dormant KVS costs nothing (no notifications fire while signed
        // out, and `synchronize()` is a harmless no-op there).
        //
        // The handler routes back through `self`, not `.shared`, so an injected
        // instance mirrors its OWN store rather than the singleton's.
        dependencies.changes.observe { [weak self] change in
            guard let self else { return }
            Task { await self.handleICloudChange(change) }
        }
    }

    // MARK: - Change notification

    /// Post `.settingsDidChangeRemotely` on the MAIN thread.
    ///
    /// `SettingsManager` is an `actor`, so a raw `NotificationCenter.post(...)`
    /// inside a setter fires on the actor's background executor. SwiftUI
    /// `.onReceive(NotificationCenter.publisher(for:))` consumers (`ContentView`,
    /// `MainWindowView`, the composer bars) run their action on the POSTING
    /// thread — so a background post mutates `@State` / `@Observable` off-main
    /// ("Publishing changes from background threads"), which forces a layout
    /// mid-pass (`_NSDetectedLayoutRecursion`) and, on the custom-voice screen,
    /// tears down the macOS `SecureField`'s out-of-process ViewBridge view →
    /// the window crash on the "Requires an API key" toggle. Marshalling the
    /// post to main makes EVERY consumer — queue-based observers AND `.onReceive`
    /// — deliver on main. `DispatchQueue.main.async` (not `Task`) keeps batched
    /// setters' posts (e.g. `deleteCustomVoiceEndpoint` calls several) in FIFO
    /// call order. `nonisolated` so it's callable from any actor-isolated setter.
    nonisolated func postSettingsDidChangeRemotely() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .settingsDidChangeRemotely, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .settingsDidChangeRemotely, object: nil)
            }
        }
    }

    // MARK: - Identity / Onboarding

    /// Whether the user has completed the onboarding flow on this device.
    /// App Groups UserDefaults (not iCloud-synced) — each device runs its
    /// own onboarding (Watch + iPhone have separate setup flows).
    func hasCompletedOnboarding() -> Bool {
        return defaults.bool(forKey: Constants.onboardingCompletedKey)
    }

    /// Mark onboarding as complete on this device. Called from the
    /// Completion step's "Get Started" tap.
    func markOnboardingComplete() {
        defaults.set(true, forKey: Constants.onboardingCompletedKey)
    }

    // MARK: - Screenshot & Ask one-time tip (macOS, device-local)

    /// Whether the one-time "new ⌘⇧2 Screenshot & Ask" tip should still show in
    /// the menu-bar popover start state (existing users discovering the feature).
    /// Device-local (App Groups, not iCloud-synced) — a per-machine "seen it"
    /// flag, mirroring `hasCompletedOnboarding`.
    func shouldShowScreenshotAskTip() -> Bool {
        return !defaults.bool(forKey: Constants.screenshotAskTipSeenKey)
    }

    /// Mark the Screenshot & Ask tip as seen so it never shows again. Called when
    /// the user dismisses it (its X) or uses the feature.
    func markScreenshotAskTipSeen() {
        defaults.set(true, forKey: Constants.screenshotAskTipSeenKey)
    }

    // MARK: - Gateway Primer one-time flag (device-local, synchronous)

    /// Whether the first-run gateway primer (the orientation step 0 in
    /// `GuidedGatewaySetupView`) has been acknowledged on this device. Device-local
    /// (App Groups, NOT iCloud-synced) — a per-machine "seen it" flag mirroring
    /// `hasCompletedOnboarding`.
    ///
    /// SYNCHRONOUS + `static` by design: it's read from `GuidedGatewaySetupView.init`
    /// (which can't await the actor) and written the instant the user leaves the
    /// primer (before navigation), so a rapid reopen can't beat an async actor
    /// write and re-show the screen. Reads the App-Group suite directly (mirrors
    /// `RootView`'s synchronous onboarding read). A missing/unavailable suite is
    /// treated as UNSEEN — never silently skip the primer.
    static func hasSeenGatewayPrimer(
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> Bool {
        defaults.bool(forKey: Constants.gatewayPrimerSeenKey)
    }

    /// Mark the gateway primer acknowledged (synchronous App-Group write). Called
    /// from the primer's "Choose how to connect" / "Set up manually" taps — NEVER
    /// on Close, so a Close-without-choosing re-shows it next time.
    static func markGatewayPrimerSeen(
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) {
        defaults.set(true, forKey: Constants.gatewayPrimerSeenKey)
    }

    // MARK: - Show in Dock (macOS, device-local)

    /// macOS "Show in Dock" preference. ON (default) = Dock-app mode
    /// (`NSApp.setActivationPolicy(.regular)` → Dock icon + top app menu +
    /// `NSStatusItem` duck); OFF = menu-bar-only utility (`.accessory` → no Dock
    /// icon / app menu, duck stays). Device-local (App Groups UserDefaults, NOT
    /// iCloud KVS — activation policy is a per-machine window-manager choice, not
    /// a synced preference). Mirrors the App-Group-only Bool shape of
    /// `hasCompletedOnboarding`. Defaults to `true`
    /// when unset via the `object(forKey:) as? Bool ?? true` read (the bare
    /// `bool(forKey:)` would default a never-written key to `false`).
    func getShowDockIcon() -> Bool {
        (defaults.object(forKey: Constants.showDockIconKey) as? Bool) ?? true
    }

    /// Persist the "Show in Dock" preference. App Groups only (no iCloud KVS —
    /// see `getShowDockIcon`). Posts `.settingsDidChangeRemotely` so any open
    /// `SettingsViewModel` re-renders the toggle consistently.
    func setShowDockIcon(_ show: Bool) {
        defaults.set(show, forKey: Constants.showDockIconKey)
        postSettingsDidChangeRemotely()
    }

    /// SYNCHRONOUS launch-path read of the "Show in Dock" preference. Reads the
    /// App Group `UserDefaults` suite directly (NOT the actor) so
    /// `AppDelegate.applicationWillFinishLaunching` can apply the activation
    /// policy WITHOUT an async actor hop (which would let a Dock icon flash
    /// before the policy switches to `.accessory`). Defaults to `true` when
    /// unset. Suite name is single-sourced from `Constants.appGroupID` — never
    /// hardcoded.
    static func showDockIconAtLaunch(
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> Bool {
        (defaults.object(forKey: Constants.showDockIconKey) as? Bool) ?? true
    }

    // MARK: - iCloud-unavailable banner dismissal (device-local)

    /// Whether the user has dismissed the "iCloud unavailable" banner for the
    /// current outage episode. Read/written SYNCHRONOUSLY against the App-Group
    /// suite (NOT the actor) so the `@MainActor` `CloudSyncMonitor` can consult /
    /// flip it without an async hop — same static-launch-path idiom as
    /// `showDockIconAtLaunch()`. Sticky across launches while iCloud stays down;
    /// `CloudSyncMonitor` resets it to false when the account returns. See
    /// `Constants.iCloudBannerDismissedKey`.
    static func iCloudBannerDismissed(
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> Bool {
        defaults.bool(forKey: Constants.iCloudBannerDismissedKey)
    }

    /// Persist the iCloud-banner dismissal flag (App-Group, device-local).
    static func setICloudBannerDismissed(
        _ dismissed: Bool,
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) {
        defaults.set(dismissed, forKey: Constants.iCloudBannerDismissedKey)
    }

    // MARK: - Read replies aloud (per-surface, device-local)

    /// iOS/iPadOS "speak the reply when opened from its notification"
    /// preference. Default OFF. Device-local (App Groups UserDefaults, NOT
    /// iCloud KVS — read-aloud is an environment choice, each device keeps its
    /// own; mirrors `getShowDockIcon`'s posture with the inverted default:
    /// `object(forKey:) as? Bool ?? false`, never bare `bool(forKey:)`).
    func getSpeakReplyOnNotificationOpen() -> Bool {
        (defaults.object(forKey: Constants.speakReplyOnNotificationOpenKey) as? Bool) ?? false
    }

    /// Persist the iOS notification-open read-aloud preference. App Groups
    /// only (see `getSpeakReplyOnNotificationOpen`). Posts
    /// `.settingsDidChangeRemotely` so an open Settings view re-renders.
    func setSpeakReplyOnNotificationOpen(_ speak: Bool) {
        defaults.set(speak, forKey: Constants.speakReplyOnNotificationOpenKey)
        postSettingsDidChangeRemotely()
    }

    /// SYNCHRONOUS notification-tap-path read of the iOS notification-open
    /// read-aloud preference. Reads the App Group `UserDefaults` suite directly
    /// (NOT the actor) so the nonisolated
    /// `NotificationDelegate.didReceive` can compute the auto-speak verdict
    /// without an async actor hop (mirrors `showDockIconAtLaunch`). Defaults
    /// to `false` when unset.
    static func speakReplyOnNotificationOpenAtTap(
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> Bool {
        (defaults.object(forKey: Constants.speakReplyOnNotificationOpenKey) as? Bool) ?? false
    }

    /// macOS "speak quick-lane replies on arrival" preference (menu-bar
    /// popover, ⌘⇧1 voice, ⌘⇧2 Screenshot & Ask). Default OFF. Device-local
    /// (App Groups UserDefaults, NOT iCloud KVS — per-machine choice: an
    /// office Mac stays silent while a home Mac speaks). The main-window lane
    /// never consults this (in-chat hard rule — the verdict rides
    /// `sendUserTurn(speaksReply:)` per send).
    func getSpeakQuickLaneReplies() -> Bool {
        (defaults.object(forKey: Constants.speakQuickLaneRepliesKey) as? Bool) ?? false
    }

    /// Persist the macOS quick-lane read-aloud preference. App Groups only
    /// (see `getSpeakQuickLaneReplies`). Posts `.settingsDidChangeRemotely`.
    func setSpeakQuickLaneReplies(_ speak: Bool) {
        defaults.set(speak, forKey: Constants.speakQuickLaneRepliesKey)
        postSettingsDidChangeRemotely()
    }

    // MARK: - Menu-bar input mode (macOS, device-local)

    /// macOS menu-bar popover input mode: `.voice` (default) auto-records on
    /// summon; `.text` shows a focused text field instead. Device-local
    /// (App Groups UserDefaults, NOT iCloud KVS — per-machine ergonomic; the
    /// surface is macOS-only, so syncing buys nothing). Raw-string +
    /// fallback-to-default read, mirroring `getSessionContinuationPolicy`.
    func getMenuBarInputMode() -> MenuBarInputMode {
        guard let raw = defaults.string(forKey: Constants.menuBarInputModeKey),
              let value = MenuBarInputMode(rawValue: raw) else {
            return MenuBarInputMode.default
        }
        return value
    }

    /// Persist the menu-bar input mode. App Groups only (no iCloud KVS — see
    /// `getMenuBarInputMode`). Posts `.settingsDidChangeRemotely` so
    /// `MenuBarCoordinator` refreshes its observable mirror live — the next
    /// popover summon uses the new mode, no relaunch.
    func setMenuBarInputMode(_ value: MenuBarInputMode) {
        defaults.set(value.rawValue, forKey: Constants.menuBarInputModeKey)
        postSettingsDidChangeRemotely()
    }

    /// SYNCHRONOUS read of the menu-bar input mode. Reads the App Group
    /// `UserDefaults` suite directly (NOT the actor) so
    /// `MenuBarCoordinator.init` can seed its observable mirror without an
    /// async hop (an async seed would let the popover render the wrong input
    /// surface on a fast first summon). Mirrors `showDockIconAtLaunch()`.
    static func menuBarInputModeAtLaunch(
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> MenuBarInputMode {
        guard let raw = defaults.string(forKey: Constants.menuBarInputModeKey),
              let value = MenuBarInputMode(rawValue: raw) else {
            return MenuBarInputMode.default
        }
        return value
    }

    // MARK: - STT API Key (Keychain, per-preset)
    //
    // Per-preset Keychain layout. Each preset's API key lives at
    // account `stt.apiKey.<presetID>` (helper:
    // `Constants.sttApiKeyKeychainAccount(for:)`). The zero-arg legacy
    // methods forward to the active preset for back-compat — UI/CarPlay/
    // Shortcuts call sites that haven't been provider-parameterized yet stay
    // green.

    /// Read the API key for a specific preset ID from Keychain.
    /// Returns nil if the slot is empty or Keychain is locked. Convenience
    /// over `apiKeyReadResult(forPresetID:)` for the many call sites that only
    /// need present-or-not; anything that must distinguish "missing" from
    /// "unreadable" (degraded-state UI, the outcome ring, snapshots) reads the
    /// typed result instead.
    func getAPIKey(forPresetID presetID: String) -> String? {
        if case .present(let key) = apiKeyReadResult(forPresetID: presetID) {
            return key
        }
        return nil
    }

    /// TYPED Keychain read for a preset's API key — distinguishes a genuinely
    /// absent key (`.missing`, `errSecItemNotFound`) from a key the Keychain
    /// could not return (`.unreadable`: locked/auth-failed/IPC error, or a
    /// success with malformed/empty payload). The old nil-collapse made a
    /// temporarily-unreadable credential indistinguishable from a missing one.
    /// Classification itself is the pure `APIKeyReadResult.classify` (testable
    /// unsigned); this method only performs the live `SecItemCopyMatching`.
    func apiKeyReadResult(forPresetID presetID: String) -> APIKeyReadResult {
        // Self-trigger the iCloud-Keychain migration before the first read in
        // this process — covers headless Shortcuts-intent / CarPlay processes
        // that never run the app's launch wiring (else the sync-only query below
        // would miss an un-migrated non-sync key and silently fail).
        ensureKeychainMigrated()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.sttApiKeyKeychainAccount(for: presetID),
            // iCloud-Keychain-synced item (Part B). A synchronizable item is a
            // DISTINCT keychain item from a non-sync one with the same account,
            // so every steady-state op must carry this flag for round-trip
            // consistency. Migration (B2) runs at launch first, so a plain
            // `true` (not `kSecAttrSynchronizableAny`) is unambiguous here.
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let (status, result) = secrets.copyMatching(query)
        return APIKeyReadResult.classify(status: status, data: result as? Data)
    }

    /// Write a preset's API key to Keychain with
    /// `kSecAttrAccessibleAfterFirstUnlock` (Watch
    /// ControlWidget cold-launch path needs key available before unlock).
    /// - Throws: `AppError.settingsLoadFailed` on failure.
    func setAPIKey(_ key: String, forPresetID presetID: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw AppError.settingsLoadFailed
        }

        let account = Constants.sttApiKeyKeychainAccount(for: presetID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account,
            // iCloud-Keychain-synced item (Part B) — synchronizable items are
            // distinct from non-sync ones, so the update query AND the add
            // (below, built from this `query`) must both carry the flag.
            kSecAttrSynchronizable as String: true
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = secrets.update(query, attributes: attributes)

        if updateStatus == errSecSuccess {
            // Post on every successful write (add OR update) so observers
            // — `PhoneSessionManager` and `CarPlaySettings`
            // — re-broadcast / refresh with the new key. First-time
            // onboarding paste fires through the add branch below.
            postSettingsDidChangeRemotely()
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Accessibility must be set at add time — immutable thereafter.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = secrets.add(addQuery)
            guard addStatus == errSecSuccess else {
                throw AppError.settingsLoadFailed
            }
            postSettingsDidChangeRemotely()
            return
        }

        throw AppError.settingsLoadFailed
    }

    /// Remove a preset's API key from Keychain.
    func clearAPIKey(forPresetID presetID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.sttApiKeyKeychainAccount(for: presetID),
            // Match the synchronizable item (Part B) — a non-sync delete query
            // would miss the iCloud-synced item, leaving it (and its sync copies)
            // alive on other devices.
            kSecAttrSynchronizable as String: true
        ]

        let status = secrets.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.settingsLoadFailed
        }
        // Post so observers (CarPlaySettings, PhoneSessionManager's
        // observer) refresh / re-broadcast — the cleared slot may have
        // been the active preset.
        if status == errSecSuccess {
            postSettingsDidChangeRemotely()
        }
    }

    /// Return the set of preset IDs that currently have a key in Keychain.
    /// Used by the Settings picker to render dot-state per row without
    /// loading every key value into memory.
    ///
    /// Implementation: query all generic-password items under our service
    /// (`Constants.keychainServiceName`) and filter to accounts beginning
    /// with the `stt.apiKey.` prefix. Returns an empty set on Keychain
    /// errors (read-only path — never throws).
    func presetIDsWithStoredKey() -> Set<String> {
        // Migrate before enumerating — else the sync-only enumeration would
        // report empty dot-state for un-migrated non-sync keys in a fresh process.
        ensureKeychainMigrated()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            // Enumerate the synchronizable items (Part B) — these are the
            // steady-state STT-key slots after migration. A non-sync enumeration
            // would report the picker's dot-state off the pre-migration items.
            kSecAttrSynchronizable as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        let (status, result) = secrets.copyMatching(query)

        // errSecItemNotFound is a normal empty result — no keys stored yet.
        var presetIDs: Set<String> = []
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            let prefix = Constants.sttApiKeyKeychainAccount(for: "")
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      account.hasPrefix(prefix) else { continue }
                let presetID = String(account.dropFirst(prefix.count))
                guard !presetID.isEmpty else { continue }
                presetIDs.insert(presetID)
            }
        }

        // Apple on-device has no Keychain entry — "stored" iff TCC has
        // granted Speech Recognition. The Settings UI uses
        // `presetIDsWithStoredKey()` to decide `.empty` vs `.storedInactive`
        // / `.storedActive`; for Apple, `.authorized` is the moral
        // equivalent of "key present". Watch never reaches this branch —
        // `Speech` ships no watchOS symbols.
        #if !os(watchOS)
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            presetIDs.insert("apple-on-device")
        }
        #endif

        return presetIDs
    }

    // MARK: - STT API Key (legacy zero-arg forwarders — active preset)
    //
    // Forwarders kept so existing call sites (Onboarding, Settings UI,
    // Shortcuts intents) continue to work. New code SHOULD use the
    // preset-parameterized variants above.

    /// Read the active preset's API key from Keychain.
    /// Returns nil if no key has ever been set or if Keychain is locked.
    func getAPIKey() -> String? {
        getAPIKey(forPresetID: getActivePresetID())
    }

    /// Write the active preset's API key to Keychain.
    /// - Throws: `AppError.settingsLoadFailed` on failure.
    func setAPIKey(_ key: String) throws {
        try setAPIKey(key, forPresetID: getActivePresetID())
    }

    /// Remove the active preset's API key from Keychain.
    func clearAPIKey() throws {
        try clearAPIKey(forPresetID: getActivePresetID())
    }

    // MARK: - Preferred Language (iCloud KVS, syncs across devices)

    /// Read the user's preferred STT language hint (ISO 639-1). Nil = auto-detect.
    /// Synced cross-device via iCloud KVS using `Constants.sttPreferredLanguageKVSKey`.
    /// Reads from App Groups UserDefaults (hydrated by `performInitialSync` +
    /// `handleICloudChange`) for synchronous, cheap access.
    func getPreferredLanguage() -> String? {
        let value = defaults.string(forKey: Constants.preferredLanguageKey)
        // Treat empty string as "no preference" so a stale empty write doesn't
        // pin the user to invalid empty-string language.
        return (value?.isEmpty == false) ? value : nil
    }

    /// Write the user's preferred STT language hint. Dual-writes to KVS and
    /// local App Groups UserDefaults so reads are synchronous on subsequent
    /// launches.
    func setPreferredLanguage(_ value: String?) {
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: Constants.preferredLanguageKey)
            if iCloudAvailable {
                iCloudStore.set(value, forKey: Constants.sttPreferredLanguageKVSKey)
            }
        } else {
            defaults.removeObject(forKey: Constants.preferredLanguageKey)
            if iCloudAvailable {
                iCloudStore.removeObject(forKey: Constants.sttPreferredLanguageKVSKey)
            }
        }
    }

    // MARK: - Apple model reserve ledger (App-Group, device-local)

    /// Last Apple on-device locale identifier Conduck reserved, or nil. Used by
    /// `SettingsViewModel.reserveAppleLocale` to release only what Conduck
    /// itself pinned when the user switches languages (never another OS
    /// feature's reservation). Device-local — reservations don't sync.
    func getLastReservedAppleLocale() -> String? {
        let value = defaults.string(forKey: Constants.lastReservedAppleLocaleKey)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Record the Apple on-device locale Conduck just reserved (or nil to clear).
    func setLastReservedAppleLocale(_ value: String?) {
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: Constants.lastReservedAppleLocaleKey)
        } else {
            defaults.removeObject(forKey: Constants.lastReservedAppleLocaleKey)
        }
    }

    // MARK: - Active STT Preset

    /// Returns the current active STT preset ID. Reads App Groups
    /// `defaults` first (hydrated by the dual-write setter + the KVS
    /// observer), then iCloud KVS if available (preserves existing KVS-only
    /// users with no migration), then `Constants.sttActivePresetIDDefault`
    /// ("apple-on-device"). The `defaults` fallback fixes the provider-
    /// selection flicker for users signed out of iCloud / on unprovisioned
    /// dev builds, where KVS writes silently dropped.
    func getActivePresetID() -> String {
        if let local = defaults.string(forKey: Constants.sttActivePresetIDKVSKey),
           !local.isEmpty {
            return local
        }
        if iCloudAvailable,
           let stored = iCloudStore.string(forKey: Constants.sttActivePresetIDKVSKey),
           !stored.isEmpty {
            return stored
        }
        return Constants.sttActivePresetIDDefault
    }

    /// Set the active STT preset ID. Dual-writes to App Groups `defaults`
    /// AND iCloud KVS (cross-device sync) and posts `.settingsDidChangeRemotely`
    /// so observers (`SettingsViewModel`, `CarPlaySettings`) refresh from the
    /// new active preset. The unconditional `defaults` write (mirroring
    /// `setSessionContinuationPolicy`) is the durable store that fixes the
    /// selection flicker when iCloud is unavailable. No-op when `newID` equals the
    /// current value to avoid spurious notification fan-out + Watch
    /// re-broadcasts on idempotent UI taps.
    func setActivePresetID(_ newID: String) {
        let current = getActivePresetID()
        guard newID != current else { return }

        defaults.set(newID, forKey: Constants.sttActivePresetIDKVSKey)
        iCloudStore.set(newID, forKey: Constants.sttActivePresetIDKVSKey)
        postSettingsDidChangeRemotely()
    }

    /// Convenience: resolve the active preset ID to its `STTProvider`
    /// registry entry. Falls back to the V1 default on unknown ID (see
    /// `STTProvider.lookup(id:)`).
    func getActiveSTTProvider() -> STTProvider {
        STTProvider.lookup(id: getActivePresetID())
    }

    /// First CONFIGURED cloud/custom STT preset id (a network provider with a key
    /// stored in Keychain) — the "Use cloud voice" fallback target when Apple
    /// on-device hits a genuine hard failure (unsupported language / failed
    /// model self-heal). Excludes `apple-on-device` (no Keychain slot; itself the
    /// failing provider) and any preset that resolves to an in-process transport.
    /// nil when the user has no cloud STT key configured → the caller falls back
    /// to "Open Voice Settings". Read-only Keychain enumeration (never throws).
    func firstConfiguredCloudSTTPresetID() -> String? {
        for id in presetIDsWithStoredKey() where id != "apple-on-device" {
            if STTProvider.lookup(id: id).transport != .inProcess {
                return id
            }
        }
        return nil
    }

    // MARK: - Apple on-device engine mode

    /// Which on-device Apple engine the `apple-on-device` provider runs.
    /// Read App Groups `defaults` first (hydrated by the dual-write setter +
    /// KVS observer), then iCloud KVS, then the `.dictation` default. Same
    /// read-through shape as `getActivePresetID()` so a fresh / iCloud-signed-
    /// out install resolves to keyboard dictation (no download) deterministically.
    func getAppleOnDeviceEngineMode() -> AppleOnDeviceEngineMode {
        if let local = defaults.string(forKey: Constants.appleOnDeviceEngineModeKVSKey),
           !local.isEmpty {
            return AppleOnDeviceEngineMode.fromStored(local)
        }
        if iCloudAvailable,
           let stored = iCloudStore.string(forKey: Constants.appleOnDeviceEngineModeKVSKey),
           !stored.isEmpty {
            return AppleOnDeviceEngineMode.fromStored(stored)
        }
        return .default
    }

    /// Set the on-device Apple engine mode. Dual-writes to App Groups
    /// `defaults` + iCloud KVS and posts `.settingsDidChangeRemotely`. No-op on
    /// an idempotent set. Clone of `setActivePresetID()` semantics — the choice
    /// is non-secret + per-user, so it syncs across the user's own devices.
    func setAppleOnDeviceEngineMode(_ mode: AppleOnDeviceEngineMode) {
        let current = getAppleOnDeviceEngineMode()
        guard mode != current else { return }

        defaults.set(mode.rawValue, forKey: Constants.appleOnDeviceEngineModeKVSKey)
        iCloudStore.set(mode.rawValue, forKey: Constants.appleOnDeviceEngineModeKVSKey)
        postSettingsDidChangeRemotely()
    }

    /// Atomic snapshot of (active preset ID, its API key, the resolved
    /// `STTProvider`, the optional per-preset custom model override, and —
    /// only when the active preset is the BYO custom OpenAI-compatible
    /// endpoint — its fully-resolved `CustomSTTConfig`). Use this instead of
    /// separately calling `getAPIKey()` + `getActivePresetID()` +
    /// `getCustomSTTURL()` etc. — those hop the actor multiple times, allowing
    /// a preset switch / URL edit in between to produce a key/provider/URL
    /// mismatch. Every field is guaranteed to refer
    /// to the SAME preset because they are resolved inside one actor-isolated
    /// call.
    ///
    /// `customModel` is resolved for EVERY provider (the per-preset
    /// `stt.customModel.<id>` slot); `customConfig` is non-nil ONLY for the
    /// custom-endpoint preset (`provider.dynamicEndpointKey != nil`) — its url
    /// / model / auth / fingerprint are read in the same hop so the foreground
    /// transcribe path can't observe a half-edited config.
    func activeSTTSnapshot() -> (
        presetID: String,
        apiKey: String?,
        provider: STTProvider,
        customModel: String?,
        customConfig: CustomSTTConfig?
    ) {
        // Migrate before the snapshot's key read (no-op if already done this
        // process — the inner getAPIKey also calls it; the latch dedupes).
        ensureKeychainMigrated()
        ensureCustomVoiceEndpointMigrated()
        let id = getActivePresetID()
        let provider = STTProvider.lookup(id: id)
        let customModel = getCustomModel(forPresetID: id)
        // Resolve the full BYO-endpoint config in the SAME actor hop — only for
        // the dynamic-endpoint provider, so the 6 frozen providers pay nothing.
        // A per-uuid id (`custom-openai_<uuid>`) reads the per-uuid slots; the
        // bare legacy id (`custom-openai`) falls back to the singleton slots.
        let customConfig: CustomSTTConfig?
        if provider.dynamicEndpointKey != nil {
            if let uuid = STTProvider.customEndpointUUID(fromPresetID: id) {
                customConfig = customSTTConfig(for: uuid)
            } else {
                customConfig = CustomSTTConfig(
                    url: customSTTTranscribeURL(),
                    model: getCustomSTTModel(),
                    auth: getCustomSTTAuthScheme(),
                    certFingerprint: getCustomSTTCertFingerprint()
                )
            }
        } else {
            customConfig = nil
        }
        return (
            presetID: id,
            apiKey: getAPIKey(forPresetID: id),
            provider: provider,
            customModel: customModel,
            customConfig: customConfig
        )
    }

    // MARK: - Active TTS Provider (cloud Text-to-Speech)
    //
    // Mirrors the active-STT-preset accessors. NO new Keychain slot: a
    // vendor's TTS key reads its EXISTING `stt.apiKey.<sttPresetID>` slot
    // (mapped on `TTSProvider.sharedKeySTTPresetID`, resolved in
    // `activeTTSSnapshot()`). The active-TTS pointer + per-provider voice
    // override are non-secret → App Groups + iCloud KVS dual-write.

    /// Returns the current active TTS provider ID. Reads App Groups `defaults`
    /// first (hydrated by the dual-write setter + the KVS observer), then
    /// iCloud KVS if available, then `Constants.ttsActiveProviderIDDefault`
    /// (`apple-tts`). EXACT clone of `getActivePresetID()` semantics.
    func getActiveTTSProviderID() -> String {
        if let local = defaults.string(forKey: Constants.ttsActiveProviderIDKVSKey),
           !local.isEmpty {
            return local
        }
        if iCloudAvailable,
           let stored = iCloudStore.string(forKey: Constants.ttsActiveProviderIDKVSKey),
           !stored.isEmpty {
            return stored
        }
        return Constants.ttsActiveProviderIDDefault
    }

    /// Set the active TTS provider ID. Dual-writes to App Groups `defaults`
    /// AND iCloud KVS and posts `.settingsDidChangeRemotely`. No-op when
    /// `newID` equals the current value (avoids spurious notification fan-out
    /// + Watch re-broadcast on idempotent taps). EXACT clone of
    /// `setActivePresetID()`.
    func setActiveTTSProviderID(_ newID: String) {
        let current = getActiveTTSProviderID()
        guard newID != current else { return }

        defaults.set(newID, forKey: Constants.ttsActiveProviderIDKVSKey)
        iCloudStore.set(newID, forKey: Constants.ttsActiveProviderIDKVSKey)
        postSettingsDidChangeRemotely()
    }

    /// Read a TTS provider's voice override. Nil = no override (the provider's
    /// pinned `defaultVoice` applies). Reads App Groups `defaults` (hydrated by
    /// the dual-write setter + the KVS observer) for synchronous, cheap access.
    /// Mirrors `getCustomModel(forPresetID:)`.
    func getTTSVoice(forProviderID providerID: String) -> String? {
        let value = defaults.string(forKey: Constants.ttsVoiceKey(for: providerID))
        // Treat empty string as "no override" so a stale empty write doesn't
        // pin the user to an invalid empty voice.
        return (value?.isEmpty == false) ? value : nil
    }

    /// Write a TTS provider's voice override. Dual-writes to App Groups
    /// `defaults` + iCloud KVS and posts `.settingsDidChangeRemotely`. Pass
    /// nil / empty to clear (falls back to the provider's `defaultVoice`).
    /// Mirrors `setCustomModel(_:forPresetID:)`.
    func setTTSVoice(_ value: String?, forProviderID providerID: String) {
        let key = Constants.ttsVoiceKey(for: providerID)
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: key)
            if iCloudAvailable {
                iCloudStore.set(value, forKey: key)
            }
        } else {
            defaults.removeObject(forKey: key)
            if iCloudAvailable {
                iCloudStore.removeObject(forKey: key)
            }
        }
        postSettingsDidChangeRemotely()
    }

    /// Read a TTS provider's per-provider MODEL override. Nil = no override (the
    /// provider's pinned `model` applies). Reads App Groups `defaults` (hydrated
    /// by the dual-write setter + the KVS observer) for synchronous, cheap
    /// access. The TTS sibling of `getCustomModel(forPresetID:)`. DISTINCT from
    /// `getCustomTTSModel()` — that is the BYO custom endpoint's REQUIRED model
    /// (`tts.custom.model`); this is the optional override for the 4 frozen cloud
    /// providers (Apple is withheld at the UI).
    func getTTSCustomModel(forProviderID providerID: String) -> String? {
        let value = defaults.string(forKey: Constants.ttsCustomModelKey(for: providerID))
        // Treat empty string as "no override" so a stale empty write doesn't pin
        // the user to an invalid empty-string model.
        return (value?.isEmpty == false) ? value : nil
    }

    /// Write a TTS provider's per-provider MODEL override. Dual-writes to App
    /// Groups `defaults` + iCloud KVS and posts `.settingsDidChangeRemotely`.
    /// Pass nil / empty to clear (falls back to the provider's pinned `model`).
    /// Mirrors `setCustomModel(_:forPresetID:)`.
    func setTTSCustomModel(_ value: String?, forProviderID providerID: String) {
        let key = Constants.ttsCustomModelKey(for: providerID)
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: key)
            if iCloudAvailable {
                iCloudStore.set(value, forKey: key)
            }
        } else {
            defaults.removeObject(forKey: key)
            if iCloudAvailable {
                iCloudStore.removeObject(forKey: key)
            }
        }
        postSettingsDidChangeRemotely()
    }

    /// Atomic snapshot of the active TTS provider's (id, its API key, the
    /// optional voice override, the optional per-provider MODEL override) in ONE
    /// actor hop. Resolves the active TTS provider id → `TTSProvider.lookup(id:)`
    /// → if the provider maps to an STT key slot (`sharedKeySTTPresetID` non-nil),
    /// read that EXISTING Keychain slot; else nil (Apple). The shared-key mapping
    /// lives on `TTSProvider` precisely so this resolution needs no STT-registry
    /// knowledge here — avoids a circular dependency and guarantees the key,
    /// voice, AND model can't tear against a concurrent active-provider switch
    /// (same one-hop rationale as `activeSTTSnapshot()`).
    ///
    /// `customModel` (the per-provider `tts.customModel.<id>` override) is
    /// resolved for EVERY provider in this hop. It is DISTINCT from the custom
    /// endpoint's `customConfig.model` (`tts.custom.model`) — the latter is the
    /// BYO endpoint's required model; the former never applies to the custom
    /// endpoint (`TTSClient` branches on `isCustomEndpoint`).
    func activeTTSSnapshot() -> TTSSnapshot {
        ttsSnapshot(forProviderID: getActiveTTSProviderID())
    }

    /// Atomic snapshot for an EXPLICIT provider id — the same one-hop
    /// resolution `activeTTSSnapshot()` composes, exposed so the Settings
    /// "Speak a sample" preview audits exactly what the STORE holds (the VM's
    /// per-row caches used to be a second, divergent read path). Key + typed
    /// key state derive from ONE `apiKeyReadResult` read (never two Keychain
    /// hits that could tear); the Apple sentinel and a keyless
    /// (`auth == .none`) custom endpoint report `.notRequired`.
    func ttsSnapshot(forProviderID id: String) -> TTSSnapshot {
        // Migrate before the key read (no-op if already done this process —
        // the inner read also calls it; the latch dedupes).
        ensureKeychainMigrated()
        ensureCustomVoiceEndpointMigrated()
        let provider = TTSProvider.lookup(id: id)
        let voice = getTTSVoice(forProviderID: id)
        let customModel = getTTSCustomModel(forProviderID: id)
        // Resolve the BYO-endpoint config in the SAME actor hop — only for the
        // dynamic-endpoint provider, so the 5 frozen providers pay nothing. The
        // URL/cert/auth are SHARED with custom STT (one server, both directions);
        // only the model is TTS-specific. Mirrors `activeSTTSnapshot()`. A per-uuid
        // id reads the per-uuid slots; the bare legacy id → the singleton slots.
        let customConfig: CustomTTSConfig?
        if provider.dynamicEndpointKey != nil {
            if let uuid = TTSProvider.customEndpointUUID(fromProviderID: id) {
                customConfig = customTTSConfig(for: uuid)
            } else {
                customConfig = customTTSConfig()
            }
        } else {
            customConfig = nil
        }

        // ONE typed Keychain read feeds BOTH the key and the key state
        // (TTSSnapshot's invariant: apiKey non-nil ⇔ keyState == .present).
        // Apple (`sharedKeySTTPresetID == nil`) and a keyless custom endpoint
        // need no key at all.
        let keyless = provider.dynamicEndpointKey != nil && customConfig?.auth == STTAuthScheme.none
        let apiKey: String?
        let keyState: APIKeyState
        if let sharedPresetID = provider.sharedKeySTTPresetID, !keyless {
            switch apiKeyReadResult(forPresetID: sharedPresetID) {
            case .present(let key):
                apiKey = key
                keyState = .present
            case .missing:
                apiKey = nil
                keyState = .missing
            case .unreadable:
                apiKey = nil
                keyState = .unreadable
            }
        } else {
            apiKey = nil
            keyState = .notRequired
        }
        return TTSSnapshot(
            providerID: id,
            apiKey: apiKey,
            keyState: keyState,
            voice: voice,
            customModel: customModel,
            customConfig: customConfig
        )
    }

    /// SECRET-FREE probe of the active TTS provider's device-local key
    /// availability — the convergence-UX read (key-readiness banner +
    /// `TTSKeyArrivalMonitor`). Derives from the same atomic
    /// `activeTTSSnapshot()` resolution so the banner can never describe a
    /// different provider than playback would use, then DROPS the key: the
    /// view model and the arrival monitor only ever hold the typed state.
    /// `keyState` means LOCAL KEY AVAILABILITY only — `.present` does not
    /// claim the provider works (wrong voice, dead endpoint, and revoked keys
    /// all still probe `.present`).
    func activeTTSKeyProbe() -> ActiveTTSKeyProbe {
        let snapshot = activeTTSSnapshot()
        let provider = TTSProvider.lookup(id: snapshot.providerID)
        return ActiveTTSKeyProbe(
            providerID: snapshot.providerID,
            keySlotID: snapshot.keyState == .notRequired ? nil : provider.sharedKeySTTPresetID,
            keyState: snapshot.keyState
        )
    }

    // MARK: - Cross-Device Broadcast Envelope

    /// Build the current `STTBroadcastEnvelope` payload for the active
    /// preset, stamped with a monotonic `Date().timeIntervalSinceReferenceDate`
    /// timestamp. Returns nil when the active preset has no key in Keychain
    /// (pre-onboarding or after a user-initiated clear) — `PhoneSessionManager`
    /// uses that signal to skip the `transferUserInfo` enqueue entirely
    /// (no point shipping an empty-key envelope to the Watch).
    ///
    /// Timestamp uses `timeIntervalSinceReferenceDate` (offset from 2001-01-01)
    /// rather than `timeIntervalSince1970` — both are monotonic at the
    /// resolution we need; the difference is constant and the receiver only
    /// uses `>` comparisons against its last-seen value.
    func currentBroadcastEnvelope() -> STTBroadcastEnvelope? {
        let presetID = getActivePresetID()

        // Resolve the active TTS triple in the SAME actor hop as the STT state
        // — the Watch must see a coherent STT+TTS snapshot, never a torn
        // mix of new-STT + old-TTS. `activeTTSSnapshot()` reads the TTS
        // provider's key from its SHARED `stt.apiKey.<…>` slot.
        let tts = activeTTSSnapshot()

        // Apple on-device STT — no STT Keychain key. Broadcast an envelope with
        // STT `apiKey: nil` so the Watch knows Apple is the active STT preset
        // (relay audio to iPhone instead of attempting in-process transcription
        // on Watch). Returning nil here would leave the Watch on the previous
        // (cloud) preset, sending audio + a stale key to a provider the user has
        // deselected — silent privacy regression.
        if presetID == "apple-on-device" {
            return STTBroadcastEnvelope(
                presetID: presetID,
                apiKey: nil,
                customModel: getCustomModel(forPresetID: presetID),
                ttsProviderID: tts.providerID,
                ttsApiKey: tts.apiKey,
                ttsVoice: tts.voice,
                ttsCustomModel: tts.customModel,
                timestamp: Date().timeIntervalSinceReferenceDate
            )
        }

        // A cloud TTS provider with a key must still reach the Watch even
        // when the active STT preset has no key. The old early `guard` returned
        // nil whenever the STT preset was keyless, which would silently strand
        // the Watch's TTS provider on its default. Ship the envelope when EITHER
        // the STT preset has a key OR the active TTS provider does.
        let sttKey = getAPIKey(forPresetID: presetID)
        let hasSTTKey = (sttKey?.isEmpty == false)
        let hasTTSKey = (tts.apiKey?.isEmpty == false)
        guard hasSTTKey || hasTTSKey else {
            return nil
        }
        return STTBroadcastEnvelope(
            presetID: presetID,
            apiKey: hasSTTKey ? sttKey : nil,
            customModel: getCustomModel(forPresetID: presetID),
            ttsProviderID: tts.providerID,
            ttsApiKey: tts.apiKey,
            ttsVoice: tts.voice,
            ttsCustomModel: tts.customModel,
            timestamp: Date().timeIntervalSinceReferenceDate
        )
    }

    // MARK: - STT Custom Model Override (App Groups + iCloud KVS)
    //
    // The per-preset optional model override (Feature 1). Non-secret →
    // App Groups UserDefaults + iCloud KVS dual-write (mirrors
    // `preferredLanguage`). Empty string = "no override" → the provider's
    // pinned default `model`. Stored under `Constants.sttCustomModelKey(for:)`
    // (`stt.customModel.<presetID>`) in BOTH stores so it rides iCloud across
    // the user's devices. Resolved inside `activeSTTSnapshot()` so key +
    // provider + model bind in one actor hop (preserves the torn-read fix).

    /// Read a preset's custom model override. Nil = no override (the provider's
    /// pinned default applies). Reads App Groups `defaults` (hydrated by the
    /// dual-write setter + the KVS observer) for synchronous, cheap access.
    func getCustomModel(forPresetID presetID: String) -> String? {
        let value = defaults.string(forKey: Constants.sttCustomModelKey(for: presetID))
        // Treat empty string as "no override" so a stale empty write doesn't
        // pin the user to an invalid empty-string model.
        return (value?.isEmpty == false) ? value : nil
    }

    /// Write a preset's custom model override. Dual-writes to KVS + local App
    /// Groups UserDefaults so reads are synchronous on subsequent launches, and
    /// posts `.settingsDidChangeRemotely` so observers (`SettingsViewModel`,
    /// `PhoneSessionManager` re-broadcast) react. Pass nil / empty to clear.
    func setCustomModel(_ value: String?, forPresetID presetID: String) {
        let key = Constants.sttCustomModelKey(for: presetID)
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: key)
            if iCloudAvailable {
                iCloudStore.set(value, forKey: key)
            }
        } else {
            defaults.removeObject(forKey: key)
            if iCloudAvailable {
                iCloudStore.removeObject(forKey: key)
            }
        }
        postSettingsDidChangeRemotely()
    }

    // MARK: - Custom OpenAI-compatible STT endpoint (BYO) — accessors
    //
    // Storage for the 7th provider (`STTProvider.customOpenAICompat`, id
    // `custom-openai`). Cloned from the `remoteAgent*` gateway accessors:
    //   - URL / model / auth scheme → App Groups + iCloud KVS (non-secret;
    //     rides iCloud across the user's devices, mirrors the gateway URL).
    //   - Cert fingerprint → App Groups local only (per-device pin, NO KVS —
    //     mirrors `remoteAgentCertFingerprintKey`).
    //   - API key → the EXISTING generic per-preset STT Keychain plumbing
    //     (account `stt.apiKey.custom-openai` via `getAPIKey(forPresetID:)` /
    //     `setAPIKey(_:forPresetID:)`); NO new Keychain code.
    //
    // The stored URL is the BASE url (user never types the path);
    // `customSTTTranscribeURL()` appends `/v1/audio/transcriptions`, mirroring
    // how the gateway appends `/v1/models`.

    /// Read the custom STT endpoint's BASE URL the user pasted in Settings.
    /// Nil = not configured. Reads `defaults` first, then falls back to iCloud
    /// KVS so the URL survives a reinstall / hydrates on a fresh device (parity
    /// with `getRemoteAgentURL()`).
    func getCustomSTTURL() -> URL? {
        let key = Constants.customSTTURLKey
        return Self.resolveStoredURL(
            local: defaults.string(forKey: key),
            iCloud: iCloudStore.string(forKey: key),
            iCloudAvailable: iCloudAvailable
        )
    }

    /// Persist the custom STT endpoint's BASE URL. Pass nil to clear.
    /// Dual-writes App Groups + iCloud KVS (so it rides across the user's
    /// devices) and posts `.settingsDidChangeRemotely`. Mirrors
    /// `setRemoteAgentURL(_:)`, write fence included — this URL syncs to KVS
    /// exactly like the gateway's, so it is held to the same policy.
    func setCustomSTTURL(_ url: URL?) {
        let key = Constants.customSTTURLKey
        if let url {
            guard EndpointURLPolicy.isAdmissible(url) else { return }
            defaults.set(url.absoluteString, forKey: key)
            iCloudStore.set(url.absoluteString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Resolve the full transcribe URL for the custom STT endpoint: the stored
    /// BASE url with `/v1/audio/transcriptions` appended. Nil when no base URL
    /// is configured. `URL.appending(path:)` (iOS 16+; Conduck deploys 26.5+)
    /// preserves the user's optional trailing slash and avoids double-slashing,
    /// mirroring how `RemoteAgentClient` appends `v1/chat/completions`. Read
    /// inside `activeSTTSnapshot()` so it can't tear against a concurrent edit.
    func customSTTTranscribeURL() -> URL? {
        guard let base = getCustomSTTURL() else { return nil }
        return base.appending(path: "v1/audio/transcriptions")
    }

    /// Read the custom STT endpoint's optional pinned SHA-256 fingerprint
    /// (lowercase hex). App Groups only (per-device pin, NO KVS — mirrors
    /// `getRemoteAgentCertFingerprint()`).
    func getCustomSTTCertFingerprint() -> String? {
        let raw = defaults.string(forKey: Constants.customSTTCertFingerprintKey)
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Persist the custom STT endpoint's pinned fingerprint. Pass nil / empty
    /// to remove the pin (default ATS chain validation resumes). Stored
    /// lowercase (canonical form — `RemoteAgentTrustEvaluator` lowercases
    /// defensively anyway). App Groups only. Mirrors
    /// `setRemoteAgentCertFingerprint(_:)`.
    func setCustomSTTCertFingerprint(_ fingerprint: String?) {
        if let fingerprint, !fingerprint.isEmpty {
            defaults.set(fingerprint.lowercased(), forKey: Constants.customSTTCertFingerprintKey)
        } else {
            defaults.removeObject(forKey: Constants.customSTTCertFingerprintKey)
        }
        postSettingsDidChangeRemotely()
    }

    /// Read the custom STT endpoint's model. Defaults to `"whisper-1"` (the
    /// de-facto self-hosted Whisper tag) when unset. Reads App Groups
    /// `defaults` for synchronous, cheap access (hydrated by the dual-write
    /// setter + the KVS observer).
    func getCustomSTTModel() -> String {
        let value = defaults.string(forKey: Constants.customSTTModelKey)
        return (value?.isEmpty == false) ? value! : "whisper-1"
    }

    /// Persist the custom STT endpoint's model. Dual-writes App Groups + iCloud
    /// KVS and posts `.settingsDidChangeRemotely`. Pass nil / empty to fall back
    /// to the `"whisper-1"` default.
    func setCustomSTTModel(_ value: String?) {
        let key = Constants.customSTTModelKey
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: key)
            iCloudStore.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Read the custom STT endpoint's auth scheme. `.bearer` (default) or
    /// `.none` (keyless local server). Stored as the raw string `"bearer"` /
    /// `"none"`; an unknown / unset value falls back to `.bearer`
    /// (forward-compat). Reads App Groups `defaults` for synchronous access.
    func getCustomSTTAuthScheme() -> STTAuthScheme {
        let raw = defaults.string(forKey: Constants.customSTTAuthSchemeKey)
        return raw == "none" ? .none : .bearer
    }

    /// Persist the custom STT endpoint's auth scheme. Stores the raw string
    /// (`"bearer"` / `"none"`). Dual-writes App Groups + iCloud KVS and posts
    /// `.settingsDidChangeRemotely`. Only `.bearer` / `.none` are valid for the
    /// BYO endpoint; any other scheme is coerced to `"bearer"`.
    func setCustomSTTAuthScheme(_ scheme: STTAuthScheme) {
        let key = Constants.customSTTAuthSchemeKey
        let raw = (scheme == .none) ? "none" : "bearer"
        defaults.set(raw, forKey: key)
        iCloudStore.set(raw, forKey: key)
        postSettingsDidChangeRemotely()
    }

    // MARK: - Custom OpenAI-compatible TTS endpoint (BYO) — accessors
    //
    // The custom TTS endpoint (`TTSProvider.customOpenAITTS`) SHARES the custom
    // STT endpoint's base URL (`getCustomSTTURL()`), API key
    // (`stt.apiKey.custom-openai`), cert pin (`getCustomSTTCertFingerprint()`),
    // and auth scheme (`getCustomSTTAuthScheme()`) — one server, both directions.
    // Only the synthesis PATH (`/v1/audio/speech`) and the MODEL differ from STT.

    /// Resolve the full synthesis URL for the custom TTS endpoint: the SHARED
    /// custom-STT base URL with `/v1/audio/speech` appended. Nil when no base URL
    /// is configured. Mirrors `customSTTTranscribeURL()` (which appends
    /// `/v1/audio/transcriptions` to the same base). Read inside
    /// `activeTTSSnapshot()` so it can't tear against a concurrent edit.
    func customTTSSpeechURL() -> URL? {
        guard let base = getCustomSTTURL() else { return nil }
        return base.appending(path: "v1/audio/speech")
    }

    /// Read the custom TTS endpoint's model. Defaults to `"tts-1"` (the de-facto
    /// OpenAI-compatible speech model tag) when unset. Reads App Groups `defaults`
    /// for synchronous, cheap access (hydrated by the dual-write setter + the KVS
    /// observer). Distinct from `getCustomSTTModel()` — the same server usually
    /// exposes different STT vs TTS model tags.
    func getCustomTTSModel() -> String {
        let value = defaults.string(forKey: Constants.customTTSModelKey)
        return (value?.isEmpty == false) ? value! : "tts-1"
    }

    /// Persist the custom TTS endpoint's model. Dual-writes App Groups + iCloud
    /// KVS and posts `.settingsDidChangeRemotely`. Pass nil / empty to fall back
    /// to the `"tts-1"` default. Mirrors `setCustomSTTModel(_:)`.
    func setCustomTTSModel(_ value: String?) {
        let key = Constants.customTTSModelKey
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: key)
            iCloudStore.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Resolve the full BYO custom TTS config (URL + model + shared auth + shared
    /// cert pin) in one actor hop. Used by `activeTTSSnapshot()` AND the Settings
    /// "Speak a sample" preview (which auditions a SPECIFIC provider that may not
    /// be the active one). The URL/auth/cert are shared with custom STT; only the
    /// model is TTS-specific. Mirrors how `activeSTTSnapshot()` assembles
    /// `CustomSTTConfig`.
    func customTTSConfig() -> CustomTTSConfig {
        CustomTTSConfig(
            url: customTTSSpeechURL(),
            model: getCustomTTSModel(),
            auth: getCustomSTTAuthScheme(),
            certFingerprint: getCustomSTTCertFingerprint()
        )
    }

    // MARK: - Custom voice endpoints (BYO) — per-uuid accessors (Phase B)
    //
    // `for uuid:` variants of the singleton custom-STT / custom-TTS accessors.
    // Each reads/writes the per-uuid slot (`Constants.customSTTURLKey(for:)`
    // etc.). The zero-arg legacy versions above remain for migration-read only.
    // Same dual-write / cert-per-device posture as the singletons.

    /// Read the per-uuid custom endpoint's BASE URL. Nil = not configured.
    func getCustomSTTURL(for uuid: UUID) -> URL? {
        let key = Constants.customSTTURLKey(for: uuid)
        return Self.resolveStoredURL(
            local: defaults.string(forKey: key),
            iCloud: iCloudStore.string(forKey: key),
            iCloudAvailable: iCloudAvailable
        )
    }

    /// Persist the per-uuid custom endpoint's BASE URL. Pass nil to clear.
    /// Write fence as on `setCustomSTTURL(_:)`.
    func setCustomSTTURL(_ url: URL?, for uuid: UUID) {
        let key = Constants.customSTTURLKey(for: uuid)
        if let url {
            guard EndpointURLPolicy.isAdmissible(url) else { return }
            defaults.set(url.absoluteString, forKey: key)
            iCloudStore.set(url.absoluteString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Full STT transcribe URL for the per-uuid endpoint (base + path).
    func customSTTTranscribeURL(for uuid: UUID) -> URL? {
        guard let base = getCustomSTTURL(for: uuid) else { return nil }
        return base.appending(path: "v1/audio/transcriptions")
    }

    /// Full TTS synthesis URL for the per-uuid endpoint (shared base + path).
    func customTTSSpeechURL(for uuid: UUID) -> URL? {
        guard let base = getCustomSTTURL(for: uuid) else { return nil }
        return base.appending(path: "v1/audio/speech")
    }

    /// Read the per-uuid endpoint's pinned SHA-256 fingerprint. App Groups only.
    func getCustomSTTCertFingerprint(for uuid: UUID) -> String? {
        let raw = defaults.string(forKey: Constants.customSTTCertFingerprintKey(for: uuid))
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Persist the per-uuid endpoint's pinned fingerprint. Pass nil/empty to clear.
    func setCustomSTTCertFingerprint(_ fingerprint: String?, for uuid: UUID) {
        let key = Constants.customSTTCertFingerprintKey(for: uuid)
        if let fingerprint, !fingerprint.isEmpty {
            defaults.set(fingerprint.lowercased(), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Read the per-uuid endpoint's STT model (default `whisper-1`).
    func getCustomSTTModel(for uuid: UUID) -> String {
        let value = defaults.string(forKey: Constants.customSTTModelKey(for: uuid))
        return (value?.isEmpty == false) ? value! : "whisper-1"
    }

    /// Persist the per-uuid endpoint's STT model. Pass nil/empty for `whisper-1`.
    func setCustomSTTModel(_ value: String?, for uuid: UUID) {
        let key = Constants.customSTTModelKey(for: uuid)
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: key)
            iCloudStore.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Read the per-uuid endpoint's TTS model (default `tts-1`).
    func getCustomTTSModel(for uuid: UUID) -> String {
        let value = defaults.string(forKey: Constants.customTTSModelKey(for: uuid))
        return (value?.isEmpty == false) ? value! : "tts-1"
    }

    /// Persist the per-uuid endpoint's TTS model. Pass nil/empty for `tts-1`.
    func setCustomTTSModel(_ value: String?, for uuid: UUID) {
        let key = Constants.customTTSModelKey(for: uuid)
        if let value = value, !value.isEmpty {
            defaults.set(value, forKey: key)
            iCloudStore.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Read the per-uuid endpoint's auth scheme (`.bearer` default / `.none`).
    func getCustomSTTAuthScheme(for uuid: UUID) -> STTAuthScheme {
        let raw = defaults.string(forKey: Constants.customSTTAuthSchemeKey(for: uuid))
        return raw == "none" ? .none : .bearer
    }

    /// Persist the per-uuid endpoint's auth scheme (`"bearer"` / `"none"`).
    func setCustomSTTAuthScheme(_ scheme: STTAuthScheme, for uuid: UUID) {
        let key = Constants.customSTTAuthSchemeKey(for: uuid)
        let raw = (scheme == .none) ? "none" : "bearer"
        defaults.set(raw, forKey: key)
        iCloudStore.set(raw, forKey: key)
        postSettingsDidChangeRemotely()
    }

    /// Resolve the full per-uuid custom STT config (URL + model + auth + cert).
    func customSTTConfig(for uuid: UUID) -> CustomSTTConfig {
        CustomSTTConfig(
            url: customSTTTranscribeURL(for: uuid),
            model: getCustomSTTModel(for: uuid),
            auth: getCustomSTTAuthScheme(for: uuid),
            certFingerprint: getCustomSTTCertFingerprint(for: uuid)
        )
    }

    /// Resolve the full per-uuid custom TTS config (URL + model + shared auth +
    /// shared cert). Mirrors `customTTSConfig()` (singleton).
    func customTTSConfig(for uuid: UUID) -> CustomTTSConfig {
        CustomTTSConfig(
            url: customTTSSpeechURL(for: uuid),
            model: getCustomTTSModel(for: uuid),
            auth: getCustomSTTAuthScheme(for: uuid),
            certFingerprint: getCustomSTTCertFingerprint(for: uuid)
        )
    }

    // MARK: - Custom voice endpoints — Registry (App-Group JSON + iCloud KVS)
    //
    // Clone of the custom-gateway roster CRUD. The roster JSON (id / name only)
    // is dual-written; per-uuid URL/key/cert/model/auth ride the per-uuid slots
    // above. The migration (`ensureCustomVoiceEndpointMigrated`) runs at the top
    // of `customVoiceEndpoints()` + the snapshots so any read path triggers it.

    /// The persisted custom voice-endpoint roster (id / name). App Groups first
    /// (durable), iCloud KVS fallback (fresh device / reinstall) — same read
    /// order as `persistedCustomGateways()`. Runs the one-time migration first.
    func customVoiceEndpoints() -> [CustomVoiceEndpoint] {
        ensureCustomVoiceEndpointMigrated()
        if let data = defaults.data(forKey: Constants.customVoiceEndpointsRegistryKey),
           let list = try? JSONDecoder().decode([CustomVoiceEndpoint].self, from: data) {
            return list
        }
        if iCloudAvailable,
           let data = iCloudStore.data(forKey: Constants.customVoiceEndpointsRegistryKey),
           let list = try? JSONDecoder().decode([CustomVoiceEndpoint].self, from: data) {
            return list
        }
        return []
    }

    /// One endpoint by id, or nil if absent (deleted / never created).
    func customVoiceEndpoint(id: UUID) -> CustomVoiceEndpoint? {
        customVoiceEndpoints().first { $0.id == id }
    }

    /// The endpoint count (for the cap UI gate).
    func customVoiceEndpointCount() -> Int {
        customVoiceEndpoints().count
    }

    /// Add or update an endpoint's ROSTER fields (name). Per-uuid URL/key/cert/
    /// model/auth are persisted separately via the per-uuid setters at the call
    /// site. ADD is capped at `Constants.maxCustomVoiceEndpoints` — returns
    /// `false` (UI surfaces the cap hint) when full; UPDATE never trips the cap.
    @discardableResult
    func upsertCustomVoiceEndpoint(_ endpoint: CustomVoiceEndpoint) -> Bool {
        var list = customVoiceEndpoints()
        if let index = list.firstIndex(where: { $0.id == endpoint.id }) {
            list[index] = endpoint
        } else {
            guard list.count < Constants.maxCustomVoiceEndpoints else { return false }
            list.append(endpoint)
        }
        persistCustomVoiceEndpoints(list)
        return true
    }

    /// Delete an endpoint: clears ALL its per-uuid slots (URL / key / cert /
    /// STT model / TTS model / auth) AND its roster entry. If the deleted
    /// endpoint was the active STT or TTS pointer, fall that pointer back to
    /// APPLE (stricter than the gateway fallback — a custom voice endpoint has
    /// no built-in sibling to inherit, and Apple is the universal default).
    func deleteCustomVoiceEndpoint(id: UUID) {
        let sttPresetID = STTProvider.customEndpointID(for: id)
        let ttsProviderID = TTSProvider.customEndpointID(for: id)

        // Clear the per-uuid non-secret slots.
        setCustomSTTURL(nil, for: id)
        setCustomSTTCertFingerprint(nil, for: id)
        setCustomSTTModel(nil, for: id)
        setCustomTTSModel(nil, for: id)
        defaults.removeObject(forKey: Constants.customSTTAuthSchemeKey(for: id))
        iCloudStore.removeObject(forKey: Constants.customSTTAuthSchemeKey(for: id))
        // Clear the shared Keychain key slot.
        try? clearAPIKey(forPresetID: sttPresetID)
        // Clear the per-provider TTS voice override slot (App Groups + KVS).
        defaults.removeObject(forKey: Constants.ttsVoiceKey(for: ttsProviderID))
        iCloudStore.removeObject(forKey: Constants.ttsVoiceKey(for: ttsProviderID))

        var list = customVoiceEndpoints()
        list.removeAll { $0.id == id }
        persistCustomVoiceEndpoints(list)

        // Fall the active pointers back to Apple if they pointed at this endpoint.
        if getActivePresetID() == sttPresetID {
            setActivePresetID(Constants.sttActivePresetIDDefault)   // apple-on-device
        }
        if getActiveTTSProviderID() == ttsProviderID {
            setActiveTTSProviderID(Constants.ttsActiveProviderIDDefault)   // apple-tts
        }
    }

    private func persistCustomVoiceEndpoints(_ list: [CustomVoiceEndpoint]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Constants.customVoiceEndpointsRegistryKey)
            iCloudStore.set(data, forKey: Constants.customVoiceEndpointsRegistryKey)
        }
        postSettingsDidChangeRemotely()
    }

    // MARK: - Custom voice endpoint migration (single-custom → roster)

    /// Self-trigger the single-custom → roster migration on the first roster /
    /// snapshot read in THIS process. The in-memory latch avoids re-reading the
    /// persistent flag on every access; the App Groups
    /// `customVoiceEndpointMigratedKey` is the real cross-process / cross-launch
    /// once-ever guard inside the migration. MUST run AFTER `ensureKeychainMigrated`
    /// (the keychain-sync migration makes the legacy `stt.apiKey.custom-openai`
    /// synchronizable so the per-uuid key copy can read it).
    private func ensureCustomVoiceEndpointMigrated() {
        guard !didAttemptCustomVoiceEndpointMigration else { return }
        didAttemptCustomVoiceEndpointMigration = true
        // SELF-ENFORCE the precondition: the migration's `copyLegacyCustomKeyToPerUUID`
        // reads the legacy `stt.apiKey.custom-openai` item, which the keychain-sync
        // migration must have promoted first — else the synchronizable read misses,
        // `errSecItemNotFound` reads as "no key", the latch sets, and the per-uuid
        // key is silently never copied (key loss). The snapshot entry points already
        // pair the two calls, but `customVoiceEndpoints()` can be the first read in
        // a process — so guarantee ordering here. The inner latch dedupes the
        // redundant call.
        ensureKeychainMigrated()
        migrateCustomVoiceEndpoint()
    }

    /// One-time, guarded migration converting the LEGACY single custom endpoint
    /// (`stt.custom.*` slots + `stt.apiKey.custom-openai` + active `custom-openai`
    /// / `custom-openai-tts` pointers) into roster endpoint #1. Clone of
    /// `migrateRemoteAgentToPerBackend` shape:
    ///   - Legacy URL empty (fresh install) → set flag, done (no endpoint).
    ///   - Legacy URL present → mint endpoint #1 ("Custom endpoint"), PERSIST the
    ///     roster + copy the non-secret slots + REPOINT the active pointers
    ///     BEFORE the keychain key-copy. Persisting first makes a retried partial
    ///     pass reuse the SAME uuid (no duplicate endpoints). Then gate the flag
    ///     on the keychain copy outcome (`copyLegacyCustomKeyToPerUUID`): set the
    ///     flag only if the copy confirms (or there was no key); else leave it
    ///     unset so the next launch retries the (idempotent) pass.
    private func migrateCustomVoiceEndpoint() {
        // Persistent once-ever guard.
        guard !defaults.bool(forKey: Constants.customVoiceEndpointMigratedKey) else {
            return
        }

        // No legacy base URL = fresh install (or single custom never configured).
        // Mark migrated; no endpoint created.
        guard let legacyURL = getCustomSTTURL() else {
            defaults.set(true, forKey: Constants.customVoiceEndpointMigratedKey)
            return
        }

        // Reuse an already-persisted endpoint #1 on a retried partial pass
        // (persist-first guarantees the uuid is stable). Else mint a fresh one.
        let existing = (try? JSONDecoder().decode(
            [CustomVoiceEndpoint].self,
            from: defaults.data(forKey: Constants.customVoiceEndpointsRegistryKey) ?? Data()
        )) ?? []
        let endpoint = existing.first ?? CustomVoiceEndpoint(
            id: UUID(),
            name: String(localized: "settings.voice.custom.defaultName", defaultValue: "Custom endpoint")
        )
        let uuid = endpoint.id

        // Persist the roster FIRST (idempotent — overwrites with the same record).
        if existing.first(where: { $0.id == uuid }) == nil {
            persistCustomVoiceEndpoints(existing + [endpoint])
        }

        // Copy the non-secret slots into the per-uuid slots (idempotent).
        setCustomSTTURL(legacyURL, for: uuid)
        setCustomSTTModel(getCustomSTTModel(), for: uuid)
        setCustomTTSModel(getCustomTTSModel(), for: uuid)
        setCustomSTTAuthScheme(getCustomSTTAuthScheme(), for: uuid)
        if let legacyCert = getCustomSTTCertFingerprint() {
            setCustomSTTCertFingerprint(legacyCert, for: uuid)
        }

        // Repoint the active pointers (bare legacy id → per-uuid id) so the
        // active endpoint keeps working after the bare id stops resolving config.
        if getActivePresetID() == STTProvider.customOpenAICompat.id {
            setActivePresetID(STTProvider.customEndpointID(for: uuid))
        }
        if getActiveTTSProviderID() == TTSProvider.customOpenAITTS.id {
            setActiveTTSProviderID(TTSProvider.customEndpointID(for: uuid))
        }

        // Keychain key copy — the only signing-gated step. Gate the flag on it.
        let keyCopySucceeded = copyLegacyCustomKeyToPerUUID(uuid)
        if keyCopySucceeded {
            defaults.set(true, forKey: Constants.customVoiceEndpointMigratedKey)
        }
        // else: leave the flag unset — next launch retries the idempotent pass
        // (the persisted roster keeps the same uuid, so no duplicate endpoint).
    }

    /// Copy the legacy synchronizable STT key (account
    /// `stt.apiKey.custom-openai`) into the per-uuid slot
    /// (`stt.apiKey.custom-openai_<uuid>`) via `SecItemAdd`, tolerating
    /// `errSecDuplicateItem`. Does NOT delete the legacy item (a mid-migration
    /// second device must still find it). Mirrors
    /// `copyLegacyRemoteAgentTokenToPerBackend`.
    ///
    /// Returns `true` when there was no legacy key (read `errSecItemNotFound` —
    /// nothing keychain-gated), or the copy confirmed
    /// (`errSecSuccess` / `errSecDuplicateItem`); `false` on any other failure
    /// (locked keychain, missing entitlement) → caller leaves the flag unset.
    private func copyLegacyCustomKeyToPerUUID(_ uuid: UUID) -> Bool {
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.sttApiKeyKeychainAccount(for: STTProvider.customOpenAICompat.id),
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let (readStatus, result) = secrets.copyMatching(readQuery)

        if readStatus == errSecItemNotFound {
            return true   // keyless / no legacy key — nothing to wait on.
        }
        guard readStatus == errSecSuccess, let data = result as? Data else {
            return false   // locked keychain / unexpected — retry next launch.
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.sttApiKeyKeychainAccount(for: STTProvider.customEndpointID(for: uuid)),
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        let addStatus = secrets.add(addQuery)
        return addStatus == errSecSuccess || addStatus == errSecDuplicateItem
    }

    /// Test-only seam: reset the in-process latch + run the migration
    /// synchronously, returning whether the persistent flag is set afterward.
    /// Mirrors `runRemoteAgentMigrationForTesting()`. NOT used by app code.
    func runCustomVoiceEndpointMigrationForTesting() -> Bool {
        ensureKeychainMigrated()
        didAttemptCustomVoiceEndpointMigration = false
        ensureCustomVoiceEndpointMigrated()
        return defaults.bool(forKey: Constants.customVoiceEndpointMigratedKey)
    }

    /// Test-only seam: reset ONLY the in-process migration latch WITHOUT running
    /// the migration (mirrors `resetRemoteAgentMigrationLatchForTesting()`).
    func resetCustomVoiceEndpointMigrationLatchForTesting() {
        didAttemptCustomVoiceEndpointMigration = false
    }

    // MARK: - Remote Agent (Personal AI) — accessors
    //
    // Settings: Personal AI. Mirrors the STT per-preset Keychain +
    // App Groups / KVS shape (lines 93–179 + 281–328 above). Storage layout:
    //   - Backend / URL / fingerprint / activeSessionID → App Groups
    //     UserDefaults (`Constants.remoteAgent*Key`). Pull-only on Watch
    //     via the envelope.
    //   - Token → Keychain account `Constants.remoteAgentTokenKeychainAccount`
    //     with `kSecAttrAccessibleAfterFirstUnlock` (Watch cold-launch
    //     parity with the STT key slot).
    //
    // No `mutate-and-not-post` mutations — every writer posts
    // `.settingsDidChangeRemotely` so `PhoneSessionManager`'s existing
    // observer enqueues a Watch re-broadcast and `SettingsViewModel`
    // refreshes from a single source.

    /// Read the user-selected backend, or nil if Settings has never been
    /// configured. Forward-compat: an unknown raw value returns nil so a
    /// future schema addition can ride alongside V1 without crashing here.
    func getRemoteAgentBackend() -> RemoteAgentBackend? {
        guard let raw = defaults.string(forKey: Constants.remoteAgentBackendKey),
              let backend = RemoteAgentBackend(rawValue: raw) else {
            return nil
        }
        return backend
    }

    /// Persist the user-selected backend. Pass nil to clear (used by
    /// `clearRemoteAgent`-style flows). Dual-writes to iCloud KVS
    /// so the Watch resolves the backend on a cold ControlWidget launch with no
    /// live envelope (cold-launch fix).
    func setRemoteAgentBackend(_ backend: RemoteAgentBackend?) {
        if let backend {
            defaults.set(backend.rawValue, forKey: Constants.remoteAgentBackendKey)
            iCloudStore.set(backend.rawValue, forKey: Constants.remoteAgentBackendKey)
        } else {
            defaults.removeObject(forKey: Constants.remoteAgentBackendKey)
            iCloudStore.removeObject(forKey: Constants.remoteAgentBackendKey)
        }
        postSettingsDidChangeRemotely()
    }

    /// Pure resolution of a stored endpoint URL: local App Groups `defaults`
    /// wins; else iCloud KVS (only when iCloud is available). Mirrors the
    /// defaults-first-then-KVS-fallback pattern of `getActivePresetID()` /
    /// `defaultRemoteAgentBackend()` — the gateway URL is the one synced
    /// setting that previously read `defaults` only, so it vanished on a
    /// reinstall (wiped App Group container) even though the setter had
    /// dual-written it to KVS. Pure + static so it is unit-testable headless
    /// (the live KVS + `iCloudAvailable` path can't run unsigned).
    ///
    /// This is the READ FENCE for every URL Conduck persists — the gateway URL
    /// (legacy + per-ref), the file-server URL, and the custom voice-endpoint
    /// URL all resolve through it. A stored string is admitted only if it still
    /// satisfies `EndpointURLPolicy` (https + real host + no `user:password@`),
    /// so a value written before that policy existed — or synced in through KVS
    /// by a version-skewed peer device running an older build — can never be
    /// requested, whatever the write-side guards on THIS build do.
    ///
    /// An inadmissible value is SKIPPED, not terminal: a contaminated local
    /// value must still fall through to a clean KVS one (and vice versa), or a
    /// single bad slot on one device would mask a perfectly good synced config.
    static func resolveStoredURL(local: String?, iCloud: String?, iCloudAvailable: Bool) -> URL? {
        if let url = EndpointURLPolicy.admissibleURL(from: local) {
            return url
        }
        if iCloudAvailable, let url = EndpointURLPolicy.admissibleURL(from: iCloud) {
            return url
        }
        return nil
    }

    /// Read the gateway base URL the user pasted in Settings. Nil = not
    /// configured. Reads `defaults` first, then falls back to iCloud KVS so the
    /// URL survives a reinstall / hydrates on a fresh device (parity with the
    /// preset / default-backend getters).
    func getRemoteAgentURL() -> URL? {
        let key = Constants.remoteAgentURLKey
        return Self.resolveStoredURL(
            local: defaults.string(forKey: key),
            iCloud: iCloudStore.string(forKey: key),
            iCloudAvailable: iCloudAvailable
        )
    }

    /// Persist the gateway base URL. Pass nil to clear. Dual-writes to iCloud
    /// KVS so the Watch resolves the URL on a cold ControlWidget launch
    /// with no live envelope (cold-launch fix).
    ///
    /// WRITE FENCE (all persisted-URL setters carry it): an inadmissible URL is
    /// REFUSED outright — neither store is touched and no change is posted. The
    /// UI guards upstream give the user an actionable reason; this one exists so
    /// a migration, a background path, or a future caller cannot reintroduce the
    /// privacy bug silently. Refusing rather than clearing keeps a good stored
    /// value intact when a bad write is attempted over it. See
    /// `EndpointURLPolicy`.
    ///
    /// Returns `false` iff the fence refused the write, so a caller that
    /// reports "saved" can tell the difference between a persisted URL and a
    /// rejected one. Clearing (nil) always succeeds. `@discardableResult`
    /// because migrations and teardown paths legitimately ignore it.
    @discardableResult
    func setRemoteAgentURL(_ url: URL?) -> Bool {
        if let url {
            guard EndpointURLPolicy.isAdmissible(url) else { return false }
            defaults.set(url.absoluteString, forKey: Constants.remoteAgentURLKey)
            iCloudStore.set(url.absoluteString, forKey: Constants.remoteAgentURLKey)
        } else {
            defaults.removeObject(forKey: Constants.remoteAgentURLKey)
            iCloudStore.removeObject(forKey: Constants.remoteAgentURLKey)
        }
        postSettingsDidChangeRemotely()
        return true
    }

    /// Read the gateway bearer token from Keychain. Returns nil if the
    /// slot is empty or Keychain is locked. Privacy: NEVER log the value.
    func getRemoteAgentToken() -> String? {
        // Migrate before the first token read in this process — covers the
        // headless converse path (Shortcuts intent / CarPlay) that reads the
        // bearer token without running the app's launch wiring.
        ensureKeychainMigrated()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.remoteAgentTokenKeychainAccount,
            // iCloud-Keychain-synced item (Part B) — every steady-state token op
            // carries this flag so it round-trips against the same synchronizable
            // item the setter / migration created.
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let (status, result) = secrets.copyMatching(query)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Write the gateway bearer token to Keychain with
    /// `kSecAttrAccessibleAfterFirstUnlock` (Watch ControlWidget cold-
    /// launch parity with the STT key slot).
    /// - Throws: `AppError.settingsLoadFailed` on Keychain failure.
    func setRemoteAgentToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw AppError.settingsLoadFailed
        }

        let account = Constants.remoteAgentTokenKeychainAccount
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account,
            // iCloud-Keychain-synced item (Part B) — the update query AND the add
            // (below, built from this `query`) must both carry the flag so the
            // token syncs across the user's iPhone/iPad/Mac.
            kSecAttrSynchronizable as String: true
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = secrets.update(query, attributes: attributes)

        if updateStatus == errSecSuccess {
            postSettingsDidChangeRemotely()
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Accessibility immutable after add — set at add time.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = secrets.add(addQuery)
            guard addStatus == errSecSuccess else {
                throw AppError.settingsLoadFailed
            }
            postSettingsDidChangeRemotely()
            return
        }

        throw AppError.settingsLoadFailed
    }

    /// Remove the gateway bearer token from Keychain. No-op if already
    /// absent; throws only on a real Keychain failure.
    func clearRemoteAgentToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.remoteAgentTokenKeychainAccount,
            // Match the synchronizable item (Part B) — a non-sync delete would
            // miss the iCloud-synced token, leaving it alive on other devices.
            kSecAttrSynchronizable as String: true
        ]

        let status = secrets.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.settingsLoadFailed
        }
        if status == errSecSuccess {
            postSettingsDidChangeRemotely()
        }
    }

    /// Read the optional pinned SHA-256 fingerprint (lowercase hex).
    func getRemoteAgentCertFingerprint() -> String? {
        let raw = defaults.string(forKey: Constants.remoteAgentCertFingerprintKey)
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Persist the pinned fingerprint. Pass nil / empty to remove the pin
    /// (default ATS chain validation resumes).
    func setRemoteAgentCertFingerprint(_ fingerprint: String?) {
        if let fingerprint, !fingerprint.isEmpty {
            // Normalise to lowercase — `RemoteAgentTrustEvaluator` does
            // a defensive `.lowercased()` compare anyway, but storing
            // canonical-form means tests / debugging see a single shape.
            defaults.set(fingerprint.lowercased(), forKey: Constants.remoteAgentCertFingerprintKey)
        } else {
            defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey)
        }
        postSettingsDidChangeRemotely()
    }

    // MARK: - Remote Agent (Personal AI) — Per-Backend (multi-gateway) accessors
    //
    // Multi-gateway: each backend (OpenClaw / Hermes) owns its own URL / token /
    // cert slot keyed by raw value, so both can be configured at once. Exact
    // parameterized clones of the single-slot block above + the STT per-preset
    // shape (`getAPIKey(forPresetID:)` etc.). The single-slot accessors above
    // are RETAINED — the migration reads them; later work rewires call sites.
    //
    // The active-conversation/session pointer stays GLOBAL — it is
    // NOT cloned per backend; `remoteAgentSnapshot(for:)` reads the global
    // session slot.

    /// Read a SPECIFIC backend's gateway URL. Nil = not configured for that
    /// backend. Reads `defaults` first, then falls back to iCloud KVS (parity
    /// with the preset / default-backend getters) so the URL survives a
    /// reinstall / hydrates on a fresh device — the setter dual-writes to KVS,
    /// and `configuredRemoteAgentBackends()` gates on this URL, so a missing
    /// fallback made the gateway read "not configured" after uninstall.
    func getRemoteAgentURL(for ref: RemoteAgentRef) -> URL? {
        // Fixed-endpoint built-ins (hosted-model backends like OpenRouter) are
        // AUTHORITATIVE on the descriptor's app-fixed URL — a stored value (from
        // pairing / KVS / a stale write) must NEVER override it. Self-hosted
        // built-ins (OpenClaw / Hermes, `fixedURL == nil`) and customs fall
        // through to the stored-slot resolution below unchanged.
        if case .builtin(let backend) = ref,
           let fixedURL = RemoteAgentBackendRegistry.lookup(id: backend).fixedURL {
            return fixedURL
        }
        let key = Constants.remoteAgentURLKey(for: ref)
        return Self.resolveStoredURL(
            local: defaults.string(forKey: key),
            iCloud: iCloudStore.string(forKey: key),
            iCloudAvailable: iCloudAvailable
        )
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    func getRemoteAgentURL(for backend: RemoteAgentBackend) -> URL? {
        getRemoteAgentURL(for: .builtin(backend))
    }

    /// Persist a SPECIFIC backend's gateway URL. Pass nil to clear. Dual-writes
    /// App Groups + iCloud KVS (cold-launch parity) and posts
    /// `.settingsDidChangeRemotely`. Carries the write fence documented on
    /// `setRemoteAgentURL(_:)` — this is the setter that actually puts a gateway
    /// URL into KVS, so it is the last line before a credential-bearing string
    /// would leave the Keychain boundary.
    ///
    /// Returns `false` iff the fence refused the write — see
    /// `setRemoteAgentURL(_:)` for why the caller needs to know.
    @discardableResult
    func setRemoteAgentURL(_ url: URL?, for ref: RemoteAgentRef) -> Bool {
        let key = Constants.remoteAgentURLKey(for: ref)
        if let url {
            guard EndpointURLPolicy.isAdmissible(url) else { return false }
            defaults.set(url.absoluteString, forKey: key)
            iCloudStore.set(url.absoluteString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
        return true
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    @discardableResult
    func setRemoteAgentURL(_ url: URL?, for backend: RemoteAgentBackend) -> Bool {
        setRemoteAgentURL(url, for: .builtin(backend))
    }

    /// Read a SPECIFIC ref's `model` slot. Nil = none stored. Reads `defaults`
    /// first, then falls back to iCloud KVS (parity with the URL getter so a
    /// hosted-model backend's model survives a reinstall / hydrates on a fresh
    /// device). Only hosted-model built-ins (OpenRouter) write here; OpenClaw /
    /// Hermes never do, and customs keep their model on the roster entry. An
    /// empty stored value resolves to nil (treated as "none").
    func getRemoteAgentModel(for ref: RemoteAgentRef) -> String? {
        let key = Constants.remoteAgentModelKey(for: ref)
        let stored = defaults.string(forKey: key)
            ?? (iCloudAvailable ? iCloudStore.string(forKey: key) : nil)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    /// Persist a SPECIFIC ref's `model`. Pass nil — or an empty string — to
    /// clear. Dual-writes App Groups + iCloud KVS (cold-launch parity,
    /// mirroring `setRemoteAgentURL`) and posts `.settingsDidChangeRemotely`.
    func setRemoteAgentModel(_ model: String?, for ref: RemoteAgentRef) {
        let key = Constants.remoteAgentModelKey(for: ref)
        if let model, !model.isEmpty {
            defaults.set(model, forKey: key)
            iCloudStore.set(model, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Read a SPECIFIC ref's auth scheme. Reads `defaults` first, then iCloud
    /// KVS (parity with the URL getter so a gateway's keyless posture survives a
    /// reinstall / hydrates on a fresh device). A missing / undecodable value
    /// resolves to `.bearer` (fail closed) — keyless is NEVER inferred from
    /// absence (a Keychain token read can fail transiently; an explicit
    /// persisted `.none` is the only keyless signal).
    func getRemoteAgentAuthScheme(for ref: RemoteAgentRef) -> RemoteAgentAuthScheme {
        let key = Constants.remoteAgentAuthSchemeKey(for: ref)
        let raw = defaults.string(forKey: key) ?? (iCloudAvailable ? iCloudStore.string(forKey: key) : nil)
        return RemoteAgentAuthScheme.from(rawValue: raw)
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    func getRemoteAgentAuthScheme(for backend: RemoteAgentBackend) -> RemoteAgentAuthScheme {
        getRemoteAgentAuthScheme(for: .builtin(backend))
    }

    /// Whether ANY raw per-ref config slot is stored (local or KVS) — the
    /// "was this ref ever saved?" probe for save-rollback classification.
    /// Reads the RAW slots deliberately: `getRemoteAgentURL` synthesizes a URL
    /// for fixed-endpoint built-ins and `getRemoteAgentAuthScheme` defaults a
    /// missing value, so neither getter can distinguish "saved before" from
    /// "never touched".
    func hasStoredRemoteAgentSlots(for ref: RemoteAgentRef) -> Bool {
        let urlKey = Constants.remoteAgentURLKey(for: ref)
        let schemeKey = Constants.remoteAgentAuthSchemeKey(for: ref)
        if defaults.string(forKey: urlKey) != nil { return true }
        if defaults.string(forKey: schemeKey) != nil { return true }
        guard iCloudAvailable else { return false }
        return iCloudStore.string(forKey: urlKey) != nil
            || iCloudStore.string(forKey: schemeKey) != nil
    }

    /// Persist a SPECIFIC ref's auth scheme. Dual-writes App Groups + iCloud KVS
    /// (cold-launch parity, mirroring `setRemoteAgentURL`) and posts
    /// `.settingsDidChangeRemotely`. `.bearer` is the default, but it is written
    /// explicitly (not omitted) so a later read never has to distinguish
    /// "defaulted" from "chose bearer".
    func setRemoteAgentAuthScheme(_ scheme: RemoteAgentAuthScheme, for ref: RemoteAgentRef) {
        let key = Constants.remoteAgentAuthSchemeKey(for: ref)
        defaults.set(scheme.rawValue, forKey: key)
        iCloudStore.set(scheme.rawValue, forKey: key)
        postSettingsDidChangeRemotely()
    }

    /// Remove a ref's stored auth scheme so a subsequent read resolves to the
    /// fail-closed `.bearer` default. Called on Forget / delete so a reconfigured
    /// built-in (the ref is reused) never inherits a stale `.none`.
    ///
    /// Also removes the ref's pairing transport HINT
    /// (`remoteAgentTransportHintKey(for:)`, App-Group only): this method is the
    /// shared terminal wipe of BOTH Forget paths (the built-in
    /// `SettingsViewModel.clearRemoteAgent` branch and `deleteCustomGateway`),
    /// and the same staleness argument applies verbatim — a reconfigured
    /// gateway on the reused ref must not inherit a stale "tailscale"/"funnel"
    /// guidance hint from the forgotten config.
    func clearRemoteAgentAuthScheme(for ref: RemoteAgentRef) {
        let key = Constants.remoteAgentAuthSchemeKey(for: ref)
        defaults.removeObject(forKey: key)
        iCloudStore.removeObject(forKey: key)
        // Transport hint is App-Group only (never KVS) — single-store removal.
        defaults.removeObject(forKey: Constants.remoteAgentTransportHintKey(for: ref))
        // Same staleness argument, one step stronger: a reused ref pointed at a
        // DIFFERENT server must never inherit a "chat worked here" record the
        // forgotten gateway earned. The signature guard would already reject it,
        // but leaving it behind means a reconfigured gateway that happens to
        // reproduce the old signature would resurrect a foreign success.
        defaults.removeObject(forKey: Constants.remoteAgentLastChatSuccessKey(for: ref))
        postSettingsDidChangeRemotely()
    }

    /// Read a SPECIFIC backend's bearer token from Keychain. Nil if empty or
    /// Keychain locked. Privacy: NEVER log the value. Runs both migrations
    /// first (keychain-sync THEN multi-gateway) so a headless process that
    /// never ran launch wiring still sees a migrated per-backend token.
    func getRemoteAgentToken(for ref: RemoteAgentRef) -> String? {
        ensureKeychainMigrated()
        ensureRemoteAgentMigrated()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.remoteAgentTokenKeychainAccount(for: ref),
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let (status, result) = secrets.copyMatching(query)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    func getRemoteAgentToken(for backend: RemoteAgentBackend) -> String? {
        getRemoteAgentToken(for: .builtin(backend))
    }

    /// Write a SPECIFIC backend's bearer token to Keychain with
    /// `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable`.
    /// - Throws: `AppError.settingsLoadFailed` on Keychain failure.
    func setRemoteAgentToken(_ token: String, for ref: RemoteAgentRef) throws {
        guard let data = token.data(using: .utf8) else {
            throw AppError.settingsLoadFailed
        }

        let account = Constants.remoteAgentTokenKeychainAccount(for: ref)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = secrets.update(query, attributes: attributes)

        if updateStatus == errSecSuccess {
            postSettingsDidChangeRemotely()
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = secrets.add(addQuery)
            guard addStatus == errSecSuccess else {
                throw AppError.settingsLoadFailed
            }
            postSettingsDidChangeRemotely()
            return
        }

        throw AppError.settingsLoadFailed
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    func setRemoteAgentToken(_ token: String, for backend: RemoteAgentBackend) throws {
        try setRemoteAgentToken(token, for: .builtin(backend))
    }

    /// Remove a SPECIFIC gateway's bearer token from Keychain. No-op if absent;
    /// throws only on a real Keychain failure.
    func clearRemoteAgentToken(for ref: RemoteAgentRef) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.remoteAgentTokenKeychainAccount(for: ref),
            kSecAttrSynchronizable as String: true
        ]

        let status = secrets.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.settingsLoadFailed
        }
        if status == errSecSuccess {
            postSettingsDidChangeRemotely()
        }
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    func clearRemoteAgentToken(for backend: RemoteAgentBackend) throws {
        try clearRemoteAgentToken(for: .builtin(backend))
    }

    /// Read a SPECIFIC backend's pinned SHA-256 fingerprint (lowercase hex).
    /// App Groups only (per-device pin — NO KVS, mirrors the single-slot cert
    /// posture).
    func getRemoteAgentCertFingerprint(for ref: RemoteAgentRef) -> String? {
        let raw = defaults.string(forKey: Constants.remoteAgentCertFingerprintKey(for: ref))
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    func getRemoteAgentCertFingerprint(for backend: RemoteAgentBackend) -> String? {
        getRemoteAgentCertFingerprint(for: .builtin(backend))
    }

    /// Persist a SPECIFIC backend's pinned fingerprint. Pass nil / empty to
    /// remove the pin (default ATS chain validation resumes). App Groups only.
    func setRemoteAgentCertFingerprint(_ fingerprint: String?, for ref: RemoteAgentRef) {
        let key = Constants.remoteAgentCertFingerprintKey(for: ref)
        if let fingerprint, !fingerprint.isEmpty {
            defaults.set(fingerprint.lowercased(), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    func setRemoteAgentCertFingerprint(_ fingerprint: String?, for backend: RemoteAgentBackend) {
        setRemoteAgentCertFingerprint(fingerprint, for: .builtin(backend))
    }

    /// Read a SPECIFIC ref's transport HINT (raw `PairingPayload.Transport`
    /// value, e.g. `"tailscale"`), imported from a pairing payload. Nil = no
    /// hint imported. App Groups ONLY (per-device guidance hint — NEVER iCloud
    /// KVS, NEVER the broadcast envelope; mirrors
    /// `getRemoteAgentCertFingerprint(for:)`'s single-store posture).
    func getRemoteAgentTransportHint(for ref: RemoteAgentRef) -> String? {
        let raw = defaults.string(forKey: Constants.remoteAgentTransportHintKey(for: ref))
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Read the last recorded successful chat round-trip for a ref, **only if it
    /// still describes the CURRENT configuration**. A caller can therefore never
    /// accidentally trust a success the present config never earned: the
    /// signature comparison is inside the accessor, not left to each reader.
    ///
    /// Nil means "nothing proven from this device under this config" — which is a
    /// legitimate, neutral state (a fresh pairing, a just-edited gateway), never a
    /// failure. Renderers must say so neutrally.
    func getGatewayChatSuccess(for ref: RemoteAgentRef) -> GatewayChatSuccess? {
        guard let data = defaults.data(forKey: Constants.remoteAgentLastChatSuccessKey(for: ref)),
              let record = try? JSONDecoder().decode(GatewayChatSuccess.self, from: data),
              let expected = gatewayChatSuccessSignature(for: ref),
              record.signature == expected
        else { return nil }
        return record
    }

    /// Record a successful chat round-trip. `dispatchSignature` is the signature
    /// captured when the request was SENT — never recomputed here.
    ///
    /// `Why:` a turn can take minutes, and the user can edit the gateway while it
    /// is in flight. Recomputing at landing time would credit the NEW
    /// configuration with a success the OLD one earned, which is precisely the
    /// false claim this whole record exists to avoid. A dispatch signature that no
    /// longer matches the live config is DROPPED rather than stored.
    func recordGatewayChatSuccess(for ref: RemoteAgentRef, dispatchSignature: String, at date: Date = Date()) {
        guard let live = gatewayChatSuccessSignature(for: ref), live == dispatchSignature else { return }
        let record = GatewayChatSuccess(signature: dispatchSignature, at: date)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Constants.remoteAgentLastChatSuccessKey(for: ref))
    }

    /// The signature of the configuration a request is ACTUALLY being dispatched
    /// under — built from the values the caller already captured and is about to
    /// send with, never re-read from storage.
    ///
    /// `Why:` a dispatch site captures its gateway snapshot, then does real work
    /// before the request leaves (assemble history, encode the body, write it to
    /// disk, mint a pinned session). Re-reading settings at the END of that
    /// stretch means an edit landing inside it produces a signature describing
    /// the NEW configuration while the request on the wire carries the OLD one —
    /// so the old gateway's success would be stored as proof the new one works.
    /// That is the exact false claim this record exists to prevent, arriving
    /// through the back door.
    ///
    /// The pin is still read live: unlike URL / scheme / model, it is resolved by
    /// the transport at challenge time (the background delegate re-resolves it
    /// per task after a relaunch), so the live value IS the one that will be
    /// enforced — and it is what the reader compares against.
    func gatewayChatSuccessSignature(
        for ref: RemoteAgentRef,
        url: URL,
        authScheme: RemoteAgentAuthScheme,
        model: String?
    ) -> String {
        GatewayChatSuccess.signature(
            url: url,
            authScheme: authScheme,
            model: model,
            pinnedFingerprintHex: getRemoteAgentCertFingerprint(for: ref),
            kind: ref.rawString
        )
    }

    /// The signature of a ref's CURRENT stored configuration, or nil when the ref
    /// isn't configured here. Shared by the reader, the writer and every dispatch
    /// site, so all three agree on what counts as "the same configuration".
    ///
    /// Resolved THROUGH `remoteAgentSnapshot` so the model component is exactly
    /// the one that goes on the wire. Reading `getRemoteAgentModel(for:)` here
    /// instead is wrong in two directions: a CUSTOM gateway keeps its model on
    /// the roster entry and never writes that per-ref slot, so every custom
    /// signed a nil model and an edit from a working model to a broken one left
    /// the signature unchanged — the record survived a change that breaks every
    /// send. And a self-hosted built-in picks its model server-side, so a stale
    /// value in the slot would sign a model no request ever carries.
    func gatewayChatSuccessSignature(for ref: RemoteAgentRef) -> String? {
        guard let snapshot = remoteAgentSnapshot(for: ref) else { return nil }
        return gatewayChatSuccessSignature(
            for: ref,
            url: snapshot.url,
            authScheme: snapshot.authScheme,
            model: snapshot.model
        )
    }

    /// Persist a SPECIFIC ref's transport hint. Pass nil / empty to remove.
    /// App Groups ONLY (NO KVS dual-write — per `spec.md` Gateway Setup &
    /// Pairing invariants the hint is per-device: another device may reach the
    /// same gateway over a different transport). Posts
    /// `.settingsDidChangeRemotely` like its per-ref siblings.
    func setRemoteAgentTransportHint(_ hint: String?, for ref: RemoteAgentRef) {
        let key = Constants.remoteAgentTransportHintKey(for: ref)
        if let hint, !hint.isEmpty {
            defaults.set(hint, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    // MARK: - Agent File Transfer (user-run file-server) — per-ref accessors
    //
    // File transfer. Mirrors the per-ref `remoteAgent*` storage layout so a
    // file-server is bound independently to each gateway ref (built-in OR
    // custom). Storage shapes (each cloned from its remote-agent twin):
    //   - URL → App Groups UserDefaults + iCloud KVS (rides iCloud + survives
    //     reinstall; mirrors `getRemoteAgentURL(for:)`).
    //   - Credential (basic-auth password) → Keychain, SAME service +
    //     `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable: true`
    //     shape as `setRemoteAgentToken(_:for:)` (account =
    //     `Constants.fileServerCredentialKeychainAccount(for:)`).
    //   - Cert fingerprint → App Groups UserDefaults ONLY (per-device pin, NO
    //     KVS — mirrors `getRemoteAgentCertFingerprint(for:)`).
    //   - Available flag → App Groups + iCloud KVS (non-secret).
    //
    // Privacy (load-bearing — see the spec.md "Privacy & Security" section): the credential is NEVER logged,
    // printed, or surfaced in error messages. Its consumers are the file-server
    // wire request (basic-auth header), the setup guide's masked credential row
    // the user deliberately copies, and the LOCAL one-way lane-ID derivation
    // below. Every writer posts `.settingsDidChangeRemotely` so observers
    // refresh from a single source.

    /// Atomic snapshot of a ref's file-server configuration. Single actor hop —
    /// mirrors `remoteAgentSnapshot(for:)` so the upload / download / probe
    /// paths observe a consistent url / credential / pin, never a half-edited
    /// combination during a Settings-side change. `username` is always
    /// `Constants.fileServerUsername` (carried for convenience so call sites
    /// don't re-reference Constants). Privacy: never log any field.
    struct FileTransferSnapshot: Sendable, Equatable {
        /// File-server base URL (https). The PUT/GET/PROBE/DELETE path is
        /// `baseURL.appending(path: storedKey)`.
        let baseURL: URL
        /// Fixed basic-auth username — `== Constants.fileServerUsername`.
        let username: String
        /// Client-minted basic-auth password. NEVER log or surface in errors.
        let credential: String
        /// Optional per-device pinned SHA-256 leaf-cert fingerprint (lowercase
        /// hex). Nil → default ATS / system trust.
        let certFingerprintHex: String?
        /// Whether the staged Test Connection has fully passed for this ref.
        let available: Bool
        /// Whether this gateway's file-server accepts NESTED (folder) PUTs
        /// (probed at Test Connection; default true). True → uploads mint
        /// per-conversation `<convID>/<8hex>__<name>` keys; false → flat
        /// `<8hex>__<name>` keys (a gateway that rejects nested PUTs).
        let folderCapable: Bool

        /// Opaque per-process fingerprint of the lane's IDENTITY — url +
        /// credential + pin, the fields a config edit changes; excludes the
        /// mutable verdict fields (`available`, `folderCapable`). The ONE
        /// definition of "what counts as an identity change", shared by
        /// DiagnosticsRunner's stale-result guard and the capability
        /// refresher's apply-guard — two independent definitions could
        /// disagree and let a stale probe verdict apply to a repointed lane.
        /// Hashed so no secret sits in a comparable field; both operands of
        /// any comparison are produced in the same process run, so the
        /// per-process Hasher seed cancels out. Never logged.
        var identitySignature: String {
            var hasher = Hasher()
            hasher.combine(baseURL.absoluteString)
            hasher.combine(credential)
            hasher.combine(certFingerprintHex)
            return "\(hasher.finalize())"
        }

        /// Stable, one-way identity for the durable file lane (URL +
        /// credential). Stored with a pending macOS output scan so crash
        /// recovery can prove that the CURRENT lane is the one used for that
        /// dispatch. The pin and mutable readiness/capability verdicts are
        /// deliberately excluded: a pin is device-local, while the durable
        /// server namespace is defined by URL + credential.
        ///
        /// Domain separation + UInt64 big-endian length prefixes make the byte
        /// encoding unambiguous. Only the SHA-256 digest is persisted or synced;
        /// the credential itself remains Keychain-only and is never logged.
        var durableLaneID: String {
            var input = Data("conduck.file-lane.v1\0".utf8)
            Self.appendLengthPrefixed(Data(baseURL.absoluteString.utf8), to: &input)
            Self.appendLengthPrefixed(Data(credential.utf8), to: &input)
            return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        }

        private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(value)
        }
    }

    /// Read a ref's file-server base URL. Nil = not configured. Reads
    /// `defaults` first, then falls back to iCloud KVS (parity with
    /// `getRemoteAgentURL(for:)`) so the URL survives a reinstall / hydrates on
    /// a fresh device.
    func getFileServerURL(for ref: RemoteAgentRef) -> URL? {
        let key = Constants.fileServerURLKey(for: ref)
        return Self.resolveStoredURL(
            local: defaults.string(forKey: key),
            iCloud: iCloudStore.string(forKey: key),
            iCloudAvailable: iCloudAvailable
        )
    }

    /// Persist a ref's file-server base URL. Pass nil to clear. Dual-writes
    /// App Groups + iCloud KVS (mirrors `setRemoteAgentURL(_:for:)`) and posts
    /// `.settingsDidChangeRemotely`. Same write fence as the gateway setters.
    func setFileServerURL(_ url: URL?, for ref: RemoteAgentRef) {
        let key = Constants.fileServerURLKey(for: ref)
        if let url {
            guard EndpointURLPolicy.isAdmissible(url) else { return }
            defaults.set(url.absoluteString, forKey: key)
            iCloudStore.set(url.absoluteString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Read a ref's client-minted file-server credential from Keychain. Nil if
    /// the slot is empty or Keychain is locked. Privacy: NEVER log the value.
    /// Same synchronizable-read shape as `getRemoteAgentToken(for:)`.
    func getFileServerCredential(for ref: RemoteAgentRef) -> String? {
        // Migrate before the first secret read in this process — covers
        // headless processes (Shortcuts intent / CarPlay) that never ran the
        // app's launch wiring, mirroring `getRemoteAgentToken(for:)`.
        ensureKeychainMigrated()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.fileServerCredentialKeychainAccount(for: ref),
            // iCloud-Keychain-synced item — every steady-state op carries this
            // flag so it round-trips against the same synchronizable item the
            // setter created (parity with the gateway-token slot).
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let (status, result) = secrets.copyMatching(query)

        guard status == errSecSuccess,
              let data = result as? Data,
              let credential = String(data: data, encoding: .utf8) else {
            return nil
        }
        return credential
    }

    /// Write a ref's client-minted file-server credential to Keychain with
    /// `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrSynchronizable` — the
    /// EXACT shape of `setRemoteAgentToken(_:for:)`.
    /// - Throws: `AppError.settingsLoadFailed` on Keychain failure.
    func setFileServerCredential(_ password: String, for ref: RemoteAgentRef) throws {
        guard let data = password.data(using: .utf8) else {
            throw AppError.settingsLoadFailed
        }

        let account = Constants.fileServerCredentialKeychainAccount(for: ref)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account,
            // Synchronizable items are distinct from non-sync ones, so both the
            // update query AND the add (below) must carry the flag.
            kSecAttrSynchronizable as String: true
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = secrets.update(query, attributes: attributes)

        if updateStatus == errSecSuccess {
            postSettingsDidChangeRemotely()
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Accessibility immutable after add — set at add time.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = secrets.add(addQuery)
            guard addStatus == errSecSuccess else {
                throw AppError.settingsLoadFailed
            }
            postSettingsDidChangeRemotely()
            return
        }

        throw AppError.settingsLoadFailed
    }

    /// Remove a ref's file-server credential from Keychain. No-op if already
    /// absent; throws only on a real Keychain failure. Mirrors
    /// `clearRemoteAgentToken(for:)`.
    func clearFileServerCredential(for ref: RemoteAgentRef) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.fileServerCredentialKeychainAccount(for: ref),
            // Match the synchronizable item — a non-sync delete would miss the
            // iCloud-synced credential, leaving it alive on other devices.
            kSecAttrSynchronizable as String: true
        ]

        let status = secrets.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.settingsLoadFailed
        }
        if status == errSecSuccess {
            postSettingsDidChangeRemotely()
        }
    }

    /// Read a ref's pinned file-server SHA-256 fingerprint (lowercase hex).
    /// App Groups only (per-device pin — NO KVS, mirrors
    /// `getRemoteAgentCertFingerprint(for:)`).
    func getFileServerCertFingerprint(for ref: RemoteAgentRef) -> String? {
        let raw = defaults.string(forKey: Constants.fileServerCertFingerprintKey(for: ref))
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Persist a ref's pinned file-server fingerprint. Pass nil / empty to
    /// remove the pin (default ATS chain validation resumes). Stored lowercase
    /// (canonical form). App Groups only. Mirrors
    /// `setRemoteAgentCertFingerprint(_:for:)`.
    func setFileServerCertFingerprint(_ fingerprint: String?, for ref: RemoteAgentRef) {
        let key = Constants.fileServerCertFingerprintKey(for: ref)
        if let fingerprint, !fingerprint.isEmpty {
            defaults.set(fingerprint.lowercased(), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        postSettingsDidChangeRemotely()
    }

    /// Read a ref's "file transfer is ready" flag. Default false when unset
    /// (the `object(forKey:) as? Bool ?? false` read documents intent and lets
    /// a future default flip in one place). Set true ONLY after the staged Test
    /// Connection fully passes.
    func getFileTransferAvailable(for ref: RemoteAgentRef) -> Bool {
        (defaults.object(forKey: Constants.fileTransferAvailableKey(for: ref)) as? Bool) ?? false
    }

    /// Persist a ref's "file transfer is ready" flag. Dual-writes App Groups +
    /// iCloud KVS so the composer on another device knows the file affordance
    /// is enabled, and posts `.settingsDidChangeRemotely`.
    func setFileTransferAvailable(_ available: Bool, for ref: RemoteAgentRef) {
        let key = Constants.fileTransferAvailableKey(for: ref)
        defaults.set(available, forKey: key)
        iCloudStore.set(available, forKey: key)
        postSettingsDidChangeRemotely()
    }

    /// Read a ref's "file-server accepts nested (folder) PUTs" flag. Default
    /// TRUE when unset — an un-probed / legacy ref (and every rclone deployment)
    /// gets the per-conversation folder layout; only a Test-Connection
    /// nested-probe FAILURE flips it false. (`object(forKey:) as? Bool ?? true`
    /// documents the default-true intent.)
    func getFileServerFolderCapable(for ref: RemoteAgentRef) -> Bool {
        (defaults.object(forKey: Constants.fileServerFolderCapableKey(for: ref)) as? Bool) ?? true
    }

    /// Persist a ref's folder-capability flag. Dual-writes App Groups + iCloud
    /// KVS (a second device's composer must mint matching keys) and posts
    /// `.settingsDidChangeRemotely`.
    func setFileServerFolderCapable(_ capable: Bool, for ref: RemoteAgentRef) {
        let key = Constants.fileServerFolderCapableKey(for: ref)
        defaults.set(capable, forKey: key)
        iCloudStore.set(capable, forKey: key)
        postSettingsDidChangeRemotely()
    }

    /// Read a ref's "THIS device ran a passing staged Test Connection" flag.
    /// Default false. App Groups ONLY (device-local provenance — `available`
    /// stops proving local testing once the inbound KVS mirror ships). Gates
    /// the silent folder-capability re-probe. Runs the one-time seed first so
    /// a pre-mirror `available=true` (which could only have come from a local
    /// test) is honoured on the first read after update.
    func getFileServerTestedLocally(for ref: RemoteAgentRef) -> Bool {
        ensureFileServerTestedLocallySeeded()
        return defaults.bool(forKey: Constants.fileServerTestedLocallyKey(for: ref))
    }

    /// Persist a ref's locally-tested flag. App Groups ONLY — never KVS, never
    /// a change notification (pure bookkeeping; no UI reads it live). Set true
    /// at the two staged-test pass sites (Settings + Diagnostics); cleared by
    /// "Forget file transfer".
    func setFileServerTestedLocally(_ tested: Bool, for ref: RemoteAgentRef) {
        ensureFileServerTestedLocallySeeded()
        if tested {
            defaults.set(true, forKey: Constants.fileServerTestedLocallyKey(for: ref))
        } else {
            defaults.removeObject(forKey: Constants.fileServerTestedLocallyKey(for: ref))
        }
    }

    /// Last DEFINITIVE silent folder-probe revision for `ref` (nil = never).
    /// App Groups only — see `Constants.fileServerFolderProbeRevisionKey`.
    func getFolderProbeRevision(for ref: RemoteAgentRef) -> Int? {
        defaults.object(forKey: Constants.fileServerFolderProbeRevisionKey(for: ref)) as? Int
    }

    /// Record a DEFINITIVE silent folder-probe outcome at the current
    /// algorithm revision. App Groups only, no notification.
    func setFolderProbeRevision(_ revision: Int, for ref: RemoteAgentRef) {
        defaults.set(revision, forKey: Constants.fileServerFolderProbeRevisionKey(for: ref))
    }

    /// Last silent folder-probe ATTEMPT for `ref` (nil = never). App Groups
    /// only — backoff seed, see `Constants.fileServerFolderProbeAttemptKey`.
    func getFolderProbeAttempt(for ref: RemoteAgentRef) -> Date? {
        guard let raw = defaults.object(forKey: Constants.fileServerFolderProbeAttemptKey(for: ref)) as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: raw)
    }

    /// Record a silent folder-probe attempt (any outcome). App Groups only.
    func setFolderProbeAttempt(_ date: Date, for ref: RemoteAgentRef) {
        defaults.set(date.timeIntervalSince1970, forKey: Constants.fileServerFolderProbeAttemptKey(for: ref))
    }

    /// The SINGLE source of truth for which file-server key families the
    /// inbound KVS mirror + cold-launch hydration sync. Shared by
    /// `handleICloudChange` and `performInitialSync` so the two passes can
    /// never drift (a key added to one list but not the other would sync on
    /// live changes yet be missing on a fresh install, or vice versa).
    /// NEVER widen to a blanket `fileServer.` scan: `certFingerprint.` is a
    /// per-device pin (an optional tightening on top of system trust, never
    /// synced), `keepImagesInline.` is the retired legacy bool,
    /// and `testedLocally.`/`folderProbeRevision.`/`folderProbeAttempt.` are
    /// device-local probe provenance — all mirror-banned.
    private static let fileServerMirroredURLPrefix = "fileServer.url."
    private static let fileServerMirroredBoolPrefixes = ["fileServer.available.", "fileServer.folderCapable."]

    /// Revoke a ref's file-transfer READINESS as one actor-level operation —
    /// the single choke point every config-identity mutation (URL save,
    /// pairing import, credential regeneration, Forget) calls BEFORE writing
    /// the new config value. Ordering is load-bearing: `available=false`
    /// dual-writes FIRST so the revocation reaches iCloud KVS no later than
    /// the new config — no peer may assemble new-config + stale-Ready.
    /// Also forfeits this device's local test proof (`testedLocally`) and
    /// clears the silent-probe markers: a changed identity makes both the
    /// proof and any recorded probe verdict meaningless for the NEW server —
    /// a surviving `folderProbeRevision` would permanently disarm the silent
    /// re-probe against the replacement server. A future mutation site that
    /// calls this cannot recreate the stale-verdict bug by construction.
    func revokeFileTransferReadiness(for ref: RemoteAgentRef) {
        setFileTransferAvailable(false, for: ref)
        setFileServerTestedLocally(false, for: ref)
        clearFolderProbeMarkers(for: ref)
    }

    /// Drop a ref's silent-probe bookkeeping (revision marker + attempt
    /// timestamp) so the next launch's refresher may probe again. Called by
    /// `revokeFileTransferReadiness` (identity changed) and by the staged
    /// Test-Connection persist sites (a fresh staged verdict supersedes any
    /// recorded silent-probe outcome — re-arming lets the upgrade-only probe
    /// correct a transiently-flaky staged nested-probe on the next launch).
    func clearFolderProbeMarkers(for ref: RemoteAgentRef) {
        defaults.removeObject(forKey: Constants.fileServerFolderProbeRevisionKey(for: ref))
        defaults.removeObject(forKey: Constants.fileServerFolderProbeAttemptKey(for: ref))
    }

    /// In-process latch for the one-time `testedLocally` seed (mirrors the
    /// migration-latch pattern, e.g. `didAttemptRemoteAgentMigration`).
    private var didAttemptTestedLocallySeed = false

    /// ONE-TIME migration seed: before the inbound KVS mirror existed, a local
    /// `fileServer.available.<suffix> == true` could ONLY have been written by
    /// a passing staged Test Connection on THIS device — so mark those refs
    /// locally tested. MUST run before the mirror's first `fileServer.available`
    /// write into defaults (callers: `handleICloudChange`, `performInitialSync`,
    /// the `testedLocally` accessors), or a synced-only peer would be
    /// misclassified as locally tested. Scans the raw defaults dictionary
    /// rather than enumerating refs so stale suffixes (deleted customs) seed
    /// too — harmless, and complete.
    private func ensureFileServerTestedLocallySeeded() {
        if didAttemptTestedLocallySeed { return }
        didAttemptTestedLocallySeed = true
        guard !defaults.bool(forKey: Constants.fileServerTestedLocallySeededKey) else { return }

        let availablePrefix = "fileServer.available."
        let testedPrefix = "fileServer.testedLocally."
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(availablePrefix) && (value as? Bool) == true {
            let suffix = String(key.dropFirst(availablePrefix.count))
            defaults.set(true, forKey: testedPrefix + suffix)
        }
        defaults.set(true, forKey: Constants.fileServerTestedLocallySeededKey)
    }

    /// Read a ref's image-history policy. Default `.recent` when unset. LAZY
    /// MIGRATION: new key absent + legacy "keep all prior images inline" bool
    /// (`fileServerKeepImagesInlineKey`) `true` → `.all` (the bool's exact
    /// semantics). Deliberately NO write-through: an un-updated device keeps
    /// writing the legacy bool, and both resolve identically until the user
    /// touches the new picker — then the new key wins everywhere it syncs.
    func getImageHistoryPolicy(for ref: RemoteAgentRef) -> ImageHistoryPolicy {
        if let raw = defaults.string(forKey: Constants.imageHistoryPolicyKey(for: ref)) {
            return ImageHistoryPolicy.from(rawValue: raw)
        }
        if (defaults.object(forKey: Constants.fileServerKeepImagesInlineKey(for: ref)) as? Bool) == true {
            return .all
        }
        return .default
    }

    /// Persist a ref's image-history policy. ALWAYS writes the raw value —
    /// even `.default` — so an explicit picker choice overrides the lazy
    /// legacy-bool migration above (removing the key would let a stale legacy
    /// `true` resurrect `.all`). Dual-writes App Groups + iCloud KVS so the
    /// policy is consistent across the user's devices (inbound mirror:
    /// `handleICloudChange` prefix-scan) and posts `.settingsDidChangeRemotely`.
    func setImageHistoryPolicy(_ policy: ImageHistoryPolicy, for ref: RemoteAgentRef) {
        let key = Constants.imageHistoryPolicyKey(for: ref)
        defaults.set(policy.rawValue, forKey: key)
        iCloudStore.set(policy.rawValue, forKey: key)
        postSettingsDidChangeRemotely()
    }

    /// Commit a full file-transfer tuple transition — URL + pin + (optionally)
    /// folder capability + availability — in ONE actor hop with NO suspension
    /// points, then post ONE settings-changed notification. This is the ONLY
    /// safe way to change the tuple together with readiness: separate setter
    /// calls suspend between writes, so a concurrent `fileTransferSnapshot`
    /// could observe a Ready lane carrying a half-written (mixed old/new)
    /// tuple. `folderCapable` nil = leave the stored flag untouched (no real
    /// probe signal — see `runFileTransferTest`'s capability rules).
    ///
    /// The hop also carries `revokeFileTransferReadiness`'s doctrine for an
    /// identity change: local test proof (`testedLocally`) FOLLOWS the
    /// availability being committed — an `available: true` commit is only ever
    /// a carried staged pass earned on THIS device against exactly this tuple,
    /// and an `available: false` commit is an unproven tuple
    /// whose old proof must not survive onto the new identity. The
    /// silent-probe markers re-arm either way (an identity change orphans a
    /// recorded silent verdict; a carried pass is a fresh staged verdict that
    /// supersedes one).
    func commitFileTransferConfig(
        url: URL,
        pin: String?,
        folderCapable: Bool?,
        available: Bool,
        for ref: RemoteAgentRef
    ) {
        // Write fence (see `setRemoteAgentURL(_:)`) — this method writes the
        // file-server URL key DIRECTLY rather than through `setFileServerURL`,
        // so it needs the guard itself. Refusing before ANY write leaves the old
        // URL/pin/capability/availability as one complete, consistent tuple —
        // the same no-half-state outcome the ordering below is built around.
        // Unreachable from the two real callers (both pre-validate), which is
        // the point: it is a backstop, not a user-facing path.
        guard EndpointURLPolicy.isAdmissible(url) else { return }

        // Fail-closed durability order for a mid-write crash: a NOT-available
        // commit revokes availability BEFORE the tuple lands (a crash leaves
        // old-tuple + false — honest), an available commit flips it true only
        // AFTER the tuple that pass proved (a crash leaves new-tuple + false —
        // honest). No durable state can pair Ready with a tuple the staged
        // test didn't prove. A COMPLETED hop flushes its KVS batch as one
        // unit, so peers see tuple + readiness together.
        let availKey = Constants.fileTransferAvailableKey(for: ref)
        if !available {
            defaults.set(false, forKey: availKey)
            iCloudStore.set(false, forKey: availKey)
        }

        let urlKey = Constants.fileServerURLKey(for: ref)
        defaults.set(url.absoluteString, forKey: urlKey)
        iCloudStore.set(url.absoluteString, forKey: urlKey)

        let pinKey = Constants.fileServerCertFingerprintKey(for: ref)
        if let pin, !pin.isEmpty {
            defaults.set(pin.lowercased(), forKey: pinKey)
        } else {
            defaults.removeObject(forKey: pinKey)
        }

        if let folderCapable {
            let capKey = Constants.fileServerFolderCapableKey(for: ref)
            defaults.set(folderCapable, forKey: capKey)
            iCloudStore.set(folderCapable, forKey: capKey)
        }

        if available {
            defaults.set(true, forKey: availKey)
            iCloudStore.set(true, forKey: availKey)
        }

        setFileServerTestedLocally(available, for: ref)
        clearFolderProbeMarkers(for: ref)

        postSettingsDidChangeRemotely()
    }

    /// Commit a staged-test VERDICT for the persisted tuple — capability +
    /// availability — in ONE actor hop, one notification. Same rationale as
    /// `commitFileTransferConfig`: two separate setter hops let a snapshot see
    /// `available == true` paired with a stale `folderCapable`. Capability is
    /// written BEFORE availability so even a mid-crash can't durably pair
    /// `available=true` with a stale default-true capability.
    ///
    /// A PASSING verdict is by definition a staged Test Connection that ran on
    /// THIS device against the persisted tuple — so the same hop records the
    /// device-local proof (`testedLocally`, arming the upgrade-only silent
    /// folder re-probe; a synced-only peer stays disarmed) and re-arms the
    /// silent-probe markers (a fresh staged verdict supersedes any recorded
    /// silent outcome). A FAILING verdict leaves the proof untouched: the
    /// tuple's identity didn't change, and the probe the proof arms never
    /// touches availability.
    func commitFileTransferVerdict(
        available: Bool,
        folderCapable: Bool?,
        for ref: RemoteAgentRef
    ) {
        if let folderCapable {
            let capKey = Constants.fileServerFolderCapableKey(for: ref)
            defaults.set(folderCapable, forKey: capKey)
            iCloudStore.set(folderCapable, forKey: capKey)
        }
        let availKey = Constants.fileTransferAvailableKey(for: ref)
        defaults.set(available, forKey: availKey)
        iCloudStore.set(available, forKey: availKey)
        if available {
            setFileServerTestedLocally(true, for: ref)
            clearFolderProbeMarkers(for: ref)
        }
        postSettingsDidChangeRemotely()
    }

    /// Atomic file-server snapshot for a ref. Single actor hop — mirrors
    /// `remoteAgentSnapshot(for:)`. Returns nil when the URL OR the credential
    /// is missing (both are hard-required to talk to the file-server; either
    /// absent is `.fileTransferNotConfigured` territory). Cert fingerprint and
    /// the available flag are independently optional.
    func fileTransferSnapshot(for ref: RemoteAgentRef) -> FileTransferSnapshot? {
        guard let url = getFileServerURL(for: ref),
              let credential = getFileServerCredential(for: ref) else {
            return nil
        }
        return FileTransferSnapshot(
            baseURL: url,
            username: Constants.fileServerUsername,
            credential: credential,
            certFingerprintHex: getFileServerCertFingerprint(for: ref),
            available: getFileTransferAvailable(for: ref),
            folderCapable: getFileServerFolderCapable(for: ref)
        )
    }

    /// Snapshot ONLY when file transfer is READY (the staged Test Connection
    /// passed — `available`). Staging / routing / promotion / readiness call
    /// sites use THIS, so a saved-but-failed (or saved-untested) server routes
    /// like "not set up" instead of receiving uploads. Operational paths on
    /// already-uploaded blobs (download, orphan DELETE, retry probe, the upload
    /// executor) keep `fileTransferSnapshot(for:)` — a failed re-test must never
    /// brick access to files already on the user's server.
    func fileTransferReadySnapshot(for ref: RemoteAgentRef) -> FileTransferSnapshot? {
        guard let snapshot = fileTransferSnapshot(for: ref), snapshot.available else { return nil }
        return snapshot
    }

    // MARK: - Remote Agent — Default-Backend Pointer (multi-gateway)

    /// Returns the default backend a freshly-minted conversation binds to.
    /// **DEVICE-LOCAL:** reads App Groups `defaults` ONLY (no iCloud-KVS
    /// fallback — see `defaultRemoteAgentRef()`), then
    /// `Constants.remoteAgentDefaultBackendDefault` (`.openclaw`). An unknown
    /// stored raw value (forward-compat) falls through to the default. Runs the
    /// migrations first so a just-migrated single-slot install reports its prior
    /// backend as default. NOTE: a back-compat forwarder, now only consulted by
    /// `setDefaultRemoteAgentBackend`'s no-op guard — it deliberately omits the
    /// config-sync bootstrap that the canonical `defaultRemoteAgentRef()` has
    /// (which is the routing-authoritative reader). Prefer the ref reader.
    func defaultRemoteAgentBackend() -> RemoteAgentBackend {
        #if DEBUG
        if QAMode.isActive {
            return QAMode.defaultBackend
        }
        #endif
        ensureKeychainMigrated()
        ensureRemoteAgentMigrated()
        ensureDefaultBackendDeviceLocalMigrated()
        // DEVICE-LOCAL: App-Group only. No iCloud-KVS read fallback (a late KVS
        // write from another device must NOT re-globalize this device's default).
        if let local = defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
           let backend = RemoteAgentBackend(rawValue: local) {
            return backend
        }
        return Constants.remoteAgentDefaultBackendDefault
    }

    /// Set the default backend (DEVICE-LOCAL — App Groups only, no iCloud KVS).
    /// Posts `.settingsDidChangeRemotely`. No-op when `newBackend` equals the
    /// current value. Does NOT clear the active-conversation pointer (the
    /// ref-typed `setDefaultRemoteAgentRef` is the user-facing re-point that
    /// clears; this forwarder is used by the per-backend migration, which must
    /// not sever capture continuity).
    func setDefaultRemoteAgentBackend(_ newBackend: RemoteAgentBackend) {
        let current = defaultRemoteAgentBackend()
        guard newBackend != current else { return }

        defaults.set(newBackend.rawValue, forKey: Constants.remoteAgentDefaultBackendKVSKey)
        postSettingsDidChangeRemotely()
    }

    /// Ref-based default pointer (built-in OR custom) — the routing-authoritative
    /// reader. **DEVICE-LOCAL:** reads App Groups `defaults` ONLY (no iCloud-KVS
    /// fallback — the default no longer syncs). Reuses the SAME
    /// `remoteAgentDefaultBackendKVSKey` — a built-in ref's `rawString` == its
    /// raw value, so legacy installs parse unchanged (migration-free). When no
    /// local value exists, the **config-sync bootstrap** adopts the first
    /// configured ref (so a device that received gateways via sync but never ran
    /// `saveRemoteAgent` doesn't dead-end), persisting it App-Group-locally; an
    /// unknown / garbage stored value or a no-gateway state falls back to the
    /// built-in default.
    func defaultRemoteAgentRef() -> RemoteAgentRef {
        #if DEBUG
        if QAMode.isActive {
            return .builtin(QAMode.defaultBackend)
        }
        #endif
        ensureKeychainMigrated()
        ensureRemoteAgentMigrated()
        ensureDefaultBackendDeviceLocalMigrated()
        // DEVICE-LOCAL: App-Group only. No iCloud-KVS read fallback (a late KVS
        // write from another device must NOT re-globalize this device's default).
        //
        // SELF-HEALS: a pointer at a gateway with NOTHING stored behind it (the
        // user forgot it here, or a peer's Forget synced in) is dropped, and the
        // bootstrap below picks a gateway that actually exists. Returning the
        // dangling ref instead left every headless capture minting onto a
        // gateway that throws `remoteAgentNotConfigured`, with nothing on screen
        // explaining why.
        //
        // The test is `hasStoredRemoteAgentEvidence`, NOT
        // `configuredRemoteAgentRefs().contains` — deliberately weaker. The
        // configured predicate fails CLOSED on a nil token, and nil means "no
        // token OR the Keychain read failed". Secrets are
        // `kSecAttrAccessibleAfterFirstUnlock`, so a headless capture after a
        // reboot and before the first unlock reads every gateway as
        // unconfigured; healing on that verdict would DELETE the user's default
        // pointer during a transient failure and silently re-point them at some
        // other gateway once the device unlocks. Evidence is App-Group-backed
        // (URL, or model for a fixed-endpoint built-in) and cannot be faked
        // absent by a locked Keychain.
        if let local = defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
           let ref = RemoteAgentRef(rawString: local) {
            if hasStoredRemoteAgentEvidence(ref) { return ref }
            defaults.removeObject(forKey: Constants.remoteAgentDefaultBackendKVSKey)
        }
        // Config-sync bootstrap: gateway CONFIGS still sync, but the default does
        // not. A device that received configs via sync (and never ran the
        // first-gateway bootstrap in `saveRemoteAgent`) would otherwise dead-end
        // on the unconfigured `.openclaw` fallback. So when no local default
        // exists but a configured gateway does, adopt the first configured ref as
        // THIS device's local default (App-Group write only — never KVS).
        if let firstConfigured = configuredRemoteAgentRefs().first {
            defaults.set(firstConfigured.rawString, forKey: Constants.remoteAgentDefaultBackendKVSKey)
            return firstConfigured
        }
        return .builtin(Constants.remoteAgentDefaultBackendDefault)
    }

    /// Set the ref-based default pointer (built-in OR custom), DEVICE-LOCAL —
    /// App Groups only, NO iCloud KVS write (each device owns its default).
    /// No-op when unchanged.
    func setDefaultRemoteAgentRef(_ newRef: RemoteAgentRef) {
        guard newRef != defaultRemoteAgentRef() else { return }
        defaults.set(newRef.rawString, forKey: Constants.remoteAgentDefaultBackendKVSKey)
        // Re-pointing the default gateway switches THIS DEVICE's HEADLESS captures
        // (Action Button / macOS menu bar / CarPlay seed / Watch-if-following) to
        // the new gateway IMMEDIATELY: clear THIS device's active-conversation
        // pointer so the next capture mints a FRESH thread on `newRef` instead of
        // continuing the prior thread on its OLD bound gateway under
        // `SessionContinuationPolicy` (≤30 min). LOCAL-ONLY clear now — there is
        // no remote propagation (the default no longer syncs), so other devices
        // keep their own default + pointer. The guard above means this only fires
        // on an ACTUAL change. `clearActiveConversation()` also posts
        // `.settingsDidChangeRemotely`, so no separate post is needed here.
        clearActiveConversation()
    }

    // MARK: - Apple Watch default override (App-Group ONLY — never iCloud KVS)

    /// The Watch-specific default override, or `nil` = "Follow iPhone". Stored
    /// App-Group-LOCAL on the iPhone — NEVER iCloud KVS (it must not leak to
    /// iPad/Mac, which own their own device-local defaults). **Self-heals:** a
    /// stored override whose gateway is no longer configured is dropped here and
    /// reported as nil, so the Watch never inherits a not-configured default.
    func watchDefaultOverrideRef() -> RemoteAgentRef? {
        guard let raw = defaults.string(forKey: Constants.remoteAgentWatchDefaultBackendKey),
              let ref = RemoteAgentRef(rawString: raw) else {
            return nil
        }
        guard configuredRemoteAgentRefs().contains(ref) else {
            defaults.removeObject(forKey: Constants.remoteAgentWatchDefaultBackendKey)
            return nil
        }
        return ref
    }

    /// Set (`ref`) or clear (`nil` = "Follow iPhone") the Watch default override.
    /// Posts `.settingsDidChangeRemotely` so `PhoneSessionManager` re-broadcasts
    /// the new Watch-effective default to the wrist. App-Group only — never KVS.
    func setWatchDefaultOverrideRef(_ newRef: RemoteAgentRef?) {
        let current = defaults.string(forKey: Constants.remoteAgentWatchDefaultBackendKey)
        let next = newRef?.rawString
        guard next != current else { return }
        if let next {
            defaults.set(next, forKey: Constants.remoteAgentWatchDefaultBackendKey)
        } else {
            defaults.removeObject(forKey: Constants.remoteAgentWatchDefaultBackendKey)
        }
        postSettingsDidChangeRemotely()
    }

    /// The default ref the WATCH should use for headless captures = the override
    /// (iff still configured) else the iPhone's device-local default. This is the
    /// value that rides the broadcast envelope's `defaultBackendRef` slot.
    func watchEffectiveDefaultRef() -> RemoteAgentRef {
        watchDefaultOverrideRef() ?? defaultRemoteAgentRef()
    }

    // MARK: - Apple Watch session-policy override (App-Group ONLY — never iCloud KVS)

    /// The Watch-specific `SessionContinuationPolicy` override, or `nil` =
    /// "Follow iPhone". Stored App-Group-LOCAL on the iPhone — NEVER iCloud KVS
    /// (it must not leak to iPad/Mac, which own their own per-device policy).
    /// No self-heal needed (unlike the gateway override): every persisted raw
    /// value is a valid enum case (unknown raw → nil = Follow iPhone, the
    /// forward-compat default). Mirrors `watchDefaultOverrideRef`.
    func watchSessionContinuationPolicyOverride() -> SessionContinuationPolicy? {
        guard let raw = defaults.string(forKey: Constants.watchSessionContinuationPolicyOverrideKey),
              let value = SessionContinuationPolicy(rawValue: raw) else {
            return nil
        }
        return value
    }

    /// Set (`value`) or clear (`nil` = "Follow iPhone") the Watch policy override.
    /// Posts `.settingsDidChangeRemotely` so `PhoneSessionManager` re-broadcasts
    /// the new Watch-effective policy to the wrist. App-Group only — never KVS.
    /// No-op when unchanged. Mirrors `setWatchDefaultOverrideRef`.
    func setWatchSessionContinuationPolicyOverride(_ value: SessionContinuationPolicy?) {
        let current = defaults.string(forKey: Constants.watchSessionContinuationPolicyOverrideKey)
        let next = value?.rawValue
        guard next != current else { return }
        if let next {
            defaults.set(next, forKey: Constants.watchSessionContinuationPolicyOverrideKey)
        } else {
            defaults.removeObject(forKey: Constants.watchSessionContinuationPolicyOverrideKey)
        }
        postSettingsDidChangeRemotely()
    }

    /// The `SessionContinuationPolicy` the WATCH should use for headless captures
    /// = the override if set, else the iPhone's device-local policy. This is the
    /// value that rides the broadcast envelope's `sessionPolicy` slot. Mirrors
    /// `watchEffectiveDefaultRef`.
    func watchEffectiveSessionContinuationPolicy() -> SessionContinuationPolicy {
        watchSessionContinuationPolicyOverride() ?? getSessionContinuationPolicy()
    }

    // MARK: - Custom Gateways — Registry (App-Group JSON + iCloud KVS)

    /// The custom-gateway roster as the UI/picker/router see it. In QA mode this
    /// also surfaces the in-memory `QAMode.customGatewayOverride` record (so the
    /// gateway list/picker/badge render a named custom on the unsigned sim);
    /// that phantom NEVER enters the write path (see `persistedCustomGateways`).
    func customGateways() -> [CustomGateway] {
        var list = persistedCustomGateways()
        #if DEBUG
        if QAMode.isActive, let override = QAMode.customGatewayOverride,
           !list.contains(where: { $0.id == override.gateway.id }) {
            list.append(override.gateway)
        }
        #endif
        return list
    }

    /// The persisted custom-gateway roster (id / name / model / badge). App
    /// Groups first (durable), iCloud KVS fallback (fresh device / reinstall) —
    /// same read order as `defaultRemoteAgentRef()`. Empty when none. The WRITE
    /// path (`upsertCustomGateway`/`deleteCustomGateway`) operates on THIS, never
    /// the QA-augmented `customGateways()`, so a QA phantom can't be persisted.
    private func persistedCustomGateways() -> [CustomGateway] {
        if let data = defaults.data(forKey: Constants.customGatewaysRegistryKey),
           let list = try? JSONDecoder().decode([CustomGateway].self, from: data) {
            return list
        }
        if iCloudAvailable,
           let data = iCloudStore.data(forKey: Constants.customGatewaysRegistryKey),
           let list = try? JSONDecoder().decode([CustomGateway].self, from: data) {
            return list
        }
        return []
    }

    /// One custom gateway by id, or nil if absent (deleted / never created).
    func customGateway(id: UUID) -> CustomGateway? {
        customGateways().first { $0.id == id }
    }

    /// The custom-gateway count (for the cap UI gate).
    func customGatewayCount() -> Int {
        customGateways().count
    }

    /// Add or update a custom gateway's ROSTER fields (name / model / badge).
    /// URL / token / cert are persisted separately via the per-ref setters at
    /// the call site. ADD is capped at `Constants.maxCustomGateways` — returns
    /// `false` (UI surfaces the cap hint) when full; UPDATE never trips the cap.
    @discardableResult
    func upsertCustomGateway(_ gateway: CustomGateway) -> Bool {
        var list = persistedCustomGateways()
        if let index = list.firstIndex(where: { $0.id == gateway.id }) {
            list[index] = gateway
        } else {
            guard list.count < Constants.maxCustomGateways else { return false }
            list.append(gateway)
        }
        persistCustomGateways(list)
        return true
    }

    /// Delete a custom gateway: clears its per-ref URL / token / cert slots AND
    /// its roster entry. Conversations bound to it then resolve nil →
    /// `remoteAgentNotConfigured` (NO reroute). If it was the default pointer,
    /// fall the default back to the first configured BUILT-IN (never silently to
    /// another custom), else the built-in default.
    func deleteCustomGateway(id: UUID) {
        let ref = RemoteAgentRef.custom(id)
        setRemoteAgentURL(nil, for: ref)
        try? clearRemoteAgentToken(for: ref)
        setRemoteAgentCertFingerprint(nil, for: ref)
        clearRemoteAgentAuthScheme(for: ref)
        setRemoteAgentModel(nil, for: ref)
        clearAuxiliaryRemoteAgentSlots(for: ref)

        // Drop a Watch override that pointed at the deleted gateway so the next
        // broadcast couriers a valid Watch-effective default (self-heal in
        // `watchDefaultOverrideRef()` also covers this lazily; clear eagerly here
        // so the `persistCustomGateways` post below re-broadcasts the corrected
        // value). Demotes the wrist to "Follow iPhone".
        if defaults.string(forKey: Constants.remoteAgentWatchDefaultBackendKey) == ref.rawString {
            defaults.removeObject(forKey: Constants.remoteAgentWatchDefaultBackendKey)
        }

        var list = persistedCustomGateways()
        list.removeAll { $0.id == id }
        persistCustomGateways(list)

        // Collect this gateway's whole per-uuid key family — the file-server
        // slots in particular, which no setter above owns. Runs AFTER the roster
        // write so `clearFileTransferConfig`'s invalidate-first `available=false`
        // has already reached KVS; the peers see the revocation, then the key
        // removal, and land on the same verdict either way.
        //
        // This is why the orphan sweep is not the collector: it is a ONE-TIME
        // historical cleanup and latches on `orphanSweepVersion`, so a gateway
        // deleted after it runs would leak the same family forever — which is
        // exactly how 135 `fileServer.available.custom_*` keys accumulated.
        purgeGatewayOwnedSlots(for: id)

        if defaultRemoteAgentRef() == ref {
            let fallback = configuredRemoteAgentRefs().first(where: { $0.isBuiltin })
                ?? .builtin(Constants.remoteAgentDefaultBackendDefault)
            setDefaultRemoteAgentRef(fallback)
        }
    }

    /// Remove the per-ref slots that no dedicated setter owns — the gateway's
    /// image-history policy, its transport hint, and this device's last-success
    /// record. Called from BOTH Forget paths (built-in and custom).
    ///
    /// They are removed, not defaulted: a written-back default value is
    /// indistinguishable from a user choice on the next read, and the orphan
    /// sweep can only recognise a slot as dead if the key is gone. The policy
    /// key is dual-written, so its removal must reach BOTH stores or the next
    /// inbound mirror re-hydrates it — the shape `deleteCustomVoiceEndpoint(id:)`
    /// already uses. The other two are App-Group-only by design (see their
    /// `Constants` docs), so removing them from KVS would be meaningless.
    func clearAuxiliaryRemoteAgentSlots(for ref: RemoteAgentRef) {
        let policyKey = Constants.imageHistoryPolicyKey(for: ref)
        defaults.removeObject(forKey: policyKey)
        iCloudStore.removeObject(forKey: policyKey)

        defaults.removeObject(forKey: Constants.remoteAgentTransportHintKey(for: ref))
        defaults.removeObject(forKey: Constants.remoteAgentLastChatSuccessKey(for: ref))

        // The retired single-config slot. A built-in Forget that leaves it
        // behind lets `migrateRemoteAgentToPerBackend` (or the legacy read
        // fallback) re-seed the gateway the user just removed.
        if case .builtin(let backend) = ref,
           defaults.string(forKey: Constants.remoteAgentBackendKey) == backend.rawValue {
            defaults.removeObject(forKey: Constants.remoteAgentURLKey)
            iCloudStore.removeObject(forKey: Constants.remoteAgentURLKey)
            defaults.removeObject(forKey: Constants.remoteAgentBackendKey)
            iCloudStore.removeObject(forKey: Constants.remoteAgentBackendKey)
            defaults.removeObject(forKey: Constants.remoteAgentCertFingerprintKey)
        }
    }

    private func persistCustomGateways(_ list: [CustomGateway]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Constants.customGatewaysRegistryKey)
            iCloudStore.set(data, forKey: Constants.customGatewaysRegistryKey)
        }
        postSettingsDidChangeRemotely()
    }

    /// Return the backends that are fully configured = have BOTH a stored token
    /// AND a stored URL (a token-without-url half-state is not
    /// offered). Ordered by `RemoteAgentBackend.allCases`. Mirrors
    /// `presetIDsWithStoredKey()` (the "which are set up" query) but returns an
    /// ordered array, not a set, because the picker renders in a stable order.
    func configuredRemoteAgentRefs() -> [RemoteAgentRef] {
        #if DEBUG
        if QAMode.isActive, !QAMode.gatewayOverrides.isEmpty || QAMode.customGatewayOverride != nil {
            var qaRefs = RemoteAgentBackend.allCases
                .filter { QAMode.gatewayOverrides[$0] != nil }
                .map(RemoteAgentRef.builtin)
            if let override = QAMode.customGatewayOverride {
                qaRefs.append(.custom(override.gateway.id))   // built-ins first, custom last (production order)
            }
            return qaRefs
        }
        #endif
        ensureKeychainMigrated()
        ensureRemoteAgentMigrated()
        var refs: [RemoteAgentRef] = RemoteAgentBackend.allCases
            .map(RemoteAgentRef.builtin)
            .filter { isRemoteAgentConfigured($0) }
        for gateway in customGateways() {
            let ref = RemoteAgentRef.custom(gateway.id)
            if isRemoteAgentConfigured(ref) {
                refs.append(ref)
            }
        }
        return refs   // built-ins (allCases order) first, then customs (registry order)
    }

    /// Gateways that are PARTIALLY configured on this device — user-stored
    /// evidence exists but the ref is NOT send-able (`isRemoteAgentConfigured`
    /// false): a `.bearer` ref whose token didn't sync/resolve here (URL rides
    /// iCloud KVS, token rides iCloud Keychain — separate channels), or an
    /// OpenRouter ref whose token and required model landed unevenly.
    /// `configuredRemoteAgentRefs()` drops these fail-closed, so a healthy
    /// sibling gateway would otherwise mask them entirely — Diagnostics
    /// surfaces the anonymous COUNT (kind/ordinal only, never a name/URL).
    /// Evidence is USER-STORED state only: for a fixed-endpoint (hosted-model)
    /// built-in, `getRemoteAgentURL` returns the app-fixed descriptor URL
    /// unconditionally, so URL presence proves nothing — a stored token or
    /// model is the evidence there; else every fresh install would read
    /// "OpenRouter partial" forever. Same ordering as the configured query.
    func partiallyConfiguredRemoteAgentRefs() -> [RemoteAgentRef] {
        #if DEBUG
        // Mirrors the configured-refs QA branch: overrides are complete by
        // construction, so nothing is "partial" on a QA rig.
        if QAMode.isActive, !QAMode.gatewayOverrides.isEmpty || QAMode.customGatewayOverride != nil {
            return []
        }
        #endif
        ensureKeychainMigrated()
        ensureRemoteAgentMigrated()
        var partial: [RemoteAgentRef] = RemoteAgentBackend.allCases
            .map(RemoteAgentRef.builtin)
            .filter { hasStoredRemoteAgentEvidence($0) && !isRemoteAgentConfigured($0) }
        for gateway in customGateways() {
            let ref = RemoteAgentRef.custom(gateway.id)
            if hasStoredRemoteAgentEvidence(ref), !isRemoteAgentConfigured(ref) {
                partial.append(ref)
            }
        }
        return partial
    }

    /// Every ref this device holds stored state for — the configured ones plus
    /// the half-configured. What the Settings UI needs to decide whether to
    /// offer Forget; computed here so it shares
    /// `hasStoredRemoteAgentEvidence` with the Diagnostics count.
    func storedRemoteAgentRefs() -> Set<RemoteAgentRef> {
        ensureKeychainMigrated()
        ensureRemoteAgentMigrated()
        var refs = Set(
            RemoteAgentBackend.allCases
                .map(RemoteAgentRef.builtin)
                .filter(hasStoredRemoteAgentEvidence)
        )
        for gateway in customGateways() where hasStoredRemoteAgentEvidence(.custom(gateway.id)) {
            refs.insert(.custom(gateway.id))
        }
        return refs
    }

    /// Whether this device holds any USER-STORED state for a gateway — the
    /// predicate behind both the Diagnostics partial count and the Settings
    /// Forget affordance, so the two can never disagree about whether there is
    /// something to remove.
    ///
    /// For a fixed-endpoint (hosted-model) built-in, `getRemoteAgentURL` returns
    /// the app-fixed descriptor URL unconditionally, so URL presence proves
    /// nothing — a stored token or model is the evidence there; else every fresh
    /// install would read "OpenRouter partial" forever.
    func hasStoredRemoteAgentEvidence(_ ref: RemoteAgentRef) -> Bool {
        if case .builtin(let backend) = ref,
           RemoteAgentBackendRegistry.lookup(id: backend).fixedURL != nil {
            let token = getRemoteAgentToken(for: ref)
            let model = getRemoteAgentModel(for: ref)
            return (token?.isEmpty == false) || ((model ?? "").isEmpty == false)
        }
        return getRemoteAgentURL(for: ref) != nil
    }

    /// The single "is this gateway usable" predicate (keyless-aware):
    /// a URL is always required; then `.none` (keyless) is configured on URL
    /// alone, while `.bearer` ALSO requires a non-empty stored token. The bearer
    /// branch FAILS CLOSED — a transient Keychain read failure (nil token) reads
    /// as not-configured, never as a silent keyless downgrade. Keyless is honored
    /// only when the auth scheme is the EXPLICIT persisted `.none`.
    ///
    /// A descriptor-REQUIRED model (OpenRouter) is ALSO required. `saveRemoteAgent`
    /// enforces the model at save, so a locally-saved gateway always has one — but
    /// cross-device the model (iCloud KVS) and the token (iCloud Keychain) sync on
    /// SEPARATE channels, so the token can land first and momentarily make a
    /// model-less OpenRouter read "configured" → a send would fail. Gating on the
    /// model closes that skew (and applies regardless of auth scheme).
    private func isRemoteAgentConfigured(_ ref: RemoteAgentRef) -> Bool {
        guard getRemoteAgentURL(for: ref) != nil else { return false }
        if case .builtin(let backend) = ref,
           RemoteAgentBackendRegistry.lookup(id: backend).requiresModel,
           (getRemoteAgentModel(for: ref) ?? "").isEmpty {
            return false
        }
        if getRemoteAgentAuthScheme(for: ref) == .none { return true }
        guard let token = getRemoteAgentToken(for: ref), !token.isEmpty else { return false }
        return true
    }

    /// Built-in-only view of configured refs (forwards). Kept for callers not
    /// yet ported to refs; delete once every consumer uses `configuredRemoteAgentRefs()`.
    func configuredRemoteAgentBackends() -> [RemoteAgentBackend] {
        configuredRemoteAgentRefs().compactMap {
            if case .builtin(let backend) = $0 { return backend }
            return nil
        }
    }

    // MARK: - Remote Agent — Per-Backend Atomic Snapshot (multi-gateway)

    /// Atomic snapshot of a SPECIFIC backend's configured gateway. Single actor
    /// hop (mirrors the zero-arg `remoteAgentSnapshot()` + `activeSTTSnapshot()`).
    /// Returns nil when the per-backend URL is missing — URL is the hard-required
    /// field; token / fingerprint are independently optional (matching the
    /// single-slot snapshot's "backend OR url missing → nil" semantics, here
    /// the backend is supplied so only url gates).
    ///
    /// `activeSessionID` is read from the GLOBAL session slot — the
    /// active-conversation/session pointer is NOT per-backend; the bound backend
    /// is recovered from the resolved `Conversation.backend`.
    func remoteAgentSnapshot(for ref: RemoteAgentRef) -> RemoteAgentSnapshot? {
        #if DEBUG
        if QAMode.isActive, case .builtin(let backend) = ref, let override = QAMode.gatewayOverrides[backend] {
            return RemoteAgentSnapshot(
                backend: backend,
                ref: ref,
                url: override.url,
                token: override.token,
                authScheme: .bearer,
                model: nil,
                certFingerprintHex: nil,
                activeSessionID: nil
            )
        }
        if QAMode.isActive, case .custom(let id) = ref,
           let override = QAMode.customGatewayOverride, override.gateway.id == id {
            return RemoteAgentSnapshot(
                backend: .openclaw,            // status-map carrier (.unified for all)
                ref: ref,
                url: override.url,
                token: override.token,
                authScheme: .bearer,
                model: override.gateway.model, // exercises the model-on-wire path
                certFingerprintHex: nil,
                activeSessionID: nil
            )
        }
        #endif
        ensureKeychainMigrated()
        ensureRemoteAgentMigrated()

        // Resolve the status-map carrier + optional model by ref kind. A custom
        // with no roster entry (deleted) is NOT configured → nil.
        let statusBackend: RemoteAgentBackend
        let model: String?
        switch ref {
        case .builtin(let backend):
            statusBackend = backend
            // Hosted-model built-ins (OpenRouter, `showsModelField`) carry their
            // persisted model on the wire; self-hosted built-ins (OpenClaw /
            // Hermes, `model == .unsupported`) pick it server-side → nil.
            let descriptor = RemoteAgentBackendRegistry.lookup(id: backend)
            model = descriptor.showsModelField ? getRemoteAgentModel(for: ref) : nil
        case .custom(let id):
            guard let gateway = customGateway(id: id) else { return nil }
            statusBackend = .openclaw   // status-map carrier (.unified for all)
            model = gateway.model
        }

        guard let url = getRemoteAgentURL(for: ref) else {
            return nil
        }
        return RemoteAgentSnapshot(
            backend: statusBackend,
            ref: ref,
            url: url,
            token: getRemoteAgentToken(for: ref),
            authScheme: getRemoteAgentAuthScheme(for: ref),
            model: model,
            certFingerprintHex: getRemoteAgentCertFingerprint(for: ref),
            activeSessionID: getRemoteAgentActiveSession()
        )
    }

    /// Built-in convenience overload — forwards to the ref-based canonical.
    func remoteAgentSnapshot(for backend: RemoteAgentBackend) -> RemoteAgentSnapshot? {
        remoteAgentSnapshot(for: .builtin(backend))
    }

    /// Resolve a snapshot for a conversation's bound backend (the persisted
    /// `Conversation.backend` raw string). Maps rawValue → enum → per-backend
    /// snapshot; returns nil on an UNKNOWN raw value OR an unconfigured backend
    /// — the routing caller maps nil to `.remoteAgentNotConfigured`
    /// (no silent reroute to default). The routing layer consumes this.
    func remoteAgentSnapshot(forConversationBackend rawValue: String) -> RemoteAgentSnapshot? {
        guard let ref = RemoteAgentRef(rawString: rawValue) else {
            return nil
        }
        // Deleted custom: the roster entry is gone (and the per-ref URL slot
        // cleared by `deleteCustomGateway`) → nil → caller maps to
        // `remoteAgentNotConfigured` (NO silent reroute). The explicit guard
        // also covers a half-deleted state (roster gone, slot lingering).
        if case .custom(let id) = ref, customGateway(id: id) == nil {
            return nil
        }
        return remoteAgentSnapshot(for: ref)
    }

    /// Read the session-continuation policy (the "New conversation" setting).
    /// Falls back to `SessionContinuationPolicy.default` (`.minutes30`) when no
    /// value is stored or the stored raw value is unknown (forward-compat).
    /// Reads App Groups for synchronous, cheap access — this device's OWN
    /// per-device value (no KVS read; never globalized from another device).
    func getSessionContinuationPolicy() -> SessionContinuationPolicy {
        guard let raw = defaults.string(forKey: Constants.sessionContinuationPolicyKey),
              let value = SessionContinuationPolicy(rawValue: raw) else {
            return SessionContinuationPolicy.default
        }
        return value
    }

    /// Persist the session-continuation policy. Writes App Groups locally —
    /// the policy is **genuinely PER-DEVICE**: each device (iPhone / iPad / Mac)
    /// reads its OWN App-Group value (`handleICloudChange` never mirrored this
    /// key inbound, so iPhone and iPad were already independent). No iCloud-KVS
    /// write: the Watch follows the iPhone via the multi-gateway broadcast
    /// envelope's `sessionPolicy` slot (`watchEffectiveSessionContinuationPolicy`),
    /// mirroring how the per-device default gateway is couriered. Posting
    /// `.settingsDidChangeRemotely` triggers `PhoneSessionManager` to re-broadcast
    /// the Watch-effective policy to the wrist.
    func setSessionContinuationPolicy(_ value: SessionContinuationPolicy) {
        defaults.set(value.rawValue, forKey: Constants.sessionContinuationPolicyKey)
        postSettingsDidChangeRemotely()
    }

    /// Read the Watch "read replies aloud" toggle (hosted in iPhone Settings;
    /// the Watch consumes it via `WatchSettingsReader.readRepliesAloud()`).
    /// Default OFF when unset (`object(forKey:) as? Bool ?? false` — never the
    /// bare `bool(forKey:)`). App-Group-local read; hydrated by the setter's
    /// dual-write + the `handleICloudChange` KVS mirror.
    func getWatchReadRepliesAloud() -> Bool {
        (defaults.object(forKey: Constants.watchReadRepliesAloudKey) as? Bool) ?? false
    }

    /// Persist the Watch read-aloud toggle. Writes App Groups locally; the
    /// iPhone additionally mirrors to iCloud KVS as the iPhone→Watch courier
    /// (macOS never writes it; iPad edge accepted: last iOS writer steers the
    /// Watch). Unlike `setSessionContinuationPolicy` (now per-device, couriered
    /// via the broadcast envelope), this toggle keeps its KVS dual-write. Posts
    /// `.settingsDidChangeRemotely`.
    func setWatchReadRepliesAloud(_ speak: Bool) {
        defaults.set(speak, forKey: Constants.watchReadRepliesAloudKey)
        #if os(iOS)
        iCloudStore.set(speak, forKey: Constants.watchReadRepliesAloudKey)
        #endif
        postSettingsDidChangeRemotely()
    }

    /// Read the cold-launch landing preference. Falls back to
    /// `OnLaunchMode.default` (`.startNewConversation`) when no value is stored
    /// or the stored raw value is unknown (forward-compat — mirrors
    /// `getSessionContinuationPolicy`).
    func getOnLaunchMode() -> OnLaunchMode {
        guard let raw = defaults.string(forKey: Constants.onLaunchModeKey),
              let value = OnLaunchMode(rawValue: raw) else {
            return OnLaunchMode.default
        }
        return value
    }

    /// Persist the cold-launch landing preference. Dual-writes to App Groups +
    /// iCloud KVS (so the choice rides across the user's devices) and posts
    /// `.settingsDidChangeRemotely` — mirrors `setSessionContinuationPolicy`.
    func setOnLaunchMode(_ value: OnLaunchMode) {
        defaults.set(value.rawValue, forKey: Constants.onLaunchModeKey)
        iCloudStore.set(value.rawValue, forKey: Constants.onLaunchModeKey)
        postSettingsDidChangeRemotely()
    }

    /// Read the currently-active conversation session ID. Nil = no live
    /// session (next turn mints one).
    func getRemoteAgentActiveSession() -> String? {
        let raw = defaults.string(forKey: Constants.remoteAgentActiveSessionKey)
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// Persist the active session ID. Pass nil to clear (backend
    /// or URL change clears the session so the next turn mints a fresh one).
    func setRemoteAgentActiveSession(_ sessionID: String?) {
        if let sessionID, !sessionID.isEmpty {
            defaults.set(sessionID, forKey: Constants.remoteAgentActiveSessionKey)
        } else {
            defaults.removeObject(forKey: Constants.remoteAgentActiveSessionKey)
        }
        postSettingsDidChangeRemotely()
    }

    // MARK: - Remote Agent — Active-Conversation Pointer
    //
    // PER-DEVICE + IMPLICIT-ONLY. The pointer (`Conversation.id` +
    // `lastActivityAt`) lives in this device's App-Group defaults and is
    // WRITTEN only by HEADLESS quick captures (entry-1 Shortcut / App Intent,
    // Watch, Mac hotkey lane) — the implicit lane the pointer exists for.
    // EXPLICIT surfaces (the in-app thread, notification taps, the Share
    // Extension, CarPlay) never stamp it: a user browsing or sharing must not
    // retarget where the next quick capture lands. Only headless captures
    // READ it to choose a conversation — the in-app thread appends to the
    // visible conversation regardless of the pointer/TTL. The pointer is
    // local-only — **never sent on the wire** and never synced (each
    // device keeps its own quick-capture thread). It is gated by the user's
    // `SessionContinuationPolicy` (default `.minutes30`; `.alwaysNew` → always
    // fresh; `.alwaysContinue` → never expires): a HEADLESS capture the policy
    // resolves to "continue" stays on the same thread; otherwise the caller
    // mints a fresh `Conversation`.

    /// Resolve the active conversation for a HEADLESS capture, gated by the
    /// user's `SessionContinuationPolicy`. Returns the stored `Conversation.id`
    /// when the policy says to continue; otherwise nil (the pointer is stale /
    /// absent / always-new, so the caller mints a fresh conversation and records
    /// it via `recordActiveConversation`).
    ///
    /// `now` is injectable for deterministic tests; production passes `Date()`.
    /// Mirrors the atomic-resolver style of `activeSTTSnapshot()` — the ID, the
    /// timestamp, AND the policy are read inside one actor-isolated call so a
    /// concurrent write can't tear the decision.
    func resolveActiveConversationID(now: Date = Date()) -> UUID? {
        guard let raw = defaults.string(forKey: Constants.remoteAgentActiveConversationIDKey),
              let id = UUID(uuidString: raw) else {
            return nil
        }

        let lastActivity = defaults.double(forKey: Constants.remoteAgentActiveConversationActivityKey)
        // `double(forKey:)` returns 0 for a missing key — treat 0 as "no
        // valid stamp" so an ID written without a timestamp is never resolved
        // as fresh.
        guard lastActivity > 0 else {
            return nil
        }

        // Delegate the continue-vs-fresh decision to the policy's shared pure
        // resolver (the single source of truth, also used by the Watch). Reading
        // the id, the timestamp, AND the policy inside this one actor-isolated
        // call keeps the decision tear-free under a concurrent write.
        return getSessionContinuationPolicy()
            .resolvedConversationID(id: id, lastActivity: lastActivity, now: now)
    }

    /// Return the stored active-conversation pointer id WITHOUT applying the
    /// session-continuation policy / TTL — nil only when no valid id is stored.
    ///
    /// For callers that need the RAW pointer, not a quick-capture routing
    /// decision: `SettingsViewModel` (display) and the `ConversationStore`
    /// delete check (a deleted conversation must not remain the quick-capture
    /// target — compare-then-clear). CarPlay no longer reads it (its session
    /// state is an in-memory per-session var, its own lane). Quick captures
    /// resolve through the TTL-gated `resolveActiveConversationID` instead.
    func currentActiveConversationID() -> UUID? {
        guard let raw = defaults.string(forKey: Constants.remoteAgentActiveConversationIDKey),
              let id = UUID(uuidString: raw) else {
            return nil
        }
        return id
    }

    /// Record a successful HEADLESS turn against `conversationID`, stamping the
    /// pointer's `lastActivityAt` to `now` so the next capture inside the TTL
    /// window continues this thread. Call after a turn lands in the store.
    /// Stamp uses `timeIntervalSinceReferenceDate` to match
    /// `resolveActiveConversationID(now:)`.
    func recordActiveConversation(_ conversationID: UUID, now: Date = Date()) {
        defaults.set(conversationID.uuidString, forKey: Constants.remoteAgentActiveConversationIDKey)
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: Constants.remoteAgentActiveConversationActivityKey)
        postSettingsDidChangeRemotely()
    }

    /// Clear the active-conversation pointer (backend / URL change, a
    /// default-gateway re-point, or an explicit "new conversation" action). Next
    /// headless capture mints a fresh `Conversation`.
    func clearActiveConversation() {
        defaults.removeObject(forKey: Constants.remoteAgentActiveConversationIDKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveConversationActivityKey)
        postSettingsDidChangeRemotely()
    }

    // MARK: - Remote Agent — Atomic Snapshot

    /// Atomic snapshot of the configured Personal AI gateway. Single actor
    /// hop — mirrors `activeSTTSnapshot()` to prevent the same race the
    /// STT snapshot closes (separate `getRemoteAgentURL()` +
    /// `getRemoteAgentToken()` calls could observe a half-cleared config
    /// during a Settings-side edit).
    ///
    /// Returns nil when backend OR URL is missing — those are the two
    /// hard-required fields; a probe / converse with either absent is
    /// `.remoteAgentNotConfigured` territory. Token / fingerprint /
    /// session are independently optional.
    struct RemoteAgentSnapshot: Sendable {
        /// Status-map CARRIER only (`.unified` for every backend, incl.
        /// customs). The TRUE identity is `ref`; `backend` is `.openclaw` for a
        /// custom ref so `snapshot.backend.statusMap` keeps working unchanged.
        let backend: RemoteAgentBackend
        /// The true gateway identity (built-in or custom).
        let ref: RemoteAgentRef
        let url: URL
        let token: String?
        /// Auth scheme — `.bearer` (token required) or `.none` (keyless). An
        /// EXPLICIT field, never inferred from `token == nil`: a transient
        /// Keychain read failure returns a nil token but MUST stay `.bearer`
        /// (fail closed), never silently become keyless. Defaults to `.bearer`.
        let authScheme: RemoteAgentAuthScheme
        /// Optional model — nil for built-ins (omit `model`); a custom's model
        /// when set. Threaded into the `/v1/chat/completions` body.
        let model: String?
        let certFingerprintHex: String?
        let activeSessionID: String?
    }

    /// Zero-arg snapshot — now a FORWARDER to the default backend's per-backend
    /// snapshot (multi-gateway). Kept so every existing (not-yet-rewired) call
    /// site stays green: the global active gateway is the default backend. The
    /// per-backend setters / migration populate the default backend's slots, so
    /// a single-gateway install behaves identically post-migration.
    /// `currentRemoteAgentEnvelope()` rides on this too.
    func remoteAgentSnapshot() -> RemoteAgentSnapshot? {
        remoteAgentSnapshot(for: defaultRemoteAgentRef())
    }

    /// Build the current `RemoteAgentBroadcastEnvelope` for the configured
    /// gateway, stamped with a monotonic
    /// `Date().timeIntervalSinceReferenceDate` timestamp. Returns nil when
    /// the gateway is not configured (backend OR URL missing) —
    /// `PhoneSessionManager` uses that signal to skip the
    /// `transferUserInfo` enqueue for the remote-agent slot (no point
    /// shipping an envelope the Watch can't act on).
    func currentRemoteAgentEnvelope() -> RemoteAgentBroadcastEnvelope? {
        let defaultRef = defaultRemoteAgentRef()
        guard let snapshot = remoteAgentSnapshot(for: defaultRef) else {
            return nil
        }
        // Custom-only display fields (built-ins pass nil for all four). A
        // one-release-old Watch that gates the legacy single envelope through
        // `RemoteAgentBackend(rawValue:)` still routes a built-in default and
        // simply ignores a custom default (graceful degradation).
        let custom: CustomGateway? = defaultRef.customID.flatMap { customGateway(id: $0) }
        return RemoteAgentBroadcastEnvelope(
            backendRef: defaultRef.rawString,
            url: snapshot.url,
            name: custom?.name,
            // Model comes from the RESOLVED snapshot (not `custom?.model`) so a
            // built-in hosted backend's model (OpenRouter) reaches the Watch.
            // The snapshot's `.custom` arm already mirrors `gateway.model`, so
            // customs are unchanged; self-hosted built-ins resolve nil.
            model: snapshot.model,
            colorID: custom?.colorID,
            monogram: custom?.monogram,
            token: snapshot.token,
            authScheme: snapshot.authScheme,
            certFingerprintHex: snapshot.certFingerprintHex,
            // The iPhone is the source of truth for file-transfer readiness. The
            // Watch now USES this to decide the per-turn file-delivery
            // instruction on its (spoken) converse turns, so it must carry the
            // READY-gate value — the same `fileTransferReadySnapshot(for:) != nil`
            // gate every capable dispatch surface uses (URL + credential present
            // AND the staged test passed), NOT the raw `available` flag, which
            // can read true while the credential is unreadable. In-actor
            // self-call, no `await`.
            fileTransferAvailable: fileTransferReadySnapshot(for: defaultRef) != nil,
            activeSessionID: snapshot.activeSessionID,
            timestamp: Date().timeIntervalSinceReferenceDate
        )
    }

    /// Full multi-gateway Watch support. Build the
    /// MULTI-gateway envelope carrying EVERY configured backend's per-backend
    /// sub-envelope plus the default-backend pointer, stamped with a monotonic
    /// `Date().timeIntervalSinceReferenceDate`. Returns nil when NO backend is
    /// configured — `PhoneSessionManager` skips the `transferUserInfo` enqueue
    /// for the multi slot in that case (mirrors the single-envelope skip).
    ///
    /// Each sub-envelope is the SAME `RemoteAgentBroadcastEnvelope` the single
    /// broadcast uses, built from `remoteAgentSnapshot(for:)` so a backend
    /// carries its own url / token / cert. `activeSessionID` is the GLOBAL
    /// session slot (the session pointer is not per-backend), so
    /// each sub-envelope carries the same value, keeping it consistent with the
    /// single-envelope builder (which reads the same global slot).
    func currentRemoteAgentMultiEnvelope() -> RemoteAgentMultiBroadcastEnvelope? {
        let configured = configuredRemoteAgentRefs()
        guard !configured.isEmpty else {
            return nil
        }
        // Snapshot the roster ONCE so each custom sub-envelope reads its name /
        // model / badge without re-walking the registry per ref.
        let customs = customGateways()
        // One timestamp for the outer envelope AND each sub-envelope (consistency
        // — a single broadcast carries one logical stamp, not N drifting `Date()`
        // reads).
        let now = Date().timeIntervalSinceReferenceDate
        let subEnvelopes: [RemoteAgentBroadcastEnvelope] = configured.compactMap { ref in
            guard let snapshot = remoteAgentSnapshot(for: ref) else {
                return nil
            }
            // Built-ins pass nil for all four custom display fields; a custom
            // pulls them from its roster entry (already loaded above).
            let custom: CustomGateway? = ref.customID.flatMap { id in
                customs.first { $0.id == id }
            }
            return RemoteAgentBroadcastEnvelope(
                backendRef: ref.rawString,
                url: snapshot.url,
                name: custom?.name,
                // Model from the RESOLVED snapshot (mirrors the single-envelope
                // builder) so a built-in hosted backend's model (OpenRouter)
                // reaches the Watch; customs already mirror `gateway.model` via
                // the snapshot's `.custom` arm, so they're unchanged.
                model: snapshot.model,
                colorID: custom?.colorID,
                monogram: custom?.monogram,
                token: snapshot.token,
                authScheme: snapshot.authScheme,
                certFingerprintHex: snapshot.certFingerprintHex,
                // Per-ref READINESS — each sub-envelope carries ITS OWN ref's
                // READY-gate value (`fileTransferReadySnapshot(for:) != nil`, the
                // same gate every capable dispatch surface uses), unlike the
                // global `activeSessionID` slot, so the Watch decides the
                // per-turn file-delivery instruction per bound gateway. The raw
                // `available` flag can read true while the credential is
                // unreadable; the ready-gate can't. In-actor self-call.
                fileTransferAvailable: fileTransferReadySnapshot(for: ref) != nil,
                activeSessionID: snapshot.activeSessionID,
                timestamp: now
            )
        }
        // `configured` already gated on URL-present (token AND url), so the
        // snapshot map should be lossless; if every snapshot somehow failed,
        // ship nothing rather than an empty-backends envelope.
        guard !subEnvelopes.isEmpty else {
            return nil
        }
        return RemoteAgentMultiBroadcastEnvelope(
            backends: subEnvelopes,
            // The Watch-EFFECTIVE default (its iPhone-set override iff still
            // configured, else the iPhone's device-local default) — NOT the
            // iPhone's own default. The wrist follows the iPhone unless the user
            // set a Watch-specific gateway from the iPhone (the Watch keeps no
            // settings UI). `watchDefaultOverrideRef()` self-heals a dangling
            // override, so this never couriers a not-configured ref.
            defaultBackendRef: watchEffectiveDefaultRef().rawString,
            timestamp: now,
            // The Watch-EFFECTIVE session-continuation policy (its iPhone-set
            // override if any, else the iPhone's own per-device policy). The
            // wrist follows the iPhone unless the user set a Watch-specific TTL
            // from the iPhone. Replaces the old KVS courier for this value.
            sessionPolicy: watchEffectiveSessionContinuationPolicy().rawValue
        )
    }

    // MARK: - iCloud Keychain migration (Part B2)

    /// Self-trigger the migration on first secret access in THIS process. Called
    /// at the top of every secret READ path (`getAPIKey`, `getRemoteAgentToken`,
    /// `activeSTTSnapshot`, `remoteAgentSnapshot`, `presetIDsWithStoredKey`)
    /// BEFORE the SecItem query — so a headless capture in the Shortcuts-intent
    /// or CarPlay process (which never runs the app's launch wiring) still
    /// migrates the old non-sync secret before the now-synchronizable-only read
    /// would miss it. The in-memory `didAttemptKeychainMigration` latch avoids
    /// re-reading the persistent flag on every secret access; the App Groups
    /// `keychainSyncMigratedKey` remains the real cross-process / cross-launch
    /// once-ever guard inside `migrateSecretsToICloudKeychain()`.
    private func ensureKeychainMigrated() {
        guard !didAttemptKeychainMigration else { return }
        migrateSecretsToICloudKeychain()
        // Latch the in-process fast path ONLY once the durable flag confirms a
        // complete pass. A pass that skipped items (Keychain locked
        // pre-first-unlock — headless intent / CarPlay launches) must retry on
        // the NEXT secret read in this process, else the sync-only reads would
        // miss keys migration never copied for the process's whole lifetime.
        if defaults.bool(forKey: Constants.keychainSyncMigratedKey) {
            didAttemptKeychainMigration = true
        }
    }

    // MARK: - Remote Agent multi-gateway migration (single-slot → per-backend)

    /// Self-trigger the single-slot → per-backend remote-agent migration on the
    /// first per-backend read in THIS process. Called at the top of every
    /// per-backend read (`getRemoteAgentToken(for:)`, `remoteAgentSnapshot(for:)`,
    /// `configuredRemoteAgentBackends()`, `defaultRemoteAgentBackend()`).
    ///
    /// MUST run AFTER `ensureKeychainMigrated()` — the keychain-sync migration
    /// makes the legacy token synchronizable, and this migration copies that
    /// synchronizable item into the per-backend slot. Every per-backend read
    /// calls `ensureKeychainMigrated()` immediately before this. The in-memory
    /// `didAttemptRemoteAgentMigration` latch avoids re-reading the persistent
    /// flag on every access; the App Groups `remoteAgentMultiGatewayMigratedKey`
    /// is the real cross-process / cross-launch once-ever guard inside the
    /// migration.
    private func ensureRemoteAgentMigrated() {
        guard !didAttemptRemoteAgentMigration else { return }
        didAttemptRemoteAgentMigration = true
        migrateRemoteAgentToPerBackend()
    }

    /// In-process latch around the synced → device-local default-backend
    /// migration. Called at the top of every default-pointer read (AFTER
    /// `ensureRemoteAgentMigrated()`, so a just-migrated single-slot install's
    /// promoted default is already in the App-Group slot and wins).
    private func ensureDefaultBackendDeviceLocalMigrated() {
        guard !didAttemptDefaultBackendDeviceLocalMigration else { return }
        didAttemptDefaultBackendDeviceLocalMigration = true
        migrateDefaultBackendToDeviceLocal()
    }

    /// One-time migration of the default-backend pointer from synced
    /// (App Groups + iCloud KVS, old behavior) to **device-local** (App Groups
    /// only). LOCAL-WINS:
    ///   1. App Group already holds a valid `RemoteAgentRef.rawString` → keep it
    ///      (this device's existing choice). Mark migrated.
    ///   2. Else the legacy synced iCloud-KVS value (a valid ref) → copy it down
    ///      ONCE as the seed (a wiped/reinstalled device restores the user's last
    ///      synced default). Mark migrated.
    ///   3. Else leave absent → the config-sync bootstrap in
    ///      `defaultRemoteAgentRef()` / the `.openclaw` fallback handle it.
    ///
    /// Tolerant decode — an empty / unknown stored value never overwrites; a
    /// syntactically valid `custom_<uuid>` is preserved even if the roster
    /// hasn't hydrated yet. NEVER clears the active-conversation pointer (this is
    /// not a user re-point; the resolve-time default re-check forces a fresh
    /// thread if the pointer is stale). NEVER gates on `kvsSchemaVersion`.
    private func migrateDefaultBackendToDeviceLocal() {
        guard !defaults.bool(forKey: Constants.remoteAgentDefaultBackendDeviceLocalMigratedKey) else {
            return
        }
        // 1. Local-wins.
        if let local = defaults.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
           RemoteAgentRef(rawString: local) != nil {
            defaults.set(true, forKey: Constants.remoteAgentDefaultBackendDeviceLocalMigratedKey)
            return
        }
        // 2. Seed once from the legacy synced value.
        if iCloudAvailable,
           let stored = iCloudStore.string(forKey: Constants.remoteAgentDefaultBackendKVSKey),
           RemoteAgentRef(rawString: stored) != nil {
            defaults.set(stored, forKey: Constants.remoteAgentDefaultBackendKVSKey)
        }
        // 3. Else leave absent (bootstrap / fallback handles it).
        defaults.set(true, forKey: Constants.remoteAgentDefaultBackendDeviceLocalMigratedKey)
    }

    /// One-time, guarded migration copying the LEGACY single-slot remote-agent
    /// config (backend + URL + cert + Keychain token) into the new PER-BACKEND
    /// slots, then promoting the legacy backend to the default pointer.
    ///
    /// Legacy keys are KEPT (NOT deleted): a mid-migration second
    /// device that hasn't run this yet must still find the legacy token, so
    /// stranding it would break that device. This is a COPY, never a move.
    ///
    /// Flag-gating (partial-pass safety): the URL / cert / default-pointer
    /// copies are pure UserDefaults writes that always succeed. The ONLY
    /// failure-prone step is the Keychain token copy (locked keychain on a
    /// cold launch, or `errSecMissingEntitlement` on an unsigned build). So:
    ///   - No legacy backend (fresh install) → set flag, return.
    ///   - Legacy backend present, NO legacy token → copy URL/cert/default,
    ///     set flag (nothing keychain-gated to wait on).
    ///   - Legacy backend present, legacy token present → copy URL/cert/default,
    ///     attempt the token `SecItemAdd`; set the flag ONLY if the token copy
    ///     confirms (`errSecSuccess` OR `errSecDuplicateItem`). If the token
    ///     read/add fails (locked / unsigned), leave the flag UNSET so the next
    ///     launch retries — the idempotent URL/cert/default re-copies are
    ///     harmless.
    private func migrateRemoteAgentToPerBackend() {
        // Persistent once-ever guard.
        guard !defaults.bool(forKey: Constants.remoteAgentMultiGatewayMigratedKey) else {
            return
        }

        // No legacy backend configured = fresh install (or never set up). Mark
        // migrated so we don't re-scan every launch; no per-backend slots created.
        guard let legacyBackend = getRemoteAgentBackend() else {
            defaults.set(true, forKey: Constants.remoteAgentMultiGatewayMigratedKey)
            return
        }

        // Copy the pure-UserDefaults config (always succeeds). Idempotent — safe
        // to repeat on a retried partial pass.
        if let legacyURL = getRemoteAgentURL() {
            setRemoteAgentURL(legacyURL, for: legacyBackend)
        }
        if let legacyCert = getRemoteAgentCertFingerprint() {
            setRemoteAgentCertFingerprint(legacyCert, for: legacyBackend)
        }
        // Promote the legacy backend to the default pointer (the global active
        // gateway in the multi-gateway world). No-op-guarded internally.
        setDefaultRemoteAgentBackend(legacyBackend)

        // Token copy — the only keychain-gated step. Gate the flag on its outcome.
        let tokenCopySucceeded = copyLegacyRemoteAgentTokenToPerBackend(legacyBackend)
        if tokenCopySucceeded {
            defaults.set(true, forKey: Constants.remoteAgentMultiGatewayMigratedKey)
        }
        // else: leave the flag unset — next launch retries the (idempotent) pass.
    }

    /// Copy the legacy synchronizable bearer token (account
    /// `remoteAgentTokenKeychainAccount`) into the per-backend slot
    /// (`remoteAgentTokenKeychainAccount(for:)`) via `SecItemAdd`, tolerating
    /// `errSecDuplicateItem` (the per-backend item already arrived from another
    /// device). Does NOT delete the legacy item. Mirrors
    /// `migrateSingleSecret`, but reads the SYNCHRONIZABLE legacy item (the
    /// keychain-sync migration already promoted it) rather than a non-sync one.
    ///
    /// Returns:
    ///   - `true` when there was NO legacy token to copy (read returned
    ///     `errSecItemNotFound`) — nothing keychain-gated, so the caller may set
    ///     the migrated flag.
    ///   - `true` when the token copy confirmed (`errSecSuccess` /
    ///     `errSecDuplicateItem`).
    ///   - `false` on any other read/add failure (locked keychain, missing
    ///     entitlement) — the caller leaves the flag unset to retry next launch.
    private func copyLegacyRemoteAgentTokenToPerBackend(_ backend: RemoteAgentBackend) -> Bool {
        // Read the legacy synchronizable token.
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.remoteAgentTokenKeychainAccount,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let (readStatus, result) = secrets.copyMatching(readQuery)

        if readStatus == errSecItemNotFound {
            // No legacy token — nothing keychain-gated to wait on.
            return true
        }
        guard readStatus == errSecSuccess, let data = result as? Data else {
            // Locked keychain / unexpected failure — retry next launch.
            return false
        }

        // Add the per-backend synchronizable copy. Accessibility set at add time.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.remoteAgentTokenKeychainAccount(for: backend),
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        let addStatus = secrets.add(addQuery)

        // errSecDuplicateItem → the per-backend item already arrived from another
        // device; treat as success. Legacy item is NOT deleted.
        return addStatus == errSecSuccess || addStatus == errSecDuplicateItem
    }

    /// Test-only seam: reset the in-process migration latch and run the
    /// multi-gateway migration synchronously, returning whether the persistent
    /// flag is set afterward. The `static let shared` singleton can't be
    /// reconstructed per test, and the in-memory latch fires once per process,
    /// so deterministic migration tests need this explicit re-run hook (mirrors
    /// the `defensiveSnapshotsFromBareObjects` test-seam posture on
    /// `ConversationStore`). NOT used by app code.
    func runRemoteAgentMigrationForTesting() -> Bool {
        ensureKeychainMigrated()
        didAttemptRemoteAgentMigration = false
        ensureRemoteAgentMigrated()
        return defaults.bool(forKey: Constants.remoteAgentMultiGatewayMigratedKey)
    }

    /// Test-only seam: reset ONLY the in-process multi-gateway migration latch
    /// (`didAttemptRemoteAgentMigration`) WITHOUT running the migration — the
    /// pure-reset counterpart to `runRemoteAgentMigrationForTesting()`. A test's
    /// `wipeRemoteAgentState()` clears the PERSISTENT
    /// `remoteAgentMultiGatewayMigratedKey` flag from App Groups; but the
    /// in-process latch survives across tests in one process (the `.shared`
    /// singleton is never reconstructed), so without this reset the migration
    /// stays "already-attempted" and the next per-backend read skips the
    /// re-evaluation that the cleared persistent flag is meant to re-enable.
    /// Resetting the latch lets the next per-backend read re-run the (now
    /// no-op, no legacy config) migration cleanly, restoring true per-test
    /// isolation. NOT used by app code.
    func resetRemoteAgentMigrationLatchForTesting() {
        didAttemptRemoteAgentMigration = false
    }

    /// One-time, guarded, idempotent migration that rewrites each device-local
    /// (non-synchronizable) STT API key + the gateway bearer token into a
    /// SYNCHRONIZABLE Keychain item so they flow across the user's
    /// iPhone/iPad/Mac via iCloud Keychain (E2E-encrypted, developer-blind).
    ///
    /// MUST run at launch BEFORE the first settings read, so the now-
    /// synchronizable steady-state queries (B1) never miss an un-migrated item.
    ///
    /// Mechanics per `Constants.keychainSyncMigratedKey`:
    ///   - Guard on the App Groups flag — return early once migrated.
    ///   - For the token (fixed account) and each `stt.apiKey.*` item: query
    ///     WITHOUT `kSecAttrSynchronizable` — the default isolates exactly the
    ///     old local-only items, auto-skipping any already-synced ones.
    ///   - Read value → `SecItemAdd` it as synchronizable (with
    ///     `kSecAttrAccessibleAfterFirstUnlock`, which is sync-compatible) →
    ///     on success delete the non-sync original.
    ///   - TOLERATE `errSecDuplicateItem` on the add: the sync item already
    ///     arrived from another device → treat as success and still delete the
    ///     local non-sync copy (without this the migration stalls).
    ///
    /// Notes (rationale):
    ///   - A synchronizable item is a DISTINCT keychain item from a non-sync one
    ///     with the same account — that is why a copy-then-delete is required,
    ///     not an in-place attribute flip.
    ///   - iCloud Keychain DISABLED on the device is a non-issue:
    ///     `SecItemAdd(synchronizable: true)` succeeds and the item stays local;
    ///     the OS begins syncing automatically if the user later enables it. No
    ///     fallback path needed.
    ///   - The Watch identity item + `WatchIdentityResolver` are NOT touched —
    ///     this only migrates the STT keys and the gateway token.
    func migrateSecretsToICloudKeychain() {
        // Idempotency guard — the flag is set only after a full pass below.
        guard !defaults.bool(forKey: Constants.keychainSyncMigratedKey) else {
            return
        }

        // Collect the accounts to migrate: the fixed token account + every
        // non-sync `stt.apiKey.*` account currently present. A failed
        // ENUMERATION (locked Keychain pre-first-unlock, IPC error) must not
        // pass for "no items" — that would set the durable flag below and
        // permanently strand un-migrated keys behind the sync-only reads.
        var complete = true
        var accounts: [String] = [Constants.remoteAgentTokenKeychainAccount]
        if let sttAccounts = nonSyncSTTKeyAccounts() {
            accounts.append(contentsOf: sttAccounts)
        } else {
            complete = false
        }

        for account in accounts where !migrateSingleSecret(account: account) {
            complete = false
        }

        // Set the durable flag ONLY after a definitively complete pass (every
        // item migrated or confirmed absent). A partial pass re-runs on the
        // next secret read / launch.
        if complete {
            defaults.set(true, forKey: Constants.keychainSyncMigratedKey)
        }
    }

    /// Enumerate the OLD non-synchronizable `stt.apiKey.*` Keychain accounts.
    /// Same enumeration shape as `presetIDsWithStoredKey()` but WITHOUT the
    /// `kSecAttrSynchronizable` attribute (the default isolates the un-migrated
    /// local-only items). Returns the full account strings (not preset IDs) so
    /// the migration can address each item directly. Nil = the enumeration
    /// itself FAILED (locked Keychain, IPC error) — the caller must treat the
    /// pass as incomplete; `errSecItemNotFound` is a confirmed-empty `[]`.
    private func nonSyncSTTKeyAccounts() -> [String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        let (status, result) = secrets.copyMatching(query)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return nil
        }
        var accounts: [String] = []
        let prefix = Constants.sttApiKeyKeychainAccount(for: "")
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix),
                  account.count > prefix.count else { continue }
            accounts.append(account)
        }
        return accounts
    }

    /// Migrate a single Keychain secret (by account) from non-sync to
    /// synchronizable. Reads the OLD non-sync item, adds a synchronizable copy,
    /// then deletes the non-sync original. Returns whether this account is
    /// DEFINITIVELY settled: migrated, or confirmed absent
    /// (`errSecItemNotFound`). False = a transient failure (locked Keychain,
    /// add error) — the caller must keep the migration flag unset so the pass
    /// re-runs. Never throws.
    private func migrateSingleSecret(account: String) -> Bool {
        // Read the OLD non-sync item explicitly (synchronizable: false).
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let (readStatus, result) = secrets.copyMatching(readQuery)
        // Confirmed absent — nothing to migrate for this account.
        if readStatus == errSecItemNotFound { return true }
        // Locked Keychain / IPC error / undecodable payload — NOT settled.
        guard readStatus == errSecSuccess, let data = result as? Data else {
            return false
        }

        // Add a synchronizable copy. Accessibility must be set at add time.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        let addStatus = secrets.add(addQuery)

        // errSecDuplicateItem → the sync item already arrived from another
        // device; treat as success so we still delete the local non-sync copy.
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            return false
        }

        // Delete the non-sync original (it has been superseded by the sync copy).
        // A failed delete is not a migration failure — the sync copy exists, so
        // the account is settled; the stale non-sync original is inert (all
        // steady-state reads are sync-only).
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        _ = secrets.delete(deleteQuery)
        return true
    }

    // MARK: - Lifecycle (called by ConduckApp)

    /// Pull current iCloud KVS values into local App Groups UserDefaults.
    /// Called from `ConduckApp` `.task` on launch. On first launch of a
    /// second device, this hydrates settings from the cloud before any view
    /// reads from UserDefaults. Trimmed to
    /// `stt.preferredLanguage` + identity keys only (no emoji/polish/vocab).
    func performInitialSync() async {
        guard iCloudAvailable else { return }

        iCloudStore.synchronize()

        // Preferred language — iCloud wins when both have values (second
        // device adopts first device's preference). If only local has a
        // value, push it up so the other device can adopt it next sync.
        if let iCloudValue = iCloudStore.string(forKey: Constants.sttPreferredLanguageKVSKey),
           !iCloudValue.isEmpty {
            defaults.set(iCloudValue, forKey: Constants.preferredLanguageKey)
        } else if let localValue = defaults.string(forKey: Constants.preferredLanguageKey),
                  !localValue.isEmpty {
            iCloudStore.set(localValue, forKey: Constants.sttPreferredLanguageKVSKey)
        }

        // Active preset ID: iCloud wins when set (second device adopts the
        // first device's choice), mirrored into App Groups `defaults` so the
        // durable local read in `getActivePresetID()` is hydrated on first
        // launch. Identity sync is owned by `UserIdentityManager`, not us.
        if let iCloudPreset = iCloudStore.string(forKey: Constants.sttActivePresetIDKVSKey),
           !iCloudPreset.isEmpty {
            defaults.set(iCloudPreset, forKey: Constants.sttActivePresetIDKVSKey)
        } else if let localPreset = defaults.string(forKey: Constants.sttActivePresetIDKVSKey),
                  !localPreset.isEmpty {
            iCloudStore.set(localPreset, forKey: Constants.sttActivePresetIDKVSKey)
        }

        // On-device Apple engine mode: iCloud wins when set (second device
        // adopts the first device's high-quality/dictation choice), mirrored
        // into App Groups `defaults` so the durable read in
        // `getAppleOnDeviceEngineMode()` is hydrated on first launch. Mirrors
        // the `sttActivePresetIDKVSKey` block above.
        if let iCloudEngine = iCloudStore.string(forKey: Constants.appleOnDeviceEngineModeKVSKey),
           !iCloudEngine.isEmpty {
            defaults.set(iCloudEngine, forKey: Constants.appleOnDeviceEngineModeKVSKey)
        } else if let localEngine = defaults.string(forKey: Constants.appleOnDeviceEngineModeKVSKey),
                  !localEngine.isEmpty {
            iCloudStore.set(localEngine, forKey: Constants.appleOnDeviceEngineModeKVSKey)
        }

        // Active TTS provider ID: iCloud wins when set, mirrored into App
        // Groups `defaults` so the durable read in `getActiveTTSProviderID()`
        // is hydrated on first launch. Mirrors the `sttActivePresetIDKVSKey`
        // block above. Per-provider voice (`tts.voice.*`) + model
        // (`tts.customModel.*`) overrides ride iCloud via the same dual-write
        // setters; their cold-launch hydration is handled in
        // `handleICloudChange` (prefix scans).
        if let iCloudTTS = iCloudStore.string(forKey: Constants.ttsActiveProviderIDKVSKey),
           !iCloudTTS.isEmpty {
            defaults.set(iCloudTTS, forKey: Constants.ttsActiveProviderIDKVSKey)
        } else if let localTTS = defaults.string(forKey: Constants.ttsActiveProviderIDKVSKey),
                  !localTTS.isEmpty {
            iCloudStore.set(localTTS, forKey: Constants.ttsActiveProviderIDKVSKey)
        }

        // Cold-launch backfill: an iOS install configured BEFORE the
        // remote-agent KVS dual-write shipped only has these in App Groups.
        // Push them up so the Watch's cold ControlWidget launch resolves the
        // gateway with no live envelope. Backend + URL + read-replies are the
        // KVS-eligible remote-agent settings (token = Keychain, fingerprint =
        // per-device App Groups — neither goes to KVS). Only writes when
        // KVS is empty AND local has a value (never clobbers a newer cloud value).
        if iCloudStore.string(forKey: Constants.remoteAgentBackendKey) == nil,
           let localBackend = defaults.string(forKey: Constants.remoteAgentBackendKey),
           !localBackend.isEmpty {
            iCloudStore.set(localBackend, forKey: Constants.remoteAgentBackendKey)
        }
        // Legacy single-slot URL is iCloud-wins, INBOUND ONLY: it must hydrate
        // back into local `defaults` on a reinstall / fresh device, since
        // `configuredRemoteAgentBackends()` gates on it. No push-up — see the
        // gateway-URL rationale below.
        if let iCloudURL = iCloudStore.string(forKey: Constants.remoteAgentURLKey),
           !iCloudURL.isEmpty {
            defaults.set(iCloudURL, forKey: Constants.remoteAgentURLKey)
        }

        // The default-backend pointer is now DEVICE-LOCAL (App Groups only) —
        // it is deliberately NOT synced here. The one-time seed from any legacy
        // synced KVS value happens in `migrateDefaultBackendToDeviceLocal()`;
        // after that, each device owns its own default and a late KVS write is
        // ignored.

        // Per-backend URL + model: iCloud-wins, HYDRATE-ONLY. A present KVS value
        // lands in local `defaults` (restoring the gateway on a reinstall or a
        // fresh device, where the App Group container was wiped but KVS still
        // holds the config).
        //
        // DELIBERATELY NO local→KVS push-up — same rule the file-server block
        // below states: a push-up cannot distinguish "configured while signed
        // out (push it)" from "deleted remotely while this device was offline
        // (must NOT push)". A device that was offline when a peer hit Forget
        // would resurrect the forgotten gateway into KVS on its next launch and
        // ping-pong it back to every device — the gateway the user removed
        // reappears everywhere. A signed-out-configured gateway simply stays
        // device-local until any config re-save dual-writes it.
        //
        // And DELIBERATELY NO delete-on-absence either. Silence at launch is not
        // evidence of a remote delete: KVS is empty on a device that has never
        // completed a first download (`synchronize()` does not wait for one), and
        // its local cache is reset by an iCloud account change — so treating
        // "absent" as "deleted" would wipe a gateway the user configured while
        // signed out the moment they sign in. A REMOTE DELETE arrives as a change
        // notification naming the key, which `handleICloudChange` acts on; that
        // notification is the evidence, and this pass has none.
        //
        // Per-backend token = Keychain (iCloud-Keychain-synced separately),
        // cert = per-device App Groups — neither goes to KVS.
        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend)
            for key in [
                Constants.remoteAgentURLKey(for: backend),
                Constants.remoteAgentModelKey(for: ref)
            ] {
                if let iCloudValue = iCloudStore.string(forKey: key), !iCloudValue.isEmpty {
                    defaults.set(iCloudValue, forKey: key)
                }
            }
        }

        // Custom STT endpoint URL: iCloud-wins-then-push (parity with the
        // gateway URL above) — the iCloud value hydrates local `defaults` on a
        // reinstall / fresh device (where the App Group container was wiped but
        // KVS still holds the URL); else a local-only value is pushed up. The
        // cert fingerprint is a per-device pin (App Groups, no KVS) — NOT synced.
        if let iCloudCustomURL = iCloudStore.string(forKey: Constants.customSTTURLKey),
           !iCloudCustomURL.isEmpty {
            defaults.set(iCloudCustomURL, forKey: Constants.customSTTURLKey)
        } else if let localCustomURL = defaults.string(forKey: Constants.customSTTURLKey),
                  !localCustomURL.isEmpty {
            iCloudStore.set(localCustomURL, forKey: Constants.customSTTURLKey)
        }
        // Custom STT model + auth scheme: iCloud-wins-then-push (rides across
        // the user's devices alongside the URL).
        if let iCloudCustomModel = iCloudStore.string(forKey: Constants.customSTTModelKey),
           !iCloudCustomModel.isEmpty {
            defaults.set(iCloudCustomModel, forKey: Constants.customSTTModelKey)
        } else if let localCustomModel = defaults.string(forKey: Constants.customSTTModelKey),
                  !localCustomModel.isEmpty {
            iCloudStore.set(localCustomModel, forKey: Constants.customSTTModelKey)
        }
        if let iCloudCustomAuth = iCloudStore.string(forKey: Constants.customSTTAuthSchemeKey),
           !iCloudCustomAuth.isEmpty {
            defaults.set(iCloudCustomAuth, forKey: Constants.customSTTAuthSchemeKey)
        } else if let localCustomAuth = defaults.string(forKey: Constants.customSTTAuthSchemeKey),
                  !localCustomAuth.isEmpty {
            iCloudStore.set(localCustomAuth, forKey: Constants.customSTTAuthSchemeKey)
        }

        // PER-UUID custom voice-endpoint roster + slots (Phase B). Hydrate the
        // ROSTER JSON first (iCloud-wins-then-push) so a fresh device knows which
        // uuids exist; then hydrate each per-uuid URL / STT-model / auth / TTS-
        // model slot. Cert is per-device (App Groups, no KVS) — not synced. The
        // per-uuid key is the shared STT slot (iCloud-Keychain-synced separately).
        if let iCloudRoster = iCloudStore.data(forKey: Constants.customVoiceEndpointsRegistryKey) {
            defaults.set(iCloudRoster, forKey: Constants.customVoiceEndpointsRegistryKey)
        } else if let localRoster = defaults.data(forKey: Constants.customVoiceEndpointsRegistryKey) {
            iCloudStore.set(localRoster, forKey: Constants.customVoiceEndpointsRegistryKey)
        }
        let rosterUUIDs = ((try? JSONDecoder().decode(
            [CustomVoiceEndpoint].self,
            from: defaults.data(forKey: Constants.customVoiceEndpointsRegistryKey) ?? Data()
        )) ?? []).map { $0.id }
        for uuid in rosterUUIDs {
            for key in [
                Constants.customSTTURLKey(for: uuid),
                Constants.customSTTModelKey(for: uuid),
                Constants.customSTTAuthSchemeKey(for: uuid),
                Constants.customTTSModelKey(for: uuid)
            ] {
                if let iCloudValue = iCloudStore.string(forKey: key), !iCloudValue.isEmpty {
                    defaults.set(iCloudValue, forKey: key)
                } else if let localValue = defaults.string(forKey: key), !localValue.isEmpty {
                    iCloudStore.set(localValue, forKey: key)
                }
            }
        }

        // PER-UUID custom-GATEWAY roster + slots. Mirrors the custom voice-
        // endpoint block above (the two are clones — see `persistedCustomGateways()`
        // / `customVoiceEndpoints()`). Hydrate the ROSTER JSON first (iCloud-wins-
        // then-push) so a fresh device knows which gateway uuids exist; then hydrate
        // each per-uuid URL + auth-scheme slot. Token = Keychain (iCloud-Keychain-
        // synced separately); cert = per-device (App Groups, no KVS) — not synced;
        // model/colour/monogram ride INSIDE the roster JSON. The built-in URL loop
        // above (`RemoteAgentBackend.allCases`) never reaches customs.
        if let iCloudGatewayRoster = iCloudStore.data(forKey: Constants.customGatewaysRegistryKey) {
            defaults.set(iCloudGatewayRoster, forKey: Constants.customGatewaysRegistryKey)
        } else if let localGatewayRoster = defaults.data(forKey: Constants.customGatewaysRegistryKey) {
            iCloudStore.set(localGatewayRoster, forKey: Constants.customGatewaysRegistryKey)
        }
        let gatewayUUIDs = ((try? JSONDecoder().decode(
            [CustomGateway].self,
            from: defaults.data(forKey: Constants.customGatewaysRegistryKey) ?? Data()
        )) ?? []).map { $0.id }
        // HYDRATE-ONLY, for the same two reasons as the built-in loop above: a
        // push-up would resurrect a gateway a peer device forgot, and an absent
        // KVS key at launch is not evidence that anything was deleted.
        for uuid in gatewayUUIDs {
            let ref = RemoteAgentRef.custom(uuid)
            for key in [
                Constants.remoteAgentURLKey(for: ref),
                Constants.remoteAgentAuthSchemeKey(for: ref),
                Constants.remoteAgentModelKey(for: ref)
            ] {
                if let iCloudValue = iCloudStore.string(forKey: key), !iCloudValue.isEmpty {
                    defaults.set(iCloudValue, forKey: key)
                }
            }
        }

        // FILE-SERVER config (`fileServer.url.*` / `fileServer.available.*` /
        // `fileServer.folderCapable.*`): iCloud-wins INBOUND hydration only,
        // prefix-scanned (suffixes are dynamic — see the shared
        // `Self.fileServerMirrored*Prefix` constants). Cold-launch counterpart
        // of the `handleICloudChange` mirror — a fresh/reinstalled device
        // hydrates the lane before any composer read, instead of waiting for
        // the first KVS change notification. DELIBERATELY NO local→KVS
        // push-up, unlike the remoteAgent URL blocks above: a push-up cannot
        // distinguish "configured while signed out (push it)" from "deleted
        // remotely while this device was offline (must NOT push)" — an
        // offline device relaunching after a peer's Forget would resurrect
        // the forgotten server into KVS and ping-pong it to every device.
        // A signed-out-configured lane simply stays device-local until any
        // config re-save dual-writes it (acceptable: that matches what the
        // peer devices already believe). The `testedLocally` seed MUST land
        // first: after a remote `available=true` is written into defaults, a
        // local `available=true` no longer proves this device tested locally.
        // Excluded by design: `fileServer.certFingerprint.*` (per-device pin,
        // never synced) + `fileServer.keepImagesInline.*` (retired legacy, mirror-banned)
        // + the local-only probe bookkeeping keys (`testedLocally.` /
        // `folderProbeRevision.` / `folderProbeAttempt.` — never in KVS).
        ensureFileServerTestedLocallySeeded()
        let iCloudSnapshot = iCloudStore.dictionaryRepresentation()
        for (key, value) in iCloudSnapshot where key.hasPrefix(Self.fileServerMirroredURLPrefix) {
            if let url = value as? String, !url.isEmpty {
                defaults.set(url, forKey: key)
            }
        }
        for (key, value) in iCloudSnapshot
        where Self.fileServerMirroredBoolPrefixes.contains(where: { key.hasPrefix($0) }) {
            if let flag = value as? Bool {
                defaults.set(flag, forKey: key)
            }
        }

        // Diagnostic-only KVS schema marker: NEVER gate behavior
        // on this — readers tolerate missing/mismatched values.
        if iCloudStore.object(forKey: Constants.kvsSchemaVersionKey) == nil {
            iCloudStore.set(Constants.kvsSchemaVersion, forKey: Constants.kvsSchemaVersionKey)
        }

        // LAST: prune per-uuid slots whose owner is gone. Deliberately after
        // every roster + slot hydration above, so a mid-sync device can never
        // prune config that was still arriving.
        reconcileOrphanedPerUUIDSlots()
    }

    // MARK: - Orphan reconciliation

    /// One-time sweep removing per-uuid keys whose uuid is absent from its
    /// roster, from BOTH stores.
    ///
    /// Every custom gateway and custom voice endpoint fans out into a family of
    /// suffixed keys, and the roster is the only index of which uuids exist. A
    /// delete path that missed one key family — or a roster that was replaced
    /// wholesale by a sync — leaves those keys with no owner and no reader, and
    /// nothing ever collects them: they are invisible to the settings UI and
    /// immortal in both stores.
    ///
    /// Gated on `iCloudAvailable` by its caller (`performInitialSync`), so a
    /// device that cannot see the cloud roster never prunes against a partial
    /// view. Versioned, so it runs once per schema revision rather than on every
    /// launch. Built-in suffixes (`openclaw`/`hermes`/`openrouter`) are never
    /// touched — only `custom_<uuid>` and bare-uuid suffixes.
    /// Key-family prefixes owned by the CUSTOM-GATEWAY roster
    /// (`remoteAgent.customGateways`). Suffix form is
    /// `RemoteAgentRef.storageKeySuffix` = `custom_<uuid-lowercased>`.
    ///
    /// Every prefix ends in a DOT on purpose: it is what keeps a family prefix
    /// from matching the legacy single-slot key it was derived from
    /// (`remoteAgent.url` is not `remoteAgent.url.`). Dropping a trailing dot
    /// here would put the migration-read slots in scope for deletion.
    private static let gatewayOwnedKeyPrefixes = [
        "remoteAgent.url.", "remoteAgent.authScheme.", "remoteAgent.model.",
        "remoteAgent.certFingerprint.", "remoteAgent.transportHint.",
        "remoteAgent.lastChatSuccess.",
        "fileServer.url.", "fileServer.available.", "fileServer.folderCapable.",
        "fileServer.certFingerprint.", "fileServer.testedLocally.",
        "fileServer.folderProbeRevision.", "fileServer.folderProbeAttempt.",
        "fileServer.keepImagesInline.",
        Constants.imageHistoryPolicyKeyPrefix
    ]

    /// Key-family prefixes owned by the CUSTOM-VOICE-ENDPOINT roster
    /// (`stt.customVoiceEndpoints`). Suffix form is the BARE lowercased uuid —
    /// no `custom_` prefix. Same trailing-dot rule as above: `stt.custom.url`
    /// (no dot) is the legacy singleton and must stay out of scope.
    /// `tts.customModel.<providerID>` is a DIFFERENT literal keyed by provider
    /// ID, not a uuid — correctly absent.
    private static let voiceEndpointOwnedKeyPrefixes = [
        "stt.custom.url.", "stt.custom.model.", "stt.custom.authScheme.",
        "stt.custom.certFingerprint.", "tts.custom.model."
    ]

    /// Every key in either store belonging to `uuid`'s per-uuid families.
    ///
    /// - Parameter customPrefixed: gateway families suffix as `custom_<uuid>`;
    ///   voice-endpoint families suffix as the bare `<uuid>`.
    ///
    /// The uuid is matched CASE-INSENSITIVELY. Production writes it lowercased
    /// (`RemoteAgentRef.rawString`, `Constants.customSTTURLKey(for:)` and
    /// siblings all call `.lowercased()`), while `UUID.uuidString` is uppercase
    /// — comparing the two raw is how a sweep decides that every LIVE gateway is
    /// an orphan and deletes the user's whole configuration off every device.
    private func perUUIDKeys(
        for uuid: UUID,
        prefixes: [String],
        customPrefixed: Bool
    ) -> Set<String> {
        let target = uuid.uuidString.lowercased()
        let allKeys = Set(defaults.dictionaryRepresentation().keys)
            .union(iCloudStore.dictionaryRepresentation().keys)
        return allKeys.filter { key in
            guard let prefix = prefixes.first(where: { key.hasPrefix($0) }) else { return false }
            var suffix = String(key.dropFirst(prefix.count))
            if customPrefixed {
                guard suffix.hasPrefix(RemoteAgentRef.customPrefix) else { return false }
                suffix = String(suffix.dropFirst(RemoteAgentRef.customPrefix.count))
            }
            return suffix.lowercased() == target
        }
    }

    /// Remove every per-uuid key belonging to a deleted custom gateway, from
    /// BOTH stores. Called by `deleteCustomGateway` so a delete collects its own
    /// litter — the orphan sweep is a ONE-TIME historical cleanup and cannot be
    /// the collector for gateways deleted after it latches.
    private func purgeGatewayOwnedSlots(for uuid: UUID) {
        for key in perUUIDKeys(for: uuid, prefixes: Self.gatewayOwnedKeyPrefixes, customPrefixed: true) {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }
    }

    private func reconcileOrphanedPerUUIDSlots() {
        guard defaults.integer(forKey: Constants.orphanSweepVersionKey)
                < Constants.orphanSweepVersion else { return }

        // LOWERCASED — production writes every per-uuid suffix lowercased, and a
        // case-sensitive compare against `UUID.uuidString` (uppercase) marks
        // every live gateway as an orphan. See `perUUIDKeys(for:…)`.
        let gatewayUUIDs = Set(persistedCustomGateways().map { $0.id.uuidString.lowercased() })
        let endpointUUIDs = Set(customVoiceEndpoints().map { $0.id.uuidString.lowercased() })

        /// Whether `key` is an orphan: it starts with one of `prefixes`, its
        /// suffix looks like a uuid slot, and that uuid is not in `roster`.
        func orphanUUID(_ key: String, prefixes: [String], custom: Bool, roster: Set<String>) -> Bool {
            guard let prefix = prefixes.first(where: { key.hasPrefix($0) }) else { return false }
            var suffix = String(key.dropFirst(prefix.count))
            if custom {
                // Built-in suffix (`openclaw`/`hermes`/`openrouter`) — never touch.
                guard suffix.hasPrefix(RemoteAgentRef.customPrefix) else { return false }
                suffix = String(suffix.dropFirst(RemoteAgentRef.customPrefix.count))
            }
            // A malformed suffix is left alone: only something that parses as a
            // uuid can be matched against a roster, and guessing is how a sweep
            // deletes live config.
            guard UUID(uuidString: suffix) != nil else { return false }
            return !roster.contains(suffix.lowercased())
        }

        var doomed: Set<String> = []
        let allKeys = Set(defaults.dictionaryRepresentation().keys)
            .union(iCloudStore.dictionaryRepresentation().keys)
        for key in allKeys {
            if orphanUUID(key, prefixes: Self.gatewayOwnedKeyPrefixes, custom: true, roster: gatewayUUIDs)
                || orphanUUID(key, prefixes: Self.voiceEndpointOwnedKeyPrefixes, custom: false, roster: endpointUUIDs) {
                doomed.insert(key)
            }
        }

        for key in doomed {
            defaults.removeObject(forKey: key)
            iCloudStore.removeObject(forKey: key)
        }

        defaults.set(Constants.orphanSweepVersion, forKey: Constants.orphanSweepVersionKey)
        if !doomed.isEmpty { postSettingsDidChangeRemotely() }
    }

    // MARK: - KVS Observation

    /// Handle an external change to the ubiquitous store. Wired in `init` via
    /// the injected `KVSChangeSource`. Mirrors changed values into App Groups
    /// UserDefaults and posts `.settingsDidChangeRemotely` for view models to
    /// react.
    ///
    /// Takes a `KVSChange` VALUE rather than a `Notification`: production
    /// translates Apple's notification in `LiveKVSChangeSource`, and a test
    /// emits the event directly through `InMemoryUbiquitousStore
    /// .simulateRemoteChange(values:)` — so the inbound mirror is exercised
    /// deterministically, without signing or Apple sync timing.
    func handleICloudChange(_ change: KVSChange) {
        #if DEBUG
        // Suites that suspend iCloud (e.g. CustomVoiceEndpointMigrationTests) must
        // not have stale KVS ServerChange echoes mirrored into their controlled
        // App-Group `defaults` mid-run. No-op for non-suspending suites + production.
        if iCloudSyncSuspendedForTesting { return }
        #endif

        // Only process server changes or initial sync — quota-violation /
        // account-change notifications would re-fire all keys spuriously.
        guard change.reason.deliversRemoteValues else { return }
        let changedKeys = change.changedKeys

        // The `testedLocally` seed must land BEFORE the fileServer mirror below
        // can write a remote `available=true` into defaults — after that write,
        // a local `available=true` no longer proves this device tested locally.
        ensureFileServerTestedLocallySeeded()

        var didChange = false

        if changedKeys.contains(Constants.sttPreferredLanguageKVSKey) {
            if let value = iCloudStore.string(forKey: Constants.sttPreferredLanguageKVSKey),
               !value.isEmpty {
                defaults.set(value, forKey: Constants.preferredLanguageKey)
            } else {
                defaults.removeObject(forKey: Constants.preferredLanguageKey)
            }
            didChange = true
        }

        // Mirror a remote active-preset change into App Groups `defaults`
        // (same key literal) so the durable local read in `getActivePresetID()`
        // reflects the cloud value — matches the `sttPreferredLanguageKVSKey`
        // block above. Surfaces the change so observers (e.g.,
        // PhoneSessionManager re-broadcast) react.
        if changedKeys.contains(Constants.sttActivePresetIDKVSKey) {
            if let value = iCloudStore.string(forKey: Constants.sttActivePresetIDKVSKey),
               !value.isEmpty {
                defaults.set(value, forKey: Constants.sttActivePresetIDKVSKey)
            } else {
                defaults.removeObject(forKey: Constants.sttActivePresetIDKVSKey)
            }
            didChange = true
        }

        // Mirror a remote on-device Apple engine-mode change into App Groups
        // `defaults` (same key literal) so the durable read in
        // `getAppleOnDeviceEngineMode()` reflects the cloud value — matches the
        // `sttActivePresetIDKVSKey` block above. Without this, a second device's
        // already-open Settings Voice→Apple row stays stale until a manual
        // refresh, and the local-defaults fast path is never hydrated.
        if changedKeys.contains(Constants.appleOnDeviceEngineModeKVSKey) {
            if let value = iCloudStore.string(forKey: Constants.appleOnDeviceEngineModeKVSKey),
               !value.isEmpty {
                defaults.set(value, forKey: Constants.appleOnDeviceEngineModeKVSKey)
            } else {
                defaults.removeObject(forKey: Constants.appleOnDeviceEngineModeKVSKey)
            }
            didChange = true
        }

        // Mirror a remote active-TTS-provider change into App Groups `defaults`
        // so the durable read in `getActiveTTSProviderID()` reflects the cloud
        // value — matches the `sttActivePresetIDKVSKey` block above.
        if changedKeys.contains(Constants.ttsActiveProviderIDKVSKey) {
            if let value = iCloudStore.string(forKey: Constants.ttsActiveProviderIDKVSKey),
               !value.isEmpty {
                defaults.set(value, forKey: Constants.ttsActiveProviderIDKVSKey)
            } else {
                defaults.removeObject(forKey: Constants.ttsActiveProviderIDKVSKey)
            }
            didChange = true
        }

        // Mirror a remote Watch read-aloud toggle change into App Groups
        // `defaults` so the durable read in `getWatchReadRepliesAloud()`
        // reflects the cloud value (keeps a second iPhone/iPad's Settings
        // toggle honest — the key is an iPhone→Watch courier, KVS-written by
        // iOS only). Bool variant of the blocks above: presence-check, then
        // `bool(forKey:)`.
        if changedKeys.contains(Constants.watchReadRepliesAloudKey) {
            if iCloudStore.object(forKey: Constants.watchReadRepliesAloudKey) != nil {
                defaults.set(iCloudStore.bool(forKey: Constants.watchReadRepliesAloudKey),
                             forKey: Constants.watchReadRepliesAloudKey)
            } else {
                defaults.removeObject(forKey: Constants.watchReadRepliesAloudKey)
            }
            didChange = true
        }

        // Mirror remote per-provider TTS VOICE overrides (`tts.voice.*`) into
        // App Groups `defaults` so the durable read in
        // `getTTSVoice(forProviderID:)` reflects the cloud value. The suffix is
        // the provider ID, so scan the changed-key prefix (matches the
        // `stt.customModel.*` block below).
        let ttsVoicePrefix = Constants.ttsVoiceKey(for: "")
        for key in changedKeys where key.hasPrefix(ttsVoicePrefix) {
            if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            didChange = true
        }

        // Mirror remote per-provider TTS MODEL overrides (`tts.customModel.*`)
        // into App Groups `defaults` so the durable read in
        // `getTTSCustomModel(forProviderID:)` reflects the cloud value. The
        // suffix is the provider ID → prefix-scan (matches the `tts.voice.*` +
        // `stt.customModel.*` blocks). `tts.customModel.` is disjoint from both
        // `tts.voice.` and `stt.customModel.`, so no double-handling.
        let ttsCustomModelPrefix = Constants.ttsCustomModelKey(for: "")
        for key in changedKeys where key.hasPrefix(ttsCustomModelPrefix) {
            if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            didChange = true
        }

        // Mirror remote per-ref IMAGE-HISTORY POLICY changes
        // (`imageHistory.policy.*`) into App Groups `defaults` so the durable
        // read in `getImageHistoryPolicy(for:)` reflects the cloud value. The
        // suffix is the ref's storage-key suffix → prefix-scan (matches the
        // `tts.voice.*` block above). The retired legacy bool
        // (`fileServer.keepImagesInline.*`) never had an inbound mirror — only
        // the new key syncs both ways.
        for key in changedKeys where key.hasPrefix(Constants.imageHistoryPolicyKeyPrefix) {
            if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            didChange = true
        }

        // The default-backend pointer is DEVICE-LOCAL now: a remote KVS change of
        // `remoteAgentDefaultBackendKVSKey` is deliberately IGNORED (no mirror, no
        // cross-device active-pointer clear). Each device owns its own default;
        // the only KVS read is the one-time legacy seed in
        // `migrateDefaultBackendToDeviceLocal()`.

        // Mirror remote per-backend URL changes into App Groups `defaults` so
        // the durable read in `getRemoteAgentURL(for:)` (and the Watch cold
        // launch) reflects the cloud value.
        for backend in RemoteAgentBackend.allCases {
            let urlKey = Constants.remoteAgentURLKey(for: backend)
            if changedKeys.contains(urlKey) {
                if let value = iCloudStore.string(forKey: urlKey), !value.isEmpty {
                    defaults.set(value, forKey: urlKey)
                } else {
                    defaults.removeObject(forKey: urlKey)
                }
                didChange = true
            }
        }

        // Mirror remote per-ref MODEL changes (`remoteAgent.model.*`) into App
        // Groups `defaults` so the durable read in `getRemoteAgentModel(for:)`
        // reflects the cloud value. Prefix-scanned because the suffix is the
        // ref's storage-key suffix (a custom gateway carries a uuid), matching
        // the `imageHistory.policy.*` block above.
        //
        // Without this, a REMOVAL never landed: OpenRouter's URL is app-fixed,
        // so a stale model alone keeps `hasStoredRemoteAgentEvidence` true and
        // the gateway reads half-configured forever on every peer device.
        for key in changedKeys where key.hasPrefix(Constants.remoteAgentModelKeyPrefix) {
            if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            didChange = true
        }

        // Mirror remote custom STT endpoint URL / model / auth-scheme changes
        // into App Groups `defaults` (same key literals) so the durable reads
        // in `getCustomSTTURL()` / `getCustomSTTModel()` / `getCustomSTTAuthScheme()`
        // reflect the cloud value — matches the per-backend URL block above.
        // The cert fingerprint is a per-device pin (no KVS) and is not mirrored.
        for key in [Constants.customSTTURLKey, Constants.customSTTModelKey, Constants.customSTTAuthSchemeKey] {
            if changedKeys.contains(key) {
                if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                didChange = true
            }
        }

        // Mirror remote per-preset custom MODEL overrides (`stt.customModel.*`)
        // into App Groups `defaults` so the durable read in
        // `getCustomModel(forPresetID:)` reflects the cloud value. The suffix
        // is the preset ID, so scan the changed-key prefix rather than a fixed
        // list (matches the per-backend loop's intent).
        let customModelPrefix = Constants.sttCustomModelKey(for: "")
        for key in changedKeys where key.hasPrefix(customModelPrefix) {
            if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            didChange = true
        }

        // Mirror remote PER-UUID custom voice-endpoint URL / STT-model /
        // auth-scheme / TTS-model changes (`stt.custom.url.<uuid>` etc.) into App
        // Groups `defaults` so the durable per-uuid reads reflect the cloud value.
        // The DOTTED prefixes (note the trailing ".") are DISJOINT from the bare
        // singleton keys (`stt.custom.url` has no trailing dot) handled above, so
        // no double-handling. Cert is per-device (App Groups, no KVS) — not here.
        let customEndpointDottedPrefixes = [
            Constants.customSTTURLKey + ".",
            Constants.customSTTModelKey + ".",
            Constants.customSTTAuthSchemeKey + ".",
            Constants.customTTSModelKey + "."
        ]
        for key in changedKeys where customEndpointDottedPrefixes.contains(where: { key.hasPrefix($0) }) {
            if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            didChange = true
        }

        // Re-mirror the custom voice-endpoint ROSTER JSON on change so the
        // App Groups copy reflects the cloud value (a second device adds/renames
        // an endpoint). `customVoiceEndpoints()` also reads KVS as a fallback,
        // but mirroring locally keeps the durable read cheap + cross-process.
        if changedKeys.contains(Constants.customVoiceEndpointsRegistryKey) {
            if let data = iCloudStore.data(forKey: Constants.customVoiceEndpointsRegistryKey) {
                defaults.set(data, forKey: Constants.customVoiceEndpointsRegistryKey)
            } else {
                defaults.removeObject(forKey: Constants.customVoiceEndpointsRegistryKey)
            }
            didChange = true
        }

        // Mirror remote PER-CUSTOM-GATEWAY URL + auth-scheme changes
        // (`remoteAgent.url.custom_<uuid>` / `remoteAgent.authScheme.custom_<uuid>`)
        // into App Groups `defaults`. The built-in URL loop above enumerates only
        // `RemoteAgentBackend.allCases`, so customs need a prefix scan. The
        // `custom_` segment is provably disjoint from the built-in `openclaw` /
        // `hermes` suffixes, so no double-handling. Token = Keychain, cert =
        // per-device (no KVS) — neither mirrored here.
        let customGatewayURLPrefix = "remoteAgent.url." + RemoteAgentRef.customPrefix
        let customGatewayAuthPrefix = "remoteAgent.authScheme." + RemoteAgentRef.customPrefix
        for key in changedKeys where key.hasPrefix(customGatewayURLPrefix) || key.hasPrefix(customGatewayAuthPrefix) {
            if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            didChange = true
        }

        // Re-mirror the custom-GATEWAY roster JSON on change so the App Groups
        // copy reflects the cloud value (a second device adds/renames/deletes a
        // gateway) and `customGateways()` reloads. Mirrors the voice-endpoint
        // roster branch above. Without this, a roster-only KVS push never flips
        // `didChange`, so `.settingsDidChangeRemotely` never posts and the open
        // Settings screen never reloads — the original cross-device-sync gap.
        if changedKeys.contains(Constants.customGatewaysRegistryKey) {
            if let data = iCloudStore.data(forKey: Constants.customGatewaysRegistryKey) {
                defaults.set(data, forKey: Constants.customGatewaysRegistryKey)
            } else {
                defaults.removeObject(forKey: Constants.customGatewaysRegistryKey)
            }
            didChange = true
        }

        // Mirror remote FILE-SERVER config changes (`fileServer.url.*` /
        // `fileServer.available.*` / `fileServer.folderCapable.*`) into App
        // Groups `defaults` so the durable reads (`getFileServerURL`,
        // `getFileTransferAvailable`, `getFileServerFolderCapable` — the last
        // two read defaults ONLY) reflect the cloud value. Without this, a
        // second device holds URL + credential (KVS fallback + iCloud
        // Keychain) but never `available` → `fileTransferReadySnapshot` stays
        // nil and uploads silently skip until the user re-runs Test Connection
        // there. Suffixes are dynamic (`custom_<uuid>`) → prefix scans over
        // the SHARED `Self.fileServerMirrored*Prefix` lists (one source of
        // truth with the `performInitialSync` hydration; the mirror-ban
        // rationale lives on those constants).
        for key in changedKeys where key.hasPrefix(Self.fileServerMirroredURLPrefix) {
            if let value = iCloudStore.string(forKey: key), !value.isEmpty {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            didChange = true
        }

        // Bool variant of the block above (presence-check, then `bool(forKey:)`
        // — matches the `watchReadRepliesAloudKey` block). `available=true`
        // arriving here means ANOTHER device passed the staged test; this
        // device adopts the verdict (the flag was dual-written to KVS for
        // exactly this since day one). An optional pin is per-device (never
        // synced), so a rotated-but-still-trusted cert this device hasn't
        // re-pinned degrades to a VISIBLE per-upload failure on this device —
        // strictly better than the silent-off lane this mirror fixes.
        // `testedLocally` stays false: adoption is not local proof (it gates
        // the silent re-probe, not uploads).
        for prefix in Self.fileServerMirroredBoolPrefixes {
            for key in changedKeys where key.hasPrefix(prefix) {
                if iCloudStore.object(forKey: key) != nil {
                    defaults.set(iCloudStore.bool(forKey: key), forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                didChange = true
            }
        }

        if didChange {
            postSettingsDidChangeRemotely()
        }
    }
}

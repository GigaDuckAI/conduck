// SPDX-License-Identifier: Apache-2.0

// Conduck
// Constants.swift
//
// Application-wide constants: STT preset config (Mistral Voxtral endpoint +
// model + Keychain/KVS key constants), plus `AppColors` + `BrandedText`.

import Foundation
import SwiftUI
#if os(macOS)
import Security
#endif

/// Application-wide constants
enum Constants {
    // MARK: - Build Identity

    /// Reverse-DNS identity namespace of THIS build, read from the
    /// `ConduckIdentityNamespace` Info.plist key (fed by the xcconfig identity
    /// layer's `CONDUCK_IDENTITY_NAMESPACE`: official `ai.gigaduck.agentrelay`,
    /// community `com.example.conduck`). Every derived identity string below is
    /// `identityNamespace` + a FROZEN suffix, so the official build's resolved
    /// values stay byte-identical to the shipping identifiers. The fallbacks are
    /// safety nets for non-hosted contexts, never the design path.
    /// `nonisolated` — `Constants` is MainActor-isolated by the target's default
    /// isolation; identity strings are read from nonisolated URLSession/queue
    /// contexts, so they must be synchronously readable off the main actor.
    nonisolated static let identityNamespace =
        Bundle.main.object(forInfoDictionaryKey: "ConduckIdentityNamespace") as? String
            ?? (Bundle.main.bundleIdentifier?.lowercased() ?? "conduck.community")

    // MARK: - App Groups

    /// App Group ID for sharing data between main app, Watch extension, and widget
    /// targets. Read from the `ConduckAppGroupID` Info.plist key (fed by
    /// `CONDUCK_GROUP_ID`); official value `group.ai.gigaduck.agentrelay`.
    nonisolated static let appGroupID =
        Bundle.main.object(forInfoDictionaryKey: "ConduckAppGroupID") as? String
            ?? "group.\(identityNamespace)"

    // MARK: - CloudKit

    /// CloudKit container for cross-device conversation sync. Read from the
    /// `ConduckCloudKitContainerID` Info.plist key (fed by
    /// `CONDUCK_ICLOUD_CONTAINER_ID`); official value `iCloud.ai.gigaduck.agentrelay`
    /// (set-once Apple identity; never changes on a product rename — same rule as
    /// bundle IDs / App Group / Keychain). MUST match the
    /// `com.apple.developer.icloud-container-identifiers` entry in both the iOS/macOS
    /// (`Conduck-*.entitlements`) and Watch (`ConduckWatch.entitlements`) targets.
    nonisolated static let iCloudCloudKitContainerID =
        Bundle.main.object(forInfoDictionaryKey: "ConduckCloudKitContainerID") as? String
            ?? "iCloud.\(identityNamespace)"

    /// Whether THIS process may legally construct the CloudKit container above.
    ///
    /// `CKContainer(identifier:)` RAISES — it does not throw or return nil — when
    /// the container is absent from the running process's entitlements, so every
    /// CloudKit entry point is gated on this and degrades to a local-only store
    /// rather than dying seconds after launch.
    ///
    /// macOS only, because macOS is the only platform where an unentitled build
    /// can run: a signed build carries
    /// `com.apple.developer.icloud-container-identifiers` from its provisioning
    /// profile, while the ad-hoc/unsigned build `CODE_SIGNING_ALLOWED=NO`
    /// produces — the only kind buildable without a signing account — carries no
    /// entitlements at all. Elsewhere this is a constant `true`: an unsigned
    /// build cannot run on an iOS/watchOS device, and the Simulator is excluded
    /// separately (it runs CloudKit-free whatever this returns).
    ///
    /// UNCERTAINTY RESOLVES TO TRUE. Sync switches off only when the entitlement
    /// list is read SUCCESSFULLY and this container is not in it; a probe that
    /// errors leaves CloudKit on. A signed build silently losing sync to a failed
    /// probe would be far worse than the unsigned-build crash this prevents, so
    /// the only path to `false` is a positive reading of its absence.
    #if os(macOS)
    nonisolated static let hasICloudContainerEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return true }
        var probeError: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-container-identifiers" as CFString, &probeError
        )
        if let probeError {
            probeError.release()
            return true
        }
        // A nil value with no error is the documented "entitlement simply not
        // present" answer — an unsigned build — and is the ONE positive reading
        // of absence, so it is the only path that may return false here.
        guard let value else { return false }
        // Present but not the documented array-of-strings shape: unreadable, not
        // absent, so it takes the fail-open branch with every other uncertainty.
        guard let containers = value as? [String] else { return true }
        return containers.contains(iCloudCloudKitContainerID)
    }()
    #else
    nonisolated static let hasICloudContainerEntitlement = true
    #endif

    // MARK: - Request Configuration

    /// Maximum audio duration in seconds. 300s (5 min) tuned for CarPlay driver-safety
    /// envelope (no transcription use-case here requires longer turns and a
    /// shorter cap reduces stuck-recording risk).
    static let maxAudioDuration: TimeInterval = 300

    /// Seconds before `maxAudioDuration` at which the soft warning fires
    /// (amber timer + "1 min left" label on Mac, `.warning` haptic on Watch).
    static let maxAudioDurationWarningOffset: TimeInterval = 60

    /// Maximum audio file size in bytes (~15MB). Mistral Voxtral hard cap.
    static let maxAudioSize: Int = 15 * 1024 * 1024

    /// Duration cap for the Apple on-device STT path. Cloud providers are
    /// implicitly bounded by `maxAudioSize`; the in-process `SpeechAnalyzer`
    /// path has no byte gate, so unbounded inputs (e.g. the Shortcuts
    /// `Record Audio` step, which Conduck cannot cap) could grind the
    /// analyzer for hours. Generous vs `maxAudioDuration` — every
    /// Conduck-owned recorder already stops at 300 s.
    static let appleMaxAudioSeconds: TimeInterval = 1800

    /// Request timeout in seconds. 120s gives 2× headroom over observed
    /// end-to-end Voxtral processing time for ~5 min audio.
    static let requestTimeout: TimeInterval = 120

    /// Seconds of continuous "Transcribing…" before the iOS composer surfaces
    /// the stall hint + Cancel affordance. Typical cloud STT returns in 1–5 s;
    /// past this the run is almost certainly in timeout/retry territory and
    /// the user deserves an out instead of a silent spinner
    /// (`feedback_no_silent_retry_budget_extension`).
    static let transcribeStallHintDelay: TimeInterval = 10

    // MARK: - UserDefaults Keys
    //
    // KVS KEY-LENGTH BUDGET — 128 UTF-16 code units, for every key below that is
    // also written to `NSUbiquitousKeyValueStore`. Longest the app can build today
    // is `tts.customModel.custom-openai-tts_<uuid>` at 70. Past the limit
    // `set(_:forKey:)` raises `NSInvalidArgumentException` — a crash, not a silent
    // drop — and nothing on our side catches it first: Apple states the limit in
    // prose but exposes no public constant to check against, and the test double
    // (`InMemoryUbiquitousStore`) is a plain dictionary that validates nothing, so
    // a suite stays green either way.
    //
    // The budget is spent by the PREFIX, not the suffix: a per-uuid suffix is
    // already 43–54 characters (`custom_<uuid>`, `custom-openai-tts_<uuid>`) and
    // is frozen by persistence, so renaming a prefix to something more descriptive
    // is the move that eats the remaining headroom. Do the arithmetic first.

    /// Key for user's preferred transcription language hint (ISO 639-1)
    static let preferredLanguageKey = "preferred_language"

    /// Last Apple on-device locale identifier Conduck `reserve(locale:)`'d
    /// (App-Group, device-local — reservations are per-device, NOT KVS-synced).
    /// The reserve-swap ledger: on a language switch we `release` THIS recorded
    /// locale and reserve the new one, so we only ever release what Conduck
    /// itself pinned and stay within `maximumReservedLocales`. Absent = nothing
    /// reserved yet.
    static let lastReservedAppleLocaleKey = "apple.lastReservedLocale"

    /// Key for onboarding completion status
    static let onboardingCompletedKey = "onboarding_completed"

    /// App-Group flag set when the user taps "Not now" on the Setup Guide
    /// notifications-priming step (`EnableNotificationsStepView`). Honored ONLY
    /// by the low-urgency in-app composer backstop (`ConversationDetailViewModel`)
    /// so an explicit defer isn't immediately undone by re-popping the OS dialog
    /// on the very next send. The genuinely-headless backstops (`ConverseIntent`,
    /// share-drain) ignore it — there a notification is the only feedback channel.
    /// Never cleared: once auth is determined `ensureRequested` no-ops anyway, so
    /// the flag becomes irrelevant. (Stored string keeps its original name for
    /// back-compat; the Swift identifier dropped the "InOnboarding" suffix when
    /// the priming step moved out of onboarding.)
    static let notificationsDeferredKey = "notifications_deferred_in_onboarding"

    /// Identity-stability flag (NOT feature-usage): intended to gate whether
    /// `UserIdentityManager.handleICloudChange` adopts an incoming iCloud UUID, so
    /// two devices launched in parallel can't ping-pong UUIDs forever. **Read-only
    /// in practice** — nothing writes this key, so the gate always reads false and
    /// adoption is unconditional; the read also targets `UserDefaults.standard`
    /// while the App-Group store is this flag's documented home. Wiring a writer
    /// changes identity resolution (watch-pairing blast radius), so it belongs in
    /// its own change with coverage for the newly-reachable branch.
    static let hasBeenUsedKey = "device_has_been_used"

    /// App Groups flag set once after the one-time iCloud-Keychain secret
    /// migration completes (`SettingsManager.migrateSecretsToICloudKeychain`).
    /// Gates the migration so the rewrite of device-local STT keys + the gateway
    /// token into synchronizable Keychain items runs exactly once per device.
    static let keychainSyncMigratedKey = "keychainSyncMigrated"

    /// macOS-only, device-local: whether the one-time "new ⌘⇧2 Screenshot & Ask"
    /// tip has been seen (shown in the menu-bar popover start state for existing
    /// users after the feature lands; dismissed on first interaction or via its X).
    /// App Groups UserDefaults, NOT iCloud-synced — a per-machine "you've seen the
    /// hint" flag.
    static let screenshotAskTipSeenKey = "screenshot_ask_tip_seen"

    /// Device-local: whether the first-run gateway "primer" — the orientation
    /// step 0 of `GuidedGatewaySetupView` that resets the "you bring your own AI"
    /// expectation — has been acknowledged. App Groups UserDefaults, NOT
    /// iCloud-synced (a per-machine "you've seen this screen" flag, mirroring
    /// `onboardingCompletedKey` / `screenshotAskTipSeenKey`).
    static let gatewayPrimerSeenKey = "gateway_primer_seen"

    /// macOS-only, device-local: the Diagnostics relevance gate for the Screen
    /// Recording capability row. Written by the capture preflight
    /// (`RegionCaptureController.preflightPermissions`) when Screen Recording
    /// preflights as granted, or right after `CGRequestScreenCaptureAccess()`
    /// runs — the request call registers Conduck in the Settings pane, and a
    /// row surfaced any earlier would deep-link a pane with no Conduck entry.
    /// Carries NO prompt-history meaning: TCC keys consent to the code
    /// SIGNATURE and it is resettable, so no persisted flag can predict
    /// whether the system consent dialog will appear (hence the capture
    /// flow's rationale-first design). Stored string frozen (pre-dates the
    /// identifier's rename). App Groups UserDefaults, NOT iCloud KVS — TCC
    /// grants are per-machine.
    static let screenRecordingCaptureAttemptedKey = "screen_recording_system_prompt_shown"

    /// macOS-only: whether the app shows a Dock icon + top application menu
    /// (`NSApp.setActivationPolicy(.regular)`) vs. running as a menu-bar-only
    /// utility (`.accessory` — NO Dock icon / app menu, but the `NSStatusItem`
    /// duck stays). Default ON (Dock app). Device-local (App Groups UserDefaults,
    /// NOT iCloud KVS — activation policy is a per-machine window-manager choice,
    /// not a cross-device synced preference). Read SYNCHRONOUSLY at launch via
    /// `SettingsManager.showDockIconAtLaunch()` so the policy is applied in
    /// `applicationWillFinishLaunching` without an actor hop.
    static let showDockIconKey = "showDockIcon"

    /// Device-local: whether the user has dismissed the "iCloud unavailable"
    /// banner for the CURRENT outage episode. Sticky across launches so a
    /// dismissed banner stays dismissed while iCloud remains signed-out — but
    /// `CloudSyncMonitor` RESETS it to false the moment the account returns to
    /// `.available`, so a future outage re-surfaces the banner once. App Groups
    /// UserDefaults, NOT iCloud KVS (the flag's whole point is to behave when
    /// iCloud is down; mirrors `screenshotAskTipSeenKey`'s device-local posture).
    static let iCloudBannerDismissedKey = "icloud_unavailable_banner_dismissed"

    /// iOS/iPadOS-only, device-local: when ON, tapping an agent-REPLY
    /// notification (identifier prefix `NotificationDeepLink.replyIdentifierPrefix`)
    /// deep-links into the thread AND auto-speaks the latest agent reply via
    /// the thread's `ThreadSpeaker`. Default OFF. App Groups UserDefaults, NOT
    /// iCloud KVS — read-aloud is an environment choice (office vs. home), so
    /// each device keeps its own (mirrors `showDockIconKey`'s device-local
    /// posture). Read synchronously at notification-tap time via
    /// `SettingsManager.speakReplyOnNotificationOpenAtTap()`.
    static let speakReplyOnNotificationOpenKey = "speakReplyOnNotificationOpen"

    /// macOS-only, device-local: when ON, replies to QUICK-LANE captures
    /// (menu-bar popover, ⌘⇧1 voice, ⌘⇧2 Screenshot & Ask) are spoken on
    /// arrival via `ReplyVoice`. Main-window sends NEVER speak (in-chat
    /// hard rule); the verdict rides each send as
    /// `sendUserTurn(speaksReply:)` — never VM state (the VM registry shares
    /// instances across popover + window). Default OFF. App Groups
    /// UserDefaults, NOT iCloud KVS (per-machine choice, like `showDockIconKey`).
    static let speakQuickLaneRepliesKey = "speakQuickLaneReplies"

    /// macOS-only: the menu-bar popover's input mode (`MenuBarInputMode` raw
    /// string — `voice` auto-records on summon, `text` shows a focused text
    /// field). Device-local (App Groups UserDefaults, NOT iCloud KVS — which
    /// input fits is a per-machine ergonomic: an office Mac and a laptop in a
    /// café are legitimately different modes; the surface is macOS-only so
    /// syncing buys nothing). Read synchronously at press time via
    /// `SettingsManager.menuBarInputModeAtLaunch()`, mirroring `showDockIconKey`.
    static let menuBarInputModeKey = "menuBarInputMode"

    /// App-Group UserDefaults key PREFIX of a LEGACY per-conversation "last
    /// looked at" marker: `conversations.readState.<uuidString>` → `Double`
    /// (seconds since 1970). **App Group ONLY, never iCloud KVS.**
    ///
    /// READ-AND-DRAIN ONLY — nothing writes a new one. What the user has seen is
    /// an ACCOUNT fact now and lives on the conversation record
    /// (`Conversation.lastViewedAt`), so these keys are only the residue of the
    /// device-local design that preceded it. `ReadStateStore` loads them once at
    /// construction, folds each into its conversation's record as that
    /// conversation actually turns up in a fetch, and deletes the key ONLY on a
    /// confirmed cover; until then the key keeps answering reads so nothing goes
    /// bold in the gap. There is deliberately no one-shot sweep: the initial
    /// CloudKit import is asynchronous, so a done-flag could commit before every
    /// conversation existed locally and would lose the marker of each one that
    /// had not arrived yet.
    ///
    /// One key per conversation (matching the per-ref prefix convention
    /// elsewhere in this file) rather than one dictionary: `DefaultsStore`
    /// offers no compare-and-swap, so a single dictionary key would make every
    /// write a read-modify-write and two writers could lose each other's
    /// markers. Cannot be deleted for several releases — an install that skips
    /// them upgrades straight past its own history.
    static let conversationReadStatePrefix = "conversations.readState."

    /// App-Group UserDefaults key PREFIX of a LEGACY per-conversation "last
    /// looked at WHILE IT WAS SHOWING A FAILURE" marker:
    /// `conversations.failureSeen.<uuidString>` → `Double` (seconds since 1970).
    /// **App Group ONLY, never iCloud KVS.**
    ///
    /// SWEPT AT LAUNCH, NEVER FOLDED, and that asymmetry with the read prefix
    /// above is deliberate. The account's acknowledgement is an ATTEMPT IDENTITY
    /// (`Conversation.failureSeenAttemptID`), not a time, so folding one of these
    /// would have to invent an identity for whatever attempt happens to be failed
    /// right now — and asking again keeps the turn's `createdAt`, so that
    /// invented cover would silence the re-failure permanently. The safe failure
    /// mode is one extra red mark the user clears with a tap, not a hidden one.
    /// Nothing will ever read one again, so `ReadStateStore`'s construction sweep
    /// retires them instead of letting them grow the App-Group domain forever.
    ///
    /// A SIBLING prefix, deliberately not nested under
    /// `conversationReadStatePrefix` — that prefix's marker sweep treats every
    /// key beneath it as a marker and deletes whatever it cannot parse as one,
    /// so a nested key would be swept as an orphan at the next launch.
    ///
    /// SEPARATE FROM the read marker and not derivable from it — the reasoning
    /// lives once, in the `ReadStateStore` header, which is also the only thing
    /// that reads or writes this key.
    static let conversationFailureSeenPrefix = "conversations.failureSeen."

    /// App-Group UserDefaults key holding the LOCAL MIRROR of the account read
    /// cutover, as a `Double` (seconds since 1970). Everything older than it
    /// counts as already viewed, which is what keeps an imported iCloud history
    /// from lighting up on a fresh install.
    ///
    /// THE KEY NAME IS FROZEN. It says "epoch" because that is what it held on
    /// every already-installed device, and renaming it would silently reset all
    /// of them to an unstamped cutover — every conversation older than the next
    /// launch would arrive bold, on every surface at once. The NAME is legacy;
    /// the MEANING is the account cutover.
    ///
    /// Mirror, not truth: the account's value lives in iCloud KVS under
    /// `conversationReadCutoverKVSKey` and the two meet by `min`. This key is
    /// what a synchronous read on a SwiftUI render pass — offline, or before
    /// iCloud has hydrated — actually answers from. Note it shares
    /// `conversationReadStatePrefix`'s literal prefix; the legacy marker sweep
    /// skips it because "epoch" is not a UUID.
    static let conversationReadStateEpochKey = "conversations.readState.epoch"

    /// iCloud KVS key holding the ACCOUNT read cutover, as a `Double` (seconds
    /// since 1970). The one read-state value that travels through KVS rather
    /// than through the conversation record.
    ///
    /// **WHY KVS AND NOT A COLUMN:** the cutover is a fact about the ACCOUNT,
    /// not about any one conversation, and it must never be folded into a record
    /// — a device's stamp means "I was not here before this date", not "the
    /// account read everything before this date", so writing a newly-installed
    /// iPad's stamp onto records would mark months of genuinely unread replies as
    /// read on every device. One account-scoped value is the whole payload: a
    /// single key, a single `Double`, nowhere near the KVS key or size limits
    /// that ruled per-conversation markers out of this store.
    ///
    /// **MERGED BY `min`, NEVER `max`** — see `ReadStateStore.meetCutover`. A
    /// future reader will assume `max` and be wrong.
    ///
    /// The local mirror is `conversationReadStateEpochKey`; reads never come from
    /// here directly, because a KVS read on a render pass is neither offline-safe
    /// nor cheap enough to run per row.
    static let conversationReadCutoverKVSKey = "conversations.readCutover"

    /// App-Group UserDefaults key for the last moment a reply notification was
    /// allowed to play a sound, as a `Double` (seconds since 1970). **App Group
    /// ONLY, never iCloud KVS** — and deliberately not a process-local static:
    /// on iOS the process is relaunched by the background URLSession event once
    /// per landing turn, so a process-local timestamp would reset every time and
    /// a burst of agents answering at once would chime once per reply.
    static let lastReplyChimeAtKey = "notifications.lastReplyChimeAt"

    /// Conduck homepage (marketing site + FAQ); linked from Settings → About
    static let websiteURL = "https://conduck.com/"

    /// Canonical gateway-setup help page (`conduck.com/setup`) — the support URL the
    /// App Store listing, Discord, in-app guided setup, and the conduck-connect README
    /// all point at. Deep-linked per lane via a `#fragment` (e.g. `#compatibility` for
    /// the bring-your-own-server lane).
    static let setupGuideURL = "https://conduck.com/setup/"

    /// The normative "Conduck adapter v1" contract page — the durable spec an AI
    /// coding tool follows to put a small OpenAI-compatible front door in front of
    /// a user-built agent (the guided custom-lane adapter escape hatch links here).
    /// The copied brief hardcodes the sibling `.md` mirror inline.
    static let adapterContractURL = "https://conduck.com/setup/adapter/v1/"

    /// Human-facing "Build it with your AI" guide page — shows the human what the
    /// AI tool will do when it follows the hosted build brief (the copied brief
    /// hardcodes that brief's raw `.md` sibling inline; this page is the human's
    /// view of the same workflow, linked beside the contract from the adapter
    /// escape hatch and the custom-gateway help sheet).
    static let adapterBuildGuideURL = "https://conduck.com/setup/adapter/build/"

    /// Lane-correct "continue on your computer" handoff pages. The full-agent
    /// page leads with `--setup`; the custom-server page leads with
    /// `--check-server`, whose interactive PASS can continue into setup. The
    /// in-app Commands step itself always uses the direct `--setup` action.
    static func setupCommandPageURL(custom: Bool) -> String {
        custom ? "https://conduck.com/setup/custom/" : "https://conduck.com/setup/agent/"
    }

    /// Short typeable display form of `setupCommandPageURL(custom:)` for the
    /// guided flow's heads-up step (no scheme, no trailing slash — something a
    /// user can read off a phone and type on a computer).
    static func setupCommandPageURLDisplay(custom: Bool) -> String {
        custom ? "conduck.com/setup/custom" : "conduck.com/setup/agent"
    }

    /// Privacy policy URL (hosted publicly for App Store + in-app link)
    static let privacyPolicyURL = "https://conduck.com/privacy/"

    /// Terms of Service URL (hosted publicly for App Store + in-app link)
    static let termsOfServiceURL = "https://conduck.com/terms/"

    /// Feedback email address
    static let feedbackEmail = "feedback@gigaduck.ai"

    /// Community landing page on conduck.com, which carries the button through to
    /// Discord. Deliberately NOT a raw `discord.gg` invite code.
    ///
    /// Discord invite codes die — they expire, they can be revoked, and once dead
    /// the code string is claimable by anyone else as their server's vanity URL
    /// (a documented malware-delivery route). A raw code baked in here can only be
    /// corrected by shipping a new build through App Review, so every installed
    /// copy keeps pointing at the dead link for as long as users take to update.
    /// Pointing at a page we control makes rotating the invite a website deploy.
    ///
    /// The code itself lives in exactly one place: `website/src/lib/community.ts`.
    static let discordCommunityURL = "https://conduck.com/discord/"

    // MARK: - User Identity

    /// Keychain service name for user identity storage — `identityNamespace` +
    /// frozen `.user-identity` suffix (official `ai.gigaduck.agentrelay.user-identity`).
    nonisolated static let keychainServiceName = identityNamespace + ".user-identity"

    /// Keychain account name for the user ID
    static let keychainAccountName = "user_id"

    /// iCloud KVS key for cross-device user identity sync.
    static let iCloudKVSUserIDKey = "conduck_user_id"

    /// iCloud KVS key for cross-device preferred-language sync (legacy alias —
    /// new code should use `sttPreferredLanguageKVSKey`).
    static let iCloudKVSPreferredLanguageKey = "conduck_preferred_language"

    // MARK: - STT Device-Crossing Keys
    //
    // Per-provider wire details (endpoint, model tag, multipart shape) live
    // on `STTProvider` registry instances in `Services/STT/STTProvider.swift`
    // (multi-provider expansion). Constants here are the device-
    // crossing keys + cross-cutting defaults that don't belong to any one
    // provider.

    /// Keychain account slot for the API key of a given STT preset. Format
    /// `stt.apiKey.<presetID>` — the V1 Mistral Voxtral literal
    /// `"stt.apiKey.mistral-voxtral"` is preserved as
    /// `sttApiKeyKeychainAccount(for: "mistral-voxtral")` — zero-migration
    /// for existing Voxtral users.
    static func sttApiKeyKeychainAccount(for presetID: String) -> String {
        "stt.apiKey.\(presetID)"
    }

    /// iCloud KVS key tracking which STT preset is active across devices.
    static let sttActivePresetIDKVSKey = "stt.activePresetID"

    /// Default active STT preset for fresh installs: `"apple-on-device"`
    /// (Apple as default for iOS 26+ fresh installs). Existing installs keep
    /// their stored value via the KVS read-through in
    /// `SettingsManager.getActivePresetID()` — the default only applies
    /// when KVS has no stored value, so existing Voxtral users are NOT
    /// migrated.
    static let sttActivePresetIDDefault = "apple-on-device"

    /// iCloud KVS key for cross-device preferred language hint passed to STT.
    static let sttPreferredLanguageKVSKey = "stt.preferredLanguage"

    /// iCloud KVS key for which on-device Apple engine the `apple-on-device`
    /// provider runs (`AppleOnDeviceEngineMode` raw value). Absent = the
    /// `.dictation` default (keyboard-grade, no download). Set to
    /// `highQuality` only when the user opts into the downloadable
    /// `SpeechTranscriber` model in Settings → Voice → Apple.
    static let appleOnDeviceEngineModeKVSKey = "stt.appleOnDeviceEngineMode"

    /// WCSession `transferUserInfo` dict key carrying the atomic STT-state
    /// envelope (presetID + apiKey + monotonic timestamp). Envelope is the
    /// SOLE source of Watch STT state — `applicationContext` no longer
    /// carries `sttActivePresetIDKVSKey` (defeats the iPhone → Watch torn-
    /// read race between the two channels). See `STTBroadcastEnvelope`.
    static let sttActivePresetEnvelopeKey = "stt.activePresetEnvelope"

    /// WCSession interactive message kind: Watch → iPhone settings pull.
    /// Request: ["kind": settingsPullMessageKind]; reply (via replyHandler) =
    /// the SAME envelope payload `broadcastToWatch` ships via transferUserInfo
    /// (STT envelope + remote-agent single/multi envelopes) + the non-secret
    /// `stt.preferredLanguage`. Homed here — Constants compiles into BOTH
    /// targets, so the literal cannot drift like the manually-mirrored Wire
    /// enums; the Wire enums stay at exactly the 11 relay literals the spec pins.
    static let settingsPullMessageKind = "settings-pull"

    /// WCSession interactive message kind: iPhone → Watch diagnostics pull
    /// (the Diagnostics screen's live Watch health query). Request:
    /// `["kind": watchDiagnosticsPullMessageKind]` sent WITH a replyHandler —
    /// the FIRST-ever replyHandler message toward the Watch (WCSession routes
    /// by the SENDER's replyHandler presence, so the relay-reply ship — sent
    /// with `replyHandler: nil` — keeps hitting the Watch's no-reply handler
    /// untouched). Reply = the flat primitive facts under
    /// `WatchDiagnosticsReplyKey` (never a URL/token/name). An old Watch build
    /// without the responder errors the phone's errorHandler → the phone
    /// fail-softs (same path as a timeout). Homed here like
    /// `settingsPullMessageKind` (single literal, both targets).
    static let watchDiagnosticsPullMessageKind = "diagnostics-pull"

    /// Reply-dict keys for the iPhone → Watch diagnostics pull. Flat, primitive
    /// values only (Int/Double/String enum-name/Bool) — allowlist-safe by
    /// construction; app/OS versions are allowed, names/URLs/tokens never.
    /// Every key is OPTIONAL on decode (tolerant both directions: an older
    /// Watch omits keys it doesn't know; an older phone ignores keys it
    /// doesn't know). The phone accepts a reply as a health report ONLY when
    /// `version` is present — an empty `[:]` (a future phone asking a kind
    /// this Watch doesn't know) decodes to "unsupported", never an all-unknown
    /// report.
    enum WatchDiagnosticsReplyKey {
        /// Int — schema version stamp; REQUIRED for the phone to accept the reply.
        static let version = "diag.v"
        static let schemaVersion = 1
        /// String — Watch app marketing version / build (allowlist-safe).
        static let appVersion = "diag.appVersion"
        static let appBuild = "diag.appBuild"
        /// String — watchOS version.
        static let osVersion = "diag.osVersion"
        /// Double — the Watch's in-memory STT-envelope high-water (0 = none since
        /// launch; resets on Watch process relaunch — observational only).
        static let sttEnvelopeTs = "diag.sttEnvelopeTs"
        /// Double — the Watch's PERSISTED remote-agent envelope high-water
        /// (`watch.lastRemoteAgentEnvelopeTimestamp`; 0 = never accepted one).
        /// The only timestamp the phone compares for settings freshness.
        static let agentEnvelopeTs = "diag.agentEnvelopeTs"
        /// Int — `AppleRelayPendingQueue` depth (recordings waiting to relay).
        static let relayQueueDepth = "diag.relayQueueDepth"
        /// String — the Watch's own mic-permission enum name (granted/denied/…).
        static let micPermission = "diag.mic"
        /// String — the Watch's own notification-authorization enum name.
        static let notificationPermission = "diag.notif"
        /// Bool — the Watch's own `isReachable` view of the companion.
        static let companionReachable = "diag.reachable"
    }

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC STT
    /// preset's optional custom MODEL override (non-secret → not Keychain).
    /// Format `stt.customModel.<presetID>`. Empty/absent → the provider's
    /// pinned default model. Dual-stored under the same literal in both
    /// stores so the override rides iCloud across the user's devices
    /// (mirrors `sttPreferredLanguageKVSKey`). Resolved inside
    /// `SettingsManager.activeSTTSnapshot()` so key + provider + model bind
    /// in one actor hop (preserves the torn-read fix).
    static func sttCustomModelKey(for presetID: String) -> String {
        "stt.customModel.\(presetID)"
    }

    // MARK: - TTS Device-Crossing Keys (cloud Text-to-Speech)
    //
    // Per-provider wire details (endpoint, model, voice, transport) live on
    // `TTSProvider` registry instances in `Services/TTS/TTSProvider.swift`.
    // Constants here are the device-crossing keys + defaults. NO new Keychain
    // slot: a vendor's TTS key reads its EXISTING `stt.apiKey.<sttPresetID>`
    // slot (mapped on `TTSProvider.sharedKeySTTPresetID`).

    /// iCloud KVS **and** App Groups UserDefaults key tracking which TTS
    /// provider is active across devices. Dual-stored like
    /// `sttActivePresetIDKVSKey`; the value is a `TTSProvider.id`
    /// (`apple-tts` / `openai-tts` / `mistral-tts` / `elevenlabs-tts`).
    static let ttsActiveProviderIDKVSKey = "tts.activeProviderID"

    /// Default active TTS provider for fresh installs. `apple-tts` — Apple's
    /// `AVSpeechSynthesizer` is free, offline, zero-setup, and the universal
    /// fallback, so it stays the default until the user opts into a cloud
    /// voice (the default only applies when KVS has no stored value, so
    /// existing installs keep their pick).
    static let ttsActiveProviderIDDefault = "apple-tts"

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC TTS
    /// provider's optional VOICE override (non-secret → not Keychain). Format
    /// `tts.voice.<ttsProviderID>`. Empty/absent → the provider's pinned
    /// `defaultVoice`. Dual-stored under the same literal in both stores so the
    /// override rides iCloud across the user's devices (mirrors
    /// `sttCustomModelKey(for:)`). Resolved inside
    /// `SettingsManager.activeTTSSnapshot()` so provider + key + voice bind in
    /// one actor hop.
    static func ttsVoiceKey(for ttsProviderID: String) -> String {
        "tts.voice.\(ttsProviderID)"
    }

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC TTS
    /// provider's optional MODEL override (non-secret → not Keychain). Format
    /// `tts.customModel.<ttsProviderID>`. Empty/absent → the provider's pinned
    /// default `model`. Dual-stored under the same literal in both stores so the
    /// override rides iCloud across the user's devices (the TTS sibling of
    /// `sttCustomModelKey(for:)`). Resolved inside
    /// `SettingsManager.activeTTSSnapshot()` so provider + key + model bind in
    /// one actor hop (preserves the torn-read invariant). DISTINCT from
    /// `customTTSModelKey` (`tts.custom.model`) — that is the BYO custom
    /// endpoint's REQUIRED model; this is the optional per-provider override for
    /// the 4 frozen cloud TTS providers (Apple is withheld at the UI — `.inProcess`
    /// sentinel has no network model to override).
    static func ttsCustomModelKey(for ttsProviderID: String) -> String {
        "tts.customModel.\(ttsProviderID)"
    }

    /// App Groups UserDefaults **and** iCloud KVS key for the BYO custom TTS
    /// endpoint's MODEL (`TTSProvider.customOpenAITTS`). Unlike the 5 frozen
    /// providers — whose model is pinned on the registry — `/v1/audio/speech`
    /// REQUIRES a `model` and it varies per server (`tts-1`, `kokoro`,
    /// vendor-specific), so it is a user field. Default `"tts-1"` when unset.
    /// Distinct from `customSTTModelKey` (`stt.custom.model`): the same server
    /// usually exposes different STT vs TTS model tags. The endpoint base URL,
    /// key, cert pin, and auth scheme are SHARED with custom STT (`stt.custom.*`
    /// + `stt.apiKey.custom-openai`) — only voice (`tts.voice.custom-openai-tts`)
    /// and this model are TTS-specific.
    static let customTTSModelKey = "tts.custom.model"

    /// Per-request timeout (seconds) for the BYO custom TTS endpoint. 60 s — a
    /// short chat reply synthesizes fast even on modest self-hosted hardware
    /// (mirrors `WatchTTSClient`'s 60 s), well under custom STT's 300 s (a full
    /// recording upload). Applied ONLY when `dynamicEndpointKey != nil`; the 5
    /// frozen cloud providers keep the standard `requestTimeout`.
    static let customTTSRequestTimeout: TimeInterval = 60

    // MARK: - Custom OpenAI-compatible STT endpoint (BYO)
    //
    // Storage keys for the 7th STT provider (`STTProvider.customOpenAICompat`,
    // id `custom-openai`). The key itself reuses the generic per-preset
    // Keychain plumbing (`stt.apiKey.custom-openai`); these four keys cover
    // the non-secret config the BYO endpoint additionally needs. Cloned from
    // the `remoteAgent*` gateway layout. The `stt.custom.url` literal is also
    // referenced as `STTProvider.customOpenAICompat.dynamicEndpointKey` — keep
    // the two in lockstep.

    /// App Groups UserDefaults **and** iCloud KVS key for the custom STT
    /// endpoint's BASE URL (https only; user never types the path — the
    /// `/v1/audio/transcriptions` suffix is appended by
    /// `SettingsManager.customSTTTranscribeURL()`, mirroring how the gateway
    /// appends `/v1/models`). Not secret → dual-stored so it rides iCloud
    /// across the user's devices. Matches
    /// `STTProvider.customOpenAICompat.dynamicEndpointKey`.
    static let customSTTURLKey = "stt.custom.url"

    /// App Groups UserDefaults key (NO KVS — per-device pin, mirrors
    /// `remoteAgentCertFingerprintKey`) for the custom STT server's optional
    /// pinned SHA-256 leaf-cert fingerprint, lowercased hex. Empty → default
    /// ATS / system trust (correct for Tailscale Funnel / Let's Encrypt).
    static let customSTTCertFingerprintKey = "stt.custom.certFingerprint"

    /// App Groups UserDefaults **and** iCloud KVS key for the custom STT
    /// endpoint's optional MODEL override (overrides the `whisper-1` default).
    /// Distinct from `sttCustomModelKey(for:)` — that is the per-preset
    /// override for the 6 frozen providers; this is the custom endpoint's own
    /// dedicated slot, surfaced in its config UI alongside URL + auth.
    static let customSTTModelKey = "stt.custom.model"

    /// App Groups UserDefaults **and** iCloud KVS key for the custom STT
    /// endpoint's auth scheme (raw value `"bearer"` / `"none"`). `"none"` is
    /// the keyless local-server case (makes the key SecureField optional and
    /// skips the missing-key guard). Default `"bearer"` when unset.
    static let customSTTAuthSchemeKey = "stt.custom.authScheme"

    /// Per-request timeout (seconds) for the custom STT endpoint
    /// (`timeoutIntervalForRequest`). 300 s mirrors
    /// `remoteAgentConverseRequestTimeout` — a self-hosted Whisper on modest
    /// hardware can take real time. Applied ONLY when `dynamicEndpointKey
    /// != nil`; cloud providers keep the 120 s `requestTimeout` untouched.
    static let customSTTRequestTimeout: TimeInterval = 300

    // MARK: - Multiple named custom voice endpoints (Phase B)
    //
    // Generalizes the SINGLE custom endpoint above into N user-named endpoints
    // (cap `maxCustomVoiceEndpoints`), each one server serving STT and/or TTS.
    // The per-uuid storage keys are built by appending `"." + uuid` to the
    // EXISTING singleton literal, so the bare singleton key
    // (`stt.custom.url` etc.) stays the migration-read form for endpoint #1 and
    // the dotted per-uuid keys (`stt.custom.url.<uuid>`) never collide with it.
    // Mirrors the `CustomGateway` roster + per-ref storage posture.

    /// Per-uuid base URL key (`stt.custom.url.<uuid>`). Built off `customSTTURLKey`
    /// so the legacy bare key is the migration-read form. Dual-stored
    /// (App Groups + iCloud KVS) — rides iCloud across the user's devices, like
    /// the singleton URL. Also resolves the synthesized provider's
    /// `dynamicEndpointKey` (`STTProvider.lookup` / `TTSProvider.lookup`).
    static func customSTTURLKey(for uuid: UUID) -> String {
        customSTTURLKey + "." + uuid.uuidString.lowercased()
    }

    /// Per-uuid cert-fingerprint key (`stt.custom.certFingerprint.<uuid>`).
    /// App Groups ONLY (per-device pin, NO KVS — mirrors the singleton +
    /// `remoteAgentCertFingerprintKey`).
    static func customSTTCertFingerprintKey(for uuid: UUID) -> String {
        customSTTCertFingerprintKey + "." + uuid.uuidString.lowercased()
    }

    /// Per-uuid STT model key (`stt.custom.model.<uuid>`). Dual-stored
    /// (App Groups + iCloud KVS). Default `whisper-1` when unset.
    static func customSTTModelKey(for uuid: UUID) -> String {
        customSTTModelKey + "." + uuid.uuidString.lowercased()
    }

    /// Per-uuid auth-scheme key (`stt.custom.authScheme.<uuid>`, `"bearer"` /
    /// `"none"`). Dual-stored (App Groups + iCloud KVS). Default `"bearer"`.
    static func customSTTAuthSchemeKey(for uuid: UUID) -> String {
        customSTTAuthSchemeKey + "." + uuid.uuidString.lowercased()
    }

    /// Per-uuid TTS model key (`tts.custom.model.<uuid>`). Dual-stored
    /// (App Groups + iCloud KVS). Default `tts-1` when unset.
    static func customTTSModelKey(for uuid: UUID) -> String {
        customTTSModelKey + "." + uuid.uuidString.lowercased()
    }

    /// Cap on user-defined custom voice endpoints (bump here). UI/UX limit —
    /// the "+ Add custom endpoint" affordance disables at this count. Enforced
    /// ONLY on ADD (`upsertCustomVoiceEndpoint`); readers never truncate, so a
    /// roster synced from a higher-cap build stays intact and editable.
    /// iOS/macOS only — no watchOS footprint. Any parity with
    /// `maxCustomGateways` is a product choice, not a constraint: the two cap
    /// unrelated domains with different per-item costs.
    static let maxCustomVoiceEndpoints = 5

    /// App Groups UserDefaults **and** iCloud KVS key holding the JSON-encoded
    /// `[CustomVoiceEndpoint]` roster (id / name ONLY — no badge fields).
    /// Dual-written, mirroring `customGatewaysRegistryKey`. The per-uuid
    /// URL / key / cert / model / auth live in the per-uuid slots above
    /// (+ `stt.apiKey.<sttPresetID>`), NOT in this JSON.
    static let customVoiceEndpointsRegistryKey = "stt.customVoiceEndpoints"

    /// App Groups flag set once after the one-time single-custom → roster
    /// migration completes (`SettingsManager.ensureCustomVoiceEndpointMigrated()`).
    /// Gates the migration so the copy of the legacy `stt.custom.*` slots into
    /// endpoint #1's per-uuid slots runs exactly once per device. Mirrors
    /// `remoteAgentMultiGatewayMigratedKey`.
    static let customVoiceEndpointMigratedKey = "customVoiceEndpointMigrated"

    /// App Groups key holding the `uuidString` of the roster endpoint the
    /// one-time migration copied the LEGACY singleton config into — the one
    /// endpoint whose deletion also retires the bare `stt.custom.*` slots and the
    /// synchronizable `stt.apiKey.custom-openai` Keychain item.
    ///
    /// Ownership is STAMPED, never inferred from a URL match: two endpoints may
    /// legitimately share one self-hosted base URL (different key, different
    /// model), and naming the wrong owner deletes a synchronizable Keychain item
    /// off every device on the account — including a peer still on the pre-roster
    /// build, which the copy-not-move migration exists to protect.
    ///
    /// App-Group LOCAL, never KVS, matching `customVoiceEndpointMigratedKey`:
    /// each device runs its own migration and may mint its own endpoint uuid.
    static let customVoiceEndpointMigratedUUIDKey = "customVoiceEndpointMigratedUUID"

    // MARK: - Remote Agent (Personal AI gateway)
    //
    // Network-layer + storage-key constants for the OpenClaw / Hermes
    // round-trip. Storage keys reserved here so the Settings UI lands
    // without re-touching this file. Wire-level dispatch facts (header
    // vs. body field) live in `RemoteAgentClient`, NOT here.

    /// Background `URLSession` identifier for the agent round-trip
    /// (`/v1/chat/completions`). `identityNamespace` + frozen `.converse` suffix,
    /// distinct from the `.stt` id to keep delivery cross-talk impossible.
    /// Consumed by the `ConverseUploadCoordinator`; reserved here so the
    /// value is single-sourced from day one.
    nonisolated static let remoteAgentConverseSessionIdentifier = identityNamespace + ".converse"

    /// Background `URLSession` identifier for the WATCH agent round-trip
    /// (`/v1/chat/completions`). `identityNamespace` + frozen `.watch.converse`
    /// suffix — distinct from the iOS `.converse` id AND from the `.watch.stt`
    /// id so the three delivery channels never
    /// cross-talk (`docs/ai-context/spec.md`). Consumed by
    /// `WatchAudioUploader.uploadConverse(...)` and the matching
    /// `ConduckWatchApp.backgroundTask(.urlSession(...))` handler — change
    /// in lockstep or the system-relaunch event won't route back to the
    /// converse delegate. Reuses the shared 300/600 s timeouts above.
    nonisolated static let remoteAgentWatchConverseSessionIdentifier = identityNamespace + ".watch.converse"

    /// Background `URLSession` identifier for the CARPLAY agent round-trip
    /// (`/v1/chat/completions`). Distinct from the iOS `.converse` id, the
    /// `.watch.converse` id, AND the two `.stt` ids so the delivery channels
    /// never cross-talk (`docs/ai-context/spec.md`). The CarPlay
    /// converse hop routes over a background session (NOT foreground) — agent
    /// replies take 30 s–several minutes; a background session survives app
    /// suspension and is not subject to the ~30 s `beginBackgroundTask` budget,
    /// so the turn always completes + persists + syncs even when the driver
    /// navigates away to Maps. Consumed by `CarPlayConverseUploader` and the
    /// matching `ConduckApp.backgroundTask(.urlSession(...))` handler —
    /// change in lockstep or the system-relaunch event won't route back to the
    /// converse delegate. Reuses the shared 300/600 s timeouts above.
    nonisolated static let remoteAgentCarPlayConverseSessionIdentifier = identityNamespace + ".carplay.converse"

    /// CarPlay VAD speech threshold (`docs/ai-context/spec.md`). Higher
    /// than the in-app default (`EndOfSpeechDetector.SensitivityLevel.medium`
    /// = 0.5) to reject road / cabin noise and HFP-mic artefacts — a moving
    /// car is a far noisier capture environment than a hand-held phone. The
    /// research-recommended band is ~0.65–0.7; 0.65 keeps short command-style
    /// utterances detectable while still rejecting steady road noise.
    static let carPlayVADThreshold: Float = 0.65

    /// CarPlay VAD minimum-silence duration (seconds) before declaring
    /// end-of-speech (`docs/ai-context/spec.md`). Shorter than the
    /// FluidAudio default (0.75 s) only marginally — ~0.8 s gives a
    /// conversational turn a brief natural pause without ending the turn on a
    /// mid-sentence breath, which matters more in a noisy cabin where false
    /// end-of-speech is costly (the loop would re-arm and capture road noise).
    static let carPlayVADMinSilence: TimeInterval = 0.8

    /// CarPlay zero-input follow-up timeout (seconds). After the loop re-arms
    /// the mic for the next turn, if no `onSpeechStart` fires within this
    /// window the session speaks a brief sign-off and ends — the cabin-noise /
    /// no-follow-up guard (`docs/ai-context/spec.md`). Same
    /// magnitude as the cold-connect `initialSilenceTimeout` (10 s) but shorter:
    /// a re-arm after a spoken reply is a deliberate "your turn" prompt, so a
    /// shorter patience window before signing off reads as conversational.
    static let carPlayFollowUpSilenceTimeout: TimeInterval = 5

    /// CarPlay HFP route-settle delay (seconds) after TTS finishes, before the
    /// loop restarts the capture engine to re-arm the mic. Skipping this races
    /// the Bluetooth-HFP route renegotiation that follows a playback→capture
    /// transition and crashes `engine.start()` with FourCC `'!obj'`
    /// (560947818) — the same g1 audio-race the scene delegate guards on the
    /// initial turn (`docs/ai-context/spec.md`).
    /// (`'!int'` is the DIFFERENT code 560557684 = `CannotInterruptOthers`.)
    static let carPlayHFPSettleDelay: TimeInterval = 0.3

    /// CarPlay COLD-START route-settle delay (seconds) for a fresh session's
    /// first listen, used AFTER `setActive(true)` and BEFORE `engine.start()`.
    /// Longer than the in-session re-arm `carPlayHFPSettleDelay` (0.3 s) because
    /// a *cross-session* cold start reacquires RemoteIO after the PRIOR session's
    /// `setActive(false, .notifyOthersOnDeactivation)` tore the HFP route down:
    /// the unit is mid-reacquisition and `engine.start()` is intermittently
    /// refused with FourCC `'nope'` (1852797029). The retry/recovery path
    /// (`startCaptureEngineWithRetry`) reuses this for its hard-recovery settle.
    /// A moderate bump over the 0.3 s re-arm window — enough for a genuine
    /// fresh-process route settle, while the cross-session *wedged-state* refusal
    /// (which a longer wait alone does NOT fix) is handled by the hard
    /// deactivate/reactivate recovery, not by inflating this delay.
    static let carPlayColdStartSettleDelay: TimeInterval = 0.6

    /// WCSession `applicationContext` + iCloud KVS key for the timestamp
    /// (`timeIntervalSinceReferenceDate`, Double) of the Watch's last successful
    /// agent turn. The Watch posts it on each converse success; the iPhone reads
    /// it for the Settings → Apple Watch sub-section. Single literal,
    /// referenced on both the Watch write site (`WatchSessionManager`) and the
    /// iOS read site (`PhoneSessionManager`).
    static let watchLastSuccessfulTurnKey = "watch.lastSuccessfulTurn"

    /// `transferUserInfo` payload MARKER identifying a settings-broadcast
    /// courier (`[watchBroadcastKindKey: watchBroadcastKindSettings]`), stamped
    /// by `PhoneSessionManager.assembleSettingsPayload()`. Load-bearing filter:
    /// relay transcript replies ALSO ride `transferUserInfo` (the
    /// `sendMessage`-fallback ship in `AppleSpeechRelayCoordinator`), so the
    /// broadcast-outcome stamps + the outstanding-transfer count below MUST
    /// select on this marker or they'd count relay traffic as settings
    /// couriers. Additive — the Watch's envelope decoder ignores unknown keys.
    static let watchBroadcastKindKey = "watch.broadcast.kind"
    static let watchBroadcastKindSettings = "settings-broadcast"

    /// App-Group stamps (`Double`, `timeIntervalSinceReferenceDate`; 0/absent =
    /// never) for settings-broadcast DELIVERY outcomes, written by
    /// `PhoneSessionManager.session(_:didFinish:error:)` — success/failure date
    /// ONLY, never error content. Persisted (not in-memory) because a failing
    /// settings courier is exactly the fact that must outlive the process; but
    /// treated as opportunistic forensics, not an authoritative ledger (Apple
    /// doesn't promise launching the app just to deliver the callback). Cleared
    /// on `sessionDidDeactivate` so a Watch switch can't carry the OLD watch's
    /// failure stamps. Read by the Diagnostics `sync.watch` row.
    static let watchBroadcastLastSuccessAtKey = "watch.broadcast.lastSuccessAt"
    static let watchBroadcastLastFailureAtKey = "watch.broadcast.lastFailureAt"

    /// App-Group stamp (`Double`) — the timestamp of the LAST remote-agent
    /// multi envelope the phone assembled for the wrist (broadcast OR pull
    /// reply; `assembleSettingsPayload()` is the single composition site). The
    /// phone-side half of the Diagnostics settings-freshness read: compared
    /// against the Watch's persisted `watch.lastRemoteAgentEnvelopeTimestamp`
    /// (returned by the diagnostics pull) — watch ≥ phone means the newest
    /// courier the phone ever minted has been accepted. NOT cleared on Watch
    /// switch (it describes what the phone minted, not per-watch delivery).
    static let watchBroadcastLastAgentEnvelopeTsKey = "watch.broadcast.lastAgentEnvelopeTs"

    /// iCloud KVS + WCSession `applicationContext` key for the "Enable on Watch"
    /// master switch (Bool, default ON when unset). iPhone writes it;
    /// the Watch reads it to suppress the ControlWidget/record action when off.
    /// Single literal, referenced on both the iOS write site (`PhoneSessionManager`)
    /// and the Watch read site (`WatchSettingsReader`).
    static let watchEnabledKey = "watch.enabled"

    /// iCloud KVS key for the Watch "read replies aloud" toggle (Bool, default
    /// OFF when unset). Hosted in iPhone Settings (the Watch has no settings
    /// UI); the iPhone dual-writes App Groups + KVS as an iPhone→Watch courier
    /// (macOS never writes it; the Watch reads App-Group first via
    /// `readRepliesAloud()`, KVS as the cold-launch fallback).
    /// The Watch reads it via `WatchSettingsReader.readRepliesAloud()` at
    /// reply time: ON ⇒ replies to HEADLESS (ControlWidget/Action Button) and
    /// in-app ASK captures auto-speak on arrival while the app is `.active`,
    /// and a reply-notification tap speaks on thread open. Composer sends
    /// never auto-speak (in-chat hard rule).
    static let watchReadRepliesAloudKey = "watch.readRepliesAloud"

    /// App-Group UserDefaults key for the one-time Watch first-run welcome
    /// (`WatchOnboardingView`). Bool, default OFF (unseen) when unset. Watch-LOCAL
    /// and device-scoped — the wrist is the only writer/reader, so it is NOT
    /// couriered from the iPhone and NOT mirrored to iCloud KVS (per-install
    /// first-run state, and KVS is unreliable on watchOS). Reset by a reinstall
    /// (fresh container ⇒ fresh welcome), which is intended.
    static let watchOnboardingSeenKey = "watch.onboardingSeen"

    /// Per-request timeout for the converse hop (`timeoutIntervalForRequest`).
    /// 300 s covers typical local-LLM compute on modest hardware
    /// (`docs/ai-context/spec.md`). Load-bearing — lowering this
    /// kills in-flight turns as "Network Offline" while the gateway is
    /// still computing the reply.
    static let remoteAgentConverseRequestTimeout: TimeInterval = 300

    /// Resource-lifetime timeout for the converse hop
    /// (`timeoutIntervalForResource`). Budgets the transfer's own retries
    /// within a single round-trip without resurrecting a session the user has
    /// abandoned.
    ///
    /// NOT A CEILING ON HOW LONG A TURN CAN LEGITIMATELY BE IN FLIGHT, and
    /// nothing may derive one from it. On iOS the converse hop runs on a
    /// background `URLSession`, which waits for connectivity unconditionally
    /// before it dispatches at all; Apple does not document whether this
    /// interval covers a pre-dispatch park, so an offline send can outlive it
    /// by any margin. What actually protects the launch-time stale-`sending`
    /// sweep from flipping a live turn is the live-task exclusion set the sweep
    /// is handed (`BackgroundRemoteAgent.liveConversationIDs`), never this
    /// number; and what bounds a parked turn for the user is Stop, not a timer.
    static let remoteAgentConverseResourceTimeout: TimeInterval = 600

    /// Hard ceiling on the bytes a BACKGROUND `URLSession` delegate will
    /// accumulate for ONE JSON response body, before the body is decoded.
    /// Applies to all four background ingest hops (converse on iOS/macOS ·
    /// CarPlay converse · Watch converse · background STT), each of which
    /// buffers the whole body in memory. Past the ceiling the task is cancelled
    /// and the turn fails with `remoteAgentInvalidResponse` / `invalidResponse`
    /// (a normal, retryable failure) instead of growing until the OS jetsams the
    /// app — the surface with the tightest memory budget, watchOS, fails first.
    ///
    /// 16 MiB is deliberately far above any legitimate reply: a model's maximum
    /// output (~128 k tokens) is roughly 0.5 MB of text, and JSON escaping does
    /// not multiply that by 30. So no real long answer, code dump, or verbose
    /// STT transcript can be rejected by this — it only bites a peer that is
    /// fabricating a body, which the threat model treats as hostile. Nothing
    /// caps the DECODED reply string: a length gate there would turn a genuine
    /// long answer into a hard failure the user cannot get past, and one bound
    /// at the transport layer is sufficient.
    nonisolated static let maxBackgroundResponseBytes = 16 * 1024 * 1024

    /// Default listening port for an OpenClaw gateway (the project's
    /// upstream-documented port). Surfaced as the Settings URL-field
    /// placeholder via `RemoteAgentBackend.openclaw.defaultPort`.
    static let openclawDefaultPort = 18789

    /// Default listening port for a Hermes gateway. Surfaced as
    /// the Settings URL-field placeholder via
    /// `RemoteAgentBackend.hermes.defaultPort`.
    static let hermesDefaultPort = 8642

    /// OpenRouter's fixed API ROOT for the hosted-model backend. **MUST end at
    /// `/api`, NOT `/api/v1`** — `RemoteAgentClient` itself appends
    /// `/v1/chat/completions` and `/v1/models`, so `/api/v1` here would produce
    /// a doubled `/v1/v1/...` path that 404s. Unlike OpenClaw/Hermes (the user's
    /// own server, user-typed URL) OpenRouter is a third-party hosted backend
    /// with a known endpoint the user never types — see
    /// `RemoteAgentBackendMetadata` (`endpoint == .fixed`).
    static let openRouterBaseURLString = "https://openrouter.ai/api"

    /// Context trim policy cap (`docs/ai-context/spec.md`). Under
    /// client-owned history `RemoteAgentClient` sends the active
    /// conversation's prior turns plus the new user turn; only the last
    /// `contextMaxTurns` prior turns cross the wire. This is a SENT-ARRAY
    /// cap only — the conversation store keeps every turn for
    /// display. Default is generous (voice threads are short; a high cap is
    /// effectively "all") and conservative on cost — the user pays their own
    /// LLM bill, so trimming is the only client-side cost lever.
    static let contextMaxTurns = 40

    /// Inline image-history window for the DEFAULT `.recent` policy: the count
    /// of most-recent IMAGE-BEARING prior turns whose images ride the wire as
    /// full inline base64 (`image_url` parts). Older image-bearing turns whose
    /// attachment has a persisted `storedKey` (dual-image route — uploaded once
    /// to the gateway file-server) DROP their inline bytes and instead splice an
    /// imperative file reference telling the agent to re-open the file from disk
    /// if it needs detail not in the text history. This converts prior-turn
    /// images from "re-shipped every turn" (the ~10× image-turn latency driver)
    /// to "uploaded once, referenced after." The current turn's images are NEVER
    /// dropped. Window selection is now driven by the per-gateway
    /// `ImageHistoryPolicy` (`imageHistoryPolicyKey`): `.recent` → this value,
    /// `.extended` → `imageInlineWindowExtended`, `.all` → no window (every
    /// image-bearing turn inline, the historic behavior). FOUNDER-TUNABLE;
    /// decided with founder: 3.
    static let imageInlineWindow = 3

    /// Inline image-history window for the `.extended` policy — same demotion
    /// shape as `imageInlineWindow`, wider in-full vision history at higher
    /// cost/latency on image-heavy chats. FOUNDER-TUNABLE: 10.
    static let imageInlineWindowExtended = 10

    /// Grace window for NEVER-UPLOADED (unkeyed) prior-turn images under the
    /// windowed policies (`.recent`/`.extended`): an unkeyed image beyond the
    /// inline window has no file to reference, so it stays inline until this
    /// many image-bearing turns have passed, then EXPIRES to the honest
    /// `spliceImageUnavailableNote` (a mixed turn demotes its keyed subset to
    /// disk refs + notes only the unkeyed count). NOT headroom added beyond
    /// the inline window — an ABSOLUTE depth on the same newest-first
    /// image-bearing-turn counter, so under `.recent` (window 3) orphans get 7
    /// extra turns of grace, while under `.extended` (window 10) the two
    /// windows coincide and orphans expire at the window edge. Bounds the
    /// token burn of images that ride exactly where no file fallback exists
    /// (server-less / failed-upload), which previously stayed inline for the
    /// full `contextMaxTurns`. `.all` never expires. FOUNDER-TUNABLE: 10.
    static let imageOrphanInlineWindow = 10

    /// Max EXTRACTED UTF-8 size (bytes) for a text/code attachment to ride the
    /// wire INLINE as a fenced block. At or below this a text file is dual-routed
    /// when the bound gateway has a file-server (inline copy NOW + an eager upload
    /// of the raw bytes so the agent's tools can act on the real file); above it
    /// the file is too large to inline and rides file-only (the existing
    /// `.serverFile` strict-send-gating path). A server-less gateway ignores this
    /// (inline-only, any size — no regression). Routed by extracted byte count,
    /// NOT raw on-disk size. FOUNDER-TUNABLE (like `imageInlineWindow`): 32 KB is
    /// a comfortable "paste a note / config / short source file" ceiling.
    static let textInlineMaxBytes = 32 * 1024

    /// Aggregate per-turn budget (bytes) for INLINE text across ALL text
    /// attachments on one turn. Once a turn's accepted inline text exceeds this,
    /// further small text files demote to ref-only ON THE WIRE (their eager upload
    /// already exists, so the agent's tools still reach them) — keeps a turn that
    /// staples many small files from ballooning the prompt. FOUNDER-TUNABLE:
    /// 96 KB ≈ three full-size inline files.
    static let textInlineTurnBudgetBytes = 96 * 1024

    /// Hard cap (bytes of UTF-8) on a Safari page-text capture. PAIRED
    /// LITERALS — this value is deliberately duplicated where this file can't
    /// be imported: `WebPageCapture.maxCaptureBytes` (compiled into both
    /// share appexes, which never see `Constants`) and `MAX_BYTES = 131072`
    /// in each appex's `ConduckWebCapture.js` (JS can't read Swift at all).
    /// `WebPageCaptureTests` pins them all equal — change ALL of them
    /// together. 128 KB ≈ a very long article's text; anything bigger
    /// truncates at capture time with an honest note in the synthetic
    /// Markdown. FOUNDER-TUNABLE.
    static let webPageCaptureMaxBytes = 128 * 1024

    /// Max on-disk size (bytes) for the composer's text-vs-binary PROBE
    /// (`TextFileExtractor.extract`, a WHOLE-FILE read into memory) to run at all.
    /// Above this a picked/dropped file routes straight to the BINARY branch
    /// (server upload / `.needsSetup`) without ever transiting memory — a 2 GB
    /// video must never be `Data(contentsOf:)`-read just to fail a UTF-8 decode.
    /// Anything text-like above this couldn't usefully ride inline anyway
    /// (`textInlineMaxBytes` is 32 KB — a >10 MB "text" file is server-route
    /// material by definition). FOUNDER-TUNABLE.
    static let textProbeMaxBytes = 10 * 1024 * 1024

    /// Soft inter-turn quiet period (seconds) before allowing another
    /// DEVICE to issue a turn on the same active session
    /// (`docs/ai-context/spec.md`). Hint only — not a hard lock.
    static let interTurnQuietPeriod: TimeInterval = 0.5

    /// Debounce (seconds) before the Tier-2 whole-history content search fires
    /// in the conversation list (iPhone / iPad / Mac / Watch). Title + first-user
    /// snippet match INSTANTLY (in-memory); only the content predicate fetch
    /// lags by this window so a fast typist doesn't spawn a scan per keystroke.
    /// FOUNDER-TUNABLE; uniform across surfaces.
    static let contentSearchDebounce: TimeInterval = 0.3

    /// Key for the user-selected `RemoteAgentBackend` (raw value:
    /// `"openclaw"` / `"hermes"`). iOS App Groups UserDefaults **and** iCloud
    /// KVS (backend is App Groups + KVS so the Watch resolves it on a
    /// cold ControlWidget launch with no live envelope). Same string in both
    /// stores — the namespaces don't collide.
    static let remoteAgentBackendKey = "remoteAgent.backend"

    /// Key for the gateway URL the user pasted in Settings (https only; ATS
    /// posture). iOS App Groups UserDefaults **and** iCloud KVS
    /// — same cold-launch rationale as `remoteAgentBackendKey`.
    static let remoteAgentURLKey = "remoteAgent.url"

    /// Keychain account slot for the gateway bearer token. Token is
    /// secure-entry in Settings, written to Keychain on save, never
    /// re-displayed plaintext.
    ///
    /// LEGACY single-slot literal — RETAINED so the multi-gateway migration
    /// (`SettingsManager.migrateRemoteAgentToPerBackend()`) can read the
    /// pre-multi-gateway token. New code uses the per-backend
    /// `remoteAgentTokenKeychainAccount(for:)` below.
    static let remoteAgentTokenKeychainAccount = "remoteAgent.token"

    // MARK: - Remote Agent — Per-Backend (multi-gateway) Keys
    //
    // Multi-gateway storage: each configured backend (OpenClaw / Hermes) owns
    // its OWN token / URL / cert slot, keyed by the backend's raw value, so
    // both can be configured simultaneously. Mirrors the STT per-preset
    // layout (`sttApiKeyKeychainAccount(for:)`).
    //
    // ⚠️ `RemoteAgentBackend` raw values ("openclaw" / "hermes") are now LOCKED
    // into these key suffixes — renaming a raw value orphans every install's
    // per-backend config (exactly the STT preset-ID lock posture). Treat as
    // permanent.

    /// Keychain account slot for a SPECIFIC backend's bearer token. Format
    /// `remoteAgent.token.<rawValue>` (e.g. `remoteAgent.token.openclaw`).
    /// Distinct from the legacy single-slot `remoteAgentTokenKeychainAccount`,
    /// which the migration copies FROM.
    static func remoteAgentTokenKeychainAccount(for backend: RemoteAgentBackend) -> String {
        "remoteAgent.token." + backend.rawValue
    }

    /// Per-REF token account (built-in OR custom). `ref.storageKeySuffix` ==
    /// the backend raw value for built-ins, so this is byte-identical to the
    /// `for backend:` overload for OpenClaw/Hermes (back-compat); customs get
    /// `remoteAgent.token.custom_<uuid>`.
    static func remoteAgentTokenKeychainAccount(for ref: RemoteAgentRef) -> String {
        "remoteAgent.token." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC backend's
    /// gateway URL. Format `remoteAgent.url.<rawValue>`. Same cold-launch
    /// rationale as the legacy `remoteAgentURLKey` (Watch resolves it on a cold
    /// ControlWidget launch with no live envelope).
    static func remoteAgentURLKey(for backend: RemoteAgentBackend) -> String {
        "remoteAgent.url." + backend.rawValue
    }

    /// Per-REF URL key (built-in OR custom). Built-in suffix == raw value
    /// (back-compat); customs get `remoteAgent.url.custom_<uuid>`.
    static func remoteAgentURLKey(for ref: RemoteAgentRef) -> String {
        "remoteAgent.url." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults key (NO KVS — per-device pin, mirrors the legacy
    /// `remoteAgentCertFingerprintKey` posture) for a SPECIFIC backend's pinned
    /// SHA-256 cert fingerprint. Format `remoteAgent.certFingerprint.<rawValue>`.
    static func remoteAgentCertFingerprintKey(for backend: RemoteAgentBackend) -> String {
        "remoteAgent.certFingerprint." + backend.rawValue
    }

    /// Per-REF cert-fingerprint key (built-in OR custom). Built-in suffix ==
    /// raw value (back-compat); customs get `remoteAgent.certFingerprint.custom_<uuid>`.
    static func remoteAgentCertFingerprintKey(for ref: RemoteAgentRef) -> String {
        "remoteAgent.certFingerprint." + ref.storageKeySuffix
    }

    /// Per-REF auth-scheme key (built-in OR custom) — stored raw `"bearer"` /
    /// `"none"`. Dual-written (App Groups UserDefaults + iCloud KVS, mirroring
    /// `remoteAgentURLKey`) so the Watch resolves a gateway's keyless posture on
    /// a cold ControlWidget launch with no live envelope. A missing / undecodable
    /// value resolves to `.bearer` via `RemoteAgentAuthScheme.from(rawValue:)`
    /// (fail closed — keyless is never inferred from absence).
    static func remoteAgentAuthSchemeKey(for ref: RemoteAgentRef) -> String {
        "remoteAgent.authScheme." + ref.storageKeySuffix
    }

    /// Per-REF `model` slot — App Groups UserDefaults + iCloud KVS dual-write,
    /// mirroring `remoteAgentURLKey(for:)` (so the Watch resolves a hosted
    /// backend's model on a cold ControlWidget launch with no live envelope).
    /// Only hosted-model built-ins (OpenRouter, `model == .required`) persist
    /// here; OpenClaw/Hermes never write it (`model == .unsupported`), and
    /// custom gateways keep their model on the `CustomGateway` roster entry.
    static func remoteAgentModelKey(for ref: RemoteAgentRef) -> String {
        remoteAgentModelKeyPrefix + ref.storageKeySuffix
    }

    /// Shared prefix for `remoteAgentModelKey(for:)`. The inbound
    /// `handleICloudChange` mirror prefix-scans on this (suffixes are dynamic —
    /// custom gateways carry a uuid), so the two cannot drift.
    static let remoteAgentModelKeyPrefix = "remoteAgent.model."

    /// Per-BACKEND auth-scheme key overload (built-in suffix == raw value),
    /// mirroring `remoteAgentURLKey(for backend:)` for the Watch cold-launch
    /// loops that enumerate `RemoteAgentBackend.allCases`.
    static func remoteAgentAuthSchemeKey(for backend: RemoteAgentBackend) -> String {
        "remoteAgent.authScheme." + backend.rawValue
    }

    /// Per-REF transport HINT key — how the gateway is exposed (raw
    /// `PairingPayload.Transport` value, e.g. `"tailscale"`), imported from a
    /// pairing payload. Format `remoteAgent.transportHint.<suffix>`.
    /// App-Group UserDefaults ONLY — NEVER iCloud KVS and NEVER the Watch
    /// broadcast envelope (per `docs/ai-context/spec.md`):
    /// the hint drives per-device setup guidance (e.g. "install Tailscale on
    /// this device to reach your tailnet gateway"), and another device may
    /// reach the same gateway over a different transport — syncing it would
    /// surface wrong guidance there.
    static func remoteAgentTransportHintKey(for ref: RemoteAgentRef) -> String {
        "remoteAgent.transportHint." + ref.storageKeySuffix
    }

    /// Per-ref record of the last SUCCESSFUL chat round-trip from THIS device
    /// (`GatewayChatSuccess`, JSON). Format
    /// `remoteAgent.lastChatSuccess.<suffix>`.
    ///
    /// App-Group UserDefaults ONLY — never iCloud KVS, never the Watch broadcast
    /// envelope, for a stronger reason than the transport hint's: the record's
    /// entire meaning is "a turn completed FROM HERE". Syncing it would let a
    /// success on the iPhone silence the wrist's or the Mac's real problem, and
    /// would assert a route (cellular, tailnet-from-Watch) that was never proven.
    static func remoteAgentLastChatSuccessKey(for ref: RemoteAgentRef) -> String {
        "remoteAgent.lastChatSuccess." + ref.storageKeySuffix
    }

    /// Tailscale's App Store product page — deep-linked by the pairing-import
    /// guidance when the imported transport hint is `tailscale` and the user
    /// still needs the Tailscale client on THIS device to reach their
    /// tailnet-exposed gateway.
    static let tailscaleAppStoreURL = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    /// Public, auditable home of the `conduck-connect` server-side pairing
    /// wizard. The onboarding gateway step links here so a user who doesn't yet
    /// have a setup code can obtain + read the script (download over HTTPS →
    /// read/skim → `bash`). See `docs/ai-context/spec.md`.
    static let conduckConnectRepoURL = URL(string: "https://github.com/gigaduckai/conduck-connect")!

    /// Stable GitHub "latest release" base. Every asset path below redirects to
    /// the newest PUBLISHED (non-prerelease) release — nothing here pins a
    /// version. The app names only "latest"; the script's version lives INSIDE
    /// the file, never in the app or the asset filename, so this string is
    /// permanent and the script can re-version forever without an app update.
    /// NOTE: GitHub resolves `/releases/latest` only once a non-prerelease
    /// release exists (pre-releases are excluded). See
    /// `docs/ai-context/spec.md`.
    private static let conduckConnectLatestBase =
        "https://github.com/gigaduckai/conduck-connect/releases/latest"

    /// Releases page opened by the onboarding "read it on GitHub" link — where
    /// the auditable source + release assets live.
    static let conduckConnectReleasesURL = URL(string: conduckConnectLatestBase)!

    /// The download half of every one-paste `conduck-connect` command — `curl -O`
    /// of the LATEST release asset onto disk. Factored out because a REMEDY screen
    /// (a failing hand-configured custom gateway) hands the user a non-`--setup`
    /// action, and that user has typically never downloaded the script: naming the
    /// action alone would print an uncopyable instruction. Verbatim shell text,
    /// NEVER localized.
    static let conduckConnectDownloadCommand =
        "curl -fsSLO \(conduckConnectLatestBase)/download/conduck-connect.sh"

    /// Short, single-line gateway setup command — the DEFAULT form everywhere
    /// the user is handed a command to run (onboarding, the per-gateway editor
    /// guided setup, and the guided-lane wizard). Downloads the
    /// LATEST script to disk and runs it in one paste. Still NOT a pipe-to-shell
    /// (`-O` lands the full file on disk before `bash` runs, so a truncated
    /// download can't execute and the script remains on disk to read) — it trades
    /// the inline same-channel checksum (which only ever caught corruption, not
    /// tampering: the `.sha256` arrived down the same HTTPS pipe as the script)
    /// for HTTPS-from-GitHub trust, the mainstream installer bar.
    ///
    /// `--setup` skips the top-level action menu, then reports any detected
    /// OpenClaw/Hermes installs and asks the user which gateway to configure.
    /// The app never makes that choice on the user's behalf. Verbatim shell
    /// text, NEVER localized.
    static let conduckConnectSetupCommandShort =
        "\(conduckConnectDownloadCommand) && bash conduck-connect.sh --setup"

    // MARK: - Custom Gateways (user-defined, multi-gateway)

    /// Cap on user-defined custom OpenAI-compatible gateways (bump here). UI/UX
    /// limit, not a storage limit — the "+ Add custom gateway" affordance
    /// disables at this count. Enforced ONLY on ADD (`upsertCustomGateway`);
    /// readers never truncate, so a roster synced from a higher-cap build stays
    /// intact and editable. Each gateway replicates to the Watch (roster entry +
    /// a token-bearing sub-envelope over `WCSession.transferUserInfo` + a Watch
    /// Keychain slot), so a gateway costs more than a voice endpoint.
    /// Raising past `RemoteAgentBadgePalette.customPalette.count` (8) forfeits
    /// the distinct auto-assigned badge colour.
    static let maxCustomGateways = 5

    /// App Groups UserDefaults **and** iCloud KVS key holding the JSON-encoded
    /// `[CustomGateway]` roster (id / name / model / badge color + monogram).
    /// Dual-written, mirroring `remoteAgentDefaultBackendKVSKey`. The per-custom
    /// URL / token / cert live in the SAME per-ref slots as built-ins (keyed by
    /// `RemoteAgentRef.storageKeySuffix`), NOT in this JSON. The Watch reuses
    /// this same key in its OWN App Group to persist the roster it receives via
    /// the multi-broadcast envelope (cold-launch durability + the known-customs
    /// index for clearing dropped per-ref slots).
    static let customGatewaysRegistryKey = "remoteAgent.customGateways"

    /// App Groups UserDefaults key holding the JSON-encoded
    /// `[RetiredGatewayBadge]` — the monogram + colour of custom gateways the
    /// user has forgotten, so their conversations keep the tag that told them
    /// apart. The Watch reuses this key in its OWN App Group.
    ///
    /// **App Group ONLY — deliberately never iCloud KVS**, unlike
    /// `customGatewaysRegistryKey` beside it. A monogram can carry organization
    /// or personal identity and `retiredAt` carries timing, so syncing would
    /// republish them into the next iCloud account the device signs into, and a
    /// restored backup would resurrect records the user believed erased. Peers
    /// stay consistent by DERIVING the same tombstone from a synced event they
    /// already receive — a custom vanishing from the roster — rather than by
    /// replicating the tombstone itself.
    static let retiredGatewayBadgesKey = "remoteAgent.retiredGatewayBadges"

    /// How many forgotten-gateway badges to keep. Deliberately NOT
    /// `maxCustomGateways`, which caps SIMULTANEOUSLY ACTIVE gateways: this is
    /// lifetime history, so reusing that value would silently start dropping
    /// badges on the sixth gateway a user ever forgets. Generous because each
    /// record is a uuid, two characters and a date, and the oldest is dropped
    /// first — so a conversation older than the last `maxRetiredGatewayBadges`
    /// forgotten gateways can still lose its badge.
    static let maxRetiredGatewayBadges = 32

    /// UserDefaults key for the DEFAULT backend pointer — which gateway a
    /// freshly-minted conversation binds to, and the sole router for the
    /// picker-less surfaces (Watch headless / CarPlay / Action Button).
    /// **DEVICE-LOCAL (App Groups only) — NOT iCloud-KVS-synced.** Each device
    /// (iPhone / iPad / Mac) owns its own default so it can route to whatever
    /// gateway makes sense there (gateway *configs* still sync; only the
    /// *choice* of default is per-device). The old KVS value (when this key
    /// was dual-stored) is read EXACTLY ONCE as a legacy migration seed by
    /// `migrateDefaultBackendToDeviceLocal()`, then never again. The key name
    /// is kept (per-ref storage-suffix lineage); only its sync semantics changed.
    static let remoteAgentDefaultBackendKVSKey = "remoteAgent.defaultBackend"

    /// **WATCH-SIDE App Groups key** recording whether the couriered
    /// `remoteAgent.defaultBackend` names a gateway the user actually CHOSE, or
    /// merely the compatibility fallback the iPhone projects when no pointer is
    /// stored. Written by `WatchSettingsReader` from the broadcast envelope's
    /// `defaultBackendChosen` slot; ABSENT reads as CHOSEN, which is both the
    /// ordinary answer and the behaviour of every build that predates the flag.
    ///
    /// Persisted rather than kept in memory because the reader that needs it most
    /// runs on a cold-launched headless capture, before any envelope arrives.
    static let remoteAgentDefaultBackendChosenKey = "remoteAgent.defaultBackendChosen"

    /// App Groups flag set once the synced → device-local migration of the
    /// default-backend pointer (`SettingsManager.migrateDefaultBackendToDeviceLocal()`)
    /// reaches a CONCLUSIVE outcome. Local-wins: a valid App-Group value is
    /// kept; else the legacy iCloud-KVS fossil is copied down once as a seed,
    /// but only when the gateway it names can actually send. An inconclusive
    /// read writes nothing and leaves this flag UNSET, so the seed is retried
    /// once iCloud has delivered more. NEVER clears the active pointer; NEVER
    /// gates on `kvsSchemaVersion`.
    static let remoteAgentDefaultBackendDeviceLocalMigratedKey = "remoteAgentDefaultBackendDeviceLocalMigrated"

    /// App-Group key holding the JSON-encoded `DefaultGatewayAdoptionNotice` —
    /// the record that THIS device repaired its own "Default for new chats".
    ///
    /// **App Group ONLY, never iCloud KVS**, for the same reason
    /// `remoteAgentDefaultBackendKVSKey` is device-local: the repair happened
    /// here, and syncing it would have an iPad announce itself on a Mac that
    /// never had the problem.
    ///
    /// Written by the adopt arms and by the Forget re-point; cleared by
    /// `acknowledgeDefaultAdoptionNotice()` and by `applyUserChosenDefault` (a
    /// user who has just picked a default does not need to be told the app
    /// picked one). A second adoption overwrites an unread first — the newest
    /// repair is the truth.
    static let remoteAgentAdoptedDefaultNoticeKey = "remoteAgent.adoptedDefaultNotice"

    /// App-Group key holding the `RemoteAgentRef.rawString` that the APP parked
    /// in the default pointer on the user's behalf — the Forget re-point's
    /// several-survivors arm, which parks on a built-in so the user CHOOSES
    /// their next gateway instead of inheriting one.
    ///
    /// It exists because the pointer alone cannot say who put it there, and a
    /// gateway the app parked must never be described to the user as "your
    /// default AI" — the user did not pick it and may never have set it up.
    /// A surface reads it through `NewChatPickerSnapshot.defaultPointerIsParked`
    /// and drops the name from its sentence.
    ///
    /// SELF-CORRECTING BY VALUE, not by lifecycle: it is compared against the
    /// stored pointer, so any later re-point — an adoption, a bootstrap, a
    /// different park — leaves a value that no longer matches and reads as "not
    /// parked". ABSENT reads as the user's own choice, which is both the
    /// ordinary answer and the behaviour of every build that predates the key.
    /// `applyUserChosenDefault` clears it outright, for the case where the user
    /// picks the very gateway that was parked.
    ///
    /// AND IT CLEARS WHEN THE PARKED GATEWAY BECOMES SENDABLE. Every surface
    /// that speaks about a parked pointer tells the user it is not set up here;
    /// a user who takes that advice and finishes setting it up writes no
    /// pointer, so a marker that only a re-point could retire would outlive the
    /// problem it describes forever. Membership of the configured set is the
    /// exit, read where the marker is read (`isDefaultPointerParked`), so a
    /// Keychain that becomes readable and an iCloud token that finishes syncing
    /// retire it just as a Settings edit does. An unreadable Keychain reports no
    /// membership and therefore KEEPS the marker (I3): holding a placeholder is
    /// the non-destructive answer under an ambiguous reading.
    ///
    /// **App Group ONLY, never iCloud KVS** — it describes this device's
    /// pointer, which is itself device-local.
    static let remoteAgentParkedDefaultRefKey = "remoteAgent.parkedDefaultRef"

    /// App Groups UserDefaults key for the optional **Apple Watch default
    /// override** — the gateway the WATCH's headless wrist captures default to.
    /// Stores a `RemoteAgentRef.rawString`; ABSENT = "Follow iPhone" (the
    /// Watch uses the iPhone's device-local default). **App-Group ONLY on the
    /// iPhone — NEVER iCloud KVS** (it must not leak to iPad/Mac, which own
    /// their own defaults). iPhone-written (the Watch keeps no settings UI);
    /// couriered to the wrist as the Watch-effective default in the multi-
    /// gateway broadcast envelope's `defaultBackendRef` slot.
    static let remoteAgentWatchDefaultBackendKey = "remoteAgent.watchDefaultBackend"

    /// App Groups UserDefaults key for the **last-used gateway** — the gateway
    /// the most recent conversation on THIS device was actually started on.
    /// Stores a `RemoteAgentRef.rawString`; ABSENT = "no chat started here yet",
    /// which is a legitimate answer and falls back to the device-local default.
    ///
    /// **App-Group ONLY — NEVER iCloud KVS.** A gateway picked on one device must
    /// not re-aim another device's picker; this mirrors the default pointer's
    /// device-local posture (`remoteAgentDefaultBackendKVSKey`).
    ///
    /// **It is a picker HINT, never a routing authority.** Only the two new-chat
    /// picker seeds consume it as a pre-selection
    /// (`ContentView.refreshGatewayRoster` / `MainWindowView.refreshConfiguredBackends`),
    /// and both validate it against the configured roster before showing it. A
    /// send always routes on the conversation's own sealed `backend`, never on
    /// this. Two more sites read the RAW slot without pre-selecting from it — the
    /// inbound-KVS handler (to spot a peer's Forget of a built-in) and
    /// `clearLastUsedRemoteAgentRefIfPointing`.
    ///
    /// Deliberately a SINGLETON key, not a `…(for:)` per-ref helper: the per-ref
    /// families are enumerated by `gatewayOwnedKeyPrefixes` /
    /// `gatewayUserStateKeyPrefixes`, and a global slot must never match those
    /// per-uuid purge scans.
    static let remoteAgentLastUsedBackendKey = "remoteAgent.lastUsedBackend"

    /// Default backend for fresh installs / when no default pointer is stored.
    /// `.openclaw` is the reference gateway (mirrors `sttActivePresetIDDefault`).
    static let remoteAgentDefaultBackendDefault: RemoteAgentBackend = .openclaw

    /// App Groups flag recording that the user EXPLICITLY forgot their last
    /// gateway on THIS device — the sole authority for broadcasting a Watch
    /// teardown envelope (`RemoteAgentMultiBroadcastEnvelope.clearAll`).
    ///
    /// It exists because "no gateway is configured" is NOT evidence of deletion.
    /// `configuredRemoteAgentRefs()` fails closed on an unreadable token, a
    /// restored / reinstalled device reads empty until iCloud KVS finishes its
    /// first download, and `PhoneSessionManager.activate()` broadcasts without
    /// awaiting `performInitialSync`. Inferring teardown from an empty read
    /// would therefore destroy the credentials of a Watch that is working fine.
    /// Only a user action sets this.
    ///
    /// **App-Group ONLY — never iCloud KVS.** It describes an action taken on
    /// the phone that couriers this Watch, not a synced fact; mirroring it would
    /// let a peer device's Forget tear down a pairing this phone still serves.
    /// Consequence: a Forget performed on iPad/Mac does not reach the wrist
    /// (the paired iPhone is the only courier, and it never saw the intent).
    ///
    /// Set in `SettingsViewModel.clearRemoteAgent(for:)` once the wipe leaves no
    /// stored evidence behind; cleared by `currentRemoteAgentMultiEnvelope()`
    /// the moment it can build a non-empty envelope again — the one composition
    /// site that always knows the phone has gateways to courier.
    static let remoteAgentUserClearedAllKey = "remoteAgent.userClearedAll"

    /// App Groups flag set once after the one-time single-slot → per-backend
    /// remote-agent migration completes
    /// (`SettingsManager.migrateRemoteAgentToPerBackend()`). Gates the migration
    /// so the copy of the legacy URL/token/cert into the per-backend slots runs
    /// exactly once per device. Distinct from `keychainSyncMigratedKey` (the
    /// earlier non-sync → synchronizable Keychain migration, which MUST run
    /// first so the legacy token is synchronizable before this copy).
    static let remoteAgentMultiGatewayMigratedKey = "remoteAgentMultiGatewayMigrated"

    /// Key for the optional pinned cert fingerprint (SHA-256 hex of the
    /// gateway leaf-cert public-key DER). iOS keeps it in App Groups
    /// (per-device, NOT KVS). The Watch persists its OWN copy in the
    /// Watch App Group UserDefaults under this same key when the broadcast
    /// envelope arrives, so a cold ControlWidget launch can pin correctly.
    /// Consumed by `RemoteAgentTrustEvaluator`.
    static let remoteAgentCertFingerprintKey = "remoteAgent.certFingerprint"

    /// UserDefaults key for the currently-active conversation session ID
    /// (`docs/ai-context/spec.md`). Cleared on backend / URL change
    /// or TTL expiry.
    static let remoteAgentActiveSessionKey = "remoteAgent.activeSession"

    /// UserDefaults key for the active-conversation pointer's `Conversation.id`
    /// (UUID string). Pairs with `remoteAgentActiveSessionKey` (the local
    /// `sessionID`) — the pointer selects which `Conversation` HEADLESS
    /// captures append to. **Never sent on the wire**. Distinct from
    /// the `sessionID` because the in-app thread tracks its visible
    /// conversation directly; this pointer is the headless-capture fallback.
    static let remoteAgentActiveConversationIDKey = "remoteAgent.activeConversationID"

    /// UserDefaults key for the active-conversation pointer's last-activity
    /// timestamp (`timeIntervalSinceReferenceDate`, Double). Drives the
    /// session-continuation-policy window in `resolveActiveConversationID(now:)` —
    /// past the window the pointer is stale and the caller mints a fresh
    /// conversation. Local/KVS-cache only; never crosses the wire.
    static let remoteAgentActiveConversationActivityKey = "remoteAgent.activeConversationActivity"

    /// Watch App Group UserDefaults key for the one-shot "pending in-app
    /// new-conversation backend" hint. Set by the in-app "Ask" button (raw
    /// `RemoteAgentBackend` value) BEFORE `startRecording()`; consumed (read +
    /// removed) by `resolveActiveConversationAndBackend()` to mint a NEW
    /// conversation bound to the chosen gateway. **App Group ONLY, never iCloud
    /// KVS** — a transient, device-local intent that must NOT sync to other
    /// devices (a stale cross-device hint would silently reroute an unrelated
    /// headless turn). Cleared on every reset-to-idle path so a cancelled in-app
    /// Ask can't leave a hint a later headless trigger consumes.
    static let remoteAgentPendingInAppNewConversationBackendKey = "remoteAgent.pendingInAppNewConversationBackend"

    /// WCSession `transferUserInfo` dict key carrying the atomic Personal-AI
    /// gateway envelope (backend + URL + token + fingerprint + activeSessionID
    /// + monotonic timestamp). Mirrors `sttActivePresetEnvelopeKey` posture
    /// — single envelope is the SOLE source of Watch gateway state to defeat
    /// torn reads against `applicationContext`. See
    /// `RemoteAgentBroadcastEnvelope`.
    static let remoteAgentEnvelopeKey = "remoteAgent.activeEnvelope"

    /// WCSession `transferUserInfo` dict key carrying the MULTI-gateway
    /// envelope (`RemoteAgentMultiBroadcastEnvelope`): every configured backend's
    /// per-backend sub-envelope + the default-backend pointer + a monotonic
    /// timestamp. Full Watch multi-gateway support — the Watch
    /// routes each conversation to ITS bound backend, so it needs ALL gateways,
    /// not just the iPhone's default. Broadcast ALONGSIDE the legacy single
    /// `remoteAgentEnvelopeKey` (one release of compat fallback for an
    /// un-upgraded Watch). See `RemoteAgentMultiBroadcastEnvelope`.
    static let remoteAgentMultiEnvelopeKey = "remoteAgent.activeMultiEnvelope"

    /// App Groups UserDefaults key for the user-selected `SessionContinuationPolicy`
    /// (raw value: `"alwaysNew"` / `"minutes15"` / `"minutes30"` / `"minutes60"`
    /// / `"alwaysContinue"`). **PER-DEVICE** — App-Group-local, NOT iCloud KVS:
    /// each device (iPhone / iPad / Mac) owns its own value. The Watch follows
    /// the iPhone via the multi-gateway broadcast envelope's `sessionPolicy` slot
    /// (`watchEffectiveSessionContinuationPolicy`) and caches it under this same
    /// literal in its OWN App Group (the Watch read prefers App-Group, with a
    /// one-time legacy KVS seed for the first cold launch post-update). Default
    /// `.minutes30` applies when unset (`SettingsManager.getSessionContinuationPolicy`).
    static let sessionContinuationPolicyKey = "remoteAgent.sessionPolicy"

    /// App Groups UserDefaults key (iPhone-written) for the Apple Watch
    /// `SessionContinuationPolicy` OVERRIDE, or ABSENT = "Follow iPhone". **App
    /// Groups ONLY — NEVER iCloud KVS** (must not leak to iPad/Mac, which own
    /// their own per-device policy). The Watch keeps no settings UI — this is set
    /// from the iPhone (Apple Watch settings sub-screen).
    /// `watchEffectiveSessionContinuationPolicy()` = override (if set) else the
    /// iPhone's device-local policy; it rides the multi-gateway broadcast
    /// envelope's `sessionPolicy` slot. Mirrors `remoteAgentWatchDefaultBackendKey`.
    static let watchSessionContinuationPolicyOverrideKey = "watch.sessionContinuationPolicyOverride"

    /// App Groups UserDefaults **and** iCloud KVS key for the user-selected
    /// `OnLaunchMode` (raw value: `"startNewConversation"` / `"resumeLastConversation"`).
    /// Governs cold-launch landing UX only — independent of
    /// `sessionContinuationPolicyKey` (which governs headless send-routing).
    /// Dual-stored under the same literal in both stores so the choice rides
    /// iCloud across the user's devices. Default `.startNewConversation`
    /// applies when unset (`SettingsManager.getOnLaunchMode`).
    static let onLaunchModeKey = "remoteAgent.onLaunchMode"

    /// HTTP path used by "Test Connection" in the Settings Personal AI
    /// section. `GET /v1/models` is the OpenAI-compatible probe both
    /// OpenClaw and Hermes expose; 200 = auth + connectivity OK, 401 =
    /// bad token, 5xx = gateway sick, transport errors map to
    /// `.remoteAgentUnreachable` / `.remoteAgentCertMismatch`.
    static let remoteAgentModelsProbePath = "/v1/models"

    /// HTTP path that VALIDATES an OpenRouter API key during "Test Connection".
    /// OpenRouter's `/v1/models` is PUBLIC (returns 200 for any/no key), so it
    /// cannot prove the key — `GET /v1/key` requires a valid key (401 on a bad
    /// one, 200 on a good one) and is the hosted-model backend's auth verdict.
    /// Model-suggestion discovery still uses `remoteAgentModelsProbePath`.
    static let openRouterKeyProbePath = "/v1/key"

    /// OpenRouter VOICE endpoints. Both ride the SAME `openRouterBaseURLString`
    /// (`…/api`) + `/v1/…` suffix the gateway uses, so the voice provider and the
    /// hosted-model gateway share one base + one Bearer key. STT is JSON+base64
    /// (`input_audio.data`, NOT multipart) — see `OpenRouterSTT`; TTS is
    /// OpenAI-compatible (`OpenAISpeechBody`, raw mp3 when `response_format:"mp3"`).
    static let openRouterTranscriptionsPath = "/v1/audio/transcriptions"
    static let openRouterSpeechPath = "/v1/audio/speech"

    /// Per-request timeout for the "Test Connection" probe
    /// (`timeoutIntervalForRequest`). 15 s is short on purpose — this is
    /// interactive UI with a spinner; the user is waiting. The 300 s
    /// `remoteAgentConverseRequestTimeout` is for the converse hop only,
    /// where the LLM may take real time to compute the reply.
    static let remoteAgentTestConnectionTimeout: TimeInterval = 15

    // MARK: - Agent File Transfer (user-run file-server)
    //
    // Network-layer + storage-key constants for the OWN-INFRA file-server
    // round-trip (a user-run WebDAV server over HTTPS — typically stood up by
    // `conduck-connect`). The device PUTs file bytes to the server root as
    // `<storedKey>` then splices a plain-text "the file is in your working
    // directory" line into the chat turn; the agent's tools act on the real
    // bytes. GigaDuck ships NO server binary — standing up the server is the
    // user's job. Storage keys mirror the per-ref `remoteAgent*` layout so a
    // file-server can be bound independently to each gateway (built-in OR
    // custom), keyed by `RemoteAgentRef.storageKeySuffix`.
    //
    // Privacy (load-bearing — see docs/ai-context/spec.md): the file-server credential is
    // client-minted, stored in Keychain (synchronizable), revealed ONLY in the
    // setup guide's masked credential row the user deliberately copies. Never
    // logged. The cert fingerprint is per-device (App Groups only, NEVER iCloud
    // KVS — same posture as `remoteAgentCertFingerprintKey`).

    /// Background `URLSession` identifier for file uploads / downloads. Distinct
    /// from every `remoteAgent*` and `.stt` id so the file-transfer delivery
    /// channel never cross-talks with converse / STT. Consumed by
    /// `BackgroundFileTransfer` and the matching `ConduckApp`
    /// `.backgroundTask(.urlSession(...))` handler — change in lockstep or the
    /// system-relaunch event won't route back to the file-transfer delegate.
    nonisolated static let fileTransferSessionIdentifier = identityNamespace + ".filetransfer"

    /// Per-request timeout for a file upload / download
    /// (`timeoutIntervalForRequest`). 600 s — generously longer than the
    /// converse 300 s because a single PUT/GET can move multi-MB bytes over a
    /// home-server tunnel; lowering this kills large transfers mid-flight.
    static let fileTransferRequestTimeout: TimeInterval = 600

    /// Resource-lifetime timeout for a file transfer
    /// (`timeoutIntervalForResource`). 3600 s — longer than the converse 600 s
    /// so a large background upload survives app suspension across a long
    /// transfer without the system tearing the session down.
    static let fileTransferResourceTimeout: TimeInterval = 3600

    /// Per-request timeout (seconds) for the ephemeral output-file existence
    /// probe + each stage of the staged Test Connection. 15 s mirrors
    /// `remoteAgentTestConnectionTimeout` — these are interactive / lightweight
    /// HEAD-free GET probes where the user is waiting, NOT a bulk transfer.
    static let fileServerProbeTimeout: TimeInterval = 15

    /// Per-request AND resource timeout (seconds) for the PRE-DISPATCH absence
    /// witness — the one file-server request that runs BEFORE a turn goes out.
    ///
    /// Its own, much shorter deadline because it is the only probe in this lane
    /// that a user pays for without having asked for anything: every dispatch on
    /// a configured lane awaits it, including a pure-text turn that was never
    /// going to involve a file. On `fileServerProbeTimeout` a file server that is
    /// simply not answering right now — a NAS behind a VPN that is down — would
    /// stall EVERY send by that full budget before the request even reaches the
    /// gateway.
    ///
    /// 4 s is sized for what the request actually is: one liveness round-trip to
    /// a host the user's own device usually reaches over a tunnel or a tailnet
    /// (sub-second when healthy, low seconds through a cold Cloudflare Tunnel),
    /// not a download. Failing it is FAIL-CLOSED AND CHEAP — no location line
    /// goes on the wire, no automatic delivery happens for that turn, and the
    /// manual "search mentioned files" affordance still reaches the files — so
    /// the cost of cutting a slow server off is one turn's automatic delivery,
    /// while the cost of waiting is every turn's latency.
    static let fileServerAbsenceWitnessTimeout: TimeInterval = 4

    /// How many LEADING body bytes an existence probe reads before it cancels
    /// the underlying task and decides. 1 KiB, because the decision the prefix
    /// feeds is made at the DOCUMENT START — a login page's doctype/root element
    /// sits inside the first few hundred bytes even behind a BOM, a comment
    /// banner, and an XML declaration — and because the cap is what stops a BYO
    /// server that ignores `Range: bytes=0-0` from streaming a multi-GB file into
    /// memory on a probe the user never asked for. Larger buys nothing the
    /// verdict can use; smaller starts losing real login pages behind a long
    /// preamble.
    static let fileServerProbeBodySniffBytes = 1024

    /// Soft-confirm threshold (bytes, ~100 MB). Above this the composer shows a
    /// "this is a large file" confirmation before staging the upload. There is
    /// NO hard cap (the user owns the server) — this is purely a courtesy guard
    /// against an accidental giant attachment.
    static let fileTransferSoftConfirmBytes = 100 * 1024 * 1024

    /// Byte ceiling on the encoded list of output-folder entries a reply
    /// remembers refusing (`OutputDeliveryOutcome.encodedNames`). Over this, the
    /// list is shortened from the tail until it fits; the COUNT beside it is
    /// untouched, so the row still reports the full census and only loses part of
    /// the offer.
    ///
    /// It bounds ADVERSARY-CHOSEN TEXT, which is why it exists at all: the names
    /// come from whatever wrote into the user's folder, the blob rides on the
    /// message record into the user's own iCloud database, and it replicates to
    /// every device they own.
    ///
    /// It is a SECOND, INDEPENDENT bound and it does not fire today — the name
    /// gate already caps each component at `storedKeyComponentMaxBytes`, so the
    /// retained dozen encode to under 3 KiB even at that ceiling. It is here so
    /// that raising `OutputDeliveryOutcome.maxRetainedRefusedNames`, or admitting
    /// a longer component, cannot quietly grow a synced field: the two caps
    /// answer different questions ("how many will we offer" and "how much will we
    /// store"), and only this one is about the record.
    ///
    /// `nonisolated` because the encoder that reads it runs inside a Core Data
    /// background context's `perform` block, off the main actor.
    nonisolated static let outputRefusedNamesMaxBytes = 4 * 1024

    /// How long the macOS pane-drop target waits for ONE dragged item to
    /// resolve before failing that item and letting the rest of the batch
    /// through (seconds). FOUNDER-TUNABLE. Generous because the source may be a
    /// slow promise (a web-page image) or a file on a network / not-yet-
    /// downloaded iCloud volume, but bounded: an item that never calls back
    /// would otherwise hold Send disabled indefinitely.
    static let dropProviderLoadTimeoutSeconds = 60

    /// Fixed basic-auth username sent on every file-server request and named in
    /// the setup guide ("Conduck signs in as conduck"). The PASSWORD is the
    /// client-minted secret (Keychain) — the username is non-secret and constant
    /// so the server config + the client agree without a second stored field.
    /// Also embedded by `conduck-connect`'s file lane — change in lockstep.
    static let fileServerUsername = "conduck"

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC ref's
    /// file-server BASE URL (https only). Format `fileServer.url.<suffix>`. Same
    /// cold-launch + reinstall-survival rationale as `remoteAgentURLKey(for:)`
    /// (dual-stored so it rides iCloud across the user's devices). Built-in
    /// suffix == raw value (back-compat); customs get
    /// `fileServer.url.custom_<uuid>`.
    static func fileServerURLKey(for ref: RemoteAgentRef) -> String {
        "fileServer.url." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults key (NO KVS — per-device pin, mirrors
    /// `remoteAgentCertFingerprintKey(for:)`) for a SPECIFIC ref's pinned
    /// SHA-256 file-server leaf-cert fingerprint, lowercased hex. Format
    /// `fileServer.certFingerprint.<suffix>`. Empty → default ATS / system
    /// trust (correct for Tailscale Serve / Let's Encrypt). NEVER synced —
    /// a cert pin is a per-machine tightening the user typed in on top of
    /// system trust, not a fact about the server to propagate.
    static func fileServerCertFingerprintKey(for ref: RemoteAgentRef) -> String {
        "fileServer.certFingerprint." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC ref's
    /// "file transfer is ready" flag (Bool, default false). Format
    /// `fileServer.available.<suffix>`. Set true ONLY after the staged Test
    /// Connection fully passes (reachability → auth → write → read):
    /// a read-only 200 false-positives on OpenClaw's Control-UI
    /// HTML, so a partial pass must NOT flip availability. Dual-stored so the
    /// composer on another device knows the file affordance is enabled.
    static func fileTransferAvailableKey(for ref: RemoteAgentRef) -> String {
        "fileServer.available." + ref.storageKeySuffix
    }

    /// **Watch App Group only** (NO KVS, and the iPhone never writes it) key for
    /// a SPECIFIC ref's couriered file-lane identity — the iPhone's
    /// `FileTransferSnapshot.durableLaneID`, delivered in that ref's
    /// `RemoteAgentBroadcastEnvelope.fileTransferLaneID`. Format
    /// `fileServer.laneID.<suffix>`. Absent = no READY lane known for this ref,
    /// so a Watch turn dispatched against it is persisted WITHOUT an
    /// output-scan owner (exactly the pre-courier behavior).
    ///
    /// Exists purely for COLD-LAUNCH durability: a ControlWidget-launched wrist
    /// process may dispatch a turn before any envelope arrives, and a turn
    /// stamped from a hydrated lane is the difference between "recoverable by
    /// the retro scan" and "permanently invisible to it". Never KVS-synced —
    /// this is a courier cache of the iPhone's live state, not a fact about the
    /// account, and the iPhone recomputes its own lane from URL + credential.
    /// The value is a one-way digest and is never logged.
    static func fileServerLaneIDKey(for ref: RemoteAgentRef) -> String {
        "fileServer.laneID." + ref.storageKeySuffix
    }

    /// Keychain account slot for a SPECIFIC ref's client-minted file-server
    /// credential (the basic-auth password). Format
    /// `fileServer.credential.<suffix>`. Stored with the SAME service +
    /// accessibility + synchronizable shape as the gateway token
    /// (`remoteAgentTokenKeychainAccount(for:)`), so it rides iCloud Keychain
    /// across the user's own devices. Built-in suffix == raw value; customs get
    /// `fileServer.credential.custom_<uuid>`.
    static func fileServerCredentialKeychainAccount(for ref: RemoteAgentRef) -> String {
        "fileServer.credential." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC ref's
    /// "file-server accepts NESTED (folder) PUTs" flag (Bool, default TRUE).
    /// Format `fileServer.folderCapable.<suffix>`. Set during the staged Test
    /// Connection's nested write-probe (MKCOL the collection, then
    /// `PUT __conduck_probe__/<uuid>` — WebDAV never auto-creates a parent on
    /// PUT, rclone 409s it, hence the MKCOL): a gateway that rejects the nested
    /// PUT even after MKCOL (an S3-DAV bridge, a locked-down nginx-DAV) flips it
    /// false → the client mints FLAT `<8hex>__<name>` keys for that gateway
    /// instead of per-conversation `<convID>/<8hex>__<name>` ones. Default true
    /// so an un-probed / legacy ref (and every rclone deployment, the documented
    /// happy path) gets the folder layout. Dual-stored so a second
    /// device's composer mints matching keys. NOT a user-facing toggle — it is a
    /// silent capability flag (flat keys are a transparent fallback, never an
    /// error surfaced to the user).
    ///
    /// IT GOVERNS THE OUTBOUND DIRECTION ONLY, and the boundary is worth stating
    /// because it used to be crossed: this flag does NOT gate the per-dispatch
    /// output box. That box is NAMED by Conduck and CREATED by the agent, so the
    /// client never PUTs into it and never MKCOLs it — the only client operation
    /// against it is a PROPFIND, which a lane that refuses nested PUTs answers
    /// perfectly well. Gating the box here left phone/Mac/CarPlay with no file
    /// return on a lane where the Watch (which cannot read this flag at all)
    /// still named one. What gates the box instead is the pair that measures the
    /// one capability it actually depends on — answering a `PROPFIND` at all:
    /// the durable `fileServerReturnCapableKeyPrefix` verdict, read first and
    /// shared with the wrist, and then the pre-dispatch absence witness, a
    /// `PROPFIND` that has to come back `404` on the lane itself, per dispatch.
    static func fileServerFolderCapableKey(for ref: RemoteAgentRef) -> String {
        "fileServer.folderCapable." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults **and** iCloud KVS key PREFIX for a SPECIFIC ref's
    /// "this file server can LIST a collection" verdict (Bool, default TRUE).
    /// Format `fileServer.returnCapable.<suffix>`.
    ///
    /// It is the whole RETURN direction: every file an agent produces reaches the
    /// device through a `PROPFIND` of the per-dispatch output box, so a lane with
    /// this false moves bytes UP perfectly and can never bring one back.
    ///
    /// A NARROWING ON PROOF, exactly like `folderCapableKey`: only a structural
    /// `405`/`501` at the staged test's listing stage may clear it, so an ABSENT
    /// stored value reads TRUE — the absence of evidence, not evidence of
    /// absence. Dual-stored because it is a fact about the SERVER, so a second
    /// device must not have to re-measure it before it stops claiming file
    /// return works.
    ///
    /// IT IS THE DISPATCH GATE — `BackgroundFileTransfer.mintOutboxKey` reads it
    /// before it spends anything, and the wrist gates its own mint on the
    /// couriered copy, so one stored fact keeps every surface on one gateway
    /// telling the same story. The per-dispatch absence witness cannot take that
    /// job: it asks about a collection that by construction does not exist, where
    /// a `405`/`501` describes the route rather than the method.
    ///
    /// A GATE THAT ONLY NARROWS NEEDS A WIDENER:
    /// `FileTransferCapabilityRefresher` re-probes a narrowed lane once per
    /// launch and writes `true` back on proof, so a repaired server self-heals at
    /// the next launch — and immediately via the "Test again" button under the
    /// amber "Uploads only" status. It is also what the surfaces that can measure
    /// nothing read: the badges on relaunch, and the wrist, which holds no
    /// file-server credential.
    ///
    /// Single-sourced as a prefix for the same reason
    /// `fileServerAutoDeliverKeyPrefix` is — the inbound KVS mirror scans by
    /// prefix, and `SettingsManager`'s mirrored-prefix list names THIS constant
    /// rather than a second copy of the literal.
    static let fileServerReturnCapableKeyPrefix = "fileServer.returnCapable."

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC ref's
    /// return-capability verdict. Format `fileServer.returnCapable.<suffix>`.
    static func fileServerReturnCapableKey(for ref: RemoteAgentRef) -> String {
        fileServerReturnCapableKeyPrefix + ref.storageKeySuffix
    }

    /// App Groups UserDefaults **and** iCloud KVS key PREFIX for a SPECIFIC
    /// ref's "may this gateway put files on my device automatically" flag
    /// (Bool, default TRUE). Format `fileServer.autoDeliver.<suffix>`.
    ///
    /// A per-gateway PROPERTY, not a capability verdict: `available` and
    /// `folderCapable` say what the server CAN do, this says what the user (and
    /// later, a policy layer) PERMITS it to do. Default true keeps today's
    /// behaviour for every existing ref, and the only value worth storing is the
    /// user's explicit `false`.
    ///
    /// Single-sourced as a prefix because the inbound KVS mirror scans by
    /// prefix — suffixes are dynamic (`custom_<uuid>`), so a scan is the only
    /// way to reach them, and a second copy of the literal would drift.
    static let fileServerAutoDeliverKeyPrefix = "fileServer.autoDeliver."

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC ref's
    /// auto-delivery permission. Format `fileServer.autoDeliver.<suffix>`.
    static func fileServerAutoDeliverKey(for ref: RemoteAgentRef) -> String {
        fileServerAutoDeliverKeyPrefix + ref.storageKeySuffix
    }

    /// App Groups UserDefaults **and** iCloud KVS key PREFIX for a SPECIFIC
    /// ref's delivered-filename policy (String, default
    /// `fileServerFilenamePolicyPreserve`). Format
    /// `fileServer.filenamePolicy.<suffix>`. Same prefix-scan rationale as
    /// `fileServerAutoDeliverKeyPrefix`.
    static let fileServerFilenamePolicyKeyPrefix = "fileServer.filenamePolicy."

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC ref's
    /// delivered-filename policy. Format `fileServer.filenamePolicy.<suffix>`.
    static func fileServerFilenamePolicyKey(for ref: RemoteAgentRef) -> String {
        fileServerFilenamePolicyKeyPrefix + ref.storageKeySuffix
    }

    /// The only filename policy that exists: keep the name the agent gave the
    /// file. Stored as a raw string rather than an enum so an UNKNOWN value
    /// written by a future build degrades to this default on an older one
    /// instead of stranding the whole per-ref config — the same tolerant
    /// posture every other synced per-ref value takes.
    static let fileServerFilenamePolicyPreserve = "preserve"

    /// App Groups UserDefaults key (NO KVS — device-local provenance, like the
    /// cert pin) for a SPECIFIC ref's "THIS device ran a passing staged Test
    /// Connection" flag (Bool, default false). Format
    /// `fileServer.testedLocally.<suffix>`. Distinct from `fileServer.available.*`
    /// once the inbound KVS mirror ships: `available` can arrive from ANOTHER
    /// device via iCloud, so it no longer proves local testing. Gates the silent
    /// launch-time folder-capability re-probe — a device that never tested
    /// locally must not fire automated writes (or an unexplained Local Network
    /// prompt) at a server it only knows through sync. Seeded once at migration:
    /// pre-mirror, a local `available=true` could ONLY have come from a local
    /// test. NEVER synced.
    static func fileServerTestedLocallyKey(for ref: RemoteAgentRef) -> String {
        "fileServer.testedLocally." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults key (NO KVS — device-local provenance, exactly
    /// like the flag it qualifies) for the identity of the file server that
    /// ref's `testedLocally` flag was measured against (String, 64 lowercase
    /// hex). Format `fileServer.testedLocallyStamp.<suffix>`.
    ///
    /// WHY A PER-REF BOOL IS NOT ENOUGH ON ITS OWN: the flag is keyed by
    /// gateway SLOT, so it says "this device tested this slot", not "this
    /// device tested the server sitting in this slot". A peer that repoints the
    /// slot at a different file server syncs the new URL and credential in
    /// through the inbound KVS mirror, which grants no local proof — and,
    /// without this key, revokes none either, so the silent upgrade probes
    /// would fire at a host this device has never seen. The folder probe WRITES
    /// (a nested PUT), which is how that reaches a stranger's server and raises
    /// an unexplained iOS Local-Network prompt.
    ///
    /// The stored value is `FileTransferSnapshot.localProofStamp` — a SHA-256
    /// over the durable lane identity (URL + credential) and the device-local
    /// certificate pin, so repointing the URL, rotating the credential or
    /// changing the pin all revoke the proof. Only the digest is ever written:
    /// no credential and no fingerprint sits in a readable field, and the key
    /// is NEVER synced and NEVER logged.
    ///
    /// ABSENT MEANS UNPROVEN. A stored flag with no stamp arms nothing — the
    /// stamp cannot be back-filled on read, because back-filling would stamp
    /// whatever server happens to occupy the slot now, which is the gap itself.
    static func fileServerTestedLocallyStampKey(for ref: RemoteAgentRef) -> String {
        "fileServer.testedLocallyStamp." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults key (NO KVS) for the ONE-TIME `testedLocally`
    /// seed guard (Bool). The seed scans local defaults for pre-mirror
    /// `fileServer.available.<suffix> == true` entries and marks each ref
    /// locally-tested; it must run BEFORE the inbound KVS mirror can write
    /// `available` into defaults, or a synced-only peer would be misclassified.
    /// It seeds the FLAG only, never a stamp — it knows a staged test once
    /// passed on this device, not which server it passed against — so a seeded
    /// ref reads as unproven until a Test Connection re-earns the stamp.
    static let fileServerTestedLocallySeededKey = "fileServer.testedLocallySeeded"

    /// Revision of the folder-capability probe ALGORITHM. Bump when the probe /
    /// upload sequence changes in a way that could turn a previously
    /// folder-incapable verdict capable (e.g. the MKCOL-before-nested-PUT fix).
    /// The silent launch-time re-probe runs once per revision per ref — NOT per
    /// launch, and NOT keyed to the marketing app version (two TestFlight
    /// builds share one). Definitive outcomes record this value in
    /// `fileServerFolderProbeRevisionKey`.
    static let fileServerFolderProbeRevision = 1

    /// App Groups UserDefaults key (NO KVS — per-device probe bookkeeping) for
    /// a SPECIFIC ref's last DEFINITIVE folder-probe revision (Int). Format
    /// `fileServer.folderProbeRevision.<suffix>`. Absent or !=
    /// `fileServerFolderProbeRevision` → the silent re-probe is due.
    /// Indeterminate probe outcomes (transport error, ambiguous status) never
    /// write it, so they retry on a later launch.
    static func fileServerFolderProbeRevisionKey(for ref: RemoteAgentRef) -> String {
        "fileServer.folderProbeRevision." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults key (NO KVS) for a SPECIFIC ref's last silent
    /// folder-probe ATTEMPT timestamp (`timeIntervalSince1970`, Double). Format
    /// `fileServer.folderProbeAttempt.<suffix>`. Backoff seed so an offline
    /// server costs at most one failed probe per `fileServerFolderProbeBackoff`
    /// window, not one per launch.
    static func fileServerFolderProbeAttemptKey(for ref: RemoteAgentRef) -> String {
        "fileServer.folderProbeAttempt." + ref.storageKeySuffix
    }

    /// Minimum seconds between silent folder-probe ATTEMPTS for one ref (24 h).
    /// Applies to indeterminate retries; a definitive outcome parks the probe
    /// until the next `fileServerFolderProbeRevision` bump regardless.
    static let fileServerFolderProbeBackoff: TimeInterval = 24 * 60 * 60

    /// LEGACY key — App Groups UserDefaults key for the RETIRED per-ref
    /// "keep ALL prior images inline" escape-hatch (Bool). Format
    /// `fileServer.keepImagesInline.<suffix>`. Superseded by the 3-level
    /// `ImageHistoryPolicy` (`imageHistoryPolicyKey`); kept ONLY as the
    /// lazy-migration source: `getImageHistoryPolicy(for:)` resolves a
    /// stored `true` to `.all` (the bool's exact semantics) while the new key
    /// is absent. No writer remains; never repurpose the prefix.
    static func fileServerKeepImagesInlineKey(for ref: RemoteAgentRef) -> String {
        "fileServer.keepImagesInline." + ref.storageKeySuffix
    }

    /// App Groups UserDefaults **and** iCloud KVS key prefix for a SPECIFIC
    /// ref's `ImageHistoryPolicy` raw value. Single-sourced so the
    /// `handleICloudChange` prefix-scan and `imageHistoryPolicyKey(for:)`
    /// never drift. NOT `fileServer.`-prefixed: the policy is gateway-scoped,
    /// not file-server-scoped (a server-less custom endpoint needs it too).
    static let imageHistoryPolicyKeyPrefix = "imageHistory.policy."

    /// App Groups UserDefaults **and** iCloud KVS key for a SPECIFIC ref's
    /// `ImageHistoryPolicy` (raw string `recent`/`extended`/`all`, default
    /// `.recent` when unset — after the legacy-bool migration check above).
    /// Format `imageHistory.policy.<suffix>`. Dual-stored + KVS-mirrored
    /// inbound (`handleICloudChange` prefix-scan) so the policy is consistent
    /// across the user's devices; the legacy bool never had an inbound mirror.
    static func imageHistoryPolicyKey(for ref: RemoteAgentRef) -> String {
        imageHistoryPolicyKeyPrefix + ref.storageKeySuffix
    }

    // MARK: - Share Extension (system share-sheet → App-Group inbox)
    //
    // The Share Extension appex (capture-and-queue) copies each shared item into
    // an App-Group inbox envelope dir + writes a `SharedInboxManifest`, then the
    // main-app `SharedInboxDrainer` reads it on the next foregrounding. Keys +
    // dir-name single-sourced here so the appex and the drainer agree.

    /// Name of the App-Group inbox subdirectory (under `Application Support`)
    /// that holds published share envelopes. NOT `Library/Caches` — iOS purges
    /// caches and a queued share is durable pending user work. Single-sourced so
    /// the appex (writer) and the drainer (reader) never drift.
    ///
    /// `nonisolated` — `Constants` is MainActor-isolated by the target's default
    /// actor isolation, but the `SharedInboxDrainer` actor reads this immutable
    /// `Sendable` string synchronously off the main actor; without `nonisolated`
    /// that cross-actor read warns (Swift 6 concurrency).
    nonisolated static let sharedInboxDirectoryName = "Inbox"

    /// File name (under the App-Group `Application Support` dir) of the
    /// "Send to" targets snapshot the main app REGENERATES and the appex picker
    /// READS. The main-app `ShareTargetsSnapshotWriter` (writer) and the appex
    /// (reader) must agree on this literal byte-for-byte; single-sourced here so
    /// they never drift. `nonisolated` for the same cross-actor reason as
    /// `sharedInboxDirectoryName` (the writer actor reads it off the main actor).
    nonisolated static let shareTargetsSnapshotFileName = "share-targets.json"

    // MARK: - KVS Schema (diagnostic only)

    /// KVS schema version key. Diagnostic-only forward-compat —
    /// MUST NOT gate behavior; readers tolerate missing/mismatched values.
    static let kvsSchemaVersionKey = "kvsSchemaVersion"

    /// Current KVS schema version. Increment only when adding new keys; never
    /// branch on this value.
    static let kvsSchemaVersion = 1

    // MARK: - Notifications

    /// Display characters kept in a reply notification's body, on every surface
    /// that posts one (iOS/macOS background landing, the wrist).
    ///
    /// The body is the untrusted agent reply, so the cut is taken INSIDE
    /// `ReplySanitizer.displayLine` rather than by the caller: projecting first
    /// and cutting last is what stops a truncation from severing a bidi opener
    /// from its terminator. `nonisolated` because the iOS poster runs in a
    /// process the background URLSession event relaunched, off the main actor.
    ///
    /// The value is a ceiling, not a target — the system already elides a
    /// notification body to two or three lines on a lock screen and to one on a
    /// watch face. What it bounds is how much of a multi-megabyte reply the
    /// projection ever has to walk before a banner can be built.
    nonisolated static let replyNotificationBodyCharacterCount = 200

    // MARK: - App Information

    /// App version from Info.plist
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Build number from Info.plist
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Full version string (e.g., "1.0 (1)")
    static var fullVersion: String {
        "\(appVersion) (\(buildNumber))"
    }

    // MARK: - Layout Constants

    /// Platform-specific layout values
    enum Layout {
        /// Shared (all platforms) chat-column cap — the axis bubbles + the
        /// composer card center on. 720pt across macOS + the iPad split.
        static let chatContentWidth: CGFloat = 720
        /// Readable measure for a centered explanatory paragraph (the unconfigured
        /// empty state). Far tighter than `chatContentWidth`: an uncapped paragraph
        /// stretches to the full iPad/Mac width and rags mid-clause.
        static let emptyStateBodyMaxWidth: CGFloat = 420
        #if os(macOS)
        static let horizontalPadding: CGFloat = 28
        static let buttonMaxWidth: CGFloat = 400
        /// Onboarding-scaffold width caps (see `OnboardingStepScaffold`). The
        /// scaffold applies these on macOS and on iPad-regular only; iPhone
        /// stays full-width via `.infinity` (gated in the scaffold, not here).
        static let onboardingContentMaxWidth: CGFloat = 520
        static let onboardingFooterMaxWidth: CGFloat = 400
        /// Height cap for the guided-wizard step panel (content + footer) on the
        /// big canvases; the scaffold centers the capped panel below the chrome
        /// band so a tall window never strands the CTA at its bottom edge.
        static let onboardingPanelMaxHeight: CGFloat = 760
        #elseif os(watchOS)
        static let horizontalPadding: CGFloat = 8
        static let buttonMaxWidth: CGFloat = .infinity
        // Onboarding scaffold is not used on watchOS; defined for symmetry.
        static let onboardingContentMaxWidth: CGFloat = .infinity
        static let onboardingFooterMaxWidth: CGFloat = .infinity
        static let onboardingPanelMaxHeight: CGFloat = .infinity
        #else
        static let horizontalPadding: CGFloat = 16
        static let buttonMaxWidth: CGFloat = .infinity
        /// Onboarding-scaffold width caps (see `OnboardingStepScaffold`).
        /// Applied on iPad-regular only — iPhone (compact, and large iPhones
        /// in landscape) stays full-width via the scaffold's idiom/size gate.
        static let onboardingContentMaxWidth: CGFloat = 540
        static let onboardingFooterMaxWidth: CGFloat = 420
        /// Height cap for the guided-wizard step panel (see the macOS twin) —
        /// consumed on iPad-regular only, via the scaffold's surface gate.
        static let onboardingPanelMaxHeight: CGFloat = 760
        #endif
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when settings are updated from iCloud KVS (remote device change)
    static let settingsDidChangeRemotely = Notification.Name("settingsDidChangeRemotely")

    /// Posted after any mutation to the conversation store (local write OR a
    /// merged CloudKit remote change) so list / detail view models refetch.
    /// Single coalescing bus — both `ConversationStore`'s own CRUD and the
    /// `.NSPersistentStoreRemoteChange` observer fan into this one name.
    static let conversationsDidChange = Notification.Name("conversationsDidChange")

    /// Posted on app FOREGROUND to nudge only the ON-SCREEN conversation list +
    /// open thread to re-read the LOCAL store — a "snapshot refresh", NOT a sync
    /// pull (NSPersistentCloudKitContainer exposes no force-fetch). Deliberately
    /// distinct from `.conversationsDidChange`, which ALSO drives share-target
    /// snapshot regeneration / menu-bar / CarPlay observers; only the list +
    /// detail view models observe THIS name, so a foreground tick never triggers
    /// those heavier side effects. Covers the gap where CloudKit imported while
    /// the app was suspended/inactive and the remote-change bus fired before a
    /// view model existed (or was coalesced away).
    static let conversationsNeedLocalRefresh = Notification.Name("conversationsNeedLocalRefresh")
}

// MARK: - App Colors (GigaDuck Brand Palette)

/// GigaDuck brand color system — amber/teal/orange on warm dark neutrals.
/// A Conduck-specific brand pass may replace these; views reference
/// `AppColors.*`. These values are canonical — there is no external token doc.
enum AppColors {
    // MARK: - Brand Colors

    /// Primary brand color — Duck Amber (#FFC107)
    static let brandAmber = Color(red: 1.0, green: 0.757, blue: 0.027)

    /// Brand teal — secondary (#26A69A)
    static let brandTeal = Color(red: 0.149, green: 0.651, blue: 0.604)

    /// Sunset orange — accent (#FF7043)
    static let sunsetOrange = Color(red: 1.0, green: 0.439, blue: 0.263)

    // MARK: - Text Colors (warm off-whites for dark mode)

    /// High-emphasis text — app title, hero text (dark-50: #F8F5F1)
    static let textEmphasis = Color(red: 0.973, green: 0.961, blue: 0.945)

    /// Primary text — headings, important content (dark-100: #EDE8E3)
    static let textPrimary = Color(red: 0.929, green: 0.910, blue: 0.890)

    /// Secondary text — descriptions, labels (dark-200: #D9D0C8)
    static let textSecondary = Color(red: 0.851, green: 0.816, blue: 0.784)

    /// Tertiary text — hints, timestamps (#A0948A, ~5.3:1 on card bg)
    static let textTertiary = Color(red: 0.627, green: 0.580, blue: 0.541)

    // MARK: - Background Colors (warm dark neutrals)

    /// Page background (dark-900: #121010)
    static let background = Color(red: 0.071, green: 0.063, blue: 0.063)

    /// Card background, elevated surfaces (dark-800: #1E1A18)
    static let cardBackground = Color(red: 0.118, green: 0.102, blue: 0.094)

    /// Elevated card surface — slightly lighter for visual lift (#25201E)
    static let cardBackgroundElevated = Color(red: 0.145, green: 0.125, blue: 0.118)

    /// Secondary background (dark-700: #2C2623)
    static let backgroundSecondary = Color(red: 0.173, green: 0.149, blue: 0.137)

    /// Gradient start (dark-900: #121010)
    static let gradientStart = Color(red: 0.071, green: 0.063, blue: 0.063)

    /// Gradient end (dark-800: #1E1A18)
    static let gradientEnd = Color(red: 0.118, green: 0.102, blue: 0.094)

    // MARK: - Border & Shadow

    /// Border color (dark-600: #3D3531)
    static let border = Color(red: 0.239, green: 0.208, blue: 0.192)

    /// Subtle border — less prominent (dark-600 at 60%)
    static let borderSubtle = Color(red: 0.239, green: 0.208, blue: 0.192).opacity(0.6)

    /// Disabled state (dark-500: #5C524A)
    static let disabled = Color(red: 0.361, green: 0.322, blue: 0.290)

    /// Shadow color — warm brown, not pure black
    static let shadow = Color(red: 0.165, green: 0.129, blue: 0.094)

    // MARK: - Pointer Feedback (macOS hover / press)

    /// Wash behind a control the mouse is hovering. Derived from `textPrimary`
    /// rather than plain white so the highlight stays in the warm family — a
    /// neutral white overlay reads cold and grey against these browns.
    /// Applied by the styles in `MacPointerTargets.swift`.
    static let pointerHoverFill = textPrimary.opacity(0.07)

    /// Wash behind a control while the mouse button is down — the same tone,
    /// deepened, so press is legible as "more of the same" rather than a
    /// different color appearing under the cursor.
    static let pointerPressedFill = textPrimary.opacity(0.13)

    // MARK: - Accent Colors

    /// Primary accent — matches brandAmber
    static let accent = Color(red: 1.0, green: 0.757, blue: 0.027)

    /// Guided-Setup blue (#0A84FF) — the ONE cool-toned affordance in an
    /// otherwise warm amber/dark palette, which is precisely what makes the
    /// Personal AI "Guided Setup" row read as the front door. Scoped to that row
    /// (`PersonalAIConnectRows`) on purpose; nothing else adopts it.
    ///
    /// Deliberately an EXPLICIT value rather than `.tint`/`Color.accentColor`:
    /// the app ships an EMPTY `AccentColor` asset, so `.tint` resolves to the
    /// OS default — and on macOS that default follows the USER's System Settings
    /// accent. A Mac user who picked pink would otherwise get a pink "Guided
    /// Setup" row, losing the exact distinctness this color exists to provide.
    static let guidedSetupBlue = Color(red: 0.039, green: 0.518, blue: 1.0)

    // MARK: - Semantic Colors (dark mode)

    /// Success (#66BB6A)
    static let success = Color(red: 0.400, green: 0.733, blue: 0.416)

    /// Error (#EF5350)
    static let error = Color(red: 0.937, green: 0.325, blue: 0.314)

    /// Warning (#FFB74D)
    static let warning = Color(red: 1.0, green: 0.718, blue: 0.302)
}

// MARK: - Branded Text (Wordmark)

/// Single neutral high-contrast "Conduck" wordmark.
enum BrandedText {
    /// Single neutral high-contrast wordmark. The app is dark-locked on every
    /// surface (`.preferredColorScheme(.dark)`), so off-white (`textEmphasis`)
    /// is the high-contrast neutral everywhere — no light background exists.
    /// Replaces the former two-tone "Con"+"duck" split, which pre-chopped the
    /// portmanteau and isolated the standalone "Con".
    static func conduck() -> Text {
        Text(verbatim: "Conduck").foregroundStyle(AppColors.textEmphasis)
    }
}

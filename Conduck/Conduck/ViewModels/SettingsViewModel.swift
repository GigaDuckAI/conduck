// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModel.swift
//
// UI layer for the per-preset multi-provider keyed model. The Settings picker
// renders one `ProviderRow` per `STTProviderRegistry.all` entry; each row's
// state is derived from `rowState(for:)` which reads
// (a) `keyStates[presetID]` for in-flight / failure state,
// (b) `SettingsManager` for stored-key + active-preset truth.
//
// Privacy invariant: raw API keys flow through `validateAndSave(key:for:)`
// and never enter `keyStates` or any other stored property. The View's
// own SecureField buffer is the only retention surface (per
// `ProviderRow.pendingKey`).

import Foundation
import Observation
#if !os(watchOS)
// Speech framework is `@available(watchOS, unavailable)`. Imported only
// where Apple on-device STT lives — required for the Apple-model
// lifecycle methods and the TCC pattern-match in
// `validateAndSave`.
import Speech
#endif

/// Per-row key-validation lifecycle. The ViewModel stores ONE instance per
/// preset ID (in `keyStates`), not one for the whole screen.
enum KeyValidationState: Equatable {
    case unset
    case checking
    case valid
    case invalid(message: String)
}

/// Coarse file-transfer setup state for a gateway — the PRIMARY axis the
/// redesigned `FileTransferSetupGuideView` lays out around. Derived from
/// `SettingsViewModel.fileTransferSetupState(for:)`.
///
/// The three-way split is load-bearing: a SAVED snapshot (URL + credential)
/// is NOT the same as READY. Availability only flips true after the staged
/// Test Connection fully passes, so `.savedNeedsTest` is the state that must
/// keep nudging "run the test" rather than masquerading as done.
enum FileTransferSetupState: Equatable {
    /// No saved file-server snapshot yet (missing URL and/or credential).
    case missing
    /// URL + credential saved, but the staged Test Connection has not passed.
    case savedNeedsTest
    /// Staged Test Connection fully passed — file transfer is usable.
    case ready
}

/// The exact input tuple a staged file-transfer Test Connection probed:
/// canonical URL + normalized pin + credential generation (a counter bumped on
/// every credential write, so the plaintext never enters the signature). A
/// verdict is only meaningful for the tuple it tested — signature equality is
/// how the editor decides whether to display a staged verdict, whether a Save
/// may carry it into availability, and whether a probe that lands late is stale.
struct FileTransferTestSignature: Equatable, Sendable {
    /// Canonical `URL.absoluteString` of the probed file-server URL.
    let url: String
    /// Normalized pin (lowercase hex, colons stripped); "" = system trust.
    let pin: String
    /// `fileServerCredentialGenerations[ref]` at probe time.
    let credentialGeneration: Int
}

/// First-class "Files and outputs" row status on the redesigned gateway editor.
/// A user-facing refinement of `FileTransferSetupState` that also folds in the
/// gateway's recommendation level and the failure signal: `.savedNeedsTest`
/// alone can't tell "saved but never tested" from "tested and failed" — the
/// failure comes from `fileServerValidationStates`. Computed by
/// `SettingsViewModel.fileLaneStatus(for:)`.
enum GatewayFileLaneStatus: Equatable {
    /// Staged test passed IN BOTH DIRECTIONS — the file server accepted a
    /// write/read cycle AND answered the two PROPFINDs the return direction is
    /// built on. The client cannot prove the agent workspace or tool-policy
    /// requirements.
    case ready
    /// Staged test passed for UPLOADS, and the server stated it does not
    /// implement `PROPFIND` (`405`/`501`), so nothing an agent writes can ever
    /// come back on its own. Neither green nor red: the lane genuinely works,
    /// in one direction, and this is the only badge that says so.
    ///
    /// Its own case rather than a flag the badge surfaces read alongside
    /// `.ready`, because every one of them (the editor's nav-row badge, the
    /// setup page's status block, the gateway-setup success screen) would
    /// otherwise have to remember to ask the second question — and the one that
    /// forgot would assert both directions on a server that has one.
    case readyUploadsOnly
    /// Saved but the last staged test FAILED (write/read/delete) — surfaces red.
    case needsAttention
    /// Saved (URL + credential) but not yet tested — neutral "run a test".
    case saved
    /// Not set up, on a built-in full-agent gateway (OpenClaw/Hermes) where the
    /// file lane is core value + usually auto-configured by the setup code.
    case recommended
    /// Not set up, on a file-capable custom gateway — purely optional.
    case optional
    /// Backend has no file lane (OpenRouter hosted model) — row hidden entirely.
    case unsupported
}

/// Per-locale Apple on-device model install state. Distinct
/// from `KeyValidationState` because Apple has no API key — the row's
/// lifecycle is "download a per-language ML asset", not "validate a key".
/// Keyed by `Locale.identifier` in `SettingsViewModel.appleModelStates`.
enum AppleModelInstallState: Sendable, Equatable {
    /// Asset not on disk; "Download model" CTA shown.
    case notDownloaded
    /// Asset download in flight; `progress` is 0.0–1.0.
    case downloading(progress: Double)
    /// Asset on disk and ready; "Set as Active" / "Active" shown.
    case installed
    /// Download / install attempt produced a terminal failure.
    ///
    /// `retryable` discriminates two distinct shapes of failure that QA
    /// found were being conflated:
    /// - `true` — transient (network drop, quota, mid-download error);
    ///   show the "Try again" affordance.
    /// - `false` — structural (language unsupported even after locale
    ///   normalization); no retry path exists, render the message only +
    ///   defer to the cloud-provider skip affordance owned by the parent.
    case failed(message: String, retryable: Bool)
}

/// One row in the Personal AI gateway list — a built-in OR a custom gateway,
/// precomputed by `SettingsViewModel.personalAIRows` so the View stays dumb
/// (no actor hop, no built-in-vs-custom branching in `body`). `ref` is the
/// stable list/nav identity; `isDefault` is precomputed against the VM's
/// `defaultRemoteAgentRef` so the row doesn't compare an enum to a ref.
struct PersonalAIRow: Identifiable, Hashable {
    let ref: RemoteAgentRef
    let displayName: String
    let configured: Bool
    let isDefault: Bool
    /// Setup was started on this device but the gateway can't be used as it
    /// stands. Distinct from `!configured`, which conflated "half set up" with
    /// "never touched" and left a URL-without-key gateway looking untouched —
    /// while Diagnostics warned about it and sent the user to this very list.
    let incomplete: Bool

    var id: RemoteAgentRef { ref }
}

/// Observable view model for Conduck app settings.
@Observable
@MainActor
final class SettingsViewModel {
    // MARK: - Published Properties

    var isLoading: Bool = false

    /// One mounted buffered editor (`bufferedEditorChrome`) and whether it
    /// currently holds unsaved edits.
    struct BufferedEditorRegistration: Identifiable, Equatable {
        let id: UUID
        var isDirty: Bool
    }

    /// Every buffered editor currently on screen, in MOUNT order — `last` is the
    /// innermost/topmost. A stack rather than a single flag because editors
    /// legitimately co-mount: the gateway editor pushes the file-transfer page,
    /// and both carry `bufferedEditorChrome`. With one shared flag the child's
    /// `.onAppear` would overwrite the parent's dirty state on push and its
    /// `.onDisappear` would clear it on pop, leaving the parent's data-loss guard
    /// resting on an untestable "a child push doesn't fire the parent's
    /// onDisappear" assumption. Per-editor entries are correct under either
    /// ordering.
    ///
    /// `private(set)` on purpose: the four mutators below are the ONLY writers,
    /// and each one ends in `drainDeferredReloadIfCleared` — that encapsulation
    /// is what replaces the `didSet` the old stored flag relied on.
    private(set) var bufferedEditors: [BufferedEditorRegistration] = []

    /// Dirty state asserted by NON-chrome writers — the onboarding gateway steps,
    /// the container hard-resets, and tests — through `editorHasUnsavedChanges`'s
    /// setter. Kept separate so a hard reset can't be resurrected by a still-clean
    /// editor's registration, and vice versa.
    private var directEditorDirty: Bool = false

    /// True while any buffered config editor (`RemoteAgentConfigBody` /
    /// `CustomSTTConfigBody` / the file-transfer editor) holds unsaved edits, or
    /// while a non-chrome writer has asserted one. It is the SINGLE source of truth
    /// the whole settings surface consults so that no unsaved edit is ever lost
    /// without a "Discard changes?" confirmation: the macOS Done/Esc/sidebar gates
    /// and the iOS sheet's `interactiveDismissDisabled` all key off it. It ALSO
    /// fences the remote-change reload (see `pendingRemoteReload`) so a
    /// write-on-change control or an incoming iCloud-KVS sync can't silently
    /// clobber the live buffers mid-edit.
    ///
    /// Setting it to `false` is a HARD RESET — it clears every registered editor's
    /// dirty bit too, matching what the bare `= false` call sites have always
    /// meant (the sheet-dismiss cleanup, the container `.onAppear` belt-and-braces,
    /// and the outer Discard pre-clear, all of which immediately tear the editors
    /// down anyway).
    var editorHasUnsavedChanges: Bool {
        get { directEditorDirty || bufferedEditors.contains { $0.isDirty } }
        set {
            let was = editorHasUnsavedChanges
            directEditorDirty = newValue
            if !newValue {
                for index in bufferedEditors.indices { bufferedEditors[index].isDirty = false }
            }
            drainDeferredReloadIfCleared(from: was)
        }
    }

    /// Whether ANY buffered editor is on screen, dirty or not. Distinct from
    /// `editorHasUnsavedChanges`: the macOS Escape gate keys off mere presence, so
    /// that Esc inside a clean editor cancels the editor instead of closing all of
    /// Settings.
    var hasMountedBufferedEditor: Bool { !bufferedEditors.isEmpty }

    /// The innermost mounted editor. `BufferedEditorChrome` gives its macOS Cancel
    /// the `.cancelAction` shortcut only when it matches, so exactly ONE Escape
    /// target is live at a time — SwiftUI documents no precedence between two live
    /// `.cancelAction` buttons, and a pushed-away parent stays in the hierarchy on
    /// macOS.
    var topBufferedEditorID: UUID? { bufferedEditors.last?.id }

    /// Register a newly mounted editor (idempotent — a repeat `.onAppear` for the
    /// same id refreshes its dirty bit rather than duplicating the entry).
    func registerBufferedEditor(_ id: UUID, isDirty: Bool) {
        let was = editorHasUnsavedChanges
        if let index = bufferedEditors.firstIndex(where: { $0.id == id }) {
            bufferedEditors[index].isDirty = isDirty
        } else {
            bufferedEditors.append(BufferedEditorRegistration(id: id, isDirty: isDirty))
        }
        drainDeferredReloadIfCleared(from: was)
    }

    /// Track a mounted editor's live dirty state. No-op for an unknown id.
    func setBufferedEditorDirty(_ id: UUID, _ isDirty: Bool) {
        let was = editorHasUnsavedChanges
        guard let index = bufferedEditors.firstIndex(where: { $0.id == id }) else { return }
        bufferedEditors[index].isDirty = isDirty
        drainDeferredReloadIfCleared(from: was)
    }

    /// Drop an editor that left the screen.
    func unregisterBufferedEditor(_ id: UUID) {
        let was = editorHasUnsavedChanges
        bufferedEditors.removeAll { $0.id == id }
        drainDeferredReloadIfCleared(from: was)
    }

    /// The drain the old stored flag carried in its `didSet`. ONE funnel, called by
    /// the setter AND by every registry mutation, so it can neither be missed (the
    /// storage is private) nor double-fire (`pendingRemoteReload` is cleared
    /// synchronously before the `Task` is dispatched, and the class is
    /// `@MainActor`, so a second transition sees it already `false`).
    private func drainDeferredReloadIfCleared(from previous: Bool) {
        guard previous, !editorHasUnsavedChanges, pendingRemoteReload else { return }
        pendingRemoteReload = false
        Task { await loadSettings() }
    }

    /// A `.settingsDidChangeRemotely` reload that arrived WHILE an editor was dirty
    /// and was deferred (running it then would overwrite the user's unsaved
    /// buffers). Drained by `drainDeferredReloadIfCleared` when the last dirty
    /// editor closes or goes clean. Non-observed bookkeeping.
    @ObservationIgnored private var pendingRemoteReload: Bool = false

    /// In-flight / failure state per preset. Keys absent from this dict
    /// resolve to `.unset` — `rowState(for:)` then consults Keychain to
    /// decide between `.empty` and `.storedInactive` / `.storedActive`.
    var keyStates: [String: KeyValidationState] = [:]

    /// Snapshot of which preset IDs currently have a key in Keychain.
    /// Reloaded after every save / clear so the picker re-renders without
    /// blocking on `SettingsManager` actor hops mid-View-render.
    var storedPresetIDs: Set<String> = []

    /// Cached masked-tail strings keyed by preset ID (e.g. `"••••XK4q"`).
    /// Populated in `loadSettings()` and refreshed after `validateAndSave`
    /// / `clearKey`. View body reads `maskedTails[presetID]` — a pure dict
    /// lookup, no Keychain call per render.
    var maskedTails: [String: String] = [:]

    /// Active preset ID — drives the "Active" badge + the `storedActive`
    /// vs `storedInactive` discriminator. Mirrors `SettingsManager.shared
    /// .getActivePresetID()`.
    var activePresetID: String = Constants.sttActivePresetIDDefault

    /// Per-preset custom model override (Feature 1), keyed by preset ID.
    /// Empty / absent = "use the provider's recommended default". Populated in
    /// `refreshCustomModels()` (mirrors `refreshMaskedTails`); the Advanced
    /// model `TextField` in `ProviderConfigBody` binds + saves through
    /// `saveCustomModel(_:for:)`. Non-secret → App Groups + iCloud KVS via
    /// `SettingsManager`, never Keychain.
    var customModels: [String: String] = [:]

    /// Per-preset rich Test Connection result (Feature 3), keyed by preset ID.
    /// Updated on EVERY stage tick by `runSuite(...)` for live checklist
    /// animation; `STTTestSuiteResultView` renders the entry. Distinct from the
    /// cheap key-check (`validateAndSave`) — the full suite is a richer surface.
    var sttTestSuiteResults: [String: STTTestSuiteResult] = [:]

    /// Preferred STT language hint (ISO 639-1, e.g. `"en"`). `nil` = auto-detect.
    /// Provider-agnostic.
    var preferredLanguage: String?

    /// Per-locale install state for the Apple on-device model
    /// Keyed by the CANONICAL RESOLVED `Locale.identifier`
    /// (e.g. `en_US`, `de_DE`) — NOT the raw requested string — so `de` /
    /// `de_DE` / `de-DE` can't drift into separate entries. The Settings UI
    /// observes this to render "Download model" → progress bar →
    /// "Ready" / "Failed". Refreshed lazily — `checkAppleModelStatus`
    /// hits `AssetInventory.status(forModules:)` for the resolved target.
    var appleModelStates: [String: AppleModelInstallState] = [:]

    /// Canonical resolved-locale identifier the Apple model UI currently
    /// targets — derived from the global `preferredLanguage` (multilingual,
    /// 2026-06). Written by `checkAppleModelStatus` / `downloadAppleModel`;
    /// views and `isProviderReady` read `appleModelStates[appleTargetKey]` so
    /// the writer and every reader always agree on the key. Defaults to the
    /// English floor until the first status check hydrates it.
    var appleTargetKey: String = Locale(identifier: "en_US").identifier

    /// The user's chosen on-device Apple engine — `.dictation` (standard
    /// keyboard-grade, no download, no hardware floor; the DEFAULT) or
    /// `.highQuality` (the downloadable `SpeechTranscriber` model, A16+).
    /// Mirrors the persisted `SettingsManager.getAppleOnDeviceEngineMode()`;
    /// hydrated in `loadSettings` (and refreshed on the Apple detail's appear
    /// via `checkAppleModelStatus`). The Apple provider detail observes this to
    /// pick the dictation vs high-quality branch. NO `#if os` guard — the enum
    /// is plain; only the high-quality DOWNLOAD path is non-watch.
    private(set) var appleOnDeviceEngineMode: AppleOnDeviceEngineMode = .default

    /// Prepare/readiness state for the STANDARD (`.dictation`) engine at the
    /// current language. Parallel to the HIGH-QUALITY `appleModelStates` ledger but
    /// a single scalar — Standard has one target (the active language). Each Apple
    /// engine row reads its own state (Standard here, High quality from
    /// `appleModelStates[appleTargetKey]`); there is no separate status line.
    /// `.notDownloaded` AND `.downloading` both render as a calm "Preparing…"
    /// spinner; `.failed` is reserved for a genuine prepare failure (offline /
    /// unsupported / disk full) with a working retry. Always `.notDownloaded` on
    /// watchOS (no probe / no Speech model on the wrist).
    var appleStandardModelState: AppleModelInstallState = .notDownloaded

    /// Canonical resolved-locale identifier the Standard state currently describes
    /// (mirrors `appleTargetKey` for the HQ ledger). Target-aware so a language
    /// switch can't leave a stale "Ready" for the previous language.
    var appleStandardTargetKey: String = Locale(identifier: "en_US").identifier

    /// Monotonic token dropping a stale `prepareStandardEngine` completion (a newer
    /// language/prepare bumps it, so an older in-flight install can't write state
    /// for a since-changed target).
    @ObservationIgnored private var appleStandardGeneration: Int = 0

    #if !os(watchOS)
    /// Single-flight guard for a Standard prepare: non-nil while an install is in
    /// flight; a second caller awaits it instead of double-kicking AssetInventory.
    @ObservationIgnored private var appleStandardPrepareTask: Task<Void, Never>?

    /// Install seam (test injection point). Production = `LiveAppleModelInstaller`
    /// (forwards to the static `AppleModelInstaller`); tests inject a stub.
    @ObservationIgnored var appleModelInstaller: any AppleModelInstalling = LiveAppleModelInstaller()
    #endif

    /// Monotonic token guarding the reserve-swap against a stale download
    /// completion: a newer language choice bumps this, so an older download
    /// that finishes late can't release the newer choice's reserved locale.
    @ObservationIgnored private var appleDownloadGeneration: Int = 0

    /// User intent to COMMIT the engine to `.highQuality` once its model finishes
    /// downloading. Set when the user picks High quality (and it isn't installed
    /// yet); CLEARED if they tap Standard while the download is still running.
    /// The engine stays `.dictation` throughout the download — it flips only on a
    /// successful install AND only if this intent is still set (so a revert-during-
    /// download doesn't auto-switch them to high quality on completion).
    @ObservationIgnored private var pendingHighQualityCommit: Bool = false

    #if !os(watchOS)
    /// Drives the Settings → Voice → Apple "Try it" live-recording test (record →
    /// transcribe on-device → show the transcript). Owned here so the iOS + macOS
    /// Apple details share one instance across navigation. Non-watch (depends on
    /// `AppleSpeechRunner`).
    let appleSpeechTester = AppleSpeechTester()

    /// Drives the Settings → Voice → <cloud provider> "Record a test" (record →
    /// transcribe over the network → show the transcript). REPLACES the old cheap
    /// "Test Connection" key-check in the STT section. One instance shared across
    /// the iOS + macOS provider details (only one detail is on screen at a time;
    /// each screen cancels it on disappear, so state never bleeds between
    /// providers). Non-watch (the cloud detail screens are iOS/macOS only).
    let cloudSTTTester = CloudSTTTester()
    #endif

    // MARK: - TTS (cloud Text-to-Speech) — observable state
    //
    // Mirrors the STT `activePresetID` / `customModels` shape. The active TTS
    // provider pointer is independent of the active STT preset (the user picks
    // each direction separately); both directions of a vendor share ONE key, so
    // both "configured" pills derive from the SAME `storedPresetIDs`. See
    // `SettingsViewModel+TTS.swift` for the methods + derivations.

    /// Active TTS provider id — drives the TTS "Active" pill + the voice-summary
    /// line. Mirrors `activePresetID`. Default `apple-tts`.
    var activeTTSProviderID: String = Constants.ttsActiveProviderIDDefault

    /// Per-TTS-provider voice override, keyed by `TTSProvider.id`. Empty/absent
    /// = the provider's pinned `defaultVoice`. Populated in `refreshTTSVoices()`;
    /// the free-text voice field in the detail binds + saves through
    /// `saveTTSVoice(_:for:)`. Non-secret → App Groups + iCloud KVS.
    var ttsVoices: [String: String] = [:]

    /// Per-TTS-provider MODEL override, keyed by `TTSProvider.id`. Empty/absent
    /// = the provider's pinned `model`. Populated in `refreshTTSCustomModels()`;
    /// the `AdvancedModelDisclosure` field in the TTS detail binds + saves
    /// through `saveTTSCustomModel(_:for:)` (reusing the STT `sanitizeModelTag`
    /// allowlist). DISTINCT from `customTTSModel` (the BYO endpoint's required
    /// `tts.custom.model`). Non-secret → App Groups + iCloud KVS. Apple is
    /// withheld at the UI (`.inProcess` sentinel — no wire model).
    var ttsCustomModels: [String: String] = [:]

    /// Transient "Speak a sample" preview state per TTS provider id. `.checking`
    /// while the sample is fetched + played, `.valid` on success, `.invalid` on
    /// failure. Kept separate from any persisted state (preview is ephemeral).
    var ttsPreviewStates: [String: KeyValidationState] = [:]

    // MARK: - Remote Agent (Personal AI) — Custom gateways (ref-keyed)

    // Custom-gateways: the per-backend dicts are re-keyed from
    // `RemoteAgentBackend` to `RemoteAgentRef` so a row can be EITHER a
    // built-in (OpenClaw / Hermes) OR a user-defined custom gateway (keyed by
    // UUID). The built-in two rows route exactly as before (a built-in ref's
    // `rawString` == its `RemoteAgentBackend.rawValue`); customs add up to
    // `Constants.maxCustomGateways` more. The Settings "Personal AI" screen
    // renders a gateway LIST (master) → per-ref detail, mirroring
    // `STTProviderListView`.

    /// In-flight / failure validation state per ref. Keys absent from
    /// this dict resolve to `.unset`. Mirrors STT `keyStates`. Every probe
    /// outcome lands here, including a rejected certificate — see
    /// `validateAndSaveRemoteAgent`.
    var remoteAgentValidationStates: [RemoteAgentRef: KeyValidationState] = [:]

    /// Masked tail of each ref's persisted token (e.g. `"••••••••AB12"`).
    /// Populated in `loadRemoteAgentState()` from token PRESENCE only — the
    /// raw token is NEVER read back into the View (privacy invariant; the
    /// Test/Save path requires the token re-entered). Mirrors STT
    /// `maskedTails`. Nil-absent = no token stored for that ref.
    var remoteAgentMaskedTails: [RemoteAgentRef: String] = [:]

    /// Editable URL string buffer per ref, for the URL `TextField`.
    /// Persisted via `SettingsManager.setRemoteAgentURL(_:for:)` only on a
    /// successful `validateAndSaveRemoteAgent(...)`; the buffer floats freely
    /// while the user types. Missing key = empty string.
    var remoteAgentURLStrings: [RemoteAgentRef: String] = [:]

    /// Editable MODEL string buffer per ref (custom gateways only). Sent as
    /// the `"model"` field; empty → omit (gateway default, identical to
    /// built-ins). Built-ins never surface this field. Missing key = empty.
    var remoteAgentModelStrings: [RemoteAgentRef: String] = [:]

    /// Editable cert-fingerprint pin per ref (lowercase hex). Missing key = no
    /// pin. A pin is an ADDITIONAL restriction on a chain the system already
    /// accepted — it narrows what connects, it can never rescue an untrusted
    /// certificate.
    var remoteAgentCertFingerprints: [RemoteAgentRef: String] = [:]

    /// Editable auth-scheme buffer per ref — `.bearer` (token required) or
    /// `.none` (keyless). Seeded from storage on load (default `.bearer`); the
    /// editor's authentication toggle writes it via `setRemoteAgentAuthSchemeBuffer`.
    /// Drives whether the token field is shown + whether Save/Test require a
    /// token. Missing key = `.bearer` (fail closed).
    var remoteAgentAuthSchemes: [RemoteAgentRef: RemoteAgentAuthScheme] = [:]

    /// Snapshot of which refs currently have a COMPLETE config
    /// (token AND URL — Decision E). Mirrors STT `storedPresetIDs`.
    /// Reloaded after every save / clear so the list re-renders without
    /// blocking on `SettingsManager` actor hops mid-render.
    var configuredRemoteAgentRefSet: Set<RemoteAgentRef> = []

    /// Snapshot of refs whose setup was STARTED here but can't be used as it
    /// stands — a URL that synced in while its token did not, a required model
    /// that hasn't landed, a malformed saved URL. Drives the Personal AI list's
    /// "Needs setup" mark.
    ///
    /// Disjoint from `configuredRemoteAgentRefSet` by construction: both are
    /// projected from ONE `remoteAgentInventory()` snapshot, so no gateway can
    /// read as usable and half-finished at the same time.
    var incompleteRemoteAgentRefSet: Set<RemoteAgentRef> = []

    /// Snapshot of refs holding anything Forget would erase — what the editor's
    /// destructive section keys on.
    ///
    /// Deliberately WIDER than `incompleteRemoteAgentRefSet`: auxiliary residue
    /// is worth offering to remove without claiming the gateway is broken. The
    /// direction that matters is the other one — every incomplete ref is
    /// removable, so a Diagnostics row that says "go remove it" always finds a
    /// Forget button waiting. Gating Forget on CONFIGURED alone left exactly that
    /// state unreachable: the row said "fix this in Settings" and Settings
    /// offered no way to.
    var removableRemoteAgentRefSet: Set<RemoteAgentRef> = []

    /// Whether the first `loadRemoteAgentState()` has completed. The Personal AI
    /// screen's empty-state hero is gated on this: `configuredRemoteAgentRefSet`
    /// starts empty and hydrates asynchronously, so a returning user with a
    /// configured gateway would briefly flash the "no gateway" hero if we
    /// branched on emptiness alone. Show neither hero nor list until loaded.
    var hasLoadedRemoteAgentState: Bool = false

    /// How many times each ref's config has been COMMITTED, bumped once per
    /// successful `saveRemoteAgent`. A monotonic receipt, not a state mirror:
    /// its only claim is "a commit for this ref happened", which is exactly what
    /// an editor needs to learn that a child flow (pairing import, guided hosted
    /// setup) saved underneath it and its own baselines are now stale.
    ///
    /// It exists because `configuredRemoteAgentRefSet` cannot answer that
    /// question. That set is a CACHE of storage, refreshed by an incremental
    /// `loadRemoteAgentState` that can interleave with a save — so a reader can
    /// see `false` for a gateway that was just committed, and an editor gated on
    /// it silently skips its post-import recovery. A counter that only ever
    /// increases has no stale value to read: a bump the editor missed is still
    /// visible in the comparison, whatever order the loads landed in.
    ///
    /// Bumped on EVERY commit path, not just imports — the guided cover also
    /// hosts hosted-model setup, which saves through the same method.
    var remoteAgentCommitEpoch: [RemoteAgentRef: Int] = [:]

    /// Refs whose config passed a LIVE Test Connection this session (session-
    /// scoped; starts empty each launch). Lets the redesigned editor's configured
    /// status row tell "Connected" (a live probe actually succeeded) apart from
    /// "Saved" (config persisted but never verified — `saveRemoteAgent` marks the
    /// validation state `.valid` WITHOUT a probe, which would otherwise overclaim
    /// "Connected"). Inserted on a validate/retest success; removed on save
    /// (save ≠ verify) and clear.
    var remoteAgentLiveValidated: Set<RemoteAgentRef> = []

    /// Refs whose last passing probe answered CORRECTLY but advertised ZERO
    /// models (`TestConnectionOutcome.okNoModels`). Connected, but with a caveat
    /// worth saying out loud: the gateway is reachable and the credentials work,
    /// yet a send may still fail for want of a model. Not a failure (nothing is
    /// misconfigured on this side), so the ref stays live-validated — this is the
    /// footnote the editor hangs off the green row. Session-scoped, cleared in
    /// lockstep with `remoteAgentLiveValidated`.
    var remoteAgentProbeReportedNoModels: Set<RemoteAgentRef> = []

    /// The `AppError.errorCode` of a ref's LAST failed probe — the error's
    /// IDENTITY, kept alongside the human message in `remoteAgentValidationStates`.
    ///
    /// Why both: `.invalid(message:)` carries only a rendered String, so a view
    /// receiving it cannot tell WHICH failure occurred and therefore cannot offer
    /// a failure-specific remedy (e.g. "OpenClaw's chat endpoint is off — here's
    /// the flag"). The code is the machine-readable half. Session-scoped, and
    /// cleared in lockstep with `remoteAgentLiveValidated` — on every probe start,
    /// on success, and on any user edit — so a stale code can never drive a
    /// remedy for a failure the user has already moved past.
    var remoteAgentLastErrorCodes: [RemoteAgentRef: Int] = [:]

    /// The default ref a freshly-minted conversation binds to. Mirrors
    /// STT `activePresetID`. Drives the "Default" pill + the picker.
    var defaultRemoteAgentRef: RemoteAgentRef = .builtin(Constants.remoteAgentDefaultBackendDefault)

    /// The Watch-specific default override, or `nil` = "Follow iPhone". Drives
    /// the iPhone-hosted Apple Watch default-gateway control (the Watch keeps no
    /// settings UI of its own). App-Group-LOCAL on the iPhone (never KVS) —
    /// `SettingsManager.watchDefaultOverrideRef()` owns the storage + self-heal.
    var watchDefaultOverrideRef: RemoteAgentRef?

    /// The Watch-specific `SessionContinuationPolicy` override, or `nil` = "Follow
    /// iPhone". Drives the iPhone-hosted Apple Watch "Add to last conversation"
    /// control. App-Group-LOCAL on the iPhone (never KVS) —
    /// `SettingsManager.watchSessionContinuationPolicyOverride()` owns storage.
    var watchSessionPolicyOverride: SessionContinuationPolicy?

    /// Cached custom-gateway roster (App-Group + iCloud-KVS, hydrated in
    /// `loadRemoteAgentState()`). Cached on the VM so `personalAIRows`,
    /// `customGatewayCount`, badge labels, and the per-conversation pickers
    /// resolve WITHOUT an actor hop inside a SwiftUI `body`. Includes any
    /// in-memory draft minted by `newCustomGatewayDraftID()` (a draft that's
    /// never saved is dropped on the next reload).
    private(set) var customGateways: [CustomGateway] = []

    /// Model IDs discovered from a ref's last Test Connection (`/v1/models`),
    /// surfaced as a tappable suggestion list in the custom editor's Model
    /// field. Empty/absent → no list (free-text only); the field degrades
    /// silently when the gateway doesn't implement `/v1/models` or returns an
    /// unfamiliar shape. Populated by `setRemoteAgentModelSuggestions(_:for:)`.
    var remoteAgentModelSuggestions: [RemoteAgentRef: [String]] = [:]

    /// Per-ref generation counter for the async model-discovery `Task`. Bumped
    /// at each Test Connection; a discovery write is dropped unless its captured
    /// generation still matches — prevents a slow earlier probe from clobbering
    /// newer suggestions (the unstructured-Task overwrite race).
    private var remoteAgentModelDiscoveryGenerations: [RemoteAgentRef: Int] = [:]

    /// Per-ref generation counter for the CONFIG a probe was launched against.
    /// Bumped by every user edit to a probed field (URL / token / auth scheme /
    /// cert pin), by a reload that moves those buffers, and at every probe start.
    ///
    /// Why: `validateRemoteAgent` suspends across the network, and applies its
    /// verdict (buffer write-back, `.valid`/`.invalid`, live mark, error code)
    /// long after. A user who edits the URL mid-flight would otherwise get the
    /// OLD probe's stale URL written back over their typing AND a green mark for
    /// a config that was never tested. Each probe captures its generation before
    /// the `await` and applies NOTHING once it no longer matches.
    private var remoteAgentValidationGenerations: [RemoteAgentRef: Int] = [:]

    /// Generation of the most recently STARTED probe per ref. Lets a superseded
    /// probe tell "an edit overtook me" (nothing else is in flight → it must
    /// release the `.checking` spinner it left behind) from "a newer probe
    /// overtook me" (that probe owns the state — touch nothing).
    private var remoteAgentActiveProbeGenerations: [RemoteAgentRef: Int] = [:]

    // MARK: - File Transfer (Agent File Transfer / file-server) — ref-keyed
    //
    // Per-ref file-server config, the mirror of the remote-agent dicts above.
    // A ref's file-server is the user-run `rclone serve webdav` endpoint the
    // agent's tools read uploaded files from; the setup guide
    // (`FileTransferSetupGuideView`) drives all of these. Like the gateway
    // token, the config is bound to the SPECIFIC ref being edited (per-ref
    // storage suffix). Privacy: the minted credential NEVER enters observable
    // state as plaintext — only `fileServerCredentialPresent` (a bool) and the
    // freshly-minted value RETURNED by `regenerateFileServerCredential` (which
    // the guide shows in its masked, session-only credential row) ever leave
    // Keychain.

    /// Editable file-server URL string buffer per ref, for the URL `TextField`.
    /// Persisted via `SettingsManager.setFileServerURL(_:for:)` only on a
    /// successful `validateAndSaveFileTransferConfig(...)`; floats freely while
    /// the user types. Missing key = empty string. Mirrors
    /// `remoteAgentURLStrings`.
    var fileServerURLStrings: [RemoteAgentRef: String] = [:]

    /// Whether a ref currently has a client-minted credential in Keychain.
    /// Derived from PRESENCE only — the raw secret is NEVER read back into the
    /// View (privacy invariant). Drives the "Regenerate" vs "Generate"
    /// affordance.
    var fileServerCredentialPresent: [RemoteAgentRef: Bool] = [:]

    /// Whether a ref has a PERSISTED file-server URL (not merely a typed buffer).
    /// The setup-state derivation reads THIS, not `fileServerURLStrings` — a URL
    /// the user typed but never saved must not read as "saved" (it vanishes on
    /// relaunch). Set true where the URL actually persists (save / pairing import /
    /// hydration), false on Forget. Mirror of `fileServerCredentialPresent`.
    var fileServerURLPresent: [RemoteAgentRef: Bool] = [:]

    /// Editable file-server cert-fingerprint pin per ref (lowercase hex).
    /// Missing key = no pin (system / ATS trust). Mirrors
    /// `remoteAgentCertFingerprints`.
    var fileServerCertFingerprints: [RemoteAgentRef: String] = [:]

    /// Whether the staged Test Connection has FULLY passed for a ref (set true
    /// ONLY on a full reachability→auth→write→read pass — Decision C). Drives
    /// the "File transfer: Ready / Not set up" status line on the gateway pill /
    /// detail. Mirrors the gateway `configuredRemoteAgentRefSet` posture, but is
    /// a pass-flag, not a config-presence flag.
    var fileTransferAvailableRefSet: Set<RemoteAgentRef> = []

    /// Refs whose PERSISTED file-server verdict says the server cannot list a
    /// collection — the upload-only lanes. Membership is a NARROWING recorded
    /// only from a structural `405`/`501` at the staged test's listing stage, so
    /// an absent stored value (every install that predates the key) is NOT a
    /// member.
    ///
    /// Persisted rather than read off `fileTransferTestResults`, because that
    /// dict is session-scoped: the user tested plain nginx, correctly saw
    /// "uploads only", quit, reopened Settings — and the badge went green,
    /// asserting files could come back on a server that had just told us they
    /// cannot. A verdict the user is shown must survive the process that
    /// measured it.
    var fileTransferUploadOnlyRefSet: Set<RemoteAgentRef> = []

    /// Per-ref image-history policy (Recent / Extended / All). Backs the
    /// "Image history" picker in the gateway editor's Advanced section —
    /// gateway-scoped, NOT file-server-scoped (a server-less custom endpoint
    /// needs it too), hence alongside the gateway dicts rather than the
    /// file-server ones. Hydrated in `loadRemoteAgentState` (mirrors
    /// `remoteAgentAuthSchemes`); the picker writes via
    /// `setImageHistoryPolicy(_:for:)`. Missing key = `.default` (`.recent`).
    var imageHistoryPolicies: [RemoteAgentRef: ImageHistoryPolicy] = [:]

    /// Validation / failure state for the file-server URL field per ref. Mirrors
    /// `remoteAgentValidationStates`: `.invalid` written on the https-only
    /// rejection so macOS (no banner) still surfaces an error rather than a
    /// silent dead-end. `.checking` is unused (the URL save is synchronous-ish);
    /// the staged Test Connection has its own richer result surface below.
    var fileServerValidationStates: [RemoteAgentRef: KeyValidationState] = [:]

    /// Per-ref staged Test Connection result (reachability → auth → write →
    /// read). Published so `FileTransferSetupGuideView` renders the per-stage
    /// checklist. Absent = test never run this session. Set by
    /// `runFileTransferTest(for:)`.
    var fileTransferTestResults: [RemoteAgentRef: FileTransferTestResult] = [:]

    /// The exact input tuple `fileTransferTestResults[ref]` was earned against.
    /// A verdict only DISPLAYS in the editor (and only carries into a Save)
    /// while the current draft still matches this signature — editing the URL,
    /// the pin, or rotating the credential silently orphans the verdict rather
    /// than letting it describe a config it never probed.
    var fileTransferTestSignatures: [RemoteAgentRef: FileTransferTestSignature] = [:]

    /// Per-ref credential generation, bumped on every successful credential
    /// write (regenerate / pairing import). Part of `FileTransferTestSignature`,
    /// so a verdict earned against the OLD password can never resurrect after a
    /// rotation — without the plaintext ever entering the signature.
    var fileServerCredentialGenerations: [RemoteAgentRef: Int] = [:]

    /// PERSISTED file-server URL mirror (canonical absoluteString; "" = none).
    /// The buffer `fileServerURLStrings` floats with edits; THIS tracks what the
    /// store actually holds — the baseline for dirty detection, discard revert,
    /// and the saved-tuple signature. Hydrated at load, updated at save /
    /// pairing import / Forget.
    var fileServerPersistedURLStrings: [RemoteAgentRef: String] = [:]

    /// PERSISTED file-server cert-pin mirror (lowercase hex; "" = system trust).
    /// Same role as `fileServerPersistedURLStrings` for the pin buffer.
    var fileServerPersistedPins: [RemoteAgentRef: String] = [:]

    /// `true` while a `runFileTransferTest(for:)` is in flight for a ref, so the
    /// guide can disable the button + show a spinner (the staged
    /// `FileTransferTestResult` has no `.running` stage of its own — it is the
    /// FINAL outcome only).
    var fileTransferTestRunning: Set<RemoteAgentRef> = []

    /// The most-recently-minted file-server credential, keyed by ref, held ONLY
    /// for the lifetime of the open setup guide so its masked credential row can
    /// reveal the real password the user is about to copy. NOT persisted as
    /// observable truth (Keychain is the store); cleared on guide dismiss via
    /// `forgetMintedFileServerCredential(for:)`. Privacy: this is the ONE
    /// in-memory plaintext surface, and it exists solely for that deliberate
    /// reveal/copy — it is never logged.
    var mintedFileServerCredentials: [RemoteAgentRef: String] = [:]

    // MARK: - Custom voice endpoints (BYO) — Phase B
    //
    // Multiple user-named custom endpoints (`custom-openai_<uuid>` presets),
    // cloned from the per-backend remote-agent shape — every editable field is
    // now keyed by the endpoint `UUID` (the broadest mechanical change in
    // Phase B). The roster of `{id, name}` records is cached in
    // `customVoiceEndpoints`; an in-memory draft is appended by
    // `newCustomVoiceEndpointDraftID()` and dropped on the next reload if never
    // saved. Mirrors how the gateway state is keyed by `RemoteAgentRef`.

    /// Cached roster (id / name) for the merged Voice library + per-uuid editor.
    /// Hydrated alongside `customGateways`. Drives `vendors(customEndpoints:)`,
    /// the "+ Add custom endpoint" cap gate, and the name-clash check. Writable
    /// (not `private(set)`) so the editor's in-memory draft/rename + the test
    /// seams can mutate it; the durable source of truth is the roster JSON.
    var customVoiceEndpoints: [CustomVoiceEndpoint] = []

    /// Per-uuid validation / failure state for the endpoint config screen.
    /// Mirrors `remoteAgentValidationStates[ref]` — every probe outcome lands
    /// here, including a rejected certificate.
    var customSTTValidationStates: [UUID: KeyValidationState] = [:]

    /// Per-uuid editable base-URL string buffer for the URL `TextField`.
    /// Persisted only on a successful save; floats while the user types.
    var customSTTURLStrings: [UUID: String] = [:]

    /// Per-uuid editable cert-fingerprint pin (lowercase hex). Empty = no pin.
    /// Like the gateway's, it only narrows a chain the system already accepted.
    var customSTTCertFingerprints: [UUID: String] = [:]

    /// Per-uuid editable STT model override (default `whisper-1`).
    var customSTTModels: [UUID: String] = [:]

    /// Per-uuid editable TEXT-TO-SPEECH model (default `tts-1`). Distinct from
    /// `customSTTModels` — the same BYO server usually exposes different STT vs
    /// TTS model tags. URL/key/cert/auth are SHARED with STT (one server).
    var customTTSModels: [UUID: String] = [:]

    /// Per-uuid effective auth scheme: `.bearer` (key required) or `.none`
    /// (keyless local server — key field optional, missing-key guard skipped).
    var customSTTAuthSchemes: [UUID: STTAuthScheme] = [:]

    /// Per-uuid masked tail of the persisted key (e.g. `"••••XK4q"`). Derived
    /// from key PRESENCE only — the raw key is NEVER read back into the View
    /// (privacy invariant). Nil = no key stored (or `.none` auth).
    var customSTTMaskedTails: [UUID: String] = [:]

    /// Per-uuid staging buffer for the custom editor's `pendingTTSVoice` @State
    /// field. The View stashes it here just before calling `saveCustomVoiceEndpoint`
    /// (the VM can't read the View's @State), so Save persists the typed voice.
    /// Buffer-until-Save: nothing here reaches storage until the explicit commit.
    /// Cleared on Save / Cancel. Not Observation-relevant for the list (private use).
    private var stagedCustomTTSVoices: [UUID: String] = [:]

    /// "New conversation" session-continuation policy (Part A). Decides
    /// whether a headless quick capture (iOS Action Button, Apple Watch,
    /// macOS menu bar) continues the most-recent conversation or mints a
    /// fresh one. Default applied by `SettingsManager.getSessionContinuationPolicy()`
    /// (`.minutes30`); persisted to App Groups + iCloud KVS so the Watch
    /// resolver sees the same choice.
    var sessionContinuationPolicy: SessionContinuationPolicy = .default

    /// Cold-launch landing preference. Default `.startNewConversation` applied
    /// by `SettingsManager.getOnLaunchMode()`. Persisted to App Groups + iCloud
    /// KVS so the choice rides across the user's devices.
    var onLaunchMode: OnLaunchMode = .default

    // MARK: - Active-TTS key readiness (convergence UX)

    /// SECRET-FREE probe of the active TTS provider's device-local key
    /// availability — drives the Voice screen's key-readiness banner. Nil
    /// until the first refresh lands. Refreshed OUTSIDE the dirty-editor
    /// fence (see the `.settingsDidChangeRemotely` observer): the probe
    /// touches no editor buffer, and the banner must clear the moment a
    /// synced key arrives even mid-edit.
    var activeTTSKeyProbe: ActiveTTSKeyProbe?

    /// Check Again in-flight flag — disables the banner button while a manual
    /// recheck runs.
    var isRecheckingTTSKey = false

    /// Stale-refresh guard: a slow probe for provider A must not overwrite
    /// the banner after the user switched to provider B (each refresh bumps
    /// the generation; only the newest write wins).
    @ObservationIgnored private var ttsKeyProbeGeneration = 0

    /// Re-read the active-TTS key probe (one secret-free actor hop).
    func refreshActiveTTSKeyProbe() async {
        ttsKeyProbeGeneration += 1
        let generation = ttsKeyProbeGeneration
        let probe = await SettingsManager.shared.activeTTSKeyProbe()
        guard generation == ttsKeyProbeGeneration else { return }
        activeTTSKeyProbe = probe
    }

    /// The banner's "Check Again": one manual probe refresh, then re-arm the
    /// bounded arrival monitor (a still-missing key deserves a fresh poll
    /// window — the user just told us they expect it to appear).
    func recheckActiveTTSKey() async {
        guard !isRecheckingTTSKey else { return }
        isRecheckingTTSKey = true
        defer { isRecheckingTTSKey = false }
        await refreshActiveTTSKeyProbe()
        await TTSKeyArrivalMonitor.shared.evaluate(reason: .manual)
    }

    // MARK: - Feedback Sheet

    var showingMailComposer = false

    // MARK: - Initialization

    init() {
        Task {
            await loadSettings()
        }
        NotificationCenter.default.addObserver(
            forName: .settingsDidChangeRemotely,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Key-readiness probe refreshes UNFENCED: it binds to no editor
                // buffer, and the banner must clear the instant a synced key
                // arrives even while an editor is dirty (the arrival monitor's
                // post is exactly this notification).
                await self.refreshActiveTTSKeyProbe()
                // FENCE: never reload buffered fields out from under an open editor.
                // `loadRemoteAgentState()` / `loadCustomSTTState()` rebuild the URL /
                // model / cert dicts the editor's TextFields bind to, so a reload
                // mid-edit (a remote iCloud-KVS sync, or a local write-on-change
                // control like the image-history picker that posts this same
                // notification) would silently revert the user's typing. Defer it;
                // `drainDeferredReloadIfCleared` runs it when the last dirty editor
                // closes or goes clean.
                if self.editorHasUnsavedChanges {
                    self.pendingRemoteReload = true
                } else {
                    await self.loadSettings()
                }
            }
        }
    }

    // MARK: - Settings Management

    /// Pull current values from `SettingsManager` actor into observable state.
    /// Reloads the stored-preset snapshot + active-preset ID + preferred
    /// language. Does NOT touch `keyStates` (those are owned by per-row
    /// interactions and don't survive a remote-change reload).
    func loadSettings() async {
        isLoading = true
        defer { isLoading = false }

        preferredLanguage = await SettingsManager.shared.getPreferredLanguage()
        appleOnDeviceEngineMode = await SettingsManager.shared.getAppleOnDeviceEngineMode()
        activePresetID = await SettingsManager.shared.getActivePresetID()
        storedPresetIDs = await SettingsManager.shared.presetIDsWithStoredKey()
        await refreshMaskedTails()
        await refreshCustomModels()
        // Cloud TTS — load the active TTS provider + per-provider voice overrides
        // so the merged "Voice" rows render without a per-body actor hop.
        activeTTSProviderID = await SettingsManager.shared.getActiveTTSProviderID()
        await refreshTTSVoices()
        await refreshTTSCustomModels()
        await refreshActiveTTSKeyProbe()
        await loadCustomSTTState()
        await loadRemoteAgentState()
    }

    /// Suspend until the remote-agent snapshot has hydrated
    /// (`hasLoadedRemoteAgentState`). Before hydration `hasAnyConfiguredRemoteAgent`
    /// reads `false` for everyone, so the empty-state auto-open latch awaits this
    /// first — otherwise it could misclassify a configured user as unconfigured.
    /// Cheap: hydration is a one-shot early task, so this returns immediately in
    /// the common case (the stable host VM is loaded well before Settings opens).
    func awaitRemoteAgentStateLoaded() async {
        while !hasLoadedRemoteAgentState {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
    }

    /// Refresh `maskedTails` from `SettingsManager`. One actor hop per
    /// preset (5 today). Called after `loadSettings`, `validateAndSave`
    /// (success), and `clearKey`. View body never enters Keychain.
    private func refreshMaskedTails() async {
        var next: [String: String] = [:]
        for entry in STTProviderRegistry.all {
            if let key = await SettingsManager.shared.getAPIKey(forPresetID: entry.id),
               !key.isEmpty {
                next[entry.id] = maskedTail(key)
            }
        }
        maskedTails = next
    }

    /// Refresh `customModels` from `SettingsManager` (Feature 1). One actor hop
    /// per preset (mirrors `refreshMaskedTails`). Empty / absent overrides are
    /// omitted so the View's binding falls back to the placeholder default.
    /// Called after `loadSettings` and after `saveCustomModel`.
    private func refreshCustomModels() async {
        var next: [String: String] = [:]
        for entry in STTProviderRegistry.all {
            if let model = await SettingsManager.shared.getCustomModel(forPresetID: entry.id),
               !model.isEmpty {
                next[entry.id] = model
            }
        }
        customModels = next
    }

    /// Persist a per-preset custom model override (Feature 1). Sanitizes the
    /// candidate to `^[A-Za-z0-9._-]+$` BEFORE storage — this prevents Gemini
    /// URL-path injection (the model lives in the URL path there) and is
    /// applied uniformly for symmetry. An empty / fully-stripped candidate
    /// clears the override (the provider's pinned default applies). Refreshes
    /// `customModels` so the row re-renders without a Keychain/KVS round-trip.
    func saveCustomModel(_ model: String, for presetID: String) async {
        // Body-model providers (OpenRouter et al.) keep `/`; URL-path models
        // (Gemini) strip it — see `sanitizeModelTag` / `STTProvider.modelInURL`.
        let sanitized = Self.sanitizeModelTag(model, allowsSlash: !STTProvider.lookup(id: presetID).modelInURL)
        await SettingsManager.shared.setCustomModel(sanitized.isEmpty ? nil : sanitized,
                                                    forPresetID: presetID)
        await refreshCustomModels()
    }

    /// Strip everything outside `^[A-Za-z0-9._-]+$` (plus `/` when `allowsSlash`)
    /// from a model tag. Defensive against URL-path injection + whitespace.
    /// Returns "" when the candidate is empty after trimming/stripping (= clear
    /// the override). Pure + static so the test suite can drive it without an
    /// actor hop.
    ///
    /// `allowsSlash` is load-bearing: a model that rides the URL PATH (Gemini's
    /// `…/models/<model>:generateContent`) MUST strip `/` (default — the
    /// path-injection guard); a model that rides the request BODY (OpenRouter,
    /// the OpenAI/Mistral families, custom endpoints) may KEEP it — OpenRouter
    /// IDs like `openai/whisper-large-v3` REQUIRE the slash. Callers pass
    /// `allowsSlash: !provider.modelInURL`.
    static func sanitizeModelTag(_ raw: String, allowsSlash: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
            + (allowsSlash ? "/" : ""))
        let filtered = trimmed.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    // MARK: - Active provider metadata (for provider-aware copy elsewhere)

    /// Display metadata for whichever preset is currently active. Used by
    /// `SettingsView` to render provider-aware copy in the Language section
    /// footer ("…unless ElevenLabs keeps guessing wrong"). Falls back to the
    /// V1 default when KVS carries an unknown ID (forward-compat).
    var activeProviderMetadata: STTProviderMetadata {
        STTProviderRegistry.lookup(id: activePresetID) ?? STTProviderRegistry.mistralVoxtral
    }

    // MARK: - Preferred Language

    /// Persist a new preferred language hint. Pass `nil` for auto-detect.
    func savePreferredLanguage(_ languageCode: String?) async {
        preferredLanguage = languageCode
        await SettingsManager.shared.setPreferredLanguage(languageCode)
        // Keep the Apple model target (`appleTargetKey` + state) in lockstep
        // with the language knob, so readiness (`isProviderReady`) never lags
        // a language change made via the Settings language picker. No-op on
        // watchOS (the body is `#if !os(watchOS)`-gated).
        await checkAppleModelStatus()
        #if !os(watchOS)
        // The Standard target moved with the language — re-prepare it (target-aware
        // + generation-guarded) so the new language's model is ready and the
        // Standard row can't show a stale "Ready" for the previous language. Only
        // when Apple on-device is the active STT provider.
        if await SettingsManager.shared.getActiveSTTProvider().transport == .inProcess {
            await prepareStandardEngine()
        }
        #endif
    }

    // MARK: - Per-Preset API Key Validation + Save

    /// Validate `key` against the given provider's auth endpoint and, on
    /// success, persist it to Keychain at `stt.apiKey.<presetID>`. Surfaces
    /// a provider-aware error message via `keyStates[presetID]` on failure.
    ///
    /// Privacy: the raw key never leaves this method — no log, no print,
    /// no state retention past the save.
    func validateAndSave(key: String, for presetID: String) async {
        let metadata = STTProviderRegistry.lookup(id: presetID) ?? STTProviderRegistry.mistralVoxtral
        let providerName = metadata.displayName

        // Apple on-device branch. No Keychain write — the
        // "key" is the TCC Speech-Recognition authorization. We fire the
        // request, observe the result, and (on `.authorized`) flip this
        // preset to active so the row jumps to `.storedActive`.
        if presetID == "apple-on-device" {
            keyStates[presetID] = .checking
            do {
                let provider = STTProvider.lookup(id: presetID)
                try await STTClient.shared.headProbe(apiKey: "", provider: provider)
                // TCC granted (or already granted) — flip active + refresh.
                await SettingsManager.shared.setActivePresetID(presetID)
                activePresetID = presetID
                storedPresetIDs = await SettingsManager.shared.presetIDsWithStoredKey()
                keyStates[presetID] = .valid
                #if !os(watchOS)
                // Apple is now the active provider AND Speech Recognition is
                // authorized (headProbe succeeded) — proactively warm the Standard
                // model so the first mic tap / CarPlay / Shortcut isn't a cold race.
                // Fire-and-forget: never block the activation return.
                Task { await prepareStandardEngine() }
                #endif
            } catch {
                // headProbe maps TCC `.denied` / `.restricted` /
                // `.notDetermined` to `AppError.sttAuthFailed`. Surface
                // the Settings-app recovery path explicitly.
                keyStates[presetID] = .invalid(
                    message: String(localized: "Speech recognition denied. Enable in Settings → Conduck → Speech Recognition.")
                )
            }
            return
        }

        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            keyStates[presetID] = .invalid(
                message: String(localized: "Paste your \(providerName) key.")
            )
            return
        }

        keyStates[presetID] = .checking

        do {
            let provider = STTProvider.lookup(id: presetID)
            try await STTClient.shared.headProbe(apiKey: candidate, provider: provider)
            try await SettingsManager.shared.setAPIKey(candidate, forPresetID: presetID)
            // Refresh the stored-preset snapshot so this row flips from
            // `.empty` → `.storedInactive` (or `.storedActive` if it was
            // already the active preset).
            storedPresetIDs = await SettingsManager.shared.presetIDsWithStoredKey()
            // Cache the masked tail so the row renders without re-reading
            // Keychain.
            maskedTails[presetID] = maskedTail(candidate)
            keyStates[presetID] = .valid
        } catch let error as AppError {
            keyStates[presetID] = .invalid(message: friendlyMessage(for: error, providerName: providerName))
        } catch {
            keyStates[presetID] = .invalid(message: String(localized: "Unexpected error. Try again."))
        }
    }

    /// Map AppError → user-facing message with provider-name substitution.
    /// Kept private so call sites can't accidentally leak the raw key by
    /// passing it as an interpolation arg.
    ///
    /// All three certificate verdicts are named explicitly rather than left to
    /// `default:` — "Unexpected error. Try again." invites a retry that can only
    /// fail again, and none of the three refusals is something a second tap can
    /// change.
    private func friendlyMessage(for error: AppError, providerName: String) -> String {
        switch error {
        case .sttAuthFailed:
            return String(localized: "Invalid key.")
        case .sttProviderUnreachable, .noInternetConnection, .networkError, .requestTimeout:
            return String(localized: "Can't reach \(providerName). Check connection.")
        case .sttServerError:
            return String(localized: "\(providerName) is having issues. Try again in a moment.")
        case .sttCustomCertUntrusted:
            // The shared refusal + remedy, verbatim — the same words the gateway
            // editor and the voice-endpoint test suite render. `providerName` is
            // deliberately unused: the fix is on the server, so it cannot differ
            // by provider, and a paraphrase here would read as a second problem.
            return CertificateTrustCopy.untrustedRefusalWithRemedy
        case .sttCustomCertMismatch:
            // A DIFFERENT failure from the one above, with its own shared words:
            // the device DID trust the chain and only the pinned key disagreed.
            // Never folded into the refusal — this one can mean an intercepted
            // connection, so it says so, and it never suggests dropping the pin,
            // which would trade the warning for silence.
            return CertificateTrustCopy.pinMismatchRefusalWithRemedy
        case .sttCustomCertKeyUnpinnable:
            // A THIRD failure, not a shade of either: system trust already
            // passed, so nothing is untrusted and nothing disagreed — Conduck
            // just can't hash this key algorithm. Borrowing the mismatch words
            // would raise an interception warning over a good certificate.
            return CertificateTrustCopy.keyUnpinnableRefusalWithRemedy
        default:
            // The catch-all answers for every verdict nobody enumerated above,
            // so it asks the taxonomy instead of assuming. "Try again." is right
            // for the retryable remainder (a transport blip, an HTTP code nobody
            // specialised) and a promise the request cannot keep on anything
            // terminal — and the arms above name only the terminal codes
            // reachable TODAY, so a case added to `AppError` later inherits this
            // arm silently. Same split as
            // `CarPlayRecordingService.speakErrorAndEnd`'s catch-all.
            return error.isRetryable
                ? String(localized: "Unexpected error. Try again.")  // xcstrings
                : String(localized: "Unexpected error. Check your settings.")  // xcstrings
        }
    }

    // MARK: - OpenRouter key cross-reuse (voice ⇄ hosted gateway)

    /// Locked preset id of the OpenRouter VOICE provider (STT side; the TTS
    /// provider shares this key slot). Centralized so the cross-reuse plumbing
    /// and the callout gating never drift from the registry id.
    static let openRouterVoiceSTTPresetID = "openrouter-stt"

    /// True when the OpenRouter hosted-model GATEWAY has a saved key the voice
    /// provider could reuse. OpenRouter's URL is fixed + auth is locked
    /// `.bearer`, so "configured" ⟺ a saved token exists.
    var openRouterGatewayKeyAvailable: Bool {
        configuredRemoteAgentRefSet.contains(.builtin(.openrouter))
    }

    /// True when the OpenRouter VOICE provider has a saved key the gateway could
    /// reuse.
    var openRouterVoiceKeyAvailable: Bool {
        storedPresetIDs.contains(Self.openRouterVoiceSTTPresetID)
    }

    /// Copy the saved OpenRouter GATEWAY token into the OpenRouter VOICE key slot
    /// (validate via the provider probe, then persist — same path as a manual
    /// paste). COPY semantics: the two slots stay INDEPENDENT afterward — a later
    /// rotation of one does NOT sync to the other, and both then draw on the same
    /// OpenRouter credit balance. Runs entirely here; the raw token is never
    /// surfaced to a View. No-op when the gateway has no saved token.
    func reuseGatewayKeyForOpenRouterVoice() async {
        guard let token = await SettingsManager.shared.getRemoteAgentToken(for: .builtin(.openrouter)),
              !token.isEmpty else { return }
        await validateAndSave(key: token, for: Self.openRouterVoiceSTTPresetID)
    }

    /// Resolve a staged token INTENT to the actual credential — the single
    /// Keychain touchpoint for the editor's Save / Test / Trust flows (secrets
    /// resolve here, never in a View). `.reuseVoiceKey` is COPY semantics (see
    /// above): the resolved voice key is persisted into the gateway slot by the
    /// caller; the two Keychain slots stay independent afterward.
    private func resolveStagedToken(_ staged: StagedRemoteAgentToken, for ref: RemoteAgentRef) async -> String? {
        switch staged {
        case .typed(let value):
            return value
        case .stored:
            return await SettingsManager.shared.getRemoteAgentToken(for: ref)
        case .reuseVoiceKey:
            return await SettingsManager.shared.getAPIKey(forPresetID: Self.openRouterVoiceSTTPresetID)
        }
    }

    /// Surfaced when a `.reuseVoiceKey` intent resolves to nothing at commit /
    /// probe time (the voice key was cleared between staging and Save/Test).
    private static var reuseMissingVoiceKeyMessage: String {
        String(localized: "settings.remoteAgent.reuse.missingVoiceKey",
               defaultValue: "The OpenRouter voice key isn't available. Paste an API key instead.")
    }

    // MARK: - Active Preset Switching

    /// Switch the active STT preset. Posts `.settingsDidChangeRemotely` via
    /// `SettingsManager`, which triggers `loadSettings()` → fresh broadcast
    /// envelope to Watch (PhoneSessionManager observer).
    func setActive(_ presetID: String) async {
        await SettingsManager.shared.setActivePresetID(presetID)
        activePresetID = presetID
    }

    // MARK: - Clear

    /// Remove the persisted API key for a single preset, and fall any ACTIVE
    /// pointer that depended on it back to Apple.
    ///
    /// The pointer fallback is the security half, not a convenience. The Watch
    /// holds its OWN copy of every cloud STT key it has ever been broadcast
    /// (non-sync Keychain — iCloud Keychain can't reach it) and routes wrist
    /// captures purely on `activePresetID`, reading the key straight from that
    /// Watch slot at upload time. If the cleared preset stayed active, the phone
    /// would hard-fail with `sttMissingAPIKey` while the WRIST kept uploading
    /// audio to the provider under the very key the user just told Conduck to
    /// forget — indefinitely, with no UI anywhere revealing the divergence.
    /// Falling the pointer back to `apple-on-device` emits a POSITIVE
    /// `presetID: "apple-on-device"` envelope (`currentBroadcastEnvelope`'s
    /// dedicated branch, which exists for exactly this "audio + a stale key to a
    /// deselected provider" hazard), and the wrist re-routes to the iPhone relay
    /// on its next capture. Positive-signal by construction, so it cannot regress
    /// the "never infer keyless from a missing token/key" invariant.
    ///
    /// The TTS pointer gets the same treatment because a cloud TTS provider reads
    /// its key from the vendor's SHARED `stt.apiKey.<presetID>` slot — clearing
    /// the STT half strands the TTS half on a key that no longer exists.
    ///
    /// Mirrors `SettingsManager.deleteCustomVoiceEndpoint`, which already falls
    /// both pointers back to Apple for its own delete. Apple on-device is the
    /// right target rather than "the next configured cloud provider": silently
    /// re-pointing a user's speech at a DIFFERENT third party would be a worse
    /// privacy outcome than the bug being fixed.
    ///
    /// Attached HERE (the user-intent site) and NOT inside
    /// `SettingsManager.clearAPIKey(forPresetID:)`, which is also called when a
    /// custom voice endpoint is saved as `.none`/keyless — that endpoint keeps
    /// working keyless and must NOT be deactivated.
    ///
    /// Residue not covered: the Watch's own copy of the cleared key stays in its
    /// Keychain (dead — nothing routes to it once the pointer moved). Purging
    /// those bytes needs a wire-level signal in `STTBroadcastEnvelope`; see the
    /// security review's follow-up note.
    func clearKey(for presetID: String) async throws {
        try await SettingsManager.shared.clearAPIKey(forPresetID: presetID)

        if await SettingsManager.shared.getActivePresetID() == presetID {
            await setActive(Constants.sttActivePresetIDDefault)
        }
        let activeTTS = await SettingsManager.shared.getActiveTTSProviderID()
        if Self.clearingKeyResetsTTSPointer(activeTTSProviderID: activeTTS, clearedPresetID: presetID) {
            await setActiveTTS(providerID: Constants.ttsActiveProviderIDDefault)
        }

        storedPresetIDs = await SettingsManager.shared.presetIDsWithStoredKey()
        maskedTails.removeValue(forKey: presetID)
        keyStates[presetID] = .unset
    }

    /// Would clearing `clearedPresetID`'s key fall the ACTIVE TTS pointer back
    /// to the Apple voice? True exactly when the active TTS provider reads that
    /// vendor's shared key slot.
    ///
    /// Pure and shared ON PURPOSE: `clearKey(for:)` above decides the fallback
    /// with it, and `ProviderConfigBody`'s confirmation copy decides what to
    /// PROMISE with it. A confirmation that names a consequence the action
    /// doesn't have — or omits one it does — is the user agreeing to something
    /// they were not told, so the two must not be able to drift apart.
    static func clearingKeyResetsTTSPointer(
        activeTTSProviderID: String,
        clearedPresetID: String
    ) -> Bool {
        TTSProvider.lookup(id: activeTTSProviderID).sharedKeySTTPresetID == clearedPresetID
    }

    /// The same question against this view model's cached TTS pointer — what the
    /// Settings UI passes to `ProviderConfigBody` so the Clear-key confirmation
    /// can name the Apple-voice fallback in the one branch where the STT row is
    /// INACTIVE but the TTS pointer still sits on this vendor.
    func clearingKeyResetsActiveTTS(for presetID: String) -> Bool {
        Self.clearingKeyResetsTTSPointer(activeTTSProviderID: activeTTSProviderID,
                                         clearedPresetID: presetID)
    }

    // MARK: - Row-State Derivation

    /// Compute the `ProviderRowState` for a given preset, mixing transient
    /// in-flight state (`.checking` / `.invalid`) with the persistent
    /// stored-key + active-preset truth from `SettingsManager`.
    func rowState(for presetID: String) -> ProviderRowState {
        switch keyStates[presetID] {
        case .checking:
            return .validating
        case .invalid(let message):
            return .invalid(message: message)
        case .valid, .unset, .none:
            break
        }

        guard storedPresetIDs.contains(presetID) else {
            return .empty
        }

        // Stored — render masked tail from the cached snapshot (no
        // Keychain read on render). Falls back to the all-
        // asterisks placeholder if the cache is somehow missing this preset
        // (rare; would indicate a load-order bug — the row stays readable).
        let masked = maskedTails[presetID] ?? "••••••••"
        if presetID == activePresetID {
            return .storedActive(maskedTail: masked)
        }
        return .storedInactive(maskedTail: masked)
    }

    /// Whether a provider is READY to be set active without further config.
    /// Used by the STT provider list (`STTProviderListView`) to decide
    /// whether a row tap flips the active preset (ready) or navigates to the
    /// per-provider detail to configure first (not ready).
    ///   - Cloud providers: ready iff a key is stored.
    ///   - Apple on-device: ready iff the model for the current locale is
    ///     installed. (TCC authorization is requested by `validateAndSave`
    ///     when the user activates — install is the gating prerequisite.)
    func isProviderReady(_ presetID: String) -> Bool {
        if presetID == "apple-on-device" {
            #if os(watchOS)
            return false
            #else
            // Engine-aware readiness, on the CLAMPED engine so a synced
            // `.highQuality` choice on a sub-A16 device reads as the `.dictation`
            // the runner will actually use (never the HQ ledger it can't install).
            // Standard is activatable without a prior download (its model is
            // prepared proactively on activation / first use); the high-quality
            // engine needs its per-language `SpeechTranscriber` model installed
            // (`appleTargetKey` is the canonical key `checkAppleModelStatus` writes).
            if effectiveAppleEngine == .dictation {
                return true
            }
            return appleModelStates[appleTargetKey] == .installed
            #endif
        }
        // Custom endpoint — ready iff a base URL is stored AND (auth `.none`
        // OR a key is stored). A stored key alone (a `presetIDsWithStoredKey`
        // hit) is NOT sufficient — the endpoint needs a URL too. Per-uuid id →
        // per-uuid readiness (Phase B).
        if let uuid = STTProvider.customEndpointUUID(fromPresetID: presetID) {
            return isCustomSTTReady(for: uuid)
        }
        return storedPresetIDs.contains(presetID)
    }

    /// Display name of the currently-active STT provider — drives the
    /// trailing summary on the Settings root "Speech-to-Text" row.
    var activeProviderDisplayName: String {
        activeProviderMetadata.displayName
    }

    // MARK: - Apple Model Lifecycle
    //
    // Per-locale download / install state for `STTProvider.appleOnDevice`.
    // Surfaces in the Settings Apple row via `appleModelStates[locale.identifier]`.
    // All three methods are wrapped in `#if !os(watchOS)` — `AssetInventory`
    // and `SpeechTranscriber` ship no watchOS symbols. Watch surface has its
    // own (audio-relay) path in 6.6.5.
    //
    // PUBLIC API NOTE — uninstall: Apple's iOS 26 `AssetInventory` exposes
    // `status(forModules:)` and `assetInstallationRequest(supporting:)` but
    // NO public `uninstall`/`delete` method (verified against shipping SDK
    // swiftinterface). Per-language assets are managed system-wide by iOS
    // Settings → General → iPhone Storage. The "Delete model" CTA in the
    // Apple row therefore informs the user that asset removal lives in
    // iOS Settings rather than attempting a no-op call.

    /// Query the install status of the Apple on-device model for the current
    /// language target. The target derives from the global `preferredLanguage`
    /// (multilingual, 2026-06): nil → device/English; an explicit non-English
    /// language Apple can't transcribe on-device resolves to `.unsupported`.
    /// Writes `appleTargetKey` (the canonical resolved-locale identifier every
    /// reader uses) + `appleModelStates[appleTargetKey]`.
    func checkAppleModelStatus() async {
        #if !os(watchOS)
        // HIGH-QUALITY engine only — standard dictation needs no downloadable
        // model, so this lifecycle (status / download / progress) serves the
        // `SpeechTranscriber` path exclusively. Resolve against that engine's
        // supported-locale set so the displayed state matches what the engine
        // would actually use.
        switch await AppleSpeechRunner.resolve(preferredLanguage: preferredLanguage, engine: .highQuality) {
        case .unsupported(let requested):
            // Explicit non-English language not in Apple's on-device set.
            // Nothing to download — structural failure; the UI routes to a
            // cloud provider. Non-retryable (a "Try again" would just re-fail).
            appleTargetKey = requested.identifier
            appleModelStates[requested.identifier] = .failed(
                message: String(localized: "Apple Speech doesn't support this language yet."),
                retryable: false
            )
        case .supported(let resolved):
            appleTargetKey = resolved.identifier
            let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
            let status = await AssetInventory.status(forModules: [transcriber])
            switch status {
            case .installed:
                appleModelStates[resolved.identifier] = .installed
            case .downloading:
                // Status alone doesn't expose progress — surface a 0-progress
                // placeholder; the caller's `downloadAppleModel` flow owns the
                // real progress stream via `Progress.fractionCompleted`.
                appleModelStates[resolved.identifier] = .downloading(progress: 0)
            case .supported:
                appleModelStates[resolved.identifier] = .notDownloaded
            case .unsupported:
                // Belt-and-suspenders: the resolver returned `.supported` but
                // AssetInventory disagrees (shouldn't happen for a resolver-
                // blessed locale). Render as non-retryable structural failure.
                appleModelStates[resolved.identifier] = .failed(
                    message: String(localized: "Apple Speech doesn't support this language yet."),
                    retryable: false
                )
            @unknown default:
                appleModelStates[resolved.identifier] = .notDownloaded
            }
        }
        #endif
    }

    /// Download + install the Apple on-device model for the current language
    /// target (derived from the global `preferredLanguage`). Observes the
    /// `AssetInstallationRequest.progress` via KVO and republishes
    /// `.downloading(progress:)` updates into `appleModelStates[appleTargetKey]`.
    /// Terminal state: `.installed` on success, `.failed(message:)` on throw.
    /// On success, reserves the locale + releases the previously-reserved one
    /// (see `reserveAppleLocale`).
    func downloadAppleModel() async {
        #if !os(watchOS)
        let resolved: Locale
        // HIGH-QUALITY engine only (matches `checkAppleModelStatus`) — the
        // download lifecycle exists solely for the `SpeechTranscriber` model.
        switch await AppleSpeechRunner.resolve(preferredLanguage: preferredLanguage, engine: .highQuality) {
        case .unsupported(let requested):
            // Nothing to download — surface the structural failure (the Apple
            // row's "Use a cloud provider" affordance is the forward path).
            appleTargetKey = requested.identifier
            appleModelStates[requested.identifier] = .failed(
                message: String(localized: "Apple Speech doesn't support this language yet."),
                retryable: false
            )
            return
        case .supported(let loc):
            resolved = loc
        }

        let key = resolved.identifier
        appleTargetKey = key
        appleModelStates[key] = .downloading(progress: 0)

        // Generation guard: bump now so a NEWER download (user switched
        // language mid-flight) wins the reserve-swap; this completion's
        // reserve-swap runs only if it's still the latest.
        appleDownloadGeneration &+= 1
        let generation = appleDownloadGeneration

        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)

        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            appleModelStates[key] = .failed(
                message: String(localized: "Couldn't start the download. Check your connection and try again."),
                retryable: true
            )
            return
        }

        guard let request else {
            // Nil request = nothing to install (already on disk per Apple
            // docs). Flip to installed + pin it.
            appleModelStates[key] = .installed
            await reserveAppleLocale(resolved, generation: generation)
            return
        }

        // Observe `Progress.fractionCompleted` via Foundation KVO. The
        // observation token is retained for the duration of the download
        // (the `await` below blocks until install completes or throws).
        // Captured by the closure; deallocated when this method returns.
        let progress = request.progress
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] prog, _ in
            let fraction = prog.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't clobber a terminal state with a late KVO callback.
                if case .downloading = self.appleModelStates[key] {
                    self.appleModelStates[key] = .downloading(progress: fraction)
                }
            }
        }
        defer { observation.invalidate() }

        do {
            try await request.downloadAndInstall()
            appleModelStates[key] = .installed
            await reserveAppleLocale(resolved, generation: generation)
        } catch {
            appleModelStates[key] = .failed(
                message: String(localized: "Download failed. Tap to try again."),
                retryable: true
            )
        }
        #endif
    }

    /// Reserve `locale` so iOS doesn't purge the model under disk pressure
    /// (a purge would silently revert the user to `.notDownloaded`), and
    /// release the PREVIOUS Conduck-reserved locale so we stay within
    /// `maximumReservedLocales` as the user switches languages. App-owned
    /// ledger (`lastReservedAppleLocale`): we only ever release what Conduck
    /// itself recorded reserving — never another OS feature's reservation. The
    /// generation guard drops a stale completion so an older download can't
    /// release the newer choice. Best-effort; never blocks the (already usable)
    /// model.
    private func reserveAppleLocale(_ locale: Locale, generation: Int) async {
        #if !os(watchOS)
        guard generation == appleDownloadGeneration else { return }
        _ = try? await AssetInventory.reserve(locale: locale)
        let previous = await SettingsManager.shared.getLastReservedAppleLocale()
        if let previous, previous != locale.identifier {
            try? await AssetInventory.release(reservedLocale: Locale(identifier: previous))
        }
        await SettingsManager.shared.setLastReservedAppleLocale(locale.identifier)
        #endif
    }

    /// "Manage in iOS Settings" CTA target. Apple ships no public
    /// `AssetInventory` uninstall API in iOS 26 — assets are managed
    /// system-wide by iOS Settings → General → iPhone Storage. The row's
    /// alert deep-links the user to Settings; the actual file removal is
    /// OS-controlled.
    ///
    /// We deliberately do NOT flip `appleModelStates[appleTargetKey]`
    /// to `.notDownloaded` here — that would lie to the UI when the user
    /// dismisses the alert without freeing the model. The sole writer of
    /// state after the alert dismisses is `checkAppleModelStatus`, which
    /// re-queries `AssetInventory` and reflects the actual on-disk truth.
    func clearAppleModelState() {
        // Intentional no-op — state is re-derived by `checkAppleModelStatus`.
        // Kept as the named call site the alert's confirm action binds to, so a
        // future programmatic-uninstall API has one place to land.
    }

    // MARK: - Apple On-Device Engine Mode (dictation ↔ high-quality)

    /// Whether the high-quality on-device engine (`SpeechTranscriber`) is
    /// available on THIS device. Gated by `SpeechTranscriber.isAvailable`
    /// (true only on A16+ hardware). Drives whether the Apple detail surfaces
    /// the "Switch to high-quality" affordance at all. Always `false` on
    /// watchOS (no `Speech` high-quality symbols + downstream-only posture).
    var appleHighQualityAvailable: Bool {
        #if os(watchOS)
        return false
        #else
        return SpeechTranscriber.isAvailable
        #endif
    }

    /// The engine the device can ACTUALLY run — `.highQuality` clamped to
    /// `.dictation` when high quality is unavailable (sub-A16), matching the
    /// runner's inline clamp. UI readiness, the active-row checkmark, the
    /// Try-voice gate, and `isProviderReady` all read THIS (never the raw
    /// persisted mode) so a synced-but-unsupported choice never dead-ends.
    var effectiveAppleEngine: AppleOnDeviceEngineMode {
        AppleOnDeviceEngineMode.effectiveEngine(
            requested: appleOnDeviceEngineMode, hqAvailable: appleHighQualityAvailable
        )
    }

    /// Whether the Apple "Try voice" test can record right now: the CLAMPED
    /// engine's model must be installed (High quality → HQ ledger; Standard →
    /// `appleStandardModelState`). Replaces the old "Standard is always
    /// recordable" assumption, which let the test fire into a not-ready model.
    var appleTestCanRecord: Bool {
        switch effectiveAppleEngine {
        case .highQuality:
            return appleModelStates[appleTargetKey] == .installed
        case .dictation:
            return appleStandardModelState == .installed
        }
    }

    /// Re-read the persisted engine mode into the observable. Called from the
    /// Apple provider detail's appear so a remote iCloud-KVS change (made on
    /// another device) is reflected without a full `loadSettings` fan-out.
    func refreshAppleOnDeviceEngineMode() async {
        appleOnDeviceEngineMode = await SettingsManager.shared.getAppleOnDeviceEngineMode()
    }

    /// Read-only probe of the STANDARD model's install state for the current
    /// language into `appleStandardModelState` (the Standard row's source of
    /// truth). Used on the Apple detail's appear and after an HQ commit/abort so
    /// the Standard row reflects on-disk truth WITHOUT the "Preparing…" spinner a
    /// `prepareStandardEngine` would show. Skips while a prepare is in flight
    /// (`.downloading`) or after a genuine `.failed` (don't mask a real error).
    func refreshAppleStandardModelStatus() async {
        #if !os(watchOS)
        switch appleStandardModelState {
        case .downloading, .failed:
            return   // in-flight / real error — let the prepare flow own it
        case .installed, .notDownloaded:
            break
        }
        // Resolve the canonical target so the state is language-accurate.
        if case .supported(let loc) = await AppleSpeechRunner.resolve(
            preferredLanguage: preferredLanguage, engine: .dictation
        ) {
            appleStandardTargetKey = loc.identifier
        }
        let ready = await AppleModelInstaller.isReady(engine: .dictation, language: preferredLanguage)
        // Re-check the guard: a prepare may have started during the await.
        switch appleStandardModelState {
        case .downloading, .failed: return
        case .installed, .notDownloaded: appleStandardModelState = ready ? .installed : .notDownloaded
        }
        #endif
    }

    /// Proactively download+install the STANDARD (`.dictation`) model for the
    /// current language, owning the ledger write-back (the installer is a pure
    /// primitive). Single-flight (a concurrent caller awaits the in-flight task);
    /// target-aware + generation-guarded so a stale completion or a language
    /// switch can't write the wrong target. CALM: shows "Preparing…" only when a
    /// real install runs (an already-installed model never flashes the spinner);
    /// `.failed` only on a genuine failure with a working retry. No-op on watchOS.
    /// Returns true iff the model ends up installed.
    @discardableResult
    func prepareStandardEngine() async -> Bool {
        #if os(watchOS)
        return false
        #else
        if let inFlight = appleStandardPrepareTask {
            await inFlight.value
            return appleStandardModelState == .installed
        }
        appleStandardGeneration &+= 1
        let gen = appleStandardGeneration
        let language = preferredLanguage
        let installer = appleModelInstaller
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // Only show "Preparing…" if we weren't already installed — an
            // already-on-disk model re-verifies fast and must not flash a spinner.
            let wasInstalled = (self.appleStandardModelState == .installed)
            if !wasInstalled { self.appleStandardModelState = .downloading(progress: 0) }
            do {
                let loc = try await installer.install(engine: .dictation, language: language) { fraction in
                    guard gen == self.appleStandardGeneration else { return }
                    self.appleStandardModelState = .downloading(progress: fraction)
                }
                guard gen == self.appleStandardGeneration else { return }
                self.appleStandardTargetKey = loc.identifier
                self.appleStandardModelState = .installed
            } catch AppError.appleSpeechLanguageUnsupported {
                guard gen == self.appleStandardGeneration else { return }
                self.appleStandardModelState = .failed(
                    message: String(localized: LocalizedStringResource(
                        "settings.voice.apple.prepare.error.unsupported",
                        defaultValue: "Apple Speech doesn't support this language yet.")),
                    retryable: false)
            } catch {
                guard gen == self.appleStandardGeneration else { return }
                self.appleStandardModelState = .failed(
                    message: String(localized: LocalizedStringResource(
                        "settings.voice.apple.prepare.error.failed",
                        defaultValue: "Couldn't set up voice. Check your connection and try again.")),
                    retryable: true)
            }
        }
        appleStandardPrepareTask = task
        await task.value
        appleStandardPrepareTask = nil
        return appleStandardModelState == .installed
        #endif
    }

    /// Persist the user's on-device engine choice (dual-write App-Group + iCloud
    /// KVS via `SettingsManager`) and mirror it into the observable so the Apple
    /// detail re-renders the right branch. Switching to `.highQuality` kicks a
    /// status check so the download/installed lifecycle hydrates immediately;
    /// switching back to `.dictation` needs no model, so it skips that probe.
    func setAppleOnDeviceEngineMode(_ mode: AppleOnDeviceEngineMode) async {
        #if !os(watchOS)
        // A live/terminal "Try voice" result is attributed to the OLD engine —
        // abort it on a REAL switch so the user re-records against the engine they
        // just picked (the A/B loop). NOT on an idempotent re-tap of the active row.
        if mode != appleOnDeviceEngineMode {
            appleSpeechTester.cancel()
        }
        #endif
        await SettingsManager.shared.setAppleOnDeviceEngineMode(mode)
        appleOnDeviceEngineMode = mode
        if mode == .highQuality {
            await checkAppleModelStatus()
        }
    }

    /// Pick the Standard (dictation) engine — instant, no download. Clears any
    /// pending high-quality commit so a download still in flight won't auto-switch
    /// the user to high quality when it finishes, then ensures the Standard model
    /// is prepared (no-op if already installed).
    func selectStandardEngine() async {
        pendingHighQualityCommit = false
        await setAppleOnDeviceEngineMode(.dictation)
        await prepareStandardEngine()
    }

    /// Pick the High-quality engine. If its model for the current language is
    /// already installed, commit immediately. Otherwise START the download and
    /// keep Standard active until it succeeds — committing to `.highQuality` only
    /// on a successful install AND only if the user hasn't reverted to Standard
    /// meanwhile (`pendingHighQualityCommit`). Also serves the "Try again" retry
    /// after a failed download. No-op on a device below the A16 floor.
    func selectHighQualityEngine() async {
        guard appleHighQualityAvailable else { return }

        // Already installed for the current language → instant commit.
        if case .installed = appleModelStates[appleTargetKey] {
            pendingHighQualityCommit = false
            await setAppleOnDeviceEngineMode(.highQuality)
            await refreshAppleStandardModelStatus()
            return
        }

        // Not installed → download; engine stays Standard during the download.
        pendingHighQualityCommit = true
        await downloadAppleModel()
        // Commit only if still wanted (user didn't tap Standard mid-download) AND
        // the model for the CURRENT target actually installed (guards a stale
        // completion landing under a since-changed language).
        if pendingHighQualityCommit, case .installed = appleModelStates[appleTargetKey] {
            pendingHighQualityCommit = false
            await setAppleOnDeviceEngineMode(.highQuality)
        }
        // Keep the (now-inactive) Standard row honest after an HQ commit/abort.
        await refreshAppleStandardModelStatus()
    }

    // MARK: - Remote Agent (Personal AI) — lifecycle

    /// Hydrate the per-backend remote-agent observable state from
    /// `SettingsManager`. Called from `loadSettings()` so the View renders
    /// the persisted configuration without per-render actor hops. Mirrors
    /// the STT `refreshMaskedTails` + active-preset load, extended across
    /// `RemoteAgentBackend.allCases`.
    ///
    /// Privacy: the token is read here ONLY to derive the masked tail; the
    /// raw value never enters observable state. (Same posture as STT
    /// `refreshMaskedTails`.)
    /// Onboarding gateway step entry point: refresh ONLY the remote-agent state
    /// (configured-set + custom roster + per-ref buffers) that the pairing
    /// import sheet and the connected-state confirmation read. Lighter than the
    /// full `loadSettings` fan-out, and ensures a returning user's
    /// already-configured gateway shows as connected on the step's first appear.
    func refreshRemoteAgentState() async {
        await loadRemoteAgentState()
    }

    private func loadRemoteAgentState() async {
        sessionContinuationPolicy = await SettingsManager.shared.getSessionContinuationPolicy()
        onLaunchMode = await SettingsManager.shared.getOnLaunchMode()

        defaultRemoteAgentRef = await SettingsManager.shared.defaultRemoteAgentRef()
        watchDefaultOverrideRef = await SettingsManager.shared.watchDefaultOverrideRef()
        watchSessionPolicyOverride = await SettingsManager.shared.watchSessionContinuationPolicyOverride()
        await refreshRemoteAgentReadinessSnapshots()

        // Cache the custom roster. A reload drops any unsaved in-memory draft
        // (the persisted roster is the source of truth) — backing out of an
        // empty "+ Add custom gateway" therefore discards it silently.
        let customs = await SettingsManager.shared.customGateways()
        customGateways = customs

        var nextURLStrings: [RemoteAgentRef: String] = [:]
        var nextModels: [RemoteAgentRef: String] = [:]
        var nextCerts: [RemoteAgentRef: String] = [:]
        var nextAuthSchemes: [RemoteAgentRef: RemoteAgentAuthScheme] = [:]
        var nextImagePolicies: [RemoteAgentRef: ImageHistoryPolicy] = [:]
        var nextMasked: [RemoteAgentRef: String] = [:]
        var nextStates: [RemoteAgentRef: KeyValidationState] = [:]

        // Built-in refs first (in `allCases` order), then custom refs.
        let allRefs: [RemoteAgentRef] =
            RemoteAgentBackend.allCases.map { .builtin($0) } + customs.map { .custom($0.id) }

        for ref in allRefs {
            let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: ref)
            nextURLStrings[ref] = storedURL?.absoluteString ?? ""
            if case .custom(let id) = ref, let model = customs.first(where: { $0.id == id })?.model {
                nextModels[ref] = model
            }
            if let cert = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: ref) {
                nextCerts[ref] = cert
            }
            var scheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: ref)

            // Built-in descriptor seeding: keep the editor + Test Connection +
            // Save consistent for preconfigured backends. A fixed-endpoint
            // backend (OpenRouter) seeds its app-fixed URL into the buffer (the
            // URL field is hidden; `getRemoteAgentURL` is already authoritative
            // for reads). A locked-auth backend seeds + forces its scheme so the
            // hidden toggle can't drift. A model-bearing backend seeds the
            // persisted model. Self-hosted built-ins (OpenClaw / Hermes) have a
            // nil `fixedURL`, nil `lockedAuthScheme`, and `showsModelField ==
            // false`, so every branch is a no-op for them.
            if case .builtin(let backend) = ref {
                let descriptor = RemoteAgentBackendRegistry.lookup(id: backend)
                if let fixedURL = descriptor.fixedURL {
                    nextURLStrings[ref] = fixedURL.absoluteString
                }
                if let locked = descriptor.lockedAuthScheme {
                    scheme = locked
                }
                if descriptor.showsModelField {
                    nextModels[ref] = await SettingsManager.shared.getRemoteAgentModel(for: ref) ?? ""
                }
            }
            nextAuthSchemes[ref] = scheme
            nextImagePolicies[ref] = await SettingsManager.shared.getImageHistoryPolicy(for: ref)
            let storedToken = await SettingsManager.shared.getRemoteAgentToken(for: ref)
            let hasToken = (storedToken?.isEmpty == false)
            if hasToken {
                nextMasked[ref] = maskedTail(storedToken!)
            }
            // Configured (Decision E, keyless-aware): URL is always required;
            // `.none` (keyless) is `.valid` on URL alone, `.bearer` ALSO needs a
            // stored token. A bearer ref missing its token (incl. a transient
            // Keychain read failure → nil) renders `.unset` (fail closed).
            let configured = (storedURL != nil) && (scheme == .none || hasToken)
            nextStates[ref] = configured ? .valid : .unset
        }

        // Reload resurrection guard. The buffers below are about to be REPLACED by
        // whatever storage says (a launch, an iCloud-KVS sync from another device,
        // a pairing import). A live verdict is a claim about the exact tuple a
        // probe ran against — so any ref whose probed fields MOVED in this reload
        // loses its green mark + remedy, and disowns a probe still in flight
        // against the old tuple. A ref whose tuple is byte-identical keeps its
        // mark: the values on screen ARE the values that passed (the pairing-
        // import happy path lands here, since its save posts
        // `.settingsDidChangeRemotely` and re-enters this reload).
        for ref in allRefs {
            let probedTupleUnchanged =
                (remoteAgentURLStrings[ref] ?? "") == (nextURLStrings[ref] ?? "")
                && (remoteAgentCertFingerprints[ref] ?? "") == (nextCerts[ref] ?? "")
                && (remoteAgentAuthSchemes[ref] ?? .bearer) == (nextAuthSchemes[ref] ?? .bearer)
                && (remoteAgentMaskedTails[ref] ?? "") == (nextMasked[ref] ?? "")
            if !probedTupleUnchanged {
                invalidateLiveValidation(for: ref)
            }
        }

        remoteAgentURLStrings = nextURLStrings
        remoteAgentModelStrings = nextModels
        remoteAgentCertFingerprints = nextCerts
        remoteAgentAuthSchemes = nextAuthSchemes
        imageHistoryPolicies = nextImagePolicies
        remoteAgentMaskedTails = nextMasked
        remoteAgentValidationStates = nextStates

        // Hydrate the per-ref file-server config alongside the gateway config
        // (same ref roster), so the setup guide renders the persisted URL /
        // credential-presence / pin + availability without per-render actor
        // hops. Mirrors the gateway hydration above.
        var nextFSURLs: [RemoteAgentRef: String] = [:]
        var nextFSURLPresent: [RemoteAgentRef: Bool] = [:]
        var nextFSCredPresent: [RemoteAgentRef: Bool] = [:]
        var nextFSCerts: [RemoteAgentRef: String] = [:]
        var nextFSAvailable: Set<RemoteAgentRef> = []
        var nextFSUploadOnly: Set<RemoteAgentRef> = []

        for ref in allRefs {
            if let url = await SettingsManager.shared.getFileServerURL(for: ref) {
                nextFSURLs[ref] = url.absoluteString
                nextFSURLPresent[ref] = true
            } else {
                nextFSURLs[ref] = ""
                nextFSURLPresent[ref] = false
            }
            // Presence-only read — the credential value never enters the View.
            nextFSCredPresent[ref] = (await SettingsManager.shared.getFileServerCredential(for: ref)) != nil
            if let cert = await SettingsManager.shared.getFileServerCertFingerprint(for: ref) {
                nextFSCerts[ref] = cert
            }
            if await SettingsManager.shared.getFileTransferAvailable(for: ref) {
                nextFSAvailable.insert(ref)
            }
            // Read unconditionally, not only for available refs: the accessor
            // defaults an absent key to capable, so a non-member is the honest
            // reading for a lane nobody has measured, and hydrating it beside
            // availability keeps the two from being read a settings-edit apart.
            if !(await SettingsManager.shared.getFileServerReturnCapable(for: ref)) {
                nextFSUploadOnly.insert(ref)
            }
        }

        fileServerURLStrings = nextFSURLs
        fileServerURLPresent = nextFSURLPresent
        fileServerCredentialPresent = nextFSCredPresent
        fileServerCertFingerprints = nextFSCerts
        fileTransferAvailableRefSet = nextFSAvailable
        fileTransferUploadOnlyRefSet = nextFSUploadOnly
        // The hydrated buffers ARE the persisted values at this point — seed the
        // persisted mirrors from the same reads (the file-transfer editor's
        // dirty-detection / discard baseline).
        fileServerPersistedURLStrings = nextFSURLs
        fileServerPersistedPins = nextFSCerts
        // Validation state + staged-test results are session-scoped (owned by
        // the open setup guide), so a remote-change reload does NOT clobber
        // them — they're left as-is, mirroring how `keyStates` survives a load.

        // First (and every) load complete — unblocks the Personal AI empty-state
        // branch so the hero only shows once we KNOW there's no gateway.
        hasLoadedRemoteAgentState = true
    }

    // MARK: - Remote Agent per-ref helpers (mirror STT `rowState`/`isProviderReady`)

    /// Whether `ref` has a COMPLETE config (token AND url — Decision E).
    /// Drives the list's "Configured"/"Default" vs "Not set up" pill and the
    /// "Set as Default" affordance. Reads the cached snapshot — no actor hop.
    func isRemoteAgentConfigured(_ ref: RemoteAgentRef) -> Bool {
        configuredRemoteAgentRefSet.contains(ref)
    }

    /// Whether `ref`'s setup was started here but can't be used as it stands.
    /// Drives the list's "Needs setup" mark. Cached snapshot — no actor hop.
    func isRemoteAgentIncomplete(_ ref: RemoteAgentRef) -> Bool {
        incompleteRemoteAgentRefSet.contains(ref)
    }

    /// Whether `ref` holds ANY stored state on this device — i.e. whether there
    /// is something for Forget to remove. True for every configured ref, every
    /// half-configured one Diagnostics reports, and refs left holding only
    /// auxiliary residue.
    /// The `configured ||` half is defensive, not redundant: a send-able gateway
    /// always has state worth erasing, so if any future removability rule ever
    /// fails to see it, the destructive section must still be reachable rather
    /// than silently vanishing from a working gateway's editor.
    func hasStoredRemoteAgentState(_ ref: RemoteAgentRef) -> Bool {
        configuredRemoteAgentRefSet.contains(ref) || removableRemoteAgentRefSet.contains(ref)
    }

    /// Re-read the three gateway-state snapshots from ONE inventory pass.
    ///
    /// One hop, not three: read separately, an iCloud change landing between the
    /// calls could leave the list marking a gateway "Needs setup" while the
    /// editor it opens offers no Forget — the two describing different moments.
    private func refreshRemoteAgentReadinessSnapshots() async {
        let inventory = await SettingsManager.shared.remoteAgentInventory()
        configuredRemoteAgentRefSet = Set(inventory.configuredRefs)
        incompleteRemoteAgentRefSet = Set(inventory.incompleteRefs)
        removableRemoteAgentRefSet = inventory.removableRefs
    }

    /// Whether ANY gateway is currently configured (cached set; no actor hop).
    /// The editor snapshots this BEFORE a save to tell the first-gateway
    /// bootstrap (silent) apart from an additional new gateway (prompt). See
    /// `shouldPromptToSetDefault`.
    var hasAnyConfiguredRemoteAgent: Bool {
        !configuredRemoteAgentRefSet.isEmpty
    }

    /// Pure decision for the post-save "Make this your default gateway?" prompt.
    /// Snapshots are taken in the editor BEFORE the save:
    /// - `hadAnyConfiguredBefore == false` → first gateway ever; `saveRemoteAgent`
    ///   silently bootstraps it as the default, so NO prompt.
    /// - `wasConfiguredBefore == true` → an edit of an already-configured gateway,
    ///   NOT a new configuration → NO prompt (never nag on routine edits).
    /// - otherwise → a genuinely new ADDITIONAL gateway: prompt only when it isn't
    ///   already the resolved default (configuring the unset-pointer fallback,
    ///   e.g. OpenClaw, is already-default → no-op → no prompt).
    static func shouldPromptToSetDefault(
        savedRef: RemoteAgentRef,
        defaultRef: RemoteAgentRef,
        wasConfiguredBefore: Bool,
        hadAnyConfiguredBefore: Bool
    ) -> Bool {
        guard hadAnyConfiguredBefore else { return false }
        guard !wasConfiguredBefore else { return false }
        return savedRef != defaultRef
    }

    /// In-flight / failure validation state for a ref's detail screen.
    /// Falls back to `.unset` for refs never touched this session.
    func remoteAgentRowState(for ref: RemoteAgentRef) -> KeyValidationState {
        remoteAgentValidationStates[ref] ?? .unset
    }

    /// Display name of the default ref — drives the Settings root
    /// "Personal AI" summary row.
    var defaultRemoteAgentDisplayName: String {
        RemoteAgentRefMetadata.displayName(for: defaultRemoteAgentRef, customs: customGateways)
    }

    /// Display name for the "Default for new chats" SELECTOR row. Unlike
    /// `defaultRemoteAgentDisplayName` (which always resolves the ever-present
    /// builtin `defaultRemoteAgentRef`), this tells the truth about a default that
    /// cannot send, in the two ways it can happen:
    ///
    ///   - NOTHING configured → "Not configured", so the selector never advertises
    ///     a phantom default (e.g. "OpenClaw") before any gateway is set up.
    ///     Mirrors the empty-set guard in `personalAISummaryShort`.
    ///   - Something configured, but not the default → the name PLUS the state.
    ///     That combination is legitimate and durable — `defaultRemoteAgentRef()`
    ///     honours an unconfigured built-in on purpose, `deleteCustomGateway`
    ///     parks the pointer on one, and a peer's Forget that arrives while this
    ///     device is offline (the retire in `handleICloudChange` only fires on a
    ///     live `.serverChange`) leaves one behind — and it is precisely when a
    ///     bare name lies: the row read
    ///     "New chats use → OpenClaw" while OpenClaw had nothing behind it and
    ///     five other gateways were doing the work. This screen is where that gets
    ///     fixed, so it is the one place that must not hide it.
    ///
    /// Gates the STRING only; `defaultRemoteAgentRef` itself is untouched
    /// (bootstrap tests assert on the ref).
    ///
    /// The second case keeps the NAME and reports the state through the separate
    /// `defaultSelectorNeedsSetup` flag rather than appending to this string: the
    /// row renders its value in a trailing slot roughly 70-100pt wide on iPhone,
    /// where "OpenClaw" fits and "OpenClaw — needs setup" (195pt) wraps the row
    /// to three lines at larger Dynamic Type.
    var defaultSelectorDisplayName: String {
        configuredRemoteAgentRefSet.isEmpty
            ? String(localized: "settings.personalAI.default.notConfigured", defaultValue: "Not configured")
            : defaultRemoteAgentDisplayName
    }

    /// Whether the "Default for new chats" row names a gateway that cannot send —
    /// the state the row must not present as ordinary. Reachable and durable:
    /// `defaultRemoteAgentRef()` honours an unconfigured built-in on purpose,
    /// `deleteCustomGateway` parks the pointer on one, and a peer's Forget that
    /// this device was offline for is never retired (that retire fires only on a
    /// live `.serverChange`). False when NOTHING is configured, because
    /// `defaultSelectorDisplayName` already says "Not configured" there and a
    /// first-run device is not broken.
    var defaultSelectorNeedsSetup: Bool {
        let configured = configuredRemoteAgentRefSet
        return !configured.isEmpty && !configured.contains(defaultRemoteAgentRef)
    }

    /// Compact "Personal AI" summary for a Settings summary row — the SINGLE
    /// source of truth shared by the iPhone root Form and the iPad Overview pane
    /// (so the two can't drift). "Setup needed" when nothing's configured, the
    /// default backend's name when exactly one, or "<default> +N" when several.
    /// Pure (no actor hop), mirrors `generalSummaryShort` / `voiceSummaryShort`.
    var personalAISummaryShort: String {
        let configured = configuredRemoteAgentRefSet
        guard !configured.isEmpty else {
            return String(localized: "settings.root.personalAI.setupNeeded", defaultValue: "Setup needed")
        }
        // A default outside the configured set breaks BOTH halves of the summary
        // below: it names a gateway that cannot send, and `count - 1` then
        // subtracts a gateway that was never in the set, hiding a working one. The
        // honest one-line answer for that state is the state itself — the same
        // wording the selector and the gateway rows use, one tap away.
        guard configured.contains(defaultRemoteAgentRef) else {
            // Its OWN wording, not the row-level "Needs setup": on this row the
            // subject is the whole Personal AI section, and a bare "Needs setup"
            // there would read as "nothing works" on a device where four other
            // gateways do. Distinct from "Setup needed" above, which is the
            // genuinely-nothing-configured state.
            return String(localized: LocalizedStringResource(
                "settings.root.personalAI.defaultNeedsSetup",
                defaultValue: "Default needs setup"
            ))
        }
        let defaultName = defaultRemoteAgentDisplayName
        let others = configured.count - 1
        if others <= 0 {
            return defaultName
        }
        return "\(defaultName) +\(others)"
    }

    /// Compact "<startup> · <quick-captures>" summary for the Settings root
    /// "General" row (e.g. "Start new · 30 min"). Uses SHORT labels — the full
    /// picker labels are too long for a one-line trailing status. Pure, no actor
    /// hop (mirrors `voiceSummaryShort`); shows defaults until `load()` lands.
    var generalSummaryShort: String {
        "\(onLaunchShortLabel) · \(sessionPolicyShortLabel)"
    }

    /// Short label for the active cold-launch landing mode.
    private var onLaunchShortLabel: String {
        switch onLaunchMode {
        case .startNewConversation:
            return String(localized: "settings.general.onLaunch.startNew.short", defaultValue: "Start new")
        case .resumeLastConversation:
            return String(localized: "settings.general.onLaunch.resumeLast.short", defaultValue: "Resume last")
        }
    }

    /// Short label for the active quick-capture continuation policy.
    private var sessionPolicyShortLabel: String {
        switch sessionContinuationPolicy {
        case .alwaysNew:      return String(localized: "settings.general.session.short.never", defaultValue: "Off")
        case .minutes15:      return String(localized: "settings.general.session.short.min15", defaultValue: "15 min")
        case .minutes30:      return String(localized: "settings.general.session.short.min30", defaultValue: "30 min")
        case .minutes60:      return String(localized: "settings.general.session.short.min60", defaultValue: "60 min")
        case .alwaysContinue: return String(localized: "settings.general.session.short.always", defaultValue: "Always")
        }
    }

    /// Display name for any ref (built-in or custom), resolved against the
    /// cached roster — pure, no actor hop. Used by detail / nav titles.
    func displayName(for ref: RemoteAgentRef) -> String {
        RemoteAgentRefMetadata.displayName(for: ref, customs: customGateways)
    }

    /// Set the default ref (the one new conversations bind to). Mirrors
    /// STT `setActive`. Re-pointing the default also clears the active-
    /// conversation pointer (inside `SettingsManager.setDefaultRemoteAgentRef`,
    /// universal across iOS/macOS settings + the CarPlay picker) so the next
    /// HEADLESS capture switches to the new gateway IMMEDIATELY rather than
    /// continuing the prior thread on its old bound gateway under
    /// `SessionContinuationPolicy`.
    ///
    /// The single funnel for every USER-facing default choice (iOS + iPad
    /// `PersonalAISettingsView`, `MacPersonalAICategory`, and the post-setup "Make
    /// Default"), which is why it routes through `applyUserChosenDefault` — that
    /// path also retires the sticky last-used gateway and always notifies, so a
    /// re-tap of the gateway already checked still takes effect. Programmatic
    /// re-points (Forget fallbacks, first-gateway bootstrap) must call
    /// `SettingsManager.setDefaultRemoteAgentRef` directly instead.
    func setDefaultRemoteAgentRef(_ ref: RemoteAgentRef) async {
        await SettingsManager.shared.applyUserChosenDefault(ref)
        defaultRemoteAgentRef = ref
    }

    /// Display name for the WATCH's effective default — "Follow iPhone" when no
    /// override is set, else the overridden gateway's name. Drives the
    /// `WatchSettingsView` default-gateway selector row (iPhone-hosted).
    var watchDefaultDisplayName: String {
        guard let ref = watchDefaultOverrideRef else {
            return String(localized: "settings.watch.default.followPhone", defaultValue: "Follow iPhone")
        }
        return RemoteAgentRefMetadata.displayName(for: ref, customs: customGateways)
    }

    /// Set (`ref`) or clear (`nil` = "Follow iPhone") the Watch default override.
    /// App-Group-local on the iPhone — `SettingsManager` re-broadcasts the new
    /// Watch-effective default to the wrist. Mirrors local state after the write.
    func setWatchDefaultOverrideRef(_ ref: RemoteAgentRef?) async {
        await SettingsManager.shared.setWatchDefaultOverrideRef(ref)
        watchDefaultOverrideRef = ref
    }

    /// Set (`value`) or clear (`nil` = "Follow iPhone") the Watch session-policy
    /// override. App-Group-local on the iPhone — `SettingsManager` re-broadcasts
    /// the new Watch-effective policy to the wrist. Mirrors local state after the
    /// write. Mirrors `setWatchDefaultOverrideRef`.
    func setWatchSessionPolicyOverride(_ value: SessionContinuationPolicy?) async {
        await SettingsManager.shared.setWatchSessionContinuationPolicyOverride(value)
        watchSessionPolicyOverride = value
    }

    // MARK: - Gateway list + "+ Add" surface (custom gateways)

    /// The ordered gateway list for the Settings master: built-ins first (in
    /// `RemoteAgentBackendRegistry.all` order — Hermes still feature-gated),
    /// then every custom in roster order. Precomputed so the View iterates a
    /// dumb array (no actor hop, no built-in-vs-custom branching in `body`).
    var personalAIRows: [PersonalAIRow] {
        var rows: [PersonalAIRow] = []
        for metadata in RemoteAgentBackendRegistry.all {
            let ref = RemoteAgentRef.builtin(metadata.id)
            rows.append(PersonalAIRow(
                ref: ref,
                displayName: metadata.displayName,
                configured: configuredRemoteAgentRefSet.contains(ref),
                isDefault: defaultRemoteAgentRef == ref,
                incomplete: incompleteRemoteAgentRefSet.contains(ref)
            ))
        }
        for gateway in customGateways {
            let ref = RemoteAgentRef.custom(gateway.id)
            rows.append(PersonalAIRow(
                ref: ref,
                displayName: gateway.name.isEmpty
                    ? String(localized: "New gateway")
                    : gateway.name,
                configured: configuredRemoteAgentRefSet.contains(ref),
                isDefault: defaultRemoteAgentRef == ref,
                incomplete: incompleteRemoteAgentRefSet.contains(ref)
            ))
        }
        return rows
    }

    /// Number of custom gateways currently in the cached roster (incl. an
    /// in-memory draft). Drives the cap gate on the "+ Add" affordance.
    var customGatewayCount: Int {
        customGateways.count
    }

    /// Mint a fresh custom-gateway draft: insert an in-memory `CustomGateway`
    /// (empty name; auto-assigned badge color; nil model) into the cached
    /// roster and return its id so the caller can push the editor bound to
    /// `.custom(id)`. Persists NOTHING — the draft becomes real only on the
    /// first successful `validateAndSaveRemoteAgent`. Backing out of an empty
    /// draft drops it on the next `loadRemoteAgentState` reload.
    ///
    /// Guarded by the cap: returns nil when already at `maxCustomGateways`
    /// (the UI also disables the button, so this is defense-in-depth).
    func newCustomGatewayDraftID() -> UUID? {
        guard customGateways.count < Constants.maxCustomGateways else { return nil }
        let id = UUID()
        let usedColorIDs = customGateways.compactMap { $0.colorID }
        let colorID = RemoteAgentBadgePalette.nextUnusedID(existing: usedColorIDs)
        customGateways.append(CustomGateway(id: id, name: "", model: nil, colorID: colorID, monogram: nil))
        return id
    }

    // MARK: - Custom voice endpoints — draft + name-clash (Phase B)

    /// Number of custom voice endpoints in the cached roster (incl. an in-memory
    /// draft). Drives the cap gate on the "+ Add custom endpoint" affordance.
    var customVoiceEndpointCount: Int {
        customVoiceEndpoints.count
    }

    /// Mint a fresh custom-endpoint draft: insert an in-memory
    /// `CustomVoiceEndpoint` (empty name) into the cached roster + seed default
    /// per-uuid editor state, and return its id so the caller can push the editor
    /// bound to this uuid. Persists NOTHING — the draft becomes real only on the
    /// first `saveCustomVoiceEndpoint(for:pendingKey:)`. Backing out of an empty
    /// draft drops it (`cancelCustomVoiceEndpointEdit` / next `loadCustomSTTState`
    /// reload). Cap-gated: returns nil at `maxCustomVoiceEndpoints` (the UI also
    /// disables the button).
    func newCustomVoiceEndpointDraftID() -> UUID? {
        guard customVoiceEndpoints.count < Constants.maxCustomVoiceEndpoints else { return nil }
        let id = UUID()
        customVoiceEndpoints.append(CustomVoiceEndpoint(id: id, name: ""))
        // Seed the per-uuid editor state so the bindings resolve to empty fields.
        customSTTURLStrings[id] = ""
        customSTTCertFingerprints[id] = ""
        customSTTModels[id] = ""
        customTTSModels[id] = ""
        customSTTAuthSchemes[id] = .bearer
        customSTTValidationStates[id] = .unset
        return id
    }

    /// Rename a custom voice endpoint's roster record in memory (live binding for
    /// the editor's Name field). Persisted to the roster JSON on the next
    /// `saveCustomVoiceEndpoint(for:pendingKey:)`.
    func setCustomVoiceEndpointName(_ name: String, for uuid: UUID) {
        if let idx = customVoiceEndpoints.firstIndex(where: { $0.id == uuid }) {
            customVoiceEndpoints[idx].name = name
        }
    }

    /// The current in-memory name for a custom voice endpoint (drives the Name
    /// field binding). Empty when the endpoint is an unnamed fresh draft.
    func customVoiceEndpointName(for uuid: UUID) -> String {
        customVoiceEndpoints.first(where: { $0.id == uuid })?.name ?? ""
    }

    /// Whether a trimmed candidate name collides (case-insensitively) with
    /// ANOTHER endpoint's name. Mirrors `remoteAgentNameClashes`. Empty / the
    /// endpoint's own name → no clash.
    func customVoiceEndpointNameClashes(_ name: String, excludingID: UUID) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        for endpoint in customVoiceEndpoints where endpoint.id != excludingID {
            if endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate {
                return true
            }
        }
        return false
    }

    /// Persist a badge override (color swatch / monogram) on an EXISTING custom
    /// gateway and re-sync the cached roster. No-op if the gateway isn't yet
    /// persisted (an unsaved draft keeps the override in-memory until first
    /// save folds it in via `validateAndSaveRemoteAgent`).
    func updateCustomGatewayBadge(_ gateway: CustomGateway) async {
        // Mirror into the in-memory cache immediately (so the swatch/monogram
        // re-render without waiting on the actor hop), then persist.
        if let idx = customGateways.firstIndex(where: { $0.id == gateway.id }) {
            customGateways[idx] = gateway
        }
        // Only persist a gateway that's already configured (has a roster entry);
        // a never-saved draft has no per-ref slots yet. `upsertCustomGateway`
        // on an existing id is an UPDATE (never trips the cap).
        if await SettingsManager.shared.customGateway(id: gateway.id) != nil {
            _ = await SettingsManager.shared.upsertCustomGateway(gateway)
            customGateways = await SettingsManager.shared.customGateways()
        }
    }

    /// Store the model IDs a ref's Test Connection discovered (`/v1/models`),
    /// feeding the custom editor's Model suggestion list. Pass an empty array
    /// to clear (degrades the field to free-text-only).
    func setRemoteAgentModelSuggestions(_ models: [String], for ref: RemoteAgentRef) {
        remoteAgentModelSuggestions[ref] = models
    }

    /// Retract a ref's live verdict because its probed config just changed.
    ///
    /// The green "Connected" row and the failure-specific remedy are claims about
    /// the EXACT tuple (URL, token, auth scheme, cert pin) a probe ran against —
    /// the moment any of them moves, both claims are unproven. Bumping the
    /// generation additionally disowns any probe still in flight against the old
    /// tuple, so its late verdict can't resurrect either claim.
    ///
    /// The validation STATE (`.valid`/`.unset`) is deliberately untouched: it
    /// describes the SAVED config, not the buffer, so an edit leaves the row at
    /// the honest "Saved" until the user tests again.
    private func invalidateLiveValidation(for ref: RemoteAgentRef) {
        remoteAgentLiveValidated.remove(ref)
        remoteAgentLastErrorCodes[ref] = nil
        remoteAgentProbeReportedNoModels.remove(ref)
        bumpValidationGeneration(for: ref)
    }

    @discardableResult
    private func bumpValidationGeneration(for ref: RemoteAgentRef) -> Int {
        let next = (remoteAgentValidationGenerations[ref] ?? 0) &+ 1
        remoteAgentValidationGenerations[ref] = next
        return next
    }

    /// Editor URL field writes the buffered gateway URL for a ref. Routed through
    /// the VM (not a raw dictionary binding) so every keystroke retracts a live
    /// verdict earned by a DIFFERENT URL.
    ///
    /// `validateRemoteAgent` / `saveRemoteAgent` write `remoteAgentURLStrings`
    /// DIRECTLY on purpose — those are the normalize-and-reflect write-backs of a
    /// tuple they just probed/committed, and routing them here would erase the
    /// verdict they are in the middle of recording.
    func setRemoteAgentURLBuffer(_ url: String, for ref: RemoteAgentRef) {
        guard remoteAgentURLStrings[ref] != url else { return }
        remoteAgentURLStrings[ref] = url
        invalidateLiveValidation(for: ref)
    }

    /// Editor cert-pin field writes the buffered fingerprint for a ref. Same
    /// invalidation contract as `setRemoteAgentURLBuffer`.
    func setRemoteAgentCertFingerprintBuffer(_ fingerprint: String, for ref: RemoteAgentRef) {
        guard remoteAgentCertFingerprints[ref] != fingerprint else { return }
        remoteAgentCertFingerprints[ref] = fingerprint
        invalidateLiveValidation(for: ref)
    }

    /// The token lives in the entry sheet's PRIVATE `@State` draft, so the VM
    /// can't observe it changing. The sheet calls this on COMMIT (not per
    /// keystroke — a draft the user abandons changes nothing) to retract a
    /// verdict earned by the previous token.
    func noteRemoteAgentSecretEdited(for ref: RemoteAgentRef) {
        invalidateLiveValidation(for: ref)
    }

    /// Editor toggle writes the buffered auth scheme for a ref (committed by
    /// Save). Mirrors `setCustomSTTAuthSchemeBuffer` on the custom-STT side.
    func setRemoteAgentAuthSchemeBuffer(_ scheme: RemoteAgentAuthScheme, for ref: RemoteAgentRef) {
        guard remoteAgentAuthSchemes[ref] != scheme else { return }
        remoteAgentAuthSchemes[ref] = scheme
        invalidateLiveValidation(for: ref)
    }

    /// Normalise a user-typed gateway BASE url — the address the client appends
    /// `/v1/chat/completions` (and `/v1/models`) to. A user who pastes the full
    /// endpoint they read in their gateway's docs would otherwise have the suffix
    /// appended a SECOND time, and every probe/send 404s against a path that
    /// looks correct in the field.
    ///
    /// Operates on `URLComponents.path` segments — never raw string matching, so
    /// a host or query that merely CONTAINS "v1" is untouched — and strips only an
    /// exact TERMINAL `/v1/chat/completions`, `/v1/models`, or `/v1`, plus a
    /// trailing slash. A legitimate path prefix survives (`https://host/openclaw`
    /// stays; `https://host/openclaw/v1` → `https://host/openclaw`); the port
    /// survives with it.
    ///
    /// Query + fragment are DROPPED: a base URL is a prefix the client extends,
    /// so anything after `?`/`#` could never survive the append anyway — carrying
    /// it would only produce an invalid request URL.
    ///
    /// Pure + static so the suite can drive it without a VM.
    static func normalizedGatewayBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil

        var segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        // Longest-first: `/v1/chat/completions` must not be shortened to `/v1/chat`
        // by an earlier `/v1` match. One strip only — a base is never nested.
        let strippableSuffixes = [["v1", "chat", "completions"], ["v1", "models"], ["v1"]]
        for suffix in strippableSuffixes
        where segments.count >= suffix.count && Array(segments.suffix(suffix.count)) == suffix {
            segments.removeLast(suffix.count)
            break
        }

        components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        return components.url ?? url
    }

    /// Outcome of normalizing a manually-typed cert-pin fingerprint.
    enum FingerprintNormalization: Equatable {
        case none            // empty input → no pin
        case valid(String)   // canonical 64-hex lowercase digest
        case invalid         // non-empty but not 64 hex → reject
    }

    /// Normalize a user-typed SPKI SHA-256 fingerprint to the one canonical form a
    /// stored pin may take: trim, lowercase, strip `:` separators (openssl style),
    /// require EXACTLY 64 hex chars. Manual entry (gateway pin + file-server pin) is
    /// the ONLY way a pin is ever set — a pairing payload carries no fingerprint —
    /// so this is the single gate that keeps a colon-form paste from persisting as
    /// garbage that could never match a presented cert. Empty stays "no pin".
    ///
    /// ASCII-only hex gate (not `Character.isHexDigit`, which also accepts
    /// fullwidth variants that must never enter a pinned digest). Pure + static so
    /// the suite can drive it without a VM.
    static func normalizeCertFingerprint(_ raw: String?) -> FingerprintNormalization {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let normalized = trimmed.lowercased().replacingOccurrences(of: ":", with: "")
        let hexDigits = Set("0123456789abcdef")
        guard normalized.count == 64, normalized.allSatisfy({ hexDigits.contains($0) }) else {
            return .invalid
        }
        return .valid(normalized)
    }

    /// VALIDATE-ONLY: probe `url` + `token` against the gateway's
    /// `GET /v1/models` and surface `.checking` → `.valid` / `.invalid`.
    /// Persists NOTHING — `saveRemoteAgent` is the single commit point
    /// (buffer-until-Save, mirrors
    /// the custom-voice editor). Reflects the normalized URL / cert back into
    /// the buffers and populates the Model suggestion chips; the masked tail is
    /// set only on Save. Same provider-aware `friendlyMessage` mapping.
    ///
    /// Privacy: the raw token never leaves this method — no log, no
    /// print, no retention.
    func validateRemoteAgent(
        ref: RemoteAgentRef,
        url: String,
        token: String,
        authScheme: RemoteAgentAuthScheme = .bearer,
        fingerprint: String?,
        name: String? = nil,
        model: String? = nil
    ) async {
        // For a custom, the name is required and drives the picker label; for a
        // built-in, the registry display name is fixed. `displayName(for:)`
        // resolves against the cached roster (incl. an in-memory draft).
        let backendName = displayName(for: ref)
        // Status-map carrier + capability descriptor for this ref. A custom
        // carries `.openclaw` → the unified status map AND descriptor defaults
        // (`/v1/models` verdict probe, no model field). A built-in resolves its
        // own descriptor (OpenRouter → `/v1/key` verdict, shows model field).
        let carrierBackend: RemoteAgentBackend = {
            if case .builtin(let backend) = ref { return backend }
            return .openclaw
        }()
        let descriptor = RemoteAgentBackendRegistry.lookup(id: carrierBackend)

        // Custom-only: a name is required before we probe (it drives the picker
        // label). Built-ins ignore `name` (their identity is locked). The soft
        // 40-char cap is applied at Save, not here.
        if case .custom = ref {
            let candidate = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else {
                remoteAgentValidationStates[ref] = .invalid(
                    message: String(localized: "remoteAgent.custom.name.required",
                                    defaultValue: "Give this gateway a name.")
                )
                return
            }
        }

        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // `EndpointURLPolicy` — https (so the bearer token never leaves the
        // device in cleartext), a real host, and no `user:password@`. The SAME
        // gate the Save path applies: a draft Save would refuse must not be
        // Testable either, or a green verdict would be earned against a tuple
        // the commit rejects.
        guard !trimmedURL.isEmpty,
              let candidateURL = URL(string: trimmedURL),
              EndpointURLPolicy.isAdmissible(candidateURL) else {
            remoteAgentValidationStates[ref] = .invalid(
                message: Self.remoteAgentURLRejectionMessage(trimmedURL)
            )
            return
        }
        // Probe the BASE url — a pasted `/v1/chat/completions` (or `/v1`) would
        // otherwise be appended to a second time by the client. `saveRemoteAgent`
        // normalises identically, so an untested Save lands the same value.
        let parsedURL = Self.normalizedGatewayBaseURL(candidateURL)

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // `.bearer` requires a token; `.none` (keyless) probes with no header.
        if authScheme.requiresToken, trimmedToken.isEmpty {
            remoteAgentValidationStates[ref] = .invalid(
                message: String(localized: "Paste your \(backendName) bearer token.")
            )
            return
        }

        // Custom-only: trim surrounding whitespace; empty → nil (omit). Model
        // identifiers are opaque server-owned strings, so preserve the full
        // value rather than imposing an app-invented length limit.
        let trimmedModel: String? = {
            guard case .custom = ref else { return nil }
            let candidate = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }()

        // A `.systemTrustOnly` backend (OpenRouter) never sends a pin — drop any
        // stale value so a Test can't probe with it (mirrors the save clamp). The
        // carrier descriptor is `.systemTrustOnly` only for OpenRouter; a custom
        // carries `.openclaw` (`.optionalUserPin`), so the normalization runs there.
        // A hand-typed pin is normalized to the canonical manual-pin form
        // (trim/lowercase/strip ':' → 64 hex); garbage is rejected here rather
        // than probed with (and later saved) as an unmatchable value. A pairing
        // payload never carries a fingerprint, so typing it is the only route in.
        let effectiveFingerprint: String?
        if descriptor.trust == .systemTrustOnly {
            effectiveFingerprint = nil
        } else {
            switch Self.normalizeCertFingerprint(fingerprint) {
            case .none: effectiveFingerprint = nil
            case .valid(let hex): effectiveFingerprint = hex
            case .invalid:
                remoteAgentValidationStates[ref] = .invalid(
                    message: String(localized: "settings.remoteAgent.fingerprint.invalid",
                                    defaultValue: "That fingerprint should be 64 hex characters.")
                )
                return
            }
        }

        remoteAgentValidationStates[ref] = .checking
        // A probe is in flight: the previous verdict (green mark + error code) is
        // now unproven, so retract BOTH before we know the new answer. Without
        // this, a re-test of an edited config keeps showing the old "Connected"
        // (or the old remedy) for the duration of the probe.
        remoteAgentLiveValidated.remove(ref)
        remoteAgentLastErrorCodes[ref] = nil
        remoteAgentProbeReportedNoModels.remove(ref)
        // This probe's identity. Everything below the `await` applies ONLY while
        // it is still the newest word on this ref — a mid-flight edit (or a newer
        // probe) bumps the counter and this run's verdict is dropped whole.
        let generation = bumpValidationGeneration(for: ref)
        remoteAgentActiveProbeGenerations[ref] = generation

        do {
            // Verdict probe path is descriptor-driven: self-hosted/custom →
            // `/v1/models` (auth-gated on those servers); OpenRouter → `/v1/key`
            // (its `/v1/models` is PUBLIC, so it can't prove the key). The
            // backend carrier still selects the unified status map.
            let outcome = try await RemoteAgentClient.shared.testConnection(
                backend: carrierBackend,
                url: parsedURL,
                token: trimmedToken,
                authScheme: authScheme,
                fingerprint: effectiveFingerprint,
                probePath: descriptor.verdictProbePath,
                bodyShape: descriptor.verdictBodyShape
            )

            // Superseded — the user edited a probed field (or launched a newer
            // probe) while this one was on the wire. Its verdict describes a tuple
            // that is no longer on screen; drop it whole.
            guard isCurrentValidation(generation, for: ref) else {
                releaseSupersededProbe(generation, for: ref)
                return
            }

            // The system rejected this gateway's certificate chain. TERMINAL:
            // a pin is an additional restriction on a chain the system already
            // accepted, so nothing this editor could offer would make the
            // connection work. Name the server-side fix and stop. The presented
            // fingerprint is deliberately NOT captured — capturing it would only
            // exist to trust it later.
            if case .untrustedCert = outcome {
                remoteAgentValidationStates[ref] = .invalid(
                    message: CertificateTrustCopy.untrustedRefusalWithRemedy
                )
                return
            }

            // Discover the gateway's advertised model IDs (best-effort,
            // non-blocking) to populate the Model field's suggestion chips. A
            // second cheap GET /v1/models — PUBLIC listing is fine; only the
            // AUTH verdict moved to /v1/key. Runs for customs AND hosted
            // built-ins whose descriptor shows a model field (OpenRouter);
            // self-hosted built-ins pick their model server-side and skip it.
            let needsModelDiscovery: Bool = {
                if case .custom = ref { return true }
                return descriptor.showsModelField
            }()
            if needsModelDiscovery {
                let discoveryRef = ref
                // Per-ref generation token + clear: a slow discovery from an
                // EARLIER test/key must not overwrite the latest results.
                let discoveryGeneration = (remoteAgentModelDiscoveryGenerations[ref] ?? 0) &+ 1
                remoteAgentModelDiscoveryGenerations[ref] = discoveryGeneration
                setRemoteAgentModelSuggestions([], for: discoveryRef)
                Task { [weak self] in
                    let models = await RemoteAgentClient.shared.discoverModels(
                        url: parsedURL, token: trimmedToken, authScheme: authScheme, fingerprint: effectiveFingerprint
                    )
                    guard let self,
                          self.remoteAgentModelDiscoveryGenerations[discoveryRef] == discoveryGeneration else { return }
                    self.setRemoteAgentModelSuggestions(models, for: discoveryRef)
                }
            }

            // Validate-only — the probe passed. `saveRemoteAgent` is the single
            // commit point; do NOT persist URL/token/cert/roster/session here.
            // Reflect the normalized URL + cert back into the buffers and mark
            // `.valid`. The masked tail is NOT set — nothing is stored until Save.
            remoteAgentURLStrings[ref] = parsedURL.absoluteString
            if case .custom = ref { remoteAgentModelStrings[ref] = trimmedModel ?? "" }
            remoteAgentCertFingerprints[ref] = effectiveFingerprint
            remoteAgentValidationStates[ref] = .valid
            // A live probe actually succeeded — distinct from a save's bare
            // `.valid`. Lets the editor say "Connected" honestly.
            remoteAgentLiveValidated.insert(ref)
            remoteAgentLastErrorCodes[ref] = nil
            // Connected, but the gateway advertises no models — a caveat on the
            // green row, not a failure (see `remoteAgentProbeReportedNoModels`).
            if outcome == .okNoModels {
                remoteAgentProbeReportedNoModels.insert(ref)
            }
        } catch let error as AppError {
            guard isCurrentValidation(generation, for: ref) else {
                releaseSupersededProbe(generation, for: ref)
                return
            }
            // Keep the error's IDENTITY next to its message — the editor needs the
            // code to decide whether to offer a failure-specific remedy.
            remoteAgentLastErrorCodes[ref] = error.errorCode
            // Shape check for the hint, computed HERE where the token lives. Only a
            // `Bool` crosses into the copy layer — the key itself never does.
            // `nil` prefix hint (every self-hosted backend) → always false.
            let keyShapeLooksWrong = descriptor.tokenPrefixHint
                .map { !trimmedToken.hasPrefix($0) } ?? false
            remoteAgentValidationStates[ref] = .invalid(
                message: Self.friendlyGatewayMessage(
                    for: error,
                    category: descriptor.category,
                    keyShapeLooksWrong: keyShapeLooksWrong
                )
            )
        } catch {
            guard isCurrentValidation(generation, for: ref) else {
                releaseSupersededProbe(generation, for: ref)
                return
            }
            remoteAgentLastErrorCodes[ref] = nil
            remoteAgentValidationStates[ref] = .invalid(
                message: String(localized: "Unexpected error. Try again.")
            )
        }
    }

    /// Whether `generation` is still the newest word on `ref` — i.e. no user edit
    /// and no newer probe has landed since it was captured.
    private func isCurrentValidation(_ generation: Int, for ref: RemoteAgentRef) -> Bool {
        remoteAgentValidationGenerations[ref] == generation
    }

    /// A probe whose verdict was dropped still owns the `.checking` spinner it
    /// put on screen. Release it — but ONLY when nothing newer is in flight: if a
    /// newer probe started, that probe owns the state and will resolve it. Fall
    /// back to what the SAVED config says (`.valid` when configured, `.unset`
    /// otherwise) — never to the dropped verdict.
    private func releaseSupersededProbe(_ generation: Int, for ref: RemoteAgentRef) {
        guard remoteAgentActiveProbeGenerations[ref] == generation else { return }
        guard remoteAgentValidationStates[ref] == .checking else { return }
        remoteAgentValidationStates[ref] = configuredRemoteAgentRefSet.contains(ref) ? .valid : .unset
    }

    /// Commit ALL gateway buffers for a ref — the SINGLE persistence point (no
    /// test required; Save commits even if untested). Mirrors
    /// `saveCustomVoiceEndpoint` for the custom-voice editor. Reuses the same
    /// guards as `validateRemoteAgent` (custom name required, `https://`-only
    /// URL) and persists in the order the per-ref slots expect: roster upsert
    /// (custom) → URL → token (only if a token was typed) → cert pin. Then
    /// clears the global session + (conditionally) the active-conversation
    /// pointer and refreshes the derived snapshots. Returns `true` on a
    /// committed save, `false` when a guard rejected it.
    ///
    /// `name` is the editor's `pendingName` @State (the VM can't read it); the
    /// URL / model / cert come from the per-ref buffers. `stagedToken` is the
    /// editor's credential INTENT: `.typed` persists the fresh value, `.stored`
    /// leaves the persisted token untouched (an edit that didn't re-type it),
    /// `.reuseVoiceKey` resolves the OpenRouter voice key here and commits it
    /// together with the rest of the form — never earlier. Privacy: the resolved
    /// token flows only to Keychain; never logged or retained.
    @discardableResult
    func saveRemoteAgent(ref: RemoteAgentRef, name: String?, stagedToken: StagedRemoteAgentToken) async -> Bool {
        let backendName = displayName(for: ref)

        // Bootstrap snapshot — whether ANY gateway was already configured BEFORE
        // this save. Drives the first-gateway-ever default bootstrap at the end
        // (parity with the pairing-import path). Read the cached set SYNCHRONOUSLY
        // at method entry — an `await` here would open a suspension window before
        // the buffer reads below, letting a late `loadSettings` / remote reload
        // reset `remoteAgentAuthSchemes[ref]` mid-save (matches the View's
        // `hasAnyConfiguredRemoteAgent` snapshot, which reads the same set).
        let hadAnyConfiguredBefore = !configuredRemoteAgentRefSet.isEmpty

        // Custom-only: name required; soft 40-char cap.
        var trimmedName: String? = nil
        if case .custom = ref {
            let candidate = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else {
                remoteAgentValidationStates[ref] = .invalid(
                    message: String(localized: "remoteAgent.custom.name.required",
                                    defaultValue: "Give this gateway a name.")
                )
                return false
            }
            trimmedName = String(candidate.prefix(40))
        }

        // Built-in descriptor (drives URL-fix + auth-lock + model-field
        // persistence below). Self-hosted built-ins (OpenClaw / Hermes) have a
        // nil `fixedURL` / `lockedAuthScheme` and `showsModelField == false`, so
        // every descriptor branch is a no-op for them. Customs → nil here.
        let builtinDescriptor: RemoteAgentBackendMetadata? = {
            guard case .builtin(let backend) = ref else { return nil }
            return RemoteAgentBackendRegistry.lookup(id: backend)
        }()

        // `EndpointURLPolicy` — verbatim from the validate guard. This is the
        // SINGLE commit point for a gateway URL (the typed editor AND the
        // pairing import both land here), so it is the one gate that decides
        // what can ever reach App-Group defaults + iCloud KVS from the app side.
        // A fixed-endpoint built-in (OpenRouter) uses its app-fixed URL
        // authoritatively — the buffer was seeded to it, but pin to the
        // descriptor so a tampered / stale buffer can't redirect the request.
        let parsedURL: URL
        if let fixedURL = builtinDescriptor?.fixedURL {
            parsedURL = fixedURL
        } else {
            let trimmedURL = (remoteAgentURLStrings[ref] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty,
                  let candidate = URL(string: trimmedURL),
                  EndpointURLPolicy.isAdmissible(candidate) else {
                remoteAgentValidationStates[ref] = .invalid(
                    message: Self.remoteAgentURLRejectionMessage(trimmedURL)
                )
                return false
            }
            // Normalise HERE too, not only in `validateRemoteAgent`: Save commits
            // WITHOUT a Test, so a pasted `/v1/chat/completions` would otherwise
            // persist verbatim and every send would double-append the suffix.
            parsedURL = Self.normalizedGatewayBaseURL(candidate)
        }

        // Auth scheme drives whether a token is required. `.none` (keyless) needs
        // none; `.bearer` needs a token for a FRESH config (an EDIT that didn't
        // re-type it keeps the already-stored token — masked tail present).
        // A locked-auth built-in (OpenRouter → `.bearer`) forces its scheme so a
        // stale buffer value can't downgrade it to keyless.
        let authScheme = builtinDescriptor?.lockedAuthScheme ?? (remoteAgentAuthSchemes[ref] ?? .bearer)
        // `.typed` carries its value; `.stored` maps to "" — the empty-token
        // persistence branch below leaves the saved token untouched.
        // `.reuseVoiceKey` resolves AFTER the remaining synchronous buffer reads
        // (a Keychain await here would open the same suspension window the
        // bootstrap snapshot above avoids), so it skips this guard — its own
        // missing-key guard runs at resolution.
        var trimmedToken: String
        if case .typed(let value) = stagedToken {
            trimmedToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            trimmedToken = ""
        }
        // NOTE: the bearer no-token guard for `.stored` runs BELOW, against the
        // LIVE Keychain value — the masked tail is only cached UI state and is
        // stale in both directions (gone token → false success, cold cache →
        // false reject of a valid save).

        // Model applies to a custom ref OR a built-in whose descriptor shows the
        // model field (OpenRouter). Trim surrounding whitespace and omit an
        // empty value, but otherwise preserve the full opaque identifier.
        // Self-hosted built-ins (`showsModelField == false`) resolve nil.
        let modelApplies = (builtinDescriptor?.showsModelField ?? false)
            || { if case .custom = ref { return true } else { return false } }()
        let trimmedModel: String? = {
            guard modelApplies else { return nil }
            let candidate = (remoteAgentModelStrings[ref] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }()

        // A `.systemTrustOnly` backend (OpenRouter, public CA) must never carry a
        // pinned fingerprint: the editor HIDES the field, but a stale buffer value
        // (a legacy pin, or one seeded by a prior backend) would otherwise persist
        // and arm a future `remoteAgentCertMismatch`. CLEAR it on save (hiding the
        // field is not the same as clearing the value). Passing nil to the setter
        // removes the key. For self-hosted/custom (`.optionalUserPin`) the hand-typed
        // pin is normalized to the canonical manual-pin form (trim/lowercase/
        // strip ':' → 64 hex); a garbage pin is rejected so Save never persists an
        // unmatchable value. Empty stays "no pin".
        let effectiveFingerprint: String?
        if builtinDescriptor?.trust == .systemTrustOnly {
            effectiveFingerprint = nil
        } else {
            switch Self.normalizeCertFingerprint(remoteAgentCertFingerprints[ref]) {
            case .none: effectiveFingerprint = nil
            case .valid(let hex): effectiveFingerprint = hex
            case .invalid:
                remoteAgentValidationStates[ref] = .invalid(
                    message: String(localized: "settings.remoteAgent.fingerprint.invalid",
                                    defaultValue: "That fingerprint should be 64 hex characters.")
                )
                return false
            }
        }

        // Staged reuse resolves here — every synchronous buffer read is done, so
        // the Keychain suspension can't race a reload into the buffers above.
        // Fail closed with a field-actionable message when the voice key is gone;
        // nothing has persisted yet, so a plain `return false` keeps the
        // "nothing persisted on failure" contract for free.
        if stagedToken == .reuseVoiceKey {
            let voiceKey = (await resolveStagedToken(.reuseVoiceKey, for: ref) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !voiceKey.isEmpty else {
                remoteAgentValidationStates[ref] = .invalid(message: Self.reuseMissingVoiceKeyMessage)
                return false
            }
            trimmedToken = voiceKey
        }

        // `.stored` on a bearer lane: verify a LIVE Keychain token actually
        // exists before committing a config that claims to be usable. Same
        // placement rule as the voice-key resolution above — after every
        // synchronous buffer read, so the Keychain suspension can't race a
        // reload into the buffers. The token slot itself stays untouched (an
        // empty `trimmedToken` skips the write below), and nothing has
        // persisted yet, so the fail is clean.
        if trimmedToken.isEmpty, authScheme.requiresToken {
            let live = (await resolveStagedToken(.stored, for: ref) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !live.isEmpty else {
                remoteAgentValidationStates[ref] = .invalid(
                    message: String(localized: "Paste your \(backendName) bearer token.")
                )
                return false
            }
        }

        // Snapshot the stored URL BEFORE the save to detect a host change
        // (a token-only re-save is NOT a URL change and must not clear the
        // active-conversation pointer).
        let priorURL = await SettingsManager.shared.getRemoteAgentURL(for: ref)
        let urlChanged = (priorURL != parsedURL)

        // ATOMICITY snapshot: the Keychain token write below is the LAST persistence
        // step, but the roster upsert / URL / auth scheme all land BEFORE it. On a
        // token-write failure the contract is "nothing persisted" (spec: commits
        // atomically), so capture the pre-write state now and restore it in the
        // catch. `priorURL` (above) is the URL half; here we add the roster row (or
        // its absence for a brand-new draft) and the auth scheme.
        let priorAuthScheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: ref)
        var priorRosterEntry: CustomGateway? = nil
        if case .custom(let id) = ref {
            priorRosterEntry = await SettingsManager.shared.customGateway(id: id)
        }
        // Whether this ref had ANY persisted config before this save — a brand-new
        // custom draft (no roster row) or a never-configured built-in rolls back by
        // CLEARING; an existing config rolls back by RESTORING. Built-ins are probed
        // via the RAW stored slots, never `getRemoteAgentURL` — fixed-endpoint
        // backends (OpenRouter) synthesize their URL, so that getter reads non-nil
        // even when nothing was ever saved.
        let storedSlotsExist = await SettingsManager.shared.hasStoredRemoteAgentSlots(for: ref)
        let refExistedBefore: Bool = {
            if case .custom = ref { return priorRosterEntry != nil }
            return storedSlotsExist
        }()

        // Undo whatever landed before a mid-commit failure, restoring the
        // snapshot above. Every persistence step from here on either completes
        // the tuple or calls this — the spec contract is that a failed save
        // persists NOTHING, so a half-written store is never left behind for a
        // reader (the editor, CarPlay dispatch, the share-target snapshot) to
        // observe as a configured gateway.
        func rollbackPartialCommit() async {
            if refExistedBefore {
                await SettingsManager.shared.setRemoteAgentURL(priorURL, for: ref)
                await SettingsManager.shared.setRemoteAgentAuthScheme(priorAuthScheme, for: ref)
                if let priorRosterEntry {
                    _ = await SettingsManager.shared.upsertCustomGateway(priorRosterEntry)
                }
            } else if case .custom(let id) = ref {
                // Brand-new draft: deleteCustomGateway clears the roster row AND
                // its per-ref URL / auth-scheme / cert slots in one call.
                await SettingsManager.shared.deleteCustomGateway(id: id)
            } else {
                // Brand-new built-in configure: clear the URL + scheme just written.
                await SettingsManager.shared.setRemoteAgentURL(nil, for: ref)
                await SettingsManager.shared.clearRemoteAgentAuthScheme(for: ref)
            }
        }

        // Persist — custom roster first so per-ref slots have a complete home.
        if case .custom(let id) = ref, let trimmedName {
            let existing = customGateways.first(where: { $0.id == id })
            let usedColorIDs = customGateways
                .filter { $0.id != id }
                .compactMap { $0.colorID }
            let colorID = existing?.colorID
                ?? RemoteAgentBadgePalette.nextUnusedID(existing: usedColorIDs)
            let updated = CustomGateway(
                id: id,
                name: trimmedName,
                model: trimmedModel,
                colorID: colorID,
                monogram: existing?.monogram
            )
            // A refused upsert (roster at `Constants.maxCustomGateways`) must
            // fail the save. Reporting success here would leave a ref with
            // per-ref slots but NO roster row — which `cancelRemoteAgentEdit`
            // reads as a never-stored draft and wipes, silently destroying a
            // config the user was told had been saved. Nothing has persisted
            // yet at this point (the roster upsert is the FIRST write), so
            // returning is already clean.
            //
            // REACHABLE, despite `newCustomGatewayDraftID` refusing to mint a
            // draft at the cap: that check reads the CACHED roster, so a peer
            // device syncing its own fifth gateway in over KVS between the mint
            // and this Save closes the last slot underneath an editor that is
            // already open.
            guard await SettingsManager.shared.upsertCustomGateway(updated) else {
                remoteAgentValidationStates[ref] = .invalid(
                    message: String(localized: "settings.remoteAgent.error.capReached",
                                    defaultValue: "You've reached the custom-gateway limit. Delete one to add another.")
                )
                return false
            }
        }
        // The write fence can refuse an inadmissible URL (`EndpointURLPolicy`).
        // The guard above already rejected one, and normalisation only strips
        // query/fragment/path — so this is unreachable today and exists so a
        // future normalisation change can't turn a refused write into a
        // reported-saved gateway with no endpoint.
        guard await SettingsManager.shared.setRemoteAgentURL(parsedURL, for: ref) else {
            await rollbackPartialCommit()
            remoteAgentValidationStates[ref] = .invalid(
                message: Self.remoteAgentURLRejectionMessage(parsedURL.absoluteString)
            )
            return false
        }
        // Persist the auth scheme EXPLICITLY (never inferred downstream from a
        // nil token).
        await SettingsManager.shared.setRemoteAgentAuthScheme(authScheme, for: ref)
        if authScheme == .none {
            // Keyless: drop any stored token + masked tail. The header is omitted
            // regardless, but don't leave a stale secret behind. A clear failure
            // is non-critical — a leftover token is never sent under `.none`.
            try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
            remoteAgentMaskedTails[ref] = nil
        } else if !trimmedToken.isEmpty {
            // Persist a freshly-typed token. A FAILED write MUST NOT report
            // success: under the keyless-aware "configured" predicate a
            // URL-present bearer gateway whose token never persisted would read
            // as configured-keyless — surface the failure (fail closed) instead.
            do {
                try await SettingsManager.shared.setRemoteAgentToken(trimmedToken, for: ref)
                remoteAgentMaskedTails[ref] = maskedTail(trimmedToken)
            } catch {
                // Roll back the roster / URL / auth scheme that already persisted
                // above so the "nothing persisted on failure" contract holds — the
                // UI reports total failure, so the store must match.
                await rollbackPartialCommit()
                remoteAgentValidationStates[ref] = .invalid(
                    message: String(localized: "Couldn't save your token securely. Try again.")
                )
                return false
            }
        }
        await SettingsManager.shared.setRemoteAgentCertFingerprint(effectiveFingerprint, for: ref)
        // Built-in hosted backends (OpenRouter) keep their model in the dedicated
        // per-ref slot (customs carry it on the roster entry, persisted above).
        // Gated on `showsModelField` so self-hosted built-ins never touch the
        // slot. Empty model → cleared (setter treats nil/empty identically).
        if builtinDescriptor?.showsModelField == true {
            await SettingsManager.shared.setRemoteAgentModel(trimmedModel, for: ref)
        }
        // A URL change clears the GLOBAL active session; the
        // active-conversation pointer clears ONLY when it's bound to THIS ref.
        await SettingsManager.shared.setRemoteAgentActiveSession(nil)
        if urlChanged {
            let activeConvBackend = await activeConversationBackendRawValue()
            if Self.shouldClearActivePointer(activeConvBackend: activeConvBackend, changedRef: ref) {
                await SettingsManager.shared.clearActiveConversation()
            }
        }

        // Every persistence step succeeded — the commit is real from here on, so
        // stamp the receipt BEFORE the cache refreshes below. Order matters:
        // those refreshes each await the actor, and an editor watching the epoch
        // must not be able to observe a refreshed cache with an unbumped epoch.
        remoteAgentCommitEpoch[ref, default: 0] += 1

        // Refresh local observable state from the freshly-persisted tuple.
        remoteAgentURLStrings[ref] = parsedURL.absoluteString
        remoteAgentModelStrings[ref] = trimmedModel ?? ""
        remoteAgentCertFingerprints[ref] = effectiveFingerprint
        remoteAgentValidationStates[ref] = .valid
        // A save is NOT a live verification — drop any prior live-validated mark
        // so the editor reads "Saved" until the user runs Test Connection. The
        // no-models caveat is a rider ON that mark, so it goes with it (the two
        // sets are documented as moving in lockstep — letting them drift here
        // would leave a caveat attached to a verdict that no longer exists).
        remoteAgentLiveValidated.remove(ref)
        remoteAgentProbeReportedNoModels.remove(ref)
        customGateways = await SettingsManager.shared.customGateways()

        // BEFORE the snapshot refresh below, not after. `defaultSelectorNeedsSetup`
        // and `personalAISummaryShort` both compare the default against the
        // configured set, so publishing the set first leaves a window — one actor
        // hop, and the MainActor is free to render inside it — where the very first
        // gateway a user saves is on the list while the pointer still says
        // `.openclaw`. That reads as "Default needs setup" on the happy path,
        // moments after a successful save. `loadRemoteAgentState` already reads the
        // default before the snapshots for the same reason.
        //
        // First gateway ever configured becomes the default (parity with the
        // pairing-import bootstrap). Without it the default pointer stays unset
        // and resolves to the `.openclaw` fallback — so a Hermes-first / custom-
        // first / OpenRouter-first user would dead-end on an UNCONFIGURED default
        // (no picker below 2 gateways; new chats mint on the resolved default).
        // The setter no-ops when the pointer already equals `ref`.
        //
        // The MANAGER's setter, not this view model's: the bootstrap is the app
        // choosing on the user's behalf, so it must not retire a last-used pointer
        // the way a deliberate choice in the chooser does.
        if !hadAnyConfiguredBefore {
            await SettingsManager.shared.setDefaultRemoteAgentRef(ref)
            defaultRemoteAgentRef = ref
        }
        await refreshRemoteAgentReadinessSnapshots()
        return true
    }

    /// Cancel an in-progress gateway edit, discarding unsaved buffer edits.
    /// Keyed SOLELY on whether the ref is already in the STORE (buffers never
    /// reach storage until Save). Mirrors `cancelCustomVoiceEndpointEdit`:
    ///   - Custom DRAFT (never stored): drop the in-memory roster row + every
    ///     per-ref buffer. Nothing was persisted.
    ///   - Existing (custom or built-in): re-hydrate this ref's buffers from
    ///     storage (per-ref mirror of `loadRemoteAgentState`), discarding edits.
    /// The editor's `pendingName` / `pendingToken` are View @State, discarded on
    /// dismiss — so this only resets the VM-side per-ref buffers.
    func cancelRemoteAgentEdit(ref: RemoteAgentRef) async {
        remoteAgentModelSuggestions.removeValue(forKey: ref)
        // Snapshot the probed tuple BEFORE re-hydrating. The verdict is retracted
        // only if reverting to storage actually MOVES one of those fields (see the
        // conditional invalidation at the tail).
        //
        // An UNCONDITIONAL retract here would break the pairing-import happy path:
        // this method doubles as the post-import rehydrate, and a QR import runs a
        // REAL probe and earns a live mark — which an unconditional invalidate
        // would then throw away, downgrading a gateway we just PROVED works to a
        // bare "Saved".
        let probedTupleBefore = probedTupleSignature(for: ref)

        if case .custom(let id) = ref,
           await SettingsManager.shared.customGateway(id: id) == nil {
            // Draft — nothing was persisted, so no verdict can outlive it.
            invalidateLiveValidation(for: ref)
            // Draft — nothing persisted. Drop the in-memory row + per-ref buffers.
            customGateways.removeAll { $0.id == id }
            remoteAgentURLStrings.removeValue(forKey: ref)
            remoteAgentModelStrings.removeValue(forKey: ref)
            remoteAgentCertFingerprints.removeValue(forKey: ref)
            remoteAgentAuthSchemes.removeValue(forKey: ref)
            remoteAgentMaskedTails.removeValue(forKey: ref)
            remoteAgentValidationStates.removeValue(forKey: ref)
            return
        }

        // Existing — re-hydrate this ref's buffers from storage, discarding edits.
        let storedURL = await SettingsManager.shared.getRemoteAgentURL(for: ref)
        remoteAgentURLStrings[ref] = storedURL?.absoluteString ?? ""
        if case .custom(let id) = ref {
            remoteAgentModelStrings[ref] = (await SettingsManager.shared.customGateway(id: id))?.model ?? ""
        }
        remoteAgentCertFingerprints[ref] = await SettingsManager.shared.getRemoteAgentCertFingerprint(for: ref) ?? ""
        var authScheme = await SettingsManager.shared.getRemoteAgentAuthScheme(for: ref)
        // Built-in descriptor seeding (mirror of `loadRemoteAgentState`): a
        // locked-auth built-in (OpenRouter) re-pins its scheme, and a
        // model-bearing built-in re-hydrates its persisted model. Self-hosted
        // built-ins (nil `lockedAuthScheme`, `showsModelField == false`) no-op.
        // `getRemoteAgentURL` already returned the fixed URL for a
        // fixed-endpoint built-in above, so the URL buffer is correct.
        if case .builtin(let backend) = ref {
            let descriptor = RemoteAgentBackendRegistry.lookup(id: backend)
            if let locked = descriptor.lockedAuthScheme {
                authScheme = locked
            }
            if descriptor.showsModelField {
                remoteAgentModelStrings[ref] = await SettingsManager.shared.getRemoteAgentModel(for: ref) ?? ""
            }
        }
        remoteAgentAuthSchemes[ref] = authScheme
        let storedToken = await SettingsManager.shared.getRemoteAgentToken(for: ref)
        let hasToken = (storedToken?.isEmpty == false)
        if hasToken {
            remoteAgentMaskedTails[ref] = maskedTail(storedToken!)
        } else {
            remoteAgentMaskedTails.removeValue(forKey: ref)
        }
        // Keyless-aware: `.none` is `.valid` on URL alone; `.bearer` needs a token.
        let configured = (storedURL != nil) && (authScheme == .none || hasToken)
        remoteAgentValidationStates[ref] = configured ? .valid : .unset

        // Retract the live verdict ONLY if reverting to storage actually moved a
        // probed field. Discarding real edits → the mark described a tuple that is
        // no longer on screen, so it goes. Re-hydrating onto values identical to
        // what was just probed (the pairing-import rehydrate) → the mark still
        // describes exactly what's on screen, so it stays.
        if probedTupleSignature(for: ref) != probedTupleBefore {
            invalidateLiveValidation(for: ref)
        }

        // Re-read the configured set from storage too. This method's contract is
        // "make VM state for this ref match storage", and that set is VM state
        // about this ref — leaving it behind is what kept a just-imported gateway
        // reading unconfigured after the post-Quick-connect rehydrate, greying
        // out File transfer and labelling Quick connect "Set up" on a gateway
        // that was already set up. Whole-set (not a per-ref insert) because
        // `configuredRemoteAgentRefs()` is the single authority on the predicate.
        await refreshRemoteAgentReadinessSnapshots()
    }

    /// The tuple a live verdict is a claim ABOUT: change any of it and a previous
    /// "Connected" (or a failure-specific remedy) no longer describes what's on
    /// screen. The token is represented by its masked tail — the VM never holds
    /// the secret, and the tail moves whenever the stored token does.
    private func probedTupleSignature(for ref: RemoteAgentRef) -> String {
        [
            remoteAgentURLStrings[ref] ?? "",
            remoteAgentCertFingerprints[ref] ?? "",
            (remoteAgentAuthSchemes[ref] ?? .bearer) == .none ? "none" : "bearer",
            remoteAgentMaskedTails[ref] ?? "",
        ].joined(separator: "\u{1F}")
    }

    /// Whether `name` clashes (case-insensitively) with any OTHER configured
    /// gateway — a built-in display name or another custom's roster name.
    /// Drives the editor's inline duplicate-name WARNING (warn, don't block;
    /// the save still proceeds). `excludingID` skips the gateway being edited.
    func remoteAgentNameClashes(_ name: String, excludingID: UUID?) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        for backend in RemoteAgentBackend.allCases where backend.displayName.lowercased() == candidate {
            return true
        }
        for gateway in customGateways where gateway.id != excludingID {
            if gateway.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate {
                return true
            }
        }
        return false
    }

    /// The editor's single Test Connection entry — resolves the staged token
    /// INTENT in-actor and routes to the right probe (validate-only; Save is
    /// the commit point). Keyless (`.none`) probes with no token regardless of
    /// what's staged; `.stored` re-tests the saved config (Keychain read stays
    /// VM-side); `.typed` / `.reuseVoiceKey` probe the resolved credential.
    /// A `.reuseVoiceKey` that resolves to nothing fails closed with the same
    /// field-actionable message as Save — no probe fires.
    /// URL / fingerprint / auth scheme / model come from the per-ref buffers.
    func testRemoteAgent(ref: RemoteAgentRef, stagedToken: StagedRemoteAgentToken, name: String?) async {
        let url = remoteAgentURLStrings[ref] ?? ""
        let fingerprint = remoteAgentCertFingerprints[ref]
        let authScheme = remoteAgentAuthSchemes[ref] ?? .bearer
        let model = remoteAgentModelStrings[ref]
        // Keyless: probe with NO token (header omitted). Route through
        // `validateRemoteAgent` (not `retest`) so a fresh draft's name/model
        // buffers are seen by the required-name guard.
        if authScheme == .none {
            await validateRemoteAgent(
                ref: ref, url: url, token: "", authScheme: .none,
                fingerprint: fingerprint, name: name, model: model
            )
            return
        }
        switch stagedToken {
        case .stored:
            await retestRemoteAgent(ref: ref, url: url)
        case .typed, .reuseVoiceKey:
            let token = (await resolveStagedToken(stagedToken, for: ref) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stagedToken == .reuseVoiceKey, token.isEmpty {
                remoteAgentValidationStates[ref] = .invalid(message: Self.reuseMissingVoiceKeyMessage)
                return
            }
            await validateRemoteAgent(
                ref: ref, url: url, token: token, authScheme: .bearer,
                fingerprint: fingerprint, name: name, model: model
            )
        }
    }

    /// Re-test an ALREADY-CONFIGURED gateway without forcing the user to
    /// re-paste the bearer token. Reads the stored token from Keychain in-actor
    /// (never surfaced to the UI) and routes through `validateRemoteAgent`
    /// (validate-only — Save commits) with the current field URL + pin, reusing
    /// the existing probe / friendly-error handling intact.
    func retestRemoteAgent(ref: RemoteAgentRef, url: String) async {
        let backendName = displayName(for: ref)
        let authScheme = remoteAgentAuthSchemes[ref] ?? .bearer
        let storedToken = await SettingsManager.shared.getRemoteAgentToken(for: ref)
        // `.bearer` needs a stored token to re-test; `.none` (keyless) re-tests
        // with no header (the stored token, if any, is ignored).
        if authScheme.requiresToken, (storedToken?.isEmpty ?? true) {
            remoteAgentValidationStates[ref] = .invalid(
                // xcstrings: mac-ui-polish
                message: String(localized: "No saved token to test. Paste your \(backendName) token first.")
            )
            return
        }
        let token = storedToken ?? ""
        // A custom re-test must keep its roster name/model — read from the
        // cached roster (the editor fields aren't passed on a re-test).
        let custom: CustomGateway? = {
            guard case .custom(let id) = ref else { return nil }
            return customGateways.first(where: { $0.id == id })
        }()
        await validateRemoteAgent(
            ref: ref,
            url: url,
            token: token,
            authScheme: authScheme,
            fingerprint: remoteAgentCertFingerprints[ref],
            name: custom?.name,
            model: remoteAgentModelStrings[ref] ?? custom?.model
        )
    }

    /// Resolve the backend raw value the CURRENTLY-active conversation is bound
    /// to, or nil when there is no active conversation pointer (or the record
    /// can't be fetched). Used by the refined pointer-clear rule. The pointer
    /// itself is global; the backend binding lives on the `ConversationRecord`.
    private func activeConversationBackendRawValue() async -> String? {
        guard let id = await SettingsManager.shared.currentActiveConversationID() else {
            return nil
        }
        let record = try? await ConversationStore.shared.fetchConversation(id: id)
        return record?.backend
    }

    /// Refined pointer-clear decision. The active-conversation pointer
    /// is GLOBAL (Decision A), so a per-backend URL/token edit must clear it
    /// ONLY when it would actually corrupt the active thread:
    ///   - No active conversation (`activeConvBackend == nil`) → nothing to
    ///     clear → `false`.
    ///   - Active conversation bound to a DIFFERENT backend → leaving the
    ///     pointer is safe (that thread's host didn't change) → `false`.
    ///   - Active conversation bound to THIS backend (or an unrecognized raw
    ///     value that maps to this backend) → clear → `true`.
    /// Pure + static so the test suite can drive it without a network mock.
    static func shouldClearActivePointer(
        activeConvBackend: String?,
        changedRef: RemoteAgentRef
    ) -> Bool {
        guard let activeConvBackend else { return false }
        return activeConvBackend == changedRef.rawString
    }

    /// Map `AppError` → user-facing message for EVERY gateway-probe surface: the
    /// per-ref editor row (`validateRemoteAgent`) and the pairing-import sheet
    /// (`runPairingGatewayTest`). ONE mapping — a second copy silently diverges,
    /// and the flow that keeps the stale copy goes on swallowing new failures.
    ///
    /// The `default:` falls through to `errorDescription`, NOT a generic "try
    /// again": a curated case list can only ever be behind the error enum, and
    /// every failure it hasn't heard of would otherwise render as an unactionable
    /// shrug. Safe by construction — `AppError.errorDescription` is a curated
    /// string per case and never echoes an associated payload (`.apiFailure`'s
    /// server text included; `AppErrorTests` locks that).
    ///
    /// Static + secret-free: no backend name, token, or URL can be interpolated in.
    /// `keyShapeLooksWrong` is a `Bool`, NEVER the key — that is what makes the
    /// secret-free property hold by construction rather than by care.
    ///
    /// Copy is selected by `category`, not by backend identity: a hosted provider
    /// (OpenRouter) is a service the user does NOT operate, so self-hosted remedies
    /// ("check the gateway is running", "check the gateway logs") are not merely
    /// unhelpful — they describe a machine that does not exist. Dispatching on the
    /// descriptor's category keeps a future hosted preset (Groq / Together) a
    /// one-row addition, per `RemoteAgentBackendMetadata`'s stated design.
    ///
    /// These keys live under `remoteAgent.editor.*`, deliberately SEPARATE from the
    /// `remoteAgent.error.*` keys behind `AppError.recoverySuggestion`. The latter
    /// are correct in their own surfaces (Diagnostics, CarPlay) where "Open Settings"
    /// IS the remedy, and are versioned rather than frozen — a rewording moves to a
    /// new `.v2` key, because a catalogued value wins over `defaultValue:`. Here the
    /// user is already standing in the editor with the field on screen, so the remedy
    /// is to fix the value in front of them.
    static func friendlyGatewayMessage(
        for error: AppError,
        category: RemoteAgentCategory = .selfHostedAgent,
        keyShapeLooksWrong: Bool = false
    ) -> String {
        let hosted = category == .hostedModel
        switch error {
        case .remoteAgentAuthFailed:
            if hosted {
                // A truncated paste is the commonest cause of a 401 on a hosted
                // lane. Say so, rather than sending the user to a dashboard to
                // re-copy a key that was already correct.
                return keyShapeLooksWrong
                    ? String(localized: "remoteAgent.editor.authFailed.hosted.badShape",
                             defaultValue: "That API key was rejected — and it doesn't look like a complete OpenRouter key (they start with sk-or-). Check the paste and try again.")
                    : String(localized: "remoteAgent.editor.authFailed.hosted",
                             defaultValue: "That API key was rejected. Check it in your OpenRouter dashboard, then paste it again.")
            }
            return String(localized: "remoteAgent.editor.authFailed.selfHosted",
                          defaultValue: "That bearer token was rejected. Check your gateway's token, then paste it again.")
        case .remoteAgentUnreachable, .noInternetConnection, .networkError:
            if hosted {
                return String(localized: "remoteAgent.editor.unreachable.hosted",
                              defaultValue: "Couldn't reach OpenRouter. Check your internet connection and try again.")
            }
            return String(localized: "remoteAgent.error.unreachable.recovery",
                          defaultValue: "Check the gateway is running and accessible from this device.")
        case .remoteAgentTimeout, .requestTimeout:
            return String(localized: "remoteAgent.error.timeout.recovery",
                          defaultValue: "Try again — the gateway may be processing a long reply.")
        case .remoteAgentCertMismatch:
            // Unreachable for a hosted backend (`.systemTrustOnly` never pins).
            // The shared refusal + remedy, verbatim: the editor is the surface
            // most likely to reach for the pin field, and this is exactly where
            // the copy must NOT offer to drop the pin that caught the problem.
            return CertificateTrustCopy.pinMismatchRefusalWithRemedy
        case .remoteAgentCertUntrusted:
            // The shared refusal + remedy, verbatim: the editor is where the
            // user is most likely to reach for a pin, and this is exactly where
            // the copy must say a pin cannot help.
            return CertificateTrustCopy.untrustedRefusalWithRemedy
        case .remoteAgentCertKeyUnpinnable:
            // The shared refusal + remedy, verbatim. `default:` would render the
            // cause with no way out, and this is the ONE screen holding the saved
            // fingerprint — so the "clear the saved fingerprint" half of the
            // remedy points at a field the user is already looking at. Legitimate
            // here alone: system trust passed, so clearing the pin returns the
            // connection to the evaluation that is already succeeding.
            return CertificateTrustCopy.keyUnpinnableRefusalWithRemedy
        case .remoteAgentServerError:
            if hosted {
                return String(localized: "remoteAgent.editor.serverError.hosted",
                              defaultValue: "OpenRouter had a server error. Try again in a moment.")
            }
            return String(localized: "remoteAgent.error.serverError.recovery",
                          defaultValue: "Check the gateway logs, then try again.")
        case .remoteAgentInvalidResponse:
            if hosted {
                return String(localized: "remoteAgent.editor.invalidResponse.hosted",
                              defaultValue: "OpenRouter returned an unexpected response. Try again.")
            }
            return String(localized: "remoteAgent.error.invalidResponse.recovery",
                          defaultValue: "Check the gateway is running an OpenAI-compatible /v1/chat/completions endpoint.")
        case .remoteAgentEndpointUnexpectedResponse, .remoteAgentEndpointWrongEnvelope,
             .remoteAgentEndpointNotFound, .remoteAgentModelRequired,
             .remoteAgentOutOfCredits, .remoteAgentRateLimited:
            // These describe a MISCONFIGURED-but-reachable gateway, or a reachable
            // provider refusing THIS request (no credits / rate-limited), so the
            // remedy (`recoverySuggestion`) is the whole message — the editor pairs
            // it with the per-backend fix-it callout. Out-of-credits and
            // rate-limited belong here and not in `default:`: their bare
            // `errorDescription` ("Your AI provider is rate-limiting you.") states
            // the symptom and withholds the fix, and 429 is routine on a hosted
            // lane's free models.
            return error.recoverySuggestion
                ?? error.errorDescription
                ?? String(localized: "Unexpected error. Try again.")
        default:
            return error.errorDescription ?? String(localized: "Unexpected error. Try again.")
        }
    }

    /// Wipe a SINGLE backend's Personal AI configuration: URL, token, cert —
    /// AND the file-server lane bound to the same ref. Used by the per-backend
    /// "Forget gateway" destructive action. Each writer posts
    /// `.settingsDidChangeRemotely`; the Watch picks up the cleared state from
    /// the next envelope absence (`currentRemoteAgentEnvelope()` returns nil
    /// when the default backend's URL is missing).
    ///
    /// File lane: Forget is the TERMINAL per-ref wipe, so it must reach every
    /// slot keyed by `ref.storageKeySuffix` — including
    /// `fileServer.{url,credential,certFingerprint,available,…}`. Leaving them
    /// behind is not merely residue: a built-in's ref is REUSED, so
    /// `fileTransferReadySnapshot(for:)` (url + credential + `available`, all
    /// three survivors) would re-arm the lane against the OLD file server on the
    /// next reconfigure, and the next document would PUT to a host the user's
    /// Forget said they were done with. For a deleted CUSTOM the suffix is never
    /// reused, so the slots would be orphaned with no UI able to reach them (the
    /// only purge route, the file-transfer page, is gated on
    /// `isRemoteAgentConfigured(ref)`).
    ///
    /// Default-pointer policy (Decision B, recommended path): if the cleared
    /// backend was the default AND another backend remains configured, repoint
    /// the default to that one (so the user keeps a working default). If no
    /// other configured backend exists, leave the default pointer as-is — a
    /// later send to an unconfigured default surfaces `remoteAgentNotConfigured`,
    /// consistent with Decision B.
    ///
    /// Active-conversation pointer: same refined rule as
    /// `validateAndSaveRemoteAgent` — clear the GLOBAL pointer ONLY when the
    /// active conversation is bound to THIS (now-forgotten) backend.
    func clearRemoteAgent(for ref: RemoteAgentRef) async {
        // Refined pointer-clear: drop the active-conversation pointer ONLY when
        // it is bound to the ref being forgotten. Capture BEFORE the slot wipe.
        let activeConvBackend = await activeConversationBackendRawValue()
        let shouldClearPointer = Self.shouldClearActivePointer(
            activeConvBackend: activeConvBackend,
            changedRef: ref
        )

        // File lane FIRST (invalidate-first ordering, same doctrine as
        // `clearFileTransferConfig` itself): `available=false` must reach iCloud
        // KVS no later than the gateway teardown, so no peer can pair a
        // reconfigured gateway with a Ready the forgotten server earned.
        //
        // Deliberately attached HERE — at the user-intent Forget site — and NOT
        // inside `SettingsManager.deleteCustomGateway(id:)` or
        // `clearRemoteAgentAuthScheme(for:)`. Both of those double as the
        // token-write-FAILURE rollback for a brand-new save (see
        // `validateAndSaveRemoteAgent`), and a 32-hex credential destroyed by a
        // transient Keychain error is unrecoverable — the user would have to
        // re-provision their server. A destructive credential wipe must hang off
        // an explicit user intent, never off a shared rollback helper.
        await clearFileTransferConfig(for: ref)

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
            // the roster entry + repoints the default to a built-in if it
            // pointed here — the whole "forget a custom" operation. Don't
            // double-wipe the per-ref slots here.
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
            // Recompute the configured set, then re-point the default if needed
            // (built-in branch — the custom branch's repoint is inside
            // `deleteCustomGateway`).
            let stillConfigured = await SettingsManager.shared.configuredRemoteAgentRefs()
            let currentDefault = await SettingsManager.shared.defaultRemoteAgentRef()
            if currentDefault == ref,
               let replacement = stillConfigured.first(where: { $0 != ref }) {
                await SettingsManager.shared.setDefaultRemoteAgentRef(replacement)
            }
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

        // Refresh local per-ref view-model state. A fixed-endpoint built-in
        // (OpenRouter) re-seeds its app-fixed URL: the editor HIDES its URL
        // field, so an empty buffer would otherwise dead-end every later
        // Save/Test (`canSave` reads this buffer) until the editor is closed
        // and reopened — the forget→reconfigure path stays live.
        if case .builtin(let backend) = ref,
           let fixed = RemoteAgentBackendRegistry.lookup(id: backend).fixedURL {
            remoteAgentURLStrings[ref] = fixed.absoluteString
        } else {
            remoteAgentURLStrings[ref] = ""
        }
        remoteAgentModelStrings.removeValue(forKey: ref)
        remoteAgentCertFingerprints.removeValue(forKey: ref)
        remoteAgentAuthSchemes[ref] = .bearer   // reset to the fail-closed default
        remoteAgentMaskedTails.removeValue(forKey: ref)
        remoteAgentValidationStates[ref] = .unset
        // Forgetting is the strongest edit there is — retract the verdict and
        // disown any probe still in flight against the wiped config.
        invalidateLiveValidation(for: ref)
        customGateways = await SettingsManager.shared.customGateways()
        // Default first, snapshots second — same ordering rule as
        // `validateAndSaveRemoteAgent` above: the two are compared against each
        // other, so publishing the set while the pointer is still the gateway the
        // user just forgot flashes "Needs setup" against its name.
        defaultRemoteAgentRef = await SettingsManager.shared.defaultRemoteAgentRef()
        await refreshRemoteAgentReadinessSnapshots()
    }

    // MARK: - File Transfer (Agent File Transfer / file-server) — lifecycle
    //
    // The setup-guide-facing surface for a ref's user-run file-server. Mirrors
    // the gateway lifecycle (`validateAndSaveRemoteAgent` / `clearRemoteAgent`)
    // but for the file-server's URL + client-minted credential + per-device cert
    // pin + the staged Test Connection result.
    //
    // Privacy invariants (spec.md "Privacy & Security"): the minted credential
    // appears ONLY (a) in Keychain, (b) in the guide's masked, session-only
    // credential row the user deliberately reveals/copies (via
    // `mintedFileServerCredentials`). It is NEVER logged, NEVER read back into
    // any other label, NEVER put in an error string. URLs / pins are non-secret
    // but still never logged here.

    /// Validate the file-server URL for `ref` (https-only gate) and, on a valid
    /// `https://` URL, persist it via `SettingsManager.setFileServerURL(_:for:)`.
    /// Mirrors the gateway URL validation in `validateAndSaveRemoteAgent`:
    /// `http://` / empty / unparseable → `.invalid` validation state (so macOS,
    /// which has no banner, still surfaces an error) — never crashes.
    ///
    /// Unlike the gateway save, this does NOT probe the network or persist a
    /// credential — the credential is minted separately
    /// (`regenerateFileServerCredential`) and the connection is proven by the
    /// staged `runFileTransferTest(for:)`. It DOES persist the optional manual pin
    /// the user typed in the setup guide's Server certificate sheet (normalized here
    /// the same way the gateway pin is). Nothing else can ever write a pin: a
    /// fingerprint reaches storage only because the user typed it, and it only
    /// narrows a chain the system already accepted.
    /// File-server editor cert-pin field writes the buffered fingerprint for a ref
    /// (setup guide's Server certificate row). Change-guarded, mirroring
    /// `setRemoteAgentCertFingerprintBuffer`. Persisted by
    /// `validateAndSaveFileTransferConfig` alongside the URL. A pin edit needs no
    /// explicit verdict retraction — the staged verdict is signature-keyed, so a
    /// diverged pin simply stops matching and the verdict goes dark on its own.
    func setFileServerCertFingerprintBuffer(_ fingerprint: String, for ref: RemoteAgentRef) {
        guard fileServerCertFingerprints[ref] != fingerprint else { return }
        fileServerCertFingerprints[ref] = fingerprint
    }

    /// Drop a ref's file-transfer availability — persisted flag AND the
    /// in-memory cache `isFileTransferAvailable` reads — as one idiom, so no
    /// call site can update one and forget the other. Internal (not private):
    /// the pairing-import extension lives in its own file.
    func dropFileTransferAvailability(for ref: RemoteAgentRef) async {
        await SettingsManager.shared.setFileTransferAvailable(false, for: ref)
        fileTransferAvailableRefSet.remove(ref)
    }

    /// A ref's file-server credential was ROTATED (regenerate / pairing
    /// import): bump the generation so no existing signature can match, and
    /// retire the verdict the old password earned. One idiom for every
    /// credential writer — a writer that bumps without retiring (or vice
    /// versa) would let a dead credential's verdict survive. Internal: the
    /// pairing-import extension lives in its own file.
    func noteFileServerCredentialRotated(for ref: RemoteAgentRef) {
        fileServerCredentialGenerations[ref] = (fileServerCredentialGenerations[ref] ?? 0) + 1
        fileTransferTestResults.removeValue(forKey: ref)
        fileTransferTestSignatures.removeValue(forKey: ref)
    }

    /// Does this URL carry `user:password@` userinfo? Thin forwarder to the
    /// canonical `EndpointURLPolicy` so the save path, the draft signature, and
    /// the Test path cannot drift on the answer — and so the file-server field's
    /// existing call sites keep reading as one predicate rather than three.
    ///
    /// Why REJECT rather than silently strip: a user who typed a password
    /// believes they configured auth. Stripping it leaves them debugging a 401
    /// with no explanation; the reject names the real model and points them at
    /// the row where the secret actually belongs.
    ///
    /// Applies to the GATEWAY URL too — see `EndpointURLPolicy` for why that is
    /// not an exception and what capability it removes.
    static func urlCarriesUserinfo(_ url: URL) -> Bool {
        EndpointURLPolicy.carriesUserinfo(url)
    }

    /// WHICH defect the three field derivations below should NAME for
    /// `trimmedURL`, or nil when the generic "enter the full URL including
    /// https://" prompt is the honest answer. Factored out so the three cannot
    /// drift on the diagnosis; the copy itself stays per-field (each names its
    /// own example host, and its own place for the secret).
    ///
    /// Two inputs deliberately land on the generic prompt rather than on the
    /// `.noHost` copy:
    ///
    ///   - The EMPTY field. "Not filled in" is not "missing a host name".
    ///
    ///   - Anything whose scheme is not `https` — which is what the COMMONEST
    ///     typo looks like. `gateway.example.com` parses with `scheme` AND
    ///     `host` both nil (the whole string becomes the path), and
    ///     `gw.example.com:18789` parses with the HOST as its scheme, so
    ///     `EndpointURLPolicy` answers `.noHost` for a user who typed nothing
    ///     BUT a host name. Telling them their host name is missing names the
    ///     one part they got right and hides the part they omitted.
    ///
    /// The correction belongs here rather than in the policy: that
    /// `Rejection` precedence (`noHost` → `notHTTPS` → `carriesUserinfo`) is
    /// load-bearing for `PairingPayload`'s `.malformed` / `.insecureURL` split
    /// and is pinned by `EndpointURLPolicyTests`. Admissibility and diagnosis
    /// are different questions; only the second one is copy.
    private static func namedURLRejection(_ trimmedURL: String) -> EndpointURLPolicy.Rejection? {
        guard !trimmedURL.isEmpty,
              let url = URL(string: trimmedURL),
              let rejection = EndpointURLPolicy.rejection(for: url)
        else { return nil }
        // A hostless verdict is only worth naming when the string already IS an
        // https URL (`https://`, `https:///v1`). Otherwise the scheme is the
        // actionable defect.
        if rejection == .noHost, url.scheme?.lowercased() != "https" { return nil }
        return rejection
    }

    /// The inline `.invalid` copy for a custom voice-endpoint URL the app won't
    /// accept. Third twin of the gateway / file-server derivations below —
    /// same policy, same one-story-per-string rule across Test and Save.
    static func customSTTURLRejectionMessage(_ trimmedURL: String) -> String {
        switch namedURLRejection(trimmedURL) {
        case .carriesUserinfo?:
            return String(localized: "settings.stt.custom.url.userinfo",
                          defaultValue: "Take the username and password out of the address. Conduck won't keep a password inside a URL — that address syncs between your devices as plain text. Your endpoint's key goes in the API key field.")
        case .noHost?:
            return String(localized: "settings.stt.custom.url.noHost",
                          defaultValue: "That address is missing its host name — it should look like https://voice.example.com.")
        default:
            return String(localized: "settings.stt.custom.url.invalid",
                          defaultValue: "Enter the full endpoint URL including https://.")
        }
    }

    /// The inline `.invalid` copy for a gateway URL the app won't accept —
    /// specific for userinfo, specific for a hostless address, generic
    /// otherwise (which defect gets named: `namedURLRejection`). ONE derivation
    /// so Save and Test can never tell the user two different stories about the
    /// same string (twin of `fileServerURLRejectionMessage`).
    static func remoteAgentURLRejectionMessage(_ trimmedURL: String) -> String {
        switch namedURLRejection(trimmedURL) {
        case .carriesUserinfo?:
            return String(localized: "settings.remoteAgent.url.userinfo",
                          defaultValue: "Take the username and password out of the address. Conduck won't keep a password inside a URL — that address syncs between your devices as plain text. Your gateway's token goes in the Token field.")
        case .noHost?:
            return String(localized: "settings.remoteAgent.url.noHost",
                          defaultValue: "That address is missing its host name — it should look like https://ai.example.com.")
        default:
            return String(localized: "Enter the full gateway URL including https://.")
        }
    }

    /// The inline `.invalid` copy for a file-server URL the app won't accept —
    /// specific for userinfo, specific for a hostless address, generic
    /// otherwise (which defect gets named: `namedURLRejection`). ONE derivation
    /// so the save path and the Test path can never tell the user two different
    /// stories about the same string.
    private static func fileServerURLRejectionMessage(_ trimmedURL: String) -> String {
        switch namedURLRejection(trimmedURL) {
        case .carriesUserinfo?:
            return String(localized: "fileTransfer.url.userinfo",
                          defaultValue: "Don't include a username or password in the URL — Conduck manages the credential for you. Use the address only, and give the generated password to your server.")
        case .noHost?:
            return String(localized: "fileTransfer.url.noHost",
                          defaultValue: "That address is missing its host name — it should look like https://files.example.com.")
        default:
            return String(localized: "fileTransfer.url.invalid",
                          defaultValue: "Enter the full file-server URL including https://.")
        }
    }

    func validateAndSaveFileTransferConfig(urlString: String, for ref: RemoteAgentRef) async {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // `EndpointURLPolicy` — https (so the basic-auth credential can never
        // leave the device in cleartext), a real host, and no `user:password@`
        // (the URL is dual-written to App-Group defaults + iCloud KVS, so it
        // must never carry a secret). Verbatim shape from the gateway's guard.
        guard !trimmedURL.isEmpty,
              let parsedURL = URL(string: trimmedURL),
              EndpointURLPolicy.isAdmissible(parsedURL) else {
            fileServerValidationStates[ref] = .invalid(
                message: Self.fileServerURLRejectionMessage(trimmedURL)
            )
            return
        }

        // Normalize the optional manual pin to the canonical manual-pin
        // form — trim/lowercase/strip ':' → require 64 hex. Reject garbage BEFORE
        // persisting the URL so a bad pin can never leave a saved URL paired with an
        // unmatchable fingerprint. Empty stays "no pin" (system trust).
        let pin: String?
        switch Self.normalizeCertFingerprint(fileServerCertFingerprints[ref]) {
        case .none: pin = nil
        case .valid(let hex): pin = hex
        case .invalid:
            fileServerValidationStates[ref] = .invalid(
                message: String(localized: "settings.remoteAgent.fingerprint.invalid",
                                defaultValue: "That fingerprint should be 64 hex characters.")
            )
            return
        }

        // The tuple being committed, as a test signature. If the staged verdict
        // was earned against EXACTLY this tuple, the Save carries it — a passing
        // draft test becomes availability at commit, and a failed one stays an
        // honest "Needs attention" (never laundered into "Not tested yet").
        let newSignature = FileTransferTestSignature(
            url: parsedURL.absoluteString,
            pin: pin ?? "",
            credentialGeneration: fileServerCredentialGenerations[ref] ?? 0
        )
        let carriedVerdict: FileTransferTestResult? =
            (fileTransferTestSignatures[ref] == newSignature) ? fileTransferTestResults[ref] : nil
        let carriedPass = carriedVerdict?.success == true
        // The listing half of the carried verdict, and only when it settled —
        // "settled" defined once, on the result itself, so this path and the
        // staged-verdict commit cannot disagree about what counts as evidence.
        let carriedSettledListing: Bool? =
            carriedPass ? carriedVerdict?.settledReturnCapability : nil

        // ONE actor hop commits URL + pin + capability + availability together
        // (no suspension inside), so a concurrent `fileTransferSnapshot` sees
        // either the old consistent tuple or the new one — never Ready over a
        // mixed half-write. Availability re-earns at the commit ONLY when a
        // passing verdict proves exactly this tuple; capability persists only
        // with that pass (a carried failure has no real capability signal).
        // The commit also transitions the device-local probe provenance in the
        // same hop — local test proof follows availability (a carried pass IS
        // this device's staged pass) and the silent-probe markers re-arm — so
        // the KVS-mirror revocation doctrine (no device or peer may pair the
        // new tuple with a Ready/proof the OLD tuple earned) holds by
        // construction. See `commitFileTransferConfig`.
        await SettingsManager.shared.commitFileTransferConfig(
            url: parsedURL,
            pin: pin,
            folderCapable: carriedPass ? carriedVerdict?.folderCapable : nil,
            // A tuple commit RESETS the listing verdict by default, because the
            // verdict described whatever server the old tuple pointed at. Only a
            // draft test that SETTLED the question against exactly this tuple
            // may state one — an unsettled draft pass resets like everything
            // else, since nothing measured the new server.
            returnCapable: carriedSettledListing.map { .set($0) } ?? .resetToUnknown,
            available: carriedPass,
            for: ref
        )
        if carriedPass {
            fileTransferAvailableRefSet.insert(ref)
        } else {
            fileTransferAvailableRefSet.remove(ref)
        }
        await refreshFileTransferUploadOnlyMirror(for: ref)

        // A persisted URL now exists — flip the mirror the setup-state derivation
        // reads (a typed-but-unsaved URL never reaches here, so never reads
        // "saved"), and reflect the canonical forms back into the buffers +
        // persisted baselines.
        fileServerURLPresent[ref] = true
        if let pin {
            fileServerCertFingerprints[ref] = pin
            fileServerPersistedPins[ref] = pin
        } else {
            fileServerCertFingerprints.removeValue(forKey: ref)
            fileServerPersistedPins.removeValue(forKey: ref)
        }
        fileServerURLStrings[ref] = parsedURL.absoluteString
        fileServerPersistedURLStrings[ref] = parsedURL.absoluteString
        fileServerValidationStates[ref] = .valid

        if carriedVerdict == nil {
            // No verdict for THIS tuple — drop any stale one so the lane reads
            // the honest "Saved — not tested yet". (A carried FAILED verdict is
            // deliberately KEPT: saving the tuple that just failed must read
            // "Needs attention", not reset to neutral.)
            fileTransferTestResults.removeValue(forKey: ref)
            fileTransferTestSignatures.removeValue(forKey: ref)
        }
    }

    /// Mint a fresh client-minted file-server credential for `ref`: 32 lowercase
    /// hex digits from `SystemRandomNumberGenerator` (16 random bytes → hex),
    /// store it in Keychain via `SettingsManager.setFileServerCredential`, and
    /// RETURN the minted secret so the caller (the setup guide) can show it in
    /// the masked credential row — or nil when the Keychain write failed, in
    /// which case NOTHING was published (a plaintext Keychain doesn't hold must
    /// never be shown for copying). It is MINTED, never user-entered.
    ///
    /// Regenerating ROTATES the secret — the user must give the new password to
    /// their file server after rotating (the old one stops working there until
    /// they do). The returned value is also stashed in
    /// `mintedFileServerCredentials[ref]` so the credential row keeps showing
    /// the real password for the duration of the open guide (cleared on dismiss
    /// via `forgetMintedFileServerCredential`).
    ///
    /// Privacy: the returned string is the plaintext credential — the caller
    /// renders it ONLY into the masked credential row, never into a log.
    @discardableResult
    func regenerateFileServerCredential(for ref: RemoteAgentRef) async -> String? {
        let secret = Self.mintCredentialHex()
        // Fail-closed order: revoke readiness BEFORE the Keychain write — a
        // rotation invalidates the LIVE server config until the user gives the
        // server the new password and retests, and the moment the new secret
        // lands a Ready snapshot would carry a password the server doesn't
        // know. The revocation (persisted flag, local test proof, probe
        // markers, AND the in-memory cache `isFileTransferAvailable` reads)
        // reaches iCloud KVS ahead of the new credential a peer's iCloud
        // Keychain syncs: no device may pair the rotated credential with a
        // Ready the OLD password earned. The prior flags are captured so a
        // FAILED rotation restores them: on failure the old credential is
        // still in Keychain and still valid server-side — a still-working
        // lane must not stay demoted by a write that never happened.
        let wasAvailable = await SettingsManager.shared.getFileTransferAvailable(for: ref)
        let wasTestedLocally = await SettingsManager.shared.getFileServerTestedLocally(for: ref)
        await SettingsManager.shared.revokeFileTransferReadiness(for: ref)
        fileTransferAvailableRefSet.remove(ref)
        // The revoke reset the stored listing verdict (a rotated credential is a
        // new identity), so the mirror drops with it. A FAILED rotation below
        // does not restore it: the verdict resolves to unknown, i.e. capable,
        // which is the conservative direction — the lane keeps working and the
        // next test re-states any limitation, where restoring a stale "uploads
        // only" would display a limitation nothing had re-measured.
        fileTransferUploadOnlyRefSet.remove(ref)
        // AWAIT the Keychain write so `fileServerCredentialPresent` reflects a
        // REAL persisted credential. A fire-and-forget write could still be in
        // flight — or have silently failed — when the user taps Test Connection,
        // which reads the credential back from Keychain; an absent/stale read
        // would surface a spurious auth error right after a correct setup.
        do {
            try await SettingsManager.shared.setFileServerCredential(secret, for: ref)
        } catch {
            // The write FAILED — never publish (or reveal) a plaintext Keychain
            // does not hold; the user would copy a password Conduck forgot.
            // Presence is left untouched: a previous credential may well have
            // survived the failed update. The rotation never landed, so the
            // pre-rotation state is still the true state of the lane — restore
            // what the revocation dropped (probe markers stay cleared; they
            // only re-arm the upgrade-only probe).
            if wasAvailable {
                await SettingsManager.shared.setFileTransferAvailable(true, for: ref)
                fileTransferAvailableRefSet.insert(ref)
            }
            if wasTestedLocally {
                await SettingsManager.shared.setFileServerTestedLocally(true, for: ref)
            }
            return nil
        }
        // Only AFTER the write proves out: publish the minted value for the
        // masked reveal row, and retire everything the OLD password earned.
        mintedFileServerCredentials[ref] = secret
        fileServerCredentialPresent[ref] = true
        fileServerValidationStates[ref] = nil
        noteFileServerCredentialRotated(for: ref)
        return secret
    }

    /// Mint 32 lowercase hex characters (16 random bytes) from
    /// `SystemRandomNumberGenerator`. Pure + static so tests can assert
    /// length/charset without an actor hop. NOT a UUID (a UUID is 122 bits and
    /// carries version/variant bits) — 16 full random bytes = 128 bits of basic-
    /// auth password entropy.
    static func mintCredentialHex() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &rng))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The current DRAFT test signature for `ref` — the buffered URL + buffered
    /// pin (both in canonical/normalized form) + the credential generation. nil
    /// when the draft can't be probed as-is (URL empty / not https / pin
    /// garbage). Pure derivation over published buffers, so verdict-display
    /// gating re-renders reactively with every keystroke.
    func fileTransferDraftSignature(for ref: RemoteAgentRef) -> FileTransferTestSignature? {
        let trimmedURL = (fileServerURLStrings[ref] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Same admissibility gate as the save path (`EndpointURLPolicy`) — a
        // draft Save can't reject must not be Testable either, or a passing
        // verdict would be earned against a tuple the commit refuses.
        guard !trimmedURL.isEmpty,
              let parsedURL = URL(string: trimmedURL),
              EndpointURLPolicy.isAdmissible(parsedURL) else { return nil }
        let pin: String
        switch Self.normalizeCertFingerprint(fileServerCertFingerprints[ref]) {
        case .none: pin = ""
        case .valid(let hex): pin = hex
        case .invalid: return nil
        }
        return FileTransferTestSignature(
            url: parsedURL.absoluteString,
            pin: pin,
            credentialGeneration: fileServerCredentialGenerations[ref] ?? 0
        )
    }

    /// The signature of the PERSISTED tuple (mirrors, no actor hop) — what a
    /// verdict must match for availability to change, and what the draft
    /// signature equals exactly when the editor is pristine. nil when no URL is
    /// persisted. The pin runs through the SAME canonicalization the draft
    /// signature applies (trim/lowercase/strip ':') — the equality the whole
    /// verdict machinery hinges on must not depend on how a writer happened to
    /// format the stored pin.
    func persistedFileTransferSignature(for ref: RemoteAgentRef) -> FileTransferTestSignature? {
        guard fileServerURLPresent[ref] == true,
              let url = fileServerPersistedURLStrings[ref], !url.isEmpty else { return nil }
        let rawPin = fileServerPersistedPins[ref] ?? ""
        let pin = rawPin.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ":", with: "")
        return FileTransferTestSignature(
            url: url,
            pin: pin,
            credentialGeneration: fileServerCredentialGenerations[ref] ?? 0
        )
    }

    /// The staged verdict the editor may DISPLAY: the latest test result, but
    /// only while the current draft still matches the tuple it probed. Editing
    /// the URL or pin (or rotating the credential) makes this nil — the verdict
    /// no longer describes what's on screen. Restoring the exact tested tuple
    /// legitimately brings it back (the verdict is signature-keyed fact, not
    /// edit history).
    func displayedFileTransferTestResult(for ref: RemoteAgentRef) -> FileTransferTestResult? {
        guard let signature = fileTransferTestSignatures[ref],
              signature == fileTransferDraftSignature(for: ref) else { return nil }
        return fileTransferTestResults[ref]
    }

    /// Run the staged file-server Test Connection for `ref` against the DRAFT
    /// buffers (reachability → auth → write → read) and publish the per-stage
    /// result for the guide. Probes WITHOUT persisting anything — Save is the
    /// commit point (`validateAndSaveFileTransferConfig` carries a matching
    /// verdict into availability). The ONE exception: when the probed tuple IS
    /// the persisted tuple (a pristine editor re-testing the live lane, or the
    /// pairing-import stage), the verdict applies to availability immediately —
    /// a live lane that just failed its own test must stop advertising Ready,
    /// and a pass must not demand a pointless Save (Decision C: availability
    /// only ever flips true on a full write+read pass).
    func runFileTransferTest(for ref: RemoteAgentRef) async {
        // Re-entrancy guard: check AND insert happen synchronously before the
        // first suspension point (MainActor-atomic), so two rapid taps can't
        // both pass the guard and race two probes over the same shared
        // result/availability state. Every await below runs inside the guard.
        guard !fileTransferTestRunning.contains(ref) else { return }
        fileTransferTestRunning.insert(ref)
        defer { fileTransferTestRunning.remove(ref) }

        // Draft-format gate — publish the same `.invalid` the save path uses
        // (macOS has no banner; the inline row is the only surface) and bail
        // before any network. An unparseable draft has no signature; still
        // publish a FAILED result (and clear any prior signature) so a caller
        // reading the raw results dict — the pairing sheet's file stage —
        // never sees a stale earlier verdict as this attempt's outcome.
        guard let signature = fileTransferDraftSignature(for: ref) else {
            fileServerValidationStates[ref] = .invalid(
                message: Self.fileServerURLRejectionMessage(
                    (fileServerURLStrings[ref] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            fileTransferTestResults[ref] = FileTransferTestResult(
                reachedStage: .reachability,
                success: false,
                failure: .fileTransferNotConfigured
            )
            fileTransferTestSignatures.removeValue(forKey: ref)
            return
        }
        fileServerValidationStates[ref] = .valid

        guard let baseURL = URL(string: signature.url),
              let credential = await SettingsManager.shared.getFileServerCredential(for: ref) else {
            // No stored credential — surface a not-configured result at the
            // first stage rather than firing a doomed network probe. If this
            // was the live tuple, availability fails closed (parity with a
            // failed probe of the persisted config).
            fileTransferTestResults[ref] = FileTransferTestResult(
                reachedStage: .reachability,
                success: false,
                failure: .fileTransferNotConfigured
            )
            fileTransferTestSignatures[ref] = signature
            if persistedFileTransferSignature(for: ref) == signature {
                await dropFileTransferAvailability(for: ref)
            }
            return
        }

        // Snapshot assembled from the DRAFT tuple + the stored credential.
        // `available`/`folderCapable` are outputs of testing, not inputs — the
        // probe ignores them.
        let snapshot = SettingsManager.FileTransferSnapshot(
            baseURL: baseURL,
            username: Constants.fileServerUsername,
            credential: credential,
            certFingerprintHex: signature.pin.isEmpty ? nil : signature.pin,
            available: false,
            folderCapable: true
        )
        let result = await FileServerClient.runConnectionTest(snapshot: snapshot)

        // Stale-result rejection: the user may have edited the draft (or rotated
        // the credential) while the probe was in flight — a verdict for a tuple
        // no longer on screen must land in the bin, not in the UI.
        guard fileTransferDraftSignature(for: ref) == signature else { return }

        fileTransferTestResults[ref] = result
        fileTransferTestSignatures[ref] = signature

        // Availability moves ONLY when the probed tuple is the persisted tuple.
        // A draft probe stages its verdict for Save to carry. Everything the
        // result durably concludes — readiness, folder capability, the listing
        // verdict, this device's local test proof — lands through the ONE
        // commit `SettingsManager` exposes for a staged test, which the
        // Diagnostics screen's copy of this flow calls too. That shared hop is
        // deliberate: while each screen spelled its own persistence they
        // drifted, and the one that forgot the listing verdict left a lane
        // green everywhere while dispatch quietly stopped naming folders.
        guard persistedFileTransferSignature(for: ref) == signature else { return }
        await SettingsManager.shared.commitStagedFileTransferResult(result, for: ref)
        if result.success {
            fileTransferAvailableRefSet.insert(ref)
        } else {
            fileTransferAvailableRefSet.remove(ref)
        }
        await refreshFileTransferUploadOnlyMirror(for: ref)
    }

    /// Re-read `ref`'s stored listing verdict into the published mirror the
    /// badge renders.
    ///
    /// READ BACK rather than derived from the value just written, and that is
    /// deliberate: the store is the authority, several paths (pairing import,
    /// Forget, a credential rotation) reset the key without going through this
    /// view model, and a mirror computed from a local branch would drift from
    /// the store exactly where nobody is looking. One read, one assignment, no
    /// second copy of the three-way rule.
    private func refreshFileTransferUploadOnlyMirror(for ref: RemoteAgentRef) async {
        if await SettingsManager.shared.getFileServerReturnCapable(for: ref) {
            fileTransferUploadOnlyRefSet.remove(ref)
        } else {
            fileTransferUploadOnlyRefSet.insert(ref)
        }
    }

    /// Whether file transfer is READY for `ref` (the staged Test Connection
    /// fully passed). Reads the cached set — no actor hop. Drives the
    /// "File transfer: Ready / Not set up" status line.
    func isFileTransferAvailable(_ ref: RemoteAgentRef) -> Bool {
        fileTransferAvailableRefSet.contains(ref)
    }

    /// Whether `ref`'s file server has been PROVEN unable to list a collection —
    /// the upload-only lane. Reads the persisted mirror (no actor hop), so it
    /// survives relaunch; false for every lane nobody has measured, because only
    /// a structural refusal may put a lane in this set.
    func isFileTransferUploadOnly(_ ref: RemoteAgentRef) -> Bool {
        fileTransferUploadOnlyRefSet.contains(ref)
    }

    /// Coarse setup state for `ref`'s file transfer, driving the redesigned
    /// `FileTransferSetupGuideView` layout. Derived PURELY from already-published
    /// view state (no actor hop, so the View re-renders reactively): a saved
    /// snapshot needs both a URL and a credential; `.ready` additionally needs a
    /// passing staged test (which can only succeed once the snapshot exists, so
    /// `.ready` strictly implies a saved snapshot — the early return is safe).
    func fileTransferSetupState(for ref: RemoteAgentRef) -> FileTransferSetupState {
        if isFileTransferAvailable(ref) { return .ready }
        // Read the PERSISTED-URL mirror, not the live `fileServerURLStrings`
        // buffer: a URL the user typed but never saved must not read as
        // "saved" (it would vanish on relaunch). Mirror of the credential-present
        // check right below it.
        let hasURL = fileServerURLPresent[ref] == true
        let hasCredential = fileServerCredentialPresent[ref] == true
        return (hasURL && hasCredential) ? .savedNeedsTest : .missing
    }

    /// First-class "Files and outputs" row status for `ref` — the user-facing
    /// mapping the redesigned gateway editor renders. Folds three signals:
    /// capability (a backend with no file lane → `.unsupported`, row hidden),
    /// the coarse `fileTransferSetupState`, and — for a saved-but-not-ready
    /// gateway — the failure signal from the staged `fileTransferTestResults` (so a
    /// failed staged test reads "Needs attention" while a never-tested one reads
    /// the neutral "Saved"). A not-yet-set-up gateway is `.recommended` on the
    /// built-in full agents (OpenClaw/Hermes) and `.optional` on customs. Pure /
    /// no actor hop, so the View re-renders reactively.
    func fileLaneStatus(for ref: RemoteAgentRef) -> GatewayFileLaneStatus {
        let fileCapable: Bool
        let recommendedWhenMissing: Bool
        switch ref {
        case .builtin(let backend):
            let descriptor = RemoteAgentBackendRegistry.lookup(id: backend)
            fileCapable = descriptor.fileTransferSupported
            // The built-in full agents (self-hosted category) are where the file
            // lane is core value; the hosted model has no lane at all.
            recommendedWhenMissing = descriptor.category == .selfHostedAgent
        case .custom:
            // Customs are OpenAI-compatible servers that MAY have file tools —
            // file-capable, but we ship no opinion, so "optional", not recommended.
            fileCapable = true
            recommendedWhenMissing = false
        }
        guard fileCapable else { return .unsupported }

        switch fileTransferSetupState(for: ref) {
        case .ready:
            // A ready lane still has two answers, and the persisted verdict —
            // not the session-scoped test result — is what decides between
            // them, so the badge tells the same story after a relaunch as it
            // did the moment the test ran.
            return isFileTransferUploadOnly(ref) ? .readyUploadsOnly : .ready
        case .savedNeedsTest:
            // "Needs attention" = the staged Test RAN and FAILED **for the
            // PERSISTED tuple** — the verdict's signature must match the saved
            // config. Without the signature gate a failed probe of an unsaved
            // DRAFT tuple (Test Connection mid-edit) would paint the persisted
            // lane red on every surface that reads this badge (iPad split view
            // shows the editor row live) for a config that never failed. The
            // failure signal is the staged `fileTransferTestResults`, NOT
            // `fileServerValidationStates` — the latter only carries the URL
            // format verdict.
            if fileTransferTestResults[ref]?.success == false,
               let signature = fileTransferTestSignatures[ref],
               signature == persistedFileTransferSignature(for: ref) {
                return .needsAttention
            }
            return .saved
        case .missing:
            return recommendedWhenMissing ? .recommended : .optional
        }
    }

    /// The image-history policy for `ref` (default `.recent`). Reads the
    /// cached dict — no actor hop. Backs the gateway editor's "Image history"
    /// picker `get`.
    func imageHistoryPolicy(_ ref: RemoteAgentRef) -> ImageHistoryPolicy {
        imageHistoryPolicies[ref] ?? .default
    }

    /// Set the image-history policy for `ref` + persist. Updates the cached
    /// dict synchronously then writes through to `SettingsManager`. The gateway
    /// editor buffers the selection and calls this from Save (the page-wide
    /// one-commit contract).
    func setImageHistoryPolicy(_ policy: ImageHistoryPolicy, for ref: RemoteAgentRef) {
        imageHistoryPolicies[ref] = policy
        Task { await SettingsManager.shared.setImageHistoryPolicy(policy, for: ref) }
    }

    /// Drop the in-memory minted credential for `ref` (called when the setup
    /// guide dismisses). The credential remains safe in Keychain; this only
    /// stops the credential row from continuing to reveal the plaintext after
    /// the user has left the guide. Privacy hygiene — the in-memory plaintext
    /// window is exactly the open-guide lifetime.
    func forgetMintedFileServerCredential(for ref: RemoteAgentRef) {
        mintedFileServerCredentials.removeValue(forKey: ref)
    }

    /// The file-transfer editor's Cancel/discard revert: URL + pin buffers back
    /// to the persisted mirrors, validation feedback dropped, and any staged
    /// verdict that describes an abandoned DRAFT tuple retired (a failed draft
    /// test must not linger as "Needs attention" against a persisted tuple it
    /// never probed). Runs on every non-committed editor exit — the
    /// `bufferedEditorChrome` safety net.
    func cancelFileTransferEdit(for ref: RemoteAgentRef) {
        fileServerURLStrings[ref] = fileServerPersistedURLStrings[ref] ?? ""
        if let pin = fileServerPersistedPins[ref], !pin.isEmpty {
            fileServerCertFingerprints[ref] = pin
        } else {
            fileServerCertFingerprints.removeValue(forKey: ref)
        }
        fileServerValidationStates[ref] = .unset
        if let signature = fileTransferTestSignatures[ref],
           signature != persistedFileTransferSignature(for: ref) {
            fileTransferTestResults.removeValue(forKey: ref)
            fileTransferTestSignatures.removeValue(forKey: ref)
        }
    }

    /// Wipe a ref's file-server configuration: URL, credential, cert pin, and
    /// the availability flag. Used by the guide's "Forget file transfer"
    /// destructive action. Mirrors `clearRemoteAgent(for:)` (scoped to the
    /// file-server slots — leaves the gateway token/url untouched).
    func clearFileTransferConfig(for ref: RemoteAgentRef) async {
        // Readiness first (invalidate-first ordering, single actor choke
        // point): available=false must reach KVS no later than the config
        // teardown below, and Forget also forfeits local test proof + probe
        // markers so a later re-add can't inherit stale provenance that would
        // mis-arm the silent re-probe before the new config is re-tested.
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

        fileServerURLStrings[ref] = ""
        fileServerURLPresent[ref] = false
        fileServerCredentialPresent[ref] = false
        fileServerCertFingerprints.removeValue(forKey: ref)
        fileTransferAvailableRefSet.remove(ref)
        // Forget resets the listing verdict in the store (via the revoke above);
        // the mirror follows so a re-added lane starts unmeasured, not carrying
        // the forgotten server's limitation.
        fileTransferUploadOnlyRefSet.remove(ref)
        fileServerValidationStates[ref] = .unset
        fileTransferTestResults.removeValue(forKey: ref)
        fileTransferTestSignatures.removeValue(forKey: ref)
        fileServerCredentialGenerations.removeValue(forKey: ref)
        fileServerPersistedURLStrings[ref] = ""
        fileServerPersistedPins.removeValue(forKey: ref)
        mintedFileServerCredentials.removeValue(forKey: ref)
    }

    // MARK: - Custom OpenAI-compatible STT endpoint (BYO) — Feature 2 lifecycle

    /// Hydrate the custom-endpoint observable state from `SettingsManager`.
    /// Called from `loadSettings()` so the config screen renders the persisted
    /// URL / model / auth / pin + masked key tail without per-render actor
    /// hops. Mirrors `loadRemoteAgentState()` (single-config, not per-backend).
    ///
    /// Privacy: the key is read here ONLY to derive the masked tail; the raw
    /// value never enters observable state.
    private func loadCustomSTTState() async {
        // Hydrate the roster first (drops unsaved in-memory drafts on reload).
        // Diff-guard every assignment below: this method is re-entered by the VM's
        // own `.settingsDidChangeRemotely` observer right after a local write, and
        // Swift Observation fires even on EQUAL reassignment — an unchanged reload
        // would force a redundant body + layout pass (which, stacked on a toggle's
        // own pass, helped trip the macOS SecureField layout recursion). Guarding
        // makes a no-op reload truly inert.
        let roster = await SettingsManager.shared.customVoiceEndpoints()
        if customVoiceEndpoints != roster { customVoiceEndpoints = roster }

        var urls: [UUID: String] = [:]
        var certs: [UUID: String] = [:]
        var sttModels: [UUID: String] = [:]
        var ttsModels: [UUID: String] = [:]
        var auths: [UUID: STTAuthScheme] = [:]
        var masked: [UUID: String] = [:]
        var states: [UUID: KeyValidationState] = [:]

        for endpoint in roster {
            let uuid = endpoint.id
            let storedURL = await SettingsManager.shared.getCustomSTTURL(for: uuid)
            urls[uuid] = storedURL?.absoluteString ?? ""
            certs[uuid] = await SettingsManager.shared.getCustomSTTCertFingerprint(for: uuid) ?? ""
            sttModels[uuid] = await SettingsManager.shared.getCustomSTTModel(for: uuid)
            ttsModels[uuid] = await SettingsManager.shared.getCustomTTSModel(for: uuid)
            let auth = await SettingsManager.shared.getCustomSTTAuthScheme(for: uuid)
            auths[uuid] = auth

            if let key = await SettingsManager.shared.getAPIKey(forPresetID: endpoint.sttPresetID),
               !key.isEmpty {
                masked[uuid] = maskedTail(key)
                states[uuid] = (storedURL != nil) ? .valid : .unset
            } else {
                // Keyless `.none` servers are ready on a stored URL alone.
                states[uuid] = (storedURL != nil && auth == .none) ? .valid : .unset
            }
        }

        if customSTTURLStrings != urls { customSTTURLStrings = urls }
        if customSTTCertFingerprints != certs { customSTTCertFingerprints = certs }
        if customSTTModels != sttModels { customSTTModels = sttModels }
        if customTTSModels != ttsModels { customTTSModels = ttsModels }
        if customSTTAuthSchemes != auths { customSTTAuthSchemes = auths }
        if customSTTMaskedTails != masked { customSTTMaskedTails = masked }
        if customSTTValidationStates != states { customSTTValidationStates = states }
    }

    /// Whether a named custom endpoint is READY to be set active: a base URL is
    /// stored AND (auth `.none` OR a key is stored). Reads cached observable
    /// state — no actor hop. Used by the row's status pill + `isProviderReady`.
    func isCustomSTTReady(for uuid: UUID) -> Bool {
        let hasURL = !(customSTTURLStrings[uuid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKey = customSTTMaskedTails[uuid] != nil
        let auth = customSTTAuthSchemes[uuid] ?? .bearer
        return hasURL && (auth == .none || hasKey)
    }

    /// Set a named endpoint's auth scheme (`.bearer` / `.none`). Persists
    /// immediately so the snapshot resolver + the missing-key guard see the
    /// choice; `.none` makes the key field optional.
    ///
    /// Await-first, then mutate observable state — the same order as
    /// `setActive` / `setActiveTTS`. Mutating BEFORE the actor hop published the
    /// `isKeyless` flip (and the key-field show/hide) mid-control-interaction,
    /// which on macOS raced the auth control's teardown and tripped a layout
    /// recursion + ViewBridge crash. Settling the persistence first defers the
    /// structural change out of that render cycle.
    func setCustomSTTAuthScheme(_ scheme: STTAuthScheme, for uuid: UUID) async {
        await SettingsManager.shared.setCustomSTTAuthScheme(scheme, for: uuid)
        customSTTAuthSchemes[uuid] = scheme
    }

    /// BUFFER-ONLY auth-scheme set for the custom editor (Save is the single
    /// commit point). Updates `customSTTAuthSchemes[uuid]` WITHOUT persisting —
    /// `saveCustomVoiceEndpoint` writes it on Save, and `cancelCustomVoiceEndpointEdit`
    /// reverts it. Synchronous (no actor hop) so the `isKeyless`-derived helper
    /// text flips in the same render pass; the `keyField` SecureField never reads
    /// `isKeyless`, so this buffer flip can't trip the macOS layout recursion.
    func setCustomSTTAuthSchemeBuffer(_ scheme: STTAuthScheme, for uuid: UUID) {
        customSTTAuthSchemes[uuid] = scheme
    }

    /// VALIDATE-ONLY (Save is the single commit point). Run the staged Test
    /// suite against the buffer values (`url` + `key` + the per-uuid model/auth/
    /// fingerprint buffers) and reflect the OUTCOME into observable state
    /// (`sttTestSuiteResults` / `customSTTValidationStates`) — but persist
    /// NOTHING. The actual upsert / `setCustomSTT…` / `setAPIKey` happens only in
    /// `saveCustomVoiceEndpoint`. Mirrors the old `validateAndSaveRemoteAgent`
    /// trim → `https://`-only rejection (REUSED verbatim) → `.checking` → rich
    /// Test suite → `.valid` / `.invalid` shape; the result also lands in
    /// `sttTestSuiteResults[custom-openai_<uuid>]`.
    ///
    /// Privacy: the raw key never leaves this method — no log, no print, no
    /// retention past the probe.
    func validateCustomSTT(for uuid: UUID, url: String, key: String, model: String) async {
        let presetID = STTProvider.customEndpointID(for: uuid)
        let auth = customSTTAuthSchemes[uuid] ?? .bearer

        // Name is required (drives the library row label). Soft 40-char cap (KVS
        // per-key limit), mirroring the gateway save. Reflected into the in-memory
        // roster buffer only — persisted on Save.
        let candidateName = customVoiceEndpointName(for: uuid).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateName.isEmpty else {
            customSTTValidationStates[uuid] = .invalid(
                message: String(localized: "settings.voice.custom.name.required",
                                defaultValue: "Give this endpoint a name.")
            )
            return
        }
        if let idx = customVoiceEndpoints.firstIndex(where: { $0.id == uuid }) {
            customVoiceEndpoints[idx].name = String(candidateName.prefix(40))
        }

        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // `EndpointURLPolicy` — https (so a bearer key can never leave the
        // device in cleartext), a real host, and no `user:password@`. This URL
        // dual-writes to App-Group defaults + iCloud KVS exactly like the
        // gateway's, so it is held to the same rule; the storage read fence
        // (`SettingsManager.resolveStoredURL`) would refuse anything looser,
        // and a Save the read path won't honour is worse than a clear reject.
        guard !trimmedURL.isEmpty,
              let parsedURL = URL(string: trimmedURL),
              EndpointURLPolicy.isAdmissible(parsedURL) else {
            customSTTValidationStates[uuid] = .invalid(
                message: Self.customSTTURLRejectionMessage(trimmedURL)
            )
            return
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // For `.bearer` a key is required; for `.none` (keyless local server)
        // it's optional.
        if auth != .none, trimmedKey.isEmpty {
            customSTTValidationStates[uuid] = .invalid(
                message: String(localized: "settings.stt.custom.key.required",
                                defaultValue: "Paste your endpoint's API key, or switch to No auth.")
            )
            return
        }

        let trimmedFingerprint = (customSTTCertFingerprints[uuid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveFingerprint: String? = trimmedFingerprint.isEmpty ? nil : trimmedFingerprint
        let effectiveModel = Self.sanitizeModelTag(model)
        let resolvedModel = effectiveModel.isEmpty ? "whisper-1" : effectiveModel

        customSTTValidationStates[uuid] = .checking

        // The full transcribe URL the suite probes (base + path) — mirrors
        // `SettingsManager.customSTTTranscribeURL(for:)` so a Test before the
        // save hits the same endpoint the live transcribe path will.
        let transcribeURL = parsedURL.appending(path: "v1/audio/transcriptions")

        let result = await runSuite(
            presetID: presetID,
            url: transcribeURL,
            token: trimmedKey,
            auth: auth,
            fingerprint: effectiveFingerprint,
            model: resolvedModel
        )

        guard result.allPassed else {
            // The suite hard-failed a stage — surface the first failing stage's
            // (key-free) reason.
            let reason = result.stages.first(where: {
                if case .failed = $0.status { return true } else { return false }
            }).flatMap { stage -> String? in
                if case .failed(let reason) = stage.status { return reason } else { return nil }
            } ?? String(localized: "stt.test.genericFailure",
                        defaultValue: "The test didn't pass. Check the checklist above.")
            customSTTValidationStates[uuid] = .invalid(message: reason)
            return
        }

        // Probe OK — reflect the validated values back into the buffers (NOT
        // storage), so the Save that follows commits exactly what was tested.
        customSTTURLStrings[uuid] = parsedURL.absoluteString
        customSTTCertFingerprints[uuid] = effectiveFingerprint ?? ""
        customSTTModels[uuid] = resolvedModel
        customSTTValidationStates[uuid] = .valid
    }

    /// Commit ALL buffers for a custom voice endpoint — the SINGLE persistence
    /// point (no test required; Save commits even if untested). Reuses the same
    /// guards as `validateCustomSTT` (name non-empty, `https://`-only URL,
    /// model sanitize) but skips the staged suite. Persists in the order the
    /// per-uuid slots expect: roster upsert → URL → auth → STT model → cert pin →
    /// API key (only if a key was typed AND auth ≠ `.none`) → TTS model → TTS
    /// voice. Then refreshes the derived snapshots so the list re-renders.
    /// Returns `true` on a committed save, `false` when a guard rejected it.
    ///
    /// Privacy: `pendingKey` flows only to Keychain; never logged or retained.
    @discardableResult
    func saveCustomVoiceEndpoint(for uuid: UUID, pendingKey: String) async -> Bool {
        let presetID = STTProvider.customEndpointID(for: uuid)
        let ttsID = TTSProvider.customEndpointID(for: uuid)
        let auth = customSTTAuthSchemes[uuid] ?? .bearer

        // Name is required (drives the library row label). Soft 40-char cap.
        let candidateName = customVoiceEndpointName(for: uuid).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateName.isEmpty else {
            customSTTValidationStates[uuid] = .invalid(
                message: String(localized: "settings.voice.custom.name.required",
                                defaultValue: "Give this endpoint a name.")
            )
            return false
        }
        if let idx = customVoiceEndpoints.firstIndex(where: { $0.id == uuid }) {
            customVoiceEndpoints[idx].name = String(candidateName.prefix(40))
        }

        // `EndpointURLPolicy` (verbatim from the Test guard above).
        let trimmedURL = (customSTTURLStrings[uuid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let parsedURL = URL(string: trimmedURL),
              EndpointURLPolicy.isAdmissible(parsedURL) else {
            customSTTValidationStates[uuid] = .invalid(
                message: Self.customSTTURLRejectionMessage(trimmedURL)
            )
            return false
        }

        let trimmedKey = pendingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // `.bearer` needs a key — unless one is already stored (an edit that
        // didn't re-type it). `.none` never needs one.
        if auth != .none, trimmedKey.isEmpty, customSTTMaskedTails[uuid] == nil {
            customSTTValidationStates[uuid] = .invalid(
                message: String(localized: "settings.stt.custom.key.required",
                                defaultValue: "Paste your endpoint's API key, or switch to No auth.")
            )
            return false
        }

        let trimmedFingerprint = (customSTTCertFingerprints[uuid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveFingerprint: String? = trimmedFingerprint.isEmpty ? nil : trimmedFingerprint
        let effectiveModel = Self.sanitizeModelTag(customSTTModels[uuid] ?? "")
        let resolvedModel = effectiveModel.isEmpty ? "whisper-1" : effectiveModel
        let trimmedTTSModel = (customTTSModels[uuid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoice = pendingTTSVoiceToPersist(for: uuid)

        // Persist in order — roster first so per-uuid slots have a home.
        if let existing = customVoiceEndpoints.first(where: { $0.id == uuid }) {
            _ = await SettingsManager.shared.upsertCustomVoiceEndpoint(existing)
        }
        await SettingsManager.shared.setCustomSTTURL(parsedURL, for: uuid)
        await SettingsManager.shared.setCustomSTTAuthScheme(auth, for: uuid)
        await SettingsManager.shared.setCustomSTTModel(resolvedModel, for: uuid)
        await SettingsManager.shared.setCustomSTTCertFingerprint(effectiveFingerprint, for: uuid)
        // Persist the key per the auth scheme — mirroring the gateway path.
        if auth == .none {
            // Keyless: drop any stored key + masked tail. A clear failure is
            // non-critical (no key is ever sent under `.none`), but never leave a
            // stale secret behind — esp. now the field is hidden when keyless.
            try? await SettingsManager.shared.clearAPIKey(forPresetID: presetID)
            customSTTMaskedTails[uuid] = nil
        } else if !trimmedKey.isEmpty {
            // Persist a freshly-typed key; an unchanged edit keeps the stored key.
            // A FAILED write MUST NOT report success — a URL-present bearer endpoint
            // whose key never persisted would otherwise read as configured. Fail closed.
            do {
                try await SettingsManager.shared.setAPIKey(trimmedKey, forPresetID: presetID)
                customSTTMaskedTails[uuid] = maskedTail(trimmedKey)
            } catch {
                customSTTValidationStates[uuid] = .invalid(
                    message: String(localized: "settings.stt.custom.key.saveFailed",
                                    defaultValue: "Couldn't save your key securely. Try again.")
                )
                return false
            }
        }
        await SettingsManager.shared.setCustomTTSModel(trimmedTTSModel.isEmpty ? nil : trimmedTTSModel, for: uuid)
        await SettingsManager.shared.setTTSVoice(trimmedVoice.isEmpty ? nil : trimmedVoice, forProviderID: ttsID)

        // Refresh local observable state from the freshly-persisted tuple.
        customSTTURLStrings[uuid] = parsedURL.absoluteString
        customSTTCertFingerprints[uuid] = effectiveFingerprint ?? ""
        customSTTModels[uuid] = resolvedModel
        customTTSModels[uuid] = trimmedTTSModel
        storedPresetIDs = await SettingsManager.shared.presetIDsWithStoredKey()
        await refreshTTSVoices()
        customSTTValidationStates[uuid] = isCustomSTTReady(for: uuid) ? .valid : .unset
        return true
    }

    /// The TTS voice the editor's `pendingTTSVoice` @State buffer wants persisted
    /// on Save. Stashed by `CustomSTTConfigBody` via `stagePendingTTSVoice` just
    /// before calling Save (the @State buffer can't be read from the VM). Falls
    /// back to the already-cached override if nothing was staged this session.
    private func pendingTTSVoiceToPersist(for uuid: UUID) -> String {
        let ttsID = TTSProvider.customEndpointID(for: uuid)
        if let staged = stagedCustomTTSVoices[uuid] { return staged }
        return ttsVoices[ttsID] ?? ""
    }

    /// Stash the editor's `pendingTTSVoice` @State buffer so `saveCustomVoiceEndpoint`
    /// can persist it (the VM can't read the View's @State directly). Cleared on
    /// Save / Cancel via `clearStagedCustomTTSVoice`.
    func stagePendingTTSVoice(_ voice: String, for uuid: UUID) {
        stagedCustomTTSVoices[uuid] = voice
    }

    /// Drop the staged TTS voice buffer for a uuid (after Save / on Cancel).
    func clearStagedCustomTTSVoice(for uuid: UUID) {
        stagedCustomTTSVoices.removeValue(forKey: uuid)
    }

    /// Cancel an in-progress custom-endpoint edit, discarding unsaved buffer
    /// edits. Two paths, keyed SOLELY on whether the uuid is ALREADY in the store
    /// (the authoritative source — buffers never reach storage until Save):
    ///   - Draft (never stored): drop the in-memory roster row + every per-uuid
    ///     buffer entry. Nothing was persisted, so this just clears the draft.
    ///   - Existing: re-hydrate this uuid's buffers from storage (per-uuid mirror
    ///     of `loadCustomSTTState`'s body), discarding the unsaved edits.
    /// The caller (`CustomSTTConfigBody`) then `dismiss()`es. Driven off the
    /// in-actor store check (not a View-captured snapshot) so it's correct
    /// regardless of how the editor was left (Cancel button, native back) and
    /// free of any appear-time race.
    func cancelCustomVoiceEndpointEdit(for uuid: UUID) async {
        clearStagedCustomTTSVoice(for: uuid)

        guard await SettingsManager.shared.customVoiceEndpoint(id: uuid) != nil else {
            // Draft — nothing persisted. Drop the in-memory row + per-uuid buffers.
            customVoiceEndpoints.removeAll { $0.id == uuid }
            customSTTURLStrings.removeValue(forKey: uuid)
            customSTTCertFingerprints.removeValue(forKey: uuid)
            customSTTModels.removeValue(forKey: uuid)
            customTTSModels.removeValue(forKey: uuid)
            customSTTAuthSchemes.removeValue(forKey: uuid)
            customSTTMaskedTails.removeValue(forKey: uuid)
            customSTTValidationStates.removeValue(forKey: uuid)
            sttTestSuiteResults.removeValue(forKey: STTProvider.customEndpointID(for: uuid))
            return
        }

        // Existing — re-hydrate this uuid's buffers from storage (mirrors the
        // per-endpoint body of `loadCustomSTTState`), discarding unsaved edits.
        if let stored = await SettingsManager.shared.customVoiceEndpoint(id: uuid),
           let idx = customVoiceEndpoints.firstIndex(where: { $0.id == uuid }) {
            customVoiceEndpoints[idx].name = stored.name
        }
        let storedURL = await SettingsManager.shared.getCustomSTTURL(for: uuid)
        customSTTURLStrings[uuid] = storedURL?.absoluteString ?? ""
        customSTTCertFingerprints[uuid] = await SettingsManager.shared.getCustomSTTCertFingerprint(for: uuid) ?? ""
        customSTTModels[uuid] = await SettingsManager.shared.getCustomSTTModel(for: uuid)
        customTTSModels[uuid] = await SettingsManager.shared.getCustomTTSModel(for: uuid)
        let auth = await SettingsManager.shared.getCustomSTTAuthScheme(for: uuid)
        customSTTAuthSchemes[uuid] = auth

        if let key = await SettingsManager.shared.getAPIKey(forPresetID: STTProvider.customEndpointID(for: uuid)),
           !key.isEmpty {
            customSTTMaskedTails[uuid] = maskedTail(key)
            customSTTValidationStates[uuid] = (storedURL != nil) ? .valid : .unset
        } else {
            customSTTMaskedTails.removeValue(forKey: uuid)
            customSTTValidationStates[uuid] = (storedURL != nil && auth == .none) ? .valid : .unset
        }
        sttTestSuiteResults.removeValue(forKey: STTProvider.customEndpointID(for: uuid))
        await refreshTTSVoices()
    }

    /// Re-test the named endpoint WITHOUT persisting (validate-only). Reads any
    /// stored key from Keychain in-actor (never surfaced) so a re-test on an
    /// already-saved endpoint doesn't force a re-paste; routes through
    /// `validateCustomSTT`. For `.none` auth there is no key to read; passes "".
    /// A freshly-typed key (in the SecureField buffer) is preferred by the caller,
    /// which passes it as `key`; an empty `key` here means "re-test the stored one".
    func retestCustomSTT(for uuid: UUID, url: String, model: String) async {
        let auth = customSTTAuthSchemes[uuid] ?? .bearer

        // URL is the prerequisite — surface the URL error BEFORE the stored-key
        // check so a blank/invalid URL always wins, regardless of key state. Keeps
        // all three test/preview paths consistent (`validateCustomSTT` checks
        // name→URL→key; the TTS preview guard checks URL first) and matches the
        // always-tappable fail-loud contract: tapping Test with no URL points at
        // the URL, not the key.
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              let parsed = URL(string: trimmedURL),
              parsed.scheme?.lowercased() == "https" else {
            customSTTValidationStates[uuid] = .invalid(
                message: String(localized: "settings.stt.custom.url.invalid",
                                defaultValue: "Enter the full endpoint URL including https://.")
            )
            return
        }

        let key: String
        if auth == .none {
            key = ""
        } else {
            guard let stored = await SettingsManager.shared.getAPIKey(forPresetID: STTProvider.customEndpointID(for: uuid)),
                  !stored.isEmpty else {
                customSTTValidationStates[uuid] = .invalid(
                    message: String(localized: "settings.stt.custom.key.noSaved",
                                    defaultValue: "No saved key to test. Paste your endpoint's API key first.")
                )
                return
            }
            key = stored
        }
        await validateCustomSTT(for: uuid, url: url, key: key, model: model)
    }

    /// Wipe a named endpoint's configuration: URL, key, model, cert, auth —
    /// including the shared TTS direction's model — AND remove its roster entry.
    /// Falls the active STT/TTS pointer back to Apple if it pointed here (via
    /// `deleteCustomVoiceEndpoint`). Used by the "Forget" destructive action.
    func clearCustomSTT(for uuid: UUID) async {
        let presetID = STTProvider.customEndpointID(for: uuid)
        // The manager clears all per-uuid slots + the roster + repoints actives.
        await SettingsManager.shared.deleteCustomVoiceEndpoint(id: uuid)

        // Drop local observable state for this uuid.
        customSTTURLStrings.removeValue(forKey: uuid)
        customSTTCertFingerprints.removeValue(forKey: uuid)
        customSTTModels.removeValue(forKey: uuid)
        customTTSModels.removeValue(forKey: uuid)
        customSTTAuthSchemes.removeValue(forKey: uuid)
        customSTTMaskedTails.removeValue(forKey: uuid)
        customSTTValidationStates.removeValue(forKey: uuid)
        customVoiceEndpoints.removeAll { $0.id == uuid }
        sttTestSuiteResults.removeValue(forKey: presetID)
        clearStagedCustomTTSVoice(for: uuid)

        // Re-pull the active pointers (the manager may have flipped them to Apple).
        activePresetID = await SettingsManager.shared.getActivePresetID()
        activeTTSProviderID = await SettingsManager.shared.getActiveTTSProviderID()
        storedPresetIDs = await SettingsManager.shared.presetIDsWithStoredKey()
    }

    // MARK: - Rich Test Connection (Feature 3) — full staged suite

    /// Drive `STTConnectionTestSuite.run`, mirroring each progress tick into
    /// `sttTestSuiteResults[presetID]` on the main actor for live animation.
    /// Returns the final result so callers (`validateCustomSTT`) can
    /// branch on `allPassed`. The progress
    /// closure hops back to `@MainActor` because the suite invokes it from its
    /// own (non-isolated) async context.
    @discardableResult
    private func runSuite(
        presetID: String,
        url: URL,
        token: String,
        auth: STTAuthScheme,
        fingerprint: String?,
        model: String
    ) async -> STTTestSuiteResult {
        sttTestSuiteResults[presetID] = .pending
        return await STTConnectionTestSuite.run(
            url: url,
            token: token,
            auth: auth,
            fingerprint: fingerprint,
            model: model,
            progress: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.sttTestSuiteResults[presetID] = snapshot
                }
            }
        )
    }

    // MARK: - Session continuation policy (Part A)

    /// Persist the "New conversation" session-continuation policy.
    func setSessionContinuationPolicy(_ value: SessionContinuationPolicy) async {
        sessionContinuationPolicy = value
        await SettingsManager.shared.setSessionContinuationPolicy(value)
    }

    // MARK: - On-launch mode

    /// Persist the cold-launch landing preference.
    func setOnLaunchMode(_ value: OnLaunchMode) async {
        onLaunchMode = value
        await SettingsManager.shared.setOnLaunchMode(value)
    }

    // MARK: - Apple Watch

    /// "Enable on Watch" master switch, surfaced in the Settings →
    /// Apple Watch sub-section. Reads/writes the `Constants.watchEnabledKey` flag
    /// through `PhoneSessionManager` (iCloud KVS + applicationContext). iOS-only;
    /// returns ON on macOS where the section never renders.
    var watchEnabled: Bool {
        #if os(iOS)
        return PhoneSessionManager.shared.isWatchEnabled
        #else
        return true
        #endif
    }

    /// Toggle "Enable on Watch". Mutates through `PhoneSessionManager` and
    /// pings observers so the toggle re-renders (the flag lives in KVS, not
    /// observable VM state).
    func setWatchEnabled(_ enabled: Bool) {
        #if os(iOS)
        PhoneSessionManager.shared.setWatchEnabled(enabled)
        // Nudge observers — the Toggle binding reads `watchEnabled` (KVS-backed).
        NotificationCenter.default.post(name: .settingsDidChangeRemotely, object: nil)
        #endif
    }
}

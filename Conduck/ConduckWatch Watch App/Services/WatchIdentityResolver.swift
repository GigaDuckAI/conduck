import Foundation
import Security
import WatchConnectivity

/// Resolves the user's UUID on Apple Watch via tiered fallback.
/// Never generates a UUID — iPhone is the sole identity origin.
/// Resolution order: Watch Keychain → WCSession context → iCloud KVS → WCSession message → nil
actor WatchIdentityResolver {
    static let shared = WatchIdentityResolver()

    private var cachedUserID: String?
    private var isObserving = false

    private init() {}

    // MARK: - Public API

    /// Synchronous Keychain-only check for initial UI state.
    /// NOT actor-isolated — safe to call from App.init().
    static func hasKeychainIdentity() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.keychainAccountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let id = String(data: data, encoding: .utf8),
              !id.isEmpty else {
            return false
        }
        return true
    }

    /// Returns the resolved user ID, or nil if no identity is available yet.
    func getUserID() -> String? {
        if let cached = cachedUserID { return cached }

        let id = resolve()
        cachedUserID = id
        return id
    }

    /// Full background resolution: local sources first, then phone with timeout.
    func resolveInBackground() async -> String? {
        if let id = getUserID() {
            return id
        }
        return await requestFromPhoneWithTimeout()
    }

    /// Attempts real-time identity request from iPhone with a 5-second timeout.
    /// Deadline race via `awaitValue` (TaskDeadline.swift) — the old
    /// `withTaskGroup` form returned the right value at the deadline but
    /// held the caller until the request's parked continuation resumed
    /// (a group drains all children even after `cancelAll()`).
    private func requestFromPhoneWithTimeout() async -> String? {
        await awaitValue(
            of: Task { await self.requestFromPhone() },
            deadline: 5,
            onDeadline: nil
        )
    }

    /// Attempts real-time identity request from iPhone (async, requires reachability).
    func requestFromPhone() async -> String? {
        guard WCSession.default.isReachable else { return nil }

        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(
                ["request": "user_id"],
                replyHandler: { reply in
                    if let id = reply[Constants.iCloudKVSUserIDKey] as? String, !id.isEmpty {
                        Task { await self.didReceiveUserID(id) }
                        continuation.resume(returning: id)
                    } else {
                        continuation.resume(returning: nil)
                    }
                },
                errorHandler: { _ in
                    continuation.resume(returning: nil)
                }
            )
        }
    }

    /// Called when identity arrives from WCSession or iCloud KVS.
    func didReceiveUserID(_ id: String) {
        guard !id.isEmpty else { return }
        cachedUserID = id
        saveToKeychain(id)
        #if DEBUG
        print("[Watch] Identity resolved: \(id.prefix(8))...")
        #endif
    }

    // MARK: - Setup

    /// Start observing iCloud KVS changes for identity updates.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        Task { @MainActor in
            // Deliberately NOT gated on `FileManager.default.ubiquityIdentityToken`:
            // that token tracks iCloud DRIVE availability, and iCloud Drive
            // doesn't exist on watchOS — so it is ALWAYS nil there, which
            // made the old guard permanently dead code on every Watch.
            // NSUbiquitousKeyValueStore itself is supported on watchOS 9+;
            // observing on a device without iCloud is harmless (the
            // notifications simply never fire).
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default,
                queue: .main
            ) { notification in
                Task { await WatchIdentityResolver.shared.handleiCloudChange(notification) }
            }

            Task.detached {
                NSUbiquitousKeyValueStore.default.synchronize()
            }
        }
    }

    // MARK: - Resolution (synchronous tiered fallback)

    private func resolve() -> String? {
        // 1. Watch Keychain (local cache, fastest, offline)
        if let keychainID = readFromKeychain() {
            return keychainID
        }

        // 2. WCSession receivedApplicationContext (pushed from iPhone)
        if let contextID = WCSession.default.receivedApplicationContext[Constants.iCloudKVSUserIDKey] as? String,
           !contextID.isEmpty {
            saveToKeychain(contextID)
            return contextID
        }

        // 3. iCloud KVS (read cached value — startObserving() triggers sync,
        // observer handles updates). Deliberately NOT gated on
        // `ubiquityIdentityToken`: that token tracks iCloud DRIVE
        // availability, and iCloud Drive doesn't exist on watchOS — so it is
        // ALWAYS nil there, which made the old gate skip this tier on every
        // Watch. NSUbiquitousKeyValueStore itself is supported on watchOS 9+
        // and the read is harmless without iCloud (it just returns nil).
        if let iCloudID = NSUbiquitousKeyValueStore.default.string(forKey: Constants.iCloudKVSUserIDKey),
           !iCloudID.isEmpty {
            saveToKeychain(iCloudID)
            return iCloudID
        }

        // 4. No identity available — caller should show setup screen
        // Real-time WCSession request is async, handled separately via requestFromPhone()
        return nil
    }

    // MARK: - iCloud Change Handler

    private func handleiCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              changedKeys.contains(Constants.iCloudKVSUserIDKey) else {
            return
        }

        guard changeReason == NSUbiquitousKeyValueStoreServerChange ||
              changeReason == NSUbiquitousKeyValueStoreInitialSyncChange else {
            return
        }

        guard let incomingID = NSUbiquitousKeyValueStore.default.string(forKey: Constants.iCloudKVSUserIDKey),
              !incomingID.isEmpty else {
            return
        }

        // On Watch, always adopt incoming identity (Watch never generates its own)
        cachedUserID = incomingID
        saveToKeychain(incomingID)

        // Post notification so UI can react
        Task { @MainActor in
            NotificationCenter.default.post(name: .watchIdentityDidChange, object: nil)
        }

        #if DEBUG
        print("[Watch] Adopted iCloud user ID: \(incomingID.prefix(8))...")
        #endif
    }

    // MARK: - STT API Key (Keychain slot, per-preset)

    /// Read a specific preset's STT API key from the Watch Keychain.
    /// Tier this with `WatchSettingsReader.shared.apiKey` (in-memory cache) and
    /// WCSession reachability — Watch ControlWidget cold-launch
    /// needs Keychain hit (`kSecAttrAccessibleAfterFirstUnlock`); foreground/hot
    /// paths can prefer the in-memory cache to avoid Keychain syscall.
    /// Privacy invariant: never log the returned key.
    ///
    /// Per-preset slots use `Constants.sttApiKeyKeychainAccount(for: presetID)`
    /// (account format `"stt.apiKey.<presetID>"`); the legacy literal
    /// `"stt.apiKey.mistral-voxtral"` is exactly subsumed for back-compat.
    nonisolated static func getSTTAPIKey(forPresetID presetID: String) -> String? {
        readKeychainString(account: Constants.sttApiKeyKeychainAccount(for: presetID))
    }

    /// Persist a preset's STT API key to the Watch Keychain. Called by the
    /// WCSession envelope dispatch when iPhone broadcasts the active preset's
    /// key (`WatchSessionManager.session(_:didReceiveUserInfo:)`).
    func setSTTAPIKey(_ key: String, forPresetID presetID: String) {
        Self.writeKeychainString(key, account: Constants.sttApiKeyKeychainAccount(for: presetID))
    }

    // MARK: - Remote Agent (Personal AI) bearer token (Keychain slot)
    //
    // Planned — Settings: Personal AI. Watch-side Keychain accessor for the
    // gateway bearer token, mirroring the per-preset STT key shape. Account
    // = `Constants.remoteAgentTokenKeychainAccount`, accessibility =
    // `kSecAttrAccessibleAfterFirstUnlock` (the ControlWidget will need the
    // token pre-unlock for converse upload).
    //
    // Privacy invariant: never log the returned value.

    /// Read the Personal AI gateway bearer token from Watch Keychain.
    nonisolated static func getRemoteAgentToken() -> String? {
        readKeychainString(account: Constants.remoteAgentTokenKeychainAccount)
    }

    /// Persist the Personal AI gateway bearer token to Watch Keychain.
    /// Called by the WCSession envelope dispatch when iPhone broadcasts
    /// the configured gateway (`WatchSessionManager.session(_:didReceiveUserInfo:)`).
    func setRemoteAgentToken(_ token: String) {
        Self.writeKeychainString(token, account: Constants.remoteAgentTokenKeychainAccount)
    }

    /// Remove the Personal AI gateway bearer token from Watch Keychain.
    /// Called when iPhone broadcasts an envelope with `token == nil`
    /// (user cleared the gateway in Settings).
    func clearRemoteAgentToken() {
        Self.deleteKeychainItem(account: Constants.remoteAgentTokenKeychainAccount)
    }

    // MARK: - Remote Agent — Per-REF bearer token (custom-gateways, ref-string keyed)
    //
    // Custom-gateways. The Watch substrate routes on a ref STRING
    // ("openclaw" / "hermes" / "custom_<uuid>") so customs are first-class.
    // Each ref owns its own Watch Keychain token slot via the SAME
    // `Constants.remoteAgentTokenKeychainAccount(for: RemoteAgentRef)` generator
    // the iPhone uses (built-in suffix == raw value → byte-identical to the
    // `for backend:` overload, back-compat). A garbage ref string is a no-op
    // (the keychain account generator is unreachable) — callers always pass a
    // ref minted by `RemoteAgentRef(rawString:)`/`.rawString`.
    //
    // Privacy invariant: never log the returned value. Tokens ride
    // `transferUserInfo` + the Watch Keychain only — NEVER KVS.

    /// Map a ref string to its Keychain account, or nil for a garbage ref.
    private static func tokenAccount(forRef ref: String) -> String? {
        guard let parsed = RemoteAgentRef(rawString: ref) else { return nil }
        return Constants.remoteAgentTokenKeychainAccount(for: parsed)
    }

    /// Read a SPECIFIC ref's gateway bearer token from Watch Keychain.
    nonisolated static func getRemoteAgentToken(for ref: String) -> String? {
        guard let account = tokenAccount(forRef: ref) else { return nil }
        return readKeychainString(account: account)
    }

    /// Persist a SPECIFIC ref's gateway bearer token to Watch Keychain.
    /// Called by the WCSession multi-envelope dispatch for each configured ref.
    func setRemoteAgentToken(_ token: String, for ref: String) {
        guard let account = Self.tokenAccount(forRef: ref) else { return }
        Self.writeKeychainString(token, account: account)
    }

    /// Remove a SPECIFIC ref's gateway bearer token from Watch Keychain.
    func clearRemoteAgentToken(for ref: String) {
        guard let account = Self.tokenAccount(forRef: ref) else { return }
        Self.deleteKeychainItem(account: account)
    }

    // MARK: - Keychain Operations (generic, account-keyed)

    private func readFromKeychain() -> String? {
        Self.readKeychainString(account: Constants.keychainAccountName)
    }

    private func saveToKeychain(_ id: String) {
        Self.writeKeychainString(id, account: Constants.keychainAccountName)
    }

    /// Shared Keychain read; nonisolated so static accessors + the actor both use it.
    nonisolated private static func readKeychainString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    nonisolated private static func writeKeychainString(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    nonisolated private static func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let watchIdentityDidChange = Notification.Name("watchIdentityDidChange")
}

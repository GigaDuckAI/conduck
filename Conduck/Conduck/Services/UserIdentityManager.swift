// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Manages a stable user identity (UUID) persisted in Keychain and synced via iCloud KVS.
///
/// The UUID is a device-local pseudonymous identifier, NOT a credential — gateway auth is
/// the bearer token `SettingsManager` keeps in the Keychain. Its single purpose is to
/// correlate an iPhone with its paired Watch: `PhoneSessionManager` puts it on the WCSession
/// `applicationContext` and answers the Watch's identity request with it.
///
/// It never enters a network request. The only sinks in this file are the device Keychain
/// (`kSecAttrAccessibleAfterFirstUnlock`, non-synchronizable) and the user's own iCloud
/// key-value store — Conduck has no operator backend, so there is nowhere off-device to send
/// it. Keep it that way: this value plus a network sink would be exactly the outbound
/// identifier the "no backend, no account, no telemetry" posture rules out.
actor UserIdentityManager {
    static let shared = UserIdentityManager()

    private var cachedUserID: String?

    /// Keychain (identity item) — via the storage seam, so a test host cannot
    /// write a UUID into the developer's real Keychain.
    private let secrets: any SecretStore

    /// iCloud KVS (identity mirror).
    private let iCloudStore: any UbiquitousStore

    private let cloudAvailability: any CloudAvailability

    init(dependencies: SettingsDependencies = .processDefault) {
        self.secrets = dependencies.secrets
        self.iCloudStore = dependencies.ubiquitous
        self.cloudAvailability = dependencies.cloudAvailability

        // Register for external KVS changes only while iCloud is available.
        let isAvailable = dependencies.cloudAvailability.isAvailable
        guard isAvailable else {
            #if DEBUG
            print("🔑 iCloud unavailable — skipping KVS observer registration")
            #endif
            return
        }
        dependencies.changes.observe { [weak self] change in
            guard let self else { return }
            Task { await self.handleICloudChange(change) }
        }
    }

    // MARK: - Public API

    /// Returns the stable user ID, resolving from iCloud KVS, Keychain, or generating a new one.
    func getUserID() -> String {
        if let cached = cachedUserID { return cached }

        let id = resolveUserID()
        cachedUserID = id
        return id
    }

    // MARK: - Resolution

    /// Priority: iCloud KVS → Keychain → generate new UUID
    private func resolveUserID() -> String {
        let iCloudAvailable = cloudAvailability.isAvailable

        // 1. Check iCloud KVS (only if iCloud is available)
        if iCloudAvailable,
           let iCloudID = iCloudStore.string(forKey: Constants.iCloudKVSUserIDKey),
           !iCloudID.isEmpty {
            // Adopt iCloud value and ensure Keychain matches
            saveToKeychain(iCloudID)
            return iCloudID
        }

        // 2. Check Keychain
        if let keychainID = readFromKeychain() {
            // Push to iCloud KVS for cross-device sync
            if iCloudAvailable { saveToiCloudKVS(keychainID) }
            return keychainID
        }

        // 3. Generate new UUID
        let newID = UUID().uuidString
        saveToKeychain(newID)
        if iCloudAvailable { saveToiCloudKVS(newID) }
        return newID
    }

    // MARK: - iCloud Change Handler

    private func handleICloudChange(_ change: KVSChange) {
        guard change.changedKeys.contains(Constants.iCloudKVSUserIDKey) else { return }

        // Only process server changes or initial sync
        guard change.reason.deliversRemoteValues else { return }

        guard let incomingID = iCloudStore.string(forKey: Constants.iCloudKVSUserIDKey),
              !incomingID.isEmpty else {
            return
        }

        // Intended gate: a device that has already established its own identity keeps it, so
        // two devices launched in parallel can't ping-pong UUIDs forever. `hasBeenUsedKey`
        // has NO writer anywhere in the repo, so `hasBeenUsed` always reads false and
        // adoption is in fact UNCONDITIONAL — the ping-pong guard is inert. Benign as it
        // stands (the UUID is a Watch-pairing correlator, not a credential, and writing this
        // KVS key at all requires the user's own Apple ID), and the read targets
        // `UserDefaults.standard` where the App-Group store is the documented home. Wiring a
        // writer is a live change to identity resolution with watch-pairing blast radius —
        // land it deliberately, with coverage for the newly-reachable `else` branch.
        let hasBeenUsed = UserDefaults.standard.bool(forKey: Constants.hasBeenUsedKey)
        if !hasBeenUsed {
            cachedUserID = incomingID
            saveToKeychain(incomingID)
            #if DEBUG
            print("🔑 Adopted iCloud user ID: \(incomingID)")
            #endif
        } else {
            #if DEBUG
            print("🔑 Ignoring iCloud user ID change — device already in use")
            #endif
        }
    }

    // MARK: - Keychain Operations

    private func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.keychainAccountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        let (status, result) = secrets.copyMatching(query)

        guard status == errSecSuccess,
              let data = result as? Data,
              let id = String(data: data, encoding: .utf8) else {
            return nil
        }

        return id
    }

    private func saveToKeychain(_ id: String) {
        guard let data = id.data(using: .utf8) else { return }

        // Try to update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainServiceName,
            kSecAttrAccount as String: Constants.keychainAccountName
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = secrets.update(query, attributes: attributes)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = secrets.add(addQuery)
            #if DEBUG
            if addStatus != errSecSuccess {
                print("⚠️ Keychain add failed: \(addStatus)")
            }
            #endif
        }
    }

    // MARK: - iCloud KVS Operations

    private func saveToiCloudKVS(_ id: String) {
        iCloudStore.set(id, forKey: Constants.iCloudKVSUserIDKey)
        iCloudStore.synchronize()
    }
}

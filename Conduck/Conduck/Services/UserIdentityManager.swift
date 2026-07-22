import Foundation
import Security

/// Manages a stable user identity (UUID) persisted in Keychain and synced via iCloud KVS.
/// This UUID is sent as `transaction_id` to the backend for rate limiting and analytics.
actor UserIdentityManager {
    static let shared = UserIdentityManager()

    private var cachedUserID: String?

    private init() {
        // Register for iCloud KVS external change notifications (only if iCloud is available)
        Task { @MainActor in
            guard FileManager.default.ubiquityIdentityToken != nil else {
                #if DEBUG
                print("🔑 iCloud unavailable — skipping KVS observer registration")
                #endif
                return
            }
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default,
                queue: .main
            ) { notification in
                Task { await UserIdentityManager.shared.handleiCloudChange(notification) }
            }
            NSUbiquitousKeyValueStore.default.synchronize()
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
        let iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil

        // 1. Check iCloud KVS (only if iCloud is available)
        if iCloudAvailable,
           let iCloudID = NSUbiquitousKeyValueStore.default.string(forKey: Constants.iCloudKVSUserIDKey),
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

    private func handleiCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
              changedKeys.contains(Constants.iCloudKVSUserIDKey) else {
            return
        }

        // Only process server changes or initial sync
        guard changeReason == NSUbiquitousKeyValueStoreServerChange ||
              changeReason == NSUbiquitousKeyValueStoreInitialSyncChange else {
            return
        }

        guard let incomingID = NSUbiquitousKeyValueStore.default.string(forKey: Constants.iCloudKVSUserIDKey),
              !incomingID.isEmpty else {
            return
        }

        // If this device hasn't been used for API calls yet, adopt the incoming UUID
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

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

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

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            #if DEBUG
            if addStatus != errSecSuccess {
                print("⚠️ Keychain add failed: \(addStatus)")
            }
            #endif
        }
    }

    // MARK: - iCloud KVS Operations

    private func saveToiCloudKVS(_ id: String) {
        NSUbiquitousKeyValueStore.default.set(id, forKey: Constants.iCloudKVSUserIDKey)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}

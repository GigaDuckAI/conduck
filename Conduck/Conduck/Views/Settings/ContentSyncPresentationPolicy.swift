// SPDX-License-Identifier: Apache-2.0

// Copy shared by General, destructive actions and unavailable Work files. These
// functions take the requested preference explicitly: OFF must not promise that
// missing bytes will arrive, and a synced usage-clear remains account-wide.

import Foundation

nonisolated enum ContentSyncPresentationPolicy {
    static let toggleLabel = LocalizedStringResource(
        "settings.contentSync.label", defaultValue: "Sync content with iCloud")

    static func explanation(enabled: Bool) -> LocalizedStringResource {
        enabled
            ? LocalizedStringResource("settings.contentSync.explanation.on", defaultValue: "Conversations, Work, files and usage records sync across your devices. This choice applies across your devices. Settings and keys continue to sync when available.")
            : LocalizedStringResource("settings.contentSync.explanation.off", defaultValue: "Automatic content sync is turned off across your devices as they receive this change. Content already on each device and in iCloud is kept. Settings and keys continue to sync when available.")
    }

    static func confirmation(enabling: Bool) -> LocalizedStringResource {
        enabling
            ? LocalizedStringResource("settings.contentSync.enable.message", defaultValue: "Content created or changed on any of your devices while sync was off will sync with the current iCloud account, including edits and deletions. Content already in iCloud will become available again as your devices receive this change.")
            : LocalizedStringResource("settings.contentSync.disable.message", defaultValue: "Conversations, Work, files and usage records will stop syncing as your devices receive this change. Content already on each device and in iCloud is kept. This does not free iCloud storage.")
    }

    static func missingFileSummary(enabled: Bool) -> LocalizedStringResource {
        enabled
            ? LocalizedStringResource("workboard.material.syncPending", defaultValue: "Waiting for iCloud…")
            : LocalizedStringResource("workboard.material.syncOff", defaultValue: "Not on this device · content sync is off")
    }

    static func missingFileExplanation(enabled: Bool, sharing: Bool) -> LocalizedStringResource {
        if !enabled {
            return LocalizedStringResource("workboard.material.syncOff.explanation", defaultValue: "This material is not on this device, and content sync is off. Use a device where the file is available, or turn content sync on in Settings → General.")
        }
        return sharing
            ? LocalizedStringResource("workboard.material.share.syncPending", defaultValue: "This material is still arriving from iCloud. It can be shared once it lands on this device.")
            : LocalizedStringResource("workboard.material.preview.syncPending", defaultValue: "This material is still arriving from iCloud. It will open once it lands on this device.")
    }

    static func deleteAllConversations(enabled: Bool) -> LocalizedStringResource {
        enabled
            ? LocalizedStringResource("conversations.deleteAll.synced.message", defaultValue: "This removes every conversation and its usage records from this device and all your other devices. Your Work desk and everything on it stay untouched. This cannot be undone.")
            : LocalizedStringResource("conversations.deleteAll.local.message", defaultValue: "This removes every conversation from this device. These deletions can sync while turning off is still in progress or if you turn content sync back on. Usage history is cleared across all your devices even while content sync is off. Your Work desk stays untouched. This cannot be undone.")
    }
}

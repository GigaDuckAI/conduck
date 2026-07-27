// SPDX-License-Identifier: Apache-2.0

// Conduck Watch
// WatchDiagnosticsReporter.swift
//
// Builds the reply for the iPhone → Watch `diagnostics-pull` interactive
// message (the Diagnostics screen's live Watch health query). Local reads
// ONLY — no network, no prompts, no Keychain: settings-envelope high-waters,
// relay queue depth, the Watch's own mic/notification permission STATUS, and
// version identity. Every value is a plist-clean primitive (Int / Double /
// String enum-name / Bool) — allowlist-safe by construction, never a
// URL/token/name (never-log posture applies to the wire too).
//
// Cheap by design: the phone races a ~5 s deadline against this reply, so a
// saturated main actor here reads as a false timeout over there — keep the
// gatherer to instant reads.

import AVFoundation
import Foundation
import UserNotifications
import WatchConnectivity
import os

/// Thread-safe ONE-SHOT wrapper around a WCSession `replyHandler`. The
/// framework requires the handler be called exactly once; the responder has
/// a synchronous unknown-kind branch AND an async MainActor gather branch, so
/// the wrapper makes "at most one send wins" a hard guarantee rather than a
/// code-path promise. `@unchecked Sendable`: the closure itself comes from
/// WatchConnectivity (callable from any thread); the lock serializes the
/// fired-flag check-and-set.
final class WatchOneShotReply: @unchecked Sendable {
    private let fired = OSAllocatedUnfairLock(initialState: false)
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    /// Deliver `payload` if nothing has been delivered yet; later calls no-op.
    func send(_ payload: [String: Any]) {
        let first = fired.withLock { alreadyFired -> Bool in
            if alreadyFired { return false }
            alreadyFired = true
            return true
        }
        guard first else { return }
        handler(payload)
    }
}

@MainActor
enum WatchDiagnosticsReporter {

    /// Gather the live Watch facts and build the reply dict.
    static func currentReply() async -> [String: Any] {
        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        return makeReply(
            appVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?",
            appBuild: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?",
            osVersion: osVersionString(),
            sttEnvelopeTs: WatchSettingsReader.shared.lastEnvelopeTimestamp,
            agentEnvelopeTs: WatchSettingsReader.shared.lastRemoteAgentEnvelopeTimestamp,
            relayQueueDepth: AppleRelayPendingQueue.shared.entryCount,
            micPermission: micPermissionName(AVAudioApplication.shared.recordPermission),
            notificationPermission: notificationStatusName(notifSettings.authorizationStatus),
            companionReachable: WCSession.default.isReachable
        )
    }

    /// Pure payload builder — the testable core (ConduckWatchTests assert the
    /// wire shape without a live session). Keys from
    /// `Constants.WatchDiagnosticsReplyKey`; `diag.v` is ALWAYS stamped (the
    /// phone rejects a version-less reply as "unsupported").
    static func makeReply(
        appVersion: String,
        appBuild: String,
        osVersion: String,
        sttEnvelopeTs: Double,
        agentEnvelopeTs: Double,
        relayQueueDepth: Int,
        micPermission: String,
        notificationPermission: String,
        companionReachable: Bool
    ) -> [String: Any] {
        typealias Key = Constants.WatchDiagnosticsReplyKey
        return [
            Key.version: Key.schemaVersion,
            Key.appVersion: appVersion,
            Key.appBuild: appBuild,
            Key.osVersion: osVersion,
            Key.sttEnvelopeTs: sttEnvelopeTs,
            Key.agentEnvelopeTs: agentEnvelopeTs,
            Key.relayQueueDepth: relayQueueDepth,
            Key.micPermission: micPermission,
            Key.notificationPermission: notificationPermission,
            Key.companionReachable: companionReachable,
        ]
    }

    // MARK: - Enum-name helpers (allowlist-safe primitives)

    private static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func micPermissionName(_ status: AVAudioApplication.recordPermission) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    static func notificationStatusName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}

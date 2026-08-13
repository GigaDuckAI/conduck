// SPDX-License-Identifier: Apache-2.0

// Conduck
// ReplyNotificationSoundPolicy.swift
//
// Whether a landing reply is allowed to make a sound: one chime per burst, not
// one per reply. The window lives in App-Group `UserDefaults`
// (`Constants.lastReplyChimeAtKey`), never in a process-local static — on iOS
// the process is relaunched by the background URLSession event once per landing
// turn, so a process-local timestamp would reset every time and three agents
// answering at once would chime three times. That is the exact failure this
// exists to kill.
//
// `@MainActor` serializes the read-modify-write against the only other writer in
// the process; there is no second WRITING process (no extension posts reply
// notifications), so a defaults key is enough and no cross-process lock is
// needed.
//
// REPLIES ONLY. Failure notifications always chime and never consume the
// window — do not "unify" the two later. A burst is many agents answering at
// once, which is a reply phenomenon; failures do not arrive in bursts, and a
// failure is the one thing worth hearing every time.

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum ReplyNotificationSoundPolicy {

    /// How long one chime speaks for. Long enough to cover a genuine burst
    /// (several gateways answering within seconds of each other), short enough
    /// that two unrelated replies minutes apart both sound.
    static let burstWindow: TimeInterval = 30

    /// Pure predicate — no storage, no clock of its own.
    ///
    /// A `lastChimeAt` in the FUTURE (device clock moved backwards between the
    /// write and this read) counts as expired: the alternative is silence for
    /// however far the clock jumped, and a missed chime is the worse failure.
    static func shouldChime(now: Date, lastChimeAt: Date?) -> Bool {
        guard let lastChimeAt else { return true }
        let elapsed = now.timeIntervalSince(lastChimeAt)
        return elapsed < 0 || elapsed >= burstWindow
    }

    /// Read the window, decide, and — when the answer is yes — CONSUME it by
    /// stamping `now`. One call per posted reply notification; the caller uses
    /// the result to set (or omit) the notification sound.
    ///
    /// A `false` answer deliberately does NOT re-stamp: the window measures time
    /// since the last audible chime, so a silent reply must not extend it.
    static func consumeChime(
        now: Date = Date(),
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> Bool {
        let stored = defaults.double(forKey: Constants.lastReplyChimeAtKey)
        let lastChimeAt = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        guard shouldChime(now: now, lastChimeAt: lastChimeAt) else { return false }
        defaults.set(now.timeIntervalSince1970, forKey: Constants.lastReplyChimeAtKey)
        return true
    }

    /// The window may only be spent on a notification that will actually be
    /// HEARD. `NotificationDelegate.willPresent` strips `.sound` from every
    /// foreground presentation (and suppresses the banner entirely for the
    /// thread the user is reading), so a reply landing while the app is
    /// frontmost cannot chime no matter what this policy says. Consuming the
    /// window there would degrade "one chime per burst" into ZERO chimes per
    /// burst: the first, silent reply would mute every reply that followed it
    /// within 30 s, including the ones that land after the user locks the phone.
    ///
    /// Frontmost is read at POST time, which is the same main-actor turn the
    /// delegate's decision runs in — not a prediction about the future.
    ///
    /// `appIsFrontmost` is `nil` in production — a default argument is evaluated
    /// in a nonisolated context and so cannot read the main-actor state itself;
    /// tests pass the flag explicitly.
    static func consumeChimeIfAudible(
        appIsFrontmost: Bool? = nil,
        now: Date = Date(),
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> Bool {
        guard !(appIsFrontmost ?? Self.appIsFrontmost) else { return false }
        return consumeChime(now: now, defaults: defaults)
    }

    /// Whether this app is the frontmost, active app right now.
    ///
    /// iOS treats only `.active` as frontmost: `.inactive` covers transitions
    /// (app switcher, an incoming call banner) where the system may present the
    /// notification itself rather than routing it through `willPresent`, and a
    /// missed chime is the worse failure — so anything short of certainly-silent
    /// is allowed to sound.
    static var appIsFrontmost: Bool {
        #if os(macOS)
        return NSApplication.shared.isActive
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }

    /// Test-only reset so suite order cannot leak a consumed window.
    static func _resetForTesting(
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) {
        defaults.removeObject(forKey: Constants.lastReplyChimeAtKey)
    }
}

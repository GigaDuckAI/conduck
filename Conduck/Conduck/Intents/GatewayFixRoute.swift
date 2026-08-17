// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayFixRoute.swift
//
// Turns "the app opened" into "the user is on the fix".
//
// An App Intent cannot present a screen. When a headless capture finds that this
// device's "Default for new chats" cannot send, the most it can do is ask the
// system to continue in the foreground — and the request then has to survive the
// gap between the ask and the view actually mounting. That gap is why the flag
// is set BEFORE the notification is posted: a cold launch has no observer
// registered yet and misses the post entirely, so the root reads the flag in
// `.onAppear` instead.
//
// Modelled on `AutoSpeakMailbox`, which solves the identical staged-request
// problem for a reply the user asked to hear.
//
// IN-MEMORY, NEVER PERSISTED, deliberately: a fix request that outlived the
// process and reopened Settings days later would be a surprise, not a service.
// The user's problem is the capture they are making right now; if they walk
// away, the request should die with the process.
//
// And within the process it is re-validated rather than replayed: the landing
// site re-reads the default before it navigates, because a pointer that could
// not send when the capture was refused can be sendable by the time the app
// opens — the same pointer, a readable Keychain. See `consumeIfStillBroken`.

import Foundation

extension Notification.Name {
    /// Posted when something headless wants the app, once foregrounded, to land
    /// the user on Settings → Personal AI.
    static let openGatewayFixRoute = Notification.Name("openGatewayFixRoute")
}

@MainActor
enum GatewayFixRoute {
    /// A route waiting to be consumed by whichever root mounts first.
    private static var pending = false

    /// Whether this process has already shown the user a foreground-continuation
    /// prompt for a broken default.
    private static var promptedThisProcess = false

    /// Ask for the route. SET-THEN-POST: the flag has to be true before the
    /// notification goes out, or a root that mounts between the two ends up with
    /// neither signal.
    static func request() {
        pending = true
        NotificationCenter.default.post(name: .openGatewayFixRoute, object: nil)
    }

    /// One-shot read-and-clear, RE-VALIDATED: true only if a route was pending
    /// AND this device's default still cannot send.
    ///
    /// Consumers must call it from BOTH an `.onReceive` of
    /// `.openGatewayFixRoute` AND an `.onAppear`, on EVERY platform root — a warm
    /// app hears the post and a cold launch never does, and a root that handles
    /// only one of the two cases silently drops half the requests.
    ///
    /// The re-read is what keeps the route honest across time, and the mechanism
    /// is NOT a synced pointer — the default pointer is device-local by design
    /// (`resolveDefaultGateway` reads App Groups with no iCloud-KVS fallback), so
    /// no amount of work on an iPad moves this device's. What DOES change under
    /// the app's feet is whether that same pointer can send: gateway definitions
    /// sync, and a Keychain that becomes readable after first unlock — or a
    /// bearer token that finishes arriving over iCloud Keychain — turns a broken
    /// default into a working one with nothing written to the pointer at all.
    /// Landing the user in Settings for a problem that resolved itself is a worse
    /// answer than saying nothing, so a default that can send again drops the
    /// route SILENTLY — the request described a state, not an appointment.
    ///
    /// NO EXPIRY on top of this. A timestamp would only approximate the question
    /// the re-read answers exactly, and the route already dies with the process
    /// (it is in-memory), so the longest a stale request can live is one app
    /// session.
    ///
    /// The claim happens BEFORE the read: the flag is one-shot, and two roots
    /// suspended on the same read would both consume the same request. Every
    /// verdict that cannot send keeps the route, `.readingUnreliable` included —
    /// a locked Keychain is not evidence the problem is gone, and Settings is a
    /// harmless place to arrive.
    ///
    /// `defaultRemoteAgentRefIfSendable()` resolves, and resolving can persist an
    /// adoption, so call this from a root's `.onAppear` / route notification —
    /// which both roots already re-seed their pickers from — and never from a
    /// handler for `.settingsDidChangeRemotely`.
    static func consumeIfStillBroken(settings: SettingsManager = .shared) async -> Bool {
        guard claim() else { return false }
        return await settings.defaultRemoteAgentRefIfSendable() == nil
    }

    /// The read-and-clear half, on its own so the claim can happen before the
    /// suspension in `consumeIfStillBroken`.
    private static func claim() -> Bool {
        guard pending else { return false }
        pending = false
        return true
    }

    /// True at most once per process. The foreground continuation RE-PERFORMS the
    /// intent, so an unguarded prompt would ask again on the second pass and loop
    /// the user through the same dialog for as long as the default stays broken.
    static func claimForegroundPrompt() -> Bool {
        guard !promptedThisProcess else { return false }
        promptedThisProcess = true
        return true
    }
}

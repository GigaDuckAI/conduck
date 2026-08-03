// SPDX-License-Identifier: Apache-2.0

// Conduck
// Pasteboard.swift
//
// Cross-platform clipboard write — the single home for the
// `UIPasteboard` / `NSPasteboard` `#if` split that is otherwise
// duplicated across the app's copy-to-clipboard call sites.
//
// Reads are macOS-only and deliberately asymmetric; see `read()`.

import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#elseif canImport(AppKit)
import AppKit
#endif

enum Pasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    #if os(macOS)
    /// Current clipboard text, or nil when it holds none.
    ///
    /// macOS ONLY, and the asymmetry is the point: AppKit has no paste-consent
    /// model, so a plain Button reading here is the native shape and matches the
    /// surrounding controls. The same read on iOS raises the system
    /// "<App> pasted from <App>" alert, so that call site uses SwiftUI's
    /// `PasteButton` instead — there the tap IS the consent, no alert appears,
    /// and the control self-disables when the clipboard has no text. Adding a
    /// UIKit branch here would invite a call site that trips that alert.
    static func read() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
    #endif

    /// What macOS leaves in the clipboard once a sensitive copy has expired.
    ///
    /// A blank clipboard is the wrong end state: the user's next ⌘V yields
    /// NOTHING, and an empty string landing in a server-side auth file
    /// (`htpasswd`, `rclone.conf`, a Caddyfile) breaks authentication with no
    /// visible cause — the exact invisible-failure class the file-transfer setup
    /// screen works hard to eliminate. A self-describing replacement fails just
    /// as loudly but tells the user WHY when they look at what they pasted.
    ///
    /// Shape constraints, all load-bearing — a translation must preserve them:
    /// ONE line (a trailing newline pasted into a terminal executes the line),
    /// no `:` (it would split a `user:hash` htpasswd record into extra fields),
    /// and no shell metacharacters. `PasteboardExpiryPlaceholderTests` asserts
    /// all three, which is why this sits OUTSIDE the AppKit `#if`: the test
    /// target runs on the iOS Simulator.
    static let expiredPlaceholder = String(
        localized: "pasteboard.expired.placeholder",
        defaultValue: "Conduck expired this clipboard copy - copy it again in Conduck"
    )

    /// Copy a SENSITIVE string (e.g. the gateway setup code, which embeds a
    /// full-access bearer token) with a bounded system-clipboard lifetime.
    /// Plain `copy(_:)` writes to the general pasteboard with NO expiry — on iOS
    /// that survives reboots/uninstall and syncs via Universal Clipboard forever;
    /// on macOS it sits in the clipboard until the next write. Both are wrong for
    /// a credential. This variant bounds that persistence.
    ///
    /// HONEST LIMIT: the bound buys the IDLE-clipboard window, not secrecy from
    /// clipboard-history utilities (Raycast, Alfred, Paste, Maccy). Those
    /// snapshot on the `changeCount` bump at WRITE time, so nothing done later —
    /// expiry, clear, replacement — can un-archive what they already captured.
    static func copySensitive(_ string: String, expiresAfter seconds: TimeInterval = 180) {
        #if canImport(UIKit)
        // DELIBERATELY no `.localOnly`: Universal Clipboard to the user's OWN Mac
        // is a designed onboarding transfer path (E2E via the user's Apple ID —
        // paste the setup code straight into Conduck on their Mac). The
        // `.expirationDate` bounds how long the credential lingers system-wide,
        // which is the actual risk we're closing.
        //
        // No `expiredPlaceholder` on this branch, unlike AppKit below: the OS
        // enforces `.expirationDate` itself, so the bound holds even after
        // Conduck is terminated — a placeholder would mean giving that up for an
        // in-process timer that dies with the app. An OS-enforced expiry that
        // always fires beats an explanation that only sometimes appears.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: string]],
            options: [.expirationDate: Date().addingTimeInterval(seconds)]
        )
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        // NSPasteboard has NO expiration API, so this is a best-effort
        // REPLACEMENT: capture the change count after our write, then after
        // `seconds` overwrite the pasteboard ONLY if it's still our contents (an
        // unchanged count means nothing has written since). If a later write
        // replaced it, or the user copied something else, we leave it alone —
        // clobbering an unrelated clipboard would be its own foot-gun. If the app
        // quits before the timer fires, the expiry is lost — acceptable best
        // effort. `expiredPlaceholder` rather than a bare `clearContents()` so a
        // late ⌘V pastes an explanation instead of nothing; see that constant.
        let writtenCount = NSPasteboard.general.changeCount
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard NSPasteboard.general.changeCount == writtenCount else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Pasteboard.expiredPlaceholder, forType: .string)
        }
        #endif
    }
}

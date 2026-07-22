// Conduck
// Pasteboard.swift
//
// Cross-platform clipboard write — the single home for the
// `UIPasteboard` / `NSPasteboard` `#if` split that is otherwise
// duplicated across the app's copy-to-clipboard call sites.

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

    /// Copy a SENSITIVE string (e.g. the gateway setup code, which embeds a
    /// full-access bearer token) with a bounded system-clipboard lifetime.
    /// Plain `copy(_:)` writes to the general pasteboard with NO expiry — on iOS
    /// that survives reboots/uninstall and syncs via Universal Clipboard forever;
    /// on macOS it sits in the clipboard until the next write. Both are wrong for
    /// a credential. This variant bounds that persistence.
    static func copySensitive(_ string: String, expiresAfter seconds: TimeInterval = 180) {
        #if canImport(UIKit)
        // DELIBERATELY no `.localOnly`: Universal Clipboard to the user's OWN Mac
        // is a designed onboarding transfer path (E2E via the user's Apple ID —
        // paste the setup code straight into Conduck on their Mac). The
        // `.expirationDate` bounds how long the credential lingers system-wide,
        // which is the actual risk we're closing.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: string]],
            options: [.expirationDate: Date().addingTimeInterval(seconds)]
        )
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        // NSPasteboard has NO expiration API, so this is a best-effort clear:
        // capture the change count after our write, then after `seconds` clear
        // the pasteboard ONLY if it's still our contents (an unchanged count
        // means nothing has written since). If a later write replaced it, or the
        // user copied something else, we leave it alone. If the app quits before
        // the timer fires, the clear is lost — acceptable best effort.
        let writtenCount = NSPasteboard.general.changeCount
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if NSPasteboard.general.changeCount == writtenCount {
                NSPasteboard.general.clearContents()
            }
        }
        #endif
    }
}

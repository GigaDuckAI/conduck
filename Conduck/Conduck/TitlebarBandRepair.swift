#if os(macOS)
//
//  TitlebarBandRepair.swift
//  Conduck
//
//  Workaround for a macOS 26 AppKit mis-layout: when the main window is laid
//  out while another window is frontmost (first-run onboarding over a restored
//  main window), the split view's `NSTitlebarBackgroundView` instances — the
//  views hosting the titlebar's scroll-edge glass (`NSScrollPocket` →
//  `NSHardPocketView` + backdrop) — land at a stale vertical offset and AppKit
//  never re-lays them out. Visible symptom: a toolbar-height translucent band
//  compositing partway down the transcript (captured at topΔ=199pt on a 949pt
//  window; the sidebar column's background sat 251pt ABOVE the window,
//  off-screen). SwiftUI `scrollEdgeEffectHidden` cannot reach these views
//  (window chrome, outside any app subtree), and a plain
//  `needsLayout`/`layoutSubtreeIfNeeded` pass recomputes the same stale
//  frames (verified by instrumented capture 2026-07-20) — only an explicit
//  frame correction (or a sidebar collapse/expand) fixes them.
//
//  Mechanism: sweep every titled visible window shortly after launch and
//  after any titled window closes (the onboarding hand-off); any
//  `NSTitlebarBackgroundView` whose top edge is not at the window's top edge
//  gets its origin corrected so it is. Exact-class-name match + |offset| > 4pt
//  keeps the detector narrow; correctly-placed chrome is never touched, so
//  repeat sweeps are no-ops. Public API only (`type(of:)`, `convert`,
//  `setFrameOrigin`) — App Store safe. On macOS versions without the bug the
//  detector finds nothing.
//

import AppKit
import os

enum TitlebarBandRepair {
    private static let log = Logger(subsystem: Constants.identityNamespace, category: "TitlebarBandRepair")
    private static var closeObserver: NSObjectProtocol?

    /// Call once from `applicationDidFinishLaunching`. Sweep times bracket the
    /// window-restoration + onboarding launch sequence (the captured
    /// misplacement exists by +6s and is stable), plus a sweep 1s after any
    /// titled window closes — the onboarding-dismiss hand-off for first-run.
    static func activate() {
        for delay in [1.5, 4.0, 8.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sweep() }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let w = note.object as? NSWindow, w.styleMask.contains(.titled) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sweep() }
        }
    }

    private static func sweep() {
        for window in NSApp.windows where window.styleMask.contains(.titled) && window.isVisible {
            guard let content = window.contentView else { continue }
            var root: NSView = content
            while let s = root.superview { root = s }
            repairMisplaced(in: root, window: window)
        }
    }

    private static func repairMisplaced(in view: NSView, window: NSWindow) {
        if String(describing: type(of: view)) == "NSTitlebarBackgroundView" {
            let inWindow = view.convert(view.bounds, to: nil)
            let topDelta = window.frame.height - inWindow.maxY
            if abs(topDelta) > 4 {
                // Shift so the view's top edge sits at the window top. Window
                // coords are bottom-origin: positive dY moves the view up.
                let dY = window.frame.height - inWindow.maxY
                var origin = view.frame.origin
                if view.superview?.isFlipped == true {
                    origin.y -= dY
                } else {
                    origin.y += dY
                }
                log.notice("repairing NSTitlebarBackgroundView in window \(window.windowNumber): topΔ=\(Int(topDelta))pt → origin \(String(describing: origin))")
                view.setFrameOrigin(origin)
            }
            return  // container corrected (or already correct); children follow
        }
        for sub in view.subviews {
            repairMisplaced(in: sub, window: window)
        }
    }
}
#endif

#if os(macOS) && DEBUG
//
//  DebugHierarchyDump.swift
//  Conduck
//
//  Forensic capture for the macOS 26 stale scroll-edge band (the glass strip
//  that composites ~203pt below the main-window top and survives the SwiftUI
//  `scrollEdgeEffectHidden` opt-outs on both the transcript and the sidebar).
//  Gated by `-ConduckDumpHierarchy`. Captures, for EVERY window of this app:
//    • the full view tree from the theme-frame root (titlebar/toolbar hosts —
//      where edge-effect pockets live — are siblings of contentView),
//    • the full CALayer tree (a stale composite can be a view-less layer),
//    • toolbar items (incl. NSTrackingSeparatorToolbarItem), titlebar
//      accessories, and the NSSplitViewController/item structure,
//    • three window inventories (NSApp.windows, orderedWindows, CGWindowList
//      for this PID — catches panels/borderless/"dismissed" windows),
//  and a CANDIDATE summary of anything ~45-60pt tall & pane-wide or sitting
//  180-230pt below the window top (the band's fingerprint). Geometry is
//  normalized to "pt below window top" so dumps match screenshot forensics
//  directly. Snapshots: fixed cadence (6/20/30/40/50/60s — the 30-50s slots
//  bracket a founder-performed sidebar collapse/expand) plus one on every
//  NSWindow.willClose (brackets onboarding dismissal) and 1s after it.
//  Public API only; frames + AppKit class names, no content — the never-log
//  rule is untouched. Deliberately NO layoutSubtreeIfNeeded/displayIfNeeded
//  anywhere: forcing layout could cure the missing invalidation before the
//  capture (the staleness IS the evidence).
//

import AppKit
import CoreGraphics

enum DebugHierarchyDump {
    private static var closeObserver: NSObjectProtocol?
    private static var dumpCounter = 0

    /// Call once from `applicationDidFinishLaunching`.
    static func scheduleIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-ConduckDumpHierarchy") else { return }
        for delay in [6.0, 10.0, 14.0, 20.0, 30.0, 40.0, 50.0, 60.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                dump(tag: "t\(Int(delay))s")
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            // Titled app windows only — transient system helper windows (text
            // cursor `TUINSWindow` etc.) close constantly and their AppKit
            // accessors assert on style-dependent queries.
            guard let w = note.object as? NSWindow, w.styleMask.contains(.titled) else { return }
            let num = w.windowNumber
            dump(tag: "willClose-w\(num)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dump(tag: "postClose-w\(num)")
            }
        }
    }

    private static func dump(tag: String) {
        guard dumpCounter < 24 else { return }  // disk-spam backstop
        dumpCounter += 1
        var out = "=== Conduck hierarchy dump #\(dumpCounter) (\(tag)) \(Date()) ===\n"
        var candidates: [String] = []

        out += "\n--- NSApp.windows ---\n"
        for w in NSApp.windows { out += windowLine(w) }
        out += "--- NSApp.orderedWindows (front to back) ---\n"
        for w in NSApp.orderedWindows { out += windowLine(w) }
        out += "--- CGWindowList (this PID) ---\n"
        let pid = ProcessInfo.processInfo.processIdentifier
        if let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for entry in info where (entry[kCGWindowOwnerPID as String] as? Int32) == pid {
                let num = entry[kCGWindowNumber as String] as? Int ?? -1
                let layerLevel = entry[kCGWindowLayer as String] as? Int ?? 0
                let alpha = entry[kCGWindowAlpha as String] as? Double ?? -1
                let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
                out += "  cgwindow num=\(num) level=\(layerLevel) alpha=\(alpha) bounds=\(bounds)\n"
            }
        } else {
            out += "  (CGWindowList unavailable)\n"
        }

        for window in NSApp.windows {
            out += "\nWINDOW \(windowLine(window))"
            out += "  contentLayoutRect=\(window.contentLayoutRect) styleMask=\(window.styleMask.rawValue)\n"

            // Style-dependent accessors (titlebar accessories, toolbar style)
            // ASSERT on non-titled system windows ('titlebarAccessoryViewControllers
            // not supported for this window style' killed run 1) — walk those
            // windows' trees but skip the titled-only queries.
            let isTitled = window.styleMask.contains(.titled)

            if isTitled, let toolbar = window.toolbar {
                out += "  --- toolbar (style=\(window.toolbarStyle.rawValue)) ---\n"
                for item in toolbar.items {
                    var line = "    \(type(of: item)) id=\(item.itemIdentifier.rawValue) visible=\(item.isVisible)"
                    if let v = item.view { line += " viewFrame=\(v.frame)" }
                    if let tracking = item as? NSTrackingSeparatorToolbarItem {
                        line += " dividerIndex=\(tracking.dividerIndex)"
                    }
                    out += line + "\n"
                }
            }
            if isTitled, !window.titlebarAccessoryViewControllers.isEmpty {
                out += "  --- titlebar accessories ---\n"
                for vc in window.titlebarAccessoryViewControllers {
                    out += "    \(type(of: vc)) layoutAttribute=\(vc.layoutAttribute.rawValue) viewFrame=\(vc.view.frame) hidden=\(vc.isHidden)\n"
                }
            }
            if let rootVC = window.contentViewController {
                out += "  --- view controllers ---\n"
                walk(controller: rootVC, depth: 2, into: &out)
            }

            guard let content = window.contentView else { continue }
            let root = rootView(of: content)
            out += "  --- view tree (topΔ = pt below window top) ---\n"
            walk(view: root, window: window, depth: 1, into: &out, candidates: &candidates)
            if let rootLayer = rootLayer(of: root) {
                out += "  --- layer tree ---\n"
                walk(layer: rootLayer, windowHeight: window.frame.height, depth: 1,
                     into: &out, candidates: &candidates)
            }
        }

        out += "\n=== CANDIDATES (≈45-60pt tall & ≥600pt wide, or top 180-230pt below window top) ===\n"
        out += candidates.isEmpty ? "(none)\n" : candidates.joined(separator: "\n") + "\n"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-hierarchy-\(String(format: "%02d", dumpCounter))-\(tag).txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        print("DebugHierarchyDump: wrote \(url.path)")
    }

    private static func windowLine(_ w: NSWindow) -> String {
        "  \(type(of: w)) num=\(w.windowNumber) title=\"\(w.title)\" frame=\(w.frame) "
        + "visible=\(w.isVisible) key=\(w.isKeyWindow) main=\(w.isMainWindow) "
        + "level=\(w.level.rawValue) occlusion=\(w.occlusionState.rawValue) "
        + "parent=\(w.parent?.windowNumber ?? 0) sheet=\(w.attachedSheet?.windowNumber ?? 0)\n"
    }

    private static func rootView(of view: NSView) -> NSView {
        var v = view
        while let s = v.superview { v = s }
        return v
    }

    private static func rootLayer(of view: NSView) -> CALayer? {
        guard var l = view.layer else { return nil }
        while let s = l.superlayer { l = s }
        return l
    }

    private static func walk(controller: NSViewController, depth: Int, into out: inout String) {
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)\(type(of: controller)) viewFrame=\(controller.isViewLoaded ? "\(controller.view.frame)" : "unloaded")"
        if let split = controller as? NSSplitViewController {
            line += " splitItems:"
            out += line + "\n"
            for item in split.splitViewItems {
                out += "\(indent)  item vc=\(type(of: item.viewController)) collapsed=\(item.isCollapsed) "
                out += "behavior=\(item.behavior.rawValue) canCollapse=\(item.canCollapse)\n"
            }
        } else {
            out += line + "\n"
        }
        for child in controller.children {
            walk(controller: child, depth: depth + 1, into: &out)
        }
    }

    private static func walk(view: NSView, window: NSWindow, depth: Int,
                             into out: inout String, candidates: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        let inWindow = view.convert(view.bounds, to: nil)
        let topDelta = window.frame.height - inWindow.maxY
        var line = "\(indent)\(type(of: view)) frame=\(view.frame) topΔ=\(Int(topDelta)) "
        line += "size=\(Int(inWindow.width))x\(Int(inWindow.height)) "
        line += "hidden=\(view.isHidden) alpha=\(view.alphaValue)"
        if let layer = view.layer, type(of: layer) != CALayer.self {
            line += " layer=\(type(of: layer))"
        }
        if let effect = view as? NSVisualEffectView {
            line += " material=\(effect.material.rawValue) blending=\(effect.blendingMode.rawValue) state=\(effect.state.rawValue)"
        }
        if let scroll = view as? NSScrollView {
            line += " docVisible=\(scroll.documentVisibleRect) insets=\(scroll.contentInsets)"
        }
        if let clip = view as? NSClipView {
            line += " boundsOrigin=\(clip.bounds.origin) insets=\(clip.contentInsets)"
        }
        if let split = view as? NSSplitView {
            line += " isVertical=\(split.isVertical) subframes=\(split.subviews.map(\.frame))"
        }
        out += line + "\n"
        let h = inWindow.height, wdt = inWindow.width
        if !view.isHidden, ((45...60).contains(h) && wdt >= 600) || (180...230).contains(topDelta) {
            candidates.append("VIEW w\(window.windowNumber) \(type(of: view)) topΔ=\(Int(topDelta)) size=\(Int(wdt))x\(Int(h)) alpha=\(view.alphaValue)")
        }
        for sub in view.subviews {
            walk(view: sub, window: window, depth: depth + 1, into: &out, candidates: &candidates)
        }
    }

    private static func walk(layer: CALayer, windowHeight: CGFloat, depth: Int,
                             into out: inout String, candidates: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)\(type(of: layer))"
        if let name = layer.name { line += " name=\(name)" }
        line += " frame=\(layer.frame) opacity=\(layer.opacity) hidden=\(layer.isHidden) z=\(layer.zPosition)"
        if !CATransform3DIsIdentity(layer.transform) { line += " TRANSFORM≠identity" }
        if layer.contents != nil { line += " has-contents" }
        if layer.mask != nil { line += " masked" }
        // A stale composite can live in the presentation tree while the model
        // layer has already moved/shrunk — surface any divergence.
        if let pres = layer.presentation(), !pres.frame.equalTo(layer.frame) {
            line += " PRESENTATION-frame=\(pres.frame)"
        }
        out += line + "\n"
        let f = layer.frame
        if !layer.isHidden, (45...60).contains(f.height), f.width >= 600 {
            candidates.append("LAYER \(type(of: layer)) name=\(layer.name ?? "-") frame=\(f) opacity=\(layer.opacity)")
        }
        for sub in layer.sublayers ?? [] {
            walk(layer: sub, windowHeight: windowHeight, depth: depth + 1,
                 into: &out, candidates: &candidates)
        }
    }
}
#endif

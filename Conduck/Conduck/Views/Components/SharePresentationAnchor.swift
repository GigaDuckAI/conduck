// SPDX-License-Identifier: Apache-2.0

// Conduck
// SharePresentationAnchor.swift
//
// A platform view, parked in a SwiftUI surface, that the system's own share
// UI can be pointed AT.
//
// WHY IT HAS TO EXIST. Both platforms' share UI is anchored to an `NSView` /
// `UIView`, not to a SwiftUI node: `NSSharingServicePicker.show(relativeTo:of:)`
// takes the view it pops out of, and `UIActivityViewController` on iPad reads
// its popover anchor from `sourceView`/`sourceRect` and TRAPS when it has
// neither. SwiftUI hands out no such view, so one is installed deliberately.
//
// WHY A REGISTRY. Work can put a second surface on screen over the desk — the
// image gallery is a sheet — and a share fired from inside it must anchor
// inside it, not to a view the sheet is covering.
//
// THE ORDERING RULE, AND WHY IT IS ATTACHMENT AND NOT UPDATE. The winner is the
// most recently ATTACHED TO A WINDOW anchor, and ordinary SwiftUI updates do
// not change that order. Promoting on update instead would mean any redraw of
// the desk underneath — a board refresh, a capture landing, a hover — silently
// moved the anchor out from under an open gallery, and the next share would pop
// out of the surface the person is not looking at. Attachment is the event that
// actually says "this surface came on screen"; an update says nothing at all.

#if !os(watchOS)

import SwiftUI

#if os(iOS)
import UIKit
typealias SharePlatformView = UIView
#elseif os(macOS)
import AppKit
typealias SharePlatformView = NSView
#endif

/// The platform views one presenter may anchor to, in attachment order.
@MainActor
final class SharePresentationAnchor {
    private struct Registration {
        weak var view: SharePlatformView?
    }

    /// Oldest attachment first. Mounted-but-never-attached views sit here too,
    /// in mount order, so a surface whose window arrives later still promotes
    /// itself when it does.
    private var registrations: [Registration] = []

    init() {}

    /// The view a share should pop out of: the most recently attached anchor
    /// still in a window. Nil means no surface is mounted, and the caller must
    /// refuse rather than present from nowhere.
    var presentationView: SharePlatformView? {
        registrations.reversed().compactMap(\.view).first { $0.window != nil }
    }

    /// A small rect in the middle of the anchor. The share UI is deliberately
    /// NOT given an arrow direction on iPad (`permittedArrowDirections = []`),
    /// because this anchor is the surface rather than the tapped control — an
    /// arrow would point at nothing.
    var presentationRect: CGRect {
        guard let view = presentationView else { return .zero }
        return CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    }

    /// A surface mounted its anchor. IDEMPOTENT, and deliberately not a
    /// promotion: SwiftUI calls the representable's update on every redraw of
    /// the surface, and a redraw is not an arrival.
    func register(_ view: SharePlatformView) {
        prune()
        guard !registrations.contains(where: { $0.view === view }) else { return }
        registrations.append(Registration(view: view))
    }

    /// The anchor's window changed. This — and only this — reorders the
    /// registry: a view that just entered a window becomes the newest, and a
    /// view that left one keeps its place but stops being eligible, so the
    /// surface underneath wins again without having to re-register.
    func viewDidMoveToWindow(_ view: SharePlatformView) {
        prune()
        guard view.window != nil else {
            register(view)
            return
        }
        registrations.removeAll { $0.view === view }
        registrations.append(Registration(view: view))
    }

    func unregister(_ view: SharePlatformView) {
        registrations.removeAll { $0.view === view || $0.view == nil }
    }

    /// Drop entries whose view is gone, so the list cannot grow across a
    /// lifetime of sheet presentations.
    private func prune() {
        registrations.removeAll { $0.view == nil }
    }
}

/// The anchor itself. A subclass rather than a bare view because window
/// attachment is the registry's ordering event and only the view is told about
/// it — a representable's `updateUIView` fires on every redraw and cannot tell
/// an arrival from a refresh.
final class SharePresentationAnchorPlatformView: SharePlatformView {
    weak var anchor: SharePresentationAnchor?

    #if os(iOS)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        anchor?.viewDidMoveToWindow(self)
    }
    #elseif os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        anchor?.viewDidMoveToWindow(self)
    }
    #endif
}

/// Installs one anchor view in the surface it modifies.
private struct SharePresentationAnchorView {
    let anchor: SharePresentationAnchor

    @MainActor
    fileprivate func makeAnchorView() -> SharePresentationAnchorPlatformView {
        let view = SharePresentationAnchorPlatformView(frame: .zero)
        view.anchor = anchor
        #if os(iOS)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        #endif
        anchor.register(view)
        return view
    }
}

#if os(iOS)
extension SharePresentationAnchorView: UIViewRepresentable {
    func makeUIView(context: Context) -> SharePresentationAnchorPlatformView {
        makeAnchorView()
    }

    /// Membership only — never order. See the ordering rule in this file's
    /// header: promoting here is what let a redraw of the desk steal the anchor
    /// from an open gallery.
    func updateUIView(_ uiView: SharePresentationAnchorPlatformView, context: Context) {
        uiView.anchor = anchor
        anchor.register(uiView)
    }
}
#elseif os(macOS)
extension SharePresentationAnchorView: NSViewRepresentable {
    func makeNSView(context: Context) -> SharePresentationAnchorPlatformView {
        makeAnchorView()
    }

    func updateNSView(_ nsView: SharePresentationAnchorPlatformView, context: Context) {
        nsView.anchor = anchor
        anchor.register(nsView)
    }
}
#endif

extension View {
    /// Park a share anchor in this surface. It goes in the BACKGROUND so it
    /// takes the surface's own frame without changing the layout of anything
    /// drawn in front of it.
    func sharePresentationAnchor(_ anchor: SharePresentationAnchor) -> some View {
        background(
            SharePresentationAnchorView(anchor: anchor)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

#endif

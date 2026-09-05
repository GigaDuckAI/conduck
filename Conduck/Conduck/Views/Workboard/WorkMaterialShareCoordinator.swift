// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkMaterialShareCoordinator.swift
//
// ONE share presenter per surface, and the only route a Work card's bytes take
// to the system's share UI.
//
// WHY A COORDINATOR AND NOT A `ShareLink` ON THE CARD. What a card can share is
// not known when the menu is drawn: a note is text, a link is a URL, and an
// image, a file or a recording is a FILE that does not exist yet — it has to be
// copied out of the vault first. `ShareLink` is a Button with no presentation
// binding, so a card carrying one would have to prepare its file before the
// menu ever opened (a vault copy per card, on every board refresh) or make the
// person tap Share twice. This prepares on the tap and presents itself when the
// bytes are ready.
//
// WHY IT READS THE STORE AND NEVER THE BOARD. `WorkboardViewModel` reloads
// behind a 180 ms debounce, so the desk keeps drawing a card the store has
// already replaced or deleted. The bytes, meanwhile, are resolved from the
// store BY ID — so a board-level gate passes on stale metadata while the copy
// picks up the new bytes, and a replacement leaves the device under the
// previous revision's filename and type. Every gate here therefore asks
// `WorkboardLiveRepository.currentMaterialSnapshot`, which is the store, and
// asks it TWICE: once to decide what to prepare, once to decide whether the
// finished copy may still be shown. A revision that moved between the two is
// refused, which is what makes "the bytes and the name describe the same
// revision" true rather than likely.
//
// WHAT HAPPENS TO THE COPY. A copy that was never presented is removed at once:
// nothing else holds its path. A copy that WAS handed to the share UI is left
// to `TempScratchSweeper` — the destination the person picks copies out on its
// own schedule, in another process, and reports nothing back on either
// platform, so there is no moment at which deleting it is known to be safe.
// This is deliberately NOT Quick Look's rule: that presenter is dismissed by
// the person, inside this app, and the dismissal is the signal. A share has no
// such edge, which is why the per-copy age sweep is the only reclaim here.
//
// "PRESENTED" HAS TO BE MEASURED, NOT ASSUMED. A Share tap arrives from a
// context menu that is still dismissing, and a note or a link is ready in the
// same runloop turn — so the presentation request can land on a controller
// UIKit will refuse. A refusal that was reported as a hand-off is the worst of
// both worlds: nothing on screen, no failure shown, and a file kept alive for a
// share that never happened. The presenter therefore WAITS for the surface to
// settle and REPORTS whether the system actually took the request.

#if !os(watchOS)

import Foundation
import Observation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One card, resolved into the thing the system's share UI is actually given.
nonisolated enum PreparedWorkShare: Sendable {
    /// A note: its own text.
    case text(String)
    /// A link: the address itself, so receiving apps treat it as a URL rather
    /// than as a string that happens to look like one.
    case link(URL)
    /// An image, a file or a recording: a disposable copy of the ORIGINAL
    /// bytes. Never a thumbnail, and never the vault's authoritative URL.
    case file(WorkMaterialExportSnapshot)

    /// Give back a copy that was never presented. Text and links own nothing.
    func discard() {
        if case .file(let snapshot) = self { snapshot.reclaim() }
    }

    /// What the system share UI is handed. A file goes over as its URL rather
    /// than its bytes, so every destination gets the name and the type with it.
    var activityItems: [Any] {
        switch self {
        case .text(let text): return [text]
        case .link(let url): return [url]
        case .file(let snapshot): return [snapshot.url]
        }
    }
}

/// Why a share did not happen, as the frontmost surface renders it.
nonisolated struct WorkShareFailure: Equatable, Sendable {
    let title: LocalizedStringResource
    let message: String
}

/// The presentation half, behind a protocol so every decision the coordinator
/// makes — what is prepared, what is refused, what is reclaimed — is testable
/// without a window.
///
/// Two members rather than one, because the wait and the hand-off answer
/// different questions and the material has to be re-checked BETWEEN them: the
/// wait can take long enough for the desk to change again.
@MainActor
protocol WorkSharePresenting: AnyObject {
    /// Wait until the surface can actually present — a context menu still
    /// dismissing, a sheet mid-transition. `false` means it never settled and
    /// nothing should be attempted.
    func awaitPresentationReadiness(from anchor: SharePresentationAnchor) async -> Bool
    /// Show the system share UI. `false` means the system did NOT take the
    /// request, so the caller still owns the bytes.
    func present(_ share: PreparedWorkShare, from anchor: SharePresentationAnchor) -> Bool
}

@MainActor
@Observable
final class WorkMaterialShareCoordinator {

    /// The card a preparation is running for, or nil. Every surface that can be
    /// frontmost draws its "Preparing…" state from this — the menu is already
    /// gone by the time the copy starts, so without it a large file reads as a
    /// dead tap, and the gallery sheet is opaque so the desk's own banner is
    /// invisible underneath it.
    private(set) var preparingMaterialID: UUID?

    var isPreparing: Bool { preparingMaterialID != nil }

    /// The last refusal, for whichever surface is on top to render. ONE piece
    /// of state with two renderers rather than two states: the desk raises it
    /// as its own notice, the gallery draws it inline, and only the frontmost
    /// one is ever visible.
    private(set) var failure: WorkShareFailure?

    /// The card as the STORE holds it right now, by id, or nil when the store
    /// no longer holds it. Injected so this type reaches no persistence
    /// directly and a test can move the store under a preparation.
    @ObservationIgnored
    var currentMaterial: @MainActor (UUID) async throws -> WorkboardMaterialSnapshot? = { _ in nil }

    /// The platform view the share UI pops out of. Surfaces attach themselves
    /// to it with `.sharePresentationAnchor(_:)`.
    @ObservationIgnored let anchor = SharePresentationAnchor()

    @ObservationIgnored private let bytes: WorkMaterialExportBytes
    @ObservationIgnored private let presenter: any WorkSharePresenting
    /// Monotonic claim, minted at the tap. Completion order must not decide
    /// which card reaches the share sheet, and every `await` below re-checks it.
    @ObservationIgnored private var latestToken: UInt64 = 0

    init(
        bytes: WorkMaterialExportBytes = .live,
        presenter: (any WorkSharePresenting)? = nil
    ) {
        self.bytes = bytes
        self.presenter = presenter ?? WorkMaterialSharePresenter()
    }

    // MARK: - The one entry point

    /// Share the card the STORE currently holds under this id.
    ///
    /// By id and not by snapshot on purpose: the gate has to answer for the
    /// card that exists, not for the one the menu closed over, and the board
    /// the menu was drawn from is up to a debounce behind the store.
    /// - Returns: the work this tap started. Nothing in the app reads it; a
    ///   test awaits it. Nothing may cancel it — cancelling a copy mid-write
    ///   would strand a partial file the token check can no longer reach.
    @discardableResult
    func share(materialID: UUID) -> Task<Void, Never> {
        latestToken &+= 1
        let token = latestToken
        failure = nil

        return Task { [weak self] in
            guard let self else { return }
            do {
                try await run(materialID: materialID, token: token)
            } catch {
                fail(error, token: token)
            }
        }
    }

    /// Drop an in-flight preparation's claim — the surface went away, or the
    /// person left Work. A copy still being made loses the token check and
    /// reclaims itself.
    func cancelPendingShare() {
        latestToken &+= 1
        preparingMaterialID = nil
    }

    /// The frontmost surface has shown the refusal (or is going away with it
    /// unread). One clear, so the same sentence is never rendered twice.
    func clearFailure() {
        if failure != nil { failure = nil }
    }

    // MARK: - The run

    private func run(materialID: UUID, token: UInt64) async throws {
        // GATE 1 — the store, before any bytes are touched.
        let requested = try await currentMaterial(materialID)
        guard token == latestToken else { return }
        guard let requested else {
            // The card was removed between the menu opening and this tap.
            // Nothing was promised and nothing is owed: stay silent.
            preparingMaterialID = nil
            return
        }
        guard WorkboardCardActionPolicy.allows(.open, when: requested.availability) else {
            preparingMaterialID = nil
            report(Self.refusal(for: requested.availability))
            return
        }

        // The copy is named and typed from THIS revision's metadata, which is
        // the revision gate 2 re-checks below.
        preparingMaterialID = materialID
        AccessibilityAnnouncer.announce(Self.preparingCopy)

        let prepared = try await Self.prepare(requested, bytes: bytes)

        // From here the copy is OURS until the system takes it, and the reclaim
        // is a `defer` rather than a line at each exit BECAUSE one of the exits
        // is a throw: the store read below can fail, and a `catch` upstack
        // cannot see this copy to give it back. Every other early return —
        // superseded, unsettled, stale — leaves through the same defer.
        var handedOff = false
        defer { if !handedOff { prepared.discard() } }

        guard token == latestToken else { return }

        // The wait for a dismissing menu happens BEFORE the final gate, because
        // it is itself long enough for the desk to change again.
        let ready = await presenter.awaitPresentationReadiness(from: anchor)
        guard token == latestToken else { return }
        guard ready else {
            refuse(Self.presentationUnavailable)
            return
        }

        // GATE 2 — the store again. A replacement committed while the copy was
        // being made means these bytes describe a revision that no longer
        // exists, so they must not leave under this card's current name.
        let current = try await currentMaterial(materialID)
        guard token == latestToken else { return }
        guard Self.acceptsPreparedShare(requested: requested, current: current) else {
            refuse(Self.stale)
            return
        }

        preparingMaterialID = nil
        guard presenter.present(prepared, from: anchor) else {
            // The system did not take the request, so nothing is holding these
            // bytes and the defer gives them back.
            report(Self.presentationUnavailable)
            return
        }
        // Presented. The bytes belong to whatever the person picked now; the
        // per-copy age sweep is what reclaims them.
        handedOff = true
    }

    /// A finished copy nobody will ever see. The bytes go back through the
    /// caller's `defer`; this only says why.
    private func refuse(_ failure: WorkShareFailure) {
        preparingMaterialID = nil
        report(failure)
    }

    /// The ONE place a refusal is published.
    ///
    /// The announcement lives here rather than in a view because BOTH surfaces
    /// that render this are silent on their own: the desk's alert is spoken
    /// only once the system can actually present it, and the gallery's inline
    /// banner is a control that simply appears. A view-level announce is also
    /// the shape that already went wrong once — one of the two routing arms
    /// returned before reaching it.
    private func report(_ failure: WorkShareFailure) {
        self.failure = failure
        AccessibilityAnnouncer.announce(failure.message)
    }

    private func fail(_ error: Error, token: UInt64) {
        guard token == latestToken else { return }
        preparingMaterialID = nil
        if case WorkMaterialExportError.bytesUnavailable = error {
            report(Self.refusal(for: .unavailableOnThisDevice))
            return
        }
        report(WorkShareFailure(title: Self.failedTitle, message: Self.message(for: error)))
    }

    // MARK: - Preparation

    /// What one card resolves to. Nonisolated because it reads no shared state:
    /// it is handed the store's own snapshot and returns a value.
    nonisolated static func prepare(
        _ material: WorkboardMaterialSnapshot,
        bytes: WorkMaterialExportBytes
    ) async throws -> PreparedWorkShare {
        switch material.kind {
        case .note:
            // The card's own text, and its title when the body is empty. A
            // share sheet opened on an empty string offers a person nothing to
            // choose between.
            let body = material.textContent ?? material.detail ?? ""
            return .text(body.isEmpty ? material.name : body)
        case .link:
            guard let value = material.urlString, let url = URL(string: value) else {
                throw WorkMaterialExportError.bytesUnavailable
            }
            return .link(url)
        case .image, .file, .audio:
            // The ORIGINAL bytes, every lane. An image card shares the picture
            // the desk stores, never the bounded thumbnail its tile draws.
            return .file(try await WorkMaterialExportSnapshot.make(for: material, bytes: bytes))
        }
    }

    /// Whether a finished copy still describes the card the store holds.
    ///
    /// Four ways it can stop doing so, and each is a different card as far as
    /// the person is concerned: the card was deleted, its content was replaced
    /// (a new revision), its kind changed, or its bytes stopped being readable
    /// here. Card SIZE is revision-neutral by contract, so resizing during a
    /// share does not refuse it. Static and pure, so the rule is provable
    /// without running a copy.
    nonisolated static func acceptsPreparedShare(
        requested: WorkboardMaterialSnapshot,
        current: WorkboardMaterialSnapshot?
    ) -> Bool {
        guard let current, current.id == requested.id else { return false }
        guard current.revision == requested.revision, current.kind == requested.kind else {
            return false
        }
        return WorkboardCardActionPolicy.allows(.open, when: current.availability)
    }

    // MARK: - Copy

    static let preparingCopy = LocalizedStringResource(
        "workboard.material.share.preparing",
        defaultValue: "Preparing…"
    )

    static let failedTitle = LocalizedStringResource(
        "workboard.material.share.failed.title",
        defaultValue: "Couldn’t share this material"
    )

    /// The two unreadable states, each named for the verb the person asked for.
    /// `WorkMaterialExportError` carries no copy precisely so this sentence can
    /// say "share" where the preview lane's says "open".
    static func refusal(
        for availability: WorkboardMaterialAvailability
    ) -> WorkShareFailure {
        let message: LocalizedStringResource = availability == .syncPending
            ? LocalizedStringResource(
                "workboard.material.share.syncPending",
                defaultValue: "This material is still arriving from iCloud. It can be shared once it lands on this device."
            )
            : LocalizedStringResource(
                "workboard.material.share.unavailable",
                defaultValue: "This material is not available on this device. Reattach it here to share it."
            )
        return WorkShareFailure(title: failedTitle, message: String(localized: message))
    }

    static var stale: WorkShareFailure {
        WorkShareFailure(
            title: failedTitle,
            message: String(localized: LocalizedStringResource(
                "workboard.material.share.stale",
                defaultValue: "This card changed while it was being prepared, so nothing was shared."
            ))
        )
    }

    static var presentationUnavailable: WorkShareFailure {
        WorkShareFailure(
            title: failedTitle,
            message: String(localized: LocalizedStringResource(
                "workboard.material.share.noAnchor",
                defaultValue: "The share options couldn’t be opened from this window."
            ))
        )
    }

    /// Cause AND remedy for a typed failure; the system's own sentence for
    /// everything else. A file-system refusal has no `AppError` behind it, so
    /// the platform's message is the only description there is.
    static func message(for error: Error) -> String {
        (error as? AppError)?.descriptionWithRecovery() ?? error.localizedDescription
    }
}

// MARK: - The platform presenter

/// The system share UI on each platform, and nothing else. Split from the
/// coordinator so every decision above is testable against a stub.
@MainActor
final class WorkMaterialSharePresenter: NSObject, WorkSharePresenting {

    /// How long the surface is given to finish whatever transition it is in.
    /// Generous relative to a menu dismissal (~0.25 s) and finite, because a
    /// surface that never settles must fail rather than hang a share forever.
    static let settleLimit: Duration = .seconds(2)
    private static let settlePoll: Duration = .milliseconds(16)

    #if os(macOS)
    /// The live picker. RETAINED because `NSSharingServicePicker` is not held
    /// by the view it pops out of: a local one is released at the end of
    /// `present` and takes its own popover down with it. Released again when
    /// the delegate reports the choice, so the retain window is bounded.
    private var picker: NSSharingServicePicker?
    #endif

    override init() {
        super.init()
    }

    // MARK: Readiness

    func awaitPresentationReadiness(from anchor: SharePresentationAnchor) async -> Bool {
        #if os(iOS)
        let deadline = ContinuousClock.now.advanced(by: Self.settleLimit)
        while ContinuousClock.now < deadline {
            guard let view = anchor.presentationView, let window = view.window else { return false }
            if let host = Self.topmostViewController(from: window.rootViewController),
               Self.isSettled(host) {
                return true
            }
            try? await Task.sleep(for: Self.settlePoll)
        }
        return false
        #elseif os(macOS)
        // AppKit has no transition to wait out here: the context menu a Share
        // was chosen from is closed by the time the action runs, and a sharing
        // picker is a menu rather than a presented controller. What must be
        // true is that the anchor is in a window that can actually show one.
        guard let window = anchor.presentationView?.window, window.isVisible else { return false }
        return true
        #else
        return false
        #endif
    }

    #if os(iOS)
    /// Whether a controller can be asked to present right now.
    ///
    /// A Share tap comes out of a context menu that is STILL DISMISSING, and a
    /// note or a link is ready in the same runloop turn. Asking a controller
    /// mid-transition to present is refused by UIKit with a log line and
    /// nothing on screen — which, before this wait existed, was reported back
    /// as a successful hand-off.
    private static func isSettled(_ controller: UIViewController) -> Bool {
        !controller.isBeingDismissed
            && !controller.isBeingPresented
            && controller.transitionCoordinator == nil
            && controller.presentedViewController == nil
            && controller.view.window != nil
    }

    /// The controller actually on screen. Work's gallery is a sheet, so the
    /// root is frequently NOT the presenter — asking it to present would raise
    /// "already presenting" and show nothing.
    private static func topmostViewController(
        from root: UIViewController?
    ) -> UIViewController? {
        var candidate = root
        while let presented = candidate?.presentedViewController {
            candidate = presented
        }
        return candidate
    }
    #endif

    // MARK: Presentation

    func present(_ share: PreparedWorkShare, from anchor: SharePresentationAnchor) -> Bool {
        guard let view = anchor.presentationView, let window = view.window else { return false }
        #if os(iOS)
        guard let host = Self.topmostViewController(from: window.rootViewController),
              Self.isSettled(host) else { return false }
        let controller = UIActivityViewController(
            activityItems: share.activityItems,
            applicationActivities: nil
        )
        // The iPad arm, and half the reason this presenter exists: a
        // `UIActivityViewController` presented with no popover anchor TRAPS.
        // The anchor is therefore set unconditionally rather than behind an
        // idiom check — on iPhone the popover controller simply goes unused.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = anchor.presentationRect
            popover.permittedArrowDirections = []
        }
        host.present(controller, animated: true)
        // `present` links the two controllers SYNCHRONOUSLY when UIKit accepts
        // the request and leaves them unlinked when it refuses, so this is a
        // measurement rather than an assumption. It is deliberately the cheap
        // check and not "did the view reach a window": a false negative here
        // would reclaim bytes a live share sheet is reading.
        return host.presentedViewController === controller
        #elseif os(macOS)
        guard window.isVisible else { return false }
        let picker = NSSharingServicePicker(items: share.activityItems)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: anchor.presentationRect, of: view, preferredEdge: .maxY)
        // AppKit exposes no did-show callback for a service picker, so what is
        // confirmed here is everything AppKit requires to show one: an anchor
        // view inside a visible window. `show` on an anchor outside a window is
        // the one way this silently does nothing, and it is refused above.
        return true
        #else
        return false
        #endif
    }
}

#if os(macOS)
extension WorkMaterialSharePresenter: NSSharingServicePickerDelegate {
    /// The picker is done — the person chose a destination or dismissed it.
    /// Dropping the retain here bounds the picker's lifetime to its own
    /// presentation instead of to the next share.
    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.picker === sharingServicePicker else { return }
            self.picker = nil
        }
    }
}
#endif

#endif

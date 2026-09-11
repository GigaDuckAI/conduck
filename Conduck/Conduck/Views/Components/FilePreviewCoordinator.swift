// SPDX-License-Identifier: Apache-2.0

// Conduck
// FilePreviewCoordinator.swift
//
// ONE Quick Look presenter per surface — the chat thread and the Work desk each
// hold their own instance, and deliberately never one per row: macOS
// `QLPreviewPanel` is application-shared and responder-chain controlled, so
// row-local presenters inside a recycling `LazyVStack` would compete for it.
// Callers mint a claim at the moment of user intent and hand the finished file
// up on completion; the latest claim wins and a stale completion reclaims its
// own bytes.
//
// The coordinator knows nothing about WHERE a previewed file comes from: the
// caller hands over the URL together with the closure that reclaims it. Chat's
// downloads live in `AgentDownloadScratch`, Work's in a disposable preview
// copy, and neither lane's storage leaks into the presenter.

import Foundation
import Observation

/// A file on local disk, ready to show, paired with the closure that reclaims
/// its bytes.
///
/// The reclaim closure — not a URL the coordinator deletes itself — is what
/// keeps this type safe to hand any lane: each caller already knows the exact
/// unit it owns (a per-download scratch directory, a disposable copy), and a
/// coordinator that only ever calls back can never delete a parent it guessed
/// at by walking up from the file it was given.
struct PreviewedFile {
    let url: URL
    /// Release the bytes behind `url`. Called at most once per file, on the
    /// MainActor, and only when the platform's lifetime rule says the file is
    /// no longer live (see `FilePreviewReclaimPolicy`).
    let reclaim: @MainActor () -> Void
}

/// When a dismissed preview's bytes may be reclaimed.
///
/// This is a platform rule, not a preference, and it is a stored property
/// rather than a `#if` inside the coordinator so both halves of it stay
/// reachable from a test running on one platform.
enum FilePreviewReclaimPolicy {
    /// iOS: reclaim as soon as the preview goes away. The full-screen
    /// `QLPreviewController` is done with the file by then, and share /
    /// Save-to-Files copy the bytes out before dismissal.
    case onDismiss
    /// macOS: leave the file to the launch age-sweep. The panel's
    /// "Open with <app>" hands the target app the LIVE path, so deleting on
    /// dismissal would yank the file out from under the app the user just
    /// opened it in.
    case onAgeSweep

    static var platformDefault: FilePreviewReclaimPolicy {
        #if os(macOS)
        .onAgeSweep
        #else
        .onDismiss
        #endif
    }
}

@MainActor @Observable
final class FilePreviewCoordinator {
    /// Drives the host view's `.quickLookPreview` — the modifier nils it on
    /// user dismissal.
    var previewURL: URL?
    /// The file currently on screen (reclaimed per `reclaimPolicy`, see
    /// `handleDismiss`).
    private var currentFile: PreviewedFile?
    /// Monotonic claim counter — minted at tap time, checked at completion.
    private var latestToken: UInt64 = 0
    /// The lifetime rule this presenter follows. Injectable so a test can
    /// exercise both platforms' behaviour on whichever one it runs on.
    private let reclaimPolicy: FilePreviewReclaimPolicy

    init(reclaimPolicy: FilePreviewReclaimPolicy = .platformDefault) {
        self.reclaimPolicy = reclaimPolicy
    }

    /// Mint a presentation claim at the moment of user intent (chip tap /
    /// soft-confirm / card open), BEFORE the async load — completion order must
    /// not decide which file gets the panel.
    func beginRequest() -> UInt64 {
        latestToken &+= 1
        return latestToken
    }

    /// Whether asynchronous work still owns the most recent user-intent claim.
    /// Destination cleanup advances the counter, so late loads can reclaim
    /// their temp file without presenting UI over another top-level surface.
    func isCurrent(_ token: UInt64) -> Bool {
        token == latestToken
    }

    /// Present a prepared file — or, when a newer claim exists, discard it.
    func present(_ file: PreviewedFile, token: UInt64) {
        guard token == latestToken else {
            // A newer tap won while this load ran — reclaim quietly. Unlike
            // dismissal, this file was never shown, so no other app can hold
            // its path and the platform rule does not apply.
            file.reclaim()
            return
        }
        // Replacing an on-screen preview: under `.onDismiss` the old file is
        // safe to reclaim (the presenter is done with it once swapped).
        // `.onAgeSweep` leaves a replaced file alone — "Open with" may hold it.
        if reclaimPolicy == .onDismiss, let old = currentFile {
            old.reclaim()
        }
        currentFile = file
        previewURL = file.url
    }

    /// The user dismissed the preview (the modifier nil'd the binding).
    /// Reclaim only where the platform rule allows it.
    func handleDismiss() {
        if reclaimPolicy == .onDismiss, let file = currentFile {
            file.reclaim()
        }
        currentFile = nil
    }

    /// Cancel the visible preview and every in-flight claim. `present` will
    /// discard a file carrying an older token, while load routes check
    /// `isCurrent` before Quick Look or a save panel hand-off.
    func cancelPendingPresentation() {
        latestToken &+= 1
        if previewURL != nil { previewURL = nil }
        if currentFile != nil { handleDismiss() }
    }
}

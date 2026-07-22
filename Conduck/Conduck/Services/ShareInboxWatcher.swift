//
//  ShareInboxWatcher.swift
//  Conduck (macOS)
//
//  Wakes the (persistent, possibly INACTIVE) menu-bar app the instant the macOS
//  share appex publishes an envelope, so a share made while Conduck is in the
//  background drains + processes WITHOUT a menu-bar click.
//
//  WHY a file-system watch (and NOT a Darwin notification): Darwin notifications
//  are stateless, edge-triggered, coalescing, and delivered via the MAIN RUN
//  LOOP. An inactive menu-bar accessory app (no visible window) is a prime App
//  Nap target with no servicing run loop, so a posted Darwin wake is simply
//  DROPPED, not queued — observed empirically (the drain never fired on a
//  background share, even after the user later activated the app). A
//  `DispatchSource` vnode source instead watches the DURABLE on-disk publish
//  contract: the appex's atomic `moveItem` lands `Inbox/<uuid>/` as a direct
//  child of the inbox base, which modifies the inbox-dir vnode. The source fires
//  on a `DispatchQueue` — NOT the run loop, not App-Nap-gated — so nothing can be
//  silently lost. The launch + `applicationDidBecomeActive` drains remain as
//  fallbacks; the drainer is an actor, so a redundant fire is a cheap no-op.
//

#if os(macOS)
import Foundation
import os

/// Watches the App-Group share `Inbox/` directory and kicks `SharedInboxDrainer`
/// when the macOS appex publishes an envelope. macOS-only; owned strongly by
/// `AppDelegate` for the whole app lifetime (never stopped). See the file header
/// for why this replaces the earlier (unreliable) Darwin-notification wake.
final class ShareInboxWatcher {
    /// The directory whose vnode we watch — the SAME inbox base the drainer
    /// claims from (single source of truth, never hardcode the path twice).
    private let inboxBase: URL
    /// All state (`fd`, `source`, `drainScheduled`) is touched ONLY on this queue.
    private let queue = DispatchQueue(label: Constants.identityNamespace + ".share-inbox-watch")
    private var fd: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    /// Debounce flag: collapse a publish burst (tmp-subdir churn + the rename into
    /// the inbox dir) into ONE drain. Guarded on `queue`.
    private var drainScheduled = false

    init(inboxBase: URL = SharedInboxDrainer.productionInboxBase) {
        self.inboxBase = inboxBase
    }

    /// Begin watching. Call once at launch. Creates the inbox dir first so `open`
    /// succeeds before the first share ever arrives, then arms the vnode source.
    func start() {
        queue.async { [weak self] in self?.arm() }
    }

    // MARK: - Private (all on `queue`)

    private func arm() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: inboxBase, withIntermediateDirectories: true)
        let openedFd = open(inboxBase.path, O_EVTONLY)
        guard openedFd >= 0 else {
            #if DEBUG
            RemoteAgentDiagnostics.log.error("shareWatch: open failed for inbox dir")
            #endif
            return
        }
        fd = openedFd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: openedFd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            self.handle(current.data)
        }
        src.setCancelHandler { close(openedFd) }
        source = src
        src.resume()
        // Cold-start race: drain anything already published before the watch armed.
        scheduleDrain()
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        // The watched dir ITSELF vanishing (deleted/renamed/revoked) invalidates
        // the fd — re-arm so a recreated scaffold is still observed. (The drainer
        // never deletes the inbox base; this is defence-in-depth.) A child moving
        // in/out of the inbox is a `.write`, handled by the normal drain path.
        if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
            source?.cancel()
            source = nil
            fd = -1
            arm()
            return
        }
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            #if DEBUG
            RemoteAgentDiagnostics.log.log("shareWatch: fired")
            #endif
            Task { await SharedInboxDrainer.shared.drain(trigger: .shareWake) }
        }
    }
}
#endif

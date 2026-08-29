// SPDX-License-Identifier: Apache-2.0

// Conduck
// ShareTargetsSnapshotWriter.swift
//
// Share-Extension "Send to" picker — the MAIN-APP WRITER that REGENERATES the
// App-Group `share-targets.json` the appex reads to fill its picker. The appex
// can't reach the live store / palette enum / `RemoteAgentRef`, so every render
// value (display name, badge color "#RRGGBB", monogram) is RESOLVED here and
// frozen into the flat `ShareTargetsSnapshot` contract.
//
// WRITE LOCATION (load-bearing): `<AppGroup>/Application Support/share-targets.json`
// — the appex reads the SAME literal path. The write is ATOMIC (sibling temp +
// rename within the same dir) so the appex never decodes a half-written file.
//
// CONSUMERS: the iOS Share Extension AND the native macOS Share Extension both
// read this snapshot to fill their pickers. The recent-conversations population
// calls `ConversationStore.fetchRecentForPicker(limit:)`, gated
// `#if os(iOS) || os(macOS)` (its `CarPlayConversationLabel.derive` dep is in
// both builds). On watchOS there is no share sheet → the whole writer is a NO-OP
// (gated below), keeping the Watch build compiling without the picker read.
//
// BEST-EFFORT: every failure (encode / disk) LOGS and returns — `regenerate()`
// never throws to its callers (the trigger hooks fire on hot paths).

import Foundation
import SwiftUI

/// Builds + atomically writes the App-Group `share-targets.json` the appex
/// picker reads. An `actor`, but actor isolation alone does NOT serialize
/// concurrent triggers (`.conversationsDidChange` + `.settingsDidChangeRemotely`
/// firing near-simultaneously): actors are REENTRANT across `await`, and
/// `regenerate()` suspends. It therefore coalesces explicitly — one build in
/// flight plus one trailing build — which both bounds the store reads a burst
/// can start and stops an older build committing over a newer one.
actor ShareTargetsSnapshotWriter {

    /// Production singleton — writes into the App-Group `Application Support`
    /// container, reads the shared store + settings singletons.
    static let shared = ShareTargetsSnapshotWriter()

    /// The snapshot file name under `Application Support` (the appex reads the
    /// SAME literal). Single-sourced so writer (here) + reader (appex) never drift.
    /// `Constants.shareTargetsSnapshotFileName` is the cross-process literal.
    private let store: ConversationStore
    private let settings: SettingsManager

    private init() {
        self.store = .shared
        self.settings = .shared
    }

    /// Test seam — inject the store/settings (so a unit test never touches the
    /// App-Group sqlite / Keychain).
    init(store: ConversationStore, settings: SettingsManager) {
        self.store = store
        self.settings = settings
    }

    #if os(iOS) || os(macOS)
    /// Single-flight state for `regenerate()`. Actor isolation alone does NOT
    /// serialize it: actors are REENTRANT across `await`, and `buildSnapshot()`
    /// suspends, so a second caller walks in while the first is mid-build.
    private var isRegenerating = false
    private var regenerationPending = false
    #endif

    /// Regenerate the snapshot and atomically write it (iOS + macOS — both have a
    /// share extension that reads it). On watchOS this is a NO-OP (no share sheet
    /// → the snapshot is never read). Best-effort: any failure logs + returns,
    /// never throws.
    ///
    /// COALESCED: at most one build in flight, plus at most one trailing build
    /// for notifications that land during it. The observer fires this on every
    /// `.conversationsDidChange` from any store, so without the latch a burst
    /// opened one concurrent build per post — each taking a fresh background
    /// context, each parking a dispatch worker on a synchronous Core Data
    /// coordinator hop while faulting relationships. At 512 parked workers
    /// libdispatch can schedule nothing ever again and the process wedges.
    /// The trailing pass is what keeps coalescing honest: dropping posts during
    /// a build would leave the snapshot stale. Single-flight also fixes an
    /// ordering bug — concurrent builds could `write()` an OLDER snapshot after
    /// a newer one.
    ///
    /// The flag is claimed BEFORE the first suspension, and nothing suspends
    /// between the final `regenerationPending` read and clearing it — that gap
    /// is exactly where reentrancy would slip through and un-bound the fan-out.
    func regenerate() async {
        #if os(iOS) || os(macOS)
        if isRegenerating {
            regenerationPending = true
            return
        }
        isRegenerating = true
        // `defer` rather than a trailing assignment: today nothing in the loop
        // can exit early, but one future `guard`/`try` would strand the flag set
        // forever, and every later call would then return at the check above —
        // the appex's `share-targets.json` frozen for the process lifetime, with
        // no error anywhere. Structural beats a comment.
        defer { isRegenerating = false }
        repeat {
            regenerationPending = false
            let snapshot = await buildSnapshot()
            write(snapshot)
        } while regenerationPending
        #endif
        // watchOS: intentional no-op (the wrist has no share sheet; the snapshot
        // is consumed by the iOS + macOS share extensions only).
    }

    #if os(iOS) || os(macOS)

    // MARK: - Build

    /// Assemble the flat snapshot from the live store + settings:
    ///   - gateways: every CONFIGURED ref (URL+token) → ref / displayName /
    ///     colorHex / monogram / configured=true, all pre-resolved here.
    ///   - recentConversations: the most-recent conversations (cap 12) → the flat
    ///     RecentConversation (id / label / backendRef / lastActivityAt).
    private func buildSnapshot() async -> ShareTargetsSnapshot {
        // One customs roster read drives both the metadata + palette resolution
        // (built-in refs ignore it; customs key on it).
        let customs = await settings.customGateways()
        let configuredRefs = await settings.configuredRemoteAgentRefs()

        let gateways: [ShareTargetsSnapshot.Gateway] = configuredRefs.map { ref in
            let color = RemoteAgentBadgePalette.color(for: ref, customs: customs)
            return ShareTargetsSnapshot.Gateway(
                ref: ref.rawString,
                displayName: RemoteAgentRefMetadata.displayName(for: ref, customs: customs),
                colorHex: Self.hexString(from: color),
                monogram: RemoteAgentRefMetadata.monogram(for: ref, customs: customs),
                // `configuredRemoteAgentRefs()` only returns refs with BOTH a URL
                // and a token, so every entry here is by-definition configured.
                configured: true
            )
        }

        // The set of still-configured gateway rawStrings. A recent conversation
        // bound to a gateway the user has since DELETED / un-configured would route
        // through precedence #1 (route by the row's backend) → throw → guaranteed
        // share failure. Presenting such a recent in the picker offers a target
        // that ALWAYS fails, so drop them here (the appex only ever sees appendable
        // recents). Customs deleted from the roster also drop out of
        // `configuredRemoteAgentRefs()`, so they're filtered the same way.
        let configuredRefStrings = Set(configuredRefs.map { $0.rawString })

        let recents = (try? await store.fetchRecentForPicker(limit: 12)) ?? []
        let recentConversations = Self.filterRecents(recents, configuredRefStrings: configuredRefStrings)

        return ShareTargetsSnapshot(
            schemaVersion: 1,
            generatedAt: Date(),
            gateways: gateways,
            recentConversations: recentConversations
        )
    }

    /// PURE filter+map: keep only recents whose bound `backend` is still in
    /// `configuredRefStrings` (a configured gateway's `rawString`), and flatten to
    /// the snapshot's `RecentConversation`. A recent bound to a deleted /
    /// unconfigured gateway is DROPPED (it would route → throw → share failure — a
    /// dead picker target). Extracted as a static pure func so the filter is
    /// unit-testable headless (no store / Keychain / signing).
    static func filterRecents(
        _ recents: [ConversationStore.RecentConversation],
        configuredRefStrings: Set<String>
    ) -> [ShareTargetsSnapshot.RecentConversation] {
        recents
            .filter { configuredRefStrings.contains($0.backend) }
            .map { recent in
                ShareTargetsSnapshot.RecentConversation(
                    id: recent.id,
                    label: recent.label,
                    backendRef: recent.backend,
                    lastActivityAt: recent.lastActivityAt
                )
            }
    }

    // MARK: - Atomic write

    /// Encode via the pinned `encoded()` contract + write atomically: write a
    /// sibling `.tmp` in the SAME dir, then `replaceItemAt` / rename onto the
    /// canonical name (an atomic same-volume swap — the appex never sees a
    /// partial file). Creates `Application Support` if absent. Best-effort.
    private func write(_ snapshot: ShareTargetsSnapshot) {
        guard let supportDir = Self.applicationSupportDir() else {
            NSLog("[ShareTargetsSnapshotWriter] App Group container URL is nil for \(Constants.appGroupID); skipping snapshot write.")
            return
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        } catch {
            // Domain/code only — a Cocoa file error's description can embed
            // container paths; never log content-derived strings.
            NSLog("[ShareTargetsSnapshotWriter] Failed to create Application Support dir: \((error as NSError).domain) code \((error as NSError).code)")
            return
        }

        let destination = supportDir.appendingPathComponent(Constants.shareTargetsSnapshotFileName)
        let temp = supportDir.appendingPathComponent(Constants.shareTargetsSnapshotFileName + ".tmp")

        let data: Data
        do {
            data = try snapshot.encoded()
        } catch {
            NSLog("[ShareTargetsSnapshotWriter] Failed to encode snapshot: \((error as NSError).domain) code \((error as NSError).code)")
            return
        }

        do {
            // Write the temp sibling first (overwrites any leftover temp from a
            // crashed prior write). AfterFirstUnlock protection: the snapshot
            // carries conversation-label-derived strings, but the writer can
            // run from a background CloudKit-push regenerate while the device
            // is locked — `.complete` would fail there; the appex only reads
            // it from an (unlocked) share-sheet invocation.
            try data.write(to: temp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // Swap into place. `replaceItemAt` requires the destination to exist;
            // the first-ever write (no destination) falls back to a plain rename.
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            NSLog("[ShareTargetsSnapshotWriter] Failed to write snapshot: \((error as NSError).domain) code \((error as NSError).code)")
            try? fm.removeItem(at: temp)
        }
    }

    /// `<AppGroup>/Application Support` (the snapshot's home dir). Nil when the
    /// App Group container is unavailable (mis-provisioned entitlement) — the
    /// caller logs + skips rather than falling back to a per-process dir the
    /// appex can't read.
    private static func applicationSupportDir() -> URL? {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupID
        ) else {
            return nil
        }
        return groupURL.appendingPathComponent("Application Support", isDirectory: true)
    }

    #endif

    // MARK: - Color → hex

    /// Resolve a SwiftUI `Color` to a `"#RRGGBB"` string for the appex (which
    /// can't reach the palette enum). Bridges through the platform color
    /// (`UIColor`/`NSColor`) → `cgColor` RGBA components, clamped to 0–255. A
    /// resolution failure falls back to neutral gray `"#808080"` (a legible
    /// badge, never a crash). Defined unconditionally (no `#if os(iOS)`) so the
    /// macOS build + the headless unit test both compile it.
    static func hexString(from color: Color) -> String {
        #if canImport(UIKit)
        let platformColor = UIColor(color)
        #elseif canImport(AppKit)
        // `usingColorSpace(.sRGB)` so a catalog/system color resolves to concrete
        // RGBA components (a named NSColor has no direct components otherwise).
        let platformColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        #endif

        guard let components = platformColor.cgColor.components, components.count >= 3 else {
            return "#808080"
        }
        let r = clampChannel(components[0])
        let g = clampChannel(components[1])
        let b = clampChannel(components[2])
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Clamp a 0…1 CGFloat channel to an Int 0…255 (defensive against a wide-
    /// gamut component slightly outside [0,1]).
    private static func clampChannel(_ value: CGFloat) -> Int {
        let scaled = Int((value * 255).rounded())
        return min(255, max(0, scaled))
    }
}

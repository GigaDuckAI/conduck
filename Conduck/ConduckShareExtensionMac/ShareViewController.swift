// Conduck
// ShareViewController.swift  (ConduckShareExtensionMac appex — macOS principal)
//
// AppKit principal class for the macOS Share Extension — the macOS sibling of the
// iOS `ConduckShareExtension/ShareViewController.swift`. Apple gives Share
// Extensions no SwiftUI principal, so on macOS the principal is an
// `NSViewController` that hosts `NSHostingController(rootView: ShareView(...))`
// (the AppKit analogue of the iOS `UIHostingController` pattern).
// `NSExtensionPrincipalClass` in Info.plist points here.
//
// ── Shared contract (DO NOT drift) ────────────────────────────────────────────
// Identical to the iOS appex: a thin CAPTURE-AND-QUEUE stage that does ZERO
// decoding/processing. It copies each shared item's bytes into an App-Group inbox
// + writes `manifest.json`, then exits. The MAIN-APP `SharedInboxDrainer` actor
// consumes these envelopes on `applicationDidBecomeActive` / notification-tap and
// runs the real pipeline (`ImageProcessor` / `TextFileExtractor` / file-server
// upload → `appendMessage` → `BackgroundRemoteAgent.send`). `SharedInboxManifest`
// + the on-disk inbox layout below ARE the cross-process contract — change them
// only in lockstep with the drainer.
//
// ── App-Group inbox layout (App-Group `Application Support/Inbox/`) ────────────
//   Inbox/tmp/<uuid>/att-<seq>.<ext>   ← appex writes here first (in-progress)
//   Inbox/tmp/<uuid>/manifest.json
//   Inbox/<uuid>/…                     ← ONE same-volume atomic rename publishes
//   Inbox/processing/<uuid>/           ← drainer claims (we never touch)
//   Inbox/failed/<uuid>/               ← quarantine (we never touch)
// The drainer's enumeration SKIPS `tmp/`, `processing/`, `failed/`. Single-writer
// + atomic-rename — NO `NSFileCoordinator`. The appex writes ONLY under
// `tmp/<uuid>/`, then renames; only the drainer moves published dirs.
//
// ── Critical race (Apple deletes provider temp files on callback return) ───────
// `loadFileRepresentation`/`loadItem` hand back a temp URL that Apple deletes
// the instant the completion handler returns. We therefore COPY the bytes into
// `tmp/<uuid>/` INSIDE the handler, synchronously, before returning. See
// `copyFileRepresentation(...)`.
//
// ── macOS `file://` divergence from iOS (the only behavioral difference) ───────
// Finder / Preview / Quick Look frequently share a document as a security-scoped
// `public.file-url` rather than a file REPRESENTATION. The iOS appex REJECTS
// file:// URLs (on iOS a security-scoped URL dies with the appex and durable
// files always arrive as representations). On macOS, dropping these would make
// the most common Finder share (a selected PDF / .txt / image) silently vanish.
// So in the macOS `loadOne`, a file:// URL is COPIED synchronously inside the
// security-scoped access window into `tmp/att-<seq>.<ext>`, producing a
// `SharedInboxManifestItem` of the SAME shape the drainer already consumes — no
// drainer change. `http(s)` URLs still go to `urls[]` exactly as on iOS.
//
// ── Safari page-text capture (NSExtensionJavaScriptPreprocessingFile) ─────────
// Shared FROM Safari, `ConduckWebCapture.js` runs inside the page and Safari
// vends its results as a `com.apple.property-list` NSItemProvider carrying
// `NSExtensionJavaScriptPreprocessingResultsKey` — REPLACING the `public.url`
// provider (iOS-verified; assumed identical on macOS). A single memoized load
// (`capturePayloadTask`, started in `viewDidLoad`) finds that provider and, when
// the JS-results key is PRESENT, builds a `CaptureLoad` carrying the provider's
// `ObjectIdentifier` + the page URL UNCONDITIONALLY, plus an OPTIONAL parsed
// `WebPageCapture.Payload` (non-nil only when the page had usable text). The
// preview surface hides ANY property-list-conforming provider EAGERLY
// (`visibleProviders`, conformance only, no load) so no "property list" flash
// shows; when there is no visible provider the header is synthesized from the
// capture load (page title/host + a "Web page" type). The envelope-writing loop
// skips ONLY the provider whose identity matches the `CaptureLoad`, and the page
// URL joins `urls[]` toggle-independently (gated by `WebPageCapture.shouldAppend`)
// — both driven by the always-present identity/URL, so a failed text parse still
// skips the bridge plist and keeps the URL. When the toggle is ON AND a payload
// parsed, a synthetic `att-<seq>.md` (`WebPageCapture.markdown`) rides as a
// `sourceKind == "webpage"` attachment. A genuine `.plist` FILE (JS-results key
// ABSENT) yields no `CaptureLoad` — byte-identical to today: no toggle, unchanged
// envelope, the plist rides as an ordinary file.
//
// ── Preview header (Telegram redesign — name/type/icon, NO full-byte reads) ────
// `ShareView` shows a pinned header row for the shared item. Two seams feed it:
//   • `buildPreviewItems()` — IMMEDIATE, byte-free type tags for the glyph. Order
//     matters on macOS: a Finder file:// conforms to BOTH `public.file-url` AND
//     `public.url`, so we test `UTType.fileURL` BEFORE `UTType.url` (else a doc
//     reads as a web link → no icon). A genuine web link doesn't conform to
//     file-url, so it still lands on `.url`.
//   • `resolveLeadHeader()` — ASYNC, rich `ResolvedHeader` for the lead provider:
//     a localized type description + an OS icon. Documents → `NSWorkspace.icon(for:
//     utType)` (type→icon, sandbox-safe, no byte read). Images → a 128px ImageIO
//     thumbnail (`CGImageSourceCreateThumbnailAtIndex`, decode-on-demand) built
//     SYNCHRONOUSLY inside the file-representation handler before Apple reaps the
//     temp URL — NEVER `NSImage(contentsOf:)` (full decode → blows the 120 MB cap).
//     Web URLs / plain text carry no icon (no network; the view keeps the glyph).

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import os

// SHARED CONTRACT TYPE: `SharedInboxManifest` / `SharedInboxManifestItem` are
// provided to THIS appex by `ConduckShareExtensionMac/SharedInboxManifest.swift` —
// a VERBATIM MIRROR of the main-app `Conduck/Models/SharedInboxManifest.swift`
// (kept byte-identical below the header to the iOS mirror + the canonical). The
// appex and the main app are SEPARATE compilation modules, so the contract is
// carried as one source file per module rather than shared via cross-target
// membership. Drift guard: `ConduckTests/SharedInboxManifestTests`.

/// Build identity for THIS appex, read from its OWN Info.plist keys
/// (`ConduckIdentityNamespace` / `ConduckAppGroupID`, fed by the xcconfig
/// identity layer — same contract as the main app's `Constants`, which this
/// appex cannot import). Official values: namespace `ai.gigaduck.agentrelay`,
/// App Group `group.ai.gigaduck.agentrelay`. The fallbacks are safety nets for
/// non-hosted contexts, never the design path.
fileprivate enum ShareExtensionIdentity {
    static let namespace =
        Bundle.main.object(forInfoDictionaryKey: "ConduckIdentityNamespace") as? String
            ?? (Bundle.main.bundleIdentifier?.lowercased() ?? "conduck.community")

    static let appGroupID =
        Bundle.main.object(forInfoDictionaryKey: "ConduckAppGroupID") as? String
            ?? "group.\(namespace)"

    /// os.Logger subsystem AND NSError domain for this appex — namespace +
    /// frozen `.share` suffix.
    static let shareSubsystem = namespace + ".share"
}

final class ShareViewController: NSViewController {

    private let log = Logger(subsystem: ShareExtensionIdentity.shareSubsystem, category: "ShareViewControllerMac")

    /// App-Group identifier (matches the main app's `Constants.appGroupID` and
    /// the App-Group entitlement entries; the appex's own entitlements mirror it).
    private static let appGroupID = ShareExtensionIdentity.appGroupID

    /// Per-attachment cap — defence-in-depth alongside the Info.plist activation
    /// rule's per-type `…WithMaxCount = 10`. A malformed share that slips the
    /// rule is still bounded here.
    private static let maxAttachments = 10

    /// A Safari capture carrier's load: the source property-list provider's
    /// IDENTITY, the page URL, and the parsed text payload. `providerID` + `url`
    /// are set whenever the provider carries `NSExtensionJavaScriptPreprocessingResultsKey`
    /// (i.e. it IS a Safari bridge) — decoupled from parse success, so the envelope
    /// loop can skip the bridge provider (never leak the raw plist as a file) and
    /// recover the page URL EVEN WHEN the text parse yields nothing (an empty /
    /// hostile page). `payload` is non-nil only when `WebPageCapture.parse`
    /// succeeded; it alone gates the synthetic markdown attachment. `ObjectIdentifier`
    /// + the Sendable `Payload?` let the whole value cross `commit`'s detached task
    /// WITHOUT holding a non-Sendable `NSItemProvider` (structural parity with the
    /// iOS appex).
    ///
    /// `providerID` is nil ONLY for the macOS SELECTION-share fallback
    /// (`selectionFallbackCapture`): Safari vends a text selection with ZERO
    /// attachments, so there is no carrier provider to skip — the envelope
    /// loop's identity check simply never matches. (Deliberate divergence from
    /// the iOS appex, where Safari always vends the property-list provider.)
    private struct CaptureLoad: Sendable {
        let providerID: ObjectIdentifier?
        let url: String
        let payload: WebPageCapture.Payload?
    }

    /// Memoized Safari page-text capture load — started once in `viewDidLoad`,
    /// awaited by BOTH the toggle row (`resolveCapture`) and `commit`, so the
    /// `com.apple.property-list` item loads exactly once. A nil result = NOT a
    /// Safari share (no property-list provider AND no attachment-less selection
    /// text — see `selectionFallbackCapture` — or a genuine `.plist` FILE with no
    /// JS-results key) → the whole capture path stays inert.
    private var capturePayloadTask: Task<CaptureLoad?, Never>?

    // MARK: - Lifecycle

    /// macOS `NSViewController` has no implicit root view (unlike UIKit), so we
    /// must provide one before `viewDidLoad`.
    override func loadView() {
        self.view = NSView()
        // Fixed panel size — the macOS share panel does not auto-size to its
        // hosted content the way the iOS sheet does.
        self.view.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Load the tiny "Send to" snapshot the main app published (gateways +
        // recent conversations). Missing / malformed → nil, and `ShareView` shows
        // the single legacy fallback row (the share never dead-ends). The picker is
        // always the surface; the manifest's `shouldAutosend` is stamped `true` at
        // commit time so the picked target always sends (share-and-go).
        let rootView = ShareView(
            attachmentCount: extractedAttachmentCount(),
            previewItems: buildPreviewItems(),
            snapshot: loadShareTargetsSnapshot(),
            resolveLeadHeader: { [weak self] in await self?.resolveLeadHeader() ?? nil },
            resolveCapture: { [weak self] in await self?.capturePayloadTask?.value?.payload },
            onSend: { [weak self] caption, target, includePageText in
                self?.commit(caption: caption, target: target, includePageText: includePageText)
            },
            onCancel: { [weak self] in self?.cancel() }
        )

        let host = NSHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // The app is dark-mode only; `ShareView` already applies
        // `.preferredColorScheme(.dark)`. There is no AppKit
        // `overrideUserInterfaceStyle`; force the dark appearance on the panel so
        // any AppKit chrome around the hosted SwiftUI also renders dark.
        view.appearance = NSAppearance(named: .darkAqua)

        // The macOS panel does not auto-size to the hosted content; pin a sensible
        // size so the picker has room.
        preferredContentSize = NSSize(width: 480, height: 600)

        // Start the memoized Safari page-text capture load ONCE. A single shared
        // load feeds both the toggle row (via `resolveCapture`) and the commit
        // path (via `capturePayloadTask.value`), so the JS-results property-list
        // provider is loaded at most once. Resolves to nil for every non-Safari
        // share (no property-list provider) and for a genuine `.plist` FILE with
        // no JS-results key.
        capturePayloadTask = Task { [weak self] in await self?.loadCapturePayload() ?? nil }
    }

    // MARK: - Safari page-text capture

    /// Locate the Safari page-text capture carrier, if any. Safari vends its
    /// `ConduckWebCapture.js` results as the FIRST `com.apple.property-list`
    /// provider carrying `NSExtensionJavaScriptPreprocessingResultsKey`. The
    /// PRESENCE of that key identifies a Safari bridge — so we set the provider
    /// IDENTITY + the page URL from it UNCONDITIONALLY, decoupled from whether the
    /// text parse succeeds: the envelope loop must still skip the bridge provider
    /// (never leak the raw plist as a file) and recover the page URL even for an
    /// empty / hostile page. `WebPageCapture.parse` (UNTRUSTED input) then fills
    /// `payload` only when there is usable text — that alone gates the synthetic
    /// markdown attachment. A genuine `.plist` FILE share (results key ABSENT)
    /// returns nil and falls through the envelope loop as an ordinary file. The
    /// results unwrap + parse run INSIDE the load callback so only the Sendable
    /// `CaptureLoad?` crosses the continuation (never the `Any`-typed dictionary,
    /// which isn't Sendable).
    @MainActor
    private func loadCapturePayload() async -> CaptureLoad? {
        guard let provider = rawProviders.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }) else { return selectionFallbackCapture() }
        let providerID = ObjectIdentifier(provider)

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
                // Results key ABSENT → genuine `.plist` FILE (no Safari bridge) →
                // nil; the provider falls through as an ordinary file attachment.
                guard let results = (item as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey]
                    as? [AnyHashable: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                // PRESENT → a Safari bridge: keep identity + page URL regardless of
                // the text parse (nil for an empty / hostile page).
                continuation.resume(returning: CaptureLoad(
                    providerID: providerID,
                    url: (results["url"] as? String) ?? "",
                    payload: WebPageCapture.parse(results)
                ))
            }
        }
    }

    /// macOS Safari SELECTION share: unlike a page share (JS bridge → property-list
    /// provider) and unlike iOS (where the in-page JS `getSelection()` covers
    /// selections), sharing a text SELECTION on macOS skips the JS preprocessing
    /// entirely — the selection travels ONLY in
    /// `NSExtensionItem.attributedContentText`, with the attachments either EMPTY
    /// (private-browsing window) or a single `public.url` for the page (normal
    /// window). Both shapes spike-verified: `providers=0` / `providers=1
    /// utis=[public.url], contentTextLen=<selection>`. Synthesize a
    /// selection-scope capture from the side-channel text so the toggle row +
    /// synthetic markdown ride the exact same pipeline as a page capture; a URL
    /// attachment still rides the normal envelope loop (link + selection, like
    /// an iOS selection share). The dict goes through `WebPageCapture.parse` —
    /// the ONE untrusted-input entry point — so clamping / whitespace-empty
    /// rejection stay uniform and the mirrored `WebPageCapture` file needs no
    /// new API.
    ///
    /// Hijack guards, in order:
    /// - attachments must be web links only (zero, or all `public.url` that are
    ///   NOT `public.file-url`) — a file / image / plain-text provider means a
    ///   real attachment share whose side-channel text is at most a caption;
    ///   those ride the provider ladder byte-for-byte as before.
    /// - the side-channel text must not be a bare URL echo — link-only shares
    ///   from other browsers put the URL string there; that's a link share,
    ///   not a selection.
    @MainActor
    private func selectionFallbackCapture() -> CaptureLoad? {
        guard rawProviders.allSatisfy({
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return nil }
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let text = items
            .compactMap { $0.attributedContentText?.string }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains(where: { $0.isWhitespace }),
           let echo = URL(string: text),
           echo.scheme?.lowercased() == "http" || echo.scheme?.lowercased() == "https" {
            return nil
        }
        let title = items.compactMap { $0.attributedTitle?.string }.first ?? ""
        guard let payload = WebPageCapture.parse([
            "title": title,
            "url": "",
            "selection": text,
            "pageText": "",
            "originalByteCount": text.utf8.count,
            "truncated": false,
            "scope": "selection",
        ]) else { return nil }
        return CaptureLoad(providerID: nil, url: "", payload: payload)
    }

    // MARK: - Input inspection (cheap, for the preview only)

    /// All attachments across all input items (bounded by `maxAttachments`) — the
    /// ENVELOPE-writing surface (the copy loop walks this, minus the confirmed
    /// capture provider).
    private var rawProviders: [NSItemProvider] {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        return Array(providers.prefix(Self.maxAttachments))
    }

    /// The PREVIEW surface (count / glyphs / lead header) — `rawProviders` minus
    /// any `com.apple.property-list`-conforming provider. A Safari share vends its
    /// capture as the ONLY provider (a property list), so excluding it EAGERLY by
    /// conformance (no load → no one-frame "property list" flash) keeps the preview
    /// showing the real user-shared attachments. A genuine `.plist` FILE share is
    /// edge-rare and acceptably hidden from preview (it still rides the envelope
    /// untouched).
    private var visibleProviders: [NSItemProvider] {
        rawProviders.filter {
            !$0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }
    }

    private func extractedAttachmentCount() -> Int { visibleProviders.count }

    /// Lightweight preview descriptors for `ShareView` — derived from the
    /// providers' registered type identifiers + suggested names, WITHOUT loading
    /// any bytes (loading a large image here would blow the appex memory cap).
    ///
    /// Classification order is LOAD-BEARING on macOS: a Finder `file://` share
    /// conforms to BOTH `public.file-url` AND `public.url`, so we MUST test
    /// `UTType.fileURL` BEFORE `UTType.url` — otherwise a dropped/selected PDF or
    /// document would be mis-tagged as a web `.url` (the "Finder doc shows the link
    /// glyph / no icon" bug). A genuine web link is a `public.url` that does NOT
    /// conform to `public.file-url`, so it still lands on `.url`. Image detection
    /// stays first (an image provider may also vend a file-url representation, but
    /// it's an image to the user).
    private func buildPreviewItems() -> [ShareView.PreviewItem] {
        visibleProviders.map { provider in
            let name = provider.suggestedName
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return .image(name: name)
            }
            // file:// BEFORE web url (a Finder file conforms to public.url too).
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                return .file(name: name)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                return .url
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                return .text
            }
            return .file(name: name)
        }
    }

    // MARK: - Rich header resolution (name / type / icon — NO full-byte reads)

    /// Resolve the rich header for the LEAD provider (`visibleProviders.first`) —
    /// the filename/title, a localized type description, and an OS-supplied icon or
    /// a MEMORY-BOUNDED image thumbnail — WITHOUT reading the full bytes (a full
    /// HEIC load would blow the 120 MB appex cap). Always returns a value on a
    /// non-empty lead provider (icon may be nil → the view keeps its typed glyph).
    /// With NO visible lead provider it falls back to `synthesizedCaptureHeader()`:
    /// a Safari share's only provider is the filtered-out property-list carrier, so
    /// the header is built from the memoized capture load (page title/host + a
    /// "Web page" type + a safari glyph). Returns nil only when there is neither a
    /// visible provider NOR a capture load. Runs on the main actor (UI-facing); the
    /// underlying loaders hop to a continuation and back. NEVER throws into the UI.
    @MainActor
    private func resolveLeadHeader() async -> ResolvedHeader? {
        guard let provider = visibleProviders.first else {
            // No user-visible attachment: a Safari share's ONLY provider is the
            // property-list capture carrier, filtered out of `visibleProviders`.
            // Synthesize the header from the memoized capture load so the pinned
            // header names the page instead of the generic fallback.
            return await synthesizedCaptureHeader()
        }

        // 1) IMAGE — a bounded ImageIO thumbnail (NEVER NSImage(contentsOf:), which
        // decodes the full image). Tested first so an image that ALSO vends a
        // file-url representation reads as an image.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await resolveImageHeader(provider)
        }

        // 2) file:// document — type→icon (sandbox-safe) + localized type desc.
        // BEFORE the web-url branch (a Finder file conforms to public.url too).
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let header = await resolveFileURLHeader(provider) { return header }
        }

        // 3) WEB url — host as the title + a plain "Link" subtitle (no network in
        // the appex, so no page-title fetch); no icon. Subtitle is NOT the host
        // again (that read as the host twice).
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await loadURL(provider), !url.isFileURL {
                let host = url.host ?? url.absoluteString
                return ResolvedHeader(
                    filename: host,
                    typeDescription: String(localized: "share.item.link",
                                            defaultValue: "Link",
                                            comment: "Subtitle shown for a shared web link"),
                    icon: nil
                )
            }
        }

        // 4) PLAIN text — a short leading snippet; no icon.
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await loadText(provider) {
                let snippet = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                return ResolvedHeader(
                    filename: snippet.isEmpty ? (provider.suggestedName ?? "") : snippet,
                    typeDescription: nil,
                    icon: nil
                )
            }
        }

        // Fallback: a minimal name-only header (the suggested name, else generic).
        return ResolvedHeader(filename: provider.suggestedName ?? "", typeDescription: nil, icon: nil)
    }

    /// Synthesize the pinned header for a Safari capture that has NO user-visible
    /// attachment (`visibleProviders` empty — its only provider is the filtered-out
    /// property-list carrier). Reads the memoized capture load: the primary line is
    /// the parsed page title (non-empty), else the URL host, else empty (the view
    /// then shows its generic fallback label). Type description is a localized
    /// "Web page"; the icon is an amber `safari` glyph. Returns nil when there is no
    /// capture load at all (not a Safari share) — a present visible lead provider is
    /// already handled by the caller. Works for a PARSED page and a URL-only capture.
    @MainActor
    private func synthesizedCaptureHeader() async -> ResolvedHeader? {
        guard let load = await capturePayloadTask?.value else { return nil }
        let primary: String
        if let payload = load.payload, !payload.title.isEmpty {
            primary = payload.title
        } else if let host = URL(string: load.url)?.host {
            primary = host
        } else {
            primary = ""
        }
        return ResolvedHeader(
            filename: primary,
            typeDescription: String(localized: "share.capture.webpage",
                                    defaultValue: "Web page",
                                    comment: "Header type description for a captured Safari web page"),
            icon: Self.webPageGlyph()
        )
    }

    /// The `safari` glyph for a synthesized web-page header, baked as a
    /// palette-colored symbol (NOT a bare template image) so it renders visibly on
    /// the dark header card regardless of SwiftUI's `Image(nsImage:)` template
    /// handling. The amber matches `ShareView.Palette.amber` (the appex can't import
    /// the palette; the literal is duplicated by the same rule the palette follows).
    private static func webPageGlyph() -> NSImage? {
        let amber = NSColor(srgbRed: 1.0, green: 0.757, blue: 0.027, alpha: 1.0)
        let config = NSImage.SymbolConfiguration(paletteColors: [amber])
        return NSImage(systemSymbolName: "safari", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Header for a `file://` document share: load the URL, read its name +
    /// content-type + localized type description under the security scope, and pull
    /// the OS file-TYPE icon (`NSWorkspace.icon(for:)` — derives from the UTType, no
    /// byte read, sandbox-safe). Returns nil → caller falls through to the glyph.
    @MainActor
    private func resolveFileURLHeader(_ provider: NSItemProvider) async -> ResolvedHeader? {
        guard let url = try? await loadURL(provider), url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let keys: Set<URLResourceKey> = [.contentTypeKey, .localizedTypeDescriptionKey]
        let values = try? url.resourceValues(forKeys: keys)
        let filename = url.lastPathComponent
        let typeDesc = values?.localizedTypeDescription
        let icon: NSImage?
        if let utType = values?.contentType {
            icon = NSWorkspace.shared.icon(for: utType)
        } else {
            icon = nil
        }
        return ResolvedHeader(filename: filename, typeDescription: typeDesc, icon: icon)
    }

    /// Header for an IMAGE share: a memory-bounded thumbnail via ImageIO. We take
    /// the provider's file-representation temp URL and build a 128px-max thumbnail
    /// with `CGImageSourceCreateThumbnailAtIndex` (decode-on-demand, never the full
    /// image), wrapped in an `NSImage`. The thumbnail is built SYNCHRONOUSLY inside
    /// the file-representation completion handler — Apple deletes the temp URL the
    /// instant it returns (same race the byte-copy path guards). On any failure the
    /// header still carries the filename (icon nil → the view shows the photo glyph).
    @MainActor
    private func resolveImageHeader(_ provider: NSItemProvider) async -> ResolvedHeader {
        let suggested = provider.suggestedName
        let typeDesc = String(localized: "share.type.image",
                              defaultValue: "Image",
                              comment: "Type description for a shared image in the Share Extension header")
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: ResolvedHeader(
                        filename: suggested ?? "", typeDescription: typeDesc, icon: nil))
                    return
                }
                // Build the bounded thumbnail synchronously, before `url` is reaped.
                let name = suggested ?? url.lastPathComponent
                let icon = Self.boundedThumbnail(at: url, maxPixel: 128)
                continuation.resume(returning: ResolvedHeader(
                    filename: name, typeDescription: typeDesc, icon: icon))
            }
        }
    }

    /// A memory-bounded image thumbnail via ImageIO — `CGImageSourceCreateWithURL`
    /// + `CGImageSourceCreateThumbnailAtIndex` capped at `maxPixel`, honoring the
    /// EXIF orientation, decoded on demand. NEVER loads the full image into memory.
    /// Returns nil on any failure (the header then shows the typed glyph).
    private static func boundedThumbnail(at url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Commit (Send)

    /// Build the inbox envelope from all providers, publish atomically, post a
    /// "Shared to Conduck" notification, THEN complete the request. Heavy work
    /// (byte copies) runs off the main thread; UI completion hops back. `target`
    /// is the picked "Send to" destination — resolved into the manifest's routing
    /// fields by `writeEnvelope`.
    private func commit(caption: String, target: ShareTarget, includePageText: Bool) {
        let providers = rawProviders
        let captureTask = capturePayloadTask
        let envelopeUUID = UUID()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // Resolve the memoized capture load once (shared with the toggle row).
            // The `CaptureLoad` carries the source provider's identity + the page
            // URL (always) and the parsed payload (only on a successful text parse),
            // so the envelope loop can skip the bridge provider and recover the URL.
            // nil for every non-Safari share.
            let capture = await captureTask?.value
            do {
                try await self.writeEnvelope(uuid: envelopeUUID, caption: caption,
                                             target: target, providers: providers,
                                             capture: capture, includeCapture: includePageText)
                // The atomic publish rename into `Inbox/<uuid>/` (inside
                // `writeEnvelope`) is ITSELF the wake: the main app's
                // `ShareInboxWatcher` observes the inbox-dir vnode and drains the
                // instant the dir changes — so a share made while Conduck is
                // inactive processes without a menu-bar click. No extra signal.
                await self.postSharedNotification(uuid: envelopeUUID)
            } catch {
                self.log.error("Share envelope write failed: \((error as NSError).domain, privacy: .public) code \((error as NSError).code, privacy: .public)")
                // Best-effort cleanup of the partial tmp dir; never publish a
                // partial envelope (the drainer skips tmp/, so a leftover is
                // swept by the janitor, but tidy up eagerly anyway).
                if let tmp = try? self.tmpDir(for: envelopeUUID) {
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
            // Complete on the main thread regardless of success — keeping the
            // extension alive after returning bytes is pointless and the host
            // expects a prompt dismiss. On failure the user simply sees no
            // notification; nothing partial is sent.
            await MainActor.run {
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: ShareExtensionIdentity.shareSubsystem, code: NSUserCancelledError)
        )
    }

    // MARK: - Envelope assembly

    /// Build `tmp/<uuid>/`, copy each provider's bytes + fold text/URLs into the
    /// manifest, write `manifest.json`, then ONE same-volume atomic rename into
    /// `Inbox/<uuid>/` (the publish). The rename is the only externally-visible
    /// mutation — a force-killed appex mid-copy leaves only an orphan `tmp/`
    /// dir the drainer skips and the janitor sweeps.
    private func writeEnvelope(uuid: UUID, caption: String, target: ShareTarget,
                               providers: [NSItemProvider],
                               capture: CaptureLoad?,
                               includeCapture: Bool) async throws {
        let fm = FileManager.default
        let tmp = try tmpDir(for: uuid)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        var items: [SharedInboxManifestItem] = []
        var urls: [String] = []
        var captionAccumulator = caption

        var sequence = 0
        for provider in providers {
            // Skip the confirmed Safari capture provider (identity match) — its
            // bytes are the raw property-list bridge payload, not a user
            // attachment. Every other provider (including a genuine `.plist` file
            // share) copies normally.
            if let capture, ObjectIdentifier(provider) == capture.providerID { continue }
            try await loadOne(
                provider: provider,
                sequence: &sequence,
                into: tmp,
                items: &items,
                urls: &urls,
                caption: &captionAccumulator
            )
        }

        // Safari page-text capture (nil for every non-Safari share). Carrier
        // identity + page-URL recovery run off the ALWAYS-present `CaptureLoad`;
        // only the synthetic markdown attachment is gated on a successful parse.
        if let capture {
            // (a) The page URL joins `urls[]` TOGGLE-INDEPENDENTLY — with the JS
            // key declared Safari vends the property-list item INSTEAD of
            // `public.url`, so toggle-OFF (and a failed text parse) must not lose
            // the URL. `shouldAppend` gates on http(s) + normalized non-equivalence
            // (the appex de-dupe and the drainer's URL splice are exact-string); an
            // empty `url` fails that gate, so it never appends.
            if WebPageCapture.shouldAppend(url: capture.url, toExisting: urls) {
                urls.append(capture.url)
            }
            // (b) The captured text rides as a synthetic markdown attachment ONLY
            // when the toggle is ON AND the parse produced a payload (usable text).
            // `sourceKind = "webpage"` drives the drainer's webpage-only behavior
            // (originalName as the display filename + the no-file-server inline
            // clamp). Write options match the manifest write.
            if includeCapture, let payload = capture.payload {
                let relPath = "att-\(sequence).md"
                let dest = tmp.appendingPathComponent(relPath)
                let data = Data(WebPageCapture.markdown(for: payload).utf8)
                try data.write(to: dest, options: [.atomic, .completeFileProtection])
                items.append(SharedInboxManifestItem(
                    relPath: relPath,
                    originalName: WebPageCapture.suggestedFilename(title: payload.title),
                    mimeType: "text/markdown",
                    utTypeIdentifier: "net.daringfireball.markdown",
                    sequence: sequence,
                    sourceKind: WebPageCapture.sourceKindWebpage
                ))
                sequence += 1
            }
        }

        // Resolve the picked target into the three mutually-exclusive routing
        // fields the drainer reads (see `SharedInboxManifest`):
        //   .existing(id, ref)           → append to that conversation
        //   .newConversation(.some(ref)) → mint a new conversation bound to `ref`
        //   .newConversation(nil)        → legacy/default route (all refs nil)
        let conversationID: UUID?
        let newConversationGatewayRef: String?
        let selectedBackendRef: String?
        switch target {
        case .existing(let id, let backendRef):
            conversationID = id
            selectedBackendRef = backendRef
            newConversationGatewayRef = nil
        case .newConversation(let gatewayRef):
            newConversationGatewayRef = gatewayRef   // nil ⇒ legacy/default
            conversationID = nil
            selectedBackendRef = nil
        }

        let manifest = SharedInboxManifest(
            v: 1,
            uuid: uuid,
            createdAt: Date(),
            caption: captionAccumulator,
            conversationID: conversationID,
            newConversationGatewayRef: newConversationGatewayRef,
            selectedBackendRef: selectedBackendRef,
            items: items,
            urls: dedupe(urls),
            // Sharing ALWAYS sends on the chosen target — the auto-send toggle was
            // removed (its OFF position never worked: the drainer always
            // dispatches). The `shouldAutosend` field stays in the frozen wire
            // contract; we write `true` literally.
            shouldAutosend: true
        )

        let manifestURL = tmp.appendingPathComponent("manifest.json")
        // Single-source the JSON contract: the drainer reads via
        // `SharedInboxManifest.decode(_:)`, so the writer MUST use the paired
        // `encoded()` (same pinned iso8601 strategy) — never an ad-hoc coder, or
        // a future strategy change silently desyncs the two processes.
        let data = try manifest.encoded()
        try data.write(to: manifestURL, options: [.atomic, .completeFileProtection])

        // Atomic publish: same-volume rename of tmp/<uuid> → Inbox/<uuid>.
        let published = try inboxDir().appendingPathComponent(uuid.uuidString, isDirectory: true)
        try fm.moveItem(at: tmp, to: published)
    }

    /// Dispatch ONE provider to the right loader by its registered type, copying
    /// file/image bytes INSIDE the completion handler (Apple deletes the temp on
    /// return). Text → fold into caption (or urls if it's a URL string); web URL
    /// → urls[]; `file://` URL → COPIED on macOS (the divergence from iOS — see
    /// the file header). Order of the `if` ladder matters: prefer the file
    /// representation for images/files so we copy bytes rather than an in-memory
    /// `NSImage`.
    private func loadOne(
        provider: NSItemProvider,
        sequence: inout Int,
        into tmp: URL,
        items: inout [SharedInboxManifestItem],
        urls: inout [String],
        caption: inout String
    ) async throws {
        // 1) URL (handled before plain text — a shared link arrives as both).
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await loadURL(provider) {
                if url.isFileURL {
                    // macOS DIVERGENCE: Finder/Preview/Quick Look share a document
                    // as a security-scoped file:// URL (not a representation). Copy
                    // its bytes synchronously inside the access window into the
                    // envelope so the file is durable post-exit. On iOS this branch
                    // rejects the URL; here we keep it.
                    if let item = copySecurityScopedFileURL(url, sequence: sequence, into: tmp) {
                        items.append(item)
                        sequence += 1
                    } else {
                        log.info("Dropped file:// URL share item (could not copy bytes)")
                    }
                } else {
                    urls.append(url.absoluteString)
                }
                return
            }
        }

        // 2) Image — copy the file representation (NO decode).
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let item = try await copyFileRepresentation(
                provider, typeIdentifier: UTType.image.identifier, sequence: sequence, into: tmp
            ) {
                items.append(item)
                sequence += 1
                return
            }
        }

        // 3) Plain text — fold into caption (or urls if the text is itself a URL).
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await loadText(provider) {
                if let url = URL(string: text), let scheme = url.scheme,
                   scheme == "http" || scheme == "https" {
                    urls.append(url.absoluteString)
                } else {
                    caption = caption.isEmpty ? text : caption + "\n" + text
                }
                return
            }
        }

        // 4) Arbitrary file — copy the file representation of its concrete UTI
        // (fall back to `public.data`). Covers PDF / docx / zip / text-files;
        // the drainer classifies them at drain time.
        let concreteType = provider.registeredTypeIdentifiers.first(where: { id in
            // Skip the abstract item/data types if a more concrete one exists.
            id != UTType.item.identifier && id != UTType.data.identifier
        }) ?? UTType.data.identifier

        if let item = try await copyFileRepresentation(
            provider, typeIdentifier: concreteType, sequence: sequence, into: tmp
        ) {
            items.append(item)
            sequence += 1
        }
    }

    // MARK: - Provider loaders

    /// macOS-only: copy a security-scoped `file://` URL's bytes into
    /// `tmp/att-<seq>.<ext>` synchronously, deriving the mime/UTI from the URL's
    /// `contentType` resource value. Wrapped in
    /// `startAccessingSecurityScopedResource()` / `stop…` so the sandboxed appex
    /// can read the user-selected file the share host temporarily granted. Returns
    /// nil (and the caller logs + drops) on any copy failure — never throws into
    /// the envelope assembly (one bad file shouldn't sink the whole share).
    private func copySecurityScopedFileURL(_ url: URL, sequence: Int, into tmp: URL) -> SharedInboxManifestItem? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Resolve the UTI/mime from the file itself (the share host hands us a
        // bare URL with no advertised type).
        let utType: UTType? = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let ext = fileExtension(for: url, suggestedName: url.lastPathComponent, utType: utType)
        let relPath = "att-\(sequence).\(ext)"
        let dest = tmp.appendingPathComponent(relPath)

        do {
            try FileManager.default.copyItem(at: url, to: dest)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: dest.path
            )
            return SharedInboxManifestItem(
                relPath: relPath,
                originalName: url.lastPathComponent,
                mimeType: utType?.preferredMIMEType,
                utTypeIdentifier: utType?.identifier,
                sequence: sequence
            )
        } catch {
            log.error("Security-scoped file copy failed: \((error as NSError).domain, privacy: .public) code \((error as NSError).code, privacy: .public)")
            return nil
        }
    }

    /// Copy a provider's FILE representation into `tmp/att-<seq>.<ext>` INSIDE
    /// the completion handler — Apple deletes the source temp file the instant
    /// the handler returns, so the copy MUST happen before we yield. Returns the
    /// manifest item (relPath + original name + mime + UTI + sequence). ZERO
    /// decoding — pure `copyItem` byte move (honours the appex memory cap).
    private func copyFileRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        sequence: Int,
        into tmp: URL
    ) async throws -> SharedInboxManifestItem? {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                // CRITICAL: copy synchronously, INSIDE this handler, before it
                // returns and Apple reclaims `url`.
                let utType = UTType(typeIdentifier)
                let ext = self.fileExtension(for: url, suggestedName: suggestedName, utType: utType)
                let relPath = "att-\(sequence).\(ext)"
                let dest = tmp.appendingPathComponent(relPath)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    // Apply complete file protection to the copy (drain-on-active
                    // = foreground = unlocked; flagged for a deferred BG path).
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete], ofItemAtPath: dest.path
                    )
                    let item = SharedInboxManifestItem(
                        relPath: relPath,
                        originalName: suggestedName,
                        mimeType: utType?.preferredMIMEType,
                        utTypeIdentifier: typeIdentifier,
                        sequence: sequence
                    )
                    continuation.resume(returning: item)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Load a shared URL object (web link or a security-scoped file URL).
    private func loadURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: url)
            }
        }
    }

    /// Load shared plain text.
    private func loadText(_ provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { string, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (string as? String))
            }
        }
    }

    // MARK: - Notification

    /// Post a local "Shared to Conduck" notification carrying the envelope UUID,
    /// so the user has a tap-path that foregrounds the app (and the drainer
    /// drains on activation). Best-effort — a denied notification permission
    /// does NOT block the queued envelope (it still drains on next activation).
    private func postSharedNotification(uuid: UUID) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "share.notification.title",
                               defaultValue: "Shared to Conduck",
                               comment: "Title of the local notification posted after a share is queued")
        content.body = String(localized: "share.notification.body",
                              defaultValue: "Tap to open in Conduck.",
                              comment: "Body of the local notification posted after a share is queued")
        content.userInfo = ["shareEnvelopeID": uuid.uuidString]
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "share.\(uuid.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            // Request provisional authorization quietly — share notifications are
            // low-stakes status updates; provisional avoids a permission prompt
            // inside the share sheet (Apple discourages prompting from appexes).
            _ = try? await center.requestAuthorization(options: [.alert, .provisional])
            try await center.add(request)
        } catch {
            log.info("Share notification not delivered: \((error as NSError).domain, privacy: .public) code \((error as NSError).code, privacy: .public)")
        }
    }

    // MARK: - Paths

    /// App-Group container root, or throws if the App Group is mis-provisioned
    /// (entitlement missing at install time).
    private func containerURL() throws -> URL {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            throw ShareError.appGroupUnavailable
        }
        return url
    }

    /// `Application Support/Inbox/` (durable — NOT `Library/Caches/`, which iOS
    /// purges). Created lazily; `Application Support` itself may not exist yet in
    /// a fresh App-Group container.
    private func inboxDir() throws -> URL {
        let inbox = try containerURL()
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// `Inbox/tmp/<uuid>/` — the in-progress write area; published via rename.
    private func tmpDir(for uuid: UUID) throws -> URL {
        try inboxDir()
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(uuid.uuidString, isDirectory: true)
    }

    /// `Application Support/share-targets.json` — the tiny "Send to" snapshot the
    /// main app writes atomically. We only READ it. Missing file, no App Group,
    /// or a malformed payload all resolve to `nil` (the picker then shows the
    /// legacy fallback row). Cheap synchronous read — the file is a few hundred
    /// bytes, off the byte-copy hot path (this runs in `viewDidLoad`, before any
    /// attachment work).
    private func loadShareTargetsSnapshot() -> ShareTargetsSnapshot? {
        guard let container = try? containerURL() else { return nil }
        let url = container
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("share-targets.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ShareTargetsSnapshot.decode(data)
    }

    // MARK: - Helpers

    /// Best file extension for the copied attachment: prefer the source URL's
    /// extension, then the suggested name's, then the UTType's preferred
    /// extension, else `dat`.
    private func fileExtension(for url: URL, suggestedName: String?, utType: UTType?) -> String {
        let fromURL = url.pathExtension
        if !fromURL.isEmpty { return fromURL.lowercased() }
        if let name = suggestedName {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        if let ext = utType?.preferredFilenameExtension { return ext.lowercased() }
        return "dat"
    }

    /// Order-preserving de-dupe for collected URLs.
    private func dedupe(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    enum ShareError: Error {
        case appGroupUnavailable
    }
}

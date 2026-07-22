// Conduck
// ShareViewController.swift  (ConduckShareExtension appex — INERT until Phase C)
//
// UIKit principal class for the iOS/iPadOS Share Extension. Apple has NOT given
// Share Extensions a SwiftUI principal through iOS 26, so the principal is a
// `UIViewController` that hosts `UIHostingController(rootView: ShareView(...))`
// — the canonical Signal-iOS `SignalShareExtension/ShareViewController.swift`
// pattern. `NSExtensionPrincipalClass` in Info.plist points here.
//
// ── Shared contract (DO NOT drift) ────────────────────────────────────────────
// This appex is a thin CAPTURE-AND-QUEUE stage; it does ZERO decoding/processing
// (the iOS 26 appex ~120 MB cap forbids decoding a 48 MP HEIC). It copies each
// shared item's bytes into an App-Group inbox + writes `manifest.json`, then
// exits. The MAIN-APP `SharedInboxDrainer` actor consumes these envelopes on
// `scenePhase == .active` / notification-tap and runs the real pipeline
// (`ImageProcessor` / `TextFileExtractor` / file-server upload → `appendMessage`
// → `BackgroundRemoteAgent.send`). `SharedInboxManifest` + the on-disk inbox
// layout below ARE the cross-process contract — change them only in lockstep
// with the drainer.
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

import UIKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import UserNotifications
import os

// SHARED CONTRACT TYPE: `SharedInboxManifest` / `SharedInboxManifestItem` are
// provided to THIS appex by `ConduckShareExtension/SharedInboxManifest.swift` — a
// VERBATIM MIRROR of the main-app `Conduck/Models/SharedInboxManifest.swift`
// The appex and the main app are SEPARATE compilation modules, so the
// contract is carried as one source file per module rather than shared via
// cross-target membership — that keeps this 120 MB-capped appex self-contained
// (no app-graph coupling) and needs no fragile .pbxproj surgery. The two files
// MUST stay byte-identical below their headers: `SharedInboxManifest.encoded()`
// pins `.iso8601` + `.sortedKeys`, so the bytes this appex writes are exactly what
// the drainer decodes. Drift guard: `ConduckTests/SharedInboxManifestTests`.

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

final class ShareViewController: UIViewController {

    private let log = Logger(subsystem: ShareExtensionIdentity.shareSubsystem, category: "ShareViewController")

    /// App-Group identifier (matches the main app's `Constants.appGroupID` and
    /// the App-Group entitlement entries; the appex's own entitlements mirror it).
    private static let appGroupID = ShareExtensionIdentity.appGroupID

    /// Per-attachment cap — defence-in-depth alongside the Info.plist activation
    /// predicate's `SUBQUERY(...) <= 10`. A malformed share that slips the
    /// predicate is still bounded here.
    private static let maxAttachments = 10

    /// The memoized Safari page-text capture load. Started ONCE in `viewDidLoad`;
    /// its single result is shared by the toggle row (`resolveCapture`), the lead
    /// header synthesis (`resolveLeadHeader`, for a capture-only share), and the
    /// commit path (`writeEnvelope`), so the JS-results property-list provider is
    /// loaded at most once. `nil` for every non-Safari share.
    private var capturePayloadTask: Task<CaptureLoad?, Never>?

    /// A Safari capture carrier load. `providerID` + `url` are bound whenever the
    /// property-list provider carries `NSExtensionJavaScriptPreprocessingResultsKey`
    /// (the Safari share), so the envelope copy loop can skip that carrier (it must
    /// not also ride as a file) and recover the page URL — EVEN when the text parse
    /// found nothing usable. `payload` is non-nil ONLY when `WebPageCapture.parse`
    /// succeeded (usable text); it alone gates the toggle row + the synthetic
    /// markdown item. Identity is an `ObjectIdentifier` (not the `NSItemProvider`
    /// itself) so the value is `Sendable` across the commit's detached task.
    private struct CaptureLoad: Sendable {
        let providerID: ObjectIdentifier
        let url: String
        let payload: WebPageCapture.Payload?
    }

    // MARK: - Lifecycle

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
            resolveLeadHeader: { [weak self] in await self?.resolveLeadHeader() },
            resolveCapture: { [weak self] in await self?.capturePayloadTask?.value?.payload },
            onSend: { [weak self] caption, target, includePageText in
                self?.commit(caption: caption, target: target, includePageText: includePageText)
            },
            onCancel: { [weak self] in self?.cancel() }
        )

        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        // Force dark — the app is dark-mode only; the share sheet inherits the
        // host app's appearance otherwise.
        overrideUserInterfaceStyle = .dark

        // Start the memoized Safari page-text capture load ONCE. A single shared
        // load feeds the toggle row (via `resolveCapture`), the lead header (via
        // `resolveLeadHeader`), and the commit path (via `capturePayloadTask.value`),
        // so the JS-results property-list provider is loaded at most once. Resolves
        // to nil ONLY when there is no property-list provider, or the loaded item
        // carries no JS results key (a genuine plist FILE share). A Safari carrier
        // whose text won't parse still resolves NON-nil (payload nil) — the carrier
        // is skipped + the URL recovered; only the toggle row / synthetic item drop.
        capturePayloadTask = Task { [weak self] in await self?.loadCapturePayload() }
    }

    // MARK: - Input inspection (cheap, for the preview only)

    /// Every attachment across all input items (bounded by `maxAttachments`) —
    /// the RAW list the envelope is written from. The commit loop skips only the
    /// confirmed capture provider; everything else rides.
    private var rawProviders: [NSItemProvider] {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        return Array(providers.prefix(Self.maxAttachments))
    }

    /// `rawProviders` minus any provider conforming to property-list — the
    /// preview surfaces (count / preview items / lead header) read THIS so a
    /// Safari share, whose ONLY provider is the JS-results property-list, never
    /// flashes a "File · property list" row before the toggle resolves. EAGER +
    /// conformance-only (no load, no async) by design; a genuine plist FILE share
    /// from a non-Safari app is edge-rare and acceptable to hide from preview (it
    /// still rides the envelope untouched, since the commit loop skips ONLY the
    /// parse-confirmed capture provider).
    private var visibleProviders: [NSItemProvider] {
        rawProviders.filter {
            !$0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }
    }

    private func extractedAttachmentCount() -> Int { visibleProviders.count }

    /// Lightweight preview descriptors for `ShareView` — derived from the
    /// providers' registered type identifiers + suggested names, WITHOUT loading
    /// any bytes (loading a 48 MP HEIC here would blow the appex memory cap).
    private func buildPreviewItems() -> [ShareView.PreviewItem] {
        visibleProviders.map { provider in
            let name = provider.suggestedName
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return .image(name: name)
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

    // MARK: - Capture payload (Safari page-text)

    /// Load the Safari page-text capture carrier, if this share carries one.
    /// Finds the FIRST property-list provider (with the JS key declared, Safari's
    /// share vends exactly one — the `NSExtensionJavaScriptPreprocessingResultsKey`
    /// carrier), loads it, and unwraps the results dictionary.
    ///
    /// Returns nil ONLY when there is no property-list provider, or the loaded item
    /// carries NO results key (a genuine plist FILE share) — that share falls
    /// through untouched: no carrier to skip, no URL to recover, the plist rides
    /// `loadOne` as a file.
    ///
    /// When the results key IS present this is the Safari carrier: the returned
    /// `CaptureLoad` always binds `providerID` (so the copy loop skips it — the
    /// JS-results plist must not ALSO ride as a file) and `url` (so a toggle-OFF or
    /// parse-nil share still recovers the page URL). `payload` is non-nil only when
    /// `WebPageCapture.parse` finds usable text; a nil payload is graceful absence
    /// of TEXT — no toggle row, no synthetic markdown item — NOT absence of the
    /// carrier. The parse runs INSIDE the load completion so the continuation
    /// resumes with the `Sendable` `CaptureLoad` (an `NSDictionary` is not `Sendable`).
    @MainActor
    private func loadCapturePayload() async -> CaptureLoad? {
        guard let plistProvider = rawProviders.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        }) else { return nil }
        let providerID = ObjectIdentifier(plistProvider)
        return await withCheckedContinuation { continuation in
            plistProvider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
                // Absent results key = a genuine plist FILE share (not Safari's JS
                // bridge): resume nil so it falls through to `loadOne` as a file.
                guard let results = (item as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey]
                    as? [AnyHashable: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                // Key present → this IS the Safari carrier. Bind identity + URL
                // unconditionally (carrier skipped in the copy loop, page URL
                // recovered even on a nil parse); `payload` is non-nil only when
                // `WebPageCapture.parse` finds usable text.
                continuation.resume(returning: CaptureLoad(
                    providerID: providerID,
                    url: (results["url"] as? String) ?? "",
                    payload: WebPageCapture.parse(results)
                ))
            }
        }
    }

    // MARK: - Rich header resolution (name / type / icon — NO full-byte reads)

    /// Resolve the rich header for the LEAD provider (`visibleProviders.first`) — the
    /// filename/title, a localized type description, and (for images only) a
    /// MEMORY-BOUNDED thumbnail — WITHOUT reading the full bytes (a full HEIC load
    /// would blow the 120 MB appex cap). Always returns a value on a non-empty lead
    /// provider (icon may be nil → the view keeps its typed glyph). A capture-only
    /// Safari share (no visible provider) synthesizes the header from the captured
    /// page (title/host + a "Web page" type line); only a share with NEITHER a
    /// visible provider NOR a capture returns nil. Runs on the main actor (UI-facing); the
    /// underlying loaders hop to a continuation and back. NEVER throws into the UI.
    ///
    /// macOS divergence: iOS rejects `file://` shares and has no `NSWorkspace.icon`,
    /// so non-image documents carry a localized type DESCRIPTION but NO icon (the
    /// header shows the typed SF-symbol glyph). Images still get a real thumbnail.
    @MainActor
    private func resolveLeadHeader() async -> ResolvedHeader? {
        // A Safari page-text share carries ONLY the JS-results property-list
        // carrier, which `visibleProviders` hides — so `visibleProviders` is empty
        // and the generic-fallback bail below would show "Shared item". Synthesize
        // the header from the capture instead: the page title (else the URL host)
        // as the primary line + a "Web page" type line, no icon (iOS `ResolvedHeader`
        // has no SF-symbol slot). Covers a parsed capture AND a parse-nil URL-only
        // capture (payload nil). Awaited only when there are no visible providers,
        // so a normal share never pays for it.
        if visibleProviders.isEmpty, let load = await capturePayloadTask?.value {
            let title = load.payload?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let primary = (title?.isEmpty == false) ? title : URL(string: load.url)?.host
            if let primary, !primary.isEmpty {
                return ResolvedHeader(
                    filename: primary,
                    typeDescription: String(localized: "share.capture.webpage",
                                            defaultValue: "Web page",
                                            comment: "Type description shown in the Share Extension header for a captured Safari web page"),
                    icon: nil
                )
            }
        }

        guard let provider = visibleProviders.first else { return nil }

        // 1) IMAGE — a bounded ImageIO thumbnail (NEVER UIImage(contentsOfFile:),
        // which decodes the full image). Tested first so an image that ALSO vends a
        // file representation reads as an image.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await resolveImageHeader(provider)
        }

        // 2) WEB url — host as the title + a plain "Link" subtitle (no network in
        // the appex, so no page-title fetch); no icon. iOS file:// URLs are rejected
        // upstream, so a web URL here is genuinely a web link.
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

        // 3) PLAIN text — a short leading snippet; no icon.
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

        // 4) Any other FILE (PDF / doc / zip …) arrives as a file representation on
        // iOS, not a file:// URL — so we can't read it cheaply here. Carry the
        // suggested name + a localized type description derived from the most
        // concrete registered UTI; the view keeps the typed SF-symbol glyph (no
        // icon, since iOS has no sandbox-safe type→icon API like NSWorkspace).
        let concreteType = provider.registeredTypeIdentifiers.first(where: { id in
            id != UTType.item.identifier && id != UTType.data.identifier
        })
        let typeDesc = concreteType.flatMap { UTType($0)?.localizedDescription }
        return ResolvedHeader(
            filename: provider.suggestedName ?? "",
            typeDescription: typeDesc,
            icon: nil
        )
    }

    /// Header for an IMAGE share: a memory-bounded thumbnail via ImageIO. We take
    /// the provider's file-representation temp URL and build a 128px-max thumbnail
    /// with `CGImageSourceCreateThumbnailAtIndex` (decode-on-demand, never the full
    /// image), wrapped in a `UIImage`. The thumbnail is built SYNCHRONOUSLY inside
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
    private static func boundedThumbnail(at url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
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
            // Await the memoized capture load (never re-loads) — needed to skip
            // the capture provider in the copy loop, recover the page URL, and
            // synthesize the markdown attachment. nil for every non-Safari share.
            let capture = await captureTask?.value
            do {
                try await self.writeEnvelope(uuid: envelopeUUID, caption: caption,
                                             target: target, providers: providers,
                                             capture: capture, includePageText: includePageText)
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
                               capture: CaptureLoad?, includePageText: Bool) async throws {
        let fm = FileManager.default
        let tmp = try tmpDir(for: uuid)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        var items: [SharedInboxManifestItem] = []
        var urls: [String] = []
        var captionAccumulator = caption

        var sequence = 0
        for provider in providers {
            // Skip the Safari capture carrier whenever present — its bytes are the
            // JS-results property list, not a file to copy. Skipped even when the
            // text parse yielded nothing (payload nil): the plist must never ride
            // as a file. The page text rides as the synthetic markdown item below
            // (and only when the toggle is ON).
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

        // Recover the page URL from the capture carrier and append it
        // TOGGLE-INDEPENDENTLY. With the JS key declared Safari vends ONLY the
        // property-list item — `public.url` DISAPPEARS — so this is the share's
        // one URL source, and a toggle-OFF (or even parse-nil, no-usable-text)
        // Safari share must still deliver it. The URL rides on `CaptureLoad` itself
        // (not its optional `payload`), so it survives a nil parse. Gated via
        // `shouldAppend` (http(s) + no normalized-equivalent already present) so a
        // URL that also arrived by another route isn't double-posted.
        if let capture, WebPageCapture.shouldAppend(url: capture.url, toExisting: urls) {
            urls.append(capture.url)
        }

        // Synthesize the captured page text as a Markdown attachment — ONLY when
        // the toggle is ON AND the parse produced usable text (`payload` non-nil;
        // a parse-nil URL-only capture skips this but already delivered its URL
        // above). It rides the existing text-attachment route; the
        // `sourceKind: webpage` marker drives the drainer's webpage-only behavior
        // (originalName as the display filename + the no-file-server inline clamp).
        // Write options match the manifest write below (.atomic + complete
        // file protection).
        if includePageText, let payload = capture?.payload {
            let relPath = "att-\(sequence).md"
            let dest = tmp.appendingPathComponent(relPath)
            let markdown = WebPageCapture.markdown(for: payload)
            try Data(markdown.utf8).write(to: dest, options: [.atomic, .completeFileProtection])
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
    /// → urls[]; `file://` URL → rejected (not durable post-exit). Order of the
    /// `if` ladder matters: prefer the file representation for images/files so we
    /// copy bytes rather than an in-memory `UIImage`.
    private func loadOne(
        provider: NSItemProvider,
        sequence: inout Int,
        into tmp: URL,
        items: inout [SharedInboxManifestItem],
        urls: inout [String],
        caption: inout String
    ) async throws {
        // 1) Web URL (handled before plain text — a shared link arrives as both).
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await loadURL(provider) {
                if url.isFileURL {
                    // Reject file:// — the security-scoped URL dies with the
                    // appex; durable *files* arrive as file representations, not
                    // file:// item URLs. Drop silently (no envelope item).
                    log.info("Rejected file:// URL share item (not durable post-exit)")
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

    /// Copy a provider's FILE representation into `tmp/att-<seq>.<ext>` INSIDE
    /// the completion handler — Apple deletes the source temp file the instant
    /// the handler returns, so the copy MUST happen before we yield. Returns the
    /// manifest item (relPath + original name + mime + UTI + sequence). ZERO
    /// decoding — pure `copyItem` byte move (honours the 120 MB appex cap).
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

    /// Load a shared URL object (web link or, rejected later, a file URL).
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

// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardCardFace.swift
//
// What a Work card SHOWS, decided in ONE place. The mosaic tile, the list row
// and the spoken label all read this policy, because a card that composes its
// own face three times is a card whose three surfaces can disagree — and they
// did. The tile drew a note's generated title over the note's own first line
// ("hi" above "hi"); the accessibility builder appended the name and the body
// separately, so VoiceOver read the same sentence twice; and the projection
// folds an availability sentence into `detail`, which the tile then drew a
// second time beside the availability glyph.
//
// Pure and view-free, so every rule here is assertable without mounting a card.
// Nothing reads bytes, fetches a favicon or measures a clip: a face is a
// function of the snapshot the board already holds, which is also what keeps
// the desk from making an outbound request just to draw itself.
//
// THE FOOTPRINT IS NOT AN INPUT. Every card is drawn at one footprint, so a
// face carries no density variants — what a card says does not depend on how
// much room it was granted, and a surface that wants less shows fewer lines of
// the same slots rather than a different sentence.

import SwiftUI

/// One card's face: the slots every Work surface fills, in the order they read.
///
/// A slot is absent rather than empty when the card has nothing to put in it,
/// which is the whole mechanism behind the de-duplication: a heading the body
/// already says is `nil`, not a repeated string the view is expected to notice.
nonisolated struct WorkboardCardFace: Equatable, Sendable {
    /// The identifying line. Absent exactly when the excerpt already says it.
    let heading: String?
    /// One continuous body — a note's whole text, a recording's transcript, a
    /// link's distinguishing path. Never the heading restated.
    let excerpt: String?
    /// What names the material when the heading is content rather than
    /// identity: a link's host, kept whether or not it is also the title.
    let identity: String?
    /// The demoted row's words: a file's type and size, an image's size. Nil
    /// where the card has nothing worth spending a row on.
    let meta: String?
    /// Whether the card states when it was captured, beside `meta`.
    let showsAge: Bool
    /// The availability sentence, or nil for a card whose bytes are here. It is
    /// a sentence as well as a glyph so a person knows when the source file
    /// is still arriving even though its metadata and notes are available.
    let availability: LocalizedStringResource?
    /// A filename's tail is the part that distinguishes it, so a heading that
    /// does not fit gives up its middle rather than its extension.
    let headingProtectsExtension: Bool
    /// Size and age are the least of what a picture says, so on a pointer
    /// platform they wait for the pointer — in space the caption reserves
    /// either way, so the name never moves when they appear.
    let metaWaitsForPointer: Bool

    /// The line a surface leads with. A card whose heading was suppressed leads
    /// with its body: the alternative is a bold blank where the title was.
    var leadLine: String? { heading ?? excerpt }

    /// The body a surface draws UNDER its lead line — nothing, when the lead
    /// line is already the body.
    var trailingExcerpt: String? { heading == nil ? nil : excerpt }

    /// The face as spoken parts, in reading order and with no slot said twice.
    /// `meta` and the age are deliberately absent: a size and a relative date
    /// are orientation for an eye scanning a grid, and reading them aloud in
    /// front of the card's actual content buries it.
    var spokenParts: [String] { [heading, identity, excerpt].compactMap { $0 } }
}

/// The rules that build a face.
///
/// SUPPRESSION IS A DISPLAY DECISION AND NEVER A MIGRATION. A stored title is
/// the person's row: rewriting every legacy "Share note" would advance the
/// revision of every one of those cards and re-sync the whole desk to say
/// nothing new, and the record does not store WHY a title exists, so a rewrite
/// cannot tell a generated prefix from a provenance label somebody relies on.
nonisolated enum WorkboardCardFacePolicy {

    // MARK: - The face

    static func face(for material: WorkboardMaterialSnapshot) -> WorkboardCardFace {
        let name = text(material.name)
        let availability = availabilityLabel(for: material.availability)

        switch material.kind {
        // A spoken note's title IS its words' lead line — the publication lane
        // writes it there — so it duplicates itself exactly as a typed note
        // does, and all three are fixed by the same rule: a heading the body
        // already says is dropped, because a card that repeats its own name
        // spends its first line saying nothing. With no words a recording keeps
        // its name and its capture time, which is all a card can honestly say
        // about a clip nothing has decoded.
        case .note, .audio, .transcript:
            let body = text(material.textContent) ?? caption(
                from: material.detail,
                byteCount: material.byteCount
            )
            var heading = name
            if let body, let candidate = heading, headingIsSaidByBody(candidate, body: body) {
                heading = nil
            }
            return WorkboardCardFace(
                heading: heading,
                excerpt: body,
                identity: nil,
                meta: nil,
                showsAge: true,
                availability: availability,
                headingProtectsExtension: false,
                metaWaitsForPointer: false
            )

        case .link:
            let urlString = text(material.urlString)
            let components = urlString.flatMap { URLComponents(string: $0) }
            let bareHost = components?.host.flatMap(text)
            let host = hostLabel(of: components)
            // A name the projection derived from the URL is not a title: the
            // repository falls back to the host, and the share extension often
            // stores the bare address. It compares against the BARE host as
            // well, because that is the form the repository stores — a card
            // named "localhost" is still a derived name once the face has
            // added the port back on.
            let title: String? = {
                guard let name, name != host, name != bareHost, name != urlString else { return nil }
                return name
            }()
            let heading = title ?? host ?? name ?? urlString
            return WorkboardCardFace(
                heading: heading,
                excerpt: distinguishingPath(of: components),
                // The host is kept whichever slot it lands in, never in both.
                identity: heading == host ? nil : host,
                meta: nil,
                showsAge: true,
                availability: availability,
                headingProtectsExtension: false,
                metaWaitsForPointer: false
            )

        case .image:
            return WorkboardCardFace(
                heading: name,
                excerpt: caption(from: material.detail, byteCount: material.byteCount),
                identity: nil,
                meta: sizeText(material.byteCount),
                showsAge: true,
                availability: availability,
                headingProtectsExtension: false,
                metaWaitsForPointer: true
            )

        case .file:
            return WorkboardCardFace(
                heading: name,
                excerpt: caption(from: material.detail, byteCount: material.byteCount),
                identity: nil,
                meta: fileMeta(filename: material.name, byteCount: material.byteCount),
                showsAge: true,
                availability: availability,
                headingProtectsExtension: true,
                metaWaitsForPointer: false
            )
        }
    }

    /// A FOLDED recording's own two text slots, decided by the same rule.
    ///
    /// A recording's title IS its transcript's lead line — the publication lane
    /// writes it there — so a folded card drawing both repeats itself exactly
    /// as a standalone recording did. That card is the one surface the shared
    /// face could not reach: the companion is a band on somebody ELSE'S
    /// material, so `face(for:)` answers for the picture and never for the clip
    /// riding on it. Only the two text slots are answered here, because a
    /// companion has no identity, meta, age or availability of its own — those
    /// belong to the card it is folded into.
    static func companionFace(title: String, transcript: String?) -> WorkboardCardFace {
        let body = text(transcript)
        var heading = text(title)
        if let body, let candidate = heading, headingIsSaidByBody(candidate, body: body) {
            heading = nil
        }
        return WorkboardCardFace(
            heading: heading,
            excerpt: body,
            identity: nil,
            meta: nil,
            showsAge: false,
            availability: nil,
            headingProtectsExtension: false,
            metaWaitsForPointer: false
        )
    }

    // MARK: - De-duplication

    /// Whether a heading is something the body already says.
    ///
    /// Two shapes, because equality alone misses the longer note. Either the
    /// heading IS the body, or the heading is the body's GENERATED leading
    /// prefix — the first non-empty line trimmed to 72 characters, which is
    /// exactly what `WorkboardWorkspaceCaptureLogic.title` writes at capture.
    /// A note whose body runs past 72 characters therefore carries a title that
    /// is a cut of its own first line, and equality would keep it.
    ///
    /// The body's opening sentence is never the thing removed: a heading is
    /// dropped, an excerpt never is. The excerpt is what carries the meaning,
    /// and a face that trimmed the lead line off the body to avoid the repeat
    /// would delete the only sentence a short note has.
    static func headingIsSaidByBody(_ heading: String, body: String) -> Bool {
        guard let heading = text(heading), let body = text(body) else { return false }
        if heading.compare(body, options: [.caseInsensitive]) == .orderedSame { return true }
        if isSuppressedGenericTitle(heading) { return true }
        // The generated prefix goes through `text(_:)` for the same reason the
        // heading does: `title(for:)` cuts the lead line at 72 characters
        // WITHOUT re-trimming, so a line whose 72nd character is a space is
        // stored with that space and the two sides would differ by it alone.
        guard let generated = text(WorkboardWorkspaceCaptureLogic.title(for: body)) else {
            return false
        }
        return heading.compare(generated, options: [.caseInsensitive]) == .orderedSame
    }

    /// Titles the desk wrote for itself before a capture derived one from what
    /// the person actually shared. They name the ROUTE rather than the content,
    /// so a card carrying one says nothing its body does not — and unlike a
    /// provenance title ("Chat response"), which the record keeps for a reason,
    /// there is nothing behind them to lose.
    static func isSuppressedGenericTitle(_ heading: String) -> Bool {
        let candidate = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        return genericTitles.contains {
            candidate.compare($0, options: [.caseInsensitive]) == .orderedSame
        }
    }

    private static var genericTitles: [String] {
        [String(localized: "workboard.capture.note", defaultValue: "Share note")]
    }

    // MARK: - Slots

    /// The person's own caption, separated from the two things the projection
    /// folds into the same field.
    ///
    /// `WorkboardLiveRepository.materialDetail` joins a caption, an availability
    /// sentence and a size fallback with " • ". The card draws availability and
    /// size itself, so a face that showed `detail` verbatim would say both of
    /// them twice. They are removed BY VALUE rather than split at the source
    /// because the projection round-trips `detail` back into `caption`, so
    /// re-deriving the field there would rewrite stored rows.
    static func caption(from detail: String?, byteCount: Int64?) -> String? {
        guard let detail = text(detail) else { return nil }
        var derived: Set<String> = [
            String(localized: "workboard.material.localOnly", defaultValue: "Available on this device"),
            String(
                localized: "workboard.material.unavailableHere",
                defaultValue: "Reattach on this device to open"
            ),
            String(localized: "workboard.material.syncPending", defaultValue: "Waiting for iCloud…")
        ]
        if let size = sizeText(byteCount) { derived.insert(size) }
        let kept = detail
            .components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !derived.contains($0) }
        return kept.isEmpty ? nil : kept.joined(separator: " • ")
    }

    /// What NAMES a destination: its host, and an explicit port when the
    /// address carries one.
    ///
    /// The port is part of the identity, not decoration. Two services on one
    /// machine differ in nothing else, so a face that dropped it drew
    /// `http://localhost:3000/` and `http://localhost:8080/` as the same card
    /// and spoke them as the same word. `URLComponents` reports only a port the
    /// address actually states, so an ordinary `https://` link is unchanged.
    static func hostLabel(of components: URLComponents?) -> String? {
        guard let host = text(components?.host) else { return nil }
        guard let port = components?.port else { return host }
        return "\(host):\(port)"
    }

    /// The part of a URL that says which page this is. A bare host, a trailing
    /// slash and an empty path all distinguish nothing, so they draw nothing
    /// rather than a decorative "/" under the host that already said it.
    ///
    /// The fragment is part of that answer, not decoration: a client-routed app
    /// puts its whole route after the "#", so two cards on the same host would
    /// otherwise carry one identical face and one identical spoken label for
    /// two different pages.
    static func distinguishingPath(of components: URLComponents?) -> String? {
        guard let components else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if let query = text(components.query) { path += "?" + query }
        if let fragment = text(components.fragment) { path += "#" + fragment }
        return text(path)
    }

    /// Type and size, in the row under a filename. The type token is the
    /// extension the person can see in the name, uppercased — a noun the file
    /// carries rather than a kind label every file card would share.
    static func fileMeta(filename: String, byteCount: Int64?) -> String? {
        let parts = [fileTypeToken(filename: filename), sizeText(byteCount)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    static func fileTypeToken(filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy(\.isLetter) else { return nil }
        return ext.uppercased()
    }

    static func sizeText(_ byteCount: Int64?) -> String? {
        guard let byteCount, byteCount > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    // MARK: - Availability

    /// The ONE place a card's availability becomes words.
    ///
    /// Source availability remains visible even though the card can open its
    /// metadata and notes before those source bytes arrive.
    ///
    /// `.localOnly` is not an error and does not wear one: its bytes are right
    /// here and readable, and the sentence exists to explain why the card is
    /// absent on the person's other device, not to ask them to repair anything.
    static func availabilityLabel(
        for availability: WorkboardMaterialAvailability
    ) -> LocalizedStringResource? {
        switch availability {
        case .available:
            return nil
        case .localOnly:
            return LocalizedStringResource(
                "workboard.material.localOnly",
                defaultValue: "Available on this device"
            )
        case .syncPending:
            return LocalizedStringResource("workboard.material.syncPending", defaultValue: "Waiting for iCloud…")
        case .unavailableOnThisDevice:
            return LocalizedStringResource(
                "workboard.material.reattach.short",
                defaultValue: "Reattach"
            )
        }
    }

    /// The glyph beside that sentence, and its tint. Kept here WITH the words
    /// so no surface can draw the repair symbol over the waiting sentence: a
    /// card waiting for iCloud is not a card asking to be repaired, and only
    /// `.unavailableOnThisDevice` is something the person can act on.
    static func availabilityGlyphName(
        for availability: WorkboardMaterialAvailability
    ) -> String {
        switch availability {
        case .localOnly: return "internaldrive"
        case .syncPending: return "icloud.and.arrow.down"
        case .available, .unavailableOnThisDevice: return "paperclip.badge.ellipsis"
        }
    }

    /// `@MainActor` because the palette is: the words and the glyph above stay
    /// reachable from anywhere, and only the colour needs the app's own tokens.
    @MainActor
    static func availabilityTint(
        for availability: WorkboardMaterialAvailability
    ) -> Color {
        switch availability {
        case .localOnly: return AppColors.brandTeal
        case .syncPending: return AppColors.textTertiary
        case .available, .unavailableOnThisDevice: return AppColors.warning
        }
    }

    // MARK: - Helpers

    /// Trimmed, or nil when there is nothing left. Every slot goes through it,
    /// so "absent" and "whitespace" are the same thing to every surface.
    static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

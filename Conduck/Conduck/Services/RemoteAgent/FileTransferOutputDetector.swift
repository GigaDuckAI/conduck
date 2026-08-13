// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileTransferOutputDetector.swift
//
// Reply-side half of the file-transfer feature: turns a landed agent reply into
// the server-reference `AttachmentDraft`s the thread renders as download chips.
// Its dispatch-side sibling is `BackgroundFileTransfer` (inbound uploads and the
// strict listing lane) and its transport is `FileServerClient`; the type doc
// below carries the full contract, including what a listing does and does not
// prove.

import Foundation

/// Output-file discovery for the file-transfer feature.
///
/// THE AUTOMATIC LANE READS ONE FOLDER, NEVER THE REPLY TEXT. Each dispatch
/// names a fresh per-turn box (`OutboxKey.mint`) on the wire and persists that
/// path with the reply, and discovery is a single `PROPFIND Depth: 1` of exactly
/// that box (`reconcileOutbox`). Nothing in the reply's prose can schedule a
/// request: a filename in the text is inert until the user asks for it.
///
/// WHY PROSE IS NOT A FILE-READ PRIMITIVE. The candidate regex cannot cross a
/// `/`, so a file delivered into `<conversationID>/out-<nonce>/` yields only its
/// bare leaf — which resolves at the served ROOT, where it either 404s or, worse,
/// matches an unrelated file the user happens to keep there. Automatic prose
/// probing therefore retained the whole harm surface (unattended GETs at the
/// user's own server, driven by attacker-influenceable text; chips for files
/// nobody produced this turn) while finding essentially nothing the box does not
/// already hold. It is gone from every automatic path.
///
/// WHAT MEMBERSHIP IN THE BOX PROVES, read this before trusting a chip. The box
/// is named by Conduck and created by the AGENT, and the same principal writes
/// the file and the reply. So membership proves FRESHNESS — nothing written
/// before this dispatch can be sitting in a path minted for it — and it proves
/// NAMESPACE, because the path is unguessable and per-turn. It does NOT prove
/// provenance, and it does not prove a write finished: a pathname can appear
/// before its last byte does, which is why `FileServerEntry.byteSize` is captured
/// at listing time and refreshed by the re-list rather than asserted at tap time.
///
/// AN EMPTY OR ABSENT BOX IS THE ORDINARY OUTCOME, NOT A FAULT. Most replies
/// produce no files, and nothing creates the folder in advance, so a `404` is
/// what a turn with no output looks like. It conflates "produced nothing", "the
/// instruction was ignored", "a mkdir failed", "the agent wrote elsewhere" and
/// "the served root is not the agent's workspace" — so it can never be reported
/// as a claim about what the agent did. Only `.unusable` (transport, non-`207`,
/// malformed body, a lane that answers everything) is a fault worth telling the
/// user about, because only that means the app learned nothing at all.
///
/// TARGET MEMBERSHIP: the app target only. The project uses a synchronized
/// file-system group, so a file under `Conduck/` joins the main target with no
/// `project.pbxproj` edit, and it stays OUT of the Watch target because the
/// Watch exception list is additive — which is correct here: the file-server
/// credential deliberately never syncs to the wrist, so the wrist can neither
/// list nor download.
///
/// CONSERVATIVE by design (false positives are worse than misses here):
///   - A listing is believed only through `BackgroundFileTransfer.listCollection`,
///     which requires a bounded, complete, well-formed `207` whose entries are
///     all direct children on a lane that demonstrated it can say no.
///   - Every entry name must survive `FileServerClient.validatedOutboxEntryName`,
///     which REJECTS rather than repairs and applies `outputAllowlist` as the
///     outbound type gate.
///   - Entries per reply are capped (`maxOutboxEntriesPerReply`) and a message's
///     lifetime chip count is capped (`maxOutputChipsPerMessage`), so a box
///     stuffed by a hostile gateway cannot fan out into unbounded chips.
///   - A pass that could not read the box, or that ran before the turn's age
///     gate opened, does NOT close the turn — see `outputScanGrace`,
///     `truncatedScanHorizon` and `scanMayClose`. Closing a turn is permanent,
///     so it is reserved for a pass that actually finished.
///
/// PREVIEWS ARE BUILT FROM BYTES THE USER ALREADY ASKED FOR. Nothing downloads
/// file content automatically. `previewPatchesForDownloadedFile` runs after the
/// user taps a chip and the real download has landed on disk, so the wrist gets
/// its thumbnail / text preview at zero extra network cost.
///
/// PRIVACY (see the spec's Privacy & Security section): never logs the reply
/// text, candidate filenames, storedKeys, entry names, or the snapshot. Returns
/// the structured drafts; no `print`/`os_log` anywhere in this path.
enum FileTransferOutputDetector {
    /// What one listing of one dispatch box established. The `verdict` rides
    /// alongside the drafts because the caller needs to tell three different
    /// things apart that all produce zero chips: a folder that is not there, a
    /// folder that is there and empty, and a server that could not be read. Only
    /// the last is a fault, and only the last may drive a user-visible row.
    struct OutboxReconciliation {
        let drafts: [AttachmentDraft]
        /// Whether this pass may PERMANENTLY stamp the turn scanned.
        let conclusive: Bool
        let verdict: FileServerListingVerdict
    }

    /// Curated set of output-file extensions Conduck is willing to address —
    /// document / data / archive / image / audio / code types an agent tool
    /// realistically WRITES. Lowercased for matching.
    ///
    /// IT IS THE OUTBOUND TYPE GATE. `FileServerClient.validatedOutboxEntryName`
    /// defaults to this set, so an entry in the box whose extension is not here
    /// is not delivered at all. That is what keeps a `.mobileconfig`, a live
    /// `.sqlite`, or an extensionless blob out of the lane even when the agent
    /// puts one in the folder it was given.
    ///
    /// It is ALSO the prose-noise filter for the manual search: the candidate
    /// regex enumerates every `<base>.<ext>` token in a reply, and this set is
    /// the only thing standing between ordinary sentences ("e.g.", "v1.1",
    /// "example.com") and a GET the user asked for.
    ///
    /// ADMITTED, and why:
    ///   - Audio (`m4a`/`mp3`/`wav`/`flac`/`ogg`/`aac`/`opus`) — a voice-first
    ///     product whose agents synthesise speech and clips needs a way to hand
    ///     one back. All are distinctive tails; none occur in prose.
    ///   - `ipynb` / `toml` — unambiguous artifact extensions with zero prose
    ///     shape. `ppt` keeps the symmetry `doc`/`xls` have with their modern
    ///     twins.
    ///   - `rtf` / `epub` — document deliverables a "write this up for me" turn
    ///     genuinely produces.
    ///   - `webp` — a modern raster output format; it also earns a thumbnail
    ///     (see `imagePreviewExtensions`).
    ///   - Languages (`go`/`rs`/`rb`/`kt`/`java`/`swift`/`cpp`/`hpp`/`css`/
    ///     `scss`/`tex`/`bat`/`ps1`, on top of `py`/`js`/`ts`/`sh`/`sql`) — the
    ///     showcase gateways are CODING agents, so source files are the modal
    ///     deliverable.
    ///
    /// REFUSED, and why:
    ///   - ONE-character tails (`c`, `h`, `r`, `m`) — the noise floor of ordinary
    ///     numbered prose ("section 4.c") swamps the signal in the manual search.
    ///   - `env` — the canonical `.env` cannot match the candidate regex anyway
    ///     (no base before the dot), and the artifact it would name is a secrets
    ///     file this app must never pull into the conversation store.
    ///   - `db` / `bin` / `dat` — generic and usually pre-existing.
    ///   - `sqlite` — legitimate but sensitive: delivering a live workspace
    ///     database is a worse mis-fire than delivering a stray document.
    ///   - Video (`mp4`/`mov`/`webm`) and config (`ini`/`cfg`/`conf`) — widening
    ///     handback to those artifact classes is a product decision, taken
    ///     deliberately or not at all.
    nonisolated static let outputAllowlist: Set<String> = [
        "pdf", "csv", "tsv", "json", "xml", "yaml", "yml", "toml", "txt", "md", "log",
        "zip", "tar", "gz", "png", "jpg", "jpeg", "gif", "svg", "webp",
        "xlsx", "xls", "docx", "doc", "pptx", "ppt", "html", "rtf", "epub",
        "m4a", "mp3", "wav", "flac", "ogg", "aac", "opus",
        "py", "js", "ts", "sh", "sql", "parquet", "ipynb",
        "go", "rs", "rb", "kt", "java", "swift", "cpp", "hpp", "css", "scss",
        "tex", "bat", "ps1"
    ]

    /// Maximum distinct candidates the MANUAL search probes per reply — a
    /// fan-out budget, so one tap on a chatty reply can't fire dozens of GETs at
    /// the user's home server. Applied AFTER the exclusion filters, so an echoed
    /// name can never displace a real output from the window.
    ///
    /// 10 rather than a handful: an honest coding reply routinely names the
    /// half-dozen files it touched BEFORE naming the deliverable, and a window a
    /// normal reply overflows is a window that loses real outputs. Ten sequential
    /// probes is still a bounded worst case, and `probeNamedCandidates` abandons
    /// the rest on the first lane-wide failure, so a dead server costs ONE probe.
    nonisolated static let maxCandidates = 10

    /// Lifetime ceiling on detector-minted chips for ONE message. Reached ⇒ the
    /// turn closes: nothing further can be added, so further examination cannot
    /// change the outcome.
    ///
    /// This is what makes "a truncated pass stays open" safe. Every pass drops
    /// the keys already chipped on the message before applying its own cap, so
    /// confirmed files make the window WALK FORWARD across passes. Without a
    /// ceiling, a box holding hundreds of entries could walk the whole list over
    /// repeated thread opens, minting unbounded chips.
    ///
    /// TWICE `maxCandidates`, deliberately: at parity the walk would be an
    /// illusion, because every chip that advances the window's head also shrinks
    /// the remaining allowance that sets its tail, pinning the far end at the
    /// same entry forever. A ceiling above the per-pass cap is what lets a long
    /// list actually be worked through.
    nonisolated static let maxOutputChipsPerMessage = maxCandidates * 2

    /// Maximum entries ONE listing of ONE dispatch box turns into chips.
    ///
    /// DERIVED FROM NEITHER CONSTANT ABOVE, and it sits BETWEEN them (10 < this
    /// < 20) because it answers a third question. `maxCandidates` bounds a
    /// fan-out of separate GETs over reply PROSE, where the population is "every
    /// filename-shaped token a model wrote". This bounds what ONE listing —
    /// already paid for, one request — may hand over from a folder minted for a
    /// SINGLE reply, where the honest population is the deliverables of one turn:
    /// a report, its data, maybe a chart. A box holding more than a dozen files
    /// is either a chatty agent using the folder as scratch space or a hostile
    /// one stuffing it, and neither is a reason to paste twenty rows under one
    /// bubble. So it is deliberately LARGER than the prose budget (a listing is
    /// cheap where ten probes are not) and deliberately SMALLER than the
    /// message's lifetime ceiling.
    ///
    /// UNDER `maxOutputChipsPerMessage`, which caps this lane too —
    /// `reconcileOutbox` spends the message's REMAINING lifetime allowance, so a
    /// per-pass cap at or above that ceiling would let one pass exhaust the whole
    /// allowance and make the walk below meaningless.
    ///
    /// Exceeding it does NOT lose the tail: the pass reports itself truncated, so
    /// the turn stays open on `truncatedScanHorizon` and later passes walk the
    /// window forward past the keys already chipped, up to the message's lifetime
    /// ceiling.
    nonisolated static let maxOutboxEntriesPerReply = 12

    /// How long after an agent turn was created a pass must wait before it may
    /// PERMANENTLY close that turn. Inside the window a pass still attaches
    /// whatever it finds — chips appear immediately — it just may not stamp the
    /// turn scanned, so a later pass re-lists.
    ///
    /// WHY A GRACE PERIOD AT ALL: the first listing fires within a beat of the
    /// agent's last token. A file that lands a second later — a tool that flushes
    /// after it answers, or an rclone VFS directory cache that has not settled —
    /// reads as a definitive empty box and would close the turn forever. This
    /// project's own connect-doctor still needs a five-second retry loop to avoid
    /// exactly that false negative even with `--dir-cache-time 1s` configured; a
    /// product that trusts ONE instant listing is trusting something its own
    /// tooling does not.
    ///
    /// WHY 60 SECONDS: an order of magnitude of headroom over that observed
    /// five-second settling, plus room for modest inter-device clock skew, while
    /// still being short enough that the one useful terminal retry is not
    /// deferred into irrelevance. Longer windows (minutes) only enlarge the
    /// pending set; a valid agent that publishes files minutes after replying
    /// needs an explicit completion protocol, not a bigger heuristic.
    ///
    /// AN ATTEMPT COUNT WOULD NOT DO: a second pass can fire milliseconds after
    /// the first (a notification tap, a foreground reload, another store event)
    /// and permanently repeat the same stale empty answer. Only wall-clock age
    /// separates "asked again" from "asked later".
    ///
    /// ANCHOR + SKEW: the deadline is measured from the turn's persisted
    /// `createdAt`, which every device sees identically after sync — no new
    /// field, no schema change. It is a wall clock, so a device whose clock runs
    /// BEHIND the author's simply waits longer (safe), and one running AHEAD by
    /// more than the window can close a turn early. Automatic time on Apple
    /// devices makes a minute of skew unusual.
    nonisolated static let outputScanGrace: TimeInterval = 60

    /// The same rule for a TRUNCATED pass — one where the box held more entries
    /// than `maxOutboxEntriesPerReply` allowed it to deliver.
    ///
    /// A truncated delivery is not a finished one: the pass never handed over the
    /// tail, so stamping the turn complete throws away whatever is there. It
    /// stays open far longer than an ordinary pass, and each later pass walks the
    /// window forward past the keys already chipped.
    ///
    /// WHY IT IS A HORIZON AND NOT "FOREVER": the window only advances when a
    /// chip is actually minted, so a box whose entries all fail the type gate
    /// would otherwise re-list on every thread open for the life of the
    /// conversation, learning nothing. One hour keeps the turn recoverable for as
    /// long as the user is plausibly still working in that thread, then lets it
    /// close.
    nonisolated static let truncatedScanHorizon: TimeInterval = 60 * 60

    /// True only while the ref still resolves to the exact lane captured by a
    /// dispatch/listing caller. The stable ID binds URL + credential across
    /// launches; the per-process signature additionally catches device-local
    /// pin changes during this run. Readiness/capability verdict changes do not
    /// repoint an already-dispatched file lane.
    static func configuredLaneStillMatches(
        ref: RemoteAgentRef,
        snapshot: SettingsManager.FileTransferSnapshot
    ) async -> Bool {
        guard let current = await SettingsManager.shared.fileTransferSnapshot(for: ref) else {
            return false
        }
        return current.durableLaneID == snapshot.durableLaneID
            && current.identitySignature == snapshot.identitySignature
    }

    // MARK: - The automatic lane: one listing of one box

    /// List ONE dispatch box and turn what is in it into this reply's output
    /// chips. THE whole automatic discovery path — one request (plus the
    /// listing's own negative control on a positive answer), no reply text read,
    /// no fan-out.
    ///
    /// `excludedKeys` is exactly the storedKeys already attached to the target
    /// message. Two jobs, and both are needed: it stops a re-list from minting a
    /// duplicate chip, and its COUNT is the message's chip census for
    /// `maxOutputChipsPerMessage`. Empty on a turn that carries no chips yet.
    ///
    /// `turnCreatedAt` is the persisted `createdAt` of the agent turn — the grace
    /// anchor (see `outputScanGrace`). `scanStartedAt` is captured by the caller
    /// BEFORE the listing and threaded through: a pass that began inside the
    /// grace window must stay pending no matter how long the request takes, or a
    /// slow listing could drift past the deadline and stamp the turn on the
    /// strength of an answer collected too early.
    ///
    /// `list` is injectable so the verdict ladder is unit-testable without a live
    /// file server; the default is the real strict listing lane.
    ///
    /// PRIVACY (see the spec's Privacy & Security section): never logs the
    /// collection key, entry names, storedKeys, or the snapshot.
    static func reconcileOutbox(
        outboxKey: String,
        snapshot: SettingsManager.FileTransferSnapshot,
        excludedKeys: Set<String>,
        turnCreatedAt: Date,
        scanStartedAt: Date = Date(),
        list: (SettingsManager.FileTransferSnapshot, String) async -> FileServerListingVerdict = {
            snapshot, collectionKey in
            await BackgroundFileTransfer.shared.listCollection(
                snapshot: snapshot, collectionKey: collectionKey)
        }
    ) async -> OutboxReconciliation {
        let verdict = await list(snapshot, outboxKey)
        // A pass may only deliver up to the message's REMAINING lifetime
        // allowance, so a walked window can never overshoot the ceiling.
        //
        // A message already AT its ceiling gets a budget of zero, and that is a
        // COMPLETE examination rather than a truncated one — no future pass could
        // add a chip either, so holding the turn open on the long horizon would
        // re-list a folder forever to learn the same nothing.
        let budget = max(0, min(maxOutboxEntriesPerReply, maxOutputChipsPerMessage - excludedKeys.count))
        var drafts: [AttachmentDraft] = []
        var truncated = false

        if case .entries(let entries) = verdict, budget > 0 {
            for entry in entries {
                // REJECT, never repair: a name Conduck is unwilling to address is
                // a file it does not deliver, because a "cleaned" name is a key
                // that no longer exists on the server.
                guard !entry.isDirectory,
                      let name = FileServerClient.validatedOutboxEntryName(entry.name) else {
                    continue
                }
                let storedKey = "\(outboxKey)/\(name)"
                // Already on the message — drop it BEFORE the cap, so a chip that
                // landed on an earlier pass cannot eat a slot and stall the walk.
                guard !excludedKeys.contains(storedKey) else { continue }
                guard drafts.count < budget else {
                    truncated = true
                    break
                }
                var draft = AttachmentDraft(
                    mimeType: mimeType(for: name),
                    filename: name,
                    data: Data(),
                    thumbnailData: nil,
                    width: 0,
                    height: 0,
                    byteSize: max(entry.byteSize, 0),
                    sequence: drafts.count
                )
                draft.isServerReference = true
                draft.storedKey = storedKey
                drafts.append(draft)
            }
        }

        return OutboxReconciliation(
            drafts: drafts,
            conclusive: scanMayClose(
                verdict: verdict,
                turnCreatedAt: turnCreatedAt,
                scanStartedAt: scanStartedAt,
                truncated: truncated
            ),
            verdict: verdict
        )
    }

    /// Whether a LISTING pass may permanently stamp `outputScanDone`, per the
    /// three-way verdict. Pure + content-free; `nonisolated` so the test target
    /// can call it off the main actor.
    ///
    /// `.unusable` never closes a turn — the app learned nothing, and a turn
    /// closed on no evidence is closed forever. `.absent` and `.entries` are both
    /// real answers about the folder, so they close on the age ladder exactly
    /// alike: a `404` is what an ordinary no-output turn looks like now that
    /// nothing creates the folder in advance, and treating it as a fault would
    /// make silence the loudest state in the product.
    nonisolated static func scanMayClose(
        verdict: FileServerListingVerdict,
        turnCreatedAt: Date,
        scanStartedAt: Date,
        truncated: Bool
    ) -> Bool {
        switch verdict {
        case .unusable:
            return false
        case .absent, .entries:
            return scanMayClose(
                turnCreatedAt: turnCreatedAt,
                scanStartedAt: scanStartedAt,
                everyProbeDefinitive: true,
                truncated: truncated
            )
        }
    }

    /// The AGE half of the close decision, shared by the listing lane and the
    /// manual probe lane. Pure + content-free; `nonisolated` so the test target
    /// can call it off the main actor.
    ///
    /// Two independent gates, both of which must open:
    ///   - EVIDENCE: the pass got a real answer. One transient outcome and it
    ///     learned nothing it can stand behind.
    ///   - AGE: the pass STARTED at or after the turn's deadline —
    ///     `createdAt + outputScanGrace`, or `+ truncatedScanHorizon` when the
    ///     pass could not deliver everything it saw.
    ///
    /// The age gate is deliberately measured from when the pass STARTED. A slow
    /// request can outlive the grace window on its own; reading the clock
    /// afterwards would let an answer from the first millisecond close a turn
    /// purely because the pass took a while.
    nonisolated static func scanMayClose(
        turnCreatedAt: Date,
        scanStartedAt: Date,
        everyProbeDefinitive: Bool,
        truncated: Bool
    ) -> Bool {
        guard everyProbeDefinitive else { return false }
        let horizon = truncated ? truncatedScanHorizon : outputScanGrace
        return scanStartedAt >= turnCreatedAt.addingTimeInterval(horizon)
    }

    // MARK: - The manual lane: names the reply mentioned, behind a tap

    /// Probe the filenames a reply MENTIONED, at the served root, on demand.
    ///
    /// TAP-GATED, AND THAT IS THE WHOLE DIFFERENCE. The same work ran
    /// automatically once and had to go: reply text is adversary-controlled, and
    /// a request the user did not ask for against the user's own home server is
    /// a cost they cannot see and did not choose. Behind an explicit per-turn
    /// tap it is a tail recovery — for the gateway that ignored the box, wrote to
    /// its workspace root, or named a file it had already produced.
    ///
    /// WEAKER PROVENANCE BY CONSTRUCTION. A draft from here carries the BARE
    /// name as its storedKey, so it can never begin with the reply's own
    /// `outputBoxKey + "/"`. The thread reads that prefix at render time and
    /// labels the chip as found on the file server rather than produced by this
    /// reply — no schema, no flag, no second field to keep in step.
    ///
    /// `excludedKeys` drops names the caller already knows about: the storedKeys
    /// on this message, and the conversation's own inbound uploads (the turn text
    /// hands the agent each uploaded file's stored name, so a reply that merely
    /// echoes one would otherwise chip the user's own upload back at them).
    ///
    /// FAIL-FAST ON THE FIRST LANE-WIDE FAILURE: `.unauthorized` / `.certRefused`
    /// / `.serverError` / `.unknown` are not key-specific. Firing the remaining
    /// probes at the same snapshot learns nothing and spends the user's home
    /// server (and, on a timeout, a budget each). `.ambiguous` is the one
    /// non-definitive outcome that does NOT stop the pass — see
    /// `probeFailureIsLaneWide`.
    ///
    /// PRIVACY (see the spec's Privacy & Security section): never logs the reply
    /// text, candidate filenames, storedKeys, or the snapshot.
    static func probeNamedCandidates(
        candidates: [String],
        snapshot: SettingsManager.FileTransferSnapshot,
        excludedKeys: Set<String>
    ) async -> (drafts: [AttachmentDraft], conclusive: Bool) {
        let window = Array(
            candidates
                .filter { !excludedKeys.contains($0) }
                .prefix(maxCandidates)
        )
        guard !window.isEmpty else { return ([], true) }

        var drafts: [AttachmentDraft] = []
        var everyProbeDefinitive = true
        for candidate in window {
            // Size-returning probe so the download chip can render the file size
            // and gate a soft-confirm on very large downloads. `byteLength` is
            // nil when the server omits a parseable length (→ byteSize 0 =
            // "unknown", chip shows no size + no gate).
            let (outcome, byteLength) = await BackgroundFileTransfer.shared.probeExistsWithLength(
                snapshot: snapshot,
                storedKey: candidate
            )
            guard probeIsConclusive(outcome) else {
                everyProbeDefinitive = false
                if probeFailureIsLaneWide(outcome) { break }
                continue
            }
            // Only a confirmed-present file chips; a mentioned-but-never-written
            // name (`.missing`) yields nothing.
            guard outcome == .exists else { continue }
            var draft = AttachmentDraft(
                mimeType: mimeType(for: candidate),
                filename: candidate,
                data: Data(),
                thumbnailData: nil,
                width: 0,
                height: 0,
                byteSize: byteLength.map(Int.init) ?? 0,   // Int64 → Int (64-bit on-device); 0 = unknown
                sequence: drafts.count
            )
            draft.isServerReference = true
            draft.storedKey = candidate
            drafts.append(draft)
        }
        return (drafts, everyProbeDefinitive)
    }

    /// Whether a single probe outcome is DEFINITIVE — a real present/absent
    /// verdict (`.exists` / `.missing`). Everything else is not: the pass
    /// learned nothing about the file. Pure + content-free; internal for the
    /// test target.
    ///
    /// `.certRefused` is non-definitive despite being TERMINAL for the attempt
    /// that produced it: the refusal says nothing about whether the file exists,
    /// and the user can fix the certificate.
    ///
    /// Definitiveness is a SEPARATE question from `probeFailureIsLaneWide`,
    /// which decides whether the rest of the window is still worth probing.
    static func probeIsConclusive(_ outcome: FileProbeOutcome) -> Bool {
        switch outcome {
        case .exists, .missing: return true
        case .unauthorized, .serverError, .certRefused, .ambiguous, .unknown: return false
        }
    }

    /// Whether a non-definitive outcome is a fact about the LANE rather than
    /// about the one key that produced it — i.e. whether the pass should stop.
    ///
    /// A wrong credential, an untrusted certificate, a server that is down, an
    /// endpoint that cannot answer sensibly: every remaining probe would meet
    /// the same wall, so firing them learns nothing and, on a timeout, spends
    /// the user's home server for each one.
    ///
    /// `.ambiguous` is the exception, and the reason this predicate is not just
    /// `!probeIsConclusive`. It means the lane answered fine and THIS key's
    /// answer was unusable — an HTML document under a `.pdf` name, a `206` whose
    /// body contradicts its own `Content-Range`. Treating that as lane-wide
    /// would let one unreadable filename starve every real deliverable named
    /// after it in the same reply.
    static func probeFailureIsLaneWide(_ outcome: FileProbeOutcome) -> Bool {
        switch outcome {
        case .ambiguous: return false
        case .exists, .missing, .unauthorized, .serverError, .certRefused, .unknown: return true
        }
    }

    /// Scan `reply` for filename-looking tokens (`<base>.<ext>`), keep only those
    /// whose lowercased extension is in `outputAllowlist`, dedup preserving first
    /// appearance. UNCAPPED — `probeNamedCandidates` applies `maxCandidates`
    /// AFTER its exclusions, so an echoed name never displaces a real output from
    /// the window. Pure + content-free (never logged). Internal (not private) for
    /// the test target.
    ///
    /// REACHED ONLY FROM A USER TAP. It is still bounded as if it were not,
    /// because a tap is not consent to burn a phone's CPU.
    ///
    /// COST — LOAD-BEARING (untrusted input): the pattern's `[A-Za-z0-9._-]+` is
    /// followed by a required `\.` that the class itself can match, so ICU
    /// backtracks O(n) per start position over O(n) start positions on a long
    /// unbroken run of those characters — quadratic (measured, `swiftc -O`
    /// arm64: 8 KB → 0.49 s, 16 KB → 1.95 s, 32 KB → 7.81 s, i.e. 4× input =
    /// 16× time). Reply text is adversary-controlled (a hostile gateway, or an
    /// honest agent prompt-injected by a page it read) and bounded only by the
    /// 16 MiB `Constants.maxBackgroundResponseBytes` transport ceiling.
    /// Moving it off the main actor (`extractCandidatesOffMainActor`, still
    /// required) only relocates that; `boundedRunInput` is what BOUNDS it, to
    /// linear (measured 2.2 s/MiB in its worst SURVIVING shape).
    ///
    /// The pattern itself and the UNCAPPED contract stay deliberately unchanged:
    /// a bounded quantifier would alter match EXTENT, and a truncated token
    /// becomes a storedKey whose probe returns `.missing` — i.e. it would report
    /// "not found" about a file that is there. Capping the input length would
    /// lose a filename mentioned past the cap the same way. The bound is on
    /// input SHAPE instead, which costs no real candidate at all — see
    /// `boundedRunInput`.
    ///
    /// `nonisolated` so the off-actor wrapper can reach it (the app module
    /// defaults declarations to `@MainActor`).
    nonisolated static func extractCandidates(from reply: String) -> [String] {
        // `name.ext` where name is a safe token and ext is 1–8 alnum chars. The
        // allowlist filter below is what actually defeats prose false-positives;
        // the regex just enumerates filename-shaped tokens.
        let pattern = "[A-Za-z0-9._-]+\\.[A-Za-z0-9]{1,8}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let scanned = boundedRunInput(reply)
        let range = NSRange(scanned.startIndex..<scanned.endIndex, in: scanned)

        var seen = Set<String>()
        var ordered: [String] = []
        for match in regex.matches(in: scanned, range: range) {
            guard let r = Range(match.range, in: scanned) else { continue }
            let token = String(scanned[r])
            guard let dot = token.lastIndex(of: ".") else { continue }
            let ext = token[token.index(after: dot)...].lowercased()
            guard outputAllowlist.contains(ext) else { continue }
            if seen.insert(token).inserted {
                ordered.append(token)
            }
        }
        return ordered
    }

    /// Longest run of `[A-Za-z0-9._-]` scalars `boundedRunInput` lets through.
    /// 255 is POSIX `NAME_MAX` — the byte ceiling on a filename on every server
    /// this app can talk to — so no run this bound drops could have held a
    /// storable name. That is what makes the bound free: it is not a guess at
    /// "how long a filename might be", it is the limit past which one cannot
    /// exist.
    nonisolated static let maxFilenameRunScalars = 255

    /// Replace every `[A-Za-z0-9._-]` run longer than `maxFilenameRunScalars`
    /// with a single space, leaving everything else byte-identical. Returns the
    /// input UNCHANGED (no copy) when no run is over budget — the case for every
    /// real reply, so real content pays one linear scan and nothing else.
    ///
    /// WHY this bound and not a length cap: the pattern's cost is quadratic in
    /// the length of ONE unbroken run, not in the reply, and a match can never
    /// span a run boundary (every character the pattern can match is in that
    /// class). Excising the over-long runs therefore turns the whole scan linear
    /// — measured `swiftc -O` arm64: 4 MiB of `a` + a real `report.pdf` goes
    /// from hours of backtracking to 0.008 s, and STILL returns `report.pdf`.
    ///
    /// WHY it loses nothing: a match starts at its run's start (the greedy `+`
    /// consumes to the run end, then backtracks to the last usable dot), so a
    /// name buried inside a longer run was never extractable in the first place
    /// — the token was the whole run. The only candidate an over-budget run can
    /// yield is therefore a >255-character token, which no file-server can hold
    /// and whose probe is a guaranteed `.missing`. A single space, not deletion,
    /// so two runs either side of an excision cannot fuse into a token that was
    /// never in the reply.
    ///
    /// RESIDUAL (accepted, and now LINEAR): a reply built entirely of maximal
    /// in-budget runs still costs ~2.2 s/MiB. Its input term is bounded at the
    /// transport layer by `Constants.maxBackgroundResponseBytes`, and this runs
    /// off the main actor, so the worst case is background CPU proportional to a
    /// body the peer already had to send — not the unbounded quadratic blow-up.
    ///
    /// Internal (not private) so the equivalence + cost contract is testable.
    nonisolated static func boundedRunInput(_ reply: String) -> String {
        func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }

        let scalars = reply.unicodeScalars
        // nil until the first over-budget run — the no-copy fast path.
        var excised: String?
        var copiedUpTo = scalars.startIndex
        var runStart = scalars.startIndex
        var runLength = 0

        func flushRun(endingAt runEnd: String.UnicodeScalarView.Index) {
            guard runLength > maxFilenameRunScalars else { return }
            if excised == nil { excised = "" }
            excised?.unicodeScalars.append(contentsOf: scalars[copiedUpTo..<runStart])
            excised?.unicodeScalars.append(" ")
            copiedUpTo = runEnd
        }

        var index = scalars.startIndex
        while index < scalars.endIndex {
            if isTokenScalar(scalars[index]) {
                if runLength == 0 { runStart = index }
                runLength += 1
            } else {
                flushRun(endingAt: index)
                runLength = 0
            }
            index = scalars.index(after: index)
        }
        flushRun(endingAt: scalars.endIndex)

        guard var excised else { return reply }
        excised.unicodeScalars.append(contentsOf: scalars[copiedUpTo...])
        return excised
    }

    /// `extractCandidates` on a detached executor — the ONE entry point every
    /// production caller uses. The manual-search caller is MainActor (module
    /// default), so calling the regex inline would freeze the UI for as long as
    /// the pattern took on a hostile reply. Detached (not merely `nonisolated`):
    /// a nonisolated sync function still executes on the caller's thread. Cheap
    /// to hop because the function is pure and content-free — it takes a `String`
    /// and returns tokens, touching no state.
    nonisolated static func extractCandidatesOffMainActor(from reply: String) async -> [String] {
        await Task.detached(priority: .utility) {
            extractCandidates(from: reply)
        }.value
    }

    /// Best-effort MIME type from a filename's extension; defaults to
    /// `application/octet-stream` (the agent's tools wrote the real bytes — this
    /// only labels the download chip).
    private static func mimeType(for filename: String) -> String {
        guard let dot = filename.lastIndex(of: ".") else { return "application/octet-stream" }
        switch filename[filename.index(after: dot)...].lowercased() {
        case "pdf": return "application/pdf"
        case "csv": return "text/csv"
        case "tsv": return "text/tab-separated-values"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/yaml"
        case "toml": return "application/toml"
        case "txt", "log": return "text/plain"
        case "md": return "text/markdown"
        case "html": return "text/html"
        case "rtf": return "application/rtf"
        case "epub": return "application/epub+zip"
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "m4a", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "xls": return "application/vnd.ms-excel"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc": return "application/msword"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "py": return "text/x-python"
        case "js": return "text/javascript"
        case "ts": return "application/typescript"
        case "sh": return "application/x-sh"
        case "bat": return "application/x-bat"
        case "ps1": return "application/x-powershell"
        case "sql": return "application/sql"
        case "parquet": return "application/vnd.apache.parquet"
        case "ipynb": return "application/x-ipynb+json"
        case "go": return "text/x-go"
        case "rs": return "text/x-rust"
        case "rb": return "text/x-ruby"
        case "kt": return "text/x-kotlin"
        case "java": return "text/x-java-source"
        case "swift": return "text/x-swift"
        case "cpp", "hpp": return "text/x-c++src"
        case "css": return "text/css"
        case "scss": return "text/x-scss"
        case "tex": return "application/x-tex"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Previews, built from bytes the user already asked for

    /// A `ConversationStore.applyPreviews` patch tuple. Aliased so the builder's
    /// signature and its call sites can't drift from the store's shape.
    typealias PreviewPatch = (messageID: UUID, storedKey: String, previewData: Data?, previewKind: String?, thumbnailData: Data?)

    /// SOURCE-read budget for one preview: the most bytes that may be read to
    /// produce it. Post-tap this bounds a local file read rather than a download,
    /// but the ceiling is the same one — an 8 MiB image is the largest thing
    /// worth decoding for a thumbnail either way.
    nonisolated static let perReplyPreviewSourceBudget: Int64 = 8 * 1024 * 1024   // 8 MiB
    /// STORED-preview budget: total preview/thumbnail bytes actually PERSISTED.
    /// Caps on-device growth — and, because previews sync, the user's iCloud.
    nonisolated static let perReplyPreviewStoredBudget = 512 * 1024               // 512 KiB
    /// Hard per-image SOURCE cap for the image lane (8 MiB): an image whose bytes
    /// exceed this is never read whole (the read bails at the cap and yields nil
    /// → the item is skipped).
    nonisolated static let imagePreviewSourceMaxBytes: Int64 = 8 * 1024 * 1024    // 8 MiB

    /// The IMAGE subset of `outputAllowlist` whose bytes ImageIO can raster-
    /// decode into a thumbnail — DERIVED by intersecting the allowlist, so it can
    /// never name an extension the lane wouldn't deliver (drop one from
    /// `outputAllowlist` and it drops here too). `svg` is in the allowlist but
    /// excluded: ImageIO cannot rasterize it, so reading one would burn the
    /// budget only to fail the decode. `webp` IS included — ImageIO has decoded
    /// it since long before this app's deployment floor.
    nonisolated static let imagePreviewExtensions: Set<String> =
        outputAllowlist.intersection(["png", "jpg", "jpeg", "gif", "webp"])

    /// Build first-writer preview patches for `drafts`, SEQUENTIALLY in draft
    /// order — no parallel reads. Pure orchestration over a supplied `fetch` +
    /// `ImageProcessor.thumbnailOnly`; never throws, never logs. Budgets are
    /// `inout` so a caller can thread ONE shared budget across a batch. Text lane
    /// → `previewData` + kind `"text"` (strict UTF-8); image lane →
    /// `thumbnailData` only. Any per-item failure (fetch nil, invalid UTF-8,
    /// decode fail, over a hard max, or a KNOWN byteSize already over the
    /// remaining budget) skips that item and continues to later (possibly
    /// smaller) items; an exhausted budget stops the batch.
    ///
    /// PRIVACY (see the spec's Privacy & Security section): never logs filenames, storedKeys, or bytes.
    ///
    /// `fetch` has NO default and that is deliberate: previews are built from
    /// bytes the user already asked for, so the caller has to say where the bytes
    /// come from. `(snapshot, storedKey, maxBytes) -> (data, received)` — the
    /// budget is charged `received` on EVERY attempt (over-cap bail included), so
    /// a source that ignores the cap still cannot blow past the ceiling.
    nonisolated static func buildPreviewPatches(
        for drafts: [AttachmentDraft],
        messageID: UUID,
        snapshot: SettingsManager.FileTransferSnapshot,
        sourceBudget: inout Int64,
        storedBudget: inout Int,
        fetch: (SettingsManager.FileTransferSnapshot, String, Int) async -> (data: Data?, received: Int64)
    ) async -> [PreviewPatch] {
        var patches: [PreviewPatch] = []

        for draft in drafts {
            // Budget exhausted → nothing more can be produced this batch.
            if sourceBudget <= 0 || storedBudget <= 0 { break }

            guard draft.isServerReference,
                  let storedKey = draft.storedKey,
                  let filename = draft.filename else { continue }
            // byteSize 0 == "unknown" (the source couldn't report a length) →
            // still eligible; the read cap protects. A KNOWN size is a pre-read
            // filter.
            let knownSize: Int64? = draft.byteSize > 0 ? Int64(draft.byteSize) : nil

            // --- TEXT LANE ---
            if AttachmentRecord.isPreviewableTextFilename(filename),
               knownSize == nil || knownSize! <= Int64(AttachmentRecord.watchViewableTextByteCeiling) {
                // Known-too-big-for-remaining-budget → skip WITHOUT reading, but
                // keep scanning for later smaller items.
                if let size = knownSize, size > sourceBudget || size > Int64(storedBudget) { continue }
                let cap = Int(min(Int64(AttachmentRecord.watchViewableTextByteCeiling), sourceBudget))
                guard cap > 0 else { continue }
                let (data, received) = await fetch(snapshot, storedKey, cap)
                sourceBudget -= received                      // charge bytes actually pulled, success OR over-cap bail
                guard let data else { continue }
                // Strict UTF-8 — reject binary/mislabelled or mid-codepoint-
                // truncated bytes rather than store an undecodable preview.
                guard String(data: data, encoding: .utf8) != nil else { continue }
                guard data.count <= storedBudget else { continue }
                storedBudget -= data.count
                patches.append((messageID, storedKey, data, "text", nil))
                continue
            }

            // --- IMAGE LANE ---
            if imagePreviewExtensions.contains(Self.fileExtension(of: filename)),
               knownSize == nil || knownSize! <= imagePreviewSourceMaxBytes {
                if let size = knownSize, size > sourceBudget { continue }
                let cap = Int(min(imagePreviewSourceMaxBytes, sourceBudget))
                guard cap > 0 else { continue }
                let (data, received) = await fetch(snapshot, storedKey, cap)
                sourceBudget -= received                      // charge bytes actually pulled, success OR over-cap bail
                guard let data else { continue }
                // Decode-as-validity: non-image bytes fail here → skip. Thumbnail
                // only (no wasted full-size decode); nil if over the 128 KiB max.
                guard let thumb = ImageProcessor.thumbnailOnly(from: data) else { continue }
                guard thumb.count <= storedBudget else { continue }
                storedBudget -= thumb.count
                patches.append((messageID, storedKey, nil, nil, thumb))
                continue
            }
        }
        return patches
    }

    /// Lowercased file extension of `filename` (empty when none). Local helper
    /// for the image lane — text eligibility uses `AttachmentRecord`'s own
    /// allowlist (`isPreviewableTextFilename`).
    nonisolated private static func fileExtension(of filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.index(before: filename.endIndex) else {
            return ""
        }
        return filename[filename.index(after: dot)...].lowercased()
    }

    /// Build this file's preview from a download the USER just asked for, at
    /// zero extra network cost.
    ///
    /// WHY IT LIVES HERE AND NOT ON THE LANDING PATH. A preview is a bounded
    /// slice of a file copied into the conversation store — i.e. into the user's
    /// own iCloud and onto their Watch. Producing it automatically meant every
    /// landed reply, and every CloudKit import echo behind it, pulled bytes off
    /// the user's home server for content nobody had opened. A tap on the chip is
    /// the moment the user asks for exactly those bytes, and the download has
    /// already put them on local disk — so the preview costs one bounded read of
    /// a file this device already holds.
    ///
    /// WHAT IT RESTORES: the wrist. `AttachmentRecord.watchDisplayClass` lands
    /// every previewless server file on `.serverPlaceholder`, and the Watch has
    /// no download capability by design — so without a preview an agent's output
    /// is a dead marker there forever. One tap on the phone or Mac is what makes
    /// it viewable on the watch. It applies to a file the USER sent too, for the
    /// same reason and at the same cost: that chip is a server reference as well,
    /// so it is equally dead on the wrist until someone opens it once.
    ///
    /// Reuses `buildPreviewPatches` verbatim with a LOCAL-FILE reader in place of
    /// the network fetch, so the eligibility rules, the strict-UTF-8 gate, the
    /// image decode and both budgets have exactly one definition.
    ///
    /// OFF THE CALLER'S ACTOR, ALWAYS — `Task.detached`, not merely
    /// `nonisolated`. The project builds with `SWIFT_APPROACHABLE_CONCURRENCY`,
    /// which turns on `NonisolatedNonsendingByDefault`: a `nonisolated async`
    /// function called from a MainActor caller RUNS on the main actor, and the
    /// only production caller is a SwiftUI chip's tap handler. Left inline, a
    /// 7 MiB PNG would do its file read plus a full ImageIO decode / downsize /
    /// re-encode on the main thread before Quick Look could appear — a visible
    /// freeze on an older device. Everything crossing the boundary is `Sendable`
    /// and the body touches no shared state, so the hop is free.
    ///
    /// THE `await` ON `.value` IS LOAD-BEARING, not incidental: the caller hands
    /// the file to Quick Look only after this returns, so a dismissal that
    /// reclaims the scratch file cannot race the read. Detaching must not become
    /// fire-and-forget.
    ///
    /// PRIVACY (see the spec's Privacy & Security section): never logs the path,
    /// filename, storedKey, or bytes.
    nonisolated static func previewPatchesForDownloadedFile(
        at url: URL,
        messageID: UUID,
        storedKey: String,
        filename: String,
        mimeType: String,
        snapshot: SettingsManager.FileTransferSnapshot
    ) async -> [PreviewPatch] {
        await Task.detached(priority: .utility) {
            // The real on-disk size, so the builder's "known size" filters apply
            // and an oversized file is skipped before a single byte is read. 0
            // means "unknown" to the builder, which is the safe degradation: the
            // read cap still bounds it.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let byteSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            var draft = AttachmentDraft(
                mimeType: mimeType,
                filename: filename,
                data: Data(),
                thumbnailData: nil,
                width: 0,
                height: 0,
                byteSize: byteSize,
                sequence: 0
            )
            draft.isServerReference = true
            draft.storedKey = storedKey

            var sourceBudget = perReplyPreviewSourceBudget
            var storedBudget = perReplyPreviewStoredBudget
            return await buildPreviewPatches(
                for: [draft],
                messageID: messageID,
                snapshot: snapshot,
                sourceBudget: &sourceBudget,
                storedBudget: &storedBudget,
                fetch: { _, _, maxBytes in
                    let data = boundedLocalPrefix(at: url, maxBytes: maxBytes)
                    return (data, Int64(data?.count ?? 0))
                }
            )
        }.value
    }

    /// The leading `maxBytes` of a local file, or nil when it cannot be read.
    /// `FileHandle` rather than `Data(contentsOf:)` so a multi-gigabyte download
    /// is never mapped or buffered whole just to look at its first 128 KiB.
    nonisolated private static func boundedLocalPrefix(at url: URL, maxBytes: Int) -> Data? {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }
}

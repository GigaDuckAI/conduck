// SPDX-License-Identifier: Apache-2.0

// Conduck
// MissingOutputNotice.swift
//
// The "a file was named but never arrived" diagnostic for the file-transfer
// route. `FileTransferOutputDetector` answers "which named files EXIST?"; this
// answers the strictly harder question "did this turn promise a file the served
// folder does not have?", which is what the user actually needs when handback
// fails. Silence is the expensive default for a BYO product whose variable is
// the USER'S OWN SETUP: an agent reply that names `poem.md` and delivers
// nothing, with no explanation anywhere in the app, is unactionable.
//
// PURE + DERIVED, never persisted. There is no schema field for "scanned and
// missing" and this deliberately does not add one — the verdict is recomputed
// from the reply text, the durable scan marker, the turn's chips, and the
// conversation's current lane. That means the notice DISAPPEARS by itself the
// moment any of those change (a chip lands, the lane is repointed, the file
// finally appears on a re-check) with no reconciliation step to get wrong.
//
// PRIVACY (see the spec's Privacy & Security section): pure and content-free —
// takes tokens and a record, returns a Bool. No `print`/`os_log` anywhere in
// this path; a filename, storedKey, URL or credential is never logged.
//
// THE MARKER SAYS LESS THAN IT LOOKS LIKE. `outputScanDone` records that some
// pass closed the turn — not which build's probe rules it ran under, and those
// rules widen over time. Every window this file reconstructs is therefore
// narrowed to the frozen `evidenceFloorAllowlist`, so a name only today's rules
// would have probed can never be reported as definitively absent.
//
// THE SAME GAP, ONE LEVEL DOWN. The marker is equally silent about the two
// EXCLUSION SETS the closing pass filtered its candidate list with: the turn's
// own stored keys and the conversation's inbound uploads. Those are DEVICE
// STATE rather than build constants, so they move for reasons no later
// reconstruction can see — `FileTransferOutputDetector.inboundStoredKeyTokens`
// yields an EMPTY set when its store fetch fails, and CloudKit mirrors a
// Message and its Attachment rows as separate records that arrive in any
// order. A set that was SMALLER at probe time means the pass faced a LONGER
// eligible list than the reconstruction does, and a longer list is one the cap
// may have cut. `isEvaluable` and `maximalUniverseOverflows` are what keep a
// difference in either set from turning into a claim.
//
// WHAT IS STILL OUT OF REACH, stated plainly because the gates below are not a
// soundness proof. A device can hold the marker while the records that justify
// it are still in flight — the inbound upload a candidate merely echoes, or the
// very chip the probe produced. Reconstruction can only read the state that HAS
// landed, so a turn whose evidence is still syncing reads as empty-handed here.
// Closing that needs evidence rather than reconstruction (a fresh definitive
// probe before the row speaks, or a notice that never outlives the process that
// gathered it) — a design change, not another gate.
//
// THE THING THIS MUST SURVIVE — filenames appear in ordinary prose constantly.
// The probe allowlist is tuned so that a WRONG candidate costs exactly one
// ranged GET that returns 404; nothing user-visible happens. A wrong NOTICE
// costs the user's trust in every future notice, so this filter is tuned on a
// different axis entirely: it is not "is this filename-shaped?" but "is this a
// DELIVERY CLAIM?". The four independent gates below are all conjunctive, and
// every one of them was chosen because it fails CLOSED (silence) on doubt.

import Foundation

enum MissingOutputNotice {

    // MARK: - Per-reply derivation

    /// Everything the notice needs from ONE reply's text, reduced to a bounded
    /// value so a view model can cache it instead of re-deriving on every
    /// reload echo. Bounded on purpose: `probedWindow` is at most
    /// `evidenceFloorMaxCandidates` entries and `standaloneClaims` is a subset
    /// of it, so a hostile 16 MiB reply naming a million distinct tokens cannot
    /// turn the cache into a memory leak.
    struct ReplyClaims: Equatable, Sendable {
        /// The candidate window EVERY build that could have closed this turn
        /// probed — today's `FileTransferOutputDetector.probePlan` intersected
        /// with the frozen `evidenceFloorPlan`. A token outside it is one some
        /// shipped build never asked the server about, so no marker that build
        /// wrote is evidence about it.
        let probedWindow: [String]
        /// More eligible candidates existed than the window could hold — under
        /// today's rules, the floor's, or the no-exclusions maximal universe
        /// either of them could have faced. The closing pass therefore may not
        /// have examined the whole reply.
        let truncated: Bool
        /// Window tokens that appear in the reply as a STANDALONE delivery
        /// claim — see `blockIsolatedClaimTokens`.
        let standaloneClaims: Set<String>

        /// The verdict for a reply this file declines to classify at all. Three
        /// independent reasons `shouldSurface` returns false, not one: an empty
        /// window, no claims, and `truncated`. Read `truncated` here as "the
        /// reconstruction cannot stand behind this reply" rather than
        /// specifically "a cap cut the list" — an unscannable reply may well
        /// have fit every cap. The strong value is the fail-closed one, and a
        /// consumer that treated `truncated == false` as proof of a complete
        /// examination would be reading a guarantee this type never made.
        static let unscannable = ReplyClaims(
            probedWindow: [], truncated: true, standaloneClaims: []
        )
    }

    /// Reduce one reply to its `ReplyClaims`. `candidates` is the already-paid
    /// `FileTransferOutputDetector.extractCandidates` output (never re-extract:
    /// that regex is the expensive, adversary-facing half).
    ///
    /// The window is the INTERSECTION of what today's rules would probe and
    /// what the frozen `evidenceFloorPlan` would — see `evidenceFloorAllowlist`
    /// for why a marker written by an unknown build can only support the
    /// narrower claim.
    ///
    /// `excludedKeys` is deliberately EMPTY rather than a parameter. The notice
    /// only ever evaluates turns where NO attachment carries a stored key (see
    /// `isEvaluable`) — the exact predicate production builds that set from —
    /// and a stored key is only ever ADDED to a turn, never removed, so the set
    /// the closing pass filtered with was empty too. That is also the condition
    /// under which the probe window is reconstructible at all: with nothing
    /// chipped, the window never "walked" across passes, so every pass —
    /// including the one that closed the turn — probed the same prefix of the
    /// same list, under whichever build's rules it ran, which is what the floor
    /// accounts for.
    ///
    /// `inboundTokens` gets no such guarantee, which is why the truncation
    /// verdict is taken from the MAXIMAL universe as well — see
    /// `maximalUniverseOverflows`.
    ///
    /// An oversized reply is refused outright — see
    /// `replyExceedsClaimScanCeiling`.
    nonisolated static func replyClaims(
        reply: String,
        candidates: [String],
        inboundTokens: Set<String>
    ) -> ReplyClaims {
        guard !replyExceedsClaimScanCeiling(reply) else { return .unscannable }
        let plan = FileTransferOutputDetector.probePlan(
            candidates: candidates,
            inboundTokens: inboundTokens,
            excludedKeys: []
        )
        let floor = evidenceFloorPlan(
            candidates: candidates,
            inboundTokens: inboundTokens
        )
        // Today's window ∩ the floor's, in today's order.
        let floorWindow = Set(floor.window)
        let window = plan.window.filter { floorWindow.contains($0) }
        return ReplyClaims(
            probedWindow: window,
            // Truncation from ANY of the four plans suppresses the turn
            // outright. `scanMayClose` lets a truncated pass close at the
            // horizon having seen only a prefix, so whichever build stamped
            // this marker — and whichever inbound set it believed in — one of
            // them stopped short of the reply's tail.
            truncated: plan.truncated
                || floor.truncated
                || maximalUniverseOverflows(candidates: candidates),
            standaloneClaims: blockIsolatedClaimTokens(
                in: reply,
                candidates: Set(window)
            )
        )
    }

    /// Whether `reply` is past the size at which this file refuses to classify
    /// it at all — `FileTransferOutputDetector.maxClaimOrderingReplyBytes`, the
    /// same ceiling every other production caller of the line scan already sits
    /// behind, applied here to the pure function so no caller can route around
    /// it.
    ///
    /// WHY THE NOTICE NEEDS THE CEILING MORE THAN THE ORDERING DOES, i.e. why
    /// this is a crash rather than a slow frame. Reply text is
    /// adversary-controlled up to the 16 MiB
    /// `Constants.maxBackgroundResponseBytes` transport ceiling, and a body of
    /// bare newlines splits into one array element per byte — tens of millions
    /// of `Substring` descriptors, hundreds of megabytes. The ordering caller
    /// pays that at most once per turn, while a probe is in flight. The notice
    /// pays it on EVERY open of the thread, because its derivation is a pure
    /// function of persisted text and its cache dies with the process. So the
    /// jetsam kill relaunches straight back into the same computation, and the
    /// marker that triggers it is CloudKit-synced — the loop follows the
    /// conversation onto every device the user owns.
    ///
    /// MEASURED BY WALKING, not by `utf8.count`. A `String` bridged from Core
    /// Data's `NSString` storage has no constant-time UTF-8 count, so asking a
    /// 16 MiB reply for its length is itself a full linear pass over the thing
    /// being avoided. The bounded walk stops one byte past the ceiling.
    ///
    /// Pure + content-free (never logged).
    nonisolated static func replyExceedsClaimScanCeiling(_ reply: String) -> Bool {
        let utf8 = reply.utf8
        return utf8.index(
            utf8.startIndex,
            offsetBy: FileTransferOutputDetector.maxClaimOrderingReplyBytes + 1,
            limitedBy: utf8.endIndex
        ) != nil
    }

    /// Whether either plan overflows its cap when NOTHING is excluded — the
    /// largest eligible list any pass over this reply could have faced.
    ///
    /// WHY THE INBOUND SET CANNOT BE TAKEN AT FACE VALUE. It is the one probe
    /// input that is neither a build constant nor derivable from the turn:
    /// `FileTransferOutputDetector.inboundStoredKeyTokens` returns an EMPTY set
    /// when its store fetch fails, and a device that already holds the marker
    /// may not yet hold the user turn whose upload contributed a token
    /// (`Message` and `Attachment` are separate CloudKit records and arrive in
    /// any order). So the closing pass may have filtered with FEWER exclusions
    /// than this reconstruction has, which means a LONGER eligible list — long
    /// enough to overflow the cap, close at `truncatedScanHorizon` having probed
    /// only a prefix, and never reach the reply's tail. Reconstruct that same
    /// turn against the fuller inbound set and the list now fits, `truncated`
    /// reads false, and `shouldSurface` — which refuses only TRUNCATED turns —
    /// lets a token nothing ever probed become a notice.
    ///
    /// The maximal universe is the bound that needs no such knowledge: no pass
    /// can have faced a longer list than the one with zero exclusions. If THAT
    /// fits, no pass was CUT — each probed everything it held eligible — so a
    /// window token can have gone unprobed only by being excluded outright,
    /// which is the separate limit this file's header states plainly. If it
    /// overflows, some pass may have stopped at a prefix, and truncation is the
    /// one condition this diagnostic refuses outright. The bound proves
    /// CAPACITY, not eligibility, and is written to be exactly that strong.
    ///
    /// REJECTED — reconstructing the inbound set the closing pass actually used.
    /// There is nothing to reconstruct it FROM: the marker carries no
    /// provenance and this feature adds no persisted field (see this file's
    /// header). Re-deriving it from today's messages is precisely the move that
    /// produces the divergence.
    ///
    /// THE COST: a reply whose raw name list overflows a cap ONLY because
    /// inbound echoes are being counted gets no notice — an agent that lists
    /// five uploaded filenames back before naming its own output goes quiet.
    /// Silence is the cheap direction, and detection is untouched.
    ///
    /// Pure + content-free (never logged); linear in the candidate count.
    nonisolated static func maximalUniverseOverflows(candidates: [String]) -> Bool {
        FileTransferOutputDetector.probePlan(
            candidates: candidates,
            inboundTokens: [],
            excludedKeys: []
        ).truncated
            || evidenceFloorPlan(candidates: candidates, inboundTokens: []).truncated
    }

    // MARK: - The evidence floor — what EVERY shipped build probed

    /// The extension allowlist of the earliest build whose closed turns can
    /// still reach this code, and the cap it probed under. Together they are
    /// the FLOOR: the window any build that could have stamped
    /// `outputScanDone` is guaranteed to have examined.
    ///
    /// WHY A FLOOR IS NEEDED AT ALL. The marker records that a pass CLOSED the
    /// turn. It does not record what that pass probed — and the probe rules are
    /// build constants that widen as the product learns which artifacts agents
    /// actually hand back (`FileTransferOutputDetector.outputAllowlist`,
    /// `maxCandidates`). Reconstruct the window with today's constants and
    /// every token a widening ADDED is reported as "probed, definitively
    /// absent" when nothing ever asked the server about it. That is not a
    /// stale notice, it is an invented one, and it appears retroactively on
    /// conversations the user has already read.
    ///
    /// WHY IT CANNOT BE DECIDED PER TURN. There is nothing to decide it WITH:
    /// recording the rules a pass ran under is a persisted field, and this
    /// feature adds none (see this file's header). A first-launch epoch in
    /// `UserDefaults` would not work either, because the fleet is MIXED — a Mac
    /// still on the older build closes a turn today and CloudKit syncs that
    /// marker to an updated iPhone, so no device-local date can classify a row
    /// it did not write. The reconstruction therefore has to be sound for every
    /// shipped build at once, and the intersection is exactly that.
    ///
    /// AN INTERSECTION, NOT "just use the old rules" — neither window contains
    /// the other. A reply naming ten `.go` files and then `k.md` gives today's
    /// build a window of the ten `.go` files (`k.md` truncated off the end) and
    /// the older build a window of exactly `k.md`. Only the intersection —
    /// empty, i.e. silence — is true of both.
    ///
    /// MAINTENANCE RULE, and it is the whole point of naming this a floor: it
    /// may only ever SHRINK. When the probe rules widen again, intersect this
    /// with the new rules; never re-point it at today's constants. The freeze
    /// covers every dimension of the plan that can change — extraction,
    /// normalisation, dedup order, exclusions, the cap, the truncation rule —
    /// not merely the two that happen to differ now. Extraction and ordering
    /// are shared with `FileTransferOutputDetector` only because they have
    /// never differed; the moment one of them does, its old form belongs here.
    ///
    /// THE COST, stated so it reads as a decision rather than an oversight: a
    /// notice can never cite a deliverable whose extension the floor lacks
    /// (audio, and the source types admitted alongside it), and a reply naming
    /// more than `evidenceFloorMaxCandidates` eligible files gets no notice at
    /// all. DETECTION IS UNTOUCHED — those files still chip normally; only the
    /// diagnostic goes quiet. That is the cheap direction: a missing notice
    /// costs one user one look at their own folder, a false one costs every
    /// future notice its credibility.
    nonisolated static let evidenceFloorAllowlist: Set<String> = [
        "pdf", "csv", "tsv", "json", "xml", "yaml", "yml", "txt", "md", "log",
        "zip", "tar", "gz", "png", "jpg", "jpeg", "gif", "svg",
        "xlsx", "xls", "docx", "doc", "pptx", "html",
        "py", "js", "ts", "sh", "sql", "parquet"
    ]

    /// The floor's per-pass cap. See `evidenceFloorAllowlist`.
    nonisolated static let evidenceFloorMaxCandidates = 5

    /// `FileTransferOutputDetector.probePlan` under the frozen rules. There is
    /// no `excludedKeys` counterpart because the notice only ever evaluates
    /// chip-free turns (see `isEvaluable`), and the message-lifetime chip
    /// ceiling that parameter feeds is therefore untouched too.
    ///
    /// Pure + content-free (never logged); linear in the candidate count.
    nonisolated static func evidenceFloorPlan(
        candidates: [String],
        inboundTokens: Set<String>
    ) -> (window: [String], truncated: Bool) {
        let eligible = candidates.filter { candidate in
            !inboundTokens.contains(candidate)
                && evidenceFloorAllowlist.contains(fileExtension(of: candidate))
        }
        return (
            Array(eligible.prefix(evidenceFloorMaxCandidates)),
            eligible.count > evidenceFloorMaxCandidates
        )
    }

    /// A candidate's lowercased extension, derived exactly as
    /// `FileTransferOutputDetector.extractCandidates` derives it — everything
    /// after the LAST dot — so the floor re-filters the same token the
    /// detector admitted. Every candidate carries one; that is what admitted
    /// it.
    nonisolated static func fileExtension(of candidate: String) -> String {
        guard let dot = candidate.lastIndex(of: ".") else { return "" }
        return candidate[candidate.index(after: dot)...].lowercased()
    }

    /// `replyClaims` on a detached executor — the entry point every production
    /// caller uses, for the same reason as
    /// `FileTransferOutputDetector.extractCandidatesOffMainActor`: the line
    /// scan is linear but the input is adversary-controlled and bounded only by
    /// the 16 MiB transport ceiling, and this runs over several replies on
    /// every thread open. Detached (not merely `nonisolated`) because a
    /// nonisolated sync function still executes on the caller's thread, and the
    /// caller here is the main actor.
    nonisolated static func replyClaimsOffMainActor(
        reply: String,
        candidates: [String],
        inboundTokens: Set<String>
    ) async -> ReplyClaims {
        await Task.detached(priority: .utility) {
            replyClaims(reply: reply, candidates: candidates, inboundTokens: inboundTokens)
        }.value
    }

    // MARK: - Gate 1 — the turn must be closed, owned, and empty-handed

    /// Whether a turn is even worth deriving a notice for. Cheap, record-only,
    /// no text work — the filter that keeps a refresh pass off nearly every
    /// message in a thread.
    ///
    ///   - AGENT role: only a reply can promise a file.
    ///   - `outputScanDone == true`: the scan CLOSED. Under the verdict model
    ///     in `FileTransferOutputDetector.scanMayClose` that is a strong claim,
    ///     and it is the whole reason this works with no schema change: a pass
    ///     may only stamp the marker when EVERY probe it attempted came back
    ///     definitive (`.exists`/`.missing` — never `.unauthorized`,
    ///     `.certRefused`, `.serverError`, `.ambiguous` or `.unknown`) AND it
    ///     started at or after the turn's age gate opened. So a closed turn is
    ///     never a transport failure, never an auth or certificate problem, and
    ///     never a response the app could not read. The fourth guarantee — never
    ///     a 404 the agent's write was a second away from disproving — comes
    ///     from the age half, and that half is NOT true of every marker this can
    ///     read; see THE AGE GATE IS NOT IN THE FLOOR below.
    ///   - `outputScanLaneID != nil`: the dispatch latched a READY file lane, so
    ///     `ConverseRequest.fileDeliveryInstruction` WAS spliced into that turn
    ///     — the agent was actually told to hand files back. A legacy or
    ///     ownerless row proves nothing about what the agent was asked to do.
    ///   - NO attachment carrying a stored key, and no server-file chip: if
    ///     anything at all was delivered this turn, the lane demonstrably
    ///     worked, and an extra filename in the prose is far more likely prose
    ///     than a broken handback.
    ///
    /// THE STORED-KEY HALF IS THE LOAD-BEARING ONE, and it is not the same test
    /// as the chip. Production builds its candidate-exclusion set from
    /// `attachments.compactMap(\.storedKey)` — EVERY key, whatever the
    /// server-reference flag says — and `FileTransferOutputDetector.probePlan`
    /// spends that set three ways: it drops those candidates, it shrinks the
    /// per-pass budget out of the message's remaining chip allowance, and at
    /// `maxOutputChipsPerMessage` it returns an EMPTY window and closes the turn
    /// having probed nothing at all. `replyClaims` reconstructs with an empty
    /// exclusion set, so ANY key the turn carries makes the reconstruction
    /// claim more than the pass examined. Matching production's predicate
    /// exactly is what keeps the two in step.
    ///
    /// The flag is still tested alongside it rather than replaced by it. The two
    /// fields sync independently (`AttachmentRecord.init(managedObject:)`
    /// nil-coalesces each on its own), so a partially-synced row can carry the
    /// server-reference flag with no key yet — a delivered output mid-flight,
    /// which must suppress the turn even though it contributes no exclusion.
    ///
    /// The zero-chip rule has a deliberate cost, stated here so it is a decision
    /// and not an accident: a turn that promised three files and delivered one
    /// says NOTHING about the other two. That is the conservative direction (a
    /// suppressed notice beats a wrong one), and it is also what makes the
    /// probe-window reconstruction in `replyClaims` exact.
    ///
    /// THE AGE GATE IS NOT IN THE FLOOR — a KNOWN, ACCEPTED residual class,
    /// written down here so the next reader recognises it as a decision instead
    /// of rediscovering it as a bug.
    ///
    /// `evidenceFloorAllowlist` freezes the WINDOW rules an unknown build
    /// probed under. It cannot freeze the CLOSING rules, and those moved too:
    /// the age gate in `FileTransferOutputDetector.scanMayClose` — a pass may
    /// only stamp the marker if it STARTED at or after `createdAt +
    /// outputScanGrace` — did not exist in the build whose allowlist the floor
    /// is copied from. That build could probe the instant a reply landed, get
    /// the 404 an agent's write was one second away from disproving, and stamp
    /// `outputScanDone` on it. Such a marker still satisfies every test above.
    ///
    /// WHY IT IS NOT CLOSED. Every classifier needs provenance the marker does
    /// not carry, and there is nowhere to put provenance:
    ///   - Recording the rules a pass ran under is a persisted field, and this
    ///     feature adds none (see this file's header).
    ///   - A first-launch epoch in `UserDefaults` cannot classify a row it did
    ///     not write. The fleet is MIXED: an older Mac closes a turn today and
    ///     CloudKit syncs that marker to an updated iPhone.
    ///   - A fixed `createdAt` cutover date is sound ONLY as a one-way deny
    ///     ("older than X ⇒ stay silent"). The converse does not follow — an
    ///     older build creates and instantly closes a NEW turn today — so a date
    ///     buys no provenance for anything after it while silencing the whole
    ///     existing history. It is the same unsound device-local reasoning in a
    ///     different hat, minus the honesty of admitting it.
    ///
    /// Closing it needs EVIDENCE rather than reconstruction — a fresh definitive
    /// probe before the row speaks — which is the design change this file's
    /// header already names as out of reach, not another gate.
    ///
    /// WHY IT IS TOLERABLE MEANWHILE, and this is the load-bearing half of the
    /// decision. The class needs all four of: a marker from a pre-age-gate
    /// build, a file that landed in the seconds AFTER that probe, no chip ever
    /// arriving since (any chip retires the row here), and the lane still
    /// pointing at the same server. The shipped copy claims no more than the
    /// evidence supports — it offers "still on its way" and "saved somewhere
    /// else" as live possibilities rather than asserting the agent failed — and
    /// "Check again" re-probes and retires the row in one tap, permanently, by
    /// inserting the chip that makes the turn ineligible forever after.
    nonisolated static func isEvaluable(_ message: MessageRecord) -> Bool {
        message.role == "agent"
            && message.outputScanDone == true
            && message.outputScanLaneID != nil
            && !message.attachments.contains { $0.isServerFile || $0.storedKey != nil }
    }

    // MARK: - Gate 2 — the reply must make a standalone delivery CLAIM

    /// Tokens from `candidates` that occupy a line of the reply BY THEMSELVES.
    ///
    /// This is the discriminator that makes the notice safe to show at all, and
    /// it is structural rather than linguistic on purpose — a verb list
    /// ("wrote", "saved", "created") would be English-only in a localized app,
    /// and a denylist of library names is whack-a-mole that loses to the next
    /// framework release. A filename mentioned IN PROSE always has other words
    /// on its line; a filename being HANDED OVER stands alone. That single
    /// property kills the entire false-positive class in one rule:
    ///
    ///   "Updated README.md and package.json; all tests pass."   → no line match
    ///   "This uses Node.js with Express.js and Chart.js."       → no line match
    ///   "I could not create report.pdf, the disk was full."     → no line match
    ///   "README.md lives in docs/."                             → no line match
    ///   "I reviewed report.pdf but made no changes."            → no line match
    ///
    /// while still catching the failure that motivated this: a reply whose
    /// entire content is `bowl_on_scale_poem.md` and nothing else.
    /// `ConverseRequest.fileDeliveryInstruction` asks for exactly this shape, so
    /// a compliant agent lands here by construction.
    ///
    /// NORMALISATION, and its limits. A line is stripped of one leading list
    /// marker (`-`/`*`/`+`/`1.`/`1)`), then of wrapping backticks and asterisks
    /// and trailing sentence punctuation, then compared for EQUALITY against the
    /// candidate set. Markdown HEADING markers (`#`) are deliberately NOT
    /// stripped: "## Node.js" is a section title, not a handover, and leaving
    /// `#` in place means a heading can never match.
    ///
    /// FENCED BLOCKS ARE SKIPPED. Text inside ``` or ~~~ is quoted material —
    /// a directory listing, command output, a file's contents — where bare
    /// filenames on their own lines are the NORM and mean nothing about
    /// delivery. An agent pasting `ls` output would otherwise produce a notice
    /// per line. Inline backticks are unaffected (and stripped above), which is
    /// the form agents actually use when naming a deliverable.
    ///
    /// Pure + content-free (never logged). Linear in the reply length.
    ///
    /// THE LOOSE READING, and the reason there are two. This one asks only
    /// "does the token occupy a SOURCE line by itself?" and is what
    /// `FileTransferOutputDetector.probeOrderedCandidates` orders a probe window
    /// with, where a wrong claim costs one ranged GET that returns 404 and the
    /// generous reading is the safe one — a promoted candidate that turns out to
    /// be prose has merely spent a request, while a demoted deliverable is a
    /// file that never arrives. `blockIsolatedClaimTokens` is the strict reading
    /// the notice uses, where the cost of a wrong claim runs the other way.
    nonisolated static func standaloneClaimTokens(
        in reply: String,
        candidates: Set<String>
    ) -> Set<String> {
        claimTokens(in: reply, candidates: candidates, requireBlockIsolation: false)
    }

    /// `standaloneClaimTokens` narrowed to tokens that RENDER on a line of
    /// their own. The reading the notice is derived from, and the asymmetry is
    /// deliberate: the ordering path pays one wasted request for a wrong claim,
    /// the notice pays the credibility of every notice after it.
    ///
    /// THE GAP IT CLOSES — a source line is not a rendered line. Agent replies
    /// render as Markdown (`AgentMarkdownBody`), where a single newline between
    /// two prose lines is a SOFT break. The reply
    ///
    ///     I reviewed
    ///     report.pdf
    ///     No file was created.
    ///
    /// is three source lines and ONE rendered paragraph — "I reviewed
    /// report.pdf No file was created." The line rule alone reads the middle
    /// line as a handover and announces a missing file the reply explicitly says
    /// was never written, on a screen where the user can plainly see it was
    /// prose. The unit therefore has to be the BLOCK — the run of lines between
    /// blank lines, fences and document edges, which is exactly where CommonMark
    /// ends a paragraph, so the app's structural test and the user's eyes agree.
    ///
    /// THE TEST IS "NOTHING BUT TOKENS", not "alone on its line". A block earns
    /// its claims only when EVERY line in it is a candidate — a manifest rather
    /// than a sentence:
    ///
    ///     report.pdf          ← claimed: the whole block is filenames
    ///     notes.md
    ///
    ///     I reviewed          ← claimed by nothing: the block holds prose,
    ///     report.pdf             so the filename inside it is prose too
    ///     No file was created.
    ///
    /// One prose line anywhere in the block silences the whole block, which is
    /// the fail-closed direction and also the honest one: a filename sharing a
    /// rendered paragraph with a sentence is being TALKED ABOUT.
    ///
    /// LIST ITEMS ARE EXEMPT because a list item renders on its own line by
    /// construction — `- a.pdf` above `- b.pdf` is two rendered lines with no
    /// blank between them, and a multi-file handover is written exactly that
    /// way. Requiring block company there would refuse the most common shape
    /// agents use for more than one deliverable. `ecosystemProseTokens` is the
    /// pass that catches the tech-stack bullet this admits.
    ///
    /// INDENTED CODE IS REFUSED. Four leading spaces (or a tab) open a
    /// CommonMark code block, so an indented bare line is quoted material for
    /// the same reason a fenced one is — an `ls` listing pasted with an indent
    /// instead of a fence would otherwise produce a notice per line.
    nonisolated static func blockIsolatedClaimTokens(
        in reply: String,
        candidates: Set<String>
    ) -> Set<String> {
        claimTokens(in: reply, candidates: candidates, requireBlockIsolation: true)
    }

    /// The one scan both readings share. `requireBlockIsolation` selects
    /// between them; everything else — terminators, fences, normalisation — is
    /// common, because a difference there would be a difference in what the two
    /// consumers believe a LINE is, and that is never the intended distinction.
    ///
    /// LINE TERMINATORS ARE THE UNICODE SET, not `\n`. Splitting on the line
    /// feed alone leaves the carriage return of a CRLF reply attached to every
    /// line, and `CharacterSet.whitespaces` is the Zs category plus tab — it
    /// does not contain U+000D. `report.pdf\r` therefore never equals the
    /// candidate `report.pdf`, and the whole rule silently does nothing for the
    /// many gateways that emit CRLF. Splitting on `Character.isNewline` (LF, VT,
    /// FF, CR, CRLF, NEL U+0085, LS U+2028, PS U+2029) makes the rule
    /// gateway-independent, which is the standing requirement that no behaviour
    /// branch on which backend produced a reply. CRLF is a single grapheme
    /// cluster in Swift, so it splits once rather than leaving an empty line
    /// between every pair.
    ///
    /// The trim stays `.whitespaces` rather than widening to
    /// `.whitespacesAndNewlines`: every terminator the split recognises is
    /// already gone, so the wider set could only add matches, and every added
    /// match is a possible added notice. Format controls (U+FEFF, U+200E,
    /// U+202A–U+202E) are deliberately neither split nor trimmed — they survive
    /// into the comparison and defeat the equality test, which is the safe
    /// direction.
    ///
    /// Pure + content-free (never logged). Linear in the reply length.
    nonisolated private static func claimTokens(
        in reply: String,
        candidates: Set<String>,
        requireBlockIsolation: Bool
    ) -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        // A line longer than the longest storable filename plus its wrappers can
        // never equal a candidate, so it is skipped before any allocation. 255
        // is POSIX `NAME_MAX` (see `FileTransferOutputDetector
        // .maxFilenameRunScalars`); the slack covers list markers and emphasis.
        let maxLineScalars = FileTransferOutputDetector.maxFilenameRunScalars + 16

        var found = Set<String>()
        var fence: (marker: Character, length: Int)?
        // The block currently being read: the bare tokens it holds, and whether
        // it holds ANYTHING ELSE. A block earns its claims only if it is made of
        // nothing but tokens, which is what makes it a manifest rather than a
        // sentence — see `blockIsolatedClaimTokens`. A SET, so a reply repeating
        // one filename on a million lines costs one entry rather than a million.
        var blockTokens = Set<String>()
        var blockIsTokensOnly = true

        func closeBlock() {
            if blockIsTokensOnly { found.formUnion(blockTokens) }
            blockTokens.removeAll(keepingCapacity: true)
            blockIsTokensOnly = true
        }

        for rawLine in reply.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if let run = fenceRun(trimmed) {
                // A fence closes only on its OWN marker at its own length or
                // longer. Toggling on any three-character run lets a ``` line
                // inside a ```` block end the fence early and expose the quoted
                // lines after it. A fence delimiter also interrupts a paragraph,
                // so it bounds the block on either side.
                if let open = fence {
                    if run.marker == open.marker, run.length >= open.length { fence = nil }
                } else {
                    fence = run
                }
                closeBlock()
                continue
            }
            guard fence == nil else { continue }
            if trimmed.isEmpty {
                closeBlock()
                continue
            }
            guard trimmed.count <= maxLineScalars else {
                blockIsTokensOnly = false
                continue
            }

            let (normalized, hadListMarker) = normalizedClaim(trimmed)
            guard requireBlockIsolation else {
                // The loose reading asks only about the SOURCE line.
                if candidates.contains(normalized) { found.insert(normalized) }
                continue
            }
            if hadListMarker {
                // A list item interrupts a paragraph and renders on its own
                // line, so it neither needs nor joins a surrounding block.
                closeBlock()
                if candidates.contains(normalized) { found.insert(normalized) }
            } else if candidates.contains(normalized), !isIndentedCode(rawLine) {
                blockTokens.insert(normalized)
            } else {
                blockIsTokensOnly = false
            }
        }
        // The document's end closes the last block.
        closeBlock()
        return found
    }

    /// The fence delimiter a line opens or closes with, if any. CommonMark needs
    /// at least three backticks or tildes; the RUN LENGTH is carried because a
    /// fence may only be closed by its own marker at its own length or longer.
    nonisolated private static func fenceRun(
        _ trimmed: String
    ) -> (marker: Character, length: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first }).count
        return run >= 3 ? (first, run) : nil
    }

    /// Whether a raw (untrimmed) line is indented far enough to be a CommonMark
    /// indented code block — four spaces, or one tab.
    nonisolated private static func isIndentedCode(_ rawLine: Substring) -> Bool {
        if rawLine.first == "\t" { return true }
        // Bounded on purpose: `rawLine.count` would walk a line padded with a
        // megabyte of leading spaces, which is exactly the shape this file
        // refuses to spend time on.
        let indent = rawLine.prefix(4)
        return indent.count == 4 && indent.allSatisfy { $0 == " " }
    }

    /// One whitespace-trimmed line reduced to the bare token it might be. See
    /// `standaloneClaimTokens` for what is stripped and what deliberately is
    /// not. Two wrapper/punctuation rounds so `` `report.pdf`. `` and
    /// `**report.pdf**.` both reduce; a third round can add nothing because the
    /// stripped sets are disjoint from the characters a candidate can end with.
    nonisolated static func normalizedClaimLine(_ line: String) -> String {
        normalizedClaim(line).token
    }

    /// `normalizedClaimLine` plus whether a list marker was what it stripped —
    /// the fact `blockIsolatedClaimTokens` needs to exempt list items from the
    /// blank-line test, since a list item already renders on its own line.
    nonisolated private static func normalizedClaim(
        _ line: String
    ) -> (token: String, hadListMarker: Bool) {
        var value = line[...]
        var hadListMarker = false

        // ONE leading list marker: "- ", "* ", "+ ", "1. ", "12) ".
        if let first = value.first {
            if first == "-" || first == "*" || first == "+" {
                let rest = value.dropFirst()
                if rest.first == " " || rest.first == "\t" {
                    value = rest.drop(while: { $0 == " " || $0 == "\t" })
                    hadListMarker = true
                }
            } else if first.isNumber {
                let digits = value.prefix(while: { $0.isNumber })
                let afterDigits = value.dropFirst(digits.count)
                if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" {
                    let rest = afterDigits.dropFirst()
                    if rest.first == " " || rest.first == "\t" {
                        value = rest.drop(while: { $0 == " " || $0 == "\t" })
                        hadListMarker = true
                    }
                }
            }
        }

        var result = String(value)
        for _ in 0..<2 {
            result = result.trimmingCharacters(in: Self.sentencePunctuation)
            result = result.trimmingCharacters(in: Self.emphasisWrappers)
        }
        return (result, hadListMarker)
    }

    /// Trailing prose punctuation an agent puts AFTER a filename. `.` is in the
    /// set even though it is also the extension separator: a candidate always
    /// carries a non-empty extension after its last dot, so trimming a trailing
    /// dot can never eat one.
    ///
    /// `?` is NOT in the set. A line reading `report.pdf?` is a question about a
    /// file, and normalising the question mark away turns it into a delivery
    /// claim — the one direction this filter must never move in. `!` stays,
    /// because an emphatic handover ("report.pdf!") is a real shape and a
    /// question mark is the only punctuation that changes the mood of the line.
    nonisolated private static let sentencePunctuation = CharacterSet(charactersIn: ".,;:!")
    /// Markdown code/emphasis wrappers. `_` is NOT included — it is a perfectly
    /// ordinary filename character, and stripping it would mangle `_config.md`
    /// into a token that matches nothing (i.e. it would fail closed, but for the
    /// wrong reason).
    nonisolated private static let emphasisWrappers = CharacterSet(charactersIn: "`*")

    // MARK: - Gate 3 — ecosystem names that survive the line rule

    /// Product and framework names that are filename-shaped and DO plausibly
    /// occupy a line alone — as a bullet in a tech-stack list ("- Node.js") or a
    /// de-marked heading. The line rule already removes the overwhelming
    /// majority of prose collisions; this is the short, honest tail.
    ///
    /// Lowercased for matching. Kept deliberately small: a denylist is a losing
    /// strategy as a PRIMARY filter (the next framework ships tomorrow), but it
    /// is cheap and correct as a last pass over a set the structural rule has
    /// already reduced to a handful of tokens.
    nonisolated static let ecosystemProseTokens: Set<String> = [
        "node.js", "next.js", "nuxt.js", "vue.js", "react.js", "three.js",
        "chart.js", "d3.js", "express.js", "nest.js", "ember.js", "backbone.js",
        "alpine.js", "moment.js", "angular.js", "jquery.js", "p5.js", "socket.js",
        "discord.js", "video.js", "vue.ts", "node.ts"
    ]

    // MARK: - The verdict

    /// Whether to surface the "named but not delivered" notice for this turn.
    /// Pure; `nonisolated` so the test target can call it off the main actor.
    ///
    /// `currentLaneID` is the conversation's CURRENTLY configured ready file
    /// lane. Requiring an exact match with the turn's `outputScanLaneID` is what
    /// stops a notice describing a server that is no longer in play: after the
    /// user removes or repoints their file server, the old turn's verdict says
    /// nothing about the setup they now have, and a stale warning about a
    /// deleted lane is worse than silence.
    ///
    /// The truncation guard is not defensive padding — it closes a real hole.
    /// `scanMayClose` lets a TRUNCATED pass close at `truncatedScanHorizon`
    /// having probed only a prefix of the eligible candidates, so the tail of a
    /// long list carries a definitive-looking marker over evidence that was
    /// never gathered. A truncated turn therefore gets no notice at all, and
    /// `claims.truncated` is true when today's rules, the frozen floor, or the
    /// no-exclusions maximal universe would have cut the list — see
    /// `evidenceFloorAllowlist` and `maximalUniverseOverflows`.
    nonisolated static func shouldSurface(
        message: MessageRecord,
        currentLaneID: String?,
        claims: ReplyClaims
    ) -> Bool {
        guard isEvaluable(message),
              let laneID = message.outputScanLaneID,
              let currentLaneID,
              laneID == currentLaneID,
              !claims.truncated,
              !claims.probedWindow.isEmpty else {
            return false
        }
        let probed = Set(claims.probedWindow)
        return claims.standaloneClaims.contains { token in
            probed.contains(token)
                && !ecosystemProseTokens.contains(token.lowercased())
        }
    }
}

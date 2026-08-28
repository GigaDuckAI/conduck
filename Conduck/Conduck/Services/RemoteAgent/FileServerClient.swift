// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileServerClient.swift
//
// Agent File Transfer. PURE request-builders + response-parsers + a
// staged "Test Connection" for the user-run file-server (rclone serve webdav
// over HTTPS, exposed via Tailscale Serve / Cloudflare Tunnel). The device is
// a thin CLIENT: it PUTs file bytes to the server ROOT as `<storedKey>`, GETs
// them back, probes existence with a GET (NEVER a HEAD — see below), DELETEs
// orphans, MKCOLs collections, and lists ONE exact collection with PROPFIND.
// Conduck ships NO server binary — we are a pure WebDAV client, and standing
// up the server is the user's job (Quick connect via `conduck-connect`, or
// the setup guide's manual steps).
//
// Mirrors the split in `RemoteAgentClient` / `RemoteAgentClient+TestConnection`:
//   - The `build*Request(...)` helpers are pure URL/header assembly so the
//     wire SHAPE is unit-testable without a network round-trip
//     (`FileServerClientTests`). They do NOT carry the cert-pinning delegate —
//     that lives on the `URLSession` the caller hands the request to
//     (`BackgroundFileTransfer` for transfers, the ephemeral session built
//     here for the staged test).
//   - THE TRUST-READING RULE, and it is a rule rather than a roster because a
//     roster goes stale the first time a lane is added: EVERY lane that builds
//     its own cert-pinned session AND turns the answer into something the user
//     reads MUST read that session's `AttemptTrustSignals` back. A trust refusal
//     that goes unread degrades to "host is down", which is the one misreading
//     this taxonomy exists to prevent — so audit every such lane, never only the
//     one you came for.
//     Four of them live in this file — `runConnectionTest(...)` (the staged
//     test), `probeReachability(...)`, `probeFolderCapability(...)` and
//     `probeListingCapability(...)` — each
//     built through the single `makeProbeSession(...)` recipe, which clones the
//     ephemeral 15 s cert-pinned `URLSession` pattern from
//     `RemoteAgentClient+TestConnection.swift` so the `RemoteAgentTrustEvaluator`
//     SPKI-pinning delegate is installed for THAT probe only, never on
//     `URLSession.shared`. Two more live on `BackgroundFileTransfer`'s own
//     ephemeral session and take its evaluator explicitly: the existence probe
//     (`probeExistsWithLength`) and the strict directory listing
//     (`listCollection`). The pure halves of both — `classifyProbe`,
//     `parseListing` — live here.
//     ONE LANE IS EXEMPT, AND THE EXEMPTION IS NARROWER THAN "IT SAYS NOTHING".
//     The pre-dispatch absence assertion
//     (`BackgroundFileTransfer.witnessCollectionAbsent`) runs on the same pinned
//     session and does not read an evaluator back. Its answer IS user-visible:
//     it becomes an `OutboxMintOutcome`, and two of those draw the thread's
//     folder-less row. So the exemption cannot rest on there being no claim — it
//     rests on WHAT the claim is permitted to say. That row is written to name
//     NO cause at all, because the turns it covers are selected from a LANE-WIDE
//     failure streak that any answer short of a definite miss can open, so the
//     row is drawn where that turn's cause is not in hand (`ConversationThreadView`'s
//     unnamed-folder row; `UnnamedFolderRowCopyTests` locks the copy against
//     naming one). End to end, a refused certificate therefore presents as: this
//     turn carried no folder, check your file server — with the lane charged the
//     one-observation `.unreachable` patience, which is the right patience for a
//     refusal no retry on this device can get past. There is no branch a trust
//     verdict could steer and no sentence it could correct, so reading the
//     evaluator here would add a parameter nothing consults, and an unread
//     parameter is how a rule stops being enforced. The place the user reads the
//     CAUSE is the staged test, which does read its evaluator and names the
//     certificate outright.
//     `ensureCollection` / `performMkcol` / `ensureFreshCollection` take the
//     CALLER's session and report a status only, so the caller that owns the
//     session owns the trust reading for them. NOTHING calls
//     `ensureFreshCollection` on the dispatch path — the per-dispatch output box
//     is NAMED by Conduck and CREATED by the agent (see `OutboxKey`), because a
//     client-created directory belongs to whoever the WebDAV lane runs as and
//     the agent usually is not that user.
//
// Why GET-never-HEAD for existence: a read-only HEAD/GET 200 on a
// gateway that exposes a Control-UI HTML page false-positives existence; rclone
// serve webdav answers GET on a real file with the bytes (200/206) and 404 on a
// missing one, so a GET is the only reliable existence signal. The staged test
// goes further (reachability → auth → write → read → delete → list) precisely because
// a bare read-only 200 is not trustworthy on its own.
//
// AND A GET IS ONLY THE PRECONDITION — NO VERDICT COMES FROM A STATUS ALONE.
// Choosing GET buys the ability to read a body; reading it is the actual rule
// (see the spec's networking invariants). An SSO portal parked in front of a
// file server answers EVERY path with its login page at 200, so a status-only
// existence check mints a convincing download chip for a file that was never
// written, and tapping it hands the user an HTML login page named `report.pdf`.
// Every positive existence verdict in this file is therefore backed by evidence
// the wall cannot manufacture:
//   - `classifyProbe` (the per-file existence probe) reads range semantics,
//     content type, and a BOUNDED body prefix, and on the one status a wall can
//     imitate — a bare `200` — demands the lane first DEMONSTRATE it can say
//     "no" (`negativeControlKey` / `negativeControlProvesNotFound`).
//   - `runConnectionTest`'s read stage and `probeFolderCapability` each require
//     an EXACT byte-echo of bytes they just wrote, which is strictly stronger.
// `probeStatusPrefilter` is a status map, and its name says so: it is legal only
// where one of those byte-echoes decides immediately after it.
//
// THE DIRECTORY LISTING IS THE SAME PROBLEM IN A DIFFERENT SHAPE, and it is the
// one path with nothing downstream to correct it: a name that survives the
// listing becomes a download chip, so the listing IS the authority on what an
// agent produced. `parseListing` therefore fails closed on everything that is
// not a bounded, complete, well-formed `207` naming direct children of the exact
// collection that was asked for, and its caller (`BackgroundFileTransfer
// .listCollection`) requires the lane to DEMONSTRATE a definite miss on a
// sibling collection that cannot exist before any entry is believed. THAT
// DEFINITE MISS IS THE ONE DEFINITION THIS APP HOLDS — `classifyAbsenceWitness`
// over the same status AND the same bounded body the pre-dispatch witness reads
// (`negativeControlProvesNotFound`'s body-aware form). A weaker rule here would
// refuse the listings of exactly the hosts the witness has just cleared to name
// a folder: the agent writes its files into a folder Conduck named, every reply
// resolves `.unusable`, and no chip ever appears. Three
// verdicts, never conflated: entries (the folder was read), absent (the folder
// is not there), unusable (nothing was learned). An empty listing is a FACT
// about a folder that was read, so it can only be reached through every one of
// those gates — a malformed body, a non-`207`, or a lane that cannot say no is
// `.unusable`, never an empty folder.
//
// THE ABSENCE WITNESS READS A `207` BODY FOR THE OPPOSITE VERDICT, and it is the
// one place in this file where taking the server at its word is safe.
// `classifyAbsenceWitness` answers `.absent` only on an unambiguous "not there":
// a `404` status line, or a `207` whose BOUNDED, strict, single-`<response>`
// multistatus is about the exact collection that was asked for and carries a
// response-level `404`/`410`. That inner-status shape is what a compliant host
// sends for a `PROPFIND` of a collection that does not exist, and a large real
// population sends it, so a status-only reading condemns those servers forever.
// Everything else keeps `.occupied`: an over-cap or truncated body, a document
// that does not parse, a row about some other href, more than one row, an inner
// `2xx`, an inner status nobody can read.
//
// WHY BELIEVING THAT NEGATIVE IS SAFE while every positive above demands a
// control: `.absent` is a NEGATIVE claim and it mints nothing. A wrong one costs
// exactly one thing — Conduck names an output folder that already exists — and
// no chip, no download and no file follow from it. Nothing downstream inherits
// it either: `BackgroundFileTransfer.listCollection` still runs its OWN negative
// control, against a fresh sibling that cannot exist, before a single entry is
// believed. What that control demands is the thing the wall this whole file is
// built against cannot produce — not a status but a per-request document naming
// the exact collection that was asked for and saying it is not there — so an SSO
// portal that answers every path with one login page cannot pass it. The
// residual is the one stated at `negativeControlProvesNotFound`: a deliberately
// hostile server can say anything, and the answer to a hostile server is the
// staged test's write-then-byte-echo against a server the user owns, never a
// control.
//
// Privacy invariants (see docs/ai-context/spec.md): the storedKey, the base
// URL, the basic-auth credential, and filenames are NEVER logged, printed, or
// echoed into a thrown `AppError`. The credential appears ONLY in the
// `Authorization` header on the request object and (separately) in the setup
// guide's masked credential row the user deliberately copies. Thrown errors are
// taxonomy codes only.

import Foundation

/// Outcome of a single existence probe (GET, never HEAD) against a stored file.
/// The states the output-download path and the orphan/retry checks care about;
/// anything the evidence cannot settle collapses to `.unknown` so callers fail
/// closed rather than guess. Produced by `classifyProbe`, which reads the
/// response BODY — never by a status on its own.
enum FileProbeOutcome: Equatable, Sendable {
    /// File is present. NEVER on a status, and never on this response alone: the
    /// server must also have DEMONSTRATED, on a random key that cannot exist,
    /// that it is capable of answering "not found". See `classifyProbe`.
    case exists
    /// File is absent (HTTP 404).
    case missing
    /// Auth rejected (HTTP 401 / 403) — credential wrong or server reconfigured.
    case unauthorized
    /// Server-side fault (HTTP 5xx) — transient, the caller may retry.
    case serverError
    /// This device refused the server's certificate — an untrusted chain, a
    /// pinned key that disagreed with a chain it DID trust, or a key algorithm
    /// Conduck cannot fingerprint. Never `.missing`: a refusal is evidence about
    /// the connection, never about the file, so a caller that acts on absence
    /// must not act on this.
    ///
    /// Distinct from `.unknown` because the two answer different questions.
    /// `.unknown` says "this attempt learned nothing"; this says "this attempt
    /// learned nothing AND no further attempt will, until something outside the
    /// app changes". Only the evaluator's own verdicts can tell them apart —
    /// every refusal arrives as the same bare `-999` a benign cancellation does.
    case certRefused
    /// The server answered ABOUT THIS KEY and the answer proves nothing: a body
    /// that contradicts its own `Content-Range`, an HTML document served under a
    /// name that is not HTML, a `416` that does not describe an empty file, a
    /// response that came back from a differently-named resource.
    ///
    /// Its own case, not `.unknown`, because the two have opposite SCOPES and
    /// therefore opposite instructions. `.unknown` is lane-wide — the tunnel is
    /// down, the credential is wrong, the endpoint answers nothing sensibly — so
    /// firing the remaining probes at the same server learns nothing and the
    /// pass abandons the turn. This one says the lane is FINE and this one
    /// candidate's answer was not usable, so the pass keeps going: the next
    /// filename in the same reply may be a real deliverable, and collapsing the
    /// two would let one unreadable name starve every file behind it.
    ///
    /// Non-definitive either way: the turn stays open for a later pass.
    case ambiguous
    /// Any other status (3xx redirect, 4xx other, transport-mapped) — fail
    /// closed, and LANE-WIDE (see `.ambiguous`).
    case unknown
}

/// Everything ONE existence probe learned off the wire, reduced to a pure value
/// so `classifyProbe`'s rules are unit-testable without a network. Collected by
/// `BackgroundFileTransfer.collectProbeEvidence`, which is the half that owns
/// the bounded read.
///
/// PRIVACY (see docs/ai-context/spec.md): this value carries the
/// storedKey and up to `Constants.fileServerProbeBodySniffBytes` of file
/// content, so it is a LOCAL value only — never logged, never thrown, never
/// stored, and never folded into an `AppError`. Everything downstream of
/// `classifyProbe` is an enum case.
struct FileProbeEvidence: Equatable, Sendable {
    /// Status of the FINAL response (`URLSession` follows redirects for us).
    let status: Int
    /// `Content-Range` verbatim, or nil when absent.
    let contentRange: String?
    /// `Content-Length` verbatim, or nil when absent.
    let contentLength: String?
    /// `Content-Type` verbatim, or nil when absent.
    let contentType: String?
    /// `Content-Encoding` verbatim, or nil when absent. The probe ASKS for
    /// `identity`; an intermediary that ignores that and compresses anyway makes
    /// every byte count in this value describe encoded bytes while `URLSession`
    /// hands us decoded ones, so both the range arithmetic and the size are void.
    let contentEncoding: String?
    /// Leading body bytes, capped at `Constants.fileServerProbeBodySniffBytes`.
    let bodyPrefix: Data
    /// Bytes actually pulled off the wire before EOF or the cap — the honest
    /// count, which is why the probe asks for `Accept-Encoding: identity`
    /// (transparent decompression would make "the server sent one byte"
    /// unverifiable).
    let deliveredBytes: Int64
    /// The body ran PAST the sniff cap and the client cancelled the task. On a
    /// `206` that is a contradiction — the server promised one byte and streamed
    /// a file — and the verdict refuses it.
    let bodyExceededSniffCap: Bool
    /// Last path component of the URL the response actually came from,
    /// percent-decoded, or nil when the response carried no URL.
    let finalPathComponent: String?
    /// The storedKey this probe asked for.
    let requestedKey: String
}

/// What `classifyProbe` can conclude from ONE response.
///
/// Note what the second case is NOT: it is not "the odd case that needs a bit
/// more". EVERY positive existence verdict lands there, because no single
/// response can establish that the file we NAMED is the file we were served.
/// A response's headers describe the representation the server SELECTED, not
/// how it chose it — so an ordinary `try_files $uri /index.html` SPA fallback
/// answers a range request for a `report.pdf` that does not exist with a
/// textbook `206` + `Content-Range: bytes 0-0/N`, entirely internally, with no
/// redirect the client can see. Range machinery proves the server has range
/// machinery. It proves nothing about routing.
///
/// The discriminator is therefore never in the response at all — it is whether
/// this namespace is CAPABLE of saying no.
enum FileProbeVerdict: Equatable, Sendable {
    /// Settled by this response alone — every NEGATIVE and every failure.
    /// `byteLength` is always nil here; a size only accompanies existence.
    case settled(FileProbeOutcome, byteLength: Int64?)
    /// This response is consistent with the file existing, and may become
    /// `.exists` only once the negative control comes back 404
    /// (`negativeControlKey` → `negativeControlProvesNotFound`). Otherwise
    /// `.unknown` — a server that cannot say no has told us nothing.
    case needsNegativeControl(byteLength: Int64?)
}

/// Outcome of the NON-MUTATING reach+auth probe (`probeReachability`) — a single
/// ranged GET of a key that cannot exist on the server. DISTINCT from
/// `FileProbeOutcome` because the semantics are inverted: here a `404` is the GOOD
/// case (the server answered our not-found probe PAST the auth gate), and a `200`
/// is SUSPICIOUS (a Control-UI / SSO page that 200s everything). Never certifies
/// that uploads work — only the staged write test (`runConnectionTest`) does.
enum FileReachabilityOutcome: Equatable, Sendable {
    /// `404` — the host answered a GET for an impossible key with a clean
    /// "not found" past the auth gate. Reach + auth APPEAR OK. Residual limit
    /// (why the label says "appears"): a server that 404s BEFORE auth, or an
    /// authenticated 404 on a wrong base path, can false-pass — the write test
    /// is the only certification.
    case reachAuthOK
    /// `401` / `403` — the basic-auth credential was rejected.
    case authFailed
    /// `200` / `206` / `416` / `3xx` — the host answered, but with a status a real
    /// WebDAV file-not-found probe should never give (a Control-UI page, a
    /// `Range`-rejecting server, or a redirect-to-login). Reachable, but sign-in
    /// can't be confirmed — flag, don't green.
    case suspicious
    /// `405` / `501` / any other `4xx`/`5xx` — the host answered but
    /// inconclusively. FAIL CLOSED (NOT `authFailed` — a `405` is
    /// "method/endpoint", not "bad credential").
    case inconclusive
    /// Transport failure (DNS / timeout / refused / a transient handshake
    /// hiccup) — the host was not reachable at all.
    case unreachable
    /// The host answered the TLS handshake and this device REFUSED its
    /// certificate. Split from `.unreachable` because the two carry opposite
    /// instructions: unreachable sends the user to check the server is running,
    /// which is exactly wrong here — it is running, and the fix is to give it a
    /// certificate this device trusts.
    case certUntrusted
    /// The host presented a certificate this device DOES trust, and the
    /// configured pin disagreed with its key. Its own outcome because it is the
    /// only one that means the connection may be intercepted: folding it into
    /// `.unreachable` threw that signal away and told the user to check whether
    /// their file server was running, and folding it into `.certUntrusted` would
    /// send them to obtain a certificate they already have.
    case certMismatch
    /// The host presented a certificate this device DOES trust, and Conduck
    /// could not compute a digest for its key algorithm, so the configured pin
    /// was never compared. Its own outcome for the same reason `.certMismatch`
    /// is: sharing that case would tell a user with a valid certificate their
    /// connection may be intercepted, and sharing `.certUntrusted` would send
    /// them to replace a certificate the device already accepts.
    case certKeyUnpinnable
    /// iOS refused the request from the URL STRING before any connect — a plain
    /// `http` address it does not consider local. Its own outcome for the same
    /// reason the three certificate ones are: the host was never contacted, so
    /// `.unreachable`'s "check your file server is running" points at a machine
    /// that had no chance to answer, and the remedy is the address.
    case insecureBlocked
}

/// One entry from a PROPFIND `Depth: 1` directory listing.
///
/// `byteSize` stays `Int` (not the probe path's `Int64`) because it is carried
/// straight into `AttachmentRecord.byteSize`, which is `Int`: widening here
/// would only move the one narrowing conversion a hop further from the
/// filesystem constraint it describes. `Int` is 64-bit on every platform this
/// app ships to, so nothing is lost.
struct FileServerEntry: Equatable, Sendable {
    /// Last path component of the entry's `<D:href>` (the stored name).
    let name: String
    /// Whether the entry is a collection (`<D:collection/>` resource type).
    let isDirectory: Bool
    /// `<D:getcontentlength>` in bytes, or 0 when absent (directories, or a
    /// server that omits the property).
    let byteSize: Int
}

/// WHICH KIND of shape guard refused a name — a CLASS, never an instance.
///
/// It exists because one sentence was being asked to cover nine guards, and it
/// was false for the two commonest of them. An agent that derives a filename
/// from a section heading writes a long, ordinary, perfectly printable name; an
/// agent that assembles one from a template writes a stray trailing space.
/// Telling either author that the name "could be read as an instruction, or
/// hides itself from a listing" describes an attack that did not happen, and
/// telling them "there's nothing to review" ends a conversation they could have
/// won by asking for a shorter name, or for the same name without the space.
///
/// IT CARRIES NOTHING FROM THE LISTING — no name, no bytes, not even a measured
/// length. Every case is a constant, so the whole population of values this type
/// can ever hold is written here in this file, and a caller that renders one is
/// rendering text this file chose. That is what keeps the shape arm displayable
/// while `.refusedShape` itself stays a bare count of anonymous entries: the
/// class is Conduck's word, the name is the server's.
///
/// THREE CASES, AND THE SPLIT IS BY WHAT THE USER CAN DO ABOUT IT rather than
/// by guard. `.overlong` is a budget the agent can be asked to stay inside and
/// `.whitespaceBounded` is a stray character it can be asked to drop — both are
/// requests an agent can act on, and between them they are the refusals an
/// HONEST agent actually earns. Everything else is a property of the name the
/// user cannot negotiate away and would not want to, so it stays one residual.
/// Splitting that residual further would multiply sentences without adding a
/// decision — and every extra class is another string that has to stay true.
nonisolated enum OutboxShapeRefusal: Equatable, Sendable {
    /// The name overran `storedKeyComponentMaxCharacters` or
    /// `storedKeyComponentMaxBytes`. THE BENIGN ONE, and the reason this type
    /// exists: nothing about such a name is hostile or hidden, it is simply
    /// longer than the lane carries, which is the one shape refusal a user can
    /// act on ("ask for a shorter name").
    ///
    /// It means the length was the FIRST thing wrong, not the only one — the
    /// length guard runs first, deliberately, so that every scan after it is
    /// bounded by a budget rather than by whatever the server sent. A name that
    /// is both overlong and otherwise unusable therefore lands here, and the
    /// sentence it earns ("the name is too long") is still true of it.
    case overlong
    /// The name opens or closes on a space. THE OTHER BENIGN ONE, and the second
    /// commonest refusal after length: only U+0020 survives the scalar alphabet
    /// (`outboxEntryScalarIsAddressable`), so this is never an exotic separator
    /// smuggled in — it is an agent writing `report.pdf ` with a stray trailing
    /// space, and "ask for the name without the space" is as actionable as "ask
    /// for a shorter name".
    ///
    /// It is split from `.unusable` for exactly the reason `.overlong` is: the
    /// residual's sentence has to cover names that read as an instruction or
    /// hide themselves from a listing, and that sentence is FALSE of a trailing
    /// space — it accuses an honest agent of an attack it did not attempt.
    ///
    /// The REFUSAL itself does not soften, only the sentence: the display half
    /// trims and collapses whitespace runs while the stored key keeps them
    /// verbatim, so a trimmed name addresses a file that is not on the server.
    case whitespaceBounded
    /// Every other shape guard: empty, a path separator, an unaddressable
    /// scalar, a leading combining mark, `.`/`..`, or a leading dot or dash. THE
    /// RESIDUAL, on purpose — these guards refuse names for reasons the user
    /// cannot fix by asking differently, and a row that enumerated them would
    /// trade a true generic sentence for seven specific ones nobody can act on.
    case unusable
}

/// What one entry name from a listing established — CLASSIFIED, because the
/// answers below are different sentences to the user and a bare optional makes
/// them one silence.
///
/// THE ONE THING THE CASES DIFFER ON IS WHETHER A NAME MAY BE SHOWN, and the
/// split is a consequence of guard ORDER rather than a judgement call. The type
/// test is the LAST guard in `outboxEntryVerdict`, so reaching it proves every
/// shape and addressability guard already passed: the name is a single path
/// component inside both filesystem budgets, built only of addressable graphic
/// scalars, carrying no rejected literal, not opening or closing on whitespace,
/// not opening on a combining mark, not hidden and not dash-led. That is exactly
/// the property a DELIVERED chip's label rests on, so a type refusal may carry
/// its name into the UI on the same terms — which is what gives the user
/// something honest to decide about.
///
/// A SHAPE refusal carries NO NAME AND NO BYTES, and that is not caution for its
/// own sake: the name failed one of the guards that make a name printable, so
/// printing it is the one thing that must not happen. Its payload is a
/// `OutboxShapeRefusal` — a closed set of three constants, holding nothing from
/// the listing — so there is still no field for a later caller to reach into and
/// render, and the rule stays structural rather than a convention someone
/// downstream has to remember.
///
/// `.refusedUntyped` is split from `.refusedExtension` because the sentences
/// diverge: one names a type Conduck will not open by itself, the other says
/// Conduck could not read a type at all. Folding them would force the second to
/// borrow the first's wording, and the borrowed sentence would be false for
/// `README` and misleading for a tail that merely FOLDS onto an allowlisted one
/// (`payload.\u{212A}t` renders as "payload.Kt" — see `outboxEntryExtension`).
///
/// `nonisolated` so the prose-scan lane, which runs off the main actor, can
/// switch on it and compare it (`FileTransferOutputDetector.extractCandidates`);
/// without it the synthesized `==` is `@MainActor` and every off-actor equality
/// breaks. `Sendable` for the same reason; `Equatable` so a test can name the
/// case it expects rather than assert a bare nil.
nonisolated enum OutboxEntryVerdict: Equatable, Sendable {
    /// Deliverable. The payload is the name BYTE-IDENTICAL to the listing's —
    /// never repaired, because a repaired name addresses a file that is not
    /// there.
    case deliverable(String)
    /// Every shape guard passed; the extension is ASCII, readable, and not on
    /// `allowedExtensions`. `ext` is already lowercased ASCII alphanumeric, so a
    /// consumer classifying it further needs no folding of its own and the set
    /// it compares against must be all-lowercase.
    case refusedExtension(name: String, ext: String)
    /// Every shape guard passed; the name carries no ASCII extension to judge —
    /// extensionless, an empty tail, or a tail that is not ASCII alphanumeric
    /// before any case folding. UNKNOWN TYPE, never "no type": it is why nothing
    /// downstream may assert what this file is.
    case refusedUntyped(name: String)
    /// A shape guard refused. NO NAME: nothing about this string has been
    /// established, so nothing about it may be rendered. The payload names the
    /// CLASS of guard and carries nothing from the listing — see
    /// `OutboxShapeRefusal`.
    case refusedShape(OutboxShapeRefusal)
}

/// Why a directory listing could not be believed. EVERY case means the same
/// thing to the caller — the app learned nothing about what the agent produced,
/// so the turn stays open, AND THE LANE IS CHARGED FOR IT — and they are kept
/// apart because they name different server faults and a test that cannot tell
/// them apart cannot prove the parser fails closed for the RIGHT reason.
///
/// A DEVICE THAT NEVER ASKED IS DELIBERATELY NOT IN THIS TYPE. An offline phone
/// and a cancellation of our own author no server fault, so they have no honest
/// spelling among these cases — and a case added here would inherit the "charge
/// the lane" half of the contract above from every existing `.unusable` arm
/// without one of them failing to compile. They live one level up, as
/// `FileServerListingVerdict.noObservation`, exactly so that the difference has
/// to be stated at each site that decides it.
///
/// No case carries a filename, a key, a URL, or a body: a refusal is a taxonomy
/// value, and the privacy invariants at the top of this file apply to it.
enum FileTransferListingRefusal: Equatable, Sendable {
    /// The request produced no HTTP response from a server that was reached for
    /// (DNS, timeout, refused, a peer-side reset). Nothing about the folder was
    /// learned, and the lane is charged: contrast
    /// `FileServerListingVerdict.noObservation`, which is this device failing to
    /// ask at all.
    case transport
    /// This device refused the server's certificate. Split from `.transport`
    /// for the reason `FileProbeOutcome.certRefused` is split from `.unknown`:
    /// the remedy is a certificate, not a retry, and folding the two tells the
    /// user their file server is down when it is answering.
    case certificateRefused(FileServerClient.CertificateRefusal)
    /// `401` / `403` — the credential was rejected, or a rule covers the whole
    /// namespace.
    case unauthorized
    /// `5xx` — the server is sick. Transient; the caller may re-list.
    case serverError
    /// Any other non-`207` status. A `200` lands here and MUST: a Control-UI /
    /// SSO wall answers every path with its own HTML at `200`, and the whole
    /// point of requiring `207` is that a wall cannot manufacture one.
    case notMultiStatus
    /// The `207` body is not a complete, well-formed `DAV: multistatus`
    /// document, or one of its `<response>` elements could not be understood in
    /// full. Partial understanding is refused rather than truncated, because a
    /// truncated listing is indistinguishable from a real short one.
    case malformedBody
    /// The body ran past `FileServerClient.listingMaxBytes`.
    case bodyTooLarge
    /// The body named more than `FileServerClient.listingMaxEntries` resources.
    /// Refused rather than truncated: an outbox holding more than the cap is not
    /// one reply's output, and a silently truncated listing looks complete.
    case tooManyEntries
    /// An `<href>` did not resolve to a direct child of the collection that was
    /// asked for, on the same origin — a foreign host, a grandchild, a parent
    /// escape, or a name whose percent-encoding hides a path separator.
    case entryOutsideCollection
    /// Two entries claimed the same name. Impossible in one real collection, so
    /// the body is describing something other than a directory.
    case duplicateEntry
    /// The lane failed its negative control: a sibling collection that cannot
    /// exist was answered with something other than a definite miss, so this
    /// server's answer about the real collection carries no information.
    case namespaceAnswersEverything
}

/// What ONE PROPFIND of ONE collection established. THE FOUR CASES ARE NEVER
/// CONFLATED, and that is the whole contract:
///
///   - `.entries` — the folder was READ. An empty array is a positive fact
///     ("this folder holds nothing right now"), reachable only through a
///     bounded, complete, well-formed `207` whose entries are all direct
///     children, on a lane that demonstrated it can say no.
///   - `.absent` — the folder is NOT THERE (`404`). Says nothing about the
///     server's health; says everything about the folder Conduck minted.
///   - `.unusable` — nothing was learned ABOUT A SERVER THAT WAS ASKED. The
///     caller must not close the turn, and the lane is charged for it.
///   - `.noObservation` — the request never really asked: the DEVICE had no
///     network path, or our own task cancelled it. Split from `.unusable` for
///     the reason `FileServerAbsenceWitness.noObservation` is split from
///     `.unreachable` — it is evidence about this device, not about the lane,
///     so it charges the breaker NOTHING and draws no row. Folding it into
///     `.unusable` is the bug this case exists to make impossible: every
///     existing `case .unusable` arm would absorb it silently, and a phone with
///     no radio would go on accusing a file server that is answering fine.
///
/// Collapsing any two of them is the failure this type exists to prevent: an
/// unreadable server reading as "the agent produced nothing" closes a turn on
/// evidence nobody has, and a device that never asked reading as an unreadable
/// server backs off a lane that was never at fault.
///
/// `.noObservation` is the one case `parseListing` can never return — a status
/// line proves a request was made and answered.
enum FileServerListingVerdict: Equatable, Sendable {
    case entries([FileServerEntry])
    case absent
    case unusable(FileTransferListingRefusal)
    case noObservation
}

/// What ONE `PROPFIND Depth: 0` of the folder a dispatch is about to name
/// established. Four cases, and the split between the last three is the whole
/// reason this is not a Bool:
///
///   - `.absent` — the server said the folder is not there, so naming it on the
///     wire is safe. Two shapes qualify and nothing else does: a `404` status
///     line, and a `207` whose inner response for that exact collection is a
///     `404`/`410` (the compliant multistatus form of the same sentence).
///   - `.cannotAnswer` — the server named `PROPFIND` as a method it will not
///     perform on this resource (`405`/`501`). WHAT IT PROVES DEPENDS ENTIRELY
///     ON WHAT WAS ASKED, which is why no caller may read it as a permanent
///     property on its own. Asked of a collection that CERTAINLY EXISTS — the
///     served root, which only the staged test probes — it is the structural
///     refusal that makes a lane upload-only, and nothing the user can do to
///     their network changes it. Asked of a collection that certainly does NOT
///     exist — which is every per-dispatch witness, by construction — it is a
///     fact about the route a missing path is served by (a path-scoped
///     `dav_methods` rule, a WAF, an SSO layer, a rewrite) on a server that may
///     list existing collections perfectly. Only the first caller may conclude
///     an incapability from it; see `probeListingCapability`'s two steps, which
///     draw exactly that line.
///   - `.occupied` — the server answered about the folder and did NOT say it is
///     missing. A collision, a namespace that answers everything, or an answer
///     nobody could read: a `207` whose body is over-cap, truncated,
///     unparseable, about another href, or carrying an inner `2xx` all land
///     here, because only an unambiguous inner not-found may be read as absence
///     and everything short of it fails closed. Either way the folder cannot
///     vouch for what is found in it later.
///
///     IT IS THE ONE FAILING ANSWER A LANE CAN GIVE FOREVER. The path carries
///     `OutboxKey.nonceHexCharacters` of fresh entropy and the next turn mints a
///     different name, so a STREAK of this is not bad luck — it is a lane
///     proving it will occupy every name Conduck can ever mint. `mintOutboxKey`
///     reads a streak of it as a capability limit and goes quiet; see the
///     process-local breaker at the foot of `BackgroundFileTransfer`.
///   - `.indeterminate` — the server ANSWERED, with something that settles
///     nothing: a rejected credential, a `5xx`, a redirect, a portal. THE
///     ACTIONABLE CASE — something that used to work stopped.
///   - `.unreachable` — no HTTP response arrived at all (DNS, refused, TLS,
///     timeout). Also actionable, and split from `.indeterminate` because it
///     is the SIGNATURE of this product's commonest file-lane failure: these
///     URLs are frequently cloudflared quick tunnels whose hostname rotates on
///     every restart, so a stale URL resolves to nothing. It is what lets the
///     witness back off after ONE observation instead of three (a host that is
///     simply not there will not be there next turn either), while a server
///     that is answering keeps its benefit of the doubt.
///   - `.noObservation` — the request never really asked: the DEVICE had no
///     network path, or our own dispatch task cancelled it (the user's Stop).
///     Split from `.unreachable` because it is evidence about this device, not
///     about the lane — an offline phone says nothing about whether the file
///     server is there, and a fault the user's own tap caused is not a fault
///     of their server. The breaker charges it NOTHING: recording it as
///     `.unreachable` opened a cooldown that suppressed the folder on the very
///     retry the user sent once their connection came back.
///
/// Carries no status, no URL, and no key: it is a taxonomy value, and the
/// privacy invariants at the top of this file apply to it.
///
/// `.unreachable` and `.noObservation` are the two cases
/// `classifyAbsenceWitness(status:)` can never return — each describes the
/// absence of a status line, not a status. `.absent`
/// is the one case that form UNDER-reports: a compliant `207` whose inner
/// response is the `404` that was asked for reads as `.occupied` from the status
/// line alone, and only the body-aware overload can see it for what it is. Every
/// production caller uses the overload.
enum FileServerAbsenceWitness: Equatable, Sendable {
    case absent
    case cannotAnswer
    case occupied
    case indeterminate
    case unreachable
    case noObservation
}

/// The stages of the staged Test Connection, in order. `Int` raw value =
/// stage ordinal so the Settings UI can render a determinate per-stage
/// result list and `FileTransferTestResult.reachedStage` can report how far the
/// probe got before a failure (or `.listing` on a full pass).
///
/// Note: the probe also runs two steps that are NOT user-facing stages — a
/// best-effort DELETE cleanup of the tiny probe file, and the nested-write
/// capability probe — because neither can fail the test: an orphaned 12-byte
/// probe file is harmless on the user's own server, and a lane that refuses
/// nested PUTs works fine on flat keys. The listing stage IS user-facing,
/// because there is no fallback behind it.
enum FileTransferTestStage: Int, Equatable, Sendable, CaseIterable {
    /// TCP/TLS reachability — can we open a connection to the file-server host
    /// at all (DNS resolves, cert validates / pins, port answers)?
    case reachability
    /// Auth — does the basic-auth credential get past the server's gate
    /// (i.e. NOT a 401/403)?
    case auth
    /// Write — can we PUT a tiny probe file and get a 2xx?
    case write
    /// Read — can we GET the probe file back and get a 2xx (proving the write
    /// actually landed and is served, not a Control-UI HTML 200)?
    case read
    /// List — can the server answer a `PROPFIND`, and can it say NO to one? This
    /// is the whole return direction: Conduck names a per-dispatch output folder,
    /// asserts it absent with a `PROPFIND` before the turn goes out, and reads it
    /// with a `PROPFIND` after the reply lands. A lane that cannot do both
    /// delivers nothing an agent produces, ever — so a test that stopped at
    /// `.read` certified half a lane as fully green and left the user with no
    /// signal anywhere.
    ///
    /// THE STAGE THAT CANNOT FAIL THE TEST. It reports on
    /// `FileTransferTestResult.returnVerification` rather than on `success`,
    /// because the four stages above have already proved the upload direction
    /// with a byte-echo and nothing this stage learns can un-prove it. What it
    /// decides is what the app may CLAIM about the other direction: verified,
    /// structurally unavailable (the amber uploads-only lane), or unchecked.
    case listing
}

/// What the staged test learned about the RETURN direction — the one question
/// the listing stage decides, held as a taxonomy rather than a Bool because
/// there are three answers and the middle one has no polarity.
///
/// THE RULE THIS TYPE ENFORCES: return-direction uncertainty may reduce what the
/// app CLAIMS, and may never erase what the upload stages PROVED. A `502` from a
/// reverse proxy on the fifth request of a sequence whose first four moved real
/// bytes end to end says nothing about the server and nothing about uploads, so
/// it neither narrows a capability nor revokes a lane.
enum FileTransferReturnVerification: Sendable {
    /// The run never reached the listing stage — an earlier stage failed, or the
    /// result was constructed synthetically. The DEFAULT, so a legacy or partial
    /// construction claims nothing in either direction.
    case notMeasured
    /// The server answered `207` for a collection that exists and `404` for one
    /// that cannot. The handshake both halves of the return direction rest on.
    ///
    /// It is a HANDSHAKE, not a delivery guarantee: two `Depth: 0` status lines
    /// prove the method is recognised and that a miss is reported as a miss;
    /// they do not prove a later `Depth: 1` body will survive `parseListing`.
    /// Nothing downstream treats it as more than it is — every real listing
    /// still runs its own negative control and the strict parser.
    case verified
    /// STRUCTURAL: `PROPFIND` of a collection that certainly exists came back
    /// `405`/`501` — the server naming the method as one it does not perform
    /// (RFC 9110 §15.5.6 / §15.6.2). Plain nginx with `dav_methods PUT DELETE`
    /// is exactly this, and it is a large real population.
    ///
    /// THE SOLE AUTHOR OF AN INCAPABILITY IN THE WHOLE SUBSYSTEM, and it earns
    /// that by being the only measurement taken against a collection that
    /// certainly exists. The per-dispatch witness can never be: the box it asks
    /// about is the one this turn is about to name, so a `405` from it describes
    /// the route a missing path is served by and settles nothing (see
    /// `FileServerAbsenceWitness.cannotAnswer`). One author is what keeps the
    /// phone, the Mac, CarPlay and the wrist from telling four stories about one
    /// server.
    ///
    /// IT IS A FACT ABOUT THE LANE AS CONFIGURED, not an eternal property of the
    /// host: `405`'s allowed-method set is explicitly permitted to change, and a
    /// path-scoped rule or a rate limiter can produce one. So it narrows the
    /// CLAIM — an amber uploads-only lane the user can read — rather than
    /// disabling anything, and the narrowing is persisted per gateway,
    /// couriered to the Watch, and read by every surface's mint.
    ///
    /// IT ALSO SEEDS THE PROCESS-LOCAL WITNESS BREAKER, which stops the dispatch
    /// path re-asking, and that suppression is deliberate: a server that
    /// structurally refuses the method would be paying a `PROPFIND` every single
    /// turn to re-learn a fact Settings already displays, and the answer the
    /// witness could get back would not settle the question anyway.
    ///
    /// A REPAIR IS NOTICED BY A DELIBERATE MEASUREMENT, never by a dispatch. The
    /// four that reach it: the next Test Connection and the Diagnostics file-lane
    /// sweep both re-run `probeListingCapability` and commit `.set(true)` on a
    /// pass; any edit to the URL, credential or pin commits `.resetToUnknown`,
    /// which is also a new witness-breaker key; and
    /// `FileTransferCapabilityRefresher` re-runs the same probe once per launch,
    /// silently, so a user who fixes their server does not have to know that a
    /// re-test is what tells the app about it. The first three are where the user
    /// reads about the limitation and therefore where they land after fixing it;
    /// the fourth is what stops the verdict outliving the fact for someone who
    /// never goes back to that screen.
    case methodUnavailable
    /// The stage ran and settled NOTHING: a timeout, a `502`, a `429`, a `401`,
    /// a redirect, a `200` that is not a multistatus, or a namespace that
    /// answered a 16-hex-entropy path. Carries the taxonomy code the user is
    /// shown next to the listing row.
    ///
    /// NOT a failure of the test and NOT a narrowing — uploads stay proven,
    /// nothing is persisted, and no capability is seeded into the dispatch-path
    /// witness breaker. (The passing test that produced this still clears that
    /// lane's failure cooldown: a cooldown is a guess about whether another
    /// request is worth spending, not a claim about the server, and four stages
    /// of moved bytes outweigh it.) It exists so the surfaces can say "couldn't
    /// check" instead of picking one of the two answers nobody has.
    case unverified(AppError)
}

/// Result of a staged Test Connection: how far it got + whether the lane is
/// USABLE + what was learned about the return direction + the mapped failure
/// (nil when usable). `fileTransferAvailable` is set true ONLY when `success`.
///
/// TWO INDEPENDENT AXES, and keeping them apart is what this type is for.
/// `success` answers "may this lane carry bytes at all", which is the question
/// that gates uploads; `returnVerification` answers "can anything come back",
/// which is the question the listing stage alone decides. A server that PUTs and
/// GETs but cannot `PROPFIND` — plain nginx with `dav_methods PUT DELETE`, a
/// large real population — is `success: true, .methodUnavailable`, and
/// collapsing that into one Bool cost those users their UPLOADS as well, for a
/// capability they were not using.
struct FileTransferTestResult: Equatable, Sendable {
    /// The furthest stage reached — on a pass this is `.listing`; on failure it
    /// is the stage that failed (everything before it passed).
    let reachedStage: FileTransferTestStage
    /// True when the lane is usable for uploads — the
    /// reachability→auth→write→read sequence passed. NO listing-stage outcome
    /// clears it: a structural refusal is a fact about the other direction, and
    /// an unsettled listing probe is not a fact at all. Both would otherwise
    /// destroy evidence the four byte-moving stages had already established.
    let success: Bool
    /// What the listing stage learned. See the enum — it is the only place the
    /// three answers are distinguished, and every surface reads it rather than
    /// re-deriving one from a pair of Bools.
    let returnVerification: FileTransferReturnVerification
    /// The taxonomy error on failure (nil on success). Never names the
    /// credential. An UNVERIFIED listing carries its code on
    /// `returnVerification`, not here: the test did not fail, so a `failure`
    /// would make every `success == false` reader draw a red X on a lane that
    /// works.
    let failure: AppError?
    /// Whether the post-pass NESTED write-probe succeeded — i.e. the gateway
    /// accepts a `PUT __conduck_probe_<8hex>__/<tag>.txt` (folder) + GET + DELETE. True →
    /// uploads can mint per-conversation `<convID>/…` keys; false → the gateway
    /// rejected nested PUTs (nginx-DAV needing MKCOL, an S3-DAV bridge, …) so the
    /// client must fall back to FLAT `<8hex>__<name>` keys for it. Defaults true
    /// so a failed connectivity test (where the nested probe never runs) and
    /// every legacy construction read as folder-capable until proven otherwise —
    /// the flat fallback is a narrowing, only flipped on a definitive nested-PUT
    /// rejection. NOT a user-facing stage (the nested probe failing does NOT fail
    /// the connection test — flat keys still work fine).
    let folderCapable: Bool

    init(
        reachedStage: FileTransferTestStage,
        success: Bool,
        failure: AppError?,
        folderCapable: Bool = true,
        returnVerification: FileTransferReturnVerification = .notMeasured
    ) {
        self.reachedStage = reachedStage
        self.success = success
        self.failure = failure
        self.folderCapable = folderCapable
        self.returnVerification = returnVerification
    }

    /// Whether the lane may be treated as able to carry files BACK.
    ///
    /// DERIVED, and the polarity matches `folderCapable`'s for the same reason:
    /// this is a NARROWING the app applies on proof, so only the one measured
    /// incapability answers false. `.notMeasured` and `.unverified` read TRUE —
    /// not because anything was proven, but because stamping a lane incapable on
    /// evidence nobody has is the specific failure being repaired here.
    var returnCapable: Bool {
        if case .methodUnavailable = returnVerification { return false }
        return true
    }

    /// The lane works for uploads and CANNOT return files — the third outcome,
    /// which is neither the green pass nor a failure and must never be rendered
    /// as either. Every surface that draws a badge, a checklist row, or a status
    /// line reads this rather than re-deriving the conjunction, so they cannot
    /// disagree about which of the three a given result is.
    var isUploadOnly: Bool { success && !returnCapable }

    /// The lane works for uploads and the return direction could not be checked
    /// AT ALL this run. A FOURTH thing a surface may need to say, and the reason
    /// it must exist: rendering it as the green pass claims a folder was listed
    /// when none was, and rendering it as the upload-only lane claims the server
    /// refused when it never said so.
    var listingUnverified: AppError? {
        guard success, case .unverified(let error) = returnVerification else { return nil }
        return error
    }

    /// The listing verdict this run SETTLED, or nil when it settled nothing —
    /// the single definition of "settled", so the two commit paths that care
    /// (a staged verdict and a tuple save) cannot come to different views of
    /// which outcomes count as evidence.
    var settledReturnCapability: Bool? {
        switch returnVerification {
        case .verified: return true
        case .methodUnavailable: return false
        case .unverified, .notMeasured: return nil
        }
    }

    /// What this result instructs the store to do about the persisted listing
    /// verdict — the ONE translation from the three-answer taxonomy to the
    /// three-operation write, so no screen can invent a fourth reading of it.
    ///
    /// AN UNSETTLED RUN PRESERVES. Widening a previously-proven incapability on
    /// a probe that learned nothing would be as wrong as narrowing on one, and
    /// this flag moves on proof in BOTH directions. Never `.resetToUnknown` — a
    /// staged test does not change the tuple, so an existing verdict still
    /// describes the same server; only an identity change invalidates one, and
    /// that caller spells its own reset.
    var returnCapabilityWrite: SettingsManager.ReturnCapabilityWrite {
        settledReturnCapability.map { .set($0) } ?? .preserve
    }

    /// `AppError` is `LocalizedError`, NOT `Equatable` (its `Error`-carrying
    /// cases can't synthesize `==`). Compare the failure by its stable numeric
    /// `errorCode` so this value stays `Equatable` for tests without forcing an
    /// `AppError: Equatable` conformance across the whole taxonomy.
    static func == (lhs: FileTransferTestResult, rhs: FileTransferTestResult) -> Bool {
        lhs.reachedStage == rhs.reachedStage
            && lhs.success == rhs.success
            && lhs.failure?.errorCode == rhs.failure?.errorCode
            && lhs.folderCapable == rhs.folderCapable
            && lhs.returnCapable == rhs.returnCapable
            && lhs.listingUnverified?.errorCode == rhs.listingUnverified?.errorCode
    }
}

/// Pure request-builders + response-parsers + the staged Test Connection for
/// the user-run file-server. Stateless namespace `enum` (no instances) — every
/// method is `static`. The transfer-execution side (background upload/download,
/// progress, delegate cert-pinning) lives in `BackgroundFileTransfer`,
/// which consumes the `build*Request(...)` helpers here.
enum FileServerClient {

    // MARK: - Stored-key minting

    /// Longest single path component a stored key may occupy, in CHARACTERS.
    ///
    /// Every stored key's last segment becomes a real filename on whatever
    /// filesystem backs the user's file server, where POSIX `NAME_MAX` is 255
    /// BYTES. The MINT maps each character to one of `[A-Za-z0-9._-]`, all
    /// single-byte, so for a key Conduck mints this character count IS its byte
    /// count and one number measures both budgets at once.
    ///
    /// That equivalence belongs to the mint alone. An inbound entry name may be
    /// any Unicode, where a character is one to four bytes, so
    /// `outboxEntryVerdict` counts the filesystem's budget in the unit the
    /// filesystem uses — `storedKeyComponentMaxBytes` — and keeps this cap only
    /// for what it still measures there: an accepted name stays no longer, in
    /// characters, than a name Conduck would have minted, which is what bounds
    /// the chip label and the wire bullet.
    ///
    /// The cap sits below 255 to leave headroom for a temporary name the server
    /// may write and rename into place during a PUT. A key that only overflows
    /// once the server appends its own suffix fails just as hard as one that
    /// overflows on its own, and diagnosing that from an opaque 5xx is far worse
    /// than reserving the room up front.
    ///
    /// `nonisolated` because `outboxEntryVerdict` reads it and that gate is
    /// reachable from the off-actor prose lane. It widens where the number may
    /// be READ and changes no value and no mint code path.
    nonisolated static let storedKeyComponentMaxCharacters = 200

    /// Longest single path component an inbound entry name may occupy, in UTF-8
    /// BYTES — the unit `NAME_MAX` is actually counted in.
    ///
    /// `Übersicht.md` is 12 characters and 13 bytes; a CJK name is three bytes
    /// per character and an emoji four, so a name inside the character cap can
    /// be four times past the filesystem's, and the failure lands as an opaque
    /// server error on a file the user can see in their own listing.
    ///
    /// Derived from the character cap rather than written as its own number: an
    /// ASCII name meets both bounds at exactly the same length, so admitting
    /// non-ASCII changes no verdict this gate reached before, and the two can
    /// never drift into disagreeing about the same headroom.
    ///
    /// `nonisolated` for the reason the character cap is.
    nonisolated static let storedKeyComponentMaxBytes = storedKeyComponentMaxCharacters

    /// The WebDAV-safe alphabet every MINTED key component is mapped into.
    ///
    /// The mint's alone, and deliberately NOT the inbound validator's. The two
    /// answer different questions. The mint IMPOSES a shape it controls end to
    /// end — it chooses the prefix, the folder and every surviving character —
    /// so it can pick the narrowest alphabet that still addresses a file, and
    /// anything it drops it also replaces. `outboxEntryVerdict` ASSERTS a
    /// property of a name the SERVER already chose, which it may not rewrite (a
    /// repaired name addresses a file that does not exist), so its standard is
    /// what that name's two consumers can survive: a path inside Conduck's own
    /// instruction line, and a rendered chip label. Holding an inbound name to
    /// THIS set instead silently discards every `Übersicht.md` a user's own
    /// agent writes.
    static let storedKeySafeCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    /// Longest dot-suffix still treated as an extension worth preserving.
    ///
    /// Real extensions are short (`.markdown` is 9). The bound exists so a
    /// pathological name whose "extension" is hundreds of characters cannot
    /// consume the budget the stem needs — such a name is truncated blind
    /// instead, which is the better failure.
    private static let maxPreservedExtensionCharacters = 16

    /// Bound an already-sanitized name so `<prefix><name>` fits inside one path
    /// component, keeping the file extension.
    ///
    /// The stem is what gets cut, because an agent routes on the extension: a
    /// `report.pdf` shortened to `repo.pdf` is still a PDF to whatever tooling
    /// opens it, where `report.p` is nothing at all.
    ///
    /// Pure and deterministic, which the retry path depends on — the same inputs
    /// must re-mint the same key so a re-PUT overwrites the partial blob instead
    /// of orphaning it. And a no-op for every name that already fits, so no key
    /// any existing conversation already holds changes shape.
    static func boundedStoredKeyName(
        _ safeName: String,
        reservedPrefixCharacters: Int
    ) -> String {
        let budget = storedKeyComponentMaxCharacters - reservedPrefixCharacters
        guard budget > 0 else { return "" }
        guard safeName.count > budget else { return safeName }

        // The extension is the last dot-suffix, but only when the dot is not the
        // leading character — a dotfile like `.gitignore` is all stem, and
        // treating it as an extension would truncate away the entire name.
        var stem = safeName
        var ext = ""
        if let dot = safeName.lastIndex(of: "."), dot != safeName.startIndex {
            let suffix = safeName[dot...]
            if suffix.count <= maxPreservedExtensionCharacters, suffix.count < budget {
                stem = String(safeName[..<dot])
                ext = String(suffix)
            }
        }
        return String(stem.prefix(budget - ext.count)) + ext
    }

    /// Derive the opaque stored name for an attachment:
    /// `[<folder>/]<8 lowercase hex>__<sanitized original>` (with the
    /// per-conversation folder prefix).
    ///
    /// - The 8-hex prefix is the first 8 hex digits of `uuid` (lowercased, no
    ///   dashes) — enough entropy to avoid collisions in the agent's working
    ///   folder while staying short + human-glanceable in the spliced
    ///   "saved as …" chat line.
    /// - The original name is sanitized to the WebDAV-safe set `[A-Za-z0-9._-]`;
    ///   every other character (spaces, slashes, unicode, shell-metachars) is
    ///   replaced with `_`. This keeps the FILENAME segment a single safe path
    ///   component for both the `PUT baseURL/<storedKey>` URL and the agent's
    ///   shell-side tooling. An empty sanitized result (e.g. a name that was all
    ///   spaces) falls back to `"file"` so the key is always well-formed.
    /// - The sanitized name is then bounded so the whole `<8hex>__<name>`
    ///   component fits `storedKeyComponentMaxCharacters`, extension preserved
    ///   (`boundedStoredKeyName`). Unbounded, a filename the source filesystem
    ///   happily accepts at its own 255-byte limit mints a LONGER component here
    ///   — the 8-hex prefix and `__` are pure additions — which the file server's
    ///   filesystem then refuses, so the attachment cannot be sent at all.
    /// - `folder` (optional) namespaces the upload under a per-conversation
    ///   directory: when present (and non-empty after the same safe-set
    ///   sanitization — a `conversationID` UUID string is already in the safe
    ///   set, so it passes through verbatim), the key becomes
    ///   `<folder>/<8hex>__<name>`. The lone `/` between folder and filename is a
    ///   real path SEPARATOR — `URL.appending(path:)` keeps it unescaped. WebDAV
    ///   servers do NOT auto-create a missing parent on a nested PUT (RFC 4918
    ///   §9.7 — a 409; `rclone serve webdav` answers exactly that), so the
    ///   uploader MKCOLs the parent collection first (`ensureCollection`). A
    ///   gateway that still rejects the nested PUT after MKCOL (probed at Test
    ///   Connection → `folderCapable=false`) passes `folder: nil` here and gets
    ///   the historic flat `<8hex>__<name>`.
    ///
    /// Deterministic given the same `(originalName, uuid, folder)` — tests assert
    /// this so a retry mints the SAME key (the bytes are already on the server).
    static func makeStoredKey(originalName: String, uuid: UUID, folder: String? = nil) -> String {
        // First 8 hex of the UUID, lowercased, no dashes. `uuidString` is
        // upper-cased with dashes (`E621E1F8-C36C-...`); strip + lower + take 8.
        let hex = uuid.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let shortID = String(hex.prefix(8))

        let allowed = storedKeySafeCharacters
        let sanitized = String(originalName.map { allowed.contains($0) ? $0 : "_" })
        let safeName = sanitized.isEmpty ? "file" : sanitized

        let prefix = "\(shortID)__"
        let baseKey = prefix + boundedStoredKeyName(
            safeName,
            reservedPrefixCharacters: prefix.count
        )

        // Prefix the per-conversation folder when supplied + capable. The folder
        // segment is sanitized through the SAME safe set (a UUID string is
        // already safe; this guards a hand-crafted caller). An empty/degenerate
        // sanitized folder falls back to the flat key (never emit a leading `/`).
        guard let folder, !folder.isEmpty else { return baseKey }
        let safeFolder = String(folder.map { allowed.contains($0) ? $0 : "_" })
        guard !safeFolder.isEmpty else { return baseKey }
        // The folder is its own path component, so it carries the same NAME_MAX
        // budget as the filename. A plain truncation is right here where the
        // filename gets extension-aware treatment: a directory name has no
        // extension to protect, and the value is a `conversationID` UUID (36
        // characters) in every real caller.
        return "\(safeFolder.prefix(storedKeyComponentMaxCharacters))/\(baseKey)"
    }

    /// Derive the deterministic stored key for a SHARE-EXTENSION attachment:
    /// `<8 lowercase hex of envelopeID>-<sequence>__<sanitized original>`.
    ///
    /// Distinct from `makeStoredKey(originalName:uuid:)` (the in-app composer's
    /// per-attachment-UUID key) because the share drain must recompute the SAME
    /// key on a relaunch WITHOUT a persisted per-attachment UUID — only the
    /// envelope UUID + the attachment's `sequence` survive (both live in the
    /// manifest). The `-<sequence>` segment keeps two same-named files in one
    /// envelope from colliding, so the key is unique per attachment AND stable
    /// across a re-PUT (idempotent, exactly-once recovery).
    ///
    /// - The 8-hex prefix is the first 8 hex digits of `envelopeID` (lowercased,
    ///   no dashes) — enough entropy in the agent's flat working folder while
    ///   staying short + glanceable in the spliced "saved as …" chat line.
    /// - `originalName` is sanitized to the WebDAV-safe set `[A-Za-z0-9._-]`;
    ///   every other character (spaces, slashes, unicode, shell-metachars) is
    ///   replaced with `-` (a single safe path component for the
    ///   `PUT baseURL/<storedKey>` URL + the agent's shell-side tooling). An empty
    ///   sanitized result (e.g. a name that was all spaces) falls back to `"file"`
    ///   so the key is always well-formed.
    /// - The sanitized name is then bounded to fit
    ///   `storedKeyComponentMaxCharacters` with the extension preserved, exactly
    ///   as the in-app key is. The budget is derived from the prefix actually
    ///   built, because `sequence` widens it. `SharedInboxManifest` already
    ///   bounds `originalName` on the way in, but that guards the manifest, not
    ///   this component — a manifest decoded from an older build carries whatever
    ///   name it was written with, and the bound belongs where the filesystem
    ///   constraint actually is.
    ///
    /// Deterministic given the same `(envelopeID, sequence, originalName, folder)`
    /// — tests assert this so a relaunch re-mints the SAME key (the bytes are
    /// already on the server) and that distinct `sequence`s never collide.
    ///
    /// `folder` (optional) namespaces the upload under the per-conversation
    /// directory `<folder>/<8hex>-<seq>__<name>` — applied uniformly with the
    /// in-app `makeStoredKey` so EVERY file a conversation receives (composer or
    /// share-extension) lands under the same `<conversationID>/` folder. Idempotent
    /// recovery still holds: a relaunch passes the SAME folder (the routed
    /// `conversationID`) so the re-mint is byte-identical. A gateway probed
    /// `folderCapable=false` passes `folder: nil` → the historic flat key.
    static func deterministicStoredKey(
        envelopeID: UUID,
        sequence: Int,
        originalName: String,
        folder: String? = nil
    ) -> String {
        let hex = envelopeID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let shortID = String(hex.prefix(8))

        let allowed = storedKeySafeCharacters
        let sanitized = String(originalName.map { allowed.contains($0) ? $0 : "-" })
        let safeName = sanitized.isEmpty ? "file" : sanitized

        // `sequence` widens the prefix, so the name budget is derived from the
        // prefix actually built rather than a hardcoded width.
        let prefix = "\(shortID)-\(sequence)__"
        let baseKey = prefix + boundedStoredKeyName(
            safeName,
            reservedPrefixCharacters: prefix.count
        )

        guard let folder, !folder.isEmpty else { return baseKey }
        let safeFolder = String(folder.map { allowed.contains($0) ? $0 : "_" })
        guard !safeFolder.isEmpty else { return baseKey }
        return "\(safeFolder.prefix(storedKeyComponentMaxCharacters))/\(baseKey)"
    }

    // MARK: - Auth

    /// Build the `Authorization: Basic <base64(user:password)>` header VALUE
    /// (the full string including the `"Basic "` scheme prefix).
    ///
    /// Privacy: the returned string embeds the credential — callers set it
    /// directly onto a `URLRequest` and never log it. The caller is responsible
    /// for keeping the value off any logging path.
    static func basicAuthHeaderValue(username: String, password: String) -> String {
        let raw = "\(username):\(password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    // MARK: - Request builders (pure)

    /// `PUT <baseURL>/<storedKey>` — upload the file bytes to the server root.
    ///
    /// - `Content-Type: application/octet-stream` (rclone serve webdav accepts
    ///   any body; octet-stream is the safe generic for arbitrary bytes — the
    ///   agent's own tooling sniffs the real type from the bytes / original name).
    /// - `Content-Length` is set only when `contentLength` is known up front
    ///   (the background uploadTask supplies the body via a file URL, which lets
    ///   `URLSession` set the length itself; the pure path may still pass it for
    ///   tests / non-streamed uploads).
    /// - `timeoutInterval = fileTransferRequestTimeout` (600 s — a multi-MB PUT
    ///   over a home tunnel can take real time).
    static func buildUploadRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String,
        contentLength: Int?
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: storedKey))
        request.httpMethod = "PUT"
        request.timeoutInterval = Constants.fileTransferRequestTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let contentLength {
            request.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    /// `MKCOL <baseURL>/<collectionKey>` — create the parent collection (folder)
    /// for nested uploads. WebDAV servers do NOT auto-create a missing parent on
    /// `PUT <folder>/<file>` (RFC 4918 §9.7 — a 409; rclone answers exactly
    /// that), so the client creates the folder explicitly before the first
    /// nested PUT. On a server where the collection already exists MKCOL answers
    /// 405 — callers treat every outcome as best-effort (the PUT that follows is
    /// the authoritative verdict). Probe-length timeout: MKCOL is a tiny
    /// bodyless request, never a multi-MB transfer.
    static func buildMkcolRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: collectionKey))
        request.httpMethod = "MKCOL"
        request.timeoutInterval = Constants.fileServerProbeTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    /// Best-effort MKCOL of `collectionKey` ahead of a nested PUT. Swallows
    /// every outcome — 201 (created), 405 (already exists), any other status,
    /// transport errors — because the nested PUT that follows is the
    /// authoritative pass/fail, and a server that auto-creates parents never
    /// needed the MKCOL at all. Shared by the Test-Connection nested probe and
    /// `BackgroundFileTransfer.uploadFile` so the probe exercises the EXACT
    /// sequence real uploads use.
    static func ensureCollection(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession
    ) async {
        _ = await performMkcol(snapshot: snapshot, collectionKey: collectionKey, session: session)
    }

    /// MKCOL `collectionKey` and require it to have been CREATED BY THIS CALL —
    /// `201`, and nothing else. The strictest available way to obtain a
    /// collection provably created at a known instant.
    ///
    /// **NOT ON THE DISPATCH PATH, deliberately, and do not put it back.** The
    /// per-dispatch output box is named by Conduck and created by the AGENT
    /// (`OutboxKey`). Measured across six live gateways: a client-created box is
    /// obeyed on 4 of 6 while a box the client only names is obeyed on 5 of 6 at
    /// full marks — and the two that fail the first are the two most common
    /// self-hosted gateways. The mechanism is ownership: the WebDAV lane
    /// typically runs as root with a `0022` umask, so a client MKCOL yields a
    /// root-owned `0755` directory while the agent runs as an ordinary user. A
    /// *successful* MKCOL is therefore WORSE than a failed one — it produces a
    /// directory the agent can neither write into nor delete, and best-effort
    /// softening does not help because the harm comes from success. The
    /// pre-dispatch freshness evidence comes instead from
    /// `BackgroundFileTransfer.witnessCollectionAbsent`, which observes absence
    /// without changing who owns anything.
    ///
    /// Retained because the 201-only distinction is a real primitive with no
    /// other expression in this file, and a future collection Conduck genuinely
    /// must own (never one an agent has to write into) needs exactly it.
    ///
    /// `405` IS A COLLISION, NOT A SUCCESS, and that inversion is the whole
    /// reason this exists next to `ensureCollection`. The shipped MKCOL idiom
    /// reads "2xx or 405" as "the collection now exists", which is right for a
    /// long-lived per-conversation folder and wrong for anything whose value is
    /// its freshness: a freshly-random key that already exists was not minted by
    /// this call. Every other status and every transport failure is also
    /// `false`.
    ///
    /// The PARENT is ensured best-effort first, and the asymmetry is deliberate:
    /// a WebDAV MKCOL into a missing parent is a `409` (RFC 4918 §9.3), the
    /// per-conversation folder is deliberately long-lived and SHARED with every
    /// upload that conversation ever made, so `405 already exists` is the
    /// correct answer for it. Only the leaf has to be new.
    static func ensureFreshCollection(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession
    ) async -> Bool {
        if let parent = parentCollectionKey(of: collectionKey) {
            await ensureCollection(snapshot: snapshot, collectionKey: parent, session: session)
        }
        return await performMkcol(
            snapshot: snapshot, collectionKey: collectionKey, session: session) == 201
    }

    /// The `/`-delimited segments of a key, split on UTF-8 BYTES.
    ///
    /// Byte-level rather than `split(separator: "/")`, because a `Character`
    /// comparison reads GRAPHEME CLUSTERS: a `/` followed by a combining mark is
    /// the single Character `/́`, which is not `/`, so a grapheme split leaves a
    /// real U+002F sitting inside what it calls one component — and
    /// `URL.appending(path:)` treats that U+002F as a separator regardless. UTF-8
    /// is self-synchronizing, so byte `0x2F` only ever encodes U+002F and the
    /// split can never land inside a character.
    private static func keySegments(_ key: String) -> [String] {
        key.utf8
            .split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// The collection holding `collectionKey`, or nil when it already sits at
    /// the served root (nothing to create).
    static func parentCollectionKey(of collectionKey: String) -> String? {
        var components = keySegments(collectionKey)
        guard components.count > 1 else { return nil }
        components.removeLast()
        return components.joined(separator: "/")
    }

    /// MKCOL `collectionKey` and report the HTTP status (nil on transport
    /// error). Same wire call as `ensureCollection`; separated so the
    /// folder-capability probe can tell "collection ensured" (2xx created /
    /// 405 already-exists) from an AMBIENT failure (timeout, 5xx, auth) —
    /// a nested-PUT 409 after the latter is indeterminate, not a verdict
    /// that the server rejects folders.
    static func performMkcol(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession
    ) async -> Int? {
        let request = buildMkcolRequest(snapshot: snapshot, collectionKey: collectionKey)
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// `GET <baseURL>/<storedKey>` — download the file bytes.
    /// `timeoutInterval = fileTransferRequestTimeout` (same multi-MB budget as
    /// upload).
    static func buildDownloadRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: storedKey))
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.fileTransferRequestTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    /// `GET <baseURL>/<storedKey>` for an EXISTENCE probe — NEVER HEAD
    /// (a read-only HEAD/GET on a Control-UI HTML page
    /// false-positives; a GET against rclone serve webdav returns the bytes on
    /// 200/206 and 404 on miss, the only reliable existence signal).
    ///
    /// Ranged to `bytes=0-0` so the probe stays an O(1) existence check on a
    /// well-behaved server: `rclone serve webdav` honours the range and answers a
    /// present file with `206` + 1 byte and a missing one with `404`; `dufs`
    /// additionally answers an empty file with `416` + `bytes` `*`/`0`. The range
    /// is a BANDWIDTH courtesy, never the safety mechanism and never a
    /// correctness dependency — a server that ignores it (nginx `max_ranges 0`,
    /// Apache `MaxRanges none`, or Go's `ServeContent`, which deliberately drops
    /// the range for a zero-length file) answers `200` + the full body, which is
    /// perfectly legitimate. What actually bounds the probe is the CLIENT-side
    /// cap in `BackgroundFileTransfer.collectProbeEvidence`, which stops reading
    /// and cancels the task past `Constants.fileServerProbeBodySniffBytes`.
    /// Without that, probing a reply naming a large existing output (e.g.
    /// `export.zip`) would pull the entire file into memory on every reply,
    /// before the user taps anything — an OOM/jetsam risk on iOS. The real chip
    /// download stays a full-range GET (`buildDownloadRequest`).
    ///
    /// `Accept-Encoding: identity` because two of the verdict's inputs are byte
    /// counts. Transparent decompression would make "the server delivered one
    /// byte for a one-byte range" and "`Content-Length` is this file's size"
    /// both unverifiable, and `identity` is always an acceptable coding.
    ///
    /// Identical wire shape to the download request EXCEPT the short
    /// `fileServerProbeTimeout` (15 s — interactive, the user is waiting; this
    /// is a quick "does it exist?" not a bulk transfer) and the `Range` cap.
    /// Kept as a separate builder so the two timeouts never drift.
    static func buildProbeRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: storedKey))
        request.httpMethod = "GET"
        request.timeoutInterval = Constants.fileServerProbeTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        // Existence-only: ask for a single byte. A server that ignores Range
        // degrades to a full-body 200 — legitimate, and bounded client-side.
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    /// `DELETE <baseURL>/<storedKey>` — best-effort orphan cleanup (a cancelled
    /// in-flight upload, or the probe file after the staged test). The caller
    /// treats the result as best-effort and never throws on failure.
    /// `timeoutInterval = fileServerProbeTimeout` (a DELETE is lightweight).
    static func buildDeleteRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String
    ) -> URLRequest {
        var request = URLRequest(url: snapshot.baseURL.appending(path: storedKey))
        request.httpMethod = "DELETE"
        request.timeoutInterval = Constants.fileServerProbeTimeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    /// `PROPFIND <baseURL>/<collectionKey>` with a `Depth` header — a listing of
    /// ONE EXACT collection.
    ///
    /// The collection is a PARAMETER, never the base URL by default: the listing
    /// is the authority on what a single reply produced, and a request aimed at
    /// the served root would answer with every file every conversation ever
    /// uploaded. An empty `collectionKey` targets the root, which only a
    /// deliberate whole-server listing may ask for.
    ///
    /// The request body is the standard `<D:propfind><D:allprop/></D:propfind>`
    /// envelope so any compliant WebDAV server returns the property set.
    ///
    /// `timeout` defaults to `fileServerProbeTimeout` — a listing is interactive
    /// and happens after a reply landed, so it may take the lane's ordinary
    /// budget. The pre-dispatch absence witness passes its own much shorter one:
    /// it is the same request shape but it runs BEFORE every turn, so it is the
    /// one PROPFIND whose deadline is a latency budget rather than a patience
    /// budget.
    static func buildPropfindRequest(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        depth: Int,
        timeout: TimeInterval = Constants.fileServerProbeTimeout
    ) -> URLRequest {
        var request = URLRequest(url: listingCollectionURL(snapshot: snapshot, collectionKey: collectionKey))
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = timeout
        request.setValue(
            basicAuthHeaderValue(username: snapshot.username, password: snapshot.credential),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>".utf8
        )
        return request
    }

    // MARK: - Response parsers (pure)

    /// A STATUS PRE-FILTER — never a verdict. Maps a raw HTTP status to the
    /// `FileProbeOutcome` shape so a caller can branch on the obvious failures
    /// (auth, server sick, absent) before it does the work that actually
    /// decides.
    ///
    ///   - 200 / 206 / 416 → `.exists`  ← THE LIE. A uniform-200 SSO wall lands
    ///     here for every path on the server, which is exactly the false
    ///     positive this file exists to prevent.
    ///   - 404       → `.missing`
    ///   - 401 / 403 → `.unauthorized`
    ///   - 5xx       → `.serverError`
    ///   - anything else → `.unknown` (fail closed)
    ///
    /// ONLY TWO CALL SITES MAY USE THIS, and both immediately require an EXACT
    /// byte-echo of a payload they just PUT (`runConnectionTest`'s read stage,
    /// `probeFolderCapability`). That echo is what turns the `.exists` above
    /// into a real verdict; the wall fails it because it serves its own HTML.
    /// The per-file existence probe has nothing it can echo — it never wrote the
    /// file — so it uses `classifyProbe`, which reads the body instead. Do not
    /// add a third caller without one of those two.
    static func probeStatusPrefilter(status: Int) -> FileProbeOutcome {
        switch status {
        case 200, 206, 416:
            return .exists
        case 404:
            return .missing
        case 401, 403:
            return .unauthorized
        case 500...599:
            return .serverError
        default:
            return .unknown
        }
    }

    // MARK: - Existence verdict (reads the body)

    /// THE existence verdict for a file this device did not write, from one
    /// probe response. Pure — the network half is
    /// `BackgroundFileTransfer.collectProbeEvidence`.
    ///
    /// THE THING THIS EXISTS TO PREVENT: an endpoint that answers convincingly
    /// for a file that is not there. Read as a status, `report.pdf` gets a
    /// download chip, and tapping it hands the user an SSO login page wearing
    /// that filename. Two ordinary (NOT adversarial) deployments produce it:
    ///
    ///   - An SSO portal or control-panel UI in front of the server, answering
    ///     every path with `200` + its own HTML.
    ///   - A static host with an SPA fallback — `try_files $uri /index.html` is
    ///     the canonical nginx form. A GET for a missing `report.pdf` is
    ///     INTERNALLY rewritten to a file that does exist, so the client sees
    ///     the URL it asked for and a textbook `206` + `Content-Range: bytes
    ///     0-0/N`. No redirect is visible; nothing in that response is malformed.
    ///
    /// The second case is why the rule below is uniform rather than graded by
    /// how "strong" a status looks. A response's headers describe the
    /// representation the server SELECTED; they say nothing about how it chose
    /// it. Range machinery proves the server has range machinery — never that
    /// the key we NAMED is the thing we were handed. So:
    ///
    /// **NO POSITIVE VERDICT COMES FROM THE CANDIDATE'S RESPONSE ALONE.** Every
    /// path to `.exists` returns `.needsNegativeControl`, and the caller must
    /// see a `404` for a random key that cannot exist before the candidate is
    /// believed. Both deployments above fail that: the wall 200s the control,
    /// and the SPA fallback serves the control `index.html` too.
    ///
    /// What the per-status rules do, then, is not establish existence — it is
    /// reject responses that are internally inconsistent or visibly wrong,
    /// before spending a second request:
    ///
    ///   - `206`: the response must be coherent with itself. A `Content-Range`
    ///     of `bytes <first>-<last>/<total>` with `first == 0`, a body of
    ///     EXACTLY `last - first + 1` bytes (a 206 that claims one byte and
    ///     streams a file is broken or lying), and no content coding, since a
    ///     coding makes every byte count here describe something other than what
    ///     was delivered. Then the provenance vetoes, then the control.
    ///   - `416`: only `bytes` `*`/`0` — the empty-file answer (`dufs`). RFC 9110
    ///     lets a server 416 because it rejected the range SET rather than
    ///     because the file is short, and a WAF or range-hostile proxy can 416
    ///     everything. The HTML veto is deliberately NOT applied: a 416 body is
    ///     an error representation, so an HTML one says nothing about a wall.
    ///   - `200`: the range was ignored, which is legitimate (nginx
    ///     `max_ranges 0`, Apache `MaxRanges none`, Go's `ServeContent` on a
    ///     zero-length file) and also exactly what a wall does. Provenance
    ///     vetoes, then the control.
    ///   - `404`: `.missing`, on the server's own not-found semantics. Its body
    ///     is an error page and reading it teaches nothing — there is no
    ///     portable body shape that proves absence. Sound because absence mints
    ///     nothing: a wrong `.missing` costs a chip that never appears, while a
    ///     wrong `.exists` costs the user a downloaded login page. This is the
    ///     one place the two directions are graded differently, on purpose.
    ///
    /// A rejected response is `.ambiguous`, never `.unknown`: it is a fact about
    /// ONE key, so the pass keeps scanning the rest of the reply (see the enum).
    ///
    /// PRIVACY: pure; takes `FileProbeEvidence` (which carries the key and body
    /// bytes) and returns an enum. Nothing here logs, and nothing downstream
    /// carries content.
    static func classifyProbe(_ evidence: FileProbeEvidence) -> FileProbeVerdict {
        switch evidence.status {
        case 401, 403:
            return .settled(.unauthorized, byteLength: nil)
        case 500...599:
            return .settled(.serverError, byteLength: nil)
        case 404:
            return .settled(.missing, byteLength: nil)
        case 206:
            guard responseCodingIsIdentity(evidence.contentEncoding),
                  let range = satisfiedRange(evidence.contentRange),
                  !evidence.bodyExceededSniffCap,
                  evidence.deliveredBytes == range.last - range.first + 1,
                  passesProvenanceVetoes(evidence) else {
                return .settled(.ambiguous, byteLength: nil)
            }
            return .needsNegativeControl(byteLength: range.total)
        case 416:
            guard emptyRepresentationRange(evidence.contentRange),
                  responseCameFromRequestedName(evidence) else {
                return .settled(.ambiguous, byteLength: nil)
            }
            return .needsNegativeControl(byteLength: 0)
        case 200:
            guard passesProvenanceVetoes(evidence) else {
                return .settled(.ambiguous, byteLength: nil)
            }
            return .needsNegativeControl(byteLength: wholeRepresentationLength(evidence))
        default:
            return .settled(.unknown, byteLength: nil)
        }
    }

    /// The two free rejections a candidate response must survive before it is
    /// worth spending a control request on: it must have come back from the
    /// resource we named, and it must not be an HTML document wearing a name
    /// that is not HTML.
    ///
    /// Neither is proof of anything on its own — an internal rewrite is
    /// invisible to the first, and a wall is free to serve `application/pdf` —
    /// which is exactly why the control still runs afterwards. They are here to
    /// catch the common shapes without a round trip.
    static func passesProvenanceVetoes(_ evidence: FileProbeEvidence) -> Bool {
        responseCameFromRequestedName(evidence) && !servesHTMLDocumentForNonHTMLKey(evidence)
    }

    /// The storedKey for the NEGATIVE CONTROL: a key that cannot exist, carrying
    /// the same extension as the candidate. The caller GETs it with the same
    /// request shape and session posture; `negativeControlProvesNotFound` reads
    /// the answer.
    ///
    /// The extension is copied because servers route on it — an extension-to-
    /// handler map, a `location ~ \.php$` block, an SSO rule that exempts static
    /// assets, an SPA fallback that only catches extensionless paths — so a
    /// control with a different suffix can take a different code path and answer
    /// a question nobody asked.
    ///
    /// Root-relative with NO `/`, like every other key this client mints, so the
    /// control cannot express a path or escape the served root.
    static func negativeControlKey(forExtension ext: String) -> String {
        let nonce = String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        )
        let stem = "__conduck_absent_\(nonce)"
        return ext.isEmpty ? stem : stem + "." + ext
    }

    /// Whether the negative control's answer shows this namespace has credible
    /// not-found semantics — i.e. whether the server is CAPABLE of saying no —
    /// read from the status line alone.
    ///
    /// ONLY a `404` counts here. The control names a random key that provably does
    /// not exist, so a real file server has exactly one honest answer; anything
    /// else (a `200` login page, a `206` off an SPA fallback, a redirect, a
    /// `403` from a rule covering the whole namespace) means this endpoint's
    /// answer for the candidate carries no information, and the candidate stays
    /// unbelieved.
    ///
    /// THIS FORM READS THE STATUS LINE, WHICH IS THE WHOLE ANSWER TO A `GET`.
    /// The existence probe's control is a ranged GET of a key that cannot exist,
    /// and HTTP gives that question one truthful shape. A `PROPFIND` control has
    /// two, so it MUST use the body-aware form below — a `PROPFIND` call site
    /// that reaches for this one is the drift the file header warns about, and
    /// it presents as a lane whose every listing is refused while its every
    /// dispatch is cleared.
    ///
    /// RESIDUAL, stated rather than papered over: this is a credibility check,
    /// not a proof. A deliberately hostile file server can 404 the control and
    /// fabricate a clean answer for the candidate, and no generic HTTP client
    /// can tell that from a real static file handler. The app's answer to a
    /// hostile SERVER is the staged Test Connection's write-then-byte-echo,
    /// which the user runs against a server they own; this is the answer to a
    /// server that CHANGED under a lane that once passed it.
    static func negativeControlProvesNotFound(status: Int) -> Bool {
        status == 404
    }

    /// The same question with a `PROPFIND` control's bounded body in hand — THE
    /// form the strict listing uses, and the only one that can read the
    /// compliant way of saying no.
    ///
    /// WHY THE OVERLOAD EXISTS. RFC 4918 lets a server report a collection that
    /// is not there in two ways: a bare `404`, or a `207` multistatus whose one
    /// `<response>` names that collection with a response-level `404`.
    /// Commercial WebDAV hosts send the second, and from the status line alone
    /// it is indistinguishable from a namespace that answers everything — so a
    /// status-only control condemns every one of those lanes, and it condemns
    /// them on the exact population the absence witness has just cleared to name
    /// a folder. End to end that is an agent writing files into a folder Conduck
    /// named, every reply folder resolving `.unusable(.namespaceAnswersEverything)`,
    /// no download chip, and the thread drawing a read fault about a server doing
    /// nothing wrong.
    ///
    /// ONE RULE, NOT A SECOND OPINION. It delegates to `classifyAbsenceWitness`,
    /// so the listing's control and the pre-dispatch witness cannot hold
    /// different ideas of a definite miss, and it fails closed on everything
    /// that rule fails closed on: over-cap, truncated, empty, unparseable, more
    /// than one `<response>`, a row about another href, no readable inner
    /// status, an inner `2xx`. A control that proved nothing disqualifies the
    /// listing exactly as a control that answered wrongly does.
    ///
    /// THE BODY MUST ARRIVE UNDER `absenceWitnessMaxBytes`, and the rule
    /// re-checks the size rather than trusting the caller's read. A control body
    /// larger than the bound the rule is documented at is not the answer this
    /// asks for — one collection that does not exist is a few hundred bytes —
    /// so it proves nothing, whichever cap the reader happened to run under.
    static func negativeControlProvesNotFound(
        status: Int,
        body: Data,
        bodyExceededCap: Bool,
        requestedURL: URL
    ) -> Bool {
        classifyAbsenceWitness(
            status: status,
            body: body,
            bodyExceededCap: bodyExceededCap,
            requestedURL: requestedURL
        ) == .absent
    }

    /// Lowercased extension of a storedKey (after the last `.` of the last path
    /// component), or `""` when it has none. Shared by the HTML veto and the
    /// negative-control key so the two can never disagree about what was asked
    /// for.
    ///
    /// The leaf is taken at BYTE level (`keySegments`): a `/` fused with a
    /// combining mark is one Character, so a grapheme split hands this the whole
    /// key and the extension is then read out of a folder name.
    static func probeKeyExtension(_ storedKey: String) -> String {
        let name = keySegments(storedKey).last ?? storedKey
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// Extensions whose legitimate content IS an HTML document, so an HTML body
    /// under one of these names is evidence of nothing. Deliberately tiny: only
    /// `html` is on the output allowlist, and the other two exist because the
    /// retry path probes keys minted from user filenames.
    static let htmlBearingExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// The size to report for a whole-representation `200`, or nil when the
    /// headers cannot support one.
    ///
    /// `Content-Length` is the whole file here precisely BECAUSE the server
    /// ignored the range — the full body is what it is describing. (On a `206`
    /// it is the range's size, which is why that arm reads the total out of
    /// `Content-Range` instead; reporting 1 byte would sail a multi-GB download
    /// straight past the large-download confirm.)
    ///
    /// Gated on the response coding: under a content coding the header counts
    /// ENCODED bytes while `URLSession` hands the app decoded ones, so the
    /// number would be a wrong size on a real file. No size is better than a
    /// wrong one — the chip renders without it and the confirm gate stands down.
    static func wholeRepresentationLength(_ evidence: FileProbeEvidence) -> Int64? {
        guard responseCodingIsIdentity(evidence.contentEncoding),
              let raw = evidence.contentLength,
              let total = httpDecimal(raw.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return total
    }

    /// Whether the response arrived unencoded. The probe asks for
    /// `Accept-Encoding: identity`; absent header or a literal `identity` both
    /// mean it was honoured, and anything else means an intermediary compressed
    /// the body regardless.
    static func responseCodingIsIdentity(_ contentEncoding: String?) -> Bool {
        guard let contentEncoding else { return true }
        let coding = contentEncoding.trimmingCharacters(in: .whitespaces).lowercased()
        return coding.isEmpty || coding == "identity"
    }

    /// The `(first, last, total)` of a `Content-Range` on a SATISFIED range
    /// response, or nil when the header is absent, malformed, or refuses to name
    /// a total.
    ///
    /// Requires `bytes <first>-<last>/<total>` with `first == 0` (we asked from
    /// byte 0; an answer about another offset is not answering our request),
    /// `first <= last < total`, and `total >= 1`. A `*` total
    /// ("complete-length unknown") is rejected: legal HTTP, but it names no size
    /// for the chip and leaves the caller unable to check the body against the
    /// range. `last` is not pinned to 0 — a proxy may widen a range — but the
    /// caller MUST then require exactly `last - first + 1` delivered bytes,
    /// which is the actual integrity check.
    static func satisfiedRange(_ header: String?) -> (first: Int64, last: Int64, total: Int64)? {
        guard let parts = rangeHeaderParts(header),
              let total = httpDecimal(parts.total), total >= 1 else {
            return nil
        }
        let bounds = parts.range.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let first = httpDecimal(bounds[0]), first == 0,
              let last = httpDecimal(bounds[1]), last >= first, last < total else {
            return nil
        }
        return (first, last, total)
    }

    /// Whether a `Content-Range` says "the representation is zero bytes long" —
    /// `bytes` `*`/`0`, the only 416 that means "this file exists and is empty".
    static func emptyRepresentationRange(_ header: String?) -> Bool {
        guard let parts = rangeHeaderParts(header), parts.range == "*" else { return false }
        return httpDecimal(parts.total) == 0
    }

    /// Split a `Content-Range` into its range and complete-length halves, after
    /// checking the unit is `bytes`. Returns nil on anything that is not exactly
    /// `<unit> <range>/<total>`.
    private static func rangeHeaderParts(_ header: String?) -> (range: String, total: String)? {
        guard let header else { return nil }
        let fields = header.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
        let halves = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        return (String(halves[0]), String(halves[1]))
    }

    /// HTTP's `1*DIGIT` — ASCII digits only, at least one. Stricter than
    /// `Int64.init` on purpose: that accepts signed forms (`+0`, `-1`) and
    /// non-ASCII digit scalars, none of which any server should be sending and
    /// all of which would feed the range arithmetic something it did not read.
    private static func httpDecimal(_ text: some StringProtocol) -> Int64? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(text)
    }

    /// Whether the response arrived from the resource we NAMED. A same-host
    /// redirect to `/login` is the cheapest form of the wall — `URLSession`
    /// follows it, so the app sees a clean 200 and only the final URL remembers
    /// the detour.
    ///
    /// Compares LAST PATH COMPONENTS, not whole URLs: a server is entitled to
    /// rewrite the host, add a signed-download query, or move the file under a
    /// different prefix, and none of that changes which file came back. A nil
    /// final URL is not evidence of anything, so it passes. The requested key's
    /// leaf comes off `keySegments`, so the comparison is against a leaf even
    /// when a combining mark fuses with the separator ahead of it — a grapheme
    /// split would compare a whole key against one component and call a response
    /// from exactly the name we asked for a redirect.
    ///
    /// LIMIT, and the reason this is a cheap pre-filter rather than the
    /// mechanism: it can only see redirects the CLIENT was told about. An nginx
    /// `try_files` fallback rewrites internally and the response still carries
    /// the requested URL. Only the negative control catches that.
    static func responseCameFromRequestedName(_ evidence: FileProbeEvidence) -> Bool {
        guard let final = evidence.finalPathComponent else { return true }
        let requested = keySegments(evidence.requestedKey).last ?? evidence.requestedKey
        return final == requested
    }

    /// Whether this response served an HTML DOCUMENT under a key that is not
    /// supposed to be one — the login-page / control-panel / SPA-fallback /
    /// directory-index signature. Two independent readings, either of which
    /// vetoes:
    ///
    ///   - the server LABELLED it HTML (`Content-Type`), or
    ///   - the body OPENS as an HTML document (`bodySniffsAsHTMLDocument`).
    ///
    /// Both are kept even though a misconfigured origin can mislabel a genuine
    /// file (`AddType text/html .pdf`, a location-wide `default_type`, a proxy
    /// or NAS middleware overwriting the header), because the two failures are
    /// not symmetric: a mislabelled real file costs a missing chip on one server
    /// until its owner fixes the header, while a trusted login page costs every
    /// user of every wall a downloaded HTML file wearing a real filename.
    ///
    /// EXTENSION-AWARE, NOT A BLANKET REJECT: `html` is on the output allowlist,
    /// so a real deliverable CAN be an HTML document and "body contains
    /// `<html>` → not a file" would silently lose every one of them. The veto
    /// fires only when the served content and the requested name DISAGREE; when
    /// they agree, the negative control is what decides.
    ///
    /// KNOWN COST, stated as a decision: a `README.md` that genuinely OPENS with
    /// an HTML document, or an `.xml` whose root element is `<html>`, is vetoed
    /// and never chips. Anchoring the sniff to the document start keeps that to
    /// files that open as HTML rather than merely mention it, and `.ambiguous`
    /// leaves both the turn open and the rest of the reply still being scanned.
    static func servesHTMLDocumentForNonHTMLKey(_ evidence: FileProbeEvidence) -> Bool {
        guard !htmlBearingExtensions.contains(probeKeyExtension(evidence.requestedKey)) else {
            return false
        }
        return contentTypeIsHTMLDocument(evidence.contentType)
            || bodySniffsAsHTMLDocument(evidence.bodyPrefix)
    }

    /// Whether a `Content-Type` declares an HTML document. Media type only —
    /// parameters (`; charset=utf-8`) are stripped, and the comparison is exact
    /// so `text/html-ish` inventions do not match.
    static func contentTypeIsHTMLDocument(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let media = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return media == "text/html" || media == "application/xhtml+xml"
    }

    /// Whether a bounded body prefix OPENS an HTML document.
    ///
    /// ANCHORED to the document start, after a BOM, whitespace, at most one XML
    /// declaration (the XHTML login-page shape), and any leading comments (a
    /// generated banner above the doctype is ordinary). That anchor is the whole
    /// safety margin: an unanchored "contains `<html>`" would veto any Markdown,
    /// log, source file or CSV that merely mentions the tag, and those are
    /// ordinary legitimate outputs.
    ///
    /// The opening token must END where the token ends — whitespace, `>`, `/`,
    /// or end of input. Without that, `<htmlReport>` (a perfectly ordinary XML
    /// root element) reads as an HTML document and a real file is refused.
    ///
    /// Decoded leniently — binary file bytes yield replacement characters and
    /// simply fail to match, which is the correct answer for them.
    static func bodySniffsAsHTMLDocument(_ prefix: Data) -> Bool {
        guard !prefix.isEmpty else { return false }
        var text = Substring(String(decoding: prefix, as: UTF8.self))
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        text = text.drop(while: { $0.isWhitespace })
        if text.prefix(5).lowercased() == "<?xml", let close = text.range(of: "?>") {
            text = text[close.upperBound...].drop(while: { $0.isWhitespace })
        }
        // Bounded: a prefix full of `<!--` with no terminator must not spin, and
        // no real document opens with a dozen banners.
        var skipped = 0
        while skipped < 8, text.hasPrefix("<!--"), let close = text.range(of: "-->") {
            text = text[close.upperBound...].drop(while: { $0.isWhitespace })
            skipped += 1
        }
        return opensWithToken(text, "<!doctype html") || opensWithToken(text, "<html")
    }

    /// `token` at the very start of `text`, followed by a character that ENDS
    /// it (whitespace, `>`, `/`) or by nothing at all. See
    /// `bodySniffsAsHTMLDocument` for why the boundary is load-bearing.
    private static func opensWithToken(_ text: Substring, _ token: String) -> Bool {
        guard text.prefix(token.count).lowercased() == token else { return false }
        guard let next = text.dropFirst(token.count).first else { return true }
        return next.isWhitespace || next == ">" || next == "/"
    }

    /// Map a raw HTTP status from the NON-MUTATING reach+auth probe (a GET of a
    /// key that cannot exist) to a `FileReachabilityOutcome`. Inverted vs
    /// `probeStatusPrefilter` (see the enum): `404` is the intended PASS.
    ///   - `404`                    → `.reachAuthOK`
    ///   - `401` / `403`            → `.authFailed`
    ///   - `200` / `206` / `416`    → `.suspicious` (a real WebDAV 404-probe never
    ///                                 returns "exists"; a `200` here is a
    ///                                 Control-UI/login page)
    ///   - `3xx`                    → `.suspicious` (a raw redirect surfaced by a
    ///                                 non-redirect-following session; in
    ///                                 production `URLSession` follows redirects
    ///                                 and this classifies the FINAL status)
    ///   - anything else            → `.inconclusive` (fail closed — `405`/`501`/
    ///                                 other `4xx`/`5xx` are NOT auth failures)
    static func classifyReachability(status: Int) -> FileReachabilityOutcome {
        switch status {
        case 404:
            return .reachAuthOK
        case 401, 403:
            return .authFailed
        case 200, 206, 416:
            return .suspicious
        case 300...399:
            return .suspicious
        default:
            return .inconclusive
        }
    }

    // MARK: - Strict directory listing (the authority on agent output)
    //
    // `StrictListingParserDelegate` is the ONLY `207` parser in this file,
    // deliberately. A tolerant sibling that accumulates whatever it can and
    // reports no failure is the wrong shape for every consumer this app has — it
    // cannot see the HTTP status, it keeps entries completed before a parse
    // fault, it ignores per-resource `<propstat><status>` and it discards the
    // parent path, so a non-`207`, a truncated body and an empty directory all
    // read as "the agent produced nothing", which is the one conclusion that
    // CLOSES a turn. Keeping one next to the strict one is how a future consumer
    // picks the wrong one by accident, so there is only the strict one. A
    // deferred in-app file browser that wants leniency states its own tolerance
    // at ITS call site, over `ListingVerdict`, rather than reviving a second
    // parser here.
    //
    // TWO CONSUMERS, ONE PARSER, OPPOSITE QUESTIONS. `parseListing` asks the
    // delegate "which direct children of this collection may become chips" and
    // `multistatusWitnessesAbsence` asks it "did the server say this exact
    // collection is not there" — and they share the href resolver
    // (`resolveListingHref`) as well as the parser, so neither can grow its own
    // idea of which body is about which collection. A second definition of that
    // is precisely what let Settings certify a lane green while every turn
    // concluded the opposite.

    /// Most `<response>` elements one listing may describe. Refused, never
    /// truncated — see `FileTransferListingRefusal.tooManyEntries`.
    ///
    /// The listing caps live beside the parser that enforces them rather than in
    /// `Constants`, because a cap that drifts from its enforcement is a cap that
    /// silently stops holding.
    static let listingMaxEntries = 200

    /// Most bytes of `207` body one listing may occupy (256 KiB). The read is
    /// bounded on the wire by `BackgroundFileTransfer`; this is the same bound
    /// stated where the parse happens, so a caller that hands over an
    /// unbounded body is refused rather than parsed.
    static let listingMaxBytes = 256 * 1024

    /// Most bytes of `207` body the ABSENCE WITNESS will read (16 KiB), on the
    /// wire and again at the parse, exactly as the listing bound is applied.
    ///
    /// Its own cap rather than `listingMaxBytes` because it bounds a different
    /// answer to a different question in a place with a different budget. This
    /// body is a multistatus describing ONE collection that is not there — a
    /// four-hundred-byte document in every honest case — where the listing's
    /// budget is sized for `listingMaxEntries` rows of properties. And its
    /// busiest reader sits on the DISPATCH CRITICAL PATH: every send waits for
    /// the pre-dispatch witness, a pure-text
    /// turn included, so the ceiling on what a stranger's server can make the app
    /// buffer before a message goes out has to be the smallest one that still
    /// admits every truthful answer. Anything past it is over-cap, and over-cap
    /// is `.occupied` — a catch-all host's login page is refused on size rather
    /// than streamed into memory to learn that it sent one.
    static let absenceWitnessMaxBytes = 16 * 1024

    /// The URL `PROPFIND` targets for `collectionKey` — the ONE place the
    /// request builder and the href resolver agree on what was asked for. A
    /// listing that resolved hrefs against a different URL than it requested
    /// would accept entries from a folder it never asked about.
    static func listingCollectionURL(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String
    ) -> URL {
        collectionKey.isEmpty ? snapshot.baseURL : snapshot.baseURL.appending(path: collectionKey)
    }

    /// The negative-control key for a LISTING: a sibling collection of
    /// `collectionKey`, under the same parent, that cannot exist.
    ///
    /// A sibling rather than `negativeControlKey`'s root-relative file key,
    /// because the two ask different questions. That one asks "can this server
    /// 404 a missing FILE at the root"; this one has to ask "can this server 404
    /// a missing COLLECTION in the very directory whose listing I am about to
    /// believe" — servers route on both the method and the prefix, so a control
    /// that lands somewhere else can take a different code path and answer a
    /// question nobody asked.
    ///
    /// Minted fresh per call with 16 hex of entropy and never persisted: a
    /// cached verdict is a verdict about a server that has since changed, and
    /// the whole point of the control is that it is contemporaneous with the
    /// listing it vouches for.
    static func negativeControlCollectionKey(siblingOf collectionKey: String) -> String {
        let nonce = String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
        )
        let stem = "__conduck_absent_\(nonce)"
        var components = keySegments(collectionKey)
        guard !components.isEmpty else { return stem }
        components.removeLast()
        components.append(stem)
        return components.joined(separator: "/")
    }

    /// THE ABSENCE WITNESS'S RULE, from a `PROPFIND Depth: 0` answer about the
    /// collection this dispatch is about to name — the pre-dispatch freshness
    /// assertion. A TAXONOMY rather than a Bool, because exactly one of its
    /// non-absent answers means something different to the user: a server that
    /// does not implement `PROPFIND` at all is not a server that failed, it is a
    /// server that cannot do this. Folding the two is what made a plain
    /// nginx-DAV lane complain on every single turn about a limitation it was
    /// always going to have.
    ///
    /// THIS FORM READS THE STATUS LINE ONLY, and it is deliberately the WEAKER
    /// of the two: it cannot reach `.absent` for a `207`, because the sentence
    /// that would justify it lives in the body. Every production caller uses the
    /// body-aware overload below, which delegates the whole taxonomy here and
    /// re-reads exactly one of its answers. One definition, one place, two entry
    /// points — the alternative, a second copy of "what does absence look like",
    /// is what let Settings certify a lane green while every turn concluded the
    /// opposite about the same server.
    ///
    /// WHAT THE ASSERTION REPLACES, and why it is both weaker and better.
    /// Creating the box (`MKCOL 201`) was a server-observed CREATION event,
    /// which is strictly stronger evidence. It is not used, because creating the
    /// directory makes it owned by whoever the WebDAV lane runs as, and the
    /// agent that must write into it usually runs as somebody else — so the
    /// stronger evidence came bundled with the failure it was evidence about.
    /// This assertion buys a server-observed ABSENCE at the same one-request
    /// cost and changes nothing about who owns the directory.
    ///
    /// A verdict here shows the user nothing on its own — the mint decides what,
    /// if anything, is said — and the privacy posture is unchanged either way:
    /// no status, URL, key, or byte of body leaves the classification.
    static func classifyAbsenceWitness(status: Int) -> FileServerAbsenceWitness {
        // The one green light a status line can give. Definition shared with
        // `negativeControlProvesNotFound` so the app cannot hold two ideas of
        // what a definite miss looks like.
        if negativeControlProvesNotFound(status: status) { return .absent }
        // `405 Method Not Allowed` is what a compliant HTTP server answers for a
        // method it knows about but does not implement on this resource, and
        // `501 Not Implemented` is what it answers for a method it does not
        // recognise at all (RFC 9110 §15.5.6 / §15.6.2). Plain nginx with
        // `dav_methods PUT DELETE` answers one of the two for PROPFIND on every
        // path it serves, which is precisely the "uploads yes, returns never"
        // population this case exists to keep quiet. STRUCTURAL and permanent
        // for as long as the server is configured that way — a retry cannot
        // change it, so re-probing it every turn buys nothing.
        if status == 405 || status == 501 { return .cannotAnswer }
        // A `207` (or any other 2xx) for a path carrying `OutboxKey`'s fresh
        // entropy is either a collision — astronomically unlikely, therefore far
        // more likely a bug in the mint — or a namespace that answers
        // everything, UNLESS the `207`'s own body says otherwise, which only the
        // overload below can see. NOT `.cannotAnswer`: a wall that 200s every
        // path is a misconfiguration in front of a server that may well speak
        // WebDAV, and calling it a permanent incapability would hide a fixable
        // fault behind a displayed limitation.
        if (200...299).contains(status) { return .occupied }
        // Everything else — `401`/`403` (the credential stopped working), `5xx`
        // (the server is sick), a redirect, a portal. All of them are things
        // that were working and stopped, which is the actionable case.
        return .indeterminate
    }

    /// The same rule with the `207`'s own body in hand — THE form every
    /// production caller uses, and the only one that can call a compliant
    /// multistatus what it is.
    ///
    /// WHY IT HAS TO EXIST. RFC 4918 lets a server answer a `PROPFIND` of a
    /// collection that is not there in two ways: a bare `404`, or a `207`
    /// multistatus whose one `<response>` names that collection and carries a
    /// response-level `404`. Both are correct; commercial WebDAV hosts send the
    /// second. Read from the status line alone the second is indistinguishable
    /// from a namespace that answers everything, so a status-only reading classes
    /// those servers `.occupied` on every dispatch — a folder-less row under every
    /// agent turn, permanently, with no in-app action that could silence it, and
    /// a staged Test Connection that reports "couldn't verify" about a lane that
    /// works perfectly.
    ///
    /// IT DELEGATES THE TAXONOMY AND RE-READS ONE ANSWER. Every non-`207` status
    /// is whatever the status-only form says it is, unchanged. A `207` is
    /// re-examined, and may become `.absent` only on an unambiguous inner
    /// not-found; anything else stays `.occupied`.
    ///
    /// FAILS CLOSED ON EVERYTHING IT CANNOT SETTLE — over-cap, truncated, empty,
    /// unparseable, not a multistatus, more than one `<response>`, a `<response>`
    /// about some other href, no readable inner status, an inner `2xx`. The list
    /// is long on purpose: `.absent` is what lets a folder name go on the wire,
    /// so the only reading that may produce it is the one a compliant server
    /// meant.
    ///
    /// AND BELIEVING THAT NEGATIVE IS SAFE, which is why the body may decide it
    /// here while every POSITIVE verdict in this file demands a control. `.absent`
    /// mints nothing: a wrong one costs Conduck naming an output folder that
    /// already exists, and no chip, no download and no file follow from it.
    /// `BackgroundFileTransfer.listCollection` still runs its OWN negative
    /// control against a sibling that cannot exist before it believes a single
    /// entry — decided by THIS rule, so what it demands is not a status but a
    /// per-request document naming the exact collection that was asked for and
    /// saying it is not there, which a blind catch-all cannot produce. The
    /// residual is the one stated at `negativeControlProvesNotFound`: a
    /// deliberately hostile server can say anything, and the answer to a hostile
    /// server is the staged test's write-then-byte-echo against a server the
    /// user owns, never a control.
    ///
    /// `bodyExceededCap` is the wire read's own report that it stopped early, and
    /// it is separate from `body.count` deliberately: a truncated prefix can
    /// parse cleanly right up to the cut, so the only thing that knows the
    /// document was incomplete is the reader that cut it.
    ///
    /// PRIVACY: takes a body and a URL, returns a taxonomy value. Nothing here
    /// logs, and no verdict carries a status, a path, or a byte of the body.
    static func classifyAbsenceWitness(
        status: Int,
        body: Data,
        bodyExceededCap: Bool,
        requestedURL: URL
    ) -> FileServerAbsenceWitness {
        let fromStatus = classifyAbsenceWitness(status: status)
        guard status == 207, fromStatus == .occupied else { return fromStatus }
        return multistatusWitnessesAbsence(
            body: body, exceededCap: bodyExceededCap, requestedURL: requestedURL
        ) ? .absent : .occupied
    }

    /// Whether a `207` body is the compliant way of saying "that collection is
    /// not there", about the collection that was actually asked for.
    ///
    /// Runs the SAME strict parser and the SAME href resolver the listing does,
    /// rather than a lenient scan for a `404` anywhere in the document: a body
    /// that a permissive reader half-understands is a body nobody understood,
    /// and here that would put a folder name on the wire.
    ///
    /// EXACTLY ONE `<response>`, and no more. A question about ONE collection
    /// that is not there has exactly one honest answer row at any depth — there
    /// are no children to enumerate; a body with two is
    /// answering something other than what was asked, and picking the row that
    /// suits us out of a set we did not understand is the same mistake as
    /// scanning for a status.
    ///
    /// THE INNER STATUS MUST BE THE RESPONSE'S OWN, never a `<propstat>`'s. A
    /// `<propstat>` `404` says "you asked for properties I do not have on this
    /// resource", which is an ordinary answer ABOUT AN EXISTING resource; only
    /// the response-level `<status>` says the resource itself is not there. `410
    /// Gone` counts alongside `404` because it is the same sentence with a
    /// history attached (RFC 9110 §15.5.5 / §15.5.11).
    ///
    /// `410` COUNTS AS AN INNER STATUS AND NOWHERE ELSE. A bare `410` STATUS
    /// LINE is `.indeterminate`, because the status-only form reaches `.absent`
    /// through `404` alone. The asymmetry is deliberate and stays: it errs in
    /// the direction that costs nothing. Admitting a status-line `410` would let
    /// one more shape put a folder name on the wire — the only direction with a
    /// price — while refusing it costs a single turn's automatic delivery on a
    /// server that answers `410` for a path it has never heard of. Inside a
    /// multistatus the same code is safe for a reason the status line cannot
    /// offer: it arrives with the single-`<response>` shape and the href match
    /// already proved, so the document has demonstrated it is talking about the
    /// exact collection that was asked for.
    private static func multistatusWitnessesAbsence(
        body: Data,
        exceededCap: Bool,
        requestedURL: URL
    ) -> Bool {
        // A body the reader had to cut proves nothing: the rest of the document
        // could say anything, including that the collection is right there.
        guard !exceededCap, !body.isEmpty, body.count <= absenceWitnessMaxBytes else { return false }
        guard let baseComponents = listingPathComponents(of: requestedURL) else { return false }

        // `maxResponses: 2` so the parser stops as soon as the body is provably
        // not the one-row shape this asks about, instead of walking a document
        // whose verdict is already decided.
        let delegate = StrictListingParserDelegate(maxResponses: 2)
        let parser = XMLParser(data: body)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false   // match local names; tolerate any/no prefix
        // An untrusted body must not be able to make the parser fetch anything.
        parser.shouldResolveExternalEntities = false
        let completed = parser.parse()

        guard delegate.refusal == nil, completed, parser.parserError == nil,
              delegate.sawMultistatus else {
            return false
        }
        guard delegate.responses.count == 1, let response = delegate.responses.first else {
            return false
        }
        // The row has to be ABOUT the collection that was asked for. Resolved the
        // way the listing resolves an href — relative references against the
        // collection with a trailing slash, percent-decoded per component,
        // origin-checked, matched from the END of the path so a proxy that
        // strips its own mount point is still understood — because a second
        // opinion on "is this body about my folder" is a second thing to keep
        // in step.
        guard let resolved = resolveListingHref(
                  response.href, requestedURL: requestedURL, baseComponents: baseComponents),
              case .collectionItself = resolved else {
            return false
        }
        guard let inner = response.resourceStatusCode else { return false }
        return inner == 404 || inner == 410
    }

    /// THE listing verdict, from one PROPFIND response. Pure — the network half
    /// (the bounded read and the negative control) is
    /// `BackgroundFileTransfer.listCollection`.
    ///
    /// THE THING THIS EXISTS TO PREVENT: a server that is not answering about
    /// the folder Conduck minted, read as if it were. Every gate below closes a
    /// specific way that happens, and every one of them fails to `.unusable`
    /// rather than to an empty folder, because "the agent produced nothing" is a
    /// conclusion that CLOSES a turn and must never be reachable from a response
    /// nobody understood.
    ///
    ///   - **Status.** Only `207` is a listing. `404` is `.absent` — its own
    ///     verdict, because the box Conduck created being gone is a different
    ///     fact from the server being unreadable, and only one of them is worth
    ///     telling the user about. Every other status is a refusal, `200`
    ///     emphatically included: a uniform-`200` SSO wall answers every path
    ///     with its own HTML, and requiring `207` is what a wall cannot fake.
    ///   - **Completeness.** `XMLParser.parse()`'s `Bool` DECIDES here. A body
    ///     that faults mid-document is `.malformedBody`, never the entries that
    ///     completed before the fault — a truncated listing looks exactly like a
    ///     real short one, and the difference is a file silently missing from
    ///     the user's device.
    ///   - **Shape.** The root element must be `multistatus`, every `<response>`
    ///     must carry exactly one `<href>`, and nesting is bounded. A response
    ///     that cannot be understood IN FULL refuses the whole listing rather
    ///     than being skipped, because a skipped response is an entry that
    ///     vanished without anyone deciding it should.
    ///   - **Per-resource status.** Properties are read only out of a `2xx`
    ///     `<propstat>`; a resource whose own `<status>` is not `2xx`, or whose
    ///     every propstat failed, is dropped. RFC 4918 lets a `207` carry
    ///     not-found rows, and emitting one as a normal entry mints a chip for a
    ///     file the server just said it does not have.
    ///   - **Provenance.** Every href is resolved against the REQUESTED URL and
    ///     must land on the same origin as a DIRECT child of it — matched from
    ///     the END of the path, so a proxy that strips its own mount point does
    ///     not turn a good listing into a permanent refusal
    ///     (`isRequestedCollectionTail`). The collection itself is suppressed (a
    ///     `Depth: 1` of a non-root collection always emits itself; a
    ///     name-emptiness test only catches the ROOT case). Grandchildren,
    ///     parents and foreign hosts refuse the listing.
    ///   - **Separators.** The path is split into components BEFORE each one is
    ///     percent-decoded, and a component that decodes to something containing
    ///     a separator, a NUL, or a dot segment refuses the listing. Decoding
    ///     first is how `%2E%2E%2F%2E%2E%2Fetc%2Fpasswd` becomes a single entry
    ///     named `../../etc/passwd`, and `URL.appending(path:)` does not
    ///     normalise dot segments back out.
    ///   - **Bounds.** Body bytes and response count are capped.
    ///   - **Duplicate names** refuse the listing — one real collection cannot
    ///     hold two — and the comparison is Swift `String` equality, i.e.
    ///     CANONICAL EQUIVALENCE, so the NFC and NFD spellings of one name
    ///     collide here. That is DELIBERATE, and it is a fail-closed boundary
    ///     rather than an oversight: everything downstream keys files by the
    ///     same String equality (the conversation store's key lookups, the row
    ///     formatters, the detail model's chip dedupe), so two spellings this
    ///     parser admitted as distinct would be collapsed into one somewhere
    ///     later, in a place with no way to say what happened. Deduping on UTF-8
    ///     bytes instead would pass the parser and lose a file silently.
    ///     THE HONEST CONSEQUENCE: a server whose folder really does list both
    ///     spellings of one name makes that folder unreadable until the user
    ///     renames one of them. A refusal the user can act on beats a file that
    ///     disappears without one.
    ///   - **Directories** are dropped: a nested folder is not a deliverable.
    ///
    /// What this function deliberately does NOT do is judge the NAME. That is
    /// `outboxEntryVerdict`'s job and it is a separate question: this one
    /// answers "is this a direct child of the folder I asked about", that one
    /// answers "is this a name I am willing to mint a key for".
    ///
    /// PRIVACY: takes a body and a URL, returns entries or a taxonomy value.
    /// Nothing here logs, and no refusal carries a name or a path.
    static func parseListing(
        status: Int,
        body: Data,
        requestedURL: URL
    ) -> FileServerListingVerdict {
        switch status {
        case 207:
            break
        case 404:
            // The one non-207 that is a fact about the FOLDER rather than about
            // the server. Sound to act on because absence mints nothing: a wrong
            // `.absent` costs a row telling the user to check their server,
            // while a wrong `.entries` costs them a downloaded file that is not
            // theirs.
            return .absent
        case 401, 403:
            return .unusable(.unauthorized)
        case 500...599:
            return .unusable(.serverError)
        default:
            return .unusable(.notMultiStatus)
        }

        guard body.count <= listingMaxBytes else { return .unusable(.bodyTooLarge) }
        guard !body.isEmpty else { return .unusable(.malformedBody) }
        guard let baseComponents = listingPathComponents(of: requestedURL) else {
            return .unusable(.malformedBody)
        }

        let delegate = StrictListingParserDelegate(maxResponses: listingMaxEntries)
        let parser = XMLParser(data: body)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false   // match local names; tolerate any/no prefix
        // An untrusted body must not be able to make the parser fetch anything.
        parser.shouldResolveExternalEntities = false
        let completed = parser.parse()

        // The delegate's own refusal is read FIRST: it aborts the parse to stop
        // work, so `completed` is false for its cases too, and reporting them all
        // as malformed would lose the one that says the folder is simply too big.
        if let refusal = delegate.refusal { return .unusable(refusal) }
        guard completed, parser.parserError == nil, delegate.sawMultistatus else {
            return .unusable(.malformedBody)
        }

        var entries: [FileServerEntry] = []
        var seen = Set<String>()
        for response in delegate.responses {
            guard let resolved = resolveListingHref(
                response.href, requestedURL: requestedURL, baseComponents: baseComponents
            ) else {
                return .unusable(.entryOutsideCollection)
            }
            // The collection's own row is resolved and dropped BEFORE its
            // per-resource status is consulted: it is not a candidate either way,
            // and a server that reports the collection itself oddly must not
            // refuse a listing that is otherwise fine.
            guard case let .child(name) = resolved else { continue }
            // Canonical equivalence, deliberately — see the duplicate-names
            // bullet above. Two spellings of one name are one name to every
            // consumer downstream, so they are one name here too.
            guard seen.insert(name).inserted else { return .unusable(.duplicateEntry) }
            guard response.isUsableResource else { continue }
            guard !response.isDirectory else { continue }
            entries.append(FileServerEntry(name: name, isDirectory: false, byteSize: response.byteSize))
        }
        return .entries(entries)
    }

    /// Whether an entry name from a listing may become a stored key, and WHAT
    /// REFUSED IT when it may not. **REJECTS, NEVER REPAIRS** — a refusal means
    /// "do not deliver this file", not "clean it up".
    ///
    /// WHY NOT `makeStoredKey`. That is a MINTER: it prepends `<8hex>__` and a
    /// folder, so running a server-supplied name through it produces a key that
    /// does not exist on the server and a file that can never be fetched. The
    /// name here already exists — the only question is whether Conduck is
    /// willing to address it — so the answer has to be yes or no.
    ///
    /// The standard is a POSITIVE POLICY WITH NAMED EXCEPTIONS, derived from
    /// what the name's two consumers can survive — a path inside Conduck's own
    /// instruction line (`ConverseRequest.spliceServerFileRefs`, which renders a
    /// key carrying anything outside `[A-Za-z0-9._-/]` inside double quotes) and
    /// a rendered chip label. It is NOT the mint's alphabet: a name the user's
    /// own agent wrote is not a name Conduck chose, and measuring `Übersicht.md`
    /// against `[A-Za-z0-9._-]` discards it in silence.
    ///
    ///   - **An ACCEPT-LIST of Unicode categories**, never a deny-list
    ///     (`outboxEntryScalarIsAddressable`), plus the literal subtractions
    ///     below.
    ///   - **A single path component**: no `/`, tested on UTF-8 BYTES, so a name
    ///     can never become a path.
    ///   - **Never `.` or `..`**, and never a leading `.` (a hidden file) or `-`
    ///     (a name that reads as a CLI option to the agent's own tooling). The
    ///     leading-character test reads the first BYTE, because a `.` followed
    ///     by a combining mark is ONE grapheme cluster equal to neither, so a
    ///     Character test waves through a `.́hidden.pdf` the filesystem hides all
    ///     the same.
    ///   - **Never opening or closing on whitespace.** Only U+0020 survives the
    ///     alphabet, so this is the leading/trailing SPACE rule: the display
    ///     half trims and collapses runs while the key keeps them verbatim, and
    ///     a name that disagrees with the path beside it sends the agent looking
    ///     for a file that is not there.
    ///   - **Never opening on a combining mark**, which is INTEROPERABILITY
    ///     policy and nothing more: a mark with nothing to combine with attaches
    ///     to whatever character happens to precede it — the bullet's opening
    ///     quote, the `/` before it in the path, the previous cell in a file
    ///     browser — so the name shown is not the name stored. It is explicitly
    ///     NOT what keeps the path seam closed: concatenation never alters
    ///     bytes, and what closes that seam is that every separator decision in
    ///     this lane reads scalars or bytes rather than Characters.
    ///   - **Both length budgets**: `storedKeyComponentMaxCharacters` and
    ///     `storedKeyComponentMaxBytes`. Once a name may be non-ASCII the two
    ///     stop being the same measurement, and only the byte one is the
    ///     filesystem's.
    ///   - **An extension on `allowedExtensions`** — the outbound TYPE gate,
    ///     which is what keeps a `.mobileconfig` or a live `.sqlite` out of the
    ///     lane. Read by `outboxEntryExtension`, which requires the RAW slice to
    ///     be ASCII alphanumeric BEFORE any case folding. It splits in two:
    ///     `.refusedUntyped` when there is no readable extension at all,
    ///     `.refusedExtension` when there is one and it is off the list.
    ///
    /// A SHAPE REFUSAL NAMES ITS CLASS, never its name: the length budgets answer
    /// `.overlong`, the leading/trailing-space guard answers
    /// `.whitespaceBounded`, and the other seven guards answer `.unusable`
    /// (`OutboxShapeRefusal`). The length guard runs FIRST for a reason unrelated
    /// to reporting — it bounds every scan below it against an adversary-chosen
    /// string — and the classification simply follows the guard that fired.
    ///
    /// THE TYPE GATE IS DELIBERATELY LAST, and every consumer of the classified
    /// refusal depends on it staying last. Reaching it proves guards 1–9 already
    /// passed, which is precisely what makes a type-refused name exactly as
    /// display-safe as a delivered chip's label — same two consumers, same
    /// established properties. Move a shape guard below it and a name that never
    /// earned those properties starts arriving with a payload attached.
    ///
    /// IT IS NOT A CONTENT-SECURITY BOUNDARY, and reading it as one is the
    /// mistake it invites. The gate reads the FILENAME and never the bytes, so a
    /// hostile agent renames to `.txt` and walks straight through it while an
    /// honest one is the only party it ever stops. What it actually decides is
    /// narrower and still worth deciding: what Conduck opens automatically, with
    /// no user involvement. Widening the list is therefore a UX call about the
    /// default, never a security regression, and narrowing it protects nobody
    /// from an adversary.
    ///
    /// SURROGATES get no arm, and the reason is worth stating so nobody adds
    /// one: `Unicode.Scalar` cannot hold a surrogate, and a listing whose bytes
    /// are not valid UTF-8 never reaches here at all —
    /// `removingPercentEncoding` answers nil and `parseListing` refuses the
    /// whole folder.
    ///
    /// `allowedExtensions` is a parameter so the gate is testable without the
    /// detector and so a caller with a narrower policy can pass one; the default
    /// IS the shipped outbound allowlist, because a second copy of that list is
    /// a second thing to keep in step.
    ///
    /// `nonisolated` because the prose-scan lane applies the same policy and
    /// runs off the main actor (`FileTransferOutputDetector.extractCandidates`,
    /// hopped through `Task.detached`). Pure, content-free, and it logs nothing.
    nonisolated static func outboxEntryVerdict(
        _ name: String,
        allowedExtensions: Set<String> = FileTransferOutputDetector.outputAllowlist
    ) -> OutboxEntryVerdict {
        // SPLIT FROM THE LENGTH GUARD BELOW, not folded into it: an empty name is
        // not a long one, and the sentence `.overlong` earns — ask for a shorter
        // name — is the one thing an empty name can never act on.
        guard !name.isEmpty else { return .refusedShape(.unusable) }
        // FIRST, AND IT STAYS FIRST. Every scan below walks the name, so the
        // budgets are what keep an adversary-chosen string from buying an
        // unbounded walk per listing entry. The classification consequence is
        // stated on `OutboxShapeRefusal.overlong`: this reports the first thing
        // wrong, which is still true of a name that is also unusable.
        guard name.count <= storedKeyComponentMaxCharacters,
              name.utf8.count <= storedKeyComponentMaxBytes else {
            return .refusedShape(.overlong)
        }
        guard !name.utf8.contains(UInt8(ascii: "/")) else { return .refusedShape(.unusable) }
        // Closure form, not the bare function reference. Passing a static as a
        // VALUE converts it to a nonisolated function type, so a bare reference
        // makes this line depend on the `nonisolated` annotation below staying
        // put — drop that annotation and the same line becomes a Swift-6
        // isolation diagnostic instead of a compile. A closure body inherits
        // whatever isolation the caller has and is right either way.
        guard name.unicodeScalars.allSatisfy({ outboxEntryScalarIsAddressable($0) }) else {
            return .refusedShape(.unusable)
        }
        // TWO GUARDS, NOT ONE, so each answers only for what it actually saw. The
        // bindings cannot fail — the empty guard above already returned — but a
        // folded `guard let … , !isWhitespace` would answer "the name opens or
        // closes on a space" for a name with no scalars at all, which is a
        // sentence about a string nobody observed. The bindings are needed
        // regardless: the combining-mark guard below reads `first`.
        guard let first = name.unicodeScalars.first,
              let last = name.unicodeScalars.last else {
            return .refusedShape(.unusable)
        }
        guard !first.properties.isWhitespace, !last.properties.isWhitespace else {
            return .refusedShape(.whitespaceBounded)
        }
        guard !isCombiningMark(first) else { return .refusedShape(.unusable) }
        guard name != ".", name != ".." else { return .refusedShape(.unusable) }
        let firstByte = name.utf8.first
        guard firstByte != UInt8(ascii: "."), firstByte != UInt8(ascii: "-") else {
            return .refusedShape(.unusable)
        }
        // PAST EVERY SHAPE GUARD. From here the name is printable on the same
        // terms a delivered chip's label is, so both remaining refusals carry it
        // — that is what gives a user-facing refusal something honest to name.
        guard let ext = outboxEntryExtension(of: name) else { return .refusedUntyped(name: name) }
        guard allowedExtensions.contains(ext) else {
            return .refusedExtension(name: name, ext: ext)
        }
        return .deliverable(name)
    }

    /// The ACCEPT half of `outboxEntryVerdict`, for callers that only need yes
    /// or no: the name when it is deliverable, nil otherwise.
    ///
    /// IT IS NOT THE ONE TO REACH FOR WHEN THE ANSWER REACHES A USER. Its nil is
    /// ten different refusals wearing one face, and a caller that has to TELL
    /// someone what happened — a row, a caption, a sheet — must take the verdict,
    /// because that is the only form that knows whether a name may be shown.
    ///
    /// Kept as a shim rather than migrated away because the refusal corpus in
    /// `OutboxEntryValidatorTests` is the regression net for this gate, and it
    /// shares its hostile names VERBATIM with the outbound-mint tripwire in
    /// `ConverseWireTests` — rewriting those assertions to name a case would
    /// trade a proven net for a rewritten one, and would make the corpus brittle
    /// to a future re-split of the taxonomy that changes no verdict at all. A
    /// test asserting "this name is refused" genuinely does not care why.
    nonisolated static func validatedOutboxEntryName(
        _ name: String,
        allowedExtensions: Set<String> = FileTransferOutputDetector.outputAllowlist
    ) -> String? {
        guard case let .deliverable(name) = outboxEntryVerdict(
            name, allowedExtensions: allowedExtensions
        ) else { return nil }
        return name
    }

    /// Scalars an inbound entry name may not carry as LITERALS, whatever their
    /// Unicode category says about them.
    ///
    /// `"`, `` ` ``, `\` and `$` are the four characters that stay special
    /// INSIDE POSIX double quotes. The quoted branch of the wire render invites
    /// an agent to quote the path it was handed, and these would give it
    /// parameter expansion, command substitution and escaping anyway — quoting
    /// them would be theatre rather than containment.
    ///
    /// `[` and `]` are shell-inert and go for Conduck's OWN reason: the key
    /// rides inside Conduck's imperative block, so a name carrying brackets
    /// could introduce a second `[Conduck …]` scoping marker — the exact marker
    /// `ConverseRequest.wireDisplayName` folds out of the DISPLAY half, which
    /// leaving it addressable through the KEY half would simply reopen from the
    /// other side.
    ///
    /// `!` is NOT POSIX-special; it history-expands in an INTERACTIVE shell.
    /// Admitting it would mean narrowing the inertness claim to non-interactive
    /// shells — a condition about tooling Conduck does not run and cannot check
    /// from the client. A caveat that cannot be verified is worth less than a
    /// character almost no real filename carries, so the character goes.
    ///
    /// `/` is absent because it is refused one guard earlier, on BYTES — the
    /// reading `URL.appending(path:)` obeys, and the one a separator fused with
    /// a combining mark cannot hide from.
    nonisolated private static let outboxEntryRejectedScalars: Set<Unicode.Scalar> = [
        "\"", "`", "\\", "$", "[", "]", "!",
    ]

    /// Whether one scalar of an inbound entry name is addressable.
    ///
    /// AN ACCEPT-LIST, NEVER A DENY-LIST, and that choice is the design: a
    /// deny-list admits every scalar the running OS's Unicode tables do not yet
    /// describe, so the same filename would be accepted on one device and
    /// refused on another as ICU versions drift between OS releases. An
    /// accept-list fails CLOSED on the unknown, and a file the user can see is
    /// worth less confusion than a file that appears on the iPad and not on the
    /// Mac.
    ///
    /// ADMITTED: the graphic categories — letters, marks, numbers, punctuation,
    /// symbols — which is what makes `Übersicht.md`, `报告.pdf` and an emoji
    /// name ordinary deliverables, plus the ASCII space, which real filenames
    /// carry constantly. The marks arm is also what carries U+FE0F, the
    /// variation selector every emoji presentation depends on (`Mn`, not `Cf`).
    ///
    /// REFUSED, each for its own reason:
    ///   - Every OTHER whitespace scalar. `Zs`/`Zl`/`Zp` sit outside the graphic
    ///     set, so this is structural rather than a subtraction, and the `Zs`
    ///     arm hands back exactly one scalar. `ConverseRequest.wireDisplayName`
    ///     collapses whitespace runs while the key keeps them verbatim, so an
    ///     NBSP would make the displayed name and the addressed path disagree
    ///     invisibly.
    ///   - `Cf` format characters EXCEPT ZWNJ (U+200C) and ZWJ (U+200D). Both
    ///     are invisible, and both are load-bearing: ZWNJ is orthographic in
    ///     Persian and Urdu, ZWJ is what builds an emoji sequence, and refusing
    ///     them would re-create the discard-in-silence defect for exactly the
    ///     users widening this gate exists to serve. Everything else in `Cf`
    ///     goes — a bidi override can make a rendered name lie about its own
    ///     extension, and the tag characters U+E0020–U+E007F buy little while
    ///     judging them at all would need real emoji-tag-sequence validation.
    ///   - `Cc`, `Co`, `Cs` and `Cn`, by falling outside every admitted
    ///     category.
    ///
    /// Unassigned code points and noncharacters are named rather than left to
    /// fall off the end of the switch: both are `Cn` today, and both are
    /// refusals of POLICY that must survive a future Unicode reclassifying
    /// either one.
    nonisolated private static func outboxEntryScalarIsAddressable(_ scalar: Unicode.Scalar) -> Bool {
        guard !outboxEntryRejectedScalars.contains(scalar) else { return false }
        let properties = scalar.properties
        guard properties.generalCategory != .unassigned,
              !properties.isNoncharacterCodePoint else { return false }
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        case .format:
            return scalar == "\u{200C}" || scalar == "\u{200D}"
        case .spaceSeparator:
            return scalar == " "
        default:
            return false
        }
    }

    /// Whether `scalar` is a combining mark (`Mn` / `Mc` / `Me`) — a scalar that
    /// renders by attaching itself to the character before it.
    nonisolated private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// The extension of an inbound entry name — the bytes after its last `.`,
    /// lowercased — when EVERY one of them is ASCII alphanumeric, and nil
    /// otherwise.
    ///
    /// THE ASCII TEST RUNS ON THE RAW SLICE, BEFORE ANY CASE FOLDING, and that
    /// order is the whole function. `lowercased()` is a Unicode operation:
    /// `"\u{212A}t"` — KELVIN SIGN, an `Lu` letter the alphabet gate admits
    /// without complaint — folds to exactly `"kt"` and satisfies an allowlist
    /// test for Kotlin. The type gate is the only thing keeping a
    /// `.mobileconfig` or a live `.sqlite` out of the lane, so it must not be
    /// reachable by a character that merely folds to the right answer. Folding
    /// AFTER the test is safe because ASCII alphanumerics fold to ASCII
    /// alphanumerics.
    ///
    /// The dot is found on BYTES, one step stricter than `probeKeyExtension`'s
    /// grapheme reading. The two can disagree only when the final `.` is fused
    /// with a combining mark, and then this reading yields a slice OPENING with
    /// that mark — not ASCII, so the name is refused outright. Every name that
    /// passes therefore has an unfused final dot, where both readings return the
    /// same extension, so the later probe can never classify a delivered key as
    /// a different type than this gate accepted it as.
    nonisolated private static func outboxEntryExtension(of name: String) -> String? {
        let bytes = Array(name.utf8)
        guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > bytes.startIndex else {
            return nil
        }
        let slice = bytes[bytes.index(after: dot)...]
        guard !slice.isEmpty, slice.allSatisfy({ byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }) else { return nil }
        return String(decoding: slice, as: UTF8.self).lowercased()
    }

    /// Where one resolved `<href>` sits relative to the collection that was
    /// listed. Nothing else is representable, which is the point: an href is
    /// either the folder itself, a direct child of it, or a refusal.
    private enum ResolvedListingHref {
        case collectionItself
        case child(String)
    }

    /// Resolve one `<href>` against the requested collection.
    ///
    /// Returns nil — refusing the WHOLE listing — for a foreign origin, a
    /// grandchild, a parent, an unparseable reference, or any component that
    /// decodes to a separator, a NUL or a dot segment. Refusing wholesale rather
    /// than dropping the row is deliberate: an href that is not a plain direct
    /// child means this body is not describing the folder that was asked about,
    /// and quietly keeping its siblings would let a server hand over a curated
    /// subset of a listing the client believes is complete.
    ///
    /// Relative references resolve against the collection WITH a trailing slash,
    /// which is what makes `report.pdf` a child rather than a sibling. RFC 3986
    /// resolution removes dot segments as it goes, so a `../..` href lands
    /// outside the base and is refused by the direct-child test; a
    /// percent-ENCODED one survives resolution intact and is refused by the
    /// component decode below.
    ///
    /// THE MATCH IS ANCHORED AT THE END, NOT AT THE START, and that is the one
    /// place this is deliberately looser than "the href begins with what I
    /// asked for". A reverse proxy that strips its own mount point — Caddy's
    /// `handle_path /files/*`, an nginx `proxy_pass` with a trailing slash — hands
    /// the WebDAV server a shortened path, so a base of `https://host/files` gets
    /// back hrefs of `/<conv>/out-<hex>/report.pdf`. Demanding the full prefix
    /// refuses every row of a perfectly good listing and leaves the user with a
    /// permanent "Couldn't read your file server". Requiring the href's PARENT to
    /// be a non-empty tail of the requested path keeps every property that
    /// matters: same origin, exactly one component past the folder, and a parent
    /// that still ends in the freshly-minted `out-<32 hex>` component, so a
    /// listing of the served root, of the conversation folder, or of any other
    /// directory is refused exactly as before.
    private static func resolveListingHref(
        _ href: String,
        requestedURL: URL,
        baseComponents: [String]
    ) -> ResolvedListingHref? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absoluteBase = requestedURL.absoluteString
        let collectionBase = absoluteBase.hasSuffix("/")
            ? requestedURL
            : (URL(string: absoluteBase + "/") ?? requestedURL)
        guard let resolved = URL(string: trimmed, relativeTo: collectionBase)?.absoluteURL,
              sameListingOrigin(resolved, requestedURL),
              let components = listingPathComponents(of: resolved) else {
            return nil
        }
        // The collection's own row is tested FIRST. Under a stripped prefix an
        // href can satisfy both readings (its components tail-match the base, and
        // so does its parent), and calling that the folder rather than a child of
        // a shorter folder is the reading that cannot invent an entry.
        if isRequestedCollectionTail(components, of: baseComponents) {
            return .collectionItself
        }
        guard let name = components.last,
              isRequestedCollectionTail(Array(components.dropLast()), of: baseComponents) else {
            return nil
        }
        return .child(name)
    }

    /// Whether `candidate` names the requested collection as the server sees it:
    /// the whole requested path, or the tail of it that survives a path-stripping
    /// proxy.
    ///
    /// A tail, never a head and never a subsequence, so what is accepted always
    /// ends where the request ended. On the collection this actually decides in
    /// production — the per-dispatch box, whose path ends in `out-<32 hex>` —
    /// that means even the shortest accepted match pins an entry's immediate
    /// parent to 128 bits of freshly-minted entropy. An EMPTY candidate matches
    /// only an empty base; otherwise a server answering about its own root would
    /// satisfy every listing.
    private static func isRequestedCollectionTail(
        _ candidate: [String],
        of baseComponents: [String]
    ) -> Bool {
        guard !candidate.isEmpty else { return baseComponents.isEmpty }
        guard candidate.count <= baseComponents.count else { return false }
        return Array(baseComponents.suffix(candidate.count)) == candidate
    }

    /// The percent-DECODED path components of `url`, or nil when any of them is
    /// something a path component may not be.
    ///
    /// SPLIT FIRST, DECODE SECOND. That order is the whole function: decoding
    /// first turns `%2F` into a real separator and `%2E%2E` into a dot segment,
    /// so a single component carries an entire path the split cannot see.
    ///
    /// AND THE DECODED COMPONENT IS READ BY SCALAR, never by Character:
    /// a separator followed by a combining mark is ONE grapheme cluster equal to
    /// neither `/` nor `\`, so a `contains("/")` calls `a%2F%CC%81b.pdf` a clean
    /// component while `URL.appending(path:)` reads the U+002F inside it as a
    /// separator — a second component smuggled through the direct-child test.
    /// Separator, backslash and NUL are therefore one scalar pass.
    private static func listingPathComponents(of url: URL) -> [String]? {
        let encodedPath = url.absoluteURL.path(percentEncoded: true)
        var components: [String] = []
        for encoded in encodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            guard let decoded = String(encoded).removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != "..",
                  !decoded.unicodeScalars.contains(where: {
                      $0 == "/" || $0 == "\\" || $0.value == 0
                  }) else {
                return nil
            }
            components.append(decoded)
        }
        return components
    }

    /// Whether two URLs share scheme, host and effective port. The listing
    /// requires it because an href on another host is not describing the file
    /// server the user configured, whatever it claims about the path.
    private static func sameListingOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftScheme = lhs.scheme?.lowercased(),
              let rightScheme = rhs.scheme?.lowercased(),
              leftScheme == rightScheme,
              let leftHost = lhs.host()?.lowercased(),
              let rightHost = rhs.host()?.lowercased(),
              leftHost == rightHost else {
            return false
        }
        return listingPort(lhs) == listingPort(rhs)
    }

    /// A URL's port, with the scheme's default filled in so `https://h/x` and
    /// `https://h:443/x` are one origin rather than two.
    private static func listingPort(_ url: URL) -> Int {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return -1
        }
    }

    // MARK: - Staged Test Connection (builds its own trust-reading session)

    /// Run the staged Test Connection against `snapshot`'s file-server:
    /// **reachability → auth → write(PUT tiny probe) → read(GET) → delete(cleanup)
    /// → listing(PROPFIND)**.
    /// Sets `fileTransferAvailable` (caller side) only when `success` — a
    /// read-only 200 false-positives on a Control-UI HTML page, so availability
    /// requires the write+read round-trip to actually land.
    ///
    /// THE LISTING STAGE DECIDES A DIFFERENT QUESTION and reports on its own
    /// field. It measures the two PROPFINDs the return direction is built on
    /// (see `probeListingCapability`) and leaves `success` alone whatever it
    /// finds, because uploads and returns are separate capabilities of one lane:
    /// revoking both on the evidence for one took a working feature away from
    /// every server that speaks PUT/GET and not PROPFIND, and revoking both on
    /// the ABSENCE of evidence would throw away a byte-echo that had already
    /// succeeded.
    ///
    /// - The probe file is `__conduck_probe_<8hex>.txt` with a tiny known body;
    ///   it is GET-read back, then best-effort DELETEd. A DELETE failure does
    ///   NOT fail the test (a stray 12-byte probe file is harmless on the user's
    ///   own server).
    /// - When `session` is nil, builds a 15 s ephemeral cert-pinned
    ///   `URLSession` (cloning `RemoteAgentClient+TestConnection`) so the
    ///   `RemoteAgentTrustEvaluator` SPKI delegate is installed for THIS probe
    ///   only. Tests inject a `MockURLProtocol`-backed session instead.
    ///
    /// Returns the furthest `reachedStage` + `success` + the mapped `failure`
    /// (nil on success). Never throws — every failure is captured into the
    /// result so the UI renders a per-stage outcome list. Never names the
    /// credential in the failure.
    static func runConnectionTest(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession? = nil,
        signalsOverride: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)? = nil
    ) async -> FileTransferTestResult {
        // Build (or adopt) the probe session. When we build it, install the
        // SPKI-pinning delegate scoped to THIS probe only — same posture as the
        // converse Test Connection. What a TLS-rejection URLError resolves to is
        // decided by the evaluator's own POSITIVE verdicts, never by whether a
        // pin exists. `signalsOverride` is the test seam (an injected session
        // has no real evaluator to read); production reads the real evaluator,
        // so a certificate the device does not trust is reported as such instead
        // of being discarded by construction.
        //
        // ONE closure returning the whole snapshot, not several loose Bools: the
        // staged test issues a SEQUENCE of requests on this session, and reading
        // the verdicts separately could pair one request's system verdict with
        // another's pin verdict.
        let pin = snapshot.certFingerprintHex
        let ownsSession: Bool
        let probeSession: URLSession
        let signals: @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
        if let session {
            probeSession = session
            ownsSession = false
            signals = Self.probeSignals(override: signalsOverride, evaluator: nil)
        } else {
            let built = makeProbeSession(pinnedFingerprintHex: pin)
            probeSession = built.session
            ownsSession = true
            signals = Self.probeSignals(override: signalsOverride, evaluator: built.evaluator)
        }
        if ownsSession {
            defer { probeSession.invalidateAndCancel() }
            return await performStagedTest(snapshot: snapshot, session: probeSession, signals: signals)
        } else {
            return await performStagedTest(snapshot: snapshot, session: probeSession, signals: signals)
        }
    }

    /// Resolve the attempt-verdict source for a probe: the override answers when
    /// one is supplied, otherwise the real evaluator does (and `.empty`'s
    /// no-verdict values stand in when there is neither — an injected mock
    /// session raises no challenge, so no verdict is the truthful reading).
    ///
    /// THE OVERRIDE SUPPLIES A WHOLE `AttemptTrustSignals`, never a field at a
    /// time. Deriving one field from another input is what this seam is
    /// forbidden to do: it previously read `challengeRefused` off "a pin is
    /// configured", which is precisely the proxy the classifier removed —
    /// correct only because of an invariant inside `decide`, invisible from
    /// here, and reintroduced on a REAL lane the moment someone shares one
    /// session between Diagnostics probes. It also let the file-lane tests lock
    /// a signal shape production never produces (a cold tunnel raises no
    /// challenge, so nothing can have refused it). A whole snapshot makes the
    /// test state the shape it is testing, and leaves the seam with nothing to
    /// infer.
    private static func probeSignals(
        override: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)?,
        evaluator: RemoteAgentTrustEvaluator?
    ) -> @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals {
        if let override { return override }
        return { evaluator?.attemptSignals ?? .empty }
    }

    /// NON-MUTATING reach+auth probe — a SINGLE ranged GET of a key that cannot
    /// exist on the server, mapped by `classifyReachability`. Wired into the
    /// explicit "Test connections" tap so Diagnostics can say something about a
    /// file lane WITHOUT the staged write test's PUT/DELETE. It NEVER mutates the
    /// server and NEVER sets `fileTransferAvailable`, and its best outcome is a
    /// WARNING, never a pass (`DiagnosticsRunner.fileReachStatus`): a `404` pass
    /// signal is equally consistent with a read-only server, a wrong base path,
    /// or a host that 404s before auth. Only `runConnectionTest` certifies uploads.
    ///
    /// Session posture mirrors `runConnectionTest`: when `session` is nil, builds
    /// the 15 s ephemeral cert-pinned `URLSession` (SPKI delegate scoped to THIS
    /// probe only); tests inject a `MockURLProtocol`-backed session, and
    /// `signalsOverride` is the seam that stands in for the evaluator such a
    /// session does not carry.
    ///
    /// A transport failure is classified by the SAME
    /// `RemoteAgentTrustEvaluator.classifyTransportError` the staged write test
    /// uses, reading the SAME attempt snapshot, so the two file-lane probes
    /// cannot tell a user two different stories about one server. All three
    /// certificate classes survive: a chain the device refuses is
    /// `.certUntrusted`, a pin that disagreed with a chain it accepted is
    /// `.certMismatch`, and a key that could not be hashed at all is
    /// `.certKeyUnpinnable` — folding any of them into `.unreachable` produces
    /// the "check your file-server is running" row for a host that answered, and
    /// in the mismatch case discards the one signal that means the connection may
    /// be intercepted. Everything else still folds to `.unreachable`. Never names
    /// the credential.
    static func probeReachability(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession? = nil,
        signalsOverride: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)? = nil
    ) async -> FileReachabilityOutcome {
        let probeSession: URLSession
        let ownsSession: Bool
        let signals: @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
        if let session {
            probeSession = session
            ownsSession = false
            signals = Self.probeSignals(override: signalsOverride, evaluator: nil)
        } else {
            let built = makeProbeSession(pinnedFingerprintHex: snapshot.certFingerprintHex)
            probeSession = built.session
            ownsSession = true
            signals = Self.probeSignals(override: signalsOverride, evaluator: built.evaluator)
        }
        defer { if ownsSession { probeSession.invalidateAndCancel() } }

        // A key that cannot exist — a real WebDAV file-not-found probe. The
        // 12-hex tag makes a collision with a real stored file impossible.
        let reachTag = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let reachKey = "__conduck_reach_\(reachTag)__"
        let request = buildProbeRequest(snapshot: snapshot, storedKey: reachKey)

        do {
            let (_, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable
            }
            return classifyReachability(status: http.statusCode)
        } catch {
            // Both trust signals are POSITIVE — set only once a server-trust
            // challenge actually failed — so a cold tunnel or a dead host leaves
            // both false and still reads as unreachable. A non-`URLError` is
            // unclassifiable and takes the same conservative answer.
            guard let urlError = error as? URLError else { return .unreachable }
            switch RemoteAgentTrustEvaluator.classifyTransportError(urlError.code, signals: signals()) {
            case .untrustedCert: return .certUntrusted
            case .certMismatch: return .certMismatch
            case .certKeyUnpinnable: return .certKeyUnpinnable
            // Never folded into `.unreachable`: -1022 is decided from the URL
            // before any connect, so the host neither answered nor failed to.
            case .blockedByATS: return .insecureBlocked
            case .timeout, .unreachable, .notEstablished, .offline, .cancelled: return .unreachable
            }
        }
    }

    // MARK: - Private

    /// Build the 15 s ephemeral cert-pinned probe session + its trust
    /// evaluator. The ONE session recipe for every FileServerClient entry that
    /// constructs its own (staged test, reach probe, folder-capability probe)
    /// — a timeout/TLS/cache-posture change lands in all three at once instead
    /// of silently diverging per probe. The caller owns invalidation.
    private static func makeProbeSession(
        pinnedFingerprintHex: String?
    ) -> (session: URLSession, evaluator: RemoteAgentTrustEvaluator) {
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: pinnedFingerprintHex)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.fileServerProbeTimeout
        config.timeoutIntervalForResource = Constants.fileServerProbeTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return (URLSession(configuration: config, delegate: evaluator, delegateQueue: nil), evaluator)
    }

    /// Execute the staged sequence on a ready `session`. Factored out of
    /// `runConnectionTest` so the session-ownership / `defer` plumbing stays in
    /// the public method and this body reads as a linear stage list.
    private static func performStagedTest(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession,
        signals: @escaping @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) async -> FileTransferTestResult {
        // Mint a unique tiny probe file name for this test run. The 8-hex tag
        // keeps concurrent / repeated tests from colliding on the same key.
        let probeTag = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let probeKey = "__conduck_probe_\(probeTag).txt"
        let probeBody = Data("conduck-probe".utf8)

        // --- Stage 1+2: reachability + auth (folded into the write attempt's
        // transport + status classification) ---
        //
        // The PUT is the first request that actually reaches the server, so its
        // TRANSPORT outcome answers reachability and its STATUS answers auth.
        // We classify a transport failure as a reachability/cert failure and a
        // 401/403 as an auth failure BEFORE crediting the write stage.

        // Body travels via `upload(for:from:)` ONLY — setting `httpBody` too makes
        // URLSession warn ("upload task should not contain a body or a body stream").
        let writeRequest = buildUploadRequest(snapshot: snapshot, storedKey: probeKey, contentLength: probeBody.count)

        let writeStatus: Int
        do {
            let (_, response) = try await session.upload(for: writeRequest, from: probeBody)
            guard let http = response as? HTTPURLResponse else {
                // No HTTP response → treat as unreachable; we got past TLS but
                // the server answered something non-HTTP.
                return FileTransferTestResult(reachedStage: .reachability, success: false, failure: .fileTransferUnreachable)
            }
            writeStatus = http.statusCode
        } catch let error as URLError {
            // Transport failure on the first request → reachability stage.
            // A pin mismatch is the one case we surface as cert-mismatch.
            return FileTransferTestResult(
                reachedStage: .reachability,
                success: false,
                failure: mapTransportError(error, signals: signals())
            )
        } catch {
            return FileTransferTestResult(reachedStage: .reachability, success: false, failure: .fileTransferUnreachable)
        }

        // Reachability passed (we got an HTTP status). Now classify auth.
        if writeStatus == 401 || writeStatus == 403 {
            return FileTransferTestResult(reachedStage: .auth, success: false, failure: .fileTransferAuthFailed)
        }
        if (500...599).contains(writeStatus) {
            // Server sick during the write — fail at the write stage with a
            // retryable server error (auth implicitly passed: a 5xx is not a
            // 401/403).
            return FileTransferTestResult(reachedStage: .write, success: false, failure: .fileTransferServerError)
        }
        // 404 / 405 / 501 on the PUT: the endpoint took the request but refuses
        // to STORE at it — a read-only nginx, the gateway's own web UI on the
        // wrong port, a base path that isn't the DAV root. This is the likeliest
        // real misconfiguration, and "couldn't upload the file" sends the user
        // hunting a transport problem that doesn't exist. Name the actual cause.
        if writeStatus == 404 || writeStatus == 405 || writeStatus == 501 {
            return FileTransferTestResult(reachedStage: .write, success: false, failure: .fileTransferNotAFileServer)
        }
        guard (200...299).contains(writeStatus) else {
            // Any other non-2xx on the write (a redirect, a 4xx we can't
            // attribute) → the write did not land. Fail the write stage.
            return FileTransferTestResult(reachedStage: .write, success: false, failure: .fileTransferUploadFailed)
        }

        // --- Stage 4: read (GET the probe back) ---
        // This is the stage that defeats the Control-UI-HTML / uniform-200
        // auth-wall false-positive: we only trust the connection if the VERY
        // BYTES we just wrote come back. Status classification is the first gate
        // (a non-2xx/404/416 still fails the read stage here), but a uniform-200
        // SSO proxy that answers every GET with its own HTML passes the status
        // gate — so we ALSO require an exact byte-equality against `probeBody`.
        // A full-range GET (`buildDownloadRequest`, NOT the ranged
        // `buildProbeRequest`) is used so the whole 13-byte body comes back to
        // compare; the blessed transports (Tailscale Serve/Funnel, Cloudflare
        // Tunnel, rclone) pass a raw file GET through unchanged, so exact
        // equality holds for real WebDAV and only the impostor endpoint fails.
        //
        // The FAILURE we attribute matters as much as the pass. A wrong-bytes
        // read is not "your server errored" — the server's own logs show a clean
        // 200. It means the URL is answering with something that isn't our file
        // (a login page, an SSO wall, a dashboard), so it gets its own code
        // (`.fileTransferNotAFileServer`, 61) that says exactly that. A 404 on
        // the key we just PUT a 2xx for is the same class: the endpoint took the
        // write and doesn't serve it back. Only a real 5xx is a server error.
        let readRequest = buildDownloadRequest(snapshot: snapshot, storedKey: probeKey)
        var readOK = false
        var readFailure: AppError = .fileTransferNotAFileServer
        do {
            let (data, response) = try await session.data(for: readRequest)
            if let http = response as? HTTPURLResponse {
                switch probeStatusPrefilter(status: http.statusCode) {
                case .exists:
                    // Byte-echo: the returned body must be EXACTLY what we PUT.
                    readOK = (data == probeBody)
                case .unauthorized:
                    // Write passed the gate but the read didn't — a half-open
                    // auth config, not an impostor endpoint.
                    readFailure = .fileTransferAuthFailed
                case .serverError:
                    readFailure = .fileTransferServerError
                case .missing, .certRefused, .ambiguous, .unknown:
                    // Stays `.fileTransferNotAFileServer`. `.certRefused` and
                    // `.ambiguous` are listed for exhaustiveness only — the
                    // first is a TRANSPORT verdict and the second a
                    // `classifyProbe` one, while `probeStatusPrefilter` reads a
                    // status, so a response we are holding here carries neither.
                    break
                }
            } else {
                readFailure = .fileTransferUnreachable
            }
        } catch {
            // The PUT reached the host, so a transport failure on the very next
            // GET is ordinarily a connectivity fault rather than a config one —
            // but a CERTIFICATE refusal is neither, and hardcoding unreachable
            // here threw it away. The PUT and the GET are separate attempts (the
            // pool can drop and re-establish the connection between them, and a
            // re-handshake raises its own challenge), so the read is entitled to
            // its own verdict. `mapTransportError` still answers unreachable for
            // everything that carries no certificate verdict, which is what keeps
            // the connectivity reading for the case this comment described.
            readFailure = mapTransportError(error, signals: signals())
        }

        // --- Stage 5: delete (best-effort cleanup) — never affects the verdict ---
        await bestEffortDelete(snapshot: snapshot, storedKey: probeKey, session: session)

        guard readOK else {
            return FileTransferTestResult(reachedStage: .read, success: false, failure: readFailure)
        }

        // --- NESTED write-probe (capability detection, NOT a user-facing stage) ---
        // The flat reachability/auth/write/read sequence has passed. Now probe
        // whether the gateway accepts the client's nested upload sequence —
        // MKCOL the folder, then PUT into it. WebDAV servers don't auto-create
        // a missing parent on PUT (rclone 409s it — RFC 4918 §9.7), and some
        // (an S3-DAV bridge, a locked-down nginx-DAV) reject the nested PUT
        // even after MKCOL. The result decides whether the client mints
        // per-conversation `<convID>/…` keys or falls back to flat ones. This
        // probe failing does NOT fail the connection test (flat keys work fine) —
        // it only narrows `folderCapable` to false.
        //
        // WITH ONE EXCEPTION, and it is the reason this switch is not a `==
        // .capable`. A CERTIFICATE refusal here is not a capability answer at
        // all: it says the connection was refused, and absorbing it into
        // `folderCapable = false` reported a trust refusal as a green connection
        // test with a narrowed feature — the failure mode that looks like
        // success. It fails the test, with the certificate's own error.
        let folderCapable: Bool
        switch await probeFolderCapability(snapshot: snapshot, session: session, signals: signals) {
        case .capable:
            folderCapable = true
        case .rejected, .indeterminate:
            // The staged test runs interactively against a server the flat stages
            // just passed, so "indeterminate" here is a narrowing like any other —
            // and the silent launch-time re-probe un-sticks a false verdict at the
            // next probe-algorithm revision anyway.
            folderCapable = false
        case .certificateRefused(let refusal):
            // Reported at `.reachability`, not at `.read`: a certificate refusal
            // is a TLS-layer verdict about the CONNECTION, and it is where every
            // other certificate refusal in this lane lands, so the user gets one
            // story about certificates wherever in the sequence one is observed.
            // Marking `.read` failed would put a red X on a stage that visibly
            // succeeded.
            //
            // `folderCapable` keeps its init DEFAULT (true), like every other
            // failure path here: the flag is a narrowing that only a DEFINITIVE
            // nested-PUT rejection may flip, a refused connection proves nothing
            // about folders, and neither caller persists it unless `success`.
            return FileTransferTestResult(
                reachedStage: .reachability,
                success: false,
                failure: refusal.fileTransferError
            )
        }

        // --- Stage 5: listing (the whole RETURN direction) ---
        // Everything above certifies bytes going OUT. This certifies the one
        // capability bytes coming BACK depend on — and a STRUCTURAL refusal here
        // is DELIBERATELY NOT FATAL. It is a fact about ONE DIRECTION of a lane
        // whose other direction the four stages above just proved end to end, so
        // failing the whole test on it revoked `fileTransferAvailable` and
        // disabled UPLOADS as well, on a server that uploads perfectly. Plain
        // nginx with `dav_methods PUT DELETE` is exactly that server and is a
        // large real population; they lost a working feature to buy nothing.
        // That verdict rides out on `returnVerification` instead, which every
        // status surface renders as its own third outcome.
        //
        // THREE OUTCOMES, and NONE of them fails this test. The four stages
        // above proved uploads end to end with a byte-echo; a later, independent
        // check of the OTHER direction cannot un-prove that, and a `502` on the
        // fifth request would otherwise revoke a lane whose upload half was just
        // demonstrated. What each outcome does instead is decide what the app
        // may CLAIM:
        //   - `.capable`        → both directions, and the witness state is seeded.
        //   - `.methodUnavailable` → the amber uploads-only lane, persisted, and
        //     the witness state is seeded so the dispatch path stops re-asking.
        //   - `.unverified`     → claim nothing about the return direction:
        //     persist nothing, seed nothing, and let the surfaces say "couldn't
        //     check" so a green "listed a folder" is never shown over a folder
        //     nobody listed.
        let verification: FileTransferReturnVerification
        switch await probeListingCapability(snapshot: snapshot, session: session, signals: signals) {
        case .capable:
            verification = .verified
        case .methodUnavailable:
            verification = .methodUnavailable
        case .unverified(let error):
            verification = .unverified(error)
        case .certificateRefused(let refusal):
            // At `.reachability`, for the reason the nested probe's refusal is:
            // a certificate verdict is about the CONNECTION, and the file lane
            // tells one story about certificates wherever one is observed.
            return FileTransferTestResult(
                reachedStage: .reachability,
                success: false,
                failure: refusal.fileTransferError
            )
        }

        // The staged test is the ONE place a lane's return capability is
        // measured deliberately, by a user who is watching, so a SETTLED verdict
        // seeds the process-local witness state the dispatch path reads. Without
        // this seeding an upload-only lane would still spend one pre-dispatch
        // PROPFIND after every launch to rediscover a fact Settings already
        // displays — and, worse, a lane the user has just REPAIRED would stay in
        // its cooldown until that expired, so a passing test must also clear the
        // failure streak outright.
        //
        // ONLY A SETTLED VERDICT STATES A CAPABILITY. `.unverified` states none:
        // the breaker is a cache of FACTS about the lane, and seeding it from a
        // `502` is what made one bad moment silence file return for the rest of
        // the process — the dispatch path's own per-turn measurement is then
        // free to learn the truth on the next turn.
        //
        // THE FAILURE STREAK IS CLEARED EITHER WAY, and that asymmetry is the
        // point. A capability is a claim and needs proof; a cooldown is only a
        // guess about whether spending another request is worth it, and four
        // stages that just moved real bytes to this server and read them back
        // are a far stronger signal than the streak that opened it. The case
        // that forced this: a server goes unreachable, one witness failure opens
        // the ladder to as much as an hour, the user restarts the server and
        // taps Test Connection on the same tuple — and a `502` from a
        // reverse proxy still warming up left them waiting out a pause they
        // cannot see, having just demonstrated the exact reachability the pause
        // was guessing about.
        //
        // A recorded INCAPABILITY is left alone, because it is not a pause:
        // `decide` answers `.cannotReturn` before any cooldown is consulted, so
        // there is nothing here to clear, and dropping it would widen a proven
        // narrowing on a probe that proved nothing.
        //
        // THE SEED IS A CACHE, NOT THE VERDICT. The verdict this run settles is
        // also PERSISTED per gateway by the commit hop that consumes this
        // result, and `mintOutboxKey` gates on that durable flag before it
        // consults the breaker at all — so the incapability survives a relaunch
        // and reaches the wrist, and this seeding only saves the rest of THIS
        // process the request. Nothing else may write the durable flag: the
        // dispatch witness asks about a collection that does not exist and can
        // therefore never settle this question (see
        // `FileServerAbsenceWitness.cannotAnswer`).
        let lane = BackgroundFileTransfer.FileLaneWitnessBreaker.laneKey(for: snapshot)
        switch verification {
        case .verified:
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.noteStagedVerdict(
                lane: lane, returnCapable: true)
        case .methodUnavailable:
            BackgroundFileTransfer.FileLaneWitnessBreaker.shared.noteStagedVerdict(
                lane: lane, returnCapable: false)
        case .unverified, .notMeasured:
            if BackgroundFileTransfer.FileLaneWitnessBreaker.shared.decide(lane: lane)
                != .cannotReturn {
                BackgroundFileTransfer.FileLaneWitnessBreaker.shared.reset(lane: lane)
            }
        }

        // Uploads passed. `folderCapable` is the one narrowing this sequence
        // makes on its own; `returnVerification` carries everything the listing
        // stage established, including that it established nothing.
        return FileTransferTestResult(
            reachedStage: .listing,
            success: true,
            failure: nil,
            folderCapable: folderCapable,
            returnVerification: verification
        )
    }

    /// What the LISTING-capability probe learned. FOUR outcomes because there
    /// are four different things to do about them, and the distinction this type
    /// exists to hold is between "the server told us it cannot do this" and "we
    /// learned nothing" — collapsing those two let ONE reverse-proxy `502`
    /// during a Test Connection stamp a healthy WebDAV server permanently unable
    /// to return files.
    ///
    /// The same shape `FileServerListingVerdict` uses for the listing itself
    /// (entries / absent / unusable, plus the device-side `noObservation` this
    /// staged probe has no equivalent of — a Test Connection the user asked for
    /// is not a request that never happened), and for the same reason: a
    /// question with a "don't know" answer needs a value to put it in, or the
    /// don't-know silently borrows the meaning of whichever neighbour it is
    /// folded into.
    enum ListingProbeOutcome: Equatable {
        /// The server answered `207` for a collection that exists AND `404` for
        /// one that cannot. Both directions of the return lane are available.
        case capable
        /// STRUCTURAL REFUSAL — `PROPFIND` of a collection that CERTAINLY EXISTS
        /// came back `405 Method Not Allowed` (known method, not allowed here)
        /// or `501 Not Implemented` (method not recognised), per RFC 9110
        /// §15.5.6 / §15.6.2. The same two statuses `classifyAbsenceWitness`
        /// calls `.cannotAnswer`, so the staged test and the per-dispatch
        /// witness cannot tell the user two different stories about one server.
        ///
        /// The ONLY outcome that may record an incapability, and ONLY from the
        /// first probe. A `405` on the SECOND probe cannot mean this: the server
        /// has just answered `207` and thereby demonstrated it performs the
        /// method, so a refusal on the missing-resource route is a fact about
        /// that route, not about the method.
        case methodUnavailable
        /// The probe ANSWERED OR FAILED and proved NOTHING — a timeout, a
        /// `502`, a `401`, a redirect, a `200` that is not a multistatus, a
        /// namespace that claims a path carrying 16 hex of fresh entropy is
        /// occupied. All of them are things that can be true this minute and
        /// false the next, or method-specific interception in front of a server
        /// that may well speak `PROPFIND` — a WAF, an SSO layer, a rewrite, a
        /// rate-limit rule — so none of them may narrow a capability.
        ///
        /// The `2xx` control deserves its name here, and what it is is settled by
        /// the SAME rule the dispatch witness uses. A `207` on the control is
        /// read through `classifyAbsenceWitness` with its body: the compliant
        /// multistatus whose inner response is the `404` that was asked for
        /// passes the step, and a namespace that answers everything lands here.
        /// Reading the outer status alone could not tell those apart and
        /// condemned both, which reported "couldn't verify, check again" about
        /// hosts that answer the question correctly.
        ///
        /// Carries the taxonomy code the surfaces show beside the listing row.
        /// It does NOT fail the test: uploads were proven end to end before this
        /// probe ran, and revoking them for an unrelated later check destroys
        /// established evidence. Nothing is persisted; no capability is seeded
        /// into the witness breaker (a passing test still clears that lane's
        /// failure cooldown, which is a spending guess rather than a claim); the
        /// user is asked to check again.
        case unverified(AppError)
        /// This device refused the server's certificate.
        case certificateRefused(CertificateRefusal)

        /// `AppError` is `LocalizedError`, not `Equatable` — compare the payload
        /// by its stable numeric code, the same way `FileTransferTestResult`
        /// does, so this stays `Equatable` for tests without forcing an
        /// `AppError: Equatable` conformance across the whole taxonomy.
        static func == (lhs: ListingProbeOutcome, rhs: ListingProbeOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.capable, .capable), (.methodUnavailable, .methodUnavailable):
                return true
            case (.unverified(let l), .unverified(let r)):
                return l.errorCode == r.errorCode
            case (.certificateRefused(let l), .certificateRefused(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    /// The taxonomy code for a listing-stage answer that settled nothing.
    ///
    /// Three codes, no new ones: the file lane already has words for all three
    /// shapes, and a fourth would be a fourth paraphrase of an instruction the
    /// user has already read elsewhere.
    ///
    /// `401` ONLY for the credential — deliberately not `403`. The PUT and the
    /// GET authenticated moments earlier, so a `403` here is the server
    /// understanding the request and refusing it (a method or path policy, RFC
    /// 9110 §15.5.4), and sending the user to regenerate a password that
    /// demonstrably works would be the wrong errand. A transport failure
    /// carrying no certificate verdict is reachability; everything else the
    /// server said routes to "check your file-server's logs, then try again",
    /// which is the honest instruction for a `5xx`, a `429`, a `403`, a redirect
    /// and a non-multistatus `200` alike — in every one of those the server's
    /// own log is the only place the answer lives.
    private static func listingStageError(status: Int?) -> AppError {
        guard let status else { return .fileTransferUnreachable }
        return status == 401 ? .fileTransferAuthFailed : .fileTransferServerError
    }

    /// Probe whether `snapshot`'s file-server can support the RETURN direction,
    /// with the two PROPFINDs the dispatch path itself issues:
    ///
    ///   1. `PROPFIND Depth: 0` of the served root — must be `207`. A collection
    ///      that certainly exists is the only way to ask "do you speak PROPFIND
    ///      at all"; a `405`/`501` here is a plain-HTTP store or an nginx-DAV
    ///      without the ext module, which PUTs and GETs perfectly and can never
    ///      list anything.
    ///   2. `PROPFIND Depth: 0` of a sibling that cannot exist — must come back
    ///      the server saying "not there". This is byte-for-byte the pre-dispatch
    ///      absence witness, decided by the SAME `classifyAbsenceWitness` over
    ///      the same status AND the same bounded body, so a lane that fails it
    ///      fails EVERY dispatch's witness and gets no output box, forever — and
    ///      a lane that passes it cannot then be told by its own dispatches that
    ///      it does not. That means a bare `404` passes and so does the compliant
    ///      `207` whose inner response for that collection is a `404`; a
    ///      catch-all host that really does claim every path lands in
    ///      `.unverified`.
    ///
    /// Both are `Depth: 0`, non-mutating, and cost one tiny request each — the
    /// question is about the collection itself, and a `Depth: 1` of the served
    /// root would make the server enumerate every file the user owns to answer a
    /// yes/no question.
    ///
    /// ONLY A STRUCTURAL REFUSAL ON THE FIRST PROBE MAY CONCLUDE INCAPABILITY,
    /// and everything else is `.unverified`. The status set is not a matter of
    /// taste: `405`/`501` are what a compliant server answers for a method it
    /// will not or cannot perform (RFC 9110 §15.5.6 / §15.6.2), and they are
    /// exactly the pair `classifyAbsenceWitness` already treats as structural. A
    /// `502` from a reverse proxy, a `429`, a `401`, a redirect and a
    /// non-multistatus `200` all say something about the moment or about a box
    /// in front of the server — a WAF, an SSO layer, a rewrite — never about
    /// what the server implements. The SECOND probe cannot conclude it at all:
    /// once the root has answered `207` the method is demonstrably performed, so
    /// a refusal or an occupied answer on the missing-resource route is a fact
    /// about that route, read the way `classifyAbsenceWitness` reads it — a
    /// fixable configuration, not a permanent property to display.
    ///
    /// The alternative — treating every non-`207` as proof — is what made one
    /// `502` during a Test Connection mark a healthy WebDAV server unable to
    /// return files, permanently and silently, with a false diagnosis on screen.
    ///
    /// Session posture and the trust-reading rule mirror `probeFolderCapability`:
    /// when `session` is nil this builds the ephemeral cert-pinned session and
    /// reads ITS evaluator; a caller supplying a session supplies `signals` too,
    /// because a probe cannot read an evaluator it did not build and without one
    /// a refused certificate is indistinguishable from a dead host.
    static func probeListingCapability(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession? = nil,
        signals: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)? = nil
    ) async -> ListingProbeOutcome {
        let probeSession: URLSession
        let ownsSession: Bool
        let attemptSignals: @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
        if let session {
            probeSession = session
            ownsSession = false
            attemptSignals = Self.probeSignals(override: signals, evaluator: nil)
        } else {
            let built = makeProbeSession(pinnedFingerprintHex: snapshot.certFingerprintHex)
            probeSession = built.session
            ownsSession = true
            attemptSignals = Self.probeSignals(override: signals, evaluator: built.evaluator)
        }
        defer { if ownsSession { probeSession.invalidateAndCancel() } }

        // Step 1 — a collection that exists must answer `207`. The status line is
        // the whole question ("do you perform this method"), so no body is read.
        switch await propfindAnswer(
            snapshot: snapshot, collectionKey: "", session: probeSession,
            readsMultistatusBody: false, signals: attemptSignals
        ) {
        case .status(207, _, _):
            break
        case .status(405, _, _), .status(501, _, _):
            // The ONE conclusion this whole function may draw: the server named
            // the method as one it will not perform, on a collection that
            // certainly exists.
            return .methodUnavailable
        case .status(let status, _, _):
            return .unverified(listingStageError(status: status))
        case .certificate(let refusal):
            return .certificateRefused(refusal)
        case .noAnswer:
            return .unverified(listingStageError(status: nil))
        }

        // Step 2 — a collection that cannot exist must come back "not there".
        // Routed through `classifyAbsenceWitness`, with the body, rather than
        // re-deriving the rule: this probe and the per-dispatch witness ask the
        // SAME question of the SAME server, so two definitions could disagree and
        // the user would be told in Settings that their server can list folders
        // while every turn silently concluded it cannot. Reading the body here is
        // not an extra — it is what makes the two definitions the same one, since
        // the witness reads it too and a compliant host's answer lives there.
        let controlKey = negativeControlCollectionKey(siblingOf: "")
        switch await propfindAnswer(
            snapshot: snapshot, collectionKey: controlKey, session: probeSession,
            readsMultistatusBody: true, signals: attemptSignals
        ) {
        case .status(let status, let body, let exceededCap):
            switch classifyAbsenceWitness(
                status: status,
                body: body,
                bodyExceededCap: exceededCap,
                requestedURL: listingCollectionURL(snapshot: snapshot, collectionKey: controlKey)
            ) {
            case .absent:
                return .capable
            case .cannotAnswer, .occupied, .indeterminate, .unreachable, .noObservation:
                // EVERY answer short of a definite miss is unverified here,
                // `405`/`501` INCLUDED — and that is not an oversight. Step 1
                // just got a `207`, so this server demonstrably performs
                // `PROPFIND`; a refusal on the missing-resource route says the
                // route cannot answer the absence question, which is a
                // configuration fact and not the method incapability the amber
                // lane is meant to describe. `.unreachable` and `.noObservation`
                // are unreachable from a status (their own doc says so) and ride
                // along for exhaustiveness.
                return .unverified(listingStageError(status: status))
            }
        case .certificate(let refusal):
            return .certificateRefused(refusal)
        case .noAnswer:
            return .unverified(listingStageError(status: nil))
        }
    }

    /// What one capability PROPFIND came back as. Three cases because the caller
    /// treats them differently, and the split has to survive the `-999` that a
    /// certificate refusal and a benign cancellation share.
    ///
    /// `.status` carries the body a `207` was allowed to deliver — empty for
    /// every other status and for every step that asked for none — plus the
    /// reader's own report that it stopped early, which a caller cannot infer
    /// from the bytes it holds.
    private enum PropfindProbeAnswer {
        case status(Int, body: Data, exceededCap: Bool)
        case certificate(CertificateRefusal)
        case noAnswer
    }

    /// Issue one `PROPFIND Depth: 0` and report its status, plus a BOUNDED body
    /// when — and only when — the caller's question can be answered by one.
    ///
    /// A BODY IS READ ONLY ON `207` AND ONLY WHEN ASKED FOR, capped at
    /// `absenceWitnessMaxBytes`. Those two conditions are the whole policy, and
    /// each has its own reason. Only on `207` because a multistatus is the sole
    /// shape whose contents can change a verdict — every other status has said
    /// everything it is going to say on its status line, and a catch-all host's
    /// login page must not be buffered to learn that it sent one. Only when
    /// asked for because the step that asks "do you perform this method" is
    /// answered by the status alone, and bytes nothing inspects are bytes nobody
    /// should have paid for.
    ///
    /// Where a body IS asked for it is not optional politeness but the answer
    /// itself: a compliant host reports a missing collection as a `207` whose
    /// inner response is the `404`, and `classifyAbsenceWitness` cannot see that
    /// without the bytes. Reading it under a cap and refusing anything over the
    /// cap keeps the old guarantee — no unbounded body, ever — while letting the
    /// probe reach the answer real deployments send.
    private static func propfindAnswer(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession,
        readsMultistatusBody: Bool,
        signals: @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) async -> PropfindProbeAnswer {
        let request = buildPropfindRequest(snapshot: snapshot, collectionKey: collectionKey, depth: 0)
        do {
            let answer = try await BackgroundFileTransfer.boundedListingResponse(
                session: session,
                request: request,
                maxBytes: absenceWitnessMaxBytes,
                readsBodyWhen: { readsMultistatusBody && $0 == 207 })
            return .status(answer.status, body: answer.body, exceededCap: answer.exceededCap)
        } catch {
            if let refusal = certificateRefusal(error, signals: signals()) {
                return .certificate(refusal)
            }
            return .noAnswer
        }
    }

    /// Outcome of the folder-capability probe. `rejected` is the ONLY value that
    /// means "the server answered and refuses nested writes"; `indeterminate`
    /// (transport error, ambient MKCOL failure, ambiguous status) must never be
    /// persisted as a capability verdict — the silent re-probe retries it later,
    /// and recording it would park a healthy server in flat mode until the next
    /// probe-revision bump.
    ///
    /// `certificateRefused` is a CASE rather than a flavour of `indeterminate`
    /// because the two demand opposite handling and Swift has to ask each caller
    /// which it means. `indeterminate` says "try again later"; this says "the
    /// connection itself was refused, and no later probe will do better until
    /// something outside the app changes". Folding it into `indeterminate` is
    /// exactly how a trust refusal disappeared into `folderCapable = false` while
    /// the connection test still reported success.
    enum FolderProbeOutcome: Equatable {
        case capable
        case rejected
        case indeterminate
        case certificateRefused(CertificateRefusal)
    }

    /// Which of the three CERTIFICATE refusals a probe hit. Deliberately narrower
    /// than `RemoteAgentTrustEvaluator.TransportErrorClass`: an outcome that
    /// carried the full class could name a timeout as a certificate refusal, and
    /// the whole point of the case that holds this is that a trust refusal is
    /// neither a capability verdict nor a reachability verdict.
    enum CertificateRefusal: Equatable, Sendable {
        /// This device does not trust the presented chain.
        case untrusted
        /// The chain IS system-trusted and the configured pin disagreed with its
        /// key — the one shape that means the connection may be intercepted.
        case mismatch
        /// The chain IS system-trusted and no digest could be computed for its
        /// key algorithm, so the pin was never compared.
        case keyUnpinnable

        /// `nil` for every non-certificate class, so a refusal can never be
        /// constructed out of a timeout, a cold tunnel, or a cancel. This
        /// exhaustive switch is the single place the split is decided; adding a
        /// transport class breaks it here rather than silently at a call site.
        init?(_ transportClass: RemoteAgentTrustEvaluator.TransportErrorClass) {
            switch transportClass {
            case .untrustedCert: self = .untrusted
            case .certMismatch: self = .mismatch
            case .certKeyUnpinnable: self = .keyUnpinnable
            // NOT a certificate refusal — no handshake happened, so there was
            // nothing to refuse. `mapTransportError` answers it directly, ahead
            // of this type, so the file lane still names it.
            case .blockedByATS: return nil
            case .timeout, .unreachable, .notEstablished, .offline, .cancelled: return nil
            }
        }

        /// The file-lane taxonomy code for this refusal. Each is its own code, and
        /// none of them is `.fileTransferUnreachable`: the host answered the
        /// handshake, so "check your file-server is running" sends the user
        /// hunting a problem that is not there.
        var fileTransferError: AppError {
            switch self {
            case .untrusted:
                // This device refused the certificate. The remedy is on the
                // server, and it is the shared one every lane shows, so the file
                // lane never invents a second story.
                return .fileTransferCertUntrusted
            case .mismatch:
                return .fileTransferCertMismatch
            case .keyUnpinnable:
                // System trust PASSED, so nothing disagreed — the pin simply
                // could not be computed for this key algorithm. Its own code so
                // the file lane states that, rather than borrowing the mismatch
                // warning.
                return .fileTransferCertKeyUnpinnable
            }
        }
    }

    /// The certificate refusal behind a transport failure, or `nil` when the
    /// failure was not a certificate verdict at all (a non-`URLError`, a timeout,
    /// a cold tunnel, a cancel). ONE place every probe in this file asks the
    /// shared classifier, so no catch block can answer the question its own way.
    private static func certificateRefusal(
        _ error: Error,
        signals: RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) -> CertificateRefusal? {
        guard let urlError = error as? URLError else { return nil }
        return CertificateRefusal(
            RemoteAgentTrustEvaluator.classifyTransportError(urlError.code, signals: signals)
        )
    }

    /// The throwaway collection ONE folder-capability probe run owns, named from
    /// that run's tag. Exposed (not private) so the cleanup tests can name the
    /// same directory the probe does instead of re-deriving the format — a
    /// second copy of this shape is how a test starts asserting against a name
    /// production no longer uses.
    ///
    /// The `__conduck_` prefix and `__` suffix keep it visibly ours in an `ls` of
    /// the agent's working directory, and the sanitized alphabet matches
    /// `makeStoredKey`'s so the path is structurally inert on the wire.
    static func probeCollectionKey(tag: String) -> String {
        "__conduck_probe_\(tag)__"
    }

    /// Probe whether `snapshot`'s file-server accepts the client's nested
    /// upload sequence: `MKCOL __conduck_probe_<8hex>__` (status INSPECTED), then
    /// `PUT __conduck_probe_<8hex>__/<tag>.txt`, `GET` byte-echo, best-effort
    /// `DELETE`. Callers: the staged Test Connection (which fails the whole test
    /// on `.certificateRefused` and collapses everything else to a Bool) and the
    /// silent launch-time capability refresh (upgrade-only — writes
    /// `folderCapable=true` on `.capable`, records a definitive revision on
    /// `.rejected`, does nothing on `.indeterminate` or a refusal).
    ///
    /// Classification:
    /// - PUT 2xx + GET echoes the written bytes → `.capable`.
    /// - PUT 2xx + GET serves something else / 404 → `.rejected` (a
    ///   uniform-200 wall or a server that acks writes it doesn't store —
    ///   nested uploads would not actually land).
    /// - PUT 403/405/409 AFTER a conclusive MKCOL (2xx created / 405
    ///   already-exists) → `.rejected` — the server saw the collection exist
    ///   and still refused the nested write (S3-DAV bridge, locked-down
    ///   nginx-DAV).
    /// - PUT 403/405/409 after an INCONCLUSIVE MKCOL (transport error, 5xx,
    ///   auth failure) → `.indeterminate` — the 409 is explained by the
    ///   missing parent, not by a folder-rejecting server.
    /// - PUT/GET transport failure carrying a CERTIFICATE verdict →
    ///   `.certificateRefused`. Never `.indeterminate`: the connection was
    ///   refused, so this probe learned nothing about folders AND no later probe
    ///   will, which is a different instruction from "try again".
    /// - Any other PUT status, any other PUT/GET transport error →
    ///   `.indeterminate`.
    ///
    /// When `session` is nil, builds the 15 s ephemeral cert-pinned session
    /// (same posture as `runConnectionTest`) and reads ITS evaluator. A caller
    /// supplying a `session` must supply `signals` too — the probe cannot read an
    /// evaluator it did not build, and without a verdict source a certificate
    /// refusal on that session is indistinguishable from a dead host. Tests inject
    /// a `MockURLProtocol`-backed session and state the verdicts they are testing.
    ///
    /// THE PROBE DIR IS PER-RUN (`__conduck_probe_<8hex>__`), and that name is
    /// the ownership proof the cleanup DELETE stands on. Under the old fixed
    /// name it did not exist: rclone — the documented happy path — re-answers
    /// `201` for a MKCOL of a collection that is ALREADY THERE, so `201` proved
    /// nothing, and two overlapping probes (two devices, or a Diagnostics sweep
    /// and a Settings tap) both believed they owned the directory. The first to
    /// finish issued the RFC 4918 §9.6 `Depth: infinity` DELETE and took the
    /// other's in-flight file with it, which cost that probe a spurious
    /// `.rejected` — a lane mis-parked on flat keys until the next Test
    /// Connection. With entropy in the name a `201` genuinely means "this call
    /// created it", so the recursive delete can only ever reach its own run.
    /// The nesting DEPTH is unchanged (one level, exactly the shape a real
    /// upload key uses), so the probe still measures what dispatch does.
    ///
    /// CLEANUP IS PART OF THE PROBE, because the served root is the AGENT'S OWN
    /// WORKING DIRECTORY — a directory this test leaves behind is litter in a
    /// folder the user works in, and it is visible to every `ls` the agent runs.
    /// So the collection is removed on EVERY exit past the MKCOL, not only the
    /// happy one, and the removal is:
    ///
    ///   - **narrow** — only THIS run's collection, only when THIS call's MKCOL
    ///     answered `201`. Anything else (a `405`, an ambient failure) means the
    ///     directory is not provably ours, and a recursive delete inside the
    ///     user's workspace may not run on a guess. Historic litter from an
    ///     older build is therefore left alone rather than swept — a sweeper
    ///     would need a rule for what is safe to delete, which is the guess this
    ///     is avoiding.
    ///   - **best-effort** — every outcome is swallowed (a server that refuses
    ///     collection `DELETE` is a real population, and a test that failed
    ///     because cleanup failed would be worse than the litter it cleaned).
    ///   - **trailing-slashed** — several DAV servers (nginx's `dav_methods`
    ///     among them) answer a collection `DELETE` without the trailing slash
    ///     with a `409` and leave the directory in place.
    ///
    /// THE LITTER TRADE-OFF, chosen deliberately: on a server that refuses a
    /// collection DELETE, a per-run name leaves one empty `__conduck_probe_*__`
    /// directory per Test Connection tap instead of reusing one. That is a
    /// handful of empty, obviously-Conduck-named directories over a lane's
    /// lifetime, bounded by user taps; the fixed name bought tidiness with a
    /// destructive DELETE fired on a `201` that does not mean what it says on
    /// the commonest server. Tidiness loses.
    static func probeFolderCapability(
        snapshot: SettingsManager.FileTransferSnapshot,
        session: URLSession? = nil,
        signals: (@Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals)? = nil
    ) async -> FolderProbeOutcome {
        let probeSession: URLSession
        let ownsSession: Bool
        let attemptSignals: @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals
        if let session {
            probeSession = session
            ownsSession = false
            attemptSignals = Self.probeSignals(override: signals, evaluator: nil)
        } else {
            let built = makeProbeSession(pinnedFingerprintHex: snapshot.certFingerprintHex)
            probeSession = built.session
            ownsSession = true
            attemptSignals = Self.probeSignals(override: signals, evaluator: built.evaluator)
        }
        defer { if ownsSession { probeSession.invalidateAndCancel() } }

        let probeTag = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        // Nested path: a real `/` separator. `buildUploadRequest` resolves it via
        // `URL.appending(path:)`, which keeps the slash unescaped as a path
        // separator (the whole point of the probe). The collection carries the
        // run's entropy so a `201` below is proof of CREATION rather than a
        // guess — see the header's ownership note.
        let collectionKey = Self.probeCollectionKey(tag: probeTag)
        let nestedKey = "\(collectionKey)/\(probeTag).txt"
        let body = Data("conduck-nested-probe".utf8)

        // Create the collection first — the client's real upload sequence is
        // MKCOL-then-PUT (WebDAV won't auto-create the parent; rclone 409s a
        // nested PUT into a missing folder). Conclusive = the server answered
        // that the collection now exists: 2xx (created; rclone re-answers 201
        // on repeat) or 405 (RFC 4918 "already exists"). A `405` on a name
        // carrying this run's entropy is a server quirk, not a real collision —
        // it still says the parent is there, which is all `mkcolConclusive` is
        // asked, and the cleanup guard below refuses it anyway.
        let mkcolStatus = await performMkcol(
            snapshot: snapshot, collectionKey: collectionKey, session: probeSession)
        let mkcolConclusive = mkcolStatus.map { (200...299).contains($0) || $0 == 405 } ?? false

        // `201` on a per-run name is the ONLY status that proves this call minted
        // the collection, which is the only ground on which it may recursively
        // remove it (see the header). Every exit below runs this; it is a no-op
        // otherwise.
        let removeProbeCollection: () async -> Void = {
            guard mkcolStatus == 201 else { return }
            await bestEffortDeleteCollection(
                snapshot: snapshot, collectionKey: collectionKey, session: probeSession)
        }

        // PUT the nested file. Body via `from:` only (no `httpBody` — see the
        // flat-write path: it makes URLSession warn about a body on an upload task).
        let putRequest = buildUploadRequest(snapshot: snapshot, storedKey: nestedKey, contentLength: body.count)
        let putStatus: Int
        do {
            let (_, response) = try await probeSession.upload(for: putRequest, from: body)
            guard let http = response as? HTTPURLResponse else {
                await removeProbeCollection()
                return .indeterminate
            }
            putStatus = http.statusCode
        } catch {
            // The verdict is READ BEFORE the cleanup request, always: the signals
            // describe the attempt that just failed, and a DELETE on the same
            // session raises its own challenge and would overwrite them.
            let refusal = certificateRefusal(error, signals: attemptSignals())
            await removeProbeCollection()
            if let refusal { return .certificateRefused(refusal) }
            return .indeterminate
        }

        guard (200...299).contains(putStatus) else {
            // Best-effort clean up any partial before classifying.
            await bestEffortDelete(snapshot: snapshot, storedKey: nestedKey, session: probeSession)
            await removeProbeCollection()
            switch putStatus {
            case 403, 405, 409:
                // Definitive folder-rejection ONLY when the parent provably
                // existed; otherwise the status is explained by the missing
                // parent (ambient MKCOL failure) and proves nothing.
                return mkcolConclusive ? .rejected : .indeterminate
            default:
                return .indeterminate
            }
        }

        // GET it back — confirm the nested write actually landed + is served.
        // Same byte-echo as the flat read stage: a uniform-200 auth-wall would
        // 200 the GET with its own HTML, so require the returned body to EQUAL
        // the nested payload we PUT before crediting folder-capability. Full-range
        // GET so the whole body comes back to compare. Transport error →
        // indeterminate (the write may well have landed) UNLESS it carries a
        // certificate verdict, which is about the connection and not about the
        // write; a served-but-wrong body or 404 → rejected (acked writes that
        // don't land are not a lane).
        let getRequest = buildDownloadRequest(snapshot: snapshot, storedKey: nestedKey)
        let outcome: FolderProbeOutcome
        do {
            let (data, response) = try await probeSession.data(for: getRequest)
            if let http = response as? HTTPURLResponse, probeStatusPrefilter(status: http.statusCode) == .exists {
                outcome = (data == body) ? .capable : .rejected
            } else {
                outcome = .rejected
            }
        } catch {
            outcome = certificateRefusal(error, signals: attemptSignals())
                .map(FolderProbeOutcome.certificateRefused) ?? .indeterminate
        }

        // Best-effort cleanup (never affects the verdict). File first, then the
        // collection: a server that refuses to delete a non-empty collection
        // would otherwise keep the directory AND its probe file.
        await bestEffortDelete(snapshot: snapshot, storedKey: nestedKey, session: probeSession)
        await removeProbeCollection()
        return outcome
    }

    /// Best-effort DELETE of the staged-test probe file. Swallows every outcome
    /// (success, non-2xx, transport error) — an orphaned probe file is harmless
    /// and must never turn a passing test into a failure.
    private static func bestEffortDelete(
        snapshot: SettingsManager.FileTransferSnapshot,
        storedKey: String,
        session: URLSession
    ) async {
        let request = buildDeleteRequest(snapshot: snapshot, storedKey: storedKey)
        _ = try? await session.data(for: request)
    }

    /// The collection form of `bestEffortDelete`, and the ONE place the trailing
    /// slash is applied. RFC 4918 §9.6 makes a collection DELETE act at `Depth:
    /// infinity`, and several servers (nginx `dav_methods DELETE` among them)
    /// answer `409` and leave the directory in place when the request-URI does
    /// not end in `/` — so a slashless collection DELETE silently cleans nothing.
    /// Swallows every outcome, exactly like the file form: a server that refuses
    /// to remove collections at all must never turn a passing test into a
    /// failing one.
    ///
    /// The KEY IS THE SAFETY BOUNDARY. This is a recursive delete inside the
    /// user's own working directory, so the only key any caller may pass is one
    /// the same call provably created — never a conversation folder, never a key
    /// derived from anything a server said.
    static func bestEffortDeleteCollection(
        snapshot: SettingsManager.FileTransferSnapshot,
        collectionKey: String,
        session: URLSession
    ) async {
        // Same builder as the file form (one auth header, one timeout); the
        // slash rides in on the key, because `appending(path:)` infers
        // "directory" from a trailing slash and keeps it in the request-URI.
        let request = buildDeleteRequest(snapshot: snapshot, storedKey: collectionKey + "/")
        _ = try? await session.data(for: request)
    }

    /// Map a transport failure to the file-transfer taxonomy via the shared
    /// `RemoteAgentTrustEvaluator.classifyTransportError` classifier (single
    /// source of truth). The trust verdicts are threaded through from the probe's
    /// own evaluator rather than hardcoded — a hardcoded `false` made a genuine
    /// certificate rejection indistinguishable from a cold tunnel. Everything
    /// that is NOT a certificate refusal collapses to unreachable, which keeps a
    /// transient `.secureConnectionFailed` (cold tunnel, no verdict set) and a
    /// connect-timeout reading as reachability rather than as a cert failure.
    /// Never names the credential.
    private static func mapTransportError(
        _ error: Error,
        signals: RemoteAgentTrustEvaluator.AttemptTrustSignals
    ) -> AppError {
        // -1022 FIRST, and lane-neutral: `CertificateRefusal` correctly declines
        // it (nothing was refused because nothing shook hands), and the
        // unreachable fallback would send the user to check a server that was
        // never contacted.
        if let urlError = error as? URLError,
           urlError.code == .appTransportSecurityRequiresSecureConnection {
            return .insecureConnectionBlocked
        }
        return certificateRefusal(error, signals: signals)?.fileTransferError ?? .fileTransferUnreachable
    }
}

// MARK: - Strict listing parser delegate

/// `XMLParser` delegate for `FileServerClient.parseListing`. Collects one
/// `Response` per `<response>` element and REFUSES the document the moment it
/// meets something it cannot account for.
///
/// Strictness is the whole point, and it is why this file carries no tolerant
/// sibling: a delegate that accumulates whatever it can and reports no failure
/// would report a listing nobody fully understood as an ordinary short one, and
/// "the agent produced nothing" CLOSES a turn. This one:
///
///   - requires `multistatus` as the root element
///   - requires every `<response>` to sit DIRECTLY under it, and refuses the
///     document for one that does not — a row in an unrecognised wrapper is a
///     row nobody understood, and dropping it would report a file that exists as
///     an empty folder
///   - requires exactly one `<href>` per `<response>`
///   - keeps property values only from a `2xx` `<propstat>`, and records the
///     response-level `<status>` separately — both as a usability flag and as
///     its raw code, so RFC 4918's not-found rows can be dropped by the listing
///     instead of emitted as ordinary entries AND read by the absence witness as
///     the server saying the collection is not there
///   - bounds element nesting and response count, aborting the parse rather
///     than accumulating
///   - records WHY it stopped, so the caller can tell "too many entries" from
///     "this is not a multistatus document"
///
/// Namespace-agnostic on local names (`D:`, `d:`, or unprefixed `DAV:`) —
/// prefixes are a serialization choice and a listing that refused one would
/// refuse real servers.
private final class StrictListingParserDelegate: NSObject, XMLParserDelegate {

    /// One `<response>`, reduced to what a listing decision needs.
    struct Response {
        var href: String
        var isDirectory: Bool
        var byteSize: Int
        /// Whether the resource itself is usable: no non-`2xx` response-level
        /// `<status>`, and at least one `2xx` `<propstat>`.
        var isUsableResource: Bool
        /// The response-level `<status>`'s code, or nil when the `<response>`
        /// carried none or carried one nobody could read.
        ///
        /// Kept as the raw code alongside the flag above because the two answer
        /// different questions. The listing only needs "may this row become a
        /// chip", which a Bool covers; the absence witness needs to tell a `404`
        /// (the collection is not there — the answer it came for) from a `403`
        /// or a `423` (the collection may well be there and something else went
        /// wrong), and a Bool cannot. nil is NOT a code the caller may treat as
        /// benign: a status nobody could read is not a server saying anything.
        var resourceStatusCode: Int?
    }

    /// Deepest element nesting accepted. A `207` describing one flat collection
    /// nests a handful deep; anything past this is a body doing something other
    /// than listing a directory, and refusing it keeps the work bounded.
    private static let maxElementDepth = 32

    private(set) var responses: [Response] = []
    private(set) var sawMultistatus = false
    private(set) var refusal: FileTransferListingRefusal?

    private let maxResponses: Int

    /// Open-element local names, outermost first. Every scoping question below
    /// ("is this `<status>` the resource's or a propstat's?") is answered from
    /// this rather than from a bag of booleans that can drift out of step.
    private var stack: [String] = []

    // Per-`<response>` accumulators.
    private var hrefCount = 0
    private var href = ""
    private var resourceStatusIs2xx = true
    private var resourceStatusCode: Int?
    private var usablePropstats = 0
    private var propstatCount = 0
    private var isDirectory = false
    private var byteSize = 0

    // Per-`<propstat>` accumulators, merged into the response only on a `2xx`.
    private var propstatStatusIs2xx = false
    private var propstatIsDirectory = false
    private var propstatByteSize = 0

    // Element-text capture.
    private var capturing = false
    private var charBuffer = ""

    init(maxResponses: Int) {
        self.maxResponses = maxResponses
        super.init()
    }

    /// Lowercased local name, stripping any `prefix:`.
    private func localName(_ elementName: String) -> String {
        if let colon = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...]).lowercased()
        }
        return elementName.lowercased()
    }

    private func refuse(_ reason: FileTransferListingRefusal, _ parser: XMLParser) {
        if refusal == nil { refusal = reason }
        parser.abortParsing()
    }

    /// `<getcontentlength>` as a plain decimal byte count, or nil when it is
    /// anything else. Stricter than `Int.init` on purpose — that accepts signed
    /// forms and non-ASCII digit scalars, none of which a server should send —
    /// and nil renders as "no size" on the chip, which is better than a wrong
    /// one sailing past the large-download confirm.
    private static func contentLength(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// The code carried by a `<status>` line (`HTTP/1.1 200 OK`), or nil when
    /// there is no three-digit ASCII field to read one from.
    ///
    /// The FIRST such field wins and the scan stops there, so a reason phrase
    /// that happens to contain digits cannot re-decide a status that was already
    /// stated.
    private static func statusLineCode(_ line: String) -> Int? {
        for field in line.split(separator: " ", omittingEmptySubsequences: true) {
            guard field.count == 3, field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let code = Int(field) else { continue }
            return code
        }
        return nil
    }

    /// Whether a `<status>` line reports success. Anything unparseable is NOT
    /// success — a status nobody can read is not permission to emit the row it
    /// covers.
    private func statusIs2xx(_ line: String) -> Bool {
        guard let code = Self.statusLineCode(line) else { return false }
        return (200...299).contains(code)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let local = localName(elementName)
        if stack.isEmpty {
            guard local == "multistatus" else { return refuse(.malformedBody, parser) }
            sawMultistatus = true
        }
        guard stack.count < Self.maxElementDepth else { return refuse(.malformedBody, parser) }
        stack.append(local)

        switch local {
        case "response" where stack.count == 2:
            hrefCount = 0
            href = ""
            resourceStatusIs2xx = true
            resourceStatusCode = nil
            usablePropstats = 0
            propstatCount = 0
            isDirectory = false
            byteSize = 0
        case "propstat":
            propstatCount += 1
            propstatStatusIs2xx = false
            propstatIsDirectory = false
            propstatByteSize = 0
        case "collection":
            // Only inside a `<resourcetype>`, so a stray element of that name
            // elsewhere cannot mark a file as a folder.
            if stack.dropLast().last == "resourcetype" { propstatIsDirectory = true }
        case "href", "getcontentlength", "status":
            capturing = true
            charBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { charBuffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localName(elementName)
        guard stack.last == local else { return refuse(.malformedBody, parser) }
        stack.removeLast()
        let parent = stack.last
        let text = charBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        capturing = false

        switch local {
        case "href" where parent == "response":
            hrefCount += 1
            href = text
        case "getcontentlength" where parent == "prop":
            if let value = Self.contentLength(text) { propstatByteSize = value }
        case "status" where parent == "propstat":
            propstatStatusIs2xx = statusIs2xx(text)
        case "status" where parent == "response":
            resourceStatusCode = Self.statusLineCode(text)
            resourceStatusIs2xx = statusIs2xx(text)
        case "propstat":
            // Properties count only when the server said they were found.
            if propstatStatusIs2xx {
                usablePropstats += 1
                if propstatIsDirectory { isDirectory = true }
                if propstatByteSize > 0 { byteSize = propstatByteSize }
            }
        case "response" where parent == "multistatus":
            guard hrefCount == 1 else { return refuse(.malformedBody, parser) }
            guard responses.count < maxResponses else { return refuse(.tooManyEntries, parser) }
            responses.append(Response(
                href: href,
                isDirectory: isDirectory,
                byteSize: byteSize,
                // No propstat at all means the response stated nothing about the
                // resource, which is not evidence that it is there.
                isUsableResource: resourceStatusIs2xx && usablePropstats > 0,
                resourceStatusCode: resourceStatusCode
            ))
        case "response":
            // A `<response>` anywhere but directly under `<multistatus>` REFUSES
            // the document. RFC 4918 puts it exactly one level down, so a deeper
            // one means this body has a structure nobody here understood — and
            // the only two ways to handle a row you did not understand are to
            // refuse the answer or to lose a file. Silently dropping it made
            // `<multistatus><sync><response>report.pdf</response></sync></…>`
            // read as "the folder is empty", which past the grace window stamps
            // the turn done forever with no row and no way back.
            return refuse(.malformedBody, parser)
        default:
            break
        }
    }
}

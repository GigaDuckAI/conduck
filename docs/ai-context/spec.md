# Conduck — Architecture

*This file changes only when a decision changes: something that was rejected becomes the design, or a boundary moves. It does not track features, status, or progress.*

## What this document is

This is the part of Conduck that reading the code will not tell you. It records the boundaries, the decisions behind them, and — most importantly — the designs that were considered and deliberately refused. Code shows what was built; it never shows what was rejected, and a contributor who does not know what was rejected will propose it again.

Everything else lives closer to the thing it describes:

| Question | Where the answer lives |
|---|---|
| What does this file do? | Its header comment. Every source file has one — `CONTRIBUTING.md` requires it. |
| What are the folders, targets and build rules? | [`project-structure.md`](project-structure.md) |
| How does this behave in this exact case? | The tests. There are thousands, and several exist specifically to encode a rule that code review kept failing to catch. |
| What is the current value of some limit? | `Conduck/Conduck/Utilities/Constants.swift`, or the type named beside the constant wherever this document qualifies one. |

**Where this document and the code disagree, the code is right.** Report the discrepancy; do not reconcile the code to the document.

Two rules keep this file small enough to stay true, and they are worth knowing before you edit it. A sentence belongs here only if it cannot be confirmed by opening one file. And numbers are never written down — the name of the constant that owns the number is written instead, because a name stays findable and stays true when the value changes.

---

## What Conduck is, and where the boundaries are

Conduck is a native client. It is not an AI, it does not host one, and it does not run a service. The user brings the AI — either a gateway they run themselves, or a hosted model under their own key — and Conduck is the thing on their phone, wrist, desk and dashboard that talks to it by voice.

Three parties exist, and keeping them straight explains almost every decision below:

- **The user's device.** Holds the conversation history, the settings, and the keys. Does the recording, the on-device speech recognition, the read-aloud, and the request assembly.
- **The user's gateway.** A server *they* operate, reachable at all times, running the agent. It has the tools, the file system, the long-running jobs. It is not ours.
- **Third parties the user chose.** A cloud speech provider, or a hosted model service, each under the user's own API key.

We — the people who publish Conduck — are in none of those. There is no fourth party. That is not a promise about how we behave; it is a statement about what exists, and it is the reason most of the design looks the way it does.

Several words in this document carry a narrower sense here than they do elsewhere in the industry, and *gateway* carries nearly the opposite one — it names the user's own always-on machine, not a routing proxy in front of model providers. The glossary in [`README.md`](../../README.md#the-words-this-project-uses) settles each of them, and a reader who has not read it will misplace which layer of their own stack this document is about.

---

## The decisions

### There is no server of ours, and there never will be in this app

No backend, no analytics, no telemetry, no crash reporting, no rate-limiting service, no health endpoint, no account system. **The app never makes a network request to anything we operate** — beyond Apple's own services, which are enumerated under "Data, secrets, and what leaves the device", every request in the tree goes to the AI the user configured, their speech provider, or their file server. The only publisher-operated destinations that exist at all are website links the user has to tap, and a Send Feedback item that composes a mail message carrying the app version, the OS version and the device model. Both require a deliberate action and neither happens on its own.

It also never registers for remote notifications and holds no push token; every notification it posts is local. The push entitlement and the remote-notification background mode are present, on both the phone and the watch, only because iCloud sync uses a silent push under the hood.

**Why:** a privacy claim backed by a policy is a promise; a privacy claim backed by an absent server is a fact. It also settles a legal question cleanly — with no server in the path we are neither processor nor controller of anyone's conversation data, so there is nothing to disclose, nothing to breach, and no data-processing agreement to sign.

**What this costs, and why it is accepted:** we cannot see crashes, cannot measure usage, cannot ship a server-side fix, and cannot rate-limit abuse. Every one of those is a real loss and none is worth the trade.

**Do not propose** adding an operator-run endpoint to this app for any reason — not for diagnostics, not for a config feed, not for a "just this one thing" convenience. Adding an analytics or crash-reporting dependency is not a routine dependency bump; it is a decision at the level of what the product is.

### The gateway is the user's always-on server, and the device is a thin client

Anything durable — hosting, file storage, background jobs, long-running work — belongs on the gateway. The device sleeps, suspends, and gets killed by the OS; the gateway does not.

**Why:** the split follows from what each side can actually guarantee. Putting durable work on a phone means discovering, repeatedly and in production, that the phone was not running.

This is not in tension with having no backend of our own. The always-on server is *the user's*.

### The hosted-model lane is an on-ramp, not the product

A user with no gateway can point Conduck at a hosted model service under their own key and have working multi-turn chat immediately. This lane is deliberately limited: no agent tools, no agent loop, and no file lane. Attachments still work — an image or a text file rides inline to the model exactly as it does everywhere else — but there is no file server to upload a binary to, and no way for the agent to hand a file back. Those need a real gateway.

**Why:** the alternative to an on-ramp is that a curious user has to stand up a server before they can find out whether they like the app. But the lane must stay visibly second-class, or the product quietly becomes a thin wrapper around someone else's hosted API — which is not what it is for.

Conversation history is explicitly *not* one of the limits: it is client-owned on every lane, so nothing here depends on a gateway remembering anything.

### The user brings the keys; there is no house key

Nothing is paid for by us. Where a credential is needed it is the user's own, entered by them — and there is consequently no notion of a user account in the app at all. Some paths legitimately need no credential: Apple's on-device engines take none, and a gateway on a private network may run keyless, which is an explicit choice rather than an inference (see below).

### The client owns the conversation, and sends it whole every turn

The conversation store on the device is the authority. Each turn sends the messages the client decides to send, statelessly. There is no session identifier, no server-side conversation handle, and no concept of a session being busy. The request body is the same shape on every lane.

**Why, and this is not obvious:** server-side sessions look like they would save tokens, and they do not. The gateway re-sends the full history to the model regardless of whether the client sent it, so the tokens are spent either way. What server state actually changes is *who can trim the history* — and only the client is in a position to do that, because only the client knows what the user is looking at. Server state costs a synchronisation problem and buys nothing.

**Rejected:** session pinning, and the session-busy failure path that comes with it.

**Also deliberately absent from the request body: the OpenAI `user` field.** It looks harmless and standard, which is exactly the danger — at least one supported gateway falls back to `user` as a session key when no explicit one is present, so sending it would silently pin a server-side session and quietly undo everything above. The body carries the messages, the streaming flag, and a model name where one is required. Nothing else.

Two separate things trim what is sent, and both are caps on the wire rather than retention policies. Turn-count trimming happens in one function, bounded by `Constants.contextMaxTurns`, and all four request builders — in-app, background, CarPlay, Watch — go through it. Independently, a per-gateway image-history policy decides how far back image bytes are re-sent, because re-uploading every past picture on every turn is the single most expensive thing a long thread can do. Nothing is ever deleted from history for being old; conversations persist until the user deletes them.

### One network client serves every gateway kind

**There is no per-kind branching in request building, response parsing, or error handling** — one assembler, one decoder, one status map serve every kind, and the settings screens render themselves from a capability descriptor: a data record saying which endpoint, which authentication scheme, whether it supports pairing, whether it supports file transfer. A *custom* OpenAI-compatible endpoint is therefore pure configuration and adds no code at all. A new *built-in* kind is not quite free — it also has to be added to a handful of exhaustive switches and a feature flag — but the networking, parsing and error surface are untouched either way.

**Why:** per-kind branches multiply. Every kind times every behaviour is another place for a bug to hide, and each new kind reopens all of them at once. A descriptor is one row.

**Rejected:** per-kind request/parse/error dispatch, and per-kind settings screens.

**No probe may decide anything from an HTTP status alone.** The servers Conduck talks to routinely answer 200 with something that is not the thing you asked for — a gateway with its chat endpoint switched off (the default state) serves its own control-panel HTML at 200 on the model-list path, and an SSO portal in front of a file server answers everything with a login page. A status-only check therefore reports a broken gateway as working, which is worse than reporting nothing. Every verdict reads the body.

### A file the agent produces comes back in a folder the app named for that one reply

The gateway connection carries text and nothing else, and the agent platforms that define their own attachment syntax strip it before a reply leaves them. So the app names a folder on a file server both sides can already reach, tells the agent where it is in the outgoing turn, and lists exactly that folder once the reply is in. Nothing outside it is looked at, and no reply is read for filenames on this route. Every dispatch names its own folder, a retry included, because a folder reused across attempts lets a late write from an abandoned attempt arrive as this reply's work.

**The app names the folder and deliberately does not create it.** Creating it first is the obvious design and is refused on measurement: a client-created folder belongs to whichever user the file-server process runs as, and on the commonest self-hosted gateways that is not the user the agent runs as — so a *successful* creation hands the agent a directory it can neither write into nor replace. **Do not re-propose creating it.** Naming costs no credential and no round trip, which is why the Watch, which never receives the file-server credential, names a folder like every other surface.

**What the name establishes is freshness, not provenance.** The folder belongs to one conversation and one dispatch, the name is unguessable, and a credentialed device requires the server to confirm it absent before the turn goes out. Together those say only that whatever is found inside arrived after this turn named it. The file server serves the agent's own workspace, so the same principal writes the files and writes the reply: there is no claim to corroborate, and the question is not whether the agent's statement about a file is true but what is in the folder this dispatch named.

**A file server must prove it can say no before it is allowed to say yes.** A host with a catch-all fallback answers a listing for a folder it does not have and returns a valid byte range for a file never written; both describe the representation the server chose and attest to nothing about routing. So before a listing that names files is believed, that same server must answer a sibling folder that cannot exist with a definite miss. A server that answers everything disqualifies itself. What this establishes is a property of the *server*, not of the folder.

**Rejected:** deriving delivery from a before-and-after snapshot of the shared folder, which proves something changed in an interval and not which dispatch changed it — concurrent conversations, scratch files, background jobs and delayed writes all break the attribution; a manifest or sentinel block in the reply, which is a second permanent wire convention, harder for an agent to satisfy than writing into a folder it was handed, and worthless where the sentinel is meant to authenticate, since the secret travels to the gateway on the channel the reply returns on; and reporting probe results back to the agent, which would turn the user's file server into an existence oracle for whatever is on the other end of the gateway.

### Sending files and getting them back are two capabilities of one lane

A WebDAV server that accepts writes and reads but implements no directory listing is a large, ordinary population, and it carries a user's attachments perfectly. Treating that as a failed setup would revoke the half that works to punish a half that was never going to work. So the connection test settles two verdicts separately — the byte round-trip decides whether the lane may carry anything, the listing check only whether anything can come back — and a lane that passes the first and fails the second stays configured and usable. Every surface reads those stored verdicts rather than a result it produced itself: the test is offered in more than one place, so a conclusion each screen remembered privately would be one the others contradicted. The stored verdict is also the one the wrist gates on, which keeps a phone and a watch from telling one user two stories about one server.

**A stored verdict must never outlive the fact.** The app re-asks quietly at each launch, away from the path a message takes, and widens the verdict the moment the server answers; narrowing only ever comes from proof. A launch-time question cannot help someone who never quits the app, which is why the screen stating the limitation offers the connection test directly.

**A failing lane is backed off, never switched off**, because switching it off would take away the only control the user has to switch it back on. The absence check sits on the critical path of every send, a pure-text turn included, so a server that has gone away would otherwise add its whole deadline to every message typed. Patience depends on the shape of the failure rather than its severity: a lane that returned no HTTP response at all is paused on the first observation, because the commonest cause is a tunnelled address whose hostname rotated and a host that is not there will not be there next turn either, while a lane that answered unhelpfully must fail repeatedly, because a rejected credential or a server error is transient often enough that one sample is not a diagnosis. The backoff withholds a request, never the truth. It is process-local health, never persisted and never shown in settings, cleared by a relaunch, by any edit to the address, credential or pin, by a passing test, and by the user asking for a turn to be looked at again. A passing test clears it whatever the listing check concluded: that check settles a claim about the server and may only be made on proof, while the pause is a guess about whether another request is worth spending.

**A server that has stated it cannot list is not on that ladder**, because it is not failing and there is nothing to wait out. The stored verdict decides this before the pre-dispatch check spends anything; re-learning a permanent property of the user's own server would put a request on the critical path of every message forever to reach a conclusion their settings screen already states. One narrowing does come from that check, and only one: a lane claiming a whole run of freshly named folders already exists has made a positive claim about paths that are not supposed to exist, on a different unguessable name each time, and nothing about how a missing path is served explains that. It is read as a limit rather than a fault, goes quiet for the rest of that run of the app, and is never stored, couriered or displayed — a notice here could name no cause it is in a position to name and offers no control that would stop it.

### A turn that hands back no files is the ordinary case, and the app says nothing about it

Most replies produce nothing, and since nothing creates the folder in advance, an absent folder is what an ordinary reply looks like — indistinguishable from an agent that ignored the instruction or wrote elsewhere. A notice there would fire constantly and carry no information.

**A file that is not there yet is not the same as a file that is not coming.** Nothing orders the write against the reply, so a first listing that finds nothing is evidence about timing. An empty folder and an absent one both leave the turn open, and only a listing past a grace horizon closes it. Outcomes that say nothing about the folder — an unreachable server, a refused certificate, a rejected credential, a listing the app cannot trust — never close it, so a broken file server is never reported as a broken promise.

The silence is owed to an *empty* answer, not to every answer that yields no download. What the user is told about is a file server they configured, that worked, and that has stopped: either the app could not read the folder it named, or it could not name one because the pre-dispatch check went unanswered. **Any reassurance offered on the first is about Conduck and never about the server**, because a read that failed establishes nothing about the folder — not that it still holds anything, and not even that it exists. What is true by construction is that this lane only lists and reads: nothing in it writes into an output folder or deletes from one, so whatever the agent put there is untouched. The second case can say neither that nor "look again", because a turn that carried no location line never told the agent where to write; what it can say is that an agent given no destination writes where it normally writes, so the work is misplaced rather than lost.

**A turn with no folder is only a fault if the lane was supposed to give it one.** Three folder-less turns are indistinguishable in the record and none is a failure: a turn dictated on the Watch whose lane the phone has not couriered as ready; a turn on a lane that cannot list at all; and a row mirrored from iCloud before the folder attribute existed on it. So the app decides from two live facts instead of from the record — the lane must be failing its check *now*, and the turn must have landed after that run of failures began. Without the first the notice outlives the outage it describes; without the second one rotated hostname lights up every wrist turn in the thread's history. The verdict is derived when the thread is drawn and never stored, so it clears the moment the server answers.

### What the app hands over by itself is a policy about opening, not a safety boundary

The gate reads the name and never a byte of the contents, so an agent that means harm renames its payload and walks through untouched; the only party a short list reliably stops is an honest one. What it settles is narrower and still worth settling: whether a one-tap download appears with no user involvement at all. So a refusal may never be a dead end — anything turned down can still be saved, by name and one file at a time, by a user who asks, and Conduck still does not open it: those bytes go to the system's own save browser, and the verb offered is always *save*, never *install*. Widening the list is a product decision about the default rather than a loosened defence.

**A folder that a pass read, holding things the app will not hand over on its own, is reported under the reply — standing there, without a tap.** A refusal reported only on a tap is one most users never hear about and that does not survive the process, leaving an undelivered entry as invisible as an empty folder — the failure this row exists to end.

What the row states is a census of one listing, in populations counted apart because they have different remedies: names whose *type* the app does not open by itself, names the app will not repeat at all, and deliverable files a budget left behind. Only the first may be named, and that licence is structural rather than a judgement — the type test is the last gate a name passes, so a name refused there has already cleared every guard a delivered file's label cleared. A name refused by an earlier guard reaches no screen, no record and no rescue; its whole presentation is a count, permanently, split only by whether the name merely overran a length budget, because a long ordinary name is benign and the sentence covering the other guards accuses it of an attack that did not happen.

**The row may never promise a delivery nothing proved.** A remainder is carried with the cause that produced it, so "ask again and the rest arrive" is spellable only where a pass established that the reply can still hold them; where `FileTransferOutputDetector.maxOutputChipsPerMessage` binds, the row says the opposite and points at the save. Permanence is never read off the fact that the turn is closed, because a turn also closes on age.

**What makes the census safe to persist is that it is an observation of a folder a pass actually read**, not an inference about one. Only a pass that got a listing back writes one, so a momentary outage cannot retire a standing refusal. Absent means never observed, never "the folder holds nothing" — a census of all zeroes is itself a positive finding, and it is the one that retires the row. Every pass replaces the census wholesale, so the record never accumulates. Two things move after a census is written — which types the app opens by itself, and how much room the reply still has — so neither is trusted from the record when the row is drawn. The record keeps only a bounded number of names (`OutputDeliveryOutcome.maxRetainedRefusedNames`), because those names come from whatever wrote into the folder and replicate to every device the user owns; where the count outruns them the row says so, rather than offering fewer files than it has claimed.

**Rejected:** persisting a verdict that a named file is *missing*, which is an inference about a folder rather than an observation of one — it creates a stored claim with nothing to re-derive it from, which must then be reconciled against a world that has moved on.

### A file found on the phone reaches the wrist as a description

The Watch holds no file-server credential and can never find the file itself, so the row is created on a device that can and the shared database mirrors it to the wrist in its own time — minutes, in the field. That is far too slow for someone still looking at the reply they just dictated, so the phone also hands the description across the paired link the moment it attaches the row: the name, the size, the type, and which turn it belongs to. Never the bytes, never a preview, never the server's address, and never a credential — the wrist gains something it can draw, not something it could fetch. It goes out on both channels at once, because they answer different questions: the queued channel survives a wrist asleep or out of range and is what guarantees arrival, and the interactive one fires only when the Watch app is awake, which is exactly when a second matters. Duplicates are harmless because the wrist recognises a description by its turn and the file's identity. On the wrist it is an overlay and never a local database write, which would make it a record in its own right that mirrors back and stands beside the phone's forever.

**Reading filenames out of reply text happens only when the user asks for it.** It is available on every agent turn, including ones that never named a folder, and what it finds is labelled as found on the file server rather than as produced by the reply, because a name lifted from a reply is a name the reply chose and the folder had no part in. It never runs by itself and never spends bytes without a tap.

### Replies are not streamed, and that is deliberate on both sides

Every request asks for a complete response, the decoder only ever reads one whole JSON body, and the published adapter contract tells third-party gateway authors to answer synchronously even if a request appears to ask for a stream.

**Why:** on iOS the whole turn rides a background upload task that survives the app being suspended or killed. That is what lets a capture from the Action Button, the Watch or CarPlay complete after the user has put the phone away — and such a task buffers one complete response body, with nowhere to put incremental tokens. Streaming would require a live foreground process for the length of every reply, which is exactly what those surfaces cannot promise. (The Mac has no background sessions and sends from a long-lived foreground process instead, so the constraint is not its own — but the wire contract is shared, so the decision is made once.)

**That one transport choice closes a whole family of alternatives at once.** A background upload task is the *only* thing on iOS that survives suspension across a reply that can take minutes, because the system hands the transfer to a separate process and relaunches the app when it finishes. Anything that needs a live socket held open by our own process cannot do that — which rules out SSH tunnelling, an embedded mesh VPN, WebRTC, and any relay we would operate, all at once. Do not re-propose them individually; the answer is the same each time, and it is not about the merits of the protocol.

### Who names the model is a property of the gateway, not a user preference

Built-in self-hosted gateways are sent **no model name at all**. The hosted lane requires one on every request. A custom OpenAI-compatible endpoint may set one.

**Why:** for a gateway the user runs, the operator already chose the model — that choice *is* the point of self-hosting, and a client-side override would quietly undo it. Hosted services and many generic OpenAI-compatible servers refuse a request that does not name a model, so there the name is mandatory. This is also why "no model set" is a different error from "wrong model": in one case there is nothing to correct, and the fix is to choose one.

### Speech providers are dispatched by value, not through an engine protocol

The on-device engine and the cloud providers share one dispatch path, selected by a transport value rather than by conforming to a common engine protocol.

**Why it is worth writing down:** the protocol refactor is the obvious tidy-up and it has a real threshold. It is refused while exactly one provider runs entirely on-device, because a protocol whose only purpose is to abstract a single case adds indirection and removes nothing. Reopen it at a second engine that runs entirely on-device — not at a general feeling that the dispatch looks untidy.

### Authentication fails closed, and keyless is never inferred

Whether a connection sends a bearer token is an explicit setting per gateway, not something derived from whether a token happens to be present. A gateway configured to use a token, with no token available, reads as *not configured* — it does not fall back to sending the request unauthenticated.

**Why this specific shape:** the gateway-token accessor deliberately collapses "there is no token" and "reading the token failed" into the same empty answer. The keychain *can* tell those apart, and the voice-key path does use the distinction — but the auth gate is written so it cannot, because if a missing token implied keyless, a transient read failure would silently send the user's conversation to their gateway with no credential attached. The collapse is onto the safe side: no resolvable token means not configured, always.

Keyless is a legitimate configuration — a gateway on a private network where the network *is* the authentication — but it is something the user states, never something the app guesses.

**A known and deliberate divergence:** Conduck accepts a keyless gateway, and accepts an empty reply string as a valid answer. The adapter contract published to third-party gateway authors permits neither. Both look like bugs and are not; the app is intentionally more forgiving than the specification it asks others to meet.

### Credentials may never be embedded in a URL

A gateway, file-server or voice-endpoint address containing a username and password is refused outright, at both the settings editor and the pairing importer, on write and on read.

**Why this is a storage rule, not input hygiene:** those URLs are written verbatim into the iCloud key-value store, and that store is *not* the developer-blind one (see below). A credential in a URL is a credential in the wrong store.

**What it costs:** this genuinely removed a capability. Embedding credentials in the URL was the only way to put a gateway behind a basic-auth reverse proxy. That was refused in favour of first-class authentication rather than kept as a convenience.

### A conversation is bound to one gateway, and the binding locks

The gateway is chosen when a conversation starts. Once the thread has turns in it, that binding is fixed; switching means cloning the conversation, not rebinding it. If the bound gateway has been deleted or unconfigured, sending throws — it never quietly reroutes to a different one.

**Why:** the whole history goes with every turn. Silently rerouting would hand one server the entire conversation the user had with a different one. There is no user-visible benefit that justifies that, and the failure is invisible when it happens.

**The rule governs a bound conversation and nothing else.** It says nothing about which gateway a *new* chat starts on: nothing has been sent yet, so there is no history to hand to the wrong server. The two questions are decided separately, and the next section decides the second one.

### The pointer to where a new chat starts is repaired only when there is one honest answer

Each device holds its own pointer at the gateway new conversations begin on, and the app never rewrites it merely because this device cannot use it — a pointer left alone is one that starts working again by itself when its key finishes syncing. When that pointer names a gateway this device cannot send to, the app moves it to one it can — but only when exactly one gateway can send, only when the secret store has proved itself readable, and only when no other gateway is sitting one unsynced token away from working. Every other shape — several candidates, none, or a pointer that might merely be locked rather than broken — is handed back to the user as a choice, and nothing is written down.

**Why repair at all:** the surfaces that follow this pointer have no picker in front of them — the Action Button, CarPlay, the Watch, a share drain. A pointer at a gateway that is not available here dead-ends every one of them while a working gateway sits beside it, and the user is given no way to see why.

**Why the conditions are that narrow:** a pointer the app invented is indistinguishable afterwards from one the user chose, so the app may only invent one where there is nothing to choose between. A repair that overrides a stored choice therefore records what it replaced, says so exactly once, and is one tap from the chooser where the default can be changed; where certainty is not available the user is asked instead. Reversal is not among the things that chooser offers — it lists only gateways that can send, and the one the repair replaced is by definition not among them.

**Rejected:** adopting the first configured gateway whenever no pointer is stored. It makes a permanent, unannounced choice among several gateways, decided by the order the gateway kinds happen to be declared in, that nothing ever revisits — and the user's first sign of it is a conversation already sealed to a server they never picked.

**A device with no pointer of its own inherits the account's last synced default only when that gateway can send at the moment it is read.** Nothing ever deletes that inherited value, so an install made long afterwards would otherwise arrive pointing at a gateway nobody has used in months and keep it forever. An inconclusive reading — iCloud has not finished arriving — writes nothing and is retried rather than settled, because a wrong answer here outlives the reason for it.

**Zero gateways readable is never grounds to change anything**, for the reason spelled out where the Watch teardown is authorised: a locked secret store, a restoring device and a genuinely empty one all read identically. On that reading the app repairs nothing, deletes nothing, blames nothing and refuses nothing — it fails closed and stays quiet. One gateway that uses a key reading as configured is the only accepted proof that the store is open — a keyless gateway proves nothing, because it never asks the store at all.

### A gateway you have not connected is an offer, not an unfinished task

The list of gateways is a menu of things you *may* connect. Not connecting one is not a defect, has nothing to finish, and is never described as though it were: no warning mark, no "needs setup", no place in any count of things needing attention. A row is either connected — a quiet green check — or it is not, and a row that is not simply says nothing.

**Why it cannot be described as unfinished even when something is stored:** the app cannot tell the two apart. A key still crossing iCloud Keychain and a configuration abandoned months ago read identically, so any word stronger than "this device cannot send on it right now" is a guess. The app says the weaker thing that is always true, and lets the situation resolve itself where it can.

**A gateway is only ever offered as a default if it can send.** The chooser lists what works; connecting something new happens in the gateway list, which is the screen that owns the whole catalog. A chooser that offered an unconnected gateway would be offering a choice that changes nothing.

**Where the app does say a stored default is unavailable, and where it stays quiet.** The sentence is owed only where the user went looking for it: the chooser they opened, the summary line that leads there, and the gateway's own screen. A conversation window says nothing — an unconnected gateway becomes a chore precisely by being mentioned on every launch, and the pointer is untouched, so it starts working again on its own if it was only waiting on iCloud. Anything the user *pressed* — a Shortcut, the Action Button, CarPlay, the watch — still names the gateway in its refusal, because there a silent failure is worse than a named one.

**Diagnostics reports faults, so it says nothing at all about an unconnected gateway.** What survives is what is genuinely broken: that no gateway on this device can send, that a specific saved conversation is bound to one that cannot, and that the default lane has nowhere to go. Clearing anything a gateway left behind is done from that gateway's own screen.

### Transport trust can only be tightened, never loosened

The gateway must present a certificate the device already trusts on an encrypted address. A self-signed certificate, or one from a private authority the device does not know, is refused — and Conduck cannot offer an "accept anyway" toggle even if it wanted to.

**Why this is not a policy choice:** App Transport Security, the platform rule Apple applies to every app's network traffic, permits an app to make certificate evaluation *stricter* and refuses to let it make evaluation looser. An untrusted certificate on a remote host fails inside the platform, below the app.

Certificate pinning exists as an optional power-user control and is additive only: it can reject a certificate the device would have accepted, and can never accept one the device would have rejected. **Not pinning is the recommended setup** — with no fingerprint configured, ordinary system validation applies, which is the right path for anyone using one of the free trusted-certificate routes.

A pin can only ever be typed in by a human. The pairing payload deliberately carries no certificate field, because a setup code is entirely attacker-supplied and a certificate claim inside one could only ever be a request to lower the app's standards.

The same object also carries the app's **cross-origin redirect refusal**, and the two live together for a reason: a redirect that changes host would carry the request body, the Authorization header and the user's pin scope somewhere they never configured. Know the scope, though — the refusal applies on the sessions that install this object as their delegate (connection tests, model discovery, custom voice endpoints, file-server probes, the Mac's converse session). The iOS background sessions do not go through it.

**Do not propose** a trust-override setting or a developer mode. It cannot be built.

### Encryption is required, except toward an address only the local network can reach

Every address the app stores must be an `https` one, with a single carve-out: plain `http` is accepted when the host is one that only the local network can reach — a loopback or private address literal, or a Bonjour name. A dotted domain name never qualifies, however private the machine behind it is; neither does a bare single-label name, because the public DNS root can answer one of those and an unencrypted request carries the key with it; and neither does the carrier-grade NAT range an overlay VPN hands out.

**Why the carve-out exists:** a large part of the self-hosting world serves plain HTTP on the local network and cannot be configured to do anything else, and refusing that outright shuts those users out of the product.

**Why the boundary sits exactly there, and why it is not the app's opinion:** the platform decides this from the address string before any connection is attempted. It permits the private literals and refuses everything else — a domain name resolving onto the same private network included. The rule the app applies is therefore a *prediction* of the platform's answer, made while the user is still looking at the address rather than delivered later as an unexplained failure. Where the app refuses, it names the things that do work: the server's address as a literal or its Bonjour name, or encryption in front of it.

**Being told is the whole of the consent.** An accepted plain address carries a warning wherever it is reviewed, naming what others on that network can read. **Rejected:** a settings toggle, and binding an address to the network it is accepted on.

**A certificate pin on an unencrypted address is refused, never ignored.** Nothing hands over a certificate, so honouring the address and quietly dropping the pin would leave a protection believed to be in force that is not.

### Apple's on-device engines are the default and the fallback

Fresh installs transcribe and speak on-device with Apple's engines. Cloud providers are opt-in. When a cloud voice fails mid-conversation, the reply is still spoken — Apple's synthesiser substitutes.

**Why:** the privacy-preserving option has to be what a user gets without making a decision, or the claim is hollow. And a spoken-reply feature that goes silent when a network call fails is worse than one that speaks in a different voice.

Every spoken reply passes through a single point in the code with exactly-once completion. That is load-bearing beyond tidiness: CarPlay must deactivate its audio session exactly once, and both a second completion and a missing one break the car.

**There is exactly one deliberate exception**, and it is worth knowing before you "fix" it: the voice *preview* in Settings does **not** fall back to Apple. A preview exists to tell the user whether the provider they just configured works. Substituting a working voice there would report a false green.

**A substitution is never allowed to be silent.** When the built-in voice stands in for a failed cloud one, it is announced on the message it affected and recorded in a small ring of recent speech outcomes held on the device, which never syncs and never leaves it. That ring is how the diagnostics screen can later tell a user why their chosen voice was not the one they heard — without it, the fallback would look like the feature simply not working.

### A transcription provider speaks for the user

The words a speech provider returns are treated as the user's own. Nothing in the client re-checks them against what was said, and on the hands-free surfaces — CarPlay, the Watch, the headless quick capture — the transcript is dispatched without a review step. In the app the transcript lands in the composer to be read and edited before it sends, but that is an editing affordance, not a security check.

**Why:** a hands-free surface exists so the user does not have to read anything, and a confirmation step deletes the feature it is attached to. More to the point, the client is not where that limit can be enforced. Conduck grants an agent no authority; it sends text. What an agent may then do — touch files, run commands, reach the network — is configured on the user's own gateway, and that is the only place a restriction actually binds. A confirmation in the client would guard a door the authority does not pass through.

The consequence follows from the decision and is stated rather than hidden: a speech provider that is hostile or compromised can put words in the user's mouth, and those words reach an agent that may hold tools. Nothing about such a transcript is malformed — ordinary prose carries it — so no amount of sanitising addresses it. On-device transcription is the default, so a user who changes nothing never takes this on, and a user who configures their own endpoint is told at that point what its output becomes.

**Rejected: requiring review before a transcript reaches a tool-capable agent.** It would have to fire on exactly the surfaces that cannot show anything — a car, a wrist mid-run, a headless capture — and it would land hardest on the user who runs their own speech endpoint precisely to keep audio off other people's servers. That user is who the design is for, and a rule that degrades their experience while leaving a hosted provider untouched has it backwards.

### Where the app lands and where a capture goes are separate settings

One preference governs what you see when the app cold-launches. A different one governs which conversation a headless quick capture appends to. They are separate preferences and are deliberately not merged.

**Why:** they answer different questions — "what do I want to look at" versus "where does this thought go" — and a user tuning one should not silently change the other.

The pointer to "the conversation a capture continues" is written only by captures that name no existing thread of their own — the Shortcut intent, the Watch, and the Mac's menu-bar quick lane, which stops stamping it the moment the user points that lane at a particular conversation. It is read by those, by a share envelope that names no target of its own, and by the landing preference when the user has asked to resume. The in-app thread and CarPlay neither write it nor consult it; they append to the conversation the user is actually in, and a surface that started consulting it would silently retarget the thread on the user's screen.

That last reader is the one place the two meet, and it reads in one direction only: a resume landing opens whatever the last headless capture pointed at, falling back to the most recently active conversation when that pointer has gone stale, while nothing about the landing preference moves the pointer.

Deep links from a notification bypass the landing preference entirely, and the Watch and CarPlay ignore it, because neither is a cold launch into a main window. On the Mac it is the menu bar that reads it, binding the quick lane at launch rather than a window.

### The gateway hop never retries by itself; speech recognition does

A failed send surfaces to the user as a tappable Try Again. Nothing re-sends in the background. Speech recognition, by contrast, does own a retry loop with a per-error budget.

**Why the two differ:** re-sending a turn spends the user's own model budget a second time, and the agent may act on the world twice. Re-sending audio costs one cheap transcription call. The asymmetry is intentional.

**On the phone, the send itself can wait, and that is not a retry.** The gateway hop there rides the system's own background transfer service, which holds an un-sent request until a route returns and re-attempts a connection outside the app. Neither behaviour can be turned off. It is one dispatch that has not left yet rather than a second send of anything, and it is the behaviour a phone should have: a turn composed in a tunnel delivers itself when the radio comes back. It also means an offline send does not fail, so there is nothing to tap. What the app owes there is an honest account of the wait, and the in-flight row gives one — it says the turn is still being sent, or that this device has no connection, and it names the gateway only once the request has actually left. The elapsed time beside those words belongs to the phase it sits in, so the number next to "answering" only ever counts time the gateway really had.

**Rejected: a deadline of the app's own that gives up on an un-sent turn.** Ending that wait would mean asking the system to cancel a transfer, which is asynchronous and not guaranteed to be honoured, so the "bound" would be a mechanism that sometimes does not fire. Worse, the system's own scheduling can legitimately delay a send past any interval the app could pick, so the deadline would also fire on turns that were about to go — manufacturing a failure out of a scheduling decision and offering a Try Again for a request that may be moments from delivery. Failing a turn is only ever allowed where non-delivery is provable; a request that has not moved yet on a device that has a route proves nothing. The bound the user has is Stop, offered throughout the wait, and it writes a failure only when the request demonstrably never left this device — and even then it names no machine at the far end, because the app has no evidence about one.

### A key that reads back as nothing has two meanings, and the app never assumes which

Secrets are stored so that they become readable after the device's first unlock. Between a restart and that unlock, a key that is present and correct reads back exactly as an empty slot does. So no lane asks the store for a key's *value* and infers from a blank answer; every lane asks for the read's *status*, and only the store reporting that the item does not exist counts as proof the user has none. A read that fails for any other reason — locked, denied, unreadable, or never attempted — is the store declining to answer, and is treated as such.

The two readings get two different sentences and two different fates. Provable absence says the key is missing and points at where to add one; that verdict is final, and a capture refused on it is discarded, because repeating it cannot succeed. An unanswered read says only that the key could not be read, invites the user to unlock and try again, and is retryable — so the capture is kept.

**Why the distinction is worth the second read:** the alternative tells a user with a perfectly good key that they never set one up, on a device where the remedy shown does nothing, and throws away what they just said in the process. Both halves are wrong, and the wrong half the user notices is the lost recording.

**A capture refused after the user has spoken is kept wherever the surface has somewhere to keep it.** In the app and on the wrist that is a preserved recording or a queued entry with a visible retry. On CarPlay there is no such place, and none is invented: that refusal loses the capture, so it earns its keep by being true and by leaving the driver able to simply say it again. Where preservation is claimed it must be real — the promise that a recording is saved is made only by the surfaces that can see the bytes landed, never by the code that merely attempted to write them.

**The wrist queue decides what is permanent by asking whether the error is retryable**, not by matching particular failures, because an entry deleted on a recoverable error takes the user's words with it. Entries are still bounded — they expire by age and by count — and the expiry notice claims no cause, since a queued capture can reach the iPhone every time and still be refused there.

**Every sentence names the device that actually failed.** A watch showing a phone's failure says so; the same words rendered on the wrist, on the paired phone's lock screen and in the car have to be unambiguous on each, so a bare "this device" is never enough where two devices are involved.

### A conversation row distinguishes working, answered, and failed

Every row in the conversation list resolves to an activity — a turn is in flight, a reply is waiting unseen, the last turn failed, or nothing is happening — rather than every row rendering alike and sort order carrying the whole story. Dispatching several agents at once is an ordinary way to use this app, and recency alone cannot say which of them came back: sort order carries *how recently* a conversation changed and never in which direction, so a thread that rises because a reply landed is otherwise indistinguishable from one that rises because the user sent something.

**Delivery and attention are independent facts, and collapsing them is the failure this design exists to prevent.** Whether a turn is still in flight asks what became of the message; whether there is something here nobody has looked at asks what the user has done. Kept apart, a fresh send never wears an older turn's failure, and a reply arriving does not by itself erase the fact that nobody has read it.

**Delivery is aggregated over the conversation's unresolved turns, never read off the last message.** Two turns can be in flight in one conversation at once — a headless wrist relay racing an in-app send — and a reply that resolves one of them says nothing about the other. Within delivery, the newest unresolved turn wins.

**A failure ends two different ways, because there are two different things to end.** Asking again ends the state itself: the failure is no longer the conversation's last activity, the row has genuinely moved on, and it stops reporting one without the user having to go back and dismiss a Retry. Opening the thread ends only the alarm: the row goes on saying the message was not sent, because it still was not, and drops the mark, because the user has now been told and does not need telling on every later glance at the list. Without the second ending a single failure sits red until the user happens to send into that thread again, which is not a thing they reliably do — the failed conversation is often exactly the one they abandon.

**Whether a failure has been seen is a separate fact from whether the thread has been looked at, and it is recorded separately because it cannot be derived.** Looking is stamped by the arrival of messages, the user's own included; failing moves no timestamp at all. So the looking marker already runs ahead of the failure it would have to acknowledge, and a design that read one from the other would retire the mark for every failure sent from the composer. Seeing is therefore recorded only where a failure is actually on screen — which is also what makes watching your own send fail count as having seen it. Asking again re-arms the mark for the same reason: what was acknowledged was one delivery attempt, and a new attempt is not the one that was acknowledged.

The Watch records a sending state like every other surface, so a turn dispatched from the wrist shows as in-flight on the phone and the Mac rather than surfacing only once its reply lands.

### A turn running on this device is a different question from a turn marked sending

A stored turn marked *sending* may have been written by another device and mirrored here. So "is a turn for this conversation running right now, on *this* device, and can I stop it?" is answered by a separate registry of live claims held in the running process, never by reading the stored status.

**That registry never writes turn state.** A write based on "I do not see a task here" would be a write based on local ignorance — the turn may be alive on the device that dispatched it, and marking it failed here would put a Retry beside a live request. Resolving a stale *sending* row stays with the launch sweeps, which is where the grace window and the live-task exclusion already live.

**A Stop button appears only for a turn this device can actually cancel.** Cancellability is declared where a turn is registered, because the registration site is the one that knows which session is behind it: a share drain and a CarPlay upload expose no cancel handle, so their turns show the wait indicator with no Stop rather than a button that calls into nothing.

**The wait indicator is re-derived rather than held by the view.** Leaving a sending thread and returning to it shows the spinner and the Stop that are still running, rather than a rebuilt view that knows nothing about them.

**On the Mac, quitting with a turn in flight asks first.** The Mac's gateway hop is a foreground request and the gateway keeps no session, so quitting mid-turn destroys the answer with nothing left anywhere to resolve or resume it. That combination is unique to the Mac, and so is the interruption.

### One chime per burst, and a banner does not outlive the thread it points at

Several agents answering at once produce several banners and one sound. The window deciding that lives in shared app-group storage rather than in memory, because on iOS each landing reply relaunches the app — a process-local timestamp would reset every time, which is precisely the failure the rule exists to kill. The window is spent only when the banner can actually be heard, so a reply presented silently in the foreground does not consume the chime the next one needs.

**Failures always chime and never spend that window.** A burst is many agents answering at once, which is a reply phenomenon; failures do not arrive in bursts, and a failure is the one thing worth hearing every time.

**Opening a conversation retires both its reply and its failure banner.** A notification that survives the thread being opened is a lie the user has to dismiss by hand, and the system removes only the notification actually tapped — which strands the other half of a pair.

The Mac raises a reply notification like every other surface. A menu-bar dot on its own reports that something happened without saying what, or where.

### What the user has already seen is a fact about the account, and it syncs

Two markers record it, deliberately kept as separate facts: when a conversation was last looked at, and which delivery attempt's failure the account has already been shown. Both are fields on the conversation itself, so they travel the way the conversations do. Reading a thread on the iPad clears its unread mark on the phone, the Mac and the wrist, and a failure dismissed on any one of them is dismissed on all.

**The price is stated rather than avoided.** The production schema is additive-only and permanent: these fields can never be renamed or withdrawn, and must be carried for as long as the app exists. Four devices showing four different answers about one account is not a rough edge — it is the app contradicting itself in front of the user, on the one question a mark exists to answer. That is worth the permanence.

**Why fields rather than a marker record of its own.** The sync layer does not treat an identifier attribute as unique, so two devices that each create a marker for the same conversation export two records that sit beside each other forever with nothing able to merge them — a hazard this codebase already carries a scar from elsewhere. Updating a field on a record that was only ever created once sidesteps it.

**Why not the key-value store.** It caps the number of keys well below the conversation count a real user accumulates, so markers would have to be packed into shared blobs, reintroducing read-modify-write across devices with no compare-and-swap to make it safe. Two findings decide it. Withdrawing an acknowledgement cannot be expressed in a blob merged by taking the newest of each entry: removing an entry is undone by the next device that merges its own copy back. And at a realistic conversation count the blobs consume a large fraction of a budget shared with everything else that store holds; an overflow arrives as a change the app discards by design, so the silent casualty would be gateway configuration sync. The result would be more permanent format commitments than the fields cost, several times the code, and a cloud-side roster of every conversation identifier that ever existed, outliving both the conversations and the app.

### Acknowledgement names a delivery attempt, not a moment

This is the correctness idea the design turns on, and it replaces the obvious one. Asking again does not move the failed turn's timestamp, so under last-writer-wins "seen" and "seen the previous attempt" are indistinguishable by time, and there are interleavings that end with a message which never sent showing no mark at all, permanently. Instead a fresh identity is stamped by every write that begins a delivery attempt, declares one failed, or republishes a failed turn's record for any other reason. Whole records converge by last writer rather than field by field, so a device rejoining late with an old copy would otherwise republish an identity the account has already acknowledged, and a failure nobody was shown would go quiet for good. Acknowledging stores the identity it was shown and the comparison is equality: a failure carrying no identity is never acknowledged, which leaves it marked, which is the safe direction. Nothing ever clears an acknowledgement — the next write stamps a new identity and the stored one stops matching.

**The wrist reads the newest message's role off the conversation row.** Whether a mark is owed depends on whether the newest message is a reply, which the phone and the Mac answer with a lazy per-row lookup the wrist refuses to pay for. So the conversation carries a small versioned description of its own newest message, trusted only on a complete match — down to the tail's stamp being exactly the conversation's activity stamp rather than merely close to it, because a build that appends a message without rewriting the description leaves a well-formed value describing the wrong tail. When it cannot be trusted the phone and the Mac fall back to the lookup they were doing anyway and quietly rewrite it; the wrist shows no mark rather than guessing, because a guess can hide a real reply or invent one on the user's own message.

### One account-wide cutover keeps imported history from arriving unread

Without it, every conversation older than its own marker reads as unread, which on a first launch is all of them. It is a single value in the key-value store, and devices reconcile it by taking the *earliest* — the earliest moment any device could have been recording. A per-device stamp folded into the records would mean "I was not here before this date" rather than "the account read everything before this date", so a newly added device would mark months of genuinely unread replies as read everywhere.

**The cutover covers the looking marker and nothing else, and that asymmetry is why the two stay separate facts.** The looking marker is allowed to assume that activity from before there was anybody here to read it is not news. The failure mark takes no such optimism — no cutover reaches it, and nothing recorded before this design counts as an acknowledgement — because the two directions do not cost the same. An unacknowledged failure over-reports and costs one tap. An acknowledged one goes silent, and a mark that never appears is a message the user never learns did not send.

**The Watch is a full participant.** It reads both markers and writes them: a thread read on the wrist is read everywhere, and a failure dismissed there is dismissed everywhere. Because that write decides for devices the user is not holding, the wrist gates it harder than any other surface — an active scene is not enough, since the ambient dim keeps a scene active with the wrist down.

### Three convergence limits are accepted rather than engineered around

They are written down on the same principle as the capture race noted further below: the next person to find one should find a decision here, not a bug.

**A view time can briefly regress.** The last-looked-at field is last-writer-wins, not an account-wide maximum, so two devices viewing the same conversation against unreconciled copies can let a delayed write carrying the earlier time win for a while and make an unread mark reappear. It is cosmetic and in the safe direction — it cannot hide a newer reply, loses nothing, and is repaired the next time the conversation is viewed. Converging properly would need one contribution record per conversation per device, a lifecycle to manage them, and a second whole-store aggregate on the conversation-list path.

**A mark can re-arm on its own.** A late acknowledgement naming an older attempt can overwrite the one for a newer attempt, and a device rejoining late to declare or enrich the same failure stamps it anew, leaving the standing acknowledgement naming nothing. Either way the mark returns without the user having asked again, at the cost of one more look at a thread they have seen. Sparing them that would mean letting a stale copy keep the acknowledged identity, which ends with a send that never happened wearing no mark at all.

**One exposure lasts only the rollout window.** A device still running a build with no notion of delivery-attempt identity can perform an entire retry without touching the field, so the turn keeps the identity the account already acknowledged; when that attempt fails again the acknowledgement still matches and the re-failure is silent on every updated device — the one case where this design degrades to silence rather than to over-reporting. No schema closes it: the device that begins the new attempt runs none of this code, so any additional field would equally fail to advance, and afterwards the record is indistinguishable from one that was never retried. It ends when the last device updates, and a retry from an updated device restores the mark immediately.

### Everything persistent goes through one seam

Three stores hold state: shared app-group defaults, the iCloud key-value store, and the keychain. Nothing in the app reaches any of them directly. They are behind protocols, with a live implementation for the app and in-memory doubles for tests.

**Why, concretely:** two of those three stores *sync*. A test that writes a gateway URL without the seam does not write to a sandbox — it writes to the developer's real iCloud account and the value appears on their own phone and watch minutes later. The seam is the only thing standing between the test suite and the maintainer's devices, and it holds only while every call site respects it, so a script checks it on every CI run.

Two carve-outs are deliberate and the script encodes both. Plain device-local defaults are a legitimate separate store and are outside the seam. And the App-Group *container directory* is outside it too — opening that folder still reaches the real shared container — so the handful of files that do are listed by name in the script, which means a new one fails the build instead of joining them quietly.

### Two of those stores are not equally private, and the difference decides what goes where

The **keychain**, marked synchronizable, is end-to-end encrypted between the user's own devices and opaque to Apple and to us. Secrets live there, and only there.

The **iCloud key-value store** is encrypted by Apple with Apple's keys. It is not developer-blind in the same sense. Configuration lives there — addresses, preferences, identifiers — and credentials never do.

Treating the two as interchangeable is the single most consequential mistake available in this area, and it is the premise behind the URL-credentials ban above.

### The published repository is the whole application

The official build is this source plus private brand artwork, signing, and Apple's per-team CarPlay entitlement. No functional code is held back — all the CarPlay code ships here; it is the entitlement that does not. Community builds are that same app minus CarPlay, under a neutral identity with placeholder art. A clone builds and runs on the simulator with no configuration at all, though an unsigned simulator build cannot write the keychain, so actually pointing it at a gateway needs either a signing identity or the QA-mode launch arguments.

**Why:** a partial open-sourcing invites the question of what is missing, and the honest answer has to be "nothing that does anything."

### The quick-capture trigger stays out of the app

On iPhone, the Action Button route runs headless: it records and sends without ever bringing Conduck to the foreground, so the user is not navigated away from whatever they were doing.

**Rejected:** foregrounding the app to record and letting the user swipe back while recording continues in the background. It works, and it throws away the entire point of the feature. The app does not declare background audio, and this is why.

The headless route has real ceilings, surfaced to the user rather than hidden: recording stops if the screen locks or dims, low-power mode cuts it short, and there is no voice-activity detection, so stopping is manual. The in-app composer exists for long or reliability-critical captures.

### Forgetting a gateway erases the credentials and keeps the colour tag

Conversation rows carry a small coloured badge naming the gateway that created them, and rows only carry it once a list could show two different gateways — one gateway means a badge that says nothing. Crucially the count spans the configured gateways together with the gateways the *conversations* were created with, not the configured set alone: a conversation stays bound to its gateway for life, and forgetting that gateway does not merge it with the others. Counting only live gateways would blank every badge the moment a user is down to one, which is exactly when a mixed history is hardest to read.

Forgetting a gateway destroys its address, token, certificate pin and file-transfer setup. What survives is the monogram and a palette colour, so the conversations it created keep the tag that told them apart. The name does not survive: a forgotten gateway reads under the same generic label as one whose roster entry is missing for any other reason, because the badge is what tells conversations apart and a name invented at the moment of forgetting would only put a placeholder everywhere the interface expects a real one. This makes custom gateways behave like the built-in ones, which keep their badge for free because their letters and colours are compiled in.

**Rejected:** erasing the badge with the credentials. It only ever applied to custom gateways, so the same user action gave opposite outcomes depending on which kind you forgot, and half an archive went permanently blank. **Also rejected:** a neutral grey chip for anything forgotten, which cannot tell two forgotten gateways apart and so does not solve the problem it exists for.

These records never leave the device — they are the one part of the gateway roster that is deliberately not synced. A monogram can carry a company or a person's name and the timestamp discloses when, so publishing them would carry both into whatever iCloud account the device is signed into next, and a restored backup would resurrect records the user believed erased. Other devices stay consistent by *deriving* the same record from something they already receive — the gateway disappearing from the synced roster — rather than by copying the record itself. Retention is bounded by `Constants.maxRetiredGatewayBadges`, oldest dropped first, so a conversation old enough can still lose its badge.

### Forgetting your last gateway has to reach the Watch

The Watch holds its own copy of every gateway's address and token, and forgetting is a local act on the phone: the token stays valid at the server. So a forget that never reaches the wrist leaves a working route to a gateway the user believes they disconnected — surviving reboots, because the Watch rebuilds that state from durable storage at launch. The phone therefore sends an explicit teardown instruction.

The hard part is not sending it, it is knowing when not to. "No gateway is configured" is also what a restored device reads before iCloud finishes downloading, what a locked keychain reads before its first unlock, and what a device with an unsynced roster reads — and the phone broadcasts to the Watch without waiting for any of those to settle. Inferring a teardown from that reading would destroy the credentials of a Watch that is working perfectly. So the teardown is authorised by a *recorded user action* and by nothing else, and it travels as its own explicit flag rather than as an empty list of gateways — an empty list is also what a Watch too old to parse a future message sees, and a compatibility gap must never read as an instruction to erase.

**Residual, accepted:** a forget performed on iPad or Mac does not reach the wrist, because the paired iPhone is the only courier and it never witnessed the intent.

---

## What one turn does

Trigger, record, transcribe, assemble, send, receive, store, speak. Every surface runs that same sequence; what differs is who triggers it and who owns the microphone.

**The store is written before the gateway hop, everywhere.** The user's turn is durably saved *before* the request to the gateway is assembled, on every surface, so nothing the user said is lost to a process kill. The history assembler then drops that trailing stored copy so the same text is not sent twice — each half looks like a bug without the other. (Attachment uploads to the user's own file server are the one thing that runs *earlier* than the store write, in both the composer and the share drain, which is why those paths have a distinct "failed before there was anything to retry" state.)

**Once a turn exists, the store is the only recovery surface.** Retry replays from the conversation, never from the queue or envelope the turn arrived in. That is precisely what makes at-most-once dispatch safe: the share drainer can mark a turn failed, notify, and delete its envelope with no risk of a second send, because the Retry the user taps reads the database. A capture that failed *before* any turn existed — speech recognition never succeeded — is the exception, and is the reason the preserved-audio path above exists at all.

The properties that hold across every surface:

- **A turn is recorded once.** Writing a message is idempotent on a caller-supplied identifier, so re-draining the same share-sheet item after a crash cannot produce a second copy of what the user said.
- **A turn is dispatched at most once — never more, possibly zero.** If the app was killed with a send in flight, it asks the background session whether that task is still alive. If it is, it is left alone. If it is not, the turn is failed and the user is told; it is never resent automatically. A dropped turn the user can see is recoverable. A silent duplicate is not, and it spends their money twice.
- **A wrist capture triggers at most one transcription and one onward hop.** Taking a queued item is a single remove-and-return that doubles as the token permitting exactly one onward hop, so a live success, a late reconciliation and a queue drain cannot each fire for the same capture. The *reply* deliberately may cross more than once: a repeat request carrying the same identity is answered from a cache of the previous verdict rather than being re-transcribed or dropped.
- **A reply is spoken exactly once.** Each platform has one speak engine behind a shared protocol — the phone and Mac share theirs, the Watch has its own — and everything that speaks goes through the engine for its platform rather than driving the synthesiser directly.
- **A reply lands atomically on the main converse path.** Inserting the agent's message and marking the user's turn delivered is one transaction, and the "turn complete" signal is posted only after the reply has actually persisted — never for a reply that is not there. Paths that arrive without a user-message identity to flip, and the Watch's own append, fall back to two writes.
- **A turn does not sit in "sending" once its transfer has ended.** Three independent mechanisms cover every turn that reaches that point, because no single one survives every way a process can die. The deliberate exception is the phone's gateway hop: a request the system's background transfer service is still holding un-sent is left alive rather than swept, because failing it would declare a non-delivery the client cannot prove. That is a boundary, not an oversight — what protects such a turn is the live-transfer set the sweep is handed, never any duration, and the user's way out of the wait is Stop.
- **A gateway's own words never reach the screen.** An HTTP status the app does not specialise surfaces as a bare code. It is deliberately not routed through the generic case that would render a server-supplied message, because that case is also where relayed text lands — and rendering it would open a path for a gateway to put its own words in front of the user.
- **A failure at the image step degrades the turn instead of failing it.** If an attached image cannot be processed, the question is still asked, as text. The ask never dies because of a picture.

---

## Where the surfaces differ

Assuming the surfaces behave alike is the most common way to get this wrong. The README lists what each one can trigger; what follows is only what that list cannot tell you.

**iOS and macOS have two entirely separate app entry points that share no launch code.** Every piece of startup wiring exists twice and must be added twice. By the codebase's own account this is its most repeated maintenance hazard — if you add something at launch, check whether you added it once or twice.

**macOS has no background sessions.** A turn stranded by quitting mid-send has no delegate left to mark it failed — which is why quitting with a turn in flight asks for confirmation there and on no other surface. Both platforms sweep for stranded turns at launch and again after a delay — the second pass exists because a quick relaunch finds the turn not yet old enough to sweep — but the Mac has no live-task registry to exclude in-flight work from that sweep, which iOS does. The Mac app also deliberately outlives its windows (closing the last one must not quit, or the menu-bar item disappears) and controls its Dock icon at runtime rather than declaring it in the bundle, because the system ties the Dock icon and the application menu to the same switch and the preference has to be togglable live.

**The Watch is not a remote control for the phone.** It records locally, and where the clip goes depends on the provider: it reaches the phone only when transcription is on-device or a custom endpoint, a cloud speech provider uploads straight from the wrist, and the gateway hop always goes wrist-to-gateway directly. It has text entry but no configuration UI — setup is taught on the phone.

**CarPlay pre-warms the speech provider and its key rather than reading them mid-turn.** They sit in a cache refreshed at launch and on every settings change, filled in one atomic step so a turn can never see a half-updated pairing of provider and key. This is empirical: keychain reads from the CarPlay scene caused intermittent stalls while Bluetooth negotiated the hands-free route. Note the limit — the *gateway* snapshot is not pre-warmed the same way and is still resolved during the turn.

**CarPlay may show a conversation's title and date, and none of its text.** Apple's rules for the voice-based-conversation entitlement forbid putting message content on a car screen: browsing to pick up a thread is allowed, showing any of what is in it is not. Voice is how you resume a conversation there. That constraint is also why the picker identifies which gateway a thread belongs to with a colour rather than words. CarPlay is absent from community builds altogether — the entitlement is granted by Apple per developer team and cannot be shipped in source.

**The share extensions decode nothing** — they copy bytes and exit, and nothing that decodes a payload may be added to them. The system gives an extension a small fraction of the app's memory, and decoding a single modern photo exceeds it; the copy also has to happen inside the system's own callback, because the file it hands over stops existing when that callback returns. The one thing an extension computes is the small document it writes for a shared web page, and even that is assembled from text the browser extracted inside the page itself, running a script the extension ships but never executes — what comes back is treated as untrusted input and re-validated and re-clamped before anything is written. Everything else happens in the main app when it drains the shared inbox, which is why a shared item's reply arrives later rather than at once.

**The share extension activates for almost everything**, rather than filtering to types the app understands. That is a product boundary, not laziness: Conduck forwards to the user's own gateway and cannot know what that gateway will do with a payload. Anything unrecognised is routed to that gateway's file server; if the bound gateway has none — the hosted lane never does — the whole item fails visibly, with a notification. Broad activation is safe because every drop is surfaced, not because every payload has a route.

Onboarding is one linear flow shared by the phone, tablet and Mac, plus a separate one-time notice on the Watch that configures nothing. CarPlay has none and says so out loud — it cannot configure anything and tells the driver to set it up on the phone. The share extensions have none either, but they deliberately do *not* dead-end: with nothing configured they still offer to send into a new conversation on the default gateway, because a share that refuses is a share the user has to redo somewhere else.

Typed turns skip speech recognition entirely, so they need no voice provider at all — though the default speech engine is Apple's on-device one, which needs no key either.

---

## Data, secrets, and what leaves the device

**Conversations** live in a local database, mirrored into the user's own private iCloud database. Apple encrypts it; we cannot read it; there is no copy anywhere else. One piece of conversation data travels between the user's own devices outside that mirror on its own account: the description of a file the phone has just found for a reply, handed to the paired Watch directly so the row does not wait on sync. It carries no bytes and no credential, it is held on the wrist only until the mirrored row arrives, and it exists because the wrist can never discover such a file for itself. The phone-to-watch relay carries more than that — a wrist capture's recording crosses it whenever the phone is the one transcribing, the transcript or the failure code comes back over it, and so do the secrets named below. The database sits in the shared app-group container rather than the app's own sandbox, because the headless Shortcut runs in a *different process* and has to read and write the same file. Sync is off on the Simulator — the mirroring container refuses to start without a signed-in account and a registered container — so simulator runs are local-only by design, not by accident.

**What the user has already read** travels with the conversations rather than staying on the device that did the reading. The record carries when a thread was last looked at and which failed delivery attempt has already been shown, inside the same encrypted mirror as the messages themselves; one account-scoped value in the key-value store — the moment before which nothing counts as unread — is the only part of it that sits outside that mirror.

**Secrets.** On iPhone, iPad and Mac every API key and gateway token lives in the keychain marked synchronizable, so it moves between the user's own devices end-to-end encrypted. **The Watch is the exception:** its copies are written non-synchronizable and arrive over the phone-to-watch relay rather than through iCloud Keychain, because the wrist cannot be the place a user types a key.

Over the network a secret is sent only to the service it authenticates, and it is never logged and never appears in an error message. Two movements are not network sends and are easy to forget: the phone hands the active speech key and gateway token to the paired Watch over the device-to-device relay, and the pairing exporter can render a gateway token back into a setup code the user shows to another of their devices.

Note a platform trap: a synchronizable keychain item is a genuinely *different* item from a non-synchronizable one with the same name, so an operation that omits the flag silently finds nothing rather than failing.

**Identity** is a locally generated identifier in the keychain. There are no accounts.

**Audio** never enters a conversation and never syncs. There is no audio entity in the database at all — though note that is a property of the code rather than of the schema, since the attachment entity holds arbitrary bytes and a free-text media type.

It is *not* memory-only. Transcription and background upload both need a file on disk, so a recording is written to scratch storage and deleted when the operation ends, on success and failure alike, with a sweeper at launch for anything a crash stranded. Two paths deliberately hold a recording longer, both inside the app's own container and both bounded:

- **A transcription that failed** keeps its recording so the user can retry instead of repeating themselves — this arms on the speech-to-text hop, not the gateway hop, which is why a failed *send* has a turn in the store to retry from while a failed *transcription* has only the audio. Bounded by `PendingRetryMetadata.isExpired` and purged both lazily on read and eagerly at launch. The headless Shortcut route saves it *proactively*, before it knows whether anything failed — because when the OS kills that process mid-transcription there is no error path left to run, and a clip saved in advance is the user's only way back.
- **A Watch capture** is written to the Watch's own container *before* the first delivery attempt, so process death cannot strand a clip the user has already spoken. Bounded by `AppleRelayPendingQueue.maxEntryCount` and `maxEntryAge`, deleted the moment the phone claims it, with an orphan sweep in both directions at startup.

Two smaller rules about audio on disk, both easy to undo by accident:

- **Scratch files must carry a filename prefix the sweeper recognises.** A file written without one is not merely unswept, it is unreclaimable — no sweep rule broad enough to catch it could avoid deleting other frameworks' files from the same shared directory. That mistake has been made three separate times, which is why a test now scans for it.
- **Capture filenames are random, not timestamped, and the sweeper logs nothing at all.** The names contain nothing sensitive, but a directory listing of timestamps would disclose when the user was recording. This is exactly the kind of rule a well-meant "let's add some logging here" removes.

**Outbound traffic** goes to Apple — the private iCloud mirror, the key-value store, and Apple's own on-device speech-model download — and otherwise to exactly three destinations, all chosen and paid for by the user: their speech provider, the AI they configured, and, where a gateway has one, its file server. Attachments sent to a file server keep their original metadata; the copy sent inline to the model is downsized with metadata stripped.

There is one non-obvious threat to that guarantee. The audio package brings in a model-hub client and a machine-learning runtime as transitive dependencies, so code capable of fetching a model from a third-party host **is compiled into the shipped binary**. Nothing calls it: the voice-activity model is loaded from the app bundle, and a missing bundle resource fails the CarPlay session closed rather than reaching out to fetch one. The guarantee here is a property of the call graph, not of the dependency list — which is why the avoidance is written down instead of assumed, and why "make it degrade gracefully" is the wrong instinct at that spot. Degrading gracefully would mean a silent third-party request originating from someone's car.

---

## Usage measurement, and what the ledger never holds

Conduck keeps a private ledger of gateway attempts — one record for each time a turn is dispatched to the user's AI — alongside the conversations, in the same local database and the same private iCloud mirror. It exists so the app can tell the user how their own setup is behaving: how often turns land, how long a complete answer takes, and whatever their gateway is willing to say about tokens. It changes nothing about the no-server rule. The measurement is as local as the conversation it describes, and there is nowhere for it to go.

**The ledger is content-free, and that is a release-blocking constraint rather than a preference.** A record carries identifiers, timings, an outcome, a stable local error code, and the handful of things the gateway itself reported. It never carries what was said, where it was sent, or what authenticated it — no prompt or reply text, no address or host, no token, no gateway name, no provider error string, no HTTP status. The gateway a record belongs to is stored as the same opaque reference a conversation binds to, and the name a person reads is resolved when a screen is drawn rather than written down. The few strings that do arrive from the wire are bounded by the same limit the app already applies to a model name and are rejected outright when they contain control or bidirectional-control characters, because a ledger is read back into an interface and text from someone else's server is untrusted input.

**Why:** "there is nothing to disclose because there is no server" holds only while what is stored could not embarrass the user if it were disclosed anyway. Usage data is precisely where that discipline erodes, one convenient field at a time — a host here, a status code there, each defensible alone.

**Capture fails open, so a recorded attempt is not the same thing as a dispatch.** Every write on this path is best-effort: if the ledger cannot be written, the turn goes out anyway and nothing is surfaced to the user. Measurement may never reduce the availability of the send path. The consequence has to be carried through to what the user reads — these are *recorded* attempts, and calling them totals would assert a completeness the design deliberately declines to provide.

**An attempt's final state is derived when it is read, never guessed when it is written.** Only what the app actually observed is stored: in flight at dispatch, then succeeded, failed or cancelled when the transfer ends. A record still reading in flight means the ending was never witnessed, usually because the process was killed — and reading it back separates an attempt young enough to still be running from one that cannot be, using the process's own live-transfer set rather than any stored flag, and the same grace the stranded-turn sweep uses. Neither reading is ever written back. A start time far enough in the future is unresolvable rather than fresh, because the clock on the device that wrote it is not one this device controls.

**Attempts outlive the conversations they describe, and clearing usage history is the only thing that removes them.** Deleting a conversation deletes its content and leaves its content-free records standing, so a trend does not develop a hole every time someone tidies up their threads. Where that gets disclosed is a decision rather than an oversight, because a user who is told deletion is total and finds otherwise has been misled about the one thing this app sells. It is said in the two places the claim can actually be tested: beside the retained figures themselves, which state that they include conversations the user has since deleted, and in the confirmation for erasing everything, which is the one deletion that does take the records with it. Deleting a single conversation is deliberately not made to argue back — a confirmation on an ordinary tidy-up buys friction rather than understanding, and the person who needs the disclosure is the person reading the numbers. Retention decoupling is temporal only — the records stay in the same private store and the same private mirror, so nothing about the disclosure boundary moves. A record whose conversation is absent stays fully counted: absence can mean deleted, not yet imported, or momentarily unavailable, and a delete driven by mere absence is a delete racing sync.

**Clearing is account-wide, and it works through a synced cutoff rather than a synced deletion.** The user's clear advances a shared cutoff date first, so every device excludes everything at or before it from every read the moment the setting arrives, and the actual row deletion follows locally on each device as it loads. That ordering is what makes the guarantee hold for a device that was offline while the clear happened: rows it minted before the cutoff are excluded and then purged when it comes back, so no amount of late syncing can resurrect cleared history. The cutoff only ever moves forward — merging two devices' values takes the later one — because a device carrying a stale value must never un-clear what another device cleared. Erasing everything advances the cutoff too, for exactly the same reason. Deletion itself is deliberately object-at-a-time in bounded passes rather than a single bulk request, since the platform does not promise bulk deletes compose with the private mirror, and the pass is written to be safely resumable so an interrupted clear finishes on the next attempt instead of leaving a half-cleared ledger.

**A reply that arrives for a conversation that is not here still settles its attempt, and is otherwise discarded.** The observed ending is written onto the record before the store's not-found verdict propagates, so the attempt reaches a terminal state; the reply text, and every consequence of a reply — storage, notification, speech, success in the interface — is dropped. Without this, keeping records past their conversations would silently manufacture attempts that read as never having finished.

**A record also carries the shape of what it carried, in counts rather than content.** The device class stamped on a record is the device that executed *that* dispatch, so a retry from another device is attributed to the device that retried rather than the one that first tried. The current-turn image count is how many inline images rode the request for the turn being sent, counted after final assembly rather than at the picker, and the prior-turn image count is how many older images rode along with it after replay policy and trimming had their say — which is the only honest way to show a user why an image-carrying thread costs what it does. The two text-file counts mirror them, and count only blocks actually spliced into the request: a failed extraction, an unavailable notice, or a file the gateway holds by reference is not an inline block and must not be counted as one. All four are counts, never names, sizes or contents, and a record written before they existed reads as unmeasured rather than as zero — which is why coverage is shown beside every figure derived from them.

**Every dispatching surface writes to the ledger, or the history is permanently skewed.** A build that measured some routes and not others would not under-report evenly; it would make whichever surfaces were instrumented look like the whole of how the app is used, and no later release can repair a period recorded that way. Adding a new way to dispatch a turn means instrumenting it in the same change.

**Two properties of the send path hold because of this ledger, and they matter well beyond it.** The agent's reply is written under an identifier minted at dispatch, so the same reply landing twice — a duplicate callback, or a late one after a relaunch — cannot produce a second copy of it. And a cancellation names the exact turn being cancelled rather than the conversation holding it, so stopping one turn leaves a sibling running beside it alone.

**What the dashboard can describe is what the ledger retains, and it says so with one date.** Measurement begins at the earliest retained record, full stop — there is no second date to reconcile against, because what is kept does not depend on which conversations still exist. Per-field coverage is still surfaced everywhere a figure depends on something optional: a gateway that reports no token usage is the ordinary case, and it must never read as a gateway reporting none used.

**Which device a record is attributed to is derived, in a fixed order, and never guessed twice.** The surface a dispatch originated from wins where it is decisive — a car session and a wrist capture identify themselves — because the underlying hardware would otherwise report the phone that carried the request. Failing that the device class stamped on the record is used, and failing that the source device recorded on the turn it belongs to, which is what lets records written before the stamp existed still land in a bucket. Anything that resolves to none of the known devices is shown as not recorded rather than folded into a plausible-looking one.

**A ranking may only ever use one basis, and must name it.** Gateway-reported totals and totals calculated from reported components are different measurements, and a list that silently mixes them ranks threads against each other on incomparable numbers. So a ranking picks whichever basis some thread in range actually supports, applies it to every row, states in the section itself which one it used, and says plainly that threads without that measurement are not ranked. A thread ranked at all is ranked honestly or not shown.

**A thread whose conversation is not present is labelled unavailable, not deleted.** The ledger cannot distinguish a deletion from an import that has not arrived yet or a store that is momentarily unreadable, so the copy claims only what is known — the row is there, the thread is not reachable from it right now — and the row becomes navigable on its own if the conversation later appears. No tombstone is written to make absence look decisive.

**Rejected:** advertising an accounting capability in the pairing payload, or discovering one from the model list. A capability recorded at pairing is a snapshot of behaviour that can change the next day without any pairing event, and the absence of usage in a reply already means exactly what a negative advertisement would have meant. Nothing about parsing a reply may ever be gated on the gateway having announced it first. **Also rejected:** storing any cost figure. There is no truthful source for one — the app does not hold the user's provider billing relationship — and a number that looks like money is believed in a way a token count is not.

---

## Things that look wrong and are not

Each of these has been "fixed" or nearly fixed by someone who did not know why it was that way.

**The conversation store holds only the turns made through Conduck.** The same agent's conversations from its other channels, and its own server-side memory, are not here and cannot be. That is a property of running a thin client against somebody else's agent, not a sync bug, and there is no client-side fix.

**A turn carrying an image is dramatically slower than a text turn** on a self-hosted gateway, and the cost is on the gateway's side of the wire. Client-side work will not move it. The levers that exist are how much image history is re-sent, and what the app shows the user while they wait.

**A wrist capture can fail on the phone's dead connection while the Watch has perfectly good Wi-Fi.** When the paired phone is switched on and in Bluetooth range but has no working network, watchOS routes the Watch's own outbound requests through it anyway. No public API selects the interface, and the Watch cannot tell whether the phone's link is alive. Error copy on the wrist has to allow for this; code cannot route around it.

**A stuck "sending" turn with an agent reply already stored beneath it is marked delivered, not failed.** The reply is always persisted before the turn's state is updated, so a reply sitting underneath a still-sending turn is proof the send succeeded and only the bookkeeping was lost. Marking it failed would put a Retry button under an answer the user can already read.

**The Watch's key-value-store observer deliberately does not check whether iCloud is available first**, even though every other surface does. The availability token is always nil on watchOS, so adding that check for consistency would not tighten anything — it would switch the observer off.

**There is no Sync Now control**, and its absence is deliberate. The platform offers no way to force a fetch or an export, so such a button could only pretend. Sync state is surfaced instead of commanded, and the only visible sync warning fires on states the user can actually act on — no account, restricted, out of space — never on the transient ones.

**Choosing a different gateway inside a CarPlay session does not change the app's default.** It sets an override that lives and dies with that connection. The obvious simplification — calling the same setter the settings screen uses — would let a change made while driving silently re-point the phone, the iPad and the Mac.

**A turn whose earlier images can no longer be resolved must say so rather than quietly becoming text.** Either it points the agent at the file on the gateway's disk, or it tells the agent plainly that it can no longer see those images. Silently dropping them produces an agent confidently answering about a picture it was never shown, which is worse than an honest gap.

---

## What is frozen, and what only looks frozen

Some strings can never change, because changing them orphans data already on people's devices. They are not interesting, and that is exactly why they get broken — they look like tidy-up opportunities.

- **Reverse-DNS identifiers** — bundle identifiers, the app group, the keychain group, the iCloud container. Apple treats these as set-once. They are parameterised through the build configuration rather than written into source.
- **Secret-store account suffixes.** A speech provider's registry identifier *is* the key its secret is stored under. Renaming the identifier orphans the user's key.
- **Serialized enum values.** Anything written into the conversation store or the synced key-value store must still decode on a device running an older build.
- **The Watch relay wire strings**, which exist as literal duplicates on both sides because neither target can see the other's symbols. A rename on one side breaks the relay at runtime with no compile error.
- **Error code numbers**, which cross the Watch relay as bare integers and are reconstructed on the far side. A silent renumber turns a real failure into a blank or wrong message.
- **The order in which a URL is rejected.** Callers map the rejection reasons onto their own error types and split them differently, so the split only stays meaningful while the precedence holds.
- **Secrets crossing to the Watch are optionals whose key is omitted when absent — never an empty string.** An empty string decodes on the far side as a value that is present, which is exactly how a missing credential stops reading as *not configured*. The fail-closed rule above holds only while this does.
- **Reworded user-facing copy takes a new string key.** Once a key exists in the string catalogue, the catalogue's value wins and the literal in the source is ignored — so editing the literal alone ships the old wording, silently, with a clean diff and a green build.
- **No App Intent title or description may name a platform.** Writing "iPhone" or "Mac" into one gets the build rejected at submission review, and nothing local catches it first.

**Part of this app's wire surface is also a contract with a second repository, and neither side may move alone.** `conduck-connect` — the companion setup tool, its own public repository — writes the pairing payload this app imports, and grades third-party gateways against the request and reply shapes this app accepts. The payload format and its version tag, the app's gateway-URL normalisation, and those acceptance rules are therefore shared, not internal. Normalisation is the sharpest case: that repository keeps a parity fixture list transcribed case by case from this app's own gateway-validation tests, and nothing on this side knows it exists. Adding an assertion there is free; changing one that is already there silently breaks a tool users have already downloaded. Its contributing guide names the same surfaces from the other end — change one, open an issue on both.

**What is *not* frozen, despite looking settled:** the duplicated relay wire constants are acknowledged debt, not a decision. The guard that watches them says so in its own header, names extracting a shared module as the intended fix, and says the guard should be retired when that happens. A contributor proposing a shared module is not re-litigating anything.

One accepted imperfection, documented rather than fixed: a share drain and a near-simultaneous quick capture can race and both create a conversation. Swift actors are re-entrant across suspension points, so routing through a shared manager does not serialise it, and the worst case is two near-identical threads rather than lost data. That was judged not worth a lock. It is written here so the next person finds a decision instead of a bug.

---

## How the rules are enforced

Several rules above are not upheld by review — they are upheld by a test that reads the source and fails the build. Each exists because review demonstrably failed to catch the mistake, sometimes repeatedly: the guard on error presentation went in after five review rounds found the same defect. The guards cover the storage seam, the folder map, licence headers, error codes and their presentation, logging, every site that renders an agent reply, the Watch relay wire, temp-file naming, and the legal text shown in the app. Each names its own subject in its header; `CONTRIBUTING.md` is where a contributor learns to run them.

Two conventions those guards follow, both deliberate:

- **They never pin a count of call sites.** A magic number makes every unrelated change fail with a mismatch, and teaches contributors to bump the number instead of reading the rule. The checks are structural instead.
- **Where a guard landed before every existing violation was fixed, its accepted-debt list may only ever shrink** — a companion test fails if an entry is fixed but left behind, so the list cannot quietly go stale. Permanent by-design exemptions are kept in a separate list from temporary debt.

Three further rules about verification are worth stating because none is discoverable from the code:

- **The full iOS-simulator run is the authoritative signal.** Running the whole suite against macOS intermittently kills the test host inside iCloud container setup, and it takes a different suite down each time. That is a consequence of hosting an entitled app under an unsigned test process, not a defect in whichever suite happened to die.
- **Any scan over an agent's reply text must be linear.** This is a standing rule for new code, not a description of the scanners that exist — reply text is unbounded and shaped by something outside our control, so a backtracking pattern over it freezes the interface on a reply that is already stored and will be re-rendered on every launch. The mistake has recurred four times.
- **A check that is merely absent reads as a check that passed.** Where a suite cannot run — the certificate-pin tests need a signing identity a hosted runner may not have — the run summary says so rather than staying silent.

### What nothing checks

Being honest about the gaps is more useful than implying coverage that does not exist.

- **There is no UI-test target.** Both bundles are unit tests, and verifying the interface is deliberately a human step.
- **Nothing reads the Xcode project file or the schemes**, so the two ways this build topology fails silently go uncaught: a scheme whose test action drifted off the testing configuration, and a watchOS test file never added to its hand-maintained target — the suite passes, having quietly skipped it. See the footgun note in [`project-structure.md`](project-structure.md).
- **Nothing verifies the checked-in placeholder artwork still matches the asset catalogues it mirrors.** The generator only regenerates; to check by hand, re-run it and read the diff.
- **The logging guard is honest about its own limits.** It matches transcript and reply text only under obvious variable names, because matching generic ones would fire on dozens of harmless counters, and a guard that cries wolf gets deleted. The reply-text half of the never-log rule remains a matter of judgement.
- Anything needing a signed build on real hardware, a paired Watch, a car, or a live gateway is checked by hand.

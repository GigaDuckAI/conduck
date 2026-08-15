// SPDX-License-Identifier: Apache-2.0

// Conduck
// OutputHeldBackCopy.swift
//
// WHICH SENTENCE the thread's held-back row is allowed to say about one census
// on one message, as a value rather than as a branch inside a `View`.
//
// WHY IT IS NOT A `private func` ON THE ROW. The row's whole reason for existing
// is that two shipped strings were not provable from what the code had observed,
// and a decision buried in a `@ViewBuilder` cannot be asserted by anything: a
// test can pin the WORDS of a string, but not that the right string was chosen
// for the state that produced it. Both halves matter here, and the second is the
// half that was wrong. Lifting the choice out gives it a name, a return value and
// a test; the view keeps only the typography.
//
// THE RULE EVERY CASE HERE SERVES: a sentence may promise a later delivery only
// when a pass PROVED one is possible, and may deny one only when the state on
// screen proves THAT. `OutputRemainder` carries the first proof and the message's
// own live chip count carries the second, which is why nothing below reads
// `outputScanDone`. That column says the TURN IS CLOSED, and a merely truncated
// pass closes on AGE once `truncatedScanHorizon` elapses, so a row deriving
// permanence from it tells a user the ceiling was hit and nothing more will come
// while "Check again" would in fact deliver more.
//
// PRIVACY: every value here is a count or a case. No name, no key, no path. The
// one record it is handed is read for a COUNT of chips and for nothing else.

import Foundation

/// The sentences the held-back row may print, chosen from the census and from
/// the message's own live chip count — never from anything else the view knows.
///
/// `nonisolated` so a test can reach it off the main actor, and so every answer
/// stays a pure function of its arguments — there is no view state it could
/// consult even by accident.
nonisolated enum OutputHeldBackCopy {

    // MARK: - What a budget left behind

    /// Which remainder sentence a row may print, or nil when there is nothing
    /// left to describe.
    ///
    /// THREE CASES AND NO FALLBACK, because the third is the one a fallback
    /// would swallow: a row whose remainder was recorded without its cause has
    /// no proof either way, and the only honest thing to say is that Conduck
    /// cannot tell. Folding it into either neighbour manufactures the promise
    /// (`.batching`) or manufactures the finality (`.ceiling`).
    enum RemainderLine: Equatable, Sendable {
        /// A later pass — or the user's own "Check again" — delivers the rest.
        /// Spellable ONLY from `.recoverable`, which a pass has to earn.
        case batching(count: Int)
        /// `maxOutputChipsPerMessage` means at least one of these never arrives
        /// on this message however often the folder is re-read. AT LEAST ONE is
        /// the whole of what it proves, which is why it does not by itself
        /// choose a sentence — see `sentences(for:on:)`.
        case ceiling(count: Int)
        /// Left behind, cause not recorded. Hedged in both directions.
        case unattributed(count: Int)
    }

    static func remainderLine(for remainder: OutputRemainder) -> RemainderLine? {
        switch remainder {
        case .nothingLeft:
            return nil
        case .recoverable(let count):
            return .batching(count: count)
        case .ceilingCapped(let count):
            return .ceiling(count: count)
        case .unknownCause(let count):
            return .unattributed(count: count)
        }
    }

    /// The words, as SENTENCES rather than as one string, because the ceiling
    /// case is deliberately two: an inflected count and an invariant statement of
    /// where the rest of those files are. Splitting them keeps the second out of
    /// every plural rule a translator would otherwise have to duplicate it into.
    ///
    /// IT TAKES THE MESSAGE BECAUSE THE LINE ALONE CANNOT SPELL THE TRUE
    /// SENTENCE. `.ceiling` proves exactly one thing — the lifetime allowance
    /// could not cover everything the pass left behind, so AT LEAST ONE of those
    /// files never arrives here. It does not prove that NONE will: a message
    /// sitting one slot under the ceiling still takes one more file, and "Check
    /// again" is offered on precisely that condition. A line claiming finality
    /// directly above a verb that then delivers a file is the defect this whole
    /// surface exists to remove, so the sentence reads the SAME live predicate
    /// the verb is gated on (`admitsMoreChips`) instead of a second one that can
    /// disagree with it.
    ///
    /// AND THE CAP IS NEVER STATED AS A NUMBER, in either arm. "Conduck shows at
    /// most N files from one reply" is not a fact about a reply:
    /// `maxOutputChipsPerMessage` bounds the FOLDER lane, while the tap-gated
    /// prose lane mints its chips against `maxCandidates` with no message-total
    /// check of its own. What is provable — and what the user can act on — is
    /// what happens to the files still sitting in the folder, which is what both
    /// arms say and all they say.
    static func sentences(
        for line: RemainderLine,
        on message: MessageRecord
    ) -> [LocalizedStringResource] {
        switch line {
        case .ceiling(let count):
            return [
                LocalizedStringResource(
                    "thread.outputs.heldBack.ceiling",
                    defaultValue: "^[\(count) more file](inflect: true) stayed in the folder."),
                admitsMoreChips(message)
                    // A SLOT IS FREE, so one more of them can still land here —
                    // which is exactly what the verb beside this line does. The
                    // shortfall is the only permanent part, so it is the only
                    // part claimed.
                    ? LocalizedStringResource(
                        "thread.outputs.heldBack.ceiling.partial",
                        defaultValue: "Conduck can't fit them all on this reply — checking again brings back what still fits, and the rest stay on your file server.")
                    // NO SLOT LEFT, so the folder lane adds nothing further to
                    // this message and these entries are where they stay. The
                    // claim is about THESE files rather than about the reply,
                    // which is the difference that keeps it true: the prose lane
                    // can still chip a file the reply NAMED, from the served
                    // root, and that is a different file in a different place.
                    : LocalizedStringResource(
                        "thread.outputs.heldBack.ceiling.full",
                        defaultValue: "Conduck can't bring these back to this reply — they're still on your file server."),
            ]
        case .batching(let count):
            return [LocalizedStringResource(
                "thread.outputs.heldBack.more",
                defaultValue: "^[\(count) more file](inflect: true) stayed in the folder. Conduck brings back a batch at a time and picks up more each time it checks this reply.")]
        case .unattributed(let count):
            // NEITHER PROMISE. This row was written without its cause, so the
            // app knows a remainder existed and nothing about whether it can
            // still arrive — and the escape hatch is the answer that holds
            // either way.
            return [LocalizedStringResource(
                "thread.outputs.heldBack.more.unknown",
                defaultValue: "^[\(count) more file](inflect: true) stayed in the folder. Conduck can't tell whether checking again brings it back; it's still on your file server either way.")]
        }
    }

    // MARK: - What the type arm may claim

    /// Whether the allowlist has WIDENED under this stored census.
    ///
    /// `stillRefused` is how many of the census's RETAINED names today's verdict
    /// still withholds — `OutputTypeRefusal.rescuableEntries` re-asks
    /// `FileServerClient.outboxEntryVerdict` for every one of them, so anything
    /// it drops is a name this build would no longer withhold. That makes the
    /// comparison a PROOF rather than a coincidence: fewer than the census
    /// retained means at least one file it counted as refused is one the app
    /// opens on its own today, and therefore that `typeRefusedCount` — a stored
    /// integer that never moves — counts files the thread would now hand over as
    /// ordinary chips.
    ///
    /// The only other verdict `rescuableEntries` drops on is `.refusedShape`,
    /// which nothing persists with a name and which would in any case push this
    /// the same way. So the mistake this can make is to under-claim, never to
    /// invent a refusal — the one direction a row about withheld files may err in.
    static func allowlistWidened(
        _ outcome: OutputDeliveryOutcome,
        stillRefused: Int
    ) -> Bool {
        stillRefused < outcome.typeRefusedEntries.count
    }

    /// The ONLY type count the row may print, and 0 when there is none.
    ///
    /// The census is the whole folder as ONE pass saw it; `stillRefused` is what
    /// today's verdict makes of the names that pass kept. While they agree the
    /// census is the better number — it covers the entries the retention cap kept
    /// no name for. Once they disagree the census is the stale one, and the row
    /// drops to the number it can still observe: it under-claims by however much
    /// of the unretained tail has also become deliverable, which is unknowable
    /// here (no name survived to re-ask about), and under-claiming is the side of
    /// that trade where no sentence goes false.
    static func claimedTypeCount(
        _ outcome: OutputDeliveryOutcome,
        stillRefused: Int
    ) -> Int {
        allowlistWidened(outcome, stillRefused: stillRefused)
            ? stillRefused
            : outcome.typeRefusedCount
    }

    /// Whether the row may name the RETENTION CAP for the gap between the count
    /// it just printed and the number the review sheet will list.
    ///
    /// The census counts the WHOLE folder; the record retains a bounded offer.
    /// When they disagree the sheet silently shows fewer files than the line
    /// above claimed, so the row says so rather than letting the user count.
    ///
    /// ONLY WHEN THE CAP IS WHAT BIT, which is what the widening term
    /// establishes: with no widening the still-refused names ARE the retained
    /// names, so a shortfall against the census can only be the retention cap.
    /// Under a widening the count line already equals exactly what the sheet
    /// lists — there is no gap left to explain, and naming the cap for a gap the
    /// allowlist opened attributes the shortfall to the one mechanism that
    /// provably did not cause it.
    static func blamesRetentionCap(
        _ outcome: OutputDeliveryOutcome,
        stillRefused: Int
    ) -> Bool {
        !allowlistWidened(outcome, stillRefused: stillRefused)
            && stillRefused > 0
            && outcome.typeRefusedCount > stillRefused
    }

    // MARK: - Names the app would not address at all

    /// One line per shape-refusal CLASS that actually occurred, in the order the
    /// row prints them.
    ///
    /// THE SPLIT IS THE REPAIR. One sentence was covering nine guards and was
    /// false for the two commonest of them: a long, ordinary filename — an agent
    /// naming a file after a section heading — is refused by a length budget and
    /// by nothing else, and a name that merely opens or closes on a space is
    /// refused by one guard about that space. Telling either author the name
    /// "could be read as an instruction, or hides itself from a listing"
    /// describes an attack that did not happen.
    ///
    /// TWO ACTIONABLE CLASSES AND ONE RESIDUAL, which is the split
    /// `FileServerClient.OutboxShapeRefusal` already makes: a shorter name and
    /// the same name without the space are both things an agent can be ASKED
    /// for, and everything else is a property of the name nobody can negotiate
    /// away.
    ///
    /// STILL NAMELESS on every arm. The class comes from a payload-free enum, so
    /// splitting the count costs the shape arm none of its silence.
    ///
    /// `Hashable` because the row drives a `ForEach` off it directly — the case
    /// IS the identity, and there is never more than one line per class.
    enum ShapeLine: Hashable, Sendable {
        /// Refused for LENGTH alone — benign, and answered by asking for a
        /// shorter name.
        case overlong(count: Int)
        /// Refused for a leading or trailing SPACE alone — benign, and answered
        /// by asking for the same name without it. A space is exactly what it
        /// says: the scalar-alphabet guard runs BEFORE this one and only U+0020
        /// gets through it, so this class can never be a tab, a newline or an
        /// exotic separator, and the sentence may name the character outright.
        case whitespaceBounded(count: Int)
        /// Refused by any other shape guard. Not negotiable, and not enumerated:
        /// seven specific sentences nobody can act on are worse than one true
        /// generic one.
        case unusable(count: Int)
    }

    /// THE ACTIONABLE CLASSES FIRST, deliberately: burying a line a user can
    /// respond to under one they cannot is the same mistake in a smaller form.
    /// Between the two of them the order is the order their guards run in, so the
    /// list is stable — a class that grows or shrinks between two listings never
    /// reorders the lines the user is reading.
    static func shapeLines(for census: ShapeRefusalCensus) -> [ShapeLine] {
        var lines: [ShapeLine] = []
        if census.overlongCount > 0 { lines.append(.overlong(count: census.overlongCount)) }
        if census.whitespaceBoundedCount > 0 {
            lines.append(.whitespaceBounded(count: census.whitespaceBoundedCount))
        }
        if census.unusableCount > 0 { lines.append(.unusable(count: census.unusableCount)) }
        return lines
    }

    /// NO NAME, EVER, on any arm, and each sentence explains its own vagueness
    /// — a generic line that does not say why it is generic reads as a bug.
    static func sentence(for line: ShapeLine) -> LocalizedStringResource {
        switch line {
        case .overlong(let count):
            // BENIGN AND ACTIONABLE, and it says so. This is the commonest shape
            // refusal by far, and the only one whose remedy is a sentence the
            // user can send to their own agent.
            return LocalizedStringResource(
                "thread.outputs.heldBack.shape.overlong",
                defaultValue: "Conduck left ^[\(count) file](inflect: true) alone because the name is longer than it can address. A shorter name comes back normally.")
        case .whitespaceBounded(let count):
            // THE SECOND BENIGN ONE, and the sentence names the space rather
            // than hedging to "whitespace": the guard that produced this class
            // runs after the scalar alphabet, which only U+0020 gets through, so
            // "a space" is what the code actually observed and anything vaguer
            // would be weaker than the evidence.
            //
            // IT ASKS FOR A NEW NAME RATHER THAN PREDICTING ONE. Conduck does
            // not repair the name itself — the display half trims, the stored
            // key does not, because a trimmed key addresses a file that is not
            // on the server — and a name whose space hid a second refusal behind
            // it (the leading-dot guard runs after this one) would make a
            // "comes back normally" promise false. Asking is true either way.
            return LocalizedStringResource(
                "thread.outputs.heldBack.shape.spaced",
                defaultValue: "Conduck left ^[\(count) file](inflect: true) alone because the name starts or ends with a space. Ask your agent for the same name without it.")
        case .unusable(let count):
            // The two mechanisms named are the real ones the REMAINING guards
            // test for — a separator or a `..` that reads as an instruction, a
            // leading dot or combining mark that hides the name — in words a
            // self-hoster can act on. Every class whose guard tests something
            // else has its own line above, which is the only reason this
            // accusation is allowed to stand: it is now true of everyone it is
            // shown to.
            return LocalizedStringResource(
                "thread.outputs.heldBack.shape.unusable",
                defaultValue: "Conduck left ^[\(count) file](inflect: true) alone because of how the name is written — a name other software could read as an instruction, or one that hides itself from a listing. There's nothing to review.")
        }
    }

    // MARK: - Whether "Check again" can still change anything

    /// Whether this message can still take another detector-minted chip.
    ///
    /// READ OFF THE ROW, NOT OFF THE CENSUS, and that is the point. The census is
    /// a snapshot of one listing; the chips are the live fact, and they keep
    /// arriving from the user's other devices through CloudKit. A message with
    /// free slots admits more files even when its last recorded remainder was
    /// `.ceilingCapped` — the ceiling bound THAT pass, and the pass that follows
    /// computes its own budget from the chips that are actually there.
    ///
    /// So this is exact in both directions: false means the verb genuinely
    /// cannot add anything (a request spent to redraw the same row), true means
    /// it can.
    ///
    /// TWO CONSUMERS, ONE PREDICATE, and keeping them on this one is the whole
    /// point: the verb is gated on it and the ceiling sentence is worded from it
    /// (`sentences(for:on:)`). A second predicate for the words could go one way
    /// while the button went the other, which is precisely the row that told a
    /// user nothing more would arrive and then handed them another file.
    static func admitsMoreChips(_ message: MessageRecord) -> Bool {
        message.attachments.count(where: \.isServerFile)
            < FileTransferOutputDetector.maxOutputChipsPerMessage
    }
}

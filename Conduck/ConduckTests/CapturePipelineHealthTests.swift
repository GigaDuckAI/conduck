// SPDX-License-Identifier: Apache-2.0

// Conduck
// CapturePipelineHealthTests.swift
//
// Locks the question a CarPlay listen asks when its no-speech window closes:
// was the driver quiet, or is the capture pipeline broken? Both look identical
// from the state machine's seat — nothing happened — and they need opposite
// answers, one of which is spoken out loud in a moving car.
//
// The verdict table is asserted row by row, but the tests that matter most are
// the GUARDRAILS, because each one is a way to say the wrong sentence:
//
//   • A FAILING CONVERTER MUST NOT LOOK LIKE A DEAD MICROPHONE. When no
//     conversion succeeds, the peak amplitude is simply never written — it stays
//     0 because nothing measured it, not because the microphone sent silence.
//     Without the `converterSuccesses > 0` precondition the zero-peak arm would
//     claim `micSilent` for every format failure and send a log reader hunting
//     the wrong layer.
//   • FINITE ALL-ZERO PROBABILITIES ARE NOT A FAULT. A run of zeros is exactly
//     what a quiet cabin looks like. Telling a driver who simply had nothing to
//     say that the car's microphone is broken is the worse error of the two, so
//     zeros sign off normally and only NaN, a VAD that ran nothing despite being
//     fed whole frames, or a thrown task count as broken.
//   • THE COUNTERS ARE PER TAP EPOCH. The engine-configuration-change path
//     reinstalls the tap mid-listen. On lifetime totals, one healthy conversion
//     from before the reconfiguration would mask a pipeline that died after it.
//   • AN EPOCH TOO YOUNG TO HAVE SEEN ANYTHING CONVICTS NOBODY. The other edge
//     of that same knife: a tap reinstalled a moment before the window closes
//     has no buffers yet, and a hands-free link still spinning its codec up
//     delivers real buffers of digital zeros. Both are the signature of a dead
//     microphone and neither is one, so a verdict needs an epoch old enough to
//     mean something.
//
// The collector half is covered too: it is written from the audio render
// thread, from the VAD task and read from the main-actor timer, so "the totals
// are right under concurrent writers" is part of the contract, not a detail.

import XCTest
@testable import Conduck

final class CapturePipelineHealthTests: XCTestCase {

    // MARK: - Fixtures

    /// How old every fixture's tap epoch is unless the test is about the age
    /// itself. A real listen runs 15 s or 30 s, and only an epoch restarted
    /// inside the last couple of seconds is too young to judge.
    private let settledEpoch: TimeInterval = 30

    /// A pipeline where everything worked: audio arrived, converted, carried
    /// signal, and the VAD scored it. The starting point every unhealthy fixture
    /// below is derived from by breaking exactly one thing.
    private func healthyCounters() -> CapturePipelineCounters {
        var counters = CapturePipelineCounters()
        counters.epochDuration = settledEpoch
        counters.tapBuffersReceived = 120
        counters.converterSuccesses = 120
        counters.converterFailures = 0
        counters.convertedSampleCount = 120 * 1024
        counters.peakAmplitude = 0.31
        counters.vadSamplesEnqueued = 120 * 1024
        counters.vadFullFramesEnqueued = 30
        counters.vadChunksProcessed = 30
        counters.maxProbability = 0.22
        return counters
    }

    /// A collector's counters with the epoch aged past the evidence window, for
    /// the assertions that are about what the pipeline did rather than about how
    /// long it has been doing it. A collector built inside a test is
    /// microseconds old, and the classifier declines to judge that on purpose.
    private func agedCounters(_ collector: CapturePipelineHealthCollector) -> CapturePipelineCounters {
        var counters = collector.snapshot()
        counters.epochDuration = settledEpoch
        return counters
    }

    /// A snapshot with its epoch age removed, so an equality assertion about the
    /// counters is not also an assertion about a clock.
    private func countersIgnoringEpochAge(_ collector: CapturePipelineHealthCollector) -> CapturePipelineCounters {
        var counters = collector.snapshot()
        counters.epochDuration = 0
        return counters
    }

    // MARK: - The verdict table

    func testHealthyPipelineWithNoSpeechIsGenuinelyQuiet() {
        XCTAssertEqual(CapturePipelineHealth.classify(healthyCounters()), .genuinelyQuiet)
    }

    func testZeroTapBuffersIsMicSilent() {
        var counters = CapturePipelineCounters()
        counters.epochDuration = settledEpoch
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .micSilent)
    }

    func testRealSamplesThatAreAllDigitalZeroIsMicSilent() {
        // A hands-free microphone that has been handed to us and is delivering
        // nothing but zeros: conversions succeed, samples flow, the peak never
        // leaves the floor.
        var counters = healthyCounters()
        counters.peakAmplitude = 0
        counters.maxProbability = 0
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .micSilent)
    }

    func testBuffersArrivingButNoConversionSucceedingIsFormatBroken() {
        var counters = CapturePipelineCounters()
        counters.epochDuration = settledEpoch
        counters.tapBuffersReceived = 90
        counters.converterSuccesses = 0
        counters.converterFailures = 90
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .formatBroken)
    }

    func testWholeFramesEnqueuedWithNoInferenceIsVADBroken() {
        var counters = healthyCounters()
        counters.vadChunksProcessed = 0
        counters.maxProbability = 0
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .vadBroken)
    }

    func testNonFiniteProbabilityIsVADBroken() {
        var counters = healthyCounters()
        counters.sawNonFiniteProbability = true
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .vadBroken)
    }

    func testThrownStreamingTaskIsVADBroken() {
        var counters = healthyCounters()
        counters.vadTaskFailed = true
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .vadBroken)
    }

    // MARK: - Guardrail: a failing converter is not a dead microphone

    func testFailingConverterWithZeroPeakIsFormatBrokenNotMicSilent() {
        // The exact masquerade the `converterSuccesses > 0` precondition exists
        // to stop: nothing converted, so nothing ever measured a peak.
        var counters = CapturePipelineCounters()
        counters.epochDuration = settledEpoch
        counters.tapBuffersReceived = 200
        counters.converterSuccesses = 0
        counters.converterFailures = 200
        counters.convertedSampleCount = 0
        counters.peakAmplitude = 0
        let verdict = CapturePipelineHealth.classify(counters)
        XCTAssertEqual(verdict, .formatBroken)
        XCTAssertNotEqual(verdict, .micSilent, "a never-written peak is not evidence about the microphone")
    }

    func testSuccessfulConversionsThatProducedNoSamplesAreNotMicSilent() {
        // Degenerate but reachable: the converter reports success on buffers
        // that carry no frames. There is no measured signal either way, so the
        // zero-peak arm must not claim a dead microphone.
        var counters = CapturePipelineCounters()
        counters.epochDuration = settledEpoch
        counters.tapBuffersReceived = 40
        counters.converterSuccesses = 40
        counters.converterFailures = 0
        counters.convertedSampleCount = 0
        counters.peakAmplitude = 0
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .genuinelyQuiet)
    }

    // MARK: - Guardrail: a quiet cabin is not a broken model

    func testFiniteAllZeroProbabilitiesAreGenuinelyQuiet() {
        var counters = healthyCounters()
        counters.maxProbability = 0
        XCTAssertEqual(
            CapturePipelineHealth.classify(counters), .genuinelyQuiet,
            "a quiet driver must never be told the microphone failed"
        )
    }

    func testAllZeroProbabilitiesAreFlaggedAsSuspiciousWithoutChangingTheVerdict() {
        var counters = healthyCounters()
        counters.maxProbability = 0
        XCTAssertTrue(CapturePipelineHealth.hasSuspiciousAllZeroProbabilities(counters))
        XCTAssertFalse(CapturePipelineHealth.classify(counters).isBroken)
    }

    func testSuspiciousZeroFlagNeedsChunksThatActuallyRan() {
        var counters = healthyCounters()
        counters.vadChunksProcessed = 0
        counters.maxProbability = 0
        XCTAssertFalse(
            CapturePipelineHealth.hasSuspiciousAllZeroProbabilities(counters),
            "no inference ran, so there are no zeros to be suspicious of"
        )
    }

    func testSuspiciousZeroFlagIsNotRaisedForNonFiniteProbabilities() {
        var counters = healthyCounters()
        counters.maxProbability = 0
        counters.sawNonFiniteProbability = true
        XCTAssertFalse(CapturePipelineHealth.hasSuspiciousAllZeroProbabilities(counters))
    }

    func testSuspiciousZeroFlagIsNotRaisedWhenSomethingScored() {
        XCTAssertFalse(CapturePipelineHealth.hasSuspiciousAllZeroProbabilities(healthyCounters()))
    }

    // MARK: - Guardrail: a young epoch is not evidence

    func testAnEpochTooYoungToHaveSeenAnythingIsNotADeadMicrophone() {
        // The tap was reinstalled by an engine reconfiguration a fraction of a
        // second before the window closed. One buffer period is 256 ms at
        // 16 kHz and 512 ms at a hands-free 8 kHz, so an empty epoch here means
        // "not yet", not "never".
        var counters = CapturePipelineCounters()
        counters.epochDuration = 0.2
        XCTAssertEqual(
            CapturePipelineHealth.classify(counters), .genuinelyQuiet,
            "a stopwatch reads zero the instant it starts"
        )
    }

    func testAJustResettledLinkDeliveringZerosIsNotADeadMicrophone() {
        // The wider case: a renegotiated hands-free link delivers a short run of
        // literal digital-zero buffers while its codec spins up. They convert
        // fine and carry a peak of exactly zero — the dead-microphone
        // signature, on a route that is about to work perfectly.
        var counters = healthyCounters()
        counters.epochDuration = 1
        counters.peakAmplitude = 0
        counters.maxProbability = 0
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .genuinelyQuiet)
    }

    func testTheEvidenceWindowExpiresAndTheVerdictReturns() {
        // The guardrail defers a verdict; it does not abolish one. A pipeline
        // that has been dead for the whole listen still gets named.
        var counters = CapturePipelineCounters()
        counters.epochDuration = CapturePipelineHealth.minimumEvidenceWindow
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .micSilent)
    }

    func testTheEvidenceWindowIsShortRelativeToBothSilenceWindows() {
        // It has to be: a window long enough to swallow an ordinary listen would
        // silence the microphone-failure line altogether.
        XCTAssertLessThan(
            CapturePipelineHealth.minimumEvidenceWindow,
            Constants.carPlayInitialSilenceTimeout / 2
        )
    }

    // MARK: - Ordering

    func testZeroTapBuffersWinsOverEveryOtherSymptom() {
        // Nothing arrived at all: whatever else is set describes a pipeline that
        // never got a chance, and "no audio is reaching us" is the actionable
        // half of that.
        var counters = CapturePipelineCounters()
        counters.epochDuration = settledEpoch
        counters.converterFailures = 5
        counters.vadFullFramesEnqueued = 5
        counters.sawNonFiniteProbability = true
        counters.vadTaskFailed = true
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .micSilent)
    }

    func testDigitalZeroSamplesWinOverAStalledVAD() {
        var counters = healthyCounters()
        counters.peakAmplitude = 0
        counters.vadChunksProcessed = 0
        counters.maxProbability = 0
        XCTAssertEqual(
            CapturePipelineHealth.classify(counters), .micSilent,
            "a VAD with nothing to score is downstream of the real failure"
        )
    }

    func testPartialConverterFailureWithSignalIsStillQuiet() {
        // Some conversions failed, some worked, and the ones that worked carried
        // signal. Nothing here is broken enough to speak about.
        var counters = healthyCounters()
        counters.converterFailures = 3
        XCTAssertEqual(CapturePipelineHealth.classify(counters), .genuinelyQuiet)
    }

    // MARK: - Verdict shape

    func testOnlyGenuinelyQuietIsUnbroken() {
        XCTAssertFalse(CapturePipelineVerdict.genuinelyQuiet.isBroken)
        for verdict: CapturePipelineVerdict in [.micSilent, .formatBroken, .vadBroken] {
            XCTAssertTrue(verdict.isBroken)
        }
    }

    func testVerdictRawValuesAreStable() {
        // These land verbatim in a fault-level log line, which is the only way
        // to tell the three failures apart after the fact — one spoken sentence
        // covers all three. Renaming a case silently rewrites that record.
        XCTAssertEqual(CapturePipelineVerdict.micSilent.rawValue, "micSilent")
        XCTAssertEqual(CapturePipelineVerdict.formatBroken.rawValue, "formatBroken")
        XCTAssertEqual(CapturePipelineVerdict.vadBroken.rawValue, "vadBroken")
        XCTAssertEqual(CapturePipelineVerdict.genuinelyQuiet.rawValue, "genuinelyQuiet")
    }

    // MARK: - Collector

    func testFreshCollectorIsEmptyAndTooYoungToConvict() {
        let collector = CapturePipelineHealthCollector()
        XCTAssertEqual(countersIgnoringEpochAge(collector), CapturePipelineCounters())
        XCTAssertEqual(
            CapturePipelineHealth.classify(collector.snapshot()), .genuinelyQuiet,
            "a collector built microseconds ago has seen nothing yet, which is not the same as nothing arriving"
        )
        XCTAssertEqual(
            CapturePipelineHealth.classify(agedCounters(collector)), .micSilent,
            "once the epoch has run long enough, an empty one does mean the microphone is dead"
        )
    }

    func testCollectorAccumulatesTapConversionAndVADFacts() {
        let collector = CapturePipelineHealthCollector()
        collector.recordTapBuffer()
        collector.recordTapBuffer()
        collector.recordConversion(sampleCount: 1024, peak: 0.2)
        collector.recordConversion(sampleCount: 1024, peak: 0.7)
        collector.recordConversion(sampleCount: 1024, peak: 0.4)
        collector.recordConversionFailure()
        let counters = collector.snapshot()
        XCTAssertEqual(counters.tapBuffersReceived, 2)
        XCTAssertEqual(counters.converterSuccesses, 3)
        XCTAssertEqual(counters.converterFailures, 1)
        XCTAssertEqual(counters.convertedSampleCount, 3 * 1024)
        XCTAssertEqual(counters.peakAmplitude, 0.7, "the peak is the loudest sample of the epoch, not the last")
    }

    func testCollectorIgnoresANonFinitePeak() {
        let collector = CapturePipelineHealthCollector()
        collector.recordConversion(sampleCount: 512, peak: 0.5)
        collector.recordConversion(sampleCount: 512, peak: .nan)
        collector.recordConversion(sampleCount: 512, peak: .infinity)
        XCTAssertEqual(collector.snapshot().peakAmplitude, 0.5)
    }

    func testCollectorDerivesWholeVADFramesFromEnqueuedSamples() {
        let collector = CapturePipelineHealthCollector()
        let frame = 4096
        collector.recordVADSamplesEnqueued(2000, frameSampleCount: frame)
        XCTAssertEqual(collector.snapshot().vadFullFramesEnqueued, 0, "a partial frame is not a frame")
        collector.recordVADSamplesEnqueued(2200, frameSampleCount: frame)
        XCTAssertEqual(collector.snapshot().vadSamplesEnqueued, 4200)
        XCTAssertEqual(collector.snapshot().vadFullFramesEnqueued, 1)
        collector.recordVADSamplesEnqueued(4096, frameSampleCount: frame)
        XCTAssertEqual(collector.snapshot().vadFullFramesEnqueued, 2)
    }

    func testCollectorIgnoresDegenerateEnqueueCounts() {
        let collector = CapturePipelineHealthCollector()
        collector.recordVADSamplesEnqueued(0, frameSampleCount: 4096)
        collector.recordVADSamplesEnqueued(-10, frameSampleCount: 4096)
        collector.recordVADSamplesEnqueued(4096, frameSampleCount: 0)
        XCTAssertEqual(countersIgnoringEpochAge(collector), CapturePipelineCounters())
    }

    func testCollectorTracksMaxProbabilityAndNonFiniteSeparately() {
        let collector = CapturePipelineHealthCollector()
        collector.recordVADChunk(probability: 0.1)
        collector.recordVADChunk(probability: 0.8)
        collector.recordVADChunk(probability: 0.3)
        XCTAssertEqual(collector.snapshot().maxProbability, 0.8)
        XCTAssertFalse(collector.snapshot().sawNonFiniteProbability)
        collector.recordVADChunk(probability: .nan)
        XCTAssertTrue(collector.snapshot().sawNonFiniteProbability)
        XCTAssertEqual(collector.snapshot().maxProbability, 0.8, "NaN never becomes the loudest thing we heard")
        XCTAssertEqual(collector.snapshot().vadChunksProcessed, 4)
    }

    func testCollectorRecordsAThrownStreamingTask() {
        let collector = CapturePipelineHealthCollector()
        collector.recordVADTaskFailure()
        XCTAssertTrue(collector.snapshot().vadTaskFailed)
    }

    // MARK: - Epoch scope

    func testBeginTapEpochClearsEveryHealthCounter() {
        let collector = CapturePipelineHealthCollector()
        collector.recordTapBuffer()
        collector.recordConversion(sampleCount: 4096, peak: 0.9)
        collector.recordVADSamplesEnqueued(4096, frameSampleCount: 4096)
        collector.recordVADChunk(probability: 0.9)
        collector.recordVADTaskFailure()

        collector.beginTapEpoch()

        let counters = collector.snapshot()
        XCTAssertEqual(counters.tapBuffersReceived, 0)
        XCTAssertEqual(counters.converterSuccesses, 0)
        XCTAssertEqual(counters.convertedSampleCount, 0)
        XCTAssertEqual(counters.peakAmplitude, 0)
        XCTAssertEqual(counters.vadSamplesEnqueued, 0)
        XCTAssertEqual(counters.vadFullFramesEnqueued, 0)
        XCTAssertEqual(counters.vadChunksProcessed, 0)
        XCTAssertEqual(counters.maxProbability, 0)
        XCTAssertFalse(counters.vadTaskFailed)
    }

    func testBeginTapEpochPreservesTheLiveCorroborationRun() {
        // The gate is not rebuilt by an engine reconfiguration, so the mirror of
        // its run length must survive one — otherwise a driver mid-word at the
        // moment the tap is reinstalled loses the expiry-boundary grace.
        let collector = CapturePipelineHealthCollector()
        collector.recordCorroborationRun(1)
        collector.recordTapBuffer()
        collector.beginTapEpoch()
        XCTAssertEqual(collector.snapshot().consecutiveQualifyingChunks, 1)
        XCTAssertEqual(collector.snapshot().tapBuffersReceived, 0)
    }

    func testAHealthyEpochCannotMaskAPipelineThatDiedAfterAReinstall() {
        // The reason the counters are epoch-scoped at all: on lifetime totals
        // this classifies as `genuinelyQuiet` and the driver is sent away
        // believing they were heard.
        let collector = CapturePipelineHealthCollector()
        collector.recordTapBuffer()
        collector.recordConversion(sampleCount: 4096, peak: 0.4)
        collector.recordVADSamplesEnqueued(4096, frameSampleCount: 4096)
        collector.recordVADChunk(probability: 0.2)
        XCTAssertEqual(CapturePipelineHealth.classify(agedCounters(collector)), .genuinelyQuiet)

        // The tap comes back after the reconfiguration and delivers nothing —
        // and goes on delivering nothing for long enough to mean it.
        collector.beginTapEpoch()
        XCTAssertEqual(CapturePipelineHealth.classify(agedCounters(collector)), .micSilent)
    }

    func testBeginTapEpochPreservesACorroboratedListen() {
        // Corroboration belongs to the listen, not to the tap: a driver who was
        // already talking when the route resettled has still been heard, and the
        // no-speech timeout reads this flag to know it.
        let collector = CapturePipelineHealthCollector()
        collector.recordCorroboratedSpeech()
        collector.recordTapBuffer()
        collector.beginTapEpoch()
        XCTAssertTrue(collector.snapshot().didCorroborateSpeech)
        XCTAssertEqual(collector.snapshot().tapBuffersReceived, 0)
    }

    func testCorroborationIsVisibleBeforeAnyMainActorHop() {
        // The whole point of the flag: the VAD task publishes it here, and the
        // main actor may not learn the same fact until later — a no-speech
        // timeout queued in between reads this instead of signing off over
        // someone mid-word.
        let collector = CapturePipelineHealthCollector()
        XCTAssertFalse(collector.snapshot().didCorroborateSpeech)
        collector.recordCorroboratedSpeech()
        XCTAssertTrue(collector.snapshot().didCorroborateSpeech)
        // Corroborating ends the qualifying run, so the run mirror is no longer
        // the evidence — which is exactly why the flag has to exist.
        collector.recordCorroborationRun(0)
        XCTAssertTrue(collector.snapshot().didCorroborateSpeech)
    }

    func testCorroborationRunMirrorIsOverwrittenNotAccumulated() {
        let collector = CapturePipelineHealthCollector()
        collector.recordCorroborationRun(1)
        collector.recordCorroborationRun(0)
        XCTAssertEqual(collector.snapshot().consecutiveQualifyingChunks, 0)
    }

    // MARK: - Concurrency

    func testCollectorTotalsSurviveConcurrentWriters() {
        // Three real writers with no ordering between them — the render thread,
        // the streaming task, and whatever else the run loop is doing — so the
        // arithmetic is done under the lock or it is wrong. Synchronous
        // `concurrentPerform`: no wall-clock waiting, no flake.
        let collector = CapturePipelineHealthCollector()
        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            collector.recordTapBuffer()
            collector.recordConversion(sampleCount: 100, peak: Float(index) / Float(iterations))
            collector.recordVADSamplesEnqueued(100, frameSampleCount: 4096)
            collector.recordVADChunk(probability: 0.1)
        }
        let counters = collector.snapshot()
        XCTAssertEqual(counters.tapBuffersReceived, iterations)
        XCTAssertEqual(counters.converterSuccesses, iterations)
        XCTAssertEqual(counters.convertedSampleCount, iterations * 100)
        XCTAssertEqual(counters.vadSamplesEnqueued, iterations * 100)
        XCTAssertEqual(counters.vadChunksProcessed, iterations)
        XCTAssertEqual(counters.vadFullFramesEnqueued, (iterations * 100) / 4096)
        XCTAssertEqual(counters.maxProbability, 0.1)
        XCTAssertEqual(
            counters.peakAmplitude, Float(iterations - 1) / Float(iterations),
            "the loudest peak of the epoch must survive every racing writer"
        )
    }
}

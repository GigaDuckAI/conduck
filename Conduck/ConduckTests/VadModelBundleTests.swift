// Conduck
// VadModelBundleTests.swift
//
// Build-drift guard for the ONE bundled ML artifact: the Silero VAD
// `.mlmodelc` that `EndOfSpeechDetector` (CarPlay end-of-speech detection)
// loads out of `Bundle.main`.
//
// Why this is a security test, not a packaging nicety: FluidAudio's only other
// way to obtain the model is `VadManager(config:)`, which DOWNLOADS it from
// `huggingface.co`. `EndOfSpeechDetector.loadManager()` never calls that init —
// a missing resource throws `LoadError.vadModelMissingFromBundle` instead — so
// the app has no code path to a host the user did not configure. These tests
// pin the other half of that invariant: that the bundled resource the
// fail-closed branch replaces is actually THERE, so the branch stays
// unreachable and CarPlay VAD keeps working. Without them, a synchronized-folder
// or Copy-Bundle-Resources regression would ship a build whose in-car voice turn
// dies silently.
//
// Same idiom and rationale as `testSpokenProbeAssetResolvesInBundle`
// (`STTConnectionTestSuiteTests`) and the `Conversations.momd` lookup in
// `WSDDeclinedTurnTests` — app-hosted target, so `Bundle.main` is `Conduck.app`
// on iOS, iOS Simulator, and macOS alike. Deliberately NOT platform-gated even
// though the detector is `#if os(iOS)`: the resource rides the shared
// synchronized `Resources/` folder and ships on every platform this target runs
// on, so an unconditional assertion catches drift on whichever destination the
// suite happens to run.

import CoreML
import XCTest
@testable import Conduck

final class VadModelBundleTests: XCTestCase {

    /// Resource name + extension EXACTLY as `EndOfSpeechDetector.loadManager()`
    /// spells them. Duplicated on purpose — a rename that touches only one side
    /// fails here loudly instead of silently arming the fail-closed branch.
    private static let modelName = "silero-vad-unified-256ms-v6.0.0"
    private static let modelExtension = "mlmodelc"

    private var modelURL: URL? {
        Bundle.main.url(forResource: Self.modelName, withExtension: Self.modelExtension)
    }

    // MARK: - 1. The production lookup resolves

    func testVadModelResolvesInAppBundle() {
        // The exact call the detector makes. A nil here means the shipped app
        // would take the fail-closed branch: no CarPlay VAD at all.
        XCTAssertNotNil(
            modelURL,
            "\(Self.modelName).\(Self.modelExtension) must resolve in Bundle.main — CarPlay end-of-speech detection loads it from there and FAILS CLOSED (no runtime download) when it is absent. A nil here = the resource left the app target (synchronized-folder / Copy-Bundle-Resources regression)."
        )
    }

    // MARK: - 2. The compiled artifact is complete, not a stub

    func testVadModelCompiledArtifactsArePresentAndNonEmpty() throws {
        let url = try XCTUnwrap(modelURL, "resource must resolve (see testVadModelResolvesInAppBundle)")

        // `.mlmodelc` is a DIRECTORY. `url(forResource:)` resolving it proves
        // only that the directory exists — a truncated copy, or a Git-LFS
        // pointer file checked out in place of the weights, would still pass
        // test 1 and then fail at `MLModel(contentsOf:)` on the road. Assert the
        // three load-bearing members are present and non-trivial in size.
        let members = ["coremldata.bin", "model.mil", "weights/weight.bin"]
        for member in members {
            let memberURL = url.appendingPathComponent(member)
            let values = try? memberURL.resourceValues(forKeys: [.fileSizeKey])
            let size = values?.fileSize ?? 0
            XCTAssertGreaterThan(
                size, 0,
                "\(Self.modelName).\(Self.modelExtension)/\(member) must be bundled and non-empty — a zero-byte or missing member means the compiled model was copied incompletely."
            )
        }

        // The weight blob dominates the ~1 MB artifact; a pointer file or
        // stripped payload lands in the low hundreds of bytes.
        let weights = url.appendingPathComponent("weights/weight.bin")
        let weightSize = (try? weights.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        XCTAssertGreaterThan(
            weightSize, 100_000,
            "The Silero weight blob is ~860 KB. A few hundred bytes = a Git-LFS pointer or a stripped payload, not the model."
        )
    }

    // MARK: - 3. CoreML actually accepts it

    func testVadModelLoadsThroughCoreML() throws {
        let url = try XCTUnwrap(modelURL, "resource must resolve (see testVadModelResolvesInAppBundle)")

        // `.cpuOnly` on purpose, unlike the detector's device path
        // (`.cpuAndNeuralEngine`): this test asserts the ARTIFACT is a valid
        // compiled model, and CPU load is the deterministic, ANE-independent,
        // simulator-safe way to prove that. Compute-unit selection for real
        // inference stays the detector's concern.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly

        let model = try MLModel(contentsOf: url, configuration: configuration)

        // Silero's unified 256 ms model takes audio + the two recurrent-state
        // inputs FluidAudio populates. If the bundled artifact were ever swapped
        // for a different model revision, the detector would fail at prediction
        // time with a feature-name mismatch — catch it here instead.
        let inputs = Set(model.modelDescription.inputDescriptionsByName.keys)
        for expected in ["audio_input", "hidden_state", "cell_state"] {
            XCTAssertTrue(
                inputs.contains(expected),
                "The bundled VAD model must expose the '\(expected)' input FluidAudio's VadManager feeds. Present inputs: \(inputs.sorted()). A mismatch means the bundled .mlmodelc is not the expected Silero revision."
            )
        }
    }
}

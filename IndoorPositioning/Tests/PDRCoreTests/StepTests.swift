//
//  StepTests.swift
//  PDRCoreTests
//

import XCTest
@testable import PDRCore

final class StepTests: XCTestCase {
    /// A phone held flat, with the gait riding on the vertical axis.
    private func flatSample(
        time: TimeInterval,
        verticalAcceleration: Double,
        horizontal: Vector2 = .zero,
        rotationRate: Vector3 = .zero
    ) -> MotionSample {
        MotionSample(
            timestamp: time,
            userAcceleration: Vector3(horizontal.x, horizontal.y, verticalAcceleration),
            gravity: Vector3(0, 0, -standardGravity),
            rotationRate: rotationRate,
            attitude: .identity
        )
    }

    private func walkSamples(
        steps: Int,
        cadence: Double = 1.8,
        amplitude: Double = 3.6,
        sampleRate: Double = 50
    ) -> [MotionSample] {
        let duration = Double(steps) / cadence
        let dt = 1 / sampleRate
        return (0..<Int(duration * sampleRate)).map { index in
            let t = Double(index) * dt
            return flatSample(time: t, verticalAcceleration: amplitude * sin(2 * .pi * cadence * t))
        }
    }

    func testDetectsOneStepPerGaitCycle() {
        var detector = StepDetector()
        var detected = 0
        for sample in walkSamples(steps: 40) {
            if detector.process(sample) != nil { detected += 1 }
        }
        // The adaptive threshold needs a full statistics window before it will
        // fire, so the opening few cycles are legitimately missed.
        XCTAssertGreaterThan(detected, 30)
        XCTAssertLessThanOrEqual(detected, 41)
    }

    func testIgnoresStandingStill() {
        var detector = StepDetector()
        var generator = SeededGenerator(seed: 3)
        var detected = 0
        for index in 0..<1000 {
            let noise = generator.nextGaussian(standardDeviation: 0.05)
            let sample = flatSample(time: Double(index) * 0.02, verticalAcceleration: noise)
            if detector.process(sample) != nil { detected += 1 }
        }
        XCTAssertEqual(detected, 0, "sensor noise while standing must not become steps")
    }

    func testEmittedStepsAlwaysRespectTheCadenceBounds() {
        let configuration = StepDetector.Configuration.default
        var detector = StepDetector(configuration: configuration)
        var detected: [StepEvent] = []
        // 0.35 Hz is one bounce every 2.9 s — beyond the maximum step interval,
        // so a peak there is a pause ending, not a three-second stride. No
        // emitted event may ever claim an interval outside the bounds, because
        // a bogus interval turns straight into a bogus distance.
        for sample in walkSamples(steps: 10, cadence: 0.35) {
            if let step = detector.process(sample) { detected.append(step) }
        }
        for step in detected {
            XCTAssertGreaterThanOrEqual(step.interval, configuration.minimumStepInterval)
            XCTAssertLessThanOrEqual(step.interval, configuration.maximumStepInterval)
        }
    }

    func testStepEventCarriesThePeakToPeakWindow() {
        var detector = StepDetector()
        var events: [StepEvent] = []
        for sample in walkSamples(steps: 30, amplitude: 3.6) {
            if let step = detector.process(sample) { events.append(step) }
        }
        guard let event = events.last else { return XCTFail("no steps detected") }
        // 3.6 m/s² of bounce, attenuated by the 3 Hz low-pass, gives a
        // peak-to-peak swing a little over 6 m/s².
        XCTAssertEqual(event.accelerationRange, 6.2, accuracy: 1.2)
        XCTAssertEqual(event.cadence, 1.8, accuracy: 0.15)
        XCTAssertGreaterThan(event.accelerationMean, 0)
    }

    func testWeinbergLengthTracksAmplitude() {
        let estimator = StepLengthEstimator()
        func step(range: Double) -> StepEvent {
            StepEvent(
                timestamp: 0, interval: 1 / 1.8,
                accelerationMax: 9.81 + range / 2,
                accelerationMin: 9.81 - range / 2,
                accelerationMean: range / 3,
                accelerationVariance: 1, index: 0
            )
        }
        let small = estimator.length(for: step(range: 3))
        let large = estimator.length(for: step(range: 12))
        XCTAssertLessThan(small, large)
        XCTAssertGreaterThanOrEqual(small, estimator.configuration.minimumStepLength)
        XCTAssertLessThanOrEqual(large, estimator.configuration.maximumStepLength)
    }

    func testStepLengthIsAlwaysBounded() {
        let estimator = StepLengthEstimator()
        // A detector failure must not turn into a twelve-metre stride. This is
        // the whole point of counting bounded events instead of integrating.
        let absurd = StepEvent(
            timestamp: 0, interval: 0.3,
            accelerationMax: 900, accelerationMin: -900,
            accelerationMean: 400, accelerationVariance: 1, index: 0
        )
        let length = estimator.length(for: absurd)
        XCTAssertLessThanOrEqual(length, estimator.configuration.maximumStepLength)

        let degenerate = StepEvent(
            timestamp: 0, interval: 0.3,
            accelerationMax: -5, accelerationMin: 5,
            accelerationMean: -1, accelerationVariance: 0, index: 0
        )
        XCTAssertGreaterThanOrEqual(
            estimator.length(for: degenerate),
            estimator.configuration.minimumStepLength
        )
        XCTAssertFalse(estimator.length(for: degenerate).isNaN)
    }

    func testCalibrationPullsTheModelOntoAKnownDistance() {
        var estimator = StepLengthEstimator()
        let steps = (0..<100).map { index in
            StepEvent(
                timestamp: Double(index) / 1.8, interval: 1 / 1.8,
                accelerationMax: 13, accelerationMin: 7,
                accelerationMean: 2, accelerationVariance: 1, index: index
            )
        }
        let before = estimator.relativeError(knownDistance: 80, steps: steps, mode: .pocket)
        XCTAssertNotNil(estimator.calibrate(knownDistance: 80, steps: steps, mode: .pocket))
        let after = estimator.relativeError(knownDistance: 80, steps: steps, mode: .pocket)
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertLessThan(abs(after!), abs(before!))
        XCTAssertEqual(after!, 0, accuracy: 0.02)
    }

    func testCalibrationRefusesAnImplausibleCorrection() {
        var estimator = StepLengthEstimator()
        let steps = (0..<50).map { index in
            StepEvent(
                timestamp: Double(index) / 1.8, interval: 1 / 1.8,
                accelerationMax: 13, accelerationMin: 7,
                accelerationMean: 2, accelerationVariance: 1, index: index
            )
        }
        // 50 steps cannot have covered 5 m; that is a mistyped reference walk,
        // and swallowing it would poison the model for the whole session.
        XCTAssertNil(estimator.calibrate(knownDistance: 5, steps: steps, mode: .handheldSteady))
        XCTAssertNil(estimator.calibrate(knownDistance: 200, steps: steps, mode: .handheldSteady))
    }

    func testCalibrationNeedsEnoughSteps() {
        var estimator = StepLengthEstimator()
        let steps = (0..<3).map { index in
            StepEvent(
                timestamp: 0, interval: 1 / 1.8,
                accelerationMax: 13, accelerationMin: 7,
                accelerationMean: 2, accelerationVariance: 1, index: index
            )
        }
        XCTAssertNil(estimator.calibrate(knownDistance: 2, steps: steps, mode: .handheldSteady))
    }
}

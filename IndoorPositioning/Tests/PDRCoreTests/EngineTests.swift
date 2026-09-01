//
//  EngineTests.swift
//  PDRCoreTests
//

import XCTest
@testable import PDRCore

final class EngineTests: XCTestCase {

    private func corridorMap(length: Double, width: Double = 2.4) -> IndoorMap {
        let half = width / 2
        return IndoorMap(
            name: "corridor",
            walls: [
                Segment(-2, half, length + 2, half),
                Segment(-2, -half, length + 2, -half),
            ],
            corridors: [
                Corridor(
                    id: "main",
                    polyline: [Point2D(x: -2, y: 0), Point2D(x: length + 2, y: 0)],
                    width: width
                )
            ],
            anchors: [MapAnchor(id: "half-way", position: Point2D(x: length / 2, y: 0))],
            entryPoints: [MapEntryPoint(id: "door", position: .zero, heading: 0)]
        )
    }

    private func straightWalk(
        distance: Double = 60,
        mode: CarriageMode = .handheldSteady,
        driftDegreesPerMinute: Double = 0,
        providesAttitude: Bool = true
    ) -> SyntheticWalk.Result {
        var configuration = SyntheticWalk.Configuration()
        configuration.path = [Point2D(x: 0, y: 0), Point2D(x: distance, y: 0)]
        configuration.mode = mode
        configuration.providesAttitude = providesAttitude
        configuration.attitudeDriftRate = Angle.degrees(driftDegreesPerMinute) / 60
        return SyntheticWalk.generate(configuration)
    }

    // MARK: - Generator sanity

    func testGeneratorProducesAConsistentGroundTruth() {
        let walk = straightWalk(distance: 60)
        XCTAssertGreaterThan(walk.samples.count, 1000)
        XCTAssertEqual(walk.truthDistance, 60, accuracy: 1.0)
        guard let end = walk.truthPositions.last else { return XCTFail("no truth path") }
        XCTAssertEqual(end.x, 60, accuracy: 1.0)
        XCTAssertEqual(end.y, 0, accuracy: 1e-9)
    }

    func testGeneratorGravityMatchesTheReportedAttitude() {
        let walk = straightWalk(distance: 10)
        for sample in walk.samples.prefix(50) {
            XCTAssertEqual(sample.gravity.magnitude, standardGravity, accuracy: 1e-6)
            guard let attitude = sample.attitude else { return XCTFail("expected an attitude") }
            let up = attitude.rotate(sample.up)
            XCTAssertEqual(up.z, 1, accuracy: 1e-6)
        }
    }

    // MARK: - End to end

    func testCountsRoughlyTheRightNumberOfSteps() {
        let walk = straightWalk(distance: 60)
        let engine = PDREngine(map: nil)
        engine.start(position: .zero, heading: 0)
        for sample in walk.samples { engine.process(sample) }

        // The adaptive threshold needs a couple of seconds before it fires, so
        // a handful of opening steps are legitimately missed.
        XCTAssertGreaterThan(engine.stepEvents.count, walk.trueStepCount - 8)
        XCTAssertLessThanOrEqual(engine.stepEvents.count, walk.trueStepCount + 2)
    }

    func testStepLengthModelIsWithinItsAdvertisedBand() {
        let walk = straightWalk(distance: 60)
        let engine = PDREngine(map: nil)
        engine.start(position: .zero, heading: 0)
        var fix: PositionFix?
        for sample in walk.samples { if let f = engine.process(sample) { fix = f } }
        guard let fix else { return XCTFail("no fix produced") }

        // Uncalibrated stride models are quoted at 10-15 %. Anything outside
        // that on clean input means the model, not the user, is wrong.
        let relativeError = abs(fix.travelledDistance - walk.truthDistance) / walk.truthDistance
        XCTAssertLessThan(relativeError, 0.15)
    }

    func testCleanWalkEndsUpNearTheTruth() {
        let walk = straightWalk(distance: 60)
        let engine = PDREngine(map: nil)
        engine.start(position: .zero, heading: 0)
        var fix: PositionFix?
        for sample in walk.samples { if let f = engine.process(sample) { fix = f } }
        guard let fix, let truth = walk.truthPositions.last else { return XCTFail("no fix") }
        XCTAssertLessThan(fix.deadReckoningPosition.distance(to: truth), 10)
    }

    func testMapConstraintBeatsDeadReckoningUnderHeadingDrift() {
        // The central claim: heading drift is what kills PDR, and the corridor
        // is what fixes it. 20 deg/min over a 45 s walk is a bad but entirely
        // realistic gyro.
        let distance = 60.0
        let walk = straightWalk(distance: distance, driftDegreesPerMinute: 20)
        let map = corridorMap(length: distance)
        let engine = PDREngine(map: map)
        engine.start(at: map.entryPoints[0])

        var fix: PositionFix?
        for sample in walk.samples { if let f = engine.process(sample) { fix = f } }
        guard let fix, let truth = walk.truthPositions.last else { return XCTFail("no fix") }

        let deadReckoningError = fix.deadReckoningPosition.distance(to: truth)
        let constrainedError = fix.position.distance(to: truth)

        XCTAssertGreaterThan(deadReckoningError, 3.0, "the drift should actually bite")
        XCTAssertLessThan(constrainedError, deadReckoningError)
        XCTAssertLessThan(abs(fix.position.y), 2.0, "the estimate must stay in the corridor")
    }

    func testAnchorResetsAccumulatedError() {
        let distance = 60.0
        let walk = straightWalk(distance: distance, driftDegreesPerMinute: 20)
        let map = corridorMap(length: distance)
        let engine = PDREngine(map: map)
        engine.start(at: map.entryPoints[0])
        for sample in walk.samples { engine.process(sample) }

        XCTAssertTrue(engine.observeAnchor(id: "half-way"))
        guard let anchor = map.anchor(id: "half-way") else { return XCTFail("missing anchor") }

        // A fix is only produced on a step, so walk a little further and check
        // the estimate came back near the marker rather than near wherever the
        // drift had taken it.
        var afterAnchor: PositionFix?
        for sample in walk.samples.prefix(300) {
            var shifted = sample
            shifted.timestamp += walk.samples.last!.timestamp + 1
            if let f = engine.process(shifted) { afterAnchor = f }
        }
        guard let afterAnchor else { return XCTFail("no fix after the anchor") }
        XCTAssertLessThan(afterAnchor.position.distance(to: anchor.position), 12)
    }

    func testUnknownAnchorIsReportedRatherThanSilentlyIgnored() {
        let map = corridorMap(length: 20)
        let engine = PDREngine(map: map)
        engine.start(at: map.entryPoints[0])
        XCTAssertFalse(engine.observeAnchor(id: "does-not-exist"))
    }

    func testCarriageModeIsRecognised() {
        for mode in [CarriageMode.handheldSteady, .pocket, .handheldSwinging, .calling] {
            let walk = straightWalk(distance: 40, mode: mode)
            let engine = PDREngine(map: nil)
            engine.start(position: .zero, heading: 0)
            for sample in walk.samples { engine.process(sample) }
            XCTAssertEqual(
                engine.latestFix?.carriageMode, mode,
                "expected \(mode.rawValue), got \(engine.latestFix?.carriageMode.rawValue ?? "none")"
            )
        }
    }

    func testPocketCarriageStillTracksDistance() {
        // The phone sits at 75 degrees to the direction of travel and bounces
        // far harder than in a hand. Both are handled: PCA recovers the walking
        // direction, and the per-mode stride gain absorbs the amplitude.
        let walk = straightWalk(distance: 60, mode: .pocket)
        let engine = PDREngine(map: nil)
        engine.start(position: .zero, heading: 0)
        var fix: PositionFix?
        for sample in walk.samples { if let f = engine.process(sample) { fix = f } }
        guard let fix else { return XCTFail("no fix") }
        let relativeError = abs(fix.travelledDistance - walk.truthDistance) / walk.truthDistance
        XCTAssertLessThan(relativeError, 0.20)
    }

    func testGyroOnlyPathStillProducesFixes() {
        // No platform attitude: the estimator falls back to integrating the
        // gyro, which is the case on a phone whose magnetometer never settles.
        let walk = straightWalk(distance: 40, providesAttitude: false)
        let engine = PDREngine(map: nil)
        engine.start(position: .zero, heading: 0)
        var fix: PositionFix?
        for sample in walk.samples { if let f = engine.process(sample) { fix = f } }
        guard let fix else { return XCTFail("no fix on the gyro-only path") }
        XCTAssertGreaterThan(fix.stepCount, 30)
        XCTAssertTrue(
            fix.headingSource == .gyroscopeOnly || fix.headingSource == .gyroscopeAndMagnetometer
        )
    }

    func testReportedAccuracyGrowsWithoutAMap() {
        let walk = straightWalk(distance: 60)
        let engine = PDREngine(map: nil)
        engine.start(position: .zero, heading: 0)
        var accuracies: [Double] = []
        for sample in walk.samples {
            if let fix = engine.process(sample) { accuracies.append(fix.horizontalAccuracy) }
        }
        guard let first = accuracies.first, let last = accuracies.last else {
            return XCTFail("no fixes")
        }
        XCTAssertGreaterThan(last, first, "unaided PDR only ever loses accuracy; say so")
    }

    // MARK: - Experiments

    func testDriftExperimentDerivesAnAnchorSpacing() {
        let distance = 100.0
        let walk = straightWalk(distance: distance, driftDegreesPerMinute: 15)
        guard let end = walk.truthPositions.last else { return XCTFail("no truth") }

        let result = DriftExperiment.run(
            DriftExperiment.Setup(
                label: "synthetic 100 m",
                samples: walk.samples,
                truthStart: .zero,
                truthEnd: end,
                truthStartHeading: 0,
                truthPathLength: walk.truthDistance,
                map: corridorMap(length: distance)
            )
        )

        XCTAssertGreaterThan(result.stepCount, 100)
        XCTAssertGreaterThan(result.errorPerMetre, 0)
        XCTAssertNotNil(result.constrainedError)
        XCTAssertLessThan(result.constrainedError ?? .infinity, result.deadReckoningError)

        // The number this whole exercise exists to produce: how far apart the
        // reset markers have to be to hold a given accuracy.
        let spacing = result.anchorSpacing(tolerance: 5)
        XCTAssertGreaterThan(spacing, 0)
        XCTAssertTrue(spacing.isFinite)
        XCTAssertFalse(result.summary(tolerance: 5).isEmpty)
    }

    func testLateralErrorIsTheHeadingErrorMadeVisible() {
        let distance = 100.0
        let walk = straightWalk(distance: distance, driftDegreesPerMinute: 25)
        guard let end = walk.truthPositions.last else { return XCTFail("no truth") }
        let result = DriftExperiment.run(
            DriftExperiment.Setup(
                label: "drifting",
                samples: walk.samples,
                truthStart: .zero,
                truthEnd: end,
                truthStartHeading: 0,
                truthPathLength: walk.truthDistance
            )
        )
        // Heading error pushes you sideways; stride error only pushes you along
        // the corridor. With a drifting gyro the sideways term dominates.
        XCTAssertGreaterThan(
            result.deadReckoningLateralError, result.deadReckoningAlongTrackError
        )
        XCTAssertGreaterThan(result.impliedHeadingError, Angle.degrees(1))
    }

    func testCarriageComparisonRuns() {
        let hand = straightWalk(distance: 60, mode: .handheldSteady)
        let pocket = straightWalk(distance: 60, mode: .pocket)
        guard let handEnd = hand.truthPositions.last,
              let pocketEnd = pocket.truthPositions.last else { return XCTFail("no truth") }

        let comparison = DriftExperiment.compareCarriage(
            hand: DriftExperiment.Setup(
                label: "hand", samples: hand.samples, truthStart: .zero, truthEnd: handEnd,
                truthStartHeading: 0, truthPathLength: hand.truthDistance
            ),
            pocket: DriftExperiment.Setup(
                label: "pocket", samples: pocket.samples, truthStart: .zero, truthEnd: pocketEnd,
                truthStartHeading: 0, truthPathLength: pocket.truthDistance
            )
        )
        XCTAssertGreaterThan(comparison.hand.stepCount, 50)
        XCTAssertGreaterThan(comparison.pocket.stepCount, 50)
        XCTAssertTrue(comparison.stepLengthGap.isFinite)
        XCTAssertFalse(comparison.summary.isEmpty)
    }

    // MARK: - The claim that motivates the whole design

    func testDoubleIntegrationIsWhatWeAvoided() {
        // Not a test of production code: a demonstration of the alternative.
        // Integrating the same clean stream twice, with a 1 degree attitude
        // error, is what "compute position from the accelerometer" would mean.
        let walk = straightWalk(distance: 60)
        let tiltError = Angle.degrees(1)
        var velocity = Vector2.zero
        var position = Point2D.zero
        var previous: TimeInterval?

        for sample in walk.samples {
            guard let last = previous else { previous = sample.timestamp; continue }
            let dt = sample.timestamp - last
            previous = sample.timestamp
            guard let attitude = sample.attitude else { continue }

            let world = attitude.rotate(sample.userAcceleration)
            // One degree of attitude error leaks 9.81 * sin(1 deg) of gravity
            // into the horizontal axes.
            let leak = standardGravity * sin(tiltError)
            let horizontal = Vector2(world.x + leak, world.y)
            velocity = velocity + horizontal * dt
            position = position + velocity * dt
        }

        guard let truth = walk.truthPositions.last else { return XCTFail("no truth") }
        let integratedError = position.distance(to: truth)

        let engine = PDREngine(map: nil)
        engine.start(position: .zero, heading: 0)
        var fix: PositionFix?
        for sample in walk.samples { if let f = engine.process(sample) { fix = f } }
        guard let fix else { return XCTFail("no fix") }
        let steppedError = fix.deadReckoningPosition.distance(to: truth)

        XCTAssertGreaterThan(
            integratedError, steppedError * 10,
            "double integration should be catastrophically worse; if it is not, "
                + "the synthetic walk has stopped being representative"
        )
    }
}

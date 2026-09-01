//
//  ParticleFilterTests.swift
//  PDRCoreTests
//

import XCTest
@testable import PDRCore

final class ParticleFilterTests: XCTestCase {
    /// A straight east-west corridor 60 m long, walls either side.
    private func corridorMap(length: Double = 60, width: Double = 2.4) -> IndoorMap {
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
            anchors: [MapAnchor(id: "pillar", position: Point2D(x: 30, y: 0))],
            entryPoints: [MapEntryPoint(id: "door", position: .zero, heading: 0)]
        )
    }

    private func walk(
        _ filter: ParticleFilter,
        steps: Int,
        length: Double = 0.72,
        heading: Double = 0,
        uncertainty: Double = 0
    ) -> ParticleFilterEstimate? {
        var estimate: ParticleFilterEstimate?
        for _ in 0..<steps {
            estimate = filter.update(
                length: length, measuredHeading: heading, headingUncertainty: uncertainty
            )
        }
        return estimate
    }

    func testStraightWalkTracksDistance() {
        let filter = ParticleFilter(map: MapIndex(map: corridorMap()))
        filter.initialize(
            position: .zero, heading: 0, measuredHeading: 0,
            positionSigma: 0.3, headingSigma: Angle.degrees(5)
        )
        guard let estimate = walk(filter, steps: 40) else { return XCTFail("no estimate") }
        XCTAssertEqual(estimate.position.x, 28.8, accuracy: 4.0)
        XCTAssertEqual(estimate.position.y, 0, accuracy: 1.0)
        XCTAssertFalse(estimate.isAmbiguous)
    }

    func testCorridorConstraintCancelsAConstantHeadingError() {
        // The failure the map exists to fix: a heading that is wrong by a fixed
        // amount pushes dead reckoning sideways, without limit. Here the sensor
        // insists the user is walking 12 degrees north of the corridor.
        let map = corridorMap()
        let filter = ParticleFilter(map: MapIndex(map: map))
        filter.initialize(
            position: .zero, heading: 0, measuredHeading: 0,
            positionSigma: 0.3, headingSigma: Angle.degrees(20)
        )
        let bogusHeading = Angle.degrees(12)
        guard let estimate = walk(filter, steps: 55, heading: bogusHeading) else {
            return XCTFail("no estimate")
        }

        // Unconstrained, 55 steps at 0.72 m would end up 8 m off the centre line.
        let unconstrained = 55 * 0.72 * sin(bogusHeading)
        XCTAssertGreaterThan(unconstrained, 8)
        XCTAssertLessThan(abs(estimate.position.y), 1.5)
        // The filter should have worked out roughly how wrong the sensor is.
        XCTAssertEqual(estimate.headingBias, -bogusHeading, accuracy: Angle.degrees(9))
    }

    func testWallsKillHypothesesThatWalkThroughThem() {
        let map = corridorMap()
        let filter = ParticleFilter(map: MapIndex(map: map))
        filter.initialize(
            position: Point2D(x: 10, y: 0), heading: 0, measuredHeading: 0,
            positionSigma: 0.2, headingSigma: Angle.degrees(3)
        )
        // Walk due north, straight into the wall.
        _ = walk(filter, steps: 10, heading: .pi / 2)
        let index = MapIndex(map: map)
        let alive = filter.particles.filter { $0.weight > 0 }
        XCTAssertFalse(alive.isEmpty, "the filter must recover rather than go blank")
        let outside = alive.filter { !index.isWalkable($0.position) }
        XCTAssertLessThan(
            Double(outside.count) / Double(alive.count), 0.5,
            "most surviving hypotheses should be back inside the corridor"
        )
    }

    func testAnchorCollapsesTheCloud() {
        let map = corridorMap()
        let filter = ParticleFilter(map: MapIndex(map: map))
        filter.initialize(
            position: .zero, heading: 0, measuredHeading: 0,
            positionSigma: 3.0, headingSigma: Angle.degrees(30)
        )
        _ = walk(filter, steps: 30, uncertainty: Angle.degrees(15))
        guard let anchor = map.anchor(id: "pillar") else { return XCTFail("missing anchor") }
        filter.observeAnchor(anchor, measuredHeading: 0)

        let spread = filter.particles.map { $0.position.distance(to: anchor.position) }
        let worst = spread.max() ?? .infinity
        XCTAssertLessThan(worst, 3.0, "a scanned marker is ground truth, not a hint")
    }

    func testDirectionSplitKeepsBothHypothesesAlive() {
        let filter = ParticleFilter(map: MapIndex(map: corridorMap()))
        filter.initialize(
            position: Point2D(x: 30, y: 0), heading: 0, measuredHeading: 0,
            positionSigma: 0.3, headingSigma: Angle.degrees(5)
        )
        filter.splitForDirectionAmbiguity()
        _ = walk(filter, steps: 10)

        // A straight corridor genuinely cannot resolve forward from backward,
        // so the filter must report the ambiguity rather than pick a side.
        let ahead = filter.particles.filter { $0.position.x > 32 }
        let behind = filter.particles.filter { $0.position.x < 28 }
        XCTAssertFalse(ahead.isEmpty)
        XCTAssertFalse(behind.isEmpty)
        XCTAssertTrue(filter.estimate?.isAmbiguous ?? false)
    }

    func testDirectionSplitIsIdempotent() {
        let filter = ParticleFilter(map: MapIndex(map: corridorMap()))
        filter.initialize(
            position: .zero, heading: 0, measuredHeading: 0,
            positionSigma: 0.1, headingSigma: 0
        )
        filter.splitForDirectionAmbiguity()
        let afterFirst = filter.particles.map(\.headingBias)
        filter.splitForDirectionAmbiguity()
        XCTAssertEqual(filter.particles.map(\.headingBias), afterFirst)
    }

    func testDeterministicForAGivenSeed() {
        func run() -> Point2D {
            let filter = ParticleFilter(map: MapIndex(map: corridorMap()), seed: 12345)
            filter.initialize(
                position: .zero, heading: 0, measuredHeading: 0,
                positionSigma: 0.5, headingSigma: Angle.degrees(10)
            )
            return walk(filter, steps: 25)?.position ?? .zero
        }
        let first = run()
        let second = run()
        XCTAssertEqual(first.x, second.x, accuracy: 1e-12)
        XCTAssertEqual(first.y, second.y, accuracy: 1e-12)
    }

    func testWithoutAMapItIsPlainDeadReckoning() {
        let filter = ParticleFilter(map: nil)
        filter.initialize(
            position: .zero, heading: 0, measuredHeading: 0,
            positionSigma: 0.1, headingSigma: 0
        )
        guard let estimate = walk(filter, steps: 50, heading: Angle.degrees(12)) else {
            return XCTFail("no estimate")
        }
        // No corridor to pull it back, so the 12 degree error is fully realised.
        XCTAssertEqual(
            estimate.position.y, 50 * 0.72 * sin(Angle.degrees(12)), accuracy: 2.0
        )
    }

    func testStepScaleStaysWithinItsBounds() {
        let configuration = ParticleFilter.Configuration.default
        let filter = ParticleFilter(map: MapIndex(map: corridorMap()))
        filter.initialize(
            position: .zero, heading: 0, measuredHeading: 0,
            positionSigma: 0.3, headingSigma: Angle.degrees(5)
        )
        _ = walk(filter, steps: 60)
        for particle in filter.particles {
            XCTAssertGreaterThanOrEqual(particle.stepScale, configuration.minimumStepScale)
            XCTAssertLessThanOrEqual(particle.stepScale, configuration.maximumStepScale)
        }
    }
}

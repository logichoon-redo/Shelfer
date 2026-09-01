//
//  MotionLogTests.swift
//  PDRCoreTests
//

import XCTest
@testable import PDRCore

final class MotionLogTests: XCTestCase {
    private func sample(_ time: TimeInterval, withOptionals: Bool) -> MotionSample {
        MotionSample(
            timestamp: time,
            userAcceleration: Vector3(0.125, -0.25, 0.5),
            gravity: Vector3(0, 0, -standardGravity),
            rotationRate: Vector3(0.01, -0.02, 0.03),
            attitude: withOptionals
                ? Quaternion(axis: Vector3(0, 0, 1), angle: 0.5)
                : nil,
            magneticField: withOptionals ? Vector3(20, -10, -35) : nil,
            magneticFieldAccuracy: withOptionals ? 1 : nil
        )
    }

    func testRoundTripsAFullSample() throws {
        let original = [sample(0, withOptionals: true), sample(0.02, withOptionals: true)]
        let decoded = try MotionLog.parse(csv: MotionLog.csv(from: original))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[1].timestamp, 0.02, accuracy: 1e-6)
        XCTAssertEqual(decoded[0].userAcceleration.x, 0.125, accuracy: 1e-6)
        XCTAssertEqual(decoded[0].gravity.z, -standardGravity, accuracy: 1e-5)
        XCTAssertEqual(decoded[0].rotationRate.y, -0.02, accuracy: 1e-6)
        XCTAssertEqual(decoded[0].magneticField?.x ?? .nan, 20, accuracy: 1e-6)
        XCTAssertEqual(decoded[0].magneticFieldAccuracy, 1)
        XCTAssertEqual(decoded[0].attitude?.w ?? .nan, cos(0.25), accuracy: 1e-6)
    }

    func testRoundTripsASampleWithNoMagnetometerOrAttitude() throws {
        let decoded = try MotionLog.parse(csv: MotionLog.csv(from: [sample(1, withOptionals: false)]))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].attitude)
        XCTAssertNil(decoded[0].magneticField)
        XCTAssertNil(decoded[0].magneticFieldAccuracy)
    }

    func testHeaderIsOptionalOnRead() throws {
        let withHeader = MotionLog.csv(from: [sample(0, withOptionals: true)])
        let withoutHeader = withHeader
            .split(separator: "\n")
            .dropFirst()
            .joined(separator: "\n")
        XCTAssertEqual(try MotionLog.parse(csv: withoutHeader).count, 1)
    }

    func testEmptyLogIsAnError() {
        XCTAssertThrowsError(try MotionLog.parse(csv: ""))
    }

    func testShortRowIsAnError() {
        XCTAssertThrowsError(try MotionLog.parse(csv: MotionLog.header + "\n1,2,3\n"))
    }

    func testUnparsableNumberIsAnError() {
        let row = MotionLog.header + "\n0,x,0,0,0,0,0,0,0,0\n"
        XCTAssertThrowsError(try MotionLog.parse(csv: row))
    }

    func testReplayingALogReproducesTheLiveResult() throws {
        var configuration = SyntheticWalk.Configuration()
        configuration.path = [Point2D(x: 0, y: 0), Point2D(x: 30, y: 0)]
        let walk = SyntheticWalk.generate(configuration)

        func run(_ samples: [MotionSample]) -> PositionFix? {
            let engine = PDREngine(map: nil, seed: 99)
            engine.start(position: .zero, heading: 0)
            var fix: PositionFix?
            for sample in samples { if let f = engine.process(sample) { fix = f } }
            return fix
        }

        let live = run(walk.samples)
        let replayed = run(try MotionLog.parse(csv: MotionLog.csv(from: walk.samples)))
        XCTAssertNotNil(live)
        XCTAssertNotNil(replayed)
        // Six decimal places is well below sensor resolution, so a replay has
        // to land on the same answer as the live run — at worst one step of
        // rounding at a threshold crossing.
        XCTAssertLessThanOrEqual(abs(live!.stepCount - replayed!.stepCount), 1)
        XCTAssertEqual(live!.position.x, replayed!.position.x, accuracy: 1.0)
    }
}

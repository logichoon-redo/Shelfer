//
//  MathTests.swift
//  PDRCoreTests
//

import XCTest
@testable import PDRCore

final class MathTests: XCTestCase {
    func testVectorAlgebra() {
        let a = Vector3(1, 2, 3)
        let b = Vector3(4, 5, 6)
        XCTAssertEqual(a.dot(b), 32, accuracy: 1e-12)
        XCTAssertEqual(a.cross(b).x, -3, accuracy: 1e-12)
        XCTAssertEqual(a.cross(b).y, 6, accuracy: 1e-12)
        XCTAssertEqual(a.cross(b).z, -3, accuracy: 1e-12)
        XCTAssertEqual(Vector3(3, 4, 0).magnitude, 5, accuracy: 1e-12)
        XCTAssertEqual(Vector3.zero.normalized(), .zero)
    }

    func testRejectionRemovesTheAxisComponent() {
        let axis = Vector3(0, 0, 2)
        let rejected = Vector3(1, 2, 9).rejected(from: axis)
        XCTAssertEqual(rejected.z, 0, accuracy: 1e-12)
        XCTAssertEqual(rejected.x, 1, accuracy: 1e-12)
        XCTAssertEqual(rejected.y, 2, accuracy: 1e-12)
    }

    func testQuaternionRotatesAboutZ() {
        let q = Quaternion(axis: Vector3(0, 0, 1), angle: .pi / 2)
        let rotated = q.rotate(Vector3(1, 0, 0))
        XCTAssertEqual(rotated.x, 0, accuracy: 1e-9)
        XCTAssertEqual(rotated.y, 1, accuracy: 1e-9)
        XCTAssertEqual(rotated.z, 0, accuracy: 1e-9)
    }

    func testQuaternionInverseRoundTrips() {
        let q = (Quaternion(axis: Vector3(0, 0, 1), angle: 0.7)
                 * Quaternion(axis: Vector3(1, 0, 0), angle: -0.4)).normalized()
        let v = Vector3(0.3, -1.2, 4)
        let round = q.inverseRotate(q.rotate(v))
        XCTAssertEqual(round.x, v.x, accuracy: 1e-9)
        XCTAssertEqual(round.y, v.y, accuracy: 1e-9)
        XCTAssertEqual(round.z, v.z, accuracy: 1e-9)
    }

    func testAngleWrapping() {
        XCTAssertEqual(Angle.wrapToPi(3 * .pi), .pi, accuracy: 1e-9)
        XCTAssertEqual(Angle.wrapToPi(-3 * .pi), .pi, accuracy: 1e-9)
        XCTAssertEqual(Angle.delta(from: Angle.degrees(350), to: Angle.degrees(10)),
                       Angle.degrees(20), accuracy: 1e-9)
    }

    func testAxialSeparationTreatsOppositeDirectionsAsOneAxis() {
        // A corridor is a line: walking north and walking south are the same
        // constraint, and the filter must not prefer one.
        XCTAssertEqual(Angle.axialSeparation(0, .pi), 0, accuracy: 1e-9)
        XCTAssertEqual(Angle.axialSeparation(0, .pi / 2), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(Angle.axialSeparation(Angle.degrees(5), Angle.degrees(185)),
                       0, accuracy: 1e-9)
    }

    func testCircularMeanDoesNotBreakAtTheWrapPoint() {
        let mean = Angle.circularMean([Angle.degrees(179), Angle.degrees(-179)])
        XCTAssertEqual(abs(mean), .pi, accuracy: Angle.degrees(1))
    }

    func testLowPassConverges() {
        var filter = LowPassFilter(cutoffHz: 1)
        filter.update(0, dt: 0)
        for _ in 0..<500 { filter.update(10, dt: 0.02) }
        XCTAssertEqual(filter.value, 10, accuracy: 0.05)
    }

    func testLowPassAttenuatesFastSignalsMoreThanSlowOnes() {
        var fast = CascadedLowPass(cutoffHz: 3)
        var slow = CascadedLowPass(cutoffHz: 3)
        var fastPeak = 0.0
        var slowPeak = 0.0
        let dt = 1.0 / 100
        for index in 0..<600 {
            let t = Double(index) * dt
            fastPeak = max(fastPeak, abs(fast.update(sin(2 * .pi * 20 * t), dt: dt)))
            slowPeak = max(slowPeak, abs(slow.update(sin(2 * .pi * 1.5 * t), dt: dt)))
        }
        XCTAssertLessThan(fastPeak, 0.2)
        XCTAssertGreaterThan(slowPeak, 0.7)
    }

    func testSlidingWindowStatsTrackMeanAndSpread() {
        var stats = SlidingWindowStats(window: 1.0)
        for index in 0..<200 {
            stats.add(Double(index % 2 == 0 ? 1 : -1), at: Double(index) * 0.01)
        }
        XCTAssertEqual(stats.mean, 0, accuracy: 0.05)
        XCTAssertEqual(stats.standardDeviation, 1, accuracy: 0.05)
        XCTAssertTrue(stats.isSaturated)
    }

    func testSlidingWindowDropsStaleSamples() {
        var stats = SlidingWindowStats(window: 0.5)
        for index in 0..<100 { stats.add(5, at: Double(index) * 0.01) }
        for index in 100..<200 { stats.add(9, at: Double(index) * 0.01) }
        XCTAssertEqual(stats.mean, 9, accuracy: 1e-6)
    }

    func testSeededGeneratorIsReproducible() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testGaussianHasTheRequestedSpread() {
        var generator = SeededGenerator(seed: 7)
        var sum = 0.0
        var sumOfSquares = 0.0
        let count = 20000
        for _ in 0..<count {
            let value = generator.nextGaussian(standardDeviation: 2)
            sum += value
            sumOfSquares += value * value
        }
        let mean = sum / Double(count)
        let deviation = (sumOfSquares / Double(count) - mean * mean).squareRoot()
        XCTAssertEqual(mean, 0, accuracy: 0.06)
        XCTAssertEqual(deviation, 2, accuracy: 0.08)
    }

    func testRingBufferKeepsTheNewestElements() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        XCTAssertEqual(buffer.elements, [3, 4, 5])
        XCTAssertEqual(buffer.last, 5)
        XCTAssertTrue(buffer.isFull)
    }
}

//
//  HeadingTests.swift
//  PDRCoreTests
//

import XCTest
@testable import PDRCore

final class HeadingTests: XCTestCase {

    // MARK: - Frame conventions

    func testFlatPhoneBasisPointsAlongTheDeviceAxes() {
        let sample = MotionSample(
            timestamp: 0,
            userAcceleration: .zero,
            gravity: Vector3(0, 0, -standardGravity),
            rotationRate: .zero,
            attitude: .identity
        )
        let basis = sample.horizontalBasis
        XCTAssertEqual(basis.e1.x, 1, accuracy: 1e-9)
        XCTAssertEqual(basis.e2.y, 1, accuracy: 1e-9)
        XCTAssertEqual(sample.up.z, 1, accuracy: 1e-9)
        XCTAssertEqual(sample.referenceHeadingOfBasis ?? .nan, 0, accuracy: 1e-9)
    }

    func testUprightPhoneStillProducesAHorizontalBasis() {
        // Phone standing on its end: the device X axis is no longer horizontal,
        // so the basis has to fall back to the Y axis instead of degenerating.
        let sample = MotionSample(
            timestamp: 0,
            userAcceleration: .zero,
            gravity: Vector3(-standardGravity, 0, 0),
            rotationRate: .zero,
            attitude: .identity
        )
        let basis = sample.horizontalBasis
        XCTAssertEqual(basis.e1.magnitude, 1, accuracy: 1e-9)
        XCTAssertEqual(basis.e1.dot(sample.up), 0, accuracy: 1e-9)
        XCTAssertEqual(basis.e2.dot(sample.up), 0, accuracy: 1e-9)
        XCTAssertEqual(basis.e1.dot(basis.e2), 0, accuracy: 1e-9)
    }

    func testVerticalAndHorizontalAccelerationSplitCleanly() {
        let sample = MotionSample(
            timestamp: 0,
            userAcceleration: Vector3(1, 2, 3),
            gravity: Vector3(0, 0, -standardGravity),
            rotationRate: .zero
        )
        XCTAssertEqual(sample.verticalAcceleration, 3, accuracy: 1e-9)
        XCTAssertEqual(sample.horizontalAcceleration.z, 0, accuracy: 1e-9)
        XCTAssertEqual(sample.horizontalAccelerationInBasis.x, 1, accuracy: 1e-9)
        XCTAssertEqual(sample.horizontalAccelerationInBasis.y, 2, accuracy: 1e-9)
    }

    func testYawRateProjectsOntoGravityNotOntoDeviceZ() {
        // Phone held upright, rotating about the world vertical. Reading the
        // gyro's z axis would report nothing at all.
        let sample = MotionSample(
            timestamp: 0,
            userAcceleration: .zero,
            gravity: Vector3(0, standardGravity, 0),   // device -Y is up
            rotationRate: Vector3(0, -0.5, 0),
            attitude: .identity
        )
        XCTAssertEqual(sample.rotationRate.z, 0, accuracy: 1e-12)
        XCTAssertEqual(sample.yawRate, 0.5, accuracy: 1e-9)
    }

    // MARK: - Heading estimator

    private func rotatingSamples(
        rate: Double,
        duration: Double,
        gyroBias: Double = 0,
        withAttitude: Bool,
        sampleRate: Double = 50
    ) -> [MotionSample] {
        let dt = 1 / sampleRate
        return (0..<Int(duration * sampleRate)).map { index in
            let t = Double(index) * dt
            let yaw = rate * t
            return MotionSample(
                timestamp: t,
                userAcceleration: Vector3(0, 0, 0.9 * sin(2 * .pi * 1.8 * t)),
                gravity: Vector3(0, 0, -standardGravity),
                rotationRate: Vector3(0, 0, rate + gyroBias),
                attitude: withAttitude
                    ? Quaternion(axis: Vector3(0, 0, 1), angle: yaw)
                    : nil
            )
        }
    }

    func testGyroIntegrationTracksAKnownTurn() {
        var estimator = HeadingEstimator()
        estimator.anchor(deviceHeading: 0, uncertainty: Angle.degrees(5))
        for sample in rotatingSamples(
            rate: Angle.degrees(30), duration: 3, withAttitude: false
        ) {
            estimator.process(sample)
        }
        XCTAssertEqual(estimator.deviceHeading, Angle.degrees(90), accuracy: Angle.degrees(4))
        XCTAssertEqual(estimator.source, .gyroscopeOnly)
    }

    func testUncertaintyGrowsWhileRunningOnGyroAlone() {
        var estimator = HeadingEstimator()
        estimator.anchor(deviceHeading: 0, uncertainty: Angle.degrees(3))
        let start = estimator.uncertainty
        for sample in rotatingSamples(rate: 0, duration: 30, withAttitude: false) {
            estimator.process(sample)
        }
        XCTAssertGreaterThan(estimator.uncertainty, start,
                             "gyro-only heading degrades monotonically and must say so")
    }

    func testPlatformAttitudeIsPreferredWhenAvailable() {
        var estimator = HeadingEstimator()
        // A badly biased gyro must not move the answer when the platform is
        // already giving us a fused attitude.
        for sample in rotatingSamples(
            rate: Angle.degrees(30), duration: 3,
            gyroBias: Angle.degrees(45), withAttitude: true
        ) {
            estimator.process(sample)
        }
        XCTAssertTrue(estimator.usesPlatformAttitude)
        XCTAssertEqual(estimator.deviceHeading, Angle.degrees(90), accuracy: Angle.degrees(2))
    }

    func testStationaryGyroBiasIsLearnedAndRemoved() {
        var estimator = HeadingEstimator()
        estimator.anchor(deviceHeading: 0, uncertainty: Angle.degrees(3))
        let bias = Angle.degrees(2)   // 2 deg/s: a bad but not unheard-of gyro
        let dt = 0.02
        // Sit still for a minute so the bias estimate can settle.
        for index in 0..<3000 {
            estimator.process(
                MotionSample(
                    timestamp: Double(index) * dt,
                    userAcceleration: .zero,
                    gravity: Vector3(0, 0, -standardGravity),
                    rotationRate: Vector3(0, 0, bias)
                )
            )
        }
        XCTAssertTrue(estimator.isStationary)
        // Without bias removal, 60 s at 2 deg/s is 120 degrees of phantom turn.
        XCTAssertLessThan(abs(Angle.wrapToPi(estimator.deviceHeading)), Angle.degrees(25))
    }

    // MARK: - Magnetometer gate

    private func magneticSample(
        time: TimeInterval,
        headingFromNorth: Double,
        strength: Double = 48,
        dip: Double = Angle.degrees(50)
    ) -> MotionSample {
        // Phone flat; magnetic north sits at `-headingFromNorth` in the device
        // frame when the device faces `headingFromNorth`.
        let horizontal = strength * cos(dip)
        let vertical = strength * sin(dip)
        let field = Vector3(
            horizontal * cos(-headingFromNorth),
            horizontal * sin(-headingFromNorth),
            -vertical
        )
        return MotionSample(
            timestamp: time,
            userAcceleration: .zero,
            gravity: Vector3(0, 0, -standardGravity),
            rotationRate: .zero,
            attitude: .identity,
            magneticField: field,
            magneticFieldAccuracy: 1
        )
    }

    func testCleanFieldOpensTheGateAndReadsTheHeading() {
        var gate = MagnetometerGate()
        var reading: MagnetometerGate.Reading?
        for index in 0..<200 {
            reading = gate.process(
                magneticSample(time: Double(index) * 0.02, headingFromNorth: Angle.degrees(40))
            )
        }
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(reading?.heading ?? .nan, Angle.degrees(40), accuracy: Angle.degrees(1))
    }

    func testGateClosesOnAFieldThatIsNotTheEarth() {
        var gate = MagnetometerGate()
        for index in 0..<200 {
            gate.process(magneticSample(time: Double(index) * 0.02, headingFromNorth: 0))
        }
        XCTAssertTrue(gate.isOpen)
        // Walk past a steel door: the field triples in strength.
        for index in 200..<260 {
            gate.process(
                magneticSample(time: Double(index) * 0.02, headingFromNorth: 0, strength: 160)
            )
        }
        XCTAssertFalse(gate.isOpen, "an implausible field must not be allowed to steer heading")
    }

    func testGateRejectsAnUncalibratedMagnetometer() {
        var gate = MagnetometerGate()
        for index in 0..<200 {
            var sample = magneticSample(time: Double(index) * 0.02, headingFromNorth: 0)
            sample.magneticFieldAccuracy = -1
            gate.process(sample)
        }
        XCTAssertFalse(gate.isOpen)
    }

    // MARK: - Walking direction

    /// Horizontal acceleration for a walker travelling at `walkingDirection`
    /// relative to the device basis.
    private func pcaSamples(walkingDirection: Double, count: Int = 200) -> [MotionSample] {
        let dt = 0.02
        let cadence = 1.8
        let forwardAxis = Vector2.unit(angle: walkingDirection)
        let leftAxis = Vector2.unit(angle: walkingDirection + .pi / 2)
        return (0..<count).map { index in
            let t = Double(index) * dt
            let phase = 2 * .pi * cadence * t
            let forward = 2.4 * cos(phase)
            let lateral = 0.6 * sin(phase / 2)
            let horizontal = forwardAxis * forward + leftAxis * lateral
            return MotionSample(
                timestamp: t,
                userAcceleration: Vector3(horizontal.x, horizontal.y, 3.5 * sin(phase)),
                gravity: Vector3(0, 0, -standardGravity),
                rotationRate: .zero,
                attitude: .identity
            )
        }
    }

    func testPCARecoversTheWalkingAxis() {
        var estimator = WalkingDirectionEstimator()
        let truth = Angle.degrees(35)
        for sample in pcaSamples(walkingDirection: truth) { estimator.process(sample) }
        let estimate = estimator.update(mode: .handheldSteady)
        // PCA recovers an axis, not an arrow — compare modulo 180 degrees.
        XCTAssertEqual(
            Angle.axialSeparation(estimate.misalignment, truth), 0,
            accuracy: Angle.degrees(8)
        )
        XCTAssertGreaterThan(estimate.confidence, 0.2)
    }

    func testPCASeparatesWalkingDirectionFromDeviceOrientation() {
        // The carriage-mode trap: the phone points 80 degrees off the direction
        // of travel. Taking the device heading as the walking heading would put
        // the user 80 degrees wrong; PCA is what recovers the difference.
        var estimator = WalkingDirectionEstimator()
        let truth = Angle.degrees(80)
        for sample in pcaSamples(walkingDirection: truth) { estimator.process(sample) }
        let estimate = estimator.update(mode: .handheldSteady)
        XCTAssertEqual(
            Angle.axialSeparation(estimate.misalignment, truth), 0,
            accuracy: Angle.degrees(8)
        )
    }

    func testForwardHintResolvesTheSignAmbiguity() {
        var estimator = WalkingDirectionEstimator()
        let truth = Angle.degrees(30)
        estimator.setForwardHint(misalignment: 0)
        for sample in pcaSamples(walkingDirection: truth) { estimator.process(sample) }
        let estimate = estimator.update(mode: .handheldSteady)
        XCTAssertTrue(estimate.isSignResolved)
        XCTAssertEqual(estimate.misalignment, truth, accuracy: Angle.degrees(8))
    }

    func testCircularCloudCarriesNoDirection() {
        // Standing and shaking the phone: no dominant axis, so no direction,
        // and the estimator must report that rather than inventing one.
        var estimator = WalkingDirectionEstimator()
        var generator = SeededGenerator(seed: 11)
        for index in 0..<300 {
            estimator.process(
                MotionSample(
                    timestamp: Double(index) * 0.02,
                    userAcceleration: Vector3(
                        generator.nextGaussian(standardDeviation: 1),
                        generator.nextGaussian(standardDeviation: 1),
                        generator.nextGaussian(standardDeviation: 1)
                    ),
                    gravity: Vector3(0, 0, -standardGravity),
                    rotationRate: .zero,
                    attitude: .identity
                )
            )
        }
        let noiseConfidence = estimator.update(mode: .handheldSteady).confidence

        var walking = WalkingDirectionEstimator()
        for sample in pcaSamples(walkingDirection: Angle.degrees(20)) { walking.process(sample) }
        let walkingConfidence = walking.update(mode: .handheldSteady).confidence

        XCTAssertLessThan(noiseConfidence, 0.5)
        XCTAssertLessThan(noiseConfidence, walkingConfidence / 2)
    }
}

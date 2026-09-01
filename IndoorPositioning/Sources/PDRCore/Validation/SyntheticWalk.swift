//
//  SyntheticWalk.swift
//  PDRCore
//

import Foundation

/// Generates IMU streams for a walk along a known path.
///
/// **What this is for, and what it is not.** It exercises the pipeline
/// end-to-end with ground truth attached, so a regression in step detection or
/// in the map constraint fails a test instead of failing in a corridor. It
/// cannot tell you how accurate the system is in a real building: the gait
/// model is a few sinusoids, and real accelerometer signals are not. Numbers
/// that matter come from `MotionLog` recordings of real walks. Treat any
/// accuracy figure produced from synthetic data as a property of this file.
public struct SyntheticWalk {
    /// Per-carriage-mode gait and handling signature.
    public struct Signature: Sendable {
        /// Vertical bounce amplitude, m/s².
        public var verticalAmplitude: Double
        /// Fore-aft acceleration amplitude, m/s².
        public var forwardAmplitude: Double
        /// Lateral sway amplitude, m/s². Runs at half the step frequency,
        /// because sway alternates sides once per stride.
        public var lateralAmplitude: Double
        /// Amplitude of the device's own pitch oscillation, radians.
        public var pitchOscillation: Double
        /// Amplitude of the device's own yaw oscillation, radians.
        public var yawOscillation: Double
        /// Fixed angle between where the device points and where the user
        /// walks, radians. The carriage-mode trap in one number.
        public var misalignment: Double
        /// Fixed tilt of the device away from flat, radians.
        public var tilt: Double

        public init(
            verticalAmplitude: Double,
            forwardAmplitude: Double,
            lateralAmplitude: Double,
            pitchOscillation: Double,
            yawOscillation: Double,
            misalignment: Double,
            tilt: Double
        ) {
            self.verticalAmplitude = verticalAmplitude
            self.forwardAmplitude = forwardAmplitude
            self.lateralAmplitude = lateralAmplitude
            self.pitchOscillation = pitchOscillation
            self.yawOscillation = yawOscillation
            self.misalignment = misalignment
            self.tilt = tilt
        }

        public static func signature(for mode: CarriageMode) -> Signature {
            switch mode {
            case .handheldSteady, .stationary, .unknown:
                return Signature(
                    verticalAmplitude: 3.6, forwardAmplitude: 1.3, lateralAmplitude: 0.8,
                    pitchOscillation: 0.02, yawOscillation: 0.02,
                    misalignment: 0, tilt: Angle.degrees(35)
                )
            case .handheldSwinging:
                return Signature(
                    verticalAmplitude: 4.2, forwardAmplitude: 2.6, lateralAmplitude: 1.9,
                    pitchOscillation: 0.55, yawOscillation: 0.18,
                    misalignment: Angle.degrees(20), tilt: Angle.degrees(70)
                )
            case .pocket:
                return Signature(
                    verticalAmplitude: 6.2, forwardAmplitude: 3.4, lateralAmplitude: 2.1,
                    pitchOscillation: 0.75, yawOscillation: 0.12,
                    misalignment: Angle.degrees(-75), tilt: Angle.degrees(80)
                )
            case .bag:
                return Signature(
                    verticalAmplitude: 3.0, forwardAmplitude: 1.5, lateralAmplitude: 1.1,
                    pitchOscillation: 0.20, yawOscillation: 0.15,
                    misalignment: Angle.degrees(140), tilt: Angle.degrees(60)
                )
            case .calling:
                return Signature(
                    verticalAmplitude: 3.1, forwardAmplitude: 1.1, lateralAmplitude: 1.4,
                    pitchOscillation: 0.05, yawOscillation: 0.05,
                    misalignment: Angle.degrees(60), tilt: Angle.degrees(85)
                )
            }
        }
    }

    public struct Configuration: Sendable {
        /// Ground-truth path in map coordinates.
        public var path: [Point2D] = [Point2D(x: 0, y: 0), Point2D(x: 100, y: 0)]
        public var mode: CarriageMode = .handheldSteady
        /// True step length, metres.
        public var stepLength: Double = 0.72
        /// Step frequency, Hz.
        public var cadence: Double = 1.8
        public var sampleRate: Double = 50
        /// Rotation from the map frame to the sensor reference frame, radians.
        public var referenceOffset: Double = 0

        /// Whether the platform supplies a fused attitude. Turning this off
        /// forces the gyro-integration path, which is what happens on a device
        /// whose magnetometer never calibrates.
        public var providesAttitude: Bool = true
        /// Yaw error injected into the reported attitude, rad/s. Stands in for
        /// the platform's own fusion drift.
        public var attitudeDriftRate: Double = 0
        /// Bias on the reported gyro, rad/s. Only bites on the no-attitude path.
        public var gyroBias: Vector3 = .zero

        public var accelerometerNoise: Double = 0.05      // m/s²
        public var gyroscopeNoise: Double = 0.005         // rad/s
        public var magnetometerNoise: Double = 0.3        // µT

        /// Whether to emit a magnetic field at all.
        public var providesMagnetometer: Bool = true
        /// Horizontal field strength, µT, and dip angle, radians.
        public var magneticFieldStrength: Double = 48
        public var magneticDip: Double = Angle.degrees(50)
        /// A circular zone of magnetic distortion — a lift shaft, a steel
        /// door frame, a rack of servers on the other side of the wall.
        public struct MagneticDisturbance: Sendable {
            public var centre: Point2D
            public var radius: Double
            /// Heading error injected inside the zone, radians.
            public var error: Double

            public init(centre: Point2D, radius: Double, error: Double) {
                self.centre = centre
                self.radius = radius
                self.error = error
            }
        }

        public var magneticDisturbances: [MagneticDisturbance] = []

        public var seed: UInt64 = 0x5EED

        public init() {}
        public static let `default` = Configuration()
    }

    /// A generated walk plus the ground truth to score it against.
    public struct Result {
        public var samples: [MotionSample]
        /// True position at each step, in order.
        public var truthPositions: [Point2D]
        public var truthDistance: Double
        public var trueStepCount: Int
        public var configuration: Configuration
    }

    public init() {}

    public static func generate(_ configuration: Configuration = .default) -> Result {
        precondition(configuration.path.count >= 2, "a walk needs at least two waypoints")
        precondition(configuration.stepLength > 0 && configuration.cadence > 0)

        var generator = SeededGenerator(seed: configuration.seed)
        let signature = Signature.signature(for: configuration.mode)

        // Ground truth: walk the polyline one step at a time.
        var truthPositions: [Point2D] = []
        var truthHeadings: [Double] = []
        var segmentIndex = 0
        var position = configuration.path[0]
        var travelled = 0.0

        while segmentIndex < configuration.path.count - 1 {
            let target = configuration.path[segmentIndex + 1]
            let toTarget = target - position
            let remaining = toTarget.magnitude
            if remaining < configuration.stepLength {
                segmentIndex += 1
                if segmentIndex < configuration.path.count - 1 {
                    position = configuration.path[segmentIndex]
                }
                continue
            }
            let heading = toTarget.angle
            position = position + Vector2.unit(angle: heading) * configuration.stepLength
            travelled += configuration.stepLength
            truthPositions.append(position)
            truthHeadings.append(heading)
        }

        guard !truthPositions.isEmpty else {
            return Result(
                samples: [], truthPositions: [], truthDistance: 0,
                trueStepCount: 0, configuration: configuration
            )
        }

        // Sensor stream. Steps are evenly spaced in time at the configured
        // cadence; the walker's pose is interpolated between step positions.
        let stepPeriod = 1.0 / configuration.cadence
        let duration = stepPeriod * Double(truthPositions.count)
        let dt = 1.0 / configuration.sampleRate
        let sampleCount = Int(duration / dt)

        var samples: [MotionSample] = []
        samples.reserveCapacity(sampleCount)
        var previousAttitude: Quaternion?
        var previousTime: TimeInterval = 0

        for index in 0..<sampleCount {
            let time = Double(index) * dt
            let phase = 2 * Double.pi * configuration.cadence * time

            let stepIndex = min(truthPositions.count - 1, Int(time / stepPeriod))
            let truth = truthPositions[stepIndex]
            // Everything below is built in the *reference* frame, which is the
            // map frame rotated by `referenceOffset` — the same convention
            // `IndoorMap.headingOffset` uses, so a map configured with the same
            // offset reads this stream correctly.
            let walkHeading = truthHeadings[stepIndex] - configuration.referenceOffset

            // Body-frame gait, then rotated into the reference frame.
            let forward = signature.forwardAmplitude * cos(phase)
            let lateral = signature.lateralAmplitude * sin(phase / 2)
            let vertical = signature.verticalAmplitude * sin(phase)

            let forwardAxis = Vector2.unit(angle: walkHeading)
            let leftAxis = Vector2.unit(angle: walkHeading + .pi / 2)
            let worldAcceleration = Vector3(
                forward * forwardAxis.x + lateral * leftAxis.x,
                forward * forwardAxis.y + lateral * leftAxis.y,
                vertical
            )

            // Device orientation: yaw to the walking direction plus the fixed
            // carriage misalignment plus a per-step wobble, then tilt.
            let yaw = walkHeading + signature.misalignment
                + signature.yawOscillation * sin(phase)
            let pitch = signature.tilt + signature.pitchOscillation * sin(phase)

            // Device -> reference. Tilt about the device's own X axis first,
            // then yaw about the world vertical.
            let yawRotation = Quaternion(axis: Vector3(0, 0, 1), angle: yaw)
            let tiltRotation = Quaternion(axis: Vector3(1, 0, 0), angle: pitch)
            let attitude = (yawRotation * tiltRotation).normalized()

            let userAcceleration = attitude.inverseRotate(worldAcceleration)
            let gravity = attitude.inverseRotate(Vector3(0, 0, -standardGravity))

            // Angular rate from the change in attitude, which keeps the gyro
            // exactly consistent with the orientation the accelerometer sees.
            var rotationRate = Vector3.zero
            if let previous = previousAttitude, time > previousTime {
                let delta = previous.conjugate * attitude
                let sign: Double = delta.w < 0 ? -1 : 1
                let step = time - previousTime
                rotationRate = Vector3(delta.x, delta.y, delta.z) * (2 * sign / step)
            }
            rotationRate = rotationRate + configuration.gyroBias

            var reportedAttitude: Quaternion?
            if configuration.providesAttitude {
                let drift = configuration.attitudeDriftRate * time
                reportedAttitude = (Quaternion(axis: Vector3(0, 0, 1), angle: drift) * attitude)
                    .normalized()
            }

            var magneticField: Vector3?
            if configuration.providesMagnetometer {
                var disturbance = 0.0
                var strengthScale = 1.0
                for zone in configuration.magneticDisturbances
                where truth.distance(to: zone.centre) <= zone.radius {
                    disturbance += zone.error
                    strengthScale *= 1.6
                }
                // Reference +X is magnetic north by construction, so the map's
                // north is rotated by `referenceOffset`.
                let northInReference = Vector2.unit(angle: disturbance)
                let horizontal = configuration.magneticFieldStrength * cos(configuration.magneticDip)
                let verticalField = configuration.magneticFieldStrength * sin(configuration.magneticDip)
                let worldField = Vector3(
                    horizontal * northInReference.x,
                    horizontal * northInReference.y,
                    -verticalField
                ) * strengthScale
                magneticField = attitude.inverseRotate(worldField)
                    + Vector3(
                        generator.nextGaussian(standardDeviation: configuration.magnetometerNoise),
                        generator.nextGaussian(standardDeviation: configuration.magnetometerNoise),
                        generator.nextGaussian(standardDeviation: configuration.magnetometerNoise)
                    )
            }

            let accelerationNoise = Vector3(
                generator.nextGaussian(standardDeviation: configuration.accelerometerNoise),
                generator.nextGaussian(standardDeviation: configuration.accelerometerNoise),
                generator.nextGaussian(standardDeviation: configuration.accelerometerNoise)
            )
            let gyroNoise = Vector3(
                generator.nextGaussian(standardDeviation: configuration.gyroscopeNoise),
                generator.nextGaussian(standardDeviation: configuration.gyroscopeNoise),
                generator.nextGaussian(standardDeviation: configuration.gyroscopeNoise)
            )

            samples.append(
                MotionSample(
                    timestamp: time,
                    userAcceleration: userAcceleration + accelerationNoise,
                    gravity: gravity,
                    rotationRate: rotationRate + gyroNoise,
                    attitude: reportedAttitude,
                    magneticField: magneticField,
                    magneticFieldAccuracy: configuration.providesMagnetometer ? 0 : nil
                )
            )

            previousAttitude = attitude
            previousTime = time
        }

        return Result(
            samples: samples,
            truthPositions: truthPositions,
            truthDistance: travelled,
            trueStepCount: truthPositions.count,
            configuration: configuration
        )
    }
}

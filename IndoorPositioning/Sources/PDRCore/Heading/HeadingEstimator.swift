//
//  HeadingEstimator.swift
//  PDRCore
//

import Foundation

/// Where the current heading estimate came from. Worth surfacing: the
/// accuracy you can promise the user differs by an order of magnitude between
/// these.
public enum HeadingSource: String, Sendable, Codable {
    /// Platform sensor fusion referenced to magnetic north. Best case.
    case fusedAttitude
    /// Platform attitude with an arbitrary reference X axis, anchored by the
    /// map entry heading. Drifts as slowly as the platform's fusion does.
    case relativeAttitude
    /// Our own gyro integration, corrected by a gated magnetometer.
    case gyroscopeAndMagnetometer
    /// Gyro integration alone. Drifts monotonically; needs an anchor.
    case gyroscopeOnly
    case unavailable
}

/// Tracks the heading of the *device* (specifically of the horizontal basis
/// vector `e1`) in the reference frame.
///
/// This is deliberately separate from the walking direction. The device points
/// where the user happens to hold it; the body goes where the corridor goes.
/// Conflating the two is the single most common way an otherwise correct PDR
/// implementation ends up 90° wrong.
///
/// Heading is also where PDR actually fails. Stride error is ~5 % of distance
/// and grows gently; heading error is unbounded, self-reinforcing, and lateral
/// — 5° held over 50 m puts you 4.4 m sideways, and nothing in the dead
/// reckoning will ever pull it back. That is what the map constraint is for.
public struct HeadingEstimator {
    public struct Configuration: Sendable {
        /// Weight given to the magnetometer per second of clean readings.
        /// Small on purpose: indoors, a wrong magnetic heading is common and a
        /// fast pull towards it is worse than gyro drift.
        public var magnetometerGainPerSecond: Double = 0.05
        /// Below this angular rate and acceleration spread the device counts as
        /// still, and the gyro's output is bias.
        public var stationaryRotationRate: Double = 0.06     // rad/s
        public var stationaryAccelerationSigma: Double = 0.25 // m/s²
        /// Time constant of the gyro bias estimate while stationary.
        public var biasLearningTimeConstant: Double = 8.0
        /// Cap on the learned bias; anything larger is a broken sensor, not a bias.
        public var maximumGyroBias: Double = Angle.degrees(5)  // rad/s
        /// Assumed 1-sigma heading error growth while running on gyro alone.
        public var gyroDriftPerSecond: Double = Angle.degrees(0.15)
        /// Floor on reported heading uncertainty.
        public var minimumUncertainty: Double = Angle.degrees(2)
        public var maximumUncertainty: Double = Angle.degrees(90)

        public var magnetometer = MagnetometerGate.Configuration.default

        public init() {}
        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private var gate: MagnetometerGate
    private var accelerationStats: SlidingWindowStats

    private var lastTimestamp: TimeInterval?
    private var integratedHeading: Double = 0
    private var gyroBias: Double = 0

    /// Heading of `e1` in the reference frame, radians CCW from reference +X.
    public private(set) var deviceHeading: Double = 0
    /// 1-sigma uncertainty on `deviceHeading`, radians.
    public private(set) var uncertainty: Double = Angle.degrees(45)
    public private(set) var source: HeadingSource = .unavailable
    /// True while the device is not moving — the moment to trust a gyro bias
    /// estimate, and the moment to stop believing PCA.
    public private(set) var isStationary = false
    /// Whether the platform's own attitude is currently driving the estimate.
    public private(set) var usesPlatformAttitude = false

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        self.gate = MagnetometerGate(configuration: configuration.magnetometer)
        self.accelerationStats = SlidingWindowStats(window: 1.0)
    }

    public mutating func reset() {
        gate.reset()
        accelerationStats.reset()
        lastTimestamp = nil
        integratedHeading = 0
        gyroBias = 0
        usesPlatformAttitude = false
        deviceHeading = 0
        uncertainty = Angle.degrees(45)
        source = .unavailable
        isStationary = false
    }

    /// Anchors the integrated heading to a known value — used at the map entry
    /// point and after an anchor marker is scanned.
    public mutating func anchor(deviceHeading heading: Double, uncertainty sigma: Double) {
        integratedHeading = Angle.wrapToPi(heading)
        deviceHeading = integratedHeading
        self.uncertainty = max(configuration.minimumUncertainty, sigma)
    }

    public mutating func process(_ sample: MotionSample) {
        let time = sample.timestamp
        let dt: Double
        if let previous = lastTimestamp {
            dt = time - previous
        } else {
            dt = 0
        }
        lastTimestamp = time
        guard dt >= 0, dt < 1.0 else { return }

        accelerationStats.add(sample.userAcceleration.magnitude, at: time)
        let rotationMagnitude = sample.rotationRate.magnitude
        isStationary = accelerationStats.isSaturated
            && accelerationStats.standardDeviation < configuration.stationaryAccelerationSigma
            && rotationMagnitude < configuration.stationaryRotationRate

        // Always run the integration, even when the platform gives us an
        // attitude: it keeps the gyro bias estimate warm, so a mid-walk loss of
        // attitude does not start from zero.
        integrate(sample, dt: dt)
        let magneticReading = gate.process(sample)

        if let attitudeHeading = sample.referenceHeadingOfBasis {
            usesPlatformAttitude = true
            deviceHeading = attitudeHeading
            // Re-anchor the integrator so it can take over seamlessly.
            integratedHeading = attitudeHeading
            source = gate.isOpen ? .fusedAttitude : .relativeAttitude
            uncertainty = gate.isOpen
                ? configuration.minimumUncertainty
                : min(configuration.maximumUncertainty,
                      uncertainty + configuration.gyroDriftPerSecond * dt * 0.25)
            return
        }

        usesPlatformAttitude = false
        if let reading = magneticReading, reading.isTrusted {
            let gain = min(1, configuration.magnetometerGainPerSecond * dt)
            integratedHeading = Angle.wrapToPi(
                integratedHeading + gain * Angle.delta(from: integratedHeading, to: reading.heading)
            )
            source = .gyroscopeAndMagnetometer
            uncertainty = max(
                configuration.minimumUncertainty,
                uncertainty - gain * (uncertainty - Angle.degrees(8))
            )
        } else {
            source = .gyroscopeOnly
            uncertainty = min(
                configuration.maximumUncertainty,
                uncertainty + configuration.gyroDriftPerSecond * dt
            )
        }
        deviceHeading = integratedHeading
    }

    private mutating func integrate(_ sample: MotionSample, dt: Double) {
        guard dt > 0 else { return }
        let yawRate = sample.yawRate

        if isStationary {
            // Anything the gyro reports while the phone is still is bias.
            let alpha = dt / (configuration.biasLearningTimeConstant + dt)
            let updated = gyroBias + alpha * (yawRate - gyroBias)
            gyroBias = min(configuration.maximumGyroBias,
                           max(-configuration.maximumGyroBias, updated))
        }

        integratedHeading = Angle.wrapToPi(integratedHeading + (yawRate - gyroBias) * dt)
    }
}

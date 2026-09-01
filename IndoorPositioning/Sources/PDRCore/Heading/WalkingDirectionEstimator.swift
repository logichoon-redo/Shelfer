//
//  WalkingDirectionEstimator.swift
//  PDRCore
//

import Foundation

/// The offset between where the phone points and where the body is going.
public struct WalkingDirectionEstimate: Sendable, Equatable {
    /// Angle from the device's horizontal basis vector `e1` to the direction of
    /// travel, radians CCW. Add this to the device heading to get the walking
    /// heading.
    public var misalignment: Double
    /// 0…1. Driven by how elongated the horizontal acceleration cloud is: a
    /// circular cloud carries no direction information at all.
    public var confidence: Double
    /// Whether the forward/backward ambiguity has been resolved, as opposed to
    /// merely assumed.
    public var isSignResolved: Bool

    public init(misalignment: Double, confidence: Double, isSignResolved: Bool) {
        self.misalignment = misalignment
        self.confidence = confidence
        self.isSignResolved = isSignResolved
    }

    public static let unknown = WalkingDirectionEstimate(
        misalignment: 0, confidence: 0, isSignResolved: false
    )
}

/// Recovers the direction of travel from horizontal acceleration by principal
/// component analysis.
///
/// While walking, the body accelerates and decelerates along the direction of
/// travel every step, and only sways along the perpendicular. So the horizontal
/// acceleration cloud is an ellipse whose long axis is the walking axis —
/// regardless of how the phone is held. That is what makes this the standard
/// answer to carriage mode: it estimates the direction of the *body* from a
/// sensor rigidly attached to something else.
///
/// PCA gives an axis, not an arrow. Forward and backward look identical to it.
/// Three things resolve that here, in order of preference: continuity with the
/// previous estimate, an external hint (the map entry heading), and the
/// skewness of the forward-axis projection — braking at heel strike is sharper
/// than push-off, which biases the distribution. The last one is a heuristic,
/// and the map constraint is the real backstop.
public struct WalkingDirectionEstimator {
    public struct Configuration: Sendable {
        /// Analysis window. Needs to span at least two full steps so that the
        /// forward oscillation shows up as an axis and not as a single push.
        public var window: TimeInterval = 2.0
        /// Highest sample count kept in the window (guards against a burst of
        /// samples blowing the buffer).
        public var capacity: Int = 400
        /// Minimum samples before an estimate is produced at all.
        public var minimumSamples: Int = 40
        /// Below this anisotropy the cloud is too round to read a direction from.
        public var minimumAnisotropy: Double = 0.15
        /// Ignore near-zero acceleration: it contributes noise to the
        /// covariance without carrying direction.
        public var minimumSampleMagnitude: Double = 0.15   // m/s²
        /// A new estimate more than this far from the previous one is treated
        /// as the mirror solution rather than as a real turn.
        public var continuityWindow: Double = Angle.degrees(90)
        /// Smoothing applied to the accepted misalignment, 0…1 per update.
        public var smoothing: Double = 0.25

        public init() {}
        public static let `default` = Configuration()
    }

    private struct Sample {
        let time: TimeInterval
        let horizontal: Vector2
        let vertical: Double
    }

    private let configuration: Configuration
    private var samples: [Sample] = []
    private var previousMisalignment: Double?
    private var externalHint: Double?

    public private(set) var estimate: WalkingDirectionEstimate = .unknown

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        samples.reserveCapacity(configuration.capacity)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        previousMisalignment = nil
        externalHint = nil
        estimate = .unknown
    }

    /// Supplies an external belief about which way is forward, expressed as a
    /// misalignment. Used at the map entry point, where the door tells you
    /// which way the user must be walking.
    public mutating func setForwardHint(misalignment: Double) {
        externalHint = Angle.wrapToPi(misalignment)
    }

    public mutating func process(_ sample: MotionSample) {
        let horizontal = sample.horizontalAccelerationInBasis
        samples.append(
            Sample(time: sample.timestamp, horizontal: horizontal, vertical: sample.verticalAcceleration)
        )

        let cutoff = sample.timestamp - configuration.window
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        if samples.count > configuration.capacity {
            samples.removeFirst(samples.count - configuration.capacity)
        }
    }

    /// Recomputes the estimate. Call this on step events rather than on every
    /// sample: the covariance only changes meaningfully once per footfall, and
    /// this is the expensive part of the pipeline.
    @discardableResult
    public mutating func update(mode: CarriageMode = .unknown) -> WalkingDirectionEstimate {
        let usable = samples.filter { $0.horizontal.magnitude >= configuration.minimumSampleMagnitude }
        guard usable.count >= configuration.minimumSamples else {
            estimate = WalkingDirectionEstimate(
                misalignment: previousMisalignment ?? 0,
                confidence: 0,
                isSignResolved: false
            )
            return estimate
        }

        let count = Double(usable.count)
        var meanX = 0.0
        var meanY = 0.0
        for sample in usable {
            meanX += sample.horizontal.x
            meanY += sample.horizontal.y
        }
        meanX /= count
        meanY /= count

        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for sample in usable {
            let dx = sample.horizontal.x - meanX
            let dy = sample.horizontal.y - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        sxx /= count
        syy /= count
        sxy /= count

        // Closed-form eigen-decomposition of a symmetric 2x2 matrix.
        let trace = sxx + syy
        let discriminant = ((sxx - syy) * (sxx - syy) + 4 * sxy * sxy).squareRoot()
        let major = (trace + discriminant) / 2
        let minor = (trace - discriminant) / 2
        guard major > 1e-9 else {
            estimate = WalkingDirectionEstimate(
                misalignment: previousMisalignment ?? 0, confidence: 0, isSignResolved: false
            )
            return estimate
        }

        let anisotropy = (major - minor) / (major + minor)
        var axis = 0.5 * atan2(2 * sxy, sxx - syy)

        var signResolved = false
        if let previous = previousMisalignment {
            // Continuity: pick whichever of `axis` / `axis + pi` is closer to
            // where we were. A real turn is gradual; a sign flip is 180°.
            if Angle.separation(axis, previous) > configuration.continuityWindow {
                axis = Angle.wrapToPi(axis + .pi)
            }
            signResolved = estimate.isSignResolved
        } else if let hint = externalHint {
            if Angle.separation(axis, hint) > .pi / 2 {
                axis = Angle.wrapToPi(axis + .pi)
            }
            signResolved = true
        } else {
            // No history and no hint: fall back on gait asymmetry. Heel strike
            // decelerates the body sharply, push-off accelerates it gently, so
            // the projection onto the forward axis is negatively skewed.
            let direction = Vector2.unit(angle: axis)
            var thirdMoment = 0.0
            var secondMoment = 0.0
            for sample in usable {
                let centred = Vector2(sample.horizontal.x - meanX, sample.horizontal.y - meanY)
                let projection = centred.dot(direction)
                secondMoment += projection * projection
                thirdMoment += projection * projection * projection
            }
            if secondMoment > 1e-9 {
                let skewness = (thirdMoment / count) / pow(secondMoment / count, 1.5)
                if skewness > 0 { axis = Angle.wrapToPi(axis + .pi) }
                // Weak evidence: enough to pick a side, not enough to call it
                // resolved. The particle filter is told to keep both options
                // alive until the corridor geometry rules one out.
                signResolved = abs(skewness) > 0.35
            }
        }

        let confidence = min(1, max(0, (anisotropy - configuration.minimumAnisotropy)
                                        / (1 - configuration.minimumAnisotropy)))
            * mode.walkingDirectionReliability

        let smoothed: Double
        if let previous = previousMisalignment {
            smoothed = Angle.wrapToPi(
                previous + configuration.smoothing * Angle.delta(from: previous, to: axis)
            )
        } else {
            smoothed = axis
        }
        previousMisalignment = smoothed

        estimate = WalkingDirectionEstimate(
            misalignment: smoothed,
            confidence: confidence,
            isSignResolved: signResolved
        )
        return estimate
    }
}

//
//  CarriageMode.swift
//  PDRCore
//

import Foundation

/// How the phone is being carried.
///
/// This is the trap that quietly ruins field results. Hand, pocket, bag, and
/// "held up to the ear" produce different acceleration amplitudes (so different
/// step lengths from the same model) and, worse, different relationships
/// between where the phone points and where the body is going.
public enum CarriageMode: String, Sendable, Codable, CaseIterable {
    /// Not walking.
    case stationary
    /// Held in front, screen up, roughly steady — reading or navigating.
    case handheldSteady
    /// In a hand at the side, swinging with the stride.
    case handheldSwinging
    /// Trouser pocket: large amplitudes, strong thigh rotation.
    case pocket
    /// Bag or backpack: damped, less rotation than a pocket.
    case bag
    /// Against the head.
    case calling
    /// Walking, but the features do not match any template.
    case unknown

    public var isWalking: Bool { self != .stationary }

    /// Whether horizontal-plane PCA can be trusted to recover the walking
    /// direction for this mode.
    ///
    /// Swinging arms inject a large periodic horizontal component along the
    /// swing axis, which competes with the true forward axis; pocket carriage
    /// is dominated by thigh rotation. In both cases the map constraint has to
    /// carry more of the load.
    public var walkingDirectionReliability: Double {
        switch self {
        case .handheldSteady: return 1.0
        case .calling: return 0.8
        case .bag: return 0.6
        case .pocket: return 0.45
        case .handheldSwinging: return 0.4
        case .unknown: return 0.5
        case .stationary: return 0.0
        }
    }
}

/// Raw features behind a carriage-mode decision.
///
/// Exposed deliberately: the thresholds below are starting points, not
/// findings. Log these next to a known mode and re-fit before trusting the
/// classifier on a new device or a new population.
public struct CarriageFeatures: Sendable, Equatable {
    /// Standard deviation of the filtered acceleration magnitude, m/s².
    public var accelerationStandardDeviation: Double = 0
    /// Vertical energy over total dynamic energy, 0…1.
    public var verticalEnergyRatio: Double = 0
    /// Standard deviation of the angular rate magnitude, rad/s.
    public var rotationStandardDeviation: Double = 0
    /// How much the gravity direction wanders in the device frame, rad.
    /// Near zero for a phone held flat; large for a swinging arm or a pocket.
    public var gravityInstability: Double = 0
    /// Angle between the device's +Z axis (out of the screen) and world up,
    /// rad. Zero when the phone lies flat screen-up, pi/2 when it stands
    /// upright. Separates "flat in the hand" from "held against the ear".
    public var screenTilt: Double = 0

    public init() {}
}

/// Classifies carriage mode from a rolling window of motion samples.
///
/// A transparent rule set rather than a learned model: with no labelled data
/// yet, a rule you can read and re-tune beats a black box you cannot.
/// Hysteresis keeps the mode from flapping between two neighbours mid-corridor.
public struct CarriageModeClassifier {
    public struct Configuration: Sendable {
        public var window: TimeInterval = 2.0
        /// Below this acceleration spread the user is standing still.
        public var stationaryAccelerationSigma: Double = 0.30
        /// Above this gravity wander the phone is moving relative to the torso.
        public var unstableGravityThreshold: Double = 0.20
        /// Pocket carriage shows both large amplitude and strong rotation.
        /// The amplitude bar sits above what a swinging arm produces, because
        /// the two otherwise look alike and confusing them costs a stride gain.
        public var pocketAccelerationSigma: Double = 3.2
        public var pocketRotationSigma: Double = 1.1
        /// Arm swing rotates a lot without the amplitude of a pocket.
        public var swingRotationSigma: Double = 0.7
        /// Screen tilt above which a steady phone reads as held to the ear.
        public var callingScreenTilt: Double = Angle.degrees(65)
        /// Consecutive windows a new mode must win before it is adopted.
        public var switchHysteresis: Int = 2

        public init() {}
        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private var accelerationStats: SlidingWindowStats
    private var verticalStats: SlidingWindowStats
    private var horizontalStats: SlidingWindowStats
    private var rotationStats: SlidingWindowStats
    private var gravityXStats: SlidingWindowStats
    private var gravityYStats: SlidingWindowStats
    private var gravityZStats: SlidingWindowStats
    private var filter: CascadedLowPass

    private var candidate: CarriageMode = .unknown
    private var candidateStreak = 0
    private var lastTimestamp: TimeInterval?

    /// Current decision. Starts `.unknown` until a full window has been seen.
    public private(set) var mode: CarriageMode = .unknown
    public private(set) var features = CarriageFeatures()

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        let window = configuration.window
        accelerationStats = SlidingWindowStats(window: window)
        verticalStats = SlidingWindowStats(window: window)
        horizontalStats = SlidingWindowStats(window: window)
        rotationStats = SlidingWindowStats(window: window)
        gravityXStats = SlidingWindowStats(window: window)
        gravityYStats = SlidingWindowStats(window: window)
        gravityZStats = SlidingWindowStats(window: window)
        filter = CascadedLowPass(cutoffHz: 5.0)
    }

    public mutating func reset() {
        accelerationStats.reset()
        verticalStats.reset()
        horizontalStats.reset()
        rotationStats.reset()
        gravityXStats.reset()
        gravityYStats.reset()
        gravityZStats.reset()
        filter.reset()
        candidate = .unknown
        candidateStreak = 0
        mode = .unknown
        features = CarriageFeatures()
        lastTimestamp = nil
    }

    @discardableResult
    public mutating func process(_ sample: MotionSample) -> CarriageMode {
        let time = sample.timestamp
        let dt = lastTimestamp.map { time - $0 } ?? 0
        lastTimestamp = time
        guard dt >= 0, dt < 1.0 else { return mode }

        let filtered = filter.update(sample.accelerationMagnitude, dt: dt)
        accelerationStats.add(filtered, at: time)

        let vertical = sample.verticalAcceleration
        verticalStats.add(vertical, at: time)
        horizontalStats.add(sample.horizontalAcceleration.magnitude, at: time)
        rotationStats.add(sample.rotationRate.magnitude, at: time)

        let gravityUnit = sample.gravity.normalized()
        gravityXStats.add(gravityUnit.x, at: time)
        gravityYStats.add(gravityUnit.y, at: time)
        gravityZStats.add(gravityUnit.z, at: time)

        guard accelerationStats.isSaturated else { return mode }

        features.accelerationStandardDeviation = accelerationStats.standardDeviation
        features.rotationStandardDeviation = rotationStats.standardDeviation

        let verticalEnergy = verticalStats.variance
        let horizontalEnergy = horizontalStats.variance
        let totalEnergy = verticalEnergy + horizontalEnergy
        features.verticalEnergyRatio = totalEnergy > 1e-9 ? verticalEnergy / totalEnergy : 0

        // Spread of the unit gravity vector doubles as an angular spread: for
        // small wander, chord length and arc length agree to within a percent.
        let gravitySpread = (
            gravityXStats.variance + gravityYStats.variance + gravityZStats.variance
        ).squareRoot()
        features.gravityInstability = gravitySpread
        features.screenTilt = acos(min(1, max(-1, -gravityUnit.z)))

        adopt(classify(features))
        return mode
    }

    private func classify(_ f: CarriageFeatures) -> CarriageMode {
        if f.accelerationStandardDeviation < configuration.stationaryAccelerationSigma {
            return .stationary
        }
        if f.accelerationStandardDeviation > configuration.pocketAccelerationSigma,
           f.rotationStandardDeviation > configuration.pocketRotationSigma,
           f.gravityInstability > configuration.unstableGravityThreshold {
            return .pocket
        }
        if f.rotationStandardDeviation > configuration.swingRotationSigma,
           f.gravityInstability > configuration.unstableGravityThreshold {
            return .handheldSwinging
        }
        if f.gravityInstability <= configuration.unstableGravityThreshold {
            // Steady relative to the torso. Which of the two steady modes it is
            // comes down to how the phone is tilted.
            return f.screenTilt > configuration.callingScreenTilt ? .calling : .handheldSteady
        }
        // Wandering relative to the torso but without a pocket's amplitude or
        // an arm swing's rotation: carried in a bag, or an unusually loose grip.
        if f.accelerationStandardDeviation > configuration.stationaryAccelerationSigma * 3 {
            return .bag
        }
        return .unknown
    }

    private mutating func adopt(_ proposed: CarriageMode) {
        guard proposed != mode else {
            candidate = mode
            candidateStreak = 0
            return
        }
        if proposed == candidate {
            candidateStreak += 1
        } else {
            candidate = proposed
            candidateStreak = 1
        }
        // A stationary call is safe to act on immediately; the cost of a false
        // "stopped" is one skipped step, versus a mis-scaled stride for the
        // rest of the corridor.
        if candidateStreak >= configuration.switchHysteresis || proposed == .stationary {
            mode = proposed
            candidateStreak = 0
        }
    }
}

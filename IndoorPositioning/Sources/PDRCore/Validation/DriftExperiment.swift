//
//  DriftExperiment.swift
//  PDRCore
//

import Foundation

/// The outcome of one measured walk.
public struct DriftExperimentResult: Sendable {
    public var label: String
    /// Ground-truth distance between start and end, metres.
    public var truthDistance: Double
    public var truthDisplacement: Double
    public var stepCount: Int
    /// Distance the step-length model thinks was walked.
    public var estimatedDistance: Double
    /// Signed relative error of the step-length model, e.g. -0.07 for 7 % short.
    public var stepLengthError: Double

    /// Final error of pure dead reckoning — no map, no filter.
    public var deadReckoningError: Double
    /// Component of that error perpendicular to the true path. This is the
    /// heading error made visible: heading pushes you sideways.
    public var deadReckoningLateralError: Double
    /// Component along the true path — almost entirely stride-model error.
    public var deadReckoningAlongTrackError: Double

    /// Final error with the map constraint applied. `nil` when run without a map.
    public var constrainedError: Double?

    public var carriageMode: CarriageMode
    public var headingSource: HeadingSource
    /// Times the particle filter lost every hypothesis and had to respawn.
    public var recoveryCount: Int

    /// Dead-reckoning error per metre walked.
    ///
    /// The number that matters: because steps are counted rather than
    /// integrated, this is roughly constant instead of growing with time.
    public var errorPerMetre: Double {
        truthDistance > 0 ? deadReckoningError / truthDistance : 0
    }

    /// How far you can walk on dead reckoning alone before exceeding
    /// `tolerance` metres of error — that is, how far apart the reset markers
    /// have to be.
    public func anchorSpacing(tolerance: Double) -> Double {
        let rate = errorPerMetre
        guard rate > 1e-6 else { return .infinity }
        return tolerance / rate
    }

    /// Equivalent constant heading error, in radians, that would produce the
    /// observed lateral drift. Useful for sanity-checking against the gyro and
    /// magnetometer specs.
    public var impliedHeadingError: Double {
        guard truthDistance > 0 else { return 0 }
        return asin(min(1, max(-1, deadReckoningLateralError / truthDistance)))
    }
}

/// Runs the two measurements that decide whether this approach is viable, and
/// how much marker infrastructure it needs.
///
/// 1. **Pure PDR drift over a straight 100 m.** How far off you are with no map
///    help at all. Five to ten metres is the expected band. Whatever it turns
///    out to be, `anchorSpacing(tolerance:)` converts it straight into "put a
///    marker every N metres", which is the same thing as "print this many QR
///    codes".
/// 2. **Hand versus pocket.** The same corridor walked twice. If the two
///    results differ materially, a carriage-mode classifier is not a nice-to-
///    have, it is in the MVP.
///
/// Feed it real recordings. Synthetic input exercises the code, not the
/// physics — see the warning on `SyntheticWalk`.
public enum DriftExperiment {
    public struct Setup {
        public var label: String
        public var samples: [MotionSample]
        /// Surveyed start point, map frame.
        public var truthStart: Point2D
        /// Surveyed end point, map frame.
        public var truthEnd: Point2D
        /// Heading the user is known to have started with, map frame.
        public var truthStartHeading: Double
        /// Path length actually walked. Defaults to the straight-line
        /// displacement, which is right for the straight-corridor test.
        public var truthPathLength: Double?
        /// Map for the constrained run. `nil` runs dead reckoning only.
        public var map: IndoorMap?
        public var configuration: PDREngine.Configuration
        public var seed: UInt64

        public init(
            label: String,
            samples: [MotionSample],
            truthStart: Point2D,
            truthEnd: Point2D,
            truthStartHeading: Double,
            truthPathLength: Double? = nil,
            map: IndoorMap? = nil,
            configuration: PDREngine.Configuration = .default,
            seed: UInt64 = 0xC0FFEE
        ) {
            self.label = label
            self.samples = samples
            self.truthStart = truthStart
            self.truthEnd = truthEnd
            self.truthStartHeading = truthStartHeading
            self.truthPathLength = truthPathLength
            self.map = map
            self.configuration = configuration
            self.seed = seed
        }
    }

    public static func run(_ setup: Setup) -> DriftExperimentResult {
        let engine = PDREngine(
            map: setup.map,
            configuration: setup.configuration,
            seed: setup.seed
        )
        engine.start(
            position: setup.truthStart,
            heading: setup.truthStartHeading,
            positionSigma: 0.5,
            headingSigma: Angle.degrees(10)
        )

        var lastFix: PositionFix?
        for sample in setup.samples {
            if let fix = engine.process(sample) { lastFix = fix }
        }
        let recoveries = engine.filterRecoveryCount

        let displacement = setup.truthStart.distance(to: setup.truthEnd)
        let pathLength = setup.truthPathLength ?? displacement

        guard let fix = lastFix else {
            return DriftExperimentResult(
                label: setup.label,
                truthDistance: pathLength,
                truthDisplacement: displacement,
                stepCount: 0,
                estimatedDistance: 0,
                stepLengthError: -1,
                deadReckoningError: displacement,
                deadReckoningLateralError: 0,
                deadReckoningAlongTrackError: displacement,
                constrainedError: setup.map == nil ? nil : displacement,
                carriageMode: .unknown,
                headingSource: .unavailable,
                recoveryCount: recoveries
            )
        }

        // Decompose the dead-reckoning error along and across the true path.
        // Splitting it this way separates the two error sources: along-track is
        // the stride model, across-track is heading.
        let pathAxis = (setup.truthEnd - setup.truthStart).normalized()
        let error = fix.deadReckoningPosition - setup.truthEnd
        let alongTrack = pathAxis.magnitude > 0 ? error.dot(pathAxis) : error.magnitude
        let lateral = pathAxis.magnitude > 0 ? pathAxis.cross(error) : 0

        return DriftExperimentResult(
            label: setup.label,
            truthDistance: pathLength,
            truthDisplacement: displacement,
            stepCount: fix.stepCount,
            estimatedDistance: fix.travelledDistance,
            stepLengthError: pathLength > 0
                ? (fix.travelledDistance - pathLength) / pathLength
                : 0,
            deadReckoningError: error.magnitude,
            deadReckoningLateralError: abs(lateral),
            deadReckoningAlongTrackError: abs(alongTrack),
            constrainedError: setup.map == nil
                ? nil
                : fix.position.distance(to: setup.truthEnd),
            carriageMode: fix.carriageMode,
            headingSource: fix.headingSource,
            recoveryCount: recoveries
        )
    }

    /// Experiment 2: the same corridor, walked with the phone in the hand and
    /// then in a pocket.
    public struct CarriageComparison: Sendable {
        public var hand: DriftExperimentResult
        public var pocket: DriftExperimentResult

        /// Difference in step-length model error between the two modes.
        /// This is the part a per-mode gain can fix.
        public var stepLengthGap: Double {
            abs(hand.stepLengthError - pocket.stepLengthError)
        }

        /// Ratio of pocket position error to hand position error.
        public var positionErrorRatio: Double {
            hand.deadReckoningError > 1e-6
                ? pocket.deadReckoningError / hand.deadReckoningError
                : .infinity
        }

        /// Whether carriage mode has to be handled in the MVP.
        ///
        /// The thresholds encode a judgement: an 8 % stride gap is roughly the
        /// whole error budget of a calibrated stride model, and a 50 % worse
        /// position means the pocket case is a different problem, not a noisier
        /// version of the same one.
        public var requiresClassifierInMVP: Bool {
            stepLengthGap > 0.08 || positionErrorRatio > 1.5
        }

        public var summary: String {
            var lines: [String] = []
            lines.append("Carriage-mode comparison")
            lines.append("  hand   : \(format(hand))")
            lines.append("  pocket : \(format(pocket))")
            lines.append(String(format: "  stride error gap : %.1f %%", stepLengthGap * 100))
            lines.append(String(format: "  position error ratio : %.2fx", positionErrorRatio))
            lines.append(
                requiresClassifierInMVP
                    ? "  => carriage-mode handling belongs in the MVP"
                    : "  => one shared model is good enough for the MVP"
            )
            return lines.joined(separator: "\n")
        }

        private func format(_ result: DriftExperimentResult) -> String {
            String(
                format: "%.1f m error over %.0f m (%.1f %% stride error, %.2f m/m)",
                result.deadReckoningError,
                result.truthDistance,
                result.stepLengthError * 100,
                result.errorPerMetre
            )
        }
    }

    public static func compareCarriage(
        hand: Setup,
        pocket: Setup
    ) -> CarriageComparison {
        CarriageComparison(hand: run(hand), pocket: run(pocket))
    }
}

public extension DriftExperimentResult {
    /// Human-readable report, including the marker-spacing answer.
    func summary(tolerance: Double = 5.0) -> String {
        var lines: [String] = []
        lines.append("[\(label)]")
        lines.append(String(format: "  walked            : %.1f m over %d steps", truthDistance, stepCount))
        lines.append(String(format: "  model distance    : %.1f m (%+.1f %%)", estimatedDistance, stepLengthError * 100))
        lines.append(String(format: "  dead reckoning    : %.2f m final error", deadReckoningError))
        lines.append(String(format: "    along track     : %.2f m  (stride model)", deadReckoningAlongTrackError))
        lines.append(String(format: "    lateral         : %.2f m  (heading)", deadReckoningLateralError))
        lines.append(String(format: "    implied heading : %.1f deg", Angle.toDegrees(impliedHeadingError)))
        if let constrainedError {
            lines.append(String(format: "  map constrained   : %.2f m final error", constrainedError))
            let improvement = deadReckoningError > 1e-6
                ? (1 - constrainedError / deadReckoningError) * 100
                : 0
            lines.append(String(format: "    improvement     : %.0f %%", improvement))
        }
        lines.append(String(format: "  error rate        : %.3f m per m walked", errorPerMetre))
        let spacing = anchorSpacing(tolerance: tolerance)
        if spacing.isFinite {
            lines.append(String(format: "  => reset anchors every %.0f m to hold %.0f m accuracy", spacing, tolerance))
        } else {
            lines.append("  => no measurable drift; check the ground truth before believing this")
        }
        lines.append("  carriage: \(carriageMode.rawValue), heading: \(headingSource.rawValue)")
        return lines.joined(separator: "\n")
    }
}

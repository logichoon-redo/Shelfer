//
//  StepLengthEstimator.swift
//  PDRCore
//

import Foundation

/// Empirical step-length models. None of them integrate anything: each maps a
/// bounded feature of one footfall onto a bounded distance, so their error
/// accumulates in proportion to distance walked rather than to time squared.
public enum StepLengthModel: String, Sendable, Codable, CaseIterable {
    /// Weinberg: `L = K * (a_max - a_min)^(1/4)`. The workhorse. Uses the
    /// vertical bounce of the torso, which scales with stride.
    case weinberg
    /// Kim: `L = K * mean(|a|)^(1/3)`. Less sensitive to a single bad peak.
    case kim
    /// Cadence-linear: `L = slope * f + intercept`. Robust but saturates —
    /// it cannot tell a long slow stride from a short slow one.
    case cadence
    /// Weighted blend of the three. The default, because their failure modes
    /// are different enough to partly cancel.
    case blended
}

/// Turns a `StepEvent` into metres.
///
/// Expect 10–15 % error uncalibrated and around 5 % after a calibration walk.
/// That is the *good* half of the PDR error budget; heading is the bad half.
public struct StepLengthEstimator {
    public struct Configuration: Sendable {
        public var model: StepLengthModel = .blended

        /// Weinberg coefficient, tuned so a typical 8 m/s² peak-to-peak swing
        /// gives ~0.75 m.
        public var weinbergK: Double = 0.45
        /// Kim coefficient for a mean dynamic acceleration around 2 m/s².
        public var kimK: Double = 0.55
        /// Cadence model, `L = slope * f + intercept`, `f` in Hz.
        public var cadenceSlope: Double = 0.26
        public var cadenceIntercept: Double = 0.28

        /// Relative weights used by `.blended`.
        public struct BlendWeights: Sendable {
            public var weinberg: Double
            public var kim: Double
            public var cadence: Double

            public init(weinberg: Double, kim: Double, cadence: Double) {
                self.weinberg = weinberg
                self.kim = kim
                self.cadence = cadence
            }

            public var total: Double { weinberg + kim + cadence }
        }

        public var blendWeights = BlendWeights(weinberg: 0.5, kim: 0.3, cadence: 0.2)

        /// Hard bounds. A step is a bounded event; anything outside this range
        /// is a detector failure, not a very long stride.
        public var minimumStepLength: Double = 0.35
        public var maximumStepLength: Double = 1.00

        /// Optional user height in metres. Stride scales close to linearly with
        /// height, so this is the cheapest calibration available — ask once.
        public var userHeight: Double?
        /// Height the default coefficients were tuned for.
        public var referenceHeight: Double = 1.70

        /// Per-carriage-mode multipliers. Pocket carriage sees larger
        /// accelerations for the same stride, so its gain is below 1.
        /// These are starting points; `calibrate` replaces them with measured
        /// values, which is the entire point of the hand-vs-pocket experiment.
        public var modeGain: [CarriageMode: Double] = [
            .handheldSteady: 1.00,
            .handheldSwinging: 0.95,
            .pocket: 0.88,
            .bag: 0.92,
            .calling: 1.00,
            .unknown: 0.96,
            .stationary: 1.00,
        ]

        /// Bounds on what calibration may do, so one bad reference walk cannot
        /// wreck the model.
        public var minimumCalibrationGain: Double = 0.6
        public var maximumCalibrationGain: Double = 1.6

        public init() {}
        public static let `default` = Configuration()
    }

    public private(set) var configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Height scaling applied on top of the model coefficients.
    private var heightGain: Double {
        guard let height = configuration.userHeight, height > 1.0, height < 2.4 else { return 1 }
        return height / configuration.referenceHeight
    }

    /// Length of one step, in metres, before any map constraint.
    public func length(for step: StepEvent, mode: CarriageMode = .unknown) -> Double {
        let raw: Double
        switch configuration.model {
        case .weinberg:
            raw = weinberg(step)
        case .kim:
            raw = kim(step)
        case .cadence:
            raw = cadence(step)
        case .blended:
            let weights = configuration.blendWeights
            guard weights.total > 0 else { return configuration.minimumStepLength }
            raw = (weights.weinberg * weinberg(step)
                   + weights.kim * kim(step)
                   + weights.cadence * cadence(step)) / weights.total
        }

        let gain = heightGain * (configuration.modeGain[mode] ?? 1.0)
        return min(configuration.maximumStepLength,
                   max(configuration.minimumStepLength, raw * gain))
    }

    private func weinberg(_ step: StepEvent) -> Double {
        // `pow` on a negative base returns NaN; clamp instead of trusting the
        // detector to never hand back an inverted window.
        let range = max(step.accelerationRange, 0.01)
        return configuration.weinbergK * pow(range, 0.25)
    }

    private func kim(_ step: StepEvent) -> Double {
        let mean = max(step.accelerationMean, 0.01)
        return configuration.kimK * pow(mean, 1.0 / 3.0)
    }

    private func cadence(_ step: StepEvent) -> Double {
        // Clamp the frequency to the range the linear fit was made over.
        let f = min(max(step.cadence, 0.5), 3.0)
        return configuration.cadenceSlope * f + configuration.cadenceIntercept
    }

    /// Fits the per-mode gain from a walk of known length.
    ///
    /// Walk a measured straight line — a corridor with a tape measure at both
    /// ends is enough — in the carriage mode you want to calibrate, and pass
    /// the steps this produced. Repeat per mode; the difference between the
    /// resulting gains *is* the answer to "does carriage mode need to be in
    /// the MVP".
    ///
    /// - Returns: the gain that was stored, or `nil` if the walk was too short
    ///   or the correction was implausible enough to be a measurement error.
    @discardableResult
    public mutating func calibrate(
        knownDistance: Double,
        steps: [StepEvent],
        mode: CarriageMode
    ) -> Double? {
        guard knownDistance > 0, steps.count >= 10 else { return nil }

        let currentGain = configuration.modeGain[mode] ?? 1.0
        let predicted = steps.reduce(0.0) { $0 + length(for: $1, mode: mode) }
        guard predicted > 0 else { return nil }

        // `length` clamps, so the correction has to be applied to the gain that
        // produced the clamped total rather than to the raw model output.
        let correction = knownDistance / predicted
        let updated = currentGain * correction
        guard updated >= configuration.minimumCalibrationGain,
              updated <= configuration.maximumCalibrationGain else { return nil }

        configuration.modeGain[mode] = updated
        return updated
    }

    /// Percentage error of the model against a known distance, for reporting.
    public func relativeError(knownDistance: Double, steps: [StepEvent], mode: CarriageMode) -> Double? {
        guard knownDistance > 0, !steps.isEmpty else { return nil }
        let predicted = steps.reduce(0.0) { $0 + length(for: $1, mode: mode) }
        return (predicted - knownDistance) / knownDistance
    }
}

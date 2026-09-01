//
//  PDREngine.swift
//  PDRCore
//

import Foundation

/// A position estimate, in map coordinates.
public struct PositionFix: Sendable, Equatable {
    public var timestamp: TimeInterval
    /// Best estimate after the map constraint, metres in the map frame.
    public var position: Point2D
    /// Direction of travel in the map frame, radians CCW from map +X.
    public var heading: Double
    /// 1-sigma horizontal accuracy, metres.
    public var horizontalAccuracy: Double
    /// Pure dead-reckoning position, no map involved.
    ///
    /// Kept alongside the constrained estimate on purpose: the gap between the
    /// two is the map's contribution, and it is the number the field
    /// experiments need. Without it you cannot tell a well-behaved filter from
    /// one that has locked onto the wrong corridor.
    public var deadReckoningPosition: Point2D
    public var stepCount: Int
    /// Distance walked according to the step-length model, metres.
    public var travelledDistance: Double
    public var carriageMode: CarriageMode
    public var headingSource: HeadingSource
    /// Filter has not settled on a single hypothesis yet.
    public var isAmbiguous: Bool
    /// Estimated heading error the filter has absorbed, radians.
    public var headingCorrection: Double
    /// Stride scale the filter has settled on, relative to the model.
    public var stepScale: Double
}

/// Step-counting pedestrian dead reckoning, constrained by a floor plan.
///
/// The whole design turns on one decision: **never integrate acceleration.**
///
/// Double integration makes position error grow as ½·b·t², and the dominant
/// `b` is not accelerometer bias but attitude error. Removing gravity from a
/// horizontal axis requires knowing which way is down to a fraction of a
/// degree; at 1° of error, 9.81·sin(1°) ≈ 0.17 m/s² of gravity leaks in, which
/// is larger than the horizontal acceleration of walking itself. Ten seconds
/// later that is 8.6 m of error. Phone-grade MEMS cannot close that gap — it is
/// why strapdown inertial navigation runs on IMUs that cost more than a car.
///
/// So walking is treated as what it physically is: a sequence of discrete,
/// bounded events. Each footfall is detected, assigned a length of 0.6–0.8 m
/// from an empirical model, and added as a vector. Error then grows linearly
/// with distance rather than quadratically with time.
///
/// That leaves heading as the weak point, and heading is where the floor plan
/// earns its place. In a corridor network, direction of travel is not a free
/// variable — it is one of a few corridor axes. The particle filter enforces
/// that, plus the hard constraint that people do not walk through walls. The
/// two halves — bounded step displacement and discretised heading — are one
/// system, not two ideas.
///
/// What it still cannot do: recover accuracy on its own. Error only ever grows
/// between resets. `observeAnchor(id:)` is the reset, and how far apart those
/// anchors have to be is a measurement, not a guess — see `DriftExperiment`.
public final class PDREngine {
    public struct Configuration: Sendable {
        public var stepDetector = StepDetector.Configuration.default
        public var stepLength = StepLengthEstimator.Configuration.default
        public var heading = HeadingEstimator.Configuration.default
        public var walkingDirection = WalkingDirectionEstimator.Configuration.default
        public var carriage = CarriageModeClassifier.Configuration.default
        public var particleFilter = ParticleFilter.Configuration.default

        /// Below this walking-direction confidence, the PCA estimate is not
        /// used and the device heading is taken as the walking heading. That is
        /// wrong whenever the phone is not pointing where the user is going,
        /// so the uncertainty handed to the filter is widened to match.
        public var minimumWalkingDirectionConfidence: Double = 0.25
        /// Heading uncertainty assumed when the walking direction is unusable.
        public var fallbackHeadingUncertainty: Double = Angle.degrees(35)
        /// Ignore steps detected while the classifier says the user is standing.
        public var rejectStepsWhileStationary: Bool = true

        public init() {}
        public static let `default` = Configuration()
    }

    // MARK: - Stored state

    public let configuration: Configuration
    public private(set) var map: IndoorMap?
    public private(set) var mapIndex: MapIndex?

    private var stepDetector: StepDetector
    private var stepLengthEstimator: StepLengthEstimator
    private var headingEstimator: HeadingEstimator
    private var walkingDirection: WalkingDirectionEstimator
    private var carriage: CarriageModeClassifier
    private let filter: ParticleFilter

    private var deadReckoning: Point2D = .zero
    private var deadReckoningHeadingOffset: Double = 0
    private var travelled: Double = 0
    private var steps: [StepEvent] = []
    private var started = false

    /// Called on every confirmed step, on whatever thread feeds `process`.
    public var onFix: ((PositionFix) -> Void)?
    public private(set) var latestFix: PositionFix?

    /// Every step event seen since `start`. Kept for calibration and for the
    /// offline experiments; clear it with `reset()` on a long-running session.
    public var stepEvents: [StepEvent] { steps }

    /// How many times the particle filter lost every hypothesis and respawned.
    /// Anything above zero in the field means the plan, the entry point, or the
    /// heading alignment is wrong — not that the filter needs more particles.
    public var filterRecoveryCount: Int { filter.recoveryCount }

    /// Current walking-direction estimate, for diagnostics and for the
    /// carriage-mode experiment.
    public var walkingDirectionEstimate: WalkingDirectionEstimate { walkingDirection.estimate }

    /// Features behind the current carriage-mode decision.
    public var carriageFeatures: CarriageFeatures { carriage.features }

    public init(
        map: IndoorMap?,
        configuration: Configuration = .default,
        seed: UInt64 = 0xC0FFEE
    ) {
        self.configuration = configuration
        self.map = map
        self.mapIndex = map.map { MapIndex(map: $0) }
        self.stepDetector = StepDetector(configuration: configuration.stepDetector)
        self.stepLengthEstimator = StepLengthEstimator(configuration: configuration.stepLength)
        self.headingEstimator = HeadingEstimator(configuration: configuration.heading)
        self.walkingDirection = WalkingDirectionEstimator(configuration: configuration.walkingDirection)
        self.carriage = CarriageModeClassifier(configuration: configuration.carriage)
        self.filter = ParticleFilter(
            map: mapIndex,
            configuration: configuration.particleFilter,
            seed: seed
        )
    }

    // MARK: - Lifecycle

    /// Starts a session at a known point on the plan.
    ///
    /// Prefer this over `start(position:heading:)`: a door gives you a heading
    /// for free, and heading is the expensive thing to acquire.
    public func start(at entry: MapEntryPoint) {
        start(
            position: entry.position,
            heading: entry.heading,
            positionSigma: entry.positionSigma,
            headingSigma: entry.headingSigma
        )
    }

    public func start(
        position: Point2D,
        heading: Double,
        positionSigma: Double = 1.0,
        headingSigma: Double = Angle.degrees(25)
    ) {
        stepDetector.reset()
        headingEstimator.reset()
        walkingDirection.reset()
        carriage.reset()
        filter.reset()
        steps.removeAll(keepingCapacity: true)
        travelled = 0
        deadReckoning = position
        deadReckoningHeadingOffset = 0
        startPositionSigma = positionSigma
        startHeadingSigma = headingSigma
        started = true

        // At the entry point we know which way the user is walking — they just
        // came through a door — but not how they are holding the phone. Assume
        // it points along travel, which is the usual case, and let the particle
        // filter's heading bias absorb the error when it does not.
        walkingDirection.setForwardHint(misalignment: 0)

        // The real alignment waits for the first step, by which point the
        // walking-direction estimate exists. Seeding it from the very first
        // sample would bake in an assumed misalignment of zero and leave the
        // dead-reckoning track permanently rotated by however the phone was
        // actually being held.
        filter.initialize(
            position: position,
            heading: heading,
            measuredHeading: heading,
            positionSigma: positionSigma,
            headingSigma: headingSigma
        )
        pendingHeadingAnchor = heading
        latestFix = nil
    }

    private var pendingHeadingAnchor: Double?
    private var startPositionSigma: Double = 1.0
    private var startHeadingSigma: Double = Angle.degrees(25)

    public func reset() {
        started = false
        stepDetector.reset()
        headingEstimator.reset()
        walkingDirection.reset()
        carriage.reset()
        filter.reset()
        steps.removeAll(keepingCapacity: true)
        travelled = 0
        latestFix = nil
        pendingHeadingAnchor = nil
    }

    // MARK: - Sensor input

    /// Feeds one IMU sample. Returns a fix on the samples where a step is
    /// confirmed, and `nil` in between.
    @discardableResult
    public func process(_ sample: MotionSample) -> PositionFix? {
        headingEstimator.process(sample)
        carriage.process(sample)
        walkingDirection.process(sample)

        guard let step = stepDetector.process(sample) else { return nil }
        guard started else { return nil }
        if configuration.rejectStepsWhileStationary, carriage.mode == .stationary { return nil }

        return handle(step: step, at: sample.timestamp)
    }

    /// Resets the estimate onto a marker of known position.
    ///
    /// This is the only mechanism that *restores* accuracy. Everything else in
    /// the pipeline can only lose it more slowly.
    @discardableResult
    public func observeAnchor(id: String) -> Bool {
        guard let anchor = map?.anchor(id: id) else { return false }
        observeAnchor(anchor)
        return true
    }

    public func observeAnchor(_ anchor: MapAnchor) {
        let measured = currentMeasuredHeading()
        filter.observeAnchor(anchor, measuredHeading: measured)
        deadReckoning = anchor.position
        if let hint = anchor.headingHint {
            deadReckoningHeadingOffset = Angle.delta(from: measured, to: hint)
        }
    }

    /// Fits the step-length model to a walk of known distance, using the steps
    /// collected since `start`.
    @discardableResult
    public func calibrateStepLength(knownDistance: Double) -> Double? {
        stepLengthEstimator.calibrate(
            knownDistance: knownDistance,
            steps: steps,
            mode: carriage.mode
        )
    }

    // MARK: - Internals

    /// Walking heading in the map frame, before any particle's bias.
    private func currentMeasuredHeading() -> Double {
        let device = headingEstimator.deviceHeading
        let direction = walkingDirection.estimate
        let offset = direction.confidence >= configuration.minimumWalkingDirectionConfidence
            ? direction.misalignment
            : 0
        let referenceHeading = device + offset
        return Angle.wrapToPi(referenceHeading + (map?.headingOffset ?? 0))
    }

    private func handle(step: StepEvent, at timestamp: TimeInterval) -> PositionFix? {
        steps.append(step)

        let mode = carriage.mode
        let direction = walkingDirection.update(mode: mode)
        let length = stepLengthEstimator.length(for: step, mode: mode)
        travelled += length

        let usesWalkingDirection =
            direction.confidence >= configuration.minimumWalkingDirectionConfidence
        let measuredHeading = currentMeasuredHeading()

        // First step: tie the sensor frame to the plan. Doing it here rather
        // than on the first sample means the walking-direction estimate already
        // exists, so the alignment is between the plan and where the user is
        // actually going — not between the plan and where the phone points.
        if let target = pendingHeadingAnchor {
            pendingHeadingAnchor = nil
            deadReckoningHeadingOffset = Angle.delta(from: measuredHeading, to: target)
            filter.initialize(
                position: deadReckoning,
                heading: target,
                measuredHeading: measuredHeading,
                positionSigma: startPositionSigma,
                headingSigma: startHeadingSigma
            )
        }

        // Uncertainty is the honest part of this. When PCA cannot separate the
        // walking direction from the device orientation, the heading may be off
        // by any amount at all, and the filter is told so rather than being fed
        // a confident lie.
        var uncertainty = headingEstimator.uncertainty
        if !usesWalkingDirection {
            uncertainty = (uncertainty * uncertainty
                + configuration.fallbackHeadingUncertainty
                * configuration.fallbackHeadingUncertainty).squareRoot()
        }

        // Pure dead reckoning, for comparison. No map, no filter.
        let deadReckoningHeading = Angle.wrapToPi(measuredHeading + deadReckoningHeadingOffset)
        deadReckoning = deadReckoning + Vector2.unit(angle: deadReckoningHeading) * length

        if usesWalkingDirection, !direction.isSignResolved {
            // PCA gave an axis but not an arrow. Let the map settle it.
            filter.splitForDirectionAmbiguity()
        }

        let estimate = filter.update(
            length: length,
            measuredHeading: measuredHeading,
            headingUncertainty: uncertainty
        )

        let fix = PositionFix(
            timestamp: timestamp,
            position: estimate?.position ?? deadReckoning,
            heading: estimate?.heading ?? deadReckoningHeading,
            // The whole cloud, not just the winning cluster: an accuracy figure
            // that ignores the hypotheses still in play is a lie the UI will
            // repeat.
            horizontalAccuracy: estimate.map { max(0.5, $0.totalSpread) }
                ?? accuracyFromDeadReckoning(),
            deadReckoningPosition: deadReckoning,
            stepCount: steps.count,
            travelledDistance: travelled,
            carriageMode: mode,
            headingSource: headingEstimator.source,
            isAmbiguous: estimate?.isAmbiguous ?? true,
            headingCorrection: estimate?.headingBias ?? 0,
            stepScale: estimate?.stepScale ?? 1
        )
        latestFix = fix
        onFix?(fix)
        return fix
    }

    /// Accuracy when there is no map to lean on.
    ///
    /// Two terms, both linear in distance: stride error at roughly 10 % and
    /// heading error swinging the whole path sideways. Linear, not quadratic —
    /// that improvement is the entire reason for counting steps.
    private func accuracyFromDeadReckoning() -> Double {
        let strideError = 0.10 * travelled
        let headingError = travelled * sin(min(headingEstimator.uncertainty, .pi / 4))
        return max(1.0, (strideError * strideError + headingError * headingError).squareRoot())
    }
}

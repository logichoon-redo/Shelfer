//
//  ParticleFilter.swift
//  PDRCore
//

import Foundation

/// One hypothesis about where the user is and how wrong their sensors are.
public struct Particle: Sendable, Equatable {
    public var position: Point2D
    /// Correction added to the measured heading, radians. This is the term that
    /// absorbs gyro drift and magnetic distortion — the filter estimates the
    /// error rather than trusting the sensor.
    public var headingBias: Double
    /// Multiplier on the estimated step length. Absorbs the 10–15 % stride
    /// error of an uncalibrated user.
    public var stepScale: Double
    public var weight: Double

    public init(position: Point2D, headingBias: Double, stepScale: Double, weight: Double) {
        self.position = position
        self.headingBias = headingBias
        self.stepScale = stepScale
        self.weight = weight
    }

    /// Heading this particle believes the user is walking, given a measurement.
    public func heading(measured: Double) -> Double {
        Angle.wrapToPi(measured + headingBias)
    }
}

/// Result of one filter update.
public struct ParticleFilterEstimate: Sendable, Equatable {
    /// Best estimate: the mean of the dominant cluster, not of everything.
    /// A bimodal cloud straddling two corridors has a mean inside the wall
    /// between them, which is the one place the user certainly is not.
    public var position: Point2D
    public var heading: Double
    /// Per-axis 1-sigma spread of the dominant cluster, metres.
    public var spread: Double
    /// Per-axis 1-sigma spread of the whole cloud about `position`, metres.
    ///
    /// This, not `spread`, is the honest accuracy figure. The cluster spread
    /// describes how tightly the winning hypothesis is held; the total spread
    /// includes the hypotheses that have not been ruled out yet.
    public var totalSpread: Double
    /// Weight fraction held by the dominant cluster, 0…1.
    public var dominantClusterWeight: Double
    /// Weight fraction held by the strongest cluster somewhere else entirely.
    public var runnerUpClusterWeight: Double
    /// Effective sample size over particle count, 0…1.
    public var effectiveSampleRatio: Double
    /// True when a second, well-separated cluster still carries real weight —
    /// the filter has not decided between two places, and the UI should say so
    /// rather than pick one and look confident.
    public var isAmbiguous: Bool
    /// Mean heading bias, radians: how far the raw sensor heading has drifted.
    public var headingBias: Double
    /// Mean step-length scale the filter has settled on.
    public var stepScale: Double
}

/// Particle filter over (position, heading bias, stride scale), constrained by
/// the floor plan.
///
/// This is the half of the system that stops PDR from degrading forever. Dead
/// reckoning on its own only ever loses accuracy; the map is what puts some
/// back, and it does it by attacking heading specifically:
///
/// * **Wall crossings kill particles.** A drifting heading eventually walks
///   into a wall, and that hypothesis dies.
/// * **Corridor axes reweight particles.** In a corridor network you cannot
///   walk at an arbitrary angle. Weighting each particle by how well its
///   heading lines up with a nearby corridor turns heading from a free
///   variable into a choice among a few discrete options — which is exactly
///   the failure mode PDR needs help with.
///
/// The two together mean stride error (gentle, proportional) is left to
/// accumulate while heading error (vicious, unbounded) is continually pruned.
public final class ParticleFilter {
    public struct Configuration: Sendable {
        public var particleCount: Int = 500

        /// Per-step heading noise, radians. Covers gait variation and the
        /// walking-direction estimate's own error.
        public var headingNoise: Double = Angle.degrees(6)
        /// Random walk on the heading bias per step. Lets the filter track a
        /// slowly rotating gyro error instead of locking onto a stale one.
        public var headingBiasRandomWalk: Double = Angle.degrees(0.4)
        /// Multiplicative noise on step length per step.
        public var stepScaleNoise: Double = 0.02

        /// Spread of the initial stride scale across particles.
        public var initialStepScaleSigma: Double = 0.10
        public var minimumStepScale: Double = 0.7
        public var maximumStepScale: Double = 1.4

        /// von Mises concentration for the corridor-axis constraint. Higher
        /// pulls harder towards the corridor direction. Zero disables it.
        public var corridorConcentration: Double = 6.0
        /// Weight multiplier for a particle that ends up outside every
        /// corridor. Not zero: a real user does step into doorways and rooms,
        /// and a hard kill there makes the filter brittle.
        public var offCorridorWeight: Double = 0.05
        /// How far outside the walkable band a particle may sit before
        /// `offCorridorWeight` bites in full.
        public var corridorTolerance: Double = 0.5
        /// Walking through a wall is not survivable. Unlike being off-corridor,
        /// this is geometrically impossible rather than merely unusual.
        public var killOnWallCrossing: Bool = true

        /// Resample when the effective sample size drops below this fraction.
        public var resampleThreshold: Double = 0.5
        /// Jitter added on resampling, to avoid collapsing onto duplicates.
        public var rougheningPosition: Double = 0.08
        public var rougheningHeading: Double = Angle.degrees(0.6)

        /// If every particle dies, respawn around the last estimate with this
        /// spread rather than giving up.
        public var recoveryPositionSigma: Double = 2.0
        public var recoveryHeadingSigma: Double = Angle.degrees(30)

        public init() {}
        public static let `default` = Configuration()
    }

    public private(set) var particles: [Particle] = []
    public private(set) var configuration: Configuration
    /// Times the filter has had to respawn from a total particle wipe-out.
    /// A non-zero count in the field means the map or the entry point is wrong.
    public private(set) var recoveryCount = 0

    private let index: MapIndex?
    private var generator: SeededGenerator
    private var lastEstimate: ParticleFilterEstimate?
    private var hasSplitForDirectionAmbiguity = false

    public init(map: MapIndex?, configuration: Configuration = .default, seed: UInt64 = 0xC0FFEE) {
        self.index = map
        self.configuration = configuration
        self.generator = SeededGenerator(seed: seed)
    }

    public var isInitialized: Bool { !particles.isEmpty }

    // MARK: - Initialisation

    /// Seeds the filter around a known starting pose.
    ///
    /// Knowing where the user started does not stop drift — accuracy still only
    /// decreases from here — but it removes the global ambiguity that would
    /// otherwise take a hundred metres of corridor to resolve.
    public func initialize(
        position: Point2D,
        heading: Double,
        measuredHeading: Double,
        positionSigma: Double,
        headingSigma: Double
    ) {
        particles.removeAll(keepingCapacity: true)
        particles.reserveCapacity(configuration.particleCount)
        let uniformWeight = 1.0 / Double(configuration.particleCount)
        let biasCentre = Angle.delta(from: measuredHeading, to: heading)

        for _ in 0..<configuration.particleCount {
            var candidate = Point2D(
                x: position.x + generator.nextGaussian(standardDeviation: positionSigma),
                y: position.y + generator.nextGaussian(standardDeviation: positionSigma)
            )
            // Do not start a hypothesis somewhere the user cannot stand.
            if let index, !index.isWalkable(candidate) {
                if let projection = index.projection(of: candidate) {
                    candidate = projection.point
                } else {
                    candidate = position
                }
            }
            particles.append(
                Particle(
                    position: candidate,
                    headingBias: Angle.wrapToPi(
                        biasCentre + generator.nextGaussian(standardDeviation: headingSigma)
                    ),
                    stepScale: clampStepScale(
                        1 + generator.nextGaussian(standardDeviation: configuration.initialStepScaleSigma)
                    ),
                    weight: uniformWeight
                )
            )
        }
        lastEstimate = nil
        hasSplitForDirectionAmbiguity = false
    }

    public func reset() {
        particles.removeAll(keepingCapacity: true)
        lastEstimate = nil
        recoveryCount = 0
        hasSplitForDirectionAmbiguity = false
    }

    /// Splits the cloud into forward and backward hypotheses, once.
    ///
    /// PCA on horizontal acceleration recovers the walking *axis* but not which
    /// way along it the user is facing, and no amount of further accelerometer
    /// data settles that. So the ambiguity is handed to the map: half the
    /// particles carry a heading bias offset by pi, both hypotheses are walked
    /// forward, and the corridor geometry kills whichever one ends up in a wall.
    ///
    /// The offset lives in `headingBias`, so it persists across steps — a
    /// per-step coin flip would just add noise and never resolve anything.
    /// Idempotent: calling it repeatedly does not keep re-splitting.
    public func splitForDirectionAmbiguity() {
        guard !hasSplitForDirectionAmbiguity, !particles.isEmpty else { return }
        hasSplitForDirectionAmbiguity = true
        for i in particles.indices where i % 2 == 1 {
            particles[i].headingBias = Angle.wrapToPi(particles[i].headingBias + .pi)
        }
    }

    // MARK: - Update

    /// Advances every particle by one step and reweights against the map.
    ///
    /// - Parameters:
    ///   - length: step length in metres from the empirical model.
    ///   - measuredHeading: walking heading in the **map** frame, before each
    ///     particle's own bias correction.
    ///   - headingUncertainty: 1-sigma confidence in that heading; widens the
    ///     per-step noise so a bad heading spreads the cloud instead of moving
    ///     it confidently to the wrong place.
    @discardableResult
    public func update(
        length: Double,
        measuredHeading: Double,
        headingUncertainty: Double = 0
    ) -> ParticleFilterEstimate? {
        guard !particles.isEmpty else { return nil }

        let headingSigma = (
            configuration.headingNoise * configuration.headingNoise
                + headingUncertainty * headingUncertainty
        ).squareRoot()

        var totalWeight = 0.0
        for i in particles.indices {
            var particle = particles[i]

            particle.headingBias = Angle.wrapToPi(
                particle.headingBias
                    + generator.nextGaussian(standardDeviation: configuration.headingBiasRandomWalk)
            )
            particle.stepScale = clampStepScale(
                particle.stepScale
                    + generator.nextGaussian(standardDeviation: configuration.stepScaleNoise)
            )

            let heading = Angle.wrapToPi(
                measuredHeading + particle.headingBias
                    + generator.nextGaussian(standardDeviation: headingSigma)
            )

            let stride = max(0.05, length * particle.stepScale)
            let destination = particle.position + Vector2.unit(angle: heading) * stride

            var weight = particle.weight
            if let index {
                if configuration.killOnWallCrossing,
                   index.crossesWall(from: particle.position, to: destination) {
                    weight = 0
                } else {
                    weight *= corridorLikelihood(at: destination, heading: heading, index: index)
                }
            }

            particle.position = destination
            particle.weight = weight
            particles[i] = particle
            totalWeight += weight
        }

        guard totalWeight > 0 else {
            recover()
            return lastEstimate
        }

        for i in particles.indices { particles[i].weight /= totalWeight }

        let effectiveSampleSize = 1.0 / particles.reduce(0.0) { $0 + $1.weight * $1.weight }
        let ratio = effectiveSampleSize / Double(particles.count)
        if ratio < configuration.resampleThreshold { resample() }

        let estimate = makeEstimate(effectiveSampleRatio: ratio, measuredHeading: measuredHeading)
        lastEstimate = estimate
        return estimate
    }

    /// Collapses the cloud onto a marker of known position.
    ///
    /// The reset that makes the whole scheme viable: error growth is monotonic,
    /// so somewhere along the corridor the estimate has to be handed a truth.
    /// How far apart these can be is the number the drift experiment measures.
    public func observeAnchor(_ anchor: MapAnchor, measuredHeading: Double) {
        let heading = anchor.headingHint ?? currentHeading(measuredHeading: measuredHeading)
        initialize(
            position: anchor.position,
            heading: heading,
            measuredHeading: measuredHeading,
            positionSigma: anchor.positionSigma,
            headingSigma: anchor.headingSigma
        )
    }

    // MARK: - Map likelihood

    /// How plausible this pose is given the floor plan.
    private func corridorLikelihood(at point: Point2D, heading: Double, index: MapIndex) -> Double {
        guard let projection = index.projection(of: point) else { return 1 }

        var likelihood = 1.0

        // Being outside the walkable band is unlikely, not impossible.
        let overhang = projection.distance - projection.halfWidth
        if overhang > 0 {
            let excess = max(0, overhang - configuration.corridorTolerance)
            let fade = exp(-excess * 2)
            likelihood *= max(configuration.offCorridorWeight, fade)
        }

        // The heading constraint. A corridor is a line, so compare axes: both
        // directions along it are equally allowed.
        if configuration.corridorConcentration > 0, projection.distance <= projection.halfWidth * 2 {
            let axialError = Angle.axialSeparation(heading, projection.axis)
            // von Mises on the doubled angle, normalised so a perfectly aligned
            // particle scores 1.
            let kappa = configuration.corridorConcentration
            likelihood *= exp(kappa * (cos(2 * axialError) - 1))
        }

        return likelihood
    }

    // MARK: - Resampling

    /// Systematic (low-variance) resampling: one uniform draw, then evenly
    /// spaced picks. Cheaper and lower-variance than multinomial.
    private func resample() {
        let count = particles.count
        guard count > 0 else { return }

        var cumulative = [Double](repeating: 0, count: count)
        var running = 0.0
        for i in 0..<count {
            running += particles[i].weight
            cumulative[i] = running
        }
        guard running > 0 else { return }

        let step = running / Double(count)
        var target = generator.nextUniform() * step
        var source = 0
        var resampled: [Particle] = []
        resampled.reserveCapacity(count)

        for _ in 0..<count {
            while source < count - 1, cumulative[source] < target { source += 1 }
            var particle = particles[source]
            // Roughening: without it the cloud collapses onto a handful of
            // duplicated states and stops representing uncertainty at all.
            particle.position = Point2D(
                x: particle.position.x
                    + generator.nextGaussian(standardDeviation: configuration.rougheningPosition),
                y: particle.position.y
                    + generator.nextGaussian(standardDeviation: configuration.rougheningPosition)
            )
            particle.headingBias = Angle.wrapToPi(
                particle.headingBias
                    + generator.nextGaussian(standardDeviation: configuration.rougheningHeading)
            )
            particle.weight = 1.0 / Double(count)
            resampled.append(particle)
            target += step
        }
        particles = resampled
    }

    /// Every hypothesis died. Respawn around the last estimate, widened.
    private func recover() {
        recoveryCount += 1
        guard let estimate = lastEstimate else {
            let uniform = 1.0 / Double(max(1, particles.count))
            for i in particles.indices { particles[i].weight = uniform }
            return
        }
        let count = particles.count
        let uniform = 1.0 / Double(max(1, count))
        for i in 0..<count {
            var candidate = Point2D(
                x: estimate.position.x
                    + generator.nextGaussian(standardDeviation: configuration.recoveryPositionSigma),
                y: estimate.position.y
                    + generator.nextGaussian(standardDeviation: configuration.recoveryPositionSigma)
            )
            if let index, !index.isWalkable(candidate), let projection = index.projection(of: candidate) {
                candidate = projection.point
            }
            particles[i].position = candidate
            particles[i].headingBias = Angle.wrapToPi(
                particles[i].headingBias
                    + generator.nextGaussian(standardDeviation: configuration.recoveryHeadingSigma)
            )
            particles[i].weight = uniform
        }
    }

    // MARK: - Estimation

    private func currentHeading(measuredHeading: Double) -> Double {
        guard !particles.isEmpty else { return measuredHeading }
        let headings = particles.map { $0.heading(measured: measuredHeading) }
        let weights = particles.map(\.weight)
        return Angle.circularMean(headings, weights: weights)
    }

    /// Weighted mean of the dominant cluster.
    ///
    /// Found by gridding the particles and growing from the heaviest cell.
    /// Reporting the global mean instead would place the user in the wall
    /// between two candidate corridors whenever the filter is genuinely torn —
    /// the one place they certainly are not.
    private func makeEstimate(
        effectiveSampleRatio: Double,
        measuredHeading: Double
    ) -> ParticleFilterEstimate {
        let cellSize = 1.5
        let radius = cellSize * 2

        var buckets: [Int64: Double] = [:]
        for particle in particles {
            buckets[bucketKey(particle.position, cellSize: cellSize), default: 0] += particle.weight
        }

        let dominantCentre = buckets.max { $0.value < $1.value }
            .map { bucketCentre($0.key, cellSize: cellSize) }
            ?? particles.first?.position
            ?? .zero

        let dominant = cluster(around: dominantCentre, radius: radius, measuredHeading: measuredHeading)
        let position = dominant.weight > 1e-9 ? dominant.position : dominantCentre

        // The runner-up: the heaviest cell that is not part of the winning
        // cluster at all. Two tight clusters ten metres apart is a different
        // situation from one loose cloud, and only the first is ambiguous.
        let runnerUpCentre = buckets
            .filter { bucketCentre($0.key, cellSize: cellSize).distance(to: dominantCentre) > radius * 2 }
            .max { $0.value < $1.value }
            .map { bucketCentre($0.key, cellSize: cellSize) }
        let runnerUpWeight = runnerUpCentre.map {
            cluster(around: $0, radius: radius, measuredHeading: measuredHeading).weight
        } ?? 0

        var totalWeight = 0.0
        var totalVariance = 0.0
        var biasSum = 0.0
        var scaleSum = 0.0
        for particle in particles {
            totalWeight += particle.weight
            totalVariance += particle.weight * particle.position.distanceSquared(to: position)
            biasSum += particle.weight * particle.headingBias
            scaleSum += particle.weight * particle.stepScale
        }
        let normalizer = totalWeight > 1e-12 ? totalWeight : 1

        return ParticleFilterEstimate(
            position: position,
            heading: dominant.heading,
            spread: dominant.spread,
            totalSpread: ((totalVariance / normalizer) / 2).squareRoot(),
            dominantClusterWeight: dominant.weight,
            runnerUpClusterWeight: runnerUpWeight,
            effectiveSampleRatio: effectiveSampleRatio,
            isAmbiguous: runnerUpWeight > 0.25 * max(dominant.weight, 1e-9),
            headingBias: biasSum / normalizer,
            stepScale: scaleSum / normalizer
        )
    }

    /// Weighted statistics of the particles within `radius` of `centre`.
    private func cluster(
        around centre: Point2D,
        radius: Double,
        measuredHeading: Double
    ) -> (position: Point2D, heading: Double, spread: Double, weight: Double) {
        var weight = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var headings: [Double] = []
        var headingWeights: [Double] = []

        for particle in particles where particle.position.distance(to: centre) <= radius {
            weight += particle.weight
            sumX += particle.position.x * particle.weight
            sumY += particle.position.y * particle.weight
            headings.append(particle.heading(measured: measuredHeading))
            headingWeights.append(particle.weight)
        }
        guard weight > 1e-9 else {
            return (centre, measuredHeading, 0, 0)
        }

        let position = Point2D(x: sumX / weight, y: sumY / weight)
        var variance = 0.0
        for particle in particles where particle.position.distance(to: centre) <= radius {
            variance += particle.weight * particle.position.distanceSquared(to: position)
        }
        return (
            position,
            Angle.circularMean(headings, weights: headingWeights),
            ((variance / weight) / 2).squareRoot(),
            weight
        )
    }

    private func bucketCentre(_ key: Int64, cellSize: Double) -> Point2D {
        let column = Double(key >> 32)
        let row = Double(Int32(truncatingIfNeeded: key))
        return Point2D(x: (column + 0.5) * cellSize, y: (row + 0.5) * cellSize)
    }

    private func bucketKey(_ point: Point2D, cellSize: Double) -> Int64 {
        let column = Int64((point.x / cellSize).rounded(.down))
        let row = Int64((point.y / cellSize).rounded(.down))
        return (column << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: row)))
    }

    private func clampStepScale(_ value: Double) -> Double {
        min(configuration.maximumStepScale, max(configuration.minimumStepScale, value))
    }

    /// Last estimate produced, if any.
    public var estimate: ParticleFilterEstimate? { lastEstimate }
}

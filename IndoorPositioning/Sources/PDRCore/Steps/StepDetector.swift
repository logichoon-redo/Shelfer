//
//  StepDetector.swift
//  PDRCore
//

import Foundation

/// One detected footfall.
///
/// The window statistics describe the interval **between the previous peak and
/// this one**, which is the window the empirical step-length models expect.
public struct StepEvent: Sendable, Equatable {
    /// Time of the acceleration peak.
    public var timestamp: TimeInterval
    /// Seconds since the previous step.
    public var interval: TimeInterval
    /// Largest filtered acceleration magnitude in the window, m/s².
    public var accelerationMax: Double
    /// Smallest filtered acceleration magnitude in the window, m/s².
    public var accelerationMin: Double
    /// Mean absolute dynamic acceleration in the window, m/s².
    public var accelerationMean: Double
    /// Variance of the dynamic acceleration in the window, (m/s²)².
    public var accelerationVariance: Double
    /// Index of this step since the detector was last reset, starting at 0.
    public var index: Int

    /// Step frequency in Hz.
    public var cadence: Double { interval > 0 ? 1 / interval : 0 }

    /// Peak-to-peak swing, the input to the Weinberg model.
    public var accelerationRange: Double { accelerationMax - accelerationMin }

    public init(
        timestamp: TimeInterval,
        interval: TimeInterval,
        accelerationMax: Double,
        accelerationMin: Double,
        accelerationMean: Double,
        accelerationVariance: Double,
        index: Int
    ) {
        self.timestamp = timestamp
        self.interval = interval
        self.accelerationMax = accelerationMax
        self.accelerationMin = accelerationMin
        self.accelerationMean = accelerationMean
        self.accelerationVariance = accelerationVariance
        self.index = index
    }
}

/// Detects footfalls as discrete events in the accelerometer magnitude.
///
/// This is the load-bearing decision of the whole system. Double-integrating
/// acceleration grows position error as ½·b·t², and the dominant `b` is not
/// accelerometer bias but attitude error — 1° of tilt leaks
/// 9.81·sin(1°) ≈ 0.17 m/s² of gravity into the horizontal axes, which is
/// larger than the horizontal signal of walking itself. Counting bounded
/// events instead turns that quadratic growth into linear growth.
///
/// So: no velocity state, no position state, nothing integrated. Peaks only.
public struct StepDetector {
    public struct Configuration: Sendable {
        /// Gait energy lives around 1–3 Hz. Above this is handling noise.
        public var lowPassCutoffHz: Double = 3.0
        /// Window for the adaptive threshold.
        public var statisticsWindow: TimeInterval = 2.0
        /// Threshold sits this many standard deviations above the local mean.
        public var thresholdSigma: Double = 0.6
        /// Absolute floor on the peak-to-mean swing, m/s². Below this the user
        /// is standing still and the "peaks" are sensor noise.
        public var minimumDynamicAmplitude: Double = 0.35
        /// Fastest believable cadence (4 Hz ~ running).
        public var minimumStepInterval: TimeInterval = 0.25
        /// Slowest believable cadence. A longer gap is treated as a pause, and
        /// the next peak starts a fresh sequence rather than producing one
        /// enormous phantom step.
        public var maximumStepInterval: TimeInterval = 2.0
        /// Steps to discard after a pause. The adaptive threshold already
        /// waits for a saturated statistics window, so the default keeps every
        /// step: discarding one per resume would quietly shorten the path.
        public var warmupSteps: Int = 0

        public init() {}
        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private var filter: CascadedLowPass
    private var stats: SlidingWindowStats

    private var lastTimestamp: TimeInterval?
    private var lastPeakTime: TimeInterval?
    private var isAboveThreshold = false
    private var candidatePeakValue = -Double.greatestFiniteMagnitude
    private var candidatePeakTime: TimeInterval = 0

    // Accumulators covering the current peak-to-peak window.
    private var windowMax = -Double.greatestFiniteMagnitude
    private var windowMin = Double.greatestFiniteMagnitude
    private var windowAbsSum = 0.0
    private var windowSquareSum = 0.0
    private var windowCount = 0

    private var stepIndex = 0
    private var stepsSinceResume = 0

    /// Number of steps emitted since the last `reset()`.
    public private(set) var stepCount = 0

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        self.filter = CascadedLowPass(cutoffHz: configuration.lowPassCutoffHz)
        self.stats = SlidingWindowStats(window: configuration.statisticsWindow)
    }

    public mutating func reset() {
        filter.reset()
        stats.reset()
        lastTimestamp = nil
        lastPeakTime = nil
        isAboveThreshold = false
        candidatePeakValue = -.greatestFiniteMagnitude
        resetWindow()
        stepIndex = 0
        stepsSinceResume = 0
        stepCount = 0
    }

    /// Feeds one sample. Returns a `StepEvent` on the sample where a footfall
    /// is confirmed — which is the falling edge of the peak, roughly 100 ms
    /// after the peak itself. The event carries the peak's own timestamp, so
    /// the latency shows up as a delay in *reporting*, not as a time error.
    public mutating func process(_ sample: MotionSample) -> StepEvent? {
        let time = sample.timestamp

        guard let previous = lastTimestamp else {
            lastTimestamp = time
            filter.update(sample.accelerationMagnitude, dt: 0)
            stats.add(filter.value, at: time)
            return nil
        }

        let dt = time - previous
        // Out-of-order samples would corrupt the filter state, and a gap of a
        // second means the stream stalled. Drop both without advancing the
        // clock, so the next good sample sees an honest `dt`.
        guard dt > 0 else { return nil }
        guard dt < 1.0 else {
            lastTimestamp = time
            lastPeakTime = nil
            isAboveThreshold = false
            stepsSinceResume = 0
            resetWindow()
            return nil
        }
        lastTimestamp = time

        let filtered = filter.update(sample.accelerationMagnitude, dt: dt)
        stats.add(filtered, at: time)

        let baseline = stats.mean
        let dynamic = filtered - baseline

        windowMax = max(windowMax, filtered)
        windowMin = min(windowMin, filtered)
        windowAbsSum += abs(dynamic)
        windowSquareSum += dynamic * dynamic
        windowCount += 1

        guard stats.isSaturated else { return nil }

        let threshold = max(
            configuration.thresholdSigma * stats.standardDeviation,
            configuration.minimumDynamicAmplitude
        )

        if dynamic > threshold {
            // Rising edge, or still climbing: remember the highest point.
            if !isAboveThreshold {
                isAboveThreshold = true
                candidatePeakValue = -.greatestFiniteMagnitude
            }
            if filtered > candidatePeakValue {
                candidatePeakValue = filtered
                candidatePeakTime = time
            }
            return nil
        }

        guard isAboveThreshold else { return nil }
        // Falling edge: the crossing confirms the peak we tracked on the way up.
        isAboveThreshold = false
        return confirmPeak(at: candidatePeakTime)
    }

    private mutating func confirmPeak(at peakTime: TimeInterval) -> StepEvent? {
        defer {
            lastPeakTime = peakTime
            resetWindow()
        }

        guard let previousPeak = lastPeakTime else {
            // First peak of a sequence only opens the window; a step needs two.
            stepsSinceResume = 0
            return nil
        }

        let interval = peakTime - previousPeak
        guard interval >= configuration.minimumStepInterval else {
            // Too fast to be a separate footfall — a double bounce off one
            // impact. Swallow it; the `defer` re-anchors the window here, which
            // costs at most a quarter second of accumulator.
            return nil
        }
        guard interval <= configuration.maximumStepInterval else {
            // The user paused. Start a fresh sequence from this peak.
            stepsSinceResume = 0
            return nil
        }

        stepsSinceResume += 1
        guard stepsSinceResume > configuration.warmupSteps else { return nil }
        guard windowCount > 0 else { return nil }

        let count = Double(windowCount)
        let event = StepEvent(
            timestamp: peakTime,
            interval: interval,
            accelerationMax: windowMax,
            accelerationMin: windowMin,
            accelerationMean: windowAbsSum / count,
            accelerationVariance: max(0, windowSquareSum / count),
            index: stepIndex
        )
        stepIndex += 1
        stepCount += 1
        return event
    }

    private mutating func resetWindow() {
        windowMax = -.greatestFiniteMagnitude
        windowMin = .greatestFiniteMagnitude
        windowAbsSum = 0
        windowSquareSum = 0
        windowCount = 0
    }
}

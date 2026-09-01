//
//  Filters.swift
//  PDRCore
//

import Foundation

/// One-pole low-pass that tolerates the jittery sample spacing CoreMotion
/// actually delivers: the smoothing factor is recomputed from each `dt`
/// instead of being baked in at a nominal rate.
public struct LowPassFilter {
    public private(set) var value: Double = 0
    private var primed = false
    private let timeConstant: Double

    /// - Parameter cutoffHz: -3 dB corner frequency.
    public init(cutoffHz: Double) {
        precondition(cutoffHz > 0, "cutoff must be positive")
        self.timeConstant = 1 / (2 * Double.pi * cutoffHz)
    }

    public mutating func reset() {
        primed = false
        value = 0
    }

    @discardableResult
    public mutating func update(_ input: Double, dt: Double) -> Double {
        guard primed else {
            primed = true
            value = input
            return value
        }
        guard dt > 0, dt.isFinite else { return value }
        let alpha = dt / (timeConstant + dt)
        value += alpha * (input - value)
        return value
    }
}

/// Two cascaded one-pole sections. A single pole leaves enough handling
/// vibration in the signal to trigger phantom peaks; two gives ~12 dB/octave,
/// which is what step detection needs to stay honest.
public struct CascadedLowPass {
    private var first: LowPassFilter
    private var second: LowPassFilter

    public init(cutoffHz: Double) {
        // Correct the per-stage corner so the cascade's -3 dB point lands on
        // the requested cutoff.
        let stageCutoff = cutoffHz / (2.0.squareRoot() - 1).squareRoot()
        first = LowPassFilter(cutoffHz: stageCutoff)
        second = LowPassFilter(cutoffHz: stageCutoff)
    }

    public var value: Double { second.value }

    public mutating func reset() {
        first.reset()
        second.reset()
    }

    @discardableResult
    public mutating func update(_ input: Double, dt: Double) -> Double {
        second.update(first.update(input, dt: dt), dt: dt)
    }
}

/// Fixed-capacity ring buffer. Used everywhere a rolling window of samples is
/// needed without per-sample allocation.
public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        storage = Array(repeating: nil, count: capacity)
    }

    public var capacity: Int { storage.count }
    public var isFull: Bool { count == storage.count }
    public var isEmpty: Bool { count == 0 }

    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % storage.count
        if count < storage.count { count += 1 }
    }

    public mutating func removeAll() {
        for index in storage.indices { storage[index] = nil }
        head = 0
        count = 0
    }

    /// Oldest element first.
    public subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "index out of range")
        let start = (head - count + storage.count) % storage.count
        return storage[(start + index) % storage.count]!
    }

    public var elements: [Element] {
        (0..<count).map { self[$0] }
    }

    public var last: Element? { count > 0 ? self[count - 1] : nil }
}

/// Mean/variance over a trailing time window. Keeps timestamps so a stalled
/// sensor cannot silently stretch the window.
public struct SlidingWindowStats {
    private struct Sample {
        let time: TimeInterval
        let value: Double
    }

    private var samples: [Sample] = []
    private let window: TimeInterval
    private var sum = 0.0
    private var sumOfSquares = 0.0
    private var dropsSinceRederive = 0

    public init(window: TimeInterval) {
        precondition(window > 0, "window must be positive")
        self.window = window
        samples.reserveCapacity(256)
    }

    public var count: Int { samples.count }
    public var mean: Double { samples.isEmpty ? 0 : sum / Double(samples.count) }

    public var variance: Double {
        guard samples.count > 1 else { return 0 }
        let n = Double(samples.count)
        return max(0, sumOfSquares / n - (sum / n) * (sum / n))
    }

    public var standardDeviation: Double { variance.squareRoot() }

    /// True once the window holds a full `window` seconds of data, which is
    /// when the statistics are worth acting on.
    public var isSaturated: Bool {
        guard let first = samples.first, let last = samples.last else { return false }
        return last.time - first.time >= window * 0.9
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        sum = 0
        sumOfSquares = 0
        dropsSinceRederive = 0
    }

    public mutating func add(_ value: Double, at time: TimeInterval) {
        samples.append(Sample(time: time, value: value))
        sum += value
        sumOfSquares += value * value

        var dropped = 0
        while dropped < samples.count, time - samples[dropped].time > window {
            sum -= samples[dropped].value
            sumOfSquares -= samples[dropped].value * samples[dropped].value
            dropped += 1
        }
        guard dropped > 0 else { return }
        samples.removeFirst(dropped)

        // Incremental subtraction drifts over the hundreds of thousands of
        // samples a long walk produces, so re-derive periodically. The window
        // holds ~100 samples, which makes this cheap enough to do often.
        dropsSinceRederive += dropped
        if samples.isEmpty || dropsSinceRederive >= 512 {
            dropsSinceRederive = 0
            sum = 0
            sumOfSquares = 0
            for sample in samples {
                sum += sample.value
                sumOfSquares += sample.value * sample.value
            }
        }
    }
}

/// Deterministic PRNG (SplitMix64). The particle filter must be reproducible:
/// a bug that only shows up on one random seed is a bug you cannot fix.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextUniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Zero-mean Gaussian via Box-Muller. One value per call; the discarded
    /// half is not worth the state.
    public mutating func nextGaussian(standardDeviation: Double = 1) -> Double {
        let u1 = max(nextUniform(), 1e-12)
        let u2 = nextUniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2) * standardDeviation
    }
}

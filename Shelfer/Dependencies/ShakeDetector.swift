//
//  ShakeDetector.swift
//  Shelfer
//

import CoreGraphics
import Foundation

/// Detects a "shake" gesture from a stream of mouse-drag positions, independent of AppKit.
struct ShakeDetector {
    struct Configuration {
        var reversalThreshold = 3
        var timeWindow: TimeInterval = 0.7
        var minTravelDistance: CGFloat = 60
        /// Distance from the latest turning point, accumulated across as many
        /// mouse events as needed, before a direction change becomes meaningful.
        var minLegDistance: CGFloat = 16

        static let `default` = Configuration()
    }

    private struct Sample {
        let point: CGPoint
        let time: TimeInterval
    }

    private struct AxisMotion {
        let travel: CGFloat
        let reversals: Int
    }

    private let configuration: Configuration
    private var samples: [Sample] = []

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    mutating func reset() {
        samples.removeAll()
    }

    /// Feed a new drag position; returns true the moment a shake is recognized.
    @discardableResult
    mutating func addSample(point: CGPoint, time: TimeInterval) -> Bool {
        samples.append(Sample(point: point, time: time))
        samples.removeAll { time - $0.time > configuration.timeWindow }

        guard samples.count >= 3 else { return false }

        let horizontal = motion(along: \.x)
        let vertical = motion(along: \.y)

        let isHorizontalShake =
            horizontal.reversals >= configuration.reversalThreshold &&
            horizontal.travel >= configuration.minTravelDistance
        let isVerticalShake =
            vertical.reversals >= configuration.reversalThreshold &&
            vertical.travel >= configuration.minTravelDistance

        guard isHorizontalShake || isVerticalShake else {
            return false
        }

        samples.removeAll()
        return true
    }

    /// Measures deliberate legs between turning points. A 16-point leg may be
    /// delivered as four 4-point events; small event deltas are therefore not
    /// discarded individually. Minor movement back toward the current extreme
    /// is treated as noise until it crosses the full hysteresis distance.
    private func motion(along axis: KeyPath<CGPoint, CGFloat>) -> AxisMotion {
        guard let first = samples.first else { return AxisMotion(travel: 0, reversals: 0) }

        var previous = first.point[keyPath: axis]
        var initialMinimum = previous
        var initialMaximum = previous
        var extreme = previous
        var direction: CGFloat = 0
        var travel: CGFloat = 0
        var reversals = 0

        for sample in samples.dropFirst() {
            let value = sample.point[keyPath: axis]
            travel += abs(value - previous)
            previous = value

            if direction == 0 {
                initialMinimum = min(initialMinimum, value)
                initialMaximum = max(initialMaximum, value)

                guard initialMaximum - initialMinimum >= configuration.minLegDistance else {
                    continue
                }

                direction = value == initialMaximum ? 1 : -1
                extreme = value
                continue
            }

            if direction > 0 {
                if value > extreme {
                    extreme = value
                } else if extreme - value >= configuration.minLegDistance {
                    direction = -1
                    extreme = value
                    reversals += 1
                }
            } else if value < extreme {
                extreme = value
            } else if value - extreme >= configuration.minLegDistance {
                direction = 1
                extreme = value
                reversals += 1
            }
        }

        return AxisMotion(travel: travel, reversals: reversals)
    }
}

//
//  ShakeDetector.swift
//  C5
//

import CoreGraphics
import Foundation

/// Detects a "shake" gesture from a stream of mouse-drag positions, independent of AppKit.
struct ShakeDetector {
    struct Configuration {
        var reversalThreshold = 4
        var timeWindow: TimeInterval = 0.6
        var minTravelDistance: CGFloat = 80
        var minAxisDelta: CGFloat = 12

        static let `default` = Configuration()
    }

    private struct Sample {
        let point: CGPoint
        let time: TimeInterval
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

        var pathLength: CGFloat = 0
        var reversalCount = 0
        var lastDirection: CGFloat = 0

        for i in 1..<samples.count {
            let delta = samples[i].point.x - samples[i - 1].point.x
            pathLength += abs(delta) + abs(samples[i].point.y - samples[i - 1].point.y)

            guard abs(delta) >= configuration.minAxisDelta else { continue }
            let direction: CGFloat = delta > 0 ? 1 : -1
            if lastDirection != 0, direction != lastDirection {
                reversalCount += 1
            }
            lastDirection = direction
        }

        guard reversalCount >= configuration.reversalThreshold,
              pathLength >= configuration.minTravelDistance else {
            return false
        }

        samples.removeAll()
        return true
    }
}

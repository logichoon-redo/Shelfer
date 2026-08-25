//
//  ShakeDetectorTests.swift
//  C5Tests
//

import CoreGraphics
import Foundation
import Testing
@testable import C5

struct ShakeDetectorTests {

    @Test func detectsRapidLeftRightMotion() {
        var detector = ShakeDetector()
        var t: TimeInterval = 0
        var fired = false

        // Zig-zag horizontally: 0 -> 100 -> 0 -> 100 -> 0 -> 100
        let xs: [CGFloat] = [0, 100, 0, 100, 0, 100]
        for x in xs {
            t += 0.05
            if detector.addSample(point: CGPoint(x: x, y: 0), time: t) {
                fired = true
            }
        }

        #expect(fired)
    }

    @Test func ignoresSmoothStraightDrag() {
        var detector = ShakeDetector()
        var fired = false

        for i in 0..<20 {
            let t = TimeInterval(i) * 0.05
            if detector.addSample(point: CGPoint(x: CGFloat(i) * 10, y: 0), time: t) {
                fired = true
            }
        }

        #expect(!fired)
    }

    @Test func ignoresSamplesOutsideTimeWindow() {
        var config = ShakeDetector.Configuration.default
        config.timeWindow = 0.3
        var detector = ShakeDetector(configuration: config)
        var fired = false

        // Same zig-zag as the positive case, but spread out far beyond the time window.
        let xs: [CGFloat] = [0, 100, 0, 100, 0, 100]
        var t: TimeInterval = 0
        for x in xs {
            t += 1.0
            if detector.addSample(point: CGPoint(x: x, y: 0), time: t) {
                fired = true
            }
        }

        #expect(!fired)
    }

    @Test func ignoresSubPixelJitter() {
        var config = ShakeDetector.Configuration.default
        config.minAxisDelta = 12
        var detector = ShakeDetector(configuration: config)
        var fired = false

        var t: TimeInterval = 0
        for _ in 0..<10 {
            t += 0.05
            let x: CGFloat = Bool.random() ? 2 : -2
            if detector.addSample(point: CGPoint(x: x, y: 0), time: t) {
                fired = true
            }
        }

        #expect(!fired)
    }
}

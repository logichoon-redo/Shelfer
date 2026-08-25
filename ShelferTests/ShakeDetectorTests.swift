//
//  ShakeDetectorTests.swift
//  ShelferTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Shelfer

struct ShakeDetectorTests {

    @Test func detectsRapidLeftRightMotion() {
        var detector = ShakeDetector()
        var t: TimeInterval = 0
        var fired = false

        // Each event moves only 4 points. The detector must accumulate those
        // small deltas into deliberate 16-point legs.
        let xs: [CGFloat] = [0, 4, 8, 12, 16, 12, 8, 4, 0, 4, 8, 12, 16, 12, 8, 4, 0]
        for x in xs {
            t += 0.02
            if detector.addSample(point: CGPoint(x: x, y: 0), time: t) {
                fired = true
            }
        }

        #expect(fired)
    }

    @Test func detectsRapidUpDownMotion() {
        var detector = ShakeDetector()
        var t: TimeInterval = 0
        var fired = false

        let ys: [CGFloat] = [0, 4, 8, 12, 16, 12, 8, 4, 0, 4, 8, 12, 16, 12, 8, 4, 0]
        for y in ys {
            t += 0.02
            if detector.addSample(point: CGPoint(x: 0, y: y), time: t) {
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

    @Test func ignoresSmoothVerticalDrag() {
        var detector = ShakeDetector()
        var fired = false

        for i in 0..<20 {
            let t = TimeInterval(i) * 0.05
            if detector.addSample(point: CGPoint(x: 0, y: CGFloat(i) * 10), time: t) {
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
        config.minLegDistance = 16
        var detector = ShakeDetector(configuration: config)
        var fired = false

        let xs: [CGFloat] = [0, 2, -2, 3, -3, 2, -1, 3, -2, 2, -3, 1, -2, 3, -1, 2]
        var t: TimeInterval = 0
        for x in xs {
            t += 0.02
            if detector.addSample(point: CGPoint(x: x, y: 0), time: t) {
                fired = true
            }
        }

        #expect(!fired)
    }
}

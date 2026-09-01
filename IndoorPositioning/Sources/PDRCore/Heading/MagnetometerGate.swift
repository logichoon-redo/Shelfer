//
//  MagnetometerGate.swift
//  PDRCore
//

import Foundation

/// Decides, sample by sample, whether the magnetometer is currently telling
/// the truth.
///
/// Indoors it usually is not. Steel frames, lift shafts, server racks and door
/// closers bend the local field by tens of degrees, and the distortion is
/// static — averaging does not remove it, and walking past it produces a
/// heading step, not noise. So the magnetometer is used as a slow, gated
/// anchor against gyro drift, never as a primary heading source.
public struct MagnetometerGate {
    public struct Configuration: Sendable {
        /// Earth's field runs 25–65 µT. Outside this the reading is dominated
        /// by something local.
        public var minimumFieldStrength: Double = 22
        public var maximumFieldStrength: Double = 70
        /// Fast changes in field magnitude mean the user is walking past metal.
        public var maximumFieldRateOfChange: Double = 12   // µT/s
        /// How far the dip angle may stray from the learned local value.
        public var maximumDipDeviation: Double = Angle.degrees(15)
        /// Seconds of clean readings before the gate opens again.
        public var settlingTime: TimeInterval = 1.5
        /// Time constant of the learned reference dip angle.
        public var dipLearningTimeConstant: Double = 60

        public init() {}
        public static let `default` = Configuration()
    }

    public struct Reading: Sendable, Equatable {
        /// Heading of the horizontal basis vector `e1` relative to magnetic
        /// north, radians CCW.
        public var heading: Double
        public var fieldStrength: Double
        public var dipAngle: Double
        public var isTrusted: Bool
    }

    private let configuration: Configuration
    private var referenceDip: Double?
    private var lastStrength: Double?
    private var lastTimestamp: TimeInterval?
    private var cleanSince: TimeInterval?

    public private(set) var isOpen = false
    public private(set) var lastReading: Reading?

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public mutating func reset() {
        referenceDip = nil
        lastStrength = nil
        lastTimestamp = nil
        cleanSince = nil
        isOpen = false
        lastReading = nil
    }

    /// Feeds a sample. Returns a reading when a magnetic heading could be
    /// computed at all — check `isTrusted` before using it.
    @discardableResult
    public mutating func process(_ sample: MotionSample) -> Reading? {
        guard let field = sample.magneticField else {
            isOpen = false
            cleanSince = nil
            return nil
        }
        // CoreMotion reports accuracy < 0 while the magnetometer is
        // uncalibrated; the numbers it emits then are not field readings.
        if let accuracy = sample.magneticFieldAccuracy, accuracy < 0 {
            isOpen = false
            cleanSince = nil
            return nil
        }

        let time = sample.timestamp
        let strength = field.magnitude
        guard strength > 1e-6 else {
            isOpen = false
            cleanSince = nil
            return nil
        }

        let up = sample.up
        let horizontal = field.rejected(from: up)
        guard horizontal.magnitude > 1e-3 else {
            // Field points straight down: no horizontal component to read a
            // heading from. Happens near the magnetic poles and next to a
            // large vertical steel member.
            isOpen = false
            cleanSince = nil
            return nil
        }

        // Dip: positive when the field tilts below the horizon.
        let dip = atan2(-field.dot(up), horizontal.magnitude)

        // Heading of e1 measured CCW from magnetic north.
        let north = horizontal.normalized()
        let e1 = sample.horizontalBasis.e1
        let heading = atan2(up.dot(north.cross(e1)), north.dot(e1))

        var clean = strength >= configuration.minimumFieldStrength
            && strength <= configuration.maximumFieldStrength

        if let previousStrength = lastStrength, let previousTime = lastTimestamp {
            let dt = time - previousTime
            if dt > 1e-4 {
                let rate = abs(strength - previousStrength) / dt
                if rate > configuration.maximumFieldRateOfChange { clean = false }
            }
        }

        if let reference = referenceDip {
            if abs(Angle.wrapToPi(dip - reference)) > configuration.maximumDipDeviation {
                clean = false
            }
        }

        // Learn the local dip only from readings that already look clean, so a
        // long walk past a steel wall cannot become the new normal.
        if clean, let previousTime = lastTimestamp {
            let dt = max(0, time - previousTime)
            let alpha = dt / (configuration.dipLearningTimeConstant + dt)
            referenceDip = referenceDip.map { $0 + alpha * Angle.wrapToPi(dip - $0) } ?? dip
        } else if clean, referenceDip == nil {
            referenceDip = dip
        }

        lastStrength = strength
        lastTimestamp = time

        if clean {
            let since = cleanSince ?? time
            cleanSince = since
            isOpen = time - since >= configuration.settlingTime
        } else {
            cleanSince = nil
            isOpen = false
        }

        let reading = Reading(
            heading: heading,
            fieldStrength: strength,
            dipAngle: dip,
            isTrusted: isOpen
        )
        lastReading = reading
        return reading
    }
}

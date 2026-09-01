//
//  MotionSample.swift
//  PDRCore
//
//  Frame conventions used throughout the package
//  --------------------------------------------
//  Device frame : whatever the phone's IMU reports. +Z out of the screen.
//  Reference    : right-handed, +Z up. +X is the sensor-fusion reference
//                 direction (magnetic north when the app asks CoreMotion for
//                 `xMagneticNorthZVertical`, otherwise arbitrary-but-fixed).
//  Map frame    : metres on the floor plan, right-handed, +Z up. Related to
//                 the reference frame by `IndoorMap.headingOffset`.
//
//  All headings are radians, counter-clockwise from the frame's +X axis.
//

import Foundation

/// One fused IMU sample.
///
/// This mirrors what `CMDeviceMotion` hands over, but the core is written
/// against this struct rather than CoreMotion so it can be driven from a
/// recorded log or a synthetic walk — which is how the accuracy numbers get
/// measured without standing in a corridor for every code change.
public struct MotionSample: Sendable, Equatable {
    /// Seconds on a monotonic clock. Only differences are used.
    public var timestamp: TimeInterval

    /// Acceleration with gravity already removed, device frame, m/s².
    public var userAcceleration: Vector3

    /// Gravity as seen in the device frame, m/s². Points *down*, so the
    /// device-frame "up" axis is `-gravity.normalized()`.
    public var gravity: Vector3

    /// Angular rate, device frame, rad/s.
    public var rotationRate: Vector3

    /// Device-to-reference rotation from the platform's sensor fusion.
    /// `nil` falls the heading estimator back to gyro integration.
    public var attitude: Quaternion?

    /// Calibrated magnetic field, device frame, µT. `nil` when the
    /// magnetometer is unavailable or uncalibrated.
    public var magneticField: Vector3?

    /// Platform's own confidence in the magnetic field, if it exposes one.
    /// Negative means "do not trust", matching CoreMotion's convention.
    public var magneticFieldAccuracy: Int?

    public init(
        timestamp: TimeInterval,
        userAcceleration: Vector3,
        gravity: Vector3,
        rotationRate: Vector3,
        attitude: Quaternion? = nil,
        magneticField: Vector3? = nil,
        magneticFieldAccuracy: Int? = nil
    ) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
        self.attitude = attitude
        self.magneticField = magneticField
        self.magneticFieldAccuracy = magneticFieldAccuracy
    }
}

/// Standard gravity, m/s².
public let standardGravity = 9.80665

public extension MotionSample {
    /// Device-frame "up" — the direction opposite gravity.
    var up: Vector3 { (-gravity).normalized() }

    /// Signed vertical acceleration, positive upwards, m/s².
    var verticalAcceleration: Double { userAcceleration.dot(up) }

    /// The part of the user acceleration that lies in the horizontal plane,
    /// still expressed in the device frame.
    ///
    /// This is the one place gravity gets subtracted, and it is subtracted as
    /// a *projection* rather than a magnitude — attitude error leaks in here
    /// and nowhere else. Which is precisely why nothing downstream integrates
    /// this signal.
    var horizontalAcceleration: Vector3 {
        userAcceleration - up * verticalAcceleration
    }

    /// Magnitude of the specific force, i.e. what a raw accelerometer reads.
    /// Hovers around 9.81 while standing; the gait signal rides on top of it.
    var accelerationMagnitude: Double { (userAcceleration + gravity).magnitude }

    /// An orthonormal basis `(e1, e2)` spanning the horizontal plane, in
    /// device-frame coordinates, with `(e1, e2, up)` right-handed.
    ///
    /// `e1` is the device's +X axis flattened onto the floor. When the phone is
    /// held flat that is "the direction the right edge points"; when it is held
    /// upright it degenerates, so the device's +Y axis is used instead.
    var horizontalBasis: (e1: Vector3, e2: Vector3) {
        let upAxis = up
        var candidate = Vector3(1, 0, 0).rejected(from: upAxis)
        if candidate.magnitude < 0.1 {
            candidate = Vector3(0, 1, 0).rejected(from: upAxis)
        }
        if candidate.magnitude < 1e-6 {
            candidate = Vector3(0, 0, 1).rejected(from: upAxis)
        }
        let e1 = candidate.normalized()
        return (e1, upAxis.cross(e1))
    }

    /// Horizontal acceleration expressed in the `horizontalBasis`, m/s².
    var horizontalAccelerationInBasis: Vector2 {
        let basis = horizontalBasis
        let a = horizontalAcceleration
        return Vector2(a.dot(basis.e1), a.dot(basis.e2))
    }

    /// Angular rate about the world vertical, rad/s, CCW seen from above.
    ///
    /// Projecting the gyro onto the gravity direction is what keeps the yaw
    /// estimate usable when the phone is not held flat — integrating raw `z`
    /// only works for a phone lying on a table.
    var yawRate: Double { rotationRate.dot(up) }

    /// Heading of the horizontal basis vector `e1` in the reference frame,
    /// or `nil` when the platform gave us no attitude.
    var referenceHeadingOfBasis: Double? {
        guard let attitude else { return nil }
        let e1World = attitude.rotate(horizontalBasis.e1)
        let planar = Vector2(e1World.x, e1World.y)
        guard planar.magnitude > 1e-6 else { return nil }
        return planar.angle
    }
}

/// Anything that can feed the engine: CoreMotion on device, a CSV replay, or
/// the synthetic walk generator.
public protocol MotionSource: AnyObject {
    var onSample: ((MotionSample) -> Void)? { get set }
    func start()
    func stop()
}

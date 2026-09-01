//
//  Vector.swift
//  PDRCore
//

import Foundation

/// A 3-vector. Hand-rolled rather than `simd` so the package builds on Linux
/// (where the validation harness and the test suite run) as well as on Apple
/// platforms.
public struct Vector3: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3()

    public var magnitudeSquared: Double { x * x + y * y + z * z }
    public var magnitude: Double { magnitudeSquared.squareRoot() }

    /// Unit vector, or `zero` for a degenerate input. Callers that cannot
    /// tolerate a zero result must check `magnitude` first.
    public func normalized() -> Vector3 {
        let m = magnitude
        guard m > 1e-12 else { return .zero }
        return Vector3(x / m, y / m, z / m)
    }

    public func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    public func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    /// The component of `self` that lies along `axis` (which need not be unit).
    public func projected(onto axis: Vector3) -> Vector3 {
        let unit = axis.normalized()
        return unit * dot(unit)
    }

    /// The component of `self` left after removing everything along `axis`.
    public func rejected(from axis: Vector3) -> Vector3 {
        self - projected(onto: axis)
    }

    public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    public static prefix func - (value: Vector3) -> Vector3 {
        Vector3(-value.x, -value.y, -value.z)
    }

    public static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    public static func * (lhs: Double, rhs: Vector3) -> Vector3 { rhs * lhs }

    public static func / (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }
}

/// A 2-vector in the horizontal plane. Distinct from `Point2D` (a map
/// coordinate) so that "a direction" and "a place" never get mixed up.
public struct Vector2: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double = 0, _ y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = Vector2()

    public var magnitudeSquared: Double { x * x + y * y }
    public var magnitude: Double { magnitudeSquared.squareRoot() }

    /// Direction measured counter-clockwise from +X, in radians.
    public var angle: Double { atan2(y, x) }

    public func normalized() -> Vector2 {
        let m = magnitude
        guard m > 1e-12 else { return .zero }
        return Vector2(x / m, y / m)
    }

    public func dot(_ other: Vector2) -> Double { x * other.x + y * other.y }

    /// Z component of the 3-D cross product; positive when `other` is CCW of `self`.
    public func cross(_ other: Vector2) -> Double { x * other.y - y * other.x }

    public static func unit(angle: Double) -> Vector2 {
        Vector2(cos(angle), sin(angle))
    }

    public static func + (lhs: Vector2, rhs: Vector2) -> Vector2 {
        Vector2(lhs.x + rhs.x, lhs.y + rhs.y)
    }

    public static func - (lhs: Vector2, rhs: Vector2) -> Vector2 {
        Vector2(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    public static func * (lhs: Vector2, rhs: Double) -> Vector2 {
        Vector2(lhs.x * rhs, lhs.y * rhs)
    }

    public static func * (lhs: Double, rhs: Vector2) -> Vector2 { rhs * lhs }
}

/// Unit quaternion describing a rotation. Stored `w + xi + yj + zk`.
///
/// Convention: a `Quaternion` produced from CoreMotion's attitude rotates a
/// vector expressed in the **device** frame into the **reference** frame.
public struct Quaternion: Equatable, Sendable, Codable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double = 1, x: Double = 0, y: Double = 0, z: Double = 0) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quaternion()

    public init(axis: Vector3, angle: Double) {
        let unit = axis.normalized()
        let half = angle / 2
        let s = sin(half)
        self.init(w: cos(half), x: unit.x * s, y: unit.y * s, z: unit.z * s)
    }

    public var norm: Double { (w * w + x * x + y * y + z * z).squareRoot() }

    public func normalized() -> Quaternion {
        let n = norm
        guard n > 1e-12 else { return .identity }
        return Quaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public var conjugate: Quaternion { Quaternion(w: w, x: -x, y: -y, z: -z) }

    /// Hamilton product. `a * b` applies `b` first, then `a`.
    public static func * (lhs: Quaternion, rhs: Quaternion) -> Quaternion {
        Quaternion(
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w
        )
    }

    /// Rotates `v` by this quaternion (device frame -> reference frame).
    public func rotate(_ v: Vector3) -> Vector3 {
        let u = Vector3(x, y, z)
        let cross1 = u.cross(v)
        let cross2 = u.cross(cross1)
        return v + (cross1 * w + cross2) * 2
    }

    /// Rotates `v` the other way (reference frame -> device frame).
    public func inverseRotate(_ v: Vector3) -> Vector3 { conjugate.rotate(v) }
}

/// Angle helpers. Every heading in this package is in **radians, measured
/// counter-clockwise from the +X axis** of whatever frame is named.
public enum Angle {
    public static let twoPi = 2 * Double.pi

    public static func degrees(_ value: Double) -> Double { value * .pi / 180 }
    public static func toDegrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Wraps to (-pi, pi]. `atan2` form is branch-free and stays exact for
    /// large inputs, where repeated subtraction accumulates error.
    public static func wrapToPi(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        return atan2(sin(angle), cos(angle))
    }

    /// Signed shortest rotation that takes `from` to `to`.
    public static func delta(from: Double, to: Double) -> Double {
        wrapToPi(to - from)
    }

    /// Smallest unsigned angle between two directions, ignoring which way round.
    public static func separation(_ a: Double, _ b: Double) -> Double {
        abs(wrapToPi(a - b))
    }

    /// Smallest unsigned angle between two *axes* — i.e. treating `a` and
    /// `a + pi` as the same line. This is what corridor constraints need: a
    /// corridor is a line, and you may walk it in either direction.
    public static func axialSeparation(_ a: Double, _ b: Double) -> Double {
        let d = abs(wrapToPi(a - b))
        return min(d, .pi - d)
    }

    /// Weighted mean of angles, done on the unit circle so that the wrap point
    /// does not bias the result.
    public static func circularMean(_ angles: [Double], weights: [Double]? = nil) -> Double {
        var sx = 0.0
        var sy = 0.0
        for (index, angle) in angles.enumerated() {
            let w = weights?[index] ?? 1
            sx += w * cos(angle)
            sy += w * sin(angle)
        }
        guard sx * sx + sy * sy > 1e-18 else { return 0 }
        return atan2(sy, sx)
    }
}

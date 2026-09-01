//
//  IndoorMap.swift
//  PDRCore
//

import Foundation

/// A point on the floor plan, in metres.
public struct Point2D: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)

    public func distance(to other: Point2D) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }

    public func distanceSquared(to other: Point2D) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return dx * dx + dy * dy
    }

    public static func + (lhs: Point2D, rhs: Vector2) -> Point2D {
        Point2D(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    public static func - (lhs: Point2D, rhs: Point2D) -> Vector2 {
        Vector2(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

/// A wall, or any other line the user cannot walk through.
public struct Segment: Equatable, Sendable, Codable {
    public var a: Point2D
    public var b: Point2D

    public init(a: Point2D, b: Point2D) {
        self.a = a
        self.b = b
    }

    public init(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) {
        self.init(a: Point2D(x: ax, y: ay), b: Point2D(x: bx, y: by))
    }

    public var length: Double { a.distance(to: b) }

    /// Direction of the segment, radians CCW from +X.
    public var heading: Double { (b - a).angle }

    /// Closest point on the segment to `point`, and the distance to it.
    public func closestPoint(to point: Point2D) -> (point: Point2D, distance: Double, t: Double) {
        let ab = b - a
        let lengthSquared = ab.magnitudeSquared
        guard lengthSquared > 1e-12 else {
            return (a, a.distance(to: point), 0)
        }
        let t = min(1, max(0, (point - a).dot(ab) / lengthSquared))
        let projection = Point2D(x: a.x + ab.x * t, y: a.y + ab.y * t)
        return (projection, projection.distance(to: point), t)
    }

    /// Proper segment-segment intersection test.
    ///
    /// Collinear overlap counts as an intersection: a step that slides exactly
    /// along a wall is not a step we want to accept.
    public func intersects(_ other: Segment) -> Bool {
        let p = a
        let r = b - a
        let q = other.a
        let s = other.b - other.a

        let denominator = r.cross(s)
        let qp = q - p
        let qpCrossR = qp.cross(r)

        if abs(denominator) < 1e-12 {
            guard abs(qpCrossR) < 1e-12 else { return false }  // parallel, disjoint
            let rr = r.dot(r)
            guard rr > 1e-12 else { return false }
            let t0 = qp.dot(r) / rr
            let t1 = t0 + s.dot(r) / rr
            return max(min(t0, t1), 0) <= min(max(t0, t1), 1)
        }

        let t = qp.cross(s) / denominator
        let u = qpCrossR / denominator
        return t >= 0 && t <= 1 && u >= 0 && u <= 1
    }
}

/// A walkable corridor: a centre line plus a width.
///
/// Corridors are what make step-counting PDR survivable. They discretise
/// heading — in a corridor network you cannot walk at an arbitrary angle, only
/// along one of a handful of axes — which turns the largest error source in
/// PDR from a free variable into a choice among a few.
public struct Corridor: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    /// Centre line, at least two points.
    public var polyline: [Point2D]
    /// Full width in metres; the walkable band is `width / 2` either side.
    public var width: Double

    public init(id: String, polyline: [Point2D], width: Double = 2.0) {
        self.id = id
        self.polyline = polyline
        self.width = width
    }

    public var segments: [Segment] {
        guard polyline.count >= 2 else { return [] }
        return (0..<(polyline.count - 1)).map {
            Segment(a: polyline[$0], b: polyline[$0 + 1])
        }
    }
}

/// A physical marker whose position is known exactly — a QR code by a door, an
/// NFC tag on a pillar, a numbered sign.
///
/// Anchors are the reset mechanism. Step-counting PDR degrades monotonically:
/// nothing in it recovers accuracy, so without periodic resets there is a
/// distance beyond which the estimate is worthless. Measuring that distance is
/// exactly how you decide how many markers to put up.
public struct MapAnchor: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var position: Point2D
    /// Direction the user must be facing when they scan it, if the marker's
    /// mounting forces one. Resets heading as well as position.
    public var headingHint: Double?
    /// 1-sigma position uncertainty after the reset, metres.
    public var positionSigma: Double
    /// 1-sigma heading uncertainty after the reset, radians.
    public var headingSigma: Double

    public init(
        id: String,
        position: Point2D,
        headingHint: Double? = nil,
        positionSigma: Double = 0.5,
        headingSigma: Double = Angle.degrees(15)
    ) {
        self.id = id
        self.position = position
        self.headingHint = headingHint
        self.positionSigma = positionSigma
        self.headingSigma = headingSigma
    }
}

/// A door or stair head: somewhere a session can legitimately begin.
public struct MapEntryPoint: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var position: Point2D
    /// Heading a user necessarily has on entering — through a door you walk in
    /// one direction, which is free heading information.
    public var heading: Double
    public var positionSigma: Double
    public var headingSigma: Double

    public init(
        id: String,
        position: Point2D,
        heading: Double,
        positionSigma: Double = 1.0,
        headingSigma: Double = Angle.degrees(25)
    ) {
        self.id = id
        self.position = position
        self.heading = heading
        self.positionSigma = positionSigma
        self.headingSigma = headingSigma
    }
}

/// A floor plan, reduced to the three things positioning needs: where you
/// cannot go, where you can, and where you can be certain.
public struct IndoorMap: Equatable, Sendable, Codable {
    public var name: String
    public var walls: [Segment]
    public var corridors: [Corridor]
    public var anchors: [MapAnchor]
    public var entryPoints: [MapEntryPoint]

    /// Rotation from the sensor reference frame to the map frame, radians.
    ///
    /// `mapHeading = referenceHeading + headingOffset`. When the app asks
    /// CoreMotion for a magnetic-north reference, this is the bearing of the
    /// plan's +X axis relative to magnetic north, negated. It is a survey
    /// constant of the building — measure it once, on the plan.
    public var headingOffset: Double

    public init(
        name: String = "",
        walls: [Segment] = [],
        corridors: [Corridor] = [],
        anchors: [MapAnchor] = [],
        entryPoints: [MapEntryPoint] = [],
        headingOffset: Double = 0
    ) {
        self.name = name
        self.walls = walls
        self.corridors = corridors
        self.anchors = anchors
        self.entryPoints = entryPoints
        self.headingOffset = headingOffset
    }

    public func anchor(id: String) -> MapAnchor? { anchors.first { $0.id == id } }
    public func entryPoint(id: String) -> MapEntryPoint? { entryPoints.first { $0.id == id } }

    /// Axis-aligned bounds over everything in the map, padded slightly.
    public var bounds: (min: Point2D, max: Point2D)? {
        var points: [Point2D] = []
        for wall in walls { points.append(wall.a); points.append(wall.b) }
        for corridor in corridors { points.append(contentsOf: corridor.polyline) }
        guard let first = points.first else { return nil }

        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let pad = 1.0
        return (Point2D(x: minX - pad, y: minY - pad), Point2D(x: maxX + pad, y: maxY + pad))
    }
}

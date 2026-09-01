//
//  GeoAnchor.swift
//  PDRCore
//

import Foundation

/// A latitude/longitude pair, in degrees.
///
/// Deliberately not `CLLocationCoordinate2D`: `PDRCore` stays free of platform
/// frameworks so the whole pipeline can run on a machine with no CoreLocation.
/// `PDRMotion` bridges the two.
public struct GeoCoordinate: Equatable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Ties the floor plan's metre grid to the world, so a PDR estimate can be
/// drawn on a geographic map next to a GPS fix.
///
/// A building is small enough that the flat-earth approximation is not a
/// compromise: over 100 m the error from ignoring curvature is millimetres.
/// What actually matters is the two survey constants — where the plan's origin
/// sits, and which way its +X axis points — and getting the second one wrong
/// rotates the whole track.
public struct GeoAnchor: Equatable, Sendable, Codable {
    /// Geographic position of the map frame's origin, `Point2D(x: 0, y: 0)`.
    public var origin: GeoCoordinate

    /// True bearing of the map frame's +X axis: radians **clockwise from
    /// north**, which is the geographic convention and the opposite sense to
    /// the counter-clockwise headings used everywhere else in this package.
    public var bearingOfXAxis: Double

    public init(origin: GeoCoordinate, bearingOfXAxis: Double = 0) {
        self.origin = origin
        self.bearingOfXAxis = bearingOfXAxis
    }

    /// Anchors the plan to wherever the user is standing, with the +X axis
    /// pointing the way they are about to walk.
    ///
    /// This is the zero-survey option, and it is what makes a side-by-side
    /// comparison against GPS possible with no preparation at all: start both
    /// at the same point and watch them diverge. It buys nothing for absolute
    /// accuracy — the estimate is only ever as good as the fix you seeded it
    /// with — but divergence is the thing being measured, not position.
    public static func here(
        _ coordinate: GeoCoordinate,
        walkingBearing: Double
    ) -> GeoAnchor {
        GeoAnchor(origin: coordinate, bearingOfXAxis: walkingBearing)
    }

    /// Metres per degree of latitude at `latitude`, WGS-84.
    static func metresPerDegreeLatitude(at latitude: Double) -> Double {
        let phi = latitude * .pi / 180
        return 111132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi)
            - 0.0023 * cos(6 * phi)
    }

    /// Metres per degree of longitude at `latitude`, WGS-84.
    static func metresPerDegreeLongitude(at latitude: Double) -> Double {
        let phi = latitude * .pi / 180
        return 111412.84 * cos(phi) - 93.5 * cos(3 * phi) + 0.118 * cos(5 * phi)
    }

    /// Where a point on the plan sits in the world.
    public func coordinate(for point: Point2D) -> GeoCoordinate {
        // Map headings run counter-clockwise from +X; bearings run clockwise
        // from north. Hence the subtraction.
        let distance = (point.x * point.x + point.y * point.y).squareRoot()
        guard distance > 1e-9 else { return origin }
        let bearing = bearingOfXAxis - atan2(point.y, point.x)

        let north = distance * cos(bearing)
        let east = distance * sin(bearing)

        let latitudeScale = Self.metresPerDegreeLatitude(at: origin.latitude)
        let longitudeScale = Self.metresPerDegreeLongitude(at: origin.latitude)
        guard latitudeScale > 1e-6, abs(longitudeScale) > 1e-6 else { return origin }

        return GeoCoordinate(
            latitude: origin.latitude + north / latitudeScale,
            longitude: origin.longitude + east / longitudeScale
        )
    }

    /// Where a place in the world sits on the plan.
    public func point(for coordinate: GeoCoordinate) -> Point2D {
        let latitudeScale = Self.metresPerDegreeLatitude(at: origin.latitude)
        let longitudeScale = Self.metresPerDegreeLongitude(at: origin.latitude)

        let north = (coordinate.latitude - origin.latitude) * latitudeScale
        let east = (coordinate.longitude - origin.longitude) * longitudeScale

        let distance = (north * north + east * east).squareRoot()
        guard distance > 1e-9 else { return .zero }
        let bearing = atan2(east, north)
        let mapHeading = bearingOfXAxis - bearing

        return Point2D(x: distance * cos(mapHeading), y: distance * sin(mapHeading))
    }

    /// Derives the +X bearing from two surveyed points: stand at one end of a
    /// corridor, then the other, and take a GPS fix at each.
    ///
    /// GPS is worth perhaps 5 m indoors, so over a 20 m corridor this is good
    /// to roughly 15 degrees — enough to get the plan the right way round on
    /// screen, nowhere near enough to trust as a heading reference. Measure the
    /// bearing off the floor plan instead when the estimate has to be good.
    public static func bearing(from start: GeoCoordinate, to end: GeoCoordinate) -> Double {
        let latitudeScale = metresPerDegreeLatitude(at: start.latitude)
        let longitudeScale = metresPerDegreeLongitude(at: start.latitude)
        let north = (end.latitude - start.latitude) * latitudeScale
        let east = (end.longitude - start.longitude) * longitudeScale
        return atan2(east, north)
    }
}

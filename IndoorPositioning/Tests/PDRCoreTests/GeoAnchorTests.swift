//
//  GeoAnchorTests.swift
//  PDRCoreTests
//

import XCTest
@testable import PDRCore

final class GeoAnchorTests: XCTestCase {
    private let seoul = GeoCoordinate(latitude: 37.5665, longitude: 126.9780)

    func testOriginMapsToItself() {
        let anchor = GeoAnchor(origin: seoul, bearingOfXAxis: Angle.degrees(37))
        let coordinate = anchor.coordinate(for: .zero)
        XCTAssertEqual(coordinate.latitude, seoul.latitude, accuracy: 1e-12)
        XCTAssertEqual(coordinate.longitude, seoul.longitude, accuracy: 1e-12)
    }

    func testXAxisFollowsItsBearing() {
        // +X pointing due north: 100 m along it must only change latitude.
        let north = GeoAnchor(origin: seoul, bearingOfXAxis: 0)
        let ahead = north.coordinate(for: Point2D(x: 100, y: 0))
        XCTAssertGreaterThan(ahead.latitude, seoul.latitude)
        XCTAssertEqual(ahead.longitude, seoul.longitude, accuracy: 1e-9)

        // +X pointing due east: only longitude.
        let east = GeoAnchor(origin: seoul, bearingOfXAxis: Angle.degrees(90))
        let right = east.coordinate(for: Point2D(x: 100, y: 0))
        XCTAssertGreaterThan(right.longitude, seoul.longitude)
        XCTAssertEqual(right.latitude, seoul.latitude, accuracy: 1e-9)
    }

    func testYAxisIsNinetyDegreesCounterClockwiseOfX() {
        // Map headings run counter-clockwise; bearings run clockwise. With +X
        // due north, +Y must come out west, not east. Getting this backwards
        // mirrors the entire track, which is the kind of bug that looks like a
        // heading problem for a day.
        let anchor = GeoAnchor(origin: seoul, bearingOfXAxis: 0)
        let left = anchor.coordinate(for: Point2D(x: 0, y: 100))
        XCTAssertLessThan(left.longitude, seoul.longitude)
        XCTAssertEqual(left.latitude, seoul.latitude, accuracy: 1e-9)
    }

    func testRoundTripsThroughGeographicCoordinates() {
        let anchor = GeoAnchor(origin: seoul, bearingOfXAxis: Angle.degrees(-115))
        for point in [
            Point2D(x: 0, y: 0),
            Point2D(x: 63.5, y: -12.25),
            Point2D(x: -140, y: 88),
        ] {
            let round = anchor.point(for: anchor.coordinate(for: point))
            XCTAssertEqual(round.x, point.x, accuracy: 0.01)
            XCTAssertEqual(round.y, point.y, accuracy: 0.01)
        }
    }

    /// Independent great-circle distance, to check the flat-earth shortcut.
    private func haversine(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let radius = 6_371_008.8
        let phi1 = a.latitude * .pi / 180
        let phi2 = b.latitude * .pi / 180
        let dPhi = phi2 - phi1
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dPhi / 2) * sin(dPhi / 2)
            + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * radius * asin(min(1, h.squareRoot()))
    }

    func testDistanceSurvivesTheFlatEarthShortcut() {
        // A building is small enough that ignoring curvature is free. Check it
        // against a real great-circle distance rather than assuming.
        let anchor = GeoAnchor(origin: seoul, bearingOfXAxis: Angle.degrees(20))
        let a = anchor.coordinate(for: Point2D(x: 10, y: 10))
        let b = anchor.coordinate(for: Point2D(x: 110, y: 10))
        XCTAssertEqual(haversine(a, b), 100, accuracy: 0.05)

        let far = anchor.coordinate(for: Point2D(x: 10, y: 510))
        XCTAssertEqual(haversine(a, far), 500, accuracy: 0.5)
    }

    func testBearingBetweenTwoFixes() {
        let anchor = GeoAnchor(origin: seoul, bearingOfXAxis: 0)
        let start = anchor.coordinate(for: .zero)
        let end = anchor.coordinate(for: Point2D(x: 50, y: 0))   // 50 m due north
        XCTAssertEqual(
            Angle.wrapToPi(GeoAnchor.bearing(from: start, to: end)), 0,
            accuracy: Angle.degrees(0.5)
        )

        let eastAnchor = GeoAnchor(origin: seoul, bearingOfXAxis: Angle.degrees(90))
        let eastEnd = eastAnchor.coordinate(for: Point2D(x: 50, y: 0))
        XCTAssertEqual(
            GeoAnchor.bearing(from: start, to: eastEnd), Angle.degrees(90),
            accuracy: Angle.degrees(0.5)
        )
    }

    func testScaleFactorsAreSane() {
        // A degree of latitude is about 111 km everywhere; a degree of
        // longitude shrinks with the cosine of latitude.
        XCTAssertEqual(GeoAnchor.metresPerDegreeLatitude(at: 37.5), 110_996, accuracy: 400)
        XCTAssertEqual(GeoAnchor.metresPerDegreeLongitude(at: 0), 111_320, accuracy: 400)
        XCTAssertEqual(GeoAnchor.metresPerDegreeLongitude(at: 37.5), 88_400, accuracy: 600)
        XCTAssertLessThan(
            GeoAnchor.metresPerDegreeLongitude(at: 60),
            GeoAnchor.metresPerDegreeLongitude(at: 30)
        )
    }

    func testAnchorRoundTripsThroughCodable() throws {
        let anchor = GeoAnchor(origin: seoul, bearingOfXAxis: 1.2)
        let decoded = try JSONDecoder().decode(
            GeoAnchor.self, from: JSONEncoder().encode(anchor)
        )
        XCTAssertEqual(decoded, anchor)
    }
}

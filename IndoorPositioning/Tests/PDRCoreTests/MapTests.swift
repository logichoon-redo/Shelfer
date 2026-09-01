//
//  MapTests.swift
//  PDRCoreTests
//

import XCTest
@testable import PDRCore

final class MapTests: XCTestCase {
    func testCrossingSegmentsIntersect() {
        XCTAssertTrue(Segment(0, 0, 10, 0).intersects(Segment(5, -5, 5, 5)))
        XCTAssertFalse(Segment(0, 0, 10, 0).intersects(Segment(5, 1, 5, 5)))
    }

    func testParallelSegmentsDoNotIntersectUnlessCollinear() {
        XCTAssertFalse(Segment(0, 0, 10, 0).intersects(Segment(0, 1, 10, 1)))
        XCTAssertTrue(Segment(0, 0, 10, 0).intersects(Segment(5, 0, 15, 0)))
        XCTAssertFalse(Segment(0, 0, 10, 0).intersects(Segment(11, 0, 15, 0)))
    }

    func testTouchingEndpointsCount() {
        XCTAssertTrue(Segment(0, 0, 10, 0).intersects(Segment(10, 0, 10, 5)))
    }

    func testClosestPointClampsToTheSegment() {
        let segment = Segment(0, 0, 10, 0)
        let beyond = segment.closestPoint(to: Point2D(x: 20, y: 3))
        XCTAssertEqual(beyond.point.x, 10, accuracy: 1e-9)
        XCTAssertEqual(beyond.t, 1, accuracy: 1e-9)

        let middle = segment.closestPoint(to: Point2D(x: 4, y: -2))
        XCTAssertEqual(middle.point.x, 4, accuracy: 1e-9)
        XCTAssertEqual(middle.distance, 2, accuracy: 1e-9)
    }

    /// An L-shaped corridor with walls, the smallest map that has a corner.
    private func corner() -> IndoorMap {
        IndoorMap(
            name: "L",
            walls: [
                Segment(-1.2, -1.2, 20, -1.2),
                Segment(-1.2, -1.2, -1.2, 20),
                Segment(1.2, 1.2, 1.2, 20),
                Segment(1.2, 1.2, 20, 1.2),
            ],
            corridors: [
                Corridor(id: "east", polyline: [Point2D(x: 0, y: 0), Point2D(x: 20, y: 0)], width: 2.4),
                Corridor(id: "north", polyline: [Point2D(x: 0, y: 0), Point2D(x: 0, y: 20)], width: 2.4),
            ],
            entryPoints: [MapEntryPoint(id: "door", position: .zero, heading: 0)]
        )
    }

    func testWalkableInsideTheBandAndNotOutside() {
        let index = MapIndex(map: corner())
        XCTAssertTrue(index.isWalkable(Point2D(x: 10, y: 0)))
        XCTAssertTrue(index.isWalkable(Point2D(x: 10, y: 1.0)))
        XCTAssertFalse(index.isWalkable(Point2D(x: 10, y: 4)))
        XCTAssertTrue(index.isWalkable(Point2D(x: 0, y: 15)))
    }

    func testWallCrossingIsDetected() {
        let index = MapIndex(map: corner())
        XCTAssertTrue(
            index.crossesWall(from: Point2D(x: 10, y: 0), to: Point2D(x: 10, y: -3)),
            "walking straight through the south wall must be rejected"
        )
        XCTAssertFalse(
            index.crossesWall(from: Point2D(x: 10, y: 0), to: Point2D(x: 10.7, y: 0)),
            "a normal step along the corridor must survive"
        )
    }

    func testCorridorAxesAreDiscreteAtACorner() {
        let index = MapIndex(map: corner())
        let axes = index.corridorAxes(near: Point2D(x: 0.5, y: 0.5))
        // This is the property the whole map constraint rests on: at a junction
        // there are two directions available, not a continuum.
        XCTAssertEqual(axes.count, 2)
        XCTAssertTrue(axes.contains { Angle.axialSeparation($0, 0) < Angle.degrees(5) })
        XCTAssertTrue(axes.contains { Angle.axialSeparation($0, .pi / 2) < Angle.degrees(5) })
    }

    func testProjectionReportsDistanceAndAxis() {
        let index = MapIndex(map: corner())
        guard let projection = index.projection(of: Point2D(x: 8, y: 0.7)) else {
            return XCTFail("expected a corridor projection")
        }
        XCTAssertEqual(projection.corridorID, "east")
        XCTAssertEqual(projection.distance, 0.7, accuracy: 1e-6)
        XCTAssertEqual(projection.halfWidth, 1.2, accuracy: 1e-9)
        XCTAssertEqual(Angle.axialSeparation(projection.axis, 0), 0, accuracy: 1e-9)
        XCTAssertEqual(projection.overhang, 0, accuracy: 1e-9)
    }

    func testProjectionStillAnswersOffPlan() {
        let index = MapIndex(map: corner())
        guard let projection = index.projection(of: Point2D(x: 8, y: 40)) else {
            return XCTFail("a point off the plan should still report how far off it is")
        }
        XCTAssertGreaterThan(projection.overhang, 30)
    }

    func testNormalizedAxisFoldsOppositeHeadings() {
        XCTAssertEqual(MapIndex.normalizedAxis(Angle.degrees(190)), Angle.degrees(10), accuracy: 1e-9)
        XCTAssertEqual(MapIndex.normalizedAxis(Angle.degrees(-170)), Angle.degrees(10), accuracy: 1e-9)
        XCTAssertEqual(MapIndex.normalizedAxis(Angle.degrees(90)), Angle.degrees(90), accuracy: 1e-9)
    }

    func testEmptyMapConstrainsNothing() {
        let index = MapIndex(map: IndoorMap())
        XCTAssertTrue(index.isWalkable(Point2D(x: 1000, y: -1000)))
        XCTAssertFalse(index.crossesWall(from: .zero, to: Point2D(x: 1000, y: 1000)))
        XCTAssertNil(index.projection(of: .zero))
    }

    func testMapRoundTripsThroughCodable() throws {
        let map = corner()
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(IndoorMap.self, from: data)
        XCTAssertEqual(decoded, map)
    }
}

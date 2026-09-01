//
//  MapIndex.swift
//  PDRCore
//

import Foundation

/// Where a point sits relative to the corridor network.
public struct CorridorProjection: Sendable, Equatable {
    public var corridorID: String
    /// Nearest point on the corridor centre line.
    public var point: Point2D
    /// Perpendicular distance from the query point to the centre line, metres.
    public var distance: Double
    /// Corridor direction there, radians CCW from map +X. This is an *axis* —
    /// the corridor may be walked in either direction.
    public var axis: Double
    /// Half-width of the corridor at that point.
    public var halfWidth: Double

    /// How far outside the walkable band the query point falls; 0 when inside.
    public var overhang: Double { max(0, distance - halfWidth) }
}

/// Spatial index over an `IndoorMap`.
///
/// Every particle tests a wall crossing on every step, so this is the hot path:
/// 500 particles times 2 steps a second times however many walls the plan has.
/// A uniform grid keeps that to the handful of walls near the step instead of
/// all of them.
/// Immutable after `init`, hence the unchecked conformance: the engine hands
/// the same index to every particle without copying it.
public final class MapIndex: @unchecked Sendable {
    public let map: IndoorMap

    private let cellSize: Double
    private let origin: Point2D
    private let columns: Int
    private let rows: Int
    // Written only in `init`; treated as immutable thereafter.
    private var wallCells: [[Int]]
    private var corridorCells: [[Int]]

    /// Flattened corridor segments, so a projection lookup does not rebuild
    /// them per query.
    private struct CorridorSegment {
        let corridorID: String
        let segment: Segment
        let halfWidth: Double
    }
    private let corridorSegments: [CorridorSegment]

    public init(map: IndoorMap, cellSize: Double = 4.0) {
        self.map = map
        self.cellSize = max(0.5, cellSize)

        var segments: [CorridorSegment] = []
        for corridor in map.corridors {
            let halfWidth = max(0.25, corridor.width / 2)
            for segment in corridor.segments {
                segments.append(
                    CorridorSegment(corridorID: corridor.id, segment: segment, halfWidth: halfWidth)
                )
            }
        }
        corridorSegments = segments

        // Pad the grid by the widest corridor so a projection query just
        // outside the plan still lands in a real cell.
        let widest = map.corridors.map(\.width).max() ?? 0
        let bounds = map.bounds ?? (Point2D.zero, Point2D(x: 1, y: 1))
        let pad = widest + self.cellSize
        origin = Point2D(x: bounds.min.x - pad, y: bounds.min.y - pad)
        let width = (bounds.max.x + pad) - origin.x
        let height = (bounds.max.y + pad) - origin.y
        columns = max(1, Int((width / self.cellSize).rounded(.up)))
        rows = max(1, Int((height / self.cellSize).rounded(.up)))

        wallCells = Array(repeating: [], count: columns * rows)
        corridorCells = Array(repeating: [], count: columns * rows)

        for (index, wall) in map.walls.enumerated() {
            for cell in cells(spanning: wall) { wallCells[cell].append(index) }
        }
        for (index, entry) in corridorSegments.enumerated() {
            // Corridor cells need the half-width bleed so a query point inside
            // the band but in a neighbouring cell still finds its corridor.
            for cell in cells(spanning: entry.segment, inflatedBy: entry.halfWidth) {
                corridorCells[cell].append(index)
            }
        }
    }

    // MARK: - Grid

    private func column(for x: Double) -> Int {
        min(columns - 1, max(0, Int(((x - origin.x) / cellSize).rounded(.down))))
    }

    private func row(for y: Double) -> Int {
        min(rows - 1, max(0, Int(((y - origin.y) / cellSize).rounded(.down))))
    }

    /// Cells overlapped by a segment's bounding box, optionally inflated.
    ///
    /// A bounding box is a superset of the true supercover, which is exactly
    /// what a broad phase wants: never miss a candidate, and let the exact test
    /// reject the rest.
    private func cells(spanning segment: Segment, inflatedBy inflation: Double = 0) -> [Int] {
        let minX = min(segment.a.x, segment.b.x) - inflation
        let maxX = max(segment.a.x, segment.b.x) + inflation
        let minY = min(segment.a.y, segment.b.y) - inflation
        let maxY = max(segment.a.y, segment.b.y) + inflation

        var result: [Int] = []
        let c0 = column(for: minX), c1 = column(for: maxX)
        let r0 = row(for: minY), r1 = row(for: maxY)
        result.reserveCapacity((c1 - c0 + 1) * (r1 - r0 + 1))
        for r in r0...r1 {
            for c in c0...c1 { result.append(r * columns + c) }
        }
        return result
    }

    // MARK: - Queries

    /// Whether walking from `from` to `to` would pass through a wall.
    ///
    /// This is the constraint that does most of the work in the particle
    /// filter: a particle whose heading has drifted will eventually try to walk
    /// through a wall, and gets killed for it.
    public func crossesWall(from: Point2D, to: Point2D) -> Bool {
        guard !map.walls.isEmpty else { return false }
        let step = Segment(a: from, b: to)
        var tested = Set<Int>()
        for cell in cells(spanning: step) {
            for index in wallCells[cell] where tested.insert(index).inserted {
                if map.walls[index].intersects(step) { return true }
            }
        }
        return false
    }

    /// Nearest corridor to a point, or `nil` when the map has no corridors or
    /// the point is nowhere near one.
    public func projection(of point: Point2D) -> CorridorProjection? {
        guard !corridorSegments.isEmpty else { return nil }
        let cell = row(for: point.y) * columns + column(for: point.x)

        var candidates = corridorCells[cell]
        if candidates.isEmpty {
            // Nothing indexed here — the point is off-plan. Fall back to a
            // full scan so the caller still gets a sensible "how far out" value
            // rather than a false "no corridors exist".
            candidates = Array(corridorSegments.indices)
        }

        var best: CorridorProjection?
        for index in candidates {
            let entry = corridorSegments[index]
            let closest = entry.segment.closestPoint(to: point)
            if best == nil || closest.distance < best!.distance {
                best = CorridorProjection(
                    corridorID: entry.corridorID,
                    point: closest.point,
                    distance: closest.distance,
                    axis: entry.segment.heading,
                    halfWidth: entry.halfWidth
                )
            }
        }
        return best
    }

    /// Whether a point lies inside the walkable band of some corridor.
    public func isWalkable(_ point: Point2D) -> Bool {
        guard let projection = projection(of: point) else {
            // A map with walls but no corridors still constrains movement; a
            // map with neither constrains nothing, and everywhere is walkable.
            return corridorSegments.isEmpty
        }
        return projection.distance <= projection.halfWidth
    }

    /// Corridor axes near a point, deduplicated.
    ///
    /// Only the point's own grid cell is consulted, so `radius` is effectively
    /// capped at the cell size. That is the right trade for the particle
    /// filter, which asks this question once per particle per step.
    ///
    /// Returned as axes in (-pi/2, pi/2] modulo pi: a corridor running
    /// north-south permits both northward and southward travel, and the
    /// constraint must not prefer one.
    public func corridorAxes(near point: Point2D, within radius: Double = 3.0) -> [Double] {
        guard !corridorSegments.isEmpty else { return [] }
        let cell = row(for: point.y) * columns + column(for: point.x)
        var axes: [Double] = []
        for index in corridorCells[cell] {
            let entry = corridorSegments[index]
            let closest = entry.segment.closestPoint(to: point)
            guard closest.distance <= max(radius, entry.halfWidth) else { continue }
            let axis = normalizedAxis(entry.segment.heading)
            if !axes.contains(where: { Angle.axialSeparation($0, axis) < Angle.degrees(5) }) {
                axes.append(axis)
            }
        }
        return axes
    }

    /// Folds a heading onto (-pi/2, pi/2] so that opposite directions along one
    /// corridor collapse to a single axis.
    public static func normalizedAxis(_ heading: Double) -> Double {
        var value = Angle.wrapToPi(heading)
        if value > .pi / 2 { value -= .pi }
        if value <= -.pi / 2 { value += .pi }
        return value
    }

    private func normalizedAxis(_ heading: Double) -> Double {
        MapIndex.normalizedAxis(heading)
    }
}

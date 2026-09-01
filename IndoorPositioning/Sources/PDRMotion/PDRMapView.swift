//
//  PDRMapView.swift
//  PDRMotion
//

import Foundation
import PDRCore

#if canImport(SwiftUI)
import SwiftUI

/// Draws the plan, the estimate, and — deliberately — the unconstrained dead
/// reckoning next to it.
///
/// Showing both tracks is not a debug affordance to strip later. A single dot
/// on a map reads as authoritative no matter how wrong it is; the pair makes
/// the system's actual state legible while the parameters are still being
/// tuned in a corridor.
@available(iOS 16.0, macOS 13.0, *)
public struct PDRMapView: View {
    public var map: IndoorMap?
    public var track: [Point2D]
    public var deadReckoningTrack: [Point2D]
    public var fix: PositionFix?
    /// Draw the raw dead-reckoning trail alongside the constrained one.
    public var showsDeadReckoning: Bool

    public init(
        map: IndoorMap?,
        track: [Point2D],
        deadReckoningTrack: [Point2D] = [],
        fix: PositionFix?,
        showsDeadReckoning: Bool = true
    ) {
        self.map = map
        self.track = track
        self.deadReckoningTrack = deadReckoningTrack
        self.fix = fix
        self.showsDeadReckoning = showsDeadReckoning
    }

    public var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let transform = Transform(map: map, track: track, size: size) else { return }
                draw(in: &context, transform: transform)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func draw(in context: inout GraphicsContext, transform: Transform) {
        if let map {
            var walls = Path()
            for wall in map.walls {
                walls.move(to: transform.point(wall.a))
                walls.addLine(to: transform.point(wall.b))
            }
            context.stroke(walls, with: .color(.primary.opacity(0.65)), lineWidth: 2)

            for corridor in map.corridors {
                var line = Path()
                guard let first = corridor.polyline.first else { continue }
                line.move(to: transform.point(first))
                for point in corridor.polyline.dropFirst() { line.addLine(to: transform.point(point)) }
                context.stroke(
                    line,
                    with: .color(.accentColor.opacity(0.18)),
                    style: StrokeStyle(
                        lineWidth: max(2, corridor.width * transform.scale),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }

            for anchor in map.anchors {
                let point = transform.point(anchor.position)
                let box = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.fill(Path(box), with: .color(.orange))
            }
        }

        if showsDeadReckoning, deadReckoningTrack.count > 1 {
            context.stroke(
                path(for: deadReckoningTrack, transform: transform),
                with: .color(.secondary.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        }

        if track.count > 1 {
            context.stroke(
                path(for: track, transform: transform),
                with: .color(.accentColor),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }

        guard let fix else { return }
        let centre = transform.point(fix.position)

        // Accuracy disc. An ambiguous filter gets a hollow ring: the estimate
        // is a guess between hypotheses, and it should not look like a fix.
        let radius = max(6, fix.horizontalAccuracy * transform.scale)
        let disc = Path(
            ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            )
        )
        if fix.isAmbiguous {
            context.stroke(disc, with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        } else {
            context.fill(disc, with: .color(.accentColor.opacity(0.18)))
        }

        var heading = Path()
        heading.move(to: centre)
        heading.addLine(
            to: CGPoint(
                x: centre.x + cos(fix.heading) * 18,
                y: centre.y - sin(fix.heading) * 18
            )
        )
        context.stroke(heading, with: .color(.accentColor), lineWidth: 2)

        let dot = CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: dot), with: .color(.accentColor))
    }

    private func path(for points: [Point2D], transform: Transform) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: transform.point(first))
        for point in points.dropFirst() { path.addLine(to: transform.point(point)) }
        return path
    }

    /// Map metres to view points, y flipped because map +Y is north and view
    /// +Y is down.
    fileprivate struct Transform {
        let scale: Double
        let originX: Double
        let originY: Double
        let height: Double

        init?(map: IndoorMap?, track: [Point2D], size: CGSize) {
            guard size.width > 1, size.height > 1 else { return nil }

            var minX = Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude

            func include(_ point: Point2D) {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            if let bounds = map?.bounds {
                include(bounds.min)
                include(bounds.max)
            }
            for point in track { include(point) }
            guard minX < maxX || minY < maxY else { return nil }

            let padding = 16.0
            let spanX = max(1, maxX - minX)
            let spanY = max(1, maxY - minY)
            scale = min(
                (Double(size.width) - padding * 2) / spanX,
                (Double(size.height) - padding * 2) / spanY
            )
            originX = padding - minX * scale
            originY = padding - minY * scale
            height = Double(size.height)
        }

        func point(_ value: Point2D) -> CGPoint {
            CGPoint(
                x: value.x * scale + originX,
                y: height - (value.y * scale + originY)
            )
        }
    }
}

#endif

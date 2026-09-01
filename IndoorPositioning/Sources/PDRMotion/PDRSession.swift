//
//  PDRSession.swift
//  PDRMotion
//

import Foundation
import PDRCore

#if canImport(Combine)
import Combine

/// Drives a `PDREngine` from a live `MotionSource` and republishes its output
/// on the main actor, ready to bind to a view.
///
/// The engine runs on the motion queue; only the fix crosses to the main
/// thread, once per step rather than once per sample.
@MainActor
public final class PDRSession: ObservableObject {
    @Published public private(set) var fix: PositionFix?
    @Published public private(set) var isRunning = false

    /// Trail of constrained positions in map metres, for drawing on a plan.
    @Published public private(set) var track: [Point2D] = []
    /// Trail of unconstrained dead-reckoning positions. Draw both: the gap
    /// between them is the map constraint doing its job, and it is the first
    /// thing to look at when a walk goes wrong.
    @Published public private(set) var deadReckoningTrack: [Point2D] = []

    /// The current estimate as a geographic coordinate, for drawing on a
    /// lat/lon map next to the system's own blue dot. `nil` until `geoAnchor`
    /// is set and a first step has landed.
    @Published public private(set) var coordinate: GeoCoordinate?
    /// The unconstrained dead-reckoning estimate, geographically.
    @Published public private(set) var deadReckoningCoordinate: GeoCoordinate?
    /// Trail of `coordinate`, for a map polyline.
    @Published public private(set) var coordinateTrack: [GeoCoordinate] = []

    /// Ties the plan's metre grid to the world. Set it before starting, or use
    /// `start(at:walkingBearing:)` which sets it for you.
    public var geoAnchor: GeoAnchor?

    public let map: IndoorMap?
    private let engine: PDREngine
    private let source: MotionSource
    private let maximumTrackLength: Int

    public init(
        map: IndoorMap?,
        source: MotionSource,
        configuration: PDREngine.Configuration = .default,
        maximumTrackLength: Int = 2000
    ) {
        self.map = map
        self.source = source
        self.maximumTrackLength = maximumTrackLength
        self.engine = PDREngine(map: map, configuration: configuration)

        source.onSample = { [engine] sample in
            guard let fix = engine.process(sample) else { return }
            Task { @MainActor [weak self] in
                self?.append(fix)
            }
        }
    }

    /// Starts at a known door or stair head. Prefer this when there is a plan:
    /// an entry point comes with a heading, and heading is the expensive half
    /// of the problem.
    public func start(at entry: MapEntryPoint) {
        engine.start(at: entry)
        beginStreaming(from: entry.position)
    }

    public func start(position: Point2D, heading: Double) {
        engine.start(position: position, heading: heading)
        beginStreaming(from: position)
    }

    /// Starts wherever the user is standing, with no plan and no survey.
    ///
    /// The map frame's origin becomes `coordinate` and its +X axis becomes the
    /// direction the user is about to walk, so the estimate begins exactly on
    /// top of whatever the system's own location says and diverges from there.
    /// That divergence is the measurement — this buys nothing for absolute
    /// accuracy, since the estimate inherits every metre of error in the fix it
    /// was seeded with.
    ///
    /// - Parameter walkingBearing: true bearing the user is about to walk,
    ///   radians clockwise from north.
    public func start(at coordinate: GeoCoordinate, walkingBearing: Double) {
        geoAnchor = GeoAnchor.here(coordinate, walkingBearing: walkingBearing)
        engine.start(position: .zero, heading: 0)
        beginStreaming(from: .zero)
    }

    public func stop() {
        source.stop()
        isRunning = false
    }

    /// Call when the user scans a marker. This is the only thing that restores
    /// accuracy rather than merely slowing its loss.
    @discardableResult
    public func observeAnchor(id: String) -> Bool {
        engine.observeAnchor(id: id)
    }

    /// Fits the stride model to a walk of known length, using the steps since
    /// `start`.
    @discardableResult
    public func calibrateStepLength(knownDistance: Double) -> Double? {
        engine.calibrateStepLength(knownDistance: knownDistance)
    }

    private func beginStreaming(from position: Point2D) {
        track = [position]
        deadReckoningTrack = [position]
        let seed = geoAnchor?.coordinate(for: position)
        coordinate = seed
        deadReckoningCoordinate = seed
        coordinateTrack = seed.map { [$0] } ?? []
        fix = nil
        isRunning = true
        source.start()
    }

    private func append(_ fix: PositionFix) {
        self.fix = fix
        track.append(fix.position)
        deadReckoningTrack.append(fix.deadReckoningPosition)
        trim(&track)
        trim(&deadReckoningTrack)

        guard let geoAnchor else { return }
        let mapped = geoAnchor.coordinate(for: fix.position)
        coordinate = mapped
        deadReckoningCoordinate = geoAnchor.coordinate(for: fix.deadReckoningPosition)
        coordinateTrack.append(mapped)
        trim(&coordinateTrack)
    }

    private func trim<Element>(_ values: inout [Element]) {
        guard values.count > maximumTrackLength else { return }
        values.removeFirst(values.count - maximumTrackLength)
    }
}

#endif

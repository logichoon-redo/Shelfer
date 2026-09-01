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
    /// Trail of constrained positions, for drawing.
    @Published public private(set) var track: [Point2D] = []
    /// Trail of unconstrained dead-reckoning positions. Draw both: the gap
    /// between them is the map constraint doing its job, and it is the first
    /// thing to look at when a walk goes wrong.
    @Published public private(set) var deadReckoningTrack: [Point2D] = []

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

    /// Starts at a known door or stair head. Prefer this: an entry point comes
    /// with a heading, and heading is the expensive half of the problem.
    public func start(at entry: MapEntryPoint) {
        engine.start(at: entry)
        beginStreaming(from: entry.position)
    }

    public func start(position: Point2D, heading: Double) {
        engine.start(position: position, heading: heading)
        beginStreaming(from: position)
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
        fix = nil
        isRunning = true
        source.start()
    }

    private func append(_ fix: PositionFix) {
        self.fix = fix
        track.append(fix.position)
        deadReckoningTrack.append(fix.deadReckoningPosition)
        if track.count > maximumTrackLength { track.removeFirst(track.count - maximumTrackLength) }
        if deadReckoningTrack.count > maximumTrackLength {
            deadReckoningTrack.removeFirst(deadReckoningTrack.count - maximumTrackLength)
        }
    }
}

#endif

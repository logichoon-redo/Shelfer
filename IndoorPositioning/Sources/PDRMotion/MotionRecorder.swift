//
//  MotionRecorder.swift
//  PDRMotion
//

import Foundation
import PDRCore

/// Captures a live IMU stream to a `MotionLog` CSV.
///
/// The corridor experiments are worth running once and replaying a hundred
/// times: re-walking 100 m after every parameter change is how a two-day
/// investigation becomes a two-week one. This is the recording half of that.
///
/// It can sit in front of a live positioning session rather than replacing it —
/// set `passthrough` and the same samples drive `PDREngine` while they are
/// being written down.
public final class MotionRecorder {
    private let source: MotionSource
    private let capacity: Int
    private let lock = NSLock()
    private var buffer: [MotionSample] = []
    private var dropped = 0

    /// Called for every sample, on the motion queue, before it is buffered.
    /// Use it to drive a live engine while recording.
    public var passthrough: ((MotionSample) -> Void)?

    /// - Parameter capacity: sample ceiling. 200k is about 65 minutes at 50 Hz
    ///   and roughly 30 MB of CSV. Recording is capped rather than unbounded so
    ///   a forgotten session cannot take the app down mid-walk.
    public init(source: MotionSource, capacity: Int = 200_000) {
        self.source = source
        self.capacity = capacity
        source.onSample = { [weak self] sample in
            self?.receive(sample)
        }
    }

    /// Samples captured so far.
    public var samples: [MotionSample] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// Samples discarded because `capacity` was reached. Non-zero means the
    /// recording is truncated and the ground-truth end point no longer matches.
    public var droppedSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    /// Seconds of data captured.
    public var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let first = buffer.first, let last = buffer.last else { return 0 }
        return last.timestamp - first.timestamp
    }

    public func start() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(min(capacity, 60_000))
        dropped = 0
        lock.unlock()
        source.start()
    }

    public func stop() {
        source.stop()
    }

    /// Writes the recording and returns the file it landed in.
    ///
    /// Defaults to the app's Documents directory. On iOS, add
    /// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` to
    /// `Info.plist` to pull the file off the device with the Files app, or hand
    /// the returned URL to a share sheet.
    @discardableResult
    public func writeLog(named name: String? = nil, in directory: URL? = nil) throws -> URL {
        let folder = try directory ?? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let url = folder.appendingPathComponent(name ?? Self.defaultName())
        try MotionLog.write(samples, to: url)
        return url
    }

    private func receive(_ sample: MotionSample) {
        passthrough?(sample)
        lock.lock()
        defer { lock.unlock() }
        guard buffer.count < capacity else {
            dropped += 1
            return
        }
        buffer.append(sample)
    }

    private static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "walk-\(formatter.string(from: Date())).csv"
    }
}

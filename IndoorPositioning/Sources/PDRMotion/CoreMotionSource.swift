//
//  CoreMotionSource.swift
//  PDRMotion
//

import Foundation
import PDRCore

#if canImport(CoreMotion) && (os(iOS) || os(watchOS))
import CoreMotion

/// Feeds `PDRCore` from CoreMotion.
///
/// Two details here are worth more than the rest of the file:
///
/// * **`xMagneticNorthZVertical`** is requested when the magnetometer is
///   available. Any other reference frame gives a heading relative to wherever
///   the phone happened to be pointing at start-up, which cannot be matched to
///   a floor plan without an extra alignment step.
/// * **The updates run on a private queue.** Delivering 50 Hz of device motion
///   to the main queue puts the whole pipeline behind whatever SwiftUI is doing.
///   The fix callback hops back to the main queue for UI, once per step rather
///   than once per sample.
public final class CoreMotionSource: NSObject, MotionSource {
    public var onSample: ((MotionSample) -> Void)?

    private let manager = CMMotionManager()
    private let queue: OperationQueue
    private let updateInterval: TimeInterval

    /// - Parameter sampleRate: Hz. 50 is plenty: gait energy lives below 3 Hz,
    ///   and the peak timing only needs to be good to a few tens of
    ///   milliseconds. 100 Hz doubles the power draw for nothing.
    public init(sampleRate: Double = 50) {
        precondition(sampleRate > 0)
        self.updateInterval = 1 / sampleRate
        self.queue = OperationQueue()
        self.queue.name = "PDRMotion.CoreMotionSource"
        self.queue.maxConcurrentOperationCount = 1
        self.queue.qualityOfService = .userInitiated
        super.init()
    }

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = updateInterval

        let frame: CMAttitudeReferenceFrame =
            CMMotionManager.availableAttitudeReferenceFrames()
                .contains(.xMagneticNorthZVertical)
                ? .xMagneticNorthZVertical
                : .xArbitraryZVertical

        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.onSample?(Self.sample(from: motion))
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Converts CoreMotion units to the package's.
    ///
    /// CoreMotion reports acceleration in g and its attitude quaternion as
    /// device-to-reference, which is the convention `MotionSample` documents.
    public static func sample(from motion: CMDeviceMotion) -> MotionSample {
        let quaternion = motion.attitude.quaternion
        let field = motion.magneticField

        return MotionSample(
            timestamp: motion.timestamp,
            userAcceleration: Vector3(
                motion.userAcceleration.x * standardGravity,
                motion.userAcceleration.y * standardGravity,
                motion.userAcceleration.z * standardGravity
            ),
            gravity: Vector3(
                motion.gravity.x * standardGravity,
                motion.gravity.y * standardGravity,
                motion.gravity.z * standardGravity
            ),
            rotationRate: Vector3(
                motion.rotationRate.x,
                motion.rotationRate.y,
                motion.rotationRate.z
            ),
            attitude: Quaternion(
                w: quaternion.w, x: quaternion.x, y: quaternion.y, z: quaternion.z
            ),
            magneticField: field.accuracy == .uncalibrated
                ? nil
                : Vector3(field.field.x, field.field.y, field.field.z),
            magneticFieldAccuracy: Int(field.accuracy.rawValue)
        )
    }
}

#endif

/// Replays a recorded or generated stream at wall-clock speed, or as fast as
/// possible. The offline half of the same interface the app uses on device, so
/// the pipeline under test is the pipeline that ships.
public final class ReplayMotionSource: MotionSource {
    public var onSample: ((MotionSample) -> Void)?

    private let samples: [MotionSample]
    private var isRunning = false

    public init(samples: [MotionSample]) {
        self.samples = samples
    }

    /// Delivers every sample synchronously on the calling thread.
    public func start() {
        isRunning = true
        for sample in samples {
            guard isRunning else { return }
            onSample?(sample)
        }
        isRunning = false
    }

    public func stop() { isRunning = false }
}

//
//  DragMonitorClient.swift
//  Shelfer
//

import ComposableArchitecture
import Foundation

enum DragEvent: Equatable, Sendable {
    case activityChanged(Bool, prefersPathOnlyDrop: Bool)
    case shelfRequested(CGPoint, prefersPathOnlyDrop: Bool)
    case dragEnded
}

/// Wraps the AppKit event machinery so the reducer sees only the two decisions
/// that matter. The polling and shake detection stay behind this boundary —
/// surfacing them as actions would flood the store at 50ms intervals for no gain,
/// since `ShakeDetector` is unit-tested directly.
struct DragMonitorClient {
    var events: @Sendable () async -> AsyncStream<DragEvent>
}

extension DragMonitorClient: DependencyKey {
    static let liveValue = DragMonitorClient(
        events: {
            AsyncStream { continuation in
                let setup = Task { @MainActor () -> DragMonitor in
                    let monitor = DragMonitor()
                    monitor.onDragActivityChanged = { isActive, prefersPathOnlyDrop in
                        continuation.yield(
                            .activityChanged(
                                isActive,
                                prefersPathOnlyDrop: prefersPathOnlyDrop
                            )
                        )
                    }
                    monitor.onShelfRequested = { point, prefersPathOnlyDrop in
                        continuation.yield(
                            .shelfRequested(
                                point,
                                prefersPathOnlyDrop: prefersPathOnlyDrop
                            )
                        )
                    }
                    monitor.onDragEnded = { continuation.yield(.dragEnded) }
                    monitor.start()
                    return monitor
                }

                continuation.onTermination = { _ in
                    Task { @MainActor in
                        await setup.value.stop()
                    }
                }
            }
        }
    )

    /// Never emits, so tests drive the reducer by sending actions directly.
    static let testValue = DragMonitorClient(
        events: { AsyncStream { _ in } }
    )
}

extension DependencyValues {
    var dragMonitor: DragMonitorClient {
        get { self[DragMonitorClient.self] }
        set { self[DragMonitorClient.self] = newValue }
    }
}

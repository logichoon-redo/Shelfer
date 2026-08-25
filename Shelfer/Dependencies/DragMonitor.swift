//
//  DragMonitor.swift
//  Shelfer
//

import AppKit

/// Watches system-wide mouse events for a shake (or Shift-hold) performed while a
/// drag is in flight, and reports where to summon a shelf.
@MainActor
final class DragMonitor {
    /// Reports whether the pointer is currently carrying pasteboard content.
    /// This drives drag-only affordances such as the sharing dock.
    var onDragActivityChanged: ((Bool) -> Void)?

    /// Called with the cursor location when the user asks for a shelf mid-drag.
    /// The shelf opens empty — items land only when the user actually drops them in.
    var onShelfRequested: ((CGPoint) -> Void)?

    /// Called once the drag that summoned a shelf has finished and any drop has
    /// had time to land, so an unused shelf can be dismissed.
    var onDragEnded: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var shakeDetector = ShakeDetector()
    private var pasteboardCountAtMouseDown = 0
    private var lastChangeCountCheck: TimeInterval = 0
    private var isDragActive = false
    private var hasTriggeredForCurrentDrag = false

    /// Bumped every time a shelf is summoned, so work scheduled for an earlier
    /// shelf can't act on a newer one.
    private var shelfGeneration = 0
    private var dragGeneration = 0
    private var dragEndTask: Task<Void, Never>?
    private var dragActivityEndTask: Task<Void, Never>?
    private var shiftHoldTask: Task<Void, Never>?

    private let shiftHoldDuration: Duration = .milliseconds(350)
    private let pollInterval: Duration = .milliseconds(50)
    private let changeCountThrottle: TimeInterval = 0.05
    private static let leftButtonMask = 1 << 0

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        // Mouse-only masks are readable without Accessibility permission. Adding
        // any keyboard event here — including .flagsChanged — would make macOS
        // require Accessibility trust, so Shift is read via NSEvent.modifierFlags
        // instead of by monitoring key events.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]

        // The monitor callbacks are delivered on the main run loop, so the
        // isolation assumption below holds; a Task hop would reorder events and
        // break shake detection.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil

        dragEndTask?.cancel()
        dragEndTask = nil
        dragActivityEndTask?.cancel()
        dragActivityEndTask = nil
        endDrag()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            beginTracking(event)
        case .leftMouseDragged:
            handleDrag(event)
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
    }

    private func beginTracking(_ event: NSEvent) {
        // A pending drag-end check is deliberately left running: it belongs to the
        // previous shelf and is guarded by `shelfGeneration`, so a quick follow-up
        // click can't strand an unused shelf on screen.
        shiftHoldTask?.cancel()
        dragGeneration &+= 1
        shakeDetector.reset()
        // Preserve the first leg of the gesture. Drag-session detection happens
        // after movement begins, so without this starting point the initial
        // up/down or left/right stroke is silently shortened.
        shakeDetector.addSample(point: NSEvent.mouseLocation, time: event.timestamp)
        pasteboardCountAtMouseDown = DragSession.changeCount
        lastChangeCountCheck = event.timestamp
        isDragActive = false
        hasTriggeredForCurrentDrag = false
    }

    private func handleDrag(_ event: NSEvent) {
        if !isDragActive {
            detectDragStart(event)
            guard isDragActive else { return }
        }

        guard !hasTriggeredForCurrentDrag else { return }

        if shakeDetector.addSample(point: NSEvent.mouseLocation, time: event.timestamp) {
            trigger(at: NSEvent.mouseLocation)
        }
    }

    /// A new drag session bumps the drag pasteboard's change count. Reading it is
    /// an IPC round trip, so it's throttled — plain mouse drags (rubber-band
    /// selection, say) would otherwise query it on every event.
    private func detectDragStart(_ event: NSEvent) {
        guard event.timestamp - lastChangeCountCheck >= changeCountThrottle else { return }
        lastChangeCountCheck = event.timestamp

        guard DragSession.changeCount > pasteboardCountAtMouseDown else { return }
        isDragActive = true
        onDragActivityChanged?(true)
        waitForDragActivityToFinish()
        startShiftHoldWatch()
    }

    /// A drag session may consume the mouse-up event. Polling the physical
    /// button guarantees that drag-only UI is hidden as soon as the item is no
    /// longer attached to the pointer, even when no shelf was summoned.
    private func waitForDragActivityToFinish() {
        let generation = dragGeneration
        dragActivityEndTask?.cancel()
        dragActivityEndTask = Task { [weak self] in
            guard let self else { return }

            while NSEvent.pressedMouseButtons & Self.leftButtonMask != 0 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: pollInterval)
            }

            guard !Task.isCancelled, generation == dragGeneration else { return }
            endDrag()
        }
    }

    /// Shift-hold is timed independently of mouse movement: `.leftMouseDragged`
    /// only arrives while the cursor moves, so holding Shift still would never
    /// accumulate any hold time.
    private func startShiftHoldWatch() {
        let generation = shelfGeneration
        shiftHoldTask?.cancel()
        shiftHoldTask = Task { [weak self] in
            var held: Duration = .zero

            while !Task.isCancelled {
                guard let self,
                      generation == shelfGeneration,
                      isDragActive,
                      !hasTriggeredForCurrentDrag else { return }

                if NSEvent.modifierFlags.contains(.shift) {
                    held += pollInterval
                    if held >= shiftHoldDuration {
                        trigger(at: NSEvent.mouseLocation)
                        return
                    }
                } else {
                    held = .zero
                }

                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func trigger(at location: CGPoint) {
        guard !hasTriggeredForCurrentDrag else { return }
        hasTriggeredForCurrentDrag = true
        shelfGeneration &+= 1
        shiftHoldTask?.cancel()

        onShelfRequested?(location)
        waitForDragToFinish()
    }

    /// A drag session can swallow the `.leftMouseUp` event, so the button state is
    /// polled directly rather than waiting for an event that may never arrive.
    private func waitForDragToFinish() {
        let generation = shelfGeneration
        dragEndTask?.cancel()
        dragEndTask = Task { [weak self] in
            guard let self else { return }

            while NSEvent.pressedMouseButtons & Self.leftButtonMask != 0 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: pollInterval)
            }

            // Give a drop onto the shelf time to register before judging it unused.
            try? await Task.sleep(for: .milliseconds(250))

            guard !Task.isCancelled, generation == shelfGeneration else { return }
            onDragEnded?()
        }
    }

    private func endDrag() {
        let wasActive = isDragActive
        dragActivityEndTask?.cancel()
        dragActivityEndTask = nil
        shiftHoldTask?.cancel()
        shiftHoldTask = nil
        isDragActive = false
        hasTriggeredForCurrentDrag = false
        shakeDetector.reset()
        if wasActive {
            onDragActivityChanged?(false)
        }
    }
}

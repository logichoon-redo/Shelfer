//
//  ShelfSurface.swift
//  Shelfer
//

import AppKit
import SwiftUI

enum ShelfFileDropMode: Equatable {
    case files
    case paths
}

/// The shelf's interactive backing: it accepts dropped files and text, and moves
/// the panel when dragged by an empty area.
///
/// Both behaviours live in one view on purpose. As separate stacked layers the
/// upper one swallows `mouseDown` before the lower one sees it, which silently
/// disables dragging the shelf around.
///
/// Drops are read straight off the pasteboard in `performDragOperation`.
/// SwiftUI's `.onDrop` hands back `NSItemProvider`s that must be read
/// asynchronously, which re-enters the drag machinery while the session is still
/// closing (`kDragIPC…` reentrancy warnings, and drops that never complete).
struct ShelfSurface: NSViewRepresentable {
    var prefersPathOnlyDrop = false
    var protectsTopLeftControl = false
    var protectsTopRightControl = false
    var topControlOuterInset = ShelfMetrics.buttonOuterInset
    var onTargetedChange: (Bool) -> Void = { _ in }
    var onFilesTargetedChange: (Bool) -> Void = { _ in }
    var onPathOnlyChange: (Bool) -> Void = { _ in }
    var onHoverChange: (Bool) -> Void = { _ in }
    var onDrop: ([ShelfItem.Content]) -> Void = { _ in }

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.registerForDraggedTypes([.fileURL, .string])
        view.prefersPathOnlyDrop = prefersPathOnlyDrop
        view.protectsTopLeftControl = protectsTopLeftControl
        view.protectsTopRightControl = protectsTopRightControl
        view.topControlOuterInset = topControlOuterInset
        view.onTargetedChange = onTargetedChange
        view.onFilesTargetedChange = onFilesTargetedChange
        view.onPathOnlyChange = onPathOnlyChange
        view.onHoverChange = onHoverChange
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: SurfaceView, context: Context) {
        nsView.prefersPathOnlyDrop = prefersPathOnlyDrop
        nsView.protectsTopLeftControl = protectsTopLeftControl
        nsView.protectsTopRightControl = protectsTopRightControl
        nsView.topControlOuterInset = topControlOuterInset
        nsView.onTargetedChange = onTargetedChange
        nsView.onFilesTargetedChange = onFilesTargetedChange
        nsView.onPathOnlyChange = onPathOnlyChange
        nsView.onHoverChange = onHoverChange
        nsView.onDrop = onDrop
    }

    final class SurfaceView: NSView {
        var onTargetedChange: (Bool) -> Void = { _ in }
        var onFilesTargetedChange: (Bool) -> Void = { _ in }
        var onPathOnlyChange: (Bool) -> Void = { _ in }
        var onHoverChange: (Bool) -> Void = { _ in }
        var onDrop: ([ShelfItem.Content]) -> Void = { _ in }
        var prefersPathOnlyDrop = false
        var protectsTopLeftControl = false
        var protectsTopRightControl = false
        var topControlOuterInset = ShelfMetrics.buttonOuterInset

        private var hoverTrackingArea: NSTrackingArea?
        private var hasFileURLs = false
        private var fileDropMode: ShelfFileDropMode = .files
        private var preparedPayload: PreparedDropPayload?
        private var activeDraggingSequenceNumber: Int?
        private var hasLatchedPathOnlyDrop = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            hoverTrackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange(false)
        }

        // MARK: - Moving the panel

        /// Let a click-drag reach the surface even while another application is
        /// active. Without this, AppKit consumes the first mouse-down only to
        /// activate the panel, so moving the shelf requires a second attempt.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        /// AppKit-backed SwiftUI views can be reordered while a shelf is
        /// created in the middle of a cross-application drag. If the full-size
        /// surface temporarily sits above a transparent button overlay, yield
        /// these two circles so the complete button—not only its opaque SF
        /// Symbol—continues to receive the first click.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if protectsTopLeftControl,
               topControlContains(point, at: .left) {
                return nil
            }
            if protectsTopRightControl,
               topControlContains(point, at: .right) {
                return nil
            }
            return super.hitTest(point)
        }

        private enum ControlEdge {
            case left
            case right
        }

        private func topControlFrame(at edge: ControlEdge) -> CGRect {
            let diameter = ShelfMetrics.buttonHitDiameter
            let x = edge == .left
                ? bounds.minX + topControlOuterInset
                : bounds.maxX - topControlOuterInset - diameter
            let y = isFlipped
                ? bounds.minY + topControlOuterInset
                : bounds.maxY - topControlOuterInset - diameter
            return CGRect(x: x, y: y, width: diameter, height: diameter)
        }

        private func topControlContains(_ point: CGPoint, at edge: ControlEdge) -> Bool {
            let frame = topControlFrame(at: edge)
            let radius = frame.width / 2
            return hypot(point.x - frame.midX, point.y - frame.midY) <= radius
        }

        override func mouseDown(with event: NSEvent) {
            if let panel = window as? ShelfPanel {
                panel.performShelfDrag(with: event)
            } else {
                window?.performDrag(with: event)
            }
        }

        // MARK: - Receiving drops

        /// A drag that started on this shelf must not be re-accepted by it: the
        /// drop would re-add the item and the drag's completion would then remove
        /// it, so releasing an item back over the shelf would make it vanish.
        private func isOwnDrag(_ sender: NSDraggingInfo) -> Bool {
            sender.draggingSource is ShelfDragSource.DragSourceView
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard !isOwnDrag(sender) else { return [] }
            NSLog("[Shelfer] draggingEntered types=%@", sender.draggingPasteboard.types?.map(\.rawValue) ?? [])
            updateFileDropMode(for: sender)
            onTargetedChange(true)
            ShelfHaptics.alignment()
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard !isOwnDrag(sender) else { return [] }
            updateFileDropMode(for: sender)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargetedChange(false)
            resetDropPresentation()
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargetedChange(false)
            resetDropSession()
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            updateFileDropMode(for: sender)
            let ok = !isOwnDrag(sender)
                && !contents(for: sender).isEmpty
            NSLog("[Shelfer] prepareForDragOperation -> %@", ok ? "true" : "false")
            return ok
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard !isOwnDrag(sender) else { return false }
            updateFileDropMode(for: sender)
            let contents = contents(for: sender)
            NSLog("[Shelfer] performDragOperation contents=%d", contents.count)
            guard !contents.isEmpty else { return false }

            // Deferred out of the drag callback: showing or resizing the panel
            // here re-enters the drag session.
            DispatchQueue.main.async { [onDrop] in
                onDrop(contents)
            }
            ShelfActiveDragIntent.consume()
            resetDropSession()
            return true
        }

        /// `prepareForDragOperation` and `performDragOperation` describe the
        /// same pasteboard payload. Materializing hundreds of Finder URLs in
        /// both callbacks doubles the most expensive synchronous drop work, so
        /// retain the first result for the remainder of that drag sequence.
        private func contents(for sender: NSDraggingInfo) -> [ShelfItem.Content] {
            let sequenceNumber = sender.draggingSequenceNumber
            if let preparedPayload,
               preparedPayload.sequenceNumber == sequenceNumber,
               preparedPayload.mode == fileDropMode {
                return preparedPayload.contents
            }

            let contents = Self.contents(
                from: sender.draggingPasteboard,
                fileDropMode: fileDropMode
            )
            preparedPayload = PreparedDropPayload(
                sequenceNumber: sequenceNumber,
                mode: fileDropMode,
                contents: contents
            )
            return contents
        }

        private func updateFileDropMode(for sender: NSDraggingInfo) {
            if activeDraggingSequenceNumber != sender.draggingSequenceNumber {
                activeDraggingSequenceNumber = sender.draggingSequenceNumber
                hasLatchedPathOnlyDrop = false
                preparedPayload = nil
            }

            let newHasFileURLs = Self.hasFileURLs(in: sender.draggingPasteboard)
            if newHasFileURLs != hasFileURLs {
                hasFileURLs = newHasFileURLs
                onFilesTargetedChange(newHasFileURLs)
            }
            let observedMode = Self.fileDropMode(
                modifierFlags: NSEvent.modifierFlags,
                pasteboard: sender.draggingPasteboard,
                prefersPathOnlyDrop: prefersPathOnlyDrop
                    || ShelfActiveDragIntent.prefersPathOnlyDrop
            )
            if observedMode == .paths {
                hasLatchedPathOnlyDrop = true
            }
            let newMode: ShelfFileDropMode = hasLatchedPathOnlyDrop ? .paths : .files
            guard newMode != fileDropMode else { return }
            fileDropMode = newMode
            onPathOnlyChange(newMode == .paths)
            ShelfHaptics.alignment()
        }

        private func resetDropSession() {
            activeDraggingSequenceNumber = nil
            hasLatchedPathOnlyDrop = false
            resetDropPresentation()
        }

        private func resetDropPresentation() {
            preparedPayload = nil
            if hasFileURLs {
                hasFileURLs = false
                onFilesTargetedChange(false)
            }
            guard fileDropMode != .files else { return }
            fileDropMode = .files
            onPathOnlyChange(false)
        }

        private static func hasFileURLs(in pasteboard: NSPasteboard) -> Bool {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            return pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
        }

        /// Checks only the advertised pasteboard types. Unlike `contents`, this
        /// does not instantiate every URL and is safe to call from high-rate
        /// `draggingUpdated` callbacks.
        static func canAcceptContents(from pasteboard: NSPasteboard) -> Bool {
            if hasFileURLs(in: pasteboard) {
                return true
            }
            return pasteboard.canReadObject(
                forClasses: [NSString.self],
                options: nil
            )
        }

        static func fileDropMode(
            modifierFlags: NSEvent.ModifierFlags,
            pasteboard: NSPasteboard,
            prefersPathOnlyDrop: Bool = false,
            sessionModifierFlags: CGEventFlags? = nil
        ) -> ShelfFileDropMode {
            guard prefersPathOnlyDrop
                    || ShelfModifierState.optionIsPressed(
                        eventFlags: modifierFlags,
                        sessionFlags: sessionModifierFlags
                    ) else {
                return .files
            }
            return hasFileURLs(in: pasteboard)
                ? .paths
                : .files
        }

        /// Files win over text: a dragged file also advertises its path as a
        /// string, which is not what the user dragged.
        static func contents(
            from pasteboard: NSPasteboard,
            fileDropMode: ShelfFileDropMode = .files
        ) -> [ShelfItem.Content] {
            let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
               !urls.isEmpty {
                switch fileDropMode {
                case .files:
                    return urls.map { .file($0) }
                case .paths:
                    return urls.map { .path($0.standardizedFileURL.path) }
                }
            }

            if let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] {
                return strings.filter { !$0.isEmpty }.map { .text($0) }
            }

            return []
        }

        private struct PreparedDropPayload {
            let sequenceNumber: Int
            let mode: ShelfFileDropMode
            let contents: [ShelfItem.Content]
        }
    }
}

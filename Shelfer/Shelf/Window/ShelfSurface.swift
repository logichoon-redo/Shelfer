//
//  ShelfSurface.swift
//  Shelfer
//

import AppKit
import SwiftUI

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
    var onTargetedChange: (Bool) -> Void = { _ in }
    var onDrop: ([ShelfItem.Content]) -> Void = { _ in }

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.registerForDraggedTypes([.fileURL, .string])
        view.onTargetedChange = onTargetedChange
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: SurfaceView, context: Context) {
        nsView.onTargetedChange = onTargetedChange
        nsView.onDrop = onDrop
    }

    final class SurfaceView: NSView {
        var onTargetedChange: (Bool) -> Void = { _ in }
        var onDrop: ([ShelfItem.Content]) -> Void = { _ in }

        // MARK: - Moving the panel

        /// Let a click-drag reach the surface even while another application is
        /// active. Without this, AppKit consumes the first mouse-down only to
        /// activate the panel, so moving the shelf requires a second attempt.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
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
            onTargetedChange(true)
            ShelfHaptics.alignment()
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargetedChange(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargetedChange(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let ok = !isOwnDrag(sender) && !Self.contents(from: sender.draggingPasteboard).isEmpty
            NSLog("[Shelfer] prepareForDragOperation -> %@", ok ? "true" : "false")
            return ok
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard !isOwnDrag(sender) else { return false }
            let contents = Self.contents(from: sender.draggingPasteboard)
            NSLog("[Shelfer] performDragOperation contents=%d", contents.count)
            guard !contents.isEmpty else { return false }

            // Deferred out of the drag callback: showing or resizing the panel
            // here re-enters the drag session.
            DispatchQueue.main.async { [onDrop] in
                onDrop(contents)
            }
            return true
        }

        /// Files win over text: a dragged file also advertises its path as a
        /// string, which is not what the user dragged.
        static func contents(from pasteboard: NSPasteboard) -> [ShelfItem.Content] {
            let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
               !urls.isEmpty {
                return urls.map { .file($0) }
            }

            if let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] {
                return strings.filter { !$0.isEmpty }.map { .text($0) }
            }

            return []
        }
    }
}

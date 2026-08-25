//
//  ShelfDragSource.swift
//  C5
//

import AppKit
import SwiftUI

/// Transparent overlay that drags every shelf item out at once.
///
/// SwiftUI's `.draggable` carries a single item, which would silently drop all but
/// one, so the drag session is started through AppKit instead. Items are written
/// to the pasteboard in their native form — a file URL stays a file, and text goes
/// out as text, so dropping it on a text field inserts the string.
struct ShelfDragSource: NSViewRepresentable {
    let contents: [ShelfItem.Content]
    /// Called with the dragged contents once they have landed somewhere.
    /// Not called when the drag is cancelled.
    var onCompleted: ([ShelfItem.Content]) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.contents = contents
        view.onCompleted = onCompleted
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.contents = contents
        nsView.onCompleted = onCompleted
        nsView.onDoubleClick = onDoubleClick
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var contents: [ShelfItem.Content] = []
        var onCompleted: ([ShelfItem.Content]) -> Void = { _ in }
        var onDoubleClick: () -> Void = {}

        /// A single click is left unhandled so it can still start a drag.
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else { return }
            onDoubleClick()
        }

        /// Snapshot taken when the drag begins, so a shelf that changes mid-drag
        /// can't confuse what actually left.
        private var draggedContents: [ShelfItem.Content] = []

        override func mouseDragged(with event: NSEvent) {
            guard !contents.isEmpty else { return }

            let items = contents.map { content -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: content.pasteboardWriter)
                item.setDraggingFrame(bounds, contents: ShelfItem(content).icon)
                return item
            }

            // Some rich-text composers (Slack, Zoom) accept the drop but never
            // insert anything. Mirroring the payload onto the clipboard means the
            // user can always fall back to ⌘V instead of losing the gesture.
            copyToClipboard(contents)

            draggedContents = contents
            beginDraggingSession(with: items, event: event, source: self)
        }

        private func copyToClipboard(_ contents: [ShelfItem.Content]) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(contents.map(\.pasteboardWriter))
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            let dragged = draggedContents.isEmpty ? contents : draggedContents
            let carriesFile = dragged.contains { if case .file = $0 { true } else { false } }

            // Only a file can meaningfully be moved — the destination relocates it.
            // Text is always handed over as a copy: offering .move lets a receiver
            // (Slack, for one) settle on it and then insert nothing.
            return carriesFile ? [.copy, .move, .generic] : .copy
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            NSLog("[C5] dragOut ended operation=%lu count=%d", operation.rawValue, draggedContents.count)
            let completed = draggedContents
            draggedContents = []

            // An empty operation means the drop was rejected or cancelled,
            // so the items stay on the shelf.
            guard !operation.isEmpty, !completed.isEmpty else { return }

            // Deferred out of the drag callback: removing the last item hides the
            // panel, and ordering a window out while the session is still closing
            // re-enters the drag machinery. Destinations that hand the drop to
            // another process (Chromium apps such as Slack and Zoom) lose the
            // payload when that happens.
            DispatchQueue.main.async { [onCompleted] in
                onCompleted(completed)
            }
        }
    }
}

private extension ShelfItem.Content {
    var pasteboardWriter: NSPasteboardWriting {
        switch self {
        case let .file(url):
            url as NSURL
        case let .text(text):
            // Carries the string itself *and* a promise of a .txt file, so an
            // editor inserts the text while a composer that only takes files
            // (Slack, Zoom) receives a file instead of silently dropping it.
            TextFilePromise(text: text)
        }
    }
}

//
//  ShelfDragSource.swift
//  Shelfer
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
    var onDragActiveChange: (Bool) -> Void = { _ in }
    var onSelection: () -> Void = {}
    var onContextMenu: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onCopy: ([ShelfItem.Content]) -> Void = { _ in }
    var onShare: (ShelfShareMethod) -> Void = { _ in }
    var onShowInFinder: ([ShelfItem.Content]) -> Void = { _ in }
    var onKeepPathsOnly: (() -> Void)?
    var onClear: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.contents = contents
        view.onCompleted = onCompleted
        view.onDragActiveChange = onDragActiveChange
        view.onSelection = onSelection
        view.onContextMenu = onContextMenu
        view.onDoubleClick = onDoubleClick
        view.onCopy = onCopy
        view.onShare = onShare
        view.onShowInFinder = onShowInFinder
        view.onKeepPathsOnly = onKeepPathsOnly
        view.onClear = onClear
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.contents = contents
        nsView.onCompleted = onCompleted
        nsView.onDragActiveChange = onDragActiveChange
        nsView.onSelection = onSelection
        nsView.onContextMenu = onContextMenu
        nsView.onDoubleClick = onDoubleClick
        nsView.onCopy = onCopy
        nsView.onShare = onShare
        nsView.onShowInFinder = onShowInFinder
        nsView.onKeepPathsOnly = onKeepPathsOnly
        nsView.onClear = onClear
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var contents: [ShelfItem.Content] = []
        var onCompleted: ([ShelfItem.Content]) -> Void = { _ in }
        var onDragActiveChange: (Bool) -> Void = { _ in }
        var onSelection: () -> Void = {}
        var onContextMenu: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        var onCopy: ([ShelfItem.Content]) -> Void = { _ in }
        var onShare: (ShelfShareMethod) -> Void = { _ in }
        var onShowInFinder: ([ShelfItem.Content]) -> Void = { _ in }
        var onKeepPathsOnly: (() -> Void)?
        var onClear: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            didBeginDragging = false
            mouseDownLocation = Self.pointerLocation(for: event)
            if event.clickCount == 2 {
                onDoubleClick()
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                didBeginDragging = false
                mouseDownLocation = nil
            }
            guard event.clickCount == 1, !didBeginDragging else { return }
            onSelection()
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard !contents.isEmpty else { return nil }

            let menu = NSMenu()
            let copyItem = NSMenuItem(
                title: "Copy",
                action: #selector(copyMenuItemSelected(_:)),
                keyEquivalent: "c"
            )
            copyItem.target = self
            copyItem.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: "Copy"
            )
            menu.addItem(copyItem)
            menu.addItem(.separator())

            let hasFiles = contents.contains(where: \.isFile)
            let showInFinderItem = NSMenuItem(
                title: "Show in Finder",
                action: hasFiles ? #selector(showInFinderMenuItemSelected(_:)) : nil,
                keyEquivalent: ""
            )
            if hasFiles {
                showInFinderItem.target = self
            }
            showInFinderItem.isEnabled = hasFiles
            showInFinderItem.image = NSImage(
                systemSymbolName: "folder",
                accessibilityDescription: "Show in Finder"
            )
            menu.addItem(showInFinderItem)

            if hasFiles, onKeepPathsOnly != nil {
                let keepPathsItem = NSMenuItem(
                    title: "Keep Paths Only",
                    action: #selector(keepPathsOnlyMenuItemSelected(_:)),
                    keyEquivalent: ""
                )
                keepPathsItem.target = self
                keepPathsItem.image = NSImage(
                    systemSymbolName: "terminal",
                    accessibilityDescription: "Keep Paths Only"
                )
                menu.addItem(keepPathsItem)
            }
            menu.addItem(.separator())

            let shareItem = NSMenuItem(
                title: "Share",
                action: nil,
                keyEquivalent: ""
            )
            shareItem.image = NSImage(
                systemSymbolName: "square.and.arrow.up",
                accessibilityDescription: "Share"
            )

            let shareMenu = NSMenu(title: "Share")
            for method in ShelfShareMethod.allCases {
                let item = NSMenuItem(
                    title: method.title,
                    action: #selector(shareMenuItemSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = method.rawValue
                if method == .airDrop, let airDrop = ShelfShareIcons.airDrop {
                    let menuImage = (airDrop.copy() as? NSImage) ?? airDrop
                    menuImage.size = NSSize(width: 16, height: 16)
                    item.image = menuImage
                } else {
                    item.image = NSImage(
                        systemSymbolName: method.systemImageName,
                        accessibilityDescription: method.title
                    )
                }
                shareMenu.addItem(item)
            }

            shareItem.submenu = shareMenu
            menu.addItem(shareItem)

            if onClear != nil {
                menu.addItem(.separator())

                let clearItem = NSMenuItem(
                    title: "Clear",
                    action: #selector(clearMenuItemSelected(_:)),
                    keyEquivalent: ""
                )
                clearItem.target = self
                clearItem.image = NSImage(
                    systemSymbolName: "trash",
                    accessibilityDescription: "Clear"
                )
                menu.addItem(clearItem)
            }
            return menu
        }

        override func rightMouseDown(with event: NSEvent) {
            onContextMenu()
            guard let menu = menu(for: event) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func shareMenuItemSelected(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let method = ShelfShareMethod(rawValue: rawValue) else { return }
            onShare(method)
        }

        @objc private func copyMenuItemSelected(_ sender: NSMenuItem) {
            onCopy(contents)
        }

        @objc private func showInFinderMenuItemSelected(_ sender: NSMenuItem) {
            onShowInFinder(contents)
        }

        @objc private func keepPathsOnlyMenuItemSelected(_ sender: NSMenuItem) {
            onKeepPathsOnly?()
        }

        @objc private func clearMenuItemSelected(_ sender: NSMenuItem) {
            onClear?()
        }

        /// Snapshot taken when the drag begins, so a shelf that changes mid-drag
        /// can't confuse what actually left.
        private var draggedContents: [ShelfItem.Content] = []
        private var completedAsShare = false
        private var didBeginDragging = false
        private var mouseDownLocation: CGPoint?

        static let dragActivationDistance: CGFloat = 4

        static func hasExceededDragThreshold(from start: CGPoint, to current: CGPoint) -> Bool {
            let horizontalDistance = current.x - start.x
            let verticalDistance = current.y - start.y
            return hypot(horizontalDistance, verticalDistance) >= dragActivationDistance
        }

        /// Window-local coordinates can jump when the first click arrives while
        /// another app is active. Core Graphics keeps both events in the same
        /// global coordinate space, making click-versus-drag deterministic.
        private static func pointerLocation(for event: NSEvent) -> CGPoint {
            event.cgEvent?.location ?? event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard !contents.isEmpty,
                  !didBeginDragging,
                  let mouseDownLocation,
                  Self.hasExceededDragThreshold(
                    from: mouseDownLocation,
                    to: Self.pointerLocation(for: event)
                  ) else { return }
            didBeginDragging = true

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
            completedAsShare = false
            onDragActiveChange(true)
            beginDraggingSession(with: items, event: event, source: self)
        }

        func markAsShared() {
            completedAsShare = true
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
            NSLog("[Shelfer] dragOut ended operation=%lu count=%d", operation.rawValue, draggedContents.count)
            onDragActiveChange(false)
            let completed = draggedContents
            let wasShared = completedAsShare
            draggedContents = []
            completedAsShare = false

            // An empty operation means the drop was rejected or cancelled,
            // so the items stay on the shelf.
            guard !wasShared, !operation.isEmpty, !completed.isEmpty else { return }

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
    var isFile: Bool {
        if case .file = self { true } else { false }
    }
}

extension ShelfItem.Content {
    var pasteboardWriter: NSPasteboardWriting {
        switch self {
        case let .file(url):
            url as NSURL
        case let .path(path):
            // Deliberately advertise plain text only. A file promise here would
            // let an AI client treat the referenced file as an attachment.
            path as NSString
        case let .text(text):
            // Carries the string itself *and* a promise of a .txt file, so an
            // editor inserts the text while a composer that only takes files
            // (Slack, Zoom) receives a file instead of silently dropping it.
            TextFilePromise(text: text)
        }
    }
}

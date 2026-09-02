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
    var itemIDs: [ShelfItem.ID] = []
    var reorderScopeID: ShelfFeature.State.ID?
    var reorderTargetID: ShelfItem.ID?
    var reorderAxis: Axis = .horizontal
    var reorderContainerSize: CGSize?
    var itemLabel: String?
    var isSelected = false
    var acceptsExternalDrops = false
    var prefersPathOnlyDrop = false
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
    var onExternalTargetedChange: (Bool) -> Void = { _ in }
    var onExternalFilesTargetedChange: (Bool) -> Void = { _ in }
    var onExternalPathOnlyChange: (Bool) -> Void = { _ in }
    var onExternalDrop: ([ShelfItem.Content]) -> Void = { _ in }
    var onReorder: ((
        [ShelfItem.ID],
        ShelfItem.ID,
        ShelfReorderPlacement
    ) -> Void)?

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.registerForDraggedTypes([.fileURL, .string])
        view.contents = contents
        view.itemIDs = itemIDs
        view.reorderScopeID = reorderScopeID
        view.reorderTargetID = reorderTargetID
        view.reorderAxis = reorderAxis
        view.reorderContainerSize = reorderContainerSize
        view.itemLabel = itemLabel
        view.isSelected = isSelected
        view.acceptsExternalDrops = acceptsExternalDrops
        view.prefersPathOnlyDrop = prefersPathOnlyDrop
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
        view.onTargetedChange = onExternalTargetedChange
        view.onFilesTargetedChange = onExternalFilesTargetedChange
        view.onPathOnlyChange = onExternalPathOnlyChange
        view.onDrop = onExternalDrop
        view.onReorder = onReorder
        view.updateAccessibility()
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.contents = contents
        nsView.itemIDs = itemIDs
        nsView.reorderScopeID = reorderScopeID
        nsView.reorderTargetID = reorderTargetID
        nsView.reorderAxis = reorderAxis
        nsView.reorderContainerSize = reorderContainerSize
        nsView.itemLabel = itemLabel
        nsView.isSelected = isSelected
        nsView.acceptsExternalDrops = acceptsExternalDrops
        nsView.prefersPathOnlyDrop = prefersPathOnlyDrop
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
        nsView.onTargetedChange = onExternalTargetedChange
        nsView.onFilesTargetedChange = onExternalFilesTargetedChange
        nsView.onPathOnlyChange = onExternalPathOnlyChange
        nsView.onDrop = onExternalDrop
        nsView.onReorder = onReorder
        nsView.updateAccessibility()
    }

    final class DragSourceView: ShelfSurface.SurfaceView, NSDraggingSource {
        var contents: [ShelfItem.Content] = []
        var itemIDs: [ShelfItem.ID] = []
        var reorderScopeID: ShelfFeature.State.ID?
        var reorderTargetID: ShelfItem.ID?
        var reorderAxis: Axis = .horizontal
        var reorderContainerSize: CGSize?
        var itemLabel: String?
        var isSelected = false
        var acceptsExternalDrops = false
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
        var onReorder: ((
            [ShelfItem.ID],
            ShelfItem.ID,
            ShelfReorderPlacement
        ) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override var acceptsFirstResponder: Bool { true }

        override var needsPanelToBecomeKey: Bool { true }

        func updateAccessibility() {
            guard let itemLabel else {
                setAccessibilityElement(false)
                return
            }

            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(itemLabel)
            setAccessibilityValue(isSelected ? "Selected" : "Not selected")
        }

        private func claimKeyboardFocus() {
            claimShelfKeyboardFocus()
        }

        private func sendEditingCommand(_ command: ShelfPanelKeyboardCommand) {
            (window as? ShelfPanel)?.onKeyboardCommand(command)
        }

        // Standard Edit-menu actions are resolved through the first-responder
        // chain before some Command-key events reach NSWindow. Expose the
        // native selectors while keeping Swift method names unambiguous.
        @objc(copy:)
        private func performCopyAction(_ sender: Any?) {
            sendEditingCommand(.copySelection)
        }

        @objc(paste:)
        private func performPasteAction(_ sender: Any?) {
            sendEditingCommand(.paste)
        }

        @objc(undo:)
        private func performUndoAction(_ sender: Any?) {
            sendEditingCommand(.undo)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let command = ShelfPanelKeyboardCommand(event: event) else {
                return super.performKeyEquivalent(with: event)
            }

            sendEditingCommand(command)
            return true
        }

        override func mouseDown(with event: NSEvent) {
            claimKeyboardFocus()
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
            Task { @MainActor [weak self] in
                // SwiftUI may update the representable after selection. Restore
                // the persistent root responder on the following actor turn.
                await Task.yield()
                self?.claimKeyboardFocus()
            }
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
            claimKeyboardFocus()
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

        // MARK: - Reordering inside one shelf

        private var isForwardingExternalDrop = false

        private var reorderIndicatorPlacement: ShelfReorderPlacement? {
            didSet {
                guard reorderIndicatorPlacement != oldValue else { return }
                needsDisplay = true
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingSource is DragSourceView else {
                guard acceptsExternalDrops else { return [] }
                isForwardingExternalDrop = true
                return super.draggingEntered(sender)
            }
            isForwardingExternalDrop = false
            return updateReorderIndicator(for: sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingSource is DragSourceView else {
                guard acceptsExternalDrops else { return [] }
                isForwardingExternalDrop = true
                return super.draggingUpdated(sender)
            }
            return updateReorderIndicator(for: sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            if isForwardingExternalDrop {
                super.draggingExited(sender)
                isForwardingExternalDrop = false
            }
            reorderIndicatorPlacement = nil
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            if isForwardingExternalDrop {
                super.draggingEnded(sender)
                isForwardingExternalDrop = false
            }
            reorderIndicatorPlacement = nil
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard sender.draggingSource is DragSourceView else {
                guard acceptsExternalDrops else { return false }
                return super.prepareForDragOperation(sender)
            }
            return reorderSource(for: sender) != nil
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard sender.draggingSource is DragSourceView else {
                guard acceptsExternalDrops else { return false }
                return super.performDragOperation(sender)
            }

            guard let source = reorderSource(for: sender),
                  let targetID = reorderTargetID,
                  let onReorder else {
                reorderIndicatorPlacement = nil
                return false
            }

            let placement = Self.reorderPlacement(
                at: convert(sender.draggingLocation, from: nil),
                in: bounds,
                axis: reorderAxis,
                isFlipped: isFlipped
            )
            let movingIDs = source.activeDraggedItemIDs
            source.markAsReordered()
            reorderIndicatorPlacement = nil

            // Reordering destroys and recreates representable views. Defer the
            // state mutation until AppKit has finished this drop callback.
            DispatchQueue.main.async {
                onReorder(movingIDs, targetID, placement)
            }
            return true
        }

        private func updateReorderIndicator(
            for sender: NSDraggingInfo
        ) -> NSDragOperation {
            guard reorderSource(for: sender) != nil else {
                reorderIndicatorPlacement = nil
                return []
            }

            reorderIndicatorPlacement = Self.reorderPlacement(
                at: convert(sender.draggingLocation, from: nil),
                in: bounds,
                axis: reorderAxis,
                isFlipped: isFlipped
            )
            return .move
        }

        private func reorderSource(
            for sender: NSDraggingInfo
        ) -> DragSourceView? {
            guard let source = sender.draggingSource as? DragSourceView,
                  source !== self,
                  let reorderScopeID,
                  source.reorderScopeID == reorderScopeID,
                  let reorderTargetID,
                  !source.activeDraggedItemIDs.isEmpty,
                  !source.activeDraggedItemIDs.contains(reorderTargetID),
                  onReorder != nil else { return nil }
            return source
        }

        static func reorderPlacement(
            at point: CGPoint,
            in bounds: CGRect,
            axis: Axis,
            isFlipped: Bool
        ) -> ShelfReorderPlacement {
            switch axis {
            case .horizontal:
                point.x < bounds.midX ? .before : .after
            case .vertical:
                if isFlipped {
                    point.y < bounds.midY ? .before : .after
                } else {
                    point.y > bounds.midY ? .before : .after
                }
            }
        }

        struct ReorderCandidate: Equatable {
            let id: ShelfItem.ID
            let frame: CGRect
        }

        enum LocalDropResolution: Equatable {
            case outsideShelf
            case keepOnShelf
            case reorder(ShelfItem.ID, ShelfReorderPlacement)
        }

        /// Resolves a rejected AppKit drop from its final screen position.
        /// Item views cover only their visible cells, so gaps between cells do
        /// not otherwise have a native drag destination. Remaining anywhere
        /// inside the shelf means reordering (or keeping the current position),
        /// while leaving this frame preserves normal cross-app drag and drop.
        static func localDropResolution(
            at screenPoint: CGPoint,
            shelfFrame: CGRect,
            candidates: [ReorderCandidate],
            movingIDs: Set<ShelfItem.ID>,
            axis: Axis
        ) -> LocalDropResolution {
            guard shelfFrame.contains(screenPoint) else { return .outsideShelf }

            if candidates.contains(where: {
                movingIDs.contains($0.id) && $0.frame.contains(screenPoint)
            }) {
                return .keepOnShelf
            }

            let stationaryCandidates = candidates.filter {
                !movingIDs.contains($0.id)
            }
            guard let nearest = stationaryCandidates.min(by: { lhs, rhs in
                let lhsDistance: CGFloat
                let rhsDistance: CGFloat
                switch axis {
                case .horizontal:
                    lhsDistance = abs(lhs.frame.midX - screenPoint.x)
                    rhsDistance = abs(rhs.frame.midX - screenPoint.x)
                case .vertical:
                    lhsDistance = abs(lhs.frame.midY - screenPoint.y)
                    rhsDistance = abs(rhs.frame.midY - screenPoint.y)
                }
                return lhsDistance < rhsDistance
            }) else {
                return .keepOnShelf
            }

            let placement: ShelfReorderPlacement
            switch axis {
            case .horizontal:
                placement = screenPoint.x < nearest.frame.midX ? .before : .after
            case .vertical:
                // Screen coordinates grow upward, while the visible list runs
                // from the top of the display toward the bottom.
                placement = screenPoint.y > nearest.frame.midY ? .before : .after
            }
            return .reorder(nearest.id, placement)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let reorderIndicatorPlacement else { return }

            let thickness: CGFloat = 3
            let indicatorFrame: CGRect
            switch reorderAxis {
            case .horizontal:
                indicatorFrame = CGRect(
                    x: reorderIndicatorPlacement == .before
                        ? bounds.minX
                        : bounds.maxX - thickness,
                    y: bounds.minY + 4,
                    width: thickness,
                    height: max(0, bounds.height - 8)
                )
            case .vertical:
                let beforeY = isFlipped
                    ? bounds.minY
                    : bounds.maxY - thickness
                let afterY = isFlipped
                    ? bounds.maxY - thickness
                    : bounds.minY
                indicatorFrame = CGRect(
                    x: bounds.minX + 4,
                    y: reorderIndicatorPlacement == .before ? beforeY : afterY,
                    width: max(0, bounds.width - 8),
                    height: thickness
                )
            }

            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: indicatorFrame,
                xRadius: thickness / 2,
                yRadius: thickness / 2
            ).fill()
        }

        /// Snapshot taken when the drag begins, so a shelf that changes mid-drag
        /// can't confuse what actually left.
        private var draggedContents: [ShelfItem.Content] = []
        private var draggedItemIDs: [ShelfItem.ID] = []
        private var completedAsShare = false
        private var completedAsReorder = false
        private var didBeginDragging = false
        private var mouseDownLocation: CGPoint?
        private var latestDraggingScreenPoint: NSPoint?
        private var autoScrollTimer: Timer?
        private weak var autoScrollView: NSScrollView?

        static let dragActivationDistance: CGFloat = 4
        static let autoScrollActivationInset: CGFloat = 42
        static let maximumAutoScrollStep: CGFloat = 8

        static func hasExceededDragThreshold(from start: CGPoint, to current: CGPoint) -> Bool {
            let horizontalDistance = current.x - start.x
            let verticalDistance = current.y - start.y
            return hypot(horizontalDistance, verticalDistance) >= dragActivationDistance
        }

        /// Returns a signed per-frame scroll step. The speed ramps up as the
        /// pointer approaches (or crosses) either visible edge.
        static func autoScrollStep(
            pointerCoordinate: CGFloat,
            visibleRange: ClosedRange<CGFloat>,
            activationInset: CGFloat = autoScrollActivationInset,
            maximumStep: CGFloat = maximumAutoScrollStep
        ) -> CGFloat {
            let visibleLength = visibleRange.upperBound - visibleRange.lowerBound
            guard visibleLength > 0, activationInset > 0, maximumStep > 0 else {
                return 0
            }

            let inset = min(activationInset, visibleLength / 2)
            let leadingThreshold = visibleRange.lowerBound + inset
            if pointerCoordinate < leadingThreshold {
                let progress = min(
                    1,
                    max(0, (leadingThreshold - pointerCoordinate) / inset)
                )
                return -maximumStep * progress
            }

            let trailingThreshold = visibleRange.upperBound - inset
            if pointerCoordinate > trailingThreshold {
                let progress = min(
                    1,
                    max(0, (pointerCoordinate - trailingThreshold) / inset)
                )
                return maximumStep * progress
            }

            return 0
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
            draggedItemIDs = itemIDs
            completedAsShare = false
            completedAsReorder = false
            onDragActiveChange(true)
            beginDraggingSession(with: items, event: event, source: self)
        }

        func markAsShared() {
            completedAsShare = true
        }

        func markAsReordered() {
            completedAsReorder = true
        }

        private var activeDraggedItemIDs: [ShelfItem.ID] {
            draggedItemIDs.isEmpty ? itemIDs : draggedItemIDs
        }

        private func copyToClipboard(_ contents: [ShelfItem.Content]) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(contents.map(\.pasteboardWriter))
        }

        func draggingSession(
            _ session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint
        ) {
            startAutoScrolling(at: screenPoint)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            movedTo screenPoint: NSPoint
        ) {
            latestDraggingScreenPoint = screenPoint
        }

        private func startAutoScrolling(at screenPoint: NSPoint) {
            guard reorderScopeID != nil,
                  onReorder != nil,
                  let scrollView = enclosingScrollView else { return }

            latestDraggingScreenPoint = screenPoint
            autoScrollView = scrollView
            autoScrollTimer?.invalidate()

            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(performAutoScrollStep),
                userInfo: nil,
                repeats: true
            )
            autoScrollTimer = timer
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .common)
        }

        private func stopAutoScrolling() {
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
            autoScrollView = nil
            latestDraggingScreenPoint = nil
        }

        @objc private func performAutoScrollStep() {
            guard let screenPoint = latestDraggingScreenPoint,
                  let scrollView = autoScrollView,
                  let documentView = scrollView.documentView,
                  let window = scrollView.window else { return }

            let clipView = scrollView.contentView
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let pointer = clipView.convert(windowPoint, from: nil)
            let visibleBounds = clipView.bounds
            let crossAxisTolerance: CGFloat = 24
            let delta: CGFloat

            switch reorderAxis {
            case .horizontal:
                guard pointer.y >= visibleBounds.minY - crossAxisTolerance,
                      pointer.y <= visibleBounds.maxY + crossAxisTolerance else { return }
                delta = Self.autoScrollStep(
                    pointerCoordinate: pointer.x,
                    visibleRange: visibleBounds.minX...visibleBounds.maxX
                )
            case .vertical:
                guard pointer.x >= visibleBounds.minX - crossAxisTolerance,
                      pointer.x <= visibleBounds.maxX + crossAxisTolerance else { return }
                delta = Self.autoScrollStep(
                    pointerCoordinate: pointer.y,
                    visibleRange: visibleBounds.minY...visibleBounds.maxY
                )
            }

            guard delta != 0 else { return }

            let documentBounds = documentView.bounds
            var origin = visibleBounds.origin
            switch reorderAxis {
            case .horizontal:
                let maximumOrigin = max(
                    documentBounds.minX,
                    documentBounds.maxX - visibleBounds.width
                )
                origin.x = min(max(origin.x + delta, documentBounds.minX), maximumOrigin)
            case .vertical:
                let maximumOrigin = max(
                    documentBounds.minY,
                    documentBounds.maxY - visibleBounds.height
                )
                origin.y = min(max(origin.y + delta, documentBounds.minY), maximumOrigin)
            }

            guard origin != visibleBounds.origin else { return }
            clipView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            let dragged = draggedContents.isEmpty ? contents : draggedContents
            let carriesFile = dragged.contains { if case .file = $0 { true } else { false } }

            if context == .withinApplication, reorderScopeID != nil {
                return [.copy, .move]
            }

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
            stopAutoScrolling()
            NSLog("[Shelfer] dragOut ended operation=%lu count=%d", operation.rawValue, draggedContents.count)
            onDragActiveChange(false)
            let completed = draggedContents
            let completedItemIDs = draggedItemIDs
            let wasConsumedInsideShelfer = completedAsShare || completedAsReorder
            draggedContents = []
            draggedItemIDs = []
            completedAsShare = false
            completedAsReorder = false

            if !wasConsumedInsideShelfer,
               let resolution = localDropResolution(
                   at: screenPoint,
                   movingIDs: Set(completedItemIDs)
               ) {
                switch resolution {
                case .outsideShelf:
                    break
                case .keepOnShelf:
                    return
                case let .reorder(targetID, placement):
                    guard let onReorder, !completedItemIDs.isEmpty else { return }
                    DispatchQueue.main.async {
                        onReorder(completedItemIDs, targetID, placement)
                    }
                    return
                }
            }

            // An empty operation means the drop was rejected or cancelled,
            // so the items stay on the shelf.
            guard !wasConsumedInsideShelfer,
                  !operation.isEmpty,
                  !completed.isEmpty else { return }

            // Deferred out of the drag callback: removing the last item hides the
            // panel, and ordering a window out while the session is still closing
            // re-enters the drag machinery. Destinations that hand the drop to
            // another process (Chromium apps such as Slack and Zoom) lose the
            // payload when that happens.
            DispatchQueue.main.async { [onCompleted] in
                onCompleted(completed)
            }
        }

        private func localDropResolution(
            at screenPoint: CGPoint,
            movingIDs: Set<ShelfItem.ID>
        ) -> LocalDropResolution? {
            guard let window,
                  let contentView = window.contentView,
                  let reorderContainerSize,
                  reorderScopeID != nil else { return nil }

            let shelfFrame = CGRect(
                x: window.frame.midX - reorderContainerSize.width / 2,
                y: window.frame.maxY - reorderContainerSize.height,
                width: reorderContainerSize.width,
                height: reorderContainerSize.height
            )
            let candidates = Self.dragSourceViews(in: contentView).compactMap {
                candidate -> ReorderCandidate? in
                guard candidate.reorderScopeID == reorderScopeID,
                      let id = candidate.reorderTargetID,
                      candidate.window === window else { return nil }
                let frameInWindow = candidate.convert(candidate.bounds, to: nil)
                return ReorderCandidate(
                    id: id,
                    frame: window.convertToScreen(frameInWindow)
                )
            }
            return Self.localDropResolution(
                at: screenPoint,
                shelfFrame: shelfFrame,
                candidates: candidates,
                movingIDs: movingIDs,
                axis: reorderAxis
            )
        }

        private static func dragSourceViews(in rootView: NSView) -> [DragSourceView] {
            var results = (rootView as? DragSourceView).map { [$0] } ?? []
            for subview in rootView.subviews {
                results.append(contentsOf: dragSourceViews(in: subview))
            }
            return results
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

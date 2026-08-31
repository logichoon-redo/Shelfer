//
//  ShelfWindowController.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture
import SwiftUI

/// SwiftUI renders its buttons inside the hosting view itself rather than as
/// individual `NSButton` descendants. `NSHostingView` rejects the first mouse by
/// default, so a click arriving while another app is active only changes the
/// panel's key state and never reaches the SwiftUI button action.
final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var needsPanelToBecomeKey: Bool {
        false
    }
}

/// Mirrors `ShelfFeature.State` onto an `NSPanel`. It makes no decisions about
/// when a shelf should appear — it only reflects what the store already decided.
@MainActor
final class ShelfWindowController {
    private let store: StoreOf<ShelfFeature>
    private var panel: ShelfPanel?
    private var isObserving = true

#if DEBUG
    var panelForTesting: ShelfPanel? { panel }
#endif

    /// The position already applied to the panel, so a state change that isn't a
    /// fresh summon (a file landing, say) doesn't undo a manual window move.
    private var appliedPosition: CGPoint?

    /// Docking is a window concern: the reducer records the selected edge while
    /// this controller keeps the exact manual frame to which it should return.
    private var appliedDockEdge: ShelfDockEdge?
    private var appliedNotchDock: ShelfNotchDock?
    private var undockedFrame: CGRect?
    private var dockedScreen: NSScreen?
    private var pendingNotchRestorePoint: CGPoint?
    private var didUndockNotchDuringCurrentDrag = false
    private var notchHoverTask: Task<Void, Never>?
    private var notchHoverWatchID: UUID?
    private var notchStowResizeTask: Task<Void, Never>?
    private var notchStowResizeID: UUID?

    init(store: StoreOf<ShelfFeature>) {
        self.store = store
        observe()
    }

    private func observe() {
        guard isObserving else { return }

        withObservationTracking {
            let isExpanded = store.isExpanded
            let shelfSize = isExpanded ? ShelfDetailMetrics.size : ShelfMetrics.size
            sync(
                isPresented: store.isPresented,
                position: store.position,
                dockedEdge: store.dockedEdge,
                notchDock: store.notchDock,
                isExpanded: isExpanded,
                isEmpty: store.isEmpty,
                isClearing: store.isClearing,
                showsEmptyCloseButton: store.showsEmptyCloseButton,
                shelfSize: shelfSize,
                panelSize: ShelfShareMetrics.panelSize(for: shelfSize)
            )
        } onChange: {
            // onChange fires before the new value is applied, so re-read on the
            // next turn of the main actor.
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    /// Stops observation and releases the panel when this shelf leaves the
    /// collection.
    func invalidate() {
        isObserving = false
        cancelNotchHoverWatch()
        cancelNotchStowResize()
        panel?.cancelUserDragTracking()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func sync(
        isPresented: Bool,
        position: CGPoint?,
        dockedEdge: ShelfDockEdge?,
        notchDock: ShelfNotchDock?,
        isExpanded: Bool,
        isEmpty: Bool,
        isClearing: Bool,
        showsEmptyCloseButton: Bool,
        shelfSize: CGSize,
        panelSize: CGSize
    ) {
        guard isPresented else {
            cancelNotchHoverWatch()
            cancelNotchStowResize()
            panel?.level = .floating
            panel?.ignoresMouseEvents = false
            if let panel {
                setShelfBackgroundVisible(true, in: panel)
                setShelfBackgroundNotchWidth(nil, in: panel)
            }
            panel?.orderOut(nil)
            appliedPosition = nil
            appliedDockEdge = nil
            appliedNotchDock = nil
            undockedFrame = nil
            dockedScreen = nil
            pendingNotchRestorePoint = nil
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        syncTopControls(
            in: panel,
            dockedEdge: dockedEdge,
            notchDock: notchDock,
            isExpanded: isExpanded,
            isEmpty: isEmpty,
            isClearing: isClearing,
            showsEmptyCloseButton: showsEmptyCloseButton
        )

        let hasFreshPosition = position.map { $0 != appliedPosition } ?? false
        if let position, hasFreshPosition, dockedEdge == nil, notchDock == nil {
            appliedPosition = position
            appliedDockEdge = nil
            appliedNotchDock = nil
            undockedFrame = nil
            dockedScreen = nil

            let origin = originClamped(
                for: position,
                shelfSize: shelfSize,
                panelSize: panelSize,
                on: screen(containing: position)
            )
            panel.setFrame(
                CGRect(origin: origin, size: panelSize),
                display: true,
                animate: false
            )
        }

        if let notchDock {
            // A shelf created by dropping directly on the notch has never had
            // its ordinary position applied. Still mark that initial position
            // as observed: otherwise the first undock mistakes it for a fresh
            // summon, clears `appliedNotchDock`, and skips `restoreFromNotch`
            // (including its material/background and window-level reset).
            appliedPosition = position
            syncNotchDock(panel, to: notchDock, fullPanelSize: panelSize)
            panel.orderFrontRegardless()
            return
        }

        if appliedNotchDock != nil {
            restoreFromNotch(panel, fullPanelSize: panelSize, shelfSize: shelfSize)
        } else if appliedDockEdge == nil {
            resize(panel, to: panelSize)
        } else if panel.frame.size != panelSize, let edge = appliedDockEdge {
            resizeDocked(panel, to: panelSize, at: edge)
        }

        syncDocking(panel, to: dockedEdge, panelSize: panelSize)
        panel.orderFrontRegardless()
    }

    private func syncNotchDock(
        _ panel: ShelfPanel,
        to notchDock: ShelfNotchDock,
        fullPanelSize: CGSize
    ) {
        let previousPresentation = appliedNotchDock?.presentation

        if appliedNotchDock == nil {
            if appliedDockEdge == nil {
                undockedFrame = panel.frame
            }
            appliedDockEdge = nil
            dockedScreen = screen(containing: notchDock.target.notchFrame)
        }

        appliedNotchDock = notchDock
        if notchDock.presentation != .stowed {
            cancelNotchStowResize()
        }
        panel.level = .statusBar
        panel.ignoresMouseEvents = notchDock.presentation == .stowed
        syncNotchHoverWatch(for: notchDock, in: panel)
        setShelfBackgroundVisible(
            notchDock.presentation == .retracting,
            in: panel
        )
        setShelfBackgroundNotchWidth(
            notchDock.presentation == .retracting
                ? ShelfNotchMetrics.mergeNeckWidth(
                    for: notchDock.target.notchFrame.width
                )
                : nil,
            in: panel
        )
        if previousPresentation != notchDock.presentation {
            let shouldAnimate = panel.isVisible
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            switch notchDock.presentation {
            case .retracting:
                animateShelfBackgroundSuction(
                    to: 1,
                    duration: ShelfNotchMetrics.retractionDuration,
                    animated: shouldAnimate,
                    in: panel
                )
            case .stowed, .peeking:
                animateShelfBackgroundSuction(
                    to: 0,
                    duration: 0,
                    animated: false,
                    in: panel
                )
            }
        }

        let targetFrame = notchFrame(for: notchDock, fullPanelSize: fullPanelSize)
        guard panel.frame != targetFrame else { return }

        switch notchDock.presentation {
        case .retracting:
            animate(panel, to: targetFrame, duration: ShelfNotchMetrics.retractionDuration)
        case .stowed:
            if notchStowResizeTask != nil {
                return
            }

            if previousPresentation == .peeking,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                scheduleNotchStowResize(panel, to: targetFrame)
            } else {
                // Retraction has already put the complete shelf behind the
                // camera housing, so this state needs no additional delay.
                panel.setFrame(targetFrame, display: true, animate: false)
            }
        case .peeking:
            animate(panel, to: targetFrame, duration: ShelfNotchMetrics.peekAnimationDuration)
        }
    }

    private func restoreFromNotch(
        _ panel: ShelfPanel,
        fullPanelSize: CGSize,
        shelfSize: CGSize
    ) {
        cancelNotchHoverWatch()
        cancelNotchStowResize()
        let notchScreen = appliedNotchDock.map { screen(containing: $0.target.notchFrame) }
            ?? dockedScreen
            ?? screen(containing: panel.frame)
        let target: CGRect

        if let point = pendingNotchRestorePoint {
            target = CGRect(
                origin: originClamped(
                    for: point,
                    shelfSize: shelfSize,
                    panelSize: fullPanelSize,
                    on: screen(containing: point)
                ),
                size: fullPanelSize
            )
        } else {
            target = restoredFrame(size: fullPanelSize, on: notchScreen)
        }

        panel.level = .floating
        panel.ignoresMouseEvents = false
        setShelfBackgroundVisible(true, in: panel)
        setShelfBackgroundNotchWidth(nil, in: panel)
        appliedNotchDock = nil
        appliedDockEdge = nil
        pendingNotchRestorePoint = nil
        undockedFrame = nil
        dockedScreen = nil

        if panel.isUserDragging {
            panel.setFrame(target, display: true, animate: false)
        } else {
            animate(panel, to: target, duration: ShelfDockMetrics.animationDuration)
        }
    }

    /// The physical camera housing is not an ordinary display region, so a
    /// window hidden behind it cannot rely on AppKit mouse-enter events. The
    /// same pointer watch also covers mouse-exit events lost during frame
    /// animation, making both reveal and retraction deterministic.
    private func syncNotchHoverWatch(
        for notchDock: ShelfNotchDock,
        in panel: ShelfPanel
    ) {
        guard notchDock.presentation == .stowed || notchDock.presentation == .peeking else {
            cancelNotchHoverWatch()
            return
        }
        guard notchHoverTask == nil else { return }

        let watchID = UUID()
        notchHoverWatchID = watchID
        notchHoverTask = Task { @MainActor [weak self, weak panel] in
            defer {
                if self?.notchHoverWatchID == watchID {
                    self?.notchHoverTask = nil
                    self?.notchHoverWatchID = nil
                }
            }

            while let self, let panel, !Task.isCancelled,
                  let currentDock = self.store.notchDock,
                  currentDock.presentation == .stowed || currentDock.presentation == .peeking {
                guard !panel.isUserDragging else {
                    try? await Task.sleep(for: .milliseconds(40))
                    continue
                }

                let pointer = NSEvent.mouseLocation
                switch currentDock.presentation {
                case .stowed:
                    let notch = currentDock.target.notchFrame
                    let triggerFrame = CGRect(
                        x: notch.minX - ShelfNotchMetrics.hoverProximityHorizontalInset,
                        y: notch.minY - ShelfNotchMetrics.hoverProximityDepth,
                        width: notch.width + ShelfNotchMetrics.hoverProximityHorizontalInset * 2,
                        height: notch.height + ShelfNotchMetrics.hoverProximityDepth
                    )
                    if triggerFrame.contains(pointer) {
                        self.store.send(.notchHoverChanged(true))
                    }

                case .peeking:
                    let interactionFrame = panel.frame.insetBy(dx: -4, dy: -4)
                    if !interactionFrame.contains(pointer) {
                        self.store.send(.notchHoverChanged(false))
                    }

                case .retracting:
                    return
                }

                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func cancelNotchHoverWatch() {
        notchHoverTask?.cancel()
        notchHoverTask = nil
        notchHoverWatchID = nil
    }

    /// Keeps the small peeking panel stationary until SwiftUI has finished
    /// removing its handle. Resizing to the wider ambient panel any earlier
    /// changes the outgoing view's coordinate space and makes it jump left.
    private func scheduleNotchStowResize(_ panel: ShelfPanel, to frame: CGRect) {
        cancelNotchStowResize()

        let resizeID = UUID()
        notchStowResizeID = resizeID
        notchStowResizeTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(
                for: .seconds(ShelfNotchMetrics.peekAnimationDuration)
            )

            guard !Task.isCancelled,
                  let self,
                  let panel,
                  self.notchStowResizeID == resizeID,
                  self.store.notchDock?.presentation == .stowed else { return }

            panel.setFrame(frame, display: true, animate: false)
            self.notchStowResizeTask = nil
            self.notchStowResizeID = nil
        }
    }

    private func cancelNotchStowResize() {
        notchStowResizeTask?.cancel()
        notchStowResizeTask = nil
        notchStowResizeID = nil
    }

    private func notchFrame(
        for notchDock: ShelfNotchDock,
        fullPanelSize: CGSize
    ) -> CGRect {
        let target = notchDock.target

        switch notchDock.presentation {
        case .retracting:
            return CGRect(
                x: target.notchFrame.midX
                    - fullPanelSize.width / 2
                    + ShelfNotchMetrics.viewHorizontalOffset,
                // By this phase the shelf is collapsing into a short tail.
                // Moving the complete panel height hid that deformation before
                // it could be perceived; move only the remaining tail behind
                // the camera housing instead.
                y: target.notchFrame.minY
                    + ShelfNotchMetrics.mergeOverlap
                    - fullPanelSize.height
                    + ShelfNotchMetrics.suctionRetractionTravelDistance,
                width: fullPanelSize.width,
                height: fullPanelSize.height
            )

        case .stowed:
            return ShelfNotchGeometry.ambientFrame(for: target)

        case .peeking:
            let width = target.notchFrame.width + ShelfNotchMetrics.peekHorizontalInset * 2
            return CGRect(
                x: target.notchFrame.midX
                    - width / 2
                    + ShelfNotchMetrics.viewHorizontalOffset,
                y: target.notchFrame.minY
                    - ShelfNotchMetrics.peekDepth
                    + ShelfNotchMetrics.viewVerticalOffset,
                width: width,
                height: target.notchFrame.height + ShelfNotchMetrics.peekDepth
            )
        }
    }

    private func setShelfBackgroundVisible(_ isVisible: Bool, in panel: ShelfPanel) {
        (panel.contentView as? ShelfPanelRootView)?.showsShelfBackground = isVisible
    }

    private func setShelfBackgroundNotchWidth(_ width: CGFloat?, in panel: ShelfPanel) {
        (panel.contentView as? ShelfPanelRootView)?.notchMergeWidth = width
    }

    private func animateShelfBackgroundSuction(
        to progress: CGFloat,
        duration: TimeInterval,
        animated: Bool,
        in panel: ShelfPanel
    ) {
        (panel.contentView as? ShelfPanelRootView)?.animateNotchSuction(
            to: progress,
            duration: duration,
            animated: animated
        )
    }

    private func syncDocking(
        _ panel: ShelfPanel,
        to edge: ShelfDockEdge?,
        panelSize: CGSize
    ) {
        guard edge != appliedDockEdge else { return }

        if let edge {
            if appliedDockEdge == nil {
                undockedFrame = panel.frame
                dockedScreen = screen(containing: panel.frame)
            }

            let screen = dockedScreen ?? screen(containing: panel.frame)
            let target = dockedFrame(
                at: edge,
                size: panelSize,
                restoreFrame: undockedFrame ?? panel.frame,
                on: screen
            )
            appliedDockEdge = edge
            animate(panel, to: target, duration: ShelfDockMetrics.animationDuration)
            return
        }

        let screen = dockedScreen ?? screen(containing: panel.frame)
        let target = restoredFrame(size: panelSize, on: screen)
        appliedDockEdge = nil
        undockedFrame = nil
        dockedScreen = nil
        animate(panel, to: target, duration: ShelfDockMetrics.animationDuration)
    }

    /// Keeps the return frame and the exposed edge aligned if the panel's size
    /// changes while docked (for example through an external state mutation).
    private func resizeDocked(
        _ panel: ShelfPanel,
        to size: CGSize,
        at edge: ShelfDockEdge
    ) {
        let screen = dockedScreen ?? screen(containing: panel.frame)
        let restore = restoredFrame(size: size, on: screen)
        undockedFrame = restore
        let target = dockedFrame(at: edge, size: size, restoreFrame: restore, on: screen)
        animate(panel, to: target, duration: ShelfMetrics.expansionAnimationDuration)
    }

    /// The compact shelf's top-left corner stays fixed. Expansion therefore
    /// preserves its existing footprint and reveals the extra space to the
    /// right (plus the small height difference below it).
    private func resize(_ panel: ShelfPanel, to size: CGSize) {
        let current = panel.frame
        guard current.size != size else { return }

        let topLeft = CGPoint(x: current.minX, y: current.maxY)
        var frame = CGRect(
            x: topLeft.x,
            y: topLeft.y - size.height,
            width: size.width,
            height: size.height
        )

        let visible = screen(containing: CGPoint(x: frame.midX, y: frame.midY)).visibleFrame
        frame.origin.x = frame.origin.x.clamped(to: visible.minX...(visible.maxX - size.width))
        frame.origin.y = frame.origin.y.clamped(to: visible.minY...(visible.maxY - size.height))

        guard panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true, animate: false)
            return
        }

        // NSWindow's resize path advances the frame monotonically from the
        // current width to the target width. It also avoids creating an ambient
        // animation transaction for the hosted SwiftUI and background layers.
        animate(panel, to: frame, duration: ShelfMetrics.expansionAnimationDuration)
    }

    private func animate(_ panel: ShelfPanel, to frame: CGRect, duration: TimeInterval) {
        let shouldAnimate = panel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.frameAnimationDuration = duration
        panel.setFrame(frame, display: true, animate: shouldAnimate)
    }

    private func makePanel() -> ShelfPanel {
        let panelSize = ShelfShareMetrics.panelSize(for: ShelfMetrics.size)
        let panel = ShelfPanel(contentRect: NSRect(origin: .zero, size: panelSize))
        let root = ShelfPanelRootView(frame: NSRect(origin: .zero, size: panelSize))
        let hosting = ShelfHostingView(rootView: ShelfPanelContentView(store: store))
        // This controller is the sole owner of panel geometry. Allowing the
        // hosting view to propagate a transition's intrinsic size back to its
        // window can shift the panel while the notch handle is disappearing.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hosting)
        root.suctionContentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        panel.onUserDragBegan = { [weak self] in
            self?.userDragBegan()
        }
        panel.onUserDragMoved = { [weak self] in
            self?.userDragMoved()
        }
        panel.onUserDragEnded = { [weak self] point in
            self?.userDragEnded(at: point)
        }
        panel.onTopControl = { [weak self] control in
            guard let self else { return }
            switch control {
            case .close:
                store.send(.closeButtonTapped)
            case .clear:
                store.send(.clearButtonTapped)
            case .back:
                store.send(.backButtonTapped)
            case .grid:
                store.send(.layoutChanged(.grid))
            case .list:
                store.send(.layoutChanged(.list))
            }
        }
        let keyboardCommandHandler: (ShelfPanelKeyboardCommand) -> Void = {
            [weak self] command in
            guard let self else { return }
            switch command {
            case let .moveSelection(direction):
                store.send(.selectionMoveRequested(direction))
            case .deleteSelection:
                store.send(.deleteSelectionRequested)
            case .copySelection:
                store.send(.copySelectionRequested)
            case .paste:
                store.send(.pasteRequested)
            case .undo:
                store.send(.undoRequested)
            }
        }
        panel.onKeyboardCommand = keyboardCommandHandler
        root.onKeyboardCommand = keyboardCommandHandler
        return panel
    }

    private func syncTopControls(
        in panel: ShelfPanel,
        dockedEdge: ShelfDockEdge?,
        notchDock: ShelfNotchDock?,
        isExpanded: Bool,
        isEmpty: Bool,
        isClearing: Bool,
        showsEmptyCloseButton: Bool
    ) {
        guard dockedEdge == nil, notchDock == nil else {
            panel.enabledTopControls = []
            return
        }

        if isExpanded {
            panel.enabledTopControls = [.back, .grid, .list]
        } else {
            var controls: Set<ShelfPanelTopControl> = []
            if !isEmpty || showsEmptyCloseButton {
                controls.insert(.close)
            }
            if !isEmpty, !isClearing {
                controls.insert(.clear)
            }
            panel.enabledTopControls = controls
        }
    }

    private func userDragBegan() {
        guard let notchDock = store.notchDock else { return }

        switch notchDock.presentation {
        case .retracting:
            didUndockNotchDuringCurrentDrag = true
            pendingNotchRestorePoint = NSEvent.mouseLocation
            store.send(.notchUndockRequested)
        case .stowed, .peeking:
            break
        }
    }

    private func userDragMoved() {
        guard let notchDock = store.notchDock else { return }

        let point = NSEvent.mouseLocation
        guard wasPulledFromNotch(at: point, notchDock: notchDock) else { return }

        didUndockNotchDuringCurrentDrag = true
        pendingNotchRestorePoint = point
        store.send(.notchUndockRequested)
    }

    private func userDragEnded(at point: CGPoint) {
        if didUndockNotchDuringCurrentDrag {
            didUndockNotchDuringCurrentDrag = false
            return
        }

        if let notchDock = store.notchDock, let panel {
            // `NSWindow.performDrag(with:)` may hold the event-tracking loop
            // until mouse-up, so the final pointer is also authoritative. This
            // keeps pull-to-restore working even when no intermediate callback
            // was scheduled during the Window Server drag.
            if wasPulledFromNotch(at: point, notchDock: notchDock) {
                pendingNotchRestorePoint = point
                store.send(.notchUndockRequested)
                return
            }

            // A click or a very short pull remains docked. Return its hit target
            // precisely to the camera housing after Window Server movement.
            let fullSize = ShelfShareMetrics.panelSize(for: ShelfMetrics.size)
            let target = notchFrame(for: notchDock, fullPanelSize: fullSize)
            animate(panel, to: target, duration: ShelfNotchMetrics.peekAnimationDuration)
            return
        }

        guard store.dockedEdge == nil, let panel else { return }
        let materialFrame = CGRect(
            x: panel.frame.minX,
            y: panel.frame.minY + ShelfShareMetrics.footerHeight,
            width: panel.frame.width,
            height: max(0, panel.frame.height - ShelfShareMetrics.footerHeight)
        )
        guard let target = ShelfNotchGeometry.target(
            accepting: materialFrame,
            allowsSideContact: store.isExpanded
        ) else { return }

        undockedFrame = panel.frame
        dockedScreen = screen(containing: target.notchFrame)
        store.send(.notchDockRequested(target))
    }

    private func wasPulledFromNotch(
        at point: CGPoint,
        notchDock: ShelfNotchDock
    ) -> Bool {
        let notch = notchDock.target.notchFrame
        let wasPulledDown = point.y < notch.minY - ShelfNotchMetrics.pullDistance
        let wasPulledSideways = abs(point.x - notch.midX)
            > notch.width / 2 + ShelfNotchMetrics.pullDistance
        return wasPulledDown || wasPulledSideways
    }

    private func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func screen(containing frame: CGRect) -> NSScreen {
        NSScreen.screens.max { first, second in
            first.frame.intersection(frame).area < second.frame.intersection(frame).area
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func dockedFrame(
        at edge: ShelfDockEdge,
        size: CGSize,
        restoreFrame: CGRect,
        on screen: NSScreen
    ) -> CGRect {
        let visible = screen.visibleFrame
        let revealedWidth = min(ShelfDockMetrics.revealedWidth, size.width)
        let x: CGFloat = switch edge {
        case .left:
            visible.minX - size.width + revealedWidth
        case .right:
            visible.maxX - revealedWidth
        }

        return CGRect(
            x: x,
            y: restoreFrame.minY.clamped(to: visible.minY...(visible.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    private func restoredFrame(size: CGSize, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let saved = undockedFrame ?? CGRect(origin: panel?.frame.origin ?? .zero, size: size)
        let topLeft = CGPoint(x: saved.minX, y: saved.maxY)

        return CGRect(
            x: topLeft.x.clamped(to: visible.minX...(visible.maxX - size.width)),
            y: (topLeft.y - size.height).clamped(to: visible.minY...(visible.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    private func originClamped(
        for point: CGPoint,
        shelfSize: CGSize,
        panelSize: CGSize,
        on screen: NSScreen
    ) -> CGPoint {
        let visible = screen.visibleFrame
        let x = (point.x - shelfSize.width / 2)
            .clamped(to: visible.minX...(visible.maxX - panelSize.width))
        // The cursor summons the material shelf at its center. The transparent
        // sharing footer is deliberately excluded from that positioning math.
        let proposedTop = point.y + shelfSize.height / 2
        let y = (proposedTop - panelSize.height)
            .clamped(to: visible.minY...(visible.maxY - panelSize.height))
        return CGPoint(x: x, y: y)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return width * height
    }
}

//
//  ShelfWindowController.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture
import SwiftUI

/// Mirrors `ShelfFeature.State` onto an `NSPanel`. It makes no decisions about
/// when a shelf should appear — it only reflects what the store already decided.
@MainActor
final class ShelfWindowController {
    private let store: StoreOf<ShelfFeature>
    private var panel: ShelfPanel?
    private var isObserving = true

    /// The position already applied to the panel, so a state change that isn't a
    /// fresh summon (a file landing, say) doesn't undo a manual window move.
    private var appliedPosition: CGPoint?

    /// Docking is a window concern: the reducer records the selected edge while
    /// this controller keeps the exact manual frame to which it should return.
    private var appliedDockEdge: ShelfDockEdge?
    private var undockedFrame: CGRect?
    private var dockedScreen: NSScreen?

    init(store: StoreOf<ShelfFeature>) {
        self.store = store
        observe()
    }

    private func observe() {
        guard isObserving else { return }

        withObservationTracking {
            let shelfSize = store.isExpanded ? ShelfDetailMetrics.size : ShelfMetrics.size
            sync(
                isPresented: store.isPresented,
                position: store.position,
                dockedEdge: store.dockedEdge,
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
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func sync(
        isPresented: Bool,
        position: CGPoint?,
        dockedEdge: ShelfDockEdge?,
        shelfSize: CGSize,
        panelSize: CGSize
    ) {
        guard isPresented else {
            panel?.orderOut(nil)
            appliedPosition = nil
            appliedDockEdge = nil
            undockedFrame = nil
            dockedScreen = nil
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        let hasFreshPosition = position.map { $0 != appliedPosition } ?? false
        if let position, hasFreshPosition {
            appliedPosition = position
            appliedDockEdge = nil
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
        } else if appliedDockEdge == nil {
            resize(panel, to: panelSize)
        } else if panel.frame.size != panelSize, let edge = appliedDockEdge {
            resizeDocked(panel, to: panelSize, at: edge)
        }

        syncDocking(panel, to: dockedEdge, panelSize: panelSize)
        panel.orderFrontRegardless()
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
        let hosting = NSHostingView(rootView: ShelfPanelContentView(store: store))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: root.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        return panel
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

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

    /// The position already applied to the panel, so a state change that isn't a
    /// fresh summon (a file landing, say) doesn't undo a manual window move.
    private var appliedPosition: CGPoint?

    init(store: StoreOf<ShelfFeature>) {
        self.store = store
        observe()
    }

    private func observe() {
        withObservationTracking {
            let shelfSize = store.isExpanded ? ShelfDetailMetrics.size : ShelfMetrics.size
            sync(
                isPresented: store.isPresented,
                position: store.position,
                shelfSize: shelfSize,
                panelSize: ShelfShareMetrics.panelSize(for: shelfSize)
            )
        } onChange: {
            // onChange fires before the new value is applied, so re-read on the
            // next turn of the main actor.
            Task { @MainActor in self.observe() }
        }
    }

    private func sync(
        isPresented: Bool,
        position: CGPoint?,
        shelfSize: CGSize,
        panelSize: CGSize
    ) {
        guard isPresented else {
            panel?.orderOut(nil)
            appliedPosition = nil
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        if let position, position != appliedPosition {
            appliedPosition = position
            panel.setFrameOrigin(
                originClamped(
                    for: position,
                    shelfSize: shelfSize,
                    panelSize: panelSize,
                    on: screen(containing: position)
                )
            )
        }

        resize(panel, to: panelSize)
        panel.orderFrontRegardless()
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
        panel.setFrame(frame, display: true, animate: true)
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

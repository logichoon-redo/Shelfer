//
//  ShelfPanel.swift
//  C5
//

import AppKit

/// Borderless floating panel that hosts the shelf without stealing focus from the
/// app the user is dragging from.
final class ShelfPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // A borderless transparent window can render its system shadow from the
        // rectangular window frame instead of the rounded material mask.
        hasShadow = false
        // Off, so dragging an item pulls the file out instead of moving the panel.
        // Panel moves come from the explicit drag area behind the content.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        ShelfMetrics.expansionAnimationDuration
    }
}

/// One material surface lives for the entire lifetime of the panel. Keeping it
/// outside SwiftUI's compact/detail branches prevents a second geometry
/// animation from briefly scaling the shelf during expansion.
final class ShelfBackgroundView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        blendingMode = .behindWindow
        state = .active
        material = .underWindowBackground
        wantsLayer = true
        layer?.cornerRadius = ShelfMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

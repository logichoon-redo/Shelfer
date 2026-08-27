//
//  ShelfPanel.swift
//  Shelfer
//

import AppKit

/// Borderless floating panel that hosts the shelf without stealing focus from the
/// app the user is dragging from.
final class ShelfPanel: NSPanel {
    var frameAnimationDuration = ShelfMetrics.expansionAnimationDuration
    var onUserDragBegan: () -> Void = {}
    var onUserDragMoved: () -> Void = {}
    var onUserDragEnded: (CGPoint) -> Void = { _ in }

    private var userDragTask: Task<Void, Never>?
    private var isPerformingUserDrag = false
    private static let leftButtonMask = 1 << 0

    var isUserDragging: Bool {
        isPerformingUserDrag
    }

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
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        frameAnimationDuration
    }

    /// `performDrag(with:)` hands movement to Window Server and may consume the
    /// eventual mouse-up. Polling the physical button gives the controller a
    /// reliable end point for notch capture and pull-to-restore.
    func performShelfDrag(with event: NSEvent) {
        guard userDragTask == nil else { return }

        isPerformingUserDrag = true
        onUserDragBegan()
        performDrag(with: event)
        userDragTask = Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons & Self.leftButtonMask != 0 {
                guard let self, !Task.isCancelled else { return }
                onUserDragMoved()
                try? await Task.sleep(for: .milliseconds(16))
            }

            guard let self, !Task.isCancelled else { return }
            userDragTask = nil
            isPerformingUserDrag = false
            onUserDragEnded(NSEvent.mouseLocation)
        }
    }

    func cancelUserDragTracking() {
        userDragTask?.cancel()
        userDragTask = nil
        isPerformingUserDrag = false
    }
}

/// One material surface lives for the entire lifetime of the panel. Keeping it
/// outside SwiftUI's compact/detail branches prevents a second geometry
/// animation from briefly scaling the shelf during expansion.
final class ShelfBackgroundView: NSVisualEffectView {
    var notchMergeWidth: CGFloat? {
        didSet {
            guard notchMergeWidth != oldValue else { return }
            updateSilhouetteMask()
            needsLayout = true
        }
    }

    private let silhouetteMask = CAShapeLayer()

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

    override func layout() {
        super.layout()
        updateSilhouetteMask()
    }

    private func updateSilhouetteMask() {
        guard let layer else { return }

        guard let notchMergeWidth else {
            layer.mask = nil
            layer.cornerRadius = ShelfMetrics.cornerRadius
            return
        }

        layer.cornerRadius = 0
        silhouetteMask.frame = layer.bounds
        silhouetteMask.path = ShelfNotchSilhouettePath.make(
            in: layer.bounds,
            notchWidth: notchMergeWidth,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: false
        )
        layer.mask = silhouetteMask
    }
}

/// The window is taller than the material shelf so its sharing dock can sit in
/// truly transparent space below it. Only `shelfBackground` receives material.
final class ShelfPanelRootView: NSView {
    let shelfBackground = ShelfBackgroundView(frame: .zero)

    var showsShelfBackground = true {
        didSet {
            if showsShelfBackground {
                layoutShelfBackground()
            }
            shelfBackground.isHidden = !showsShelfBackground
        }
    }

    var notchMergeWidth: CGFloat? {
        didSet {
            // A shelf created by a direct notch drop can enter `.attached`
            // before AppKit performs the root view's first layout pass. Give
            // the material its real bounds before building the shape mask.
            layoutShelfBackground()
            shelfBackground.notchMergeWidth = notchMergeWidth
            shelfBackground.layoutSubtreeIfNeeded()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(shelfBackground)
        layoutShelfBackground()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(shelfBackground)
        layoutShelfBackground()
    }

    override func layout() {
        super.layout()
        layoutShelfBackground()
    }

    private func layoutShelfBackground() {
        shelfBackground.frame = CGRect(
            x: bounds.minX,
            y: bounds.minY + ShelfShareMetrics.footerHeight,
            width: bounds.width,
            height: max(0, bounds.height - ShelfShareMetrics.footerHeight)
        )
    }
}

//
//  ShelfNotchDropController.swift
//  Shelfer
//

import AppKit
import SwiftUI

/// Provides a drag destination over every physical camera housing even when no
/// shelf exists yet. The windows are present only during a real pasteboard drag,
/// so they never interfere with ordinary menu-bar interaction.
@MainActor
final class ShelfNotchDropController {
    var onDrop: (ShelfNotchTarget, [ShelfItem.Content]) -> Void

    private var panels: [UInt32: ShelfNotchDropPanel] = [:]
    private var isDragActive = false
    private var prefersPathOnlyDrop = false
    private var panelRemovalTask: Task<Void, Never>?
    private var screenParametersObserver: NSObjectProtocol?

    init(onDrop: @escaping (ShelfNotchTarget, [ShelfItem.Content]) -> Void) {
        self.onDrop = onDrop
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.isDragActive == true else { return }
                self?.rebuildPanels()
            }
        }
    }

    func setDragActive(_ isActive: Bool, prefersPathOnlyDrop: Bool) {
        guard isActive != isDragActive
                || prefersPathOnlyDrop != self.prefersPathOnlyDrop
        else { return }
        isDragActive = isActive
        self.prefersPathOnlyDrop = isActive && prefersPathOnlyDrop

        if isActive {
            cancelPanelRemoval()
            rebuildPanels()
        } else {
            schedulePanelRemoval()
        }
    }

    func invalidate() {
        isDragActive = false
        prefersPathOnlyDrop = false
        cancelPanelRemoval()
        removePanels()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    private func rebuildPanels() {
        removePanels()

        for target in ShelfNotchGeometry.targets() {
            let panel = ShelfNotchDropPanel(
                target: target,
                prefersPathOnlyDrop: prefersPathOnlyDrop
            ) { [weak self] target, contents in
                self?.onDrop(target, contents)
            }
            panels[target.displayID] = panel
            panel.orderFrontRegardless()
        }
    }

    private func removePanels() {
        panels.values.forEach { panel in
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
    }

    /// A global mouse-up is observed before AppKit finishes routing the drop to
    /// `performDragOperation`. Removing these destination windows synchronously
    /// makes a valid Finder drop vanish between those two callbacks. Keep them
    /// alive for a few run-loop turns, then remove them once delivery is done.
    private func schedulePanelRemoval() {
        cancelPanelRemoval()
        panelRemovalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }

            guard let self, !isDragActive else { return }
            removePanels()
            panelRemovalTask = nil
        }
    }

    private func cancelPanelRemoval() {
        panelRemovalTask?.cancel()
        panelRemovalTask = nil
    }

    static func fileDropMode(
        modifierFlags: NSEvent.ModifierFlags,
        pasteboard: NSPasteboard,
        prefersPathOnlyDrop: Bool,
        sessionModifierFlags: CGEventFlags? = nil
    ) -> ShelfFileDropMode {
        ShelfSurface.SurfaceView.fileDropMode(
            modifierFlags: modifierFlags,
            pasteboard: pasteboard,
            prefersPathOnlyDrop: prefersPathOnlyDrop,
            sessionModifierFlags: sessionModifierFlags
        )
    }
}

private final class ShelfNotchDropPanel: NSPanel {
    init(
        target: ShelfNotchTarget,
        prefersPathOnlyDrop: Bool,
        onDrop: @escaping (ShelfNotchTarget, [ShelfItem.Content]) -> Void
    ) {
        let ambientFrame = ShelfNotchGeometry.ambientFrame(for: target)
        super.init(
            contentRect: ambientFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = false

        let root = NSView(frame: NSRect(origin: .zero, size: ambientFrame.size))
        let ambient = NSHostingView(
            rootView: ShelfNotchAmbientLight(notchSize: target.notchFrame.size)
        )
        ambient.sizingOptions = []
        ambient.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(ambient)
        NSLayoutConstraint.activate([
            ambient.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ambient.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ambient.topAnchor.constraint(equalTo: root.topAnchor),
            ambient.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let dropFrame = ShelfNotchGeometry.dropFrame(for: target)
        let dropTarget = ShelfNotchDropTargetView(
            target: target,
            prefersPathOnlyDrop: prefersPathOnlyDrop,
            onDrop: onDrop
        )
        dropTarget.frame = CGRect(
            x: dropFrame.minX - ambientFrame.minX,
            y: dropFrame.minY - ambientFrame.minY,
            width: dropFrame.width,
            height: dropFrame.height
        )
        root.addSubview(dropTarget)
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ShelfNotchDropTargetView: NSView {
    private let target: ShelfNotchTarget
    private let prefersPathOnlyDrop: Bool
    private let onDrop: (ShelfNotchTarget, [ShelfItem.Content]) -> Void
    private var isTargeted = false {
        didSet {
            guard oldValue != isTargeted else { return }
            needsDisplay = true
        }
    }

    init(
        target: ShelfNotchTarget,
        prefersPathOnlyDrop: Bool,
        onDrop: @escaping (ShelfNotchTarget, [ShelfItem.Content]) -> Void
    ) {
        self.target = target
        self.prefersPathOnlyDrop = prefersPathOnlyDrop
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
        fileDropMode = .files
        preparedPayload = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isTargeted = false
        resetDragSession()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateFileDropMode(for: sender)
        return !contents(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateFileDropMode(for: sender)
        let contents = contents(for: sender)
        guard !contents.isEmpty else { return false }

        isTargeted = false
        resetDragSession()
        ShelfActiveDragIntent.consume()
        ShelfHaptics.confirmation()
        DispatchQueue.main.async { [target, onDrop] in
            onDrop(target, contents)
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isTargeted else { return }

        // Fill the complete target height, including the part hidden behind the
        // hardware notch. The previous short rounded rectangle ended below the
        // notch and exposed two empty wedges at its upper corners.
        let revealRect = CGRect(
            x: bounds.minX
                + ShelfNotchMetrics.dropTargetHorizontalInset
                - ShelfNotchMetrics.dropHighlightLeftExtension,
            y: bounds.minY,
            width: bounds.width
                - ShelfNotchMetrics.dropTargetHorizontalInset * 2
                + ShelfNotchMetrics.dropHighlightLeftExtension,
            height: bounds.height
        )
        let path = ShelfNotchDropHighlightPath.make(
            in: revealRect,
            bottomCornerRadius: ShelfNotchMetrics.dropHighlightBottomCornerRadius
        )
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.addPath(path)
        context.setFillColor(NSColor.black.withAlphaComponent(0.94).cgColor)
        let strokeColor: NSColor = fileDropMode == .paths ? .systemCyan : .controlAccentColor
        context.setStrokeColor(strokeColor.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(2)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    private func updateTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateFileDropMode(for: sender)
        guard ShelfSurface.SurfaceView.canAcceptContents(
            from: sender.draggingPasteboard
        ) else {
            isTargeted = false
            return []
        }

        if !isTargeted {
            isTargeted = true
            ShelfHaptics.alignment()
        }
        return .copy
    }

    private var fileDropMode: ShelfFileDropMode = .files
    private var activeDraggingSequenceNumber: Int?
    private var hasLatchedPathOnlyDrop = false
    private var preparedPayload: PreparedDropPayload?

    private func contents(for sender: NSDraggingInfo) -> [ShelfItem.Content] {
        let sequenceNumber = sender.draggingSequenceNumber
        if let preparedPayload,
           preparedPayload.sequenceNumber == sequenceNumber,
           preparedPayload.mode == fileDropMode {
            return preparedPayload.contents
        }

        let contents = ShelfSurface.SurfaceView.contents(
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
        }

        let newMode = ShelfNotchDropController.fileDropMode(
            modifierFlags: NSEvent.modifierFlags,
            pasteboard: sender.draggingPasteboard,
            prefersPathOnlyDrop: prefersPathOnlyDrop
                || ShelfActiveDragIntent.prefersPathOnlyDrop
        )
        if newMode == .paths {
            hasLatchedPathOnlyDrop = true
        }
        let resolvedMode: ShelfFileDropMode = hasLatchedPathOnlyDrop ? .paths : .files
        guard resolvedMode != fileDropMode else { return }
        fileDropMode = resolvedMode
        needsDisplay = true
        ShelfHaptics.alignment()
    }

    private func resetDragSession() {
        fileDropMode = .files
        activeDraggingSequenceNumber = nil
        hasLatchedPathOnlyDrop = false
        preparedPayload = nil
    }

    private struct PreparedDropPayload {
        let sequenceNumber: Int
        let mode: ShelfFileDropMode
        let contents: [ShelfItem.Content]
    }
}

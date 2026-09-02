//
//  ShelfPanel.swift
//  Shelfer
//

import AppKit

enum ShelfPanelTopControl: Hashable {
    case close
    case clear
    case back
    case grid
    case list
}

enum ShelfPanelKeyboardCommand: Equatable {
    case moveSelection(ShelfSelectionNavigationDirection)
    case deleteSelection
    case copySelection
    case paste
    case undo

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }

        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        let editingModifiers = modifiers.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])

        if editingModifiers.isEmpty {
            switch event.keyCode {
            case 51, 117:
                self = .deleteSelection
                return
            case 123, 126:
                self = .moveSelection(.previous)
                return
            case 124, 125:
                self = .moveSelection(.next)
                return
            default:
                break
            }
        }

        guard editingModifiers == .command else { return nil }

        // Use the physical ANSI key positions first. Character lookup changes
        // with the active input source (notably while typing Korean), whereas
        // macOS editing shortcuts are expected to remain ⌘C/⌘V/⌘Z.
        switch event.keyCode {
        case 8: self = .copySelection
        case 9: self = .paste
        case 6: self = .undo
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased()
            else { return nil }
            switch characters {
            case "c": self = .copySelection
            case "v": self = .paste
            case "z": self = .undo
            default: return nil
            }
        }
    }
}

/// Borderless floating panel that hosts the shelf without stealing focus from the
/// app the user is dragging from.
final class ShelfPanel: NSPanel {
    var frameAnimationDuration = ShelfMetrics.expansionAnimationDuration
    var onUserDragBegan: () -> Void = {}
    var onUserDragMoved: () -> Void = {}
    var onUserDragEnded: (CGPoint) -> Void = { _ in }
    var onTopControl: (ShelfPanelTopControl) -> Void = { _ in }
    var onKeyboardCommand: (ShelfPanelKeyboardCommand) -> Void = { _ in }
    var enabledTopControls: Set<ShelfPanelTopControl> = []

    private var userDragTask: Task<Void, Never>?
    private var keyboardMonitor: Any?
    private var isPerformingUserDrag = false
    private var pressedTopControl: ShelfPanelTopControl?
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
        // Shelfer behaves like a tool palette: its controls should act without
        // first taking keyboard focus away from the app the user is working in.
        // Combined with the hosting view's click-through support, this prevents
        // the first button press from being spent only on making the panel key.
        becomesKeyOnlyIfNeeded = true
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

        // AppKit may resolve menu shortcuts before they enter this panel's
        // sendEvent/performKeyEquivalent paths. A local monitor is the earliest
        // in-process hook and only consumes commands while this exact shelf is
        // the key window.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  isKeyWindow,
                  let command = ShelfPanelKeyboardCommand(event: event) else {
                return event
            }

            onKeyboardCommand(command)
            return nil
        }
    }

    deinit {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        frameAnimationDuration
    }

    /// Route the shelf's top controls before AppKit asks the dynamically
    /// composed SwiftUI/AppKit subtree to hit-test. This makes the complete
    /// 44pt circles deterministic even while an empty mid-drag shelf is being
    /// replaced by its filled state and its platform subviews are reordered.
    override func sendEvent(_ event: NSEvent) {
        if let command = ShelfPanelKeyboardCommand(event: event) {
            onKeyboardCommand(command)
            return
        }

        switch event.type {
        case .leftMouseDown:
            guard event.clickCount == 1,
                  let control = topControl(at: event.locationInWindow) else {
                super.sendEvent(event)
                return
            }
            pressedTopControl = control

        case .leftMouseDragged:
            if pressedTopControl == nil {
                super.sendEvent(event)
            }

        case .leftMouseUp:
            guard let pressedTopControl else {
                super.sendEvent(event)
                return
            }
            self.pressedTopControl = nil
            if topControl(at: event.locationInWindow) == pressedTopControl {
                onTopControl(pressedTopControl)
            }

        default:
            super.sendEvent(event)
        }
    }

    /// Command-key events can be offered to the menu/responder chain before
    /// AppKit sends them through the window's ordinary event path. Handling
    /// key equivalents here keeps ⌘C, ⌘V, and ⌘Z available even though Shelfer
    /// is hosted by a nonactivating utility panel with no conventional menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let command = ShelfPanelKeyboardCommand(event: event) else {
            return super.performKeyEquivalent(with: event)
        }

        onKeyboardCommand(command)
        return true
    }

    private func topControl(at windowPoint: CGPoint) -> ShelfPanelTopControl? {
        guard let contentView else { return nil }
        let point = contentView.convert(windowPoint, from: nil)

        for control in enabledTopControls {
            let center = topControlCenter(for: control, in: contentView.bounds)
            if hypot(point.x - center.x, point.y - center.y)
                <= ShelfMetrics.buttonHitDiameter / 2 {
                return control
            }
        }
        return nil
    }

    private func topControlCenter(
        for control: ShelfPanelTopControl,
        in bounds: CGRect
    ) -> CGPoint {
        let radius = ShelfMetrics.buttonHitDiameter / 2

        switch control {
        case .close:
            return CGPoint(
                x: bounds.minX + ShelfMetrics.buttonOuterInset + radius,
                y: bounds.maxY - ShelfMetrics.buttonOuterInset - radius
            )
        case .clear:
            return CGPoint(
                x: bounds.maxX - ShelfMetrics.buttonOuterInset - radius,
                y: bounds.maxY - ShelfMetrics.buttonOuterInset - radius
            )
        case .back:
            return CGPoint(
                x: bounds.minX + ShelfDetailMetrics.inset + radius,
                y: bounds.maxY - ShelfDetailMetrics.inset - radius
            )
        case .list:
            return CGPoint(
                x: bounds.maxX - ShelfDetailMetrics.inset - radius,
                y: bounds.maxY - ShelfDetailMetrics.inset - radius
            )
        case .grid:
            return CGPoint(
                x: bounds.maxX
                    - ShelfDetailMetrics.inset
                    - radius
                    - ShelfMetrics.buttonHitDiameter
                    - 8,
                y: bounds.maxY - ShelfDetailMetrics.inset - radius
            )
        }
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
    private(set) var notchSuctionProgress: CGFloat = 0

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
        // Use the same system material as macOS contextual menus so AppKit
        // supplies their native balance of backdrop blur, tint, and translucency.
        material = .menu
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
            silhouetteMask.removeAnimation(forKey: "notchSuction")
            notchSuctionProgress = 0
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
            topEdgeAtMinY: false,
            suctionProgress: notchSuctionProgress
        )
        layer.mask = silhouetteMask
    }

    func animateNotchSuction(
        to targetProgress: CGFloat,
        duration: TimeInterval,
        animated: Bool
    ) {
        guard notchMergeWidth != nil else {
            notchSuctionProgress = 0
            return
        }

        let startProgress = notchSuctionProgress
        let targetProgress = min(max(0, targetProgress), 1)
        notchSuctionProgress = targetProgress
        updateSilhouetteMask()

        guard animated, duration > 0, startProgress != targetProgress else {
            silhouetteMask.removeAnimation(forKey: "notchSuction")
            return
        }

        let stepCount = max(2, Int(duration * 60))
        let values = (0...stepCount).map { step -> CGPath in
            let fraction = CGFloat(step) / CGFloat(stepCount)
            let progress = startProgress + (targetProgress - startProgress) * fraction
            return suctionPath(progress: progress)
        }
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.32,
            0,
            0.18,
            1
        )
        silhouetteMask.add(animation, forKey: "notchSuction")
    }

    private func suctionPath(progress: CGFloat) -> CGPath {
        ShelfNotchSilhouettePath.make(
            in: silhouetteMask.bounds,
            notchWidth: notchMergeWidth ?? bounds.width,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: false,
            suctionProgress: progress
        )
    }
}

/// The window is taller than the material shelf so its sharing dock can sit in
/// truly transparent space below it. Only `shelfBackground` receives material.
final class ShelfPanelRootView: NSView {
    private static let entranceAnimationKey = "shelf.entrance"

    let shelfBackground = ShelfBackgroundView(frame: .zero)
    var onKeyboardCommand: (ShelfPanelKeyboardCommand) -> Void = { _ in }
    weak var suctionContentView: NSView? {
        didSet {
            suctionContentView?.wantsLayer = true
        }
    }

    private var genieOverlayLayer: CALayer?

    override var acceptsFirstResponder: Bool { true }

    override var needsPanelToBecomeKey: Bool { true }

    @objc(copy:)
    private func performCopyAction(_ sender: Any?) {
        onKeyboardCommand(.copySelection)
    }

    @objc(paste:)
    private func performPasteAction(_ sender: Any?) {
        onKeyboardCommand(.paste)
    }

    @objc(undo:)
    private func performUndoAction(_ sender: Any?) {
        onKeyboardCommand(.undo)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let command = ShelfPanelKeyboardCommand(event: event) else {
            return super.performKeyEquivalent(with: event)
        }

        onKeyboardCommand(command)
        return true
    }

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
            // A shelf created by a direct notch drop can start retracting
            // before AppKit performs the root view's first layout pass. Give
            // the material its real bounds before building the shape mask.
            layoutShelfBackground()
            shelfBackground.notchMergeWidth = notchMergeWidth
            shelfBackground.layoutSubtreeIfNeeded()
            if notchMergeWidth == nil {
                resetContentSuction()
            }
        }
    }

    func animateNotchSuction(
        to progress: CGFloat,
        duration: TimeInterval,
        animated: Bool
    ) {
        shelfBackground.animateNotchSuction(
            to: progress,
            duration: duration,
            animated: animated
        )
        animateContentSuction(
            to: progress,
            duration: duration,
            animated: animated
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(shelfBackground)
        layoutShelfBackground()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        addSubview(shelfBackground)
        layoutShelfBackground()
    }

    func animateEntrance(duration: TimeInterval, initialScale: CGFloat) {
        guard let layer else { return }

        layer.removeAnimation(forKey: Self.entranceAnimationKey)

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [initialScale, 1]
        scale.keyTimes = [0, 1]

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.72, 1]
        opacity.keyTimes = [0, 1]

        let animation = CAAnimationGroup()
        animation.animations = [scale, opacity]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.2,
            0.82,
            0.32,
            1
        )
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: Self.entranceAnimationKey)
    }

    func cancelEntranceAnimation() {
        layer?.removeAnimation(forKey: Self.entranceAnimationKey)
    }

#if DEBUG
    var isEntranceAnimationActiveForTesting: Bool {
        layer?.animation(forKey: Self.entranceAnimationKey) != nil
    }
#endif

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

    private func animateContentSuction(
        to targetProgress: CGFloat,
        duration: TimeInterval,
        animated: Bool
    ) {
        let targetProgress = min(max(0, targetProgress), 1)
        guard targetProgress > 0 else {
            resetContentSuction()
            return
        }

        guard animated, duration > 0 else {
            suctionContentView?.isHidden = true
            return
        }

        animateGenieSuction(duration: duration)
    }

    private func resetContentSuction() {
        genieOverlayLayer?.removeFromSuperlayer()
        genieOverlayLayer = nil
        suctionContentView?.isHidden = false
        shelfBackground.isHidden = !showsShelfBackground
    }

    private func animateGenieSuction(duration: TimeInterval) {
        resetContentSuction()
        layoutSubtreeIfNeeded()
        guard let snapshot = snapshotImage(), let rootLayer = layer else { return }

        let overlay = CALayer()
        overlay.frame = bounds
        overlay.isGeometryFlipped = true
        overlay.masksToBounds = false
        rootLayer.addSublayer(overlay)
        genieOverlayLayer = overlay

        suctionContentView?.isHidden = true
        shelfBackground.isHidden = true

        // Keep each strip close to three points high. The denser mesh makes
        // curved edges continuous on Retina displays without needing a custom
        // Metal shader.
        let sliceCount = max(48, Int(bounds.height / 3))
        let stepCount = max(2, Int(duration * 60))
        let backingScale = window?.backingScaleFactor ?? 2

        for index in 0..<sliceCount {
            let top = CGFloat(index) / CGFloat(sliceCount)
            let bottom = CGFloat(index + 1) / CGFloat(sliceCount)
            let sourceHeight = bounds.height / CGFloat(sliceCount)
            let slice = CALayer()
            slice.contents = snapshot
            slice.contentsScale = backingScale
            slice.contentsGravity = .resize
            slice.contentsRect = CGRect(
                x: 0,
                y: top,
                width: 1,
                height: bottom - top
            )
            slice.bounds = CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: sourceHeight + 0.8
            )
            slice.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            slice.allowsEdgeAntialiasing = true
            slice.minificationFilter = .linear
            slice.magnificationFilter = .linear
            overlay.addSublayer(slice)

            let states = (0...stepCount).map { step in
                ShelfGenieGeometry.state(
                    progress: CGFloat(step) / CGFloat(stepCount),
                    top: top,
                    bottom: bottom,
                    size: bounds.size
                )
            }
            guard let finalState = states.last else { continue }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            slice.position = finalState.center
            slice.transform = genieTransform(for: finalState)
            slice.opacity = Float(finalState.opacity)
            CATransaction.commit()

            addGenieAnimations(to: slice, states: states, duration: duration)
        }
    }

    private func addGenieAnimations(
        to layer: CALayer,
        states: [ShelfGenieSliceState],
        duration: TimeInterval
    ) {
        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = states.map { NSValue(point: $0.center) }

        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = states.map { NSValue(caTransform3D: genieTransform(for: $0)) }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = states.map(\.opacity)

        for animation in [position, transform, opacity] {
            animation.duration = duration
            animation.calculationMode = .linear
            animation.isRemovedOnCompletion = true
        }
        layer.add(position, forKey: "genie.position")
        layer.add(transform, forKey: "genie.transform")
        layer.add(opacity, forKey: "genie.opacity")
    }

    private func genieTransform(for state: ShelfGenieSliceState) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 500
        transform = CATransform3DScale(transform, state.scaleX, state.scaleY, 1)
        return CATransform3DRotate(transform, state.rotationX, 1, 0, 0)
    }

    private func snapshotImage() -> CGImage? {
        guard !bounds.isEmpty,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: representation)
        compositeOpaqueShelfSurface(behind: representation)
        return representation.cgImage
    }

    /// `NSVisualEffectView` records its blur as translucent pixels when cached.
    /// Once that bitmap leaves the live window during the Genie animation, the
    /// desktop can show through the moving strips. Filling only the shelf's
    /// silhouette behind those pixels preserves the material's appearance while
    /// guaranteeing that the animated sheet is fully opaque.
    private func compositeOpaqueShelfSurface(behind representation: NSBitmapImageRep) {
        guard let bitmapContext = NSGraphicsContext(bitmapImageRep: representation) else {
            return
        }

        let shelfFrame = shelfBackground.frame
        guard !shelfFrame.isEmpty else { return }

        let localPath = ShelfNotchSilhouettePath.make(
            in: CGRect(origin: .zero, size: shelfFrame.size),
            notchWidth: notchMergeWidth ?? shelfFrame.width,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: false
        )
        var translation = CGAffineTransform(
            translationX: shelfFrame.minX,
            y: shelfFrame.minY
        )
        guard let surfacePath = localPath.copy(using: &translation) else { return }

        let context = bitmapContext.cgContext
        context.saveGState()
        context.setBlendMode(.destinationOver)
        context.setFillColor(genieSurfaceColor)
        context.addPath(surfacePath)
        context.fillPath()
        context.restoreGState()
    }

    private var genieSurfaceColor: CGColor {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return CGColor(
                srgbRed: 0.14,
                green: 0.145,
                blue: 0.155,
                alpha: 1
            )
        }
        return CGColor(
            srgbRed: 0.94,
            green: 0.94,
            blue: 0.95,
            alpha: 1
        )
    }
}

extension NSView {
    /// Makes the stable shelf root the editor responder. Item views can be
    /// removed by Delete/Paste, while this root remains alive for the whole
    /// window session and therefore keeps subsequent shortcuts available.
    func claimShelfKeyboardFocus() {
        guard let window else { return }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        var candidate: NSView? = self
        while let view = candidate {
            if let root = view as? ShelfPanelRootView {
                window.makeFirstResponder(root)
                return
            }
            candidate = view.superview
        }

        window.makeFirstResponder(self)
    }
}

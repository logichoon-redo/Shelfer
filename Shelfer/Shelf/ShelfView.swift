//
//  ShelfView.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture
import SwiftUI

struct ShelfView: View {
    let store: StoreOf<ShelfFeature>

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHoveringShelf = false
    @State private var isTargeted = false
    @State private var areFilesTargeted = false
    @State private var isPathOnlyTargeted = false

    var body: some View {
        ZStack {
            border

            if let dockedEdge = store.dockedEdge {
                ShelfDockedHandle(edge: dockedEdge) {
                    store.send(.undockRequested)
                }
            } else {
                ShelfSurface(
                    prefersPathOnlyDrop: store.prefersPathOnlyDrop,
                    protectsTopLeftControl: !store.isEmpty
                        || store.showsEmptyCloseButton,
                    protectsTopRightControl: !store.isEmpty,
                    topControlOuterInset: store.isExpanded
                        ? ShelfDetailMetrics.inset
                        : ShelfMetrics.buttonOuterInset,
                    onTargetedChange: { isTargeted = $0 },
                    onFilesTargetedChange: { areFilesTargeted = $0 },
                    onPathOnlyChange: { isPathOnlyTargeted = $0 },
                    onDrop: { store.send(.itemsDropped($0)) }
                )
                .zIndex(0)

                Group {
                    if store.isExpanded {
                        ShelfDetailView(
                            store: store,
                            onExternalTargetedChange: { isTargeted = $0 },
                            onExternalFilesTargetedChange: { areFilesTargeted = $0 },
                            onExternalPathOnlyChange: { isPathOnlyTargeted = $0 }
                        )
                            .transition(contentTransition)
                    } else if store.isEmpty {
                        emptyState
                            .transition(contentTransition)
                    } else {
                        filledState
                            .transition(contentTransition)
                    }
                }
                // Keep SwiftUI's animation transaction on the controls only. The
                // panel owns all geometry changes.
                .animation(expansionAnimation, value: store.isExpanded)
                .zIndex(10)

                dockCornerTargets
                    .zIndex(20)

                if isTargeted && areFilesTargeted {
                    pathOnlyDropHint
                        .offset(y: 34)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(30)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { isHoveringShelf = $0 }
        .animation(.easeOut(duration: 0.14), value: isPathOnlyTargeted)
    }

    private var expansionAnimation: Animation? {
        guard !accessibilityReduceMotion else { return nil }
        return .easeInOut(duration: ShelfMetrics.expansionAnimationDuration)
    }

    private var clearAnimation: Animation? {
        guard !accessibilityReduceMotion else { return nil }
        return .easeIn(duration: ShelfMetrics.clearAnimationDuration)
    }

    /// The panel resize supplies the directional motion. A simple fade swaps
    /// the controls without making the persistent background appear to shrink.
    private var contentTransition: AnyTransition {
        .opacity
    }

    private var border: some View {
        ShelfBorderShape(notchWidth: mergingNotchWidth)
            .strokeBorder(
                isTargeted
                    ? (isPathOnlyTargeted ? Color.cyan : Color.accentColor)
                    : Color.white.opacity(0.14),
                lineWidth: isTargeted ? 3 : 1
            )
            .allowsHitTesting(false)
    }

    private var pathOnlyDropHint: some View {
        Label(
            isPathOnlyTargeted ? "Drop paths only" : "Hold ⌥ for path only",
            systemImage: isPathOnlyTargeted ? "terminal" : "option"
        )
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(isPathOnlyTargeted ? 0.95 : 0.68))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    isPathOnlyTargeted ? Color.cyan.opacity(0.8) : Color.white.opacity(0.12),
                    lineWidth: 1
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var mergingNotchWidth: CGFloat? {
        guard let notchDock = store.notchDock,
              notchDock.presentation == .retracting else { return nil }
        return ShelfNotchMetrics.mergeNeckWidth(
            for: notchDock.target.notchFrame.width
        )
    }

    private var dockCornerTargets: some View {
        HStack(spacing: 0) {
            ShelfDockChevron(
                pointsRight: false,
                idleOpacity: 0,
                hoverOpacity: 0.18,
                accessibilityLabel: "Dock shelf on the left"
            ) {
                store.send(.dockRequested(.left))
            }
            .frame(
                width: ShelfDockMetrics.cornerTargetSize,
                height: ShelfDockMetrics.cornerTargetSize
            )

            Spacer(minLength: 0)

            ShelfDockChevron(
                pointsRight: true,
                idleOpacity: 0,
                hoverOpacity: 0.18,
                accessibilityLabel: "Dock shelf on the right"
            ) {
                store.send(.dockRequested(.right))
            }
            .frame(
                width: ShelfDockMetrics.cornerTargetSize,
                height: ShelfDockMetrics.cornerTargetSize
            )
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var emptyState: some View {
        ZStack {
            EmptyShelfPrompt(isPresented: store.isPresented)

            if store.showsEmptyCloseButton {
                VStack(spacing: 0) {
                    HStack {
                        closeButton
                        Spacer()
                    }
                    .padding(ShelfMetrics.buttonOuterInset)

                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filledState: some View {
        VStack(spacing: 0) {
            topControls

            Spacer(minLength: 0)

            itemStack
                .scaleEffect(store.isClearing ? 0.18 : 1)
                .offset(y: store.isClearing ? -16 : 0)
                .opacity(store.isClearing ? 0 : 1)
                .blur(radius: store.isClearing ? 3 : 0)
                .allowsHitTesting(!store.isClearing)
                .animation(clearAnimation, value: store.isClearing)

            Spacer(minLength: 0)

            nameLabel
                .padding(.bottom, ShelfMetrics.outerInset)
                .opacity(store.isClearing ? 0 : 1)
                .allowsHitTesting(!store.isClearing)
                .animation(clearAnimation, value: store.isClearing)
        }
    }

    private var topControls: some View {
        ZStack(alignment: .top) {
            handle
            topButtons
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ShelfMetrics.buttonOuterInset)
        .padding(.top, ShelfMetrics.buttonOuterInset)
    }

    private var handle: some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(width: ShelfMetrics.handleSize.width, height: ShelfMetrics.handleSize.height)
            .opacity(isHoveringShelf ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: isHoveringShelf)
            // Decorative only: a filled shape would swallow the click and stop it
            // reaching the WindowDragArea that moves the panel.
            .allowsHitTesting(false)
    }

    private var topButtons: some View {
        GlassEffectContainer(spacing: 8) {
            HStack {
                closeButton
                Spacer()
                circleButton(systemImage: "trash", label: "Clear shelf") {
                    store.send(.clearButtonTapped)
                }
                .disabled(store.isClearing)
            }
        }
    }

    private var closeButton: some View {
        circleButton(systemImage: "xmark", label: "Close shelf") {
            store.send(.closeButtonTapped)
        }
    }

    private func circleButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        ShelfCircularButton(
            systemImage: systemImage,
            label: label,
            diameter: ShelfMetrics.buttonDiameter,
            action: action
        )
    }

    @ViewBuilder
    private var itemStack: some View {
        if !store.items.isEmpty {
            let visibleItems = Array(store.items.suffix(3))

            ZStack {
                // Keep every layer, including the top item, in one identified
                // collection. A structurally separate top view would reuse its
                // thumbnail state when a new item became the top of the stack.
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    let isTop = index == visibleItems.count - 1

                    icon(for: item)
                        .rotationEffect(.degrees(isTop ? 0 : index == 0 ? -7 : 5))
                        .rotationEffect(
                            .degrees(store.isClearing ? ShelfMetrics.clearRotationDegrees : 0)
                        )
                        .offset(x: isTop ? 0 : index == 0 ? -6 : 6, y: isTop ? 0 : 3)
                        .opacity(isTop ? 1 : 0.65)
                        .zIndex(Double(index))
                }
            }
            .overlay {
                ShelfDragSource(
                    contents: store.items.map(\.content),
                    acceptsExternalDrops: true,
                    prefersPathOnlyDrop: store.prefersPathOnlyDrop,
                    onCompleted: { store.send(.itemsDraggedOut($0)) },
                    onDragActiveChange: { store.send(.shelfDragActivityChanged($0)) },
                    onDoubleClick: { store.send(.stackDoubleClicked) },
                    onCopy: { store.send(.itemsCopyRequested($0, .stack)) },
                    onShare: {
                        store.send(.shareItemsRequested($0, store.items.map(\.content)))
                    },
                    onShowInFinder: { store.send(.revealItemsInFinderRequested($0)) },
                    onKeepPathsOnly: {
                        store.send(.itemsConvertToPathsRequested(Set(store.items.ids)))
                    },
                    onClear: { store.send(.clearButtonTapped) },
                    onExternalTargetedChange: { isTargeted = $0 },
                    onExternalFilesTargetedChange: { areFilesTargeted = $0 },
                    onExternalPathOnlyChange: { isPathOnlyTargeted = $0 },
                    onExternalDrop: { store.send(.itemsDropped($0)) }
                )
            }
            .overlay {
                if store.copyFeedbackTarget == .stack {
                    CopiedBadge()
                }
            }
            .animation(
                .easeOut(duration: 0.15),
                value: store.copyFeedbackTarget == .stack
            )
        }
    }

    private func icon(for item: ShelfItem) -> some View {
        ShelfItemIcon(item: item, size: ShelfMetrics.iconSize)
            .id(item.id)
    }

    /// Tapping the label opens the detail view; the chevron advertises that.
    private var nameLabel: some View {
        Button {
            store.send(.expandButtonTapped)
        } label: {
            HStack(spacing: 4) {
                if store.items.count == 1 {
                    MarqueeText(
                        text: labelText,
                        font: .system(size: 11, weight: .regular),
                        maxWidth: ShelfMetrics.labelTextMaxWidth,
                        pointsPerSecond: ShelfMetrics.labelMarqueePointsPerSecond
                    )
                } else {
                    // A count represents the whole stack and is always short
                    // enough to read at a glance, so it should never marquee.
                    Text(labelText)
                        .font(.system(size: 11, weight: .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.interaction, Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Show shelf contents")
        .help(labelHelpText)
    }

    private var labelText: String {
        switch store.items.count {
        case 0: ""
        case 1: store.items[0].displayName
        default: "\(store.items.count) items"
        }
    }

    private var labelHelpText: String {
        store.items.map(\.displayName).joined(separator: "\n")
    }
}

/// A circular glass control with a concrete interaction surface. The glass is
/// a visual effect and an SF Symbol only contributes its opaque glyph to hit
/// testing in some SwiftUI container/transition combinations. The nearly
/// transparent disc gives every shelf state the same full-size button target.
struct ShelfCircularButton: View {
    let systemImage: String
    let label: String
    let diameter: CGFloat
    var isSelected = false
    let action: () -> Void

    private var hitDiameter: CGFloat {
        max(diameter, ShelfMetrics.buttonHitDiameter)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.001))

                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: diameter, height: diameter)
                    .glassEffect(
                        isSelected
                            ? .regular.tint(.white.opacity(0.2)).interactive()
                            : .regular.interactive(),
                        in: .circle
                    )
            }
            .frame(width: hitDiameter, height: hitDiameter)
            .contentShape(.interaction, Circle())
        }
        .frame(width: hitDiameter, height: hitDiameter)
        .contentShape(.interaction, Circle())
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(label)
        .overlay {
            ShelfCircularButtonHitTarget(action: action)
                .frame(width: hitDiameter, height: hitDiameter)
                .accessibilityHidden(true)
                .zIndex(1)
        }
    }
}

/// SwiftUI continues to draw and expose the Liquid Glass button to
/// accessibility, while this borderless AppKit button owns pointer delivery.
/// Its hit test is a real 44pt circle and accepts the first click even while
/// Finder remains active, so view transitions cannot collapse it to the glyph.
private struct ShelfCircularButtonHitTarget: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> ShelfCircularHitButton {
        let button = ShelfCircularHitButton(frame: .zero)
        button.title = ""
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.isBordered = false
        button.focusRingType = .none
        button.setAccessibilityElement(false)
        return button
    }

    func updateNSView(_ nsView: ShelfCircularHitButton, context: Context) {
        context.coordinator.action = action
        nsView.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

final class ShelfCircularHitButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }

        let radius = min(bounds.width, bounds.height) / 2
        let distance = hypot(point.x - bounds.midX, point.y - bounds.midY)
        return distance <= radius ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // Liquid Glass is rendered by the SwiftUI button directly underneath.
    }
}

private struct ShelfBorderShape: InsettableShape {
    let notchWidth: CGFloat?
    private var insetAmount: CGFloat = 0

    init(notchWidth: CGFloat?, insetAmount: CGFloat = 0) {
        self.notchWidth = notchWidth
        self.insetAmount = insetAmount
    }

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)

        guard let notchWidth else {
            return RoundedRectangle(
                cornerRadius: max(0, ShelfMetrics.cornerRadius - insetAmount),
                style: .continuous
            )
            .path(in: insetRect)
        }

        return Path(
            ShelfNotchSilhouettePath.make(
                in: insetRect,
                notchWidth: max(0, notchWidth - insetAmount * 2),
                cornerRadius: max(0, ShelfMetrics.cornerRadius - insetAmount),
                topEdgeAtMinY: true
            )
        )
    }

    func inset(by amount: CGFloat) -> ShelfBorderShape {
        ShelfBorderShape(
            notchWidth: notchWidth,
            insetAmount: insetAmount + amount
        )
    }
}

/// Introduces the empty drop target with the short, damped pop used by the
/// reference shelf, without leaving a perpetual animation on screen.
private struct EmptyShelfPrompt: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var scale: CGFloat = 1.13
    @State private var opacity = 0.0

    let isPresented: Bool

    var body: some View {
        Text("Drop files here")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .scaleEffect(scale)
            .opacity(opacity)
            .allowsHitTesting(false)
            .task(id: isPresented) {
                guard isPresented else {
                    scale = 1.13
                    opacity = 0
                    return
                }

                guard !accessibilityReduceMotion else {
                    scale = 1
                    opacity = 1
                    return
                }

                // On the first summon the hosting view and its panel are created
                // in the same run-loop turn. Give AppKit two display frames to
                // order the panel before beginning the prompt animation.
                do {
                    try await Task.sleep(for: .milliseconds(32))
                } catch {
                    return
                }

                withAnimation(.easeOut(duration: 0.05)) {
                    opacity = 1
                }

                withAnimation(
                    .spring(
                        response: 0.36,
                        dampingFraction: 0.36,
                        blendDuration: 0
                    )
                ) {
                    scale = 1
                }
            }
    }
}

extension View {
    func shelfHoverHighlight() -> some View {
        modifier(ShelfHoverHighlightModifier())
    }
}

private struct ShelfHoverHighlightModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .foregroundStyle(.white.opacity(isHovering && isEnabled ? 0.09 : 0))
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// The compact hint shared by the undocked corner targets and the visible tab
/// of a docked shelf. Its movement begins only while the pointer is over the
/// interaction, keeping the resting shelf visually quiet.
private struct ShelfDockChevron: View {
    let pointsRight: Bool
    let idleOpacity: Double
    let hoverOpacity: Double
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovering = false
    @State private var isShifted = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)

            Image(systemName: pointsRight ? "chevron.right.2" : "chevron.left.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: isShifted ? (pointsRight ? 2.5 : -2.5) : 0)
                .opacity(isHovering ? hoverOpacity : idleOpacity)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: action)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .task(id: shouldPulse) {
            isShifted = false
            guard shouldPulse else { return }

            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.55)) {
                    isShifted.toggle()
                }

                do {
                    try await Task.sleep(for: .milliseconds(550))
                } catch {
                    isShifted = false
                    return
                }
            }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double-click")
    }

    private var shouldPulse: Bool {
        isHovering && !accessibilityReduceMotion
    }
}

/// A right-docked panel exposes its leading edge and points back to the left;
/// a left-docked panel mirrors that arrangement.
private struct ShelfDockedHandle: View {
    let edge: ShelfDockEdge
    let onDoubleClick: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if edge == .right {
                handle(pointsRight: false)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                handle(pointsRight: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handle(pointsRight: Bool) -> some View {
        ShelfDockChevron(
            pointsRight: pointsRight,
            idleOpacity: 0.2,
            hoverOpacity: 0.34,
            accessibilityLabel: "Restore shelf"
        ) {
            onDoubleClick()
        }
        .frame(width: ShelfDockMetrics.handleWidth)
        .frame(maxHeight: .infinity)
    }
}

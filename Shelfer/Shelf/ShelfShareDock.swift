//
//  ShelfShareDock.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture
import SwiftUI

struct ShelfPanelContentView: View {
    let store: StoreOf<ShelfFeature>

    var body: some View {
        VStack(spacing: ShelfShareMetrics.gap) {
            ShelfView(store: store)
                .frame(maxWidth: .infinity)
                .frame(height: shelfSize.height)

            ShelfShareDock(store: store)
                .frame(
                    width: ShelfShareMetrics.dockSize.width,
                    height: ShelfShareMetrics.dockSize.height
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var shelfSize: CGSize {
        store.isExpanded ? ShelfDetailMetrics.size : ShelfMetrics.size
    }
}

private struct ShelfShareDock: View {
    let store: StoreOf<ShelfFeature>

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var emergenceProgress: CGFloat = 0
    @State private var hasSplitDuringCurrentDrag = false
    @State private var hoveredMethod: ShelfShareMethod?
    @State private var isExpanded = false
    @State private var returnTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { direction in
                ShareSplitBridge(
                    progress: isExpanded ? 1 : 0,
                    direction: direction
                )
            }

            shareCircle(
                systemImage: "square.and.arrow.up",
                isTargeted: false
            )
                .modifier(
                    ShareDropletEmergenceModifier(
                        progress: emergenceProgress
                    )
                )
                .scaleEffect(
                    x: isExpanded ? 1.32 : 1,
                    y: isExpanded ? 0.72 : 1,
                    anchor: .center
                )
                .blur(radius: isExpanded ? 1.2 : 0)
                .opacity(isExpanded ? 0 : 1)

            ForEach(Array(ShelfShareMethod.allCases.enumerated()), id: \.element) { index, method in
                VStack(spacing: 4) {
                    shareCircle(
                        systemImage: method.systemImage,
                        isTargeted: hoveredMethod == method
                    )
                    Text(method.shortTitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .modifier(
                    ShareDropletSplitModifier(
                        progress: isExpanded ? 1 : 0,
                        destinationX: CGFloat(index - 1) * ShelfShareMetrics.optionStride
                    )
                )
                .help(method.title)
            }

            ShareDropSurface(
                isExpanded: isExpanded,
                onExpandedChange: { expanded in
                    if expanded {
                        hasSplitDuringCurrentDrag = true
                    }
                    isExpanded = expanded
                },
                onHoveredMethodChange: { hoveredMethod = $0 },
                onDrop: { method, contents in
                    store.send(.shareItemsDropped(method, contents))
                    hoveredMethod = nil
                    isExpanded = false
                }
            )
            .frame(
                width: ShelfShareMetrics.dockSize.width,
                height: ShelfShareMetrics.dockSize.height
            )
        }
        .frame(
            width: ShelfShareMetrics.dockSize.width,
            height: ShelfShareMetrics.dockSize.height,
            alignment: .top
        )
        .animation(dropletAnimation, value: isExpanded)
        .animation(.easeOut(duration: 0.12), value: hoveredMethod)
        .onAppear {
            emergenceProgress = store.hasActiveDrag ? 1 : 0
        }
        .onChange(of: store.hasActiveDrag) { _, isActive in
            if isActive {
                separateFromShelf()
            } else {
                returnToShelf()
            }
        }
    }

    private var dropletEmergenceAnimation: Animation? {
        guard !accessibilityReduceMotion else { return nil }
        return .spring(response: 0.42, dampingFraction: 0.72)
    }

    private var dropletAnimation: Animation? {
        guard !accessibilityReduceMotion else { return nil }
        return .spring(response: 0.38, dampingFraction: 0.68)
    }

    private func separateFromShelf() {
        returnTask?.cancel()
        returnTask = nil
        hasSplitDuringCurrentDrag = false

        withAnimation(dropletEmergenceAnimation) {
            emergenceProgress = 1
        }
    }

    /// Reverses the interaction in two readable steps: the share destinations
    /// merge back into one drop, then that drop is pulled into the shelf body.
    private func returnToShelf() {
        returnTask?.cancel()
        let needsMerge = hasSplitDuringCurrentDrag || isExpanded

        withAnimation(dropletAnimation) {
            hoveredMethod = nil
            isExpanded = false
        }

        guard needsMerge, !accessibilityReduceMotion else {
            withAnimation(dropletEmergenceAnimation) {
                emergenceProgress = 0
            }
            hasSplitDuringCurrentDrag = false
            return
        }

        returnTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, !store.hasActiveDrag else { return }

            withAnimation(dropletEmergenceAnimation) {
                emergenceProgress = 0
            }
            hasSplitDuringCurrentDrag = false
            returnTask = nil
        }
    }

    private func shareCircle(
        systemImage: String,
        isTargeted: Bool
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(
                width: ShelfShareMetrics.circleDiameter,
                height: ShelfShareMetrics.circleDiameter
            )
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle().fill(.white.opacity(isTargeted ? 0.18 : 0.04))
                    }
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    }
            }
            .scaleEffect(isTargeted ? 1.08 : 1)
    }
}

/// Pulls the collapsed share circle out of the shelf's lower edge. The capsule
/// is visible only in the middle of the animation, creating the narrowing neck
/// of a droplet just before it separates.
private struct ShareDropletEmergenceModifier: AnimatableModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let phase = min(max(progress, 0), 1)

        ZStack(alignment: .top) {
            ShareShelfLiquidNeck(progress: phase)

            content
                .scaleEffect(
                    x: 0.52 + 0.48 * phase,
                    y: 1.36 - 0.36 * phase,
                    anchor: .top
                )
                .offset(y: -40 * (1 - phase))
                .opacity(min(1, phase * 2.8))
        }
    }
}

/// A metaball mask joins a source bulge inside the shelf to the moving share
/// circle. As the source shrinks, the narrow neck snaps and leaves a detached
/// drop instead of looking like a circle that merely faded into place.
private struct ShareShelfLiquidNeck: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let phase = min(max(progress, 0), 1)
        let neckOpacity = sin(.pi * phase)

        Rectangle()
            .fill(.ultraThinMaterial)
            .mask {
                Canvas { context, size in
                    context.addFilter(.alphaThreshold(min: 0.48, color: .white))
                    context.addFilter(.blur(radius: 7))

                    context.drawLayer { layer in
                        let centerX = size.width / 2
                        let sourceRadius = max(2, 18 * (1 - phase))
                        let movingRadius: CGFloat = 19
                        let sourceCenterY: CGFloat = 44
                        let movingCenterY = 34 + 40 * phase

                        layer.fill(
                            Path(
                                ellipseIn: CGRect(
                                    x: centerX - sourceRadius,
                                    y: sourceCenterY - sourceRadius,
                                    width: sourceRadius * 2,
                                    height: sourceRadius * 2
                                )
                            ),
                            with: .color(.white)
                        )
                        layer.fill(
                            Path(
                                ellipseIn: CGRect(
                                    x: centerX - movingRadius,
                                    y: movingCenterY - movingRadius,
                                    width: movingRadius * 2,
                                    height: movingRadius * 2
                                )
                            ),
                            with: .color(.white)
                        )
                    }
                }
            }
            .frame(width: 72, height: 104)
            .offset(y: -52)
            .opacity(neckOpacity * min(1, phase * 4))
            .allowsHitTesting(false)
    }
}

/// Moves each destination out of the original share circle while briefly
/// stretching it along the travel axis, like a small liquid mass pulling free.
private struct ShareDropletSplitModifier: AnimatableModifier {
    var progress: CGFloat
    let destinationX: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let phase = min(max(progress, 0), 1)
        let stretch = sin(.pi * phase)

        content
            .offset(x: destinationX * phase)
            .scaleEffect(
                x: 0.34 + 0.66 * phase + 0.18 * stretch,
                y: 0.72 + 0.28 * phase - 0.12 * stretch,
                anchor: .top
            )
            .opacity(phase)
    }
}

/// Temporary liquid neck between the center and each side destination. It grows
/// with the separating circles, then thins and disappears once they are apart.
private struct ShareSplitBridge: View, Animatable {
    var progress: CGFloat
    let direction: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let phase = min(max(progress, 0), 1)
        let opacity = sin(.pi * phase)
        let length = max(12, ShelfShareMetrics.optionStride * phase)
        let thickness = 5 + 13 * (1 - phase)

        Capsule()
            .fill(.ultraThinMaterial)
            .frame(width: length, height: thickness)
            .offset(
                x: direction * ShelfShareMetrics.optionStride * phase / 2,
                y: (ShelfShareMetrics.circleDiameter - thickness) / 2
            )
            .opacity(opacity * 0.88)
    }
}

private extension ShelfShareMethod {
    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .email: "Email"
        case .kakaoTalk: "KakaoTalk"
        }
    }

    var shortTitle: String {
        switch self {
        case .airDrop: "AirDrop"
        case .email: "Mail"
        case .kakaoTalk: "Kakao"
        }
    }

    var systemImage: String {
        switch self {
        case .airDrop: "airdrop"
        case .email: "envelope.fill"
        case .kakaoTalk: "message.fill"
        }
    }
}

@MainActor
enum ShelfHaptics {
    static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func confirmation() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

private struct ShareDropSurface: NSViewRepresentable {
    let isExpanded: Bool
    var onExpandedChange: (Bool) -> Void
    var onHoveredMethodChange: (ShelfShareMethod?) -> Void
    var onDrop: (ShelfShareMethod, [ShelfItem.Content]) -> Void

    func makeNSView(context: Context) -> TargetView {
        let view = TargetView()
        view.registerForDraggedTypes([.fileURL, .string])
        update(view)
        return view
    }

    func updateNSView(_ nsView: TargetView, context: Context) {
        update(nsView)
    }

    private func update(_ view: TargetView) {
        view.isExpanded = isExpanded
        view.onExpandedChange = onExpandedChange
        view.onHoveredMethodChange = onHoveredMethodChange
        view.onDrop = onDrop
    }

    final class TargetView: NSView {
        var isExpanded = false
        var onExpandedChange: (Bool) -> Void = { _ in }
        var onHoveredMethodChange: (ShelfShareMethod?) -> Void = { _ in }
        var onDrop: (ShelfShareMethod, [ShelfItem.Content]) -> Void = { _, _ in }

        private var hoveredMethod: ShelfShareMethod?
        private var exitMergeTask: Task<Void, Never>?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            cancelExitMerge()
            return updateTarget(for: sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            cancelExitMerge()
            return updateTarget(for: sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            scheduleExitMerge()
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            cancelExitMerge()
            reset()
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            method(at: convert(sender.draggingLocation, from: nil)) != nil
                && !ShelfSurface.SurfaceView.contents(from: sender.draggingPasteboard).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let location = convert(sender.draggingLocation, from: nil)
            guard let method = method(at: location) else { return false }
            let contents = ShelfSurface.SurfaceView.contents(from: sender.draggingPasteboard)
            guard !contents.isEmpty else { return false }

            (sender.draggingSource as? ShelfDragSource.DragSourceView)?.markAsShared()
            ShelfHaptics.confirmation()

            DispatchQueue.main.async { [onDrop] in
                onDrop(method, contents)
            }
            return true
        }

        private func updateTarget(for sender: NSDraggingInfo) -> NSDragOperation {
            let contents = ShelfSurface.SurfaceView.contents(from: sender.draggingPasteboard)
            guard !contents.isEmpty else { return [] }

            let location = convert(sender.draggingLocation, from: nil)
            if !isExpanded {
                guard collapsedCircleRect.contains(location) else { return [] }
                isExpanded = true
                onExpandedChange(true)
                ShelfHaptics.alignment()
                return .copy
            }

            // Keep the split menu and its last highlighted option alive while
            // crossing the small gaps between circles. The exact hit target is
            // checked again at drop time, so releasing in a gap shares nothing.
            if let method = method(at: location), method != hoveredMethod {
                hoveredMethod = method
                onHoveredMethodChange(method)
                ShelfHaptics.alignment()
            }
            return .copy
        }

        private var collapsedCircleRect: CGRect {
            circleRect(centerX: bounds.midX)
        }

        private func method(at point: CGPoint) -> ShelfShareMethod? {
            for (index, method) in ShelfShareMethod.allCases.enumerated() {
                let centerX = bounds.midX
                    + CGFloat(index - 1) * ShelfShareMetrics.optionStride
                if circleRect(centerX: centerX).contains(point) {
                    return method
                }
            }
            return nil
        }

        private func circleRect(centerX: CGFloat) -> CGRect {
            CGRect(
                x: centerX - ShelfShareMetrics.circleDiameter / 2,
                y: bounds.maxY - ShelfShareMetrics.circleDiameter,
                width: ShelfShareMetrics.circleDiameter,
                height: ShelfShareMetrics.circleDiameter
            )
        }

        private func reset() {
            guard isExpanded || hoveredMethod != nil else { return }
            isExpanded = false
            hoveredMethod = nil
            onHoveredMethodChange(nil)
            onExpandedChange(false)
        }

        /// A short delay filters the transient exit AppKit may emit while the
        /// circles animate. A real departure from the full dock bounds persists
        /// long enough to merge the three destinations back into one droplet.
        private func scheduleExitMerge() {
            exitMergeTask?.cancel()
            exitMergeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.reset()
                self?.exitMergeTask = nil
            }
        }

        private func cancelExitMerge() {
            exitMergeTask?.cancel()
            exitMergeTask = nil
        }

    }
}

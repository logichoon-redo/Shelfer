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

    var body: some View {
        ZStack {
            border
            ShelfSurface(
                onTargetedChange: { isTargeted = $0 },
                onDrop: { store.send(.itemsDropped($0)) }
            )

            Group {
                if store.isExpanded {
                    ShelfDetailView(store: store)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { isHoveringShelf = $0 }
        .overlay(alignment: .center) {
            if store.didCopy { CopiedBadge() }
        }
        .animation(.easeOut(duration: 0.15), value: store.didCopy)
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
        let shape = RoundedRectangle(cornerRadius: ShelfMetrics.cornerRadius, style: .continuous)
        return shape
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.white.opacity(0.14),
                lineWidth: isTargeted ? 3 : 1
            )
            .allowsHitTesting(false)
    }

    private var emptyState: some View {
        ZStack {
            Text("Drop files here")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .allowsHitTesting(false)

            if store.showsEmptyCloseButton {
                VStack(spacing: 0) {
                    HStack {
                        closeButton
                        Spacer()
                    }
                    .padding(ShelfMetrics.outerInset)

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
        .padding(.horizontal, ShelfMetrics.outerInset)
        .padding(.top, ShelfMetrics.outerInset)
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
        HStack {
            closeButton
            Spacer()
            circleButton(systemImage: "trash", label: "Clear shelf") {
                store.send(.clearButtonTapped)
            }
            .disabled(store.isClearing)
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
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: ShelfMetrics.buttonDiameter, height: ShelfMetrics.buttonDiameter)
                .background(Circle().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .shelfHoverHighlight()
        .focusEffectDisabled()
        .accessibilityLabel(label)
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
                        .offset(x: isTop ? 0 : index == 0 ? -6 : 6, y: isTop ? 0 : 3)
                        .opacity(isTop ? 1 : 0.65)
                        .zIndex(Double(index))
                }
            }
            .overlay {
                ShelfDragSource(
                    contents: store.items.map(\.content),
                    onCompleted: { store.send(.itemsDraggedOut($0)) },
                    onDragActiveChange: { store.send(.shelfDragActivityChanged($0)) },
                    onDoubleClick: { store.send(.stackDoubleClicked) }
                )
            }
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
                MarqueeText(
                    text: labelText,
                    font: .system(size: 11, weight: .regular),
                    maxWidth: ShelfMetrics.labelTextMaxWidth,
                    pointsPerSecond: ShelfMetrics.labelMarqueePointsPerSecond
                )
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .shelfHoverHighlight()
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

//
//  ShelfView.swift
//  C5
//

import AppKit
import ComposableArchitecture
import SwiftUI

struct ShelfView: View {
    let store: StoreOf<ShelfFeature>

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
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
        .overlay(alignment: .center) {
            if store.didCopy { CopiedBadge() }
        }
        .animation(.easeOut(duration: 0.15), value: store.didCopy)
    }

    private var expansionAnimation: Animation? {
        guard !accessibilityReduceMotion else { return nil }
        return .easeInOut(duration: ShelfMetrics.expansionAnimationDuration)
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
        Text("Drop files here")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .allowsHitTesting(false)
    }

    private var filledState: some View {
        VStack(spacing: 0) {
            handle
                .padding(.top, 8)

            topButtons
                .padding(.horizontal, ShelfMetrics.buttonInset)
                .padding(.top, 6)

            Spacer(minLength: 0)

            itemStack

            Spacer(minLength: 0)

            nameLabel
                .padding(.bottom, 18)
        }
    }

    private var handle: some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(width: ShelfMetrics.handleSize.width, height: ShelfMetrics.handleSize.height)
            // Decorative only: a filled shape would swallow the click and stop it
            // reaching the WindowDragArea that moves the panel.
            .allowsHitTesting(false)
    }

    private var topButtons: some View {
        HStack {
            circleButton(systemImage: "xmark", label: "Close shelf") {
                store.send(.closeButtonTapped)
            }
            Spacer()
            circleButton(systemImage: "chevron.down", label: "Show shelf details") {
                store.send(.expandButtonTapped)
            }
        }
    }

    private func circleButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: ShelfMetrics.buttonDiameter, height: ShelfMetrics.buttonDiameter)
                .background(Circle().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var itemStack: some View {
        if let top = store.items.last {
            ZStack {
                // Items underneath peek out as a slightly fanned stack.
                ForEach(Array(store.items.dropLast().suffix(2).enumerated()), id: \.element.id) { index, item in
                    icon(for: item)
                        .rotationEffect(.degrees(index == 0 ? -7 : 5))
                        .offset(x: index == 0 ? -6 : 6, y: 3)
                        .opacity(0.65)
                }

                icon(for: top)
            }
            .overlay {
                ShelfDragSource(
                    contents: store.items.map(\.content),
                    onCompleted: { store.send(.itemsDraggedOut($0)) },
                    onDoubleClick: { store.send(.stackDoubleClicked) }
                )
            }
        }
    }

    private func icon(for item: ShelfItem) -> some View {
        ShelfItemIcon(item: item, size: ShelfMetrics.iconSize)
    }

    /// Tapping the label opens the detail view; the chevron advertises that.
    private var nameLabel: some View {
        Button {
            store.send(.expandButtonTapped)
        } label: {
            HStack(spacing: 6) {
                MarqueeText(text: labelText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Show shelf contents")
    }

    private var labelText: String {
        switch store.items.count {
        case 0: ""
        case 1: store.items[0].displayName
        default: "\(store.items.count) items"
        }
    }
}

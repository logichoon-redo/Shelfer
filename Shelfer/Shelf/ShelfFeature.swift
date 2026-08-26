//
//  ShelfFeature.swift
//  Shelfer
//

import ComposableArchitecture
import Foundation

enum ShelfDockEdge: Equatable, Sendable {
    case left
    case right
}

@Reducer
struct ShelfFeature {
    @ObservableState
    struct State: Equatable, Identifiable {
        var id = UUID()
        var items: IdentifiedArrayOf<ShelfItem> = []

        /// Whether a shelf is on screen, and where it was last summoned.
        /// The window layer mirrors these rather than owning the decision.
        var isPresented = false
        var position: CGPoint?

        /// While docked, the panel is mostly outside this screen edge. The
        /// window controller retains its exact undocked frame for restoration.
        var dockedEdge: ShelfDockEdge?

        /// True only while the pointer is carrying an active drag payload.
        /// Drag-only controls stay completely hidden at every other time.
        var isDragActive = false

        /// Shelf-originated drags report their lifecycle directly. Keeping this
        /// separate prevents a global mouse-up event from hiding the sharing
        /// droplet before AppKit finishes the shelf's own drag session.
        var isShelfDragActive = false

        var hasActiveDrag: Bool {
            isDragActive || isShelfDragActive
        }

        /// Whether the shelf is showing its detail list instead of the compact stack.
        var isExpanded = false
        var layout: ShelfLayout = .grid

        /// Keeps the items alive while their clear-away animation is running.
        var isClearing = false

        /// A shelf emptied explicitly by the user keeps a way to close the
        /// otherwise-empty panel. The initial drop target does not show it.
        var showsEmptyCloseButton = false

        /// Briefly true after a copy, so the shelf can confirm something happened.
        var didCopy = false

        var isEmpty: Bool { items.isEmpty }

        var hasText: Bool {
            items.contains { if case .text = $0.content { true } else { false } }
        }
    }

    enum ShelfLayout: Equatable {
        case grid
        case list
    }

    enum Action: Equatable {
        case dragActivityChanged(Bool)
        case shelfDragActivityChanged(Bool)
        case dockRequested(ShelfDockEdge)
        case undockRequested
        case itemsDropped([ShelfItem.Content])
        case itemsDraggedOut([ShelfItem.Content])
        case closeButtonTapped
        case clearButtonTapped
        case clearAnimationFinished
        case expandButtonTapped
        case backButtonTapped
        case layoutChanged(ShelfLayout)
        case revealInFinderTapped
        case shareItemsDropped(ShelfShareMethod, [ShelfItem.Content])
        /// Double-clicking one item in the detail view copies its text or image.
        case itemDoubleClicked(ShelfItem.ID)
        /// Double-clicking the collapsed stack copies every snippet at once, or
        /// its image when the stack contains a single image.
        case stackDoubleClicked
        case imageCopyFinished(Bool)
        case copyFeedbackExpired
        /// Dismisses the shelf but keeps whatever is on it, unlike closing.
        case hideRequested
    }

    @Dependency(\.workspace) var workspace
    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.sharing) var sharing
    @Dependency(\.continuousClock) var clock

    // Opted out of the project's default MainActor isolation: a cancellation ID
    // must be Sendable, which an actor-isolated conformance can't satisfy.
    private nonisolated enum CancelID {
        case clearAnimation
        case copyFeedback
    }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case let .dragActivityChanged(isActive):
                state.isDragActive = isActive
                return .none

            case let .shelfDragActivityChanged(isActive):
                state.isShelfDragActive = isActive
                return .none

            case let .dockRequested(edge):
                guard state.isPresented else { return .none }
                state.dockedEdge = edge
                return .none

            case .undockRequested:
                state.dockedEdge = nil
                return .none

            case let .itemsDropped(contents):
                let interruptedClear = state.isClearing
                if interruptedClear {
                    // New content wins over an in-flight clear. The items that
                    // were already flying away are discarded immediately.
                    state.items.removeAll()
                    state.isClearing = false
                }
                if !contents.isEmpty {
                    state.showsEmptyCloseButton = false
                }
                for content in contents {
                    state.items.append(ShelfItem(content))
                }
                return interruptedClear ? .cancel(id: CancelID.clearAnimation) : .none

            case let .itemsDraggedOut(contents):
                // The shelf is a staging area: once items land elsewhere they
                // leave it, and an emptied shelf dismisses itself.
                for content in contents {
                    state.items.remove(id: ShelfItem(content).id)
                }
                if state.isEmpty {
                    state.isPresented = false
                    state.isExpanded = false
                    state.showsEmptyCloseButton = false
                    state.dockedEdge = nil
                }
                return .none

            case .closeButtonTapped:
                state.items.removeAll()
                state.isPresented = false
                state.isExpanded = false
                state.isClearing = false
                state.showsEmptyCloseButton = false
                state.dockedEdge = nil
                return .cancel(id: CancelID.clearAnimation)

            case .clearButtonTapped:
                guard !state.isEmpty, !state.isClearing else { return .none }
                state.isClearing = true
                return .run { send in
                    try await clock.sleep(for: .milliseconds(260))
                    await send(.clearAnimationFinished)
                }
                .cancellable(id: CancelID.clearAnimation, cancelInFlight: true)

            case .clearAnimationFinished:
                guard state.isClearing else { return .none }
                state.items.removeAll()
                state.isExpanded = false
                state.isClearing = false
                state.showsEmptyCloseButton = true
                // Deliberately keep `isPresented`: clearing returns this same
                // panel to its initial drop-target state instead of closing it.
                return .none

            case .expandButtonTapped:
                // Nothing to detail on an empty shelf.
                guard !state.isEmpty, !state.isClearing else { return .none }
                state.isExpanded.toggle()
                return .none

            case .backButtonTapped:
                state.isExpanded = false
                return .none

            case let .layoutChanged(layout):
                state.layout = layout
                return .none

            case .revealInFinderTapped:
                let urls = state.items.compactMap(\.url)
                return .run { _ in await workspace.revealInFinder(urls) }

            case let .shareItemsDropped(method, contents):
                guard !contents.isEmpty else { return .none }
                return .run { _ in
                    await sharing.share(method, contents)
                }

            case let .itemDoubleClicked(id):
                guard let item = state.items[id: id] else { return .none }
                return copy(item, &state)

            case .stackDoubleClicked:
                let snippets = state.items.compactMap { item -> String? in
                    guard case let .text(text) = item.content else { return nil }
                    return text
                }
                if !snippets.isEmpty {
                    return copyText(snippets.joined(separator: "\n"), &state)
                }

                // A collapsed multi-item stack represents the collection rather
                // than its top item. Only a lone image has an unambiguous payload.
                guard state.items.count == 1, let item = state.items.first else { return .none }
                return copy(item, &state)

            case let .imageCopyFinished(didCopy):
                guard didCopy else { return .none }
                return showCopyFeedback(&state)

            case .copyFeedbackExpired:
                state.didCopy = false
                return .none

            case .hideRequested:
                state.isPresented = false
                state.dockedEdge = nil
                return .none
            }
        }
    }

    private func copy(_ item: ShelfItem, _ state: inout State) -> Effect<Action> {
        switch item.content {
        case let .text(text):
            return copyText(text, &state)

        case let .file(url) where item.isImage:
            return copyImage(url)

        case .file:
            return .none
        }
    }

    private func copyText(_ text: String, _ state: inout State) -> Effect<Action> {
        state.didCopy = true
        return .run { send in
            await pasteboard.copyText(text)
            try await clock.sleep(for: .seconds(1))
            await send(.copyFeedbackExpired)
        }
        .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
    }

    private func copyImage(_ url: URL) -> Effect<Action> {
        return .run { send in
            let didCopy = await pasteboard.copyImage(url)
            await send(.imageCopyFinished(didCopy))
        }
    }

    private func showCopyFeedback(_ state: inout State) -> Effect<Action> {
        state.didCopy = true
        return .run { send in
            try await clock.sleep(for: .seconds(1))
            await send(.copyFeedbackExpired)
        }
        .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
    }
}

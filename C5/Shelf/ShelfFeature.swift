//
//  ShelfFeature.swift
//  C5
//

import ComposableArchitecture
import Foundation

@Reducer
struct ShelfFeature {
    @ObservableState
    struct State: Equatable {
        var items: IdentifiedArrayOf<ShelfItem> = []

        /// Whether a shelf is on screen, and where it was last summoned.
        /// The window layer mirrors these rather than owning the decision.
        var isPresented = false
        var position: CGPoint?

        /// Whether the shelf is showing its detail list instead of the compact stack.
        var isExpanded = false
        var layout: ShelfLayout = .grid

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
        /// Begin listening for drag gestures. Sent once at launch.
        case task
        case shelfRequested(CGPoint)
        case dragEnded
        case itemsDropped([ShelfItem.Content])
        case itemsDraggedOut([ShelfItem.Content])
        case closeButtonTapped
        case expandButtonTapped
        case backButtonTapped
        case layoutChanged(ShelfLayout)
        case revealInFinderTapped
        case optionsButtonTapped
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

    @Dependency(\.dragMonitor) var dragMonitor
    @Dependency(\.workspace) var workspace
    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.continuousClock) var clock

    // Opted out of the project's default MainActor isolation: a cancellation ID
    // must be Sendable, which an actor-isolated conformance can't satisfy.
    private nonisolated enum CancelID { case copyFeedback }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    for await event in await dragMonitor.events() {
                        switch event {
                        case let .shelfRequested(point):
                            await send(.shelfRequested(point))
                        case .dragEnded:
                            await send(.dragEnded)
                        }
                    }
                }

            case let .shelfRequested(point):
                state.position = point
                state.isPresented = true
                return .none

            case .dragEnded:
                // A shelf summoned mid-drag that never received anything was not
                // wanted, so it shouldn't linger on screen.
                if state.isEmpty { state.isPresented = false }
                return .none

            case let .itemsDropped(contents):
                for content in contents {
                    state.items.append(ShelfItem(content))
                }
                return .none

            case let .itemsDraggedOut(contents):
                // The shelf is a staging area: once items land elsewhere they
                // leave it, and an emptied shelf dismisses itself.
                for content in contents {
                    state.items.remove(id: ShelfItem(content).id)
                }
                if state.isEmpty {
                    state.isPresented = false
                    state.isExpanded = false
                }
                return .none

            case .closeButtonTapped:
                state.items.removeAll()
                state.isPresented = false
                state.isExpanded = false
                return .none

            case .expandButtonTapped:
                // Nothing to detail on an empty shelf.
                guard !state.isEmpty else { return .none }
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

            case .optionsButtonTapped:
                // TODO: per-shelf options (name, colour, behaviour).
                return .none

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

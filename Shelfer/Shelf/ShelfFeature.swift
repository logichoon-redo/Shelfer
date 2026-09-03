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

enum ShelfCopyFeedbackTarget: Equatable, Sendable {
    case item(ShelfItem.ID)
    case stack
}

enum ShelfReorderPlacement: Equatable, Sendable {
    case before
    case after
}

enum ShelfSelectionNavigationDirection: Equatable, Sendable {
    case previous
    case next
}

@Reducer
struct ShelfFeature {
    struct EditSnapshot: Equatable {
        var items: IdentifiedArrayOf<ShelfItem>
        var selectedItemIDs: Set<ShelfItem.ID>
        var isExpanded: Bool
        var showsEmptyCloseButton: Bool
    }

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

        /// Present only on a display whose safe area reports a camera housing.
        /// The presentation phase drives retraction and the hover peek.
        var notchDock: ShelfNotchDock?

        /// True only while the pointer is carrying an active drag payload.
        /// Drag-only controls stay completely hidden at every other time.
        var isDragActive = false

        /// Remembers that Option was held before this shelf existed. AppKit's
        /// destination callback cannot reliably reconstruct modifiers from the
        /// beginning of a cross-application drag.
        var prefersPathOnlyDrop = false

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

        /// Clicking items toggles membership without requiring a modifier.
        var selectedItemIDs: Set<ShelfItem.ID> = []

        /// Content edits use a small local history so ⌘Z can restore deletes,
        /// paste replacements, and drag reordering without involving the app
        /// that happened to be active before this nonactivating panel.
        var undoHistory: [EditSnapshot] = []

        /// Keeps the items alive while their clear-away animation is running.
        var isClearing = false

        /// A shelf emptied explicitly by the user keeps a way to close the
        /// otherwise-empty panel. The initial drop target does not show it.
        var showsEmptyCloseButton = false

        /// Identifies the exact item that should confirm a successful copy.
        /// The compact shelf uses `.stack` because it represents all contents.
        var copyFeedbackTarget: ShelfCopyFeedbackTarget?

        var isEmpty: Bool { items.isEmpty }

        var hasText: Bool {
            items.contains {
                switch $0.content {
                case .path, .text: true
                case .file: false
                }
            }
        }

        /// An interaction that starts on a selected item applies to the entire
        /// selection. An unselected item remains an independent target until
        /// its click action updates the selection.
        func itemsTargeted(by id: ShelfItem.ID) -> [ShelfItem] {
            guard selectedItemIDs.contains(id) else {
                return items[id: id].map { [$0] } ?? []
            }
            return items.filter { selectedItemIDs.contains($0.id) }
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
        case notchDockRequested(ShelfNotchTarget)
        case notchRetractionFinished
        case notchHoverChanged(Bool)
        case notchUndockRequested
        case itemsDropped([ShelfItem.Content])
        case itemsDraggedOut([ShelfItem.Content])
        case closeButtonTapped
        case clearButtonTapped
        case clearAnimationFinished
        case expandButtonTapped
        case backButtonTapped
        case layoutChanged(ShelfLayout)
        case backgroundTapped
        case itemSelectionToggled(ShelfItem.ID)
        case itemContextMenuRequested(ShelfItem.ID)
        case selectionMoveRequested(ShelfSelectionNavigationDirection)
        case deleteSelectionRequested
        case copySelectionRequested
        case pasteRequested
        case pasteContentsLoaded(
            [ShelfItem.Content],
            replacing: Set<ShelfItem.ID>
        )
        case itemsReorderRequested(
            [ShelfItem.ID],
            relativeTo: ShelfItem.ID,
            placement: ShelfReorderPlacement
        )
        case undoRequested
        case revealInFinderTapped
        case revealItemsInFinderRequested([ShelfItem.Content])
        case shareItemsDropped(ShelfShareMethod, [ShelfItem.Content])
        case shareItemsRequested(ShelfShareMethod, [ShelfItem.Content])
        case itemsCopyRequested([ShelfItem.Content], ShelfCopyFeedbackTarget)
        case itemsCopyFinished(Bool, ShelfCopyFeedbackTarget)
        /// Replaces file references with inert absolute-path strings.
        case itemsConvertToPathsRequested(Set<ShelfItem.ID>)
        /// Removes the item or selected group targeted in the expanded shelf.
        case itemsClearRequested(Set<ShelfItem.ID>)
        /// Double-clicking one item in the detail view copies its text or image.
        case itemDoubleClicked(ShelfItem.ID)
        /// Double-clicking the collapsed stack copies every snippet at once, or
        /// its image when the stack contains a single image.
        case stackDoubleClicked
        case imageCopyFinished(Bool, ShelfCopyFeedbackTarget)
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
        case notchLifecycle
        case paste
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
                state.notchDock = nil
                // Every side-dock entry point renders the same compact return
                // handle. In particular, dragging an expanded shelf to a
                // display edge must not leave the handle sized and positioned
                // using the detail panel's geometry.
                state.isExpanded = false
                state.selectedItemIDs.removeAll()
                return .cancel(id: CancelID.notchLifecycle)

            case .undockRequested:
                state.dockedEdge = nil
                return .none

            case let .notchDockRequested(target):
                guard state.isPresented else { return .none }
                state.dockedEdge = nil
                state.isExpanded = false
                state.selectedItemIDs.removeAll()
                state.notchDock = ShelfNotchDock(target: target, presentation: .retracting)
                return .run { send in
                    try await clock.sleep(for: .seconds(ShelfNotchMetrics.retractionDuration))
                    await send(.notchRetractionFinished)
                }
                .cancellable(id: CancelID.notchLifecycle, cancelInFlight: true)

            case .notchRetractionFinished:
                guard state.notchDock?.presentation == .retracting else { return .none }
                state.notchDock?.presentation = .stowed
                return .none

            case let .notchHoverChanged(isHovering):
                switch (state.notchDock?.presentation, isHovering) {
                case (.stowed, true):
                    state.notchDock?.presentation = .peeking
                case (.peeking, false):
                    state.notchDock?.presentation = .stowed
                default:
                    break
                }
                return .none

            case .notchUndockRequested:
                state.notchDock = nil
                return .cancel(id: CancelID.notchLifecycle)

            case let .itemsDropped(contents):
                let interruptedClear = state.isClearing
                state.prefersPathOnlyDrop = false
                if interruptedClear {
                    // New content wins over an in-flight clear. The items that
                    // were already flying away are discarded immediately.
                    state.items.removeAll()
                    state.selectedItemIDs.removeAll()
                    state.isClearing = false
                }
                if !contents.isEmpty {
                    state.showsEmptyCloseButton = false
                }

                // Build and append one deduplicated batch. Repeatedly mutating
                // an IdentifiedArray for a large Finder selection causes its
                // identity index and observation machinery to do avoidable
                // work for every single file.
                var knownIDs = Set(state.items.ids)
                var newItems: [ShelfItem] = []
                newItems.reserveCapacity(contents.count)
                for content in contents {
                    let item = ShelfItem(content)
                    if knownIDs.insert(item.id).inserted {
                        newItems.append(item)
                    }
                }
                if !newItems.isEmpty {
                    state.items.append(contentsOf: newItems)
                }
                return interruptedClear ? .cancel(id: CancelID.clearAnimation) : .none

            case let .itemsDraggedOut(contents):
                // The shelf is a staging area: once items land elsewhere they
                // leave it, and an emptied shelf dismisses itself.
                let removedIDs = Set(contents.map { ShelfItem($0).id })
                state.items.removeAll { removedIDs.contains($0.id) }
                state.selectedItemIDs.subtract(removedIDs)
                if state.isEmpty {
                    state.isPresented = false
                    state.isExpanded = false
                    state.selectedItemIDs.removeAll()
                    state.showsEmptyCloseButton = false
                    state.dockedEdge = nil
                    state.notchDock = nil
                }
                return state.isEmpty ? .cancel(id: CancelID.notchLifecycle) : .none

            case .closeButtonTapped:
                state.items.removeAll()
                state.isPresented = false
                state.prefersPathOnlyDrop = false
                state.isExpanded = false
                state.selectedItemIDs.removeAll()
                state.isClearing = false
                state.showsEmptyCloseButton = false
                state.dockedEdge = nil
                state.notchDock = nil
                return .merge(
                    .cancel(id: CancelID.clearAnimation),
                    .cancel(id: CancelID.notchLifecycle),
                    .cancel(id: CancelID.paste)
                )

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
                state.selectedItemIDs.removeAll()
                state.isClearing = false
                state.showsEmptyCloseButton = true
                // Deliberately keep `isPresented`: clearing returns this same
                // panel to its initial drop-target state instead of closing it.
                return .none

            case .expandButtonTapped:
                // Nothing to detail on an empty shelf.
                guard !state.isEmpty, !state.isClearing else { return .none }
                state.isExpanded.toggle()
                if !state.isExpanded {
                    state.selectedItemIDs.removeAll()
                }
                return .none

            case .backButtonTapped:
                state.isExpanded = false
                state.selectedItemIDs.removeAll()
                return .none

            case let .layoutChanged(layout):
                state.layout = layout
                return .none

            case .backgroundTapped:
                guard state.isExpanded else { return .none }
                state.selectedItemIDs.removeAll()
                return .none

            case let .itemSelectionToggled(id):
                guard state.isExpanded, state.items[id: id] != nil else { return .none }
                if state.selectedItemIDs.contains(id) {
                    state.selectedItemIDs.remove(id)
                } else {
                    state.selectedItemIDs.insert(id)
                }
                return .none

            case let .itemContextMenuRequested(id):
                guard state.isExpanded, state.items[id: id] != nil else { return .none }
                // Right-clicking inside an existing multi-selection preserves
                // it. A right-click elsewhere moves selection to that item.
                if !state.selectedItemIDs.contains(id) {
                    state.selectedItemIDs = [id]
                }
                return .none

            case let .selectionMoveRequested(direction):
                guard state.isExpanded, !state.items.isEmpty else { return .none }

                let selectedIndices = state.items.indices.filter {
                    state.selectedItemIDs.contains(state.items[$0].id)
                }
                let targetIndex: Int
                switch direction {
                case .previous:
                    targetIndex = selectedIndices.min().map {
                        max(state.items.startIndex, $0 - 1)
                    } ?? state.items.index(before: state.items.endIndex)
                case .next:
                    targetIndex = selectedIndices.max().map {
                        min(state.items.index(before: state.items.endIndex), $0 + 1)
                    } ?? state.items.startIndex
                }

                state.selectedItemIDs = [state.items[targetIndex].id]
                return .none

            case .deleteSelectionRequested:
                guard state.isExpanded else { return .none }
                return clearItems(
                    state.selectedItemIDs,
                    recordingUndo: true,
                    in: &state
                )

            case .copySelectionRequested:
                guard state.isExpanded else { return .none }
                let selectedItems = state.items.filter {
                    state.selectedItemIDs.contains($0.id)
                }
                guard let feedbackItem = selectedItems.first else { return .none }
                return .send(
                    .itemsCopyRequested(
                        selectedItems.map(\.content),
                        .item(feedbackItem.id)
                    )
                )

            case .pasteRequested:
                guard state.isPresented,
                      state.isExpanded,
                      !state.isClearing else { return .none }
                let replacementIDs = state.selectedItemIDs
                return .run { send in
                    let contents = await pasteboard.readContents()
                    await send(
                        .pasteContentsLoaded(
                            contents,
                            replacing: replacementIDs
                        )
                    )
                }
                .cancellable(id: CancelID.paste, cancelInFlight: true)

            case let .pasteContentsLoaded(contents, replacementIDs):
                guard state.isExpanded,
                      !state.isClearing,
                      !contents.isEmpty else { return .none }

                var resultingItems = IdentifiedArrayOf<ShelfItem>()
                resultingItems.reserveCapacity(
                    state.items.count - state.selectedItemIDs.count + contents.count
                )
                for item in state.items where !replacementIDs.contains(item.id) {
                    resultingItems.append(item)
                }

                var pastedIDs: Set<ShelfItem.ID> = []
                for content in contents {
                    let item = ShelfItem(content)
                    pastedIDs.insert(item.id)
                    if resultingItems[id: item.id] == nil {
                        resultingItems.append(item)
                    }
                }

                let resultingSelection = pastedIDs.intersection(
                    Set(resultingItems.ids)
                )

                // A duplicate-only paste changes no contents, but selecting
                // the matching shelf item gives immediate visual feedback that
                // the payload already exists. Selection itself is not an undo
                // step, just like an ordinary item click.
                guard resultingItems != state.items else {
                    state.selectedItemIDs = resultingSelection
                    return .none
                }

                recordUndo(in: &state)
                state.items = resultingItems
                state.selectedItemIDs = resultingSelection
                state.showsEmptyCloseButton = false
                return .none

            case let .itemsReorderRequested(movingIDs, targetID, placement):
                guard state.isExpanded,
                      !state.isClearing,
                      !movingIDs.isEmpty,
                      state.items[id: targetID] != nil else { return .none }

                let movingIDSet = Set(movingIDs)
                guard !movingIDSet.contains(targetID) else { return .none }

                let orderedMovingItems = state.items.filter {
                    movingIDSet.contains($0.id)
                }
                guard !orderedMovingItems.isEmpty else { return .none }

                var remainingItems = state.items.filter {
                    !movingIDSet.contains($0.id)
                }
                guard let targetIndex = remainingItems.firstIndex(where: {
                    $0.id == targetID
                }) else { return .none }

                let insertionIndex = placement == .before
                    ? targetIndex
                    : targetIndex + 1
                remainingItems.insert(contentsOf: orderedMovingItems, at: insertionIndex)

                let reorderedItems = IdentifiedArray(uniqueElements: remainingItems)
                guard reorderedItems != state.items else { return .none }

                recordUndo(in: &state)
                state.items = reorderedItems
                // Reordering is a spatial edit, not a selection gesture. An
                // unselected item can move independently, and an existing
                // multi-selection remains exactly as the user left it.
                state.selectedItemIDs.formIntersection(Set(reorderedItems.ids))
                return .none

            case .undoRequested:
                guard let snapshot = state.undoHistory.popLast() else { return .none }
                state.items = snapshot.items
                state.selectedItemIDs = snapshot.selectedItemIDs.intersection(
                    Set(snapshot.items.ids)
                )
                state.isExpanded = snapshot.isExpanded && !snapshot.items.isEmpty
                state.showsEmptyCloseButton = snapshot.showsEmptyCloseButton
                state.isClearing = false
                state.copyFeedbackTarget = nil
                return .merge(
                    .cancel(id: CancelID.clearAnimation),
                    .cancel(id: CancelID.copyFeedback),
                    .cancel(id: CancelID.paste)
                )

            case .revealInFinderTapped:
                let urls = state.items.compactMap(\.url)
                return .run { _ in await workspace.revealInFinder(urls) }

            case let .revealItemsInFinderRequested(contents):
                let urls = contents.compactMap { content -> URL? in
                    guard case let .file(url) = content else { return nil }
                    return url
                }
                guard !urls.isEmpty else { return .none }
                return .run { _ in await workspace.revealInFinder(urls) }

            case let .shareItemsDropped(method, contents),
                 let .shareItemsRequested(method, contents):
                guard !contents.isEmpty else { return .none }
                return .run { _ in
                    await sharing.share(method, contents)
                }

            case let .itemsCopyRequested(contents, feedbackTarget):
                guard !contents.isEmpty else { return .none }
                return .run { send in
                    let didCopy = await pasteboard.copyContents(contents)
                    await send(.itemsCopyFinished(didCopy, feedbackTarget))
                }

            case let .itemsCopyFinished(didCopy, feedbackTarget):
                guard didCopy else { return .none }
                return showCopyFeedback(feedbackTarget, &state)

            case let .itemsConvertToPathsRequested(ids):
                guard !ids.isEmpty else { return .none }

                let oldSelection = state.selectedItemIDs
                var convertedItems: IdentifiedArrayOf<ShelfItem> = []
                var convertedSelection: Set<ShelfItem.ID> = []

                for item in state.items {
                    let converted: ShelfItem
                    if ids.contains(item.id), case let .file(url) = item.content {
                        converted = ShelfItem(.path(url.path))
                    } else {
                        converted = item
                    }

                    // A matching path may already be present. Keep the first
                    // occurrence while still moving selection to that identity.
                    if convertedItems[id: converted.id] == nil {
                        convertedItems.append(converted)
                    }
                    if oldSelection.contains(item.id) {
                        convertedSelection.insert(converted.id)
                    }
                }

                state.items = convertedItems
                state.selectedItemIDs = convertedSelection.intersection(
                    Set(convertedItems.ids)
                )
                return .none

            case let .itemsClearRequested(ids):
                return clearItems(ids, recordingUndo: false, in: &state)

            case let .itemDoubleClicked(id):
                guard let item = state.items[id: id] else { return .none }
                return copy(item, feedbackTarget: .item(id), &state)

            case .stackDoubleClicked:
                let snippets = state.items.compactMap { item -> String? in
                    switch item.content {
                    case let .path(path): path
                    case let .text(text): text
                    case .file: nil
                    }
                }
                if !snippets.isEmpty {
                    return copyText(
                        snippets.joined(separator: "\n"),
                        feedbackTarget: .stack,
                        &state
                    )
                }

                // A collapsed multi-item stack represents the collection rather
                // than its top item. Only a lone image has an unambiguous payload.
                guard state.items.count == 1, let item = state.items.first else { return .none }
                return copy(item, feedbackTarget: .stack, &state)

            case let .imageCopyFinished(didCopy, feedbackTarget):
                guard didCopy else { return .none }
                return showCopyFeedback(feedbackTarget, &state)

            case .copyFeedbackExpired:
                state.copyFeedbackTarget = nil
                return .none

            case .hideRequested:
                state.isPresented = false
                state.dockedEdge = nil
                state.notchDock = nil
                state.selectedItemIDs.removeAll()
                return .cancel(id: CancelID.notchLifecycle)
            }
        }
    }

    private func recordUndo(in state: inout State) {
        let snapshot = EditSnapshot(
            items: state.items,
            selectedItemIDs: state.selectedItemIDs,
            isExpanded: state.isExpanded,
            showsEmptyCloseButton: state.showsEmptyCloseButton
        )
        state.undoHistory.append(snapshot)

        let maximumUndoCount = 30
        if state.undoHistory.count > maximumUndoCount {
            state.undoHistory.removeFirst(
                state.undoHistory.count - maximumUndoCount
            )
        }
    }

    private func clearItems(
        _ ids: Set<ShelfItem.ID>,
        recordingUndo: Bool,
        in state: inout State
    ) -> Effect<Action> {
        guard !state.isClearing,
              !ids.isEmpty,
              ids.contains(where: { state.items[id: $0] != nil }) else { return .none }

        if recordingUndo {
            recordUndo(in: &state)
        }

        state.items.removeAll { ids.contains($0.id) }
        state.selectedItemIDs.subtract(ids)

        let clearedCopyFeedback: Bool
        if case let .item(feedbackID)? = state.copyFeedbackTarget {
            clearedCopyFeedback = ids.contains(feedbackID)
        } else {
            clearedCopyFeedback = false
        }
        if clearedCopyFeedback {
            state.copyFeedbackTarget = nil
        }

        if state.isEmpty {
            state.isExpanded = false
            state.showsEmptyCloseButton = true
        }

        return clearedCopyFeedback
            ? .cancel(id: CancelID.copyFeedback)
            : .none
    }

    private func copy(
        _ item: ShelfItem,
        feedbackTarget: ShelfCopyFeedbackTarget,
        _ state: inout State
    ) -> Effect<Action> {
        switch item.content {
        case let .path(path):
            return copyText(path, feedbackTarget: feedbackTarget, &state)

        case let .text(text):
            return copyText(text, feedbackTarget: feedbackTarget, &state)

        case let .file(url) where item.isImage:
            return copyImage(url, feedbackTarget: feedbackTarget)

        case .file:
            return .none
        }
    }

    private func copyText(
        _ text: String,
        feedbackTarget: ShelfCopyFeedbackTarget,
        _ state: inout State
    ) -> Effect<Action> {
        state.copyFeedbackTarget = feedbackTarget
        return .run { send in
            await pasteboard.copyText(text)
            try await clock.sleep(for: .seconds(1))
            await send(.copyFeedbackExpired)
        }
        .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
    }

    private func copyImage(
        _ url: URL,
        feedbackTarget: ShelfCopyFeedbackTarget
    ) -> Effect<Action> {
        return .run { send in
            let didCopy = await pasteboard.copyImage(url)
            await send(.imageCopyFinished(didCopy, feedbackTarget))
        }
    }

    private func showCopyFeedback(
        _ feedbackTarget: ShelfCopyFeedbackTarget,
        _ state: inout State
    ) -> Effect<Action> {
        state.copyFeedbackTarget = feedbackTarget
        return .run { send in
            try await clock.sleep(for: .seconds(1))
            await send(.copyFeedbackExpired)
        }
        .cancellable(id: CancelID.copyFeedback, cancelInFlight: true)
    }
}

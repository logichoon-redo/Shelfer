//
//  ShelvesFeature.swift
//  Shelfer
//

import ComposableArchitecture
import CoreGraphics
import Foundation

/// Owns the set of independent shelves and the one system-wide drag monitor.
/// A summon always appends a new shelf; it never repurposes a shelf that is
/// already on screen.
@Reducer
struct ShelvesFeature {
    @ObservableState
    struct State: Equatable {
        var shelves: IdentifiedArrayOf<ShelfFeature.State> = []
        var isDragActive = false
        var activeDragPrefersPathOnlyDrop = false

        /// The empty shelf created for the current drag. It is discarded if the
        /// drag ends without landing content on that shelf.
        var pendingShelfID: ShelfFeature.State.ID?

        var isPresented: Bool {
            shelves.contains(where: \.isPresented)
        }
    }

    enum Action: Equatable {
        case task
        case dragActivityChanged(Bool, prefersPathOnlyDrop: Bool)
        case shelfRequested(CGPoint, prefersPathOnlyDrop: Bool)
        case showRequested(CGPoint)
        case externalItemsRequested([ShelfItem.Content], CGPoint)
        case notchItemsDropped(ShelfNotchTarget, [ShelfItem.Content])
        case dragEnded
        case shelves(IdentifiedActionOf<ShelfFeature>)
        case removeShelf(ShelfFeature.State.ID)
        case hideRequested
    }

    @Dependency(\.dragMonitor) var dragMonitor
    @Dependency(\.uuid) var uuid

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    for await event in await dragMonitor.events() {
                        switch event {
                        case let .activityChanged(isActive, prefersPathOnlyDrop):
                            await send(
                                .dragActivityChanged(
                                    isActive,
                                    prefersPathOnlyDrop: prefersPathOnlyDrop
                                )
                            )
                        case let .shelfRequested(point, prefersPathOnlyDrop):
                            await send(
                                .shelfRequested(
                                    point,
                                    prefersPathOnlyDrop: prefersPathOnlyDrop
                                )
                            )
                        case .dragEnded:
                            await send(.dragEnded)
                        }
                    }
                }

            case let .dragActivityChanged(isActive, prefersPathOnlyDrop):
                state.isDragActive = isActive
                state.activeDragPrefersPathOnlyDrop = isActive && prefersPathOnlyDrop
                for id in state.shelves.ids {
                    state.shelves[id: id]?.isDragActive = isActive
                }
                return .none

            case let .shelfRequested(point, prefersPathOnlyDrop):
                // A newer summon supersedes only an older, still-unused pending
                // shelf. Shelves that already contain content are never moved or
                // replaced by this event.
                if let pendingShelfID = state.pendingShelfID,
                   state.shelves[id: pendingShelfID]?.isEmpty == true {
                    state.shelves.remove(id: pendingShelfID)
                }

                let id = uuid()
                state.shelves.append(
                    ShelfFeature.State(
                        id: id,
                        isPresented: true,
                        position: point,
                        isDragActive: state.isDragActive,
                        prefersPathOnlyDrop: prefersPathOnlyDrop
                    )
                )
                state.pendingShelfID = id
                return .none

            case let .showRequested(point):
                guard !state.shelves.isEmpty else {
                    state.shelves.append(
                        ShelfFeature.State(
                            id: uuid(),
                            isPresented: true,
                            position: point,
                            isDragActive: state.isDragActive
                        )
                    )
                    return .none
                }

                for id in state.shelves.ids {
                    state.shelves[id: id]?.isPresented = true
                }
                return .none

            case let .externalItemsRequested(contents, point):
                guard !contents.isEmpty else { return .none }

                // A service invocation represents a complete payload, so it
                // replaces only an unused shelf left pending by a drag gesture.
                if let pendingShelfID = state.pendingShelfID,
                   state.shelves[id: pendingShelfID]?.isEmpty == true {
                    state.shelves.remove(id: pendingShelfID)
                }
                state.pendingShelfID = nil

                let shelfID = uuid()
                state.shelves.append(
                    ShelfFeature.State(
                        id: shelfID,
                        isPresented: true,
                        position: point,
                        isDragActive: state.isDragActive
                    )
                )
                return .send(
                    .shelves(
                        .element(
                            id: shelfID,
                            action: .itemsDropped(contents)
                        )
                    )
                )

            case let .notchItemsDropped(target, contents):
                guard !contents.isEmpty else { return .none }

                if let shelfID = state.shelves.first(where: {
                    $0.notchDock?.target.displayID == target.displayID
                })?.id {
                    state.shelves[id: shelfID]?.isPresented = true
                    return .concatenate(
                        .send(.shelves(.element(id: shelfID, action: .itemsDropped(contents)))),
                        .send(.shelves(.element(id: shelfID, action: .notchDockRequested(target))))
                    )
                }

                let shelfID = uuid()
                state.shelves.append(
                    ShelfFeature.State(
                        id: shelfID,
                        isPresented: true,
                        position: CGPoint(
                            x: target.notchFrame.midX,
                            y: target.notchFrame.minY - ShelfMetrics.size.height / 2
                        ),
                        isDragActive: state.isDragActive
                    )
                )
                return .concatenate(
                    .send(.shelves(.element(id: shelfID, action: .itemsDropped(contents)))),
                    .send(.shelves(.element(id: shelfID, action: .notchDockRequested(target))))
                )

            case .dragEnded:
                state.isDragActive = false
                state.activeDragPrefersPathOnlyDrop = false
                for id in state.shelves.ids {
                    state.shelves[id: id]?.isDragActive = false
                }

                if let pendingShelfID = state.pendingShelfID,
                   state.shelves[id: pendingShelfID]?.isEmpty == true {
                    state.shelves.remove(id: pendingShelfID)
                }
                state.pendingShelfID = nil
                return .none

            case let .shelves(.element(id: id, action: .closeButtonTapped)):
                // Let the child perform its own cleanup first, then remove its
                // window state on the next reducer turn.
                return .send(.removeShelf(id))

            case let .shelves(.element(id: id, action: .itemsDraggedOut(contents))):
                guard let shelf = state.shelves[id: id], !shelf.items.isEmpty else {
                    return .none
                }

                let draggedIDs = Set(contents.map { ShelfItem($0).id })
                let willBecomeEmpty = shelf.items.allSatisfy { draggedIDs.contains($0.id) }
                return willBecomeEmpty ? .send(.removeShelf(id)) : .none

            case .shelves:
                return .none

            case let .removeShelf(id):
                state.shelves.remove(id: id)
                if state.pendingShelfID == id {
                    state.pendingShelfID = nil
                }
                return .none

            case .hideRequested:
                // Route through every child so hiding also clears transient
                // selection state and cancels an in-flight notch lifecycle.
                // Direct state mutation here used to leave those child-owned
                // details alive until the shelf was shown again.
                return .concatenate(
                    state.shelves.ids.map { id in
                        .send(
                            .shelves(
                                .element(id: id, action: .hideRequested)
                            )
                        )
                    }
                )
            }
        }
        .forEach(\.shelves, action: \.shelves) {
            ShelfFeature()
        }
    }
}

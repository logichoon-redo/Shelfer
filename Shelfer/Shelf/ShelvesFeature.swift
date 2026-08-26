//
//  ShelvesFeature.swift
//  Shelfer
//

import ComposableArchitecture
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

        /// The empty shelf created for the current drag. It is discarded if the
        /// drag ends without landing content on that shelf.
        var pendingShelfID: ShelfFeature.State.ID?

        var isPresented: Bool {
            shelves.contains(where: \.isPresented)
        }
    }

    enum Action: Equatable {
        case task
        case dragActivityChanged(Bool)
        case shelfRequested(CGPoint)
        case showRequested(CGPoint)
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
                        case let .activityChanged(isActive):
                            await send(.dragActivityChanged(isActive))
                        case let .shelfRequested(point):
                            await send(.shelfRequested(point))
                        case .dragEnded:
                            await send(.dragEnded)
                        }
                    }
                }

            case let .dragActivityChanged(isActive):
                state.isDragActive = isActive
                for id in state.shelves.ids {
                    state.shelves[id: id]?.isDragActive = isActive
                }
                return .none

            case let .shelfRequested(point):
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
                        isDragActive: state.isDragActive
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

            case .dragEnded:
                state.isDragActive = false
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
                for id in state.shelves.ids {
                    state.shelves[id: id]?.isPresented = false
                    state.shelves[id: id]?.dockedEdge = nil
                }
                return .none
            }
        }
        .forEach(\.shelves, action: \.shelves) {
            ShelfFeature()
        }
    }
}

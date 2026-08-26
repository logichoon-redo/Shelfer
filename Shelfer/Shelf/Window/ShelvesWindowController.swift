//
//  ShelvesWindowController.swift
//  Shelfer
//

import ComposableArchitecture
import Foundation

/// Maintains one independent panel controller for every shelf in app state.
@MainActor
final class ShelvesWindowController {
    private let store: StoreOf<ShelvesFeature>
    private var controllers: [ShelfFeature.State.ID: ShelfWindowController] = [:]
    private var isObserving = true

    var managedShelfCount: Int {
        controllers.count
    }

    init(store: StoreOf<ShelvesFeature>) {
        self.store = store
        observe()
    }

    private func observe() {
        guard isObserving else { return }

        withObservationTracking {
            let shelfStores = Array(store.scope(\.shelves, action: \.shelves))
            sync(to: shelfStores)
        } onChange: {
            // Observation reports before the collection has applied its change.
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func sync(to shelfStores: [StoreOf<ShelfFeature>]) {
        let currentIDs = Set(shelfStores.map { $0.state.id })

        for id in controllers.keys.filter({ !currentIDs.contains($0) }) {
            controllers.removeValue(forKey: id)?.invalidate()
        }

        for shelfStore in shelfStores where controllers[shelfStore.state.id] == nil {
            controllers[shelfStore.state.id] = ShelfWindowController(store: shelfStore)
        }
    }

    func invalidate() {
        isObserving = false
        controllers.values.forEach { $0.invalidate() }
        controllers.removeAll()
    }
}

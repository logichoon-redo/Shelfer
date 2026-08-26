//
//  AppDelegate.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store(initialState: ShelvesFeature.State()) {
        ShelvesFeature()
    }

    private lazy var shelvesController = ShelvesWindowController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Instantiating the controller starts it observing the store.
        _ = shelvesController
        store.send(.task)

        // Debug affordance: fill a shelf without a real drag,
        // e.g. Shelfer_DEBUG_SEED="/path/a.png:/path/b.pdf"
        if let seed = ProcessInfo.processInfo.environment["Shelfer_DEBUG_SEED"] {
            let contents = seed.split(separator: ":").map {
                ShelfItem.Content.file(URL(fileURLWithPath: String($0)))
            }
            if let screen = NSScreen.main {
                store.send(.showRequested(CGPoint(x: screen.frame.midX - 380, y: screen.frame.midY)))
            }

            guard let shelfID = store.shelves.last?.id else { return }
            store.send(
                .shelves(.element(id: shelfID, action: .itemsDropped(contents)))
            )

            if ProcessInfo.processInfo.environment["Shelfer_DEBUG_EXPAND"] != nil {
                store.send(
                    .shelves(.element(id: shelfID, action: .expandButtonTapped))
                )
            }
        }
    }
}

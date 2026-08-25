//
//  AppDelegate.swift
//  C5
//

import AppKit
import ComposableArchitecture

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store(initialState: ShelfFeature.State()) {
        ShelfFeature()
    }

    private lazy var shelfController = ShelfWindowController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Instantiating the controller starts it observing the store.
        _ = shelfController
        store.send(.task)

        // Debug affordance: fill a shelf without a real drag,
        // e.g. C5_DEBUG_SEED="/path/a.png:/path/b.pdf"
        if let seed = ProcessInfo.processInfo.environment["C5_DEBUG_SEED"] {
            let contents = seed.split(separator: ":").map {
                ShelfItem.Content.file(URL(fileURLWithPath: String($0)))
            }
            if let screen = NSScreen.main {
                store.send(.shelfRequested(CGPoint(x: screen.frame.midX - 380, y: screen.frame.midY)))
            }
            store.send(.itemsDropped(contents))

            if ProcessInfo.processInfo.environment["C5_DEBUG_EXPAND"] != nil {
                store.send(.expandButtonTapped)
            }
        }
    }
}

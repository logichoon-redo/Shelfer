//
//  C5App.swift
//  C5
//

import AppKit
import ComposableArchitecture
import SwiftUI

@main
struct C5App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("C5", systemImage: "tray.and.arrow.down") {
            let store = appDelegate.store

            Button(store.isPresented ? "Hide Shelf" : "Show Shelf") {
                store.send(
                    store.isPresented ? .hideRequested : .shelfRequested(NSEvent.mouseLocation)
                )
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

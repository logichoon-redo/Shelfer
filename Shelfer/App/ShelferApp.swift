//
//  ShelferApp.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture
import SwiftUI

@main
struct ShelferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Shelfer", systemImage: "tray.and.arrow.down") {
            let store = appDelegate.store

            Button(store.isPresented ? "Hide Shelf" : "Show Shelf") {
                store.send(
                    store.isPresented ? .hideRequested : .showRequested(NSEvent.mouseLocation)
                )
            }

            Divider()

            Button("Getting Started…") {
                appDelegate.showFinderSyncOnboarding()
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

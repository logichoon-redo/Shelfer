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
        .commands {
            // MenuBarExtra does not install the standard Edit commands. Keep
            // native key equivalents in the application menu and forward them
            // through AppKit's responder chain to the focused shelf.
            CommandMenu("Edit") {
                Button("Undo") {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                }
                .keyboardShortcut("z")

                Divider()

                Button("Copy") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c")

                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v")
            }
        }
    }
}

//
//  AppDelegate.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let servicesPortName: NSServiceProviderName =
        "shelfer.com.Shelfer.Services"

    let store = Store(initialState: ShelvesFeature.State()) {
        ShelvesFeature()
    }

    private lazy var shelvesController = ShelvesWindowController(store: store)
    private lazy var finderFileAccessAuthorizer = FinderFileAccessAuthorizer()
    private lazy var finderSyncOnboardingController = FinderSyncOnboardingController()

    private func receiveExternalFiles(_ urls: [URL], at point: CGPoint = NSEvent.mouseLocation) {
        var seen: Set<URL> = []
        let contents = urls.compactMap { url -> ShelfItem.Content? in
            guard url.isFileURL else { return nil }
            let standardizedURL = url.standardizedFileURL
            guard seen.insert(standardizedURL).inserted else { return nil }
            return .file(standardizedURL)
        }
        guard !contents.isEmpty else { return }

        store.send(.externalItemsRequested(contents, point))
    }

    private func receiveExternalPaths(_ urls: [URL], at point: CGPoint = NSEvent.mouseLocation) {
        var seen: Set<String> = []
        let contents = urls.compactMap { url -> ShelfItem.Content? in
            guard url.isFileURL else { return nil }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return .path(path)
        }
        guard !contents.isEmpty else { return }

        store.send(.externalItemsRequested(contents, point))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Finder Sync cannot vend contextual-menu items for File Provider
        // locations such as an iCloud-managed Desktop. A system Service is the
        // supported fallback for those selections.
        NSApp.servicesProvider = self
        NSRegisterServicesProvider(self, Self.servicesPortName)
        NSUpdateDynamicServices()

        // Instantiating the controller starts it observing the store.
        _ = shelvesController
        store.send(.task)

        let environment = ProcessInfo.processInfo.environment
        if environment["Shelfer_DEBUG_SHOW_FINDER_ONBOARDING"] != nil {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.finderSyncOnboardingController.present()
            }
        } else if environment["Shelfer_DEBUG_SEED"] == nil {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.finderSyncOnboardingController.presentIfNeeded()
            }
        }

        // Debug affordance: fill a shelf without a real drag,
        // e.g. Shelfer_DEBUG_SEED="/path/a.png:/path/b.pdf"
        if let seed = ProcessInfo.processInfo.environment["Shelfer_DEBUG_SEED"] {
            let seedPathsOnly = ProcessInfo.processInfo.environment[
                "Shelfer_DEBUG_SEED_PATHS_ONLY"
            ] != nil
            let contents = seed.split(separator: ":").map { rawValue in
                let url = URL(fileURLWithPath: String(rawValue)).standardizedFileURL
                return seedPathsOnly
                    ? ShelfItem.Content.path(url.path)
                    : ShelfItem.Content.file(url)
            }

            if ProcessInfo.processInfo.environment["Shelfer_DEBUG_SHAKE_SHELF"] != nil,
               let screen = NSScreen.main {
                let point = CGPoint(x: screen.frame.midX - 380, y: screen.frame.midY)
                store.send(
                    .dragActivityChanged(
                        true,
                        prefersPathOnlyDrop: seedPathsOnly
                    )
                )
                store.send(
                    .shelfRequested(
                        point,
                        prefersPathOnlyDrop: seedPathsOnly
                    )
                )

                // Preserve the real ordering: the empty shelf gets a window
                // while the Finder drag is active, and its controls replace
                // that drop target only after the payload lands.
                if let shelfID = store.shelves.last?.id {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(150))
                        guard let self else { return }
                        self.store.send(
                            .shelves(
                                .element(
                                    id: shelfID,
                                    action: .itemsDropped(contents)
                                )
                            )
                        )
                        self.store.send(.dragEnded)
                    }
                }
                return
            }

            if ProcessInfo.processInfo.environment["Shelfer_DEBUG_DIRECT_NOTCH"] != nil,
               let target = ShelfNotchGeometry.targets().first {
                store.send(.notchItemsDropped(target, contents))

                if ProcessInfo.processInfo.environment["Shelfer_DEBUG_RESTORE_NOTCH"] != nil,
                   let shelfID = store.shelves.last?.id {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(
                            for: .seconds(ShelfNotchMetrics.retractionDuration + 0.2)
                        )
                        self?.store.send(
                            .shelves(
                                .element(
                                    id: shelfID,
                                    action: .notchUndockRequested
                                )
                            )
                        )
                    }
                }
                return
            }

            if let screen = NSScreen.main {
                store.send(.showRequested(CGPoint(x: screen.frame.midX - 380, y: screen.frame.midY)))
            }

            guard let shelfID = store.shelves.last?.id else { return }
            store.send(
                .shelves(.element(id: shelfID, action: .itemsDropped(contents)))
            )

            if ProcessInfo.processInfo.environment["Shelfer_DEBUG_NOTCH"] != nil,
               let target = ShelfNotchGeometry.targets().first {
                store.send(
                    .shelves(.element(id: shelfID, action: .notchDockRequested(target)))
                )
            }

            if ProcessInfo.processInfo.environment["Shelfer_DEBUG_EXPAND"] != nil {
                store.send(
                    .shelves(.element(id: shelfID, action: .expandButtonTapped))
                )
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        finderSyncOnboardingController.refreshIfPresented()
    }

    func showFinderSyncOnboarding() {
        finderSyncOnboardingController.present()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receiveExternalFiles(urls.filter(\.isFileURL))

        let handoffRequests = urls.compactMap {
            FinderHandoff.request(from: $0)
        }
        guard !handoffRequests.isEmpty else { return }

        let summonPoint = NSEvent.mouseLocation
        let pathContents = FinderHandoff.pathContents(
            from: handoffRequests
                .filter { $0.mode == .paths }
                .flatMap(\.items)
        )
        if !pathContents.isEmpty {
            store.send(.externalItemsRequested(pathContents, summonPoint))
        }

        let fileItems = handoffRequests
            .filter { $0.mode == .files }
            .flatMap(\.items)
        guard !fileItems.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let authorizedURLs = await finderFileAccessAuthorizer.authorizedURLs(
                for: fileItems
            )
            receiveExternalFiles(authorizedURLs, at: summonPoint)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSUnregisterServicesProvider(Self.servicesPortName)
    }

    @objc(addToShelfer:userData:error:)
    func addToShelferService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = serviceFileURLs(from: pasteboard), !urls.isEmpty else {
            error.pointee = "Shelfer couldn't read the selected Finder items."
            return
        }

        receiveExternalFiles(urls)
    }

    @objc(addPathsToShelfer:userData:error:)
    func addPathsToShelferService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = serviceFileURLs(from: pasteboard), !urls.isEmpty else {
            error.pointee = "Shelfer couldn't read the selected Finder item paths."
            return
        }

        receiveExternalPaths(urls)
    }

    private func serviceFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let urls = objects.compactMap { object -> URL? in
            guard let url = object as? NSURL else { return nil }
            return url as URL
        }
        if !urls.isEmpty {
            return urls
        }

        // Some Finder versions still provide the legacy filename list for a
        // Service request even when the service advertises modern file UTIs.
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        guard let paths = pasteboard.propertyList(forType: filenamesType) as? [String] else {
            return nil
        }
        return paths.map { URL(filePath: $0) }
    }
}

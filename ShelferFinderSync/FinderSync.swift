//
//  FinderSync.swift
//  ShelferFinderSync
//

import AppKit
import FinderSync

/// Adds Shelfer directly to Finder's item contextual menu.
final class FinderSync: FIFinderSync {
    private static let handoffScheme = "shelfer"
    private static let handoffHost = "finder-add"
    private static let pasteboardNamePrefix = "shelfer.com.Shelfer.finder."
    private static let pasteboardType = NSPasteboard.PasteboardType(
        "shelfer.com.Shelfer.finder-paths"
    )

    private struct HandoffItem: Codable {
        let path: String
        let isDirectory: Bool
    }

    private enum HandoffMode: String {
        case files
        case paths
    }

    private static var desktopDirectoryURLs: [URL] {
        let accountDesktopURL = NSHomeDirectoryForUser(NSUserName()).map {
            URL(filePath: $0, directoryHint: .isDirectory)
                .appending(path: "Desktop", directoryHint: .isDirectory)
        }
        let resolvedDesktopURLs = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        )

        return ([accountDesktopURL].compactMap { $0 } + resolvedDesktopURLs)
            .map(\.standardizedFileURL)
    }

    private let controller = FIFinderSyncController.default()

    override init() {
        super.init()

        // Finder Sync menus are available only inside monitored directories.
        // Do not also register Desktop here: an iCloud-managed Desktop is a
        // File Provider location that Finder Sync cannot monitor, and nesting
        // it under the root produces ambiguous ownership inside Finder.
        let rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        controller.directoryURLs = [rootURL.standardizedFileURL]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForItems:
            break

        case .contextualMenuForContainer:
            // Finder uses the container menu for a right-click on an empty
            // portion of the Desktop. Finder can report its target a moment
            // later, when the action runs, so never suppress the direct menu
            // merely because `targetedURL()` is temporarily nil here.
            break

        default:
            return nil
        }

        let menu = NSMenu()
        let fileItem = NSMenuItem(
            title: "Add to Shelfer",
            action: #selector(addSelectionToShelfer),
            keyEquivalent: ""
        )
        fileItem.target = self
        fileItem.image = NSImage(
            systemSymbolName: "tray.and.arrow.down",
            accessibilityDescription: "Add to Shelfer"
        )
        menu.addItem(fileItem)

        let pathItem = NSMenuItem(
            title: "Add Paths to Shelfer",
            action: #selector(addSelectionPathsToShelfer),
            keyEquivalent: ""
        )
        pathItem.target = self
        pathItem.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Add Paths to Shelfer"
        )
        menu.addItem(pathItem)
        return menu
    }

    @objc private func addSelectionToShelfer() {
        handoffSelection(mode: .files)
    }

    @objc private func addSelectionPathsToShelfer() {
        handoffSelection(mode: .paths)
    }

    private func handoffSelection(mode: HandoffMode) {
        let selectedURLs = controller.selectedItemURLs() ?? []
        let urls: [URL]
        if !selectedURLs.isEmpty {
            urls = selectedURLs
        } else if let targetedURL = controller.targetedURL() {
            // Container menus have no selected items. Hand off the current
            // directory, which is the Desktop when its background was clicked.
            urls = [targetedURL]
        } else if let desktopURL = Self.desktopDirectoryURLs.first {
            // The Desktop is a special Finder surface and occasionally exposes
            // neither API value to an extension action. Keep the direct menu
            // functional by falling back to its explicitly monitored URL.
            urls = [desktopURL]
        } else {
            return
        }

        let items = urls.map {
            HandoffItem(path: $0.path, isDirectory: $0.hasDirectoryPath)
        }
        guard let data = try? JSONEncoder().encode(items) else {
            scheduleHandoffFailure()
            return
        }

        let pasteboardName = NSPasteboard.Name(
            Self.pasteboardNamePrefix + UUID().uuidString
        )
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: Self.pasteboardType),
              let handoffURL = handoffURL(
                  for: pasteboardName,
                  mode: mode
              ) else {
            pasteboard.releaseGlobally()
            scheduleHandoffFailure()
            return
        }
        let pasteboardRawName = pasteboardName.rawValue

        let containingAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false

        NSWorkspace.shared.open(
            [handoffURL],
            withApplicationAt: containingAppURL,
            configuration: configuration
        ) { _, error in
            guard error != nil else { return }
            Task { @MainActor in
                NSPasteboard(name: NSPasteboard.Name(pasteboardRawName))
                    .releaseGlobally()
                Self.presentHandoffFailure()
            }
        }
    }

    private func handoffURL(
        for pasteboardName: NSPasteboard.Name,
        mode: HandoffMode
    ) -> URL? {
        var components = URLComponents()
        components.scheme = Self.handoffScheme
        components.host = Self.handoffHost
        components.queryItems = [
            URLQueryItem(name: "pasteboard", value: pasteboardName.rawValue),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        return components.url
    }

    private func scheduleHandoffFailure() {
        Task { @MainActor in Self.presentHandoffFailure() }
    }

    @MainActor
    private static func presentHandoffFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Add Files to Shelfer"
        alert.informativeText = "Open Shelfer, choose Finder Menu Settings…, and make sure Shelfer Finder Menu is enabled."
        alert.addButton(withTitle: "Open Finder Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }
}

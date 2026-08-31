//
//  FinderFileAccessAuthorizer.swift
//  Shelfer
//

import AppKit

/// Owns persistent, read-only access to folders explicitly chosen by the user.
@MainActor
final class FinderFileAccessAuthorizer {
    private static let bookmarksKey = "FinderAuthorizedFolderBookmarks"

    private let defaults: UserDefaults
    private var activeRoots: [URL] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreBookmarks()
    }

    func authorizedURLs(for items: [FinderHandoff.Item]) async -> [URL] {
        var seen: Set<URL> = []
        let requests = items.compactMap { item -> (url: URL, directory: URL)? in
            let url = item.url.standardizedFileURL
            guard seen.insert(url).inserted else { return nil }
            let directory = item.isDirectory ? url : url.deletingLastPathComponent()
            return (url, directory)
        }

        var requestedDirectories: [URL] = []
        for request in requests where !hasAccess(to: request.url) {
            guard !requestedDirectories.contains(where: {
                Self.directory($0, contains: request.directory)
            }) else {
                continue
            }
            requestedDirectories.removeAll(where: {
                Self.directory(request.directory, contains: $0)
            })
            requestedDirectories.append(request.directory)
        }

        for directory in requestedDirectories where !hasAccess(to: directory) {
            guard let selectedDirectory = await requestAccess(to: directory) else {
                continue
            }
            register(selectedDirectory)
        }

        return requests.compactMap { hasAccess(to: $0.url) ? $0.url : nil }
    }

    static func directory(_ directory: URL, contains candidate: URL) -> Bool {
        let directoryPath = canonicalPath(for: directory)
        let candidatePath = canonicalPath(for: candidate)
        guard candidatePath != directoryPath else { return true }

        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private func hasAccess(to url: URL) -> Bool {
        activeRoots.contains(where: { Self.directory($0, contains: url) })
    }

    private func requestAccess(to directory: URL) async -> URL? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Allow Finder Access"
        panel.message = "Select the “\(directory.lastPathComponent)” folder, then click Allow Access. Shelfer will remember this one-time permission for future Finder actions."
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.directoryURL = directory.deletingLastPathComponent()

        let response = await panel.begin()
        guard response == .OK, let selectedDirectory = panel.url else {
            return nil
        }

        guard Self.directory(selectedDirectory, contains: directory) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That folder doesn’t contain the selected item"
            alert.informativeText = "Choose “\(directory.lastPathComponent)” or one of its parent folders, then try Add to Shelfer again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }

        return selectedDirectory.standardizedFileURL
    }

    private func register(_ directory: URL) {
        guard !hasAccess(to: directory) else { return }

        do {
            let data = try directory.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            guard directory.startAccessingSecurityScopedResource() else { return }

            activeRoots.append(directory)
            var bookmarks = defaults.array(forKey: Self.bookmarksKey) as? [Data] ?? []
            bookmarks.append(data)
            defaults.set(bookmarks, forKey: Self.bookmarksKey)
        } catch {
            showBookmarkError()
        }
    }

    private func restoreBookmarks() {
        let bookmarks = defaults.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        var validBookmarks: [Data] = []

        for data in bookmarks {
            var isStale = false
            guard let directory = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), directory.startAccessingSecurityScopedResource() else {
                continue
            }

            activeRoots.append(directory.standardizedFileURL)
            if isStale,
               let refreshedData = try? directory.bookmarkData(
                   options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                validBookmarks.append(refreshedData)
            } else {
                validBookmarks.append(data)
            }
        }

        if validBookmarks.count != bookmarks.count || validBookmarks != bookmarks {
            defaults.set(validBookmarks, forKey: Self.bookmarksKey)
        }
    }

    private func showBookmarkError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shelfer couldn’t save folder access"
        alert.informativeText = "Try Add to Shelfer again and choose the containing folder when prompted."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

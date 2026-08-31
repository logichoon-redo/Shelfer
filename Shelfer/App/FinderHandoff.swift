//
//  FinderHandoff.swift
//  Shelfer
//

import AppKit

/// Decodes requests from the sandboxed Finder Sync extension.
///
/// The extension cannot hand arbitrary file URLs to LaunchServices because it
/// does not own their sandbox grants. A private named pasteboard carries only
/// path metadata. The containing app either stores that metadata as inert path
/// text or obtains access with an NSOpenPanel when the actual files are needed.
enum FinderHandoff {
    static let scheme = "shelfer"
    static let host = "finder-add"
    static let pasteboardNamePrefix = "shelfer.com.Shelfer.finder."
    static let pasteboardType = NSPasteboard.PasteboardType(
        "shelfer.com.Shelfer.finder-paths"
    )

    enum Mode: String, Equatable, Sendable {
        case files
        case paths
    }

    struct Item: Codable, Equatable, Sendable {
        let path: String
        let isDirectory: Bool

        var url: URL {
            URL(
                filePath: path,
                directoryHint: isDirectory ? .isDirectory : .notDirectory
            )
        }
    }

    struct Request: Equatable, Sendable {
        let items: [Item]
        let mode: Mode
    }

    static func request(from handoffURL: URL) -> Request? {
        guard handoffURL.scheme == scheme,
              handoffURL.host == host,
              let components = URLComponents(url: handoffURL, resolvingAgainstBaseURL: false),
              let pasteboardName = components.queryItems?.first(where: {
                  $0.name == "pasteboard"
              })?.value,
              pasteboardName.hasPrefix(pasteboardNamePrefix) else {
            return nil
        }

        let modeValue = components.queryItems?.first(where: {
            $0.name == "mode"
        })?.value
        let mode: Mode
        if let modeValue {
            guard let requestedMode = Mode(rawValue: modeValue) else {
                return nil
            }
            mode = requestedMode
        } else {
            // Older Finder extensions did not include a mode and always sent
            // actual-file requests. Preserve that behavior during upgrades.
            mode = .files
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        defer { pasteboard.releaseGlobally() }

        guard let data = pasteboard.data(forType: pasteboardType) else {
            return nil
        }
        guard let items = try? JSONDecoder().decode([Item].self, from: data),
              !items.isEmpty else {
            return nil
        }
        return Request(items: items, mode: mode)
    }

    static func items(from handoffURL: URL) -> [Item]? {
        request(from: handoffURL)?.items
    }

    static func pathContents(from items: [Item]) -> [ShelfItem.Content] {
        var seen: Set<String> = []
        return items.compactMap { item in
            let path = item.url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return .path(path)
        }
    }
}

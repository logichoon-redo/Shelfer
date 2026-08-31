//
//  ShelfItem.swift
//  Shelfer
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    /// Text is kept in memory rather than written out as an .rtf file, so it can
    /// be handed straight back to a text field on the way out.
    nonisolated enum Content: Hashable, Sendable {
        case file(URL)
        /// An absolute filesystem path kept as inert text. Unlike `.file`, this
        /// never grants access to, previews, or exports the file it points at.
        case path(String)
        case text(String)
    }

    /// The content itself identifies the item: the same file or the same snippet
    /// can only sit on the shelf once, so collections keyed by `id` dedupe for free.
    var id: Content { content }

    let content: Content

    init(_ content: Content) {
        switch content {
        case let .file(url):
            self.content = .file(url.standardizedFileURL)
        case let .path(path):
            self.content = .path(
                URL(fileURLWithPath: path).standardizedFileURL.path
            )
        case let .text(text):
            self.content = .text(text)
        }
    }

    var url: URL? {
        guard case let .file(url) = content else { return nil }
        return url
    }

    var path: String? {
        guard case let .path(path) = content else { return nil }
        return path
    }

    var displayName: String {
        switch content {
        case let .file(url):
            url.lastPathComponent
        case let .path(path):
            path
        case let .text(text):
            text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        }
    }

    var icon: NSImage {
        switch content {
        case let .file(url):
            NSWorkspace.shared.icon(forFile: url.path)
        case .path:
            NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "File path"
            ) ?? NSWorkspace.shared.icon(for: .plainText)
        case .text:
            NSWorkspace.shared.icon(for: .plainText)
        }
    }

    var isImage: Bool {
        guard let url else { return false }

        // This property is evaluated from SwiftUI title rendering and reducer
        // actions, both on the main actor. Reading URL resource values here
        // causes one blocking filesystem lookup per item on every render. The
        // extension identifies the common image formats without touching disk;
        // detailed dimensions are loaded asynchronously by FileInfoClient.
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

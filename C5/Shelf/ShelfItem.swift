//
//  ShelfItem.swift
//  C5
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    /// Text is kept in memory rather than written out as an .rtf file, so it can
    /// be handed straight back to a text field on the way out.
    enum Content: Hashable {
        case file(URL)
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
        case let .text(text):
            self.content = .text(text)
        }
    }

    var url: URL? {
        guard case let .file(url) = content else { return nil }
        return url
    }

    var displayName: String {
        switch content {
        case let .file(url):
            url.lastPathComponent
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
        case .text:
            NSWorkspace.shared.icon(for: .plainText)
        }
    }

    var isImage: Bool {
        guard let url else { return false }

        if let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
           contentType.conforms(to: .image) {
            return true
        }

        // The extension fallback also keeps classification useful while a file
        // is temporarily unavailable (for example, on an unmounted volume).
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

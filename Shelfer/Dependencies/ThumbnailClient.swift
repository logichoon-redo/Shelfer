//
//  ThumbnailClient.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture
import QuickLookThumbnailing

/// Generates Quick Look thumbnails, caching results so re-rendering the shelf
/// doesn't ask for the same file again.
struct ThumbnailClient {
    var thumbnail: @Sendable (_ url: URL, _ size: CGFloat) async -> NSImage?
}

extension ThumbnailClient: DependencyKey {
    static let liveValue: ThumbnailClient = {
        let cache = Cache()
        return ThumbnailClient(
            thumbnail: { url, size in
                await cache.thumbnail(for: url, size: size)
            }
        )
    }()

    /// Renders nothing, so tests and previews fall back to the file-type icon.
    static let testValue = ThumbnailClient(thumbnail: { _, _ in nil })
}

extension DependencyValues {
    var thumbnails: ThumbnailClient {
        get { self[ThumbnailClient.self] }
        set { self[ThumbnailClient.self] = newValue }
    }
}

private actor Cache {
    private var images: [URL: NSImage] = [:]

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        if let cached = images[url] { return cached }

        let image = await Self.generate(for: url, size: size)
        if let image { images[url] = image }
        return image
    }

    private static func generate(for url: URL, size: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: 2,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }
}

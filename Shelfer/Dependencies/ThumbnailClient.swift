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
    private struct Key: Hashable {
        let url: URL
        let pointSize: Int

        var cacheKey: NSString {
            "\(url.absoluteString)|\(pointSize)" as NSString
        }
    }

    private static let maximumConcurrentRequests = 4

    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()
    private var inFlight: [Key: Task<NSImage?, Never>] = [:]
    private var activeRequestCount = 0
    private var permitWaiters: [CheckedContinuation<Void, Never>] = []

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = Key(url: url.standardizedFileURL, pointSize: Int(size.rounded(.up)))
        if let cached = images.object(forKey: key.cacheKey) { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task { [self] in
            await generateWithPermit(for: key.url, size: size)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            // A Quick Look request is generated at high scale. This estimate
            // is intentionally conservative so scrolling through thousands of
            // files cannot grow thumbnail memory without a bound.
            let estimatedCost = max(1, key.pointSize * key.pointSize * 16)
            images.setObject(image, forKey: key.cacheKey, cost: estimatedCost)
        }
        return image
    }

    private func generateWithPermit(for url: URL, size: CGFloat) async -> NSImage? {
        await acquirePermit()
        defer { releasePermit() }
        return await Self.generate(for: url, size: size)
    }

    private func acquirePermit() async {
        if activeRequestCount < Self.maximumConcurrentRequests {
            activeRequestCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            permitWaiters.append(continuation)
        }
    }

    private func releasePermit() {
        if permitWaiters.isEmpty {
            activeRequestCount -= 1
        } else {
            permitWaiters.removeFirst().resume()
        }
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

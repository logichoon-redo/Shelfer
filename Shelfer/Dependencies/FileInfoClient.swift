//
//  FileInfoClient.swift
//  Shelfer
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FileInfo: Equatable, Sendable {
    var byteCount: Int64
    /// Only images report one.
    var pixelSize: CGSize?
}

/// Reads the size and, for images, the dimensions shown in the detail view.
struct FileInfoClient: Sendable {
    var info: @Sendable (URL) async -> FileInfo?
}

extension FileInfoClient: DependencyKey {
    static let liveValue: FileInfoClient = {
        let cache = FileInfoCache()
        return FileInfoClient(
            info: { url in
                await cache.info(for: url)
            }
        )
    }()

    static let testValue = FileInfoClient(info: { _ in nil })
}

extension DependencyValues {
    var fileInfo: FileInfoClient {
        get { self[FileInfoClient.self] }
        set { self[FileInfoClient.self] = newValue }
    }
}

/// File coordination and ImageIO header inspection are blocking operations.
/// Keeping them behind an actor deduplicates repeated SwiftUI tasks, while the
/// detached utility task ensures a large Finder selection never stalls AppKit's
/// main event loop.
private actor FileInfoCache {
    private var values: [URL: FileInfo] = [:]
    private var missing: Set<URL> = []
    private var inFlight: [URL: Task<FileInfo?, Never>] = [:]

    func info(for url: URL) async -> FileInfo? {
        if let value = values[url] { return value }
        if missing.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }

        let task = Task.detached(priority: .utility) {
            Self.readInfo(for: url)
        }
        inFlight[url] = task
        let value = await task.value
        inFlight[url] = nil

        if let value {
            values[url] = value
        } else {
            missing.insert(url)
        }
        return value
    }

    private nonisolated static func readInfo(for url: URL) -> FileInfo? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = values?.fileSize else { return nil }

        // Avoid asking ImageIO to inspect every arbitrary document. The file
        // extension is enough to decide whether pixel dimensions are useful.
        let isImage = UTType(filenameExtension: url.pathExtension)?
            .conforms(to: .image) == true
        return FileInfo(
            byteCount: Int64(bytes),
            pixelSize: isImage ? pixelSize(of: url) : nil
        )
    }

    /// Read from the image header rather than by decoding the whole file.
    private nonisolated static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }

        return CGSize(width: width, height: height)
    }
}

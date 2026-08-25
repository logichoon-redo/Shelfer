//
//  FileInfoClient.swift
//  C5
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import ImageIO

struct FileInfo: Equatable, Sendable {
    var byteCount: Int64
    /// Only images report one.
    var pixelSize: CGSize?
}

/// Reads the size and, for images, the dimensions shown in the detail view.
struct FileInfoClient {
    var info: @Sendable (URL) async -> FileInfo?
}

extension FileInfoClient: DependencyKey {
    static let liveValue = FileInfoClient(
        info: { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            guard let bytes = values?.fileSize else { return nil }
            return FileInfo(byteCount: Int64(bytes), pixelSize: pixelSize(of: url))
        }
    )

    static let testValue = FileInfoClient(info: { _ in nil })

    /// Read from the image header rather than by decoding the whole file.
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }

        return CGSize(width: width, height: height)
    }
}

extension DependencyValues {
    var fileInfo: FileInfoClient {
        get { self[FileInfoClient.self] }
        set { self[FileInfoClient.self] = newValue }
    }
}

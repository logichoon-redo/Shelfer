//
//  ReleaseReadinessTests.swift
//  ShelferTests
//

import AppKit
import Foundation
import Testing
@testable import Shelfer

@MainActor
struct ReleaseReadinessTests {
    @Test func textPromiseOffersTextHTMLAndAFileFallback() throws {
        let provider = TextFilePromise(text: "<script>&\nsecond line")
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        let types = provider.writableTypes(for: pasteboard)
        #expect(types.starts(with: [.string, .html]))
        #expect(
            provider.pasteboardPropertyList(forType: .string) as? String
                == "<script>&\nsecond line"
        )
        #expect(
            provider.pasteboardPropertyList(forType: .html) as? String
                == "<span>&lt;script&gt;&amp;<br>second line</span>"
        )
        #expect(
            provider.filePromiseProvider(provider, fileNameForType: "public.plain-text")
                == "script &.txt"
        )
    }

    @Test func textPromiseCreatesSafeBoundedFileNames() {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let name = TextFilePromise.fileName(
            for: "  A/very:long\\unsafe?title%that*keeps|going\"past<forty>characters  \nbody"
        )

        #expect(name.count <= 40)
        #expect(name.rangeOfCharacter(from: forbidden) == nil)
        #expect(TextFilePromise.fileName(for: " \n\t ") == "Text")
    }

    @Test func textPromiseWritesTheExactUTF8Payload() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Snippet.txt")
        let text = "한글과 emoji 📎\nsecond line"
        let provider = TextFilePromise(text: text)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            provider.filePromiseProvider(
                provider,
                writePromiseTo: destination
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        #expect(try String(contentsOf: destination, encoding: .utf8) == text)
    }

    @Test func fileInfoReadsRegularFileSizeWithoutImageDimensions() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.txt")
        let data = Data("release readiness".utf8)
        try data.write(to: file)

        let info = await FileInfoClient.liveValue.info(file)

        #expect(info?.byteCount == Int64(data.count))
        #expect(info?.pixelSize == nil)
    }

    @Test func fileInfoReadsImageDimensionsFromTheHeader() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("dimensions.png")
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 13,
                pixelsHigh: 7,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: file)

        let info = await FileInfoClient.liveValue.info(file)

        #expect(info?.byteCount == Int64(data.count))
        #expect(info?.pixelSize == CGSize(width: 13, height: 7))
    }

    @Test func itemTypeDetectionDoesNotNeedTheFileToExist() {
        #expect(ShelfItem(.file(URL(fileURLWithPath: "/tmp/photo.HEIC"))).isImage)
        #expect(!ShelfItem(.file(URL(fileURLWithPath: "/tmp/archive.zip"))).isImage)
        #expect(!ShelfItem(.path("/tmp/photo.png")).isImage)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShelferReleaseReadinessTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

//
//  PasteboardClient.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture

struct PasteboardClient {
    var copyText: @Sendable (String) async -> Void
    var copyImage: @Sendable (URL) async -> Bool
    var copyContents: @Sendable ([ShelfItem.Content]) async -> Bool
    var readContents: @Sendable () async -> [ShelfItem.Content]

    init(
        copyText: @escaping @Sendable (String) async -> Void,
        copyImage: @escaping @Sendable (URL) async -> Bool,
        copyContents: @escaping @Sendable ([ShelfItem.Content]) async -> Bool,
        readContents: @escaping @Sendable () async -> [ShelfItem.Content] = { [] }
    ) {
        self.copyText = copyText
        self.copyImage = copyImage
        self.copyContents = copyContents
        self.readContents = readContents
    }
}

extension PasteboardClient: DependencyKey {
    static let liveValue = PasteboardClient(
        copyText: { text in
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        },
        copyImage: { url in
            await MainActor.run {
                PasteboardClient.writeImage(at: url, to: .general)
            }
        },
        copyContents: { contents in
            await MainActor.run {
                PasteboardClient.writeContents(contents, to: .general)
            }
        },
        readContents: {
            await MainActor.run {
                ShelfSurface.SurfaceView.contents(from: .general)
            }
        }
    )

    static let testValue = PasteboardClient(
        copyText: { _ in },
        copyImage: { _ in false },
        copyContents: { _ in false },
        readContents: { [] }
    )
}

extension PasteboardClient {
    @MainActor
    static func writeContents(
        _ contents: [ShelfItem.Content],
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard !contents.isEmpty else { return false }

        let writers: [NSPasteboardWriting] = contents.map { content in
            switch content {
            case let .file(url): url as NSURL
            case let .path(path): path as NSString
            case let .text(text): text as NSString
            }
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects(writers)
    }

    @MainActor
    static func writeImage(at url: URL, to pasteboard: NSPasteboard) -> Bool {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = NSImage(contentsOf: url),
              let tiffData = image.tiffRepresentation
        else { return false }

        // Write eager bitmap data instead of a lazily loaded NSImage. The
        // latter can lose access to a sandboxed dropped file by the time another
        // app asks the pasteboard for its representation.
        let item = NSPasteboardItem()
        item.setData(tiffData, forType: .tiff)

        if let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            item.setData(pngData, forType: .png)
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

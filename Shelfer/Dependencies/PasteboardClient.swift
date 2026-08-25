//
//  PasteboardClient.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture

struct PasteboardClient {
    var copyText: @Sendable (String) async -> Void
    var copyImage: @Sendable (URL) async -> Bool
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
        }
    )

    static let testValue = PasteboardClient(
        copyText: { _ in },
        copyImage: { _ in false }
    )
}

extension PasteboardClient {
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

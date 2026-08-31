//
//  TextFilePromise.swift
//  Shelfer
//

import AppKit
import UniformTypeIdentifiers

/// Offers a shelf snippet as a `.txt` file *if the destination asks for one*.
///
/// Apps differ in what they accept from a drag: an editor takes text, while a
/// rich-text composer (Slack, Zoom) ignores text and only handles files. Pairing
/// this promise with the plain-text flavours lets each destination pick what it
/// can use. The file is written only when claimed, so the shelf still holds
/// nothing but a string.
final class TextFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let text: String

    init(text: String) {
        self.text = text
        super.init()
        fileType = UTType.plainText.identifier
        delegate = self
    }

    // MARK: - Also carry the text itself

    /// Text flavours are listed first so an editor that can insert a string keeps
    /// doing so; the file promise is what apps that ignore text fall back to.
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.string, .html] + super.writableTypes(for: pasteboard)
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        switch type {
        case .string, .html: []
        default: super.writingOptions(forType: type, pasteboard: pasteboard)
        }
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .string: text
        case .html: Self.html(from: text)
        default: super.pasteboardPropertyList(forType: type)
        }
    }

    private static func html(from text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<span>\(escaped)</span>"
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        "\(Self.fileName(for: text)).txt"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    /// Names the file after its opening words, so a shelf full of snippets doesn't
    /// land as "Untitled 1, 2, 3…".
    nonisolated static func fileName(for text: String) -> String {
        let firstLine = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""

        let cleaned = firstLine
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        let trimmed = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Text" : trimmed
    }
}

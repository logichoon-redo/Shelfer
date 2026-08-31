//
//  SharingClient.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture

enum ShelfShareMethod: String, CaseIterable, Equatable, Hashable, Sendable {
    case airDrop
    case email
    case kakaoTalk

    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .email: "Mail"
        case .kakaoTalk: "KakaoTalk"
        }
    }

    var systemImageName: String {
        switch self {
        case .airDrop: "antenna.radiowaves.left.and.right"
        case .email: "envelope"
        case .kakaoTalk: "message.fill"
        }
    }
}

struct SharingClient: Sendable {
    var share: @Sendable (_ method: ShelfShareMethod, _ contents: [ShelfItem.Content]) async -> Void
}

extension SharingClient: DependencyKey {
    static let liveValue = SharingClient { method, contents in
        switch method {
        case .airDrop:
            do {
                let preparedItems = try await Task.detached(priority: .userInitiated) {
                    try AirDropItemPreparer.prepare(contents)
                }.value
                await MainActor.run {
                    SharingClient.performAirDrop(with: preparedItems)
                }
            } catch {
                await MainActor.run {
                    NSLog("[Shelfer] Unable to prepare AirDrop text: %@", error.localizedDescription)
                    NSSound.beep()
                }
            }

        case .email, .kakaoTalk:
            await MainActor.run {
                SharingClient.perform(method, contents: contents)
            }
        }
    }

    static let testValue = SharingClient(share: { _, _ in })
}

extension DependencyValues {
    var sharing: SharingClient {
        get { self[SharingClient.self] }
        set { self[SharingClient.self] = newValue }
    }
}

struct AirDropPreparedItems: Sendable {
    let urls: [URL]
    let temporaryDirectory: URL?

    nonisolated func cleanup() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

enum AirDropItemPreparer {
    nonisolated static func prepare(
        _ contents: [ShelfItem.Content],
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> AirDropPreparedItems {
        guard contents.contains(where: \.isText) else {
            return AirDropPreparedItems(
                urls: contents.compactMap(\.fileURL),
                temporaryDirectory: nil
            )
        }

        let fileManager = FileManager.default
        let directory = temporaryRoot.appendingPathComponent(
            "Shelfer-AirDrop-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            var urls: [URL] = []
            var usedFileNames: Set<String> = []

            for content in contents {
                switch content {
                case let .file(url):
                    urls.append(url)

                case let .path(path):
                    let baseName = "File Paths"
                    let fileName = uniqueFileName(
                        baseName: baseName,
                        usedFileNames: &usedFileNames
                    )
                    let fileURL = directory.appendingPathComponent(fileName)
                    try path.write(to: fileURL, atomically: true, encoding: .utf8)
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: fileURL.path
                    )
                    urls.append(fileURL)

                case let .text(text):
                    let baseName = TextFilePromise.fileName(for: text)
                    let fileName = uniqueFileName(
                        baseName: baseName,
                        usedFileNames: &usedFileNames
                    )
                    let fileURL = directory.appendingPathComponent(fileName)
                    try text.write(to: fileURL, atomically: true, encoding: .utf8)
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: fileURL.path
                    )
                    urls.append(fileURL)
                }
            }

            return AirDropPreparedItems(
                urls: urls,
                temporaryDirectory: directory
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private nonisolated static func uniqueFileName(
        baseName: String,
        usedFileNames: inout Set<String>
    ) -> String {
        var suffix = 1
        var candidate = "\(baseName).txt"

        while usedFileNames.contains(candidate) {
            suffix += 1
            candidate = "\(baseName) \(suffix).txt"
        }
        usedFileNames.insert(candidate)
        return candidate
    }
}

private extension SharingClient {
    @MainActor
    static func performAirDrop(with preparedItems: AirDropPreparedItems) {
        let items = preparedItems.urls.map { $0 as NSURL }
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: items) else {
            preparedItems.cleanup()
            NSSound.beep()
            return
        }

        AirDropSharingSession.start(
            service: service,
            items: items,
            preparedItems: preparedItems
        )
    }

    @MainActor
    static func perform(_ method: ShelfShareMethod, contents: [ShelfItem.Content]) {
        guard !contents.isEmpty else { return }

        switch method {
        case .airDrop:
            assertionFailure("AirDrop must use its prepared-file sharing path")
            return
        case .email:
            let items = contents.map(shareItem)
            guard let service = NSSharingService(named: .composeEmail),
                  service.canPerform(withItems: items) else {
                NSSound.beep()
                return
            }

            NSApp.activate()
            service.perform(withItems: items)
        case .kakaoTalk:
            // AppKit deprecated enumerating installed share services in macOS 13.
            // A standard picker would add another service-selection step to
            // this explicit KakaoTalk action, so use the reliable clipboard
            // handoff and launch KakaoTalk directly instead.
            openKakaoTalkWithClipboard(contents)
        }
    }

    static func shareItem(_ content: ShelfItem.Content) -> Any {
        switch content {
        case let .file(url): url as NSURL
        case let .path(path): path as NSString
        case let .text(text): text as NSString
        }
    }

    @MainActor
    static func openKakaoTalkWithClipboard(_ contents: [ShelfItem.Content]) {
        let writers: [NSPasteboardWriting] = contents.map { content in
            switch content {
            case let .file(url): url as NSURL
            case let .path(path): path as NSString
            case let .text(text): text as NSString
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)

        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.kakao.KakaoTalkMac"
        ) else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.open(appURL)
    }
}

@MainActor
private final class AirDropSharingSession: NSObject, NSSharingServiceDelegate {
    private static var activeSessions: [UUID: AirDropSharingSession] = [:]

    private let id = UUID()
    private let service: NSSharingService
    private let items: [Any]
    private let preparedItems: AirDropPreparedItems

    private init(
        service: NSSharingService,
        items: [Any],
        preparedItems: AirDropPreparedItems
    ) {
        self.service = service
        self.items = items
        self.preparedItems = preparedItems
    }

    static func start(
        service: NSSharingService,
        items: [Any],
        preparedItems: AirDropPreparedItems
    ) {
        let session = AirDropSharingSession(
            service: service,
            items: items,
            preparedItems: preparedItems
        )
        activeSessions[session.id] = session
        session.start()
    }

    private func start() {
        service.delegate = self
        NSApp.activate()
        service.perform(withItems: items)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish()
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        NSLog("[Shelfer] AirDrop failed: %@", error.localizedDescription)
        finish()
    }

    private func finish() {
        preparedItems.cleanup()
        Self.activeSessions[id] = nil
    }
}

private extension ShelfItem.Content {
    nonisolated var isText: Bool {
        switch self {
        case .path, .text: true
        case .file: false
        }
    }

    nonisolated var fileURL: URL? {
        guard case let .file(url) = self else { return nil }
        return url
    }
}

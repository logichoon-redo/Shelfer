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
}

struct SharingClient {
    var share: @Sendable (_ method: ShelfShareMethod, _ contents: [ShelfItem.Content]) async -> Void
}

extension SharingClient: DependencyKey {
    static let liveValue = SharingClient { method, contents in
        await MainActor.run {
            SharingClient.perform(method, contents: contents)
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

private extension SharingClient {
    @MainActor
    static func perform(_ method: ShelfShareMethod, contents: [ShelfItem.Content]) {
        guard !contents.isEmpty else { return }

        let items = contents.map(shareItem)
        let service: NSSharingService?

        switch method {
        case .airDrop:
            service = NSSharingService(named: .sendViaAirDrop)
        case .email:
            service = NSSharingService(named: .composeEmail)
        case .kakaoTalk:
            service = kakaoTalkService(for: items)
        }

        guard let service, service.canPerform(withItems: items) else {
            if method == .kakaoTalk {
                openKakaoTalkWithClipboardFallback(contents)
            } else {
                NSSound.beep()
            }
            return
        }

        NSApp.activate()
        service.perform(withItems: items)
    }

    static func shareItem(_ content: ShelfItem.Content) -> Any {
        switch content {
        case let .file(url): url as NSURL
        case let .text(text): text as NSString
        }
    }

    @MainActor
    static func kakaoTalkService(for items: [Any]) -> NSSharingService? {
        // macOS has no public Kakao SDK for direct file sharing. KakaoTalk's Mac
        // app installs a system Share extension, which AppKit exposes here.
        NSSharingService.sharingServices(forItems: items).first { service in
            let name = "\(service.title) \(service.menuItemTitle)"
            return name.localizedCaseInsensitiveContains("kakao")
                || name.localizedCaseInsensitiveContains("카카오")
                || name.localizedCaseInsensitiveContains("mactalk")
        }
    }

    @MainActor
    static func openKakaoTalkWithClipboardFallback(_ contents: [ShelfItem.Content]) {
        let writers: [NSPasteboardWriting] = contents.map { content in
            switch content {
            case let .file(url): url as NSURL
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

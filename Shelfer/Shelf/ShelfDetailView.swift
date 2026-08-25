//
//  ShelfDetailView.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

/// The expanded shelf: what's on it, in detail, with the actions that apply.
struct ShelfDetailView: View {
    let store: StoreOf<ShelfFeature>

    @Dependency(\.fileInfo) private var fileInfo
    @State private var infos: [ShelfItem.ID: FileInfo] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, ShelfDetailMetrics.inset)
                .padding(.top, ShelfDetailMetrics.inset)

            content
                .padding(.horizontal, ShelfDetailMetrics.inset)
                .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .task(id: store.items) {
            await loadInfos()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            circleButton(systemImage: "chevron.left", label: "Back to shelf") {
                store.send(.backButtonTapped)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text(totalSize)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                circleButton(
                    systemImage: "square.grid.2x2.fill",
                    label: "Grid view",
                    isSelected: store.layout == .grid
                ) {
                    store.send(.layoutChanged(.grid))
                }
                circleButton(
                    systemImage: "list.bullet",
                    label: "List view",
                    isSelected: store.layout == .list
                ) {
                    store.send(.layoutChanged(.list))
                }
            }
        }
        // The controls remain above this view and keep their normal button
        // behaviour. Only the otherwise empty parts of the header reach the
        // drag target and move the panel.
        .background {
            WindowDragTarget()
        }
    }

    private func circleButton(
        systemImage: String,
        label: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    width: ShelfDetailMetrics.buttonDiameter,
                    height: ShelfDetailMetrics.buttonDiameter
                )
                .background(Circle().fill(.white.opacity(isSelected ? 0.28 : 0.14)))
        }
        .buttonStyle(.plain)
        .shelfHoverHighlight()
        .focusEffectDisabled()
        .accessibilityLabel(label)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.layout {
        case .grid: gridContent
        case .list: listContent
        }
    }

    private var gridContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 22) {
                ForEach(store.items) { item in
                    gridTile(for: item)
                }
                revealTile
            }
            // A short row still fills the visible content width, making the
            // empty part beside its tiles useful as a panel drag handle.
            .frame(minWidth: ShelfDetailMetrics.contentWidth, alignment: .leading)
            .background {
                WindowDragTarget()
            }
        }
    }

    private func gridTile(for item: ShelfItem) -> some View {
        VStack(spacing: 8) {
            ShelfItemIcon(item: item, size: ShelfDetailMetrics.thumbnailSize)

            VStack(spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(for: item))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(width: ShelfDetailMetrics.tileWidth)
        }
        .overlay {
            itemDragSource(for: item)
        }
    }

    private var listContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(store.items) { item in
                    HStack(spacing: 10) {
                        ShelfItemIcon(item: item, size: 28)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(subtitle(for: item))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        itemDragSource(for: item)
                    }
                }

                revealRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                WindowDragTarget()
            }
        }
    }

    /// Items own their pixels: dragging one exports that item's payload, while
    /// a native double-click copies it. The row background behind these sources
    /// is reserved for moving the shelf window.
    private func itemDragSource(for item: ShelfItem) -> some View {
        ShelfDragSource(
            contents: [item.content],
            onCompleted: { store.send(.itemsDraggedOut($0)) },
            onDragActiveChange: { store.send(.shelfDragActivityChanged($0)) },
            onDoubleClick: { store.send(.itemDoubleClicked(item.id)) }
        )
    }

    private var revealTile: some View {
        Button {
            store.send(.revealInFinderTapped)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(
                        width: ShelfDetailMetrics.thumbnailSize,
                        height: ShelfDetailMetrics.thumbnailSize
                    )
                    .background(Circle().fill(.white.opacity(0.14)))

                Text("Reveal in Finder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: ShelfDetailMetrics.tileWidth)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(hasFiles ? 1 : 0.35)
        .disabled(!hasFiles)
    }

    private var revealRow: some View {
        Button {
            store.send(.revealInFinderTapped)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.14)))

                Text("Reveal in Finder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(hasFiles ? 1 : 0.35)
        .disabled(!hasFiles)
    }

    // MARK: - Derived text

    private var hasFiles: Bool {
        store.items.contains { $0.url != nil }
    }

    /// "1 Image", "3 Files", "2 Items" — matching what's actually on the shelf.
    private var title: String {
        let items = store.items
        let count = items.count
        guard count > 0 else { return "Empty" }

        let noun: String
        if items.allSatisfy(\.isImage) {
            noun = count == 1 ? "Image" : "Images"
        } else if items.allSatisfy({ $0.url != nil }) {
            noun = count == 1 ? "File" : "Files"
        } else if items.allSatisfy({ $0.url == nil }) {
            noun = count == 1 ? "Snippet" : "Snippets"
        } else {
            noun = count == 1 ? "Item" : "Items"
        }

        return "\(count) \(noun)"
    }

    private var totalSize: String {
        let bytes = store.items.reduce(Int64(0)) { total, item in
            total + byteCount(for: item)
        }
        return Self.formatted(bytes: bytes)
    }

    private func subtitle(for item: ShelfItem) -> String {
        let size = Self.formatted(bytes: byteCount(for: item))
        guard let pixels = infos[item.id]?.pixelSize else { return size }
        return "\(size) • \(Int(pixels.width))x\(Int(pixels.height))"
    }

    private func byteCount(for item: ShelfItem) -> Int64 {
        if let info = infos[item.id] { return info.byteCount }
        // Text never hits the filesystem, so measure the string itself.
        if case let .text(text) = item.content { return Int64(text.utf8.count) }
        return 0
    }

    private static func formatted(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func loadInfos() async {
        var loaded: [ShelfItem.ID: FileInfo] = [:]
        for item in store.items {
            guard let url = item.url else { continue }
            if let info = await fileInfo.info(url) {
                loaded[item.id] = info
            }
        }
        infos = loaded
    }
}

enum ShelfDetailMetrics {
    static let size = CGSize(width: 430, height: 226)
    static let inset: CGFloat = 16
    static let contentWidth = size.width - inset * 2
    static let buttonDiameter = ShelfMetrics.buttonDiameter
    static let thumbnailSize: CGFloat = 72
    static let tileWidth: CGFloat = 116
}

/// Turns only the background beneath detail content into a panel drag handle.
private struct WindowDragTarget: NSViewRepresentable {
    func makeNSView(context: Context) -> TargetView {
        TargetView()
    }

    func updateNSView(_ nsView: TargetView, context: Context) {}

    final class TargetView: NSView {
        private var initialMouseLocation: CGPoint?
        private var initialWindowOrigin: CGPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            initialMouseLocation = NSEvent.mouseLocation
            initialWindowOrigin = window?.frame.origin
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let initialMouseLocation, let initialWindowOrigin else { return }

            let location = NSEvent.mouseLocation
            window.setFrameOrigin(
                CGPoint(
                    x: initialWindowOrigin.x + location.x - initialMouseLocation.x,
                    y: initialWindowOrigin.y + location.y - initialMouseLocation.y
                )
            )
        }

        override func mouseUp(with event: NSEvent) {
            initialMouseLocation = nil
            initialWindowOrigin = nil
        }
    }
}

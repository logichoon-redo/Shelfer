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
    var onExternalTargetedChange: (Bool) -> Void = { _ in }
    var onExternalFilesTargetedChange: (Bool) -> Void = { _ in }
    var onExternalPathOnlyChange: (Bool) -> Void = { _ in }

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
        // Cover the complete empty surface, not just the title row. Controls
        // and items remain above this view, while any exposed shelf material
        // can now claim keyboard focus (and continue to act as a drag handle).
        .background {
            WindowDragTarget {
                store.send(.backgroundTapped)
            }
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

            GlassEffectContainer(spacing: 8) {
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
        }
        // Keep the automation/accessibility focus target scoped to the header.
        // Marking the full-size background as one AX element would overlap the
        // item scroll view and make its buttons ambiguous to assistive clients.
        .background {
            WindowDragTarget(accessibilityLabel: "Shelf background") {
                store.send(.backgroundTapped)
            }
        }
    }

    private func circleButton(
        systemImage: String,
        label: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        ShelfCircularButton(
            systemImage: systemImage,
            label: label,
            diameter: ShelfDetailMetrics.buttonDiameter,
            isSelected: isSelected,
            action: action
        )
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
        let selectedItemIDs = store.selectedItemIDs
        let selectedItems = Array(
            store.items.filter { selectedItemIDs.contains($0.id) }
        )

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(store.items) { item in
                        gridTile(
                            for: item,
                            selectedItemIDs: selectedItemIDs,
                            selectedItems: selectedItems
                        )
                        .id(item.id)
                    }
                    revealTile
                }
                // A short row still fills the visible content width, making the
                // empty part beside its tiles useful as a panel drag handle.
                .frame(minWidth: ShelfDetailMetrics.contentWidth, alignment: .leading)
                .background {
                    WindowDragTarget {
                        store.send(.backgroundTapped)
                    }
                }
                .animation(
                    .easeInOut(duration: 0.18),
                    value: Array(store.items.ids)
                )
            }
            .onChange(of: selectedItemIDs) { _, ids in
                scrollToSingleSelection(ids, with: proxy)
            }
        }
    }

    private func gridTile(
        for item: ShelfItem,
        selectedItemIDs: Set<ShelfItem.ID>,
        selectedItems: [ShelfItem]
    ) -> some View {
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
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background {
            selectionBackground(for: item, cornerRadius: 14)
        }
        .overlay {
            itemDragSource(
                for: item,
                selectedItemIDs: selectedItemIDs,
                selectedItems: selectedItems
            )
        }
        .overlay {
            copyFeedback(for: item)
        }
        .animation(
            .easeOut(duration: 0.15),
            value: store.copyFeedbackTarget == .item(item.id)
        )
        .animation(.easeOut(duration: 0.12), value: isSelected(item))
    }

    private var listContent: some View {
        let selectedItemIDs = store.selectedItemIDs
        let selectedItems = Array(
            store.items.filter { selectedItemIDs.contains($0.id) }
        )

        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
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
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            selectionBackground(for: item, cornerRadius: 9)
                        }
                        .overlay {
                            itemDragSource(
                                for: item,
                                selectedItemIDs: selectedItemIDs,
                                selectedItems: selectedItems
                            )
                        }
                        .overlay {
                            copyFeedback(for: item)
                        }
                        .animation(
                            .easeOut(duration: 0.15),
                            value: store.copyFeedbackTarget == .item(item.id)
                        )
                        .animation(.easeOut(duration: 0.12), value: isSelected(item))
                        .id(item.id)
                    }

                    revealRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    WindowDragTarget {
                        store.send(.backgroundTapped)
                    }
                }
                .animation(
                    .easeInOut(duration: 0.18),
                    value: Array(store.items.ids)
                )
            }
            .onChange(of: selectedItemIDs) { _, ids in
                scrollToSingleSelection(ids, with: proxy)
            }
        }
    }

    private func scrollToSingleSelection(
        _ selectedItemIDs: Set<ShelfItem.ID>,
        with proxy: ScrollViewProxy
    ) {
        guard selectedItemIDs.count == 1,
              let id = selectedItemIDs.first else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// Items own their pixels: dragging one exports that item's payload, while
    /// a native double-click copies it. The row background behind these sources
    /// is reserved for moving the shelf window.
    private func itemDragSource(
        for item: ShelfItem,
        selectedItemIDs: Set<ShelfItem.ID>,
        selectedItems: [ShelfItem]
    ) -> some View {
        let targetedItems: [ShelfItem] = selectedItemIDs.contains(item.id)
            ? selectedItems
            : [item]
        let targetedContents: [ShelfItem.Content] = targetedItems.map(\.content)

        return ShelfDragSource(
            contents: targetedContents,
            itemIDs: targetedItems.map(\.id),
            reorderScopeID: store.id,
            reorderTargetID: item.id,
            reorderAxis: store.layout == .grid ? .horizontal : .vertical,
            reorderContainerSize: ShelfDetailMetrics.size,
            itemLabel: item.displayName,
            isSelected: selectedItemIDs.contains(item.id),
            acceptsExternalDrops: true,
            prefersPathOnlyDrop: store.prefersPathOnlyDrop,
            onCompleted: { store.send(.itemsDraggedOut($0)) },
            onDragActiveChange: { store.send(.shelfDragActivityChanged($0)) },
            onSelection: { store.send(.itemSelectionToggled(item.id)) },
            onContextMenu: { store.send(.itemContextMenuRequested(item.id)) },
            onDoubleClick: { store.send(.itemDoubleClicked(item.id)) },
            onCopy: {
                store.send(.itemsCopyRequested($0, .item(item.id)))
            },
            onShare: { store.send(.shareItemsRequested($0, targetedContents)) },
            onShowInFinder: { store.send(.revealItemsInFinderRequested($0)) },
            onKeepPathsOnly: {
                store.send(.itemsConvertToPathsRequested(Set(targetedItems.map(\.id))))
            },
            onClear: {
                store.send(.itemsClearRequested(Set(targetedItems.map(\.id))))
            },
            onExternalTargetedChange: onExternalTargetedChange,
            onExternalFilesTargetedChange: onExternalFilesTargetedChange,
            onExternalPathOnlyChange: onExternalPathOnlyChange,
            onExternalDrop: { store.send(.itemsDropped($0)) },
            onReorder: { movingIDs, targetID, placement in
                store.send(
                    .itemsReorderRequested(
                        movingIDs,
                        relativeTo: targetID,
                        placement: placement
                    )
                )
            }
        )
    }

    private func isSelected(_ item: ShelfItem) -> Bool {
        store.selectedItemIDs.contains(item.id)
    }

    @ViewBuilder
    private func selectionBackground(for item: ShelfItem, cornerRadius: CGFloat) -> some View {
        if isSelected(item) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.2))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                }
        }
    }

    @ViewBuilder
    private func copyFeedback(for item: ShelfItem) -> some View {
        if store.copyFeedbackTarget == .item(item.id) {
            CopiedBadge()
        }
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
                    .glassEffect(.regular.interactive(), in: .circle)

                Text("Reveal in Finder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: ShelfDetailMetrics.tileWidth)
            }
            .contentShape(.interaction, Rectangle())
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
                    .glassEffect(.regular.interactive(), in: .circle)

                Text("Reveal in Finder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)
            }
            .contentShape(.interaction, Rectangle())
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
        } else if items.allSatisfy({ $0.path != nil }) {
            noun = count == 1 ? "Path" : "Paths"
        } else if items.allSatisfy({ $0.url == nil }) {
            noun = count == 1 ? "Snippet" : "Snippets"
        } else {
            noun = count == 1 ? "Item" : "Items"
        }

        return "\(count) \(noun)"
    }

    private var totalSize: String {
        if store.items.allSatisfy({ $0.path != nil }) {
            return "Path only"
        }
        let bytes = store.items.reduce(Int64(0)) { total, item in
            total + byteCount(for: item)
        }
        return Self.formatted(bytes: bytes)
    }

    private func subtitle(for item: ShelfItem) -> String {
        if item.path != nil { return "Path only" }
        let size = Self.formatted(bytes: byteCount(for: item))
        guard let pixels = infos[item.id]?.pixelSize else { return size }
        return "\(size) • \(Int(pixels.width))x\(Int(pixels.height))"
    }

    private func byteCount(for item: ShelfItem) -> Int64 {
        if let info = infos[item.id] { return info.byteCount }
        // Text and paths never hit the filesystem, so measure the string itself.
        switch item.content {
        case let .path(path): return Int64(path.utf8.count)
        case let .text(text): return Int64(text.utf8.count)
        case .file: return 0
        }
    }

    private static func formatted(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func loadInfos() async {
        let fileItems = store.items.compactMap { item -> (ShelfItem.ID, URL)? in
            guard let url = item.url else { return nil }
            return (item.id, url)
        }
        let loadInfo = fileInfo.info
        var loaded: [ShelfItem.ID: FileInfo] = [:]
        loaded.reserveCapacity(fileItems.count)

        // A small pool keeps local disks busy without flooding iCloud,
        // network volumes, or ImageIO with one task per dropped file.
        await withTaskGroup(of: (ShelfItem.ID, FileInfo?).self) { group in
            let initialCount = min(
                fileItems.count,
                ShelfDetailMetrics.maximumConcurrentMetadataLoads
            )
            for index in 0..<initialCount {
                let (id, url) = fileItems[index]
                group.addTask {
                    (id, await loadInfo(url))
                }
            }

            var nextIndex = initialCount
            while let (id, info) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                if let info {
                    loaded[id] = info
                }

                if nextIndex < fileItems.count {
                    let (nextID, nextURL) = fileItems[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        (nextID, await loadInfo(nextURL))
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }
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
    static let maximumConcurrentMetadataLoads = 6
}

/// Turns only the background beneath detail content into a panel drag handle.
struct WindowDragTarget: NSViewRepresentable {
    var accessibilityLabel: String?
    var onClick: () -> Void

    init(
        accessibilityLabel: String? = nil,
        onClick: @escaping () -> Void = {}
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.onClick = onClick
    }

    func makeNSView(context: Context) -> TargetView {
        let view = TargetView()
        view.onClick = onClick
        updateAccessibility(of: view)
        return view
    }

    func updateNSView(_ nsView: TargetView, context: Context) {
        nsView.onClick = onClick
        updateAccessibility(of: nsView)
    }

    private func updateAccessibility(of view: TargetView) {
        guard let accessibilityLabel else {
            view.setAccessibilityElement(false)
            return
        }

        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(accessibilityLabel)
    }

    final class TargetView: NSView {
        var onClick: () -> Void = {}

        private var initialMouseLocation: CGPoint?
        private var initialWindowOrigin: CGPoint?
        private var exceededClickTolerance = false

        private static let clickMovementTolerance: CGFloat = 3

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override var acceptsFirstResponder: Bool { true }

        override var needsPanelToBecomeKey: Bool { true }

        private func claimKeyboardFocus() {
            claimShelfKeyboardFocus()
        }

        private func sendEditingCommand(_ command: ShelfPanelKeyboardCommand) {
            (window as? ShelfPanel)?.onKeyboardCommand(command)
        }

        @objc(copy:)
        private func performCopyAction(_ sender: Any?) {
            sendEditingCommand(.copySelection)
        }

        @objc(paste:)
        private func performPasteAction(_ sender: Any?) {
            sendEditingCommand(.paste)
        }

        @objc(undo:)
        private func performUndoAction(_ sender: Any?) {
            sendEditingCommand(.undo)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let command = ShelfPanelKeyboardCommand(event: event) else {
                return super.performKeyEquivalent(with: event)
            }

            sendEditingCommand(command)
            return true
        }

        override func mouseDown(with event: NSEvent) {
            claimKeyboardFocus()
            initialMouseLocation = NSEvent.mouseLocation
            initialWindowOrigin = window?.frame.origin
            exceededClickTolerance = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let initialMouseLocation, let initialWindowOrigin else { return }

            let location = NSEvent.mouseLocation
            if hypot(
                location.x - initialMouseLocation.x,
                location.y - initialMouseLocation.y
            ) > Self.clickMovementTolerance {
                exceededClickTolerance = true
            }
            window.setFrameOrigin(
                CGPoint(
                    x: initialWindowOrigin.x + location.x - initialMouseLocation.x,
                    y: initialWindowOrigin.y + location.y - initialMouseLocation.y
                )
            )
        }

        override func mouseUp(with event: NSEvent) {
            if !exceededClickTolerance {
                onClick()
            }
            initialMouseLocation = nil
            initialWindowOrigin = nil
            exceededClickTolerance = false
        }
    }
}

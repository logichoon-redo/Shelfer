//
//  ShelfFeatureTests.swift
//  ShelferTests
//

import AppKit
import ComposableArchitecture
import CoreGraphics
import Foundation
import Testing
@testable import Shelfer

@MainActor
struct ShelfFeatureTests {

    private func makeStore(
        _ state: ShelfFeature.State? = nil
    ) -> TestStore<ShelfFeature.State, ShelfFeature.Action> {
        TestStore(initialState: state ?? ShelfFeature.State()) { ShelfFeature() }
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    // MARK: - Dropping in

    @Test func droppedFilesLandOnTheShelf() async {
        let store = makeStore()

        await store.send(.itemsDropped([.file(url("a.txt")), .file(url("b.txt"))])) {
            $0.items = [ShelfItem(.file(self.url("a.txt"))), ShelfItem(.file(self.url("b.txt")))]
        }
    }

    @Test func theInitialPathOnlyIntentEndsAfterTheFirstDrop() async {
        let store = makeStore(
            ShelfFeature.State(prefersPathOnlyDrop: true)
        )

        await store.send(.itemsDropped([.path("/tmp/a.txt")])) {
            $0.items = [ShelfItem(.path("/tmp/a.txt"))]
            $0.prefersPathOnlyDrop = false
        }
    }

    @Test func aFileAlreadyOnTheShelfIsNotAddedTwice() async {
        let store = makeStore(
            ShelfFeature.State(items: [ShelfItem(.file(url("a.txt")))])
        )

        await store.send(.itemsDropped([.file(url("a.txt")), .file(url("b.txt"))])) {
            $0.items.append(ShelfItem(.file(self.url("b.txt"))))
        }
    }

    @Test func duplicatesWithinOneDropAreCollapsed() async {
        let store = makeStore()

        await store.send(.itemsDropped([.file(url("a.txt")), .file(url("a.txt"))])) {
            $0.items = [ShelfItem(.file(self.url("a.txt")))]
        }
    }

    @Test func pathsPointingAtTheSameFileAreTreatedAsOne() async {
        let store = makeStore()

        await store.send(.itemsDropped([.file(url("dir/../a.txt")), .file(url("a.txt"))])) {
            $0.items = [ShelfItem(.file(self.url("a.txt")))]
        }
    }

    @Test func aLargeDropIsInsertedAsOneOrderedDeduplicatedBatch() async {
        let store = makeStore()
        let uniqueContents = (0..<500).map {
            ShelfItem.Content.file(url("bulk/\($0).txt"))
        }
        let contents = uniqueContents + uniqueContents.prefix(100)
        let expectedItems = uniqueContents.map(ShelfItem.init)

        await store.send(.itemsDropped(Array(contents))) {
            $0.items = .init(uniqueElements: expectedItems)
        }

        #expect(store.state.items.count == 500)
        #expect(Array(store.state.items.map(\.content)) == uniqueContents)
    }

    // MARK: - Text

    @Test func droppedTextLandsOnTheShelf() async {
        let store = makeStore()

        await store.send(.itemsDropped([.text("hello")])) {
            $0.items = [ShelfItem(.text("hello"))]
        }
    }

    @Test func theSameSnippetIsNotAddedTwice() async {
        let store = makeStore(
            ShelfFeature.State(items: [ShelfItem(.text("hello"))])
        )

        await store.send(.itemsDropped([.text("hello")]))
    }

    @Test func textAndAFileCanShareAShelf() async {
        let store = makeStore()

        await store.send(.itemsDropped([.file(url("a.txt")), .text("hello")])) {
            $0.items = [ShelfItem(.file(self.url("a.txt"))), ShelfItem(.text("hello"))]
        }
    }

    @Test func draggingTextOutRemovesIt() async {
        let store = makeStore(
            ShelfFeature.State(items: [ShelfItem(.text("hello"))], isPresented: true)
        )

        await store.send(.itemsDraggedOut([.text("hello")])) {
            $0.items = []
            $0.isPresented = false
        }
    }

    @Test func textIsLabelledByItsContentOnOneLine() {
        let item = ShelfItem(.text("  first line\nsecond line  "))
        #expect(item.displayName == "first line second line")
    }

    @Test func aTextItemHasNoFileURL() {
        #expect(ShelfItem(.text("hello")).url == nil)
    }

    @Test func aPathItemKeepsOnlyAnInertAbsoluteString() {
        let item = ShelfItem(.path("/tmp/Folder/../document.pdf"))

        #expect(item.content == .path("/tmp/document.pdf"))
        #expect(item.path == "/tmp/document.pdf")
        #expect(item.url == nil)
        #expect(item.displayName == "/tmp/document.pdf")
    }

    // MARK: - Dragging out

    @Test func draggingFilesOutRemovesThemButKeepsTheShelf() async {
        let store = makeStore(
            ShelfFeature.State(
                items: [ShelfItem(.file(url("a.txt"))), ShelfItem(.file(url("b.txt")))],
                isPresented: true
            )
        )

        await store.send(.itemsDraggedOut([.file(url("a.txt"))])) {
            $0.items = [ShelfItem(.file(self.url("b.txt")))]
        }
    }

    @Test func draggingOutTheLastFileDismissesTheShelf() async {
        let store = makeStore(
            ShelfFeature.State(items: [ShelfItem(.file(url("a.txt")))], isPresented: true)
        )

        await store.send(.itemsDraggedOut([.file(url("a.txt"))])) {
            $0.items = []
            $0.isPresented = false
        }
    }

    // MARK: - Buttons

    @Test func closingDiscardsEverything() async {
        let store = makeStore(
            ShelfFeature.State(items: [ShelfItem(.file(url("a.txt")))], isPresented: true)
        )

        await store.send(.closeButtonTapped) {
            $0.items = []
            $0.isPresented = false
        }
    }

    @Test func clearingAnimatesBeforeReturningToTheEmptyDropTarget() async {
        let clock = TestClock()
        let store = TestStore(
            initialState: ShelfFeature.State(
                items: [ShelfItem(.file(url("a.txt")))],
                isPresented: true
            )
        ) {
            ShelfFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.clearButtonTapped) {
            $0.isClearing = true
        }

        // Items stay in state while SwiftUI shrinks and fades their icons.
        #expect(store.state.items.count == 1)

        await clock.advance(by: .milliseconds(260))
        await store.receive(.clearAnimationFinished) {
            $0.items = []
            $0.isClearing = false
            $0.showsEmptyCloseButton = true
        }

        #expect(store.state.isPresented)
        #expect(store.state.isEmpty)

        await store.send(.closeButtonTapped) {
            $0.isPresented = false
            $0.showsEmptyCloseButton = false
        }
    }

    @Test func droppingDuringClearKeepsOnlyTheNewItems() async {
        let clock = TestClock()
        let store = TestStore(
            initialState: ShelfFeature.State(
                items: [ShelfItem(.file(url("old.txt")))],
                isPresented: true
            )
        ) {
            ShelfFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.clearButtonTapped) {
            $0.isClearing = true
        }
        await store.send(.itemsDropped([.file(url("new.txt"))])) {
            $0.items = [ShelfItem(.file(self.url("new.txt")))]
            $0.isClearing = false
        }

        await clock.advance(by: .seconds(1))
        await store.finish()
    }

    @Test func clearingOneExpandedItemKeepsTheOtherItemsAndShelfOpen() async {
        let first = ShelfItem(.file(url("a.txt")))
        let second = ShelfItem(.file(url("b.txt")))
        let store = makeStore(
            ShelfFeature.State(
                items: [first, second],
                isPresented: true,
                isExpanded: true
            )
        )

        await store.send(.itemsClearRequested([first.id])) {
            $0.items = [second]
        }
    }

    @Test func clearingTheCollapsedStackRemovesEveryItem() async {
        let clock = TestClock()
        let lowerItem = ShelfItem(.file(url("older.txt")))
        let visibleItem = ShelfItem(.file(url("newer.txt")))
        let store = TestStore(
            initialState: ShelfFeature.State(
                items: [lowerItem, visibleItem],
                isPresented: true,
                isExpanded: false
            )
        ) {
            ShelfFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.clearButtonTapped) {
            $0.isClearing = true
        }

        await clock.advance(by: .milliseconds(260))
        await store.receive(.clearAnimationFinished) {
            $0.items = []
            $0.isClearing = false
            $0.showsEmptyCloseButton = true
        }
    }

    @Test func clearingTheLastExpandedItemReturnsToTheEmptyDropTarget() async {
        let item = ShelfItem(.text("note"))
        let store = makeStore(
            ShelfFeature.State(
                items: [item],
                isPresented: true,
                isExpanded: true
            )
        )

        await store.send(.itemsClearRequested([item.id])) {
            $0.items = []
            $0.isExpanded = false
            $0.showsEmptyCloseButton = true
        }

        #expect(store.state.isPresented)
    }

    @Test func hidingKeepsTheContents() async {
        let store = makeStore(
            ShelfFeature.State(items: [ShelfItem(.file(url("a.txt")))], isPresented: true)
        )

        await store.send(.hideRequested) {
            $0.isPresented = false
        }
    }

    // MARK: - Edge docking

    @Test func eitherBottomCornerCanDockTheShelf() async {
        let store = makeStore(ShelfFeature.State(isPresented: true))

        await store.send(.dockRequested(.left)) {
            $0.dockedEdge = .left
        }

        await store.send(.dockRequested(.right)) {
            $0.dockedEdge = .right
        }
    }

    @Test func doubleClickingTheDockHandleMakesTheShelfUndocked() async {
        let store = makeStore(
            ShelfFeature.State(isPresented: true, dockedEdge: .right)
        )

        await store.send(.undockRequested) {
            $0.dockedEdge = nil
        }
    }

    @Test func hidingClearsDockingButKeepsTheContents() async {
        let item = ShelfItem(.file(url("a.txt")))
        let store = makeStore(
            ShelfFeature.State(items: [item], isPresented: true, dockedEdge: .right)
        )

        await store.send(.hideRequested) {
            $0.isPresented = false
            $0.dockedEdge = nil
        }

        #expect(store.state.items == [item])
    }

    // MARK: - Notch docking

    @Test func notchDockStartsGenieRetractionImmediately() async {
        let clock = TestClock()
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let store = TestStore(initialState: ShelfFeature.State(isPresented: true)) {
            ShelfFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.notchDockRequested(target)) {
            $0.notchDock = ShelfNotchDock(target: target, presentation: .retracting)
        }

        await clock.advance(by: .seconds(ShelfNotchMetrics.retractionDuration))
        await store.receive(.notchRetractionFinished) {
            $0.notchDock?.presentation = .stowed
        }
    }

    @Test func hoveringRevealsAStowedNotchHandleAndPullingRestoresIt() async {
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let store = makeStore(
            ShelfFeature.State(
                isPresented: true,
                notchDock: ShelfNotchDock(target: target, presentation: .stowed)
            )
        )

        await store.send(.notchHoverChanged(true)) {
            $0.notchDock?.presentation = .peeking
        }
        await store.send(.notchHoverChanged(false)) {
            $0.notchDock?.presentation = .stowed
        }
        await store.send(.notchUndockRequested) {
            $0.notchDock = nil
        }
    }

    @Test func sideDockingAndNotchDockingAreMutuallyExclusive() async {
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let store = makeStore(
            ShelfFeature.State(
                isPresented: true,
                notchDock: ShelfNotchDock(target: target, presentation: .stowed)
            )
        )

        await store.send(.dockRequested(.right)) {
            $0.dockedEdge = .right
            $0.notchDock = nil
        }
    }

    // MARK: - Detail view

    @Test func tappingTheLabelExpandsTheShelf() async {
        let store = makeStore(
            ShelfFeature.State(items: [ShelfItem(.file(url("a.txt")))], isPresented: true)
        )

        await store.send(.expandButtonTapped) {
            $0.isExpanded = true
        }

        await store.send(.backButtonTapped) {
            $0.isExpanded = false
        }
    }

    @Test func anEmptyShelfCannotBeExpanded() async {
        let store = makeStore(ShelfFeature.State(isPresented: true))

        await store.send(.expandButtonTapped)
    }

    @Test func layoutCanBeSwitched() async {
        let store = makeStore(
            ShelfFeature.State(items: [ShelfItem(.file(url("a.txt")))], isExpanded: true)
        )

        await store.send(.layoutChanged(.list)) {
            $0.layout = .list
        }
    }

    @Test func clickingItemsBuildsASelectionAndClickingAgainDeselects() async {
        let first = ShelfItem(.file(url("a.txt")))
        let second = ShelfItem(.file(url("b.txt")))
        let store = makeStore(
            ShelfFeature.State(items: [first, second], isExpanded: true)
        )

        await store.send(.itemSelectionToggled(first.id)) {
            $0.selectedItemIDs = [first.id]
        }
        await store.send(.itemSelectionToggled(second.id)) {
            $0.selectedItemIDs = [first.id, second.id]
        }
        await store.send(.itemSelectionToggled(first.id)) {
            $0.selectedItemIDs = [second.id]
        }
    }

    @Test func rightClickPreservesASelectionOrMovesItToTheClickedItem() async {
        let first = ShelfItem(.file(url("a.txt")))
        let second = ShelfItem(.file(url("b.txt")))
        let third = ShelfItem(.text("note"))
        let store = makeStore(
            ShelfFeature.State(
                items: [first, second, third],
                isExpanded: true,
                selectedItemIDs: [first.id, second.id]
            )
        )

        await store.send(.itemContextMenuRequested(first.id))
        await store.send(.itemContextMenuRequested(third.id)) {
            $0.selectedItemIDs = [third.id]
        }
    }

    @Test func selectedItemTargetsTheWholeSelectionForContextActions() {
        let first = ShelfItem(.file(url("a.txt")))
        let second = ShelfItem(.text("note"))
        let unselected = ShelfItem(.file(url("c.txt")))
        let state = ShelfFeature.State(
            items: [first, second, unselected],
            isExpanded: true,
            selectedItemIDs: [first.id, second.id]
        )

        #expect(state.itemsTargeted(by: first.id) == [first, second])
        #expect(state.itemsTargeted(by: unselected.id) == [unselected])
    }

    @Test func convertingSelectedFilesToPathsPreservesTextAndSelection() async {
        let file = ShelfItem(.file(url("document.pdf")))
        let text = ShelfItem(.text("note"))
        let convertedPath = ShelfItem(.path(url("document.pdf").path))
        let store = makeStore(
            ShelfFeature.State(
                items: [file, text],
                isExpanded: true,
                selectedItemIDs: [file.id, text.id]
            )
        )

        await store.send(.itemsConvertToPathsRequested([file.id])) {
            $0.items = [convertedPath, text]
            $0.selectedItemIDs = [convertedPath.id, text.id]
        }
    }

    @Test func clearingASelectionRemovesEverySelectedItem() async {
        let first = ShelfItem(.file(url("a.txt")))
        let second = ShelfItem(.text("note"))
        let remaining = ShelfItem(.file(url("c.txt")))
        let store = makeStore(
            ShelfFeature.State(
                items: [first, second, remaining],
                isPresented: true,
                isExpanded: true,
                selectedItemIDs: [first.id, second.id]
            )
        )

        await store.send(.itemsClearRequested([first.id, second.id])) {
            $0.items = [remaining]
            $0.selectedItemIDs = []
        }
    }

    @Test func emptyingAnExpandedShelfCollapsesIt() async {
        let store = makeStore(
            ShelfFeature.State(
                items: [ShelfItem(.file(url("a.txt")))],
                isPresented: true,
                isExpanded: true
            )
        )

        await store.send(.itemsDraggedOut([.file(url("a.txt"))])) {
            $0.items = []
            $0.isPresented = false
            $0.isExpanded = false
        }
    }

    @Test func revealingAsksTheWorkspaceForTheFilesOnly() async {
        let revealed = LockIsolated<[URL]>([])
        let store = TestStore(
            initialState: ShelfFeature.State(items: [
                ShelfItem(.file(url("a.txt"))),
                ShelfItem(.text("hello")),
            ])
        ) {
            ShelfFeature()
        } withDependencies: {
            $0.workspace = WorkspaceClient(revealInFinder: { urls in
                revealed.setValue(urls)
            })
        }

        await store.send(.revealInFinderTapped)
        await store.finish()

        #expect(revealed.value == [self.url("a.txt")])
    }

    @Test func requestingRevealFromAnItemShowsOnlyThatFileInFinder() async {
        let revealed = LockIsolated<[URL]>([])
        let selected = url("selected.pdf")
        let store = TestStore(initialState: ShelfFeature.State()) {
            ShelfFeature()
        } withDependencies: {
            $0.workspace = WorkspaceClient(revealInFinder: { urls in
                revealed.setValue(urls)
            })
        }

        await store.send(
            .revealItemsInFinderRequested([.file(selected), .text("ignored")])
        )
        await store.finish()

        #expect(revealed.value == [selected])
    }

    @Test func droppingOnAShareTargetSharesWithoutRemovingShelfItems() async {
        let existing = ShelfItem(.file(url("existing.pdf")))
        let shared = LockIsolated<[(ShelfShareMethod, [ShelfItem.Content])]>([])
        let dropped: [ShelfItem.Content] = [
            .file(url("photo.jpg")),
            .text("hello"),
        ]
        let store = TestStore(
            initialState: ShelfFeature.State(items: [existing], isPresented: true)
        ) {
            ShelfFeature()
        } withDependencies: {
            $0.sharing = SharingClient { method, contents in
                shared.withValue { $0.append((method, contents)) }
            }
        }

        await store.send(.shareItemsDropped(.airDrop, dropped))
        await store.finish()

        #expect(store.state.items == [existing])
        #expect(shared.value.count == 1)
        #expect(shared.value[0].0 == .airDrop)
        #expect(shared.value[0].1 == dropped)
    }

    @Test func requestingShareFromAnItemSharesOnlyThatItem() async {
        let shared = LockIsolated<[(ShelfShareMethod, [ShelfItem.Content])]>([])
        let selected = ShelfItem(.text("selected"))
        let other = ShelfItem(.file(url("other.pdf")))
        let store = TestStore(
            initialState: ShelfFeature.State(items: [selected, other], isPresented: true)
        ) {
            ShelfFeature()
        } withDependencies: {
            $0.sharing = SharingClient { method, contents in
                shared.withValue { $0.append((method, contents)) }
            }
        }

        await store.send(.shareItemsRequested(.email, [selected.content]))
        await store.finish()

        #expect(store.state.items == [selected, other])
        #expect(shared.value.count == 1)
        #expect(shared.value[0].0 == .email)
        #expect(shared.value[0].1 == [selected.content])
    }

    // MARK: - Copying

    private func copyStore(
        _ state: ShelfFeature.State,
        copied: LockIsolated<[String]>,
        copiedImages: LockIsolated<[URL]> = LockIsolated([]),
        clock: TestClock<Duration>
    ) -> TestStore<ShelfFeature.State, ShelfFeature.Action> {
        TestStore(initialState: state) {
            ShelfFeature()
        } withDependencies: {
            $0.pasteboard = PasteboardClient(
                copyText: { text in
                    copied.withValue { $0.append(text) }
                },
                copyImage: { url in
                    copiedImages.withValue { $0.append(url) }
                    return true
                },
                copyContents: { _ in false }
            )
            $0.continuousClock = clock
        }
    }

    @Test func doubleClickingASnippetCopiesJustThatOne() async {
        let copied = LockIsolated<[String]>([])
        let clock = TestClock()
        let first = ShelfItem(.text("alpha"))
        let store = copyStore(
            ShelfFeature.State(items: [first, ShelfItem(.text("beta"))], isExpanded: true),
            copied: copied,
            clock: clock
        )

        await store.send(.itemDoubleClicked(first.id)) {
            $0.copyFeedbackTarget = .item(first.id)
        }

        #expect(copied.value == ["alpha"])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.copyFeedbackTarget = nil
        }
    }

    @Test func doubleClickingAPathCopiesThePathString() async {
        let copied = LockIsolated<[String]>([])
        let clock = TestClock()
        let path = ShelfItem(.path("/Users/test/My Project/App.swift"))
        let store = copyStore(
            ShelfFeature.State(items: [path], isExpanded: true),
            copied: copied,
            clock: clock
        )

        await store.send(.itemDoubleClicked(path.id)) {
            $0.copyFeedbackTarget = .item(path.id)
        }
        #expect(copied.value == ["/Users/test/My Project/App.swift"])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.copyFeedbackTarget = nil
        }
    }

    @Test func contextMenuCopyWritesEverySelectedContentAndShowsFeedback() async {
        let copiedContents = LockIsolated<[[ShelfItem.Content]]>([])
        let clock = TestClock()
        let first = ShelfItem(.file(url("first.pdf")))
        let second = ShelfItem(.text("second"))
        let store = TestStore(
            initialState: ShelfFeature.State(
                items: [first, second],
                isExpanded: true,
                selectedItemIDs: [first.id, second.id]
            )
        ) {
            ShelfFeature()
        } withDependencies: {
            $0.pasteboard = PasteboardClient(
                copyText: { _ in },
                copyImage: { _ in false },
                copyContents: { contents in
                    copiedContents.withValue { $0.append(contents) }
                    return true
                }
            )
            $0.continuousClock = clock
        }

        let contents = [first.content, second.content]
        await store.send(.itemsCopyRequested(contents, .item(first.id)))
        await store.receive(.itemsCopyFinished(true, .item(first.id))) {
            $0.copyFeedbackTarget = .item(first.id)
        }

        #expect(copiedContents.value == [contents])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.copyFeedbackTarget = nil
        }
    }

    @Test func doubleClickingTheStackJoinsEverySnippet() async {
        let copied = LockIsolated<[String]>([])
        let clock = TestClock()
        let store = copyStore(
            ShelfFeature.State(items: [
                ShelfItem(.text("alpha")),
                ShelfItem(.file(url("a.txt"))),
                ShelfItem(.text("beta")),
            ]),
            copied: copied,
            clock: clock
        )

        await store.send(.stackDoubleClicked) {
            $0.copyFeedbackTarget = .stack
        }

        // Files are skipped; snippets keep their shelf order.
        #expect(copied.value == ["alpha\nbeta"])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.copyFeedbackTarget = nil
        }
    }

    @Test func doubleClickingAFileCopiesNothing() async {
        let copied = LockIsolated<[String]>([])
        let copiedImages = LockIsolated<[URL]>([])
        let item = ShelfItem(.file(url("a.txt")))
        let store = copyStore(
            ShelfFeature.State(items: [item], isExpanded: true),
            copied: copied,
            copiedImages: copiedImages,
            clock: TestClock()
        )

        await store.send(.itemDoubleClicked(item.id))

        #expect(copied.value.isEmpty)
        #expect(copiedImages.value.isEmpty)
    }

    @Test func doubleClickingAFileOnlyStackCopiesNothing() async {
        let copied = LockIsolated<[String]>([])
        let copiedImages = LockIsolated<[URL]>([])
        let store = copyStore(
            ShelfFeature.State(items: [ShelfItem(.file(url("a.txt")))]),
            copied: copied,
            copiedImages: copiedImages,
            clock: TestClock()
        )

        await store.send(.stackDoubleClicked)

        #expect(copied.value.isEmpty)
        #expect(copiedImages.value.isEmpty)
    }

    @Test func doubleClickingAnImageItemCopiesItsImage() async {
        let copied = LockIsolated<[String]>([])
        let copiedImages = LockIsolated<[URL]>([])
        let clock = TestClock()
        let image = ShelfItem(.file(url("photo.png")))
        let store = copyStore(
            ShelfFeature.State(items: [image], isExpanded: true),
            copied: copied,
            copiedImages: copiedImages,
            clock: clock
        )

        await store.send(.itemDoubleClicked(image.id))
        await store.receive(.imageCopyFinished(true, .item(image.id))) {
            $0.copyFeedbackTarget = .item(image.id)
        }

        #expect(copied.value.isEmpty)
        #expect(copiedImages.value == [self.url("photo.png")])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.copyFeedbackTarget = nil
        }
    }

    @Test func doubleClickingASingleImageStackCopiesItsImage() async {
        let copied = LockIsolated<[String]>([])
        let copiedImages = LockIsolated<[URL]>([])
        let clock = TestClock()
        let image = ShelfItem(.file(url("photo.jpeg")))
        let store = copyStore(
            ShelfFeature.State(items: [image]),
            copied: copied,
            copiedImages: copiedImages,
            clock: clock
        )

        await store.send(.stackDoubleClicked)
        await store.receive(.imageCopyFinished(true, .stack)) {
            $0.copyFeedbackTarget = .stack
        }

        #expect(copied.value.isEmpty)
        #expect(copiedImages.value == [self.url("photo.jpeg")])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.copyFeedbackTarget = nil
        }
    }

    @Test func imageWriterPlacesEagerBitmapDataOnThePasteboard() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        let imageURL = URL(
            fileURLWithPath:
                "/System/Library/CoreServices/Dock.app/Contents/Resources/url@2x.png"
        )

        #expect(PasteboardClient.writeImage(at: imageURL, to: pasteboard))
        #expect(pasteboard.data(forType: .tiff) != nil)
        #expect(pasteboard.data(forType: .png) != nil)
    }

    @Test func contentWriterPreservesTextAndFileItemsOnThePasteboard() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        let fileURL = url("document.pdf")
        #expect(
            PasteboardClient.writeContents(
                [.text("note"), .file(fileURL)],
                to: pasteboard
            )
        )

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "note")
        #expect(items[1].string(forType: .fileURL) == fileURL.absoluteString)
    }

    @Test func pathWriterAdvertisesTextButNeverAFileURL() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        #expect(
            PasteboardClient.writeContents(
                [.path("/Users/test/Project/App.swift")],
                to: pasteboard
            )
        )

        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.string(forType: .string) == "/Users/test/Project/App.swift")
        #expect(item.string(forType: .fileURL) == nil)
    }

    @Test func shelfDragKeepsShareDropletActiveUntilItsSessionEnds() async {
        let store = makeStore()

        await store.send(.dragActivityChanged(true)) {
            $0.isDragActive = true
        }
        #expect(store.state.hasActiveDrag)

        await store.send(.shelfDragActivityChanged(true)) {
            $0.isShelfDragActive = true
        }

        // The global monitor may observe mouse-up before AppKit closes a drag
        // that originated inside the shelf. The direct source signal keeps the
        // share droplet visible throughout that hand-off.
        await store.send(.dragActivityChanged(false)) {
            $0.isDragActive = false
        }
        #expect(store.state.hasActiveDrag)

        await store.send(.shelfDragActivityChanged(false)) {
            $0.isShelfDragActive = false
        }
        #expect(!store.state.hasActiveDrag)
    }
}

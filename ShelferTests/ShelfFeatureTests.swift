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
        _ state: ShelfFeature.State = ShelfFeature.State()
    ) -> TestStore<ShelfFeature.State, ShelfFeature.Action> {
        TestStore(initialState: state) { ShelfFeature() }
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

    @Test func notchDockRetractsAsSoonAsTheMergeAnimationFinishes() async {
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
            $0.notchDock = ShelfNotchDock(target: target, presentation: .attached)
        }

        await clock.advance(by: ShelfNotchMetrics.attachmentAnimationDuration)
        await store.receive(.notchAttachmentFinished) {
            $0.notchDock?.presentation = .retracting
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
                }
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
            $0.didCopy = true
        }

        #expect(copied.value == ["alpha"])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.didCopy = false
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
            $0.didCopy = true
        }

        // Files are skipped; snippets keep their shelf order.
        #expect(copied.value == ["alpha\nbeta"])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.didCopy = false
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
        await store.receive(.imageCopyFinished(true)) {
            $0.didCopy = true
        }

        #expect(copied.value.isEmpty)
        #expect(copiedImages.value == [self.url("photo.png")])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.didCopy = false
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
        await store.receive(.imageCopyFinished(true)) {
            $0.didCopy = true
        }

        #expect(copied.value.isEmpty)
        #expect(copiedImages.value == [self.url("photo.jpeg")])

        await clock.advance(by: .seconds(1))
        await store.receive(.copyFeedbackExpired) {
            $0.didCopy = false
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

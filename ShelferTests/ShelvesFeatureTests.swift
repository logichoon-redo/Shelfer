//
//  ShelvesFeatureTests.swift
//  ShelferTests
//

import AppKit
import ComposableArchitecture
import CoreGraphics
import Foundation
import Testing
@testable import Shelfer

@MainActor
struct ShelvesFeatureTests {
    private func makeStore(
        _ state: ShelvesFeature.State? = nil
    ) -> TestStore<ShelvesFeature.State, ShelvesFeature.Action> {
        TestStore(initialState: state ?? ShelvesFeature.State()) {
            ShelvesFeature()
        } withDependencies: {
            $0.uuid = .incrementing
        }
    }

    @Test func shakingWithAnExistingShelfAddsANewIndependentShelf() async {
        let existingID = UUID(99)
        let existingPosition = CGPoint(x: 100, y: 200)
        let newPosition = CGPoint(x: 700, y: 500)
        let existing = ShelfFeature.State(
            id: existingID,
            items: [ShelfItem(.text("kept"))],
            isPresented: true,
            position: existingPosition,
            dockedEdge: .right,
            isDragActive: true
        )
        let store = makeStore(
            ShelvesFeature.State(
                shelves: [existing],
                isDragActive: true
            )
        )

        await store.send(.shelfRequested(newPosition, prefersPathOnlyDrop: false)) {
            $0.shelves.append(
                ShelfFeature.State(
                    id: UUID(0),
                    isPresented: true,
                    position: newPosition,
                    isDragActive: true
                )
            )
            $0.pendingShelfID = UUID(0)
        }

        #expect(store.state.shelves[id: existingID] == existing)
        #expect(store.state.shelves.count == 2)
    }

    @Test func contentDroppedOnTheNewShelfKeepsBothShelvesAfterTheDrag() async {
        let existing = ShelfFeature.State(
            id: UUID(99),
            items: [ShelfItem(.text("existing"))],
            isPresented: true
        )
        let store = makeStore(ShelvesFeature.State(shelves: [existing]))
        let point = CGPoint(x: 400, y: 300)

        await store.send(.shelfRequested(point, prefersPathOnlyDrop: false)) {
            $0.shelves.append(
                ShelfFeature.State(id: UUID(0), isPresented: true, position: point)
            )
            $0.pendingShelfID = UUID(0)
        }

        await store.send(
            .shelves(.element(id: UUID(0), action: .itemsDropped([.text("new")])) )
        ) {
            $0.shelves[id: UUID(0)]?.items = [ShelfItem(.text("new"))]
        }

        await store.send(.dragEnded) {
            $0.pendingShelfID = nil
        }

        #expect(store.state.shelves.count == 2)
        #expect(store.state.shelves[id: UUID(99)]?.items == [ShelfItem(.text("existing"))])
        #expect(store.state.shelves[id: UUID(0)]?.items == [ShelfItem(.text("new"))])
    }

    @Test func optionIntentBeforeSummoningIsPreservedByTheNewShelf() async {
        let point = CGPoint(x: 420, y: 260)
        let store = makeStore(ShelvesFeature.State(isDragActive: true))

        await store.send(.shelfRequested(point, prefersPathOnlyDrop: true)) {
            $0.shelves.append(
                ShelfFeature.State(
                    id: UUID(0),
                    isPresented: true,
                    position: point,
                    isDragActive: true,
                    prefersPathOnlyDrop: true
                )
            )
            $0.pendingShelfID = UUID(0)
        }
    }

    @Test func anUnusedNewShelfIsRemovedWithoutTouchingExistingShelves() async {
        let existing = ShelfFeature.State(
            id: UUID(99),
            items: [ShelfItem(.text("existing"))],
            isPresented: true
        )
        let point = CGPoint(x: 400, y: 300)
        let store = makeStore(
            ShelvesFeature.State(
                shelves: [
                    existing,
                    ShelfFeature.State(id: UUID(0), isPresented: true, position: point),
                ],
                pendingShelfID: UUID(0)
            )
        )

        await store.send(.dragEnded) {
            $0.shelves.remove(id: UUID(0))
            $0.pendingShelfID = nil
        }

        #expect(store.state.shelves == [existing])
    }

    @Test func globalDragActivityIsMirroredToEveryShelf() async {
        let store = makeStore(
            ShelvesFeature.State(shelves: [
                ShelfFeature.State(id: UUID(10), isPresented: true),
                ShelfFeature.State(id: UUID(11), isPresented: true),
            ])
        )

        await store.send(.dragActivityChanged(true, prefersPathOnlyDrop: false)) {
            $0.isDragActive = true
            $0.shelves[id: UUID(10)]?.isDragActive = true
            $0.shelves[id: UUID(11)]?.isDragActive = true
        }
    }

    @Test func globalOptionIntentIsAvailableToTheNotchDropController() async {
        let store = makeStore()

        await store.send(.dragActivityChanged(true, prefersPathOnlyDrop: true)) {
            $0.isDragActive = true
            $0.activeDragPrefersPathOnlyDrop = true
        }

        await store.send(.dragActivityChanged(false, prefersPathOnlyDrop: false)) {
            $0.isDragActive = false
            $0.activeDragPrefersPathOnlyDrop = false
        }
    }

    @Test func serviceFilesCreateANewShelfAtThePointer() async {
        let existing = ShelfFeature.State(
            id: UUID(99),
            items: [ShelfItem(.text("existing"))],
            isPresented: true
        )
        let point = CGPoint(x: 820, y: 640)
        let urls = [
            URL(fileURLWithPath: "/tmp/first.pdf"),
            URL(fileURLWithPath: "/tmp/second.png"),
        ]
        let contents = urls.map(ShelfItem.Content.file)
        let store = makeStore(
            ShelvesFeature.State(shelves: [existing])
        )

        await store.send(.externalItemsRequested(contents, point)) {
            $0.shelves.append(
                ShelfFeature.State(
                    id: UUID(0),
                    isPresented: true,
                    position: point
                )
            )
        }
        await store.receive(
            .shelves(.element(id: UUID(0), action: .itemsDropped(contents)))
        ) {
            for url in urls {
                $0.shelves[id: UUID(0)]?.items.append(ShelfItem(.file(url)))
            }
        }

        #expect(store.state.shelves[id: existing.id] == existing)
        #expect(store.state.shelves[id: UUID(0)]?.items.count == 2)
    }

    @Test func droppingDirectlyOnANotchCreatesAStoredShelf() async {
        let clock = TestClock()
        let file = URL(fileURLWithPath: "/tmp/from-finder.pdf")
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let store = TestStore(initialState: ShelvesFeature.State(isDragActive: true)) {
            ShelvesFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
        }

        await store.send(.notchItemsDropped(target, [.file(file)])) {
            $0.shelves.append(
                ShelfFeature.State(
                    id: UUID(0),
                    isPresented: true,
                    position: CGPoint(
                        x: target.notchFrame.midX,
                        y: target.notchFrame.minY - ShelfMetrics.size.height / 2
                    ),
                    isDragActive: true
                )
            )
        }
        await store.receive(
            .shelves(.element(id: UUID(0), action: .itemsDropped([.file(file)])) )
        ) {
            $0.shelves[id: UUID(0)]?.items = [ShelfItem(.file(file))]
        }
        await store.receive(
            .shelves(.element(id: UUID(0), action: .notchDockRequested(target)))
        ) {
            $0.shelves[id: UUID(0)]?.notchDock = ShelfNotchDock(
                target: target,
                presentation: .retracting
            )
        }
        await store.send(
            .shelves(.element(id: UUID(0), action: .notchUndockRequested))
        ) {
            $0.shelves[id: UUID(0)]?.notchDock = nil
        }
    }

    @Test func aNotchDropAddsToTheShelfAlreadyStoredOnThatDisplay() async {
        let clock = TestClock()
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let shelfID = UUID(42)
        let store = TestStore(
            initialState: ShelvesFeature.State(shelves: [
                ShelfFeature.State(
                    id: shelfID,
                    items: [ShelfItem(.text("existing"))],
                    isPresented: true,
                    notchDock: ShelfNotchDock(target: target, presentation: .stowed)
                ),
            ])
        ) {
            ShelvesFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
        }

        await store.send(.notchItemsDropped(target, [.text("new")]))
        await store.receive(
            .shelves(.element(id: shelfID, action: .itemsDropped([.text("new")])) )
        ) {
            $0.shelves[id: shelfID]?.items.append(ShelfItem(.text("new")))
        }
        await store.receive(
            .shelves(.element(id: shelfID, action: .notchDockRequested(target)))
        ) {
            $0.shelves[id: shelfID]?.notchDock?.presentation = .retracting
        }
        await store.send(
            .shelves(.element(id: shelfID, action: .notchUndockRequested))
        ) {
            $0.shelves[id: shelfID]?.notchDock = nil
        }
    }

    @Test func menuShowRestoresExistingShelvesWithoutCreatingAnotherOne() async {
        let first = ShelfFeature.State(
            id: UUID(10),
            items: [ShelfItem(.text("first"))]
        )
        let second = ShelfFeature.State(
            id: UUID(11),
            items: [ShelfItem(.text("second"))]
        )
        let store = makeStore(ShelvesFeature.State(shelves: [first, second]))

        await store.send(.showRequested(CGPoint(x: 900, y: 700))) {
            $0.shelves[id: first.id]?.isPresented = true
            $0.shelves[id: second.id]?.isPresented = true
        }

        #expect(store.state.shelves.count == 2)
    }

    @Test func menuHideUsesEachShelfsCompleteCleanupPath() async {
        let first = ShelfItem(.file(URL(fileURLWithPath: "/tmp/selected.txt")))
        let firstID = UUID(10)
        let secondID = UUID(11)
        let store = makeStore(
            ShelvesFeature.State(shelves: [
                ShelfFeature.State(
                    id: firstID,
                    items: [first],
                    isPresented: true,
                    dockedEdge: .left,
                    isExpanded: true,
                    selectedItemIDs: [first.id]
                ),
                ShelfFeature.State(
                    id: secondID,
                    items: [ShelfItem(.text("kept"))],
                    isPresented: true,
                    dockedEdge: .right
                ),
            ])
        )

        await store.send(.hideRequested)
        await store.receive(
            .shelves(.element(id: firstID, action: .hideRequested))
        ) {
            $0.shelves[id: firstID]?.isPresented = false
            $0.shelves[id: firstID]?.dockedEdge = nil
            $0.shelves[id: firstID]?.selectedItemIDs = []
        }
        await store.receive(
            .shelves(.element(id: secondID, action: .hideRequested))
        ) {
            $0.shelves[id: secondID]?.isPresented = false
            $0.shelves[id: secondID]?.dockedEdge = nil
        }

        #expect(store.state.shelves[id: firstID]?.items == [first])
        #expect(store.state.shelves[id: firstID]?.isExpanded == true)
        #expect(store.state.shelves[id: secondID]?.items == [ShelfItem(.text("kept"))])
    }

    @Test func notchDropOnAnotherDisplayCreatesAnotherStoredShelf() async {
        let firstTarget = ShelfNotchTarget(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let secondTarget = ShelfNotchTarget(
            displayID: 2,
            screenFrame: CGRect(x: 1512, y: 0, width: 1512, height: 982),
            notchFrame: CGRect(x: 2188, y: 950, width: 160, height: 32)
        )
        let existingID = UUID(99)
        let existing = ShelfFeature.State(
            id: existingID,
            items: [ShelfItem(.text("first display"))],
            isPresented: true,
            notchDock: ShelfNotchDock(target: firstTarget, presentation: .stowed)
        )
        let clock = TestClock()
        let store = TestStore(
            initialState: ShelvesFeature.State(shelves: [existing])
        ) {
            ShelvesFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
        }

        let content = ShelfItem.Content.path("/tmp/second-display.txt")
        await store.send(.notchItemsDropped(secondTarget, [content])) {
            $0.shelves.append(
                ShelfFeature.State(
                    id: UUID(0),
                    isPresented: true,
                    position: CGPoint(
                        x: secondTarget.notchFrame.midX,
                        y: secondTarget.notchFrame.minY - ShelfMetrics.size.height / 2
                    )
                )
            )
        }
        await store.receive(
            .shelves(.element(id: UUID(0), action: .itemsDropped([content])))
        ) {
            $0.shelves[id: UUID(0)]?.items = [ShelfItem(content)]
        }
        await store.receive(
            .shelves(.element(id: UUID(0), action: .notchDockRequested(secondTarget)))
        ) {
            $0.shelves[id: UUID(0)]?.notchDock = ShelfNotchDock(
                target: secondTarget,
                presentation: .retracting
            )
        }

        #expect(store.state.shelves[id: existingID] == existing)
        await store.send(
            .shelves(.element(id: UUID(0), action: .notchUndockRequested))
        ) {
            $0.shelves[id: UUID(0)]?.notchDock = nil
        }
    }

    @Test func closingOneShelfRemovesOnlyThatShelf() async {
        let first = ShelfFeature.State(
            id: UUID(10),
            items: [ShelfItem(.text("first"))],
            isPresented: true
        )
        let second = ShelfFeature.State(
            id: UUID(11),
            items: [ShelfItem(.text("second"))],
            isPresented: true
        )
        let store = makeStore(ShelvesFeature.State(shelves: [first, second]))

        await store.send(
            .shelves(.element(id: first.id, action: .closeButtonTapped))
        ) {
            $0.shelves[id: first.id]?.items = []
            $0.shelves[id: first.id]?.isPresented = false
        }
        await store.receive(.removeShelf(first.id)) {
            $0.shelves.remove(id: first.id)
        }

        #expect(store.state.shelves == [second])
    }

    @Test func dragMonitorCreatesAShelfInsteadOfRepositioningTheExistingOne() async {
        let (stream, continuation) = AsyncStream<DragEvent>.makeStream()
        let existing = ShelfFeature.State(
            id: UUID(99),
            items: [ShelfItem(.text("existing"))],
            isPresented: true,
            position: CGPoint(x: 10, y: 20)
        )
        let point = CGPoint(x: 500, y: 600)
        let store = TestStore(
            initialState: ShelvesFeature.State(shelves: [existing])
        ) {
            ShelvesFeature()
        } withDependencies: {
            $0.dragMonitor = DragMonitorClient(events: { stream })
            $0.uuid = .incrementing
        }

        let task = await store.send(.task)

        continuation.yield(.activityChanged(true, prefersPathOnlyDrop: false))
        await store.receive(.dragActivityChanged(true, prefersPathOnlyDrop: false)) {
            $0.isDragActive = true
            $0.shelves[id: existing.id]?.isDragActive = true
        }

        continuation.yield(.shelfRequested(point, prefersPathOnlyDrop: false))
        await store.receive(.shelfRequested(point, prefersPathOnlyDrop: false)) {
            $0.shelves.append(
                ShelfFeature.State(
                    id: UUID(0),
                    isPresented: true,
                    position: point,
                    isDragActive: true
                )
            )
            $0.pendingShelfID = UUID(0)
        }

        #expect(store.state.shelves[id: existing.id]?.position == CGPoint(x: 10, y: 20))

        continuation.finish()
        await task.cancel()
    }

    @Test func everyShelfStateGetsItsOwnPanelController() {
        let store = Store(
            initialState: ShelvesFeature.State(shelves: [
                ShelfFeature.State(id: UUID(10), isPresented: true, position: .zero),
                ShelfFeature.State(id: UUID(11), isPresented: true, position: .zero),
            ])
        ) {
            ShelvesFeature()
        }
        let controller = ShelvesWindowController(store: store)
        defer { controller.invalidate() }

        #expect(controller.managedShelfCount == 2)
    }
}

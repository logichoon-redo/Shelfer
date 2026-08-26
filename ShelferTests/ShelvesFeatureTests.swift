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
        _ state: ShelvesFeature.State = ShelvesFeature.State()
    ) -> TestStore<ShelvesFeature.State, ShelvesFeature.Action> {
        TestStore(initialState: state) {
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

        await store.send(.shelfRequested(newPosition)) {
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

        await store.send(.shelfRequested(point)) {
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

        await store.send(.dragActivityChanged(true)) {
            $0.isDragActive = true
            $0.shelves[id: UUID(10)]?.isDragActive = true
            $0.shelves[id: UUID(11)]?.isDragActive = true
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

        continuation.yield(.activityChanged(true))
        await store.receive(.dragActivityChanged(true)) {
            $0.isDragActive = true
            $0.shelves[id: existing.id]?.isDragActive = true
        }

        continuation.yield(.shelfRequested(point))
        await store.receive(.shelfRequested(point)) {
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

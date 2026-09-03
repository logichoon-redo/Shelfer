//
//  ShelfSurfaceTests.swift
//  ShelferTests
//

import AppKit
import SwiftUI
import Testing
@testable import Shelfer

@MainActor
struct ShelfSurfaceTests {
    @Test func movementSurfaceAcceptsTheFirstMouseFromAnInactiveApp() {
        let surface = ShelfSurface.SurfaceView()

        #expect(surface.acceptsFirstMouse(for: nil))
    }

    @Test func hostedButtonsAcceptTheFirstMouseFromAnInactiveApp() {
        let hosting = ShelfHostingView(rootView: Button("Test") {})

        #expect(hosting.acceptsFirstMouse(for: nil))
        #expect(!hosting.needsPanelToBecomeKey)
    }

    @Test func circularButtonOwnsItsWholeNativeHitTarget() {
        let button = ShelfCircularHitButton(
            frame: CGRect(x: 0, y: 0, width: 44, height: 44)
        )

        #expect(button.acceptsFirstMouse(for: nil))
        #expect(button.hitTest(CGPoint(x: 2, y: 22)) === button)
        #expect(button.hitTest(CGPoint(x: 0, y: 0)) == nil)
    }

    @Test func shelfSurfaceYieldsTheWholeTopButtonCircles() {
        let surface = ShelfSurface.SurfaceView(
            frame: CGRect(origin: .zero, size: ShelfMetrics.size)
        )
        surface.protectsTopLeftControl = true
        surface.protectsTopRightControl = true
        surface.topControlOuterInset = ShelfMetrics.buttonOuterInset

        let centerY = ShelfMetrics.size.height
            - ShelfMetrics.buttonOuterInset
            - ShelfMetrics.buttonHitDiameter / 2
        #expect(
            surface.hitTest(
                CGPoint(x: ShelfMetrics.buttonOuterInset + 1, y: centerY)
            ) == nil
        )
        #expect(
            surface.hitTest(
                CGPoint(x: ShelfMetrics.size.width - ShelfMetrics.buttonOuterInset - 1, y: centerY)
            ) == nil
        )
        #expect(surface.hitTest(CGPoint(x: 100, y: 100)) === surface)
    }

    @Test func shelfPanelDoesNotTakeKeyFocusForOrdinaryControls() {
        let panel = ShelfPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120))

        #expect(panel.becomesKeyOnlyIfNeeded)
    }

    @Test func manualWindowDragUsesTheSharedCaptureLifecycle() {
        let panel = ShelfPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120))
        var events: [String] = []
        var endPoint: CGPoint?
        panel.onUserDragBegan = { events.append("began") }
        panel.onUserDragMoved = { events.append("moved") }
        panel.onUserDragEnded = {
            events.append("ended")
            endPoint = $0
        }

        panel.beginUserDragTracking()
        #expect(panel.isUserDragging)
        panel.updateUserDragTracking()
        panel.endUserDragTracking(at: CGPoint(x: 24, y: 48))

        #expect(!panel.isUserDragging)
        #expect(events == ["began", "moved", "ended"])
        #expect(endPoint == CGPoint(x: 24, y: 48))
    }

    @Test func displayEdgeCaptureRecognizesBothSidesAndIgnoresTheInterior() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        #expect(
            ShelfEdgeDockGeometry.edge(
                accepting: CGRect(x: 18, y: 300, width: 200, height: 288),
                in: screen
            ) == .left
        )
        #expect(
            ShelfEdgeDockGeometry.edge(
                accepting: CGRect(x: 1_220, y: 300, width: 200, height: 288),
                in: screen
            ) == .right
        )
        #expect(
            ShelfEdgeDockGeometry.edge(
                accepting: CGRect(x: 500, y: 300, width: 200, height: 288),
                in: screen
            ) == nil
        )
    }

    @Test func displayEdgeCaptureRejectsAFrameOutsideTheDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        #expect(
            ShelfEdgeDockGeometry.edge(
                accepting: CGRect(x: -400, y: 300, width: 200, height: 288),
                in: screen
            ) == nil
        )
        #expect(
            ShelfEdgeDockGeometry.edge(
                accepting: CGRect(x: 0, y: 1_000, width: 200, height: 288),
                in: screen
            ) == nil
        )
    }

    @Test func itemInteractionCanMakeThePanelKeyForEditingShortcuts() {
        let source = ShelfDragSource.DragSourceView()

        #expect(source.acceptsFirstResponder)
        #expect(source.needsPanelToBecomeKey)
    }

    @Test func itemOverlayReceivesExternalDropsWithoutLookingUpAnotherView() async throws {
        let source = ShelfDragSource.DragSourceView()
        source.acceptsExternalDrops = true
        var targetedStates: [Bool] = []
        var droppedContents: [[ShelfItem.Content]] = []
        source.onTargetedChange = { targetedStates.append($0) }
        source.onDrop = { droppedContents.append($0) }

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.ItemOverlayExternalDrop")
        )
        pasteboard.clearContents()
        let fileURL = URL(fileURLWithPath: "/tmp/Shelfer-Item-Overlay-Drop.txt")
        #expect(pasteboard.writeObjects([fileURL as NSURL]))
        let draggingInfo = TestDraggingInfo(pasteboard: pasteboard)

        #expect(source.draggingEntered(draggingInfo) == .copy)
        #expect(targetedStates == [true])
        #expect(source.prepareForDragOperation(draggingInfo))
        #expect(source.performDragOperation(draggingInfo))

        await Task.yield()
        #expect(droppedContents == [[.file(fileURL)]])
    }

    @Test func detailBackgroundCanMakeThePanelKeyForEditingShortcuts() {
        let background = WindowDragTarget.TargetView()

        #expect(background.acceptsFirstResponder)
        #expect(background.needsPanelToBecomeKey)
    }

    @Test func detailBackgroundRecognizesAClickWithoutLosingItsFocusBehavior() throws {
        let background = WindowDragTarget.TargetView()
        var clickCount = 0
        background.onClick = { clickCount += 1 }

        background.mouseDown(with: try #require(leftClickEvent(type: .leftMouseDown)))
        background.mouseUp(with: try #require(leftClickEvent(type: .leftMouseUp)))

        #expect(clickCount == 1)
    }

    @Test func shelfPanelRoutesEditingKeyboardCommands() throws {
        let panel = ShelfPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120))
        var received: [ShelfPanelKeyboardCommand] = []
        panel.onKeyboardCommand = { received.append($0) }

        panel.sendEvent(
            try #require(keyEvent(characters: "\u{F702}", keyCode: 123))
        )
        panel.sendEvent(
            try #require(keyEvent(characters: "\u{F703}", keyCode: 124))
        )
        panel.sendEvent(
            try #require(keyEvent(characters: "\u{F700}", keyCode: 126))
        )
        panel.sendEvent(
            try #require(keyEvent(characters: "\u{F701}", keyCode: 125))
        )
        panel.sendEvent(
            try #require(keyEvent(characters: "\u{7F}", keyCode: 51))
        )
        panel.sendEvent(
            try #require(keyEvent(characters: "c", modifiers: .command, keyCode: 8))
        )
        panel.sendEvent(
            try #require(keyEvent(characters: "v", modifiers: .command, keyCode: 9))
        )
        panel.sendEvent(
            try #require(keyEvent(characters: "z", modifiers: .command, keyCode: 6))
        )

        #expect(
            received == [
                .moveSelection(.previous),
                .moveSelection(.next),
                .moveSelection(.previous),
                .moveSelection(.next),
                .deleteSelection,
                .copySelection,
                .paste,
                .undo,
            ]
        )
    }

    @Test func persistentShelfRootRoutesCommandKeyEquivalents() throws {
        let root = ShelfPanelRootView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        var received: [ShelfPanelKeyboardCommand] = []
        root.onKeyboardCommand = { received.append($0) }

        #expect(
            root.performKeyEquivalent(
                with: try #require(
                    keyEvent(characters: "c", modifiers: .command, keyCode: 8)
                )
            )
        )
        #expect(
            root.performKeyEquivalent(
                with: try #require(
                    keyEvent(characters: "v", modifiers: .command, keyCode: 9)
                )
            )
        )
        #expect(
            root.performKeyEquivalent(
                with: try #require(
                    keyEvent(characters: "z", modifiers: .command, keyCode: 6)
                )
            )
        )

        #expect(received == [.copySelection, .paste, .undo])
    }

    @Test func shelfEntranceUsesAShortLayerAnimationWithoutChangingItsFrame() {
        let frame = CGRect(x: 20, y: 30, width: 200, height: 288)
        let root = ShelfPanelRootView(frame: frame)

        root.animateEntrance(
            duration: ShelfMetrics.entranceAnimationDuration,
            initialScale: ShelfMetrics.entranceAnimationInitialScale
        )

        #expect(root.frame == frame)
        #expect(root.isEntranceAnimationActiveForTesting)
        #expect(ShelfMetrics.entranceAnimationDuration == 0.30)

        root.cancelEntranceAnimation()
        #expect(!root.isEntranceAnimationActiveForTesting)
    }

    @Test func editingShortcutsDoNotDependOnTheActiveInputLanguage() throws {
        #expect(
            ShelfPanelKeyboardCommand(
                event: try #require(
                    keyEvent(characters: "ㅊ", modifiers: .command, keyCode: 8)
                )
            ) == .copySelection
        )
        #expect(
            ShelfPanelKeyboardCommand(
                event: try #require(
                    keyEvent(characters: "ㅍ", modifiers: .command, keyCode: 9)
                )
            ) == .paste
        )
        #expect(
            ShelfPanelKeyboardCommand(
                event: try #require(
                    keyEvent(characters: "ㅋ", modifiers: .command, keyCode: 6)
                )
            ) == .undo
        )
    }

    @Test func reorderPlacementTracksBothGridAndListEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)

        #expect(
            ShelfDragSource.DragSourceView.reorderPlacement(
                at: CGPoint(x: 20, y: 40),
                in: bounds,
                axis: .horizontal,
                isFlipped: false
            ) == .before
        )
        #expect(
            ShelfDragSource.DragSourceView.reorderPlacement(
                at: CGPoint(x: 80, y: 40),
                in: bounds,
                axis: .horizontal,
                isFlipped: false
            ) == .after
        )
        #expect(
            ShelfDragSource.DragSourceView.reorderPlacement(
                at: CGPoint(x: 50, y: 70),
                in: bounds,
                axis: .vertical,
                isFlipped: false
            ) == .before
        )
        #expect(
            ShelfDragSource.DragSourceView.reorderPlacement(
                at: CGPoint(x: 50, y: 10),
                in: bounds,
                axis: .vertical,
                isFlipped: false
            ) == .after
        )
    }

    @Test func anUnselectedItemCanResolveAReorderAnywhereInsideTheShelf() {
        let first = ShelfItem(.text("first"))
        let second = ShelfItem(.text("second"))
        let shelfFrame = CGRect(x: 0, y: 0, width: 300, height: 180)
        let candidates = [
            ShelfDragSource.DragSourceView.ReorderCandidate(
                id: first.id,
                frame: CGRect(x: 20, y: 40, width: 80, height: 90)
            ),
            ShelfDragSource.DragSourceView.ReorderCandidate(
                id: second.id,
                frame: CGRect(x: 150, y: 40, width: 80, height: 90)
            ),
        ]

        #expect(
            ShelfDragSource.DragSourceView.localDropResolution(
                at: CGPoint(x: 260, y: 90),
                shelfFrame: shelfFrame,
                candidates: candidates,
                movingIDs: [first.id],
                axis: .horizontal
            ) == .reorder(second.id, .after)
        )
        #expect(
            ShelfDragSource.DragSourceView.localDropResolution(
                at: CGPoint(x: 60, y: 90),
                shelfFrame: shelfFrame,
                candidates: candidates,
                movingIDs: [first.id],
                axis: .horizontal
            ) == .keepOnShelf
        )
        #expect(
            ShelfDragSource.DragSourceView.localDropResolution(
                at: CGPoint(x: 340, y: 90),
                shelfFrame: shelfFrame,
                candidates: candidates,
                movingIDs: [first.id],
                axis: .horizontal
            ) == .outsideShelf
        )
    }

    @Test func reorderAutoScrollAcceleratesTowardHiddenItemsAtEitherEdge() {
        let visibleRange: ClosedRange<CGFloat> = 100...300

        #expect(
            ShelfDragSource.DragSourceView.autoScrollStep(
                pointerCoordinate: 100,
                visibleRange: visibleRange
            ) == -ShelfDragSource.DragSourceView.maximumAutoScrollStep
        )
        #expect(
            ShelfDragSource.DragSourceView.autoScrollStep(
                pointerCoordinate: 300,
                visibleRange: visibleRange
            ) == ShelfDragSource.DragSourceView.maximumAutoScrollStep
        )
        #expect(
            ShelfDragSource.DragSourceView.autoScrollStep(
                pointerCoordinate: 200,
                visibleRange: visibleRange
            ) == 0
        )
    }

    @Test func shelfPanelRoutesTheOuterEdgesOfCompactControls() throws {
        let panelSize = ShelfShareMetrics.panelSize(for: ShelfMetrics.size)
        let panel = ShelfPanel(
            contentRect: CGRect(origin: .zero, size: panelSize)
        )
        panel.enabledTopControls = [.close, .clear]
        var received: [ShelfPanelTopControl] = []
        panel.onTopControl = { received.append($0) }

        let y = panelSize.height
            - ShelfMetrics.buttonOuterInset
            - ShelfMetrics.buttonHitDiameter / 2
        let closePoint = CGPoint(x: ShelfMetrics.buttonOuterInset + 1, y: y)
        let clearPoint = CGPoint(
            x: panelSize.width - ShelfMetrics.buttonOuterInset - 1,
            y: y
        )

        panel.sendEvent(
            try #require(leftClickEvent(type: .leftMouseDown, location: closePoint))
        )
        panel.sendEvent(
            try #require(leftClickEvent(type: .leftMouseUp, location: closePoint))
        )
        panel.sendEvent(
            try #require(leftClickEvent(type: .leftMouseDown, location: clearPoint))
        )
        panel.sendEvent(
            try #require(leftClickEvent(type: .leftMouseUp, location: clearPoint))
        )

        #expect(received == [.close, .clear])
    }

    @Test func itemClickRequestsASelectionToggle() throws {
        let source = ShelfDragSource.DragSourceView()
        var selectionCount = 0
        source.onSelection = { selectionCount += 1 }

        source.mouseDown(with: try #require(leftClickEvent(type: .leftMouseDown)))
        source.mouseUp(with: try #require(leftClickEvent(type: .leftMouseUp)))

        #expect(selectionCount == 1)
    }

    @Test func pointerJitterStillCompletesAsAClick() throws {
        let source = ShelfDragSource.DragSourceView()
        source.contents = [.text("note")]
        var selectionCount = 0
        source.onSelection = { selectionCount += 1 }

        source.mouseDown(
            with: try #require(leftClickEvent(type: .leftMouseDown, location: .zero))
        )
        source.mouseDragged(
            with: try #require(
                leftClickEvent(type: .leftMouseDragged, location: CGPoint(x: 2, y: 2))
            )
        )
        source.mouseUp(
            with: try #require(
                leftClickEvent(type: .leftMouseUp, location: CGPoint(x: 2, y: 2))
            )
        )

        #expect(selectionCount == 1)
    }

    @Test func dragThresholdRejectsJitterAndAcceptsAnIntentionalMove() {
        #expect(
            !ShelfDragSource.DragSourceView.hasExceededDragThreshold(
                from: .zero,
                to: CGPoint(x: 2, y: 2)
            )
        )
        #expect(
            ShelfDragSource.DragSourceView.hasExceededDragThreshold(
                from: .zero,
                to: CGPoint(x: 4, y: 0)
            )
        )
    }

    @Test func optionDropTurnsFileURLsIntoInertPaths() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/Folder/document.pdf")
        pasteboard.writeObjects([url as NSURL])

        #expect(
            ShelfSurface.SurfaceView.fileDropMode(
                modifierFlags: [.option],
                pasteboard: pasteboard,
                sessionModifierFlags: []
            ) == .paths
        )
        #expect(
            ShelfSurface.SurfaceView.contents(
                from: pasteboard,
                fileDropMode: .paths
            ) == [.path("/tmp/Folder/document.pdf")]
        )
    }

    @Test func optionIntentCapturedBeforeShelfCreationStillProducesPaths() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/Folder/from-finder.pdf")
        pasteboard.writeObjects([url as NSURL])

        let mode = ShelfSurface.SurfaceView.fileDropMode(
            modifierFlags: [],
            pasteboard: pasteboard,
            prefersPathOnlyDrop: true,
            sessionModifierFlags: []
        )

        #expect(mode == .paths)
        #expect(
            ShelfSurface.SurfaceView.contents(
                from: pasteboard,
                fileDropMode: mode
            ) == [.path("/tmp/Folder/from-finder.pdf")]
        )
    }

    @Test func notchDropUsesOptionIntentCapturedBeforeItsPanelExisted() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/Folder/notch-drop.pdf")
        pasteboard.writeObjects([url as NSURL])

        let mode = ShelfNotchDropController.fileDropMode(
            modifierFlags: [],
            pasteboard: pasteboard,
            prefersPathOnlyDrop: true,
            sessionModifierFlags: []
        )

        #expect(mode == .paths)
        #expect(
            ShelfSurface.SurfaceView.contents(
                from: pasteboard,
                fileDropMode: mode
            ) == [.path("/tmp/Folder/notch-drop.pdf")]
        )
    }

    @Test func optionDetectionAlsoUsesTheGlobalSessionFlags() {
        #expect(
            ShelfModifierState.optionIsPressed(
                eventFlags: [],
                sessionFlags: [.maskAlternate]
            )
        )
        #expect(
            !ShelfModifierState.optionIsPressed(
                eventFlags: [],
                sessionFlags: []
            )
        )
    }

    @Test func optionDetectionCanUseThePhysicalKeyState() {
        #expect(
            ShelfModifierState.optionIsPressed(
                eventFlags: [],
                sessionFlags: [],
                physicalOptionPressed: true
            )
        )
        #expect(
            !ShelfModifierState.optionIsPressed(
                eventFlags: [],
                sessionFlags: [],
                physicalOptionPressed: false
            )
        )
    }

    @Test func optionIntentSurvivesMouseUpUntilTheDropConsumesIt() {
        ShelfActiveDragIntent.reset()
        defer { ShelfActiveDragIntent.reset() }

        ShelfActiveDragIntent.begin(
            eventFlags: [],
            eventCGFlags: [.maskAlternate]
        )
        ShelfActiveDragIntent.end()

        #expect(ShelfActiveDragIntent.prefersPathOnlyDrop)

        ShelfActiveDragIntent.consume()
        #expect(!ShelfActiveDragIntent.prefersPathOnlyDrop)
    }

    @Test func optionPressedAfterFinderSelectionIsStillLatchedForTheDrag() {
        ShelfActiveDragIntent.reset()
        defer { ShelfActiveDragIntent.reset() }

        ShelfActiveDragIntent.begin(eventFlags: [], eventCGFlags: [])
        #expect(!ShelfActiveDragIntent.prefersPathOnlyDrop)

        // Matches the reported order: Finder selection already exists, then
        // Option is pressed before the pointer begins its shake motion.
        ShelfActiveDragIntent.observe(
            eventFlags: [],
            eventCGFlags: [.maskAlternate]
        )
        ShelfActiveDragIntent.end()

        #expect(ShelfActiveDragIntent.prefersPathOnlyDrop)
    }

    @Test func ordinaryDropKeepsFileURLsAsFiles() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/document.pdf")
        pasteboard.writeObjects([url as NSURL])

        #expect(
            ShelfSurface.SurfaceView.fileDropMode(
                modifierFlags: [],
                pasteboard: pasteboard,
                sessionModifierFlags: []
            ) == .files
        )
        #expect(
            ShelfSurface.SurfaceView.contents(from: pasteboard) == [.file(url)]
        )
    }

    @Test func aLargeFinderPayloadCanBeValidatedBeforeItIsMaterialized() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let urls = (0..<500).map {
            URL(fileURLWithPath: "/tmp/Bulk/\($0).txt") as NSURL
        }
        pasteboard.writeObjects(urls)

        #expect(ShelfSurface.SurfaceView.canAcceptContents(from: pasteboard))
        #expect(
            ShelfSurface.SurfaceView.contents(from: pasteboard).count == 500
        )
    }

    @Test func draggingAStoredPathAdvertisesPlainTextOnly() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ShelferTests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        #expect(
            pasteboard.writeObjects([
                ShelfItem.Content.path("/Users/test/Project/App.swift").pasteboardWriter
            ])
        )

        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.string(forType: .string) == "/Users/test/Project/App.swift")
        #expect(item.string(forType: .fileURL) == nil)
        let promisedFileURL = NSPasteboard.PasteboardType(
            "com.apple.pasteboard.promised-file-url"
        )
        #expect(!item.types.contains(promisedFileURL))
    }

    @Test func fileContextMenuOffersCopyShowInFinderAndShare() throws {
        let source = ShelfDragSource.DragSourceView()
        source.contents = [.file(URL(fileURLWithPath: "/tmp/document.pdf"))]

        let menu = source.menu(for: try #require(rightClickEvent()))

        #expect(menu?.item(withTitle: "Copy") != nil)
        #expect(menu?.item(withTitle: "Show in Finder") != nil)
        #expect(menu?.item(withTitle: "Share")?.submenu != nil)
    }

    @Test func itemContextMenuOffersClearWhenTheSourceProvidesTheAction() throws {
        let source = ShelfDragSource.DragSourceView()
        source.contents = [.file(URL(fileURLWithPath: "/tmp/document.pdf"))]
        source.onClear = {}

        let menu = source.menu(for: try #require(rightClickEvent()))

        #expect(menu?.item(withTitle: "Clear")?.isEnabled == true)
    }

    @Test func fileContextMenuCanDiscardTheFileReferenceAndKeepItsPath() throws {
        let source = ShelfDragSource.DragSourceView()
        source.contents = [.file(URL(fileURLWithPath: "/tmp/document.pdf"))]
        source.onKeepPathsOnly = {}

        let menu = source.menu(for: try #require(rightClickEvent()))

        #expect(menu?.item(withTitle: "Keep Paths Only")?.isEnabled == true)
    }

    @Test func sourceWithoutClearActionDoesNotOfferClear() throws {
        let source = ShelfDragSource.DragSourceView()
        source.contents = [.file(URL(fileURLWithPath: "/tmp/document.pdf"))]

        let menu = source.menu(for: try #require(rightClickEvent()))

        #expect(menu?.item(withTitle: "Clear") == nil)
    }

    @Test func textContextMenuShowsDisabledFinderOption() throws {
        let source = ShelfDragSource.DragSourceView()
        source.contents = [.text("note")]

        let menu = source.menu(for: try #require(rightClickEvent()))

        #expect(menu?.item(withTitle: "Show in Finder")?.isEnabled == false)
        #expect(menu?.item(withTitle: "Share")?.submenu != nil)
    }

    @Test func contextMenuActionsForwardTheCurrentContents() throws {
        let source = ShelfDragSource.DragSourceView()
        let contents: [ShelfItem.Content] = [
            .file(URL(fileURLWithPath: "/tmp/document.pdf")),
            .text("note"),
        ]
        var copied: [ShelfItem.Content] = []
        var sharedMethod: ShelfShareMethod?
        var sharedContents: [ShelfItem.Content] = []
        var cleared = false
        source.contents = contents
        source.onCopy = { copied = $0 }
        source.onShare = {
            sharedMethod = $0
            sharedContents = source.contents
        }
        source.onClear = { cleared = true }

        let event = try #require(rightClickEvent())
        let menu = try #require(source.menu(for: event))
        let copy = try #require(menu.item(withTitle: "Copy"))
        #expect(NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy))
        #expect(copied == contents)

        let airDrop = try #require(
            menu.item(withTitle: "Share")?.submenu?.item(withTitle: "AirDrop")
        )
        #expect(airDrop.image != nil)
        #expect(NSApp.sendAction(try #require(airDrop.action), to: airDrop.target, from: airDrop))
        #expect(sharedMethod == .airDrop)
        #expect(sharedContents == contents)

        let clear = try #require(menu.item(withTitle: "Clear"))
        #expect(NSApp.sendAction(try #require(clear.action), to: clear.target, from: clear))
        #expect(cleared)
    }

    private func rightClickEvent() -> NSEvent? {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    }

    private func leftClickEvent(
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = [],
        location: CGPoint = .zero
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

@MainActor
private final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSequenceNumber: Int

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, sequenceNumber: Int = 1) {
        draggingPasteboard = pasteboard
        draggingSequenceNumber = sequenceNumber
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(
        atDestination dropDestination: URL
    ) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

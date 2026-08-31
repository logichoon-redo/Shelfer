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
}

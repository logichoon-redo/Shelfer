//
//  ShelfNotchGeometryTests.swift
//  ShelferTests
//

import AppKit
import ComposableArchitecture
import Testing
@testable import Shelfer

@MainActor
struct ShelfNotchGeometryTests {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let leftArea = CGRect(x: 0, y: 950, width: 676, height: 32)
    private let rightArea = CGRect(x: 836, y: 950, width: 676, height: 32)

    @Test func auxiliaryAreaGapBecomesTheNotch() {
        let target = ShelfNotchGeometry.target(
            displayID: 7,
            screenFrame: screenFrame,
            safeAreaInsets: NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea
        )

        #expect(target?.displayID == 7)
        #expect(target?.notchFrame == CGRect(x: 676, y: 950, width: 160, height: 32))
    }

    @Test func aRegularDisplayDoesNotAdvertiseANotch() {
        let target = ShelfNotchGeometry.target(
            displayID: 8,
            screenFrame: screenFrame,
            safeAreaInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        #expect(target == nil)
    }

    @Test func captureAndDropAreasExtendBelowTheCameraHousing() {
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: screenFrame,
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )

        let capture = ShelfNotchGeometry.captureFrame(for: target)
        let drop = ShelfNotchGeometry.dropFrame(for: target)
        let ambient = ShelfNotchGeometry.ambientFrame(for: target)

        #expect(capture.minY == target.notchFrame.minY - ShelfNotchMetrics.verticalCaptureDistance)
        #expect(capture.width > target.notchFrame.width)
        #expect(drop.minY == target.notchFrame.minY - ShelfNotchMetrics.dropTargetDepth)
        #expect(drop.maxY == target.screenFrame.maxY)
        #expect(ambient.midX == target.notchFrame.midX + ShelfNotchMetrics.viewHorizontalOffset)
        #expect(ambient.maxY == target.screenFrame.maxY + ShelfNotchMetrics.viewVerticalOffset)
        #expect(
            ambient.minY
                == target.notchFrame.minY
                    - ShelfNotchMetrics.idleHintDepth
                    - ShelfNotchMetrics.ambientBottomRenderOverflow
                    + ShelfNotchMetrics.viewVerticalOffset
        )
    }

    @Test func expandedShelfCanBeCapturedFromEitherSide() {
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: screenFrame,
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let capture = ShelfNotchGeometry.captureFrame(for: target)
        let expandedSize = ShelfDetailMetrics.size
        let leftSideContact = CGRect(
            x: capture.minX - expandedSize.width + 4,
            y: capture.minY + 4,
            width: expandedSize.width,
            height: expandedSize.height
        )
        let rightSideContact = CGRect(
            x: capture.maxX - 4,
            y: capture.minY + 4,
            width: expandedSize.width,
            height: expandedSize.height
        )

        #expect(
            ShelfNotchGeometry.accepts(
                leftSideContact,
                for: target,
                allowsSideContact: true
            )
        )
        #expect(
            ShelfNotchGeometry.accepts(
                rightSideContact,
                for: target,
                allowsSideContact: true
            )
        )
    }

    @Test func sideCaptureOnlyAppliesToTheExpandedShelf() {
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: screenFrame,
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let capture = ShelfNotchGeometry.captureFrame(for: target)
        let sideContact = CGRect(
            x: capture.minX - ShelfDetailMetrics.size.width + 4,
            y: capture.minY + 4,
            width: ShelfDetailMetrics.size.width,
            height: ShelfDetailMetrics.size.height
        )

        #expect(
            !ShelfNotchGeometry.accepts(
                sideContact,
                for: target,
                allowsSideContact: false
            )
        )
    }

    @Test func expandedShelfStillRequiresVerticalNotchContact() {
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: screenFrame,
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        let capture = ShelfNotchGeometry.captureFrame(for: target)
        let belowCaptureArea = CGRect(
            x: capture.minX - ShelfDetailMetrics.size.width / 2,
            y: capture.minY - ShelfDetailMetrics.size.height - 1,
            width: ShelfDetailMetrics.size.width,
            height: ShelfDetailMetrics.size.height
        )

        #expect(
            !ShelfNotchGeometry.accepts(
                belowCaptureArea,
                for: target,
                allowsSideContact: true
            )
        )
    }

    @Test func temporaryDropHighlightHasAStraightTopAndRoundedBottom() {
        let rect = CGRect(x: 24, y: 0, width: 160, height: 50)
        let path = ShelfNotchDropHighlightPath.make(
            in: rect,
            bottomCornerRadius: ShelfNotchMetrics.dropHighlightBottomCornerRadius
        )

        #expect(path.boundingBox == rect)
        #expect(path.contains(CGPoint(x: rect.minX + 1, y: rect.maxY - 1)))
        #expect(path.contains(CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)))
        #expect(!path.contains(CGPoint(x: rect.minX + 1, y: rect.minY + 1)))
        #expect(!path.contains(CGPoint(x: rect.maxX - 1, y: rect.minY + 1)))
    }

    @Test func mergedShelfNarrowsToTheNotchOnlyAtItsTop() {
        let rect = CGRect(origin: .zero, size: ShelfMetrics.size)
        let notchWidth: CGFloat = 160
        let path = ShelfNotchSilhouettePath.make(
            in: rect,
            notchWidth: notchWidth,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: true
        )

        #expect(path.contains(CGPoint(x: rect.midX, y: rect.minY + 1)))
        #expect(!path.contains(CGPoint(x: rect.minX + 5, y: rect.minY + 1)))
        #expect(
            path.contains(
                CGPoint(
                    x: rect.minX + 1,
                    y: rect.minY + ShelfNotchMetrics.mergeGradientDepth + 1
                )
            )
        )
    }

    @Test func suctionTwistsAndCompressesTheShelfTowardTheNotch() {
        let rect = CGRect(origin: .zero, size: ShelfMetrics.size)
        let notchWidth: CGFloat = 160
        let restingPath = ShelfNotchSilhouettePath.make(
            in: rect,
            notchWidth: notchWidth,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: true
        )
        let twistingPath = ShelfNotchSilhouettePath.make(
            in: rect,
            notchWidth: notchWidth,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: true,
            suctionProgress: 0.6
        )
        let absorbedPath = ShelfNotchSilhouettePath.make(
            in: rect,
            notchWidth: notchWidth,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: true,
            suctionProgress: 1
        )

        #expect(restingPath.boundingBox == rect)
        #expect(absorbedPath.boundingBox.height < rect.height * 0.4)
        #expect(absorbedPath.contains(CGPoint(x: rect.midX, y: rect.minY + 1)))
        #expect(!absorbedPath.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)))

        let trailingY = twistingPath.boundingBox.maxY - 3
        #expect(twistingPath.contains(CGPoint(x: rect.midX + 35, y: trailingY)))
        #expect(!twistingPath.contains(CGPoint(x: rect.midX - 50, y: trailingY)))
        #expect(
            ShelfNotchMetrics.suctionRetractionTravelDistance
                < ShelfShareMetrics.panelSize(for: rect.size).height / 2
        )
    }

    @Test func genieSurfaceCurlsUpperStripsBeforeLowerStrips() {
        let size = ShelfShareMetrics.panelSize(for: ShelfMetrics.size)
        let resting = ShelfGenieGeometry.state(
            progress: 0,
            top: 0.4,
            bottom: 0.45,
            size: size
        )
        let upper = ShelfGenieGeometry.state(
            progress: 0.5,
            top: 0,
            bottom: 0.05,
            size: size
        )
        let lower = ShelfGenieGeometry.state(
            progress: 0.5,
            top: 0.9,
            bottom: 0.95,
            size: size
        )
        let absorbed = ShelfGenieGeometry.state(
            progress: 1,
            top: 0.9,
            bottom: 0.95,
            size: size
        )

        #expect(resting.scaleX == 1)
        #expect(abs(resting.scaleY - 1) < 0.0001)
        #expect(upper.scaleX < lower.scaleX)
        #expect(upper.center.x != lower.center.x)
        #expect(abs(upper.rotationX) > abs(lower.rotationX))
        #expect(abs(absorbed.scaleX - 0.16) < 0.0001)
        #expect(absorbed.center.y < size.height * 0.1)
        #expect(absorbed.opacity < 0.0001)
    }

    @Test func neckCoversTheNotchsRoundedLowerCorners() {
        let rect = CGRect(origin: .zero, size: ShelfMetrics.size)
        let actualNotchWidth: CGFloat = 185
        let conservativeNeckWidth = ShelfNotchMetrics.mergeNeckWidth(
            for: actualNotchWidth
        )
        let path = ShelfNotchSilhouettePath.make(
            in: rect,
            notchWidth: conservativeNeckWidth,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: true
        )

        let notchLeftEdge = rect.midX - actualNotchWidth / 2
        let pointOutsideSquareNotch = CGPoint(
            x: notchLeftEdge - 2,
            y: rect.minY + ShelfNotchMetrics.notchCornerCoverDepth
        )

        #expect(path.contains(pointOutsideSquareNotch))
        #expect(ShelfNotchMetrics.mergeOverlap >= ShelfNotchMetrics.notchCornerCoverDepth)
        #expect(conservativeNeckWidth == actualNotchWidth - 8)
    }

    @Test func appKitMaterialMaskUsesTheSameFlippedSilhouette() {
        let rect = CGRect(origin: .zero, size: ShelfMetrics.size)
        let path = ShelfNotchSilhouettePath.make(
            in: rect,
            notchWidth: 160,
            cornerRadius: ShelfMetrics.cornerRadius,
            topEdgeAtMinY: false
        )

        #expect(path.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)))
        #expect(!path.contains(CGPoint(x: rect.minX + 5, y: rect.maxY - 1)))
        #expect(
            path.contains(
                CGPoint(
                    x: rect.minX + 1,
                    y: rect.maxY - ShelfNotchMetrics.mergeGradientDepth - 1
                )
            )
        )
    }

    @Test func directNotchShelfBuildsItsBackgroundBeforeFirstDisplay() {
        let panelSize = ShelfShareMetrics.panelSize(for: ShelfMetrics.size)
        let root = ShelfPanelRootView(
            frame: CGRect(origin: .zero, size: panelSize)
        )

        root.notchMergeWidth = ShelfNotchMetrics.mergeNeckWidth(for: 185)

        #expect(root.shelfBackground.frame == CGRect(
            x: 0,
            y: ShelfShareMetrics.footerHeight,
            width: ShelfMetrics.size.width,
            height: ShelfMetrics.size.height
        ))
        #expect(root.shelfBackground.layer?.mask != nil)
        #expect(root.shelfBackground.layer?.mask?.bounds.size == ShelfMetrics.size)
        #expect(root.shelfBackground.material == .menu)
    }

    @Test func directNotchShelfRestoresItsMaterialWhenPulledOut() async throws {
        let target = ShelfNotchTarget(
            displayID: 7,
            screenFrame: screenFrame,
            notchFrame: CGRect(x: 676, y: 950, width: 160, height: 32)
        )
        var state = ShelfFeature.State()
        state.items = [ShelfItem(.file(URL(fileURLWithPath: "/tmp/direct-notch.txt")))]
        state.isPresented = true
        state.position = CGPoint(x: target.notchFrame.midX, y: target.notchFrame.minY - 108)
        state.notchDock = ShelfNotchDock(target: target, presentation: .stowed)

        let store = Store(initialState: state) {
            ShelfFeature()
        }
        let controller = ShelfWindowController(store: store)
        defer { controller.invalidate() }

        let panel = try #require(controller.panelForTesting)
        let root = try #require(panel.contentView as? ShelfPanelRootView)
        #expect(panel.level == .statusBar)
        #expect(root.shelfBackground.isHidden)

        store.send(.notchUndockRequested)
        for _ in 0..<10 where root.shelfBackground.isHidden {
            await Task.yield()
        }

        #expect(panel.level == .floating)
        #expect(root.showsShelfBackground)
        #expect(!root.shelfBackground.isHidden)
        #expect(root.shelfBackground.frame.size == ShelfMetrics.size)
        #expect(root.shelfBackground.notchMergeWidth == nil)
        #expect(root.shelfBackground.material == .menu)
    }
}

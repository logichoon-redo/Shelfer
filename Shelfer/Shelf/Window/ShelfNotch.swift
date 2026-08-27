//
//  ShelfNotch.swift
//  Shelfer
//

import AppKit

/// A value snapshot of a physical camera housing. Keeping screen geometry in
/// state lets the reducer describe notch docking without depending on AppKit.
struct ShelfNotchTarget: Equatable, Sendable {
    let displayID: UInt32
    let screenFrame: CGRect
    let notchFrame: CGRect
}

enum ShelfNotchPresentation: Equatable, Sendable {
    /// The complete shelf is joined to the bottom of the camera housing.
    case attached
    /// The complete shelf is moving upward into the camera housing.
    case retracting
    /// Only the invisible hit target inside the physical housing remains.
    case stowed
    /// A short handle is revealed below the camera housing.
    case peeking
}

struct ShelfNotchDock: Equatable, Sendable {
    var target: ShelfNotchTarget
    var presentation: ShelfNotchPresentation
}

/// Derives the physical notch from AppKit's safe-area information. Screens
/// without a camera housing return nil, including every ordinary external
/// display.
enum ShelfNotchGeometry {
    static func target(for screen: NSScreen) -> ShelfNotchTarget? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value
        else { return nil }

        return target(
            displayID: displayID,
            screenFrame: screen.frame,
            safeAreaInsets: screen.safeAreaInsets,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    static func target(
        displayID: UInt32,
        screenFrame: CGRect,
        safeAreaInsets: NSEdgeInsets,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) -> ShelfNotchTarget? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else { return nil }

        let notchWidth = right.minX - left.maxX
        guard notchWidth > 0 else { return nil }

        let notchFrame = CGRect(
            x: left.maxX,
            y: screenFrame.maxY - safeAreaInsets.top,
            width: notchWidth,
            height: safeAreaInsets.top
        )
        guard screenFrame.contains(notchFrame) else { return nil }

        return ShelfNotchTarget(
            displayID: displayID,
            screenFrame: screenFrame,
            notchFrame: notchFrame
        )
    }

    static func targets(for screens: [NSScreen] = NSScreen.screens) -> [ShelfNotchTarget] {
        screens.compactMap(target(for:))
    }

    static func target(accepting shelfFrame: CGRect, on screens: [NSScreen] = NSScreen.screens) -> ShelfNotchTarget? {
        targets(for: screens).first { target in
            captureFrame(for: target).intersects(shelfFrame)
                && abs(target.notchFrame.midX - shelfFrame.midX) <= ShelfNotchMetrics.horizontalCaptureDistance
        }
    }

    static func captureFrame(for target: ShelfNotchTarget) -> CGRect {
        CGRect(
            x: target.notchFrame.minX - ShelfNotchMetrics.horizontalCaptureDistance,
            y: target.notchFrame.minY - ShelfNotchMetrics.verticalCaptureDistance,
            width: target.notchFrame.width + ShelfNotchMetrics.horizontalCaptureDistance * 2,
            height: target.notchFrame.height + ShelfNotchMetrics.verticalCaptureDistance
        )
    }

    static func dropFrame(for target: ShelfNotchTarget) -> CGRect {
        CGRect(
            x: target.notchFrame.minX - ShelfNotchMetrics.dropTargetHorizontalInset,
            y: target.notchFrame.minY - ShelfNotchMetrics.dropTargetDepth,
            width: target.notchFrame.width + ShelfNotchMetrics.dropTargetHorizontalInset * 2,
            height: target.notchFrame.height + ShelfNotchMetrics.dropTargetDepth
        )
    }

    static func ambientFrame(for target: ShelfNotchTarget) -> CGRect {
        CGRect(
            x: target.notchFrame.minX
                - ShelfNotchMetrics.idleHintHorizontalInset
                + ShelfNotchMetrics.viewHorizontalOffset,
            y: target.notchFrame.minY
                - ShelfNotchMetrics.idleHintDepth
                + ShelfNotchMetrics.viewVerticalOffset,
            width: target.notchFrame.width
                + ShelfNotchMetrics.idleHintHorizontalInset * 2,
            height: target.notchFrame.height
                + ShelfNotchMetrics.idleHintDepth
        )
    }
}

/// One path definition shared by AppKit's material mask and SwiftUI's border.
/// The complete shelf keeps its normal body dimensions, but its top edge begins
/// at the physical notch width and curves outward through a short neck.
enum ShelfNotchSilhouettePath {
    static func make(
        in rect: CGRect,
        notchWidth: CGFloat,
        cornerRadius: CGFloat,
        topEdgeAtMinY: Bool
    ) -> CGPath {
        let width = min(max(0, notchWidth), rect.width)
        let horizontalInset = (rect.width - width) / 2
        let requestedNeckDepth = min(ShelfNotchMetrics.mergeGradientDepth, rect.height)
        let availableBodyHeight = max(0, rect.height - requestedNeckDepth)
        let radius = min(cornerRadius, rect.width / 2, availableBodyHeight)
        let neckDepth = min(requestedNeckDepth, rect.height - radius)
        let curveConstant: CGFloat = 0.552_284_8

        func point(x: CGFloat, topOffset: CGFloat) -> CGPoint {
            CGPoint(
                x: x,
                y: topEdgeAtMinY
                    ? rect.minY + topOffset
                    : rect.maxY - topOffset
            )
        }

        let topLeft = point(x: rect.minX + horizontalInset, topOffset: 0)
        let topRight = point(x: rect.maxX - horizontalInset, topOffset: 0)
        let path = CGMutablePath()

        path.move(to: topLeft)
        path.addLine(to: topRight)
        path.addCurve(
            to: point(x: rect.maxX, topOffset: neckDepth),
            control1: point(
                x: topRight.x + horizontalInset * 0.72,
                topOffset: 0
            ),
            control2: point(
                x: rect.maxX,
                topOffset: neckDepth * 0.42
            )
        )
        path.addLine(to: point(x: rect.maxX, topOffset: rect.height - radius))
        path.addCurve(
            to: point(x: rect.maxX - radius, topOffset: rect.height),
            control1: point(
                x: rect.maxX,
                topOffset: rect.height - radius + radius * curveConstant
            ),
            control2: point(
                x: rect.maxX - radius + radius * curveConstant,
                topOffset: rect.height
            )
        )
        path.addLine(to: point(x: rect.minX + radius, topOffset: rect.height))
        path.addCurve(
            to: point(x: rect.minX, topOffset: rect.height - radius),
            control1: point(
                x: rect.minX + radius - radius * curveConstant,
                topOffset: rect.height
            ),
            control2: point(
                x: rect.minX,
                topOffset: rect.height - radius + radius * curveConstant
            )
        )
        path.addLine(to: point(x: rect.minX, topOffset: neckDepth))
        path.addCurve(
            to: topLeft,
            control1: point(
                x: rect.minX,
                topOffset: neckDepth * 0.42
            ),
            control2: point(
                x: topLeft.x - horizontalInset * 0.72,
                topOffset: 0
            )
        )
        path.closeSubpath()
        return path
    }

    /// The opaque-to-clear bridge uses only the neck portion of the same
    /// silhouette, without the shelf body's lower rounded corners.
    static func makeNeck(
        in rect: CGRect,
        notchWidth: CGFloat,
        topEdgeAtMinY: Bool
    ) -> CGPath {
        let width = min(max(0, notchWidth), rect.width)
        let horizontalInset = (rect.width - width) / 2

        func point(x: CGFloat, topOffset: CGFloat) -> CGPoint {
            CGPoint(
                x: x,
                y: topEdgeAtMinY
                    ? rect.minY + topOffset
                    : rect.maxY - topOffset
            )
        }

        let topLeft = point(x: rect.minX + horizontalInset, topOffset: 0)
        let topRight = point(x: rect.maxX - horizontalInset, topOffset: 0)
        let path = CGMutablePath()

        path.move(to: topLeft)
        path.addLine(to: topRight)
        path.addCurve(
            to: point(x: rect.maxX, topOffset: rect.height),
            control1: point(
                x: topRight.x + horizontalInset * 0.72,
                topOffset: 0
            ),
            control2: point(
                x: rect.maxX,
                topOffset: rect.height * 0.42
            )
        )
        path.addLine(to: point(x: rect.minX, topOffset: rect.height))
        path.addCurve(
            to: topLeft,
            control1: point(
                x: rect.minX,
                topOffset: rect.height * 0.42
            ),
            control2: point(
                x: topLeft.x - horizontalInset * 0.72,
                topOffset: 0
            )
        )
        path.closeSubpath()
        return path
    }
}

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
    /// The shelf is deforming and moving into the camera housing as one motion.
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
    @MainActor
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

    @MainActor
    static func targets(for screens: [NSScreen] = NSScreen.screens) -> [ShelfNotchTarget] {
        screens.compactMap { screen in
            target(for: screen)
        }
    }

    @MainActor
    static func target(
        accepting shelfFrame: CGRect,
        allowsSideContact: Bool = false,
        on screens: [NSScreen] = NSScreen.screens
    ) -> ShelfNotchTarget? {
        targets(for: screens).first { target in
            accepts(
                shelfFrame,
                for: target,
                allowsSideContact: allowsSideContact
            )
        }
    }

    /// A compact shelf keeps the original center-biased capture feel. Once the
    /// shelf is expanded, either horizontal edge may enter the notch capture
    /// area; requiring its much wider frame to be centered makes side contact
    /// appear unresponsive.
    static func accepts(
        _ shelfFrame: CGRect,
        for target: ShelfNotchTarget,
        allowsSideContact: Bool
    ) -> Bool {
        guard captureFrame(for: target).intersects(shelfFrame) else { return false }
        return allowsSideContact
            || abs(target.notchFrame.midX - shelfFrame.midX)
                <= ShelfNotchMetrics.horizontalCaptureDistance
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
                - ShelfNotchMetrics.ambientBottomRenderOverflow
                + ShelfNotchMetrics.viewVerticalOffset,
            width: target.notchFrame.width
                + ShelfNotchMetrics.idleHintHorizontalInset * 2,
            height: target.notchFrame.height
                + ShelfNotchMetrics.idleHintDepth
                + ShelfNotchMetrics.ambientBottomRenderOverflow
        )
    }
}

/// The temporary drop highlight continues behind the camera housing with a
/// straight top edge. Only the two exposed lower corners are rounded, so no
/// slivers of desktop appear between the highlight and the physical notch.
enum ShelfNotchDropHighlightPath {
    static func make(in rect: CGRect, bottomCornerRadius: CGFloat) -> CGPath {
        let radius = min(
            max(0, bottomCornerRadius),
            rect.width / 2,
            rect.height
        )
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct ShelfGenieSliceState: Equatable {
    let center: CGPoint
    let scaleX: CGFloat
    let scaleY: CGFloat
    let rotationX: CGFloat
    let opacity: CGFloat
}

/// Approximates the macOS Genie surface with thin horizontal strips. Upper
/// strips collapse first, while the lower strips lag and follow a curved path,
/// making the shelf read as one flexible sheet instead of a rigid rectangle.
enum ShelfGenieGeometry {
    static func state(
        progress: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        size: CGSize
    ) -> ShelfGenieSliceState {
        let progress = min(max(progress, 0), 1)
        let top = min(max(top, 0), 1)
        let bottom = min(max(bottom, top), 1)
        let middle = (top + bottom) / 2
        let globalProgress = smoothstep(progress)
        let topY = mappedY(row: top, progress: progress, height: size.height)
        let bottomY = mappedY(row: bottom, progress: progress, height: size.height)
        let sourceHeight = max(0.001, (bottom - top) * size.height)
        let destinationHeight = max(0.001, bottomY - topY)
        let collapse = rowCollapse(row: middle, progress: progress)
        let waveEnvelope = sin(globalProgress * .pi)
        let phase = (middle * 1.45 - globalProgress * 0.8) * .pi
        let curve = sin(phase) * 24 * waveEnvelope
        // Only the moving collapse boundary rolls around the horizontal axis.
        // Rows ahead of and behind it stay flat, like a paper curl travelling
        // down the surface instead of the whole shelf tilting as one card.
        let rotationX = -sin(collapse * .pi) * 0.44
        let foreshortening = max(0.8, cos(rotationX))

        return ShelfGenieSliceState(
            center: CGPoint(
                x: size.width / 2 + curve + collapse * 8,
                y: (topY + bottomY) / 2
            ),
            scaleX: max(0.16, 1 - collapse * 0.84),
            scaleY: destinationHeight / sourceHeight / foreshortening,
            rotationX: rotationX,
            opacity: globalProgress > 0.92
                ? max(0, 1 - (globalProgress - 0.92) / 0.08)
                : 1
        )
    }

    private static func mappedY(
        row: CGFloat,
        progress: CGFloat,
        height: CGFloat
    ) -> CGFloat {
        let collapse = rowCollapse(row: row, progress: progress)
        return row * height * (1 - collapse * 0.96)
    }

    private static func rowCollapse(row: CGFloat, progress: CGFloat) -> CGFloat {
        // A pronounced row delay leaves the lower sheet broad while the upper
        // rows have already entered the notch. This moving boundary is the
        // characteristic macOS Genie funnel.
        let delay = row * 0.62
        let unboundedProgress = (progress - delay) / max(0.001, 1 - delay)
        let localProgress = min(max(unboundedProgress, 0), 1)
        return smoothstep(localProgress)
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
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
        topEdgeAtMinY: Bool,
        suctionProgress: CGFloat = 0
    ) -> CGPath {
        let width = min(max(0, notchWidth), rect.width)
        let horizontalInset = (rect.width - width) / 2
        let requestedNeckDepth = min(ShelfNotchMetrics.mergeGradientDepth, rect.height)
        let availableBodyHeight = max(0, rect.height - requestedNeckDepth)
        let restingRadius = min(cornerRadius, rect.width / 2, availableBodyHeight)
        let neckDepth = min(requestedNeckDepth, rect.height - restingRadius)
        let curveConstant: CGFloat = 0.552_284_8
        let progress = min(max(0, suctionProgress), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        let twist = easedProgress * ShelfNotchMetrics.suctionTwistAmplitude

        let minimumBodyWidth = min(
            rect.width,
            max(ShelfNotchMetrics.suctionTailWidth, width * 0.26)
        )
        let bodyWidth = rect.width + (minimumBodyWidth - rect.width) * easedProgress
        let bodyCenterX = rect.midX + twist
        let bodyLeft = max(rect.minX, bodyCenterX - bodyWidth / 2)
        let bodyRight = min(rect.maxX, bodyCenterX + bodyWidth / 2)
        let minimumBottomOffset = min(
            rect.height,
            neckDepth + ShelfNotchMetrics.suctionTailHeight
        )
        let bottomOffset = rect.height
            + (minimumBottomOffset - rect.height) * easedProgress
        let bodyHeight = max(0, bottomOffset - neckDepth)
        let radius = min(
            restingRadius * (1 - easedProgress * 0.72),
            bodyWidth / 2,
            bodyHeight / 2
        )

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
            to: point(x: bodyRight, topOffset: neckDepth),
            control1: point(
                x: topRight.x + (bodyRight - topRight.x) * 0.72,
                topOffset: 0
            ),
            control2: point(
                x: bodyRight - twist * 0.18,
                topOffset: neckDepth * 0.42
            )
        )
        path.addLine(to: point(x: bodyRight, topOffset: bottomOffset - radius))
        path.addCurve(
            to: point(x: bodyRight - radius, topOffset: bottomOffset),
            control1: point(
                x: bodyRight,
                topOffset: bottomOffset - radius + radius * curveConstant
            ),
            control2: point(
                x: bodyRight - radius + radius * curveConstant,
                topOffset: bottomOffset
            )
        )
        path.addLine(to: point(x: bodyLeft + radius, topOffset: bottomOffset))
        path.addCurve(
            to: point(x: bodyLeft, topOffset: bottomOffset - radius),
            control1: point(
                x: bodyLeft + radius - radius * curveConstant,
                topOffset: bottomOffset
            ),
            control2: point(
                x: bodyLeft,
                topOffset: bottomOffset - radius + radius * curveConstant
            )
        )
        path.addLine(to: point(x: bodyLeft, topOffset: neckDepth))
        path.addCurve(
            to: topLeft,
            control1: point(
                x: bodyLeft - twist * 0.18,
                topOffset: neckDepth * 0.42
            ),
            control2: point(
                x: topLeft.x + (bodyLeft - topLeft.x) * 0.72,
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

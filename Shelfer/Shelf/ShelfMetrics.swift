//
//  ShelfMetrics.swift
//  Shelfer
//

import CoreGraphics
import Foundation

/// Shared by the SwiftUI content and the AppKit panel that hosts it, so the
/// window and the view it contains can't drift apart.
enum ShelfMetrics {
    static let size = CGSize(width: 200, height: 216)
    static let cornerRadius: CGFloat = 28
    static let outerInset: CGFloat = 12
    static let buttonDiameter: CGFloat = 34
    static let buttonHitDiameter: CGFloat = 44
    static let buttonOuterInset = outerInset - (buttonHitDiameter - buttonDiameter) / 2
    static let handleSize = CGSize(width: 36, height: 4)
    static let iconSize: CGFloat = 84
    static let labelTextMaxWidth: CGFloat = 72
    static let labelMarqueePointsPerSecond: CGFloat = 14

    /// A compact summon should feel responsive rather than theatrical. The
    /// panel frame stays fixed so its drop and button hit regions are correct
    /// from the first frame; only the rendered surface scales into place.
    static let entranceAnimationDuration: TimeInterval = 0.30
    static let entranceAnimationInitialScale: CGFloat = 0.94

    /// Shared by AppKit's panel resize and SwiftUI's content transition so the
    /// shelf grows and changes screens as one continuous movement.
    static let expansionAnimationDuration = 0.26
    static let clearAnimationDuration = 0.26
    static let clearRotationDegrees = -180.0
}

/// The part of a docked shelf that remains on screen as its return handle.
enum ShelfDockMetrics {
    static let revealedWidth: CGFloat = 33
    static let handleWidth: CGFloat = 33
    static let cornerTargetSize: CGFloat = 52
    static let animationDuration = 0.32
}

enum ShelfNotchMetrics {
    static let horizontalCaptureDistance: CGFloat = 70
    static let verticalCaptureDistance: CGFloat = 72
    static let dropTargetHorizontalInset: CGFloat = 24
    static let dropTargetDepth: CGFloat = 18
    static let dropHighlightLeftExtension: CGFloat = 2
    static let dropHighlightBottomCornerRadius: CGFloat = 13
    /// Pushes the neck behind the camera housing far enough to fill the display
    /// pixels exposed by the notch's rounded lower corners.
    static let notchCornerCoverDepth: CGFloat = 14
    static let mergeOverlap = notchCornerCoverDepth
    /// Keeps the merging neck slightly inside the hardware bounds. The camera
    /// housing's optical edge is tighter than the safe-area rectangle.
    static let mergeNeckHorizontalInset: CGFloat = 4
    /// A short black bridge visually joins the material shelf to the camera
    /// housing. Its top matches the notch exactly, then widens and fades into
    /// the shelf so neither the border nor the material seam remains visible.
    static let mergeGradientDepth: CGFloat = 52
    static let suctionTwistAmplitude: CGFloat = 24
    static let suctionTailWidth: CGFloat = 42
    static let suctionTailHeight: CGFloat = 20
    /// The material collapses before the panel moves. It only needs to travel
    /// far enough to carry the final narrow tail behind the camera housing.
    static var suctionRetractionTravelDistance: CGFloat {
        max(0, mergeGradientDepth + suctionTailHeight - mergeOverlap)
    }
    /// The transparent window leaves enough room for the ambient halo to bloom.
    static let idleHintDepth: CGFloat = 20
    static let idleHintHorizontalInset: CGFloat = 66
    /// Extra transparent space below the visible hint prevents the Gaussian
    /// blur from being cut off by the panel's lower window boundary.
    static let ambientBottomRenderOverflow: CGFloat = 64

    /// Extends the luminous surface past the hardware notch so its sides and
    /// lower edge remain visible while the center sits behind the camera housing.
    static let ambientWidthExpansion: CGFloat = 45
    static let ambientHeightExpansion: CGFloat = 7
    static let ambientHorizontalScale: CGFloat = 0.9
    static let ambientVerticalScale: CGFloat = 0.5
    static let peekDepth: CGFloat = 24
    static let peekHorizontalInset: CGFloat = 8
    static let peekCornerRadius: CGFloat = 12
    static let peekHandleTopSpacing: CGFloat = 6
    static let peekHandleSize = CGSize(width: 28, height: 3)
    static let hoverProximityHorizontalInset: CGFloat = 18
    static let hoverProximityDepth: CGFloat = 14

    /// Manual optical alignment for the merge, idle glow, and revealed notch view.
    /// Positive X moves right; positive Y moves up.
    static let viewHorizontalOffset: CGFloat = -1
    static let viewVerticalOffset: CGFloat = 0

    static func mergeNeckWidth(for notchWidth: CGFloat) -> CGFloat {
        max(0, notchWidth - mergeNeckHorizontalInset * 2)
    }

    /// Independent optical adjustment for the small gray drag handle.
    static let handleHorizontalOffset: CGFloat = -4
    static let pullDistance: CGFloat = 14
    static let retractionDuration: TimeInterval = 0.72
    /// The handle should answer the pointer quickly, while its slower dismissal
    /// preserves the stable fade that prevents it from jumping sideways.
    static let peekRevealAnimationDuration: TimeInterval = 0.28
    static let peekHideAnimationDuration: TimeInterval = 0.52
    static let hoverPollingInterval: Duration = .milliseconds(16)
}

enum ShelfShareMetrics {
    static let gap: CGFloat = 8
    static let circleDiameter: CGFloat = 44
    static let optionSpacing: CGFloat = 12
    static let optionStride = circleDiameter + optionSpacing
    static let dockSize = CGSize(width: 172, height: 62)
    static let footerHeight = gap + dockSize.height

    static func panelSize(for shelfSize: CGSize) -> CGSize {
        CGSize(
            width: max(shelfSize.width, dockSize.width),
            height: shelfSize.height + footerHeight
        )
    }
}

//
//  ShelfMetrics.swift
//  Shelfer
//

import CoreGraphics

/// Shared by the SwiftUI content and the AppKit panel that hosts it, so the
/// window and the view it contains can't drift apart.
enum ShelfMetrics {
    static let size = CGSize(width: 200, height: 216)
    static let cornerRadius: CGFloat = 28
    static let outerInset: CGFloat = 12
    static let buttonDiameter: CGFloat = 34
    static let handleSize = CGSize(width: 36, height: 4)
    static let iconSize: CGFloat = 84
    static let labelTextMaxWidth: CGFloat = 72
    static let labelMarqueePointsPerSecond: CGFloat = 14

    /// Shared by AppKit's panel resize and SwiftUI's content transition so the
    /// shelf grows and changes screens as one continuous movement.
    static let expansionAnimationDuration = 0.26
    static let clearAnimationDuration = 0.26
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

//
//  ShelfMetrics.swift
//  C5
//

import CoreGraphics

/// Shared by the SwiftUI content and the AppKit panel that hosts it, so the
/// window and the view it contains can't drift apart.
enum ShelfMetrics {
    static let size = CGSize(width: 200, height: 200)
    static let cornerRadius: CGFloat = 28
    static let buttonDiameter: CGFloat = 26
    static let buttonInset: CGFloat = 14
    static let handleSize = CGSize(width: 36, height: 4)
    static let iconSize: CGFloat = 76

    /// Shared by AppKit's panel resize and SwiftUI's content transition so the
    /// shelf grows and changes screens as one continuous movement.
    static let expansionAnimationDuration = 0.26
}

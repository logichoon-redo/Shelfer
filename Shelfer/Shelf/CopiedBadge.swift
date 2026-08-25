//
//  CopiedBadge.swift
//  Shelfer
//

import SwiftUI

/// Confirms a copy happened — without it, double-clicking looks like nothing.
struct CopiedBadge: View {
    var body: some View {
        Label("Copied!", systemImage: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.45)))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .allowsHitTesting(false)
    }
}

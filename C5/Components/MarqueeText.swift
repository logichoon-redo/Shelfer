//
//  MarqueeText.swift
//  C5
//

import SwiftUI

/// Single-line text that scrolls sideways when it doesn't fit, instead of truncating.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .medium)
    var maxWidth: CGFloat = 140
    var pointsPerSecond: CGFloat = 28

    @State private var textWidth: CGFloat = 0
    @State private var isScrolled = false

    private var overflow: CGFloat { max(0, textWidth - maxWidth) }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                }
            }
            .offset(x: isScrolled ? -overflow : 0)
            .frame(width: textWidth > 0 ? min(textWidth, maxWidth) : nil, alignment: .leading)
            .clipped()
            .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
            .onChange(of: overflow) { restartScrolling() }
            .onChange(of: text) { restartScrolling() }
            .onAppear { restartScrolling() }
    }

    private func restartScrolling() {
        isScrolled = false
        guard overflow > 0 else { return }

        withAnimation(
            .linear(duration: Double(overflow / pointsPerSecond))
            .delay(0.8)
            .repeatForever(autoreverses: true)
        ) {
            isScrolled = true
        }
    }
}

private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

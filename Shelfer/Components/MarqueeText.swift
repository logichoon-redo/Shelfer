//
//  MarqueeText.swift
//  Shelfer
//

import SwiftUI

/// Single-line text that scrolls sideways when it doesn't fit, instead of truncating.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .medium)
    var maxWidth: CGFloat = 140
    var pointsPerSecond: CGFloat = 28

    @State private var textWidth: CGFloat = 0
    @State private var horizontalOffset: CGFloat = 0

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
            .offset(x: horizontalOffset)
            // Reserve a real width on the first layout pass. This keeps the
            // filename visible while its intrinsic width is being measured.
            .frame(width: visibleWidth, alignment: .leading)
            .clipped()
            .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
            .task(id: ScrollID(text: text, measuredWidth: textWidth)) {
                await scrollIfNeeded()
            }
    }

    private var visibleWidth: CGFloat {
        textWidth > 0 ? min(textWidth, maxWidth) : maxWidth
    }

    private func scrollIfNeeded() async {
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            horizontalOffset = 0
        }

        // Commit the leading position before scheduling any movement. Without
        // this yield, a newly inserted label can inherit the model value from
        // the repeating animation and render its first frame outside the clip.
        await Task.yield()
        guard overflow > 0 else { return }

        let travelDuration = Double(overflow / pointsPerSecond)
        do {
            try await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                withAnimation(.linear(duration: travelDuration)) {
                    horizontalOffset = -overflow
                }
                try await Task.sleep(for: .seconds(travelDuration + 0.8))

                withAnimation(.linear(duration: travelDuration)) {
                    horizontalOffset = 0
                }
                try await Task.sleep(for: .seconds(travelDuration + 0.8))
            }
        } catch {
            // A new filename or measurement starts a fresh task at x = 0.
        }
    }
}

private struct ScrollID: Hashable {
    let text: String
    let measuredWidth: CGFloat
}

private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

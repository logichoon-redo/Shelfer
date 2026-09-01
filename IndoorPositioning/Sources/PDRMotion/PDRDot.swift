//
//  PDRDot.swift
//  PDRMotion
//

import Foundation
import PDRCore

#if canImport(SwiftUI)
import SwiftUI

/// The marker for our own estimate, meant to sit on the same map as the
/// system's blue dot so the two can be watched diverge.
///
/// Red, and visibly not the system dot: the whole value of showing both is that
/// nobody has to guess which is which. When the filter has not settled on a
/// single hypothesis the ring goes dashed and hollow, because a solid dot reads
/// as authoritative however wrong it is.
@available(iOS 16.0, macOS 13.0, *)
public struct PDRDot: View {
    public var isAmbiguous: Bool
    /// 1-sigma horizontal accuracy in metres, shown as a caption when given.
    public var accuracy: Double?
    /// Direction of travel, radians counter-clockwise from map +X. Drawn as a
    /// pointer when given.
    public var heading: Double?
    public var diameter: CGFloat

    public init(
        isAmbiguous: Bool = false,
        accuracy: Double? = nil,
        heading: Double? = nil,
        diameter: CGFloat = 16
    ) {
        self.isAmbiguous = isAmbiguous
        self.accuracy = accuracy
        self.heading = heading
        self.diameter = diameter
    }

    public var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if let heading {
                    Triangle()
                        .fill(.red)
                        .frame(width: diameter * 0.55, height: diameter * 0.55)
                        .offset(y: -diameter * 0.85)
                        .rotationEffect(.radians(.pi / 2 - heading))
                }
                Circle()
                    .fill(isAmbiguous ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color.red))
                    .frame(width: diameter, height: diameter)
                    .overlay {
                        Circle().strokeBorder(
                            Color.red,
                            style: StrokeStyle(
                                lineWidth: 3,
                                dash: isAmbiguous ? [3, 3] : []
                            )
                        )
                    }
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                    }
                    .shadow(radius: 2)
            }
            if let accuracy {
                Text(String(format: "±%.0fm", accuracy))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 3)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

#endif

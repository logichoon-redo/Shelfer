//
//  ShelfItemIcon.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture
import SwiftUI

/// Shows a Quick Look thumbnail when the file has one (images, PDFs, …),
/// falling back to the file-type icon.
struct ShelfItemIcon: View {
    let item: ShelfItem
    let size: CGFloat

    @Dependency(\.thumbnails) private var thumbnails
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            } else {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.id) {
            // `thumbnail` belongs to the view's structural position. Clear it
            // before loading so a position reused for another item can never
            // display the previous item's image while Quick Look catches up.
            thumbnail = nil

            // Only files have something to preview; text renders as its type icon.
            guard let url = item.url else { return }
            let loadedThumbnail = await thumbnails.thumbnail(url, size)
            guard !Task.isCancelled else { return }
            thumbnail = loadedThumbnail
        }
    }
}

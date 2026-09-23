import AppKit
import SwiftUI

/// In-memory cache over the on-disk thumbnails so scrolling stays smooth.
enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 1500
        return c
    }()

    static func image(for photo: Photo) async -> NSImage? {
        if let hit = cache.object(forKey: photo.id as NSString) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if let img = NSImage(contentsOf: photo.thumbnailURL) { return img }
            // Thumbnail missing (e.g. cache cleared): make one from the original.
            return Indexer.thumbnail(photo.url).map { NSImage(cgImage: $0, size: .zero) }
        }.value
        if let image { cache.setObject(image, forKey: photo.id as NSString) }
        return image
    }
}

struct ThumbnailView: View {
    let photo: Photo
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.5))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            .overlay(Rectangle().fill(.black.opacity(hovering ? 0.12 : 0)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: photo.id) { image = await ThumbnailCache.image(for: photo) }
    }
}

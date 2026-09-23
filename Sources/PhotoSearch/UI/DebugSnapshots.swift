import AppKit

/// Development aid: with PHOTOSEARCH_SNAPSHOTS=<dir> set, the app walks
/// through a few screens and saves its own window to PNGs, then quits.
/// Rendering our own views needs no screen-recording permission.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["PHOTOSEARCH_SNAPSHOTS"] else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let queries = (ProcessInfo.processInfo.environment["PHOTOSEARCH_SNAPSHOT_QUERIES"] ?? "painting in church")
            .split(separator: "|").map(String.init)

        Task {
            while model.phase != .ready || model.progress != nil || model.photos.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            save(out.appendingPathComponent("1-grid.png"))

            for (i, q) in queries.enumerated() {
                model.query = q
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                save(out.appendingPathComponent("2-search-\(i).png"))
            }

            model.viewing = model.photos.first
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            save(out.appendingPathComponent("3-viewer.png"))
            model.showNext(1)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            save(out.appendingPathComponent("4-viewer-next.png"))
            model.viewing = nil
            model.query = ""
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if ProcessInfo.processInfo.environment["PHOTOSEARCH_SNAPSHOT_STAY"] == nil {
                NSApp.terminate(nil)
            }
        }
    }

    static func save(_ url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = size
        // Rendering the layer tree (rather than cacheDisplay) also captures
        // text fields, which draw through a separate field editor.
        view.wantsLayer = true
        ctx.cgContext.scaleBy(x: scale, y: scale)
        view.layer?.render(in: ctx.cgContext)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

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
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

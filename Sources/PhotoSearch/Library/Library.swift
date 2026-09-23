import Foundation
import PhotoSorterCore

/// The user's photo folder: keeps it sorted (PhotoSorter layout) and brings
/// in photos dragged onto the window.
struct Library: Sendable {
    let root: URL
    let sorter: Sorter

    /// True if the file already sits where PhotoSorter would keep it:
    /// `<year>/<MM - Month>/<Location>/file` or `Unknown Date/file`.
    func isSorted(_ url: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard Array(parts.prefix(rootParts.count)) == rootParts else { return true }
        let rel = Array(parts.dropFirst(rootParts.count))
        if rel.count == 2 && rel[0] == Sorter.unknownDate { return true }
        guard rel.count == 4 else { return false }
        return rel[0].count == 4 && Int(rel[0]) != nil
            && rel[1].range(of: #"^\d{2} - \p{L}+$"#, options: .regularExpression) != nil
    }

    /// Sorts every media file that isn't in its place yet (new arrivals).
    /// Files still being copied in are left for the next pass.
    /// Returns how many files were moved.
    @discardableResult
    func sortNewArrivals() async -> Int {
        let candidates = sorter.scanFiles(under: root).media.filter { !isSorted($0) }
        guard !candidates.isEmpty else { return 0 }

        let before = Dictionary(uniqueKeysWithValues: candidates.map { ($0, Self.size($0)) })
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        var moved = 0
        for url in candidates where Self.size(url) == before[url] && Self.size(url) != nil {
            if (try? await sorter.sortFile(url, root: root)) != nil { moved += 1 }
        }
        if moved > 0 { sorter.cleanupEmptyDirs(under: root) }
        return moved
    }

    /// Copies dropped files (or the media inside dropped folders) into the
    /// library root and sorts them into place. Originals are left untouched.
    /// Files that already live in the library, or whose exact content is
    /// already there (`isDuplicate`), are skipped.
    func importItems(_ urls: [URL], isDuplicate: (URL) async -> Bool = { _ in false }) async -> Int {
        let fm = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                files += sorter.scanFiles(under: url).media
            } else if Sorter.mediaExts.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }

        let rootPath = root.standardizedFileURL.path + "/"
        var imported = 0
        for file in files where !file.standardizedFileURL.path.hasPrefix(rootPath) {
            if await isDuplicate(file) { continue }
            // Stage under a hidden name so the watcher doesn't grab it half-copied.
            let staging = root.appendingPathComponent(".importing-\(UUID().uuidString).\(file.pathExtension.lowercased())")
            do {
                try fm.copyItem(at: file, to: staging)
                let named = uniqueName(file.lastPathComponent)
                try fm.moveItem(at: staging, to: named)
                try await sorter.sortFile(named, root: root)
                imported += 1
            } catch {
                try? fm.removeItem(at: staging)
            }
        }
        return imported
    }

    private func uniqueName(_ filename: String) -> URL {
        let fm = FileManager.default
        var target = root.appendingPathComponent(filename)
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = root.appendingPathComponent(ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)")
            n += 1
        }
        return target
    }

    private static func size(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }
}

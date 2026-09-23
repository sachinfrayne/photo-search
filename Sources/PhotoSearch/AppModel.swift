import AppKit
import Foundation
import PhotoSorterCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case needsFolder
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var libraryURL: URL?
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var isSearching = false
    @Published var query = ""
    @Published var viewing: Photo?

    private let engine = Engine()
    private var engineStart: Task<Void, Error>?
    private var watcher: FolderWatcher?
    private var library: Library?
    /// All library work (sort, import, index) runs one job at a time.
    private var workTail: Task<Void, Never>?
    private var rescanQueued = false

    private static let bookmarkKey = "libraryBookmark"

    init() {
        // PHOTOSEARCH_LIBRARY is for development/testing only.
        if let override = ProcessInfo.processInfo.environment["PHOTOSEARCH_LIBRARY"] {
            open(URL(fileURLWithPath: override))
        } else if let url = Self.savedLibrary() {
            open(url)
        } else {
            phase = .needsFolder
        }
    }

    // MARK: - Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that holds your photos."
        if panel.runModal() == .OK, let url = panel.url {
            useFolder(url)
        }
    }

    func useFolder(_ url: URL) {
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        open(url)
    }

    private static func savedLibrary() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    private func open(_ url: URL) {
        let root = url.standardizedFileURL
        libraryURL = root
        library = Library(root: root, sorter: Sorter(geocodeCache: engine.geocoder))
        watcher = nil
        phase = .starting
        photos = []
        Task { await boot(root) }
    }

    private func boot(_ root: URL) async {
        do {
            if engineStart == nil {
                let engine = engine
                engineStart = Task { try await engine.start() }
            }
            try await engineStart!.value
            phase = .ready
            await refresh()
            watcher = FolderWatcher(url: root) { [weak self] in
                Task { @MainActor in self?.scheduleRescan() }
            }
            scheduleRescan()
        } catch {
            engineStart = nil
            engine.stop()
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() {
        if let libraryURL { open(libraryURL) } else { phase = .needsFolder }
    }

    // MARK: - Library work

    /// Sort new arrivals, then reconcile the index with what's on disk.
    func scheduleRescan() {
        guard !rescanQueued else { return }
        rescanQueued = true
        enqueue { [weak self] in
            guard let self, let library = self.library else { return }
            self.rescanQueued = false
            await library.sortNewArrivals()
            await self.syncIndex()
        }
    }

    func importDropped(_ urls: [URL]) {
        enqueue { [weak self] in
            guard let self, let library = self.library else { return }
            self.progress = (0, 0)
            let indexer = self.engine.indexer!
            _ = await library.importItems(urls) { await indexer.contains(contentOf: $0) }
            await self.syncIndex()
        }
    }

    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let previous = workTail
        workTail = Task { @MainActor in
            await previous?.value
            await job()
        }
    }

    private func syncIndex() async {
        guard let root = library?.root, phase == .ready else { return }
        do {
            try await engine.indexer.sync(root: root) { [weak self] done, total in
                self?.progress = total > 0 && done < total ? (done, total) : nil
                // Show new photos as they arrive rather than all at the end.
                if total > 0, done % 25 == 0 { Task { await self?.refresh() } }
            }
        } catch {
            NSLog("PhotoSearch: indexing failed: \(error)")
        }
        progress = nil
        await engine.search.refreshPlaces()
        await refresh()
    }

    // MARK: - Search

    func refresh() async {
        guard phase == .ready else { return }
        let text = query
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await engine.search.search(text)
            guard text == query else { return }  // superseded by newer typing
            photos = results
            totalCount = await engine.indexer.count()
        } catch {
            NSLog("PhotoSearch: search failed: \(error)")
        }
    }

    func stop() {
        engine.stop()
    }

    // MARK: - Power users

    /// Opens Qdrant's web dashboard in the browser. The API key changes every
    /// launch, so it's put on the clipboard for the dashboard's key prompt.
    func openDashboard() {
        guard phase == .ready else {
            let alert = NSAlert()
            alert.messageText = "PhotoSearch is still starting"
            alert.informativeText = "Try again in a moment, once your photos are showing."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open the search database?"
        alert.informativeText = """
            This opens Qdrant's dashboard in your browser, where you can browse \
            the "photos" collection and run your own queries.

            Its API key has been copied to the clipboard. Paste it when the \
            dashboard asks for one. The key changes each time PhotoSearch starts.
            """
        alert.addButton(withTitle: "Open Dashboard")
        alert.addButton(withTitle: "Cancel")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.apiKey, forType: .string)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(engine.dashboardURL)
        }
    }

    var dashboardURL: URL? { phase == .ready ? engine.dashboardURL : nil }

    // MARK: - Viewer navigation

    func showNext(_ step: Int) {
        guard let current = viewing, let i = photos.firstIndex(of: current) else { return }
        let j = i + step
        if photos.indices.contains(j) { viewing = photos[j] }
    }
}

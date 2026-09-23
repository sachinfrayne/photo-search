import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Treat `kill`/logout-style SIGTERM like Quit so Qdrant shuts down cleanly.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source

        // Launched as a bare executable (swift run) there is no bundle to make
        // us a regular app, so ask for a Dock icon and focus explicitly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // SwiftUI can rebuild the menu bar, so (re)install the hidden item
        // whenever a menu is about to open.
        DispatchQueue.main.async { self.installDashboardItem() }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.installDashboardItem() }
    }

    private static let dashboardTag = 0x5153_4442  // "QSDB"
    static let showFolderTitle = "Show Photos Folder in Finder"

    /// Power-user escape hatch: holding Option in the File menu turns
    /// "Show Photos Folder in Finder" into "Open Search Database…". SwiftUI
    /// menus can't express alternates, so this one is added through AppKit.
    func installDashboardItem() {
        guard let fileMenu = NSApp.mainMenu?.items.compactMap(\.submenu)
                .first(where: { $0.items.contains { $0.title == Self.showFolderTitle } }),
              !fileMenu.items.contains(where: { $0.tag == Self.dashboardTag }),
              let index = fileMenu.items.firstIndex(where: { $0.title == Self.showFolderTitle }) else { return }
        let primary = fileMenu.items[index]
        let item = NSMenuItem(title: "Open Search Database…", action: #selector(openDashboard), keyEquivalent: primary.keyEquivalent)
        item.keyEquivalentModifierMask = primary.keyEquivalentModifierMask.union(.option)
        item.isAlternate = true
        item.target = self
        item.tag = Self.dashboardTag
        fileMenu.insertItem(item, at: index + 1)
    }

    @objc private func openDashboard() {
        MainActor.assumeIsolated { model?.openDashboard() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.stop() }
    }
}

struct PhotoSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("PhotoSearch") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 480)
                .onAppear {
                    delegate.model = model
                    DebugSnapshots.runIfRequested(model)
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Change Photos Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button(AppDelegate.showFolderTitle) {
                    if let url = model.libraryURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(model.libraryURL == nil)
            }
        }
    }
}

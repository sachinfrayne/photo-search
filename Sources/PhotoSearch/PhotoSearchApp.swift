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
                Button("Show Photos Folder in Finder") {
                    if let url = model.libraryURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(model.libraryURL == nil)
            }
        }
    }
}

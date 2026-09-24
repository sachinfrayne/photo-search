import AppKit
import SwiftUI

/// PhotoSearch › Settings…: choose which model the search uses.
struct SettingsView: View {
    @State private var models: [ModelManifest] = []
    @State private var selected = AppConfig.load().searchModel ?? ModelManifest.defaultID
    @State private var saved = AppConfig.load().searchModel ?? ModelManifest.defaultID

    var body: some View {
        Form {
            Section {
                Picker("Search model", selection: $selected) {
                    ForEach(models, id: \.id) { model in
                        Text(model.displayName + (model.id == ModelManifest.defaultID ? " (built in)" : ""))
                            .tag(model.id)
                    }
                }
                if let model = models.first(where: { $0.id == selected }) {
                    LabeledContent("Licence", value: model.license ?? "Unknown")
                    if let source = model.source, let url = URL(string: source) {
                        LabeledContent("Source") { Link(url.host ?? source, destination: url) }
                    }
                }
            } footer: {
                Text("Switching models re-reads your photos, which takes a little while for a large library.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Add your own model by putting its folder (with a model.json) in the Models folder.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Models Folder") { showModelsFolder() }
                }
            }

            HStack {
                Spacer()
                Button("Use This Model") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == saved)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { models = ModelManifest.discover() }
    }

    private func showModelsFolder() {
        try? FileManager.default.createDirectory(at: AppPaths.userModels, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppPaths.userModels)
        // Pick up anything added while the folder was open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { models = ModelManifest.discover() }
    }

    private func apply() {
        var config = AppConfig.load()
        config.searchModel = selected == ModelManifest.defaultID ? nil : selected
        do {
            try config.save()
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        saved = selected
        let alert = NSAlert()
        alert.messageText = "Restart PhotoSearch to switch models?"
        alert.informativeText = "PhotoSearch will reopen and re-read your photos with the new model."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { Self.relaunch() }
    }

    /// Opens a fresh copy of the app once this one has quit.
    static func relaunch() {
        let path = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.path : nil
        if let path {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"\(path)\""]
            try? task.run()
        }
        NSApp.terminate(nil)
    }
}

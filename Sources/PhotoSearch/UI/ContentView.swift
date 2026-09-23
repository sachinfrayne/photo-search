import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            switch model.phase {
            case .needsFolder:
                SetupView()
            case .starting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Getting your photos ready…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                FailureView(message: message)
            case .ready:
                LibraryView()
            }

            if let photo = model.viewing {
                PhotoViewer(photo: photo)
                    .transition(.opacity)
            }

            if dropTargeted && model.phase == .ready {
                DropOverlay()
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.viewing)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard model.phase == .ready || model.phase == .needsFolder else { return false }
            Task { await handleDrop(providers) }
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
               let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        if model.phase == .needsFolder {
            // During setup, dropping a folder picks it as the library.
            var isDir: ObjCBool = false
            if let first = urls.first, FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                model.useFolder(first)
            }
        } else {
            model.importDropped(urls)
        }
    }
}

// MARK: - Main screen

private struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.query)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            if model.photos.isEmpty {
                EmptyState()
            } else {
                PhotoGrid()
            }

            StatusBar()
        }
        .task(id: model.query) {
            // Small pause so we search once the user stops typing.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await model.refresh()
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.title3)
            TextField("Search your photos, e.g. “painting in a church” or “beach in Spain”", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
        .onAppear { focused = true }
    }
}

private struct PhotoGrid: View {
    @EnvironmentObject private var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 6)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(model.photos) { photo in
                    ThumbnailView(photo: photo)
                        .aspectRatio(1, contentMode: .fill)
                        .onTapGesture { model.viewing = photo }
                        .help(photo.url.lastPathComponent)
                }
            }
            .padding(12)
        }
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            if !model.query.isEmpty {
                Text("No photos match “\(model.query)”").font(.title3)
                Text("Try describing what's in the photo in a different way.").foregroundStyle(.secondary)
            } else if model.progress != nil {
                Text("Adding your photos…").font(.title3)
            } else {
                Text("No photos yet").font(.title3)
                Text("Drag photos onto this window, or put them in \(model.libraryURL?.lastPathComponent ?? "your photos folder").")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let progress = model.progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 140)
                Text(progress.total > 0 ? "Adding photos… \(progress.done) of \(progress.total)" : "Adding photos…")
            } else if model.query.isEmpty {
                Text(model.totalCount == 1 ? "1 photo" : "\(model.totalCount) photos")
            } else {
                Text("\(model.photos.count) of \(model.totalCount) photos")
            }
            Spacer()
            Text("Drop photos here to add them").foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Setup and errors

private struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Welcome to PhotoSearch").font(.largeTitle.weight(.semibold))
            Text("Find any photo by describing it: “church in Italy”, “dog on the beach”, “birthday cake”.\nEverything stays on this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                model.chooseFolder()
            } label: {
                Text("Choose Your Photos Folder").padding(.horizontal, 12).padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("New photos you add are tidied into Year › Month › Country folders.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    @EnvironmentObject private var model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("Something went wrong starting PhotoSearch").font(.title2)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
            Button("Try Again") { model.retry() }
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 48))
                Text("Drop to add to your photos").font(.title2)
                Text("They'll be copied in. Your originals stay where they are.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10])).padding(10))
        .allowsHitTesting(false)
    }
}

import AppKit
import SwiftUI

/// Full-size view of one photo, over the grid. ← / → step through the
/// current results, Esc (or clicking the backdrop) closes.
struct PhotoViewer: View {
    @EnvironmentObject private var model: AppModel
    let photo: Photo
    @State private var image: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @FocusState private var focused: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
                .onTapGesture { close() }

            if let image {
                GeometryReader { geo in
                    let scale = zoom * pinch
                    ScrollView([.horizontal, .vertical], showsIndicators: scale > 1) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                            .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2.5 } }
                    }
                    .scrollDisabled(scale <= 1)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { pinch = $0.magnification }
                            .onEnded { _ in zoom = min(max(zoom * pinch, 1), 6); pinch = 1 }
                    )
                }
                .padding(.vertical, 64)
                .padding(.horizontal, 72)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }

            VStack {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(photo.url.lastPathComponent).font(.caption).opacity(0.7)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button { NSWorkspace.shared.open(photo.url) } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.title3)
                    }
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Spacer()
                HStack {
                    NavButton(systemImage: "chevron.left") { model.showNext(-1) }
                    Spacer()
                    NavButton(systemImage: "chevron.right") { model.showNext(1) }
                }
                .padding(.horizontal, 12)
                Spacer()
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.showNext(-1); return .handled }
        .onKeyPress(.rightArrow) { model.showNext(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .task(id: photo.id) {
            zoom = 1
            image = nil
            let url = photo.url
            image = await Task.detached(priority: .userInitiated) {
                // Screen-sized, orientation-corrected; much faster than full-res decode.
                Indexer.thumbnail(url, maxPixels: 3200).map { NSImage(cgImage: $0, size: .zero) }
            }.value
        }
    }

    private var title: String {
        let place = [photo.city, photo.country].compactMap { $0 }.joined(separator: ", ")
        let date = photo.taken.map { Self.dateFormatter.string(from: $0) }
        return [date, place.isEmpty ? nil : place].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func close() {
        model.viewing = nil
    }
}

private struct NavButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

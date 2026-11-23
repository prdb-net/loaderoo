import ImageIO
import SwiftUI
import LoaderooCore

extension EnvironmentValues {
    @Entry var previewWindowSize = CGSize(width: 740, height: 450)
}

private struct GallerySource: Equatable {
    let url: URL
    var tile: CGSize?

    func load() async throws -> CGImage {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int else { throw URLError(.cannotDecodeContentData) }
        // Apply the file's orientation at its original resolution, independently of its print DPI.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        guard let tile else { return image }
        guard tile.width <= CGFloat(image.width), tile.height <= CGFloat(image.height),
              let frame = image.cropping(to: CGRect(origin: .zero, size: tile)) else {
            throw URLError(.cannotDecodeContentData)
        }
        return frame
    }
}

struct GalleryPreview: View {
    let title: String
    let urls: [URL]
    let sheet: PreviewSheet?
    @Binding var selected: URL?
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (source: GallerySource, image: CGImage)?
    @State private var failed: GallerySource?
    @State private var enlarged = false
    @State private var hovered = false

    private var index: Int { selected.flatMap { urls.firstIndex(of: $0) } ?? 0 }
    private var source: GallerySource? {
        if !urls.isEmpty { return GallerySource(url: urls[index]) }
        return sheet.map { GallerySource(url: $0.url, tile: CGSize(width: $0.tileWidth, height: $0.tileHeight)) }
    }
    private var image: CGImage? { loaded?.source == source ? loaded?.image : nil }

    var body: some View {
        Color.clear.aspectRatio(16/9, contentMode: .fit)
            .overlay {
                GeometryReader { area in
                    if let image {
                        let canEnlarge = CGFloat(image.width) > (area.size.width * displayScale).rounded()
                                      || CGFloat(image.height) > (area.size.height * displayScale).rounded()
                        if canEnlarge {
                            Button { enlarged = true } label: {
                                photo(image)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                                    .overlay(alignment: .bottomTrailing) {
                                        if hovered {
                                            Image(systemName: "plus.magnifyingglass").padding(6)
                                                .background(.regularMaterial, in: Circle()).padding(6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain).accessibilityLabel("Enlarge preview")
                            .help("Enlarge preview").onHover { hovered = $0 }
                        } else {
                            photo(image).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .task(id: source) {
                let requested = source
                loaded = nil
                failed = nil
                guard let requested else { return }
                do {
                    let bitmap = try await requested.load()
                    try Task.checkCancellation()
                    loaded = (requested, bitmap)
                } catch {
                    if !Task.isCancelled { failed = requested }
                }
            }
            .sheet(isPresented: $enlarged) { viewer }
    }

    private func photo(_ bitmap: CGImage) -> some View {
        Image(bitmap, scale: 1, label: Text(title)).resizable().scaledToFit()
    }

    @ViewBuilder private var placeholder: some View {
        if source == nil {
            Image(systemName: "film").foregroundStyle(.secondary).accessibilityLabel("Preview unavailable")
        } else if failed == source {
            Label("Preview failed to load", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small).accessibilityLabel("Loading preview")
        }
    }

    private var viewer: some View {
        PhotoDialog(title: title, urls: urls, selected: $selected) {
            GeometryReader { area in
                ZStack {
                    if let image {
                        photo(image)
                            .frame(width: min(area.size.width, CGFloat(image.width) / displayScale),
                                   height: min(area.size.height, CGFloat(image.height) / displayScale))
                    } else {
                        placeholder
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct PhotoDialog<Content: View>: View {
    let title: String
    let urls: [URL]
    @Binding var selected: URL?
    @ViewBuilder let content: () -> Content
    @Environment(\.previewWindowSize) private var windowSize
    @Environment(\.dismiss) private var dismiss
    private var index: Int { selected.flatMap { urls.firstIndex(of: $0) } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if urls.count > 1 {
                    Button("Previous image", systemImage: "chevron.left") { selected = urls[index - 1] }
                        .disabled(index == 0).keyboardShortcut(.leftArrow, modifiers: [])
                    Text("\(index + 1) / \(urls.count)").font(.callout).monospacedDigit()
                    Button("Next image", systemImage: "chevron.right") { selected = urls[index + 1] }
                        .disabled(index + 1 >= urls.count).keyboardShortcut(.rightArrow, modifiers: [])
                }
                Button("Close preview", systemImage: "xmark.circle.fill") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }.labelStyle(.iconOnly).buttonStyle(.borderless).padding(14)
            Divider()
            content().padding(12)
        }
        .frame(width: max(320, windowSize.width - 32), height: max(200, windowSize.height - 48))
    }
}

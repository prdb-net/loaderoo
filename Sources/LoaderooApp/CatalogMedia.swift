import SwiftUI
import LoaderooCore

struct CatalogArtwork: View {
    let title: FeedTitle
    let engine: LiveFeed?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var loaded: UserPreviews?

    var body: some View {
        let sheet = (title.userPreviews ?? loaded)?.sheet
        LiveArtwork(remote: title.preview)
            .overlay {
                if let sheet, hovered || title.preview == nil {
                    SheetPreview(sheet: sheet, playing: hovered && !reduceMotion)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
            .task(id: hovered) {
                guard hovered, title.userPreviews == nil else { return }
                do {
                    // Passing over a card on the way to another one needn't start a request.
                    try await Task.sleep(for: .milliseconds(150))
                    let result = try await engine?.catalogPreviews(for: title.id)
                    try Task.checkCancellation()
                    loaded = result
                } catch { /* Keep the poster when the optional preview is unavailable. */ }
            }
    }
}

private struct SheetPreview: View {
    let sheet: PreviewSheet
    let playing: Bool
    @State private var frame = 0

    var body: some View {
        AsyncImage(url: sheet.url) { phase in
            if let image = phase.image {
                Canvas { context, size in
                    let image = context.resolve(image)
                    let tile = CGSize(width: sheet.tileWidth, height: sheet.tileHeight)
                    let scale = min(size.width / tile.width, size.height / tile.height)
                    let width = tile.width * scale, height = tile.height * scale
                    let bounds = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                        width: width, height: height)
                    let index = playing ? frame % sheet.frames : 0
                    context.clip(to: Path(bounds))
                    context.draw(image, in: CGRect(
                        x: bounds.minX - CGFloat(index % sheet.columns) * width,
                        y: bounds.minY - CGFloat(index / sheet.columns) * height,
                        width: image.size.width * scale, height: image.size.height * scale))
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .task(id: playing) {
                    frame = 0
                    guard playing, sheet.frames > 1 else { return }
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .milliseconds(500))
                            frame = (frame + 1) % sheet.frames
                        }
                    } catch { }
                }
                .accessibilityLabel("Scene preview")
            }
        }
    }
}

struct CatalogGallery: View {
    let title: FeedTitle
    let engine: LiveFeed?
    @State private var loaded: UserPreviews?
    @State private var selected: URL?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        let previews = title.userPreviews ?? loaded
        var seen = Set<URL>()
        let images = (title.siteImages + (previews?.stills ?? []) + [title.preview].compactMap { $0 })
            .filter { seen.insert($0).inserted }
        let current = selected.flatMap { images.contains($0) ? $0 : nil } ?? images.first ?? title.preview
        VStack(alignment: .leading, spacing: 6) {
            GalleryPreview(title: title.title, urls: images, sheet: previews?.sheet, selected: $selected)
            if images.count > 1 {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 5) {
                        ForEach(Array(images.enumerated()), id: \.element) { index, url in
                            Button { selected = url } label: {
                                LiveArtwork(remote: url).frame(width: 50, height: 32)
                                    .overlay {
                                        if url == current {
                                            RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Preview \(index + 1) of \(images.count)")
                                .accessibilityAddTraits(url == current ? .isSelected : [])
                        }
                    }.padding(2)
                }.frame(height: 40)
            }
            if let error {
                HStack {
                    Text("Couldn’t load additional previews.").font(.caption)
                    Button("Retry") { attempt += 1 }.controlSize(.small)
                }.help(error)
            }
        }.task(id: attempt) {
            guard title.userPreviews == nil else { return }
            error = nil
            do {
                let result = try await engine?.catalogPreviews(for: title.id)
                try Task.checkCancellation()
                loaded = result
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

struct CatalogCast: View {
    let members: [CastMember]
    let openProfile: (CatalogSubject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Cast").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(members) { member in
                    Button { openProfile(CatalogSubject(actor: member)) } label: {
                        HStack(spacing: 6) {
                            AsyncImage(url: member.portrait) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                            }
                            .frame(width: 26, height: 26).background(.quaternary).clipShape(Circle())
                            .accessibilityHidden(true)
                            Text(member.name).font(.callout)
                        }
                    }.buttonStyle(.link)
                }
            }
        }
    }
}

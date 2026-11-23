import SwiftUI
import LoaderooCore

struct ActorGallerySelection: Identifiable {
    let id: UUID
    let name: String
    let cover: URL
    let photos: [URL]?

    init?(subject: CatalogSubject, photos: [URL]?) {
        guard case .actor(let id) = subject.id, let cover = photos?.first ?? subject.portrait else { return nil }
        self.id = id
        self.name = subject.name
        self.cover = cover
        self.photos = photos
    }
}

struct ActorPhotoDialog: View {
    let gallery: ActorGallerySelection
    let engine: LiveFeed?
    @State private var photos: [URL] = []
    @State private var selected: URL?
    @State private var loadError: String?
    @State private var attempt = 0

    private var urls: [URL] {
        let rest = gallery.photos ?? photos
        return [gallery.cover] + rest.filter { $0 != gallery.cover }
    }

    var body: some View {
        PhotoDialog(title: gallery.name, urls: urls, selected: $selected) {
            VStack(spacing: 6) {
                AsyncImage(url: selected ?? gallery.cover) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: ContentUnavailableView("Photo unavailable", systemImage: "photo")
                    default: ProgressView().accessibilityLabel("Loading photo")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let loadError {
                    HStack {
                        Text(loadError).foregroundStyle(.secondary)
                        Button("Retry actor photos") { attempt += 1 }
                    }.font(.caption)
                }
            }
        }.task(id: attempt) {
            guard gallery.photos == nil, let engine else { return }
            do {
                photos = try await engine.actorProfile(gallery.id).photoURLs
                loadError = nil
            } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
        }
    }
}

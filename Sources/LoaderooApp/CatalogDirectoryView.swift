import SwiftUI
import LoaderooCore

struct ProfileVisit: Identifiable {
    let id = UUID()
    let subject: CatalogSubject
    var openedVideo: UUID?
}

struct CatalogDirectoryView<Action: View>: View {
    let model: FeedWorkspace
    let kind: DirectoryKind
    @Binding var visit: ProfileVisit?
    let openProfile: (ProfileVisit) -> Void
    @ViewBuilder let download: (FeedTitle, FeedOffer?) -> Action
    @State private var query = ""
    @State private var visibleCount = 100
    private struct PhotoQuery: Equatable {
        let ids: [UUID]
        let attempt: Int
    }
    @State private var photoAttempt = 0
    @State private var photoError: String?
    @State private var actorPhotos: [UUID: [URL]] = [:]
    @State private var gallery: ActorGallerySelection?

    var body: some View {
        if let visit, visit.subject.kind == kind {
            SubjectProfileView(model: model, subject: visit.subject, openedVideo: visit.openedVideo, back: { self.visit = nil },
                               openProfile: openProfile, download: download).id(visit.id)
        } else {
            let all = kind == .actors ? model.actors : model.studios
            let entries = query.isEmpty ? all : all.filter { $0.subject.name.localizedStandardContains(query) }
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    WorkspaceSearchField(text: $query, prompt: "Search " + kind.rawValue.lowercased()) {}
                }.padding(.horizontal, 18).padding(.vertical, 9)
                Divider()
                if entries.isEmpty {
                    ContentUnavailableView("No matching " + kind.rawValue.lowercased(), systemImage: kind.symbol,
                                           description: Text("The PRDB directory updates in the background."))
                } else {
                    let visible = entries.prefix(visibleCount)
                    let ids = visible.compactMap { entry -> UUID? in
                        guard case .actor(let id) = entry.id, entry.subject.portrait == nil else { return nil }
                        return id
                    }
                    List(visible) { entry in
                        let subject = entry.subject
                        let photos: [URL]? = if case .actor(let id) = subject.id { actorPhotos[id] } else { nil }
                        let portrait = ActorGallerySelection(subject: subject, photos: photos)
                        HStack(spacing: 10) {
                            if let portrait {
                                Button { gallery = portrait } label: {
                                    SubjectPortrait(subject: subject, size: 56, url: portrait.cover)
                                }.buttonStyle(.plain).accessibilityLabel("View photos of " + subject.name)
                                    .help("View actor photos")
                            }
                            Button { openProfile(ProfileVisit(subject: subject)) } label: {
                                HStack(spacing: 10) {
                                    if portrait == nil { SubjectPortrait(subject: subject, size: kind == .actors ? 56 : 32) }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(subject.name).font(.headline)
                                        if let context = subject.context { Text(context).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Text(entry.count == 1 ? "1 available video" : "\(entry.count) available videos").foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }.padding(.vertical, 2)
                    }.listStyle(.inset)
                        .task(id: PhotoQuery(ids: ids, attempt: photoAttempt)) { await loadPhotos(for: ids) }
                    if let photoError {
                        HStack {
                            Text(photoError).font(.caption).foregroundStyle(.secondary)
                            Button("Retry actor photos") { photoAttempt += 1 }
                        }.padding(6)
                    }
                    if visibleCount < entries.count {
                        HStack {
                            Text("Showing \(visibleCount) of \(entries.count)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Show more") { visibleCount += 100 }
                        }.padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
                .onChange(of: query) { visibleCount = 100 }
                .sheet(item: $gallery) { ActorPhotoDialog(gallery: $0, engine: model.engine) }
        }
    }

    private func loadPhotos(for ids: [UUID]) async {
        photoError = nil
        let missing = ids.filter { actorPhotos[$0] == nil }
        guard !missing.isEmpty, let engine = model.engine else { return }
        do {
            try await Task.sleep(for: .milliseconds(200))
            for start in stride(from: 0, to: missing.count, by: 50) {
                try Task.checkCancellation()
                let images = try await engine.actorPhotos(for: Array(missing[start...].prefix(50)))
                try Task.checkCancellation()
                actorPhotos.merge(images) { _, latest in latest }
            }
        } catch {
            if !Task.isCancelled { photoError = error.localizedDescription }
        }
    }
}

extension DirectoryKind {
    var symbol: String { self == .actors ? "person.2" : "building.2" }
}

private struct SubjectPortrait: View {
    let subject: CatalogSubject
    let size: CGFloat
    var height: CGFloat?
    var url: URL?

    var body: some View {
        AsyncImage(url: url ?? subject.portrait) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { Image(systemName: subject.kind == .actors ? "person.fill" : "building.2").foregroundStyle(.secondary) }
        }.frame(width: size, height: height ?? size).background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: min(10, size / 5))).accessibilityHidden(true)
    }
}

private struct SubjectProfileView<Action: View>: View {
    let model: FeedWorkspace
    let subject: CatalogSubject
    let openedVideo: UUID?
    let back: () -> Void
    let openProfile: (ProfileVisit) -> Void
    @ViewBuilder let download: (FeedTitle, FeedOffer?) -> Action
    private static var pageSize: Int { 20 }
    @State private var limit = Self.pageSize
    @State private var selected: UUID?
    @State private var searching = false
    @State private var cursor: IndexerSearch?
    @State private var gallery: ActorGallerySelection?
    @State private var actor: ActorProfile?
    @State private var actorError: String?
    @State private var attempt = 0

    var body: some View {
        let videos = subject.releases(in: model.page, prioritizing: openedVideo)
        let visible = videos.prefix(limit)
        let remaining = videos.count - visible.count
        VStack(alignment: .leading, spacing: 0) {
            Button("All " + subject.kind.rawValue.lowercased(), systemImage: "chevron.left", action: back)
                .buttonStyle(.link).padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        if subject.kind == .actors {
                            let portrait = ActorGallerySelection(subject: subject, photos: actor?.photoURLs)
                            if let portrait {
                                Button { gallery = portrait } label: {
                                    SubjectPortrait(subject: subject, size: 120, height: 150, url: portrait.cover)
                                        .overlay(alignment: .bottomTrailing) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus.magnifyingglass")
                                                if let count = portrait.photos?.count, count > 1 { Text("\(count)") }
                                            }.font(.caption.weight(.semibold)).padding(5)
                                                .background(.regularMaterial, in: Capsule()).padding(6)
                                        }
                                }.buttonStyle(.plain).accessibilityLabel("View photos of " + subject.name)
                                    .help("View actor photos")
                            } else { SubjectPortrait(subject: subject, size: 120, height: 150) }
                        } else { SubjectPortrait(subject: subject, size: 64) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(actor?.name ?? subject.name).font(.title.bold()).textSelection(.enabled)
                            if let context = subject.context { Text(context).foregroundStyle(.secondary) }
                            if let actor {
                                if let country = actor.nationalityLabel { Text(country) }
                                if let birthplace = actor.birthplace { Text("Born in " + birthplace) }
                                if let start = actor.careerStart {
                                    Text(actor.careerEnd.map { "Career: \(start)–\($0)" } ?? "Career since \(start)")
                                }
                                let aliases = (actor.aliases ?? []).map(\.name).filter { $0 != actor.name }
                                if !aliases.isEmpty { Text("Also known as " + aliases.joined(separator: ", ")).foregroundStyle(.secondary) }
                            }
                            if let actorError {
                                Text(actorError).font(.caption).foregroundStyle(.secondary)
                                Button("Retry actor details") { attempt += 1 }.controlSize(.small)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("Available videos").font(.headline)
                        Spacer()
                        Text(remaining > 0 ? "Showing \(visible.count) of \(videos.count)" : "\(videos.count)")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if videos.isEmpty {
                        Text("No matching NZB offers in the catalog.").foregroundStyle(.secondary)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { video in
                            HStack {
                                Button { selected = video.id } label: {
                                    HStack(spacing: 10) {
                                        CatalogArtwork(title: video, engine: model.engine).frame(width: 76, height: 45)
                                        VStack(alignment: .leading, spacing: 3) {
                                            if video.id == openedVideo {
                                                Label("Opened release", systemImage: "pin.fill")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Text(video.title).font(.headline).lineLimit(2)
                                            Text([video.posted.map { "NZB posted " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "NZB posting date unknown",
                                                  video.qualities.joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                download(video, nil).controlSize(.small)
                            }.padding(.vertical, 6)
                            Divider()
                        }
                    }
                    if remaining > 0 {
                        let nextCount = min(Self.pageSize, remaining)
                        Button(nextCount == 1 ? "Show 1 more video" : "Show \(nextCount) more videos") {
                            limit += Self.pageSize
                        }
                    } else if cursor?.hasMore != false {
                        Button(cursor == nil ? "Search indexers for more videos" : "Load more indexer results") {
                            Task {
                                searching = true
                                defer { searching = false }
                                if let next = await model.refresh(search: cursor ?? IndexerSearch(term: subject.name), forCatalog: false) {
                                    cursor = next
                                    limit = max(limit, visible.count + Self.pageSize)
                                }
                            }
                        }.disabled(model.loading || searching)
                        if searching { ProgressView("Searching indexers…").controlSize(.small) }
                    } else {
                        Text("No more indexer results").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .trailing) {
                if let selected, let video = videos.first(where: { $0.id == selected }) {
                    DetailPanel(title: "Release details", close: { self.selected = nil }) {
                        CatalogDetail(title: video, engine: model.engine, openProfile: { target in
                            self.selected = nil
                            openProfile(target)
                        }, hasDownload: model.activeJob(for: video) != nil) { offer in download(video, offer) }
                    }.id(video.id)
                }
            }
            .sheet(item: $gallery) { ActorPhotoDialog(gallery: $0, engine: model.engine) }
            .task(id: attempt) {
                guard case .actor(let id) = subject.id else { return }
                actorError = nil
                do { actor = try await model.engine?.actorProfile(id) }
                catch { if !Task.isCancelled { actorError = error.localizedDescription } }
            }
    }
}

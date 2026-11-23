import SwiftUI
import LoaderooCore

struct CatalogDirectoryView<Action: View>: View {
    let model: FeedWorkspace
    let kind: DirectoryKind
    @Binding var subject: CatalogSubject?
    let openProfile: (CatalogSubject) -> Void
    @ViewBuilder let download: (FeedTitle, FeedOffer?) -> Action
    @State private var query = ""

    var body: some View {
        if let subject, subject.kind == kind {
            SubjectProfileView(model: model, subject: subject, back: { self.subject = nil },
                               openProfile: openProfile, download: download).id(subject.id)
        } else {
            let entries = (kind == .actors ? model.actors : model.studios)
                .filter { query.isEmpty || $0.subject.name.localizedStandardContains(query) }
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    WorkspaceSearchField(text: $query, prompt: "Search " + kind.rawValue.lowercased()) {}
                }.padding(.horizontal, 18).padding(.vertical, 9)
                Divider()
                if entries.isEmpty {
                    ContentUnavailableView("No matching " + kind.rawValue.lowercased(), systemImage: kind.symbol,
                                           description: Text("Available titles with confirmed NZB offers appear here."))
                } else {
                    List(entries) { entry in
                        Button { openProfile(entry.subject) } label: {
                            HStack(spacing: 10) {
                                SubjectPortrait(subject: entry.subject, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.subject.name).font(.headline)
                                    if let context = entry.subject.context { Text(context).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(entry.count == 1 ? "1 video" : "\(entry.count) videos").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle()).padding(.vertical, 2)
                        }.buttonStyle(.plain)
                    }.listStyle(.inset)
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

extension DirectoryKind {
    var symbol: String { self == .actors ? "person.2" : "building.2" }
}

private struct SubjectPortrait: View {
    let subject: CatalogSubject
    let size: CGFloat

    var body: some View {
        AsyncImage(url: subject.portrait) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { Image(systemName: subject.kind == .actors ? "person.fill" : "building.2").foregroundStyle(.secondary) }
        }.frame(width: size, height: size).background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: size / 5)).accessibilityHidden(true)
    }
}

private struct SubjectProfileView<Action: View>: View {
    let model: FeedWorkspace
    let subject: CatalogSubject
    let back: () -> Void
    let openProfile: (CatalogSubject) -> Void
    @ViewBuilder let download: (FeedTitle, FeedOffer?) -> Action
    @State private var days: Int? = 90
    @State private var selected: UUID?
    @State private var searching = false
    @State private var cursor: IndexerSearch?
    @State private var actor: ActorProfile?
    @State private var actorError: String?
    @State private var attempt = 0

    var body: some View {
        let videos = subject.releases(in: model.page, days: days)
        VStack(alignment: .leading, spacing: 0) {
            Button("All " + subject.kind.rawValue.lowercased(), systemImage: "chevron.left", action: back)
                .buttonStyle(.link).padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        SubjectPortrait(subject: subject, size: 64)
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
                        Text("Available videos (\(videos.count))").font(.headline)
                        Spacer()
                        Picker("Released", selection: $days) {
                            ForEach([90, 180, 365], id: \.self) { Text("Last \($0) days").tag(Optional($0)) }
                            Text("Any time").tag(nil as Int?)
                        }.fixedSize()
                    }
                    if videos.isEmpty {
                        Text("No matching NZB offers for this period.").foregroundStyle(.secondary)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(videos) { video in
                            HStack {
                                Button { selected = video.id } label: {
                                    HStack(spacing: 10) {
                                        CatalogArtwork(title: video, engine: model.engine).frame(width: 76, height: 45)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(video.title).font(.headline).lineLimit(2)
                                            Text([video.releaseDate.map { $0.formatted(Self.dateStyle) } ?? "Release date unknown",
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
                    if cursor?.hasMore != false {
                        Button(cursor == nil ? "Search indexers for more videos" : "Load more indexer results") {
                            Task {
                                searching = true
                                defer { searching = false }
                                if let next = await model.refresh(search: cursor ?? IndexerSearch(term: subject.name), forCatalog: false) {
                                    cursor = next
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
            .task(id: attempt) {
                guard case .actor(let id) = subject.id else { return }
                actorError = nil
                do { actor = try await model.engine?.actorProfile(id) }
                catch { if !Task.isCancelled { actorError = error.localizedDescription } }
            }
    }

    private static var dateStyle: Date.FormatStyle { Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt) }
}

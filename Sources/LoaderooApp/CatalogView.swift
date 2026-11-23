import SwiftUI
import LoaderooCore

struct CatalogView<Controls: View, Action: View>: View {
    let model: FeedWorkspace
    let openProfile: (CatalogSubject) -> Void
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let download: (FeedTitle, FeedOffer?) -> Action
    @AppStorage("catalogListLayout") private var listLayout = false
    @AppStorage("catalogOnlyWithPreview") private var onlyWithPreview = true
    @State private var filtering = false
    private var filter: CatalogFilter { model.catalogFilter }
    private var selected: UUID? {
        get { model.selectedRelease }
        nonmutating set { model.selectedRelease = newValue }
    }
    @State private var scrollAnchor: UUID?

    private var query: String { model.catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var more: Bool {
        if let search = model.indexerSearch { return search.hasMore }
        return query.isEmpty && model.page.hasEarlier
    }

    var body: some View {
        let titles = filter.titles(in: model.page, matching: query, search: model.indexerSearch,
                                   onlyWithPreview: onlyWithPreview)
        let detail = selected.flatMap { id in titles.first { $0.id == id } }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                controls()
                ViewThatFits(in: .horizontal) {
                    toolbar(compact: false)
                    toolbar(compact: true)
                }
            }.padding(.horizontal, 18).padding(.vertical, 9)
            Divider()
            results(titles)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    if let detail {
                        DetailPanel(title: "Release details", close: { selected = nil }) {
                            CatalogDetail(title: detail, engine: model.engine, openProfile: openProfile, hasDownload: model.activeJob(for: detail) != nil) { offer in
                                download(detail, offer)
                            }
                        }.id(detail.id)
                    }
                }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { status(titles.count); Spacer(); paging }
                VStack(alignment: .leading, spacing: 5) { status(titles.count); paging }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .sheet(isPresented: $filtering) {
            CatalogFilterDialog(model: model, draft: filter, onlyWithPreview: onlyWithPreview) { draft, previews in
                model.catalogFilter = draft
                onlyWithPreview = previews
            }
        }
    }

    @ViewBuilder private func results(_ titles: [FeedTitle]) -> some View {
        if titles.isEmpty {
            let hiddenByPreview = onlyWithPreview && !filter.titles(in: model.page, matching: query,
                search: model.indexerSearch, onlyWithPreview: false).isEmpty
            ContentUnavailableView {
                Label(hiddenByPreview ? "No matching titles with previews" :
                        query.isEmpty && filter == CatalogFilter() ? "No available titles" : "No matching titles",
                      systemImage: "rectangle.stack")
            } description: {
                if !hiddenByPreview {
                    Text(!query.isEmpty && model.indexerSearch == nil ? "Search your indexers to include older releases." :
                            "Confirmed videos missing from your library appear here.")
                }
            } actions: {
                if hiddenByPreview {
                    Button("Include titles without previews") { onlyWithPreview = false }
                }
            }.frame(maxHeight: .infinity)
        } else {
            let column = GridItem(listLayout ? .flexible() : .adaptive(minimum: 192), spacing: 16, alignment: .top)
            ScrollView {
                LazyVGrid(columns: [column], alignment: .leading, spacing: listLayout ? 0 : 22) {
                    ForEach(titles) { title in
                        entry(title)
                            .id(title.id)
                            .onAppear {
                                if title.id == titles.last?.id { loadMore() }
                            }
                    }
                }.scrollTargetLayout().padding(listLayout ? 12 : 18)
            }.scrollPosition(id: $scrollAnchor, anchor: .top)
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 10) {
            let count = [onlyWithPreview, !filter.studioIDs.isEmpty, !filter.actorIDs.isEmpty,
                         filter.quality != nil, filter.indexer != nil, filter.days != nil].filter { $0 }.count
            Button(count == 0 ? "Filters" : "Filters (\(count))", systemImage: "line.3.horizontal.decrease.circle") {
                filtering = true
            }.fixedSize()
            if !compact && filter != CatalogFilter() {
                Button("Clear filters", action: clearFilters).buttonStyle(.link).fixedSize()
            }
            if !query.isEmpty {
                Button {
                    let search = IndexerSearch(term: query)
                    Task { await model.refresh(search: search) }
                } label: {
                    if compact { Image(systemName: "antenna.radiowaves.left.and.right") }
                    else { Label("Search indexers", systemImage: "antenna.radiowaves.left.and.right") }
                }.accessibilityLabel("Search indexers").help("Search indexers").disabled(model.loading).fixedSize()
            }
            Picker("Layout", selection: $listLayout) {
                Image(systemName: "square.grid.2x2").accessibilityLabel("Grid").tag(false)
                Image(systemName: "list.bullet").accessibilityLabel("Compact list").tag(true)
            }.labelsHidden().pickerStyle(.segmented).fixedSize().help("Catalog layout")
        }
    }

    private func clearFilters() {
        model.catalogFilter = CatalogFilter()
        onlyWithPreview = false
    }

    private func status(_ count: Int) -> some View {
        let extent = model.page.oldestBrowsed.map { "Browsed to " + $0.formatted(date: .abbreviated, time: .omitted) }
            ?? "\(model.page.releaseCount) releases loaded"
        let matches = count == model.page.titles.count ? "\(count) titles" : "\(count) of \(model.page.titles.count) titles"
        let parts = [matches, "\(model.page.pending) awaiting a match", extent]
        return Text(parts.joined(separator: "  ·  ")).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var paging: some View {
        if more {
            Button(model.indexerSearch == nil ? "Load earlier uploads" : "More search results", action: loadMore)
                .disabled(model.loading)
        } else if let search = model.indexerSearch {
            Text("\(search.offerIDs.count) indexer results")
        }
    }

    private func loadMore() {
        guard more, !model.loading else { return }
        let search = model.indexerSearch
        Task { await model.refresh(earlier: search == nil, search: search) }
    }

    @ViewBuilder private func entry(_ title: FeedTitle) -> some View {
        if listLayout {
            HStack(spacing: 12) {
                Button { selected = title.id } label: {
                    HStack(spacing: 12) {
                        CatalogArtwork(title: title, engine: model.engine).frame(width: 64, height: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title.title).font(.headline).lineLimit(1)
                            Text(metadata(title)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                download(title, nil).controlSize(.small)
            }.padding(6).background(selectionColor(title), in: RoundedRectangle(cornerRadius: 6))
            Divider()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button { selected = title.id } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        CatalogArtwork(title: title, engine: model.engine).aspectRatio(16/9, contentMode: .fit)
                            .overlay { RoundedRectangle(cornerRadius: 7).stroke(selectionColor(title), lineWidth: 3) }
                        // Measure two actual headline lines so every card gets the same title height.
                        Text(verbatim: "\n").hidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .topLeading) {
                                Text(title.title).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .font(.headline).help(title.title)
                        if let studio = title.studio, !studio.isEmpty {
                            Text(studio).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(verbatim: " ").hidden()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text([date(title), title.qualities.joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1, reservesSpace: true)
                download(title, nil).controlSize(.small)
            }
        }
    }

    private func selectionColor(_ title: FeedTitle) -> Color {
        selected == title.id ? Color.accentColor.opacity(listLayout ? 0.16 : 0.9) : .clear
    }

    private func date(_ title: FeedTitle) -> String {
        title.posted?.formatted(date: .abbreviated, time: .omitted) ?? "Posting date unknown"
    }

    private func metadata(_ title: FeedTitle) -> String {
        ([title.studio, date(title)] + title.qualities).compactMap { $0 }.joined(separator: "  ·  ")
    }
}

struct CatalogDetail<Action: View>: View {
    let title: FeedTitle
    let engine: LiveFeed?
    let openProfile: (CatalogSubject) -> Void
    let hasDownload: Bool
    @ViewBuilder let action: (FeedOffer?) -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CatalogGallery(title: title, engine: engine)
            Text(title.title).font(.title2.bold()).textSelection(.enabled)
            if let studio = CatalogSubject(studioOf: title) {
                Button(studio.name) { openProfile(studio) }.buttonStyle(.link)
            }
            if !title.cast.isEmpty { CatalogCast(members: title.cast, openProfile: openProfile) }
            if hasDownload { action(nil) }
            Divider()
            Text("Usenet releases (\(title.offers.count))").font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(title.offers) { offer in
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(offer.quality ?? "—")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 62, alignment: .leading)
                                .accessibilityLabel(offer.quality ?? "Quality unknown")
                            let size = offer.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                            Text(size ?? "—")
                                .font(.body.weight(.medium)).monospacedDigit()
                                .frame(width: 86, alignment: .trailing)
                                .accessibilityLabel(size ?? "Size unknown")
                            Spacer(minLength: 0)
                            if !hasDownload { action(offer).controlSize(.small) }
                        }
                        Text(offer.name).lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundStyle(.secondary).help(offer.name).textSelection(.enabled)
                        Text([offer.source, offer.posted?.formatted(date: .abbreviated, time: .omitted)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.vertical, 8)
                }
            }
        }
    }
}

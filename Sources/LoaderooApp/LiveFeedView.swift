import AVFoundation
import SwiftUI
import LoaderooCore

struct LiveFeedView: View {
    let openDemo: () -> Void
    @State private var model = FeedWorkspace()
    @State private var selection: SectionName? = .releases
    @State private var editing = false
    @State private var sabTab = false
    @State private var detail: FeedTitle?
    @State private var search = ""
    @State private var manageFolders = false

    var body: some View {
        NavigationSplitView {
            List(SectionName.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .badge(count(section)).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 148, ideal: 172, max: 230)
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                Button { settings() } label: { Label("Connections", systemImage: "gearshape") }
                    .buttonStyle(.plain).padding(16)
            }
        } detail: {
            VStack(spacing: 0) {
                let issues = [model.error, model.downloadIssue].compactMap { $0 } + model.page.issues
                if !issues.isEmpty {
                    Text(issues.joined(separator: "\n")).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(.quaternary)
                }
                if !model.ready {
                    if model.error == nil { ProgressView("Opening library…") }
                    else { Button("Retry") { Task { await model.open() } } }
                } else if model.config == nil {
                    ContentUnavailableView {
                        Label("Connect your indexers", systemImage: "antenna.radiowaves.left.and.right")
                    } description: { Text("Use your PRDB key and Newznab indexers to find recent uploads.") }
                    actions: {
                        Button("Set Up Connections…") { settings() }.buttonStyle(.borderedProminent)
                        Button("Open Local Demo", action: openDemo)
                    }
                } else {
                    switch selection ?? .releases {
                    case .releases:
                        feed
                        HStack {
                            Text("\(model.page.titles.count) available · \(model.page.pending) awaiting a match").foregroundStyle(.secondary)
                            Spacer()
                            if model.page.hasEarlier {
                                Button("Load Earlier Uploads") { Task { await model.refresh(earlier: true) } }.disabled(model.loading)
                            }
                        }.font(.callout).padding(.horizontal,20).padding(.vertical,8).background(.bar)
                    case .library: library
                    case .downloads: downloads
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((selection ?? .releases).rawValue)
            .toolbar {
                if model.config != nil {
                    if model.loading || model.scanning { ProgressView().controlSize(.small) }
                    if selection == .library {
                        Button("Manage Folders", systemImage: "folder.badge.gearshape") { manageFolders = true }
                        Button("Scan Library", systemImage: "arrow.clockwise") { Task { await model.scan() } }.disabled(model.scanning)
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { if selection == .downloads { await model.follow() } else { await model.refresh(manual: true) } }
                        }.disabled(model.loading)
                    }
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search titles or studios")
        }
        .frame(minWidth: 740, minHeight: 450)
        .sheet(isPresented: $editing) {
            ConnectionsForm(downloadSettings: sabTab, draft: model.config ?? FeedConnections()) { config, verifySAB in
                try await model.save(config, verifySAB: verifySAB)
                editing = false
                Task { await model.refresh(manual: true) }
            }
        }
        .sheet(item: $detail) { title in
            VStack(alignment: .leading, spacing: 12) {
                LiveArtwork(remote: title.preview).aspectRatio(16/9, contentMode: .fit)
                Text(title.title).font(.title.bold()).textSelection(.enabled)
                if let studio = title.studio { Text(studio).font(.title3) }
                LabeledContent("Usenet upload", value: title.posted?.formatted() ?? "Unknown")
                LabeledContent("Indexers", value: title.sources.joined(separator: ", "))
                if !title.qualities.isEmpty { LabeledContent("Quality", value: title.qualities.joined(separator: ", ")) }
                DisclosureGroup("Usenet releases (\(title.offers.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(title.offers) { offer in
                                Text(offer.name).font(.callout).textSelection(.enabled)
                                Text([offer.source, offer.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
                                    .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity,alignment: .leading)
                    }.frame(maxHeight: 100)
                }
                Divider()
                HStack { Button("Done") { detail = nil }.keyboardShortcut(.cancelAction); Spacer(); downloadButton(title) }
            }.padding(24).frame(width: 520)
        }
        .sheet(isPresented: $manageFolders) { folderSheet }
        .task {
            await model.open()
            await model.follow()
            if !model.folders.isEmpty { await model.scan() }
        }
        .task {
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
                tick += 1
                if model.jobs.contains(where: { !$0.retryable && $0.state != "Completed" || $0.state == "Completed" && $0.studio == nil && tick.isMultiple(of: 90) }) { await model.follow() }
                if tick.isMultiple(of: 6), !editing { await model.refresh() }
                if tick.isMultiple(of: 8640), !model.folders.isEmpty { await model.scan() }
            }
        }
    }

    private func settings(sab: Bool = false) { sabTab = sab; detail = nil; editing = true }
    private func count(_ section: SectionName) -> Int {
        switch section {
        case .releases: model.page.titles.count
        case .library: model.files.count + filed.count
        case .downloads: model.jobs.count
        }
    }
    private var filed: [Transfer] {
        let paths = Set(model.files.map(\.path))
        return model.jobs.filter { $0.state == "Completed" && !paths.contains($0.localPath ?? "") }
    }
    private func includes(_ parts: String?...) -> Bool {
        search.isEmpty || parts.compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
    }

    @ViewBuilder private func downloadButton(_ title: FeedTitle) -> some View {
        if let job = model.jobs.first(where: { $0.video == title.id.uuidString }), !job.retryable {
            Button("View Download") { detail = nil; selection = .downloads }
        } else {
            Button {
                if model.config?.sab == nil { settings(sab: true) }
                else { Task { await model.download(title) } }
            } label: { Label("Download", systemImage: "arrow.down.to.line") }
            .disabled(model.sending.contains(title.id))
        }
    }

    private var feed: some View {
        let titles = model.page.titles.filter { includes($0.title,$0.studio,$0.sources.joined(separator: " ")) }
        return Group {
            if titles.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No new matched uploads" : "No matching titles", systemImage: "rectangle.stack",
                                       description: Text(search.isEmpty ? "\(model.page.pending) uploads await another PRDB check." : "Try another title or studio."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(titles) { title in
                            HStack(spacing: 16) {
                                Button { detail = title } label: {
                                    LiveArtwork(remote: title.preview).frame(width: 148,height: 84)
                                }.buttonStyle(.plain).accessibilityLabel("Details for " + title.title)
                                VStack(alignment: .leading, spacing: 5) {
                                    Button { detail = title } label: {
                                        Text(title.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                                    }.buttonStyle(.plain)
                                    if let studio = title.studio { Text(studio).foregroundStyle(.secondary) }
                                    let metadata: [String?] = [title.posted?.formatted(date: .abbreviated,time: .omitted),
                                                    title.qualities.joined(separator: " · "),title.sources.joined(separator: ", ")]
                                    Text(metadata.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                downloadButton(title)
                            }.padding(.vertical,12)
                            Divider()
                        }
                    }.padding(.horizontal,20)
                }
            }
        }
    }

    @ViewBuilder private var library: some View {
        let files = model.files.filter { includes($0.title,$0.path,$0.studio) }
        let jobs = filed.filter { includes($0.title,$0.studio) }
        if files.isEmpty && jobs.isEmpty {
            ContentUnavailableView {
                Label(search.isEmpty ? "Your video library" : "No matching files", systemImage: "film.stack")
            } description: { Text("Choose folders to identify existing videos and hide them from recent uploads.") }
            actions: { Button("Choose Folders…") { manageFolders = true } }
        } else {
            List {
                ForEach(files) { file in
                    mediaRow(file.title ?? file.url.lastPathComponent, path: file.path, studio: file.studio,
                             image: file.image, offline: file.offline, identified: file.video != nil)
                }
                ForEach(jobs) { job in
                    mediaRow(job.title, path: job.localPath ?? "", studio: job.studio, image: job.image, offline: false, identified: true)
                }
            }.listStyle(.inset)
        }
    }

    private func mediaRow(_ name: String, path: String, studio: String?, image: String?, offline: Bool, identified: Bool) -> some View {
        HStack(spacing: 12) {
            LiveArtwork(remote: image.flatMap(URL.init(string:)), local: offline ? nil : URL(filePath: path)).frame(width: 112,height: 63)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(offline ? "Folder unavailable" : studio ?? (identified ? "Matched to PRDB" : "Unmatched")).foregroundStyle(.secondary)
                Text(path).font(.caption).lineLimit(1).truncationMode(.middle).help(path)
            }
            Spacer()
            Button("Show in Finder",systemImage: "folder") { reveal(path) }.labelStyle(.iconOnly).disabled(offline)
        }.padding(.vertical,5)
    }
    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }

    @ViewBuilder private var downloads: some View {
        let jobs = model.jobs.filter { includes($0.title,$0.studio,$0.provider) }
        if jobs.isEmpty {
            ContentUnavailableView("No downloads here", systemImage: "arrow.down.circle", description: Text("Choose Download next to a title in Recent uploads."))
        } else {
            List(jobs) { job in
                HStack(alignment: .top, spacing: 12) {
                    LiveArtwork(remote: job.image.flatMap(URL.init(string:))).frame(width: 112,height: 63)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.title).font(.headline)
                        Text([job.state, job.provider].joined(separator: " · ")).foregroundStyle(.secondary)
                        if let release = job.releaseName { Text(release).font(.caption).lineLimit(2).textSelection(.enabled) }
                        if let note = job.note { Text(note).font(.callout) }
                        if let path = job.localPath ?? job.storage { Text(path).font(.caption).textSelection(.enabled) }
                    }
                    Spacer()
                    if let path = job.localPath { Button("Show in Finder") { reveal(path) } }
                    if job.retryable, let title = model.page.titles.first(where: { $0.id.uuidString == job.video }) { downloadButton(title) }
                }.padding(.vertical,5)
            }
        }
    }

    private var folderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Library folders").font(.title2.bold())
            List(model.folders) { folder in
                HStack {
                    Label(folder.path, systemImage: folder.offline ? "externaldrive.badge.exclamationmark" : "folder")
                    Spacer()
                    Button("Remove",systemImage: "minus.circle") {
                        Task {
                            do { try await model.engine?.removeFolder(folder.path); try await model.reload() }
                            catch { model.error = error.localizedDescription }
                        }
                    }.labelStyle(.iconOnly).disabled(model.scanning)
                }
            }
            HStack {
                Button("Add Folder…", systemImage: "plus") {
                    if let url = chooseFolder() { Task { await model.scan(adding: url) } }
                }.disabled(model.scanning)
                if model.scanning { ProgressView().controlSize(.small); Text("Scanning…") }
                Spacer()
                Button("Done") { manageFolders = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500,height: 320)
    }
}

struct LiveArtwork: View {
    let remote: URL?
    var local: URL?
    @State private var still: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(.quaternary)
            AsyncImage(url: remote) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else if let still { Image(nsImage: still).resizable().scaledToFit() }
                else { Image(systemName: "film").font(.title2).foregroundStyle(.tertiary).accessibilityLabel("Preview unavailable") }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: local) {
            still = nil
            guard remote == nil, let local else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: local))
            generator.maximumSize = CGSize(width: 320,height: 180)
            generator.appliesPreferredTrackTransform = true
            if let frame = try? await generator.image(at: .zero), !Task.isCancelled {
                still = NSImage(cgImage: frame.image,size: .zero)
            }
        }
    }
}

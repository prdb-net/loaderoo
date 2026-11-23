import AVFoundation
import SwiftUI
import LoaderooCore

private enum LiveSection: String, CaseIterable, Identifiable {
    case releases = "Catalog", studios = "Studios", actors = "Actors", downloads = "Downloads", library = "Library"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .studios: DirectoryKind.studios.symbol
        case .actors: DirectoryKind.actors.symbol
        case .downloads: SectionName.downloads.symbol
        case .library: SectionName.library.symbol
        case .releases: SectionName.releases.symbol
        }
    }
}

struct LiveFeedView: View {
    let openDemo: () -> Void
    @State private var model = FeedWorkspace()
    @State private var selection: LiveSection = .releases
    @State private var subject: CatalogSubject?
    @State private var editing = false
    @State private var sabTab = false
    @State private var downloadSelection: String?
    @State private var downloadQuery = ""
    @State private var search = ""
    @State private var manageFolders = false
    @State private var windowSize = CGSize(width: 740, height: 450)

    var body: some View {
        NavigationSplitView {
            List(LiveSection.allCases, selection: Binding(get: { selection }, set: {
                subject = nil
                selection = $0
            })) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .badge(count(section)).tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                Button("Connections", systemImage: "gearshape") { settings() }
                    .buttonStyle(.plain).padding(16)
            }
        } detail: {
            workspace
        }
        .frame(minWidth: 740, minHeight: 450)
        .environment(\.previewWindowSize, windowSize)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        .sheet(isPresented: $editing) {
            ConnectionsForm(downloadSettings: sabTab, draft: model.config ?? FeedConnections()) { config, verifySAB in
                try await model.save(config, verifySAB: verifySAB)
                editing = false
                Task { await model.refresh(manual: true) }
            }
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

    private var workspace: some View {
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
                switch selection {
                case .releases:
                    CatalogView(model: model, openProfile: openProfile, controls: { searchControls }, download: downloadButton)
                case .actors, .studios:
                    CatalogDirectoryView(model: model, kind: selection == .actors ? .actors : .studios, subject: $subject,
                                         openProfile: openProfile, download: downloadButton).id(selection)
                case .library:
                    HStack {
                        Button("Manage Folders", systemImage: "folder.badge.gearshape") { manageFolders = true }
                        Spacer()
                        searchControls
                    }.padding(.horizontal, 18).padding(.vertical, 9)
                    Divider()
                    library.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .downloads:
                    DownloadsView(model: model, query: downloadQuery, selection: $downloadSelection, controls: { searchControls }) { title in
                        downloadButton(title, nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .navigationTitle(selection == .releases ? "Release catalog" : selection.rawValue)
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            WorkspaceSearchField(text: searchBinding, prompt: searchPrompt) {
                guard selection == .releases else { return }
                let search = IndexerSearch(term: model.catalogQuery)
                if !search.term.isEmpty { Task { await model.refresh(search: search) } }
            }
            Button {
                Task {
                    switch selection {
                    case .downloads: await model.follow()
                    case .library: await model.scan()
                    case .releases, .actors, .studios: await model.refresh(manual: true)
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(refreshing ? 0 : 1)
                    .overlay { if refreshing { ProgressView().controlSize(.small) } }
            }
            .accessibilityLabel(selection == .library ? "Scan Library" : "Refresh")
            .help(selection == .library ? "Scan Library" : "Refresh")
            .disabled(refreshing)
        }
    }

    private var refreshing: Bool {
        switch selection {
        case .releases, .actors, .studios: model.loading
        case .downloads: model.following
        case .library: model.scanning
        }
    }

    private func settings(sab: Bool = false) { sabTab = sab; editing = true }
    private func openProfile(_ target: CatalogSubject) {
        selection = target.kind == .actors ? .actors : .studios
        subject = target
    }

    private func count(_ section: LiveSection) -> Int {
        switch section {
        case .actors: model.actors.count
        case .studios: model.studios.count
        case .releases: model.page.titles.count
        case .library: model.files.count + filed.count
        case .downloads: model.jobs.count
        }
    }
    private var filed: [Transfer] {
        let paths = Set(model.files.map(\.path))
        return model.jobs.filter { $0.state == "Completed" && !paths.contains($0.localPath ?? "") }
    }
    private var searchBinding: Binding<String> {
        switch selection {
        case .downloads: $downloadQuery
        case .library: $search
        default: Binding(get: { model.catalogQuery }, set: { model.catalogQuery = $0 })
        }
    }
    private var searchPrompt: String {
        switch selection {
        case .downloads: "Search downloads or paths"
        case .library: "Search your library"
        default: "Search titles, studios or releases"
        }
    }
    private func includes(_ parts: String?...) -> Bool {
        search.isEmpty || parts.compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
    }

    @ViewBuilder private func downloadButton(_ title: FeedTitle, _ offer: FeedOffer?) -> some View {
        if let job = model.activeJob(for: title) {
            Button("View Download") { downloadSelection = job.id; downloadQuery = ""; selection = .downloads }
        } else {
            Button {
                if model.config?.sab == nil { settings(sab: true) }
                else { Task { await model.download(title, offerID: offer?.id) } }
            } label: { Label("Download", systemImage: "arrow.down.to.line") }
            .disabled(model.sending.contains(title.id))
            .accessibilityLabel(offer.map { "Download \($0.name) from \($0.source)" } ?? "Download \(title.title)")
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
                else if phase.error != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).help("Preview failed to load")
                        .accessibilityLabel("Preview failed to load")
                }
                else if remote != nil { ProgressView().controlSize(.small).accessibilityLabel("Loading preview") }
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

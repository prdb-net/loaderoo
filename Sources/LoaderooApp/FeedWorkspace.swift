import SwiftUI
import LoaderooCore

@MainActor @Observable
final class FeedWorkspace {
    /// The local demo runs this same workspace against simulated services.
    let demo: Bool
    var engine: LiveFeed?
    var config: FeedConnections?
    var page = FeedPage() {
        didSet { updateDirectories() }
    }
    /// What the last refresh could not do. Kept apart from `page`, whose every change rebuilds the directories.
    var issues: [String] = []
    private(set) var reference = PRDBCatalog() {
        didSet { updateDirectories() }
    }
    private func updateDirectories() {
        studios = DirectoryEntry.entries(in: page, kind: .studios, including: reference.studios)
        actors = DirectoryEntry.entries(in: page, kind: .actors, including: reference.actors)
    }
    private(set) var studios: [DirectoryEntry] = []
    private(set) var actors: [DirectoryEntry] = []
    var catalogFilter = CatalogFilter()
    var selectedRelease: UUID?
    var catalogQuery = "" {
        didSet { if catalogQuery != oldValue { indexerSearch = nil } }
    }
    var indexerSearch: IndexerSearch?
    var loading = false
    var ready = false
    var folders: [LibraryFolder] = []
    var files: [LibraryFile] = []
    var jobs: [Transfer] = []
    var following = false
    var scanning = false
    var sending = Set<UUID>()
    var downloadIssue: String?
    var error: String?
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var scanWork: Task<Void, Never>?
    private var saving = false

    init(demo: Bool = false) { self.demo = demo }

    private func interruptMaintenance() async {
        guard let maintenance else { return }
        maintenance.cancel()
        await maintenance.value
    }

    func maintainCatalog() async {
        guard let engine, config != nil, maintenance == nil, !loading, !saving, sending.isEmpty else { return }
        let task = Task(priority: .utility) {
            do {
                let recent = try await engine.refresh()
                try Task.checkCancellation()
                page = recent
                issues = recent.issues
                guard !scanning, !following else { return }
                // Check PRDB before queuing more unresolved uploads from the indexers.
                do {
                    if try await engine.syncReferenceCatalog() { reference = try await engine.referenceCatalog() }
                } catch {
                    try Task.checkCancellation()
                    reference = try await engine.referenceCatalog()
                    issues.append(error.localizedDescription)
                }
                try Task.checkCancellation()
                guard let updated = try await engine.loadEarlierInBackground() else { return }
                try Task.checkCancellation()
                page = updated
            } catch {
                if !Task.isCancelled { issues.append(error.localizedDescription) }
            }
        }
        maintenance = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        maintenance = nil
    }

    func reload() async throws {
        guard let engine else { return }
        folders = try await engine.folders()
        files = try await engine.library()
        jobs = try await engine.transfers()
        page = try await engine.cached()
    }

    /// Which videos the downloads put on disk, and where. The catalog and library only change with it.
    private var filed: [String] { jobs.filter { $0.storage != nil }.map { $0.video + ($0.localPath ?? "") } }

    func follow() async {
        guard let engine, !following else { return }
        following = true
        defer { following = false }
        do {
            try await engine.followDownloads()
            downloadIssue = nil
        } catch { downloadIssue = error.localizedDescription }
        do {
            // Progress alone needs the job list. Reading the whole catalog again waits for a filed video.
            let before = filed
            jobs = try await engine.transfers()
            if filed != before { try await reload() }
        } catch { self.error = error.localizedDescription }
    }

    func scan(adding folder: URL? = nil) async {
        guard let engine, !scanning else { return }
        scanning = true
        defer { scanning = false }
        let work = Task {
            do {
                if let folder { try await engine.addFolder(folder) }
                folders = try await engine.folders()
                try await engine.scanLibrary()
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        scanWork = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        scanWork = nil
        do { try await reload() } catch { self.error = error.localizedDescription }
    }

    /// Files read so far keep their place. The next scan picks up where this one stopped.
    func stopScan() { scanWork?.cancel() }

    func activeJob(for title: FeedTitle) -> Transfer? {
        jobs.first { $0.video == title.id.uuidString && !$0.retryable }
    }

    func download(_ item: FeedTitle, offerID: String?) async {
        guard let engine, sending.insert(item.id).inserted else { return }
        defer { sending.remove(item.id) }
        await interruptMaintenance()
        do {
            try await engine.startDownload(item.id, offerID: offerID)
            try await reload()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Sends a download again that SABnzbd never confirmed.
    func resend(_ job: Transfer) async {
        guard let engine, let id = UUID(uuidString: job.video), sending.insert(id).inserted else { return }
        defer { sending.remove(id) }
        await interruptMaintenance()
        do {
            try await engine.retryDownload(id)
            error = nil
        } catch { self.error = error.localizedDescription }
        do { try await reload() } catch { self.error = error.localizedDescription }
    }

    func remove(_ job: Transfer) async {
        guard let engine else { return }
        do {
            try await engine.removeTransfer(job.video)
            try await reload()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func open() async {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let service: LiveFeed
            if demo {
                let chosen = ProcessInfo.processInfo.environment["LOADEROO_DEMO_ROOT"] ?? ""
                let root = chosen.isEmpty ? support.appending(path: "net.prdb.loaderoo/Demo") : URL(filePath: chosen, directoryHint: .isDirectory)
                service = try await Demo.open(root: root)
            } else {
                service = try LiveFeed(root: support.appending(path: "net.prdb.loaderoo/Live"))
            }
            engine = service
            config = try await service.connections()
            reference = try await service.referenceCatalog()
            try await reload()
            error = nil
            ready = true
            await maintainCatalog()
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func refresh(manual: Bool = false, earlier: Bool = false, search: IndexerSearch? = nil,
                 forCatalog: Bool = true) async -> IndexerSearch? {
        guard let engine, config != nil, !loading else { return nil }
        loading = true
        defer { loading = false }
        await interruptMaintenance()
        do {
            let result = try await engine.refresh(manual: manual, earlier: earlier, search: search)
            page = result
            issues = result.issues
            if forCatalog, let search, catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines) == search.term {
                indexerSearch = result.indexerSearch
            }
            error = nil
            return result.indexerSearch
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        return nil
    }

    func save(_ draft: FeedConnections, verifySAB: Bool) async throws {
        guard let engine else { throw CocoaError(.fileReadUnknown) }
        saving = true
        defer { saving = false }
        await interruptMaintenance()
        try await engine.configure(draft, verifySAB: verifySAB)
        config = try await engine.connections()
        indexerSearch = nil
        page = try await engine.cached()
    }
}

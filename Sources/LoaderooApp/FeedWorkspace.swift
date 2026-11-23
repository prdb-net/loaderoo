import SwiftUI
import LoaderooCore

@MainActor @Observable
final class FeedWorkspace {
    var engine: LiveFeed?
    var config: FeedConnections?
    var page = FeedPage() {
        didSet { updateDirectories() }
    }
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
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    private var saving = false

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
                guard !scanning, !following else { return }
                // Check PRDB before queuing more unresolved uploads from the indexers.
                do {
                    if try await engine.syncReferenceCatalog() { reference = try await engine.referenceCatalog() }
                } catch {
                    try Task.checkCancellation()
                    reference = try await engine.referenceCatalog()
                    page.issues.append(error.localizedDescription)
                }
                try Task.checkCancellation()
                guard let updated = try await engine.loadEarlierInBackground() else { return }
                try Task.checkCancellation()
                var result = updated
                result.issues = page.issues
                page = result
            } catch {
                if !Task.isCancelled { page.issues.append(error.localizedDescription) }
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
        let issues = page.issues
        page = try await engine.cached()
        page.issues = issues
    }

    func follow() async {
        guard let engine, !following else { return }
        following = true
        defer { following = false }
        do {
            try await engine.followDownloads()
            downloadIssue = nil
        } catch { downloadIssue = error.localizedDescription }
        do { try await reload() } catch { self.error = error.localizedDescription }
    }

    func scan(adding folder: URL? = nil) async {
        guard let engine, !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            if let folder { try await engine.addFolder(folder) }
            folders = try await engine.folders()
            try await engine.scanLibrary()
            error = nil
        } catch { self.error = error.localizedDescription }
        do { try await reload() } catch { self.error = error.localizedDescription }
    }

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
    var error: String?

    func open() async {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let service = try LiveFeed(root: support.appending(path: "net.prdb.loaderoo/Live"))
            engine = service
            config = try await service.connections()
            reference = try await service.referenceCatalog()
            try await reload()
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

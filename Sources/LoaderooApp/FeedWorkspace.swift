import SwiftUI
import LoaderooCore

@MainActor @Observable
final class FeedWorkspace {
    var engine: LiveFeed?
    var config: FeedConnections?
    var page = FeedPage() {
        didSet {
            studios = DirectoryEntry.entries(in: page, kind: .studios)
            actors = DirectoryEntry.entries(in: page, kind: .actors)
        }
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
            try await reload()
            ready = true
            if config != nil { await refresh() }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func refresh(manual: Bool = false, earlier: Bool = false, search: IndexerSearch? = nil,
                 forCatalog: Bool = true) async -> IndexerSearch? {
        guard let engine, config != nil, !loading else { return nil }
        loading = true
        defer { loading = false }
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
        try await engine.configure(draft, verifySAB: verifySAB)
        config = try await engine.connections()
        indexerSearch = nil
        page = try await engine.cached()
    }
}

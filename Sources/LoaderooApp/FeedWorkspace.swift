import SwiftUI
import LoaderooCore

@MainActor @Observable
final class FeedWorkspace {
    var engine: LiveFeed?
    var config: FeedConnections?
    var page = FeedPage()
    var loading = false
    var ready = false
    var folders: [LibraryFolder] = []
    var files: [LibraryFile] = []
    var jobs: [Transfer] = []
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
        guard let engine else { return }
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

    func download(_ item: FeedTitle) async {
        guard let engine, sending.insert(item.id).inserted else { return }
        defer { sending.remove(item.id) }
        do {
            try await engine.startDownload(item.id)
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

    func refresh(manual: Bool = false, earlier: Bool = false) async {
        guard let engine, config != nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            page = try await engine.refresh(manual: manual, earlier: earlier)
            error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func save(_ draft: FeedConnections, verifySAB: Bool) async throws {
        guard let engine else { throw CocoaError(.fileReadUnknown) }
        try await engine.configure(draft, verifySAB: verifySAB)
        config = try await engine.connections()
        page = try await engine.cached()
    }
}

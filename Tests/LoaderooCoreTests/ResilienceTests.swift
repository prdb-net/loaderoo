import Foundation
import os
import Testing
@testable import LoaderooCore

/// One indexer listing three releases, PRDB and SABnzbd, each of which can be made to misbehave.
private actor Backend {
    let videos = ["a": UUID(), "b": UUID(), "c": UUID()]
    var unreadable: String?
    var rejected: String?
    var acceptsUploads = true
    var matchRequests = 0
    var submissions = 0
    var history: [[String: String]] = []
    func cannotDescribe(_ entry: String?) { unreadable = entry }
    func rejectBatches(with entry: String?) { rejected = entry }
    func acceptUploads(_ accepts: Bool) { acceptsUploads = accepts }
    func report(_ slots: [[String: String]]) { history = slots }

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        var status = 200
        var data = Data()
        if url.host == "api.prdb.net" {
            switch url.path {
            case "/user-identity": data = try json(["userHash": "test"])
            case "/releases/resolve":
                matchRequests += 1
                let input = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: [[String: Any]]])
                let entries = try (input["releases"] ?? []).map { try #require(($0["source"] as? [String: String])?["entryId"]) }
                if let rejected, entries.contains(rejected) { status = 400 }
                data = try json(["results": zip(input["releases"] ?? [], entries).map { release, entry in
                    ["ref": release["ref"]!, "status": "resolved", "contentKind": "single", "automationEligible": true,
                     "videoIds": [videos[entry]!.uuidString]] as [String: Any]
                }])
            case "/videos/identify": data = try json(["results": [Any]()])
            default:
                let entry = try #require(videos.first { $0.value.uuidString == url.lastPathComponent }?.key)
                data = entry == unreadable ? Data("{}".utf8) : try json([
                    "id": url.lastPathComponent, "title": "Title " + entry, "site": ["title": "Studio North"],
                    "images": [["url": "https://art.example.invalid/\(entry).jpg"]]])
            }
        } else if url.host == "sab.example.invalid" {
            switch value("mode") {
            case "addfile":
                if !acceptsUploads { throw URLError(.cannotConnectToHost) }
                submissions += 1
                data = try json(["status": true, "nzo_ids": ["job-\(submissions)"]])
            case "queue": data = try json(["queue": ["slots": [Any]()]])
            default: data = try json(["history": ["slots": history]])
            }
        } else if value("t") == "get" {
            data = Data("<nzb><file><segments><segment>part@example.invalid</segment></segments></file></nzb>".utf8)
        } else {
            let items = videos.keys.sorted().map { entry in
                "<item><title>Release.\(entry)</title><guid>\(entry)</guid><n:attr name='usenetdate' value='2026-11-23T01:00:00Z'/>"
                    + "<link>https://\(url.host!)/api?t=get&amp;id=\(entry)</link></item>"
            }
            data = Data("<rss xmlns:n='urn:newznab'><channel>\(items.joined())</channel></rss>".utf8)
        }
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct ResilienceTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private let api = Backend()
    private let now = Date(timeIntervalSince1970: 1_795_392_000)

    private var config: FeedConnections {
        var config = FeedConnections()
        config.prdbKey = "test-prdb"
        config.indexers[0].name = "Index"
        config.indexers[0].address = "https://index.example.invalid/api"
        config.indexers[0].apiKey = "indexer-key"
        var sab = SABConnection()
        sab.address = "http://sab.example.invalid:8080"
        sab.apiKey = "sab-key"
        sab.mount = root.appending(path: "mount").path
        config.sab = sab
        return config
    }

    private func open(vault: SecretStore? = nil) throws -> LiveFeed {
        try LiveFeed(root: root, http: FeedHTTP { try await api.respond($0) }, vault: vault)
    }

    private func titles(_ page: FeedPage) -> [String] { page.titles.map(\.title).sorted() }

    @Test func oneVideoPRDBCannotDescribeDoesNotHoldUpTheOthers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await api.cannotDescribe("b")
        let feed = try open()
        try await feed.configure(config)
        let first = try await feed.refresh(now: now)
        #expect(titles(first) == ["Title a", "Title c"])
        #expect(first.issues == ["PRDB: 1 entry could not be read. Loaderoo will ask again in an hour."])
        // Nothing is left waiting, so older pages and the PRDB catalog are no longer held back.
        let db = await feed.store
        #expect(try await db.read { try LiveFeed.hasDueMetadata($0, at: now.timeIntervalSince1970) } == false)
        #expect(titles(try await feed.refresh(manual: true, now: now.addingTimeInterval(120))) == ["Title a", "Title c"])
        await api.cannotDescribe(nil)
        let later = try await feed.refresh(now: now.addingTimeInterval(3601))
        #expect(titles(later) == ["Title a", "Title b", "Title c"])
        #expect(later.issues.isEmpty)
    }

    @Test func oneListingPRDBRejectsIsSetAsideWhileTheRestOfItsBatchIsMatched() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await api.rejectBatches(with: "b")
        let feed = try open()
        try await feed.configure(config)
        let first = try await feed.refresh(now: now)
        #expect(titles(first) == ["Title a", "Title c"])
        #expect(first.pending == 1)
        #expect(first.issues.count == 1)
        #expect(await api.matchRequests <= 5)
        await api.rejectBatches(with: nil)
        #expect(titles(try await feed.refresh(now: now.addingTimeInterval(3601))).count == 3)
    }

    @Test func renamingAnIndexerOrChangingItsKeyKeepsItsListings() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try open()
        try await feed.configure(config)
        #expect(try await feed.refresh(now: now).releaseCount == 3)
        var changed = try #require(try await feed.connections())
        changed.indexers[0].name = "Renamed"
        changed.indexers[0].apiKey = "rotated-key"
        try await feed.configure(changed)
        let kept = try await feed.cached(now: now)
        #expect(kept.releaseCount == 3)
        #expect(kept.titles.first?.sources == ["Renamed"])
        // Another address is another indexer.
        changed.indexers[0].address = "https://elsewhere.example.invalid/api"
        try await feed.configure(changed)
        #expect(try await feed.cached(now: now).releaseCount == 0)
    }

    @Test func aDownloadSABnzbdNeverConfirmedCanBeSentAgainOrRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try open()
        try await feed.configure(config)
        _ = try await feed.refresh(now: now)
        let video = api.videos["a"]!
        await api.acceptUploads(false)
        try await feed.startDownload(video)
        try await feed.followDownloads()
        var job = try #require(try await feed.transfers().first)
        #expect(job.state == .checkingReceipt)
        #expect(job.awaitsReceipt && job.needsAttention && !job.retryable)
        await api.acceptUploads(true)
        try await feed.retryDownload(video)
        job = try #require(try await feed.transfers().first)
        #expect(job.state == .queued)
        #expect(job.job == "job-1")
        #expect(!job.awaitsReceipt)
        // A confirmed download is never sent twice.
        await #expect(throws: Never.self) { try await feed.retryDownload(video) }
        #expect(await api.submissions == 1)
        try await feed.removeTransfer(job.video)
        #expect(try await feed.transfers().isEmpty)
        #expect(try await feed.cached().titles.contains { $0.id == video })
    }

    @Test func aJobWithoutACompletionPathDoesNotHoldUpTheJobsBehindIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try open()
        try await feed.configure(config)
        _ = try await feed.refresh(now: now)
        let older = api.videos["a"]!, newer = api.videos["c"]!
        try await feed.startDownload(older)
        try await feed.startDownload(newer)
        await api.report([["nzo_id": "job-2", "name": "Release.c", "status": "Completed"],
                          ["nzo_id": "job-1", "name": "Release.a", "status": "Completed", "storage": "/downloads/complete/Release.a"]])
        try await feed.followDownloads()
        let jobs = try await feed.transfers()
        let stuck = try #require(jobs.first { $0.video == newer.uuidString })
        #expect(stuck.state == .awaitingFiling)
        #expect(stuck.note == "SABnzbd history has no completion path.")
        #expect(jobs.first { $0.video == older.uuidString }?.storage == "/downloads/complete/Release.a")
    }

    @Test func anUnencryptedAddressMacOSBlocksIsNamedAsSuch() async throws {
        let blocked = FeedHTTP { _ in throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let request = URLRequest(url: URL(string: "http://nas.home.example:8080/api")!)
        let failure = await #expect(throws: FeedError.self) { try await blocked.data(request) }
        #expect(failure?.message.contains("https") == true)
        #expect(failure?.unreachable == true)
    }

    @Test func apiKeysMoveToTheSecretStoreAndStayOutOfTheDatabase() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let vault = SecretStore(load: { kept.withLock { $0 } }, save: { data in kept.withLock { $0 = data } })
        func saved(_ feed: LiveFeed) async throws -> String {
            let db = await feed.store
            return String(decoding: try #require(try await db.read { try Data.fetchOne($0, sql: "SELECT config FROM connection") }), as: UTF8.self)
        }
        // A build without a team signature keeps the keys in its database.
        let adHoc = try open()
        try await adHoc.configure(config)
        let expected = try #require(try await adHoc.connections())
        #expect(try await saved(adHoc).contains("indexer-key"))

        let signed = try open(vault: vault)
        #expect(try await signed.connections() == expected)
        for key in ["test-prdb", "indexer-key", "sab-key"] {
            #expect(try await !saved(signed).contains(key))
            #expect(String(decoding: try #require(kept.withLock { $0 }), as: UTF8.self).contains(key))
        }
        var rotated = expected
        rotated.indexers[0].apiKey = "rotated-key"
        try await signed.configure(rotated)
        #expect(try await !saved(signed).contains("rotated-key"))
        #expect(try await open(vault: vault).connections() == rotated)
    }

    @Test func aLibraryFolderThatLostEveryVideoAtOnceKeepsItsMatches() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try open()
        try await feed.configure(config)
        let folder = root.appending(path: "collection/")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["one.mp4", "two.mkv"]
        for name in names { try Data("video".utf8).write(to: folder.appending(path: name)) }
        try await feed.addFolder(folder)
        try await feed.scanLibrary()
        #expect(try await feed.library().count == 2)
        // A share that dropped away can leave its mount point behind as an empty folder.
        for name in names { try FileManager.default.removeItem(at: folder.appending(path: name)) }
        try await feed.scanLibrary()
        #expect(try await feed.library().count == 2)
        #expect(try await feed.library().allSatisfy(\.offline))
        try Data("video".utf8).write(to: folder.appending(path: "one.mp4"))
        try await feed.scanLibrary()
        #expect(try await feed.library().map(\.url.lastPathComponent) == ["one.mp4"])
        #expect(try await feed.library().allSatisfy { !$0.offline })
    }
}

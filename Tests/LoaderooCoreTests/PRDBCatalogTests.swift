import Foundation
import GRDB
import Testing
@testable import LoaderooCore

private actor CatalogAPI {
    let studio = UUID(), olderActor = UUID(), recentActor = UUID()
    let cursor = "2026-11-01T10:00:00.1234567+00:00"
    var videoRequests: [Int] = []
    var bounds: Set<String> = []
    var limited = false
    var invalid = false
    private var total: Int

    init(total: Int) { self.total = total }
    func rateLimit(_ value: Bool) { limited = value }
    func malformed(_ value: Bool) { invalid = value }
    func removeAllVideos() { total = 0 }

    func reply(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test")
        var code = 200
        var doc: [String: Any] = [:]
        switch url.path {
        case "/user-identity": doc = ["userHash":"test"]
        case "/sites/changes":
            if value("since") == "2026-11-02T00:00:00Z" {
                doc = ["items":[], "hasMore":false, "serverTimeUtc":"2026-11-03T00:00:00Z"]
                break
            }
            let first = value("sinceId") == nil
            if !first {
                #expect(value("since") == cursor)
                #expect(url.absoluteString.contains("%2B"))
                #expect(value("sinceId") == studio.uuidString)
            }
            let item: [String: Any] = ["id":studio.uuidString,"title":"Even Without Offers","isDeleted":!first]
            doc = ["items":[["site":item]], "hasMore":first, "serverTimeUtc":cursor,
                   "nextCursor":["updatedAtUtc":first ? cursor : "2026-11-02T00:00:00Z","id":studio.uuidString]]
        case "/videos":
            let page = Int(try #require(value("page")))!
            videoRequests.append(page)
            bounds.insert(try #require(value("createdBefore")))
            #expect(value("sortBy") == "createdAtUtc")
            #expect(value("sortDirection") == "desc")
            if limited { code = 429; break }
            let first = (page - 1) * 100
            let items: [[String: Any]] = (first..<max(first,min(first+100,total))).map { index in
                let actor = index >= 20_000 ? olderActor : recentActor
                let id = String(format: "90000000-0000-0000-0000-%012d", index)
                let created = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
                return ["id":id,"title":"Title \(index)","siteTitle":"Écran","createdAtUtc": invalid ? "unknown" : created.ISO8601Format(),
                        "actors":[["id":actor.uuidString,"name":"Credit \(actor.uuidString.prefix(4))"]]]
            }
            doc = ["page":page,"pageSize":100,"totalCount":total,"items":items]
        default: throw FeedError("Unexpected request")
        }
        return (try JSONSerialization.data(withJSONObject: doc), HTTPURLResponse(url: url,statusCode: code,httpVersion: nil,headerFields: nil)!)
    }
}

struct PRDBCatalogTests {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func open(_ api: CatalogAPI) throws -> LiveFeed {
        try LiveFeed(root: root, http: FeedHTTP { try await api.reply($0) })
    }

    private func setup(_ api: CatalogAPI) async throws -> LiveFeed {
        let feed = try open(api)
        var config = FeedConnections()
        config.prdbKey = "test"
        config.indexers[0].address = "https://index.example.invalid/api"
        try await feed.configure(config)
        return feed
    }

    @Test func resumesBothFeedsKeepsOnlyLatestTitlesAndFindsOlderCredits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = CatalogAPI(total: 20_001)
        let feed = try await setup(api)
        #expect(try await feed.syncReferenceCatalog(now: start))
        let first = try await feed.referenceCatalog()
        #expect(first.studios.first?.id == .studio(api.studio))
        #expect(first.videoCount == 300)
        #expect(first.actors.map(\.id) == [.actor(api.recentActor)])
        let reopened = try open(api)
        #expect(try await !reopened.syncReferenceCatalog(now: start.addingTimeInterval(59)))
        var tick = 1
        while try await reopened.syncReferenceCatalog(now: start.addingTimeInterval(Double(tick)*60)) {
            #expect(try await reopened.referenceCatalog().videoCount <= PRDBCatalog.videoLimit)
            tick += 1
            if tick > 53 { Issue.record("Video scan did not stop"); break }
        }
        let catalog = try await reopened.referenceCatalog()
        #expect(catalog.videoCount == 20_000)
        #expect(catalog.studios.isEmpty)
        #expect(Set(catalog.actors.map(\.id)) == [.actor(api.recentActor), .actor(api.olderActor)])
        #expect(catalog.olderCreditPage == nil)
        #expect(await api.videoRequests == Array(1...201))
        #expect(await api.bounds.count == 1)
        #expect(try await reopened.referenceVideos(matching: "éCRAN", limit: 2).map(\.title) == ["Title 0","Title 1"])
        #expect(try await reopened.referenceVideos(matching: "Title 20000", limit: 1).isEmpty)
        #expect(try await reopened.cached().titles.isEmpty)
    }

    @Test func malformedPageAndRateLimitPreserveTheVideoCursor() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = CatalogAPI(total: 5)
        let feed = try await setup(api)
        await api.malformed(true)
        await #expect(throws: FeedError.self) { try await feed.syncReferenceCatalog(now: start) }
        #expect(try await feed.referenceCatalog().videoCount == 0)
        await api.malformed(false)
        await api.rateLimit(true)
        let later = start.addingTimeInterval(61)
        await #expect(throws: FeedError.self) { try await feed.syncReferenceCatalog(now: later) }
        let reopened = try open(api)
        await api.rateLimit(false)
        #expect(try await !reopened.syncReferenceCatalog(now: later.addingTimeInterval(899)))
        #expect(try await reopened.syncReferenceCatalog(now: later.addingTimeInterval(901)))
        #expect(try await reopened.referenceCatalog().videoCount == 5)
        #expect(await api.videoRequests == [1,1,1])
    }

    @Test func aCompletedNewWindowDropsRemovedVideosAndTheirLastCredits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = CatalogAPI(total: 2)
        let feed = try await setup(api)
        _ = try await feed.syncReferenceCatalog(now: start)
        #expect(try await feed.referenceCatalog().actors.count == 1)
        await api.removeAllVideos()
        _ = try await feed.syncReferenceCatalog(now: start.addingTimeInterval(86401))
        let catalog = try await feed.referenceCatalog()
        #expect(catalog.actors.isEmpty)
        #expect(catalog.videoCount == 0)
    }
}

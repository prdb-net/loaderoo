import Foundation
import GRDB
import Testing
@testable import LoaderooCore

private actor ArchiveService {
    let now = Date(timeIntervalSince1970: 1_795_392_000)
    let archiveVideo = UUID()
    var requests: [String] = []
    private var limitedHost: String?
    func limit(_ host: String?) { limitedHost = host }

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let host = try #require(url.host)
        let data: Data
        var status = 200
        if url.path == "/user-identity" {
            data = Data(#"{"userHash":"test"}"#.utf8)
        } else if url.path == "/releases/resolve" {
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: [[String: Any]]])
            let results: [[String: Any]] = try (body["releases"] ?? []).map {
                let confirmed = $0["title"] as? String == "Release.3"
                return ["ref": try #require($0["ref"] as? String), "status": confirmed ? "resolved" : "ambiguous",
                        "contentKind": "single", "automationEligible": confirmed, "videoIds": confirmed ? [archiveVideo.uuidString] : []]
            }
            data = try JSONSerialization.data(withJSONObject: ["results": results])
        } else if url.path == "/videos/" + archiveVideo.uuidString {
            data = try JSONSerialization.data(withJSONObject: [
                "id": archiveVideo.uuidString, "title": "Earlier release",
                "images": [["url": "https://art.example.invalid/cover.jpg"]]])
        } else {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "0")!
            let name = String(host.prefix { $0 != "." })
            requests.append("\(name)/\(offset)")
            if limitedHost == name { status = 429 }
            let old = now.addingTimeInterval(-35 * 86400)
            let dates: [Date?] = switch name {
            case "dated" where offset < 4: [now, old]
            case "dated": [old, old]
            default: [nil, nil]
            }
            let items = dates.enumerated().map { index, date in
                let attr = date.map { "<n:attr name='usenetdate' value='\($0.ISO8601Format())'/>" } ?? ""
                let entry = offset + index
                return "<item><title>Release.\(entry)</title><guid>entry-\(entry)</guid><link>https://\(host)/get/\(entry)</link>\(attr)</item>"
            }
            let total = name == "dated" ? 8 : 5000
            data = Data(("<rss xmlns:n='urn:newznab'><channel><n:response offset='\(offset)' total='\(total)'/>"
                         + items.joined() + "</channel></rss>").utf8)
        }
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct IndexerHistoryTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private let service = ArchiveService()

    private func open() throws -> LiveFeed {
        try LiveFeed(root: root, http: FeedHTTP { try await service.respond($0) })
    }

    private func configure(_ names: [String]) async throws -> LiveFeed {
        let feed = try open()
        var config = FeedConnections()
        config.prdbKey = "test"
        config.indexers = names.map { name in
            var indexer = IndexerConnection()
            indexer.name = name
            indexer.address = "https://\(name).example.invalid/api"
            return indexer
        }
        try await feed.configure(config)
        _ = try await feed.refresh(now: service.now)
        return feed
    }

    @Test func rotatesAcrossRestartsAndDrainsDueMatchesBeforeFetchingAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await configure(["dated", "undated"])
        let now = service.now
        let first = try #require(try await feed.loadEarlierInBackground(now: now))
        #expect(first.history.map(\.pages) == [1, 0])
        #expect(first.history.first?.status == .moreAvailable)
        #expect(first.history.first?.through == now)
        #expect(first.pending > 0)
        let reopened = try open()
        // Another slot is available, but the two new offers still need an initial PRDB lookup.
        #expect(try await reopened.loadEarlierInBackground(now: now.addingTimeInterval(60)) == nil)
        let matched = try await reopened.refresh(now: now.addingTimeInterval(60))
        #expect(matched.titles.map(\.id) == [service.archiveVideo])
        #expect(matched.titles.first?.preview != nil)
        #expect(try await reopened.loadEarlierInBackground(now: now.addingTimeInterval(60))?.history.map(\.pages) == [1, 1])
        _ = try await reopened.refresh(now: now.addingTimeInterval(61))
        #expect(try await reopened.loadEarlierInBackground(now: now.addingTimeInterval(119)) == nil)
        let older = try #require(try await reopened.loadEarlierInBackground(now: now.addingTimeInterval(120)))
        #expect(older.history.first?.status == .lookbackReached)
        _ = try await reopened.refresh(now: now.addingTimeInterval(900))
        #expect(try await reopened.loadEarlierInBackground(now: now.addingTimeInterval(900))?.history.map(\.pages) == [2, 2])
        #expect(await service.requests == ["dated/0", "undated/0", "dated/2", "undated/2", "dated/4",
                                           "dated/0", "undated/0", "undated/4"])
        let manual = try await reopened.refresh(earlier: true, now: now.addingTimeInterval(902))
        #expect(manual.history.first?.status == .endOfResults)
        _ = try await reopened.refresh(manual: true, now: now.addingTimeInterval(903))
        #expect(try await reopened.cached(now: now).history.first?.status == .endOfResults)
    }

    @Test func pageLimitBoundsUndatedIndexersAndManualPagingCanContinue() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await configure(["undated"])
        for step in 0..<100 {
            let tick = service.now.addingTimeInterval(Double(step) * 60)
            _ = try await feed.refresh(now: tick)
            let page = try #require(try await feed.loadEarlierInBackground(now: tick))
            #expect(page.history.first?.pages == step + 1)
        }
        let now = service.now.addingTimeInterval(6000)
        _ = try await feed.refresh(now: now)
        let reopened = try open()
        #expect(try await reopened.cached(now: now).history.first?.status == .pageLimitReached)
        #expect(try await reopened.loadEarlierInBackground(now: now) == nil)
        let manual = try await reopened.refresh(earlier: true, now: now)
        #expect(manual.history.first?.pages == 101)
        #expect(await service.requests.last == "undated/202")
    }

    @Test func sourceCooldownStillAllowsOtherIndexersAndPRDBRetryPausesAll() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await configure(["dated", "undated"])
        let now = service.now
        await service.limit("dated")
        await #expect(throws: FeedError.self) { try await feed.loadEarlierInBackground(now: now) }
        let minute = now.addingTimeInterval(60)
        #expect(try await feed.loadEarlierInBackground(now: minute)?.history.map(\.pages) == [0, 1])
        _ = try await feed.refresh(now: minute)
        try await feed.backoff(HTTPFailure(status: 429, retryAt: nil), service: "PRDB", now: minute)
        #expect(try await open().loadEarlierInBackground(now: now.addingTimeInterval(120)) == nil)
        #expect(await service.requests == ["dated/0", "undated/0", "dated/2", "undated/2"])
    }

    @Test func freshHeadStartsANewWindowAfterAMonthOffline() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await configure(["undated"])
        let first = try await feed.loadEarlierInBackground(now: service.now)
        #expect(first?.history.first?.pages == 1)
        let later = service.now.addingTimeInterval(33 * 86400)
        let reopened = try open()
        let recent = try await reopened.refresh(now: later)
        #expect(recent.history.first?.pages == 0)
        _ = try await reopened.loadEarlierInBackground(now: later)
        #expect(await service.requests == ["undated/0", "undated/2", "undated/0", "undated/2"])
    }

    @Test func upgradePreservesExistingOffsetWithoutUsingOldestOutlierAsCutoff() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await configure(["undated"])
        let db = await feed.store
        try await db.write {
            try $0.execute(sql: """
                CREATE TABLE oldPaging(source TEXT PRIMARY KEY, offset INTEGER, oldest DOUBLE);
                INSERT INTO oldPaging SELECT source,400,0 FROM paging;
                DROP TABLE paging;
                ALTER TABLE oldPaging RENAME TO paging;
                """)
        }
        let reopened = try open()
        let page = try #require(try await reopened.loadEarlierInBackground(now: service.now))
        #expect(await service.requests.last == "undated/400")
        #expect(page.history.first?.pages == 4)
        #expect(page.history.first?.through == nil)
    }

    @Test func cancellingBackgroundFetchLeavesTheSamePageAvailableForAManualRequest() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await configure(["undated"])
        let (requests, started) = AsyncStream<Void>.makeStream()
        let delayed = try LiveFeed(root: root, http: FeedHTTP { request in
            started.yield(())
            try await Task.sleep(for: .seconds(5))
            return try await service.respond(request)
        })
        let task = Task { try await delayed.loadEarlierInBackground(now: service.now) }
        var iterator = requests.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let resumed = try open()
        #expect(try await resumed.cached().history.first?.pages == 0)
        let result = try await resumed.refresh(earlier: true, now: service.now)
        #expect(result.history.first?.pages == 1)
        #expect(result.issues.isEmpty)
        #expect(await service.requests == ["undated/0", "undated/2"])
    }
}

import Foundation
import Testing
@testable import LoaderooCore

// Synthetic responses for the public API and two independent Newznab origins.
private actor Services {
    static let first = UUID()
    static let second = UUID()
    var rechecked = false
    var failingHost: String?
    var batches = 0
    var origins: [String] = []
    var searches: [String] = []
    var previewRequests = 0
    var userImages = Data("[]".utf8)
    func setUserImages(_ data: Data) { userImages = data }
    var hasImages = true
    func setImagesAvailable(_ available: Bool) { hasImages = available }

    func confirmPending() { rechecked = true }
    func fail(_ host: String) { failingHost = host }

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let host = try #require(url.host)
        var status = 200
        var data = Data()
        var headers: [String: String] = [:]
        if host == "api.prdb.net" {
            #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-prdb")
            if url.path == "/user-identity" {
                data = Data(#"{"userHash":"local-test"}"#.utf8)
            } else if url.path == "/releases/resolve" {
                #expect(request.httpMethod == "POST")
                let body = try #require(request.httpBody)
                #expect(!String(decoding: body, as: UTF8.self).contains("test-indexer"))
                let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: [[String: Any]]])
                batches += 1
                var results: [[String: Any]] = []
                for input in decoded["releases"] ?? [] {
                    let source = try #require(input["source"] as? [String: String])
                    origins.append(try #require(source["origin"]))
                    let entry = try #require(source["entryId"])
                    #expect(input["sizeBytes"] as? Int == 4321)
                    #expect(input["categories"] as? [String] == ["6000"])
                    let pending = entry == "wait" && !rechecked
                    let id = entry == "wait" ? Self.second : Self.first
                    results.append(["ref": try #require(input["ref"] as? String), "status": pending ? "ambiguous" : "resolved",
                                    "automationEligible": !pending, "videoIds": pending ? [] : [id.uuidString],
                                    "contentKind": "single", "recheckAfterUtc": "2026-11-23T08:02:00.1234567Z"])
                }
                data = try JSONSerialization.data(withJSONObject: ["results": Array(results.reversed())])
            } else if url.path.hasPrefix("/actors/") {
                data = Data(#"{"name":"Sam","nationalityLabel":"Canada","careerStart":2012,"aliases":[{"name":"River"}]}"#.utf8)
            } else if url.lastPathComponent == "user-images" {
                previewRequests += 1
                data = userImages
            } else {
                let id = try #require(UUID(uuidString: url.lastPathComponent))
                data = try JSONSerialization.data(withJSONObject: [
                    "id": id.uuidString, "title": id == Self.first ? "Harbor Lights" : "Late Arrival",
                    "actors": [["id": Self.second.uuidString, "name": "Sam", "images": [["url":"https://art.example.invalid/portrait.jpg"]]]],
                    "releaseDate": "2026-11-20",
                    "site": ["title": "Test Studio", "id": Self.first.uuidString, "network": ["title": "Studio Group"]], "images": hasImages ? [["url": "https://art.example.invalid/still.jpg"]] : []])
            }
        } else {
            searches.append(host)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(.init(name: "t", value: "search")))
            #expect(query.contains(.init(name: "apikey", value: "test-indexer")))
            #expect(request.value(forHTTPHeaderField: "X-Api-Key") == nil)
            if host == failingHost {
                status = 429
                headers["Retry-After"] = "1800"
            } else {
                func item(_ id: String, _ date: String) -> String {
                    """
                    <item><guid>https://\(host)/details/\(id)</guid><title><![CDATA[Release.\(id)]]></title>
                    <pubDate>Sun, 22 Nov 2026 03:00:00 +0000</pubDate><n:attr name="usenetdate" value="\(date)"/>
                    <enclosure url="https://\(host)/api?t=get&amp;apikey=test-indexer&amp;id=\(id)" length="4321"/>
                    <n:attr name="category" value="6000"/></item>
                    """
                }
                let items = host.hasPrefix("one") ? item("a","2026-11-23T01:00:00Z") + item("wait","2026-11-23T06:00:00Z")
                                                  : item("b","2026-11-23T04:00:00Z")
                data = Data("<rss xmlns:n='urn:newznab'><channel>\(items)</channel></rss>".utf8)
            }
        }
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

struct LiveFeedTests {
    @available(macOS 15, *)
    @Test func deniedQueueCheckKeepsSettingsAndCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = Services()
        var config = connections()
        let http = FeedHTTP(reachability: { endpoint in
            #expect(endpoint == .hostPort(host: "sab.local", port: 8080))
            return .localNetworkDenied
        }) { request in
            if request.url?.host == "sab.local" { throw URLError(.notConnectedToInternet) }
            return try await services.respond(request)
        }
        let feed = try LiveFeed(root: root, http: http)
        try await feed.configure(config)
        var sab = SABConnection()
        sab.address = "http://sab.local:8080/api"
        sab.apiKey = "test-key"
        config.sab = sab
        await #expect(throws: LocalNetworkAccessRequired.self) { try await feed.configure(config) }
        #expect(try await feed.connections()?.sab == nil)

        actor Queue {
            var checks = 0
            func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
                checks += 1
                #expect(request.httpMethod == "GET")
                let url = try #require(request.url)
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "mode", value: "queue")) == true)
                if checks == 1 { throw URLError(.notConnectedToInternet) }
                return (Data(#"{"queue":{"slots":[]}}"#.utf8),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let queue = Queue()
        let allowed = FeedHTTP(reachability: { _ in .reachable }) { try await queue.respond($0) }
        let reopened = try LiveFeed(root: root, http: allowed)
        try await reopened.configure(config)
        #expect(try await reopened.connections()?.sab == sab)
        #expect(await queue.checks == 2)
        await #expect(throws: LocalNetworkAccessRequired.self) { try await feed.configure(config, verifySAB: true) }
        #expect(try await feed.connections()?.sab == sab)
    }

    @Test func offlineAndBadAPIKeyDoNotReportPermissionDenial() async throws {
        let url = URL(string: "http://sab.local:8080/api")!
        let request = URLRequest(url: url)
        let offline = FeedHTTP(reachability: { _ in .unavailable }) { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: FeedError.self) { try await offline.data(request) }
        let refused = FeedHTTP(reachability: { _ in
            Issue.record("An HTTP response already proves the endpoint was reachable.")
            return .unavailable
        }) { _ in (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!) }
        await #expect(throws: HTTPFailure.self) { try await refused.data(request) }
    }

    private func connections() -> FeedConnections {
        var config = FeedConnections()
        config.prdbKey = "test-prdb"
        config.indexers = ["one", "two"].map { host in
            var source = IndexerConnection()
            source.name = host
            source.apiKey = "test-indexer"
            source.address = "https://" + host + ".example.invalid/api"
            return source
        }
        return config
    }

    @Test func livePipelineGroupsListingsAndRechecksAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = Services()
        let http = FeedHTTP { try await service.respond($0) }
        let feed = try LiveFeed(root: root, http: http)
        let now = try #require(feedDate("2026-11-23T08:00:00Z"))
        let config = connections()
        try await feed.configure(config)
        let first = try await feed.refresh(now: now)
        #expect(first.issues.isEmpty)
        #expect(first.pending == 1)
        #expect(first.titles.count == 1)
        let title = try #require(first.titles.first)
        #expect(title.sources == ["one","two"])
        #expect(title.posted == feedDate("2026-11-23T04:00:00Z"))
        #expect(title.studio == "Test Studio")
        #expect(title.preview?.host == "art.example.invalid")
        #expect(Set(await service.origins) == ["https://one.example.invalid","https://two.example.invalid"])
        let reopened = try LiveFeed(root: root, http: http)
        #expect(try await reopened.cached().titles.first?.id == title.id)
        await service.confirmPending()
        _ = try await reopened.refresh(now: now.addingTimeInterval(90))
        #expect(await service.batches == 1)
        let after = try await reopened.refresh(now: now.addingTimeInterval(125))
        #expect(await service.searches.count == 2)
        #expect(after.titles.map(\.title) == ["Late Arrival","Harbor Lights"])
        #expect(after.pending == 0)
        var changed = config
        changed.indexers.removeFirst()
        try await reopened.configure(changed)
        #expect(try await reopened.cached().titles.first?.sources == ["two"])
    }

    @Test func galleryFetchIsSharedAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = Services()
        let response = Data("""
            [{"previewImageType":"Single","url":"https://art.example.invalid/frame.jpg"},
             {"previewImageType":"Single","url":"file:///invalid.jpg"},
             {"previewImageType":"SpriteSheet","url":"https://art.example.invalid/incomplete.jpg"},
             {"previewImageType":"SpriteSheet","url":"https://art.example.invalid/tiles.jpg",
              "spriteColumns":3,"spriteRows":2,"spriteTileCount":5,"spriteTileWidth":160,"spriteTileHeight":90}]
            """.utf8)
        await service.setUserImages(response)
        let http = FeedHTTP { try await service.respond($0) }
        let feed = try LiveFeed(root: root, http: http)
        try await feed.configure(connections())
        let title = try #require(try await feed.refresh().titles.first)
        #expect(title.siteImages == [title.preview].compactMap { $0 })
        #expect(title.releaseDate == feedDate("2026-11-20T00:00:00Z"))
        #expect(title.studioID == Services.first)
        #expect(title.studioContext == "Studio Group")
        #expect(title.cast.first?.name == "Sam")
        let actor = try await feed.actorProfile(Services.second)
        #expect(actor.aliases?.first?.name == "River")
        #expect(actor.careerStart == 2012)
        #expect(title.cast.first?.portrait?.lastPathComponent == "portrait.jpg")
        #expect(await service.previewRequests == 0)
        async let hover = feed.catalogPreviews(for: title.id)
        async let details = feed.catalogPreviews(for: title.id)
        let (first, second) = try await (hover, details)
        #expect(first.sheet?.frames == 5)
        #expect(first.sheet?.columns == 3)
        #expect(first.sheet?.url.lastPathComponent == "tiles.jpg")
        #expect(second.stills.map(\.lastPathComponent) == ["frame.jpg"])
        let reopened = try LiveFeed(root: root, http: http)
        #expect(try await reopened.cached().titles.first?.userPreviews?.sheet == first.sheet)
        _ = try await reopened.catalogPreviews(for: title.id)
        #expect(await service.previewRequests == 1)
    }

    @Test func sheetWithoutAStillIsVisibleInThePreviewCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = Services()
        await service.setImagesAvailable(false)
        await service.setUserImages(Data("""
            [{"previewImageType":"SpriteSheet","url":"https://art.example.invalid/tiles.jpg",
              "spriteColumns":2,"spriteRows":1,"spriteTileCount":3,"spriteTileWidth":160,"spriteTileHeight":90}]
            """.utf8))
        let feed = try LiveFeed(root: root, http: FeedHTTP { try await service.respond($0) })
        try await feed.configure(connections())
        let page = try await feed.refresh()
        let title = try #require(CatalogFilter().titles(in: page, matching: "", search: nil).first)
        #expect(title.preview == nil)
        #expect(title.userPreviews?.sheet?.frames == 2)
    }

    @Test func manualRefreshFindsNewPreviewsForFilteredTitles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = Services()
        await service.setImagesAvailable(false)
        let feed = try LiveFeed(root: root, http: FeedHTTP { try await service.respond($0) })
        try await feed.configure(connections())
        let now = try #require(feedDate("2026-11-23T08:00:00Z"))
        let first = try await feed.refresh(now: now)
        let filter = CatalogFilter()
        #expect(filter.titles(in: first, matching: "", search: nil).isEmpty)
        #expect(filter.titles(in: first, matching: "Harbor", search: nil, onlyWithPreview: false).count == 1)
        await service.setImagesAvailable(true)
        let early = try await feed.refresh(manual: true, now: now.addingTimeInterval(30))
        #expect(filter.titles(in: early, matching: "", search: nil).isEmpty)
        let updated = try await feed.refresh(manual: true, now: now.addingTimeInterval(901))
        #expect(filter.titles(in: updated, matching: "Harbor", search: nil).count == 1)
    }

    @Test func failedIndexerLeavesOtherSourcesAvailableAndHonorsCooldown() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = Services()
        await service.fail("one.example.invalid")
        let feed = try LiveFeed(root: root, http: FeedHTTP { try await service.respond($0) })
        try await feed.configure(connections())
        let first = try await feed.refresh()
        #expect(first.issues.count == 1)
        #expect(first.titles.first?.sources == ["two"])
        _ = try await feed.refresh(manual: true)
        #expect(await service.searches == ["one.example.invalid", "two.example.invalid", "two.example.invalid"])
    }

    @Test func missingPostingTimeStaysUnknownAndReleaseQualityIsPreserved() async throws {
        let xml = """
            <rss><channel><item><title>Studio.Scene.1080p</title><guid>video-1</guid>
            <pubDate>Tue, 12 May 2026 12:00:00 +0000</pubDate>
            <link>https://one.example.invalid/api?t=get&amp;id=video-1</link>
            </item></channel></rss>
            """
        let reader = NewznabFeed(http: FeedHTTP { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "attrs" })?.value?.contains("usenetdate") == true)
            return (Data(xml.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let results = try await reader.latest(connections().indexers[0])
        let parsed = try #require(results.first)
        #expect(parsed.posted == nil)
        #expect(parsed.quality == "1080p")
    }

    @Test func automatedMatchRequiresAnEligibleSingleVideo() {
        let video = UUID()
        func result(_ status: String, _ eligible: Bool, _ ids: [UUID], _ kind: String) -> UUID? {
            Resolution(ref: "r", status: status, automationEligible: eligible, videoIds: ids,
                       contentKind: kind, recheckAfterUtc: nil).confirmedID
        }
        #expect(result("resolved", false, [video], "single") == nil)
        #expect(result("candidate", true, [video], "single") == nil)
        #expect(result("resolved", true, [video, UUID()], "single") == nil)
        #expect(result("resolved", true, [video], "unknown") == nil)
        #expect(result("resolved", true, [video], "single") == video)
    }

    @Test func apiAddressRejectsEmbeddedCredentials() throws {
        var invalid = connections()
        invalid.indexers[0].address = "https://index.example.invalid/api?apikey=embedded"
        #expect(throws: FeedError.self) { try invalid.validated() }
        #expect(throws: FeedError.self) { try FeedConnections().validated() }
    }
}

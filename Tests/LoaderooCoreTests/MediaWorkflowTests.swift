import Foundation
import Testing
@testable import LoaderooCore

private actor MediaAPI {
    let id = UUID()
    let artwork = URL(string: "https://images.example.invalid/still.jpg")!
    var searches: [Int] = []
    var submissions = 0
    let disposition: String?
    var jobName: String?
    var uploadFilename: String?
    init(disposition: String? = nil) { self.disposition = disposition }
    var completed = false
    var loseReply = false
    func finish() { completed = true }
    func dropReply() { loseReply = true }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        var headers: [String: String] = [:]
        let data: Data
        if url.host == "api.prdb.net" {
            switch url.path {
            case "/user-identity": data = try json(["userHash":"test"])
            case "/releases/resolve":
                let input = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String:[[String:Any]]])
                data = try json(["results":input["releases"]!.map { ["ref":$0["ref"]!, "status":"resolved",
                                    "contentKind":"single","automationEligible":true,"videoIds":[id.uuidString]] }])
            case "/videos/identify":
                let input = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String:Any])
                let files = try #require(input["files"] as? [[String:Any]])
                let result = try files.map { file -> [String:Any] in
                    let filename = try #require(file["filename"] as? String)
                    #expect(!filename.contains("/"))
                    let hash = try #require(file["osHash"] as? String)
                    #expect(hash == "0000000000020000")
                    let matched = filename.hasPrefix("renamed")
                    return ["ref":file["ref"]!, "confidence":4,"matchedBy":matched ? 0 : 2,
                            "candidates":[],"videoId":id.uuidString,"video":["title":"Harbor Walk"]]
                }
                data = try json(["results":result])
            default:
                if url.lastPathComponent == "user-images" {
                    data = try json([["previewImageType":"SpriteSheet","url":"https://example.invalid/sprite"],
                                     ["previewImageType":"Single","url":artwork.absoluteString]])
                } else {
                    data = try json(["id":id.uuidString,"title":"Harbor Walk","site":["title":"Studio North"],"images":[]])
                }
            }
        } else if url.host == "sab.example.invalid" {
            switch value("mode") {
            case "addfile":
                submissions += 1
                jobName = value("nzbname")
                let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
                uploadFilename = try #require(body.firstMatch(of: /filename="([^"]+)"/)?.1.description)
                #expect(request.httpMethod == "POST")
                #expect(body.contains("<segment"))
                if loseReply { throw URLError(.networkConnectionLost) }
                data = try json(["status":true,"nzo_ids":["SAB-job"]])
            case "queue":
                let slots = completed || jobName == nil ? [] : [["filename":jobName ?? "", "nzo_id":"SAB-job", "status":"Downloading"]]
                data = try json(["queue":["slots":slots]])
            case "history":
                let name = jobName ?? ""
                var slots = [["name":name, "nzb_name":"other.nzb", "nzo_id":"other", "status":"Completed", "storage":"/downloads/complete/other"]]
                if completed {
                    slots.append(["name":name, "nzb_name":try #require(uploadFilename), "nzo_id":"SAB-job", "status":"Completed", "storage":"/downloads/complete/" + name])
                }
                data = try json(["history":["slots":slots]])
            default: throw FeedError("Unexpected SABnzbd operation")
            }
        } else if value("t") == "get" {
            headers["Content-Type"] = "application/x-nzb"
            headers["Content-Disposition"] = disposition
            #expect(value("id") == "download-a")
            data = Data("<nzb><file><segments><segment>sample@example.invalid</segment></segments></file></nzb>".utf8)
        } else {
            let offset = Int(value("offset") ?? "0") ?? 0
            searches.append(offset)
            let entry = offset == 0 ? "a" : "older"
            data = Data("""
                <rss xmlns:n="urn:newznab"><channel><n:response offset="\(offset)" total="2"/>
                <item><title>Test.Release</title><guid>\(entry)</guid><link>https://index.example.invalid/api?t=get&amp;id=download-\(entry)</link></item>
                </channel></rss>
                """.utf8)
        }
        return (data,HTTPURLResponse(url: url,statusCode: 200,httpVersion: nil,headerFields: headers)!)
    }
}

struct MediaWorkflowTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func setup(_ api: MediaAPI) async throws -> LiveFeed {
        var config = FeedConnections()
        config.prdbKey = "test"
        config.indexers[0].address = "https://index.example.invalid/api"
        var sab = SABConnection()
        sab.address = "http://sab.example.invalid:8080"
        sab.apiKey = "test-sab"
        sab.mount = root.appending(path: "mount").path
        sab.destination = root.appending(path: "videos").path
        config.sab = sab
        let feed = try LiveFeed(root: root,http: FeedHTTP { try await api.perform($0) })
        try await feed.configure(config)
        let page = try await feed.refresh()
        #expect(page.titles.first?.preview == api.artwork)
        return feed
    }

    @Test func confirmedDownloadRecoversReceiptAndFilesUnderSelectedTitle() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI(disposition: "attachment; filename*=UTF-8''Caf%C3%A9%20Walk.1080p.nzb")
        let feed = try await setup(api)
        let fm = FileManager.default
        let output = root.appending(path: "mount/Café Walk.1080p/")
        let studio = root.appending(path: "videos/Studio North/")
        try fm.createDirectory(at: output,withIntermediateDirectories: true)
        try fm.createDirectory(at: studio,withIntermediateDirectories: true)
        let clip = output.appending(path: "unrecognized.mkv")
        try Data("video".utf8).write(to: clip)
        let existing = studio.appending(path: "Harbor Walk.mkv")
        try Data("existing".utf8).write(to: existing)
        await api.dropReply()
        try await feed.startDownload(api.id)
        try await feed.startDownload(api.id)
        #expect(await api.submissions == 1)
        #expect(await api.jobName == "Café Walk.1080p")
        let reopened = try LiveFeed(root: root,http: FeedHTTP { try await api.perform($0) })
        try await reopened.followDownloads()
        #expect(try await reopened.transfers().first?.job == nil)
        await api.finish()
        try await reopened.followDownloads()
        #expect(try await reopened.cached().titles.isEmpty)
        try await reopened.followDownloads()
        let result = try #require(try await reopened.transfers().first)
        #expect(result.note == nil)
        #expect(result.state == "Completed")
        #expect(result.job == "SAB-job")
        let target = studio.appending(path: "Harbor Walk (2).mkv")
        #expect(result.localPath == target.path)
        #expect(try Data(contentsOf: target) == Data("video".utf8))
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
        #expect(!fm.fileExists(atPath: clip.path))
        #expect(try await reopened.cached().titles.isEmpty)
        try await reopened.addFolder(studio)
        try await reopened.scanLibrary()
        let managed = try await reopened.library().first { $0.path == target.path }
        #expect(managed?.video == api.id.uuidString)
    }

    @Test(arguments: [nil, "attachment"] as [String?])
    func downloadFolderFallsBackToIndexerListingTitle(disposition: String?) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI(disposition: disposition)
        let feed = try await setup(api)
        try await feed.startDownload(api.id)
        #expect(await api.jobName == "Test.Release")
        try await feed.followDownloads()
        #expect(try await feed.transfers().first?.state == "Downloading")
    }

    @Test func earlierUploadsResumeAtProviderOffsetAfterRestart() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI()
        let feed = try await setup(api)
        #expect(try await feed.cached().hasEarlier)
        let reopened = try LiveFeed(root: root,http: FeedHTTP { try await api.perform($0) })
        let page = try await reopened.refresh(earlier: true)
        #expect(!page.hasEarlier)
        #expect(page.titles.count == 1)
        #expect(page.titles.first?.offers.count == 2)
        _ = try await reopened.refresh(earlier: true)
        #expect(await api.searches == [0,1])
    }

    @Test func scanUsesOnlyHashMatchesAndKeepsOfflineOwnership() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI()
        let feed = try await setup(api)
        let folder = root.appending(path: "collection/")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["renamed.mp4","suggested.mkv"] {
            try Data(count: 131072).write(to: folder.appending(path: name))
        }
        try await feed.addFolder(folder)
        try await feed.scanLibrary()
        let files = try await feed.library()
        #expect(files.count == 2)
        #expect(files.filter { $0.video != nil }.count == 1)
        #expect(try await feed.cached().titles.isEmpty)
        try FileManager.default.moveItem(at: folder,to: root.appending(path: "offline"))
        try await feed.scanLibrary()
        #expect(try await feed.library().allSatisfy(\.offline))
        #expect(try await feed.cached().titles.isEmpty)
        try await feed.removeFolder(folder.path)
        #expect(try await feed.cached().titles.count == 1)
    }

    @Test func mappedJobMustBeBelowCompletionRootAndContainOneVideo() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "job")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var sab = SABConnection()
        sab.mount = root.path
        for name in ["one.mp4","two.mp4"] { try Data().write(to: folder.appending(path: name)) }
        for path in ["/downloads/complete", "/downloads/complete/../job","/downloads/complete/job"] {
            #expect(throws: FeedError.self) { try LiveFeed.completedVideo(path,sab:sab) }
        }
    }
}

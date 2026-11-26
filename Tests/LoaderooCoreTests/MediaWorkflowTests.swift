import Foundation
import os
import Testing
@testable import LoaderooCore

private actor MediaAPI {
    let id = UUID()
    let archiveID = UUID()
    let artwork = URL(string: "https://images.example.invalid/still.jpg")!
    var searches: [Int] = []
    var terms: [String] = []
    var submissions = 0
    var requestedNZBs: [String] = []
    var invalidNZB: String?
    func invalidateNZB(_ id: String) { invalidNZB = id }
    let disposition: String?
    var jobName: String?
    var uploadFilename: String?
    let include4K: Bool
    init(disposition: String? = nil, include4K: Bool = false) {
        self.disposition = disposition
        self.include4K = include4K
    }
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
                data = try json(["results":input["releases"]!.map { release in
                    let video = (release["title"] as? String)?.hasPrefix("Archive.") == true ? archiveID : id
                    return ["ref":release["ref"]!, "status":"resolved", "contentKind":"single",
                            "automationEligible":true,"videoIds":[video.uuidString]] as [String:Any]
                }])
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
                    data = try json(["id":url.lastPathComponent,"title":url.lastPathComponent == archiveID.uuidString ? "Distant Shore" : "Harbor Walk","site":["title":"Studio North"],"images":[]])
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
                let slots = completed || jobName == nil ? [] : [["filename":jobName ?? "", "nzo_id":"SAB-job", "status":"Downloading", "percentage":"42.5", "timeleft":"0:03:12"]]
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
            let id = try #require(value("id"))
            requestedNZBs.append(id)
            data = id == invalidNZB ? Data() : Data("<nzb><file><segments><segment>sample@example.invalid</segment></segments></file></nzb>".utf8)
        } else {
            let offset = Int(value("offset") ?? "0") ?? 0
            searches.append(offset)
            let term = value("q") ?? ""
            if term.contains("+") { #expect(url.absoluteString.contains("%2B")) }
            terms.append(term)
            let entry = term.isEmpty ? (offset == 0 ? "a" : "older") : "archive-\(offset)"
            let older4K = include4K && offset > 0
            let standardRelease = include4K ? "Test.Release.1080p" : "Test.Release"
            let release = term.isEmpty ? (older4K ? "Test.Release.4K" : standardRelease) : "Archive.Remaster.2160p"
            let date = term.isEmpty && !older4K ? "2026-11-23T01:00:00Z" : "2020-03-01T01:00:00Z"
            data = Data("""
                <rss xmlns:n="urn:newznab"><channel><n:response offset="\(offset)" total="2"/>
                <item><n:attr name="usenetdate" value="\(date)"/><title>\(release)</title><guid>\(entry)</guid><link>https://index.example.invalid/api?t=get&amp;id=download-\(entry)</link></item>
                </channel></rss>
                """.utf8)
        }
        return (data,HTTPURLResponse(url: url,statusCode: 200,httpVersion: nil,headerFields: headers)!)
    }
}

struct MediaWorkflowTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func setup(_ api: MediaAPI, moves: FileMoves = FileMoves()) async throws -> LiveFeed {
        var config = FeedConnections()
        config.prdbKey = "test"
        config.indexers[0].address = "https://index.example.invalid/api"
        var sab = SABConnection()
        sab.address = "http://sab.example.invalid:8080"
        sab.apiKey = "test-sab"
        sab.mount = root.appending(path: "mount").path
        sab.destination = root.appending(path: "videos").path
        config.sab = sab
        let feed = try LiveFeed(root: root,http: FeedHTTP { try await api.perform($0) }, moves: moves)
        try await feed.configure(config)
        let page = try await feed.refresh()
        #expect(page.titles.first?.preview == api.artwork)
        return feed
    }

    /// Downloads the test release into the mounted folder and returns its video and the studio folder.
    private func download(_ api: MediaAPI, with feed: LiveFeed) async throws -> (clip: URL, studio: URL) {
        let output = root.appending(path: "mount/Test.Release/")
        let studio = root.appending(path: "videos/Studio North/")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: studio, withIntermediateDirectories: true)
        let clip = output.appending(path: "unrecognized.mkv")
        try Data("video".utf8).write(to: clip)
        try Data("existing".utf8).write(to: studio.appending(path: "Harbor Walk.mkv"))
        try await feed.startDownload(api.id)
        await api.finish()
        return (clip, studio)
    }

    /// An SMB or NFS share has neither hard links nor a rename that refuses to replace a file.
    @Test(arguments: [true, false])
    func filingWorksOnASharedVolume(downloadIsOnTheSameShare: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let copies = OSAllocatedUnfairLock(initialState: 0)
        let share = FileMoves(link: { _, _ in throw CocoaError(.featureUnsupported) },
                              renameExclusively: { source, _ in
                                  if source.hasSuffix(".partial") { copies.withLock { $0 += 1 } }
                                  return ENOTSUP
                              }, sameVolume: { _, _ in downloadIsOnTheSameShare })
        let api = MediaAPI()
        let feed = try await setup(api, moves: share)
        let (clip, studio) = try await download(api, with: feed)
        try await feed.followDownloads()
        let result = try #require(try await feed.transfers().first)
        #expect(result.note == nil)
        #expect(result.state == .completed)
        let target = studio.appending(path: "Harbor Walk (2).mkv")
        #expect(result.localPath == target.path)
        #expect(try Data(contentsOf: target) == Data("video".utf8))
        #expect(try Data(contentsOf: studio.appending(path: "Harbor Walk.mkv")) == Data("existing".utf8))
        #expect(!fm.fileExists(atPath: clip.path))
        #expect(try fm.contentsOfDirectory(atPath: studio.path).sorted() == ["Harbor Walk (2).mkv", "Harbor Walk.mkv"])
        // On the same share the video is renamed. Only another volume needs a copy.
        #expect(copies.withLock { $0 } == (downloadIsOnTheSameShare ? 0 : 1))
    }

    @Test func filingInterruptedAfterClaimingTheNameFinishesUnderThatName() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let share = FileMoves(link: { _, _ in throw CocoaError(.featureUnsupported) },
                              renameExclusively: { _, target in
                                  guard attempts.withLock({ $0 += 1; return $0 }) == 1 else { return ENOTSUP }
                                  // The first attempt claims the name and stops before its rename.
                                  FileManager.default.createFile(atPath: target, contents: nil)
                                  return EIO
                              }, sameVolume: { _, _ in true })
        let api = MediaAPI()
        let feed = try await setup(api, moves: share)
        let (clip, studio) = try await download(api, with: feed)
        try await feed.followDownloads()
        let interrupted = try #require(try await feed.transfers().first)
        #expect(interrupted.state == .awaitingFiling)
        #expect(FileManager.default.fileExists(atPath: clip.path))
        try await feed.followDownloads()
        let result = try #require(try await feed.transfers().first)
        #expect(result.state == .completed)
        #expect(result.localPath == studio.appending(path: "Harbor Walk (2).mkv").path)
        #expect(try Data(contentsOf: URL(filePath: try #require(result.localPath))) == Data("video".utf8))
        #expect(!FileManager.default.fileExists(atPath: clip.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func theEngineAnswersWhileAVideoIsStillBeingFiled() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let slow = FileMoves(link: { source, target in
            started.signal()
            proceed.wait()
            try FileManager.default.linkItem(at: source, to: target)
        })
        let api = MediaAPI()
        let feed = try await setup(api, moves: slow)
        _ = try await download(api, with: feed)
        let filing = Task { try await feed.followDownloads() }
        await withCheckedContinuation { waiting in
            DispatchQueue.global().async { started.wait(); waiting.resume() }
        }
        // A copy between volumes can take minutes. The catalog and the job list stay available meanwhile.
        #expect(try await feed.transfers().first?.state == .downloaded)
        #expect(try await feed.cached().titles.isEmpty)
        proceed.signal()
        try await filing.value
        #expect(try await feed.transfers().first?.state == .completed)
    }

    @Test func removingADownloadKeepsItsVideoAndOffersTheTitleAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI()
        let feed = try await setup(api)
        let (_, studio) = try await download(api, with: feed)
        try await feed.followDownloads()
        let filed = try #require(try await feed.transfers().first)
        #expect(filed.completed)
        #expect(try await feed.cached().titles.isEmpty)
        try await feed.removeTransfer(filed.video)
        #expect(try await feed.transfers().isEmpty)
        #expect(FileManager.default.fileExists(atPath: studio.appending(path: "Harbor Walk (2).mkv").path))
        #expect(try await feed.cached().titles.map(\.id) == [api.id])
    }

    @Test(arguments: [nil, .p2160, .p1080] as [ReleaseQuality?])
    func automaticDownloadUsesSavedPreference(preference: ReleaseQuality?) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI(include4K: true)
        let feed = try await setup(api)
        _ = try await feed.refresh(earlier: true)
        var config = try #require(try await feed.connections())
        config.sab?.preferredQuality = preference
        try await feed.configure(config)
        let reopened = try LiveFeed(root: root, http: FeedHTTP { try await api.perform($0) })
        let qualities = try await reopened.cached().titles.first?.offers.compactMap(\.quality)
        #expect(qualities == (preference == .p1080 ? ["1080p", "2160p"] : ["2160p", "1080p"]))
        try await reopened.startDownload(api.id)
        #expect(await api.requestedNZBs == [preference == .p2160 ? "download-older" : "download-a"])
        #expect(await api.submissions == 1)
    }

    @Test func manualDownloadIsExactAndOnlyAutomaticSelectionFallsBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI(include4K: true)
        let feed = try await setup(api)
        let page = try await feed.refresh(earlier: true)
        let older = try #require(page.titles.first?.offers.first { $0.name == "Test.Release.4K" })
        await #expect(throws: FeedError.self) { try await feed.startDownload(api.id, offerID: "missing") }
        #expect(await api.requestedNZBs.isEmpty)

        await api.invalidateNZB("download-older")
        await #expect(throws: FeedError.self) { try await feed.startDownload(api.id, offerID: older.id) }
        #expect(await api.requestedNZBs == ["download-older"])
        #expect(await api.submissions == 0)

        var config = try #require(try await feed.connections())
        config.sab?.preferredQuality = .p2160
        try await feed.configure(config)
        try await feed.startDownload(api.id)
        #expect(await api.requestedNZBs == ["download-older", "download-older", "download-a"])
        #expect(await api.submissions == 1)
    }

    @Test func manualDownloadOverridesQualityPreferenceAndRecordsChosenRelease() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI(include4K: true)
        let feed = try await setup(api)
        let page = try await feed.refresh(earlier: true)
        let newest = try #require(page.titles.first?.offers.first { $0.quality == "1080p" })
        var config = try #require(try await feed.connections())
        config.sab?.preferredQuality = .p2160
        try await feed.configure(config)
        try await feed.startDownload(api.id, offerID: newest.id)
        try await feed.startDownload(api.id)
        #expect(await api.requestedNZBs == ["download-a"])
        #expect(await api.submissions == 1)
        #expect(try await feed.transfers().first?.releaseName == newest.name)
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
        #expect(result.state == .completed)
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
        let job = try #require(try await feed.transfers().first)
        #expect(job.state.rawValue == "Downloading")
        #expect(job.progress == 42.5)
        #expect(job.timeLeft == "0:03:12")
        #expect(job.jobName == "Test.Release")
        await api.finish()
        try await feed.followDownloads()
        let received = try #require(try await feed.transfers().first)
        #expect(received.progress == 100)
        #expect(received.timeLeft == nil)
    }

    @Test func indexerSearchHasIndependentPagesAndResultsSurviveRestart() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI()
        let feed = try await setup(api)
        let term = "Shore + sea & sand"
        #expect(CatalogFilter().titles(in: try await feed.cached(), matching: term, search: nil).isEmpty)
        let first = try await feed.refresh(search: IndexerSearch(term: term))
        let search = try #require(first.indexerSearch)
        #expect(search.hasMore)
        #expect(CatalogFilter().titles(in: first, matching: term, search: search).map(\.id) == [api.archiveID])
        let second = try await feed.refresh(search: search)
        #expect(second.indexerSearch?.hasMore == false)
        #expect(second.indexerSearch?.offerIDs.count == 2)
        #expect(second.oldestBrowsed == feedDate("2026-11-23T01:00:00Z"))
        #expect(second.hasEarlier)
        let reopened = try LiveFeed(root: root, http: FeedHTTP { try await api.perform($0) })
        let page = try await reopened.refresh(earlier: true)
        #expect(!page.hasEarlier)
        #expect(await api.terms == ["",term,term,""])
        #expect(await api.searches == [0,0,1,1])
        var filter = CatalogFilter()
        filter.studioIDs = [.namedStudio("Studio North")]
        filter.indexer = "index.example.invalid"
        filter.quality = "2160p"
        #expect(filter.titles(in: page, matching: "archive remaster", search: nil).map(\.id) == [api.archiveID])
        filter.days = 7
        #expect(filter.titles(in: page, matching: "", search: nil, now: try #require(page.oldestBrowsed)).isEmpty)
    }

    @Test func olderSearchListingsRemainAvailableForNinetyDays() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let api = MediaAPI()
        let feed = try await setup(api)
        let now = Date.now
        _ = try await feed.refresh(search: IndexerSearch(term: "shore"), now: now)
        let afterMonth = try await feed.refresh(now: now.addingTimeInterval(30 * 86400))
        #expect(afterMonth.titles.contains { $0.id == api.archiveID })
        let expired = try await feed.refresh(now: now.addingTimeInterval(91 * 86400))
        #expect(!expired.titles.contains { $0.id == api.archiveID })
        #expect(expired.hasEarlier)
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

    @Test func samplesBesideTheVideoDoNotMakeAJobAmbiguous() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "job")
        try FileManager.default.createDirectory(at: folder.appending(path: "Sample"), withIntermediateDirectories: true)
        var sab = SABConnection()
        sab.mount = root.path
        try Data(count: 4000).write(to: folder.appending(path: "feature.mp4"))
        try Data(count: 3000).write(to: folder.appending(path: "Sample/feature-sample.mp4"))
        try Data(count: 100).write(to: folder.appending(path: "trailer.mkv"))
        #expect(try LiveFeed.completedVideo("/downloads/complete/job", sab: sab).lastPathComponent == "feature.mp4")
        // A second video of comparable size is a second video.
        try Data(count: 3000).write(to: folder.appending(path: "part2.mp4"))
        #expect(throws: FeedError.self) { try LiveFeed.completedVideo("/downloads/complete/job", sab: sab) }
    }
}

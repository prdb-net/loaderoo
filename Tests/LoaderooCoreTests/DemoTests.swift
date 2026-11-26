import Foundation
import Testing
@testable import LoaderooCore

struct DemoTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    /// The demo replaces only the network. Matching, download tracking and filing are the live ones.
    @Test func demoFollowsItsDownloadIntoTheStudioFolderAcrossARestart() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await Demo.open(root: root, downloadDuration: 3600)
        let page = try await feed.refresh()
        #expect(page.issues.isEmpty)
        #expect(page.titles.count == 1)
        let title = try #require(page.titles.first)
        #expect(title.title == "Night Shift")
        #expect(title.studio == "Studio North")
        #expect(title.sources == ["Harbor Index", "North Index"])
        #expect(title.qualities == ["540p"])
        let artwork = try #require(title.preview.flatMap(Demo.media(for:)))
        #expect(FileManager.default.fileExists(atPath: artwork.path))

        try await feed.startDownload(title.id)
        try await feed.followDownloads()
        let pending = try #require(try await feed.transfers().first)
        #expect(pending.state.rawValue == "Downloading")
        #expect(pending.jobName == "Studio.North.Night.Shift.540p")

        // Quit while the job is pending and come back once it is done.
        let reopened = try await Demo.open(root: root, downloadDuration: 0)
        try await reopened.followDownloads()
        let filed = try #require(try await reopened.transfers().first)
        #expect(filed.note == nil)
        #expect(filed.state == .completed)
        #expect(filed.localPath == root.appending(path: "Library/Studio North/Night Shift.mp4").path)
        #expect(FileManager.default.fileExists(atPath: try #require(filed.localPath)))
        #expect(try await reopened.cached().titles.isEmpty)

        #expect(try await reopened.syncReferenceCatalog())
        let catalog = try await reopened.referenceCatalog()
        #expect(catalog.studios.map(\.name) == ["Studio North"])
        #expect(catalog.videoCount == 1)
        #expect(try await reopened.referenceVideos(matching: "night", limit: 5).map(\.title) == ["Night Shift"])
    }

    @Test func searchingTheDemoIndexersFindsOnlyTheDemoRelease() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = try await Demo.open(root: root)
        let found = try await feed.refresh(search: IndexerSearch(term: "night shift"))
        #expect(found.indexerSearch?.offerIDs.count == 2)
        #expect(found.indexerSearch?.hasMore == false)
        let missing = try await feed.refresh(search: IndexerSearch(term: "something else"))
        #expect(missing.indexerSearch?.offerIDs.isEmpty == true)
        #expect(missing.issues.isEmpty)
    }
}

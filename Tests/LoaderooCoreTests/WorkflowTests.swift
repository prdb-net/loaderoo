import Foundation
import GRDB
import Testing
@testable import LoaderooCore

struct WorkflowTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    @Test func feedToFiledVideoAcrossRestart() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try Workflow(root: root)
        let feed = try await engine.snapshot()
        #expect(feed.releases.count == 1)
        let release = try #require(feed.releases.first)
        #expect(release.sourceCount == 2)
        #expect(FileManager.default.fileExists(atPath: release.video.preview.path))
        let sent = try await engine.download(id: release.id, now: start)
        let first = try #require(sent.downloads.first)
        #expect(first.source == "Harbor Index")
        #expect(first.job != nil)
        #expect(!first.filed)
        let repeated = try await engine.download(id: release.id, now: start)
        #expect(repeated.downloads.count == 1)
        #expect(repeated.downloads.first?.job == first.job)

        let restarted = try Workflow(root: root)
        let completed = try await restarted.refresh(now: start.addingTimeInterval(30))
        #expect(completed.releases.isEmpty)
        let video = try #require(completed.library.first)
        let path = root.appending(path: "Library/Studio North/Night Shift.mp4")
        #expect(video.id == release.id)
        #expect(video.finalPath == path.path)
        #expect(try Data(contentsOf: path) == Data(contentsOf: Fixture.clip))
        let reopened = try Workflow(root: root)
        #expect(try await reopened.refresh().releases.isEmpty)
        #expect(try await reopened.download(id: release.id).library.count == 1)
        let sab = try DemoSAB(root: root, duration: 12)
        #expect(try await sab.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM queue") } == 1)
    }

    @Test func restartBetweenClientAcceptanceAndCatalogUpdate() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try Workflow(root: root)
        let sent = try await engine.download(id: Fixture.video.id, now: start)
        let job = try #require(sent.downloads.first?.job)
        let db = try DatabaseQueue(path: root.appending(path: "Catalog.sqlite").path)
        try await db.write { try $0.execute(sql: "UPDATE download SET job = NULL") }
        let resumed = try Workflow(root: root)
        #expect(try await resumed.refresh(now: start).downloads.first?.job == job)
    }

    @Test func filenameCollisionAndInterruptedMove() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = root.appending(path: "Library/Studio North")
        try FileManager.default.createDirectory(at: studio, withIntermediateDirectories: true)
        let existing = studio.appending(path: "Night Shift.mp4")
        try Data("existing".utf8).write(to: existing)
        let engine = try Workflow(root: root, downloadDuration: 0)
        let result = try await engine.download(id: Fixture.video.id, now: start)
        #expect(result.library.first?.finalPath == studio.appending(path: "Night Shift (2).mp4").path)
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
        // Simulate loss of the final catalog commit after the filesystem move.
        let db = try DatabaseQueue(path: root.appending(path: "Catalog.sqlite").path)
        try await db.write { try $0.execute(sql: "UPDATE download SET filed = 0") }
        let resumed = try Workflow(root: root)
        #expect(try await resumed.refresh().library.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: studio.path).count == 2)
    }

    @Test func matchingAndMappedPaths() throws {
        let unknown = Listing(source: "North Index", entry: "other", releaseName: "Unknown", posted: start)
        #expect(Fixture.releases([unknown]).isEmpty)
        for path in ["/downloads/completed/movie.mp4", "/downloads/complete/../movie.mp4", "/downloads/complete/"] {
            #expect(throws: DemoError.self) { try Workflow.map(path, mount: root) }
        }
    }
}

import Foundation
import GRDB

public struct Video: Equatable, Sendable {
    public let id: String
    public let title: String
    public let studio: String
    public let preview: URL
}

struct Listing: Sendable {
    let source: String
    let entry: String
    let releaseName: String
    let posted: Date
}

public struct Release: Identifiable, Sendable {
    public var id: String { video.id }
    public let video: Video
    public let posted: Date
    public let sourceCount: Int
    let listing: Listing
}

enum Fixture {
    static let video = Video(id: "demo-video-01", title: "Night Shift", studio: "Studio North",
                             preview: Bundle.module.url(forResource: "NightShift", withExtension: "jpg")!)
    static let clip = Bundle.module.url(forResource: "NightShift", withExtension: "mp4")!
    static let releaseName = "Studio.North.Night.Shift.540p"
    static let indexers = [DemoIndexer(name: "Harbor Index", key: "h-17"),
                          DemoIndexer(name: "North Index", key: "n-94")]

    static func resolve(_ listing: Listing) -> Video? {
        listing.releaseName == releaseName ? video : nil
    }

    static func releases(_ listings: [Listing]) -> [Release] {
        let matches = listings.compactMap { listing in resolve(listing).map { ($0, listing) } }
        return Dictionary(grouping: matches, by: { $0.0.id }).values.compactMap { group in
            // Prefer the newest listing. Stable keys break ties across refreshes.
            let ranked = group.sorted {
                if $0.1.posted != $1.1.posted { return $0.1.posted > $1.1.posted }
                return ($0.1.source, $0.1.entry) < ($1.1.source, $1.1.entry)
            }
            guard let (video, best) = ranked.first else { return nil }
            return Release(video: video, posted: best.posted,
                           sourceCount: Set(group.map { $0.1.source }).count, listing: best)
        }.sorted { $0.posted > $1.posted }
    }
}

struct DemoIndexer {
    let name: String
    let key: String

    func recent() -> [Listing] {
        [Listing(source: name, entry: key, releaseName: Fixture.releaseName,
                 posted: Date(timeIntervalSince1970: 1_795_428_000))]
    }

    func nzb(for entry: String) throws -> Data {
        guard entry == key else { throw DemoError.message("The indexer no longer has this upload.") }
        return Data("""
        <nzb xmlns="http://www.newzbin.com/DTD/2003/nzb"><file poster="demo" date="1795428000" subject="Night Shift">
        <groups><group>example.demo</group></groups><segments><segment bytes="1" number="1">demo@example.invalid</segment></segments></file></nzb>
        """.utf8)
    }
}

enum DemoError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(text): text }
    }
}

// A separate database stands in for the external download client's queue and history.
final class DemoSAB {
    let db: DatabaseQueue
    let share: URL
    let duration: TimeInterval

    init(root: URL, duration: TimeInterval) throws {
        self.duration = duration
        share = root.appending(path: "Mounted Share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        db = try DatabaseQueue(path: root.appending(path: "DemoSAB.sqlite").path)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS queue (
                    id TEXT PRIMARY KEY, request TEXT UNIQUE NOT NULL, nzb BLOB NOT NULL,
                    started DOUBLE NOT NULL, completedPath TEXT)
                """)
        }
    }

    func submit(nzb: Data, request: String, now: Date) throws -> String {
        try db.write { db in
            if let id = try String.fetchOne(db, sql: "SELECT id FROM queue WHERE request = ?", arguments: [request]) {
                return id
            }
            let id = UUID().uuidString
            try db.execute(sql: "INSERT INTO queue (id, request, nzb, started) VALUES (?, ?, ?, ?)",
                           arguments: [id, request, nzb, now.timeIntervalSince1970])
            return id
        }
    }

    func completedPath(id: String, now: Date) throws -> String? {
        try db.write { db in
            guard let job = try Row.fetchOne(db, sql: "SELECT * FROM queue WHERE id = ?", arguments: [id]) else {
                throw DemoError.message("The demo download client could not find the queued job.")
            }
            if let path: String = job["completedPath"] { return path }
            let started: Double = job["started"]
            guard now.timeIntervalSince1970 >= started + duration else { return nil }
            let folder = share.appending(path: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "night.shift.demo.mp4")
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data(contentsOf: Fixture.clip).write(to: file, options: .atomic)
            }
            let reported = "/downloads/complete/" + id + "/" + file.lastPathComponent
            try db.execute(sql: "UPDATE queue SET completedPath = ? WHERE id = ?", arguments: [reported, id])
            return reported
        }
    }
}

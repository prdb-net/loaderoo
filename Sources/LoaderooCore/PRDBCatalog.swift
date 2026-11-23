import Foundation
import GRDB

public struct PRDBCatalog: Sendable {
    public static let videoLimit = 20_000
    public var studios: [CatalogSubject] = []
    public var actors: [CatalogSubject] = []
    public var videoCount = 0
    public var olderCreditPage: Int?
    public let revision = UUID()
    public init() {}

    static func createTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS prdbStudio(id TEXT PRIMARY KEY, name TEXT NOT NULL, context TEXT, logo TEXT);
            CREATE TABLE IF NOT EXISTS prdbCredit(id TEXT PRIMARY KEY, name TEXT NOT NULL, seen REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS prdbVideo(id TEXT PRIMARY KEY, title TEXT NOT NULL, studio TEXT NOT NULL,
                released TEXT, created REAL NOT NULL, seen REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS prdbVideoOrder ON prdbVideo(created DESC,id DESC);
            CREATE INDEX IF NOT EXISTS prdbVideoWindow ON prdbVideo(seen DESC,created DESC,id DESC);
            CREATE TABLE IF NOT EXISTS prdbSiteCursor(singleton INTEGER PRIMARY KEY, since TEXT NOT NULL, afterId TEXT, due REAL NOT NULL);
            INSERT OR IGNORE INTO prdbSiteCursor VALUES(1,'0001-01-01T00:00:00Z',NULL,0);
            CREATE TABLE IF NOT EXISTS prdbVideoPass(kind TEXT PRIMARY KEY, page INTEGER NOT NULL, anchor REAL, due REAL NOT NULL);
            INSERT OR IGNORE INTO prdbVideoPass VALUES('recent',1,NULL,0),('credits',0,NULL,0);
            """)
    }
}

public struct PRDBCatalogVideo: Identifiable, Sendable {
    public let id: UUID
    public let title, studio: String
    public let releaseDate: String?
}

private struct SiteChanges: Decodable {
    struct Cursor: Decodable { let updatedAtUtc: String; let id: UUID }
    struct Item: Decodable {
        struct Site: Decodable {
            let id: UUID
            let title, networkTitle, platformTitle, logoUrl: String?
            let isDeleted: Bool
        }
        let site: Site
    }
    let items: [Item]
    let hasMore: Bool
    let nextCursor: Cursor?
    let serverTimeUtc: String
}

private struct VideoSummaries: Decodable {
    struct Video: Decodable {
        struct Actor: Decodable { let id: UUID; let name: String }
        let id: UUID
        let title, siteTitle, createdAtUtc: String
        let releaseDate: String?
        let actors: [Actor]
    }
    let page, pageSize, totalCount: Int
    let items: [Video]
}

extension LiveFeed {
    public func referenceCatalog() throws -> PRDBCatalog {
        try store.read { db in
            var catalog = PRDBCatalog()
            let sort = DatabaseCollation.localizedStandardCompare.name
            catalog.studios = try Row.fetchAll(db, sql: "SELECT * FROM prdbStudio ORDER BY name COLLATE \(sort),id").compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return CatalogSubject(id: .studio(id), name: row["name"], portrait: PRDBFeed.imageURL(row["logo"]), context: row["context"])
            }
            catalog.actors = try Row.fetchAll(db, sql: "SELECT id,name FROM prdbCredit ORDER BY name COLLATE \(sort),id").compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return CatalogSubject(id: .actor(id), name: row["name"], portrait: nil, context: nil)
            }
            catalog.videoCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM prdbVideo") ?? 0
            catalog.olderCreditPage = try Int.fetchOne(db, sql: "SELECT page FROM prdbVideoPass WHERE kind='credits' AND page>0")
            return catalog
        }
    }

    public func referenceVideos(matching query: String, limit: Int) throws -> [PRDBCatalogVideo] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM prdbVideo WHERE ?='' OR instr(swiftLocalizedLowercaseString(title),?) OR instr(swiftLocalizedLowercaseString(studio),?)
                ORDER BY created DESC,id DESC LIMIT ?
                """, arguments: [term,term.localizedLowercase,term.localizedLowercase,max(0, min(limit, PRDBCatalog.videoLimit))]).compactMap { row in
                    guard let id = UUID(uuidString: row["id"]) else { return nil }
                    return PRDBCatalogVideo(id: id, title: row["title"], studio: row["studio"], releaseDate: row["released"])
                }
        }
    }

    /// A bounded background turn. Cursor and rows from each successful request commit together.
    public func syncReferenceCatalog(now: Date = .now) async throws -> Bool {
        let service = "PRDB-catalog"
        guard !busy, let config = try connections(), try clock(for: "PRDB", now: now, includePoll: false),
              try clock(for: service, now: now, includePoll: true) else { return false }
        busy = true
        defer { busy = false }
        let timestamp = now.timeIntervalSince1970
        let ready = try await store.write { db in
            guard try !Self.hasDueMetadata(db, at: timestamp) else { return false }
            try db.execute(sql: "INSERT OR REPLACE INTO sourceClock(id,poll) VALUES (?,?)", arguments: [service,timestamp+60])
            return true
        }
        guard ready else { return false }
        var changed = false
        do {
            // Reserve room for videos even when a new installation has many pages of studios.
            try Task.checkCancellation()
            let sites = try await syncSiteChanges(key: config.prdbKey, now: timestamp)
            changed = sites
            for _ in 0..<(sites ? 3 : 4) {
                try Task.checkCancellation()
                guard try clock(for: "PRDB", now: now, includePoll: false) else { break }
                guard try await syncVideoPage(key: config.prdbKey, now: timestamp) else { break }
                changed = true
            }
        } catch {
            try Task.checkCancellation()
            let failure = error as? HTTPFailure
            let shared = failure?.status == 429 || failure?.retryAt != nil
            try backoff(error, service: shared ? "PRDB" : service, now: now)
            throw FeedError("PRDB catalog: " + error.localizedDescription)
        }
        return changed
    }

    private func syncSiteChanges(key: String, now: Double) async throws -> Bool {
        let cursor = try await store.read { db in
            try Row.fetchOne(db, sql: "SELECT since,afterId FROM prdbSiteCursor WHERE due<=?", arguments: [now])
                .map { ($0["since"] as String, $0["afterId"] as String?) }
        }
        guard let (since, afterID) = cursor else { return false }
        var query = [URLQueryItem(name: "since", value: since), .init(name: "pageSize", value: "500")]
        if let afterID { query.append(.init(name: "sinceId", value: afterID)) }
        let result: SiteChanges = try await prdb.fetch("sites/changes", key: key, query: query)
        guard result.items.isEmpty ? !result.hasMore : result.nextCursor != nil else { throw FeedError("Invalid studio continuation.") }
        try Task.checkCancellation()
        try await store.write { db in
            for item in result.items {
                let site = item.site
                if site.isDeleted {
                    try db.execute(sql: "DELETE FROM prdbStudio WHERE id=?", arguments: [site.id.uuidString])
                } else {
                    guard let title = site.title else { throw FeedError("A PRDB studio is missing its title.") }
                    try db.execute(sql: "INSERT OR REPLACE INTO prdbStudio VALUES(?,?,?,?)",
                                   arguments: [site.id.uuidString,title,site.networkTitle ?? site.platformTitle,site.logoUrl])
                }
            }
            try db.execute(sql: "UPDATE prdbSiteCursor SET since=?,afterId=?,due=?",
                           arguments: [result.nextCursor?.updatedAtUtc ?? result.serverTimeUtc, result.nextCursor?.id.uuidString,
                                       result.hasMore ? now : now+3600])
        }
        return true
    }

    private func syncVideoPage(key: String, now: Double) async throws -> Bool {
        let job = try await store.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM prdbVideoPass WHERE page>0 AND due<=? ORDER BY kind='recent' DESC LIMIT 1
                """, arguments: [now]).map { ($0["kind"] as String, $0["page"] as Int, $0["anchor"] as Double?) }
        }
        guard let (kind, page, savedAnchor) = job else { return false }
        let anchor = savedAnchor ?? now
        let before = Date(timeIntervalSince1970: anchor).ISO8601Format()
        let size = 100
        let query = [URLQueryItem(name: "page", value: String(page)), .init(name: "pageSize", value: String(size)),
                     .init(name: "sortBy", value: "createdAtUtc"), .init(name: "sortDirection", value: "desc"),
                     .init(name: "createdBefore", value: before)]
        let result: VideoSummaries = try await prdb.fetch("videos", key: key, query: query)
        guard result.page == page, result.pageSize == size, result.items.count <= size else {
            throw FeedError("PRDB returned a different video page.")
        }
        let recent = kind == "recent"
        let more = page * size < result.totalCount
        try Task.checkCancellation()
        try await store.write { db in
            for video in result.items {
                if recent {
                    guard let created = feedDate(video.createdAtUtc) else { throw FeedError("Invalid PRDB creation date.") }
                    try db.execute(sql: "INSERT OR REPLACE INTO prdbVideo VALUES(?,?,?,?,?,?)",
                                   arguments: [video.id.uuidString,video.title,video.siteTitle,video.releaseDate,created.timeIntervalSince1970,anchor])
                }
                for actor in video.actors {
                    try db.execute(sql: """
                        INSERT INTO prdbCredit VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET
                        name=excluded.name,seen=excluded.seen WHERE excluded.seen>=seen
                        """, arguments: [actor.id.uuidString,actor.name,anchor])
                }
            }
            if recent {
                try db.execute(sql: """
                    DELETE FROM prdbVideo WHERE id IN (SELECT id FROM prdbVideo ORDER BY seen DESC,created DESC,id DESC LIMIT -1 OFFSET ?)
                    """, arguments: [PRDBCatalog.videoLimit])
            }
            if more && (!recent || page * size < PRDBCatalog.videoLimit) {
                try db.execute(sql: "UPDATE prdbVideoPass SET page=?,anchor=? WHERE kind=?", arguments: [page+1,anchor,kind])
                return
            }
            if recent {
                try db.execute(sql: "DELETE FROM prdbVideo WHERE seen<?", arguments: [anchor])
                try db.execute(sql: "UPDATE prdbVideoPass SET page=1,anchor=NULL,due=? WHERE kind='recent'", arguments: [now+86400])
                if more {
                    let creditsDue = try Bool.fetchOne(db, sql: "SELECT page=0 AND due<=? FROM prdbVideoPass WHERE kind='credits'", arguments: [now])
                    guard creditsDue == true else { return }
                    try db.execute(sql: "UPDATE prdbVideoPass SET page=?,anchor=?,due=? WHERE kind='credits'", arguments: [page+1,anchor,now])
                    return
                }
            }
            // Only a completed pass over all credits can retire an actor with no remaining videos.
            try db.execute(sql: "DELETE FROM prdbCredit WHERE seen<?", arguments: [anchor])
            try db.execute(sql: "UPDATE prdbVideoPass SET page=0,anchor=NULL,due=? WHERE kind='credits'", arguments: [now+30*86400])
        }
        return true
    }
}

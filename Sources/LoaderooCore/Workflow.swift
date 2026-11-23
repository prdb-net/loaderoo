import Foundation
import GRDB

public struct Download: FetchableRecord, Decodable, Identifiable, Sendable {
    public let id: String
    public let source: String
    let entry: String
    let request: String
    public let job: String?
    public let finalPath: String?
    let fileID: String?
    public let filed: Bool
    public var video: Video { Fixture.video }
}

public struct Snapshot: Sendable {
    public let releases: [Release]
    public let downloads: [Download]
    public var library: [Download] { downloads.filter(\.filed) }
}

public actor Workflow {
    private let catalog: DatabaseQueue
    private let sab: DemoSAB
    private let listings: [Listing]
    private let library: URL

    public init(root: URL, downloadDuration: TimeInterval = 12) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = root.appending(path: "Library")
        listings = Fixture.indexers.flatMap { $0.recent() }
        catalog = try DatabaseQueue(path: root.appending(path: "Catalog.sqlite").path)
        sab = try DemoSAB(root: root, duration: downloadDuration)
        try catalog.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS download (
                    id TEXT PRIMARY KEY, source TEXT NOT NULL, entry TEXT NOT NULL,
                    request TEXT UNIQUE NOT NULL, job TEXT, finalPath TEXT, fileID TEXT,
                    filed BOOLEAN NOT NULL DEFAULT 0)
                """)
        }
    }

    public func snapshot() throws -> Snapshot {
        let jobs = try catalog.read { try Download.fetchAll($0, sql: "SELECT * FROM download ORDER BY rowid DESC") }
        let owned = Set(jobs.filter(\.filed).map(\.id))
        return Snapshot(releases: Fixture.releases(listings).filter { !owned.contains($0.id) }, downloads: jobs)
    }

    public func download(id: String, now: Date = .now) throws -> Snapshot {
        guard let release = Fixture.releases(listings).first(where: { $0.id == id }) else {
            throw DemoError.message("This release is no longer available.")
        }
        try catalog.write { db in
            try db.execute(sql: """
                INSERT INTO download (id, source, entry, request) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [id, release.listing.source, release.listing.entry, UUID().uuidString])
        }
        return try refresh(now: now)
    }

    public func refresh(now: Date = .now) throws -> Snapshot {
        for item in try snapshot().downloads where !item.filed {
            guard let provider = Fixture.indexers.first(where: { $0.name == item.source }) else {
                throw DemoError.message("The download’s indexer is unavailable.")
            }
            let job: String
            if let existing = item.job {
                job = existing
            } else {
                job = try sab.submit(nzb: provider.nzb(for: item.entry), request: item.request, now: now)
                try catalog.write {
                    try $0.execute(sql: "UPDATE download SET job = ? WHERE id = ?", arguments: [job, item.id])
                }
            }
            if let path = try sab.completedPath(id: job, now: now) {
                try file(item, from: Self.map(path, mount: sab.share))
            }
        }
        return try snapshot()
    }

    static func map(_ path: String, mount: URL) throws -> URL {
        let prefix = "/downloads/complete/"
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix(prefix), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DemoError.message("The completed path is outside the configured share.")
        }
        let url = parts.reduce(mount) { $0.appending(path: String($1)) }
        guard url.resolvingSymlinksInPath().path.hasPrefix(mount.resolvingSymlinksInPath().path + "/") else {
            throw DemoError.message("The completed file is outside the configured share.")
        }
        return url
    }

    // Persist the destination before moving. On restart the file identity confirms
    // that an existing destination is our move, even after a filename collision.
    private func file(_ item: Download, from source: URL) throws {
        let fm = FileManager.default
        if let path = item.finalPath, let expected = item.fileID,
           try Self.identity(at: path) == expected {
            try markFiled(item.id)
            return
        }
        guard let identity = try Self.identity(at: source.path) else {
            throw DemoError.message("Waiting for the completed file on the mounted share.")
        }
        let folder = library.appending(path: item.video.studio)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var suffix = 1
        while true {
            let stem = item.video.title + (suffix == 1 ? "" : " (\(suffix))")
            let target = folder.appending(path: stem).appendingPathExtension(source.pathExtension)
            suffix += 1
            if fm.fileExists(atPath: target.path) { continue }
            try catalog.write {
                try $0.execute(sql: "UPDATE download SET finalPath = ?, fileID = ? WHERE id = ?",
                               arguments: [target.path, identity, item.id])
            }
            do {
                try fm.moveItem(at: source, to: target)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            try markFiled(item.id)
            return
        }
    }

    private func markFiled(_ id: String) throws {
        try catalog.write { try $0.execute(sql: "UPDATE download SET filed = 1 WHERE id = ?", arguments: [id]) }
    }

    private static func identity(at path: String) throws -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                throw DemoError.message("The file identity could not be read.")
            }
            return "\(device):\(inode)"
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }
}

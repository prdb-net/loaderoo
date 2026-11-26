import Foundation
import GRDB

public struct LibraryFolder: Decodable, FetchableRecord, Identifiable, Sendable {
    public let path: String
    public let offline: Bool
    public var id: String { path }
}

public struct LibraryFile: Decodable, FetchableRecord, Identifiable, Sendable {
    public let path: String
    public let size: Int64
    public let video: String?
    public let title: String?
    public let studio: String?
    public let image: String?
    public let offline: Bool
    public var id: String { path }
    public var url: URL { URL(filePath: path) }
}

enum LibraryScanner {
    static let extensions = Set(["mp4", "m4v", "mov", "mkv", "avi", "wmv", "webm", "mpg", "mpeg", "ts"])

    static func hash(_ url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let block = 65_536
        guard length >= 2 * block else { return nil }
        var sum = length
        for position in [0, length - UInt64(block)] {
            try handle.seek(toOffset: position)
            var buffer = Data()
            while buffer.count < block {
                guard let bytes = try handle.read(upToCount: block - buffer.count), !bytes.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                buffer.append(bytes)
            }
            buffer.withUnsafeBytes { data in
                for offset in stride(from: 0, to: block, by: 8) {
                    sum &+= UInt64(littleEndian: data.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", sum)
    }

    static func discover(root: String, db: DatabaseQueue) throws {
        let folder = URL(filePath: root)
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]
        var incomplete = false
        guard FileManager.default.isReadableFile(atPath: root),
              let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in incomplete = true; return true }) else {
            try db.write { try $0.execute(sql: "UPDATE folder SET offline=1 WHERE path=?", arguments: [root]) }
            return
        }
        let generation = UUID().uuidString
        let known = try db.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT path,size,modified FROM libraryFile WHERE root=?", arguments: [root]).map {
                ($0["path"] as String, ($0["size"] as Int, $0["modified"] as Double))
            })
        }
        let managed = try db.read { db in
            try Dictionary(Row.fetchAll(db, sql: """
                SELECT t.localPath,t.video,t.title,t.studio,t.image,f.size,f.modified FROM transfer t
                JOIN completedFile f ON f.video=t.video WHERE t.localPath IS NOT NULL ORDER BY t.created
                """).map { ($0["localPath"] as String, $0) }, uniquingKeysWith: { _,new in new })
        }
        struct Entry {
            let path: String
            let size: Int
            let modified: Double
            let hash: String?
            let trusted: Row?
        }
        var unchanged: [String] = []
        var changed: [Entry] = []
        var found = 0
        func flush() throws {
            try db.write { database in
                for path in unchanged {
                    try database.execute(sql: "UPDATE libraryFile SET seen=? WHERE path=?", arguments: [generation,path])
                }
                for file in changed {
                    let row = file.trusted
                    try database.execute(sql: """
                        INSERT OR REPLACE INTO libraryFile(path,root,size,modified,hash,seen,video,title,studio,image)
                        VALUES(?,?,?,?,?,?,?,?,?,?)
                        """, arguments: [file.path,root,file.size,file.modified,file.hash,generation,row?["video"] as String?,
                                         row?["title"] as String?,row?["studio"] as String?,row?["image"] as String?])
                }
            }
            unchanged.removeAll(keepingCapacity: true)
            changed.removeAll(keepingCapacity: true)
        }
        for case let url as URL in walk {
            try Task.checkCancellation()
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let properties: URLResourceValues
            do { properties = try url.resourceValues(forKeys: resourceKeys) }
            catch { incomplete = true; continue }
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  let bytes = properties.fileSize, let modified = properties.contentModificationDate?.timeIntervalSince1970 else { continue }
            let path = url.resolvingSymlinksInPath().path
            found += 1
            if let cached = known[path], cached == (bytes,modified) {
                unchanged.append(path)
            } else {
                let row = managed[path]
                let trusted = row.flatMap { ($0["size"] as Int == bytes && $0["modified"] as Double == modified) ? $0 : nil }
                do {
                    let hash = trusted == nil ? try Self.hash(url) : nil
                    changed.append(Entry(path: path,size: bytes,modified: modified,hash: hash,trusted: trusted))
                } catch { incomplete = true; continue }
            }
            if changed.count + unchanged.count >= 200 { try flush() }
        }
        try flush()
        // A share that dropped away can leave its mount point behind as an empty, readable folder.
        // Treat a library that lost every video at once like an offline one and keep its matches.
        if found == 0, !known.isEmpty { incomplete = true }
        try db.write {
            try $0.execute(sql: "UPDATE folder SET offline=? WHERE path=?", arguments: [incomplete,root])
            if !incomplete { try $0.execute(sql: "DELETE FROM libraryFile WHERE root=? AND seen!=?", arguments: [root,generation]) }
        }
    }
}

private struct HashInput: Encodable, Sendable {
    let ref, filename, osHash: String
    let filesize: Int64
}
private struct FileAnswer: Decodable {
    let ref: String
    let confidence: Int
    let matchedBy: Int?
    let videoId: UUID?
    let candidates: [UUID]
    struct Detail: Decodable {
        struct Site: Decodable { let title: String }
        struct Image: Decodable { let url: String? }
        let title: String
        let site: Site?
        let images: [Image]?
    }
    let video: Detail?
}

extension LiveFeed {
    public func folders() throws -> [LibraryFolder] {
        try store.read { try LibraryFolder.fetchAll($0, sql: "SELECT * FROM folder ORDER BY path") }
    }

    public func library() throws -> [LibraryFile] {
        try store.read { try LibraryFile.fetchAll($0, sql: """
            SELECT f.*, d.offline FROM libraryFile f JOIN folder d ON f.root=d.path
            ORDER BY COALESCE(f.title,f.path) COLLATE NOCASE
            """) }
    }

    public func addFolder(_ url: URL) throws {
        guard !scanning else { throw FeedError("Wait for the current library scan to finish.") }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let existing = try folders()
        guard !existing.contains(where: { $0.path == path || path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") }) else {
            throw FeedError("This folder overlaps a folder already in the library.")
        }
        try store.write { try $0.execute(sql: "INSERT INTO folder(path) VALUES (?)", arguments: [path]) }
    }

    public func removeFolder(_ path: String) throws {
        guard !scanning else { throw FeedError("Wait for the current library scan to finish.") }
        try store.write {
            try $0.execute(sql: "DELETE FROM libraryFile WHERE root=?", arguments: [path])
            try $0.execute(sql: "DELETE FROM folder WHERE path=?", arguments: [path])
        }
    }

    public func scanLibrary() async throws {
        guard !scanning, let config = try connections() else { return }
        scanning = true
        defer { scanning = false }
        for folder in try folders() {
            let db = store
            let walk = Task.detached(priority: .utility) { try LibraryScanner.discover(root: folder.path, db: db) }
            // A detached task does not hear about the caller being cancelled by itself.
            try await withTaskCancellationHandler { try await walk.value } onCancel: { walk.cancel() }
        }
        struct Request: Encodable { let files: [HashInput]; let includeVideoDetails = true }
        struct Answer: Decodable { let results: [FileAnswer] }
        let start = Date.now.timeIntervalSince1970
        while true {
            try Task.checkCancellation()
            let paths = try await store.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT f.path,f.size,f.hash FROM libraryFile f JOIN folder d ON d.path=f.root
                    WHERE d.offline=0 AND f.hash IS NOT NULL AND f.video IS NULL AND (checked IS NULL OR checked < ?) LIMIT 200
                    """, arguments: [start-86400]).map { row -> (String, HashInput) in
                    let path: String = row["path"]
                    return (path, HashInput(ref: UUID().uuidString, filename: URL(filePath: path).lastPathComponent,
                                            osHash: row["hash"], filesize: row["size"]))
                }
            }
            if paths.isEmpty { return }
            guard try clock(for: "PRDB", now: .now, includePoll: false) else { throw FeedError("PRDB is waiting to retry. Scan again later.") }
            let answer: Answer
            do {
                answer = try await prdb.fetch("videos/identify", key: config.prdbKey,
                                              body: JSONEncoder().encode(Request(files: paths.map(\.1))))
            } catch {
                try Task.checkCancellation()
                try backoff(error, service: "PRDB", now: .now)
                throw error
            }
            let byRef = Dictionary(uniqueKeysWithValues: paths.map { ($0.1.ref, $0.0) })
            guard answer.results.count == paths.count, Set(answer.results.map(\.ref)) == Set(byRef.keys) else {
                throw FeedError("PRDB returned incomplete file matches.")
            }
            try await store.write { db in
                for result in answer.results {
                    let match = result.matchedBy == 0 && (1...4).contains(result.confidence) && result.candidates.isEmpty ? result.videoId : nil
                    let detail = match == nil ? nil : result.video
                    let image = detail?.images?.compactMap { $0.url }.first { URL(string: $0)?.scheme == "https" }
                    try db.execute(sql: "UPDATE libraryFile SET video=?,title=?,studio=?,image=?,checked=? WHERE path=?",
                                   arguments: [match?.uuidString, detail?.title,detail?.site?.title,image,start,byRef[result.ref]])
                }
            }
        }
    }
}

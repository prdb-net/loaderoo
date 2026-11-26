import Foundation
import GRDB

/// The local demo. It runs the same `LiveFeed` as the live app and replaces only the network:
/// PRDB, two Newznab indexers and SABnzbd answer from this file.
public enum Demo {
    static let video = UUID(uuidString: "0D3E5B1C-51F7-4E0A-9C1D-000000000001")!
    static let studio = UUID(uuidString: "0D3E5B1C-51F7-4E0A-9C1D-000000000002")!
    static let release = "Studio.North.Night.Shift.540p"
    static let posted = Date(timeIntervalSince1970: 1_795_428_000)
    static let preview = URL(string: "https://media.demo.invalid/NightShift.jpg")!
    static let sabHost = "sab.demo.invalid"
    static let indexers = [(id: UUID(uuidString: "0D3E5B1C-51F7-4E0A-9C1D-000000000011")!, name: "Harbor Index", host: "harbor.demo.invalid", entry: "h-17"),
                           (id: UUID(uuidString: "0D3E5B1C-51F7-4E0A-9C1D-000000000012")!, name: "North Index", host: "north.demo.invalid", entry: "n-94")]

    /// Opens the demo library below `root` and connects it on first use. A download becomes ready
    /// `downloadDuration` seconds after it was submitted, also across a restart.
    public static func open(root: URL, downloadDuration: TimeInterval = 12) async throws -> LiveFeed {
        let sab = try DemoSAB(root: root, duration: downloadDuration)
        let library = root.appending(path: "Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let feed = try LiveFeed(root: root, http: FeedHTTP { try respond(to: $0, sab: sab) })
        if try await feed.connections() == nil {
            var config = FeedConnections()
            config.prdbKey = "demo"
            config.indexers = indexers.map { indexer in
                var source = IndexerConnection()
                source.id = indexer.id
                source.name = indexer.name
                source.address = "https://\(indexer.host)/api"
                source.apiKey = "demo"
                return source
            }
            var client = SABConnection()
            client.address = "http://\(sabHost):8080"
            client.apiKey = "demo"
            client.mount = sab.share.path
            client.destination = library.path
            config.sab = client
            try await feed.configure(config)
        }
        return feed
    }

    /// The bundled file behind a demo artwork address. The app serves it in place of a download.
    public static func media(for url: URL) -> URL? {
        guard url.host == preview.host else { return nil }
        return Bundle.module.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension)
    }

    private static func respond(to request: URLRequest, sab: DemoSAB) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host else { throw URLError(.badURL) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        var headers: [String: String] = [:]
        var body: Data?
        if host == "api.prdb.net" {
            body = try prdb(url.path, page: value("page").flatMap(Int.init) ?? 1, input: request.httpBody)
        } else if host == sabHost {
            body = try sab.answer(mode: value("mode"), jobs: value("nzo_ids"), name: value("nzbname"), upload: request.httpBody)
        } else if let indexer = indexers.first(where: { $0.host == host }) {
            if value("t") != "get" {
                let term = value("q") ?? ""
                let listed = (value("offset") ?? "0") == "0"
                    && (term.isEmpty || "Night Shift Studio North \(release)".localizedCaseInsensitiveContains(term))
                let item = """
                    <item><title>\(release)</title><guid>https://\(host)/details/\(indexer.entry)</guid>
                    <enclosure url="https://\(host)/api?t=get&amp;id=\(indexer.entry)" length="87044" type="application/x-nzb"/>
                    <newznab:attr name="usenetdate" value="\(posted.ISO8601Format())"/>
                    <newznab:attr name="category" value="6000"/></item>
                    """
                body = Data("""
                    <rss xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/"><channel>
                    <newznab:response offset="\(value("offset") ?? "0")" total="\(listed ? 1 : 0)"/>
                    \(listed ? item : "")
                    </channel></rss>
                    """.utf8)
            } else if value("id") == indexer.entry {
                headers["Content-Disposition"] = "attachment; filename=\"\(release).nzb\""
                body = Data("""
                    <nzb xmlns="http://www.newzbin.com/DTD/2003/nzb"><file poster="demo" date="1795428000" subject="Night Shift">
                    <groups><group>example.demo</group></groups><segments><segment bytes="1" number="1">demo@example.invalid</segment></segments></file></nzb>
                    """.utf8)
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body ?? Data(), response)
    }

    /// The part of the public PRDB API that Loaderoo reads, answering for the one demo video.
    private static func prdb(_ path: String, page: Int, input: Data?) throws -> Data? {
        let posted = input.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let answer: Any
        switch path {
        case "/user-identity":
            answer = ["userHash": "demo"]
        case "/releases/resolve":
            answer = ["results": (posted?["releases"] as? [[String: Any]] ?? []).map { listing -> [String: Any] in
                let known = listing["title"] as? String == release
                return ["ref": listing["ref"] ?? "", "status": known ? "resolved" : "unknown", "automationEligible": known,
                        "contentKind": "single", "videoIds": known ? [video.uuidString] : []]
            }]
        case "/videos/identify":
            answer = ["results": (posted?["files"] as? [[String: Any]] ?? []).map { file -> [String: Any] in
                ["ref": file["ref"] ?? "", "confidence": 0, "candidates": [String]()]
            }]
        case "/videos/" + video.uuidString:
            answer = ["id": video.uuidString, "title": "Night Shift", "releaseDate": "2026-11-20",
                      "site": ["id": studio.uuidString, "title": "Studio North"], "images": [["url": preview.absoluteString]]]
        case "/videos/" + video.uuidString + "/user-images":
            answer = [Any]()
        case "/sites/changes":
            answer = ["items": [["site": ["id": studio.uuidString, "title": "Studio North", "isDeleted": false]]], "hasMore": false,
                      "nextCursor": ["updatedAtUtc": "2026-11-20T00:00:00Z", "id": studio.uuidString],
                      "serverTimeUtc": Date.now.ISO8601Format()]
        case "/videos":
            let listed: [[String: Any]] = page == 1 ? [["id": video.uuidString, "title": "Night Shift", "siteTitle": "Studio North",
                                                        "createdAtUtc": "2026-11-20T00:00:00Z", "releaseDate": "2026-11-20", "actors": [Any]()]] : []
            answer = ["page": page, "pageSize": 100, "totalCount": 1, "items": listed]
        default:
            return nil
        }
        return try JSONSerialization.data(withJSONObject: answer)
    }
}

/// A small database stands in for SABnzbd's queue and history, so that a job outlives the app the way a real one does.
final class DemoSAB: Sendable {
    private let db: DatabaseQueue
    let share: URL
    private let duration: TimeInterval

    init(root: URL, duration: TimeInterval) throws {
        self.duration = duration
        share = root.appending(path: "Mounted Share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        db = try DatabaseQueue(path: root.appending(path: "DemoSAB.sqlite").path)
        try db.write {
            try $0.execute(sql: """
                CREATE TABLE IF NOT EXISTS demoJob (
                    id TEXT PRIMARY KEY, receipt TEXT NOT NULL, name TEXT NOT NULL, started DOUBLE NOT NULL)
                """)
        }
    }

    func answer(mode: String?, jobs: String?, name: String?, upload: Data?) throws -> Data? {
        let now = Date.now.timeIntervalSince1970
        let answer: Any
        switch mode {
        case "addfile":
            let form = String(decoding: upload ?? Data(), as: UTF8.self)
            guard let receipt = form.firstMatch(of: /filename="([^"]+)"/)?.1 else { return nil }
            let id = "SABnzbd_nzo_" + UUID().uuidString.prefix(8).lowercased()
            try db.write {
                try $0.execute(sql: "INSERT INTO demoJob VALUES (?,?,?,?)", arguments: [id, String(receipt), name ?? String(receipt), now])
            }
            answer = ["status": true, "nzo_ids": [id]]
        case "queue", "history":
            let wanted = jobs.map { Set($0.split(separator: ",").map(String.init)) }
            let rows = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM demoJob ORDER BY started DESC") }
            let finished = rows.filter { now >= ($0["started"] as Double) + duration }
            let slots = try rows.filter { wanted?.contains($0["id"]) != false }.compactMap { job -> [String: Any]? in
                let id: String = job["id"], name: String = job["name"]
                let elapsed = now - (job["started"] as Double)
                if mode == "queue" {
                    guard elapsed < duration else { return nil }
                    let left = Int((duration - elapsed).rounded(.up))
                    return ["nzo_id": id, "filename": name, "status": "Downloading",
                            "percentage": String(Int(elapsed / duration * 100)),
                            "timeleft": String(format: "0:%02d:%02d", left / 60, left % 60)]
                }
                guard elapsed >= duration else { return nil }
                // The download is complete once its folder holds the video.
                let folder = share.appending(path: name)
                let clip = folder.appending(path: "night.shift.demo.mp4")
                if !FileManager.default.fileExists(atPath: clip.path) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: Bundle.module.url(forResource: "NightShift", withExtension: "mp4")!, to: clip)
                }
                return ["nzo_id": id, "name": name, "nzb_name": job["receipt"] as String, "status": "Completed",
                        "storage": "/downloads/complete/" + name]
            }
            answer = [mode ?? "": ["slots": slots, "noofslots": slots.count, "last_history_update": finished.count]]
        default:
            return nil
        }
        return try JSONSerialization.data(withJSONObject: answer)
    }
}

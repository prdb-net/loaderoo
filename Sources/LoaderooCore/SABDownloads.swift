import Foundation
import GRDB

public struct SABConnection: Codable, Equatable, Sendable {
    public var address = ""
    public var apiKey = ""
    public var category = ""
    public var remoteRoot = "/downloads/complete"
    public var mount = ""
    public var destination = ""
    public var originalName = false
    public var unsortedFolder = false
    public init() {}

    var endpoint: URL {
        get throws {
            var base = IndexerConnection()
            base.address = address
            let url = try base.endpoint
            return url.lastPathComponent == "api" ? url : url.appending(path: "api")
        }
    }

    func validated() throws -> Self {
        var copy = self
        copy.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.apiKey.isEmpty else { throw FeedError("Enter the full SABnzbd API key.") }
        copy.address = try copy.endpoint.absoluteString
        guard mount.isEmpty || (mount.hasPrefix("/") && remoteRoot.hasPrefix("/")),
              destination.isEmpty || (!mount.isEmpty && destination.hasPrefix("/")) else {
            throw FeedError("Select the mounted completion folder and enter its absolute container path.")
        }
        return copy
    }

    func request(_ mode: String, _ extra: [URLQueryItem] = []) throws -> URLRequest {
        var url = try endpoint
        url.append(queryItems: [.init(name: "mode", value: mode), .init(name: "output", value: "json"),
                                .init(name: "apikey", value: apiKey)] + extra)
        return URLRequest(url: url)
    }
}

public struct Transfer: Decodable, FetchableRecord, Identifiable, Sendable {
    public let video, title, provider, state: String
    let endpoint, token: String
    public let studio, image, job, note, storage, localPath, releaseName: String?
    public var id: String { video }
    public var retryable: Bool { state == "Rejected" || state == "Failed" }
}

private struct SABSlot: Decodable {
    let nzo_id: String
    let filename, name, nzb_name, status, storage: String?
}

private struct SABEnvelope: Decodable {
    struct Page: Decodable {
        let slots: [SABSlot]
        let noofslots, last_history_update: Int?
    }
    let queue, history: Page?
}

extension LiveFeed {
    func checkSAB(_ connection: SABConnection) async throws {
        let request = try connection.request("queue", [.init(name: "limit", value: "1")])
        let data = try await http.data(request, retryReadIfReachable: true)
        guard let response = try? JSONDecoder().decode(SABEnvelope.self, from: data), response.queue != nil else {
            throw FeedError("SABnzbd did not return its queue. Check the address and full API key.")
        }
    }

    public func transfers() throws -> [Transfer] {
        try store.read { try Transfer.fetchAll($0, sql: "SELECT t.*,s.releaseName FROM transfer t LEFT JOIN transferSource s ON s.video=t.video ORDER BY t.created DESC") }
    }

    public func startDownload(_ id: UUID) async throws {
        guard let config = try connections(), let sab = config.sab else { throw FeedError("Set up SABnzbd in Connections first.") }
        let raw = id.uuidString
        if let job = try transfers().first(where: { $0.video == raw }), !job.retryable { return }
        guard let title = try cached().titles.first(where: { $0.id == id }) else { throw FeedError("The video is already owned or unavailable.") }
        let offers = try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT source,payload FROM offer WHERE video=?", arguments: [raw]).compactMap { row -> (IndexerConnection, Upload)? in
                guard let provider = config.indexers.first(where: { $0.id.uuidString == row["source"] as String }) else { return nil }
                return (provider, try JSONDecoder().decode(Upload.self, from: row["payload"]))
            }.sorted { a,b in
                let keyA = (a.1.posted ?? .distantPast, a.1.size ?? 0)
                let keyB = (b.1.posted ?? .distantPast, b.1.size ?? 0)
                if keyA != keyB { return keyA > keyB }
                return (a.0.id.uuidString, a.1.entry) < (b.0.id.uuidString, b.1.entry)
            }
        }
        var selected: (provider: String, upload: Upload, nzb: Data, jobName: String)?
        var lastError: Error = FeedError("The indexers have no usable NZB for this title.")
        for (provider, upload) in offers {
            try Task.checkCancellation()
            guard try clock(for: provider.id.uuidString, now: .now, includePoll: false) else { continue }
            var url = try provider.endpoint
            url.append(queryItems: [.init(name: "t", value: "get"), .init(name: "id", value: upload.downloadID ?? upload.entry),
                                    .init(name: "apikey", value: provider.apiKey)])
            do {
                let (data, response) = try await http.response(URLRequest(url: url))
                guard NZBCheck.valid(data) else { throw FeedError("The indexer returned an invalid NZB.") }
                selected = (provider.name, upload, data, Self.jobName(response, fallback: upload.title))
                break
            } catch {
                try Task.checkCancellation()
                if let failure = error as? HTTPFailure, failure.status == 429 { try backoff(error, service: provider.id.uuidString, now: .now) }
                lastError = error
            }
        }
        guard let (provider,upload,nzb,jobName) = selected else { throw lastError }
        let token = UUID().uuidString + ".nzb"
        let endpoint = try sab.endpoint.absoluteString
        // Reserve before the only external write. The token also identifies a job whose HTTP reply was lost.
        let reserved = try await store.write { db in
            try db.execute(sql: "DELETE FROM transfer WHERE video=? AND state IN ('Failed','Rejected')", arguments: [raw])
            try db.execute(sql: """
                INSERT OR IGNORE INTO transfer(video,title,studio,image,provider,endpoint,token,state,created)
                SELECT ?,?,?,?,?,?,?,'Submitting',? WHERE NOT EXISTS(SELECT 1 FROM libraryFile WHERE video=?)
                """, arguments: [raw,title.title,title.studio,title.preview?.absoluteString,provider,endpoint,token,Date.now.timeIntervalSince1970,raw])
            guard db.changesCount == 1 else { return false }
            try db.execute(sql: "INSERT OR REPLACE INTO transferSource VALUES (?,?,?)", arguments: [raw,upload.entry,upload.title])
            return true
        }
        guard reserved else { return }
        var query: [URLQueryItem] = [.init(name: "nzbname", value: jobName)]
        if !sab.category.isEmpty { query.append(.init(name: "cat", value: sab.category)) }
        var request = try sab.request("addfile", query)
        request.httpMethod = "POST"
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"; filename=\"\(token)\"\r\nContent-Type: application/x-nzb\r\n\r\n".utf8)
        body.append(nzb)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        struct Reply: Decodable { let status: Bool?; let nzo_ids: [String]?; let error: String? }
        do {
            let reply = try JSONDecoder().decode(Reply.self, from: await http.data(request))
            if reply.status == false || reply.error != nil {
                try update(raw, state: "Rejected", note: "SABnzbd rejected the NZB. Check its API key and category.")
            } else if let ids = reply.nzo_ids, ids.count == 1, !ids[0].isEmpty {
                try update(raw, state: "Queued", job: ids[0])
            } else { throw FeedError("Missing job ID.") }
        } catch let failure as HTTPFailure where [401,403].contains(failure.status) {
            try update(raw, state: "Rejected", note: "SABnzbd refused access. Check the configured API key.")
        } catch {
            try update(raw, state: "Checking receipt", note: "Looking for the submitted job in SABnzbd.")
        }
    }

    private static func jobName(_ response: HTTPURLResponse, fallback: String) -> String {
        // suggestedFilename can also be synthesized from the API URL and MIME type.
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let hasFilename = disposition.range(of: #";\s*filename\*?\s*=\s*(?:"[^"]+"|[^\s";]+)"#,
                                            options: [.regularExpression, .caseInsensitive]) != nil
        let name = (hasFilename ? response.suggestedFilename : nil) ?? fallback
        let stem = name.lowercased().hasSuffix(".nzb") ? String(name.dropLast(4)) : name
        return component(stem)
    }

    private func update(_ id: String, state: String, job: String? = nil, note: String? = nil, storage: String? = nil) throws {
        try store.write { try $0.execute(sql: "UPDATE transfer SET state=?,job=COALESCE(?,job),note=?,storage=COALESCE(?,storage) WHERE video=? AND storage IS NULL",
                                        arguments: [state,job,note,storage,id]) }
    }

    private func resolveMissingStudios(_ config: FeedConnections, sab: SABConnection) async throws {
        guard !sab.destination.isEmpty, try clock(for: "PRDB", now: .now, includePoll: false) else { return }
        let now = Date.now.timeIntervalSince1970
        let endpoint = try sab.endpoint.absoluteString
        let ids = try await store.read { db in
            try String.fetchAll(db, sql: """
                SELECT t.video FROM transfer t LEFT JOIN studioRetry r ON t.video=r.video
                WHERE t.state='Completed' AND COALESCE(t.studio,'')='' AND t.endpoint=? AND COALESCE(r.checked,0) < ? LIMIT 10
                """, arguments: [endpoint,now-86400])
        }
        for raw in ids {
            guard let id = UUID(uuidString: raw) else { continue }
            let detail: FeedMetadata
            do { detail = try await prdb.video(id, key: config.prdbKey) }
            catch { try backoff(error, service: "PRDB", now: .now); return }
            try await store.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO studioRetry VALUES(?,?)", arguments: [raw,now])
                if let studio = detail.studio, !studio.isEmpty {
                    try db.execute(sql: "UPDATE transfer SET studio=?,state='Ready to file' WHERE video=?", arguments: [studio,raw])
                }
            }
        }
    }

    public func followDownloads() async throws {
        guard !polling, let config = try connections(), let sab = config.sab else { return }
        polling = true
        defer { polling = false }
        let endpoint = try sab.endpoint.absoluteString
        try await resolveMissingStudios(config, sab: sab)
        for item in try transfers() where item.endpoint == endpoint && !item.retryable && item.state != "Completed" {
            if item.storage != nil { try finish(item, sab: sab); continue }
            if let (mode, hit) = try await findJob(item, sab: sab) {
                let state = hit.status ?? "Queued"
                if mode == "history", state == "Completed" {
                    guard let path = hit.storage, !path.isEmpty else { throw FeedError("SABnzbd history has no completion path.") }
                    try update(item.id, state: "Downloaded", job: hit.nzo_id, storage: path)
                } else {
                    try update(item.id, state: state == "Completed" ? "Processing" : state, job: hit.nzo_id)
                }
            } else {
                try update(item.id, state: "Checking receipt", note: "Waiting for the job in SABnzbd.")
            }
        }
    }

    private func findJob(_ item: Transfer, sab: SABConnection) async throws -> (String, SABSlot)? {
        // New submissions use the upload filename as a receipt. Only history exposes it
        // separately from the display name. Older submissions used the token as their job name.
        if item.job == nil && item.token.hasSuffix(".nzb") {
            return try await historyReceipt(item.token, sab: sab).map { ("history", $0) }
        }

        let filter = item.job.map { URLQueryItem(name: "nzo_ids", value: $0) } ?? URLQueryItem(name: "search", value: item.token)
        for mode in ["queue", "history"] {
            let page = try await jobPage(mode, sab: sab, query: [filter])
            let matches = page.slots.filter { slot in
                if let job = item.job { return slot.nzo_id == job }
                return [slot.name,slot.filename].contains(item.token) || [slot.name,slot.filename].contains(item.token + ".nzb")
            }
            if matches.count == 1, let hit = matches.first { return (mode, hit) }
        }
        return nil
    }

    private func historyReceipt(_ token: String, sab: SABConnection) async throws -> SABSlot? {
        let limit = 50
        var start = 0
        var historyUpdate: Int?
        repeat {
            let page = try await jobPage("history", sab: sab, query: [
                .init(name: "start", value: String(start)), .init(name: "limit", value: String(limit))
            ])
            if let hit = page.slots.first(where: { $0.nzb_name == token }) {
                receiptHistoryUpdates.removeValue(forKey: token)
                return hit
            }
            if start == 0 {
                historyUpdate = page.last_history_update
                if let historyUpdate, receiptHistoryUpdates[token] == historyUpdate { return nil }
            }
            start += page.slots.count
            if page.slots.isEmpty || start >= (page.noofslots ?? start) { break }
        } while true
        receiptHistoryUpdates[token] = historyUpdate
        return nil
    }

    private func jobPage(_ mode: String, sab: SABConnection, query: [URLQueryItem]) async throws -> SABEnvelope.Page {
        let data = try await http.data(sab.request(mode, query))
        let response = try JSONDecoder().decode(SABEnvelope.self, from: data)
        guard let page = mode == "queue" ? response.queue : response.history else {
            throw FeedError("Could not read SABnzbd queue or history. Check its API key.")
        }
        return page
    }
}

private final class NZBCheck: NSObject, XMLParserDelegate {
    var root: String?
    var hasSegment = false
    static func valid(_ data: Data) -> Bool {
        let check = NZBCheck()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = check
        return parser.parse() && check.root == "nzb" && check.hasSegment
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if root == nil { root = elementName }
        if elementName == "segment" { hasSegment = true }
    }
}

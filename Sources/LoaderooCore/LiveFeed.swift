import Foundation
import GRDB
import CryptoKit

public struct FeedOffer: Identifiable, Sendable {
    public let id, source, name: String
    public let size: Int64?
    public let quality: String?
    public let posted: Date?
}

public struct FeedTitle: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let studioID: UUID?
    public let studioContext: String?
    public let releaseDate: Date?
    public let studio: String?
    public let preview: URL?
    public let siteImages: [URL]
    public let cast: [CastMember]
    public let userPreviews: UserPreviews?
    public let posted: Date?
    public let sources: [String]
    public let qualities: [String]
    public let offers: [FeedOffer]

    static func newestUploadFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        (lhs.posted ?? .distantPast, lhs.id.uuidString) > (rhs.posted ?? .distantPast, rhs.id.uuidString)
    }
}

public struct IndexerSearch: Sendable {
    public let term: String
    public fileprivate(set) var offerIDs: Set<String> = []
    fileprivate var offsets: [String: Int]?
    public var hasMore: Bool { offsets?.isEmpty == false }

    public init(term: String) { self.term = term.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct FeedPage: Sendable {
    public var titles: [FeedTitle] = []
    public var issues: [String] = []
    public var releaseCount = 0
    public var pending = 0
    public var hasEarlier = false
    public var oldestBrowsed: Date?
    public var history: [IndexerHistory] = []
    public var indexerSearch: IndexerSearch?
    public init() {}
}

public actor LiveFeed {
    private static let recentPollInterval: TimeInterval = 900
    let store: DatabaseQueue
    private let newznab: NewznabFeed
    let prdb: PRDBFeed
    let http: FeedHTTP
    let moves: FileMoves
    private let vault: SecretStore?
    private var secrets: ConnectionSecrets?
    var scanning = false
    var receiptHistoryUpdates: [String: Int] = [:]
    var polling = false
    var busy = false
    private var previewRequests: [UUID: Task<UserPreviews, Error>] = [:]

    public init(root: URL) throws {
        try self.init(root: root, http: FeedHTTP(), vault: .forThisBuild)
    }

    init(root: URL, http: FeedHTTP, vault: SecretStore? = nil, moves: FileMoves = FileMoves()) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        store = try DatabaseQueue(path: root.appending(path: "Feed.sqlite").path)
        self.http = http
        self.vault = vault
        self.moves = moves
        newznab = NewznabFeed(http: http)
        prdb = PRDBFeed(http: http)
        try Schema.migrate(store)
    }

    public func connections() throws -> FeedConnections? {
        let saved = try store.read { db in
            try Data.fetchOne(db, sql: "SELECT config FROM connection").map { try JSONDecoder().decode(FeedConnections.self, from: $0) }
        }
        guard var config = saved, let vault else { return saved }
        if secrets == nil {
            var known = try vault.load().map { try JSONDecoder().decode(ConnectionSecrets.self, from: $0) } ?? ConnectionSecrets()
            // Keys saved by a build that kept them in the database move over on first use.
            let found = config.detachSecrets()
            if !found.isEmpty {
                if !found.prdb.isEmpty { known.prdb = found.prdb }
                if !found.sab.isEmpty { known.sab = found.sab }
                known.indexers.merge(found.indexers) { $1 }
                try vault.save(JSONEncoder().encode(known))
                let bare = try JSONEncoder().encode(config)
                try store.write { try $0.execute(sql: "UPDATE connection SET config=?", arguments: [bare]) }
            }
            secrets = known
        }
        config.attach(secrets ?? ConnectionSecrets())
        return config
    }

    public func configure(_ draft: FeedConnections, verifySAB: Bool = false) async throws {
        guard !busy else { throw FeedError("A refresh is already running.") }
        busy = true
        defer { busy = false }
        let config = try draft.validated()
        let old = try connections()
        if let sab = config.sab, verifySAB || old?.sab?.address != sab.address || old?.sab?.apiKey != sab.apiKey {
            try await checkSAB(sab)
        }
        if old?.prdbKey != config.prdbKey {
            let digest = SHA256.hash(data: Data(config.prdbKey.utf8)).map { String(format: "%02x", $0) }.joined()
            let validation = "setup-" + digest
            guard try clock(for: validation, now: .now, includePoll: false) else {
                throw FeedError("PRDB has limited requests for this key. Try again later.")
            }
            do { try await prdb.validate(config.prdbKey) }
            catch {
                if let failure = error as? HTTPFailure, failure.status == 429 || failure.retryAt != nil {
                    try backoff(error, service: validation, now: .now)
                }
                throw FeedError("PRDB: " + error.localizedDescription)
            }
        }
        var bare = config
        if let vault {
            let keys = bare.detachSecrets()
            try vault.save(JSONEncoder().encode(keys))
            secrets = keys
        }
        let stored = try JSONEncoder().encode(bare)
        try await store.write { db in
            for previous in old?.indexers ?? [] {
                let id = previous.id.uuidString
                let current = config.indexers.first { $0.id == previous.id }
                // A new name or API key still serves the same listings. Another address or category does not.
                if current?.address != previous.address || current?.categories != previous.categories {
                    try db.execute(sql: "DELETE FROM offer WHERE source = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM paging WHERE source=?", arguments: [id])
                    try db.execute(sql: "DELETE FROM sourceClock WHERE id = ?", arguments: [id])
                } else if current?.apiKey != previous.apiKey {
                    try db.execute(sql: "UPDATE sourceClock SET retry=NULL WHERE id = ?", arguments: [id])
                }
            }
            if old?.prdbKey != config.prdbKey {
                try db.execute(sql: "DELETE FROM sourceClock WHERE id = 'PRDB'")
            }
            try db.execute(sql: "INSERT OR REPLACE INTO connection VALUES (1, ?)", arguments: [stored])
        }
    }

    func clock(for id: String, now: Date, includePoll: Bool) throws -> Bool {
        try store.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT poll, retry FROM sourceClock WHERE id = ?", arguments: [id]) else { return true }
            let poll: Double? = row["poll"], retry: Double? = row["retry"]
            return max(includePoll ? poll ?? 0 : 0, retry ?? 0) <= now.timeIntervalSince1970
        }
    }

    func backoff(_ error: Error, service: String, now: Date) throws {
        let response = error as? HTTPFailure
        let delay: TimeInterval = response?.status == 429 ? 900 : 60
        let expires = max(now.addingTimeInterval(delay), response?.retryAt ?? now)
        try store.write {
            try $0.execute(sql: """
                INSERT INTO sourceClock(id,retry) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET retry=excluded.retry
                """, arguments: [service, expires.timeIntervalSince1970])
        }
    }

    public func refresh(manual: Bool = false, earlier: Bool = false, search: IndexerSearch? = nil, now: Date = .now) async throws -> FeedPage {
        guard !busy else { return try cached() }
        guard let config = try connections() else { throw FeedError("Set up your connections to load recent uploads.") }
        busy = true
        defer { busy = false }
        var indexerSearch = search
        if let search, search.term.isEmpty { throw FeedError("Enter a search term.") }
        if indexerSearch != nil && indexerSearch?.offsets == nil {
            indexerSearch?.offsets = Dictionary(uniqueKeysWithValues: config.indexers.map { ($0.id.uuidString, 0) })
        }
        var issues: [String] = []
        var requests: [(source: IndexerConnection, offset: Int)] = []
        for source in config.indexers {
            let id = source.id.uuidString
            let offset: Int
            if let indexerSearch {
                guard let next = indexerSearch.offsets?[id] else { continue }
                offset = next
            } else if earlier {
                guard let next = try await store.read({ try Int.fetchOne($0, sql: "SELECT offset FROM paging WHERE source=? AND offset IS NOT NULL", arguments: [id]) }) else { continue }
                offset = next
            } else { offset = 0 }
            guard try clock(for: id, now: now, includePoll: !manual && !earlier && search == nil) else {
                if try !clock(for: id, now: now, includePoll: false) { issues.append("\(source.name): waiting to retry.") }
                continue
            }
            requests.append((source, offset))
        }
        try Task.checkCancellation()
        // A slow indexer must not hold up the others. Awaiting the tasks in turn keeps each page with its
        // request. A task group handing back `(index, page)` lost the index in optimized builds (Swift 6.4).
        let reader = newznab, term = search?.term
        let fetches = requests.map { request in
            Task { try await reader.page(request.source, offset: request.offset, term: term) }
        }
        let pages = await withTaskCancellationHandler {
            var pages: [Result<NewznabFeed.Page, any Error>] = []
            for fetch in fetches { pages.append(await fetch.result) }
            return pages
        } onCancel: {
            for fetch in fetches { fetch.cancel() }
        }
        try Task.checkCancellation()
        for (request, page) in zip(requests, pages) {
            let id = request.source.id.uuidString
            switch page {
            case .success(let page):
                let refs = try remember(page, source: id, offset: request.offset, searching: search != nil, now: now)
                indexerSearch?.offerIDs.formUnion(refs)
                indexerSearch?.offsets?[id] = page.next
            case .failure(let error):
                try backoff(error, service: id, now: now)
                issues.append("\(request.source.name): \(error.localizedDescription)")
            }
        }
        let cutoff = now.addingTimeInterval(-90 * 86400).timeIntervalSince1970
        try await store.write {
            // Expired pages must be reachable again from the top of the catalog.
            try $0.execute(sql: """
                UPDATE paging SET offset=0, oldest=NULL, historyPages=0, through=NULL
                WHERE (lastAttempt IS NULL OR lastAttempt < ?)
                AND source IN (SELECT source FROM offer WHERE lastSeen < ?)
                """, arguments: [now.addingTimeInterval(-Double(IndexerHistory.dayLimit) * 86400).timeIntervalSince1970, cutoff])
            try $0.execute(sql: "DELETE FROM offer WHERE lastSeen < ?", arguments: [cutoff])
            try $0.execute(sql: "DELETE FROM metadata WHERE video NOT IN (SELECT video FROM offer WHERE video IS NOT NULL)")
        }
        if try clock(for: "PRDB", now: now, includePoll: false) {
            do {
                let unanswered = try await enrich(config, now: now, manual: manual)
                if unanswered > 0 {
                    issues.append("PRDB: \(unanswered) \(unanswered == 1 ? "entry" : "entries") could not be read. Loaderoo will ask again in an hour.")
                }
            }
            catch {
                try Task.checkCancellation()
                try backoff(error, service: "PRDB", now: now)
                issues.append("PRDB: " + error.localizedDescription)
            }
        } else { issues.append("PRDB: waiting to retry.") }
        var page = try cached(now: now)
        page.indexerSearch = indexerSearch
        page.issues = issues
        return page
    }

    /// Reserve one older page across all indexers. Newly discovered offers join the normal PRDB queue.
    public func loadEarlierInBackground(now: Date = .now) async throws -> FeedPage? {
        guard !busy, let config = try connections(), try clock(for: "PRDB", now: now, includePoll: false) else { return nil }
        busy = true
        defer { busy = false }
        let timestamp = now.timeIntervalSince1970
        let candidate = try await store.write { db -> IndexerHistory? in
            let history = try IndexerHistory.read(db, sources: config.indexers, now: now)
            guard history.compactMap(\.lastAttempt).allSatisfy({ $0 <= timestamp - 60 }),
                  let next = history.filter({ $0.status == .moreAvailable && ($0.retry ?? 0) <= timestamp })
                    .min(by: { ($0.lastAttempt ?? 0) < ($1.lastAttempt ?? 0) }) else { return nil }
            guard try !Self.hasDueMetadata(db, at: timestamp) else { return nil }
            try db.execute(sql: "UPDATE paging SET lastAttempt=? WHERE source=?", arguments: [timestamp, next.id.uuidString])
            return next
        }
        guard let candidate, let offset = candidate.offset,
              let source = config.indexers.first(where: { $0.id == candidate.id }) else { return nil }
        let id = source.id.uuidString
        try Task.checkCancellation()
        let result: NewznabFeed.Page
        do {
            result = try await newznab.page(source, offset: offset)
        } catch {
            try Task.checkCancellation()
            try backoff(error, service: id, now: now)
            throw FeedError("\(source.name): \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        _ = try remember(result, source: id, offset: offset, searching: false, now: now)
        return try cached(now: now)
    }

    static func hasDueMetadata(_ db: Database, at timestamp: Double) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM offer WHERE nextCheck <= ?)
                OR EXISTS(SELECT 1 FROM offer o LEFT JOIN metadata m ON m.video=o.video
                          WHERE o.video IS NOT NULL AND (m.fetched IS NULL OR m.fetched < ?))
            """, arguments: [timestamp, timestamp - 86400]) == true
    }

    private func remember(_ page: NewznabFeed.Page, source: String, offset: Int, searching: Bool, now: Date) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try store.write { db in
            var refs: [String] = []
            for upload in page.uploads {
                let ref = try String.fetchOne(db, sql: """
                    INSERT INTO offer(ref,source,entry,payload,lastSeen,nextCheck) VALUES (?,?,?,?,?,0)
                    ON CONFLICT(source,entry) DO UPDATE SET
                    nextCheck=CASE WHEN payload != excluded.payload THEN 0 ELSE nextCheck END,
                    video=CASE WHEN payload != excluded.payload THEN NULL ELSE video END,
                    payload=excluded.payload,lastSeen=excluded.lastSeen RETURNING ref
                    """, arguments: [UUID().uuidString, source, upload.entry, try encoder.encode(upload), now.timeIntervalSince1970])
                if searching, let ref { refs.append(ref) }
            }
            guard !searching else { return refs }
            let dates = page.uploads.compactMap(\.posted)
            let oldest = dates.min()?.timeIntervalSinceReferenceDate
            // A single old upload on a recent or mostly undated page cannot establish coverage.
            let through = dates.count * 2 > page.uploads.count ? dates.max()?.timeIntervalSinceReferenceDate : nil
            let earlier = offset > 0
            if !earlier {
                // After a whole lookback window offline, the previous cursor describes an older window.
                let cutoff = now.addingTimeInterval(-Double(IndexerHistory.dayLimit) * 86400 + Self.recentPollInterval)
                try db.execute(sql: """
                    UPDATE paging SET offset=0, oldest=NULL, historyPages=0, through=NULL
                    WHERE source=? AND source IN (SELECT id FROM sourceClock WHERE poll <= ?)
                    """, arguments: [source, cutoff.timeIntervalSince1970])
            }
            try db.execute(sql: """
                INSERT INTO paging(source,offset,oldest,historyPages,through) VALUES (?,?,?,?,?)
                ON CONFLICT(source) DO UPDATE SET
                offset=CASE WHEN ? OR paging.offset=0 OR (paging.historyPages=0 AND paging.offset IS NULL)
                            THEN excluded.offset ELSE paging.offset END,
                oldest=COALESCE(MIN(paging.oldest,excluded.oldest),paging.oldest,excluded.oldest),
                historyPages=paging.historyPages + excluded.historyPages,
                through=CASE WHEN ? THEN excluded.through
                             WHEN paging.historyPages=0 THEN excluded.through ELSE paging.through END
                WHERE excluded.historyPages=0 OR paging.offset=?
                """, arguments: [source,page.next,oldest,earlier ? 1 : 0,through,earlier,earlier,offset])
            if !earlier {
                try db.execute(sql: "INSERT OR REPLACE INTO sourceClock(id,poll) VALUES (?,?)",
                               arguments: [source, now.addingTimeInterval(Self.recentPollInterval).timeIntervalSince1970])
            }
            return refs
        }
    }

    /// Whether a failure concerns the one request, as opposed to PRDB being unreachable, limited or refusing the key.
    static func concernsOneRequest(_ error: any Error) -> Bool {
        if let failure = error as? HTTPFailure { return failure.retryAt == nil && ![401, 403, 429].contains(failure.status) }
        return (error as? FeedError)?.unreachable == false
    }

    /// Matches due listings and loads missing video details. Returns how many entries PRDB could not
    /// answer for. Those wait an hour, so that one of them cannot hold up everything behind it.
    private func enrich(_ config: FeedConnections, now: Date, manual: Bool) async throws -> Int {
        let sources = Dictionary(uniqueKeysWithValues: config.indexers.map { ($0.id.uuidString, $0) })
        let due = try await store.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM offer WHERE nextCheck <= ? ORDER BY nextCheck,ref LIMIT 400",
                             arguments: [now.timeIntervalSince1970]).compactMap { row -> PendingUpload? in
                guard let source = sources[row["source"]] else { return nil }
                return PendingUpload(ref: row["ref"], connection: source, upload: try JSONDecoder().decode(Upload.self, from: row["payload"]))
            }
        }
        // Failed requests tolerated in one round. A round still ends early when PRDB fails throughout.
        var allowance = 12
        var unanswered = 0
        for start in stride(from: 0, to: due.count, by: 100) {
            try Task.checkCancellation()
            try await resolve(Array(due[start..<min(start+100, due.count)]), key: config.prdbKey, now: now,
                              allowance: &allowance, unanswered: &unanswered)
        }
        let missing = try await store.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT o.video FROM offer o LEFT JOIN metadata m ON m.video=o.video
                WHERE o.video IS NOT NULL AND (m.fetched IS NULL OR m.fetched < ?
                    OR (? AND m.fetched < ? AND json_extract(CAST(m.payload AS TEXT),'$.image') IS NULL
                        AND json_extract(CAST(m.payload AS TEXT),'$.userPreviews.sheet') IS NULL))
                ORDER BY m.fetched LIMIT 100
                """, arguments: [now.addingTimeInterval(-86400).timeIntervalSince1970, manual,
                                 now.addingTimeInterval(-900).timeIntervalSince1970])
        }
        let reader = prdb, key = config.prdbKey
        let hourLater = now.addingTimeInterval(3600).timeIntervalSince1970
        // Four videos at a time. Their answers are taken up in order.
        for start in stride(from: 0, to: missing.count, by: 4) {
            try Task.checkCancellation()
            let videos = missing[start..<min(start + 4, missing.count)]
            let lookups = videos.map { raw in
                Task {
                    guard let id = UUID(uuidString: raw) else { throw HTTPFailure(status: 404, retryAt: nil) }
                    return try await reader.video(id, key: key)
                }
            }
            let answers = await withTaskCancellationHandler {
                var answers: [Result<FeedMetadata, any Error>] = []
                for lookup in lookups { answers.append(await lookup.result) }
                return answers
            } onCancel: {
                for lookup in lookups { lookup.cancel() }
            }
            try Task.checkCancellation()
            for (raw, answer) in zip(videos, answers) {
                switch answer {
                case .success(let detail):
                    try await store.write {
                        try $0.execute(sql: "INSERT OR REPLACE INTO metadata VALUES (?,?,?)",
                                       arguments: [raw, try JSONEncoder().encode(detail), now.timeIntervalSince1970])
                    }
                case .failure(let error as HTTPFailure) where error.status == 404 || error.status == 410:
                    try await store.write {
                        try $0.execute(sql: "UPDATE offer SET video=NULL,nextCheck=? WHERE video=?",
                                       arguments: [now.addingTimeInterval(86400).timeIntervalSince1970,raw])
                    }
                case .failure(let error):
                    guard Self.concernsOneRequest(error), allowance > 0 else { throw error }
                    allowance -= 1
                    unanswered += 1
                    try await store.write { db in
                        // Details that only failed to refresh stay on show. A video without any is matched again later.
                        try db.execute(sql: "UPDATE metadata SET fetched=? WHERE video=?", arguments: [hourLater - 86400, raw])
                        if db.changesCount == 0 {
                            try db.execute(sql: "UPDATE offer SET video=NULL,nextCheck=? WHERE video=?", arguments: [hourLater, raw])
                        }
                    }
                }
            }
        }
        return unanswered
    }

    private func resolve(_ batch: [PendingUpload], key: String, now: Date, allowance: inout Int, unanswered: inout Int) async throws {
        let results: [Resolution]
        do { results = try await prdb.resolve(batch, key: key) }
        catch {
            try Task.checkCancellation()
            guard Self.concernsOneRequest(error), allowance > 0 else { throw error }
            allowance -= 1
            if batch.count > 1 {
                // Halve the batch until the listing PRDB cannot answer for stands alone.
                let half = batch.count / 2
                try await resolve(Array(batch[..<half]), key: key, now: now, allowance: &allowance, unanswered: &unanswered)
                try await resolve(Array(batch[half...]), key: key, now: now, allowance: &allowance, unanswered: &unanswered)
            } else {
                unanswered += 1
                try await store.write {
                    try $0.execute(sql: "UPDATE offer SET nextCheck=? WHERE ref=?",
                                   arguments: [now.addingTimeInterval(3600).timeIntervalSince1970, batch[0].ref])
                }
            }
            return
        }
        try await store.write { db in
            for row in results {
                let permanent = ["unsupported", "invalid"].contains(row.status)
                let later = row.recheckAfterUtc.flatMap(feedDate) ?? now.addingTimeInterval(86400)
                let next = permanent ? nil : max(now.addingTimeInterval(60), later).timeIntervalSince1970
                try db.execute(sql: "UPDATE offer SET video=?,nextCheck=? WHERE ref=?",
                               arguments: [row.confirmedID?.uuidString, next, row.ref])
            }
        }
    }

    public func catalogPreviews(for id: UUID) async throws -> UserPreviews {
        if let request = previewRequests[id] { return try await request.value }
        let request = Task { try await fetchCatalogPreviews(for: id) }
        previewRequests[id] = request
        defer { previewRequests[id] = nil }
        return try await request.value
    }

    private func fetchCatalogPreviews(for id: UUID) async throws -> UserPreviews {
        let raw = id.uuidString
        let cached = try await store.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM metadata WHERE video=?", arguments: [raw])
        }
        guard let payload = cached, let config = try connections() else {
            throw FeedError("This title is no longer in the catalog.")
        }
        var detail = try JSONDecoder().decode(FeedMetadata.self, from: payload)
        if let previews = detail.userPreviews { return previews }
        guard try clock(for: "PRDB", now: .now, includePoll: false) else { throw FeedError("PRDB is waiting to retry.") }
        let previews: UserPreviews
        do { previews = try await prdb.userPreviews(id, key: config.prdbKey) }
        catch {
            if let failure = error as? HTTPFailure, failure.status == 429 || failure.retryAt != nil {
                try backoff(error, service: "PRDB", now: .now)
            }
            throw error
        }
        detail.userPreviews = previews
        let updated = try JSONEncoder().encode(detail)
        // A concurrent refresh may already have replaced this version of the metadata.
        try await store.write {
            try $0.execute(sql: "UPDATE metadata SET payload=? WHERE video=? AND payload=?", arguments: [updated, raw, payload])
        }
        return previews
    }

    public func cached(now: Date = .now) throws -> FeedPage {
        guard let config = try connections() else { return FeedPage() }
        let sources = Dictionary(uniqueKeysWithValues: config.indexers.map { ($0.id.uuidString, $0.name) })
        return try store.read { db in
            var page = FeedPage()
            page.history = try IndexerHistory.read(db, sources: config.indexers, now: now)
            page.hasEarlier = page.history.contains { $0.offset != nil }
            page.oldestBrowsed = try Double.fetchOne(db, sql: "SELECT MIN(oldest) FROM paging").map(Date.init(timeIntervalSinceReferenceDate:))
            page.releaseCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offer") ?? 0
            page.pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offer WHERE video IS NULL AND nextCheck IS NOT NULL") ?? 0
            let rows = try Row.fetchCursor(db, sql: """
                SELECT o.ref,o.source,o.video,o.payload,m.payload AS detail FROM offer o JOIN metadata m ON m.video=o.video
                WHERE NOT EXISTS (SELECT 1 FROM libraryFile f WHERE f.video=o.video)
                AND NOT EXISTS (SELECT 1 FROM transfer t WHERE t.video=o.video AND t.storage IS NOT NULL)
                """)
            struct Group {
                let metadata: FeedMetadata
                var posted: Date?
                var sources = Set<String>()
                var qualities = Set<String>()
                var offers: [FeedOffer] = []
            }
            let decoder = JSONDecoder()
            // Several offers share a video. Its details are read once.
            var groups: [String: Group] = [:]
            while let row = try rows.next() {
                guard let name = sources[row["source"]] else { continue }
                let upload = try decoder.decode(Upload.self, from: row["payload"])
                let video: String = row["video"]
                var group = try groups[video] ?? Group(metadata: decoder.decode(FeedMetadata.self, from: row["detail"]), posted: upload.posted)
                if let date = upload.posted { group.posted = max(date, group.posted ?? date) }
                group.sources.insert(name)
                group.offers.append(FeedOffer(id: row["ref"], source: name, name: upload.title, size: upload.size, quality: upload.quality, posted: upload.posted))
                if let quality = upload.quality { group.qualities.insert(quality) }
                groups[video] = group
            }
            let preferred = config.sab?.preferredQuality
            func rank(_ offer: FeedOffer) -> Int {
                guard let quality = offer.quality.flatMap(ReleaseQuality.init(rawValue:)) else { return .max }
                if quality == preferred { return -1 }
                return ReleaseQuality.allCases.firstIndex(of: quality) ?? .max
            }
            page.titles = groups.values.map { group in
                let detail = group.metadata
                return FeedTitle(id: detail.id, title: detail.title, studioID: detail.studioID,
                                 studioContext: detail.studioContext, releaseDate: detail.releaseDate,
                                 studio: detail.studio, preview: detail.image,
                                 siteImages: detail.siteImages ?? detail.image.map { [$0] } ?? [],
                                 cast: detail.cast ?? [], userPreviews: detail.userPreviews,
                                 posted: group.posted, sources: group.sources.sorted(), qualities: group.qualities.sorted(),
                                 offers: group.offers.sorted {
                                     (rank($0), $0.source, $0.name, $0.id) < (rank($1), $1.source, $1.name, $1.id)
                                 })
            }.sorted(by: FeedTitle.newestUploadFirst)
            return page
        }
    }
}

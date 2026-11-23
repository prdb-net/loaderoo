import Foundation
import GRDB

public struct IndexerHistory: Identifiable, Sendable {
    public enum Status: Sendable {
        case awaitingFirstPage, moreAvailable, endOfResults, lookbackReached, pageLimitReached
    }

    public static let dayLimit = 30
    public static let pageLimit = 100
    public let id: UUID
    public let name: String
    public let pages: Int
    public let through: Date?
    public let status: Status
    let offset: Int?
    let lastAttempt: Double?
    let retry: Double?

    static func read(_ db: Database, sources: [IndexerConnection], now: Date) throws -> [Self] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.*, c.retry FROM paging p LEFT JOIN sourceClock c ON c.id = p.source
            """)
        let bySource = Dictionary(uniqueKeysWithValues: rows.map { ($0["source"] as String, $0) })
        let cutoff = now.addingTimeInterval(-Double(dayLimit) * 86400)
        return sources.map { source in
            let row = bySource[source.id.uuidString]
            let pages: Int = row?["historyPages"] ?? 0
            let offset: Int? = row?["offset"]
            let timestamp: Double? = row?["through"]
            let through = timestamp.map(Date.init(timeIntervalSinceReferenceDate:))
            let status: Status
            if row == nil || offset == 0 { status = .awaitingFirstPage }
            else if offset == nil { status = .endOfResults }
            else if pages >= pageLimit { status = .pageLimitReached }
            else if let through, through <= cutoff { status = .lookbackReached }
            else { status = .moreAvailable }
            return Self(id: source.id, name: source.name, pages: pages, through: through, status: status,
                        offset: offset, lastAttempt: row?["lastAttempt"], retry: row?["retry"])
        }
    }
}

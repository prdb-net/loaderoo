import Foundation

public enum DirectoryKind: String, CaseIterable, Sendable {
    case actors = "Actors"
    case studios = "Studios"
}

public struct CatalogSubject: Identifiable, Sendable {
    public enum ID: Hashable, Sendable {
        case actor(UUID), studio(UUID), namedStudio(String)

        func matches(_ title: FeedTitle) -> Bool {
            switch self {
            case .actor(let id): title.cast.contains { $0.id == id }
            case .studio(let id): title.studioID == id
            case .namedStudio(let name): title.studio == name
            }
        }
    }
    public let id: ID
    public let name: String
    public let portrait: URL?
    public let context: String?
    public var kind: DirectoryKind {
        if case .actor = id { return .actors }
        return .studios
    }

    public init(actor: CastMember) {
        id = .actor(actor.id)
        name = actor.name
        portrait = actor.portrait
        context = nil
    }

    public init?(studioOf title: FeedTitle) {
        guard let studio = title.studio else { return nil }
        id = title.studioID.map(ID.studio) ?? .namedStudio(studio)
        name = studio
        portrait = nil
        context = title.studioContext
    }

    public func releases(in page: FeedPage, days: Int?, now: Date = .now) -> [FeedTitle] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: now)
        let start = days.flatMap { calendar.date(byAdding: .day, value: 1 - max(1, $0), to: today) }
        return page.titles.filter { title in
            guard !title.offers.isEmpty, id.matches(title) else { return false }
            guard let start else { return true }
            guard let date = title.releaseDate else { return false }
            return date >= start && date <= today
        }.sorted {
            ($0.releaseDate ?? .distantPast, $0.posted ?? .distantPast, $0.id.uuidString) >
            ($1.releaseDate ?? .distantPast, $1.posted ?? .distantPast, $1.id.uuidString)
        }
    }
}

public struct DirectoryEntry: Identifiable, Sendable {
    public let subject: CatalogSubject
    public var count: Int
    public var id: CatalogSubject.ID { subject.id }

    public static func entries(in page: FeedPage, kind: DirectoryKind) -> [Self] {
        var entries: [CatalogSubject.ID: Self] = [:]
        for title in page.titles where !title.offers.isEmpty {
            let subjects = kind == .actors ? title.cast.map(CatalogSubject.init(actor:)) : [CatalogSubject(studioOf: title)].compactMap { $0 }
            var counted = Set<CatalogSubject.ID>()
            for subject in subjects where counted.insert(subject.id).inserted {
                entries[subject.id, default: Self(subject: subject, count: 0)].count += 1
            }
        }
        return entries.values.sorted { $0.subject.name.localizedStandardCompare($1.subject.name) == .orderedAscending }
    }
}

public struct ActorProfile: Decodable, Sendable {
    public struct Alias: Decodable, Sendable { public let name: String }
    public let name: String
    public let nationalityLabel: String?
    public let birthplace: String?
    public let careerStart: Int?
    public let careerEnd: Int?
    public let aliases: [Alias]?
}

extension LiveFeed {
    public func actorProfile(_ id: UUID) async throws -> ActorProfile {
        guard let config = try connections() else { throw FeedError("Set up PRDB to load actor details.") }
        guard try clock(for: "PRDB", now: .now, includePoll: false) else { throw FeedError("PRDB is waiting to retry.") }
        do { return try await prdb.fetch("actors/" + id.uuidString, key: config.prdbKey) }
        catch let error as HTTPFailure {
            if error.status == 429 || error.retryAt != nil { try backoff(error, service: "PRDB", now: .now) }
            throw error
        }
    }
}

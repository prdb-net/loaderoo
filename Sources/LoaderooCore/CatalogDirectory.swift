import Foundation
import GRDB

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

    init(id: ID, name: String, portrait: URL?, context: String?) {
        self.id = id
        self.name = name
        self.portrait = portrait
        self.context = context
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

    public func releases(in page: FeedPage, prioritizing openedVideo: UUID? = nil) -> [FeedTitle] {
        var matches = page.titles.filter { !$0.offers.isEmpty && id.matches($0) }
            .sorted(by: FeedTitle.newestUploadFirst)
        if let openedVideo, let index = matches.firstIndex(where: { $0.id == openedVideo }), index != 0 {
            let opened = matches.remove(at: index)
            matches.insert(opened, at: 0)
        }
        return matches
    }
}

public struct DirectoryEntry: Identifiable, Sendable {
    public let subject: CatalogSubject
    public var count: Int
    public var id: CatalogSubject.ID { subject.id }

    public static func entries(in page: FeedPage, kind: DirectoryKind, including catalog: [CatalogSubject] = []) -> [Self] {
        var entries: [CatalogSubject.ID: Self] = [:]
        for title in page.titles where !title.offers.isEmpty {
            let subjects = kind == .actors ? title.cast.map(CatalogSubject.init(actor:)) : [CatalogSubject(studioOf: title)].compactMap { $0 }
            var counted = Set<CatalogSubject.ID>()
            for subject in subjects where counted.insert(subject.id).inserted {
                entries[subject.id, default: Self(subject: subject, count: 0)].count += 1
            }
        }
        // The reference directory arrives sorted. Only the locally known additions need sorting.
        var result = catalog.map { subject in
            guard let local = entries.removeValue(forKey: subject.id) else { return Self(subject: subject, count: 0) }
            let enriched = CatalogSubject(id: subject.id, name: subject.name, portrait: subject.portrait ?? local.subject.portrait,
                                          context: subject.context ?? local.subject.context)
            return Self(subject: enriched, count: local.count)
        }
        if !entries.isEmpty {
            result.append(contentsOf: entries.values)
            result.sort { $0.subject.name.localizedStandardCompare($1.subject.name) == .orderedAscending }
        }
        return result
    }
}

public struct ActorProfile: Codable, Sendable {
    public struct Alias: Codable, Sendable { public let name: String }
    public let name: String
    public let nationalityLabel: String?
    public let birthplace: String?
    public let careerStart: Int?
    public let careerEnd: Int?
    public let aliases: [Alias]?
    let id: UUID?
    let requestedIds: [UUID]?
    private struct Photo: Codable, Sendable {
        let url: String?
        let imageType: Int?
    }
    private let images: [Photo]?

    public var photoURLs: [URL] {
        var seen = Set<URL>()
        let photos = images ?? []
        // Prefer a full poster as the cover, keeping PRDB's order within each group.
        return (photos.filter { $0.imageType == 2 } + photos.filter { $0.imageType != 2 && $0.imageType != 1 }
                + photos.filter { $0.imageType == 1 })
            .compactMap { PRDBFeed.imageURL($0.url) }.filter { seen.insert($0).inserted }
    }
}

extension LiveFeed {
    private func cachedProfiles(_ ids: [UUID]) throws -> [UUID: ActorProfile?] {
        guard !ids.isEmpty else { return [:] }
        let keys = ids.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try store.read { db in
            let query = "SELECT id,payload FROM actorProfileCache WHERE checked>=? AND id IN (" + placeholders + ")"
            let rows = try Row.fetchAll(db, sql: query, arguments: [Date.now.addingTimeInterval(-86400).timeIntervalSince1970] + StatementArguments(keys))
            var result: [UUID: ActorProfile?] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["id"]) else { continue }
                let data: Data? = row["payload"]
                result.updateValue(try data.map { try JSONDecoder().decode(ActorProfile.self, from: $0) }, forKey: id)
            }
            return result
        }
    }

    private func saveProfiles(_ profiles: [UUID: ActorProfile?]) throws {
        try store.write { db in
            let now = Date.now.timeIntervalSince1970
            try db.execute(sql: "DELETE FROM actorProfileCache WHERE checked < ?", arguments: [now-86400])
            for (id, profile) in profiles {
                try db.execute(sql: "INSERT OR REPLACE INTO actorProfileCache VALUES(?,?,?)",
                               arguments: [id.uuidString,try profile.map { try JSONEncoder().encode($0) },now])
            }
        }
    }

    private func actorRequest<T: Decodable & Sendable>(_ path: String, body: Data? = nil) async throws -> T {
        guard let config = try connections() else { throw FeedError("Set up PRDB to load actor details.") }
        guard try clock(for: "PRDB", now: .now, includePoll: false) else { throw FeedError("PRDB is waiting to retry.") }
        do { return try await prdb.fetch(path, key: config.prdbKey, body: body) }
        catch let error as HTTPFailure {
            if error.status == 429 || error.retryAt != nil { try backoff(error, service: "PRDB", now: .now) }
            throw error
        }
    }

    public func actorProfile(_ id: UUID) async throws -> ActorProfile {
        if let cached = try cachedProfiles([id])[id] {
            guard let cached else { throw FeedError("This actor is unavailable in PRDB.") }
            return cached
        }
        let profile: ActorProfile = try await actorRequest("actors/" + id.uuidString)
        try saveProfiles([id: profile])
        return profile
    }

    /// The actor batch endpoint accepts up to 50 IDs, including retained IDs for merged actors.
    public func actorPhotos(for ids: [UUID]) async throws -> [UUID: [URL]] {
        guard !ids.isEmpty, ids.count <= 50 else { throw FeedError("Request between 1 and 50 actors.") }
        var profiles = try cachedProfiles(ids)
        let missing = Set(ids).subtracting(profiles.keys)
        if !missing.isEmpty {
            let body = try JSONEncoder().encode(["ids": Array(missing)])
            let actors: [ActorProfile] = try await actorRequest("actors/batch", body: body)
            var fetched = Dictionary(uniqueKeysWithValues: missing.map { ($0, nil as ActorProfile?) })
            for actor in actors {
                guard let canonical = actor.id else { throw FeedError("Missing actor ID in PRDB response.") }
                for id in [canonical] + (actor.requestedIds ?? []) where missing.contains(id) {
                    fetched[id] = actor
                }
            }
            try Task.checkCancellation()
            try saveProfiles(fetched)
            profiles.merge(fetched) { _, new in new }
        }
        return profiles.mapValues { $0?.photoURLs ?? [] }
    }
}

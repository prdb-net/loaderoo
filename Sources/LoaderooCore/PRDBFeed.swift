import Foundation

struct PendingUpload {
    let ref: String
    let connection: IndexerConnection
    let upload: Upload
}

struct Resolution: Decodable {
    let ref: String
    let status: String
    let automationEligible: Bool
    let videoIds: [UUID]
    let contentKind: String?
    let recheckAfterUtc: String?

    var confirmedID: UUID? {
        guard status == "resolved", automationEligible, contentKind == "single", videoIds.count == 1 else { return nil }
        return videoIds.first
    }
}

public struct CastMember: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let portrait: URL?
}

public struct PreviewSheet: Codable, Equatable, Sendable {
    public let url: URL
    public let frames: Int
    public let columns: Int
    public let tileWidth: Int
    public let tileHeight: Int
}

public struct UserPreviews: Codable, Sendable {
    public let stills: [URL]
    public let sheet: PreviewSheet?
}

struct FeedMetadata: Codable {
    let id: UUID
    let title: String
    let studio: String?
    let image: URL?
    let siteImages: [URL]?
    let cast: [CastMember]?
    var userPreviews: UserPreviews?
}

struct PRDBFeed {
    let http: FeedHTTP
    private let base = URL(string: "https://api.prdb.net")!

    func fetch<T: Decodable>(_ path: String, key: String, body: Data? = nil) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data = try await http.data(request)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw FeedError("PRDB returned an unexpected response for \(path).") }
    }

    func validate(_ key: String) async throws {
        struct Identity: Decodable { let userHash: String }
        let identity: Identity = try await fetch("user-identity", key: key)
        guard !identity.userHash.isEmpty else { throw FeedError("PRDB did not confirm the API key.") }
    }

    func resolve(_ uploads: [PendingUpload], key: String) async throws -> [Resolution] {
        struct Source: Encodable { let kind = "newznab"; let origin, entryId: String }
        struct Input: Encodable {
            let ref, title: String
            let postedAtUtc: String?
            let source: Source?
            let sizeBytes: Int64?
            let categories: [String]
        }
        struct Answer: Decodable { let results: [Resolution] }
        let inputs = uploads.map { item in
            Input(ref: item.ref, title: item.upload.title, postedAtUtc: item.upload.posted?.ISO8601Format(),
                  source: item.connection.origin.map { Source(origin: $0, entryId: item.upload.entry) },
                  sizeBytes: item.upload.size, categories: item.upload.categories)
        }
        let body = try JSONEncoder().encode(["releases": inputs])
        if body.count > 1024 * 1024, uploads.count > 1 {
            let half = uploads.count / 2
            let first = try await resolve(Array(uploads[..<half]), key: key)
            return first + (try await resolve(Array(uploads[half...]), key: key))
        }
        let answer: Answer = try await fetch("releases/resolve", key: key, body: body)
        guard answer.results.count == inputs.count, Set(answer.results.map(\.ref)) == Set(inputs.map(\.ref)) else {
            throw FeedError("PRDB returned uncorrelated release results.")
        }
        return answer.results
    }

    private struct Artwork: Decodable {
        let url: String?
        var usableURL: URL? { PRDBFeed.imageURL(url) }
    }

    private static func imageURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func userPreviews(_ id: UUID, key: String) async throws -> UserPreviews {
        struct Preview: Decodable {
            let previewImageType: String
            let url: String?
            let spriteTileCount, spriteTileWidth, spriteTileHeight, spriteColumns, spriteRows: Int?

            var sheet: PreviewSheet? {
                guard previewImageType.lowercased() == "spritesheet", let url = PRDBFeed.imageURL(url),
                      let count = spriteTileCount, count > 0,
                      let width = spriteTileWidth, width > 0, let height = spriteTileHeight, height > 0,
                      let columns = spriteColumns, columns > 0, let rows = spriteRows, rows > 0 else { return nil }
                let capacity = columns.multipliedReportingOverflow(by: rows)
                guard !capacity.overflow else { return nil }
                return PreviewSheet(url: url, frames: min(count, capacity.partialValue), columns: columns,
                                    tileWidth: width, tileHeight: height)
            }
        }
        let previews: [Preview]
        do { previews = try await fetch("videos/" + id.uuidString + "/user-images", key: key) }
        catch let failure as HTTPFailure where failure.status == 404 { previews = [] }
        let stills = previews.filter { $0.previewImageType.lowercased() == "single" }
            .compactMap { Self.imageURL($0.url) }
        return UserPreviews(stills: stills, sheet: previews.lazy.compactMap(\.sheet).first)
    }

    func video(_ id: UUID, key: String) async throws -> FeedMetadata {
        struct Site: Decodable { let title: String }
        struct Actor: Decodable { let id: UUID; let name: String; let images: [Artwork]? }
        struct Detail: Decodable {
            let id: UUID
            let title: String
            let site: Site?
            let images: [Artwork]?
            let actors: [Actor]?
        }
        let detail: Detail = try await fetch("videos/" + id.uuidString, key: key)
        guard detail.id == id else { throw FeedError("PRDB returned a different video ID.") }
        let images = detail.images?.compactMap(\.usableURL) ?? []
        let cast = detail.actors?.map { CastMember(id: $0.id, name: $0.name, portrait: $0.images?.lazy.compactMap(\.usableURL).first) } ?? []
        let previews = images.isEmpty ? try await userPreviews(id, key: key) : nil
        return FeedMetadata(id: id, title: detail.title, studio: detail.site?.title,
                            image: images.first ?? previews?.stills.first, siteImages: images, cast: cast, userPreviews: previews)
    }
}

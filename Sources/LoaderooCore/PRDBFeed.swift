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

struct FeedMetadata: Codable {
    let id: UUID
    let title: String
    let studio: String?
    let image: URL?
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

    func video(_ id: UUID, key: String) async throws -> FeedMetadata {
        struct Site: Decodable { let title: String }
        struct Artwork: Decodable { let url: String? }
        struct Detail: Decodable { let id: UUID; let title: String; let site: Site?; let images: [Artwork]? }
        let detail: Detail = try await fetch("videos/" + id.uuidString, key: key)
        guard detail.id == id else { throw FeedError("PRDB returned a different video ID.") }
        var image = detail.images?.compactMap { $0.url.flatMap(URL.init(string:)) }.first {
            $0.scheme?.lowercased() == "https" && $0.host != nil && $0.user == nil && $0.password == nil
        }
        if image == nil {
            struct Still: Decodable { let previewImageType: String; let url: String? }
            let alternatives: [Still]
            do { alternatives = try await fetch("videos/" + id.uuidString + "/user-images", key: key) }
            catch let failure as HTTPFailure where failure.status == 404 { alternatives = [] }
            image = alternatives.lazy.filter { $0.previewImageType.lowercased() == "single" }
                .compactMap { $0.url.flatMap(URL.init(string:)) }.first {
                    $0.scheme == "https" && $0.host != nil && $0.user == nil && $0.password == nil
                }
        }
        return FeedMetadata(id: id, title: detail.title, studio: detail.site?.title, image: image)
    }
}

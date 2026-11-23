import Foundation
import Network

public struct IndexerConnection: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = ""
    public var address = ""
    public var apiKey = ""
    public var categories = "6000"
    public init() {}

    var endpoint: URL {
        get throws {
            guard var parts = URLComponents(string: address), let host = parts.host, !host.isEmpty,
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
                throw FeedError("Enter an indexer URL without credentials or query parameters.")
            }
            parts.host = host.lowercased()
            let base = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            parts.path = base.isEmpty ? "/api" : "/" + base
            guard let url = parts.url else { throw FeedError("The indexer address is invalid.") }
            return url
        }
    }

    var origin: String? {
        guard let url = try? endpoint, url.scheme == "https" else { return nil }
        let base = url.lastPathComponent == "api" ? url.deletingLastPathComponent() : url
        return base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public struct FeedConnections: Codable, Equatable, Sendable {
    public var sab: SABConnection?
    public var prdbKey = ""
    public var indexers: [IndexerConnection] = [.init()]
    public init() {}

    public func validated() throws -> Self {
        var copy = self
        copy.prdbKey = prdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.prdbKey.isEmpty, !indexers.isEmpty else {
            throw FeedError("Enter your PRDB API key and add at least one indexer.")
        }
        var endpoints = Set<URL>()
        for i in copy.indexers.indices {
            var row = copy.indexers[i]
            row.address = row.address.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = try row.endpoint
            guard endpoints.insert(url).inserted else { throw FeedError("Each indexer needs a different API address.") }
            row.address = url.absoluteString
            row.name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if row.name.isEmpty { row.name = url.host ?? "Indexer" }
            row.apiKey = row.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let categories = row.categories.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard categories.allSatisfy({ (Int($0) ?? 0) > 0 }) else { throw FeedError("Use comma-separated numeric category IDs.") }
            row.categories = categories.joined(separator: ",")
            copy.indexers[i] = row
        }
        if let sab = copy.sab { copy.sab = try sab.validated() }
        return copy
    }
}

struct FeedError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct HTTPFailure: LocalizedError {
    let status: Int
    let retryAt: Date?
    var errorDescription: String? {
        switch status {
        case 401, 403: "Access denied. Check the API key and account permissions."
        case 429: "Request limit reached. Loaderoo will retry later."
        default: "The service returned HTTP \(status)."
        }
    }
}

struct FeedHTTP: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let send: Transport
    private let reachability: @Sendable (NWEndpoint) async -> EndpointReachability

    init(reachability: @escaping @Sendable (NWEndpoint) async -> EndpointReachability = { await EndpointReachability.check($0) },
         send: @escaping Transport) {
        self.reachability = reachability
        self.send = send
    }
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        let session = URLSession(configuration: config, delegate: StopRedirects(), delegateQueue: nil)
        self.init { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw FeedError("Unexpected network response.") }
            guard http.statusCode == 200 else { return (Data(), http) }
            let limit = 8 * 1024 * 1024
            guard http.expectedContentLength <= Int64(limit) else { throw FeedError("The response exceeded the size limit.") }
            var body = Data()
            for try await byte in bytes {
                guard body.count < limit else { throw FeedError("The response exceeded the size limit.") }
                body.append(byte)
            }
            return (body, http)
        }
    }

    func data(_ request: URLRequest, retryReadIfReachable: Bool = false) async throws -> Data {
        let body: Data
        let response: HTTPURLResponse
        do { (body, response) = try await send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .notConnectedToInternet {
            if let url = request.url, let endpoint = EndpointReachability.endpoint(for: url) {
                let status = await reachability(endpoint)
                try Task.checkCancellation()
                if status == .localNetworkDenied { throw LocalNetworkAccessRequired(endpoint: endpoint) }
                if status == .reachable, retryReadIfReachable, request.httpMethod == "GET" {
                    return try await data(request)
                }
            }
            throw FeedError("Connection failed. Check the address and network.")
        }
        catch let error as FeedError { throw error }
        catch { throw FeedError("Connection failed. Check the address and network.") }
        guard response.statusCode == 200 else {
            let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let deadline = Double(value).flatMap { $0.isFinite && $0 >= 0 ? Date.now.addingTimeInterval($0) : nil }
                ?? feedDate(value)
            throw HTTPFailure(status: response.statusCode, retryAt: deadline)
        }
        return body
    }
}

private final class StopRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func feedDate(_ value: String) -> Date? {
    if let instant = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return instant }
    if let instant = try? Date.ISO8601FormatStyle().parse(value) { return instant }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

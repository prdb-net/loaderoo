import Foundation

struct Upload: Codable, Equatable, Sendable {
    let entry: String
    let title: String
    let posted: Date?
    let size: Int64?
    let categories: [String]
    var downloadID: String? = nil

    var quality: String? {
        let name = title.lowercased()
        let tags = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return tags.first { ["480p", "540p", "576p", "720p", "1080p", "1080i", "2160p", "4k", "8k"].contains($0) }
    }
}

struct NewznabFeed {
    let http: FeedHTTP

    func latest(_ connection: IndexerConnection) async throws -> [Upload] {
        try await page(connection, offset: 0).uploads
    }

    struct Page {
        let uploads: [Upload]
        let next: Int?
    }

    func page(_ connection: IndexerConnection, offset: Int) async throws -> Page {
        var url = try connection.endpoint
        var query = [URLQueryItem(name: "t", value: "search"), .init(name: "o", value: "xml"),
                     .init(name: "limit", value: "100"),
                     .init(name: "attrs", value: "usenetdate,category,size,password,guid")]
        if offset > 0 { query.append(.init(name: "offset", value: String(offset))) }
        if !connection.apiKey.isEmpty { query.append(.init(name: "apikey", value: connection.apiKey)) }
        if !connection.categories.isEmpty { query.append(.init(name: "cat", value: connection.categories)) }
        url.append(queryItems: query)
        return try RSSReader.read(await http.data(URLRequest(url: url)), offset: offset)
    }
}

private final class RSSReader: NSObject, XMLParserDelegate {
    var listings: [Upload] = []
    private var stack: [String] = []
    private var itemCount = 0
    private var total: Int?
    private var responseOffset: Int?
    private var rssChannel = false
    private var failure: (any Error)?
    private var fields: [String: String] = [:]
    private var categories: [String] = []
    private var text = ""

    static func read(_ data: Data, offset: Int) throws -> NewznabFeed.Page {
        let reader = RSSReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let ok = parser.parse()
        if let error = reader.failure { throw error }
        guard ok, reader.rssChannel else { throw FeedError("Expected a Newznab RSS search response.") }
        if let actual = reader.responseOffset, actual != offset {
            throw FeedError("The indexer did not return the requested page.")
        }
        let end = offset + reader.itemCount
        let more = reader.total.map { end < $0 } ?? (reader.itemCount == 100)
        return NewznabFeed.Page(uploads: reader.listings, next: reader.itemCount > 0 && more ? end : nil)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(name)
        text = ""
        if stack == ["error"] || stack == ["rss", "channel", "error"] {
            let code = attributes["code"]
            if code == "429" || code == "500" && attributes["description"]?.localizedCaseInsensitiveContains("limit") == true {
                failure = HTTPFailure(status: 429, retryAt: nil)
            } else {
                failure = FeedError("Newznab refused the search (code \(Int(code ?? "") ?? 0)). Check the API address, key and category.")
            }
            parser.abortParsing()
        }
        if stack == ["rss", "channel"] { rssChannel = true }
        if stack == ["rss", "channel", "response"] {
            total = attributes["total"].flatMap(Int.init)
            responseOffset = attributes["offset"].flatMap(Int.init)
        }
        if stack == ["rss", "channel", "item"] { fields = [:]; categories = []; itemCount += 1 }
        guard stack.count == 4, stack[2] == "item" else { return }
        if name == "attr", let key = attributes["name"]?.lowercased(), let value = attributes["value"] {
            if key == "category" { categories.append(value) }
            if ["size", "usenetdate", "password", "guid"].contains(key) { fields[key] = value }
        }
        if name == "enclosure" {
            fields["length"] = attributes["length"]
            fields["enclosureURL"] = attributes["url"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count == 4, stack[2] == "item", ["guid", "title", "link", "comments"].contains(name) {
            fields[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if stack == ["rss", "channel", "item"], let upload = upload() { listings.append(upload) }
        stack.removeLast()
        text = ""
    }

    private func upload() -> Upload? {
        guard fields["password"] != "1", let title = fields["title"], !title.isEmpty, title.count <= 2000,
              let entry = ["guid", "enclosureURL", "comments", "link"].compactMap({ fields[$0] }).compactMap(Self.entryID).first,
              // Newznab entries advertise their NZB in the enclosure or item link.
              [fields["enclosureURL"], fields["link"]].compactMap({ $0 }).contains(where: {
                  guard let url = URL(string: $0) else { return false }
                  return ["https", "http"].contains(url.scheme) && url.host != nil
              }) else { return nil }
        let size = (fields["size"] ?? fields["length"]).flatMap(Int64.init)
        var upload = Upload(entry: entry, title: title, posted: fields["usenetdate"].flatMap(feedDate),
                            size: size.flatMap { $0 > 0 ? $0 : nil },
                            categories: Array(categories.filter { !$0.isEmpty && $0.count <= 128 }.prefix(20)))
        // Some providers use a listing GUID distinct from the ID in their NZB enclosure.
        upload.downloadID = [fields["enclosureURL"], fields["link"]].compactMap { $0 }.compactMap { address in
            guard let query = URLComponents(string: address)?.queryItems,
                  query.contains(where: { $0.name == "t" && $0.value == "get" }),
                  let raw = query.first(where: { $0.name == "id" })?.value,
                  !raw.contains(":") else { return nil as String? }
            return Self.entryID(raw)
        }.first
        return upload
    }

    // Extract only an opaque provider ID. Credential-bearing URLs stay inside the RSS reader.
    private static func entryID(_ raw: String) -> String? {
        var id = raw
        if let url = URLComponents(string: raw), url.host != nil {
            if let queryID = url.queryItems?.first(where: { $0.name == "id" })?.value { id = queryID }
            else {
                let parts = url.path.split(separator: "/")
                guard let tail = parts.last, parts.count >= 2,
                      ["details", "getnzb", "release"].contains(parts[parts.count - 2].lowercased()) else { return nil }
                id = String(tail)
                if id.hasSuffix(".nzb") { id.removeLast(4) }
            }
        }
        guard !id.isEmpty, id.count <= 512,
              id.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#&=@\\").union(.whitespacesAndNewlines)) == nil else { return nil }
        return id
    }
}

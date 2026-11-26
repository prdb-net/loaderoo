import Foundation

public struct CatalogFilter: Equatable, Sendable {
    public var studioIDs = Set<CatalogSubject.ID>()
    public var actorIDs = Set<CatalogSubject.ID>()
    public var quality: String?
    public var indexer: String?
    public var days: Int?
    public init() {}

    public func titles(in page: FeedPage, matching query: String, search: IndexerSearch?,
                       onlyWithPreview: Bool = true, now: Date = .now) -> [FeedTitle] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let since = days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: now) }
        return page.titles.filter { title in
            guard !onlyWithPreview || title.preview != nil || title.userPreviews?.sheet != nil else { return false }
            if !studioIDs.isEmpty, !studioIDs.contains(where: { $0.matches(title) }) { return false }
            if !actorIDs.isEmpty, !actorIDs.contains(where: { $0.matches(title) }) { return false }
            return title.offers.contains { offer in
                guard indexer == nil || offer.source == indexer,
                      quality == nil || offer.quality == quality else { return false }
                if let since, (offer.posted ?? .distantPast) < since { return false }
                if words.isEmpty || search?.offerIDs.contains(offer.id) == true { return true }
                let text = [title.title, title.studio, offer.name, offer.source].compactMap { $0 }.joined(separator: " ")
                return words.allSatisfy { text.localizedStandardContains($0) }
            }
        }
    }
}

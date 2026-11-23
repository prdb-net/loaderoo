import Foundation
import Testing
@testable import LoaderooCore

struct CatalogDirectoryTests {
    let actor = CastMember(id: UUID(), name: "Sam", portrait: nil)
    let studio = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func video(_ name: String, daysAgo: Int?, cast: [CastMember], studioID: UUID?, available: Bool = true) -> FeedTitle {
        let date = daysAgo.map { Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 86400) * 86400 - Double($0) * 86400) }
        let offer = FeedOffer(id: UUID().uuidString, source: "Test Index", name: name, size: 4200, quality: "1080p", posted: now)
        return FeedTitle(id: UUID(), title: name, studioID: studioID, studioContext: nil, releaseDate: date, studio: "North",
                         preview: nil, siteImages: [], cast: cast, userPreviews: nil, posted: now, sources: ["Test Index"],
                         qualities: ["1080p"], offers: available ? [offer] : [])
    }

    @Test func profilesUsePublicationDatesAndRequireAnOffer() throws {
        var page = FeedPage()
        page.titles = [
            video("Boundary", daysAgo: 89, cast: [actor, actor], studioID: studio),
            video("Older", daysAgo: 90, cast: [actor], studioID: studio),
            video("Recent", daysAgo: 2, cast: [actor], studioID: studio),
            video("Undated", daysAgo: nil, cast: [actor], studioID: studio),
            video("No offer", daysAgo: 1, cast: [actor], studioID: studio, available: false)
        ]
        for kind in DirectoryKind.allCases {
            let entry = try #require(DirectoryEntry.entries(in: page, kind: kind).first)
            #expect(entry.count == 4)
            #expect(entry.subject.releases(in: page, days: 90, now: now).map(\.title) == ["Recent", "Boundary"])
            #expect(entry.subject.releases(in: page, days: 180, now: now).count == 3)
            #expect(entry.subject.releases(in: page, days: nil, now: now).count == 4)
        }
    }

    @Test func studioAndActorFiltersRespectIdentityAndCombineWithOfferFilters() {
        let otherActor = CastMember(id: UUID(), name: actor.name, portrait: nil)
        let secondStudio = UUID()
        var page = FeedPage()
        page.titles = [
            video("First", daysAgo: 1, cast: [actor], studioID: studio),
            video("Second", daysAgo: 1, cast: [otherActor], studioID: studio),
            video("Third", daysAgo: 1, cast: [actor], studioID: secondStudio)
        ]
        var filter = CatalogFilter()
        filter.studioIDs = [.studio(studio)]
        filter.actorIDs = [.actor(actor.id)]
        func matches() -> [String] {
            filter.titles(in: page, matching: "", search: nil, onlyWithPreview: false).map(\.title)
        }
        #expect(matches() == ["First"])
        filter.actorIDs.insert(.actor(otherActor.id))
        #expect(matches() == ["First", "Second"])
        filter.studioIDs.insert(.studio(secondStudio))
        #expect(matches().count == 3)
        filter.quality = "2160p"
        #expect(matches().isEmpty)
    }
}

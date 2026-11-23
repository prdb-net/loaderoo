import Foundation
import Testing
@testable import LoaderooCore

struct CatalogDirectoryTests {
    let actor = CastMember(id: UUID(), name: "Sam", portrait: nil)
    let studio = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func video(_ name: String, daysAgo: Int?, cast: [CastMember], studioID: UUID?, postedDaysAgo: Int? = 0, available: Bool = true) -> FeedTitle {
        let date = daysAgo.map { Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 86400) * 86400 - Double($0) * 86400) }
        let posted = postedDaysAgo.map { now.addingTimeInterval(-Double($0) * 86400) }
        let offer = FeedOffer(id: UUID().uuidString, source: "Test Index", name: name, size: 4200, quality: "1080p", posted: posted)
        return FeedTitle(id: UUID(), title: name, studioID: studioID, studioContext: nil, releaseDate: date, studio: "North",
                         preview: nil, siteImages: [], cast: cast, userPreviews: nil, posted: posted, sources: ["Test Index"],
                         qualities: ["1080p"], offers: available ? [offer] : [])
    }

    @Test func profilesOrderAvailableVideosByUploadRegardlessOfReleaseDate() throws {
        let noDates = video("Undated", daysAgo: nil, cast: [actor, actor], studioID: studio, postedDaysAgo: nil)
        let old = video("Old release, new upload", daysAgo: 750, cast: [actor], studioID: studio)
        let newer = video("Recent release, older upload", daysAgo: 12, cast: [actor], studioID: studio, postedDaysAgo: 10)
        let noRelease = video("Unknown release", daysAgo: nil, cast: [actor], studioID: studio, postedDaysAgo: 2)
        let unavailable = video("No offer", daysAgo: 1, cast: [actor], studioID: studio, available: false)
        var page = FeedPage()
        page.titles = [noDates, newer, unavailable, old, noRelease]
        for kind in DirectoryKind.allCases {
            let entry = try #require(DirectoryEntry.entries(in: page, kind: kind).first)
            #expect(entry.count == 4)
            #expect(entry.subject.releases(in: page).map(\.id) == [old.id, noRelease.id, newer.id, noDates.id])
            #expect(entry.subject.releases(in: page, prioritizing: unavailable.id).count == 4)
        }
    }

    @Test func openingAnOlderReleasePinsItOnceEvenBeyondTheFirstPage() throws {
        var page = FeedPage()
        page.titles = (0..<45).map { (index: Int) in
            video("Title \(index)", daysAgo: nil, cast: [actor], studioID: studio, postedDaysAgo: index)
        }
        let origin = try #require(page.titles.last)
        for kind in DirectoryKind.allCases {
            let subject = try #require(DirectoryEntry.entries(in: page, kind: kind).first?.subject)
            let ordered = subject.releases(in: page, prioritizing: origin.id)
            #expect(ordered.prefix(20).map(\.id) == [origin.id] + page.titles.prefix(19).map(\.id))
            #expect(ordered.dropFirst().map(\.id) == page.titles.dropLast().map(\.id))
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

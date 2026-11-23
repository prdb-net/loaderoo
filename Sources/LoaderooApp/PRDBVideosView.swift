import LoaderooCore
import SwiftUI

struct PRDBVideosView: View {
    let model: FeedWorkspace
    let searchIndexers: (String) -> Void
    @State private var query = ""
    @State private var limit = 100
    @State private var rows: [PRDBCatalogVideo] = []
    @State private var error: String?

    private struct Request: Equatable {
        let query: String
        let limit: Int
        let revision: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                WorkspaceSearchField(text: $query, prompt: "Search PRDB titles or studios") {}
            }.padding(.horizontal, 18).padding(.vertical, 9)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No PRDB videos yet" : "No matching PRDB videos", systemImage: "film",
                                       description: Text(error ?? (query.isEmpty ? "Video titles load in the background." : "Try another title or studio.")))
                    .frame(maxHeight: .infinity)
            } else {
                List(rows.prefix(limit)) { video in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(video.title).font(.headline)
                            Text([video.studio, video.releaseDate].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Search indexers") { searchIndexers(video.title) }.disabled(model.loading)
                    }.padding(.vertical, 3)
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.reference.videoCount) PRDB videos cached")
                    if let page = model.reference.olderCreditPage {
                        Text("Checking actor credits on older videos · Page \(page)")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                if rows.count > limit { Button("Show more") { limit += 100 } }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .onChange(of: query) { limit = 100 }
        .task(id: Request(query: query, limit: limit, revision: model.reference.revision)) {
            do {
                let result = try await model.engine?.referenceVideos(matching: query, limit: limit + 1) ?? []
                try Task.checkCancellation()
                rows = result
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; rows = [] }
            }
        }
    }
}

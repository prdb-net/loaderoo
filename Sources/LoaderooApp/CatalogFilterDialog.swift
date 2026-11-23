import SwiftUI
import LoaderooCore

struct CatalogFilterDialog: View {
    let model: FeedWorkspace
    @State var draft: CatalogFilter
    @State var onlyWithPreview: Bool
    let apply: (CatalogFilter, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.previewWindowSize) private var windowSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Catalog filters").font(.title2.bold())
            HStack(spacing: 18) {
                choices("Quality", values: model.page.titles.flatMap(\.qualities), selected: $draft.quality)
                choices("Indexer", values: model.config?.indexers.map(\.name) ?? [], selected: $draft.indexer)
            }
            HStack {
                Picker("Posting date", selection: $draft.days) {
                    Text("Any time").tag(nil as Int?)
                    ForEach([7, 30, 90, 365], id: \.self) { Text("Last \($0) days").tag(Optional($0)) }
                }.fixedSize()
                Spacer()
                Toggle("Only titles with previews", isOn: $onlyWithPreview)
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                SubjectChoices(kind: .studios, entries: model.studios.filter { $0.count > 0 }, selected: $draft.studioIDs)
                SubjectChoices(kind: .actors, entries: model.actors.filter { $0.count > 0 }, selected: $draft.actorIDs)
            }
            Divider()
            HStack {
                Button("Clear filters") { draft = CatalogFilter(); onlyWithPreview = false }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                let count = draft.titles(in: model.page, matching: model.catalogQuery, search: model.indexerSearch,
                                         onlyWithPreview: onlyWithPreview).count
                Button(count == 1 ? "Show 1 video" : "Show \(count) videos") {
                    apply(draft, onlyWithPreview)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 650, height: min(500, max(350, windowSize.height - 48)))
    }

    private func choices(_ label: String, values: [String], selected: Binding<String?>) -> some View {
        Picker(label, selection: selected) {
            Text("All").tag(nil as String?)
            ForEach(Set(values).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
        }
    }
}

private struct SubjectChoices: View {
    let kind: DirectoryKind
    let entries: [DirectoryEntry]
    @Binding var selected: Set<CatalogSubject.ID>
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(kind.rawValue).font(.headline)
            TextField("Search " + kind.rawValue.lowercased(), text: $query)
            let matches = entries.filter { query.isEmpty || $0.subject.name.localizedStandardContains(query) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(matches) { entry in
                        Toggle(isOn: Binding(get: { selected.contains(entry.id) }, set: { enabled in
                            if enabled { selected.insert(entry.id) } else { selected.remove(entry.id) }
                        })) {
                            HStack {
                                Text(entry.subject.name).lineLimit(1).help(entry.subject.name)
                                Spacer()
                                Text("\(entry.count)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                }.padding(8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

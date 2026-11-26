import SwiftUI
import LoaderooCore

struct ConnectionsForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var downloadSettings: Bool
    @State var draft: FeedConnections
    let save: (FeedConnections, _ verifySAB: Bool) async throws -> Void
    @State private var error: (any Error)?
    @State private var waitingForAccess: LocalNetworkAccessRequired?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connections").font(.title2.bold()).padding()
            Picker("Service", selection: $downloadSettings) {
                Text("PRDB & Indexers").tag(false)
                Text("SABnzbd").tag(true)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal)
            Form {
                if downloadSettings {
                    SABForm(connection: Binding(get: { draft.sab ?? SABConnection() }, set: { draft.sab = $0 }))
                    if draft.sab != nil {
                        Section {
                            Button("Remove SABnzbd Connection", role: .destructive) { draft.sab = nil }
                        } footer: {
                            Text("Jobs already sent stay in SABnzbd. Loaderoo stops following them once you save.")
                        }
                    }
                } else {
                    Section("PRDB") { SecureField("Personal API key", text: $draft.prdbKey) }
                    ForEach($draft.indexers) { $indexer in
                        Section {
                            TextField("Name", text: $indexer.name, prompt: Text("Indexer name"))
                            TextField("API address", text: $indexer.address, prompt: Text("https://indexer.example/api"))
                            SecureField("Indexer API key", text: $indexer.apiKey)
                            TextField("Category IDs", text: $indexer.categories, prompt: Text("All categories"))
                        } header: {
                            HStack {
                                Text(indexer.name.isEmpty ? "Newznab indexer" : indexer.name)
                                Spacer()
                                Button("Remove", systemImage: "minus.circle") {
                                    let id = indexer.id
                                    draft.indexers.removeAll { $0.id == id }
                                }.labelStyle(.iconOnly)
                            }
                        }
                    }
                    Button("Add Indexer", systemImage: "plus") { draft.indexers.append(IndexerConnection()) }
                }
            }.formStyle(.grouped).disabled(saving)
            if let error {
                VStack(alignment: .leading, spacing: 5) {
                    if error is LocalNetworkAccessRequired {
                        Label("Local network access needed", systemImage: "network.slash").font(.headline)
                        Text(error.localizedDescription)
                        Link("Open Privacy & Security…",
                             destination: URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
                    } else {
                        Text(error.localizedDescription).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 8).textSelection(.enabled)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(error is LocalNetworkAccessRequired ? "Try Again" : "Save Connections") { submit() }
                    .keyboardShortcut(.defaultAction)
            }.disabled(saving).padding()
        }
        .frame(width: 510, height: 480)
        .interactiveDismissDisabled(saving)
        .onChange(of: draft) {
            waitingForAccess = nil
            error = nil
        }
        .task(id: waitingForAccess) {
            guard let pending = waitingForAccess, await pending.waitForAccess(), !Task.isCancelled,
                  pending == waitingForAccess else { return }
            submit(retryAfterPermission: false)
        }
    }

    private func submit(retryAfterPermission: Bool = true) {
        guard !saving else { return }
        waitingForAccess = nil
        error = nil
        saving = true
        Task {
            defer { saving = false }
            do { try await save(draft, downloadSettings) }
            catch {
                self.error = error
                if retryAfterPermission { waitingForAccess = error as? LocalNetworkAccessRequired }
            }
        }
    }
}

@MainActor func chooseFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}

private struct SABForm: View {
    @Binding var connection: SABConnection
    var body: some View {
        Section {
            TextField("API address", text: $connection.address, prompt: Text("http://sab.local:8080"))
            SecureField("Full API key", text: $connection.apiKey)
            TextField("Category", text: $connection.category, prompt: Text("Default"))
        } header: { Text("Download client") } footer: {
            if #available(macOS 15, *) {
                Text("Saving checks the SABnzbd queue. If macOS asks for local network access, choose Allow.")
            }
        }
        Section {
            Picker("Preferred quality", selection: $connection.preferredQuality) {
                Text("No preference").tag(nil as ReleaseQuality?)
                ForEach(ReleaseQuality.allCases, id: \.self) { quality in
                    Text(quality.label).tag(Optional(quality))
                }
            }
        } header: { Text("Automatic NZB selection") } footer: {
            Text("The catalog tries your preferred quality first, then other releases. Within each group, it tries the newest upload first.")
        }
        Section {
            TextField("Container folder", text: $connection.remoteRoot)
            directory("Mounted on Mac", path: $connection.mount)
            directory("Studio library", path: $connection.destination)
            Toggle("Keep original filenames", isOn: $connection.originalName)
            Toggle("Use Unsorted for unknown studios", isOn: $connection.unsortedFolder)
        } header: { Text("Completed downloads") } footer: {
            Text("Choose a studio library to file completed videos automatically. Without one, files stay in SABnzbd’s completed folder.")
        }
    }

    func directory(_ label: String, path: Binding<String>) -> some View {
        LabeledContent(label) {
            Text(path.wrappedValue.isEmpty ? "Not selected" : path.wrappedValue)
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(path.wrappedValue)
            Button("Choose…") { if let url = chooseFolder() { path.wrappedValue = url.path } }
            if !path.wrappedValue.isEmpty {
                Button("Clear", systemImage: "xmark.circle") { path.wrappedValue = "" }.labelStyle(.iconOnly)
            }
        }
    }
}

import AppKit
import SwiftUI
import LoaderooCore

@main
struct LoaderooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var demo = ProcessInfo.processInfo.arguments.contains("--demo")
        || ProcessInfo.processInfo.environment["LOADEROO_DEMO_ROOT"] != nil
    var body: some Scene {
        Window("Loaderoo", id: "library") {
            if demo {
                WorkspaceView()
            } else {
                LiveFeedView(openDemo: { demo = true })
            }
        }
        .commands {
            CommandMenu("Workspace") {
                Button(demo ? "Open Live Feed" : "Open Local Demo") { demo.toggle() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(sizeInitialWindow(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
    }

    @objc private func sizeInitialWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel),
              let screen = window.screen else { return }
        // Size the workspace once, on the display macOS chose when restoring the window.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
        if !window.styleMask.contains(.fullScreen) {
            window.setFrame(screen.visibleFrame, display: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SectionName: String, CaseIterable, Identifiable {
    case releases = "Recent uploads"
    case downloads = "Downloads"
    case library = "Library"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .releases: "rectangle.stack"
        case .downloads: "arrow.down.circle"
        case .library: "film.stack"
        }
    }
}

@MainActor @Observable
final class Workspace {
    var snapshot: Snapshot?
    var issue: String?
    var submitting = false
    private var engine: Workflow?

    func refresh() async {
        do {
            if engine == nil {
                let root: URL
                if let path = ProcessInfo.processInfo.environment["LOADEROO_DEMO_ROOT"], !path.isEmpty {
                    root = URL(fileURLWithPath: path, isDirectory: true)
                } else {
                    root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                        .appending(path: "net.prdb.loaderoo/Demo")
                }
                engine = try Workflow(root: root)
            }
            snapshot = try await engine?.refresh()
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    func download(_ release: Release) async {
        guard let engine, !submitting else { return }
        submitting = true
        defer { submitting = false }
        do {
            snapshot = try await engine.download(id: release.id)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
    }
}

struct WorkspaceView: View {
    @State private var workspace = Workspace()
    @State private var selection: SectionName? = .releases

    var body: some View {
        NavigationSplitView {
            List(SectionName.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 164, ideal: 184, max: 230)
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                Label("Local demo", systemImage: "desktopcomputer")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
                    .help("PRDB, both indexers and SABnzbd are simulated on this Mac.")
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let issue = workspace.issue {
                    HStack {
                        Label(issue, systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Retry") { Task { await workspace.refresh() } }
                    }.padding()
                    Divider()
                }
                if let snapshot = workspace.snapshot {
                    content(snapshot)
                } else if workspace.issue == nil {
                    ProgressView("Opening demo library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle((selection ?? .releases).rawValue)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 660, minHeight: 450)
        .task {
            repeat {
                if workspace.snapshot == nil || workspace.issue != nil ||
                    workspace.snapshot?.downloads.contains(where: { !$0.filed }) == true {
                    await workspace.refresh()
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            } while !Task.isCancelled
        }
    }

    @ViewBuilder private func content(_ snapshot: Snapshot) -> some View {
        switch selection ?? .releases {
        case .releases:
            if snapshot.releases.isEmpty {
                ContentUnavailableView {
                    Label("You’re all caught up", systemImage: "checkmark.circle")
                } description: {
                    Text("Your library contains every matched demo upload.")
                } actions: {
                    Button("Open Library") { selection = .library }
                }
            } else {
                ScrollView {
                    ForEach(snapshot.releases) { release in
                        VStack(alignment: .leading, spacing: 14) {
                            Artwork(video: release.video)
                                .aspectRatio(16/9, contentMode: .fit)
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(release.video.title).font(.largeTitle.bold())
                                    Text(release.video.studio).font(.title3).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if snapshot.downloads.contains(where: { $0.id == release.id }) {
                                    Button("View Download") { selection = .downloads }
                                } else {
                                    Button {
                                        Task { await workspace.download(release) }
                                    } label: {
                                        Label("Download", systemImage: "arrow.down.to.line")
                                    }.buttonStyle(.borderedProminent)
                                    .disabled(workspace.submitting)
                                }
                            }
                            Divider()
                            HStack(spacing: 18) {
                                Label(release.posted.formatted(date: .abbreviated, time: .omitted),
                                      systemImage: "calendar")
                                Label("\(release.sourceCount) indexers", systemImage: "server.rack")
                            }.font(.callout).foregroundStyle(.secondary)
                        }.padding(24)
                    }
                }
            }
        case .downloads, .library:
            let isLibrary = selection == .library
            let items = isLibrary ? snapshot.library : snapshot.downloads
            if items.isEmpty {
                ContentUnavailableView {
                    Label(isLibrary ? "Your library is empty" : "No downloads yet",
                          systemImage: isLibrary ? "film" : "arrow.down.circle")
                } description: {
                    Text(isLibrary ? "Completed videos appear here after filing." : "Choose a video from Recent uploads.")
                } actions: {
                    Button("Browse Uploads") { selection = .releases }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 16) {
                                Artwork(video: item.video).frame(width: 132, height: 74)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.video.title).font(.title2.bold())
                                    Text(item.video.studio).foregroundStyle(.secondary)
                                    if !isLibrary {
                                        Label(item.source, systemImage: "server.rack").font(.callout)
                                    }
                                    if item.filed, let path = item.finalPath {
                                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        Button("Show in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                        }
                                    } else {
                                        Label("Downloading in demo SABnzbd…", systemImage: "arrow.down.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }.padding(24)
                }
            }
        }
    }
}

struct Artwork: View {
    let video: Video
    var body: some View {
        if let image = NSImage(contentsOf: video.preview) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Preview of " + video.title)
        }
    }
}

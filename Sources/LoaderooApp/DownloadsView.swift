import SwiftUI
import LoaderooCore

private enum DownloadScope: String, CaseIterable {
    case all = "All", active = "Active", completed = "Completed", attention = "Needs attention"

    func includes(_ job: Transfer) -> Bool {
        let needsAttention = job.retryable || ["Awaiting filing", "Checking receipt"].contains(job.state)
        switch self {
        case .all: return true
        case .active: return !needsAttention && job.state != "Completed"
        case .completed: return job.state == "Completed"
        case .attention: return needsAttention
        }
    }
}

struct DownloadsView<Controls: View, Action: View>: View {
    let model: FeedWorkspace
    let query: String
    @Binding var selection: String?
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let retry: (FeedTitle) -> Action
    @State private var scope = DownloadScope.all

    var body: some View {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let jobs = model.jobs.filter { job in
            guard scope.includes(job) else { return false }
            if words.isEmpty { return true }
            let text = [job.title, job.studio, job.provider, job.releaseName, job.jobName, job.state, job.localPath, job.storage]
                .compactMap { $0 }.joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
        let detail = jobs.first { $0.id == selection }
        VStack(spacing: 0) {
            HStack {
                ViewThatFits(in: .horizontal) {
                    scopePicker.pickerStyle(.segmented).fixedSize()
                    scopePicker.pickerStyle(.menu)
                }
                Spacer(minLength: 0)
                controls()
            }.padding(.horizontal, 16).padding(.vertical, 9)
            Divider()
            Table(jobs, selection: $selection) {
                TableColumn("Title") { job in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.title).font(.headline).lineLimit(1)
                        if let studio = job.studio { Text(studio).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.padding(.vertical, 3)
                }.width(min: 100, ideal: 220)
                TableColumn("Status", value: \.state).width(min: 78, ideal: 106)
                TableColumn("Progress") { job in
                    if let value = job.progress ?? (job.storage != nil ? 100 : nil) {
                        HStack(spacing: 5) {
                            ProgressView(value: value, total: 100).progressViewStyle(.linear)
                            Text((value / 100).formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption).monospacedDigit()
                        }
                    } else { Text("—").foregroundStyle(.secondary) }
                }.width(min: 66, ideal: 100)
                TableColumn("Time left") { job in Text(job.timeLeft ?? "—").monospacedDigit() }
                    .width(min: 54, ideal: 72)
                TableColumn("Indexer", value: \.provider).width(min: 62, ideal: 110)
            }
            .overlay {
                if jobs.isEmpty {
                    ContentUnavailableView(model.jobs.isEmpty ? "No downloads yet" : "No matching downloads",
                                           systemImage: "arrow.down.circle",
                                           description: Text(model.jobs.isEmpty ? "Choose Download in the release catalog." :
                                            "Try a different search or status filter."))
                }
            }
            .overlay(alignment: .trailing) {
                if let detail {
                    DetailPanel(title: "Download details", close: { selection = nil }) {
                        inspector(detail)
                    }.id(detail.id)
                }
            }
            Divider()
            Text("\(jobs.count) of \(model.jobs.count) downloads").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private var scopePicker: some View {
        Picker("Download status", selection: $scope) {
            ForEach(DownloadScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden()
    }

    private func inspector(_ job: Transfer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LiveArtwork(remote: job.image.flatMap(URL.init(string:))).aspectRatio(16/9, contentMode: .fit)
            Text(job.title).font(.title2.bold()).textSelection(.enabled)
            Text(job.state).font(.headline)
            if let progress = job.progress, job.storage == nil {
                ProgressView(value: progress, total: 100) {
                    Text((progress / 100).formatted(.percent.precision(.fractionLength(0))))
                } currentValueLabel: {
                    if let eta = job.timeLeft { Text("\(eta) left") }
                }
            }
            if let note = job.note, !note.isEmpty { Label(note, systemImage: "info.circle").textSelection(.enabled) }
            Divider()
            field("Indexer", job.provider)
            field("Usenet release", job.releaseName)
            field("SABnzbd job name", job.jobName)
            field("Completion path", job.storage)
            field("Video file", job.localPath)
            if let path = job.localPath {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
            }
            if job.retryable, let title = model.page.titles.first(where: { $0.id.uuidString == job.video }) {
                retry(title)
            }
        }
    }

    @ViewBuilder private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

import SwiftUI

struct WorkspaceSearchField: View {
    @Binding var text: String
    let prompt: String
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button("Find", systemImage: "magnifyingglass") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).focused($focused).onSubmit(submit)
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    text = ""
                    focused = true
                }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minWidth: 145, maxWidth: 240)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: focused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }
}

struct DetailPanel<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Close details", systemImage: "xmark.circle.fill", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            ScrollView {
                content().frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 1).allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.15), radius: 6, x: -2, y: 0)
    }
}

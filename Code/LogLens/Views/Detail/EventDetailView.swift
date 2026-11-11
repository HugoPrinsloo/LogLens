import SwiftUI

struct EventDetailView: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        if let entry = store.selectedEntry {
            EntryDetail(entry: entry, starred: store.isStarred(entry.id)) { store.toggleStar(entry.id) }
                .id(entry.id)
        } else {
            ContentUnavailableView("No Event Selected", systemImage: "sidebar.trailing", description: Text("Select an event to inspect its properties."))
        }
    }
}

private struct EntryDetail: View {
    let entry: LogEntry
    let starred: Bool
    let toggleStar: () -> Void
    @State private var showRaw = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if !entry.parsed.fields.isEmpty {
                    DetailSection(title: "Fields", symbol: "list.bullet.rectangle") {
                        KeyValueGrid(fields: entry.parsed.fields)
                    }
                }

                ForEach(entry.parsed.groups) { group in
                    DetailSection(title: group.name, symbol: "curlybraces", trailing: group.typeName) {
                        KeyValueGrid(fields: group.fields)
                    }
                }

                if !entry.parsed.freeText.isEmpty && entry.parsed.isStructured {
                    DetailSection(title: "Text", symbol: "text.alignleft") {
                        ForEach(Array(entry.parsed.freeText.enumerated()), id: \.offset) { _, line in
                            Text(line).textSelection(.enabled)
                        }
                    }
                }

                // Network rows whose transaction the proxy no longer holds (10 k cap / body budget) still carry
                // their decoded bodies on the entry.
                if let net = entry.network {
                    if let body = net.requestBody {
                        DetailSection(title: "Request body", symbol: "arrow.up", trailing: "\(net.requestContent) \(NetworkStyle.bytes(net.requestSize))") {
                            JSONText(text: body, lineCap: 80)
                        }
                    }
                    if let body = net.responseBody {
                        DetailSection(title: "Response body", symbol: "arrow.down", trailing: "\(net.responseContent) \(NetworkStyle.bytes(net.responseSize))") {
                            JSONText(text: body, lineCap: 80)
                        }
                    }
                }

                DetailSection(title: "Message", symbol: "doc.plaintext", trailing: "\(entry.message.count) chars", collapsible: true, expanded: $showRaw) {
                    Text(entry.message)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }

                DetailSection(title: "Metadata", symbol: "info.circle") {
                    KeyValueGrid(fields: metadata)
                }
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { toggleStar() } label: { Image(systemName: starred ? "star.fill" : "star") }
                    .foregroundStyle(starred ? .yellow : .primary)
                    .help("Star")
                Menu {
                    Button("Copy Message") { Pasteboard.copy(entry.message) }
                    Button("Copy Title") { Pasteboard.copy(entry.parsed.title) }
                    Button("Copy as JSON") { Pasteboard.copy(Pasteboard.json(for: entry)) }
                } label: { Image(systemName: "doc.on.doc") }
                .help("Copy")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LevelBadge(level: entry.level)
                Text(entry.parsed.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            HStack(spacing: 6) {
                Image(systemName: "app").foregroundStyle(.secondary)
                Text(entry.process).fontWeight(.medium)
                Text("›").foregroundStyle(.tertiary)
                Text(entry.subsystemDisplay)
                Text("›").foregroundStyle(.tertiary)
                Text(entry.categoryDisplay)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            Text(Formatters.fullMillis.string(from: entry.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var metadata: [ParsedMessage.Field] {
        var f: [ParsedMessage.Field] = [
            .init(id: 1, key: "Source", value: entry.sourceName),
            .init(id: 2, key: "Process", value: "\(entry.process) (pid \(entry.processID))"),
            .init(id: 3, key: "Thread", value: String(entry.threadID)),
            .init(id: 4, key: "Sender", value: entry.sender),
            .init(id: 5, key: "Level", value: entry.level.name),
        ]
        if let a = entry.activityID { f.append(.init(id: 6, key: "Activity", value: String(a))) }
        if let t = entry.traceID { f.append(.init(id: 7, key: "Trace", value: String(t))) }
        f.append(.init(id: 8, key: "Path", value: entry.processPath))
        return f
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let symbol: String
    var trailing: String? = nil
    var collapsible = false
    var expanded: Binding<Bool>? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption).foregroundStyle(.tertiary)
                }
                if collapsible, let expanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
                    } label: {
                        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if expanded?.wrappedValue ?? true {
                content()
            }
        }
    }
}

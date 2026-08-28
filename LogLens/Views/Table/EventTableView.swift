import SwiftUI

struct EventTableView: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.entries.isEmpty {
                EmptyStateView()
            } else if store.filtered.isEmpty {
                ContentUnavailableView.search(text: store.filter.searchText)
            } else {
                ScrollViewReader { proxy in
                    Table(store.filtered, selection: $store.selection) {
                        TableColumn("Time") { e in
                            Text(Formatters.time.string(from: e.timestamp))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 104, ideal: 108, max: 130)

                        TableColumn("") { e in
                            LevelDot(level: e.level, starred: store.isStarred(e.id))
                        }
                        .width(22)

                        TableColumn("App") { e in
                            Text(e.process).lineLimit(1)
                        }
                        .width(min: 60, ideal: 110, max: 220)

                        TableColumn("Subsystem") { e in
                            Text(e.subsystemDisplay).lineLimit(1).foregroundStyle(.secondary)
                        }
                        .width(min: 60, ideal: 130, max: 300)

                        TableColumn("Category") { e in
                            Text(e.categoryDisplay).lineLimit(1).foregroundStyle(.secondary)
                        }
                        .width(min: 60, ideal: 120, max: 260)

                        TableColumn("Event") { e in
                            EventCell(entry: e)
                        }
                        .width(min: 200, ideal: 600)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                    .contextMenu(forSelectionType: LogEntry.ID.self) { ids in
                        if let id = ids.first, let e = store.filtered.last(where: { $0.id == id }) {
                            Button(store.isStarred(id) ? "Unstar" : "Star") { store.toggleStar(id) }
                            Divider()
                            Button("Copy Message") { Pasteboard.copy(e.message) }
                            Button("Copy Title") { Pasteboard.copy(e.parsed.title) }
                            Button("Copy as JSON") { Pasteboard.copy(Pasteboard.json(for: e)) }
                            Divider()
                            Button("Only “\(e.process)”") { store.toggleFacet(.process(e.process), exclusive: true) }
                            Button("Only “\(e.subsystemDisplay)”") { store.toggleFacet(.subsystem(e.subsystem), exclusive: true) }
                            Button("Only “\(e.categoryDisplay)”") { store.toggleFacet(.category(e.category), exclusive: true) }
                        }
                    }
                    .onChange(of: store.filtered.count) { _, _ in
                        guard store.autoScroll, let last = store.filtered.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                    .onChange(of: store.autoScroll) { _, on in
                        guard on, let last = store.filtered.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct LevelDot: View {
    let level: LogLevel
    let starred: Bool

    var body: some View {
        ZStack {
            Circle().fill(level.color).frame(width: 8, height: 8)
            if starred {
                Image(systemName: "star.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.yellow)
                    .offset(x: 6, y: -6)
            }
        }
        .help(level.name)
    }
}

private struct EventCell: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.parsed.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(entry.level >= .error ? entry.level.color : .primary)
            if !entry.parsed.summary.isEmpty {
                Text(entry.parsed.summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }
        }
    }
}

struct EmptyStateView: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: store.isCapturing ? "dot.radiowaves.left.and.right" : "waveform.badge.magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: store.isCapturing)
            Text(store.isCapturing ? "Listening for events…" : "No events yet")
                .font(.title2.weight(.semibold))
            if store.isCapturing {
                Text("Interact with the app on **\(store.selectedSource.name)**. Anything it logs via OSLog will show up here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Pick a booted simulator (or This Mac) in the toolbar.")
                    step(2, "Press **Record** (⌘R) and use the app.")
                    step(3, "Click apps, subsystems or categories in the sidebar to filter. ⌘-click to combine.")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)
            }
            Text(store.commandPreview)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: 640)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text)
        }
    }
}

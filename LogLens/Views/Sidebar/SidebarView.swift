import SwiftUI

struct SidebarView: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        List {
            Section {
                SourceCard()
            }

            FacetSection(title: "Apps", symbol: "app.badge", counts: store.processCounts, make: Facet.process)
            FacetSection(title: "Subsystems", symbol: "shippingbox", counts: store.subsystemCounts, make: Facet.subsystem)
            FacetSection(title: "Categories", symbol: "tag", counts: store.categoryCounts, make: Facet.category)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if store.filter.isActive {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
                    Text("Filters active").font(.caption)
                    Spacer()
                    Button("Reset") { store.resetFilter() }.controlSize(.small)
                }
                .padding(10)
                .background(.bar)
            }
        }
    }
}

private struct SourceCard: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: store.selectedSource.symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.selectedSource.name).font(.headline)
                    Text(store.selectedSource.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Button {
                    store.toggleCapture()
                } label: {
                    Label(store.isCapturing ? "Stop" : "Record", systemImage: store.isCapturing ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(store.isCapturing ? .red : .accentColor)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!store.selectedSource.isSupported)

                Button { store.clear() } label: { Image(systemName: "trash") }
                    .controlSize(.small)
                    .help("Clear events")
            }
            if !store.selectedSource.isSupported {
                Text("Physical devices need a different transport and aren't supported yet.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FacetSection: View {
    @Environment(EventStore.self) private var store
    let title: String
    let symbol: String
    let counts: [String: Int]
    let make: (String) -> Facet

    private var rows: [(key: String, count: Int)] {
        counts.map { (key: $0.key, count: $0.value) }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.key < $1.key
        }
    }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text("No events yet").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(rows, id: \.key) { row in
                let facet = make(row.key)
                let selected = store.filter.facets.contains(facet)
                FacetRow(name: row.key.isEmpty ? "(none)" : row.key, count: row.count, selected: selected, dimmed: row.key.isEmpty)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let cmd = NSEvent.modifierFlags.contains(.command)
                        store.toggleFacet(facet, exclusive: !cmd)
                    }
                    .contextMenu {
                        Button(selected ? "Remove from filter" : "Add to filter") { store.toggleFacet(facet, exclusive: false) }
                        Button("Only this") { store.toggleFacet(facet, exclusive: true) }
                        Divider()
                        Button("Copy “\(row.key)”") { Pasteboard.copy(row.key) }
                    }
            }
        } header: {
            Label(title, systemImage: symbol)
        }
    }
}

private struct FacetRow: View {
    let name: String
    let count: Int
    let selected: Bool
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                .font(.system(size: 12))
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(dimmed ? .secondary : .primary)
            Spacer(minLength: 4)
            Text(Formatters.count(count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 1)
    }
}

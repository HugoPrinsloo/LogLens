import SwiftUI

struct SidebarView: View {
    @Environment(EventStore.self) private var store
    @State private var query = ""

    var body: some View {
        List {
            Section {
                SourceCard()
            }

            Section {
                FacetSearchField(text: $query)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
            }

            FacetSection(title: "Apps", symbol: "app.badge", counts: store.processCounts, query: query, make: Facet.process)
            FacetSection(title: "Subsystems", symbol: "shippingbox", counts: store.subsystemCounts, query: query, make: Facet.subsystem)
            FacetSection(title: "Categories", symbol: "tag", counts: store.categoryCounts, query: query, make: Facet.category)
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
    @Environment(NetworkStore.self) private var network

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
                .help(store.isCapturing ? "Stop recording (⌘R)" : "Start recording logs and HTTP(S) requests (⌘R)")

                Button { store.clear() } label: { Image(systemName: "trash") }
                    .controlSize(.small)
                    .help("Clear events")
            }
            if !store.selectedSource.isSupported {
                Text("Physical devices need a different transport and aren't supported yet.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if store.isCapturing && store.captureNetwork {
                Label(network.statusLine, systemImage: network.isCapturing ? "network" : "network.badge.shield.half.filled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Filters the facet lists below by name.
private struct FacetSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
            TextField("Search filters", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.separator))
    }
}

private struct FacetSection: View {
    @Environment(EventStore.self) private var store
    let title: String
    let symbol: String
    let counts: [String: Int]
    let query: String
    let make: (String) -> Facet

    private var rows: [(key: String, count: Int)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return counts
            .filter { q.isEmpty || $0.key.localizedCaseInsensitiveContains(q) }
            .map { (key: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.key < $1.key
            }
    }

    private var selectedCount: Int {
        counts.keys.filter { store.filter.facets.contains(make($0)) }.count
    }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text(counts.isEmpty ? "No events yet" : "No matches").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(rows, id: \.key) { row in
                let facet = make(row.key)
                let selected = store.filter.facets.contains(facet)
                FacetRow(name: row.key.isEmpty ? "(none)" : row.key, count: row.count, selected: selected, dimmed: row.key.isEmpty)
                    .contentShape(Rectangle())
                    // Click toggles: selecting adds to the current selection, clicking a selected row deselects it.
                    .onTapGesture { store.toggleFacet(facet) }
                    .contextMenu {
                        Button("Only This") { store.toggleFacet(facet, exclusive: true) }
                        Button("Clear \(title) Selection") { store.clearFacets(ofKind: facet) }
                            .disabled(selectedCount == 0)
                        Divider()
                        Menu("Timeline Lanes") {
                            ForEach(Array(store.lanes.enumerated()), id: \.element.id) { i, lane in
                                Button {
                                    store.assignFacet(facet, toLaneAt: i)
                                } label: {
                                    if lane.facets.contains(facet) {
                                        Label("Lane \(i + 1): \(lane.title)", systemImage: "checkmark")
                                    } else {
                                        Text("Lane \(i + 1): \(lane.title)")
                                    }
                                }
                            }
                            if store.lanes.count < EventStore.maxLanes {
                                Button("Show in New Lane") { store.assignFacet(facet, toLaneAt: store.lanes.count) }
                            }
                        }
                        Divider()
                        Button("Copy “\(row.key)”") { Pasteboard.copy(row.key) }
                    }
            }
        } header: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if selectedCount > 0 {
                    Button("Clear") { store.clearFacets(ofKind: make("")) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .help("Deselect all \(title.lowercased())")
                }
            }
        }
    }
}

struct FacetRow: View {
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

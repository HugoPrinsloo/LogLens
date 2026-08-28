import SwiftUI

struct NetworkSidebar: View {
    @Environment(NetworkStore.self) private var network

    var body: some View {
        List {
            Section { ProxyCard() }
            NetworkFacetSection(title: "Apps", symbol: "app.badge", counts: network.processCounts,
                                selected: network.processFilter) { network.processFilter = $0 }
            NetworkFacetSection(title: "Hosts", symbol: "globe", counts: network.hostCounts,
                                selected: network.hostFilter) { network.hostFilter = $0 }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if network.isFilterActive {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
                    Text("Filters active").font(.caption)
                    Spacer()
                    Button("Reset") { network.resetFilter() }.controlSize(.small)
                }
                .padding(10)
                .background(.bar)
            }
        }
    }
}

private struct ProxyCard: View {
    @Environment(NetworkStore.self) private var network

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("HTTP(S) Proxy").font(.headline)
                    Text(network.statusLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Button {
                    network.toggleCapture()
                } label: {
                    Label(network.isCapturing ? "Stop" : "Record", systemImage: network.isCapturing ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(network.isCapturing ? .red : .accentColor)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(network.isStarting)

                Button { network.clear() } label: { Image(systemName: "trash") }
                    .controlSize(.small)
                    .help("Clear requests")
            }
            Menu {
                Button("Heal Connection") { Task { await network.repair() } }
                Button("Reinstall in Booted Simulators") { Task { await network.reinstallCertificate() } }
                Button("Trust on This Mac…") { Task { await network.trustOnThisMac() } }
                Divider()
                Button("Forget Pinned Hosts (\(network.bypassHosts.count))") { network.clearBypassHosts() }
                    .disabled(network.bypassHosts.isEmpty)
                Divider()
                Button("Reveal Certificate in Finder") {
                    if !network.caPath.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: network.caPath)]) }
                }
                .disabled(network.caPath.isEmpty)
            } label: {
                Label(network.caFingerprint.isEmpty ? "Certificate" : "Certificate \(network.caFingerprint.prefix(8))…", systemImage: "checkmark.seal")
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            Picker("Decrypt", selection: Binding(get: { network.policy }, set: { network.policy = $0 })) {
                ForEach(DecryptPolicy.allCases) { Text($0.title).tag($0) }
            }
            .font(.caption)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private struct NetworkFacetSection: View {
    let title: String
    let symbol: String
    let counts: [String: Int]
    let selected: String?
    let select: (String?) -> Void

    private var rows: [(key: String, count: Int)] {
        counts.map { (key: $0.key, count: $0.value) }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.key < $1.key
        }
    }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text("No requests yet").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(rows, id: \.key) { row in
                let isSelected = selected == row.key
                FacetRow(name: row.key.isEmpty ? "(unknown)" : row.key, count: row.count, selected: isSelected, dimmed: row.key.isEmpty)
                    .contentShape(Rectangle())
                    .onTapGesture { select(isSelected ? nil : row.key) }
                    .contextMenu {
                        Button("Copy “\(row.key)”") { Pasteboard.copy(row.key) }
                    }
            }
        } header: {
            Label(title, systemImage: symbol)
        }
    }
}

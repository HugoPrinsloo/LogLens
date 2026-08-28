import SwiftUI

struct NetworkView: View {
    @Environment(NetworkStore.self) private var network

    var body: some View {
        @Bindable var network = network
        Group {
            if network.transactions.isEmpty {
                NetworkEmptyState()
            } else if network.filtered.isEmpty {
                ContentUnavailableView.search(text: network.searchText)
            } else {
                ScrollViewReader { proxy in
                    Table(network.filtered, selection: $network.selection) {
                        TableColumn("Time") { t in
                            Text(Formatters.time.string(from: t.startedAt))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 100, ideal: 104, max: 130)

                        TableColumn("Method") { t in MethodBadge(method: t.method) }
                            .width(min: 56, ideal: 64, max: 80)

                        TableColumn("Status") { t in StatusBadge(tx: t) }
                            .width(min: 48, ideal: 58, max: 90)

                        TableColumn("App") { t in
                            HStack(spacing: 4) {
                                if !t.clientIsSimulator && !t.clientProcess.isEmpty {
                                    Image(systemName: "desktopcomputer").font(.caption2).foregroundStyle(.tertiary)
                                }
                                Text(t.clientProcess.isEmpty ? "?" : t.clientProcess).lineLimit(1)
                            }
                        }
                        .width(min: 60, ideal: 84, max: 200)

                        TableColumn("Host") { t in
                            Text(t.host).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        }
                        .width(min: 100, ideal: 170, max: 400)

                        TableColumn("Path") { t in PathCell(tx: t) }
                            .width(min: 180, ideal: 260)

                        TableColumn("Size") { t in
                            HStack(spacing: 4) {
                                Text(t.isTunnel ? "—" : NetworkStyle.bytes(t.responseBodySize)).monospacedDigit()
                                let type = NetworkStyle.shortType(t.responseContentType)
                                if !type.isEmpty { Text(type).foregroundStyle(.tertiary) }
                            }
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .width(min: 64, ideal: 96, max: 160)

                        TableColumn("Duration") { t in
                            Text(NetworkStyle.duration(t.duration))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .width(min: 56, ideal: 68, max: 100)

                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                    .contextMenu(forSelectionType: NetworkTransaction.ID.self) { ids in
                        if let id = ids.first, let t = network.filtered.last(where: { $0.id == id }) {
                            Button("Copy URL") { Pasteboard.copy(t.url) }
                            Button("Copy as cURL") { Pasteboard.copy(t.curlCommand) }
                            Button("Copy Response Body") { Pasteboard.copy(t.decodedResponseText ?? "") }
                                .disabled(t.responseBody.isEmpty)
                            Divider()
                            if network.isBypassed(t.host) {
                                Button("Try Decrypting “\(t.host)” Again") { network.setBypass(t.host, false) }
                            } else {
                                Button("Don’t Decrypt “\(t.host)”") { network.setBypass(t.host, true) }
                            }
                            Divider()
                            Button("Only “\(t.host)”") { network.hostFilter = t.host }
                            Button("Only “\(t.clientProcess)”") { network.processFilter = t.clientProcess }
                                .disabled(t.clientProcess.isEmpty)
                        }
                    }
                    .onChange(of: network.filtered.count) { _, _ in
                        guard network.autoScroll, let last = network.filtered.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottomLeading)
                    }
                    .onChange(of: network.autoScroll) { _, on in
                        guard on, let last = network.filtered.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottomLeading)
                    }
                }
            }
        }
    }
}

private struct PathCell: View {
    let tx: NetworkTransaction

    var body: some View {
        HStack(spacing: 6) {
            if tx.isTunnel {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                Text(tx.note ?? "TLS tunnel (not decrypted)").foregroundStyle(.tertiary).lineLimit(1)
            } else if tx.path.isEmpty, let error = tx.error {
                Text(error).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(tx.pathOnly)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(tx.state == .failed ? .red : .primary)
                if let q = tx.query {
                    Text("?" + q)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
            }
        }
    }
}

struct NetworkEmptyState: View {
    @Environment(NetworkStore.self) private var network

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: network.isCapturing ? "dot.radiowaves.left.and.right" : "network")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: network.isCapturing)
            Text(network.isCapturing ? "Waiting for requests…" : "No requests yet")
                .font(.title2.weight(.semibold))
            if network.isCapturing {
                Text("Use an app in a booted simulator. Its HTTP(S) requests — headers and bodies — show up here as they happen.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Press **Record** (⌘R). LogLens starts a local proxy, installs its certificate in booted simulators and points the Mac's proxy at itself.")
                    step(2, "Use the app in the simulator. Requests appear with full request and response bodies.")
                    step(3, "Stop, quit or crash — the Mac's proxy settings are restored automatically.")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
                Text("While capturing, all of this Mac's web traffic passes through LogLens (untouched unless you choose to decrypt it). Apps that pin certificates show up as failed handshakes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.top, 6)
            }
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

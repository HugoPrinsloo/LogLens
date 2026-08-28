import SwiftUI

struct ContentView: View {
    @Environment(EventStore.self) private var store
    @Environment(NetworkStore.self) private var network
    @State private var searchText = ""
    @State private var networkSearchText = ""
    @State private var isExporting = false
    @State private var exportFiltered = true

    private var isNetwork: Bool { store.viewMode == .network }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Group {
                if isNetwork { NetworkSidebar() } else { SidebarView() }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.captureError, !isNetwork {
                    ErrorBanner(message: error) { store.dismissError() }
                }
                if let error = network.error, isNetwork {
                    ErrorBanner(message: error) { network.dismissError() }
                }
                switch store.viewMode {
                case .table: EventTableView()
                case .timeline: EventTimelineView()
                case .network: NetworkView()
                }
                Divider()
                StatusBar()
            }
            // Timeline cards expand in place, so the inspector only applies to the table and network views.
            .inspector(isPresented: Binding(
                get: { isNetwork ? network.showInspector : (store.showInspector && store.viewMode == .table) },
                set: { if isNetwork { network.showInspector = $0 } else { store.showInspector = $0 } }
            )) {
                Group {
                    if isNetwork { NetworkDetailView() } else { EventDetailView() }
                }
                .inspectorColumnWidth(min: 320, ideal: 400, max: 800)
            }
        }
        .navigationTitle("LogLens")
        .navigationSubtitle(subtitle)
        .searchable(
            text: Binding(get: { isNetwork ? networkSearchText : searchText }, set: { if isNetwork { networkSearchText = $0 } else { searchText = $0 } }),
            placement: .toolbar,
            prompt: isNetwork ? "Filter requests" : "Filter events"
        )
        .onChange(of: searchText) { _, new in store.updateFilter { $0.searchText = new } }
        .onChange(of: networkSearchText) { _, new in network.searchText = new }
        .toolbar { CaptureToolbar(isExporting: $isExporting, exportFiltered: $exportFiltered) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.stopCapture() }
        .fileExporter(
            isPresented: $isExporting,
            document: ExportDocument(data: store.exportData(onlyFiltered: exportFiltered)),
            contentType: .json,
            defaultFilename: "LogLens-\(Formatters.fullMillis.string(from: Date()).prefix(19).replacingOccurrences(of: ":", with: "-"))"
        ) { _ in }
    }

    private var subtitle: String {
        if isNetwork { return network.isCapturing ? "Capturing HTTP(S) · \(network.statusLine)" : "Network idle" }
        return store.isCapturing ? "Capturing \(store.selectedSource.name)" : "Idle"
    }
}

// MARK: - Toolbar

struct CaptureToolbar: ToolbarContent {
    @Environment(EventStore.self) private var store
    @Environment(NetworkStore.self) private var network
    @Binding var isExporting: Bool
    @Binding var exportFiltered: Bool

    var body: some ToolbarContent {
        if store.viewMode == .network {
            networkItems
        } else {
            logItems
        }
    }

    private var viewPicker: some View {
        Picker("View", selection: Binding(get: { store.viewMode }, set: { store.viewMode = $0 })) {
            ForEach(EventViewMode.allCases) { m in
                Image(systemName: m.symbol).tag(m).help(m.title)
            }
        }
        .pickerStyle(.segmented)
        .help("Switch between list, timeline and network view")
    }

    @ToolbarContentBuilder private var networkItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Label {
                VStack(alignment: .leading, spacing: 0) {
                    Text("HTTP(S) Proxy")
                    Text(network.statusLine).font(.caption2).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "network")
            }
            .labelStyle(.titleAndIcon)
        }

        ToolbarItemGroup(placement: .principal) {
            viewPicker

            Button {
                network.toggleCapture()
            } label: {
                Label(network.isCapturing ? "Stop" : "Record", systemImage: network.isCapturing ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(network.isCapturing ? .red : .primary)
            }
            .help(network.isCapturing ? "Stop the proxy and restore Mac proxy settings (⌘R)" : "Start the proxy (⌘R)")
            .disabled(network.isStarting)

            Button { network.clear() } label: { Label("Clear", systemImage: "trash") }
                .help("Clear all requests (⌘K)")
                .disabled(network.transactions.isEmpty)

            Button {
                Task { await network.repair() }
            } label: {
                Label("Heal", systemImage: "bandage.fill")
            }
            .help("Heal the connection: restore the Mac proxy, reinstall the certificate in every booted simulator, restart the proxy")
            .disabled(network.isStarting)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(DecryptPolicy.allCases) { p in
                    Button {
                        network.policy = p
                    } label: {
                        if p == network.policy { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                    }
                }
            } label: {
                Label("Decrypt", systemImage: network.policy == .nothing ? "lock" : "lock.open")
            }
            .help("Which clients' TLS connections LogLens decrypts")

            Toggle(isOn: Binding(get: { network.autoScroll }, set: { network.autoScroll = $0 })) {
                Label("Auto-scroll", systemImage: "arrow.down.to.line")
            }
            .help("Follow newest requests (⇧⌘T)")

            Button {
                network.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle inspector (⌥⌘I)")
        }
    }

    @ToolbarContentBuilder private var logItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            SourceMenu()
        }

        ToolbarItemGroup(placement: .principal) {
            viewPicker

            Button {
                store.toggleCapture()
            } label: {
                Label(store.isCapturing ? "Stop" : "Record", systemImage: store.isCapturing ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(store.isCapturing ? .red : .primary)
            }
            .help(store.isCapturing ? "Stop capturing (⌘R)" : "Start capturing (⌘R)")

            Button { store.clear() } label: { Label("Clear", systemImage: "trash") }
                .help("Clear all events (⌘K)")
                .disabled(store.entries.isEmpty)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if store.viewMode == .timeline {
                Toggle(isOn: Binding(
                    get: { !store.lanes.isEmpty },
                    set: { on in if on { store.enableSplit() } else { store.disableSplit() } }
                )) {
                    Label("Split", systemImage: "rectangle.split.2x1")
                }
                .help("Split the timeline into side-by-side lanes")

                Toggle(isOn: Binding(get: { store.timelineExpandAll }, set: { store.timelineExpandAll = $0 })) {
                    Label("Expand All", systemImage: store.timelineExpandAll ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .help(store.timelineExpandAll ? "Show new events collapsed" : "Show all events expanded")

                Toggle(isOn: Binding(get: { store.copyCardOnClick }, set: { store.copyCardOnClick = $0 })) {
                    Label("Copy as Image", systemImage: "photo.on.rectangle.angled")
                }
                .help(store.copyCardOnClick ? "Clicking a card copies it as a PNG (click again to go back to expand/collapse)" : "Turn on to copy a card as a PNG when you click it")
            }

            Toggle(isOn: Binding(get: { store.showNetworkEvents }, set: { store.showNetworkEvents = $0 })) {
                Label("Network", systemImage: "network")
            }
            .help(store.showNetworkEvents ? "Hide HTTP requests captured by the proxy" : "Show HTTP requests captured by the proxy alongside log events")

            ScopeMenu()
            LevelMenu()

            Toggle(isOn: Binding(get: { store.filter.onlyStarred }, set: { v in store.updateFilter { $0.onlyStarred = v } })) {
                Label("Starred", systemImage: store.filter.onlyStarred ? "star.fill" : "star")
            }
            .help("Show only starred events")

            Toggle(isOn: Binding(get: { store.autoScroll }, set: { store.autoScroll = $0 })) {
                Label("Auto-scroll", systemImage: "arrow.down.to.line")
            }
            .help("Follow newest events (⇧⌘T)")

            Menu {
                Button("Export Filtered Events…") { exportFiltered = true; isExporting = true }
                Button("Export All Events…") { exportFiltered = false; isExporting = true }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(store.entries.isEmpty)

            Button {
                store.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle inspector (⌥⌘I)")
            .disabled(store.viewMode == .timeline)
        }
    }
}

struct SourceMenu: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        Menu {
            Section("Simulators") {
                ForEach(store.sources.filter(\.isSimulator)) { s in sourceRow(s) }
            }
            let devices = store.sources.filter { if case .physicalDevice = $0.kind { true } else { false } }
            if !devices.isEmpty {
                Section("Devices") { ForEach(devices) { s in sourceRow(s) } }
            }
            Section { sourceRow(.mac) }
            Divider()
            Button("Refresh Sources") { store.refreshSources() }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.selectedSource.name)
                    Text(store.selectedSource.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: store.selectedSource.symbol)
            }
        }
        .menuIndicator(.visible)
        .disabled(store.isCapturing)
        .help("Choose which simulator or Mac to stream logs from")
    }

    private func sourceRow(_ s: LogSource) -> some View {
        Button {
            store.selectedSource = s
        } label: {
            HStack {
                Image(systemName: s.symbol)
                Text(s.name)
                Text("· \(s.subtitle)").foregroundStyle(.secondary)
                if s.id == store.selectedSource.id { Image(systemName: "checkmark") }
            }
        }
        .disabled(!s.isSupported)
    }
}

struct ScopeMenu: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        Menu {
            ForEach(CaptureScope.allCases) { scope in
                Button {
                    store.scope = scope
                } label: {
                    if scope == store.scope { Label(scope.title, systemImage: "checkmark") } else { Text(scope.title) }
                }
            }
            Divider()
            Text(store.scope.help)
            if store.isCapturing { Text("Restart capture to apply.").foregroundStyle(.secondary) }
        } label: {
            Label("Scope", systemImage: "scope")
        }
        .help("What the log stream captures at the source")
    }
}

struct LevelMenu: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        Menu {
            ForEach(LogLevel.allCases) { level in
                Toggle(isOn: Binding(
                    get: { store.filter.levels.contains(level) },
                    set: { on in store.updateFilter { f in if on { f.levels.insert(level) } else { f.levels.remove(level) } } }
                )) {
                    Label(level.name, systemImage: level.symbol)
                }
            }
            Divider()
            Button("All Levels") { store.updateFilter { $0.levels = Set(LogLevel.allCases) } }
        } label: {
            Label("Levels", systemImage: store.filter.levels.count == LogLevel.allCases.count ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter by log level")
    }
}

// MARK: - Banners & status

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

struct StatusBar: View {
    @Environment(EventStore.self) private var store
    @Environment(NetworkStore.self) private var network

    var body: some View {
        if store.viewMode == .network { networkBar } else { logBar }
    }

    private var networkBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(network.isCapturing ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .overlay {
                        if network.isCapturing {
                            Circle().stroke(Color.red.opacity(0.35), lineWidth: 3).scaleEffect(1.6)
                        }
                    }
                Text(network.isCapturing ? "Proxy on 127.0.0.1:\(String(network.port))" : "Proxy idle")
            }
            Divider().frame(height: 12)
            Text("\(Formatters.count(network.filtered.count)) of \(Formatters.count(network.transactions.count)) requests")
            if network.isFilterActive {
                Button("Reset filters") { network.resetFilter() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
            Text(network.policy.title).foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var logBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isCapturing ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .overlay {
                        if store.isCapturing {
                            Circle().stroke(Color.red.opacity(0.35), lineWidth: 3).scaleEffect(1.6)
                        }
                    }
                Text(store.isCapturing ? "Capturing" : "Idle")
            }
            Divider().frame(height: 12)
            Text("\(Formatters.count(store.filtered.count)) of \(Formatters.count(store.entries.count)) events")
            if store.filter.isActive {
                Button("Reset filters") { store.resetFilter() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
            if store.isCapturing {
                Text("\(store.eventsPerSecond)/s").monospacedDigit()
                Divider().frame(height: 12)
            }
            Text("buffer \(Formatters.count(store.maxEntries))")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

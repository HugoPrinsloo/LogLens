import SwiftUI

struct ContentView: View {
    @Environment(EventStore.self) private var store
    @Environment(NetworkStore.self) private var network
    @Environment(UpdateChecker.self) private var updates
    @State private var searchText = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var exportDocument: ExportDocument?

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let release = updates.availableUpdate {
                    UpdateBanner(release: release)
                }
                if let error = store.captureError {
                    ErrorBanner(message: error) { store.dismissError() }
                }
                if let error = network.error {
                    ErrorBanner(message: "HTTP(S) proxy: \(error)") { network.dismissError() }
                }
                switch store.viewMode {
                case .table: EventTableView()
                case .timeline: EventTimelineView()
                }
                Divider()
                StatusBar()
            }
            // Timeline cards expand in place, so the inspector only applies to the table.
            .inspector(isPresented: Binding(
                get: { store.showInspector && store.viewMode == .table },
                set: { store.showInspector = $0 }
            )) {
                InspectorContent()
                    .inspectorColumnWidth(min: 320, ideal: 400, max: 800)
            }
        }
        .navigationTitle("LogLens")
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter events")
        // Debounced: a keystroke applies ~120 ms after typing pauses, so fast typing runs one filter pass, not six.
        .onChange(of: searchText) { _, new in
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                store.updateFilter { $0.searchText = new }
            }
        }
        .toolbar { CaptureToolbar(exportDocument: $exportDocument) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.stopCapture() }
        .alert(item: Binding(get: { updates.manualResult }, set: { updates.manualResult = $0 })) { result in
            Alert(title: Text(result.title), message: Text(result.message))
        }
        // The document is encoded off the main actor when the menu item is chosen; the panel opens once it's ready.
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .json,
            defaultFilename: "LogLens-\(Formatters.fullMillis.string(from: Date()).prefix(19).replacingOccurrences(of: ":", with: "-"))"
        ) { _ in }
    }

    private var subtitle: String {
        guard store.isCapturing else { return "Idle" }
        return network.isCapturing ? "Recording \(store.selectedSource.name) + HTTP(S)" : "Recording \(store.selectedSource.name)"
    }
}

/// Lives in its own view so `ContentView.body` doesn't depend on `filtered` (which changes on every batch).
private struct InspectorContent: View {
    @Environment(EventStore.self) private var store
    @Environment(NetworkStore.self) private var network

    var body: some View {
        // A network row gets the full request inspector (headers, raw bodies) while the proxy still holds it.
        if let entry = store.selectedEntry, entry.isNetwork, let tx = network.transaction(id: entry.id - LogEntry.networkIDBase) {
            NetworkDetailView(tx: tx)
        } else {
            EventDetailView()
        }
    }
}

// MARK: - Toolbar

struct CaptureToolbar: ToolbarContent {
    @Environment(EventStore.self) private var store
    @Environment(NetworkStore.self) private var network
    @Binding var exportDocument: ExportDocument?

    var body: some ToolbarContent {
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
            .help(store.isCapturing ? "Stop recording (⌘R)" : "Start recording logs and HTTP(S) requests (⌘R)")

            Button { store.clear() } label: { Label("Clear", systemImage: "trash") }
                .help("Clear all events (⌘K)")
                .disabled(!store.hasEntries)
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

            NetworkMenu()
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
                Button("Export Filtered Events…") { export(onlyFiltered: true) }
                Button("Export All Events…") { export(onlyFiltered: false) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(!store.hasEntries)

            Button {
                store.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Toggle inspector (⌥⌘I)")
            .disabled(store.viewMode == .timeline)
        }
    }

    private func export(onlyFiltered: Bool) {
        Task {
            let data = await store.exportData(onlyFiltered: onlyFiltered)
            exportDocument = ExportDocument(data: data)
        }
    }

    private var viewPicker: some View {
        Picker("View", selection: Binding(get: { store.viewMode }, set: { store.viewMode = $0 })) {
            ForEach(EventViewMode.allCases) { m in
                Image(systemName: m.symbol).tag(m).help(m.title)
            }
        }
        .pickerStyle(.segmented)
        .help("Switch between list and timeline")
    }
}

/// HTTP(S) capture on/off plus the proxy's certificate and decrypt settings.
struct NetworkMenu: View {
    @Environment(EventStore.self) private var store
    @Environment(NetworkStore.self) private var network

    var body: some View {
        Menu {
            Toggle("Capture HTTP(S) Requests", isOn: Binding(get: { store.captureNetwork }, set: { store.captureNetwork = $0 }))
            Text(network.statusLine).foregroundStyle(.secondary)
            Divider()
            // Restore the Mac proxy, reinstall the certificate in every booted simulator, restart the proxy.
            Button("Heal Connection", systemImage: "bandage.fill") { Task { await network.repair() } }
                .disabled(!store.isCapturing || !store.captureNetwork || network.isStarting)
            Divider()
            Picker("Decrypt", selection: Binding(get: { network.policy }, set: { network.policy = $0 })) {
                ForEach(DecryptPolicy.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Reinstall Certificate in Booted Simulators") { Task { await network.reinstallCertificate() } }
            Button("Trust Certificate on This Mac…") { Task { await network.trustOnThisMac() } }
            Button("Forget Pinned Hosts (\(network.bypassHosts.count))") { network.clearBypassHosts() }
                .disabled(network.bypassHosts.isEmpty)
            Button("Reveal Certificate in Finder") {
                if !network.caPath.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: network.caPath)]) }
            }
            .disabled(network.caPath.isEmpty)
        } label: {
            Label("Network", systemImage: store.captureNetwork ? "network" : "network.slash")
        }
        .help(store.captureNetwork ? "HTTP(S) requests are captured with the recording" : "HTTP(S) capture is off")
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

/// "A newer LogLens is out": download the dmg, read the notes, or skip this version.
struct UpdateBanner: View {
    @Environment(UpdateChecker.self) private var updates
    let release: UpdateChecker.Release

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text("LogLens \(release.version) is available.").font(.callout.weight(.medium))
            Text("You have \(updates.currentVersion).").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Release Notes") { updates.openReleaseNotes(release) }
                .buttonStyle(.borderless)
            Button("Download") { updates.download(release) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button { updates.skipAvailableUpdate() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Skip this version")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }
}

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
                Text(store.isCapturing ? "Recording" : "Idle")
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
            if store.isCapturing && store.captureNetwork {
                Label(network.isCapturing ? "HTTP(S) on :\(String(network.port))" : network.statusLine, systemImage: "network")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

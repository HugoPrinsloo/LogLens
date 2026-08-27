import SwiftUI

struct ContentView: View {
    @Environment(EventStore.self) private var store
    @State private var searchText = ""
    @State private var isExporting = false
    @State private var exportFiltered = true

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.captureError {
                    ErrorBanner(message: error) { store.dismissError() }
                }
                EventTableView()
                Divider()
                StatusBar()
            }
            .inspector(isPresented: $store.showInspector) {
                EventDetailView()
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 700)
            }
        }
        .navigationTitle("LogLens")
        .navigationSubtitle(store.isCapturing ? "Capturing \(store.selectedSource.name)" : "Idle")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter events")
        .onChange(of: searchText) { _, new in store.updateFilter { $0.searchText = new } }
        .toolbar { CaptureToolbar(isExporting: $isExporting, exportFiltered: $exportFiltered) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.stopCapture() }
        .fileExporter(
            isPresented: $isExporting,
            document: ExportDocument(data: store.exportData(onlyFiltered: exportFiltered)),
            contentType: .json,
            defaultFilename: "LogLens-\(Formatters.fullMillis.string(from: Date()).prefix(19).replacingOccurrences(of: ":", with: "-"))"
        ) { _ in }
    }
}

// MARK: - Toolbar

struct CaptureToolbar: ToolbarContent {
    @Environment(EventStore.self) private var store
    @Binding var isExporting: Bool
    @Binding var exportFiltered: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            SourceMenu()
        }

        ToolbarItemGroup(placement: .principal) {
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

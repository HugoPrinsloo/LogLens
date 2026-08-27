import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class EventStore {

    // MARK: Data
    private(set) var entries: [LogEntry] = []
    private(set) var filtered: [LogEntry] = []
    private(set) var processCounts: [String: Int] = [:]
    private(set) var subsystemCounts: [String: Int] = [:]
    private(set) var categoryCounts: [String: Int] = [:]
    private(set) var starred: Set<Int> = []
    private(set) var totalReceived = 0
    private(set) var eventsPerSecond = 0

    // MARK: Filter
    private(set) var filter = LogFilter()

    // MARK: Capture
    var sources: [LogSource] = [.mac]
    var selectedSource: LogSource = .mac
    var scope: CaptureScope = .appsOnly { didSet { UserDefaults.standard.set(scope.rawValue, forKey: "scope") } }
    var customPredicate: String = "" { didSet { UserDefaults.standard.set(customPredicate, forKey: "customPredicate") } }
    var captureLevel: LogLevel = .debug { didSet { UserDefaults.standard.set(captureLevel.rawValue, forKey: "captureLevel") } }
    var maxEntries: Int = 100_000 { didSet { UserDefaults.standard.set(maxEntries, forKey: "maxEntries") } }
    private(set) var isCapturing = false
    private(set) var captureError: String?

    // MARK: UI
    var selection: LogEntry.ID? {
        didSet { if selection != nil { showInspector = true } }
    }
    var autoScroll = true
    var showInspector = true

    var selectedEntry: LogEntry? {
        guard let selection else { return nil }
        // Selected rows are almost always near the end; search backwards.
        if let e = filtered.last(where: { $0.id == selection }) { return e }
        return entries.last(where: { $0.id == selection })
    }

    private let streamer = LogStreamer()
    private var matcher: (LogEntry) -> Bool = { _ in true }
    private var rateWindow: [(Date, Int)] = []
    private var discoveryTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "scope"), let s = CaptureScope(rawValue: raw) { scope = s }
        customPredicate = d.string(forKey: "customPredicate") ?? ""
        if d.object(forKey: "captureLevel") != nil, let l = LogLevel(rawValue: d.integer(forKey: "captureLevel")) { captureLevel = l }
        if d.object(forKey: "maxEntries") != nil { maxEntries = max(1_000, d.integer(forKey: "maxEntries")) }

        streamer.onBatch = { [weak self] batch in self?.append(batch) }
        streamer.onTerminate = { [weak self] status, stderr, expected in
            guard let self else { return }
            isCapturing = false
            if !expected {
                captureError = stderr.isEmpty ? "log stream exited with status \(status)." : stderr
            }
        }
        refreshSources(selectBooted: true)
        startSourcePolling()
    }

    // MARK: - Sources

    func refreshSources(selectBooted: Bool = false) {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            let found = await SourceDiscovery.discover()
            guard let self, !Task.isCancelled else { return }
            sources = found
            if selectBooted, let booted = found.first(where: { $0.isSimulator && $0.isBooted }) {
                selectedSource = booted
            } else if let updated = found.first(where: { $0.id == selectedSource.id }) {
                selectedSource = updated
            }
            // `LogLens --record` starts capturing immediately (handy for scripting and dev).
            if selectBooted, !isCapturing, CommandLine.arguments.contains("--record") { startCapture() }
        }
    }

    private func startSourcePolling() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                if !isCapturing { refreshSources() }
            }
        }
    }

    // MARK: - Capture control

    func toggleCapture() { isCapturing ? stopCapture() : startCapture() }

    func dismissError() { captureError = nil }

    func startCapture() {
        captureError = nil
        guard selectedSource.isSupported else {
            captureError = "Physical devices aren't supported yet. Pick a simulator or This Mac."
            return
        }
        let config = LogStreamer.Configuration(source: selectedSource, scope: scope, customPredicate: customPredicate, level: captureLevel)
        do {
            try streamer.start(config)
            isCapturing = true
        } catch {
            captureError = error.localizedDescription
        }
    }

    func stopCapture() {
        streamer.stop()
        isCapturing = false
    }

    var commandPreview: String {
        let config = LogStreamer.Configuration(source: selectedSource, scope: scope, customPredicate: customPredicate, level: captureLevel)
        let cmd = LogStreamer.command(for: config)
        let quoted = cmd.args.map { $0.contains(" ") ? "'\($0)'" : $0 }
        return ([cmd.path] + quoted).joined(separator: " ")
    }

    // MARK: - Data mutation

    private func append(_ batch: [LogEntry]) {
        guard !batch.isEmpty else { return }
        totalReceived += batch.count
        entries.append(contentsOf: batch)
        for e in batch {
            processCounts[e.process, default: 0] += 1
            subsystemCounts[e.subsystem, default: 0] += 1
            categoryCounts[e.category, default: 0] += 1
        }
        let matches = batch.filter(matcher)
        if !matches.isEmpty { filtered.append(contentsOf: matches) }
        trimIfNeeded()
        updateRate(added: batch.count)
    }

    private func trimIfNeeded() {
        guard entries.count > maxEntries else { return }
        let overflow = entries.count - maxEntries
        let removed = entries.prefix(overflow)
        for e in removed {
            decrement(&processCounts, e.process)
            decrement(&subsystemCounts, e.subsystem)
            decrement(&categoryCounts, e.category)
            starred.remove(e.id)
        }
        entries.removeFirst(overflow)
        if let firstID = entries.first?.id {
            let drop = filtered.firstIndex { $0.id >= firstID } ?? filtered.count
            if drop > 0 { filtered.removeFirst(drop) }
        }
    }

    private func decrement(_ dict: inout [String: Int], _ key: String) {
        guard let v = dict[key] else { return }
        if v <= 1 { dict.removeValue(forKey: key) } else { dict[key] = v - 1 }
    }

    private func updateRate(added: Int) {
        let now = Date()
        rateWindow.append((now, added))
        rateWindow.removeAll { now.timeIntervalSince($0.0) > 1 }
        eventsPerSecond = rateWindow.reduce(0) { $0 + $1.1 }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        filtered.removeAll(keepingCapacity: true)
        processCounts.removeAll()
        subsystemCounts.removeAll()
        categoryCounts.removeAll()
        starred.removeAll()
        selection = nil
        rateWindow.removeAll()
        eventsPerSecond = 0
    }

    // MARK: - Filtering

    func updateFilter(_ change: (inout LogFilter) -> Void) {
        var f = filter
        change(&f)
        guard f != filter else { return }
        filter = f
        refilter()
    }

    func resetFilter() { updateFilter { $0 = LogFilter() } }

    func toggleFacet(_ facet: Facet, exclusive: Bool) {
        updateFilter { f in
            if exclusive {
                // Plain click: this facet alone within its kind (keeps other kinds).
                let sameKind = f.facets.filter { kind($0) == kind(facet) }
                if sameKind == [facet] { f.facets.subtract(sameKind) } else { f.facets.subtract(sameKind); f.facets.insert(facet) }
            } else if f.facets.contains(facet) {
                f.facets.remove(facet)
            } else {
                f.facets.insert(facet)
            }
        }
    }

    private func kind(_ facet: Facet) -> Int {
        switch facet { case .process: 0; case .subsystem: 1; case .category: 2 }
    }

    private func refilter() {
        matcher = filter.makeMatcher(starred: starred)
        filtered = filter.isActive ? entries.filter(matcher) : entries
    }

    // MARK: - Starring

    func toggleStar(_ id: LogEntry.ID) {
        if starred.contains(id) { starred.remove(id) } else { starred.insert(id) }
        if filter.onlyStarred { refilter() }
    }

    func isStarred(_ id: LogEntry.ID) -> Bool { starred.contains(id) }

    // MARK: - Export

    func exportData(onlyFiltered: Bool) -> Data {
        let list = onlyFiltered ? filtered : entries
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(list)) ?? Data()
    }
}

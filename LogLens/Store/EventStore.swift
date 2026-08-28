import Foundation
import Observation
import SwiftUI

enum EventViewMode: String, CaseIterable, Identifiable {
    case table, timeline, network
    var id: String { rawValue }
    var title: String {
        switch self { case .table: "List"; case .timeline: "Timeline"; case .network: "Network" }
    }
    var symbol: String {
        switch self { case .table: "list.bullet"; case .timeline: "rectangle.stack"; case .network: "network" }
    }
}

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

    let timeline = TimelineFeed()
    private(set) var lanes: [TimelineLane] = []
    static let maxLanes = 4

    var viewMode: EventViewMode = .table {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode")
            timeline.setActive(viewMode == .timeline && lanes.isEmpty, seed: filtered)
            for lane in lanes {
                lane.feed.setActive(viewMode == .timeline, seed: entries.filter(lane.matcher))
            }
        }
    }
    /// Timeline toolbar toggle: when on, clicking a card copies it as a PNG instead of expanding it. Not persisted.
    var copyCardOnClick = false
    /// Show proxied HTTP requests (from the Network tab) alongside log events in the table and timeline.
    var showNetworkEvents = true {
        didSet { UserDefaults.standard.set(showNetworkEvents, forKey: "showNetworkEvents"); refilter() }
    }
    var timelineExpandAll = false {
        didSet { UserDefaults.standard.set(timelineExpandAll, forKey: "timelineExpandAll") }
    }

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
        if let raw = d.string(forKey: "viewMode"), let m = EventViewMode(rawValue: raw) { viewMode = m }
        timelineExpandAll = d.bool(forKey: "timelineExpandAll")
        if d.object(forKey: "showNetworkEvents") != nil { showNetworkEvents = d.bool(forKey: "showNetworkEvents") }
        // `LogLens --network` opens straight into the network inspector (and NetworkStore auto-starts the proxy).
        if CommandLine.arguments.contains("--network") { viewMode = .network }
        // didSet doesn't fire during init.
        timeline.setActive(viewMode == .timeline, seed: [])

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
            // `LogLens --split` opens the timeline pre-split into two lanes.
            if selectBooted, CommandLine.arguments.contains("--split") { enableSplit() }
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

    /// Network proxy transactions join the same stream as log events (they carry `isNetwork`).
    func appendNetwork(_ tx: NetworkTransaction) {
        append([LogEntry.network(tx)])
    }

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
        if !matches.isEmpty {
            filtered.append(contentsOf: matches)
            timeline.ingest(matches)
        }
        for lane in lanes { lane.feed.ingest(batch.filter(lane.matcher)) }
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
        timeline.reset(seed: [])
        for lane in lanes { lane.feed.reset(seed: []) }
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

    /// The sidebar/search filter plus the "show network events" toggle.
    private func makeMatcher(_ f: LogFilter) -> (LogEntry) -> Bool {
        let base = f.makeMatcher(starred: starred)
        let showNetwork = showNetworkEvents
        return { e in (showNetwork || !e.isNetwork) && base(e) }
    }

    private func refilter() {
        matcher = makeMatcher(filter)
        filtered = filter.isActive ? entries.filter(matcher) : entries
        timeline.reset(seed: filtered)
        for lane in lanes {
            lane.matcher = laneMatcher(lane)
            lane.feed.reset(seed: entries.filter(lane.matcher))
        }
    }

    // MARK: - Timeline lanes

    /// Lanes keep the global search/level/star filter but swap in their own facets.
    private func laneMatcher(_ lane: TimelineLane) -> (LogEntry) -> Bool {
        var f = filter
        f.facets = lane.facets
        return makeMatcher(f)
    }

    /// Adds the facet to the lane at `index` (toggling it if already present),
    /// or creates a new lane when `index` is past the end.
    func assignFacet(_ facet: Facet, toLaneAt index: Int) {
        if index >= lanes.count {
            guard lanes.count < Self.maxLanes else { return }
            let lane = TimelineLane()
            lane.facets.insert(facet)
            lane.matcher = laneMatcher(lane)
            lanes.append(lane)
            if lanes.count == 1 { timeline.setActive(false, seed: []) }
        } else {
            let lane = lanes[index]
            if lane.facets.contains(facet) { lane.facets.remove(facet) } else { lane.facets.insert(facet) }
            lane.matcher = laneMatcher(lane)
        }
        if viewMode != .timeline {
            viewMode = .timeline   // didSet activates every lane feed
        } else {
            for lane in lanes {
                lane.feed.setActive(true, seed: entries.filter(lane.matcher))
            }
        }
    }

    func removeLane(_ lane: TimelineLane) {
        lane.feed.setActive(false, seed: [])
        lanes.removeAll { $0.id == lane.id }
        if lanes.isEmpty { timeline.setActive(viewMode == .timeline, seed: filtered) }
    }

    /// One-click split: lane 1 takes the current sidebar facet selection,
    /// lane 2 starts with everything. Facets are then adjusted per lane via
    /// the sidebar's "Timeline Lanes" context menu.
    func enableSplit() {
        guard lanes.isEmpty else { return }
        let first = TimelineLane()
        first.facets = filter.facets
        first.matcher = laneMatcher(first)
        let second = TimelineLane()
        second.matcher = laneMatcher(second)
        lanes = [first, second]
        timeline.setActive(false, seed: [])
        if viewMode != .timeline {
            viewMode = .timeline   // didSet activates every lane feed
        } else {
            for lane in lanes {
                lane.feed.setActive(true, seed: entries.filter(lane.matcher))
            }
        }
    }

    func disableSplit() {
        for lane in lanes { lane.feed.setActive(false, seed: []) }
        lanes = []
        timeline.setActive(viewMode == .timeline, seed: filtered)
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

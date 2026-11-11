import AppKit
import Foundation
import Observation
import SwiftUI

enum EventViewMode: String, CaseIterable, Identifiable {
    case table, timeline
    var id: String { rawValue }
    var title: String {
        switch self { case .table: "List"; case .timeline: "Timeline" }
    }
    var symbol: String {
        switch self { case .table: "list.bullet"; case .timeline: "rectangle.stack" }
    }
}

/// Sorted facet lists for the sidebar, published at most a few times a second (see `EventStore.facets`).
struct FacetSnapshot: Equatable {
    struct Count: Hashable, Identifiable {
        let key: String
        let count: Int
        var id: String { key }
    }
    var processes: [Count] = []
    var subsystems: [Count] = []
    var categories: [Count] = []
}

@MainActor
@Observable
final class EventStore {

    // MARK: Data
    private(set) var entries: [LogEntry] = [] {
        didSet { let e = !entries.isEmpty; if hasEntries != e { hasEntries = e } }
    }
    private(set) var filtered: [LogEntry] = [] {
        didSet { let f = !filtered.isEmpty; if hasFiltered != f { hasFiltered = f } }
    }
    /// Bumped whenever `filtered` is replaced or trimmed (anything other than appending at the end), so the table
    /// can tell "rows were appended" from "reload everything" without diffing.
    private(set) var filteredRevision = 0
    /// `entries`/`filtered` change on every batch; these only change when they flip, so views that just need to
    /// know "is there anything?" don't re-render 10×/s.
    private(set) var hasEntries = false
    private(set) var hasFiltered = false
    /// The filter that produced the current `filtered` (nil until the first pass lands). Narrowing while typing is
    /// only valid when `filtered` really reflects the previous filter, not an older one whose pass was still in flight.
    @ObservationIgnored private var appliedFilter: (filter: LogFilter, showNetwork: Bool)?
    private(set) var starred: Set<Int> = []
    private(set) var totalReceived = 0
    private(set) var eventsPerSecond = 0

    /// Live counts (mutated on every batch, not observed by the UI).
    @ObservationIgnored private var processCounts: [String: Int] = [:]
    @ObservationIgnored private var subsystemCounts: [String: Int] = [:]
    @ObservationIgnored private var categoryCounts: [String: Int] = [:]
    /// What the sidebar renders: re-sorted and published at ≤ 4 Hz, and only when something changed.
    private(set) var facets = FacetSnapshot()
    @ObservationIgnored private var facetsDirty = false
    @ObservationIgnored private var facetPublishScheduled = false

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
    /// The HTTP(S) proxy rides along with the log capture: one Record button starts and stops both.
    /// Wired in `LogLensApp.init`.
    var network: NetworkStore?

    // MARK: UI
    var selection: LogEntry.ID? {
        didSet {
            guard selection != oldValue else { return }
            selectedEntry = selection.flatMap(entry(id:))
            if selection != nil { showInspector = true }
        }
    }
    /// Resolved once per selection change (it used to be a computed scan of `filtered` on every batch).
    private(set) var selectedEntry: LogEntry?
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
                lane.feed.setActive(viewMode == .timeline, seed: lastMatches(in: entries, lane.matcher))
            }
        }
    }
    /// Timeline toolbar toggle: when on, clicking a card copies it as a PNG instead of expanding it. Not persisted.
    var copyCardOnClick = false
    /// Capture HTTP(S) requests through the proxy as part of the recording. Turning it off mid-capture stops the
    /// proxy and hides the requests already captured; turning it on starts the proxy right away.
    var captureNetwork = true {
        didSet {
            guard captureNetwork != oldValue else { return }
            UserDefaults.standard.set(captureNetwork, forKey: "captureNetwork")
            refilter()
            if isCapturing { captureNetwork ? startNetwork() : stopNetwork() }
        }
    }
    var timelineExpandAll = false {
        didSet { UserDefaults.standard.set(timelineExpandAll, forKey: "timelineExpandAll") }
    }

    private let streamer = LogStreamer()
    /// `--select-last` keeps the newest network row selected (dev/screenshot aid for the request inspector).
    private static let selectLastNetwork = CommandLine.arguments.contains("--select-last")
    @ObservationIgnored private var matcher: (LogEntry) -> Bool = { _ in true }
    @ObservationIgnored private var rateWindow: [(Date, Int)] = []
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// The launch-time discovery selects the booted simulator and honours `--record`; periodic refreshes wait for it.
    @ObservationIgnored private var initialDiscoveryDone = false
    /// Bumped per `refilter`; a background filter pass whose generation is stale is discarded.
    @ObservationIgnored private var filterGeneration = 0
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    /// True while a background pass is running (cleared when it lands or is superseded).
    @ObservationIgnored private var filterInFlight = false
    /// Finished proxy transactions arrive one at a time; they're coalesced like log batches (one append per ~16 ms).
    @ObservationIgnored private var pendingNetwork: [LogEntry] = []
    @ObservationIgnored private var networkFlushScheduled = false
    /// Above this many entries a filter change runs off the main actor.
    static let backgroundFilterThreshold = 20_000

    init() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "scope"), let s = CaptureScope(rawValue: raw) { scope = s }
        customPredicate = d.string(forKey: "customPredicate") ?? ""
        if d.object(forKey: "captureLevel") != nil, let l = LogLevel(rawValue: d.integer(forKey: "captureLevel")) { captureLevel = l }
        if d.object(forKey: "maxEntries") != nil { maxEntries = max(1_000, d.integer(forKey: "maxEntries")) }
        if let raw = d.string(forKey: "viewMode"), let m = EventViewMode(rawValue: raw) { viewMode = m }
        timelineExpandAll = d.bool(forKey: "timelineExpandAll")
        if d.object(forKey: "captureNetwork") != nil { captureNetwork = d.bool(forKey: "captureNetwork") }
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

    func refreshSources(selectBooted: Bool = false, includeDevices: Bool = true) {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            var found = await SourceDiscovery.discover(includeDevices: includeDevices)
            guard let self, !Task.isCancelled else { return }
            initialDiscoveryDone = true
            // A simulator-only refresh keeps the devices the full discovery found, so the menu doesn't flap.
            if !includeDevices { found += sources.filter { if case .physicalDevice = $0.kind { true } else { false } } }
            if found != sources { sources = found }
            if selectBooted, let booted = found.first(where: { $0.isSimulator && $0.isBooted }) {
                selectedSource = booted
            } else if let updated = found.first(where: { $0.id == self.selectedSource.id }), updated != selectedSource {
                selectedSource = updated
            }
            // `LogLens --record` starts capturing immediately (handy for scripting and dev).
            if selectBooted, !isCapturing, CommandLine.arguments.contains("--record") { startCapture() }
            // `LogLens --record-cycle` toggles Record/Stop every 5 s (soak test for the stop/start path).
            if selectBooted, CommandLine.arguments.contains("--record-cycle") {
                Task { [weak self] in
                    while let self {
                        try? await Task.sleep(for: .seconds(5))
                        toggleCapture()
                    }
                }
            }
            // `LogLens --split` opens the timeline pre-split into two lanes.
            if selectBooted, CommandLine.arguments.contains("--split") { enableSplit() }
        }
    }

    /// Simulator list refresh: only while LogLens is the active app and not recording, and without `devicectl`
    /// (physical devices aren't supported yet, and it's the expensive one). Idle in the background costs nothing.
    private func startSourcePolling() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.initialDiscoveryDone, !self.isCapturing else { return }
                self.refreshSources(includeDevices: false)
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if initialDiscoveryDone, !isCapturing, NSApp.isActive { refreshSources(includeDevices: false) }
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
            return
        }
        if captureNetwork { startNetwork() }
    }

    func stopCapture() {
        streamer.stop()
        isCapturing = false
        stopNetwork()
    }

    private func startNetwork() {
        guard let network else { return }
        Task { await network.start() }
    }

    private func stopNetwork() {
        guard let network else { return }
        Task { await network.stopCapture() }
    }

    var commandPreview: String {
        let config = LogStreamer.Configuration(source: selectedSource, scope: scope, customPredicate: customPredicate, level: captureLevel)
        let cmd = LogStreamer.command(for: config)
        let quoted = cmd.args.map { $0.contains(" ") ? "'\($0)'" : $0 }
        return ([cmd.path] + quoted).joined(separator: " ")
    }

    // MARK: - Lookup

    /// Selected rows are almost always near the end; search backwards.
    func entry(id: LogEntry.ID) -> LogEntry? {
        if let e = filtered.last(where: { $0.id == id }) { return e }
        return entries.last(where: { $0.id == id })
    }

    // MARK: - Data mutation

    /// Network proxy transactions join the same stream as log events (they carry `isNetwork`).
    /// The entry is built off the main thread by the proxy (body decode + pretty-print are not cheap).
    func appendNetwork(_ entry: LogEntry) {
        pendingNetwork.append(entry)
        guard !networkFlushScheduled else { return }
        networkFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self else { return }
            networkFlushScheduled = false
            let batch = pendingNetwork
            pendingNetwork.removeAll(keepingCapacity: true)
            append(batch)
        }
    }

    private func append(_ batch: [LogEntry]) {
        guard !batch.isEmpty else { return }
        Perf.measure("store.append") {
            totalReceived += batch.count
            entries.append(contentsOf: batch)
            for e in batch {
                processCounts[e.process, default: 0] += 1
                subsystemCounts[e.subsystem, default: 0] += 1
                categoryCounts[e.category, default: 0] += 1
            }
            markFacetsDirty()
            let matches = batch.filter(matcher)
            if !matches.isEmpty {
                filtered.append(contentsOf: matches)
                timeline.ingest(matches)
            }
            for lane in lanes {
                let laneMatches = batch.filter(lane.matcher)
                if !laneMatches.isEmpty { lane.feed.ingest(laneMatches) }
            }
            if Self.selectLastNetwork, let last = batch.last(where: { $0.isNetwork && $0.network?.isTunnel == false }) { selection = last.id }
            trimIfNeeded()
            updateRate(added: batch.count)
        }
    }

    /// Trim with hysteresis: shifting a 100 k array is ~ms on the main thread, so do it once per ~10 % of the
    /// buffer rather than on every batch once the buffer is full.
    private func trimIfNeeded() {
        guard entries.count > maxEntries else { return }
        Perf.measure("store.trim") {
            let slack = max(500, maxEntries / 10)
            let overflow = entries.count - (maxEntries - slack)
            var removedIDs = Set<Int>(minimumCapacity: overflow)
            for e in entries.prefix(overflow) {
                decrement(&processCounts, e.process)
                decrement(&subsystemCounts, e.subsystem)
                decrement(&categoryCounts, e.category)
                starred.remove(e.id)
                removedIDs.insert(e.id)
            }
            entries.removeFirst(overflow)
            // `filtered` is a subsequence of `entries`, so what was removed is a prefix of it too.
            // (Match by id: network entries carry ids from their own range, so ids aren't monotonic.)
            let drop = filtered.prefix { removedIDs.contains($0.id) }.count
            if drop > 0 {
                filtered.removeFirst(drop)
                filteredRevision += 1
            }
            if let sel = selection, removedIDs.contains(sel) { selection = nil }
            markFacetsDirty()
            // A background filter pass splices in `entries[snapshotCount...]` when it lands; the trim just shifted
            // those indices, so restart it (trims happen once per ~10 % of the buffer, so this is rare).
            if filterInFlight { refilter() }
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
        let rate = rateWindow.reduce(0) { $0 + $1.1 }
        if rate != eventsPerSecond { eventsPerSecond = rate }
    }

    // MARK: - Facets (sidebar)

    private func markFacetsDirty() {
        facetsDirty = true
        if facets.processes.isEmpty && facets.subsystems.isEmpty && facets.categories.isEmpty {
            publishFacets()   // first events: show the sidebar right away
            return
        }
        guard !facetPublishScheduled else { return }
        facetPublishScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            facetPublishScheduled = false
            publishFacets()
        }
    }

    private func publishFacets() {
        guard facetsDirty else { return }
        facetsDirty = false
        Perf.measure("store.facets") {
            let snapshot = FacetSnapshot(
                processes: Self.sorted(processCounts),
                subsystems: Self.sorted(subsystemCounts),
                categories: Self.sorted(categoryCounts)
            )
            if snapshot != facets { facets = snapshot }
        }
    }

    private static func sorted(_ counts: [String: Int]) -> [FacetSnapshot.Count] {
        counts.map { FacetSnapshot.Count(key: $0.key, count: $0.value) }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.key < $1.key
        }
    }

    func clear() {
        filterTask?.cancel()
        filterInFlight = false
        filterGeneration += 1
        entries.removeAll(keepingCapacity: true)
        filtered.removeAll(keepingCapacity: true)
        filteredRevision += 1
        appliedFilter = (filter, captureNetwork)
        processCounts.removeAll()
        subsystemCounts.removeAll()
        categoryCounts.removeAll()
        facetsDirty = true
        publishFacets()
        starred.removeAll()
        selection = nil
        rateWindow.removeAll()
        eventsPerSecond = 0
        timeline.reset(seed: [])
        for lane in lanes { lane.feed.reset(seed: []) }
        network?.clear()
    }

    // MARK: - Filtering

    func updateFilter(_ change: (inout LogFilter) -> Void) {
        var f = filter
        change(&f)
        guard f != filter else { return }
        let old = filter
        filter = f
        refilter(previous: old)
    }

    func resetFilter() { updateFilter { $0 = LogFilter() } }

    /// Plain click: toggle the facet in or out of the selection (checkbox semantics).
    /// `exclusive` ("Only this"): this facet alone within its kind, keeping the other kinds.
    func toggleFacet(_ facet: Facet, exclusive: Bool = false) {
        updateFilter { f in
            if exclusive {
                let sameKind = f.facets.filter { kind($0) == kind(facet) }
                f.facets.subtract(sameKind)
                f.facets.insert(facet)
            } else if f.facets.contains(facet) {
                f.facets.remove(facet)
            } else {
                f.facets.insert(facet)
            }
        }
    }

    /// Clears every selected facet of the given kind (e.g. all selected categories).
    func clearFacets(ofKind sample: Facet) {
        updateFilter { f in f.facets = f.facets.filter { kind($0) != kind(sample) } }
    }

    private func kind(_ facet: Facet) -> Int {
        switch facet { case .process: 0; case .subsystem: 1; case .category: 2 }
    }

    /// The sidebar/search filter plus the "capture network" toggle (off hides requests already captured).
    private func makeMatcher(_ f: LogFilter) -> (LogEntry) -> Bool {
        let base = f.makeMatcher(starred: starred)
        let showNetwork = captureNetwork
        return { e in (showNetwork || !e.isNetwork) && base(e) }
    }

    /// The last `n` entries matching `m`, scanning backwards (the timeline only ever shows the newest cap).
    nonisolated private static func lastMatches(_ n: Int = TimelineFeed.maxVisible, in source: [LogEntry], _ m: (LogEntry) -> Bool) -> [LogEntry] {
        var out: [LogEntry] = []
        out.reserveCapacity(n)
        for e in source.reversed() where m(e) {
            out.append(e)
            if out.count == n { break }
        }
        return out.reversed()
    }

    private func lastMatches(in source: [LogEntry], _ m: (LogEntry) -> Bool) -> [LogEntry] {
        Self.lastMatches(in: source, m)
    }

    /// Rebuilds `filtered` and every timeline feed for the current filter.
    ///
    /// Small buffers filter synchronously. Large ones run the pass off the main actor: new batches keep landing
    /// (matched with the new matcher, appended to the stale `filtered`) and the finished result replaces
    /// `filtered` plus whatever arrived meanwhile. Typing one more character into a non-empty search narrows the
    /// previous result instead of rescanning everything.
    private func refilter(previous: LogFilter? = nil) {
        filterTask?.cancel()
        filterInFlight = false
        filterGeneration += 1
        let generation = filterGeneration
        matcher = makeMatcher(filter)
        for lane in lanes { lane.matcher = laneMatcher(lane) }
        let target = (filter: filter, showNetwork: captureNetwork)

        // Fast paths.
        if !filter.isActive && captureNetwork {
            filtered = entries
            filteredRevision += 1
            appliedFilter = target
            reseedFeeds()
            return
        }
        // Typing one more character: narrow the current result — but only if it really is the previous filter's.
        let narrowing: Bool = {
            guard let a = appliedFilter, a.showNetwork == captureNetwork, !a.filter.searchText.isEmpty,
                  filter.searchText.hasPrefix(a.filter.searchText) else { return false }
            var q = filter; q.searchText = a.filter.searchText
            return q == a.filter
        }()
        let source = narrowing ? filtered : entries
        if source.count <= Self.backgroundFilterThreshold {
            Perf.measure("store.refilter.sync") {
                filtered = source.filter(matcher)
                filteredRevision += 1
                appliedFilter = target
                reseedFeeds()
            }
            return
        }
        filterInFlight = true

        let snapshotCount = entries.count
        let m = matcher
        let laneMatchers = lanes.map(\.matcher)
        let laneCap = TimelineFeed.maxVisible
        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Perf.measure("store.refilter.background") { () -> ([LogEntry], [[LogEntry]]) in
                let f = source.filter(m)
                let seeds = laneMatchers.map { Self.lastMatches(laneCap, in: source, $0) }
                return (f, seeds)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == self.filterGeneration else { return }
                filterInFlight = false
                filterTask = nil
                // Entries that arrived while we were filtering.
                let tail = entries.count > snapshotCount ? Array(entries[snapshotCount...]) : []
                filtered = result.0 + tail.filter(m)
                filteredRevision += 1
                appliedFilter = target
                timeline.reset(seed: filtered)
                for (lane, seed) in zip(lanes, result.1) {
                    lane.feed.reset(seed: seed + tail.filter(lane.matcher))
                }
            }
        }
    }

    private func reseedFeeds() {
        timeline.reset(seed: filtered)
        for lane in lanes { lane.feed.reset(seed: lastMatches(in: entries, lane.matcher)) }
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
                lane.feed.setActive(true, seed: lastMatches(in: entries, lane.matcher))
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
                lane.feed.setActive(true, seed: lastMatches(in: entries, lane.matcher))
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

    /// Encodes off the main actor; 100 k pretty-printed entries take seconds.
    func exportData(onlyFiltered: Bool) async -> Data {
        let list = onlyFiltered ? filtered : entries
        return await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return (try? encoder.encode(list)) ?? Data()
        }.value
    }
}

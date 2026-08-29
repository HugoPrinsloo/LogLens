import Foundation
import Observation
import SwiftUI

/// Feeds incoming entries into the timeline.
///
/// `EventStore` feeds it explicitly (`ingest`/`reset`). Everything queued is revealed together as one spring
/// (one animation per incoming batch, coalesced to ~10 reveals/s), so events appear as soon as they arrive and
/// nothing is ever dropped — only cards that would already be past the visible cap are skipped.
@MainActor
@Observable
final class TimelineFeed {

    struct TimelineItem: Identifiable, Equatable {
        let entry: LogEntry
        let eventType: String?
        let eid: String?
        var id: Int { entry.id }

        init(_ entry: LogEntry) {
            self.entry = entry
            self.eventType = entry.parsed.eventType
            self.eid = entry.parsed.eid
        }

        static func == (l: Self, r: Self) -> Bool { l.entry.id == r.entry.id }
    }

    /// Oldest → newest; newest renders at the bottom of the stack.
    private(set) var visible: [TimelineItem] = []
    /// Queued but not yet revealed (only non-zero for the few ms between a batch landing and its reveal).
    private(set) var backlog = 0
    /// Skipped because more than `maxVisible` arrived in one go; reset once the feed is idle.
    private(set) var skipped = 0

    var pendingCount: Int { backlog + skipped }

    nonisolated static let maxVisible = 200
    /// Trim the head in chunks so the stack isn't re-laid-out on every reveal once it's full.
    static let trimSlack = 20
    /// Minimum spacing between reveals; batches that land inside the window merge into the next spring.
    static let revealInterval: Duration = .milliseconds(100)
    /// Groups larger than this land without the spring: nobody can follow 20 cards sliding in at once, and the
    /// animation would keep the whole stack re-laying-out for 350 ms per reveal under a flood.
    static let maxAnimatedGroup = 10

    private var queue: [LogEntry] = []
    private var drainTask: Task<Void, Never>?
    private var active = false

    func setActive(_ on: Bool, seed: [LogEntry]) {
        active = on
        drainTask?.cancel()
        drainTask = nil
        queue.removeAll()
        setBacklog(0)
        if skipped != 0 { skipped = 0 }
        visible = on ? seed.suffix(Self.maxVisible).map(TimelineItem.init) : []
    }

    /// Filter change or clear: re-seed instantly, no animation storm.
    func reset(seed: [LogEntry]) {
        guard active else { return }
        setActive(true, seed: seed)
    }

    func ingest(_ batch: [LogEntry]) {
        guard active, !batch.isEmpty else { return }
        queue.append(contentsOf: batch)
        setBacklog(queue.count)
        startDrainIfNeeded()
    }

    private func setBacklog(_ n: Int) {
        // Observation fires on every assignment; only assign when the value changes.
        if backlog != n { backlog = n }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            defer { self?.drainTask = nil }
            while let self, self.active, !self.queue.isEmpty, !Task.isCancelled {
                self.revealAll()
                try? await Task.sleep(for: Self.revealInterval)
            }
            if let self, self.queue.isEmpty, self.skipped != 0 { self.skipped = 0 }
        }
    }

    private func revealAll() {
        Perf.measure("timeline.reveal") {
            if queue.count > Self.maxVisible {
                // Cards beyond the visible cap would be trimmed straight away; don't build views for them.
                skipped += queue.count - Self.maxVisible
                queue.removeFirst(queue.count - Self.maxVisible)
            }
            let items = queue.map(TimelineItem.init)
            queue.removeAll(keepingCapacity: true)
            setBacklog(0)
            if items.count <= Self.maxAnimatedGroup {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    visible.append(contentsOf: items)
                }
            } else {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { visible.append(contentsOf: items) }
            }
            if visible.count > Self.maxVisible + Self.trimSlack {
                // Trimmed rows are far off-screen; animating their removal would jank the stack.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { visible.removeFirst(visible.count - Self.maxVisible) }
            }
        }
    }
}

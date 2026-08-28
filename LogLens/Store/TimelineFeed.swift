import Foundation
import Observation
import SwiftUI

/// Paces incoming entries into the timeline at a readable cadence.
///
/// `EventStore` feeds it explicitly (`ingest`/`reset`); it releases entries into
/// `visible` one spring animation at a time, tightening the interval as backlog
/// grows and skipping ahead when the stream outruns what a human can watch.
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
            self.eventType = entry.parsed.derivedEventType
            self.eid = entry.parsed.derivedEID
        }

        static func == (l: Self, r: Self) -> Bool { l.entry.id == r.entry.id }
    }

    /// Oldest → newest; newest renders at the bottom of the stack.
    private(set) var visible: [TimelineItem] = []
    /// Queued but not yet revealed.
    private(set) var backlog = 0
    /// Dropped by skip-ahead since the feed last caught up.
    private(set) var skipped = 0

    var pendingCount: Int { backlog + skipped }

    static let maxVisible = 200
    static let maxQueue = 60

    private var queue: [LogEntry] = []
    private var drainTask: Task<Void, Never>?
    private var active = false

    func setActive(_ on: Bool, seed: [LogEntry]) {
        active = on
        drainTask?.cancel()
        drainTask = nil
        queue.removeAll()
        backlog = 0
        skipped = 0
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
        if queue.count > Self.maxQueue {
            skipped += queue.count - Self.maxQueue
            queue.removeFirst(queue.count - Self.maxQueue)
        }
        backlog = queue.count
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            defer { self?.drainTask = nil }
            while let self, self.active, !self.queue.isEmpty, !Task.isCancelled {
                self.revealNext()
                try? await Task.sleep(for: self.interval)
            }
            if let self, self.queue.isEmpty { self.skipped = 0 }
        }
    }

    /// Readable when calm, faster as backlog grows: 350 ms → 80 ms.
    private var interval: Duration {
        .milliseconds(max(80, 350 - backlog * 6))
    }

    private func revealNext() {
        // Under heavy backlog reveal small groups so one animation covers several cards.
        let n = backlog > 30 ? 3 : 1
        let items = queue.prefix(n).map(TimelineItem.init)
        queue.removeFirst(min(n, queue.count))
        backlog = queue.count
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            visible.append(contentsOf: items)
        }
        if visible.count > Self.maxVisible {
            // Trimmed rows are far off-screen; animating their removal would jank the stack.
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { visible.removeFirst(visible.count - Self.maxVisible) }
        }
    }
}

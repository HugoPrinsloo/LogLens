import Foundation
import Observation

/// One column in the split timeline: a facet selection with its own paced feed.
@MainActor
@Observable
final class TimelineLane: Identifiable {
    let id = UUID()
    var facets: Set<Facet> = []
    let feed = TimelineFeed()
    /// Rebuilt by EventStore whenever the global filter or the lane's facets change.
    @ObservationIgnored var matcher: (LogEntry) -> Bool = { _ in true }

    var title: String {
        facets.isEmpty ? "All events" : facets.map(\.displayName).sorted().joined(separator: " + ")
    }
}

extension Facet {
    var displayName: String {
        switch self {
        case .process(let s), .subsystem(let s), .category(let s):
            return s.isEmpty ? "(none)" : s
        }
    }
}

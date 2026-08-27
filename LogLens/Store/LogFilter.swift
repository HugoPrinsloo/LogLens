import Foundation

/// A facet the sidebar can filter on.
enum Facet: Hashable, Codable {
    case process(String)
    case subsystem(String)
    case category(String)

    var value: String {
        switch self {
        case let .process(v), let .subsystem(v), let .category(v): v
        }
    }
}

struct LogFilter: Equatable {
    var searchText = ""
    var levels: Set<LogLevel> = Set(LogLevel.allCases)
    var facets: Set<Facet> = []
    var onlyStarred = false

    var isActive: Bool {
        !searchText.isEmpty || levels.count != LogLevel.allCases.count || !facets.isEmpty || onlyStarred
    }

    private var processes: Set<String> { Set(facets.compactMap { if case let .process(v) = $0 { v } else { nil } }) }
    private var subsystems: Set<String> { Set(facets.compactMap { if case let .subsystem(v) = $0 { v } else { nil } }) }
    private var categories: Set<String> { Set(facets.compactMap { if case let .category(v) = $0 { v } else { nil } }) }

    /// Pre-computed matcher; build once per filter change, apply to many entries.
    func makeMatcher(starred: Set<Int>) -> (LogEntry) -> Bool {
        let terms = searchText.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let levels = self.levels
        let processes = self.processes, subsystems = self.subsystems, categories = self.categories
        let onlyStarred = self.onlyStarred
        let allLevels = levels.count == LogLevel.allCases.count
        return { e in
            if !allLevels && !levels.contains(e.level) { return false }
            if onlyStarred && !starred.contains(e.id) { return false }
            if !processes.isEmpty && !processes.contains(e.process) { return false }
            if !subsystems.isEmpty && !subsystems.contains(e.subsystem) { return false }
            if !categories.isEmpty && !categories.contains(e.category) { return false }
            if !terms.isEmpty {
                let hay = e.searchText
                for t in terms where !hay.contains(t) { return false }
            }
            return true
        }
    }
}

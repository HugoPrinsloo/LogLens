import Foundation

struct LogEntry: Identifiable, Hashable, Codable {
    let id: Int
    let timestamp: Date
    let level: LogLevel
    let process: String
    let processPath: String
    let processID: Int
    let threadID: Int
    let sender: String
    let subsystem: String
    let category: String
    let message: String
    let activityID: Int?
    let traceID: UInt64?
    let sourceName: String
    let parsed: ParsedMessage

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var subsystemDisplay: String { subsystem.isEmpty ? "—" : subsystem }
    var categoryDisplay: String { category.isEmpty ? "—" : category }

    /// Lower-cased haystack used by text search.
    var searchText: String {
        (parsed.title + "\n" + message + "\n" + process + "\n" + subsystem + "\n" + category).lowercased()
    }
}

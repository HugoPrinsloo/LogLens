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
    /// True for HTTP transactions captured by the network proxy (see `LogEntry.network(_:)`).
    var isNetwork: Bool = false
    /// Rendering data for network cards (bodies, status); nil for log events.
    var network: NetworkCardData? = nil
    /// Lower-cased haystack for text search. Built once, off the main thread, so a keystroke never lowercases
    /// 100 k messages (or a 64 KB network body) on the main actor.
    var searchKey: String = ""
    /// "HH:mm:ss.SSS", pre-rendered so table cells and cards never call a DateFormatter.
    var timeText: String = ""

    // Derived render/search fields stay out of exports and "Copy as JSON".
    enum CodingKeys: String, CodingKey {
        case id, timestamp, level, process, processPath, processID, threadID, sender, subsystem, category
        case message, activityID, traceID, sourceName, parsed, isNetwork, network
    }

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var subsystemDisplay: String { subsystem.isEmpty ? "—" : subsystem }
    var categoryDisplay: String { category.isEmpty ? "—" : category }

    /// The lower-cased haystack used by text search: title, message, process, subsystem, category (+ extras such as
    /// decoded network bodies).
    static func makeSearchKey(title: String, message: String, process: String, subsystem: String, category: String, extra: [String] = []) -> String {
        var s = title
        s.reserveCapacity(title.utf8.count + message.utf8.count + process.utf8.count + subsystem.utf8.count + category.utf8.count + 8)
        s += "\n"; s += message
        s += "\n"; s += process
        s += "\n"; s += subsystem
        s += "\n"; s += category
        for e in extra { s += "\n"; s += e }
        return s.lowercased()
    }
}

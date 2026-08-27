import Foundation

/// A structured view of a log message. Produced by `MessageParser`.
struct ParsedMessage: Hashable, Codable {
    struct Field: Hashable, Codable, Identifiable {
        let id: Int
        let key: String
        let value: String
    }

    struct Group: Hashable, Codable, Identifiable {
        let id: Int
        let name: String
        /// Type name when the group came from a Swift description like `PageViewInfo(...)`.
        let typeName: String?
        let fields: [Field]
    }

    /// Best-effort headline for the message (event identifier, first line, …).
    var title: String
    /// Short one-line summary of the most interesting fields, for the table.
    var summary: String
    /// Top-level `Key: Value` pairs.
    var fields: [Field]
    /// Nested blocks: `Header:` followed by `- key: value` lines, or `Key: Type(a: 1, b: 2)`.
    var groups: [Group]
    /// Lines that weren't key/value pairs.
    var freeText: [String]

    var isStructured: Bool { !fields.isEmpty || !groups.isEmpty }
}

import Foundation

/// Turns a free-form log message into a `ParsedMessage`.
///
/// Understands three common shapes that appear in the wild:
///
///     Event Identifier: app.checkout.button.click                    ← `Key: Value`
///     Action: click ["source": "editor"]                            ← trailing dictionary literal
///
///     Screen Viewed                                                 ← free line becomes the title
///     Property:                                                     ← header
///     - screen: Home                                                ← nested `- key: value`
///
///     Properties: PageViewInfo(pageName: "Home", count: 3)          ← Swift description
enum MessageParser {

    private static let titleKeys: Set<String> = [
        "event identifier", "eventidentifier", "event_identifier", "event id", "eventid",
        "event", "event name", "eventname", "event_name", "eid", "name", "title", "id"
    ]

    static func parse(_ message: String) -> ParsedMessage {
        var fields: [ParsedMessage.Field] = []
        var groups: [ParsedMessage.Group] = []
        var free: [String] = []
        var open: (name: String, typeName: String?, fields: [ParsedMessage.Field])?
        var nextID = 0
        func makeID() -> Int { defer { nextID += 1 }; return nextID }

        func closeGroup() {
            if let g = open {
                groups.append(.init(id: makeID(), name: g.name, typeName: g.typeName, fields: g.fields))
                open = nil
            }
        }

        for rawLine in message.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Nested list item: "- key: value" or "• key: value"
            if let item = listItem(line) {
                if open == nil { open = ("Items", nil, []) }
                if let kv = splitKeyValue(item) {
                    open?.fields.append(.init(id: makeID(), key: kv.key, value: kv.value))
                } else {
                    open?.fields.append(.init(id: makeID(), key: "", value: item))
                }
                continue
            }

            closeGroup()

            guard let kv = splitKeyValue(line) else {
                free.append(line)
                continue
            }

            if kv.value.isEmpty {
                // "Property:" header for a following list
                open = (kv.key, nil, [])
            } else if let structured = SwiftDescriptionParser.parse(kv.value) {
                var gFields: [ParsedMessage.Field] = []
                for pair in structured.pairs { gFields.append(.init(id: makeID(), key: pair.key, value: pair.value)) }
                groups.append(.init(id: makeID(), name: kv.key, typeName: structured.typeName, fields: gFields))
            } else if let (head, dict) = SwiftDescriptionParser.trailingDictionary(kv.value) {
                fields.append(.init(id: makeID(), key: kv.key, value: head))
                var gFields: [ParsedMessage.Field] = []
                for pair in dict { gFields.append(.init(id: makeID(), key: pair.key, value: pair.value)) }
                groups.append(.init(id: makeID(), name: "\(kv.key) traits", typeName: nil, fields: gFields))
            } else {
                fields.append(.init(id: makeID(), key: kv.key, value: kv.value))
            }
        }
        closeGroup()

        let title = deriveTitle(fields: fields, free: free, message: message)
        let summary = deriveSummary(fields: fields, groups: groups, title: title)
        return ParsedMessage(title: title, summary: summary, fields: fields, groups: groups, freeText: free)
    }

    // MARK: - Helpers

    private static func listItem(_ line: String) -> String? {
        for prefix in ["- ", "• ", "* "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Splits "Key: Value" (or "Key:") into parts, rejecting things that only look like pairs (URLs, timestamps, prose).
    static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = line[line.index(after: colon)...]

        // "Key:" alone is a header. Otherwise require a space after the colon so "http://x" and "12:30" don't match.
        if !rest.isEmpty && !rest.hasPrefix(" ") { return nil }

        guard !key.isEmpty, key.count <= 48 else { return nil }
        // Keys are identifier-ish: letters, digits, spaces, dots, underscores, dashes. No sentences.
        guard key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ._-/".unicodeScalars.contains($0) }) else { return nil }
        guard key.split(separator: " ").count <= 4 else { return nil }
        guard key.first?.isNumber == false else { return nil }

        return (key, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func deriveTitle(fields: [ParsedMessage.Field], free: [String], message: String) -> String {
        for key in ["event identifier", "eid", "event", "event name", "name"] {
            if let f = fields.first(where: { $0.key.lowercased() == key }) { return f.value }
        }
        if let f = fields.first(where: { titleKeys.contains($0.key.lowercased()) }) { return f.value }
        if let first = free.first { return first }
        if let first = message.split(whereSeparator: \.isNewline).first {
            return String(first).trimmingCharacters(in: .whitespaces)
        }
        return message
    }

    private static func deriveSummary(fields: [ParsedMessage.Field], groups: [ParsedMessage.Group], title: String) -> String {
        var parts: [String] = []
        for f in fields where f.value != title && !f.value.isEmpty && "\(f.key): \(f.value)" != title {
            parts.append("\(f.key): \(f.value)")
            if parts.count == 3 { break }
        }
        if parts.isEmpty, let g = groups.first {
            for f in g.fields.prefix(3) { parts.append(f.key.isEmpty ? f.value : "\(f.key): \(f.value)") }
        }
        return parts.joined(separator: "   ·   ")
    }
}

/// Parses Swift `description` output such as `PageViewInfo(pageName: "Home", count: 3)`
/// and dictionary literals such as `["source": "editor", "count": 3]`.
enum SwiftDescriptionParser {

    struct Structured {
        let typeName: String?
        let pairs: [(key: String, value: String)]
    }

    static func parse(_ text: String) -> Structured? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Type(...)
        if let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
            let name = String(trimmed[..<open])
            guard isTypeName(name) else { return nil }
            let inner = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            guard let pairs = keyedPairs(inner), !pairs.isEmpty else { return nil }
            return Structured(typeName: name, pairs: pairs)
        }
        // ["k": v, ...]
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.contains("\":") || trimmed.contains("\" :") {
            let inner = String(trimmed.dropFirst().dropLast())
            guard let pairs = keyedPairs(inner), !pairs.isEmpty else { return nil }
            return Structured(typeName: nil, pairs: pairs)
        }
        return nil
    }

    /// `click ["source": "editor"]` → ("click", [source: editor])
    static func trailingDictionary(_ text: String) -> (String, [(key: String, value: String)])? {
        guard text.hasSuffix("]"), let start = text.range(of: " [")?.lowerBound else { return nil }
        let head = String(text[..<start]).trimmingCharacters(in: .whitespaces)
        let dict = String(text[start...]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, let s = parse(dict), s.typeName == nil else { return nil }
        return (head, s.pairs)
    }

    private static func isTypeName(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    private static func keyedPairs(_ inner: String) -> [(key: String, value: String)]? {
        let parts = splitTopLevel(inner)
        var result: [(String, String)] = []
        for part in parts {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            guard let colon = findTopLevelColon(p) else { return nil }
            var key = p[..<colon].trimmingCharacters(in: .whitespaces)
            let value = p[p.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 { key = String(key.dropFirst().dropLast()) }
            guard !key.isEmpty else { return nil }
            result.append((key, unquote(value)))
        }
        return result
    }

    private static func unquote(_ v: String) -> String {
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { return String(v.dropFirst().dropLast()) }
        if v.hasPrefix("Optional("), v.hasSuffix(")") { return unquote(String(v.dropFirst(9).dropLast())) }
        return v
    }

    /// Splits on commas that are not inside (), [], {} or string literals.
    private static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escaped = false
        for ch in s {
            if inString {
                current.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true; current.append(ch)
            case "(", "[", "{": depth += 1; current.append(ch)
            case ")", "]", "}": depth -= 1; current.append(ch)
            case "," where depth == 0: parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    private static func findTopLevelColon(_ s: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "(", "[", "{": depth += 1
                case ")", "]", "}": depth -= 1
                case ":" where depth == 0: return i
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

import SwiftUI

/// Derives analytics-style semantics (event type, EID) from a parsed message.
/// Nothing in the log format guarantees these exist, so both are best-effort.
extension ParsedMessage {

    private static let typeKeys = ["event type", "eventtype", "event_type", "type", "action", "kind"]
    private static let eidKeys = [
        "eid", "event identifier", "eventidentifier", "event_identifier",
        "event id", "eventid", "event"
    ]

    static let knownVerbs: Set<String> = [
        "impression", "click", "tap", "view", "viewed", "screen", "swipe", "scroll",
        "submit", "select", "open", "close", "load", "start", "stop",
        "success", "failure", "error", "dismiss", "appear", "disappear"
    ]

    /// "impression", "click", … from a typed field, or the last segment of a
    /// dotted title like `cart.checkout_button.click`. `nil` when nothing fits;
    /// callers fall back to the log level.
    var derivedEventType: String? {
        for key in Self.typeKeys {
            if let f = fields.first(where: { $0.key.lowercased() == key }), !f.value.isEmpty {
                return f.value.lowercased()
            }
        }
        if !title.contains(" "), title.contains("."),
           let last = title.split(separator: ".").last.map({ String($0).lowercased() }),
           Self.knownVerbs.contains(last) {
            return last
        }
        return nil
    }

    /// An explicit EID field, or a title that looks like a dotted event identifier.
    var derivedEID: String? {
        for key in Self.eidKeys {
            if let f = fields.first(where: { $0.key.lowercased() == key }), !f.value.isEmpty {
                return f.value
            }
        }
        if !title.contains(" "), title.contains("."), title.count <= 120 { return title }
        return nil
    }
}

enum EventTypeStyle {

    private static let fixed: [String: Color] = [
        "impression": .blue,
        "click": .green, "tap": .green, "select": .green,
        "view": .orange, "viewed": .orange, "screen": .orange,
        "submit": .purple, "open": .teal, "close": .teal,
        "success": .mint, "failure": .red, "error": .red,
    ]

    private static let palette: [Color] = [.orange, .red, .purple, .teal, .yellow, .pink, .indigo, .mint]

    static func color(for type: String) -> Color {
        if let c = fixed[type] { return c }
        // FNV-1a: String.hashValue is seeded per launch, which would reshuffle colors.
        var h: UInt64 = 0xcbf29ce484222325
        for b in type.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return palette[Int(h % UInt64(palette.count))]
    }

    private static let symbols: [String: String] = [
        "impression": "eye.fill", "view": "rectangle.inset.filled", "viewed": "rectangle.inset.filled",
        "screen": "rectangle.inset.filled",
        "click": "cursorarrow.rays", "tap": "hand.tap.fill", "select": "cursorarrow.rays",
        "submit": "paperplane.fill", "open": "arrow.up.right.square.fill", "close": "xmark.square.fill",
        "success": "checkmark.circle.fill", "failure": "exclamationmark.triangle.fill",
        "error": "exclamationmark.triangle.fill",
    ]

    static func symbol(for type: String) -> String {
        symbols[type] ?? "sparkle"
    }
}

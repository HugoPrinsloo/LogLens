import SwiftUI

/// Monospaced code box with light JSON syntax colouring. Non-JSON text renders plain.
struct JSONText: View {
    let text: String
    var lineCap: Int = 40
    @State private var showAll = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let capped = !showAll && lines.count > lineCap
        let shown = capped ? lines.prefix(lineCap).joined(separator: "\n") : text
        VStack(alignment: .leading, spacing: 6) {
            Text(JSONHighlighter.attributed(shown))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if capped {
                Button("Show all \(lines.count) lines") { showAll = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator))
    }
}

enum JSONHighlighter {
    private static let key = Color(red: 0.42, green: 0.66, blue: 1.0)      // soft blue
    private static let string = Color(red: 0.98, green: 0.55, blue: 0.42)  // coral
    private static let number = Color(red: 0.80, green: 0.62, blue: 1.0)   // lavender
    private static let literal = Color(red: 0.98, green: 0.75, blue: 0.40) // amber
    private static let punctuation = Color.secondary

    /// Single pass over the text: strings (key vs. value decided by the next non-space char), numbers, literals, punctuation.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(text)
        var i = 0
        func emit(_ s: String, _ color: Color?) {
            var piece = AttributedString(s)
            if let color { piece.foregroundColor = color }
            out.append(piece)
        }
        var plain = ""
        func flushPlain() { if !plain.isEmpty { emit(plain, nil); plain = "" } }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                var escaped = false
                while j < chars.count {
                    if escaped { escaped = false } else if chars[j] == "\\" { escaped = true } else if chars[j] == "\"" { break }
                    j += 1
                }
                let end = min(j, chars.count - 1)
                let token = String(chars[i...end])
                var k = end + 1
                while k < chars.count, chars[k] == " " { k += 1 }
                let isKey = k < chars.count && chars[k] == ":"
                flushPlain()
                emit(token, isKey ? key : string)
                i = end + 1
            } else if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i + 1
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "e" || chars[j] == "E" || chars[j] == "-" || chars[j] == "+" { j += 1 }
                flushPlain()
                emit(String(chars[i..<j]), number)
                i = j
            } else if c.isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter { j += 1 }
                let word = String(chars[i..<j])
                flushPlain()
                emit(word, ["true", "false", "null"].contains(word) ? literal : nil)
                i = j
            } else if "{}[]:,".contains(c) {
                flushPlain()
                emit(String(c), punctuation)
                i += 1
            } else {
                plain.append(c)
                i += 1
            }
        }
        flushPlain()
        return out
    }
}

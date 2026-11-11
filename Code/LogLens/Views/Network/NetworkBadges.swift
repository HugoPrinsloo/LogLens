import SwiftUI

enum NetworkStyle {
    static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": .blue
        case "POST": .green
        case "PUT": .orange
        case "PATCH": .purple
        case "DELETE": .red
        case "HEAD": .teal
        default: .gray
        }
    }

    static func statusColor(_ tx: NetworkTransaction) -> Color {
        if tx.state == .failed { return .red }
        guard let code = tx.statusCode else { return .secondary }
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500...: return .red
        default: return .secondary
        }
    }

    /// "application/json; charset=utf-8" → "json"
    static func shortType(_ contentType: String) -> String {
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !mime.isEmpty else { return "" }
        let sub = mime.split(separator: "/").last.map(String.init) ?? mime
        if let plus = sub.firstIndex(of: "+") { return String(sub[sub.index(after: plus)...]) }
        return sub.replacingOccurrences(of: "x-www-form-urlencoded", with: "form").replacingOccurrences(of: "x-protobuf", with: "protobuf")
    }

    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1024 / 1024)
    }

    static func duration(_ d: TimeInterval?) -> String {
        guard let d else { return "…" }
        if d < 1 { return "\(Int(d * 1000)) ms" }
        return String(format: "%.2f s", d)
    }
}

struct MethodBadge: View {
    let method: String
    var body: some View {
        let color = NetworkStyle.methodColor(method)
        Text(method.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct StatusBadge: View {
    let tx: NetworkTransaction
    var body: some View {
        let color = NetworkStyle.statusColor(tx)
        HStack(spacing: 4) {
            if tx.state == .pending && !tx.isTunnel {
                ProgressView().controlSize(.mini)
            } else if tx.state == .failed {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            }
            Text(tx.statusText)
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(color)
    }
}

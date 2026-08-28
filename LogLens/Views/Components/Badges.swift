import SwiftUI

struct LevelBadge: View {
    let level: LogLevel
    var body: some View {
        Text(level.name.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(level.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(level.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct TagBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

/// Success/failure tag for network cards: ✓ 200 (green), ✕ 404 (orange), ✕ 500 / FAILED (red), TUNNEL (gray).
struct OutcomeBadge: View {
    let card: NetworkCardData

    private var color: Color {
        if card.isTunnel { return .gray }
        if card.failed && card.statusCode == nil { return .red }
        switch card.statusCode ?? 0 {
        case 0..<400: return .green
        case 400..<500: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if !card.isTunnel {
                Image(systemName: card.isSuccess ? "checkmark" : "xmark")
                    .font(.system(size: 8, weight: .heavy))
            }
            Text(card.outcomeText.uppercased())
        }
        .font(.caption2.weight(.heavy).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color, in: Capsule())
        .help(card.statusReason.isEmpty ? card.outcomeText : "\(card.outcomeText) \(card.statusReason)")
    }
}

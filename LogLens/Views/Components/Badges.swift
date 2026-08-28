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

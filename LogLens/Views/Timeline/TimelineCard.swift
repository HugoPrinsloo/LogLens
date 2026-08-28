import SwiftUI

/// One timeline entry: a centered card, linked to the previous one by a short
/// vertical connector segment.
struct TimelineRow: View {
    static let cardMaxWidth: CGFloat = 640
    static let connectorHeight: CGFloat = 26

    let item: TimelineFeed.TimelineItem
    let isFirst: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: Self.connectorHeight)
            }
            TimelineCard(item: item, isExpanded: isExpanded, toggle: toggle)
                .frame(maxWidth: Self.cardMaxWidth)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TimelineCard: View {
    let item: TimelineFeed.TimelineItem
    let isExpanded: Bool
    let toggle: () -> Void
    @Environment(EventStore.self) private var store

    private var entry: LogEntry { item.entry }

    /// The event identifier is the headline; the parsed title backs it up.
    private var mainTitle: String { item.eid ?? entry.parsed.title }

    private var accent: Color {
        item.eventType.map(EventTypeStyle.color(for:)) ?? entry.level.color
    }

    private var blobShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !isExpanded {
                collapsedDetail
            } else {
                expandedDetail
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: blobShape)
        .overlay(blobShape.stroke(.separator))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(blobShape)
        .onTapGesture(perform: toggle)
        .contextMenu { menuItems }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(mainTitle)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(entry.level >= .error ? entry.level.color : .primary)
                    .lineLimit(isExpanded ? 4 : 1)
                    .truncationMode(.middle)
                meta
            }
            Spacer(minLength: 8)
            if let type = item.eventType {
                TagBadge(text: type, color: EventTypeStyle.color(for: type))
            } else {
                LevelBadge(level: entry.level)
            }
        }
    }

    private var iconSymbol: String {
        item.eventType.map(EventTypeStyle.symbol(for:)) ?? entry.level.symbol
    }

    private var meta: some View {
        HStack(spacing: 8) {
            Text(Formatters.time.string(from: entry.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(entry.process)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if store.isStarred(entry.id) {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
            }
        }
    }

    @ViewBuilder
    private var collapsedDetail: some View {
        if entry.parsed.title != mainTitle {
            Text(entry.parsed.title)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        let fields = previewFields
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(fields) { f in
                    Text("\(f.key): \(f.value)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    // Same de-dup rule as MessageParser.deriveSummary: skip fields echoing the headline.
    private var previewFields: [ParsedMessage.Field] {
        var out: [ParsedMessage.Field] = []
        for f in entry.parsed.fields where f.value != entry.parsed.title && f.value != mainTitle && !f.value.isEmpty {
            out.append(f)
            if out.count == 3 { break }
        }
        return out
    }

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !entry.parsed.fields.isEmpty {
                KeyValueGrid(fields: entry.parsed.fields)
            }
            ForEach(entry.parsed.groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let typeName = group.typeName {
                            Text(typeName).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    KeyValueGrid(fields: group.fields)
                }
            }
            if !entry.parsed.freeText.isEmpty && entry.parsed.isStructured {
                ForEach(Array(entry.parsed.freeText.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).textSelection(.enabled)
                }
            }
            // The parsed grid already carries everything for structured messages;
            // only show the raw body when parsing couldn't break it down.
            if !entry.parsed.isStructured {
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(store.isStarred(entry.id) ? "Unstar" : "Star") { store.toggleStar(entry.id) }
        Divider()
        Button("Copy Message") { Pasteboard.copy(entry.message) }
        Button("Copy Title") { Pasteboard.copy(entry.parsed.title) }
        Button("Copy as JSON") { Pasteboard.copy(Pasteboard.json(for: entry)) }
        Divider()
        Button("Only “\(entry.process)”") { store.toggleFacet(.process(entry.process), exclusive: true) }
        Button("Only “\(entry.subsystemDisplay)”") { store.toggleFacet(.subsystem(entry.subsystem), exclusive: true) }
        Button("Only “\(entry.categoryDisplay)”") { store.toggleFacet(.category(entry.category), exclusive: true) }
    }
}

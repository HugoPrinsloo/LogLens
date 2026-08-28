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
    /// True when the card is being rendered off-screen for "Copy as Image" (no gestures, no feedback).
    var isSnapshot = false
    @Environment(EventStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var showCopied = false

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
        .overlay(alignment: .topTrailing) {
            if showCopied {
                Label("Image copied", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .padding(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        // Click expands/collapses, or copies the card as a PNG when the toolbar "Copy as Image" toggle is on.
        .onTapGesture { if store.copyCardOnClick { copyAsImage() } else { toggle() } }
        .contextMenu { menuItems }
        .onAppear(perform: writeDevSnapshot)
    }

    /// `LogLens --snapshot-card <path>` writes the first card's "Copy as Image" PNG to disk (dev/verification aid).
    private static let devSnapshotPath: String? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot-card"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }()
    private static var devSnapshotDone = false

    private func writeDevSnapshot() {
        // Prefers a network card with a body when the proxy is running, else the first structured analytics card.
        let wanted = CommandLine.arguments.contains("--proxy") ? (entry.network?.responseBody != nil || entry.network?.requestBody != nil) : item.eventType != nil
        guard let path = Self.devSnapshotPath, !Self.devSnapshotDone, !isSnapshot, wanted else { return }
        Self.devSnapshotDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let image = renderImage(), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Copy as image

    private func copyAsImage() {
        guard !isSnapshot else { return }
        if let image = renderImage() {
            Pasteboard.copy(image: image)
            withAnimation(.snappy(duration: 0.2)) { showCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.3)) { showCopied = false }
            }
        }
    }

    /// Renders this card, expanded, at the timeline's card width and 2× scale (transparent background).
    @MainActor
    private func renderImage() -> NSImage? {
        let snapshot = TimelineCard(item: item, isExpanded: true, toggle: {}, isSnapshot: true)
            .frame(width: TimelineRow.cardMaxWidth)
            .padding(12)   // room for the shadow
            .environment(store)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 2
        renderer.isOpaque = false
        var image: NSImage?
        // Dynamic NSColors (controlBackgroundColor…) resolve against the current drawing appearance.
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        return image
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
            if let net = entry.network {
                OutcomeBadge(card: net)
            }
            if let type = item.eventType {
                TagBadge(text: type, color: EventTypeStyle.color(for: type))
            } else {
                LevelBadge(level: entry.level)
            }
        }
    }

    /// Request / response bodies for network cards, each in a syntax-coloured code box.
    @ViewBuilder
    private func bodyBox(_ text: String, label: String, symbol: String, content: String, size: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(label, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !content.isEmpty { Text(content).font(.caption).foregroundStyle(.tertiary) }
                Text(NetworkStyle.bytes(size)).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if !isSnapshot {
                    Button { Pasteboard.copy(text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Copy \(label.lowercased())")
                }
            }
            JSONText(text: text, lineCap: isSnapshot ? 60 : 40)
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
                    selectable(Text(line).font(.callout))
                }
            }
            if let net = entry.network {
                if let body = net.requestBody {
                    bodyBox(body, label: "Request", symbol: "arrow.up", content: net.requestContent, size: net.requestSize)
                }
                if let body = net.responseBody {
                    bodyBox(body, label: "Response", symbol: "arrow.down", content: net.responseContent, size: net.responseSize)
                }
            }
            // The parsed grid already carries everything for structured messages;
            // only show the raw body when parsing couldn't break it down.
            if !entry.parsed.isStructured {
                selectable(Text(entry.message).font(.system(.caption, design: .monospaced)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
        }
        .padding(.top, 4)
    }

    /// Selectable text is backed by a different view that won't wrap under `ImageRenderer`; snapshots use plain text.
    @ViewBuilder
    private func selectable(_ text: Text) -> some View {
        if isSnapshot {
            text.fixedSize(horizontal: false, vertical: true)
        } else {
            text.textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(store.isStarred(entry.id) ? "Unstar" : "Star") { store.toggleStar(entry.id) }
        Divider()
        Button(isExpanded ? "Collapse" : "Expand", action: toggle)
        Divider()
        Button("Copy as Image", action: copyAsImage)
        Button("Copy Message") { Pasteboard.copy(entry.message) }
        Button("Copy Title") { Pasteboard.copy(entry.parsed.title) }
        Button("Copy as JSON") { Pasteboard.copy(Pasteboard.json(for: entry)) }
        Divider()
        Button("Only “\(entry.process)”") { store.toggleFacet(.process(entry.process), exclusive: true) }
        Button("Only “\(entry.subsystemDisplay)”") { store.toggleFacet(.subsystem(entry.subsystem), exclusive: true) }
        Button("Only “\(entry.categoryDisplay)”") { store.toggleFacet(.category(entry.category), exclusive: true) }
    }
}

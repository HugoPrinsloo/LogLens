import AppKit
import SwiftUI

struct EventTableView: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        Group {
            if !store.hasEntries {
                EmptyStateView()
            } else if !store.hasFiltered {
                ContentUnavailableView.search(text: store.filter.searchText)
            } else {
                EventTable(
                    // Only the count is read here (it registers the dependency on `filtered`); the coordinator
                    // reads rows straight from the store. Holding the array in this struct made SwiftUI keep a
                    // second reference to the buffer, which turned every append into a 100 k-element copy.
                    count: store.filtered.count,
                    revision: store.filteredRevision,
                    selection: store.selection,
                    autoScroll: store.autoScroll,
                    starred: store.starred
                )
            }
        }
    }
}

/// The list is an `NSTableView` driven directly: SwiftUI's `Table` re-diffs the whole collection by id on every
/// update, which at 10 batches/s over 100 k rows was the dominant main-thread cost in list mode. Here an incoming
/// batch is `noteNumberOfRowsChanged()` (O(batch)), a trim/refilter is one `reloadData()` (O(1) with fixed row
/// heights) that keeps the row under the cursor in place, and cells are plain reused `NSTextField`s.
private struct EventTable: NSViewRepresentable {
    @Environment(EventStore.self) private var store
    let count: Int
    let revision: Int
    let selection: LogEntry.ID?
    let autoScroll: Bool
    let starred: Set<Int>

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.store = store
        context.coordinator.apply(count: count, revision: revision, selection: selection, autoScroll: autoScroll, starred: starred)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var store: EventStore
        /// Rows are read from `store.filtered` on demand (never copied here).
        private var rows: [LogEntry] { store.filtered }
        private var count = 0
        private var revision = -1
        /// Id of the row under the top edge, refreshed on every scroll; used to keep the reader's place across reloads.
        private var anchorID: LogEntry.ID?
        private var anchorOffset: CGFloat = 0
        private var starred: Set<Int> = []
        private var autoScroll = true
        private var populated = false
        /// Set while we change the table's selection ourselves so the delegate callback doesn't echo it back.
        private var suppressSelectionCallback = false

        private let scrollView = NSScrollView()
        private let tableView = NSTableView()
        private let menu = NSMenu()

        static let rowHeight: CGFloat = 24
        private enum ColumnID {
            static let time = NSUserInterfaceItemIdentifier("time")
            static let level = NSUserInterfaceItemIdentifier("level")
            static let app = NSUserInterfaceItemIdentifier("app")
            static let subsystem = NSUserInterfaceItemIdentifier("subsystem")
            static let category = NSUserInterfaceItemIdentifier("category")
            static let event = NSUserInterfaceItemIdentifier("event")
        }
        private static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        private static let calloutFont = NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)
        private static let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        init(store: EventStore) {
            self.store = store
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, min: CGFloat, ideal: CGFloat, max: CGFloat) -> NSTableColumn {
                let c = NSTableColumn(identifier: id)
                c.title = title
                c.minWidth = min
                c.width = ideal
                c.maxWidth = max
                c.resizingMask = .userResizingMask
                return c
            }
            tableView.addTableColumn(column(ColumnID.time, "Time", min: 104, ideal: 108, max: 130))
            let level = column(ColumnID.level, "", min: 22, ideal: 22, max: 22)
            level.resizingMask = []
            tableView.addTableColumn(level)
            tableView.addTableColumn(column(ColumnID.app, "App", min: 60, ideal: 110, max: 220))
            tableView.addTableColumn(column(ColumnID.subsystem, "Subsystem", min: 60, ideal: 130, max: 300))
            tableView.addTableColumn(column(ColumnID.category, "Category", min: 60, ideal: 120, max: 260))
            let event = column(ColumnID.event, "Event", min: 200, ideal: 600, max: 100_000)
            event.resizingMask = [.userResizingMask, .autoresizingMask]
            tableView.addTableColumn(event)

            tableView.dataSource = self
            tableView.delegate = self
            tableView.style = .inset
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.usesAutomaticRowHeights = false
            tableView.rowHeight = Self.rowHeight
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = true
            tableView.allowsColumnReordering = false
            tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            tableView.autosaveName = "EventTable"
            tableView.autosaveTableColumns = true
            tableView.intercellSpacing = NSSize(width: 8, height: 0)
            menu.delegate = self
            tableView.menu = menu

            scrollView.documentView = tableView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            return scrollView
        }

        // MARK: Updates

        func apply(count newCount: Int, revision newRevision: Int, selection: LogEntry.ID?, autoScroll: Bool, starred newStarred: Set<Int>) {
            let oldCount = count
            let oldRevision = revision
            count = newCount
            revision = newRevision
            self.autoScroll = autoScroll

            if !populated {
                populated = true
                withSelectionSuppressed { tableView.reloadData() }
            } else if newRevision == oldRevision, newCount >= oldCount {
                if newCount > oldCount {
                    Perf.measure("table.append") {
                        withSelectionSuppressed { tableView.noteNumberOfRowsChanged() }
                    }
                }
            } else {
                Perf.measure("table.reload") { reloadKeepingPlace() }
            }

            if newStarred != starred {
                starred = newStarred
                reloadVisibleRows(columns: [ColumnID.level])
            }

            syncSelection(selection)

            if autoScroll, count > 0 {
                tableView.scrollRowToVisible(count - 1)
            }
            updateAnchor()
        }

        /// Remember which row sits under the top edge (one lookup per scroll event / update).
        @objc private func clipDidScroll() { updateAnchor() }

        private func updateAnchor() {
            let clip = scrollView.contentView
            let visible = tableView.rows(in: clip.bounds)
            let rows = self.rows
            guard visible.location >= 0, visible.location < rows.count else { anchorID = nil; return }
            anchorID = rows[visible.location].id
            anchorOffset = clip.bounds.origin.y - tableView.rect(ofRow: visible.location).minY
        }

        /// Rows were trimmed from the top or the filter changed: reload, then put the row that was under the top
        /// edge back where it was (if it still exists) so reading isn't interrupted by the buffer trimming.
        private func reloadKeepingPlace() {
            let keep = autoScroll ? nil : anchorID
            let offset = anchorOffset
            withSelectionSuppressed { tableView.reloadData() }
            guard let keep, let newIndex = rows.firstIndex(where: { $0.id == keep }) else { return }
            let clip = scrollView.contentView
            let y = tableView.rect(ofRow: newIndex).minY + offset
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, y)))
            scrollView.reflectScrolledClipView(clip)
        }

        private func reloadVisibleRows(columns: [NSUserInterfaceItemIdentifier]) {
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.length > 0 else { return }
            var cols = IndexSet()
            for id in columns { let i = tableView.column(withIdentifier: id); if i >= 0 { cols.insert(i) } }
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: cols)
        }

        private func syncSelection(_ id: LogEntry.ID?) {
            let rows = self.rows
            let current = tableView.selectedRow >= 0 && tableView.selectedRow < rows.count ? rows[tableView.selectedRow].id : nil
            guard current != id else { return }
            withSelectionSuppressed {
                if let id, let index = rows.lastIndex(where: { $0.id == id }) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                } else {
                    tableView.deselectAll(nil)
                }
            }
        }

        private func withSelectionSuppressed(_ body: () -> Void) {
            suppressSelectionCallback = true
            body()
            suppressSelectionCallback = false
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { store.filtered.count }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let rows = self.rows
            guard let tableColumn, row < rows.count else { return nil }
            let entry = rows[row]
            let id = tableColumn.identifier
            if id == ColumnID.level {
                let view = (tableView.makeView(withIdentifier: id, owner: nil) as? LevelDotView) ?? {
                    let v = LevelDotView()
                    v.identifier = id
                    return v
                }()
                view.configure(level: entry.level, starred: starred.contains(entry.id))
                return view
            }
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? Self.makeTextCell(id)
            guard let field = cell.textField else { return cell }
            switch id {
            case ColumnID.time:
                field.font = Self.monoFont
                field.textColor = .secondaryLabelColor
                field.stringValue = entry.timeText
            case ColumnID.app:
                field.font = Self.bodyFont
                field.textColor = .labelColor
                field.stringValue = entry.process
            case ColumnID.subsystem:
                field.font = Self.bodyFont
                field.textColor = .secondaryLabelColor
                field.stringValue = entry.subsystemDisplay
            case ColumnID.category:
                field.font = Self.bodyFont
                field.textColor = .secondaryLabelColor
                field.stringValue = entry.categoryDisplay
            default:
                field.attributedStringValue = Self.eventText(for: entry)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback else { return }
            let row = tableView.selectedRow
            let rows = self.rows
            let id: LogEntry.ID? = row >= 0 && row < rows.count ? rows[row].id : nil
            if store.selection != id { store.selection = id }
        }

        private static func makeTextCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.truncatesLastVisibleLine = true
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        /// Title (level-coloured for errors) followed by the parsed summary in a lighter, smaller face.
        private static func eventText(for entry: LogEntry) -> NSAttributedString {
            let titleColor: NSColor = entry.level >= .error ? NSColor(entry.level.color) : .labelColor
            let out = NSMutableAttributedString(string: entry.parsed.title, attributes: [.font: bodyFont, .foregroundColor: titleColor])
            if !entry.parsed.summary.isEmpty {
                out.append(NSAttributedString(string: "   " + entry.parsed.summary, attributes: [.font: calloutFont, .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            return out
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let row = tableView.clickedRow
            let rows = self.rows
            guard row >= 0, row < rows.count else { return }
            let e = rows[row]
            let store = self.store
            func item(_ title: String, _ action: @escaping () -> Void) {
                let i = ClosureMenuItem(title: title, action: action)
                menu.addItem(i)
            }
            item(store.isStarred(e.id) ? "Unstar" : "Star") { store.toggleStar(e.id) }
            menu.addItem(.separator())
            item("Copy Message") { Pasteboard.copy(e.message) }
            item("Copy Title") { Pasteboard.copy(e.parsed.title) }
            item("Copy as JSON") { Pasteboard.copy(Pasteboard.json(for: e)) }
            menu.addItem(.separator())
            item("Only “\(e.process)”") { store.toggleFacet(.process(e.process), exclusive: true) }
            item("Only “\(e.subsystemDisplay)”") { store.toggleFacet(.subsystem(e.subsystem), exclusive: true) }
            item("Only “\(e.categoryDisplay)”") { store.toggleFacet(.category(e.category), exclusive: true) }
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Level dot with an optional star, drawn directly (no SwiftUI hosting per row).
private final class LevelDotView: NSView {
    private var color: NSColor = .secondaryLabelColor
    private var starred = false
    private static let star: NSImage? = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Starred")?
        .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))

    func configure(level: LogLevel, starred: Bool) {
        let c = NSColor(level.color)
        guard c != color || starred != self.starred else { return }
        color = c
        self.starred = starred
        toolTip = level.name
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSRect(x: bounds.midX - 4, y: bounds.midY - 4, width: 8, height: 8)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        if starred, let star = Self.star {
            let rect = NSRect(x: dot.maxX - 2, y: dot.maxY - 2, width: 8, height: 8)
            NSColor.systemYellow.set()
            star.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

struct EmptyStateView: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: store.isCapturing ? "dot.radiowaves.left.and.right" : "waveform.badge.magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: store.isCapturing)
            Text(store.isCapturing ? "Listening for events…" : "No events yet")
                .font(.title2.weight(.semibold))
            if store.isCapturing {
                Text("Interact with the app on **\(store.selectedSource.name)**. Anything it logs via OSLog will show up here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Pick a booted simulator (or This Mac) in the toolbar.")
                    step(2, "Press **Record** (⌘R) and use the app.")
                    step(3, "Click apps, subsystems or categories in the sidebar to filter. Click again to remove one.")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460, alignment: .leading)
            }
            Text(store.commandPreview)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: 640)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text)
        }
    }
}

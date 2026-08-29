# LogLens Performance Audit

_2026-08-28, against `develop` @ `b6cfc3b` (v1.3.1). Written as a read-only sweep of every Swift file; **implemented the same night** — see "Status" at the end for what landed and the before/after numbers._

## Goals (from Hugo)

1. The app should feel **extremely smooth**.
2. Logs should appear **instantly**, no lag.
3. Scroll views should stay **silky** while data is being appended live.

## TL;DR — where the time actually goes

Today an event travels: `log stream` → pipe → parse queue → `pending` → **100 ms timer** → main → `EventStore.append` → SwiftUI `Table` diff of the **entire** `filtered` array (up to 100 k rows) / timeline `TimelineFeed` queue (**80–350 ms per card**, drops events beyond 60) → render.

The three things standing between LogLens and "instant + silky" are, in order of payoff:

| # | Problem | Where | Why it hurts | Fix (short) |
|---|---------|-------|--------------|-------------|
| 1 | SwiftUI `Table` re-diffs all of `filtered` on every batch | `EventTableView.swift:15` | 10×/s × 100 k row identities, then `scrollTo` forces layout | AppKit `NSTableView` with incremental `insertRows` |
| 2 | Timeline pacing *adds* latency by design | `TimelineFeed.swift:84-87` | a burst of 10 events takes 3.5 s to appear; >60 queued are dropped | Reveal the whole queue per tick, one spring per group |
| 3 | Every batch pays O(n) once the buffer is full | `EventStore.trimIfNeeded` | `removeFirst(k)` memmoves ~25 MB on main 10×/s | Hysteresis trim (or a `Deque`) |
| 4 | Search/filter rebuilds a lowercased haystack for every entry | `LogEntry.searchText`, `LogFilter.makeMatcher` | 100 k allocations + lowercasing 64 KB network bodies per keystroke, on main | Precompute once on the parse queue, filter off-main, debounce |
| 5 | `selectedEntry` linear-scans `filtered` on every batch | `EventStore.selectedEntry`, `InspectorContent` | up to 1 M comparisons/s while a row is selected | Cache the selected entry; ID-indexed lookup |
| 6 | Sidebar re-sorts three facet dictionaries 10×/s | `SidebarView.FacetSection.rows` | filter + map + sort ×3 per batch inside a `List` diff | Publish facet snapshots at ≤4 Hz |
| 7 | Network bodies are decoded + pretty-printed on the main thread | `LogEntry.network(_:)` via `NetworkStore.handle` | a 4 MB JSON response = tens of ms of main-thread stall | Build the entry on a utility queue, hop to main with the result |
| 8 | `.shadow()` on all 200 timeline cards | `TimelineCard.swift:69` | offscreen render + blur per card | Flat card (hairline stroke) — matches the app's flat look anyway |
| 9 | `DateFormatter` per line on the parse queue | `LogLineDecoder.decode` | ~10 µs/line ICU; delays each 100 ms batch under load | Hand-parse the fixed `log` timestamp format |
| 10 | 100 ms fixed batch timer | `LogStreamer.start` | worst-case 100 ms before the UI even hears about an event | Leading-edge flush + short trailing coalesce |

Everything below is the detail, grouped by pipeline stage, with concrete code changes. Items are tagged **[Big]**, **[Medium]**, **[Small]** by expected impact and **(easy / moderate / larger)** by effort.

---

## 1. Ingestion: `LogStreamer` + `LogLineDecoder` + `MessageParser`

All of this runs on `parseQueue`, so it doesn't jank the UI directly — but it sets the floor on latency and CPU, and at high rates it delays whole batches.

### 1.1 Batch cadence is a fixed 100 ms tail **[Medium] (easy)**

`LogStreamer.swift:102-106` — a repeating 100 ms `DispatchSourceTimer` is the only thing that moves entries from `pending` to main. A single event that arrives just after a tick waits ~100 ms for nothing.

**Fix:** coalesce with a leading edge. In `consume`, after appending to `pending`, if no flush is scheduled, schedule one for `now + 16 ms` (one frame); the timer becomes a fallback. Worst-case latency drops from 100 ms to ~16–33 ms with identical batching behaviour under load.

```swift
// in consume(), after pending.append
if !flushScheduled {
    flushScheduled = true
    parseQueue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
        self?.flushScheduled = false
        self?.flush()
    }
}
```

### 1.2 `DateFormatter.date(from:)` per line **[Medium] (easy)**

`LogStreamer.swift:166-180`. `log stream --style ndjson` emits a fixed `yyyy-MM-dd HH:mm:ss.SSSSSSZ` (e.g. `2026-08-28 21:14:03.123456+0200`). `DateFormatter` goes through ICU (~5–15 µs/line, plus it isn't the cheapest thing to call from a non-main queue). A hand parser over `utf8` is ~100 ns. At 5 k lines/s that's 50–75 ms/s of CPU saved on the parse queue, and less time between a line arriving and its batch being ready.

**Fix:** parse the 6 numeric fields + µs + `±HHMM` offset by hand from the UTF-8 bytes; build the `Date` from `timeIntervalSince1970` via `timegm`-style arithmetic or cache a `DateComponents`-free epoch computation per day (the date part changes once a day; cache `dayEpoch` keyed on the first 10 bytes). Fall back to the `DateFormatter` only if the fast path fails.

### 1.3 Line splitting is O(n²) per chunk **[Small] (easy)**

`LogStreamer.consume`: `buffer.removeSubrange(startIndex...nl)` inside the `while` loop shifts the remaining bytes on every line. A 64 KB `availableData` chunk with 300 lines does 300 memmoves of a shrinking buffer.

**Fix:** walk with a cursor and slice; only keep the tail once:

```swift
var start = buffer.startIndex
while let nl = buffer[start...].firstIndex(of: 0x0A) {
    let line = buffer[start..<nl]
    if !line.isEmpty, let e = decoder.decode(line, ...) { batch.append(e) }
    start = buffer.index(after: nl)
}
buffer = Data(buffer[start...])   // one copy of the partial tail
```

### 1.4 Precompute what the UI needs, once, off-main **[Big] (moderate)**

This is the single most "clever" lever: the parse queue has spare time; the main thread doesn't. Move every per-entry derived value out of render/filter paths into `LogLineDecoder`:

| Today | Computed where | Move to |
|-------|----------------|---------|
| `LogEntry.searchText` (concat + `lowercased()`) | every filter pass, per entry, on main | `let searchKey: String` stored on the entry |
| `Formatters.time.string(from:)` | every table cell / card render (ICU) | `let timeText: String` stored on the entry |
| `parsed.derivedEventType` / `derivedEID` | `TimelineItem.init` per reveal | store once in `ParsedMessage` |
| `EventTypeStyle.color(for:)` FNV hash | per card render | trivial, but free once the type is stored |

`LogEntry` grows by two strings; in exchange the main thread never touches ICU or lowercases anything again. (Keep `searchKey` out of `Codable` export with `CodingKeys`.)

### 1.5 Intern the repeated strings **[Medium] (easy)**

`process`, `processPath`, `sender`, `subsystem`, `category`, `sourceName` take a handful of distinct values across 100 k entries, but each entry holds its own heap-allocated `String` (anything >15 UTF-8 bytes leaves the inline buffer). Interning on the parse queue —

```swift
private var intern: [String: String] = [:]
func interned(_ s: String) -> String { if let h = intern[s] { return h }; intern[s] = s; return s }
```

— means every entry shares one buffer per distinct value. Three wins: fewer allocations per line, less resident memory, and `String ==` hits its identity fast path when the facet matcher compares `e.process` against the selected set. Bound the table (e.g. reset at 4 k keys) so a pathological stream can't grow it.

### 1.6 `MessageParser` **[Small]**

It's per-line and character-oriented but fine; nothing here is hot compared to 1.2/1.4. `splitKeyValue`'s `CharacterSet.alphanumerics.contains` per scalar and repeated `trimmingCharacters` could be tightened, but measure first.

---

## 2. The store: `EventStore.append` / `trimIfNeeded` / `refilter`

### 2.1 Trim tax once the buffer is full **[Big] (easy)**

`EventStore.swift:232-247`. With `maxEntries = 100_000`, once the buffer fills **every** batch (10×/s) does:

- `entries.removeFirst(overflow)` → shifts ~100 k `LogEntry`s (≈250 B each → ~25 MB memmove) on the main thread;
- `filtered.firstIndex { $0.id >= firstID }` → linear scan from the front;
- `filtered.removeFirst(drop)` → another shift.

That's a steady 2–5 ms of main-thread time per batch forever, precisely when the app is busiest.

**Fix A (5 lines): hysteresis.** Trim only when `entries.count > maxEntries + slack` and trim down to `maxEntries - slack` (slack = 5–10 %). The shift now happens once per ~1 000 batches instead of every batch. Same for `NetworkStore.handle` (`transactions.removeFirst` + `rebuildIndex()` on every event at cap — same shape, same fix).

**Fix B (better): `Deque` from swift-collections.** It's already resolved in `build/SourcePackages/checkouts/swift-collections` as a transitive dependency; add `swift-collections` / product `DequeModule` to `project.yml` and `removeFirst` becomes O(k). `Deque` is `RandomAccessCollection`, so `Table`, `ForEach`, `suffix`, and `last(where:)` all keep working.

Because IDs are monotonic ints, a deque also gives you **O(1) lookup by ID**: `entries[id - entries.first!.id]`. That kills every `last(where: { $0.id == … })` in the store (see 2.3).

### 2.2 COW copy after each filter reset **[Small] (easy)**

`refilter` does `filtered = entries` when no filter is active, so the two arrays share a buffer; the next `entries.append` in `append()` copies all 100 k elements (a million retains). One-off per reset, ~10 ms hitch. Goes away with `Deque` + hysteresis, or by keeping `filtered` as a separate array always (`entries.filter { _ in true }` is the same cost once, but on your terms).

### 2.3 `selectedEntry` scans `filtered` on every batch **[Big] (easy)**

`EventStore.selectedEntry` (`filtered.last(where:)`, then `entries.last(where:)`) is a computed property read by `InspectorContent` and `EventDetailView`. Both depend on `filtered`, so both re-evaluate on every batch, and if the selected row isn't near the end (you selected something, then 20 k events arrived) each evaluation walks the array. Two readers × 10 batches/s × up to 100 k = up to 2 M comparisons/s of pure waste while a row is selected.

**Fix:** make it stored. In `selection.didSet` resolve the entry once (O(1) with the ID index from 2.1, or the current backwards scan — it's a single scan on click, fine); clear it in `clear()` and when trim drops it. Views then observe a property that only changes on click.

### 2.4 Filtering: precompute, move off-main, narrow incrementally **[Big] (moderate)**

`refilter()` runs `entries.filter(matcher)` on main for every keystroke in the search field, every facet click, every level toggle, and `toggleStar` when "starred only" is on. With `searchText` built per entry (1.4) and network entries whose `message` embeds up to 128 KB of bodies, a keystroke over a full buffer can take hundreds of ms.

Three layers, each independent:

1. **Precomputed `searchKey`** (1.4) — removes the allocation and the lowercase; the matcher becomes `terms.allSatisfy { key.contains($0) }` over an existing string.
2. **Debounce the search field** — `ContentView.onChange(of: searchText)` → schedule `updateFilter` 120–150 ms after the last keystroke. Facet clicks stay immediate.
3. **Filter off the main actor with a generation token.** `LogEntry` is a value type of value types (Sendable). Snapshot `entries` (COW, free), bump `filterGeneration`, run the filter in `Task.detached(priority: .userInitiated)`, and on return apply only if the generation still matches. Meanwhile keep the UI live: new batches that arrive during the background pass are matched on main with the new matcher and appended to a "pending tail" that is glued onto the result. **Incremental narrowing** is a cheap extra: if the new filter only added a search term (old text is a prefix, everything else equal), filter `filtered` instead of `entries` — typically 100× fewer rows.

Also: `refilter` re-walks `entries` once per lane (`entries.filter(lane.matcher)` × up to 4) plus once for the global feed. Do one pass and bucket into lanes.

### 2.5 Observation granularity **[Medium] (easy)**

`@Observable` tracks per property, which is great — but `entries` and `filtered` change 10×/s and are read in more places than they need to be:

- `EventTableView` / `EventTimelineView` read `store.entries.isEmpty` and `store.filtered.isEmpty` → both container bodies re-run every batch.
- `CaptureToolbar` reads `store.entries.isEmpty` for two `.disabled()`s → toolbar body every batch.
- `StatusBar` reads `filtered.count`, `entries.count`, `eventsPerSecond` → fine, it must.

**Fix:** expose `private(set) var hasEntries = false`, `hasFiltered = false` (and `entryCount`/`filteredCount` for the status bar) and only assign them **when the value changes** (Observation fires on every `willSet`, not on inequality). Views read those instead of the arrays. Same in `TimelineFeed`: `backlog = queue.count` on every ingest and every reveal fires observers even when equal — guard with `if backlog != n`.

### 2.6 `eventsPerSecond` **[Small]**

Updated per batch; only `StatusBar` reads it. Fine. Consider rounding the window to 250 ms ticks so the label doesn't churn at 10 Hz; cosmetic.

### 2.7 Export encodes on main **[Small] (easy)**

`exportData` pretty-prints up to 100 k entries synchronously the moment the panel opens. User-initiated, so not a smoothness issue, but a 100 k export is a multi-second beachball. Encode in a `Task.detached`, then present.

---

## 3. Table view

### 3.1 SwiftUI `Table` over 100 k rows that change 10×/s **[Big] (larger — the one real rewrite)**

`EventTableView.swift:15`: `Table(store.filtered, selection:)` gets a brand-new collection every batch. SwiftUI's `Table` on macOS is an `NSTableView` underneath, but the SwiftUI layer diffs the collection by ID to work out inserts/removes (O(n) per update) and then reloads. Then `.onChange(of: store.filtered.count)` calls `proxy.scrollTo(last.id, anchor: .bottom)`, which forces a layout pass. At 100 k rows × 10 Hz this is the dominant main-thread cost in table mode, and the reason list mode will never feel "silky" under load no matter what the store does.

**Fix: an `NSViewRepresentable` around `NSTableView`** (the Console.app / Xcode approach). What you gain:

- **Incremental updates:** `tableView.insertRows(at: IndexSet(range), withAnimation: [])` for the batch, `removeRows(at:)` for trims. No diffing, no reload. Cost is proportional to the batch, not the buffer.
- **Fixed row height, no autolayout:** `usesAutomaticRowHeights = false`, `rowHeight = 22`, cell views reused via `makeView(withIdentifier:)`, text set directly on `NSTextField` (no SwiftUI cell bodies at all).
- **Real stick-to-bottom:** only `scrollRowToVisible(last)` when auto-scroll is on *and* the view was already at the bottom; when trimming from the top while the user is scrolled up, offset `contentView.bounds.origin.y -= removed * rowHeight` so what they're looking at doesn't move. That's the "silky while data streams" behaviour Hugo wants and SwiftUI `Table` can't express.
- **Selection survives**: bind `selectedRowIndexes` ⇄ `store.selection` in the coordinator.
- Row background alternation, column resizing, header sort indicators, `contextMenu` → `NSMenu` via `menu(for:)` — all still there.

It's ~250 lines. Keep `EventTableView` as the SwiftUI shell (empty state, `ContentUnavailableView`), swap the body.

If you'd rather stay in SwiftUI for now, the cheap mitigations are: precomputed `timeText` (1.4), the stored `selectedEntry` (2.3), and only calling `scrollTo` when `filtered.last?.id` changed *and* the user hasn't scrolled up — but the O(n) diff stays.

### 3.2 Cells **[Small]**

`Formatters.time.string(from:)` per cell — gone with 1.4. `LevelDot` reads `store.isStarred(e.id)` → every visible cell depends on `starred`; starring one row re-renders every visible cell. Harmless at NSTableView scale, but with the representable, star state becomes a per-row `reloadData(forRowIndexes:)`.

---

## 4. Timeline view

The 1.3.1 fixes (bottom-anchored scroll instead of `scrollTo`, `Equatable` rows) removed the worst of it. What's left is mostly about *latency*, plus a few render costs.

### 4.1 Pacing adds lag by design **[Big] (easy)**

`TimelineFeed.interval` = 350 ms when calm, tightening to 80 ms with backlog; `revealNext` shows 1 card (3 when backlog > 30); `maxQueue = 60` **drops** anything beyond that. The intent was "readable cadence", but it's the direct cause of "logs don't appear instantly": an app that fires 10 analytics events on a screen load takes 3.5 s to show them, and a burst of 200 loses 140.

**Fix: reveal what's queued, per tick, as one group.** Keep the spring — it's the signature of the app — but attach it to the *group*, not to each card:

```swift
private func revealNext() {
    let items = queue.map(TimelineItem.init)   // everything waiting
    queue.removeAll(keepingCapacity: true)
    backlog = 0
    withAnimation(.spring(duration: 0.35, bounce: 0.15)) { visible.append(contentsOf: items) }
    trimVisible()
}
```

and tick at ~60–100 ms (one reveal per incoming batch is the natural cadence — you could even drop the drain loop and reveal directly from `ingest`). Nothing is ever skipped; latency is bounded by the batch cadence. If Hugo still wants the one-at-a-time cinematic feel, make it a toggle ("Paced") — default off.

### 4.2 Cards carry a real shadow **[Medium] (easy)**

`TimelineCard.swift:69`: `.shadow(color:radius:6,y:2)` on the whole card subtree. SwiftUI shadows rasterize the view into an offscreen texture and blur it; 200 cards × (first draw + every expand/collapse + every content change) adds up, and it's the kind of thing that shows up as "Core Animation commit" spikes in Instruments during the reveal spring. The app's design language is flat (no gradients) — a shadow is the odd one out anyway.

**Fix:** drop the shadow; keep the hairline `.stroke(.separator)` and maybe nudge the fill one step darker/lighter than the background for separation. If a shadow must stay, shadow only the shape (`.background(blobShape.fill(...).shadow(...))`) so the blur runs over a rounded rect, not over text glyphs, and add `.compositingGroup()` above it.

### 4.3 `TimelineScroll.body` re-runs on every ingest and every reveal **[Medium] (easy)**

`TimelineScroll` reads `feed.pendingCount` (backlog + skipped) to feed `IncomingIndicator`. `backlog` changes on every `ingest` (10 Hz) and every `revealNext`, so the `ForEach` over 200 rows is re-evaluated ~20×/s. The rows are `Equatable` so their bodies don't re-run, but the identity diff + `LazyVStack` update still does.

**Fix:** let `IncomingIndicator` take the `feed` and read `pendingCount` itself; `TimelineScroll.body` then only depends on `feed.visible`. Combine with the "assign only if changed" guard from 2.5.

### 4.4 Per-card store dependencies **[Small] (easy)**

`TimelineCard` reads `store.isStarred(entry.id)` (→ `starred`), `store.copyCardOnClick`, and `store.isCapturing` indirectly via `TimelineScroll`. Starring any card re-runs 200 card bodies. Pass `isStarred` into `TimelineRow` as a `let` (it's already `Equatable`) and read `copyCardOnClick` inside the tap handler through a closure rather than in `body`.

### 4.5 `JSONText` re-splits the body on every evaluation **[Small] (easy)**

`JSONText.body` does `text.split(separator: "\n")` (up to 64 KB) each time the card re-evaluates, before the cached `JSONHighlighter.attributed` lookup. Cache `(lineCount, cappedText)` next to the attributed string in the same `NSCache` entry, keyed on `(text, lineCap)`.

### 4.6 `Text(AttributedString)` with thousands of runs **[Small]**

A 40-line JSON body produces a few hundred attributed runs; fine. If bodies get longer ("Show all"), consider `NSTextView` in a representable — lays out large attributed text far faster than SwiftUI `Text`.

### 4.7 Trimming the head of a bottom-anchored `LazyVStack` **[Small]**

`visible.removeFirst` at 200 with animations disabled is correct. If Instruments shows a hitch on the trim, the cure is to trim in chunks (drop 20 at 220) rather than 1 per reveal — same hysteresis idea as 2.1.

---

## 5. Sidebar

### 5.1 Facet lists re-sorted 10×/s **[Medium] (easy)**

`FacetSection` takes `counts: [String: Int]` from the store; the dictionaries mutate on every batch, so each of the three sections re-runs `rows` (filter → map → sort) and `selectedCount` (scan of all keys) per batch, inside a `List` that then diffs the rows. With a few hundred subsystems/categories that's real work at 10 Hz, and the count capsules flicker numbers faster than anyone can read.

**Fix:** keep the live dictionaries private and publish an observable snapshot at ≤4 Hz (a `facetSnapshot` struct of three pre-sorted `[(key, count)]` arrays, updated by a 250 ms main-actor task that only assigns when the sorted arrays actually differ). The sidebar then re-renders at most 4×/s and only when something changed; the search-field filtering becomes a filter over an already-sorted array.

---

## 6. Network path

### 6.1 Body decode + pretty-print on the main thread **[Big] (easy)**

`ProxyServer.emit` → `DispatchQueue.main.async` → `NetworkStore.handle` → `onFinished` → `EventStore.appendNetwork` → **`LogEntry.network(tx)`**, which runs `BodyDecoder.decode` (zlib inflate, up to 4 MB), `JSONSerialization.jsonObject` + `.prettyPrinted` (allocates the whole object graph), `String(data:)`, and joins both bodies into `message`. All on the main actor. One large JSON response is a visible hitch; a burst of them on app launch is a freeze.

**Fix:** build the `LogEntry` before hopping to main: in `ProxyServer.emit` (or a dedicated utility queue) for `.updated` events whose state is no longer `.pending`, compute `LogEntry.network(tx)` there and ship `(tx, entry)` to main. `NetworkTransaction` and `LogEntry` are Sendable value types; nothing on main needs to change except accepting the prebuilt entry.

### 6.2 Body memory budget **[Medium] (easy)**

`ProxyServer.maxStoredBody = 4 MB` × `NetworkStore.maxTransactions = 10_000` is a theoretical 40 GB; realistically a session that pulls a few hundred images/videos through the proxy keeps hundreds of MB resident, and `NetworkStore.transactions` holds them for the whole session. On top of that, each network `LogEntry` stores the pretty-printed bodies **twice** — once in `network.requestBody/responseBody` and again inside `message` (for search).

**Fixes:**
- Don't retain bodies for non-text content types (`image/*`, `video/*`, `audio/*`, `application/octet-stream`, fonts): keep the first 512 B for sniffing and the size. Decide from the response `Content-Type` in `.head`, before the `.body` chunks arrive.
- A global body budget (e.g. 256 MB) with oldest-first eviction, independent of the transaction count.
- Drop the body duplication in `message`: with a stored `searchKey` (1.4) search can include the bodies without keeping a second copy for display.

### 6.3 `.updated` per response head/end **[Small]**

Emitting the full struct is fine — `Data` and arrays are refcounted, so it's a shallow copy. No action.

---

## 7. App usage: idle CPU and energy

### 7.1 Discovery polling spawns processes every 8 s forever **[Medium] (easy)**

`EventStore.startSourcePolling` runs `xcrun simctl list devices -j` **and** `xcrun devicectl list devices` (which can take seconds and talks to `CoreDevice`) every 8 s while not capturing, for the lifetime of the app — even in the background, even when the window is hidden. That's constant idle CPU, process churn, and energy.

**Fix (pick one or combine):**
- Only poll while the window is key / the app is active (`NSApplication.didBecomeActiveNotification` / `didResignActive`), and immediately on `didBecomeActive`.
- Refresh when the Source menu opens (that's when the list matters) plus a slow 60 s heartbeat.
- Watch `~/Library/Developer/CoreSimulator/Devices` with `DispatchSource.makeFileSystemObjectSource` — a simulator boot touches it — and skip `devicectl` entirely until physical devices are supported (they aren't; `LogSource.isSupported` says so).

### 7.2 Continuous symbol effects **[Small]**

`IncomingIndicator`'s `.symbolEffect(.variableColor…, options: .repeating)` and `EmptyStateView`'s `.symbolEffect(.variableColor.iterative, isActive: isCapturing)` are CoreAnimation-driven and cheap, but they do keep the display awake at 60 Hz while recording. Fine to keep; just know they're there if you're chasing the last few % in Activity Monitor.

### 7.3 `log stream` itself

The dominant *system* cost while recording is `logd` + `log stream` filtering, not LogLens. The `--predicate` already narrows at the source; keep the "apps only" default. Nothing to change in-app.

---

## 8. Measure first — how to verify each item

Nothing above has been profiled in the app yet; these are code-reading findings. Before implementing, get numbers so you can rank them for real and prove the wins:

1. **A replay harness (30 min, highest leverage).** Add `--replay <file.ndjson> [--rate N]`: `LogStreamer` reads from the file at N lines/s instead of spawning `log`. Capture one real Over session to a file once (`log stream … --style ndjson > session.ndjson`). Every measurement below becomes reproducible, and it doubles as a soak test.
2. **Signposts** (`os_signpost` / `OSSignposter`) around `EventStore.append`, `trimIfNeeded`, `refilter`, `LogEntry.network`, `TimelineFeed.revealNext`, and `LogStreamer.flush`. Instruments' *Points of Interest* lane then shows exactly what each batch costs.
3. **Instruments templates:** *SwiftUI* (View Body counts per view — confirms 2.5/4.3/5.1), *Time Profiler* on main (confirms 2.1/2.3/6.1), *Animation Hitches* while the timeline is springing, *Allocations* for 1.5/6.2.
4. **Quick ad-hoc:** `sample <pid> 5` (what caught the 1.3.0 regressions), `top -l 3 -s 2 -pid` for idle CPU (7.1), Activity Monitor → Energy.
5. **Targets to hit:** ≤ 50 ms from `log` emitting a line to the card being on screen at 100 ev/s; zero dropped events at 1 000 ev/s in table mode; main thread < 30 % busy at 1 000 ev/s with a full 100 k buffer; 0 hitches > 8 ms in Animation Hitches during a 60 s replay; idle CPU ≈ 0 % with the window in the background.

---

## 9. Suggested order

Each step is independently shippable and testable with the replay harness.

1. **Harness + signposts** (§8) — half a day, pays for everything else.
2. **Store hygiene** — hysteresis trim (2.1A), stored `selectedEntry` (2.3), `hasEntries`/`hasFiltered` (2.5), `backlog` change guard, `TimelineScroll` indicator split (4.3), sidebar throttle (5.1). All small, all main-thread wins.
3. **Timeline instant reveal** (4.1) + flat cards (4.2) + per-card deps (4.4). This is where "appears instantly" and "silky" are felt most.
4. **Parse-queue precompute** (1.4, 1.5, 1.2, 1.3, 1.1) — `searchKey`, `timeText`, interning, fast date, leading-edge flush.
5. **Off-main filtering with debounce and incremental narrowing** (2.4).
6. **Network entry built off-main + body budget** (6.1, 6.2).
7. **`NSTableView` representable** (3.1) — the largest change; do it last, once the store is lean, so the table is the only remaining variable.
8. **Idle polling** (7.1) — whenever; it's about battery, not smoothness.
9. `Deque` + ID-indexed lookup (2.1B) — optional after step 2; nice-to-have once the hysteresis trim has removed the urgency.

## Appendix — things checked and found fine

- `ProcessLookup` runs off the NIO event loop (`resolveOwner` → global queue) — good.
- Response body chunks don't emit `.updated` — only head/end do.
- `TimelineRow.==` ignoring the closure, `defaultScrollAnchor(.bottom)` instead of `scrollTo`, `fileExporter` document built lazily, `JSONHighlighter` `NSCache` — the 1.3.1 fixes hold up.
- `LogEntry` `==`/`hash` by `id` only — cheap diffing where diffing still happens.
- Release builds go through `xcodebuild -configuration Release` (`-O`, WMO) — no debug-build perf illusions in shipped DMGs.

---

## Status (2026-08-28, implemented on top of v1.3.1)

Everything in the tables above landed, plus one item the profiler found once the rest was in (§S.3). Not done: `Deque` (2.1B — the hysteresis trim removed the need), `NSTextView` for very long bodies (4.6), and the fast-path `CharacterSet` tweaks in `MessageParser` (1.6).

### What changed, by file

| Area | Change |
|------|--------|
| `Support/Perf.swift` (new) | `OSSignposter` intervals: `store.append`, `store.trim`, `store.refilter.*`, `store.facets`, `timeline.reveal`, `table.append`/`table.reload`, `proxy.entry`. Instruments → Points of Interest. |
| `Capture/LogStreamer.swift` | `--replay <file.ndjson> [--rate N] [--replay-loop]` harness (feeds a captured file through the real parse path, no `log` process). Leading-edge flush (16 ms after the first line of a batch, 100 ms timer as fallback). Cursor-based line splitting. Hand-parsed timestamps (~0.13 µs vs 26 µs for `DateFormatter`; also more precise — µs instead of ms). String interning for process/subsystem/category/paths. `searchKey` + `timeText` precomputed per entry. |
| `Models/LogEntry.swift` | `searchKey` (lower-cased haystack) and `timeText` stored; excluded from `Codable` so exports don't change. |
| `Models/ParsedMessage.swift`, `Parsing/MessageParser.swift` | `eventType`/`eid` resolved once at parse time. |
| `Store/EventStore.swift` | Hysteresis trim (10 % slack, id-set based so mixed network ids trim correctly). Stored `selectedEntry`. `hasEntries`/`hasFiltered` flags. `filteredRevision` (append vs. reload signal for the table). Facet snapshot published ≤ 4 Hz. Off-main filtering above 20 k entries with generation tokens + incremental narrowing while typing. Lane seeds via backwards scan. Discovery polling only while active, no `devicectl` in periodic refreshes. Async export. |
| `Store/TimelineFeed.swift` | Reveals everything queued per 100 ms tick; nothing dropped (only what's past the visible cap). Spring for groups ≤ 10 cards, instant above. Head trimmed in chunks. `backlog` only assigned on change. |
| `Views/Table/EventTableView.swift` | `NSTableView` representable: `noteNumberOfRowsChanged` per batch, `reloadData` on trim/refilter keeping the row under the top edge in place, reused `NSTextField` cells, custom level-dot view, `NSMenu` context menu, column widths autosaved. Rows are read from the store on demand — holding the array in the view struct made every append a 100 k-element copy. |
| `Views/Timeline/*` | Flat cards (no shadow). `isStarred` passed in. `IncomingIndicator` reads the feed itself. `timeText` instead of `DateFormatter`. |
| `Views/Components/JSONText.swift` | Line split cached with the highlighted text. |
| `Views/Sidebar/SidebarView.swift` | Renders the pre-sorted facet snapshot. |
| `Views/ContentView.swift` | Search debounced 120 ms; export encoded off-main before the panel opens; `hasEntries` for the toolbar. |
| `Network/ProxyServer.swift`, `Store/NetworkStore.swift`, `Models/NetworkLogEntry.swift` | The timeline/table entry for a finished transaction is built on a serial `entryQueue` (inflate + pretty-print) and handed to main with the event. Binary bodies (image/video/audio/font/octet-stream…) keep only a 512 B prefix. 256 MB body budget with oldest-first eviction. Transaction buffer trims with hysteresis. Bodies no longer duplicated into `message` (they're in `searchKey` for search and on the card for display). |

### Measured (Debug builds, same machine, same replay file, `top` over 6 s)

| Scenario | v1.3.1 | After | Notes |
|----------|--------|-------|-------|
| List, 2 000 ev/s, 60 k file | 40 % CPU, **1 045 MB** | 24 % CPU, **288 MB** | whole process incl. parse queue |
| List, 6 000 ev/s, 250 k file, buffer full (100 k) and trimming | 33 % CPU, **2 279 MB** | 35 % CPU, **659 MB** | old build was lagging behind the feed; new one finished the file 5 s earlier |
| Timeline, 200 ev/s | 18 % CPU (dropping most events via skip-ahead) | 12 % CPU, **every event shown** | |
| Timeline, 2 000 ev/s flood | — | 18 % CPU, stays live | |
| Timeline, 30 ev/s | — | 13 % CPU | continuous spring animation |
| Idle in background | `simctl` + `devicectl` spawned every 8 s | 0 % | |

Latency: an event now reaches the screen within one batch (≤ 16 ms coalesce + one 100 ms reveal tick in the timeline) instead of 100 ms + 350 ms × queue position.

### How to reproduce

```
python3 <scratchpad>/gen.py 60000 synthetic.ndjson        # or capture: xcrun simctl spawn booted log stream --style ndjson --level debug --type log > session.ndjson
open -n build/Build/Products/Debug/LogLens.app --args --replay synthetic.ndjson --rate 2000 --record
top -l 3 -s 2 -pid $(pgrep -n -x LogLens) -stats pid,cpu,mem
sample $(pgrep -n -x LogLens) 3 -file sample.txt          # main thread is the first thread in the file
```

import SwiftUI

/// Animated vertical timeline: new events slide in from the bottom at the pace
/// set by `TimelineFeed`, linked by a thin connector line. Shows either the
/// single global feed or up to four side-by-side lanes with their own facets.
struct EventTimelineView: View {
    @Environment(EventStore.self) private var store

    var body: some View {
        Group {
            if store.entries.isEmpty {
                EmptyStateView()
            } else if store.lanes.isEmpty {
                if store.filtered.isEmpty {
                    ContentUnavailableView.search(text: store.filter.searchText)
                } else {
                    TimelineScroll(feed: store.timeline, horizontalPadding: 24)
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(store.lanes) { lane in
                        VStack(spacing: 0) {
                            LaneHeader(lane: lane)
                            Divider()
                            TimelineScroll(feed: lane.feed, horizontalPadding: 12)
                        }
                        if lane.id != store.lanes.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct LaneHeader: View {
    @Environment(EventStore.self) private var store
    let lane: TimelineLane

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.caption)
            Text(lane.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                store.removeLane(lane)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close this lane")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// One scrolling timeline column over a feed.
struct TimelineScroll: View {
    @Environment(EventStore.self) private var store
    let feed: TimelineFeed
    var horizontalPadding: CGFloat = 24

    /// Cards the user has toggled away from the default expansion state.
    @State private var toggledIDs: Set<Int> = []

    private static let incomingID = "incoming-indicator"

    /// While capturing, follow the incoming stub so the pulse stays in view;
    /// otherwise pin to the newest card.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        if store.isCapturing {
            proxy.scrollTo(Self.incomingID, anchor: .bottom)
        } else if let last = feed.visible.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(feed.visible) { item in
                        TimelineRow(
                            item: item,
                            isFirst: item.id == feed.visible.first?.id,
                            isExpanded: store.timelineExpandAll != toggledIDs.contains(item.id),
                            toggle: {
                                withAnimation(.snappy(duration: 0.2)) {
                                    toggledIDs.toggleMembership(item.id)
                                }
                            }
                        )
                        .equatable()
                        .id(item.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.96, anchor: .bottom)),
                            removal: .opacity
                        ))
                    }
                    if store.isCapturing {
                        IncomingIndicator(pending: feed.pendingCount)
                            .id(Self.incomingID)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 24)
            }
            // Pinned to the newest event. While auto-scroll is on the scroll view itself keeps the bottom anchored as
            // content grows, which is far cheaper than a `scrollTo` per reveal (that forced a full layout of every card).
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(store.autoScroll ? .bottom : nil, for: .sizeChanges)
            .overlay {
                if feed.visible.isEmpty, !store.isCapturing {
                    Text("No matching events")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            // Track the last id, not the count: once `visible` hits its cap the
            // count stops changing while events keep flowing.
            // Same spring as TimelineFeed.revealNext, so the stack glides up in
            // sync with the new card sliding in.
            .onChange(of: store.autoScroll) { _, on in
                guard on, feed.visible.last != nil else { return }
                scrollToNewest(proxy)
            }
            // Flipping the default gives a clean all-expanded/all-collapsed slate.
            .onChange(of: store.timelineExpandAll) { _, _ in
                withAnimation(.snappy(duration: 0.25)) { toggledIDs.removeAll() }
            }
        }
    }
}

/// The tail of the connector line: a breathing pulse hinting that the next
/// event will be born here, with a count when the feed is catching up.
private struct IncomingIndicator: View {
    let pending: Int

    var body: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(LinearGradient(colors: [Color.secondary.opacity(0.35), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1, height: 26)
            Image(systemName: "ellipsis")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers.reversing,
                              options: .repeating)
            if pending > 5 {
                Text("+\(pending) incoming")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: pending)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 0)
        .help(pending > 0 ? "\(pending) events waiting to animate in" : "Listening for events")
    }
}

private extension Set where Element == Int {
    mutating func toggleMembership(_ member: Int) {
        if contains(member) { remove(member) } else { insert(member) }
    }
}

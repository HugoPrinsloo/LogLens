import SwiftUI

/// Animated vertical timeline: new events slide in from the bottom at the pace
/// set by `TimelineFeed`, linked by a thin connector line.
struct EventTimelineView: View {
    @Environment(EventStore.self) private var store
    /// Cards the user has toggled away from the default expansion state.
    @State private var toggledIDs: Set<Int> = []

    private static let incomingID = "incoming-indicator"

    /// While capturing, follow the incoming stub so the pulse stays in view;
    /// otherwise pin to the newest card.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        if store.isCapturing {
            proxy.scrollTo(Self.incomingID, anchor: .bottom)
        } else if let last = store.timeline.visible.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                EmptyStateView()
            } else if store.filtered.isEmpty {
                ContentUnavailableView.search(text: store.filter.searchText)
            } else {
                timeline
            }
        }
    }

    private var timeline: some View {
        let feed = store.timeline
        return ScrollViewReader { proxy in
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
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            // Start pinned to the newest event (the seed never fires onChange).
            .defaultScrollAnchor(.bottom)
            // Track the last id, not the count: once `visible` hits its cap the
            // count stops changing while events keep flowing.
            // Same spring as TimelineFeed.revealNext, so the stack glides up in
            // sync with the new card sliding in.
            .onChange(of: feed.visible.last?.id) { _, _ in
                guard store.autoScroll, feed.visible.last != nil else { return }
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    scrollToNewest(proxy)
                }
            }
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

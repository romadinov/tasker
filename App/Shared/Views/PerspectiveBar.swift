import SwiftUI
import TaskerCore

struct BarItem: Identifiable, Hashable {
    let item: SidebarItem
    let title: String
    let icon: String
    let count: Int
    let alert: Bool
    var id: String {
        if case .perspective(let p) = item { return "p-\(p)" }
        return "b-\(item.title)"
    }
}

extension AppModel {
    /// Available actions tagged with a location that applies here and now.
    var nearbyCount: Int {
        let here = NearbyModel.shared.hereTagIDs
        guard !here.isEmpty else { return 0 }
        return Set(here.flatMap { snapshot.tasksByTag[$0] ?? [] }).filter { snapshot.info[$0]?.isAvailable == true }.count
    }

    /// Built-in perspectives first, then custom ones, in sidebar order.
    var barItems: [BarItem] {
        var out: [BarItem] = [
            BarItem(item: .inbox, title: "Inbox", icon: SidebarItem.inbox.icon, count: inboxCount, alert: false),
            BarItem(item: .projects, title: "Projects", icon: SidebarItem.projects.icon, count: 0, alert: false),
            BarItem(item: .tags, title: "Tags", icon: SidebarItem.tags.icon, count: 0, alert: false),
            BarItem(item: .forecast, title: "Forecast", icon: SidebarItem.forecast.icon, count: dueSoonCount, alert: true),
            BarItem(item: .flagged, title: "Flagged", icon: SidebarItem.flagged.icon, count: flaggedCount, alert: false),
            BarItem(item: .review, title: "Review", icon: SidebarItem.review.icon, count: reviewCount, alert: false),
            BarItem(item: .nearby, title: "Nearby", icon: SidebarItem.nearby.icon, count: nearbyCount, alert: false),
            BarItem(item: .analytics, title: "Analytics", icon: SidebarItem.analytics.icon, count: 0, alert: false),
        ]
        out += snapshot.perspectives.map { BarItem(item: .perspective($0.id), title: $0.name, icon: $0.icon, count: 0, alert: false) }
        return out
    }
}

/// One perspective button: icon with label underneath.
struct PerspectiveButton: View {
    @Environment(AppModel.self) private var model
    let bar: BarItem
    var compact = false

    var body: some View {
        let selected = model.sidebar == bar.item
        Button { model.sidebar = bar.item } label: {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Image(systemName: bar.icon)
                        .font(.system(size: compact ? 17 : 15, weight: .medium))
                        .symbolVariant(selected ? .fill : .none)
                    if bar.count > 0 {
                        Text("\(min(bar.count, 999))")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 3).padding(.vertical, 0.5)
                            .background(Capsule().fill(bar.alert ? Palette.dueSoon : Color.secondary.opacity(0.25)))
                            .foregroundStyle(bar.alert ? Color.white : Color.primary)
                            .fixedSize()
                    }
                }
                Text(bar.title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .frame(maxWidth: compact ? 72 : 80)
            }
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(bar.title)
    }
}

/// iPhone/iPad: horizontally scrolling perspective strip above the list.
struct PerspectiveStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.barItems) { bar in
                        PerspectiveButton(bar: bar, compact: true).id(bar.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onAppear {
                if let current = model.barItems.first(where: { $0.item == model.sidebar }) { proxy.scrollTo(current.id, anchor: .center) }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Mac: one window-toolbar item per perspective, so a narrow window overflows into the » menu.
struct PerspectiveToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ToolbarActionButton(title: "New Action", icon: "plus.circle.fill") { model.newTask() }
                .help("New Action (⌘N)")
            ToolbarActionButton(title: "Clean Up", icon: "wand.and.sparkles") { model.cleanUp() }
                .help("Clean Up (⌘K): hide completed items and items filed out of the Inbox")
            Divider().frame(height: 28)
            ForEach(model.barItems) { bar in PerspectiveButton(bar: bar) }
        }
    }
}

struct ToolbarActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

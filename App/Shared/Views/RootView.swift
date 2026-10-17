import SwiftUI
import TaskerCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var columns = NavigationSplitViewVisibility.all

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    var isCompact: Bool { sizeClass == .compact }
    #else
    let isCompact = false
    #endif
    @State private var twoColumns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        Group {
            if isCompact { compactLayout } else { omniLayout }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.becameActive() } }
        .sheet(item: Binding(get: { model.moveTargetFor.map(MoveRequest.init) }, set: { model.moveTargetFor = $0?.ids })) { req in
            MoveSheet(ids: req.ids)
        }
        .sheet(item: $model.editingPerspective) { p in
            PerspectiveEditor(perspective: p)
        }
        .sheet(isPresented: $model.showSyncStatus) {
            NavigationStack { SyncStatusView() }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 520)
                #endif
        }
        #if os(iOS)
        .sheet(isPresented: $model.showQuickEntry) {
            NavigationStack { QuickEntryForm(capture: model.quickEntryCapture, onDone: { model.showQuickEntry = false }) }
        }
        #endif
        .alert("Database problem", isPresented: Binding(get: { model.openError != nil }, set: { if !$0 { model.openError = nil } })) {
            Button("OK") { model.openError = nil }
        } message: { Text(model.openError ?? "") }
    }
}

extension RootView {
    /// iPhone: sidebar list → list → details, as before.
    var compactLayout: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
        } content: {
            ContentColumn()
        } detail: {
            InspectorColumn()
        }
    }

    /// Mac & iPad: perspective rail | perspective sidebar | main | inspector, like OmniFocus.
    var omniLayout: some View {
        @Bindable var model = model
        return HStack(spacing: 0) {
            PerspectiveRail()
            Divider()
            Group {
                #if os(macOS)
                // Mac: the perspective sidebar is a plain column shown only when it has content.
                // (NavigationSplitView doesn't reliably hide its sidebar, and swapping containers
                // re-creates toolbar items, which trips an NSToolbar race.)
                HStack(spacing: 0) {
                    if (model.sidebar ?? .inbox).hasSidebarContent && model.showSidebar {
                        PerspectiveSidebar()
                            .frame(width: model.sidebarWidth)
                            .background(.background.secondary)
                        SidebarResizeHandle()
                    }
                    NavigationStack { ContentColumn() }
                }
                #else
                if (model.sidebar ?? .inbox).hasSidebarContent {
                    NavigationSplitView(columnVisibility: $twoColumns) {
                        PerspectiveSidebar()
                            .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 400)
                    } detail: {
                        ContentColumn()
                    }
                } else {
                    // iPad: no empty sidebar drawer for Inbox, Flagged, custom perspectives.
                    NavigationStack { ContentColumn() }
                }
                #endif
            }
            .inspector(isPresented: $model.showInspector) {
                InspectorColumn()
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
            }
        }
        #if os(macOS)
        .toolbar(id: "main") { OmniToolbarCustomizable(model: model) }
        .background(ToolbarLabelsOn())
        #endif
    }

    /// The sidebar column only appears for perspectives that have something to put in it.
    func syncColumns() {
        #if os(macOS)
        let want: NavigationSplitViewVisibility = (model.sidebar ?? .inbox).hasSidebarContent ? .all : .detailOnly
        #else
        let want = NavigationSplitViewVisibility.all
        #endif
        if twoColumns != want { DispatchQueue.main.async { twoColumns = want } }
    }
}

struct MoveRequest: Identifiable {
    let ids: [String]
    var id: String { ids.joined(separator: ",") }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Section {
                row(.inbox, count: model.inboxCount)
                row(.projects)
                row(.tags)
                row(.forecast, count: model.dueSoonCount, alert: true)
                row(.flagged, count: model.flaggedCount)
                row(.review, count: model.reviewCount)
                row(.nearby, count: model.nearbyCount)
            }
            Section("Perspectives") {
                ForEach(model.snapshot.perspectives) { p in
                    Label(p.name, systemImage: p.icon)
                        .tag(SidebarItem.perspective(p.id))
                        .contextMenu {
                            Button("Edit Perspective…") { model.editingPerspective = p }
                            Button("Duplicate") {
                                var copy = p; copy.id = IDs.make(); copy.name += " copy"
                                model.perform("Duplicate Perspective") { $0.createPerspective(copy) }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                model.perform("Delete Perspective") { $0.set(.perspective, p.id, F.deleted, true) }
                                if model.sidebar == .perspective(p.id) { model.sidebar = .inbox }
                            }
                        }
                }
                Button {
                    var p = Perspective(id: IDs.make())
                    p.name = "New Perspective"
                    p.rules = [.object(["actionAvailability": "available"])]
                    model.editingPerspective = p
                } label: {
                    Label("New Perspective", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Tasker")
        .safeAreaInset(edge: .bottom) { SyncBadge().padding(8) }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
        #endif
    }

    private func row(_ item: SidebarItem, count: Int = 0, alert: Bool = false) -> some View {
        Label(item.title, systemImage: item.icon)
            .badge(count > 0 ? Text("\(count)").foregroundStyle(alert ? Palette.dueSoon : .secondary) : nil)
            .tag(item)
    }
}

struct SyncBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.syncStatus
        Button { model.showSyncStatus = true } label: {
            HStack(spacing: 6) {
                Image(systemName: icon(s)).foregroundStyle(color(s))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title(s)).font(.caption)
                    if let f = s.lastFetch {
                        Text("Checked \(f.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if s.pendingUpload > 0 { Text("\(s.pendingUpload)↑").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    func icon(_ s: SyncStatus) -> String {
        switch s.phase {
        case .noAccount: "icloud.slash"
        case .error: "exclamationmark.icloud"
        case .fetching, .sending, .starting: "arrow.triangle.2.circlepath.icloud"
        case .idle: s.missingChanges > 0 ? "icloud.and.arrow.down" : "checkmark.icloud"
        }
    }
    func color(_ s: SyncStatus) -> Color {
        switch s.phase {
        case .noAccount, .error: .red
        case .idle: s.missingChanges > 0 ? .orange : .green
        default: .secondary
        }
    }
    func title(_ s: SyncStatus) -> String {
        switch s.phase {
        case .starting: "Connecting to iCloud…"
        case .fetching: "Receiving…"
        case .sending: "Sending…"
        case .noAccount: "iCloud unavailable"
        case .error(let e): e
        case .idle: s.missingChanges > 0 ? "Waiting for \(s.missingChanges) changes" : "Synced"
        }
    }
}

/// OmniFocus toolbar: Back/Forward and View · New Action, Quick Entry, Focus · Search, Clean Up, Inspect.
struct OmniToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        items
    }

    @ToolbarContentBuilder
    var items: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            #if os(macOS)
            Button { model.showSidebar.toggle() } label: { Label("Sidebar", systemImage: "sidebar.left") }
                .help("Show or hide the sidebar (⌃⌘S)")
            #endif
            ControlGroup {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack)
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!model.canGoForward)
            } label: { Label("Back/Forward", systemImage: "chevron.left") }
            .help("Back / Forward (⌥⌘[ ⌥⌘])")
            Menu {
                Picker("Show", selection: model.sidebar == .tags ? $model.tagFilter : $model.filter) {
                    ForEach(ItemFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Label("View", systemImage: "eye") }
            .help("View options")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.newTask() } label: { Label("New Action", systemImage: "plus") }
                .help("New Action (⌘N)")
            #if os(macOS)
            Button { QuickEntryController.shared.show() } label: { Label("Quick Entry", systemImage: "tray.and.arrow.down") }
                .help("Quick Entry (⌃⌥Space)")
            #else
            Button { model.presentQuickEntry() } label: { Label("Quick Entry", systemImage: "tray.and.arrow.down") }
            #endif
            Button { model.toggleFocus() } label: {
                Label(model.focusIDs.isEmpty ? "Focus" : "Unfocus", systemImage: model.focusIDs.isEmpty ? "scope" : "xmark.circle")
            }
            .disabled(!model.canFocus)
            .help("Focus on the selected projects or folders (⇧⌘F)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if case .perspective(let id) = model.sidebar, let p = model.snapshot.perspectives.first(where: { $0.id == id }) {
                Button { model.editingPerspective = p } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    .help("Edit Perspective")
            }
            Button { model.cleanUp() } label: { Label("Clean Up", systemImage: "wand.and.sparkles") }
                .help("Clean Up (⌘K)")
            Button { model.showInspector.toggle() } label: { Label("Inspect", systemImage: "info.circle") }
                .help("Inspector (⌥⌘I)")
        }
    }
}

/// Icon with its title underneath, drawn inside the button. (Changing NSToolbar's display mode
/// directly crashes SwiftUI's toolbar updates, so labels are part of the item instead.)
struct IconAboveTitle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        VStack(spacing: 1) {
            configuration.icon.font(.system(size: 14, weight: .regular))
            configuration.title.font(.system(size: 10))
        }
        .frame(minWidth: 44)
        #else
        Label { configuration.title } icon: { configuration.icon }
        #endif
    }
}

#if os(macOS)
/// Drag to resize the perspective sidebar.
struct SidebarResizeHandle: View {
    @Environment(AppModel.self) private var model
    @State private var start: CGFloat?
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if start == nil { start = model.sidebarWidth }
                        model.sidebarWidth = min(max((start ?? 260) + v.translation.width, 180), 480)
                    }
                    .onEnded { _ in start = nil }))
    }
}

/// Native "Icon and Text" toolbar, like OmniFocus. Set once when the window appears; with no
/// container swaps underneath, SwiftUI's toolbar updates are stable.
struct ToolbarLabelsOn: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let tb = v.window?.toolbar, tb.displayMode != .iconAndLabel else { return }
            tb.displayMode = .iconAndLabel
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Same items as OmniToolbar, as a customizable toolbar (right-click → Customize Toolbar…).
struct OmniToolbarCustomizable: CustomizableToolbarContent {
    @Bindable var model: AppModel

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "sidebar", placement: .navigation) {
            Button { model.showSidebar.toggle() } label: { Label("Sidebar", systemImage: "sidebar.left") }
                .help("Show or hide the sidebar")
        }
        ToolbarItem(id: "back", placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }.disabled(!model.canGoBack)
        }
        ToolbarItem(id: "forward", placement: .navigation) {
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }.disabled(!model.canGoForward)
        }
        ToolbarItem(id: "view", placement: .navigation) {
            Menu {
                Picker("Show", selection: model.sidebar == .tags ? $model.tagFilter : $model.filter) {
                    ForEach(ItemFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Label("View", systemImage: "eye") }
        }
        ToolbarItem(id: "newAction", placement: .primaryAction) {
            Button { model.newTask() } label: { Label("New Action", systemImage: "plus") }.help("New Action (⌘N)")
        }
        ToolbarItem(id: "quickEntry", placement: .primaryAction) {
            Button { QuickEntryController.shared.show() } label: { Label("Quick Entry", systemImage: "tray.and.arrow.down") }
                .help("Quick Entry (⌃⌥Space)")
        }
        ToolbarItem(id: "focus", placement: .primaryAction) {
            Button { model.toggleFocus() } label: {
                Label(model.focusIDs.isEmpty ? "Focus" : "Unfocus", systemImage: model.focusIDs.isEmpty ? "scope" : "xmark.circle")
            }
            .disabled(!model.canFocus)
        }
        ToolbarItem(id: "editPerspective", placement: .primaryAction) {
            Button {
                if case .perspective(let id) = model.sidebar { model.editingPerspective = model.snapshot.perspectives.first { $0.id == id } }
            } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            .disabled({ if case .perspective = model.sidebar { return false }; return true }())
            .help("Edit Perspective")
        }
        ToolbarItem(id: "cleanUp", placement: .primaryAction) {
            Button { model.cleanUp() } label: { Label("Clean Up", systemImage: "wand.and.sparkles") }.help("Clean Up (⌘K)")
        }
        ToolbarItem(id: "inspect", placement: .primaryAction) {
            Button { model.showInspector.toggle() } label: { Label("Inspect", systemImage: "info.circle") }.help("Inspector (⌥⌘I)")
        }
    }
}
#endif

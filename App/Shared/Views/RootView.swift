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
                if (model.sidebar ?? .inbox).hasSidebarContent {
                    NavigationSplitView(columnVisibility: $twoColumns) {
                        PerspectiveSidebar()
                            .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 400)
                    } detail: {
                        ContentColumn()
                    }
                } else {
                    // No sidebar content (Inbox, Flagged, custom perspectives): no empty column or drawer.
                    NavigationStack { ContentColumn() }
                }
            }
            .inspector(isPresented: $model.showInspector) {
                InspectorColumn()
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
            }
        }
        #if os(macOS)
        .toolbar { OmniToolbar(model: model) }
        .background(ToolbarLabelsOn())
        #endif
    }

    /// The sidebar column only appears for perspectives that have something to put in it.
    func syncColumns() {
        if twoColumns != .all { twoColumns = .all }
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
        ToolbarItemGroup(placement: .navigation) {
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
            Button { model.cleanUp() } label: { Label("Clean Up", systemImage: "wand.and.sparkles") }
                .help("Clean Up (⌘K)")
            Button { model.showInspector.toggle() } label: { Label("Inspect", systemImage: "info.circle") }
                .help("Inspector (⌥⌘I)")
        }
    }
}

#if os(macOS)
/// Shows labels under toolbar icons, as OmniFocus does (SwiftUI has no API for the display mode).
struct ToolbarLabelsOn: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.toolbar?.displayMode = .iconAndLabel }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { v.window?.toolbar?.displayMode = .iconAndLabel }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

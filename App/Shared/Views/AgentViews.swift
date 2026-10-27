import SwiftUI
import TaskerCore

/// Agent tags: a tag linked to an app built with agents. Its actions are that agent's improvement tasks
/// (listed by `feedback.swift notes <app>` and the uberdoer-mcp `agent_tasks` tool); the agent completes them
/// when done. Developer builds only (DeveloperBuild).
extension AppModel {
    func agentName(_ id: String) -> String { snapshot.agentApps.first { $0.id == id }?.name ?? id }

    func setAgent(_ tagID: String, _ agent: String?) {
        perform(agent == nil ? "Unlink Agent" : "Link Agent") { $0.setTagAgent(tagID, agent) }
    }

    /// A new tag under "Agents" linked to `app` (reuses an existing tag for it).
    func newAgentTag(_ app: AgentApp) {
        if let existing = snapshot.tags.values.first(where: { $0.agent == app.id }) { tagFocus = [existing.id]; return }
        var id = ""
        perform("New Agent Tag") { tx in
            if tx.base.tags[Agents.parentTagID] == nil { tx.createTag("Agents", id: Agents.parentTagID) }
            id = tx.createTag(Agents.tagName(app), parent: Agents.parentTagID)
            tx.setTagAgent(id, app.id)
        }
        tagFocus = [id]
    }

    #if os(macOS)
    /// Mirrors ~/Dev/agent-feedback/apps.json into the synced agent list and creates a tag for each new agent.
    /// Not undoable: it's housekeeping, not an edit.
    func syncAgentRegistry() {
        guard DeveloperBuild.isDeveloper, ProcessInfo.processInfo.environment["TASKER_DEMO_DIR"] == nil else { return }
        let url = URL(fileURLWithPath: NSString(string: "~/Dev/agent-feedback/apps.json").expandingTildeInPath)
        guard let apps = Agents.registry(at: url), !apps.isEmpty else { return }
        guard store.transact("Agents", { $0.syncAgents(apps) }) != nil else { return }
        reloadSnapshot()
        sync?.localChangesCommitted()
    }
    #endif
}

struct AgentMenuItems: View {
    @Environment(AppModel.self) private var model
    let tag: Tag
    var body: some View {
        Button { model.setAgent(tag.id, nil) } label: { check("None", tag.agent == nil) }
        ForEach(model.snapshot.agentApps) { app in
            Button { model.setAgent(tag.id, app.id) } label: { check(app.name, tag.agent == app.id) }
        }
    }
    @ViewBuilder func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

struct AgentPicker: View {
    @Environment(AppModel.self) private var model
    let tag: Tag
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Agent", selection: Binding(get: { tag.agent ?? "" }, set: { model.setAgent(tag.id, $0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(model.snapshot.agentApps) { Text($0.name).tag($0.id) }
                if let a = tag.agent, !model.snapshot.agentApps.contains(where: { $0.id == a }) { Text(a).tag(a) }
            }
            .labelsHidden()
            Text(tag.agent == nil
                 ? "Link to an agent to send this tag's actions to its improvement queue."
                 : "Actions with this tag go to \(model.agentName(tag.agent!))'s improvement queue; the agent completes them when done.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

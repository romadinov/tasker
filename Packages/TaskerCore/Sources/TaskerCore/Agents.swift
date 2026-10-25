import Foundation

/// An app built with agents, from the shared feedback registry (~/Dev/agent-feedback/apps.json). The Mac app
/// copies the list into the synced setting `agents`, so iPhone and iPad offer the same agents.
public struct AgentApp: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum Agents {
    public static let settingKey = "agents"
    /// Parent tag of the agent tags. Deterministic ids, so two devices creating them at once merge.
    public static let parentTagID = "agents"
    public static func tagID(_ agent: String) -> String { "agent-" + agent }
    /// "Jinnie agent", not "Jinnie": companion apps already use tags named after themselves (Jinnie's synced
    /// tasks carry "Jinnie"), and lookups by name must never land on the agent tag.
    public static func tagName(_ app: AgentApp) -> String { app.name + " agent" }

    /// Reads the registry file (Mac). nil if it isn't there.
    public static func registry(at url: URL) -> [AgentApp]? {
        struct File: Decodable { var apps: [AgentApp] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(File.self, from: data))?.apps
    }
}

extension Snapshot {
    /// Known agents (from the synced setting).
    public var agentApps: [AgentApp] { setting(Agents.settingKey)?.decode([AgentApp].self) ?? [] }

    /// Remaining actions tagged with a tag linked to `agent` (or a tag nested under one).
    public func agentTasks(_ agent: String) -> [TaskItem] {
        let agentTags = Set(tags.values.filter { tag in
            var cur: Tag? = tag
            var seen = Set<String>()
            while let t = cur, seen.insert(t.id).inserted {
                if t.agent == agent { return true }
                cur = t.position.parent.flatMap { tags[$0] }
            }
            return false
        }.map(\.id))
        var ids = Set<String>()
        for tag in agentTags { ids.formUnion(tasksByTag[tag] ?? []) }
        return ids.compactMap { tasks[$0] }
            .filter { !$0.isProject && info[$0.id]?.isRemaining == true }
            .sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
    }
}

extension Tx {
    public mutating func setTagAgent(_ tagID: String, _ agent: String?) {
        set(.tag, tagID, F.agent, agent.map(JSON.string) ?? .null)
    }

    /// Records the registry and creates an "Agents : <Name>" tag for each agent seen for the first time
    /// (a tag the user later deletes or renames stays that way).
    public mutating func syncAgents(_ apps: [AgentApp]) {
        let known = Set(base.agentApps.map(\.id))
        let new = apps.filter { !known.contains($0.id) }
        if !new.isEmpty {
            if base.tags[Agents.parentTagID] == nil { createTag("Agents", id: Agents.parentTagID) }
            for app in new where base.tags[Agents.tagID(app.id)] == nil {
                createTag(Agents.tagName(app), parent: Agents.parentTagID, id: Agents.tagID(app.id))
                setTagAgent(Agents.tagID(app.id), app.id)
            }
        }
        let merged = base.agentApps.filter { a in !apps.contains { $0.id == a.id } } + apps
        if merged != base.agentApps { setSetting(Agents.settingKey, JSON(encoding: merged)) }
    }
}

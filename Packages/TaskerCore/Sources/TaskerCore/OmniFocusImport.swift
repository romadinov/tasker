import Foundation

/// Imports an OmniFocus database. The export runs inside OmniFocus via Omni Automation
/// (`evaluate javascript`), which reads the live, decrypted database with exact ids, so
/// perspective rules that reference tags/projects/folders keep pointing at the right things.
/// Re-importing is safe: OmniFocus ids are reused, so it refreshes instead of duplicating.
public enum OmniFocusImport {
    public static let exportScript = #"""
    (() => {
      const ts = d => (d instanceof Date) ? Math.round(d.getTime() / 1000) : null;
      const pk = o => o ? o.id.primaryKey : null;
      const safe = f => { try { return f(); } catch (e) { return null; } };
      const out = { version: 1, folders: [], projects: [], tasks: [], tags: [], perspectives: [] };

      const repeat = t => safe(() => {
        const r = t.repetitionRule; if (!r) return null;
        let fromCompletion = false, anchor = 'due';
        const st = safe(() => r.scheduleType);
        if (st) {
          fromCompletion = st === Task.RepetitionScheduleType.FromCompletion;
          const a = safe(() => r.anchorDateKey);
          if (a === Task.AnchorDateKey.DeferDate) anchor = 'defer';
          else if (a === Task.AnchorDateKey.PlannedDate) anchor = 'planned';
        } else {
          const m = safe(() => r.method);
          if (m === Task.RepetitionMethod.DeferUntilDate) { fromCompletion = true; anchor = 'defer'; }
          else if (m === Task.RepetitionMethod.DueDate) { fromCompletion = true; anchor = 'due'; }
        }
        return { rrule: r.ruleString, fromCompletion, anchor, catchUp: safe(() => r.catchUpAutomatically) ?? true };
      });

      const base = t => ({
        id: pk(t), name: t.name, note: t.note || '', flagged: t.flagged,
        defer: ts(t.deferDate), due: ts(t.dueDate), planned: ts(safe(() => t.plannedDate)),
        estimate: t.estimatedMinutes, completed: ts(t.completionDate), dropped: ts(t.dropDate),
        sequential: t.sequential, autoComplete: t.completedByChildren,
        tags: t.tags.map(pk), added: ts(t.added), repeat: repeat(t)
      });

      const taskRec = (t, parent, idx) => {
        const r = base(t); r.parent = parent; r.idx = idx;
        out.tasks.push(r);
        t.children.forEach((c, i) => taskRec(c, r.id, i));
      };

      const tagWalk = (arr, parent) => arr.forEach((t, i) => {
        out.tags.push({ id: pk(t), name: t.name, parent, idx: i,
          status: t.status === Tag.Status.OnHold ? 'onHold' : (t.status === Tag.Status.Dropped ? 'dropped' : 'active') });
        tagWalk(t.children, pk(t));
      });
      tagWalk(tags, null);

      const projStatus = p => p.status === Project.Status.OnHold ? 'onHold'
        : p.status === Project.Status.Done ? 'done'
        : p.status === Project.Status.Dropped ? 'dropped' : 'active';
      const unitName = u => { const s = String(u).toLowerCase(); return s.startsWith('d') ? 'day' : s.startsWith('w') ? 'week' : s.startsWith('m') ? 'month' : s.startsWith('y') ? 'year' : 'week'; };

      const libWalk = (arr, parent) => arr.forEach((x, i) => {
        if (x instanceof Folder) {
          out.folders.push({ id: pk(x), name: x.name, parent, idx: i, dropped: x.status === Folder.Status.Dropped });
          libWalk(x.children, pk(x));
        } else if (x instanceof Project) {
          const r = base(x.task);
          r.id = pk(x); r.parent = parent; r.idx = i;
          r.status = projStatus(x);
          r.singleActions = x.containsSingletonActions;
          r.sequential = x.sequential;
          const ri = safe(() => x.reviewInterval);
          r.review = ri ? { count: ri.steps, unit: unitName(ri.unit) } : null;
          r.nextReview = ts(safe(() => x.nextReviewDate));
          r.lastReview = ts(safe(() => x.lastReviewDate));
          out.projects.push(r);
          x.task.children.forEach((c, j) => taskRec(c, r.id, j));
        }
      });
      libWalk(library, null);
      inbox.forEach((t, i) => taskRec(t, null, i));

      Perspective.Custom.all.forEach((p, i) => {
        out.perspectives.push({ id: p.identifier, name: p.name, idx: i,
          rules: safe(() => p.archivedFilterRules), aggregation: safe(() => p.archivedTopLevelFilterAggregation) });
      });
      return JSON.stringify(out);
    })()
    """#

    public struct Export: Decodable {
        public var folders: [FolderRec]
        public var projects: [TaskRec]
        public var tasks: [TaskRec]
        public var tags: [TagRec]
        public var perspectives: [PerspectiveRec]
    }
    public struct FolderRec: Decodable { var id: String; var name: String; var parent: String?; var idx: Int; var dropped: Bool? }
    public struct TagRec: Decodable { var id: String; var name: String; var parent: String?; var idx: Int; var status: String? }
    public struct PerspectiveRec: Decodable { var id: String; var name: String; var idx: Int; var rules: [JSON]?; var aggregation: String? }
    public struct ReviewRec: Decodable { var count: Int?; var unit: String? }
    public struct TaskRec: Decodable {
        var id: String; var name: String; var note: String?; var flagged: Bool?
        var `defer`: Double?; var due: Double?; var planned: Double?; var estimate: Int?
        var completed: Double?; var dropped: Double?; var sequential: Bool?; var autoComplete: Bool?
        var tags: [String?]?; var added: Double?; var `repeat`: RepeatRule?
        var parent: String?; var idx: Int
        var status: String?; var singleActions: Bool?; var review: ReviewRec?; var nextReview: Double?; var lastReview: Double?
    }

    public struct Summary: Sendable, CustomStringConvertible {
        public var folders = 0, projects = 0, tasks = 0, tags = 0, perspectives = 0
        public var unsupportedRules: [String] = []
        public var description: String {
            "\(projects) projects, \(tasks) actions, \(folders) folders, \(tags) tags, \(perspectives) perspectives"
        }
    }

    public static func decode(_ data: Data) throws -> Export {
        try JSONDecoder().decode(Export.self, from: data)
    }

    public static func summary(_ e: Export) -> Summary {
        var s = Summary()
        s.folders = e.folders.count; s.projects = e.projects.count; s.tasks = e.tasks.count
        s.tags = e.tags.count; s.perspectives = e.perspectives.count
        s.unsupportedRules = e.perspectives.filter { p in !(p.rules ?? []).allSatisfy(PerspectiveEngine.isSupported) }.map(\.name)
        return s
    }

    /// Writes the export into the store. Large imports are split into several transactions
    /// so memory stays bounded; each is atomic and the whole import is idempotent.
    @discardableResult
    public static func apply(_ e: Export, to store: Store) -> Summary {
        func keys<T>(_ items: [T], parent: (T) -> String?, idx: (T) -> Int) -> [Int: String] {
            // Order keys per parent, from OmniFocus's sibling index.
            var groups: [String: [(Int, Int)]] = [:]
            for (n, it) in items.enumerated() { groups[parent(it) ?? "", default: []].append((n, idx(it))) }
            var out: [Int: String] = [:]
            for (_, list) in groups {
                let sorted = list.sorted { $0.1 < $1.1 }
                let k = FractionalIndex.evenlySpaced(sorted.count)
                for (j, item) in sorted.enumerated() { out[item.0] = k[j] }
            }
            return out
        }

        // Folders and projects share one sibling list per container (OmniFocus numbers them together),
        // so they're ordered together; otherwise their interleaving is lost.
        let library: [(parent: String?, idx: Int)] = e.folders.map { ($0.parent, $0.idx) } + e.projects.map { ($0.parent, $0.idx) }
        let libraryKeys = keys(library, parent: { $0.parent }, idx: { $0.idx })

        store.transact("Import folders & tags") { tx in
            for (n, f) in e.folders.enumerated() {
                tx.set(.folder, f.id, F.name, .string(f.name))
                tx.set(.folder, f.id, F.pos, Position(parent: f.parent, order: libraryKeys[n]!).json)
                tx.set(.folder, f.id, F.status, (f.dropped ?? false) ? "dropped" : "active")
                tx.set(.folder, f.id, F.deleted, false)
            }
            let tk = keys(e.tags, parent: { $0.parent }, idx: { $0.idx })
            for (n, t) in e.tags.enumerated() {
                tx.set(.tag, t.id, F.name, .string(t.name))
                tx.set(.tag, t.id, F.pos, Position(parent: t.parent, order: tk[n]!).json)
                tx.set(.tag, t.id, F.status, .string(t.status ?? "active"))
                tx.set(.tag, t.id, F.deleted, false)
            }
            let pk = FractionalIndex.evenlySpaced(e.perspectives.count)
            for (n, p) in e.perspectives.enumerated() {
                tx.set(.perspective, p.id, F.name, .string(p.name))
                tx.set(.perspective, p.id, F.pos, Position(parent: nil, order: pk[n]).json)
                tx.set(.perspective, p.id, F.rules, .array(p.rules ?? []))
                tx.set(.perspective, p.id, F.aggregation, .string(p.aggregation ?? "all"))
                let completed = (p.rules ?? []).contains { $0["actionAvailability"]?.string == "completed" }
                tx.set(.perspective, p.id, F.groupBy, .string(completed ? GroupBy.completed.rawValue : GroupBy.project.rawValue))
                tx.set(.perspective, p.id, F.sortBy, .string(completed ? SortBy.completed.rawValue : SortBy.manual.rawValue))
                tx.set(.perspective, p.id, F.icon, .string(completed ? "checkmark.circle" : "line.3.horizontal.decrease.circle"))
                tx.set(.perspective, p.id, F.deleted, false)
            }
        }

        let taskKeys = keys(e.tasks, parent: { $0.parent }, idx: { $0.idx })
        let all = e.projects.enumerated().map { ($1, true, libraryKeys[e.folders.count + $0]!) }
            + e.tasks.enumerated().map { ($1, false, taskKeys[$0]!) }
        for chunk in stride(from: 0, to: all.count, by: 1500) {
            store.transact("Import from OmniFocus") { tx in
                for (r, isProject, order) in all[chunk..<min(chunk + 1500, all.count)] {
                    write(r, isProject: isProject, order: order, tx: &tx)
                }
            }
        }
        return summary(e)
    }

    static func write(_ r: TaskRec, isProject: Bool, order: String, tx: inout Tx) {
        let id = r.id
        func date(_ v: Double?) -> JSON { v.map { .number($0) } ?? .null }
        tx.set(.task, id, F.kind, isProject ? "project" : "action")
        tx.set(.task, id, F.title, .string(r.name))
        tx.set(.task, id, F.note, .string(r.note ?? ""))
        tx.set(.task, id, F.pos, Position(parent: r.parent, order: order).json)
        tx.set(.task, id, F.flagged, .bool(r.flagged ?? false))
        tx.set(.task, id, F.deferDate, date(r.defer))
        tx.set(.task, id, F.dueDate, date(r.due))
        tx.set(.task, id, F.plannedDate, date(r.planned))
        tx.set(.task, id, F.estimate, .optional(r.estimate))
        tx.set(.task, id, F.completed, date(r.completed))
        tx.set(.task, id, F.dropped, date(r.dropped))
        tx.set(.task, id, F.sequential, .bool(r.sequential ?? false))
        tx.set(.task, id, F.autoComplete, .bool(r.autoComplete ?? false))
        tx.set(.task, id, F.repeatRule, r.repeat.map { JSON(encoding: $0) } ?? .null)
        tx.set(.task, id, F.created, date(r.added))
        tx.set(.task, id, F.deleted, false)
        let newTags = Set((r.tags ?? []).compactMap { $0 })
        // Clear tags removed in OmniFocus since a previous import.
        if let existing = tx.state.fields(EntityKey(.task, id)) {
            for (field, reg) in existing where field.hasPrefix(F.tagPrefix) && reg.value.bool == true {
                let tagID = String(field.dropFirst(F.tagPrefix.count))
                if !newTags.contains(tagID) { tx.set(.task, id, field, false) }
            }
        }
        for tag in newTags { tx.set(.task, id, F.tag(tag), true) }
        if isProject {
            tx.set(.task, id, F.status, .string(r.status ?? "active"))
            tx.set(.task, id, F.singleActions, .bool(r.singleActions ?? false))
            if let rv = r.review, let c = rv.count {
                let unit = ReviewInterval.Unit(rawValue: rv.unit ?? "week") ?? .week
                tx.set(.task, id, F.reviewEvery, JSON(encoding: ReviewInterval(count: c, unit: unit)))
            }
            tx.set(.task, id, F.nextReview, date(r.nextReview))
            tx.set(.task, id, F.lastReview, date(r.lastReview))
        }
    }
}

import Foundation

/// A write being assembled inside `Store.transact`.
public struct Tx {
    struct Write { var type: EntityType; var id: String; var field: String; var value: JSON }
    var writes: [Write] = []
    var created: Set<EntityKey> = []
    var lastAppended: [String: String] = [:]
    var createdFolders: [String: String] = [:]
    let snapshot: Snapshot
    let state: CRDTState

    public var now: Date { snapshot.now }
    public var base: Snapshot { snapshot }

    public mutating func set(_ type: EntityType, _ id: String, _ field: String, _ value: JSON) {
        writes.append(Write(type: type, id: id, field: field, value: value))
    }

    public func current(_ type: EntityType, _ id: String, _ field: String) -> JSON? {
        if let w = writes.last(where: { $0.type == type && $0.id == id && $0.field == field }) { return w.value }
        return state.value(EntityKey(type, id), field)
    }

    public func exists(_ type: EntityType, _ id: String) -> Bool {
        created.contains(EntityKey(type, id)) || state.fields(EntityKey(type, id)) != nil
    }

    mutating func markCreated(_ type: EntityType, _ id: String) { created.insert(EntityKey(type, id)) }
}

/// Inverse of a committed transaction, for undo.
public struct UndoRecord: Sendable {
    public let name: String
    let writes: [(EntityType, String, String, JSON)]
}

public struct SyncCounts: Sendable {
    public var totalOps: Int
    public var pendingUpload: Int
    public var replicas: [String: Int64]
}

/// The local database: an append-only op log plus materialised LWW registers in SQLite.
/// Safe to use from any thread; also safe to open from several processes (app + extension).
public final class Store: @unchecked Sendable {
    public let url: URL
    public let replica: String
    let db: SQLiteDB
    private let lock = NSRecursiveLock()
    private var clock: HLCClock
    private var state = CRDTState()
    private var cache: [EntityKey: Any] = [:]
    private var lastSeq: Int64 = 0
    private var version = 0
    private var cachedSnapshot: Snapshot?
    private var snapshotBuiltAt = Date.distantPast
    private var counters: [String: Int64] = [:]            // max counter seen per replica
    private var contiguousCache: [String: Int64] = [:]

    /// Called (on an arbitrary thread) after any change becomes visible.
    public var onChange: (@Sendable () -> Void)?

    /// - Parameter role: distinguishes processes sharing one database ("app", "share").
    ///   Each process gets its own replica id, so op counters never collide.
    public init(url: URL, role: String = "app") throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.path)
        try Store.migrate(db)
        let key = "replica.\(role)"
        if let r = try db.prepare("SELECT value FROM meta WHERE key=?").bind(key).first({ $0.string(0) }) {
            replica = r
        } else {
            replica = IDs.make()
            try db.prepare("INSERT INTO meta(key,value) VALUES(?,?)").bind(key, replica).run()
        }
        clock = HLCClock(replica: replica)
        try loadRegisters()
        try pullNewOps(notify: false)
    }

    static func migrate(_ db: SQLiteDB) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS ops(
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            replica TEXT NOT NULL, counter INTEGER NOT NULL,
            ms INTEGER NOT NULL, c INTEGER NOT NULL,
            etype TEXT NOT NULL, eid TEXT NOT NULL, field TEXT NOT NULL, value TEXT NOT NULL,
            uploaded INTEGER NOT NULL DEFAULT 0,
            UNIQUE(replica, counter));
        CREATE INDEX IF NOT EXISTS ops_pending ON ops(uploaded, replica, counter);
        CREATE TABLE IF NOT EXISTS registers(
            etype TEXT NOT NULL, eid TEXT NOT NULL, field TEXT NOT NULL,
            value TEXT NOT NULL, ms INTEGER NOT NULL, c INTEGER NOT NULL, replica TEXT NOT NULL,
            PRIMARY KEY(etype, eid, field)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS heads(
            replica TEXT PRIMARY KEY, last INTEGER NOT NULL, device TEXT NOT NULL DEFAULT '',
            platform TEXT NOT NULL DEFAULT '', updated REAL NOT NULL DEFAULT 0);
        """)
    }

    private func loadRegisters() throws {
        try db.prepare("SELECT etype, eid, field, value, ms, c, replica FROM registers").forEach { row in
            guard let type = EntityType(rawValue: row.string(0)) else { return }
            let hlc = HLC(ms: row.int64(4), c: Int32(row.int64(5)), replica: row.string(6))
            state.load(EntityKey(type, row.string(1)), field: row.string(2),
                       register: Register(value: JSON(text: row.string(3)), hlc: hlc))
        }
        clock.observe(state.maxHLC)
        // Start after the registers already reflected; any newer op rows are pulled next.
        lastSeq = try db.prepare("SELECT value FROM meta WHERE key='appliedSeq'").first { Int64($0.string(0)) ?? 0 } ?? 0
        try db.prepare("SELECT replica, MAX(counter) FROM ops GROUP BY replica").forEach { row in
            counters[row.string(0)] = row.int64(1)
        }
    }

    // MARK: Reading

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        // Rebuild when data changed, or when the day/minute rolled over (availability is time-based).
        if let s = cachedSnapshot, s.version == version, Date().timeIntervalSince(snapshotBuiltAt) < 60 { return s }
        let s = Snapshot(state: state, version: version, cache: cache)
        for (id, t) in s.tasks { cache[EntityKey(.task, id)] = t }
        for (id, f) in s.folders { cache[EntityKey(.folder, id)] = f }
        for (id, t) in s.tags { cache[EntityKey(.tag, id)] = t }
        for p in s.perspectives { cache[EntityKey(.perspective, p.id)] = p }
        cachedSnapshot = s
        snapshotBuiltAt = Date()
        return s
    }

    var debugState: CRDTState { lock.lock(); defer { lock.unlock() }; return state }

    public var currentVersion: Int { lock.lock(); defer { lock.unlock() }; return version }

    // MARK: Writing (local edits)

    /// Applies a batch of local edits atomically. Returns an undo record.
    @discardableResult
    public func transact(_ name: String = "Edit", _ body: (inout Tx) throws -> Void) rethrows -> UndoRecord? {
        lock.lock(); defer { lock.unlock() }
        var tx = Tx(snapshot: snapshot(), state: state)
        try body(&tx)
        guard !tx.writes.isEmpty else { return nil }

        // Inverse: previous values, or a tombstone for entities this transaction created.
        var inverse: [(EntityType, String, String, JSON)] = []
        var seen = Set<String>()
        for w in tx.writes {
            let k = EntityKey(w.type, w.id)
            if tx.created.contains(k) && state.fields(k) == nil {
                if seen.insert("\(w.type.rawValue)|\(w.id)|deleted").inserted {
                    inverse.append((w.type, w.id, F.deleted, true))
                }
                continue
            }
            if seen.insert("\(w.type.rawValue)|\(w.id)|\(w.field)").inserted {
                inverse.append((w.type, w.id, w.field, state.value(k, w.field) ?? .null))
            }
        }

        do {
            try db.transaction {
                // Re-read the counter inside the write lock: another process may share our db file.
                var counter = try db.prepare("SELECT MAX(counter) FROM ops WHERE replica=?").bind(replica).first { $0.int64(0) } ?? 0
                counter = max(counter, counters[replica] ?? 0)
                let ins = "INSERT INTO ops(replica,counter,ms,c,etype,eid,field,value,uploaded) VALUES(?,?,?,?,?,?,?,?,0)"
                for w in tx.writes {
                    counter += 1
                    let hlc = clock.tick()
                    try db.prepare(ins).bind(replica, counter, hlc.ms, hlc.c, w.type.rawValue, w.id, w.field, w.value.text).run()
                }
            }
        } catch {
            assertionFailure("Store write failed: \(error)")
            return nil
        }
        try? pullNewOps(notify: true)
        return UndoRecord(name: name, writes: inverse)
    }

    public func undo(_ record: UndoRecord) -> UndoRecord? {
        transact(record.name) { tx in
            for (t, id, f, v) in record.writes { tx.set(t, id, f, v) }
        }
    }

    // MARK: Merging (remote ops)

    /// Merges ops from another replica. Idempotent; returns how many were new.
    @discardableResult
    public func ingest(_ ops: [Op]) throws -> Int {
        guard !ops.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var inserted = 0
        try db.transaction {
            let ins = "INSERT OR IGNORE INTO ops(replica,counter,ms,c,etype,eid,field,value,uploaded) VALUES(?,?,?,?,?,?,?,?,1)"
            for op in ops {
                try db.prepare(ins).bind(op.replica, op.counter, op.hlc.ms, op.hlc.c, op.type.rawValue, op.id, op.field, op.value.text).run()
                inserted += db.changes
            }
        }
        if inserted > 0 { try pullNewOps(notify: true) }
        return inserted
    }

    /// Applies op rows we haven't folded into memory yet: our own, remote ones, and ones
    /// written by another process (the share extension). Registers are updated in SQL too.
    public func pullNewOps(notify: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        var maxSeq = lastSeq
        var batch: [Op] = []
        try db.prepare("SELECT seq, replica, counter, ms, c, etype, eid, field, value FROM ops WHERE seq > ? ORDER BY seq").bind(lastSeq).forEach { row in
            maxSeq = max(maxSeq, row.int64(0))
            guard let type = EntityType(rawValue: row.string(5)) else { return }
            let replica = row.string(1)
            let hlc = HLC(ms: row.int64(3), c: Int32(row.int64(4)), replica: replica)
            batch.append(Op(replica: replica, counter: row.int64(2), hlc: hlc, type: type, id: row.string(6), field: row.string(7), value: JSON(text: row.string(8))))
        }
        guard maxSeq > lastSeq else { return }
        try db.transaction {
            let up = """
            INSERT INTO registers(etype,eid,field,value,ms,c,replica) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(etype,eid,field) DO UPDATE SET value=excluded.value, ms=excluded.ms, c=excluded.c, replica=excluded.replica
            WHERE (excluded.ms, excluded.c, excluded.replica) > (registers.ms, registers.c, registers.replica)
            """
            for op in batch {
                clock.observe(op.hlc)
                counters[op.replica] = max(counters[op.replica] ?? 0, op.counter)
                if state.apply(op) {
                    changed = true
                    cache[op.key] = nil
                    try db.prepare(up).bind(op.type.rawValue, op.id, op.field, op.value.text, op.hlc.ms, op.hlc.c, op.replica).run()
                }
            }
            try db.prepare("INSERT INTO meta(key,value) VALUES('appliedSeq',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").bind(String(maxSeq)).run()
        }
        lastSeq = maxSeq
        contiguousCache = [:]
        if changed {
            version += 1
            if notify { onChange?() }
        }
    }

    // MARK: Sync bookkeeping

    /// Highest n such that ops 1...n from `replica` are all present locally.
    public func contiguous(_ replica: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let c = contiguousCache[replica] { return c }
        var expected: Int64 = 1
        try? db.prepare("SELECT counter FROM ops WHERE replica=? ORDER BY counter").bind(replica).forEach { row in
            if row.int64(0) == expected { expected += 1 }
        }
        contiguousCache[replica] = expected - 1
        return expected - 1
    }

    public var knownReplicas: [String: Int64] { lock.lock(); defer { lock.unlock() }; return counters }

    /// Local replicas are ones whose ops originate on this device (app + extensions).
    public func localReplicas() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (try? collect("SELECT value FROM meta WHERE key LIKE 'replica.%'") { $0.string(0) }) ?? [replica]
    }

    /// Contiguous runs of not-yet-uploaded ops: (replica, first, last), each at most `maxOps` long.
    public func pendingUploadRuns(maxOps: Int = 1000, limit: Int = 200_000) -> [(replica: String, first: Int64, last: Int64)] {
        lock.lock(); defer { lock.unlock() }
        var runs: [(String, Int64, Int64)] = []
        try? db.prepare("SELECT replica, counter FROM ops WHERE uploaded=0 ORDER BY replica, counter LIMIT ?").bind(limit).forEach { row in
            let r = row.string(0), n = row.int64(1)
            if var last = runs.last, last.0 == r, last.2 == n - 1, n - last.1 < Int64(maxOps) {
                last.2 = n; runs[runs.count - 1] = last
            } else {
                runs.append((r, n, n))
            }
        }
        return runs.map { (replica: $0.0, first: $0.1, last: $0.2) }
    }

    public func ops(replica: String, first: Int64, last: Int64) -> [Op] {
        lock.lock(); defer { lock.unlock() }
        return (try? collect("SELECT replica, counter, ms, c, etype, eid, field, value FROM ops WHERE replica=? AND counter BETWEEN ? AND ? ORDER BY counter", replica, first, last) { row -> Op? in
            guard let type = EntityType(rawValue: row.string(4)) else { return nil }
            return Op(replica: row.string(0), counter: row.int64(1), hlc: HLC(ms: row.int64(2), c: Int32(row.int64(3)), replica: row.string(0)),
                      type: type, id: row.string(5), field: row.string(6), value: JSON(text: row.string(7)))
        }.compactMap { $0 }) ?? []
    }

    /// Highest n such that this replica's ops 1...n are all uploaded (what our head announces).
    public func uploadedThrough(_ replica: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let firstPending = try? db.prepare("SELECT MIN(counter) FROM ops WHERE replica=? AND uploaded=0").bind(replica).first { $0.isNull(0) ? nil : $0.int64(0) }
        if let p = firstPending ?? nil { return min(p - 1, contiguous(replica)) }
        return contiguous(replica)
    }

    public func markUploaded(replica: String, first: Int64, last: Int64) {
        lock.lock(); defer { lock.unlock() }
        try? db.prepare("UPDATE ops SET uploaded=1 WHERE replica=? AND counter BETWEEN ? AND ?").bind(replica, first, last).run()
    }

    /// Used when the cloud copy is gone (zone deleted, account switched): every op we hold,
    /// from every device, gets uploaded again so the cloud is rebuilt from this replica.
    public func markAllNotUploaded() {
        lock.lock(); defer { lock.unlock() }
        try? db.exec("UPDATE ops SET uploaded=0")
    }

    public func syncCounts() -> SyncCounts {
        lock.lock(); defer { lock.unlock() }
        let total = ((try? db.prepare("SELECT COUNT(*) FROM ops").first { Int($0.int64(0)) }) ?? nil) ?? 0
        let pending = ((try? db.prepare("SELECT COUNT(*) FROM ops WHERE uploaded=0").first { Int($0.int64(0)) }) ?? nil) ?? 0
        return SyncCounts(totalOps: total, pendingUpload: pending, replicas: counters)
    }

    public struct Head: Sendable, Hashable {
        public var replica: String
        public var last: Int64
        public var device: String
        public var platform: String
        public var updated: Date
    }

    public func saveHead(_ h: Head) {
        lock.lock(); defer { lock.unlock() }
        try? db.prepare("""
        INSERT INTO heads(replica,last,device,platform,updated) VALUES(?,?,?,?,?)
        ON CONFLICT(replica) DO UPDATE SET last=MAX(heads.last, excluded.last), device=excluded.device,
            platform=excluded.platform, updated=MAX(heads.updated, excluded.updated)
        """).bind(h.replica, h.last, h.device, h.platform, h.updated.timeIntervalSince1970).run()
    }

    public func heads() -> [Head] {
        lock.lock(); defer { lock.unlock() }
        return (try? collect("SELECT replica,last,device,platform,updated FROM heads ORDER BY updated DESC") {
            Head(replica: $0.string(0), last: $0.int64(1), device: $0.string(2), platform: $0.string(3), updated: Date(timeIntervalSince1970: $0.double(4)))
        }) ?? []
    }

    public func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return try? db.prepare("SELECT value FROM meta WHERE key=?").bind(key).first { $0.string(0) } ?? nil
    }

    public func setMeta(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        if let value {
            try? db.prepare("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").bind(key, value).run()
        } else {
            try? db.prepare("DELETE FROM meta WHERE key=?").bind(key).run()
        }
    }

    // MARK: Export / merge files (manual fallback and backups)

    /// Every op as JSON lines (compressed). Merging this file into any replica is safe.
    public func exportLog() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var out = Data()
        let enc = JSONEncoder()
        try db.prepare("SELECT replica, counter, ms, c, etype, eid, field, value FROM ops ORDER BY seq").forEach { row in
            guard let type = EntityType(rawValue: row.string(4)) else { return }
            let op = Op(replica: row.string(0), counter: row.int64(1), hlc: HLC(ms: row.int64(2), c: Int32(row.int64(3)), replica: row.string(0)),
                        type: type, id: row.string(5), field: row.string(6), value: JSON(text: row.string(7)))
            out.append(try enc.encode(op)); out.append(0x0A)
        }
        return try (out as NSData).compressed(using: .lzfse) as Data
    }

    @discardableResult
    public func mergeLog(_ data: Data) throws -> Int {
        let raw = try (data as NSData).decompressed(using: .lzfse) as Data
        let dec = JSONDecoder()
        var ops: [Op] = []
        for line in raw.split(separator: 0x0A) where !line.isEmpty {
            if let op = try? dec.decode(Op.self, from: line) { ops.append(op) }
        }
        var total = 0
        for chunk in stride(from: 0, to: ops.count, by: 5000) {
            total += try ingest(Array(ops[chunk..<min(chunk + 5000, ops.count)]))
        }
        return total
    }

    /// Keeps a rolling set of daily backups next to the database.
    public func backupIfNeeded(keep: Int = 14) {
        let dir = url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let file = dir.appendingPathComponent("tasker-\(f.string(from: Date())).taskerlog")
        guard !FileManager.default.fileExists(atPath: file.path), let data = try? exportLog() else { return }
        try? data.write(to: file, options: .atomic)
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "taskerlog" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    private func collect<T>(_ sql: String, _ args: Any?..., map: (Row) -> T) throws -> [T] {
        var out: [T] = []
        try db.prepare(sql).bind(array: args).forEach { out.append(map($0)) }
        return out
    }
}

import CloudKit
import Foundation
import os

public struct SyncStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case starting, idle, fetching, sending, noAccount, error(String)
    }
    public struct Device: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var platform: String
        public var lastCounter: Int64
        public var have: Int64
        public var updated: Date
        public var isThisDevice: Bool
    }
    public var phase: Phase = .starting
    public var lastFetch: Date?
    public var lastSend: Date?
    public var pendingUpload = 0
    public var totalOps = 0
    public var devices: [Device] = []
    public var missingChanges: Int64 = 0
    public var lastError: String?
    public var lastRepair: Date?
    public var events: [String] = []
    public init() {}
}

/// CloudKit transport for the op log, built on CKSyncEngine.
///
/// Why this can't get stuck:
/// - Records are immutable op batches. Each device only creates records, never edits shared
///   ones, so there are no server-side conflicts to resolve and no "merge failed" states.
/// - Merging is a set union of ops (idempotent, order-independent). Records may arrive late,
///   twice or out of order: the result is the same.
/// - Every device publishes a head (how many of its ops it has uploaded). Peers compare that
///   with what they hold; a persistent gap triggers an automatic full re-fetch.
/// - If the cloud copy disappears (zone deleted, account reset), any device re-uploads the
///   complete history it holds, rebuilding the cloud.
public final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    public static let zoneName = "Tasker"

    let container: CKContainer
    let store: Store
    let zoneID = CKRecordZone.ID(zoneName: CloudSync.zoneName, ownerName: CKCurrentUserDefaultName)
    let deviceName: String
    let platform: String
    let log = Logger(subsystem: "Tasker", category: "sync")

    private let lock = NSRecursiveLock()
    private var engine: CKSyncEngine?
    private var status = SyncStatus()
    private var scheduledThrough: [String: Int64] = [:]
    private var headRecords: [String: CKRecord] = [:]
    private var sentHeadValue: [String: Int64] = [:]
    private var missingSince: [String: Date] = [:]
    /// During a repair, uploads wait for the full fetch so ranges the cloud already holds are
    /// recognised and not re-sent. Expires on its own so a failed fetch can't block uploads.
    private var holdUploadsSince: Date?
    private var holdUploadsUntilFetched: Bool {
        get { holdUploadsSince.map { Date().timeIntervalSince($0) < 600 } ?? false }
        set { holdUploadsSince = newValue ? Date() : nil }
    }

    /// Status updates, delivered on an arbitrary thread.
    public var onStatus: (@Sendable (SyncStatus) -> Void)?

    public init(containerIdentifier: String, store: Store, deviceName: String, platform: String) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.store = store
        self.deviceName = deviceName
        self.platform = platform
        if let r = store.meta("ck.lastRepair").flatMap(Double.init) { status.lastRepair = Date(timeIntervalSince1970: r) }
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard engine == nil else { return }
        let saved = store.meta("ck.state").flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        config.automaticallySync = true
        let e = CKSyncEngine(config)
        engine = e
        if saved == nil {
            e.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        note("Sync started\(saved == nil ? " (fresh state)" : "")")
        Task { await self.checkAccount() }
        scheduleUploads()
        publish()
    }

    func checkAccount() async {
        do {
            let s = try await container.accountStatus()
            if s != .available {
                update { $0.phase = .noAccount; $0.lastError = "iCloud account unavailable (\(s.rawValue)). Sign in to iCloud and enable iCloud Drive." }
            }
        } catch {
            update { $0.lastError = error.localizedDescription }
        }
    }

    /// Call after local edits. Cheap; CKSyncEngine batches and sends shortly after.
    public func localChangesCommitted() {
        scheduleUploads()
    }

    /// Fetch then send now (app foregrounded, timer, pull-to-refresh, background task).
    public func syncNow() async {
        guard let e = lock.withLock({ engine }) else { return }
        do {
            try await e.fetchChanges()
            scheduleUploads()
            try await e.sendChanges()
        } catch {
            note("Sync now failed: \(error.localizedDescription)")
            update { $0.lastError = error.localizedDescription }
        }
    }

    /// Re-downloads everything from iCloud and re-uploads anything the cloud is missing.
    /// Safe at any time: merging is idempotent, so nothing can be duplicated or lost.
    public func repair() async {
        note("Repair: full re-fetch and re-upload")
        let e: CKSyncEngine? = lock.withLock {
            store.markAllNotUploaded()
            holdUploadsUntilFetched = true
            resetEngineLocked()
            let now = Date()
            status.lastRepair = now
            store.setMeta("ck.lastRepair", String(now.timeIntervalSince1970))
            return engine
        }
        publish()
        do { try await e?.fetchChanges() } catch { note("Repair fetch failed: \(error.localizedDescription)") }
    }

    private func resetEngineLocked() {
        store.setMeta("ck.state", nil)
        scheduledThrough = [:]
        headRecords = [:]
        sentHeadValue = [:]
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: nil, delegate: self)
        config.automaticallySync = true
        let e = CKSyncEngine(config)
        engine = e
        e.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    // MARK: Uploads

    func scheduleUploads() {
        lock.lock(); defer { lock.unlock() }
        guard let e = engine, !holdUploadsUntilFetched else { publish(); return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        var replicas = Set<String>()
        for run in store.pendingUploadRuns() {
            let from = max(run.first, (scheduledThrough[run.replica] ?? 0) + 1)
            guard from <= run.last else { continue }
            let name = OpBatchCodec.recordName(replica: run.replica, first: from, last: run.last)
            changes.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            scheduledThrough[run.replica] = run.last
            replicas.insert(run.replica)
        }
        for r in replicas { changes.append(headChange(r)) }
        // Keep our own heads current even with nothing new to send (e.g. after a repair).
        for r in store.localReplicas() where store.uploadedThrough(r) != sentHeadValue[r] && store.uploadedThrough(r) > 0 {
            changes.append(headChange(r))
        }
        if !changes.isEmpty { e.state.add(pendingRecordZoneChanges: changes) }
        publish()
    }

    private func headChange(_ replica: String) -> CKSyncEngine.PendingRecordZoneChange {
        .saveRecord(CKRecord.ID(recordName: OpBatchCodec.headName(replica: replica), zoneID: zoneID))
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] id in
            guard let self else { return nil }
            let r = self.buildRecord(id)
            if r == nil { syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)]) }
            return r
        }
    }

    func buildRecord(_ id: CKRecord.ID) -> CKRecord? {
        let name = id.recordName
        if let range = OpBatchCodec.parseRecordName(name) {
            let ops = store.ops(replica: range.replica, first: range.first, last: range.last)
            guard !ops.isEmpty, let data = try? OpBatchCodec.encode(ops) else { return nil }
            let record = CKRecord(recordType: OpBatchCodec.recordType, recordID: id)
            record["replica"] = range.replica as NSString
            record["first"] = NSNumber(value: range.first)
            record["last"] = NSNumber(value: range.last)
            record["count"] = NSNumber(value: ops.count)
            if data.count > OpBatchCodec.inlineLimit {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).ops")
                guard (try? data.write(to: file)) != nil else { return nil }
                record["asset"] = CKAsset(fileURL: file)
            } else {
                record["payload"] = data as NSData
            }
            return record
        }
        if name.hasPrefix("h_") {
            let replica = String(name.dropFirst(2))
            lock.lock(); defer { lock.unlock() }
            let record = headRecords[replica] ?? CKRecord(recordType: OpBatchCodec.headType, recordID: id)
            let local = store.localReplicas().contains(replica)
            let value = local ? store.uploadedThrough(replica) : store.contiguous(replica)
            let previous = (record["last"] as? NSNumber)?.int64Value ?? 0
            record["last"] = NSNumber(value: max(value, previous))
            if local {
                record["device"] = deviceName as NSString
                record["platform"] = platform as NSString
            }
            record["updated"] = Date() as NSDate
            sentHeadValue[replica] = value
            return record
        }
        return nil
    }

    // MARK: Events

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                store.setMeta("ck.state", data.base64EncodedString())
            }

        case .accountChange(let e):
            switch e.changeType {
            case .signIn:
                note("iCloud account signed in")
                update { $0.phase = .idle; $0.lastError = nil }
                scheduleUploads()
            case .signOut:
                note("iCloud account signed out; local data kept")
                update { $0.phase = .noAccount }
            case .switchAccounts:
                note("iCloud account switched; uploading local data to the new account")
                lock.withLock {
                    store.markAllNotUploaded()
                    resetEngineLocked()
                }
                scheduleUploads()
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let e):
            for d in e.deletions where d.zoneID == zoneID {
                note("iCloud data was removed (\(d.reason)); rebuilding it from this device")
                lock.withLock {
                    store.markAllNotUploaded()
                    scheduledThrough = [:]
                    headRecords = [:]
                    sentHeadValue = [:]
                    engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                }
                scheduleUploads()
            }

        case .fetchedRecordZoneChanges(let e):
            var ops: [Op] = []
            for m in e.modifications {
                let r = m.record
                switch r.recordType {
                case OpBatchCodec.recordType:
                    var data = r["payload"] as? Data
                    if data == nil, let url = (r["asset"] as? CKAsset)?.fileURL { data = try? Data(contentsOf: url) }
                    guard let data, let decoded = try? OpBatchCodec.decode(data) else {
                        note("Could not read batch \(r.recordID.recordName); will retry via repair")
                        continue
                    }
                    ops.append(contentsOf: decoded)
                    // The cloud holds this range, so it never needs uploading from here.
                    if let range = OpBatchCodec.parseRecordName(r.recordID.recordName) {
                        store.markUploaded(replica: range.replica, first: range.first, last: range.last)
                    }
                case OpBatchCodec.headType:
                    let replica = String(r.recordID.recordName.dropFirst(2))
                    store.saveHead(Store.Head(replica: replica,
                                              last: (r["last"] as? NSNumber)?.int64Value ?? 0,
                                              device: (r["device"] as? String) ?? "",
                                              platform: (r["platform"] as? String) ?? "",
                                              updated: (r["updated"] as? Date) ?? r.modificationDate ?? Date()))
                    lock.withLock { headRecords[replica] = r }
                default:
                    break
                }
            }
            do {
                let n = try store.ingest(ops)
                if n > 0 { note("Merged \(n) changes") }
            } catch {
                note("Merge failed: \(error)")
            }

        case .sentRecordZoneChanges(let e):
            var touched = Set<String>()
            for r in e.savedRecords {
                if let range = OpBatchCodec.parseRecordName(r.recordID.recordName) {
                    store.markUploaded(replica: range.replica, first: range.first, last: range.last)
                    touched.insert(range.replica)
                } else if r.recordType == OpBatchCodec.headType {
                    lock.withLock { headRecords[String(r.recordID.recordName.dropFirst(2))] = r }
                }
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            var needZone = false
            for f in e.failedRecordSaves {
                let id = f.record.recordID
                let range = OpBatchCodec.parseRecordName(id.recordName)
                switch f.error.code {
                case .serverRecordChanged:
                    if let range {
                        // Batches are immutable: the server already has exactly this content.
                        store.markUploaded(replica: range.replica, first: range.first, last: range.last)
                        touched.insert(range.replica)
                    } else if let server = f.error.serverRecord {
                        lock.withLock { headRecords[String(id.recordName.dropFirst(2))] = server }
                        retry.append(.saveRecord(id))
                    }
                case .zoneNotFound, .userDeletedZone:
                    needZone = true
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    lock.withLock { headRecords[String(id.recordName.dropFirst(2))] = nil }
                    retry.append(.saveRecord(id))
                case .limitExceeded:
                    if let range, range.last > range.first {
                        let mid = (range.first + range.last) / 2
                        for (a, b) in [(range.first, mid), (mid + 1, range.last)] {
                            retry.append(.saveRecord(CKRecord.ID(recordName: OpBatchCodec.recordName(replica: range.replica, first: a, last: b), zoneID: zoneID)))
                        }
                    } else {
                        note("Record too large: \(id.recordName)")
                    }
                case .quotaExceeded:
                    update { $0.phase = .error("iCloud storage is full"); $0.lastError = "iCloud storage is full" }
                    retry.append(.saveRecord(id))
                default:
                    note("Save failed (\(f.error.code.rawValue)): \(f.error.localizedDescription); will retry")
                    retry.append(.saveRecord(id))
                }
            }
            if needZone { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            if !touched.isEmpty { scheduleUploads() }
            update { $0.lastSend = Date() }

        case .sentDatabaseChanges(let e):
            for f in e.failedZoneSaves {
                note("Zone save failed: \(f.error.localizedDescription)")
                update { $0.lastError = f.error.localizedDescription }
            }

        case .willFetchChanges:
            update { $0.phase = .fetching }
        case .didFetchChanges:
            lock.withLock { holdUploadsUntilFetched = false }
            update { $0.phase = .idle; $0.lastFetch = Date(); if case .error = $0.phase {} else { $0.lastError = nil } }
            checkCompleteness()
            scheduleUploads()
        case .willSendChanges:
            update { $0.phase = .sending }
        case .didSendChanges:
            update { $0.phase = .idle }
        default:
            break
        }
        publish()
    }

    // MARK: Completeness

    /// Compares each device's published head with what we hold. A gap that persists for a few
    /// minutes (longer than normal propagation) triggers a full re-fetch, at most every 30 minutes.
    func checkCompleteness() {
        var missing: Int64 = 0
        var stale = false
        let now = Date()
        let locals = Set(store.localReplicas())
        lock.lock()
        for h in store.heads() where !locals.contains(h.replica) {
            let have = store.contiguous(h.replica)
            if have < h.last {
                missing += h.last - have
                let since = missingSince[h.replica] ?? now
                missingSince[h.replica] = since
                if now.timeIntervalSince(since) > 180 { stale = true }
            } else {
                missingSince[h.replica] = nil
            }
        }
        let canRepair = status.lastRepair.map { now.timeIntervalSince($0) > 1800 } ?? true
        status.missingChanges = missing
        lock.unlock()
        if stale && canRepair {
            note("Detected \(missing) changes announced by other devices but not received; re-fetching everything")
            Task { await self.repair() }
        }
    }

    // MARK: Status

    private func note(_ s: String) {
        log.info("\(s, privacy: .public)")
        lock.withLock {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            status.events.insert("\(f.string(from: Date()))  \(s)", at: 0)
            if status.events.count > 60 { status.events.removeLast(status.events.count - 60) }
        }
    }

    private func update(_ body: (inout SyncStatus) -> Void) {
        lock.withLock { body(&status) }
    }

    private func publish() {
        let counts = store.syncCounts()
        let locals = Set(store.localReplicas())
        let heads = store.heads()
        let snapshot: SyncStatus = lock.withLock {
            status.pendingUpload = counts.pendingUpload
            status.totalOps = counts.totalOps
            var devices: [SyncStatus.Device] = heads.map { h in
                SyncStatus.Device(id: h.replica, name: h.device.isEmpty ? "Unknown device" : h.device, platform: h.platform,
                                  lastCounter: h.last, have: locals.contains(h.replica) ? h.last : store.contiguous(h.replica),
                                  updated: h.updated, isThisDevice: locals.contains(h.replica))
            }
            if !devices.contains(where: { $0.id == store.replica }) {
                devices.insert(SyncStatus.Device(id: store.replica, name: deviceName, platform: platform, lastCounter: counts.replicas[store.replica] ?? 0,
                                                 have: counts.replicas[store.replica] ?? 0, updated: Date(), isThisDevice: true), at: 0)
            }
            status.devices = devices.filter { !$0.name.isEmpty }
            return status
        }
        onStatus?(snapshot)
    }

    // MARK: Direct upload (share extension)

    /// Best-effort immediate upload without CKSyncEngine, used by extensions so a capture
    /// reaches other devices even before the app is opened. The app re-sends anything this misses.
    public static func uploadPending(store: Store, containerIdentifier: String, replicas: [String]) async {
        let db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let runs = store.pendingUploadRuns().filter { replicas.contains($0.replica) }
        var records: [CKRecord] = []
        for run in runs {
            let ops = store.ops(replica: run.replica, first: run.first, last: run.last)
            guard let data = try? OpBatchCodec.encode(ops), data.count < OpBatchCodec.inlineLimit else { continue }
            let id = CKRecord.ID(recordName: OpBatchCodec.recordName(replica: run.replica, first: run.first, last: run.last), zoneID: zoneID)
            let r = CKRecord(recordType: OpBatchCodec.recordType, recordID: id)
            r["replica"] = run.replica as NSString
            r["first"] = NSNumber(value: run.first)
            r["last"] = NSNumber(value: run.last)
            r["count"] = NSNumber(value: ops.count)
            r["payload"] = data as NSData
            records.append(r)
        }
        guard !records.isEmpty else { return }
        guard let result = try? await db.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false) else { return }
        for (id, r) in result.saveResults {
            guard let range = OpBatchCodec.parseRecordName(id.recordName) else { continue }
            switch r {
            case .success: store.markUploaded(replica: range.replica, first: range.first, last: range.last)
            case .failure(let e as CKError) where e.code == .serverRecordChanged:
                store.markUploaded(replica: range.replica, first: range.first, last: range.last)
            default: break
            }
        }
    }
}

import Foundation
import SwiftUI
import Supabase

/// Keeps the household on screen in sync with the server.
///
/// The files on this device stay the app's working copy (it works offline as before). Each save on the
/// server gets a new revision; the device remembers the revision it last saw, and a copy of that version (the
/// "base"). When only the server changed, its version is loaded; when only this device changed, it's saved;
/// when both changed, the two are merged against the base (`SyncMerge`): every change from both sides is kept,
/// and only where both changed the same value does the later change win — the other version stays in the
/// household's version history on the server (the newest 30 are kept).
@MainActor
final class ServerSync: ObservableObject {
    @Published private(set) var status = "" {
        didSet { if !status.isEmpty, status != oldValue { AppLog.add("sync", status) } }
    }
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String? {
        didSet { if let lastError, lastError != oldValue { AppLog.add("sync-error", lastError) } }
    }
    private weak var store: Store?
    private weak var account: UserAccount?
    private var debounce: Task<Void, Never>?
    private var timer: Timer?
    private var applyingRemote = false
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var listeningTo: UUID?

    /// The household whose data is in the local files right now.
    private(set) var linkedHouseholdID: UUID? {
        get { UserDefaults.standard.string(forKey: "syncLinkedHousehold").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "syncLinkedHousehold") }
    }

    private var lastSeenRevision: Int64 {
        get { (UserDefaults.standard.object(forKey: "syncLastSeenRevision") as? NSNumber)?.int64Value ?? 0 }
        set { UserDefaults.standard.set(NSNumber(value: newValue), forKey: "syncLastSeenRevision") }
    }

    /// When this device's data changed without being saved to the server yet.
    private var localChangedAt: Date? {
        get { UserDefaults.standard.object(forKey: "syncLocalChangedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "syncLocalChangedAt") }
    }

    var hasUnsyncedChanges: Bool { localChangedAt != nil }

    /// Posted when another account signs in on this device and the previous account's data is cleared off it.
    static let deviceDataCleared = Notification.Name("maskoretDeviceDataCleared")

    /// The account whose data is in the local files. nil = data from before accounts existed (the device owner's).
    private var dataOwner: UUID? {
        get { UserDefaults.standard.string(forKey: "syncDataOwner").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "syncDataOwner") }
    }

    init() {
        lastSync = UserDefaults.standard.object(forKey: "syncLastSync") as? Date
    }

    func attach(store: Store, account: UserAccount) {
        guard self.store == nil else { return }
        self.store = store
        self.account = account
        // Synchronous, so changes made while loading the server's data aren't mistaken for local edits.
        store.onDataChange = { [weak self] in
            MainActor.assumeIsolated { self?.localDidChange() }
        }
        store.encryptLocalCopyIfNeeded()
        #if os(iOS)
        // Old versions kept backups in the app's Documents folder; once this device has synced, versions live on the server.
        if dataOwner != nil {
            try? FileManager.default.removeItem(at: Platform.homeDirectory.appendingPathComponent("גיבויים", isDirectory: true))
        }
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
    }

    // MARK: Which household is on screen

    /// Called whenever the user, their households or the chosen household change.
    func accountChanged() async {
        guard let account else { return }
        guard account.isSignedIn else {
            await stopListening()
            status = ""
            return
        }
        // Another account's data must never reach this one (a shared device, or "sign out and keep the data").
        if let owner = dataOwner, let me = account.userID, owner != me {
            clearDeviceForNewAccount(me)
        }
        // The households list may still be loading.
        if account.households.isEmpty { await account.refreshHouseholds() }

        if linkedHouseholdID == nil {
            await linkLocalData()
            return
        }
        // The chosen household is gone (deleted, or this user was removed): keep the data, stop syncing it.
        if let linked = linkedHouseholdID, !account.households.contains(where: { $0.id == linked }) {
            // Its data stays on the device as a backup before another household is shown.
            unlink(keepingData: true)
            if let first = account.households.first {
                await switchTo(first.id, cacheCurrent: false)
                lastError = "משק הבית הקודם כבר לא זמין לך (נמחק או שהוסרת ממנו)."
            } else {
                // No household on this account (e.g. a new server): this device's data becomes its household.
                await createHousehold(name: "משק הבית שלי", from: store?.familyBackup)
            }
            return
        }
        if let wanted = account.activeHouseholdID, wanted != linkedHouseholdID,
           account.households.contains(where: { $0.id == wanted }) {
            await switchTo(wanted)
            return
        }
        account.activeHouseholdID = linkedHouseholdID
        await listen(to: linkedHouseholdID)
        await sync()
    }

    /// This device's data isn't linked to a household of the account (first sign-in, or after signing out).
    /// The server is the source: the account's household is loaded. Data that was on the device goes to that
    /// household's version history first (it can be restored from "גרסאות"), so nothing is lost and nobody is asked.
    /// Changes made offline on a linked device aren't affected — `sync()` sends them up when it's back online.
    private func linkLocalData() async {
        guard let account, let store else { return }
        if account.households.isEmpty {
            // New account: this device's data becomes their first household.
            await createHousehold(name: "משק הבית שלי", from: store.familyBackup)
            return
        }
        let target = account.activeHouseholdID ?? account.households[0].id
        if !ServerSync.isEmpty(store) {
            await uploadVersion(store.familyBackup, to: target, note: "הנתונים שהיו במכשיר לפני ההתחברות")
        }
        await switchTo(target, cacheCurrent: false)
    }

    /// A data set that was never really used (nothing worth uploading or asking about).
    static func isEmpty(_ store: Store) -> Bool {
        store.members.count <= 1 && store.history.isEmpty && store.money.transactions.isEmpty
            && store.money.cardTransactions.isEmpty && store.budget.gross == 0
    }

    func createHousehold(name: String, from family: FamilyBackup? = nil) async {
        guard let account, let store else { return }
        do {
            struct Params: Encodable { let p_name: String; let p_data: AnyJSON; let p_device: String }
            struct Created: Decodable { let id: UUID; let revision: Int64 }
            let data = family ?? ServerSync.emptyFamily(rates: store)
            let created = try await supabase.rpc("create_household",
                                                 params: Params(p_name: name, p_data: try .appJSON(data), p_device: Platform.deviceName))
                .decoded(Created.self)
            if linkedHouseholdID != nil { cacheCurrent() }
            if family == nil { apply(data, backupFirst: false) }
            linkedHouseholdID = created.id
            lastSeenRevision = created.revision
            localChangedAt = nil
            writeBase(data, hid: created.id, revision: created.revision)
            await account.refreshHouseholds()
            account.activeHouseholdID = created.id
            markSynced("משק הבית נוצר ונשמר בשרת")
            await listen(to: created.id)
        } catch {
            lastError = UserAccount.describe(error)
        }
    }

    /// Shows another household: this one is kept in a cache on the device, then the other is loaded.
    func switchTo(_ id: UUID, cacheCurrent shouldCache: Bool = true) async {
        guard let account else { return }
        if let current = linkedHouseholdID {
            if current == id { return }
            await sync()                 // push what's pending first
            if shouldCache { cacheCurrent() }
        }
        if let cached = ServerSync.readCache(id) {
            apply(cached.family, backupFirst: false)
            lastSeenRevision = cached.revision
            writeBase(cached.family, hid: id, revision: cached.revision)
        } else {
            lastSeenRevision = 0         // nothing on the device yet: the server's version is loaded below
        }
        linkedHouseholdID = id
        localChangedAt = nil
        account.activeHouseholdID = id
        await listen(to: id)
        await sync()
    }

    /// Signing out: optionally clear this device's copy (it stays on the server).
    /// Signing out (or deleting the account): last changes go up, then the encrypted copy on this device is deleted.
    func signedOut() async {
        await sync()
        await stopListening()
        wipeDevice()
    }

    /// Nothing of this account stays on the device: the encrypted files and their key are deleted,
    /// and the screen shows an empty household until someone signs in.
    private func wipeDevice() {
        unlink(keepingData: false)
        SecureFile.wipeAll()
        if let store { apply(ServerSync.emptyFamily(rates: store), backupFirst: false) }
        dataOwner = nil
        UserDefaults.standard.removeObject(forKey: "activeHouseholdID")
        UserDefaults.standard.removeObject(forKey: "syncLastSync")
        lastSync = nil
        status = ""
        lastError = nil
        NotificationCenter.default.post(name: ServerSync.deviceDataCleared, object: nil)
    }

    /// The previous account's data leaves the screen (kept as a local backup on this device),
    /// and the new account starts from its own households, or from nothing.
    private func clearDeviceForNewAccount(_ newOwner: UUID) {
        wipeDevice()
        dataOwner = newOwner
    }

    private func unlink(keepingData: Bool) {
        linkedHouseholdID = nil
        lastSeenRevision = 0
        localChangedAt = nil
        try? FileManager.default.removeItem(at: ServerSync.baseURL)
    }

    // MARK: Triggers

    private func localDidChange() {
        guard !applyingRemote, linkedHouseholdID != nil, account?.isSignedIn == true else { return }
        localChangedAt = Date()
        status = "יש שינויים שעוד לא נשמרו בשרת"
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    private func listen(to id: UUID?) async {
        guard listeningTo != id else { return }
        await stopListening()
        guard let id else { return }
        listeningTo = id
        let channel = supabase.channel("household-\(id.uuidString.lowercased())")
        let changes = channel.postgresChange(UpdateAction.self, schema: "public", table: "households",
                                             filter: "id=eq.\(id.uuidString.lowercased())")
        self.channel = channel
        await channel.subscribe()
        listenTask = Task { [weak self] in
            for await _ in changes {
                await self?.sync()
            }
        }
    }

    private func stopListening() async {
        listenTask?.cancel()
        listenTask = nil
        if let channel { await supabase.removeChannel(channel) }
        channel = nil
        listeningTo = nil
    }

    // MARK: Sync

    private struct Head: Decodable { let data_revision: Int64 }
    private struct Remote: Decodable {
        let data: FamilyBackup
        let revision: Int64
        let updated_at: String
        let device: String?
    }
    private struct SaveResult: Decodable { let ok: Bool; let revision: Int64? }

    func sync() async {
        guard let store, let account, account.isSignedIn, let hid = linkedHouseholdID, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let head = try await supabase.from("households").select("data_revision").eq("id", value: hid)
                .single().decoded(Head.self)
            if head.data_revision > lastSeenRevision {
                let remote = try await supabase.from("household_data").select("data,revision,updated_at,device")
                    .eq("household_id", value: hid).single().decoded(Remote.self)
                if localChangedAt == nil {
                    apply(remote.data, backupFirst: false)
                    lastSeenRevision = remote.revision
                    writeBase(remote.data, hid: hid, revision: remote.revision)
                    markSynced("עודכן מ-" + (remote.device ?? "השרת"))
                } else {
                    try await merge(store, hid: hid, remote: remote)
                }
            } else if localChangedAt != nil {
                try await push(store, hid: hid, expected: lastSeenRevision)
            } else {
                markSynced("מסונכרן")
            }
        } catch {
            handle(error)
        }
    }

    /// Both changed since the base: the server's changes and this device's are merged, the result is shown here
    /// and saved to the server. Where both changed the same value the later one wins, and the other version
    /// is kept in the server's history.
    private func merge(_ store: Store, hid: UUID, remote: Remote) async throws {
        let local = store.familyBackup
        let remoteDate = ISO8601DateFormatter.flexible(remote.updated_at) ?? .distantPast
        let mineIsNewer = (localChangedAt ?? .distantPast) > remoteDate
        // Which member is edited / shown is per device: it's not a change to merge.
        func withDeviceState(_ family: FamilyBackup) -> FamilyBackup {
            var f = family
            f.state.activeID = local.state.activeID
            f.state.viewIDs = local.state.viewIDs
            return f
        }
        let base = readBase(hid: hid).map(withDeviceState)
        let theirs = withDeviceState(remote.data)
        guard let l = SyncMerge.json(local), let r = SyncMerge.json(theirs) else {
            throw CocoaError(.coderInvalidValue)
        }
        let result = SyncMerge.merge(base: base.flatMap(SyncMerge.json), local: l, remote: r, preferLocal: mineIsNewer)
        guard let data = try? JSONSerialization.data(withJSONObject: result.value),
              let merged = try? JSONDecoder().decode(FamilyBackup.self, from: data) else {
            throw CocoaError(.coderInvalidValue)
        }
        AppLog.add("sync", "מיזוג עם גרסה \(remote.revision) מ-\(remote.device ?? "השרת")"
                   + (result.conflicts.isEmpty ? "" : " — \(result.conflicts.count) ערכים השתנו בשני המכשירים, נשמר "
                      + (mineIsNewer ? "של המכשיר הזה" : "של השרת"))
                   + (base == nil ? " (בלי גרסת בסיס)" : ""))
        // The server keeps its own version in the history when ours replaces it; ours is kept when theirs wins.
        if !result.conflicts.isEmpty, !mineIsNewer {
            await uploadVersion(local, to: hid, note: "גרסה מהמכשיר לפני מיזוג (אותם ערכים שונו גם במכשיר אחר)")
        }
        let changedBefore = localChangedAt
        apply(merged, backupFirst: false)
        lastSeenRevision = remote.revision
        writeBase(remote.data, hid: hid, revision: remote.revision)
        if SyncMerge.equal(result.value, r) {
            if localChangedAt == changedBefore { localChangedAt = nil }
            markSynced("עודכן מ-" + (remote.device ?? "השרת"))
        } else {
            try await push(store, hid: hid, expected: remote.revision)
        }
    }

    // MARK: The base — the last version this device and the server agreed on

    private struct Base: Codable {
        let household: UUID
        let revision: Int64
        let family: FamilyBackup
    }

    private static var baseURL: URL { SecureFile.folder.appendingPathComponent("sync_base.json") }

    private func writeBase(_ family: FamilyBackup, hid: UUID, revision: Int64) {
        guard let data = try? JSONEncoder().encode(Base(household: hid, revision: revision, family: family)) else { return }
        try? SecureFile.write(data, to: ServerSync.baseURL)
    }

    /// The base, only if it's of this household and of the revision this device last saw.
    private func readBase(hid: UUID) -> FamilyBackup? {
        guard let data = SecureFile.read(ServerSync.baseURL),
              let base = try? JSONDecoder().decode(Base.self, from: data),
              base.household == hid, base.revision == lastSeenRevision else { return nil }
        return base.family
    }

    private func push(_ store: Store, hid: UUID, expected: Int64) async throws {
        struct Params: Encodable {
            let hid: UUID
            let p_data: AnyJSON
            let expected_revision: Int64
            let p_device: String
        }
        let changedBefore = localChangedAt
        let sent = store.familyBackup
        let result = try await supabase.rpc("save_household_data", params: Params(
            hid: hid, p_data: try .appJSON(sent), expected_revision: expected, p_device: Platform.deviceName
        )).decoded(SaveResult.self)
        if result.ok, let revision = result.revision {
            lastSeenRevision = revision
            writeBase(sent, hid: hid, revision: revision)
            // A change made while saving stays pending for the next round.
            if localChangedAt == changedBefore { localChangedAt = nil }
            markSynced("נשמר בשרת")
        } else {
            // Someone saved in between — the next round loads it and decides.
            status = "יש גרסה חדשה בשרת — מסנכרן…"
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await sync()
            }
        }
    }

    private func handle(_ error: Error) {
        let text = String(describing: error).lowercased()
        if text.contains("not a member") || text.contains("pgrst116") {
            // Removed from the household, or it was deleted.
            Task { await account?.refreshHouseholds(); await accountChanged() }
            return
        }
        lastError = UserAccount.describe(error)
    }

    private func markSynced(_ message: String) {
        // From now on the data on this device belongs to this account.
        if let me = account?.userID { dataOwner = me }
        status = message
        lastError = nil
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: "syncLastSync")
    }

    // MARK: Applying

    private func apply(_ remote: FamilyBackup, backupFirst: Bool) {
        guard let store else { return }
        // The version being replaced goes to the server's history (not to a file on the device).
        if backupFirst, let hid = linkedHouseholdID {
            let current = store.familyBackup
            Task { await uploadVersion(current, to: hid, note: "גרסה מהמכשיר שהוחלפה בסנכרון") }
        }
        var family = remote
        guard !family.state.members.isEmpty else { return }
        // Which member is being edited / shown is per device.
        let ids = Set(family.state.members.map(\.id))
        if ids.contains(store.activeMemberID) { family.state.activeID = store.activeMemberID }
        if !ids.contains(family.state.activeID) { family.state.activeID = family.state.primaryID }
        let view = store.viewMemberIDs.filter { ids.contains($0) }
        if !view.isEmpty { family.state.viewIDs = family.state.members.map(\.id).filter { view.contains($0) } }
        if !family.state.viewIDs.contains(family.state.activeID) { family.state.viewIDs.append(family.state.activeID) }
        applyingRemote = true
        store.restoreFamily(family)
        applyingRemote = false
    }

    /// Adds a version to the household's history on the server (newest 30 are kept).
    func uploadVersion(_ family: FamilyBackup, to hid: UUID, note: String) async {
        struct Params: Encodable { let hid: UUID; let p_data: AnyJSON; let p_device: String; let p_note: String }
        do {
            try await supabase.rpc("save_household_snapshot", params: Params(
                hid: hid, p_data: try .appJSON(family), p_device: Platform.deviceName, p_note: note)).execute()
        } catch {
            lastError = UserAccount.describe(error)
        }
    }

    // MARK: Version history (replaces local backups)

    struct Version: Decodable, Identifiable {
        let id: Int64
        let revision: Int64
        let saved_at: String
        let device: String?
        let note: String?
        var date: Date? { ISO8601DateFormatter.flexible(saved_at) }
    }

    /// The household's previous versions on the server, newest first (without their data).
    func versions() async throws -> [Version] {
        guard let hid = linkedHouseholdID else { return [] }
        return try await supabase.from("household_snapshots").select("id,revision,saved_at,device,note")
            .eq("household_id", value: hid).order("saved_at", ascending: false).decoded([Version].self)
    }

    /// Brings back an earlier version: it becomes the current one on every device (what's there now joins the history).
    func restore(_ version: Version) async throws {
        struct Row: Decodable { let data: FamilyBackup }
        let row = try await supabase.from("household_snapshots").select("data").eq("id", value: Int(version.id))
            .single().decoded(Row.self)
        apply(row.data, backupFirst: false)
        localChangedAt = Date()
        await sync()
    }

    var linkedHouseholdIDForDisplay: UUID? { linkedHouseholdID }

    /// A fresh household: one member ("אני"), starter budget, the current tax rates.
    static func emptyFamily(rates store: Store) -> FamilyBackup {
        let me = FamilyMember(name: "אני")
        var budget = Budget.starter
        budget.rates = store.budget.rates
        let file = Store.SaveFile(budget: budget, history: [], ratesURL: nil, lastRatesCheck: nil, money: MoneyData())
        return FamilyBackup(state: FamilyState(members: [me], primaryID: me.id, activeID: me.id, viewIDs: [me.id]),
                            files: [me.id.uuidString: file])
    }

    // MARK: Cache of the households not on screen

    private struct Cached: Codable {
        let revision: Int64
        let family: FamilyBackup
    }

    private static var cacheFolder: URL {
        let folder = Store.fileURL.deletingLastPathComponent().appendingPathComponent("households", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func cacheCurrent() {
        guard let store, let id = linkedHouseholdID else { return }
        let cached = Cached(revision: lastSeenRevision, family: store.familyBackup)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: ServerSync.cacheFolder.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
        }
    }

    private static func readCache(_ id: UUID) -> Cached? {
        guard let data = try? Data(contentsOf: cacheFolder.appendingPathComponent(id.uuidString + ".json")) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private static func clearCaches() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }
}

// MARK: - Three-way merge of the household document

/// Merges this device's version and the server's against the last version both agreed on (the base).
/// The same rules as merge.dart:
/// - A value only one side changed takes that side's value.
/// - Objects merge key by key.
/// - Lists of objects that all have a unique "id" merge item by item: items added on either side are kept,
///   an item deleted on one side is dropped unless the other side edited it, edited items merge recursively.
/// - Lists of unique strings (lists of ids) merge as sets.
/// - When both sides changed the same plain value differently, the side that changed later wins (`preferLocal`)
///   and it is counted as a conflict.
/// Without a base, everything is treated as changed on both sides: items from both are kept.
enum SyncMerge {
    private final class Missing {}
    private static let missing = Missing()

    /// The document as JSONSerialization objects, encoded exactly like the files on disk.
    static func json<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func merge(base: Any?, local: Any, remote: Any, preferLocal: Bool) -> (value: Any, conflicts: [String]) {
        var conflicts: [String] = []
        let value = merge(base ?? missing, local, remote, "", preferLocal, &conflicts)
        return (value, conflicts)
    }

    static func equal(_ a: Any, _ b: Any) -> Bool {
        if a is Missing || b is Missing { return a is Missing && b is Missing }
        guard let x = a as? NSObject, let y = b as? NSObject else { return false }
        return x.isEqual(y)
    }

    /// The ids of a list whose items are all objects with a unique, non-empty string "id"; nil otherwise.
    private static func ids(_ v: Any) -> [String]? {
        guard let list = v as? [Any] else { return nil }
        var out: [String] = []
        for item in list {
            guard let id = (item as? [String: Any])?["id"] as? String, !id.isEmpty else { return nil }
            out.append(id)
        }
        return Set(out).count == out.count ? out : nil
    }

    private static func stringSet(_ v: Any) -> [String]? {
        guard let list = v as? [Any] else { return nil }
        var out: [String] = []
        for item in list {
            guard let s = item as? String else { return nil }
            out.append(s)
        }
        return Set(out).count == out.count ? out : nil
    }

    private static func byID(_ v: Any) -> [String: Any] {
        var out: [String: Any] = [:]
        for item in v as? [Any] ?? [] {
            if let id = (item as? [String: Any])?["id"] as? String { out[id] = item }
        }
        return out
    }

    private static func merge(_ b: Any, _ l: Any, _ r: Any, _ path: String, _ preferLocal: Bool,
                              _ conflicts: inout [String]) -> Any {
        if equal(l, r) { return l }
        if equal(l, b) { return r }
        if equal(r, b) { return l }

        // Both changed it.
        if let lm = l as? [String: Any], let rm = r as? [String: Any] {
            let bm = b as? [String: Any] ?? [:]
            var out: [String: Any] = [:]
            for key in Set(lm.keys).union(rm.keys) {
                let v = merge(bm[key] ?? missing, lm[key] ?? missing, rm[key] ?? missing, path + "/" + key, preferLocal, &conflicts)
                if !(v is Missing) { out[key] = v }
            }
            return out
        }

        if ids(l) != nil, ids(r) != nil, let ll = l as? [Any], let rl = r as? [Any] {
            let bByID = ids(b) != nil ? byID(b) : [:]
            let lByID = byID(l), rByID = byID(r)
            var out: [Any] = []
            for item in rl {
                guard let id = (item as? [String: Any])?["id"] as? String else { continue }
                if let mine = lByID[id] {
                    out.append(merge(bByID[id] ?? missing, mine, item, path + "[" + id + "]", preferLocal, &conflicts))
                } else if let old = bByID[id] {
                    // Deleted here; kept only if the server edited it.
                    if !equal(item, old) { out.append(item); conflicts.append(path + "[" + id + "]") }
                } else {
                    out.append(item)     // added on the server
                }
            }
            for item in ll {
                guard let id = (item as? [String: Any])?["id"] as? String, rByID[id] == nil else { continue }
                if let old = bByID[id] {
                    // Deleted on the server; kept only if edited here.
                    if !equal(item, old) { out.append(item); conflicts.append(path + "[" + id + "]") }
                } else {
                    out.append(item)     // added here
                }
            }
            return out
        }

        if let ls = stringSet(l), let rs = stringSet(r) {
            let bSet = Set(stringSet(b) ?? []), lSet = Set(ls), rSet = Set(rs)
            return rs.filter { lSet.contains($0) || !bSet.contains($0) }
                + ls.filter { !rSet.contains($0) && !bSet.contains($0) }
        }

        // The same plain value changed on both sides.
        if r is Missing { return l }     // deleted on the server, changed here: keep the change
        if l is Missing { return r }
        conflicts.append(path)
        return preferLocal ? l : r
    }
}

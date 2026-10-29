import Foundation
import SwiftUI
import Supabase

/// Keeps the household on screen in sync with the server.
///
/// The files on this device stay the app's working copy (it works offline as before). Each save on the
/// server gets a new revision; the device remembers the revision it last saw. When only the server changed,
/// its version is loaded; when only this device changed, it's saved; when both changed, the newer one wins
/// and the other is kept as a backup (and the server keeps its last 30 versions).
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
    /// Signed in for the first time with data already on this device, and the account has households:
    /// ask whether to upload this data as a new household or use one from the server.
    @Published var pendingLocalChoice = false

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

    /// First time this device's data meets the account.
    private func linkLocalData() async {
        guard let account, let store else { return }
        // Whatever happens next, this device's data is kept as a backup first.
        if account.households.isEmpty {
            // New account: this device's data becomes their first household.
            await createHousehold(name: "משק הבית שלי", from: store.familyBackup)
        } else if ServerSync.isEmpty(store) {
            await switchTo(account.activeHouseholdID ?? account.households[0].id, cacheCurrent: false)
        } else {
            pendingLocalChoice = true
        }
    }

    /// The answer to `pendingLocalChoice`.
    func resolveLocalChoice(uploadAsNew: Bool) async {
        pendingLocalChoice = false
        guard let account, let store else { return }
        if uploadAsNew {
            await createHousehold(name: "משק הבית שלי (מהמכשיר)", from: store.familyBackup)
        } else {
            // This device's data joins the household's version history on the server before it's replaced.
            let target = account.activeHouseholdID ?? account.households[0].id
            await uploadVersion(store.familyBackup, to: target, note: "הנתונים שהיו במכשיר לפני החיבור לחשבון")
            await switchTo(target, cacheCurrent: false)
        }
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
                let remoteDate = ISO8601DateFormatter.flexible(remote.updated_at) ?? .distantPast
                if let mine = localChangedAt, mine > remoteDate {
                    // Both changed, this device is newer: keep the server's version as a backup, then save ours.
                    // The server's version stays in its history automatically when ours replaces it.
                    try await push(store, hid: hid, expected: remote.revision)
                } else {
                    apply(remote.data, backupFirst: localChangedAt != nil)
                    localChangedAt = nil
                    lastSeenRevision = remote.revision
                    markSynced("עודכן מ-" + (remote.device ?? "השרת"))
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

    private func push(_ store: Store, hid: UUID, expected: Int64) async throws {
        struct Params: Encodable {
            let hid: UUID
            let p_data: AnyJSON
            let expected_revision: Int64
            let p_device: String
        }
        let changedBefore = localChangedAt
        let result = try await supabase.rpc("save_household_data", params: Params(
            hid: hid, p_data: try .appJSON(store.familyBackup), expected_revision: expected, p_device: Platform.deviceName
        )).decoded(SaveResult.self)
        if result.ok, let revision = result.revision {
            lastSeenRevision = revision
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

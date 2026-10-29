import Foundation

// MARK: - Family members

/// One person (or a shared "household") with their own payslip, accounts, card and history.
/// The family can be viewed one member at a time, or several members together.
struct FamilyMember: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var emoji: String = "🙂"

    private enum CodingKeys: String, CodingKey { case id, name, emoji }

    var title: String { emoji + " " + name }
}

extension FamilyMember {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🙂"
    }
}

/// Saved in family.json next to the data file.
struct FamilyState: Codable {
    var members: [FamilyMember]
    /// The member whose data lives in the original maskoret-data.json.
    var primaryID: UUID
    /// The member being edited.
    var activeID: UUID
    /// Members included in the summary, forecast and AI insights.
    var viewIDs: [UUID]

    private enum CodingKeys: String, CodingKey { case members, primaryID, activeID, viewIDs }

    init(members: [FamilyMember], primaryID: UUID, activeID: UUID, viewIDs: [UUID]) {
        self.members = members
        self.primaryID = primaryID
        self.activeID = activeID
        self.viewIDs = viewIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? c.decodeIfPresent([FamilyMember].self, forKey: .members)) ?? []
        if members.isEmpty { members = [FamilyMember(name: "אני")] }
        primaryID = (try? c.decodeIfPresent(UUID.self, forKey: .primaryID)) ?? members[0].id
        activeID = (try? c.decodeIfPresent(UUID.self, forKey: .activeID)) ?? primaryID
        viewIDs = (try? c.decodeIfPresent([UUID].self, forKey: .viewIDs)) ?? [activeID]
    }
}

/// All members inside one backup file.
struct FamilyBackup: Codable {
    var state: FamilyState
    /// member id → that member's data
    var files: [String: Store.SaveFile]
}

// MARK: - What the dashboards look at

/// Budget, money and history — of one member, or several members merged into one household view.
struct DataSnapshot {
    var budget: Budget
    var money: MoneyData
    var history: [MonthRecord]

    func record(year: Int, month: Int) -> MonthRecord? {
        history.first { $0.year == year && $0.month == month }
    }

    /// Merges members for the "together" view. Each member's tax is calculated on their own payslip,
    /// so the household gets everyone's *net*; percent expenses become their amount in shekels.
    static func combine(_ parts: [(member: FamilyMember, file: Store.SaveFile)], base: Budget, baseMoney: MoneyData) -> DataSnapshot {
        var budget = base
        budget.incomes = []
        budget.deductions = []
        budget.expenses = []
        budget.trackedItems = []

        var money = MoneyData()
        money.accounts = []
        money.forecast = baseMoney.forecast
        money.primeRate = baseMoney.primeRate
        money.primeAuto = baseMoney.primeAuto
        money.boiRate = baseMoney.boiRate
        money.primeCheckedAt = baseMoney.primeCheckedAt
        money.nextRateDecision = baseMoney.nextRateDecision
        money.rateLastChanged = baseMoney.rateLastChanged

        var seenCards = Set<String>()
        var records: [Int: [MonthRecord]] = [:]

        for (member, file) in parts {
            let b = file.budget
            let tag = member.emoji + " "
            budget.incomes.append(IncomeItem(name: member.title + " — נטו", amount: b.net, isNet: true))
            for e in b.expenses where e.isActive {
                var item = e
                item.kind = .fixed
                item.value = e.amount(base: b.expenseBase)
                item.auto = nil
                item.name = tag + e.name
                budget.expenses.append(item)
            }
            for t in b.trackedItems {
                var item = t
                item.name = tag + t.name
                budget.trackedItems.append(item)
            }

            let m = file.money ?? MoneyData()
            for a in m.accounts {
                var account = a
                account.name = tag + a.name
                money.accounts.append(account)
            }
            money.transactions += m.transactions
            // The same card imported by two members counts once.
            for t in m.cardTransactions where seenCards.insert(t.id).inserted {
                money.cardTransactions.append(t)
            }
            money.merchantRules += m.merchantRules
            money.receivables += m.receivables.map { r in
                var r = r
                r.person = tag + r.person
                return r
            }
            money.cardImports += m.cardImports
            for t in m.trends {
                var trend = t
                trend.name = tag + t.name
                money.trends.append(trend)
            }
            for r in file.history { records[r.sortKey, default: []].append(r) }
        }
        money.cardImports.sort { $0.importedAt > $1.importedAt }
        if money.accounts.isEmpty { money.accounts = [Account(name: "עו״ש", kind: .checking)] }

        // A month counts as "actual" only when every member recorded their actual net.
        let history: [MonthRecord] = records.compactMap { key, list in
            let actuals = list.compactMap { $0.actualNet }
            let sum: Double? = actuals.count == parts.count ? actuals.reduce(0, +) : nil
            return MonthRecord(year: key / 100, month: key % 100, budget: budget, actualNet: sum)
        }
        return DataSnapshot(budget: budget, money: money, history: history)
    }
}

// MARK: - Store: members

extension Store {
    static var familyURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("family.json") }

    static var membersFolder: URL {
        let folder = fileURL.deletingLastPathComponent().appendingPathComponent("members", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func loadFamily() -> FamilyState {
        if let data = SecureFile.read(familyURL),
           let state = try? JSONDecoder().decode(FamilyState.self, from: data) {
            return state
        }
        let me = FamilyMember(name: "אני")
        return FamilyState(members: [me], primaryID: me.id, activeID: me.id, viewIDs: [me.id])
    }

    func fileURL(for id: UUID) -> URL {
        id == primaryMemberID ? Store.fileURL : Store.membersFolder.appendingPathComponent(id.uuidString + ".json")
    }

    func saveFamily() {
        let state = FamilyState(members: members, primaryID: primaryMemberID, activeID: activeMemberID,
                                viewIDs: members.map(\.id).filter { viewMemberIDs.contains($0) })
        if let data = try? JSONEncoder().encode(state) {
            try? SecureFile.write(data, to: Store.familyURL)
        }
        onDataChange?()
    }

    var activeMember: FamilyMember? { members.first { $0.id == activeMemberID } }
    var hasFamily: Bool { members.count > 1 }
    var isCombined: Bool { viewMemberIDs.count > 1 }
    var viewedMembers: [FamilyMember] { members.filter { viewMemberIDs.contains($0.id) } }

    /// What the summary, forecast, sidebar and AI insights show.
    var dashboard: DataSnapshot {
        guard isCombined else { return DataSnapshot(budget: budget, money: money, history: history) }
        let parts: [(member: FamilyMember, file: SaveFile)] = viewedMembers.compactMap { m in
            let file = m.id == activeMemberID ? currentFile : memberFiles[m.id]
            return file.map { (m, $0) }
        }
        return DataSnapshot.combine(parts, base: budget, baseMoney: money)
    }

    /// Start editing another member (their data becomes the app's current data).
    func setEditing(_ id: UUID) {
        guard id != activeMemberID, members.contains(where: { $0.id == id }) else { return }
        save()
        memberFiles[activeMemberID] = currentFile
        let file = memberFiles.removeValue(forKey: id) ?? newMemberFile()
        suppressSave = true
        activeMemberID = id
        apply(file)
        suppressSave = false
        viewMemberIDs.insert(id)
        if !isCombined { viewMemberIDs = [id] }
        save()
        saveFamily()
    }

    /// Show only this member (and edit them).
    func showOnly(_ id: UUID) {
        viewMemberIDs = [id]
        if id != activeMemberID { setEditing(id) } else { saveFamily() }
    }

    /// Add / remove a member from the "together" view.
    func toggleInView(_ id: UUID) {
        if viewMemberIDs.contains(id) {
            guard viewMemberIDs.count > 1 else { return }
            viewMemberIDs.remove(id)
            if id == activeMemberID, let next = members.first(where: { viewMemberIDs.contains($0.id) }) {
                setEditing(next.id)
                return
            }
        } else {
            viewMemberIDs.insert(id)
        }
        saveFamily()
    }

    func showEveryone() {
        viewMemberIDs = Set(members.map(\.id))
        saveFamily()
    }

    private func newMemberFile() -> SaveFile {
        var b = Budget.starter
        b.rates = budget.rates
        var m = MoneyData()
        m.primeRate = money.primeRate
        m.primeAuto = money.primeAuto
        m.boiRate = money.boiRate
        m.nextRateDecision = money.nextRateDecision
        return SaveFile(budget: b, history: [], ratesURL: ratesURL, lastRatesCheck: lastRatesCheck, money: m)
    }

    /// Adds a member with empty data and switches to them.
    func addMember(name: String, emoji: String) {
        let member = FamilyMember(name: name.isEmpty ? "בן משפחה" : name, emoji: emoji.isEmpty ? "🙂" : emoji)
        let file = newMemberFile()
        if let data = try? JSONEncoder().encode(file) {
            try? SecureFile.write(data, to: fileURL(for: member.id))
        }
        members.append(member)
        memberFiles[member.id] = file
        setEditing(member.id)
        viewMemberIDs = [member.id]
        saveFamily()
    }

    func updateMember(_ member: FamilyMember) {
        guard let i = members.firstIndex(where: { $0.id == member.id }) else { return }
        members[i] = member
        saveFamily()
    }

    /// Deletes a member and their data (not the first one).
    func deleteMember(_ id: UUID) {
        guard id != primaryMemberID, members.count > 1 else { return }
        if id == activeMemberID { setEditing(primaryMemberID) }
        members.removeAll { $0.id == id }
        memberFiles[id] = nil
        viewMemberIDs.remove(id)
        if viewMemberIDs.isEmpty { viewMemberIDs = [activeMemberID] }
        try? FileManager.default.removeItem(at: Store.membersFolder.appendingPathComponent(id.uuidString + ".json"))
        saveFamily()
    }

    // MARK: Backups with everyone

    var familyBackup: FamilyBackup {
        var files: [String: SaveFile] = [:]
        for m in members {
            files[m.id.uuidString] = m.id == activeMemberID ? currentFile : memberFiles[m.id]
        }
        let state = FamilyState(members: members, primaryID: primaryMemberID, activeID: activeMemberID,
                                viewIDs: members.map(\.id).filter { viewMemberIDs.contains($0) })
        return FamilyBackup(state: state, files: files)
    }

    func restoreFamily(_ backup: FamilyBackup) {
        let state = backup.state
        // Write every member's file, then load the active one.
        suppressSave = true
        primaryMemberID = state.primaryID
        members = state.members
        memberFiles = [:]
        for m in state.members {
            guard let file = backup.files[m.id.uuidString] else { continue }
            if let data = try? JSONEncoder().encode(file) { try? SecureFile.write(data, to: fileURL(for: m.id)) }
            if m.id != state.activeID { memberFiles[m.id] = file }
        }
        activeMemberID = state.activeID
        if let active = backup.files[state.activeID.uuidString] { apply(active) }
        viewMemberIDs = Set(state.viewIDs.filter { id in state.members.contains { $0.id == id } })
        if viewMemberIDs.isEmpty { viewMemberIDs = [activeMemberID] }
        suppressSave = false
        save()
        saveFamily()
    }
}

// MARK: - Encrypted local copy

extension Store {
    /// Older versions kept the files as plain JSON; they're rewritten encrypted (the content doesn't change).
    func encryptLocalCopyIfNeeded() {
        let fm = FileManager.default
        let plain = [Store.fileURL, Store.familyURL] + ((try? fm.contentsOfDirectory(at: Store.membersFolder, includingPropertiesForKeys: nil)) ?? [])
        guard plain.contains(where: { fm.fileExists(atPath: $0.path) && !SecureFile.isEncrypted($0) }) else { return }
        let backup = familyBackup
        for m in members {
            guard let file = backup.files[m.id.uuidString], let data = try? JSONEncoder().encode(file) else { continue }
            try? SecureFile.write(data, to: fileURL(for: m.id))
        }
        if let data = try? JSONEncoder().encode(backup.state) { try? SecureFile.write(data, to: Store.familyURL) }
        if let data = SecureFile.read(InsightsEngine.fileURL), !SecureFile.isEncrypted(InsightsEngine.fileURL) {
            try? SecureFile.write(data, to: InsightsEngine.fileURL)
        }
    }
}

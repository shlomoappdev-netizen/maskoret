import Foundation
import SwiftUI

/// Holds all app data and persists it as JSON in Application Support.
final class Store: ObservableObject {
    /// Where updated tax rates are published. Edit in "נתוני מס" if you host the file elsewhere.
    static let defaultRatesURL = ""
    static let legacyRatesURL = "https://raw.githubusercontent.com/Shlomo116/maskoret-rates/main/tax-rates.json"

    @Published var budget: Budget {
        didSet { save() }
    }

    @Published var history: [MonthRecord] {
        didSet { save() }
    }

    @Published var ratesURL: String {
        didSet { save() }
    }

    @Published var lastRatesCheck: Date? {
        didSet { save() }
    }

    @Published var money: MoneyData {
        didSet {
            MoneyCalc.prime = money.primeRate
            save()
        }
    }

    @Published var ratesStatus: String = ""
    @Published var isCheckingRates = false

    // MARK: Family
    @Published var members: [FamilyMember] = []
    /// The member being edited — `budget`, `money` and `history` are theirs.
    @Published var activeMemberID = UUID()
    /// Members shown together in the summary, forecast, sidebar and AI insights.
    @Published var viewMemberIDs: Set<UUID> = []
    var primaryMemberID = UUID()
    /// Data of the members not being edited right now.
    var memberFiles: [UUID: SaveFile] = [:]
    var suppressSave = false
    /// Called after every save (used by the iCloud sync).
    var onDataChange: (() -> Void)?

    struct SaveFile: Codable {
        var budget: Budget
        var history: [MonthRecord]
        var ratesURL: String?
        var lastRatesCheck: Date?
        var money: MoneyData?

        init(budget: Budget, history: [MonthRecord], ratesURL: String?, lastRatesCheck: Date?, money: MoneyData?) {
            self.budget = budget
            self.history = history
            self.ratesURL = ratesURL
            self.lastRatesCheck = lastRatesCheck
            self.money = money
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            budget = try c.decodeIfPresent(Budget.self, forKey: .budget) ?? .starter
            history = (try? c.decodeIfPresent([MonthRecord].self, forKey: .history)) ?? []
            ratesURL = try? c.decodeIfPresent(String.self, forKey: .ratesURL)
            lastRatesCheck = try? c.decodeIfPresent(Date.self, forKey: .lastRatesCheck)
            money = try? c.decodeIfPresent(MoneyData.self, forKey: .money)
        }
    }

    static var fileURL: URL {
        // ~/Library/Application Support/Maskoret/maskoret-data.json
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Maskoret", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("maskoret-data.json")
    }

    static func readFile(_ url: URL) -> SaveFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SaveFile.self, from: data)
    }

    init() {
        let family = Store.loadFamily()
        let primary = family.primaryID
        func url(_ id: UUID) -> URL {
            id == primary ? Store.fileURL : Store.membersFolder.appendingPathComponent(id.uuidString + ".json")
        }
        let activeID = family.members.contains { $0.id == family.activeID } ? family.activeID : primary
        var others: [UUID: SaveFile] = [:]
        for m in family.members where m.id != activeID {
            if let f = Store.readFile(url(m.id)) { others[m.id] = f }
        }
        if let file = Store.readFile(url(activeID)) {
            var loaded = file.budget
            // A newer app version may ship newer rates than the saved ones.
            if loaded.rates.version < TaxRates.bundled.version {
                loaded.rates = .bundled
            }
            budget = loaded
            history = file.history
            ratesURL = (file.ratesURL == Store.legacyRatesURL ? nil : file.ratesURL) ?? Store.defaultRatesURL
            lastRatesCheck = file.lastRatesCheck
            money = file.money ?? MoneyData()
            MoneyCalc.prime = money.primeRate
        } else {
            budget = .starter
            history = []
            ratesURL = Store.defaultRatesURL
            lastRatesCheck = nil
            money = MoneyData()
        }
        members = family.members
        primaryMemberID = primary
        activeMemberID = activeID
        memberFiles = others
        let view = Set(family.viewIDs.filter { id in family.members.contains { $0.id == id } })
        viewMemberIDs = view.isEmpty ? [activeID] : view
        viewMemberIDs.insert(activeID)
        if !FileManager.default.fileExists(atPath: Store.familyURL.path) { saveFamily() }
    }

    func save() {
        guard !suppressSave else { return }
        let file = SaveFile(budget: budget, history: history, ratesURL: ratesURL, lastRatesCheck: lastRatesCheck, money: money)
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL(for: activeMemberID), options: [.atomic])
            onDataChange?()
        } catch {
            print("Save failed: \(error)")
        }
    }

    /// Replaces everything with the contents of a saved file (used by restore from backup).
    func apply(_ file: SaveFile) {
        var loaded = file.budget
        if loaded.rates.version < TaxRates.bundled.version { loaded.rates = .bundled }
        budget = loaded
        history = file.history
        ratesURL = file.ratesURL ?? Store.defaultRatesURL
        lastRatesCheck = file.lastRatesCheck
        money = file.money ?? MoneyData()
    }

    var currentFile: SaveFile {
        SaveFile(budget: budget, history: history, ratesURL: ratesURL, lastRatesCheck: lastRatesCheck, money: money)
    }

    // MARK: Prime rate (Bank of Israel)

    @Published var primeStatus: String = ""
    @Published var isCheckingPrime = false

    private struct BOIInterest: Decodable {
        let currentInterest: Double
        let nextInterestDate: String?
        let lastPublishedDate: String?
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    /// Prime = Bank of Israel rate + 1.5%. Checked a few times a day, and right after a rate decision.
    @MainActor
    func refreshPrime(force: Bool = false) async {
        guard money.primeAuto || force else { return }
        if !force, let last = money.primeCheckedAt {
            let decisionPassed = money.nextRateDecision.map { $0 <= Date() && $0 > last } ?? false
            if Date().timeIntervalSince(last) < 6 * 3600 && !decisionPassed { return }
        }
        guard let url = URL(string: "https://www.boi.org.il/PublicApi/GetInterest") else { return }
        isCheckingPrime = true
        defer { isCheckingPrime = false }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let info = try JSONDecoder().decode(BOIInterest.self, from: data)
            let newPrime = ((info.currentInterest + 1.5) * 100).rounded() / 100
            var updated = money
            if abs(updated.primeRate - newPrime) > 0.001 {
                updated.rateLastChanged = Date()
                primeStatus = "הפריים עודכן ל-" + Fmt.percent(newPrime)
            } else {
                primeStatus = "הפריים מעודכן"
            }
            updated.primeRate = newPrime
            updated.boiRate = info.currentInterest
            updated.nextRateDecision = Store.parseDate(info.nextInterestDate)
            updated.primeCheckedAt = Date()
            money = updated
        } catch {
            primeStatus = "לא ניתן להתחבר לבנק ישראל כרגע — משתמש בפריים השמור"
        }
    }

    // MARK: Tax rates auto-update

    /// Downloads the latest rates file and applies it when it is newer than what we have.
    @MainActor
    func refreshRates(force: Bool = false) async {
        // 1) Rates file shipped with updates in the local project folder.
#if os(macOS)
        let localFile = Updater.sourceFolder.appendingPathComponent("rates/tax-rates.json")
        if let data = try? Data(contentsOf: localFile),
           let local = try? JSONDecoder().decode(TaxRates.self, from: data),
           local.version > budget.rates.version {
            budget.rates = local
            ratesStatus = "עודכן לנתוני \(local.year) (\(local.updated)) מתיקיית הפרויקט"
        }
        #endif

        // 2) Optional online file.
        if !force, let last = lastRatesCheck, Date().timeIntervalSince(last) < 12 * 3600 {
            return
        }
        let trimmed = ratesURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" else {
            if ratesStatus.isEmpty { ratesStatus = "השיעורים מתעדכנים יחד עם עדכוני האפליקציה" }
            return
        }
        isCheckingRates = true
        defer { isCheckingRates = false }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let remote = try JSONDecoder().decode(TaxRates.self, from: data)
            lastRatesCheck = Date()
            if remote.version > budget.rates.version {
                budget.rates = remote
                ratesStatus = "עודכן לנתוני \(remote.year) (\(remote.updated))"
            } else {
                ratesStatus = "הנתונים מעודכנים"
            }
        } catch {
            ratesStatus = "לא ניתן לבדוק עדכונים כרגע — משתמש בנתונים השמורים"
        }
    }

    // MARK: Items

    func upsertIncome(_ item: IncomeItem) {
        var item = item
        if item.name.trimmingCharacters(in: .whitespaces).isEmpty { item.name = "הכנסה" }
        if let i = budget.incomes.firstIndex(where: { $0.id == item.id }) {
            budget.incomes[i] = item
        } else {
            budget.incomes.append(item)
        }
    }

    func upsertCost(_ item: CostItem, in keyPath: WritableKeyPath<Budget, [CostItem]>) {
        var item = item
        if item.name.trimmingCharacters(in: .whitespaces).isEmpty { item.name = "ללא שם" }
        if let i = budget[keyPath: keyPath].firstIndex(where: { $0.id == item.id }) {
            budget[keyPath: keyPath][i] = item
        } else {
            budget[keyPath: keyPath].append(item)
        }
    }

    func hasAutoDeduction(_ type: AutoDeduction) -> Bool {
        budget.deductions.contains { $0.auto == type }
    }

    func upsertTracked(_ item: TrackedItem) {
        var item = item
        if item.name.trimmingCharacters(in: .whitespaces).isEmpty { item.name = "פריט" }
        if let i = budget.trackedItems.firstIndex(where: { $0.id == item.id }) {
            budget.trackedItems[i] = item
        } else {
            budget.trackedItems.append(item)
        }
    }

    func addPurchase(_ purchase: Purchase, to itemID: UUID) {
        guard let i = budget.trackedItems.firstIndex(where: { $0.id == itemID }) else { return }
        if let p = budget.trackedItems[i].purchases.firstIndex(where: { $0.id == purchase.id }) {
            budget.trackedItems[i].purchases[p] = purchase
        } else {
            budget.trackedItems[i].purchases.append(purchase)
        }
    }

    func deletePurchase(_ purchaseID: UUID, from itemID: UUID) {
        guard let i = budget.trackedItems.firstIndex(where: { $0.id == itemID }) else { return }
        budget.trackedItems[i].purchases.removeAll { $0.id == purchaseID }
    }

    // MARK: History

    var sortedHistory: [MonthRecord] {
        history.sorted { $0.sortKey > $1.sortKey }
    }

    func record(year: Int, month: Int) -> MonthRecord? {
        history.first { $0.year == year && $0.month == month }
    }

    func saveMonth(year: Int, month: Int, note: String, actualNet: Double? = nil, addToChecking: Bool = false) {
        if let i = history.firstIndex(where: { $0.year == year && $0.month == month }) {
            history[i] = MonthRecord(id: history[i].id, year: year, month: month, note: note, budget: budget, actualNet: actualNet)
        } else {
            history.append(MonthRecord(year: year, month: month, note: note, budget: budget, actualNet: actualNet))
        }

        // Optionally record the salary as an income into the checking account.
        let key = year * 100 + month
        money.transactions.removeAll { $0.salaryKey == key }
        if addToChecking, let net = actualNet, net > 0, let checking = money.checking {
            var parts = DateComponents()
            parts.year = year
            parts.month = month
            parts.day = 1
            let monthStart = Calendar.current.date(from: parts) ?? Date()
            let monthEnd = Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart) ?? Date()
            let date = min(Date(), monthEnd)
            money.transactions.append(MoneyTransaction(
                date: date,
                title: "משכורת " + Fmt.monthNames[month - 1],
                amount: net,
                kind: .income,
                accountID: checking.id,
                salaryKey: key
            ))
        }
    }

    // MARK: Money

    func value(of account: Account, on date: Date = Date()) -> Double {
        MoneyCalc.value(of: account, on: date, transactions: money.transactions)
    }

    /// Totals of the members in view (one member, or the family together).
    private func total(_ kinds: [AccountKind], in m: MoneyData) -> Double {
        m.accounts.filter { kinds.contains($0.kind) }
            .reduce(0) { $0 + MoneyCalc.value(of: $1, on: Date(), transactions: m.transactions) }
    }

    var checkingNow: Double { total([.checking], in: dashboard.money) }
    var savingsNow: Double { total([.savings, .deposit], in: dashboard.money) }
    var pensionNow: Double { total([.pension], in: dashboard.money) }

    /// Totals of the member being edited only.
    var ownChecking: Double { total([.checking], in: money) }
    var ownSavings: Double { total([.savings, .deposit], in: money) }
    var ownPension: Double { total([.pension], in: money) }

    func forecast(months: Int? = nil) -> [ForecastMonth] {
        let d = dashboard
        return Forecaster.run(budget: d.budget, money: d.money, history: d.history, months: months ?? money.forecast.months)
    }

    func upsertAccount(_ account: Account) {
        var account = account
        if account.name.trimmingCharacters(in: .whitespaces).isEmpty { account.name = account.kind.title }
        if let i = money.accounts.firstIndex(where: { $0.id == account.id }) {
            money.accounts[i] = account
        } else {
            money.accounts.append(account)
        }
    }

    func deleteAccount(_ account: Account) {
        money.accounts.removeAll { $0.id == account.id }
        money.transactions.removeAll { $0.accountID == account.id && $0.toAccountID == nil }
        for i in money.transactions.indices {
            if money.transactions[i].toAccountID == account.id { money.transactions[i].toAccountID = nil }
            if money.transactions[i].accountID == account.id { money.transactions[i].accountID = nil }
        }
        for i in budget.expenses.indices where budget.expenses[i].targetAccountID == account.id {
            budget.expenses[i].targetAccountID = nil
        }
        if money.checking == nil {
            money.accounts.insert(Account(name: "עו״ש", kind: .checking), at: 0)
        }
    }

    func addBalance(_ entry: BalanceEntry, to accountID: UUID) {
        guard let i = money.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        if let b = money.accounts[i].balances.firstIndex(where: { $0.id == entry.id }) {
            money.accounts[i].balances[b] = entry
        } else {
            money.accounts[i].balances.append(entry)
        }
    }

    func deleteBalance(_ entryID: UUID, from accountID: UUID) {
        guard let i = money.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        money.accounts[i].balances.removeAll { $0.id == entryID }
    }

    func upsertTransaction(_ transaction: MoneyTransaction) {
        var transaction = transaction
        if transaction.title.trimmingCharacters(in: .whitespaces).isEmpty { transaction.title = transaction.kind.title }
        if let i = money.transactions.firstIndex(where: { $0.id == transaction.id }) {
            money.transactions[i] = transaction
        } else {
            money.transactions.append(transaction)
        }
    }

    func deleteTransaction(_ transaction: MoneyTransaction) {
        money.transactions.removeAll { $0.id == transaction.id }
    }

    func deleteRecord(_ record: MonthRecord) {
        history.removeAll { $0.id == record.id }
    }

    /// Restores incomes, deductions and expenses from a saved month,
    /// but keeps the current purchase tracking and the latest tax rates.
    func loadIntoCurrent(_ record: MonthRecord) {
        var restored = record.budget
        restored.trackedItems = budget.trackedItems
        restored.rates = budget.rates
        budget = restored
    }
}

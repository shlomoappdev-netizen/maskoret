import Foundation

// MARK: - This month, from every source

/// One consistent picture of the current month, used by the summary, the sidebar and the stats:
/// actual net (if recorded) or the estimate, fixed expenses, periodic purchases,
/// money moved into savings (fixed transfers + savings-plan deposits) and this month's one-off transactions.
struct MonthPicture {
    struct Line: Identifiable {
        let id = UUID()
        let title: String
        let amount: Double
    }

    let year: Int
    let month: Int
    let estimatedNet: Double
    let actualNet: Double?
    let spending: [Line]
    let periodic: Double
    let toSavings: [Line]
    let oneOffs: [Line]
    /// Variable credit-card spending charged this month (not linked to a fixed expense), by category.
    var card: [Line] = []
    /// True when `card` is an average because this month's statement wasn't imported yet.
    var cardEstimated: Bool = false

    /// One payment of a purchase split into installments — only this payment comes off this month.
    struct InstallmentLine: Identifiable {
        let id = UUID()
        let merchant: String
        let number: Int
        let of: Int
        /// Charged this month (your part).
        let amount: Double
        /// The whole purchase.
        let total: Double
        /// Still to pay in later months.
        let leftAfter: Double
        /// Not in an imported statement yet — expected by the plan.
        let expected: Bool

        var paymentsLeft: Int { max(0, of - number) }
        var title: String {
            "\(merchant) — תשלום \(number)/\(of) מתוך \(Fmt.money(total))" + (expected ? " (צפוי)" : "")
        }
        var detail: String {
            paymentsLeft == 0 ? "תשלום אחרון" : "נשארו עוד \(paymentsLeft) תשלומים · \(Fmt.money(leftAfter))"
        }
    }

    /// Bought this month in installments, first payment in a later month — shown, not counted.
    struct LaterInstallmentPurchase: Identifiable {
        let id = UUID()
        let merchant: String
        let total: Double
        let count: Int
        let firstPayment: Double
        let firstCharge: Date?
    }

    var installments: [InstallmentLine] = []
    var laterInstallmentPurchases: [LaterInstallmentPurchase] = []
    /// Every installment still to be charged after this month (all active purchases).
    var installmentsAfterThisMonth: Double = 0
    let daysLeft: Int

    var net: Double { actualNet ?? estimatedNet }
    var isActual: Bool { actualNet != nil }
    var spendingTotal: Double { spending.reduce(0) { $0 + $1.amount } }
    var toSavingsTotal: Double { toSavings.reduce(0) { $0 + $1.amount } }
    var cardTotal: Double { card.reduce(0) { $0 + $1.amount } }
    var installmentsTotal: Double { installments.reduce(0) { $0 + $1.amount } }
    /// The full price of the purchases whose payment is charged this month.
    var installmentsFullPrice: Double { installments.reduce(0) { $0 + $1.total } }
    /// Card spending including this month's installment payments.
    var cardWithInstallments: Double { cardTotal + installmentsTotal }
    /// Positive = money came in, negative = went out.
    var oneOffTotal: Double { oneOffs.reduce(0) { $0 + $1.amount } }
    var remaining: Double { net - spendingTotal - periodic - toSavingsTotal - cardWithInstallments + oneOffTotal }
    var outTotal: Double { spendingTotal + periodic + toSavingsTotal + cardWithInstallments - min(oneOffTotal, 0) }
    var title: String { Fmt.monthTitle(year: year, month: month) }
}

extension Store {
    var monthPicture: MonthPicture {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let monthStart = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
        let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) ?? now
        let daysLeft = max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: now), to: monthEnd).day ?? 1))
        let d = dashboard
        let budget = d.budget
        let money = d.money

        var spending: [MonthPicture.Line] = []
        var toSavings: [MonthPicture.Line] = []
        for item in budget.expenses where item.isActive {
            let amount = item.amount(base: budget.expenseBase)
            guard amount != 0 else { continue }
            if let target = money.account(item.targetAccountID) {
                toSavings.append(.init(title: item.name + " ← " + target.name, amount: amount))
            } else {
                spending.append(.init(title: item.name, amount: amount))
            }
        }

        // Automatic monthly deposits into savings plans.
        for account in money.accounts where account.kind == .savings || account.kind == .deposit {
            guard account.monthlyContribution > 0 else { continue }
            if let start = account.startDate, start >= monthEnd { continue }
            if let maturity = account.maturityDate, maturity < monthStart { continue }
            toSavings.append(.init(title: "הפקדה ל" + account.name, amount: account.monthlyContribution))
        }

        // One-off transactions this month that touch the checking account (salary excluded).
        var oneOffs: [MonthPicture.Line] = []
        let checkingIDs = money.accounts.filter { $0.kind == .checking }.map(\.id)
        let reimbursements = money.reimbursementIncomeIDs
        do {
            for t in money.transactions where t.salaryKey == nil && t.date >= monthStart && t.date < monthEnd {
                // Money paid back by someone isn't income.
                if reimbursements.contains(t.id) { continue }
                // Several members' checking accounts count as one (a transfer between them cancels out).
                var change = checkingIDs.reduce(0.0) { $0 + t.effect(on: $1) }
                // The part of an expense someone owes you isn't your spending.
                if t.kind == .expense, change < 0 { change = min(0, change + money.owedPortion(transaction: t.id)) }
                guard change != 0 else { continue }
                if t.kind == .transfer {
                    let other = money.account(change < 0 ? t.toAccountID : t.accountID)?.name ?? "חשבון"
                    if change < 0 {
                        toSavings.append(.init(title: t.title + " ← " + other, amount: -change))
                    } else {
                        oneOffs.append(.init(title: t.title + " (מ" + other + ")", amount: change))
                    }
                } else {
                    let suspect = money.looksLikeCardPurchase(t) != nil ? " ⚠︎ נראה שזה כבר בכרטיס" : ""
                    oneOffs.append(.init(title: t.title + (t.isPlanned ? " (מתוכנן)" : "") + suspect, amount: change))
                }
            }
        }

        // Credit card: what is charged this month and isn't already a fixed expense / tracked purchase.
        // Installments get their own lines, so a big purchase shows as the part charged this month.
        let key = year * 100 + month
        var card: [MonthPicture.Line] = []
        var cardEstimated = false
        let charged = money.cardTransactions(billingKey: key)
        let summary = CardMonthSummary.of(charged)
        let hasStatement = money.cardStatementKeys.contains(key) || (money.cardStatementKeys.isEmpty && !charged.isEmpty)
        // Purchases you recorded as "paid by card" that the statements don't show yet.
        let manualCard = money.manualCardPayments
        let manualRegular = manualCard.filter { $0.of == 1 && $0.billingKey == key }
        let manualRegularTotal = manualRegular.reduce(0) { $0 + $1.amount }
        if hasStatement {
            card = summary.byCategory.map { .init(title: $0.name, amount: $0.amount) }
            card += manualRegular.map { .init(title: "💳 " + $0.title + " (צפוי בכרטיס)", amount: $0.amount) }
        } else {
            let average = money.averageCardVariable()
            let soFar = summary.variable - summary.installments + manualRegularTotal
            if average > 0 {
                card = [.init(title: "הערכה לפי ממוצע (בלי תשלומים)", amount: max(average, soFar))]
                if manualRegularTotal > average {
                    card[0] = .init(title: "הערכה — כולל קניות שרשמת באשראי", amount: soFar)
                }
                cardEstimated = true
            } else {
                card = summary.byCategory.map { .init(title: $0.name, amount: $0.amount) }
                card += manualRegular.map { .init(title: "💳 " + $0.title + " (צפוי בכרטיס)", amount: $0.amount) }
            }
        }
        // Installments: only this month's payment counts, never the whole purchase.
        let allPlans = money.installmentPlans
        let plans = Dictionary(allPlans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var installments: [MonthPicture.InstallmentLine] = []
        for t in charged where t.isVariable && t.myAmount != 0 {
            guard let inst = t.installment else { continue }
            let plan = plans[t.installmentPlanKey]
            let share = t.amount != 0 ? t.myAmount / t.amount : 1
            let later = plan?.payments.filter { $0.number > inst.number }.reduce(0) { $0 + $1.amount } ?? 0
            let total = t.originalAmount != 0 ? t.originalAmount : (plan?.total ?? t.amount * Double(inst.of))
            installments.append(.init(merchant: t.merchant, number: inst.number, of: inst.of, amount: t.myAmount,
                                      total: total * share, leftAfter: later * share, expected: false))
        }
        var installmentsAfter = 0.0
        for plan in allPlans where plan.countsAsVariable {
            for p in plan.payments where !p.imported && p.billingKey == key {
                let later = plan.payments.filter { $0.number > p.number }.reduce(0) { $0 + $1.amount }
                installments.append(.init(merchant: plan.merchant, number: p.number, of: plan.count, amount: p.amount,
                                          total: plan.total, leftAfter: later, expected: true))
            }
            installmentsAfter += plan.payments.filter { $0.billingKey > key }.reduce(0) { $0 + $1.amount }
        }
        for p in manualCard where p.of > 1 {
            if p.billingKey == key {
                let later = manualCard.filter { $0.transaction.id == p.transaction.id && $0.number > p.number }.reduce(0) { $0 + $1.amount }
                installments.append(.init(merchant: p.transaction.title, number: p.number, of: p.of, amount: p.amount,
                                          total: p.transaction.amount, leftAfter: later, expected: true))
            } else if p.billingKey > key {
                installmentsAfter += p.amount
            }
        }
        installments.sort { $0.amount > $1.amount }

        // Bought this month in installments, first charge next month or later.
        var laterPurchases: [MonthPicture.LaterInstallmentPurchase] = money.cardTransactions
            .filter { t in
                guard t.isVariable, let inst = t.installment, inst.number == 1 else { return false }
                return t.date >= monthStart && t.date < monthEnd && (t.billingKey ?? 0) > key
            }
            .sorted { $0.date < $1.date }
            .map { t in
                .init(merchant: t.merchant, total: t.originalAmount != 0 ? t.originalAmount : t.amount * Double(t.installment?.of ?? 1),
                      count: t.installment?.of ?? 1, firstPayment: t.myAmount, firstCharge: t.chargeDate)
            }
        for p in manualCard where p.number == 1 && p.billingKey > key && p.transaction.date >= monthStart && p.transaction.date < monthEnd {
            laterPurchases.append(.init(merchant: p.transaction.title, total: p.transaction.amount, count: p.of,
                                        firstPayment: p.amount, firstCharge: p.chargeDate))
        }

        return MonthPicture(
            year: year,
            month: month,
            estimatedNet: budget.net,
            actualNet: d.record(year: year, month: month)?.actualNet,
            spending: spending,
            periodic: budget.periodicTotal,
            toSavings: toSavings,
            oneOffs: oneOffs,
            card: card,
            cardEstimated: cardEstimated,
            installments: installments,
            laterInstallmentPurchases: laterPurchases,
            installmentsAfterThisMonth: installmentsAfter,
            daysLeft: daysLeft
        )
    }
}

// MARK: - Backups

struct BackupFile: Codable {
    var app: String = "Maskoret"
    var appVersion: String
    var createdAt: Date
    var data: Store.SaveFile
    /// Every family member (from 3.1). Older backups have only `data`.
    var family: FamilyBackup? = nil
}

enum BackupError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "הקובץ לא נראה כמו גיבוי של מחשבון שכר."
    }
}

extension Store {
    static let backupPrefix = "מחשבון שכר - גיבוי"

    static var autoBackupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoBackup") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoBackup") }
    }

    static var lastBackupAt: Date? {
        get { UserDefaults.standard.object(forKey: "lastBackupAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastBackupAt") }
    }

    /// iCloud Drive when available (so backups reach the cloud), otherwise next to the project.
    static var defaultBackupFolder: URL {
        #if os(iOS)
        return Platform.homeDirectory.appendingPathComponent("גיבויים", isDirectory: true)
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloud.path) {
            return iCloud.appendingPathComponent("מחשבון שכר - גיבויים", isDirectory: true)
        }
        return home.appendingPathComponent("Documents/מחשבון שכר/גיבויים", isDirectory: true)
        #endif
    }

    static var backupFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "backupFolder") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultBackupFolder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "backupFolder") }
    }

    func backupData() throws -> Data {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let file = BackupFile(appVersion: version, createdAt: Date(), data: currentFile,
                              family: members.count > 1 ? familyBackup : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    static func backupFileName(for date: Date = Date(), suffix: String = "") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "\(backupPrefix) \(f.string(from: date))\(suffix).json"
    }

    /// Writes a backup into the backup folder (one file per day) and keeps the newest 30.
    @discardableResult
    func backupNow(suffix: String = "") throws -> URL {
        let folder = Store.backupFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Store.backupFileName(suffix: suffix))
        try backupData().write(to: url, options: [.atomic])
        Store.lastBackupAt = Date()
        pruneBackups(keep: 30)
        return url
    }

    func autoBackupIfNeeded() {
        guard Store.autoBackupEnabled else { return }
        if let last = Store.lastBackupAt, Calendar.current.isDateInToday(last) { return }
        _ = try? backupNow()
    }

    func listBackups() -> [URL] {
        let folder = Store.backupFolder
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return items
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(Store.backupPrefix) }
            .sorted { modified($0) > modified($1) }
    }

    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func pruneBackups(keep: Int) {
        let all = listBackups()
        guard all.count > keep else { return }
        for url in all.dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A fresh backup in a temporary folder, ready to share (WhatsApp, Mail, AirDrop…).
    func shareableBackup() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maskoret-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Store.backupFileName())
        do {
            try backupData().write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    /// Reads a backup without applying it — to show what's inside before restoring.
    static func readBackup(at url: URL) throws -> BackupFile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let backup = try? decoder.decode(BackupFile.self, from: data) {
            return backup
        }
        // Also accept the raw data file from Application Support.
        if let raw = try? decoder.decode(SaveFile.self, from: data) {
            return BackupFile(appVersion: "?", createdAt: Date(), data: raw)
        }
        throw BackupError.unreadable
    }

    /// Restores a backup. The current data is backed up first, just in case.
    func restore(_ backup: BackupFile) {
        _ = try? backupNow(suffix: " (לפני שחזור)")
        if let family = backup.family {
            restoreFamily(family)
        } else {
            apply(backup.data)
        }
    }
}

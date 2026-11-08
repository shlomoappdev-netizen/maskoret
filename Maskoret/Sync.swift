import Foundation

// MARK: - This month, from every source

/// One consistent picture of a money period (pay day to pay day), used by the summary, the sidebar and the stats:
/// actual net (if recorded) or the estimate, fixed expenses, periodic purchases, money moved into savings and one-offs.
/// Everything already committed comes off as soon as the income is in, so `remaining` is what is really free to spend.
struct MonthPicture {
    struct Line: Identifiable {
        let id = UUID()
        let title: String
        let amount: Double
        /// An estimate (the average of past statements, a card's usual charge) — not charged yet.
        var estimate = false
    }

    let year: Int
    let month: Int
    let estimatedNet: Double
    let actualNet: Double?
    let spending: [Line]
    let periodic: Double
    let toSavings: [Line]
    let oneOffs: [Line]
    /// Variable credit-card spending bought in this period (not linked to a fixed expense), by category —
    /// whenever the card happens to charge it.
    var card: [Line] = []
    /// True when `card` includes an estimate of what's still to come, by the average of the last statements.
    var cardEstimated: Bool = false
    /// The estimate itself (0 when there is none).
    var cardEstimate: Double = 0
    /// Card purchases priced like a fixed expense but not linked to it: they may be counted twice.
    var fixedInCardSuspects: [String] = []
    /// When this period began and ends.
    var periodStart: Date? = nil
    var periodEnd: Date? = nil

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
    /// Expected to be left once the card charges this period — includes the estimate by the average of the last statements.
    var remaining: Double { net - spendingTotal - periodic - toSavingsTotal - cardWithInstallments + oneOffTotal }
    /// Left right now: only what actually went out so far, without the estimate.
    var remainingActual: Double { remaining + cardEstimate }
    /// Without the card estimates: only what was actually charged or recorded.
    var actualOnly: MonthPicture {
        var p = self
        p.card = card.filter { !$0.estimate }
        p.cardEstimated = false
        p.cardEstimate = 0
        return p
    }
    var outTotal: Double { spendingTotal + periodic + toSavingsTotal + cardWithInstallments - min(oneOffTotal, 0) }
    var title: String { Fmt.monthTitle(year: year, month: month) }
    /// "10 באוק׳ – 9 בנוב׳", or the month's name when the period is a calendar month.
    var periodTitle: String {
        let cal = Calendar.current
        guard let periodStart, let periodEnd, cal.component(.day, from: periodStart) != 1,
              let last = cal.date(byAdding: .day, value: -1, to: periodEnd) else { return title }
        let style = Date.FormatStyle().day().month(.abbreviated).locale(Fmt.locale)
        return periodStart.formatted(style) + " – " + last.formatted(style)
    }
}

extension Store {
    /// The month in view — without the card estimates when the user switched them off on the home screen.
    var monthPicture: MonthPicture {
        UserDefaults.standard.bool(forKey: Store.hideCardEstimateKey) ? fullMonthPicture.actualOnly : fullMonthPicture
    }

    /// The month in view with the card estimates, whatever the switch says.
    var fullMonthPicture: MonthPicture {
        let current = dashboard.money.period(containing: Date())
        return monthPicture(year: current.year, month: current.month)
    }

    static let hideCardEstimateKey = "hideCardEstimate"

    /// What was left of a saved month's income — the same calculation as "נשאר מההכנסה האחרונה" in the summary,
    /// with that month's own incomes, deductions and fixed expenses (the current period uses today's).
    func monthResult(_ record: MonthRecord) -> MonthPicture {
        let current = dashboard.money.period(containing: Date())
        if record.year == current.year && record.month == current.month {
            return monthPicture
        }
        return monthPicture(year: record.year, month: record.month, budget: record.budget)
    }

    /// One month: net (actual if recorded), fixed expenses, periodic purchases, savings, card charges and one-offs.
    /// `budget` overrides today's incomes/deductions/expenses (a saved month keeps its own).
    func monthPicture(year: Int, month: Int, budget override: Budget? = nil) -> MonthPicture {
        let cal = Calendar.current
        let now = Date()
        let d = dashboard
        let budget = override ?? d.budget
        let money = d.money
        let monthStart = money.periodStart(year: year, month: month)
        let monthEnd = money.periodEnd(year: year, month: month)
        let daysLeft = max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: now), to: monthEnd).day ?? 1))

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

        // Credit card: purchases count in the period they were bought in, whenever the card charges them. Fixed expenses
        // and tracked purchases already came off above, so a charge linked to one isn't counted again.
        // Installments get their own lines below, so a big purchase shows as one payment a period.
        let key = year * 100 + month
        let charged = money.cardTransactions(billingKey: key)
        let bought = money.cardTransactions.filter { $0.installment == nil && $0.date >= monthStart && $0.date < monthEnd }
        let summary = CardMonthSummary.of(bought)
        // Purchases you recorded as "paid by card" that the statements don't show yet.
        let manualCard = money.manualCardPayments
        let manualRegular = manualCard.filter { $0.of == 1 && $0.transaction.date >= monthStart && $0.transaction.date < monthEnd }
        var card: [MonthPicture.Line] = summary.byCategory.map { .init(title: $0.name, amount: $0.amount) }
        card += manualRegular.map { .init(title: "💳 " + $0.title, amount: $0.amount) }
        // What wasn't imported yet: the rest of the usual spending, by the average of the last statements.
        var cardEstimated = false
        var cardEstimate = 0.0
        let known = card.reduce(0) { $0 + $1.amount }
        let average = money.averageCardVariable()
        if average > known, monthEnd > now || card.isEmpty {
            card.append(.init(title: "עוד צפוי לפי ממוצע החודשים הקודמים", amount: average - known, estimate: true))
            cardEstimated = true
            cardEstimate = average - known
        }
        // Cards whose statements aren't imported (e.g. the bank's own card): what they usually charge.
        for s in money.cardSettings where s.monthlyEstimate > 0 {
            card.append(.init(title: "💳 " + s.displayName + " (משוער)", amount: s.monthlyEstimate, estimate: true))
        }
        // A fixed expense paid by card that isn't linked to its charge would count twice — point it out.
        let fixedAmounts = spending.map(\.amount).filter { $0 >= 20 }
        let suspects = bought.filter { t in t.isVariable && fixedAmounts.contains { abs($0 - t.myAmount) < 1 } }
        let fixedInCardSuspects = Array(Set(suspects.map(\.merchant))).sorted()
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
            cardEstimate: cardEstimate,
            fixedInCardSuspects: fixedInCardSuspects,
            periodStart: monthStart,
            periodEnd: monthEnd,
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

    /// Inside the app's own folder (wiped on sign-out) — the real history lives on the server.
    static var defaultBackupFolder: URL {
        Platform.homeDirectory.appendingPathComponent("גיבויים", isDirectory: true)
    }

    static var backupFolder: URL {
        get { defaultBackupFolder }
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

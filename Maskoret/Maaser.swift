import Foundation

// MARK: - Settings

/// What the maaser percentage is taken from.
enum MaaserBase: String, Codable, CaseIterable, Identifiable {
    case gross
    case afterIncomeTax
    case afterTaxAndNI
    case actualNet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gross: return "ברוטו מלא"
        case .afterIncomeTax: return "ברוטו פחות מס הכנסה"
        case .afterTaxAndNI: return "ברוטו פחות מס, ביטוח לאומי ובריאות"
        case .actualNet: return "נטו שנכנס בפועל"
        }
    }
}

struct MaaserDonation: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var date = Date()
    var amount: Double = 0
    var note: String = ""
}

/// Per family member — every member has their own maaser fund.
struct MaaserSettings: Codable, Equatable {
    var enabled = false
    var percent: Double = 10
    var base: MaaserBase = .afterIncomeTax
    var includeInterest = true
    var includeOneOffs = true
    /// One-off income transactions that should not count.
    var excludedIncomeIDs: [UUID] = []
    /// Fixed expenses that lower the base ("expenses that reduce what maaser is taken from").
    var deductedExpenseIDs: [UUID] = []
    /// Fixed expenses that are maaser (paid every month).
    var maaserExpenseIDs: [UUID] = []
    /// Card charges marked as maaser, and merchants whose charges are always maaser.
    var maaserCardIDs: [String] = []
    var maaserMerchants: [String] = []
    var donations: [MaaserDonation] = []
    /// First month that counts (year * 100 + month) and the balance carried into it (+ owed, − credit).
    var startKey: Int = 0
    var openingBalance: Double = 0

    private enum CodingKeys: String, CodingKey {
        case enabled, percent, base, includeInterest, includeOneOffs, excludedIncomeIDs, deductedExpenseIDs
        case maaserExpenseIDs, maaserCardIDs, maaserMerchants, donations, startKey, openingBalance
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? 10
        base = (try? c.decodeIfPresent(MaaserBase.self, forKey: .base)) ?? .afterIncomeTax
        includeInterest = (try? c.decodeIfPresent(Bool.self, forKey: .includeInterest)) ?? true
        includeOneOffs = (try? c.decodeIfPresent(Bool.self, forKey: .includeOneOffs)) ?? true
        excludedIncomeIDs = (try? c.decodeIfPresent([UUID].self, forKey: .excludedIncomeIDs)) ?? []
        deductedExpenseIDs = (try? c.decodeIfPresent([UUID].self, forKey: .deductedExpenseIDs)) ?? []
        maaserExpenseIDs = (try? c.decodeIfPresent([UUID].self, forKey: .maaserExpenseIDs)) ?? []
        maaserCardIDs = (try? c.decodeIfPresent([String].self, forKey: .maaserCardIDs)) ?? []
        maaserMerchants = (try? c.decodeIfPresent([String].self, forKey: .maaserMerchants)) ?? []
        donations = (try? c.decodeIfPresent([MaaserDonation].self, forKey: .donations)) ?? []
        startKey = (try? c.decodeIfPresent(Int.self, forKey: .startKey)) ?? 0
        openingBalance = (try? c.decodeIfPresent(Double.self, forKey: .openingBalance)) ?? 0
    }

    func isMaaser(_ tx: CardTransaction) -> Bool {
        !tx.ignored && (maaserCardIDs.contains(tx.id) || maaserMerchants.contains(tx.merchantKey))
    }
}

// MARK: - Calculation

struct MaaserMonth: Identifiable {
    let key: Int
    /// nil = the actual net for this month wasn't recorded yet, so nothing is owed for it yet.
    let base: Double?
    let salaryBase: Double
    let interest: Double
    let oneOffs: Double
    let deducted: Double
    let owed: Double
    let paid: Double
    /// Running balance after this month: + owed, − credit.
    let balance: Double
    var id: Int { key }
    var title: String { Fmt.monthTitle(year: key / 100, month: key % 100) }
}

struct MaaserStatus {
    var months: [MaaserMonth] = []
    var balance: Double = 0
    var thisMonthOwed: Double = 0
    var thisMonthPaid: Double = 0
    var paidThisYear: Double = 0
    var missingMonths: [Int] = []
}

enum MaaserCalc {
    static func key(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.component(.year, from: date) * 100 + cal.component(.month, from: date)
    }

    static func monthRange(_ key: Int) -> (Date, Date) {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: key / 100, month: key % 100, day: 1)) ?? Date()
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    static func nextKey(_ key: Int) -> Int {
        key % 100 == 12 ? (key / 100 + 1) * 100 + 1 : key + 1
    }

    /// Salary part of the base, from the actual net and that month's payslip.
    static func salaryBase(actualNet: Double, budget: Budget, base: MaaserBase) -> Double {
        func sum(_ types: [AutoDeduction]) -> Double {
            budget.deductions
                .filter { item in
                    guard item.isActive, let auto = item.auto else { return false }
                    return types.contains(auto)
                }
                .reduce(0) { $0 + budget.deductionAmount($1) }
        }
        let all = budget.totalDeductions
        switch base {
        case .gross: return actualNet + all
        case .afterIncomeTax: return actualNet + all - sum([.incomeTax])
        case .afterTaxAndNI: return actualNet + all - sum([.incomeTax, .nationalInsurance, .healthInsurance])
        case .actualNet: return actualNet
        }
    }

    /// Interest earned during the month in savings and deposits (after tax unless the base is gross).
    static func interest(_ money: MoneyData, from: Date, to: Date, gross: Bool) -> Double {
        let end = min(to, Date())
        guard end > from else { return 0 }
        var total = 0.0
        for a in money.accounts where a.kind.hasInterest {
            // Measure only from the latest balance you entered — before it the app doesn't know the balance,
            // so the balance itself must never count as profit.
            guard let lastEntry = a.balances.filter({ $0.date <= end }).map(\.date).max() else { continue }
            let start = max(from, lastEntry)
            guard end > start else { continue }
            let before = MoneyCalc.value(of: a, on: start, transactions: money.transactions)
            let after = MoneyCalc.value(of: a, on: end, transactions: money.transactions)
            let deposits = Double(a.contributionDates(from: start, to: end).count) * a.monthlyContribution
            let flows = MoneyCalc.flows(a, since: start, until: end, transactions: money.transactions)
            let earned = after - before - deposits - flows
            guard earned > 0 else { continue }
            total += gross ? earned : MoneyCalc.afterTax(earned, a)
        }
        return total
    }

    static func status(settings s: MaaserSettings, budget: Budget, history: [MonthRecord], money: MoneyData, now: Date = Date()) -> MaaserStatus {
        var result = MaaserStatus()
        guard s.enabled else { return result }
        let current = key(now)
        let start = s.startKey > 0 ? s.startKey : current
        var balance = s.openingBalance
        var k = start
        var guardCount = 0
        while k <= current && guardCount < 600 {
            guardCount += 1
            let (from, to) = monthRange(k)
            let record = history.first { $0.year * 100 + $0.month == k }

            // What's owed — only once the actual net was recorded.
            var base: Double? = nil
            var salary = 0.0, interest = 0.0, oneOffs = 0.0, deducted = 0.0
            if let record, let net = record.actualNet {
                salary = salaryBase(actualNet: net, budget: record.budget, base: s.base)
                if s.includeInterest {
                    interest = MaaserCalc.interest(money, from: from, to: to, gross: s.base == .gross)
                }
                if s.includeOneOffs {
                    oneOffs = money.transactions
                        .filter { $0.kind == .income && $0.salaryKey == nil && $0.date >= from && $0.date < to
                                  && $0.date <= now && !s.excludedIncomeIDs.contains($0.id)
                                  && !money.reimbursementIncomeIDs.contains($0.id) }
                        .reduce(0) { $0 + $1.amount }
                }
                deducted = record.budget.expenses
                    .filter { $0.isActive && s.deductedExpenseIDs.contains($0.id) }
                    .reduce(0) { $0 + $1.amount(base: record.budget.expenseBase) }
                base = max(0, salary + interest + oneOffs - deducted)
            } else {
                result.missingMonths.append(k)
            }
            let owed = (base ?? 0) * s.percent / 100

            // What was given.
            var paid = 0.0
            let monthBudget = record?.budget ?? budget
            for id in s.maaserExpenseIDs {
                if let e = monthBudget.expenses.first(where: { $0.id == id }) ?? budget.expenses.first(where: { $0.id == id }), e.isActive {
                    paid += e.amount(base: monthBudget.expenseBase)
                }
            }
            paid += money.cardTransactions
                .filter { $0.billingKey == k && s.isMaaser($0) && ($0.chargeDate ?? $0.date) <= now }
                .reduce(0) { $0 + $1.amount }
            paid += s.donations.filter { $0.date >= from && $0.date < to }.reduce(0) { $0 + $1.amount }

            balance += owed - paid
            result.months.append(MaaserMonth(key: k, base: base, salaryBase: salary, interest: interest, oneOffs: oneOffs,
                                             deducted: deducted, owed: owed, paid: paid, balance: balance))
            if k == current {
                result.thisMonthOwed = owed
                result.thisMonthPaid = paid
            }
            if k / 100 == current / 100 { result.paidThisYear += paid }
            k = nextKey(k)
        }
        result.balance = balance
        return result
    }
}

struct FamilyMaaserRow: Identifiable {
    let member: FamilyMember
    let status: MaaserStatus
    var id: UUID { member.id }
}

// MARK: - Store

extension Store {
    var maaserStatus: MaaserStatus {
        MaaserCalc.status(settings: money.maaser, budget: budget, history: history, money: money)
    }

    /// Each family member in view with their own fund (for the "together" view).
    var familyMaaser: [FamilyMaaserRow] {
        viewedMembers.compactMap { m in
            if m.id == activeMemberID {
                return money.maaser.enabled ? FamilyMaaserRow(member: m, status: maaserStatus) : nil
            }
            guard let f = memberFiles[m.id], let money = f.money, money.maaser.enabled else { return nil }
            return FamilyMaaserRow(member: m, status: MaaserCalc.status(settings: money.maaser, budget: f.budget, history: f.history, money: money))
        }
    }

    func addDonation(_ d: MaaserDonation, alsoFromChecking: Bool) {
        money.maaser.donations.append(d)
        if alsoFromChecking, let checking = money.checking {
            money.transactions.append(MoneyTransaction(date: d.date, title: "מעשרות" + (d.note.isEmpty ? "" : " — " + d.note),
                                                       amount: d.amount, kind: .expense, accountID: checking.id))
        }
    }

    func deleteDonation(_ id: UUID) {
        money.maaser.donations.removeAll { $0.id == id }
    }

    /// Marks / unmarks a card charge as maaser; with `merchant`, every charge from that business counts.
    func setCardMaaser(_ tx: CardTransaction, on: Bool, merchant: Bool) {
        var m = money.maaser
        if on {
            if merchant {
                if !m.maaserMerchants.contains(tx.merchantKey) { m.maaserMerchants.append(tx.merchantKey) }
            } else if !m.maaserCardIDs.contains(tx.id) {
                m.maaserCardIDs.append(tx.id)
            }
        } else {
            m.maaserCardIDs.removeAll { $0 == tx.id }
            m.maaserMerchants.removeAll { $0 == tx.merchantKey }
        }
        money.maaser = m
    }
}

import Foundation

// MARK: - Accounts

enum AccountKind: String, Codable, CaseIterable, Identifiable {
    case checking
    case savings
    case deposit
    case pension

    var id: String { rawValue }

    var title: String {
        switch self {
        case .checking: return "עו״ש"
        case .savings: return "חיסכון נזיל"
        case .deposit: return "פיקדון / תוכנית חיסכון"
        case .pension: return "פנסיה"
        }
    }

    var icon: String {
        switch self {
        case .checking: return "creditcard.fill"
        case .savings: return "banknote.fill"
        case .deposit: return "lock.fill"
        case .pension: return "umbrella.fill"
        }
    }

    /// Money you can use today.
    var isLiquid: Bool { self == .checking || self == .savings }

    /// Accounts that earn bank interest.
    var hasInterest: Bool { self == .savings || self == .deposit }

    var rateTitle: String {
        self == .pension ? "תשואה שנתית משוערת" : "ריבית שנתית"
    }
}

enum RateType: String, Codable, CaseIterable, Identifiable {
    case fixed
    case prime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed: return "ריבית קבועה"
        case .prime: return "צמודה לפריים"
        }
    }
}

enum Compounding: String, Codable, CaseIterable, Identifiable {
    case simple
    case monthly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: return "פשוטה (משולמת בפירעון)"
        case .monthly: return "צבירה חודשית"
        case .yearly: return "צבירה שנתית"
        }
    }
}

/// Savings plans often pay a better rate the longer you stay:
/// "withdraw from month 6 → P−2.95%, from month 15 → P−2.9%, from month 27 → P−2.85%".
struct RateTier: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    /// Applies when the money is taken out at this month (from the plan start) or later.
    var fromMonth: Int = 0
    var primeMinus: Double = 0
}

/// A balance you checked and typed in ("on this date the account had X").
struct BalanceEntry: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var amount: Double = 0
    var note: String = ""
}

struct Account: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var kind: AccountKind = .checking
    var balances: [BalanceEntry] = []
    /// Interest (deposit / savings) or expected return (pension), percent per year.
    var annualRate: Double = 0
    var compounding: Compounding = .simple
    var maturityDate: Date? = nil
    /// Tax on interest, percent (15% on most shekel deposits).
    var interestTax: Double = 15
    /// Pension: monthly deposit (employee + employer).
    var monthlyContribution: Double = 0
    var note: String = ""
    /// Fixed rate, or prime minus a margin (e.g. "P − 2.85%").
    var rateType: RateType = .fixed
    var primeMinus: Double = 0
    /// Savings plans: when the plan started, and the day of the month the fixed deposit is taken.
    var startDate: Date? = nil
    var contributionDay: Int = 1
    /// Exit points: first after N months, then every M months (0 = none).
    var exitFirstMonths: Int = 0
    var exitEveryMonths: Int = 0
    /// Prime-linked plans: rate by the month you withdraw (empty = one rate, `primeMinus`).
    var rateTiers: [RateTier] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, balances, annualRate, compounding, maturityDate, interestTax, monthlyContribution, note
        case rateType, primeMinus, startDate, contributionDay, exitFirstMonths, exitEveryMonths, rateTiers
    }

    var isPrimeLinked: Bool { rateType == .prime && kind != .pension }

    var sortedTiers: [RateTier] { rateTiers.sorted { $0.fromMonth < $1.fromMonth } }

    /// "P minus" that applies when withdrawing at month `m` of the plan.
    func primeMinus(forMonths m: Int?) -> Double {
        let tiers = sortedTiers
        guard !tiers.isEmpty else { return primeMinus }
        guard let m else { return tiers.last?.primeMinus ?? primeMinus }
        return tiers.last(where: { $0.fromMonth <= m })?.primeMinus ?? tiers.first?.primeMinus ?? primeMinus
    }

    func monthsFromStart(to date: Date) -> Int? {
        guard let start = startDate else { return nil }
        return Calendar.current.dateComponents([.month], from: start, to: date).month
    }

    /// The exit point (or the end of the plan) whose rate applies to money valued on `date`.
    func exitMonths(covering date: Date) -> Int? {
        if let exit = nextExitPoint(after: date) { return monthsFromStart(to: exit) }
        if let maturity = maturityDate { return monthsFromStart(to: maturity) }
        return monthsFromStart(to: date)
    }

    /// The yearly rate in percent for money valued on `date` (today by default).
    func effectiveRate(prime: Double, at date: Date = Date()) -> Double {
        guard isPrimeLinked else { return annualRate }
        return prime - primeMinus(forMonths: rateTiers.isEmpty ? nil : exitMonths(covering: date))
    }

    private func describe(minus: Double) -> String {
        let rate = MoneyCalc.prime - minus
        return "P−" + Fmt.percent(minus) + " = " + Fmt.percent((rate * 100).rounded() / 100)
    }

    var rateDescription: String {
        guard isPrimeLinked else { return Fmt.percent(annualRate) }
        if rateTiers.isEmpty {
            return describe(minus: primeMinus) + " (פריים " + Fmt.percent(MoneyCalc.prime) + ")"
        }
        let now = primeMinus(forMonths: exitMonths(covering: Date()))
        return describe(minus: now) + " עכשיו"
    }

    /// Final rate when the plan is held to the end (tiered plans).
    var endRateDescription: String? {
        guard isPrimeLinked, !rateTiers.isEmpty else { return nil }
        return describe(minus: primeMinus(forMonths: maturityDate.flatMap { monthsFromStart(to: $0) }))
    }

    /// Every exit point from the first one up to the end of the plan (the end itself included).
    func exitSchedule() -> [Date] {
        guard let start = startDate, exitFirstMonths > 0 else {
            return maturityDate.map { [$0] } ?? []
        }
        let cal = Calendar.current
        var result: [Date] = []
        guard var point = cal.date(byAdding: .month, value: exitFirstMonths, to: start) else { return [] }
        var count = 0
        while count < 400 {
            // Exit points that fall within a week of the end are the end itself.
            if let maturity = maturityDate, point >= maturity.addingTimeInterval(-7 * 86_400) { break }
            result.append(point)
            guard exitEveryMonths > 0, let next = cal.date(byAdding: .month, value: exitEveryMonths, to: point) else { break }
            point = next
            count += 1
        }
        if let maturity = maturityDate { result.append(maturity) }
        return result
    }

    /// Next date you can take the money out without breaking the plan.
    func nextExitPoint(after date: Date = Date()) -> Date? {
        guard let start = startDate, exitFirstMonths > 0 else { return nil }
        let cal = Calendar.current
        guard var point = cal.date(byAdding: .month, value: exitFirstMonths, to: start) else { return nil }
        var guardCount = 0
        while point < date && guardCount < 400 {
            guard exitEveryMonths > 0, let next = cal.date(byAdding: .month, value: exitEveryMonths, to: point) else { return nil }
            point = next
            guardCount += 1
        }
        if let maturity = maturityDate, point > maturity { return nil }
        return point
    }

    /// Dates of the fixed monthly deposit in (from, to].
    func contributionDates(from: Date, to: Date) -> [Date] {
        guard monthlyContribution > 0, kind != .pension, kind != .checking else { return [] }
        let cal = Calendar.current
        var end = to
        if let maturity = maturityDate, maturity < end { end = maturity }
        var parts = cal.dateComponents([.year, .month], from: from)
        parts.day = min(max(contributionDay, 1), 28)
        guard var d = cal.date(from: parts) else { return [] }
        var result: [Date] = []
        var count = 0
        while d <= end && count < 600 {
            if d > from, startDate.map({ d >= $0 }) ?? true {
                result.append(d)
            }
            guard let next = cal.date(byAdding: .month, value: 1, to: d) else { break }
            d = next
            count += 1
        }
        return result
    }

    var latestBalance: BalanceEntry? { balances.max { $0.date < $1.date } }
    var sortedBalances: [BalanceEntry] { balances.sorted { $0.date > $1.date } }
}

extension Account {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(AccountKind.self, forKey: .kind) ?? .checking
        balances = try c.decodeIfPresent([BalanceEntry].self, forKey: .balances) ?? []
        annualRate = try c.decodeIfPresent(Double.self, forKey: .annualRate) ?? 0
        compounding = try c.decodeIfPresent(Compounding.self, forKey: .compounding) ?? .simple
        maturityDate = try c.decodeIfPresent(Date.self, forKey: .maturityDate)
        interestTax = try c.decodeIfPresent(Double.self, forKey: .interestTax) ?? 15
        monthlyContribution = try c.decodeIfPresent(Double.self, forKey: .monthlyContribution) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        rateType = try c.decodeIfPresent(RateType.self, forKey: .rateType) ?? .fixed
        primeMinus = try c.decodeIfPresent(Double.self, forKey: .primeMinus) ?? 0
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate)
        contributionDay = try c.decodeIfPresent(Int.self, forKey: .contributionDay) ?? 1
        exitFirstMonths = try c.decodeIfPresent(Int.self, forKey: .exitFirstMonths) ?? 0
        exitEveryMonths = try c.decodeIfPresent(Int.self, forKey: .exitEveryMonths) ?? 0
        rateTiers = try c.decodeIfPresent([RateTier].self, forKey: .rateTiers) ?? []
    }
}

// MARK: - Transactions

enum TransactionKind: String, Codable, CaseIterable, Identifiable {
    case income
    case expense
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .income: return "הכנסה"
        case .expense: return "הוצאה"
        case .transfer: return "העברה"
        }
    }
}

/// Only big / unusual money moves are recorded; a future date means "planned".
struct MoneyTransaction: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var title: String = ""
    var amount: Double = 0
    var kind: TransactionKind = .expense
    var accountID: UUID? = nil
    var toAccountID: UUID? = nil
    var note: String = ""
    /// Set when the transaction is a month's salary (year * 100 + month).
    var salaryKey: Int? = nil
    /// Paid with the credit card — it leaves the bank only when the card is charged,
    /// so it never touches an account directly (the card statement / its expected charge counts instead).
    var paidByCard = false
    /// Number of card payments (1 = regular charge).
    var cardInstallments = 1

    var isPlanned: Bool { date > Date() }
    var isCardPurchase: Bool { kind == .expense && paidByCard }

    enum CodingKeys: String, CodingKey {
        case id, date, title, amount, kind, accountID, toAccountID, note, salaryKey, paidByCard, cardInstallments
    }

    /// Signed change this transaction makes to `account`.
    func effect(on account: UUID) -> Double {
        switch kind {
        case .income:
            return accountID == account ? amount : 0
        case .expense:
            if paidByCard { return 0 }
            return accountID == account ? -amount : 0
        case .transfer:
            var change = 0.0
            if accountID == account { change -= amount }
            if toAccountID == account { change += amount }
            return change
        }
    }
}

extension MoneyTransaction {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        kind = (try? c.decodeIfPresent(TransactionKind.self, forKey: .kind)) ?? .expense
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
        toAccountID = try c.decodeIfPresent(UUID.self, forKey: .toAccountID)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        salaryKey = try c.decodeIfPresent(Int.self, forKey: .salaryKey)
        paidByCard = (try? c.decodeIfPresent(Bool.self, forKey: .paidByCard)) ?? false
        cardInstallments = max(1, (try? c.decodeIfPresent(Int.self, forKey: .cardInstallments)) ?? 1)
    }
}

// MARK: - Forecast settings & container

enum IncomeBasis: String, Codable, CaseIterable, Identifiable {
    case recentAverage
    case budget
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentAverage: return "ממוצע הנטו בפועל"
        case .budget: return "חישוב לפי הברוטו"
        case .manual: return "סכום שאני קובע"
        }
    }
}

struct ForecastSettings: Codable, Equatable {
    var months: Int = 6
    var basis: IncomeBasis = .recentAverage
    var manualNet: Double = 0
}

struct MoneyData: Codable, Equatable {
    var accounts: [Account] = [Account(name: "עו״ש", kind: .checking)]
    var transactions: [MoneyTransaction] = []
    var forecast = ForecastSettings()
    /// Bank of Israel prime rate, percent (rate + 1.5%).
    var primeRate: Double = 4.75
    /// Update the prime rate from the Bank of Israel automatically.
    var primeAuto: Bool = true
    var boiRate: Double? = nil
    var primeCheckedAt: Date? = nil
    var nextRateDecision: Date? = nil
    var rateLastChanged: Date? = nil
    /// Imported credit-card charges (Max).
    var cardTransactions: [CardTransaction] = []
    var merchantRules: [MerchantRule] = []
    var cardImports: [CardImport] = []
    /// User-defined spending groups ("דייטים").
    var trends: [Trend] = []
    /// Maaser fund of this family member.
    var maaser = MaaserSettings()
    /// Money others owe you ("חייבים לי").
    var receivables: [Receivable] = []

    private enum CodingKeys: String, CodingKey {
        case accounts, transactions, forecast, primeRate, primeAuto, boiRate, primeCheckedAt, nextRateDecision, rateLastChanged
        case cardTransactions, merchantRules, cardImports, trends, maaser, receivables
    }

    var checking: Account? { accounts.first { $0.kind == .checking } }

    func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }
}

extension MoneyData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        transactions = try c.decodeIfPresent([MoneyTransaction].self, forKey: .transactions) ?? []
        forecast = (try? c.decodeIfPresent(ForecastSettings.self, forKey: .forecast)) ?? ForecastSettings()
        primeRate = (try? c.decodeIfPresent(Double.self, forKey: .primeRate)) ?? 4.75
        primeAuto = (try? c.decodeIfPresent(Bool.self, forKey: .primeAuto)) ?? true
        boiRate = try? c.decodeIfPresent(Double.self, forKey: .boiRate)
        primeCheckedAt = try? c.decodeIfPresent(Date.self, forKey: .primeCheckedAt)
        nextRateDecision = try? c.decodeIfPresent(Date.self, forKey: .nextRateDecision)
        rateLastChanged = try? c.decodeIfPresent(Date.self, forKey: .rateLastChanged)
        cardTransactions = (try? c.decodeIfPresent([CardTransaction].self, forKey: .cardTransactions)) ?? []
        merchantRules = (try? c.decodeIfPresent([MerchantRule].self, forKey: .merchantRules)) ?? []
        cardImports = (try? c.decodeIfPresent([CardImport].self, forKey: .cardImports)) ?? []
        trends = (try? c.decodeIfPresent([Trend].self, forKey: .trends)) ?? []
        maaser = (try? c.decodeIfPresent(MaaserSettings.self, forKey: .maaser)) ?? MaaserSettings()
        receivables = (try? c.decodeIfPresent([Receivable].self, forKey: .receivables)) ?? []
        if !accounts.contains(where: { $0.kind == .checking }) {
            accounts.insert(Account(name: "עו״ש", kind: .checking), at: 0)
        }
    }
}

// MARK: - Calculations

enum MoneyCalc {
    static let day = 86_400.0

    /// Current prime rate (kept in sync by the Store).
    static var prime: Double = 4.75

    static func years(_ from: Date, _ to: Date) -> Double {
        max(0, to.timeIntervalSince(from)) / day / 365
    }

    /// How much 1 ₪ in `account` grows between two dates (deposits stop at maturity).
    static func growth(_ account: Account, from: Date, to: Date) -> Double {
        let rate = account.effectiveRate(prime: prime, at: to)
        guard account.kind != .checking, rate != 0 else { return 1 }
        var end = to
        if account.kind == .deposit, let maturity = account.maturityDate, maturity < end {
            end = maturity
        }
        let y = years(from, end)
        guard y > 0 else { return 1 }
        let r = rate / 100
        if account.kind == .pension { return pow(1 + r, y) }
        switch account.compounding {
        case .simple: return 1 + r * y
        case .monthly: return pow(1 + r / 12, y * 12)
        case .yearly: return pow(1 + r, y)
        }
    }

    /// The balance update that `date` is measured from.
    static func baseEntry(_ account: Account, on date: Date) -> BalanceEntry? {
        account.balances.filter { $0.date <= date }.max { $0.date < $1.date }
    }

    /// Money put in / taken out of the account since its last balance update (no interest).
    static func flows(_ account: Account, since: Date, until: Date, transactions: [MoneyTransaction]) -> Double {
        transactions
            .filter { $0.date > since && $0.date <= until }
            .reduce(0) { $0 + $1.effect(on: account.id) }
    }

    /// Estimated balance on `date`: last balance update, plus interest, plus recorded transactions since.
    static func value(of account: Account, on date: Date, transactions: [MoneyTransaction]) -> Double {
        let base = baseEntry(account, on: date)
        let baseDate = base?.date ?? .distantPast
        var value = (base?.amount ?? 0) * growth(account, from: base?.date ?? date, to: date)
        for t in transactions where t.date > baseDate && t.date <= date {
            let change = t.effect(on: account.id)
            if change != 0 {
                value += change * growth(account, from: t.date, to: date)
            }
        }
        for d in account.contributionDates(from: baseDate == .distantPast ? date : baseDate, to: date) {
            value += account.monthlyContribution * growth(account, from: d, to: date)
        }
        if account.kind == .pension, account.monthlyContribution > 0, let base {
            value += account.monthlyContribution * floor(years(base.date, date) * 12)
        }
        return value
    }

    /// Gross interest earned since the last balance update.
    static func interestEarned(_ account: Account, on date: Date, transactions: [MoneyTransaction]) -> Double {
        guard account.kind.hasInterest, let base = baseEntry(account, on: date) else { return 0 }
        let deposits = Double(account.contributionDates(from: base.date, to: date).count) * account.monthlyContribution
        let principal = base.amount + deposits + flows(account, since: base.date, until: date, transactions: transactions)
        return value(of: account, on: date, transactions: transactions) - principal
    }

    static func afterTax(_ interest: Double, _ account: Account) -> Double {
        interest > 0 ? interest * (1 - account.interestTax / 100) : interest
    }

    // MARK: Expected income

    /// Expected net income per month and a short explanation of where it came from.
    static func expectedNet(budget: Budget, history: [MonthRecord], settings: ForecastSettings) -> (amount: Double, source: String) {
        switch settings.basis {
        case .manual:
            return (settings.manualNet, "סכום שקבעת")
        case .budget:
            return (budget.net, "חישוב לפי הברוטו והניכויים")
        case .recentAverage:
            let actuals = history
                .filter { $0.actualNet != nil }
                .sorted { $0.sortKey > $1.sortKey }
                .prefix(3)
                .compactMap { $0.actualNet }
            if actuals.isEmpty {
                return (budget.net, "אין עדיין נטו בפועל — לפי חישוב הברוטו")
            }
            let avg = actuals.reduce(0, +) / Double(actuals.count)
            return (avg, "ממוצע נטו בפועל של \(actuals.count) החודשים האחרונים")
        }
    }
}

// MARK: - Forecast

struct ForecastMonth: Identifiable {
    var id: Int { index }
    let index: Int
    let date: Date
    let income: Double
    let spending: Double
    let toSavings: Double
    var card: Double = 0
    let events: [String]
    let checking: Double
    let savings: Double
    let pension: Double

    var liquid: Double { checking + savings }
    var label: String { Fmt.monthTitle(year: Calendar.current.component(.year, from: date), month: Calendar.current.component(.month, from: date)) }
    var shortLabel: String {
        let c = Calendar.current
        return "\(c.component(.month, from: date))/\(c.component(.year, from: date) % 100)"
    }
}

enum Forecaster {
    /// Month-by-month projection. Index 0 is today.
    static func run(budget: Budget, money: MoneyData, history: [MonthRecord], months: Int, now: Date = Date()) -> [ForecastMonth] {
        let cal = Calendar.current
        let net = MoneyCalc.expectedNet(budget: budget, history: history, settings: money.forecast).amount

        var balances: [UUID: Double] = [:]
        for account in money.accounts {
            balances[account.id] = MoneyCalc.value(of: account, on: now, transactions: money.transactions)
        }
        let checkingID = money.checking?.id

        func totals(_ b: [UUID: Double]) -> (Double, Double, Double) {
            var checking = 0.0, savings = 0.0, pension = 0.0
            for account in money.accounts {
                let v = b[account.id] ?? 0
                switch account.kind {
                case .checking: checking += v
                case .savings, .deposit: savings += v
                case .pension: pension += v
                }
            }
            return (checking, savings, pension)
        }

        let start = totals(balances)
        var result = [ForecastMonth(index: 0, date: now, income: 0, spending: 0, toSavings: 0, events: [],
                                    checking: start.0, savings: start.1, pension: start.2)]

        // Fixed expenses split: plain spending vs transfers into one of your accounts.
        var transfers: [(UUID, Double)] = []
        var spending = budget.periodicTotal
        for item in budget.expenses where item.isActive {
            let amount = item.amount(base: budget.expenseBase)
            if let target = item.targetAccountID, money.account(target) != nil {
                transfers.append((target, amount))
            } else {
                spending += amount
            }
        }
        let monthlyToSavings = transfers.reduce(0) { $0 + $1.1 }
        // Variable credit-card spending: imported future charges, otherwise the recent average.
        let cardAverage = money.averageCardVariable()
        let manualCard = money.manualCardPayments

        guard months > 0 else { return result }
        for m in 1...months {
            guard let from = cal.date(byAdding: .month, value: m - 1, to: now),
                  let to = cal.date(byAdding: .month, value: m, to: now) else { continue }
            var events: [String] = []

            // Interest / returns for the month.
            for account in money.accounts where account.kind != .checking {
                balances[account.id, default: 0] *= MoneyCalc.growth(account, from: from, to: to)
            }

            // Salary in, fixed spending out, transfers to savings.
            if let checkingID {
                balances[checkingID, default: 0] += net - spending - monthlyToSavings
            }
            for (target, amount) in transfers {
                balances[target, default: 0] += amount
            }

            // Pension deposits (from the salary, not the checking account).
            for account in money.accounts where account.kind == .pension {
                balances[account.id, default: 0] += account.monthlyContribution
            }

            // Fixed monthly deposits into savings plans — taken from the checking account.
            for account in money.accounts where account.kind == .savings || account.kind == .deposit {
                let count = account.contributionDates(from: from, to: to).count
                if count > 0 {
                    let amount = Double(count) * account.monthlyContribution
                    balances[account.id, default: 0] += amount
                    if let checkingID { balances[checkingID, default: 0] -= amount }
                }
            }

            // Credit card (spending not already covered by a fixed expense).
            var card = 0.0
            let upcoming = money.cardTransactions.filter {
                guard let d = $0.chargeDate else { return false }
                return d > now && d > from && d <= to && !$0.ignored
            }
            // Installments: imported ones are in `upcoming`, the rest are projected one a month.
            let projected = money.projectedInstallments(from: from, to: to)
            let upcomingInstallments = upcoming.filter { $0.isVariable && $0.installment != nil }.reduce(0) { $0 + $1.myAmount }
            if !upcoming.isEmpty {
                var regular = upcoming.filter { $0.isVariable && $0.installment == nil }.reduce(0) { $0 + $1.myAmount }
                // A statement that is still open (only pending purchases) will grow — never below the average.
                if upcoming.allSatisfy({ $0.chargeEstimated }) { regular = max(regular, cardAverage) }
                card = regular + upcomingInstallments + projected
                if card != 0 { events.append("כרטיס אשראי −\(Fmt.moneyRounded(card))") }
            } else {
                card = cardAverage + projected
            }
            if upcomingInstallments + projected > 0 {
                events.append("מתוכם תשלומים −\(Fmt.moneyRounded(upcomingInstallments + projected))")
            }
            // Purchases you recorded as paid by card that aren't in an imported statement yet.
            for p in manualCard where p.chargeDate > now && p.chargeDate > from && p.chargeDate <= to {
                card += p.amount
                events.append("💳 \(p.title) −\(Fmt.moneyRounded(p.amount))")
            }
            if let checkingID { balances[checkingID, default: 0] -= card }

            // Planned transactions.
            for t in money.transactions where t.date > now && t.date > from && t.date <= to {
                for account in money.accounts {
                    let change = t.effect(on: account.id)
                    if change != 0 { balances[account.id, default: 0] += change }
                }
                let sign = t.kind == .income ? "+" : (t.kind == .expense ? "−" : "↔")
                events.append("\(t.title) \(sign)\(Fmt.moneyRounded(t.amount))")
            }

            // Deposits that mature go back to the checking account.
            for account in money.accounts where account.kind == .deposit {
                if let maturity = account.maturityDate, maturity > from, maturity <= to, let checkingID {
                    let amount = balances[account.id] ?? 0
                    let interest = MoneyCalc.interestEarned(account, on: maturity, transactions: money.transactions)
                    let tax = max(0, interest) * account.interestTax / 100
                    balances[account.id] = 0
                    balances[checkingID, default: 0] += amount - tax
                    events.append("פירעון \(account.name) +\(Fmt.moneyRounded(amount - tax))")
                }
            }

            let t = totals(balances)
            result.append(ForecastMonth(index: m, date: to, income: net, spending: spending + card, toSavings: monthlyToSavings,
                                        card: card, events: events, checking: t.0, savings: t.1, pension: t.2))
        }
        return result
    }
}

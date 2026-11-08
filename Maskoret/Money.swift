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
    /// The day of the month the salary comes in: "what's left" starts over on this day.
    var payDay: Int = 1
    /// From when the checking estimate follows the salary, fixed expenses and card charges by themselves
    /// (set once, so updating the app doesn't rewrite what happened before it).
    var autoBalanceSince: Date? = nil
    /// Per card: name, the day the bank takes it, and cards whose statements aren't imported.
    var cardSettings: [CardSetting] = []
    /// Bank of Israel representative rates: ₪ for one unit of each currency ("USD": 3.157). Used for card charges
    /// in a foreign currency that the statement doesn't show in ₪ yet.
    var exchangeRates: [String: Double] = MoneyData.fallbackRates
    var exchangeRatesAt: Date? = nil
    /// The rates of each day the app saw them ("2026-11-03" → rates), so a charge is converted at the rate of the
    /// day it was made. The Bank of Israel API gives only today's rates, so the days fill in as the app is used.
    var exchangeRateHistory: [String: [String: Double]] = [:]
    /// Income transactions that are someone's participation in a shared fixed expense: income id → expense id
    /// (both uuidString). Not income — they come off that expense.
    var costShareIncomes: [String: String] = [:]

    /// Until the first check with the Bank of Israel (November 2026).
    static let fallbackRates: [String: Double] = ["USD": 3.157, "EUR": 3.5306, "GBP": 4.235]

    private enum CodingKeys: String, CodingKey {
        case accounts, transactions, forecast, primeRate, primeAuto, boiRate, primeCheckedAt, nextRateDecision, rateLastChanged
        case cardTransactions, merchantRules, cardImports, trends, maaser, receivables, payDay, autoBalanceSince, cardSettings
        case exchangeRates, exchangeRatesAt, exchangeRateHistory, costShareIncomes
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
        costShareIncomes = (try? c.decodeIfPresent([String: String].self, forKey: .costShareIncomes)) ?? [:]
        payDay = (try? c.decodeIfPresent(Int.self, forKey: .payDay)) ?? 1
        autoBalanceSince = try? c.decodeIfPresent(Date.self, forKey: .autoBalanceSince)
        cardSettings = (try? c.decodeIfPresent([CardSetting].self, forKey: .cardSettings)) ?? []
        exchangeRates = (try? c.decodeIfPresent([String: Double].self, forKey: .exchangeRates)) ?? MoneyData.fallbackRates
        exchangeRatesAt = try? c.decodeIfPresent(Date.self, forKey: .exchangeRatesAt)
        exchangeRateHistory = (try? c.decodeIfPresent([String: [String: Double]].self, forKey: .exchangeRateHistory)) ?? [:]
        if !accounts.contains(where: { $0.kind == .checking }) {
            accounts.insert(Account(name: "עו״ש", kind: .checking), at: 0)
        }
    }
}

// MARK: - Pay periods

extension MoneyData {
    /// Where the money period of (year, month) begins: that month's pay day. The period runs until the next month's
    /// pay day and is named after the month the salary came in. A pay day of 1 makes it the calendar month.
    func periodStart(year: Int, month: Int) -> Date {
        let cal = Calendar.current
        let first = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 28
        return cal.date(from: DateComponents(year: year, month: month, day: min(max(payDay, 1), days))) ?? first
    }

    func periodEnd(year: Int, month: Int) -> Date {
        let next = month == 12 ? (year + 1, 1) : (year, month + 1)
        return periodStart(year: next.0, month: next.1)
    }

    /// The money period a date falls in.
    func period(containing date: Date) -> (year: Int, month: Int) {
        let cal = Calendar.current
        let y = cal.component(.year, from: date), m = cal.component(.month, from: date)
        if date >= periodStart(year: y, month: m) { return (y, m) }
        return m == 1 ? (y - 1, 12) : (y, m - 1)
    }

    /// Estimated balance of an account: `MoneyCalc.value`, and the main checking account also pays for the fixed
    /// deposits into savings plans (they raise the plan on their day, so the money has to leave here on that day).
    /// With a budget, it also follows the salary, fixed expenses and card charges (`expectedChecking`).
    func balance(of account: Account, on date: Date = Date(), budget: Budget? = nil, history: [MonthRecord] = []) -> Double {
        var value = MoneyCalc.value(of: account, on: date, transactions: transactions)
        guard account.id == checking?.id, let base = MoneyCalc.baseEntry(account, on: date) else { return value }
        for plan in accounts where plan.kind == .savings || plan.kind == .deposit {
            value -= Double(plan.contributionDates(from: base.date, to: date).count) * plan.monthlyContribution
        }
        if let budget, let since = autoBalanceSince {
            value += expectedChecking(from: max(base.date, since), to: date, budget: budget, history: history)
        }
        return value
    }

    /// What should have moved in the checking account in (from, to] without being recorded: the salary on the pay day,
    /// fixed expenses on their day, and the card on its charge day. Typing in a balance starts this count over.
    func expectedChecking(from: Date, to: Date, budget: Budget, history: [MonthRecord]) -> Double {
        expectedCheckingLines(from: from, to: to, budget: budget, history: history).reduce(0) { $0 + $1.amount }
    }

    /// The same as `expectedChecking`, one line per movement (for the statement in "תנועות").
    func expectedCheckingLines(from: Date, to: Date, budget: Budget, history: [MonthRecord]) -> [LedgerLine] {
        guard from < to else { return [] }
        let cal = Calendar.current
        func day(_ wanted: Int, year: Int, month: Int) -> Date {
            let first = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? from
            let days = cal.range(of: .day, in: .month, for: first)?.count ?? 28
            return cal.date(from: DateComponents(year: year, month: month, day: min(max(wanted, 1), days))) ?? first
        }
        func inRange(_ d: Date) -> Bool { d > from && d <= to }
        var lines: [LedgerLine] = []

        // Card: every imported charge once the bank takes it — fixed expenses and tracked purchases on the card included.
        // One line per card and day, like the bank shows it. An amount typed in for that month replaces the statement's.
        let primary = primaryCard
        struct Group { var date: Date; var amount: Double }
        var groups: [String: Group] = [:]   // "last4|day" or, when the actual amount was typed, "last4|month"
        func add(card: String, charge: Date, amount: Double) {
            let d = bankDate(card: card, charge: charge)
            let month = cal.component(.year, from: charge) * 100 + cal.component(.month, from: charge)
            if setting(card: card)?.actualCharges[String(month)] != nil {
                let key = card + "|m" + String(month)
                groups[key] = Group(date: max(groups[key]?.date ?? d, d), amount: 0)
            } else if inRange(d) {
                groups[card + "|" + String(d.timeIntervalSinceReferenceDate), default: Group(date: d, amount: 0)].amount += amount
            }
        }
        for t in cardTransactions where !t.ignored {
            if let d = t.chargeDate { add(card: t.cardLast4, charge: d, amount: t.amount) }
        }
        for p in manualCardPayments { add(card: primary, charge: p.chargeDate, amount: p.amount) }
        for (key, g) in groups {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let card = parts[0]
            var amount = g.amount
            if parts.count > 1, parts[1].hasPrefix("m") {
                guard inRange(g.date), let actual = setting(card: card)?.actualCharges[String(parts[1].dropFirst())] else { continue }
                amount = actual
            }
            guard amount != 0 else { continue }
            let month = cal.component(.year, from: g.date) * 100 + cal.component(.month, from: g.date)
            lines.append(LedgerLine(id: "card:" + key, date: g.date, title: "חיוב " + cardName(card), amount: -amount,
                                    source: .card, cardKey: CardChargeKey(card: card, month: month)))
        }
        // Cards without imported statements: what they usually charge, on their day.
        for s in cardSettings where s.monthlyEstimate > 0 {
            var yy = cal.component(.year, from: from), mm = cal.component(.month, from: from)
            let last = cal.component(.year, from: to) * 100 + cal.component(.month, from: to)
            while yy * 100 + mm <= last {
                let key = yy * 100 + mm
                let base = day(s.chargeDay ?? payDay, year: yy, month: mm)
                let d = cal.date(byAdding: .day, value: s.delayDays, to: base) ?? base
                if inRange(d) {
                    let actual = s.actualCharges[String(key)]
                    lines.append(LedgerLine(id: "cardm:\(s.id):\(key)", date: d,
                                            title: "חיוב " + s.displayName + (actual == nil ? " (משוער)" : ""),
                                            amount: -(actual ?? s.monthlyEstimate), source: .card,
                                            cardKey: CardChargeKey(card: s.key, month: key)))
                }
                if mm == 12 { yy += 1; mm = 1 } else { mm += 1 }
            }
        }

        var y = cal.component(.year, from: from), m = cal.component(.month, from: from)
        let endKey = cal.component(.year, from: to) * 100 + cal.component(.month, from: to)
        let cardDay = setting(card: primary)?.chargeDay ?? usualChargeDay
        let cardDelay = setting(card: primary)?.delayDays ?? 0
        let average = averageCardVariable()
        while y * 100 + m <= endKey {
            let key = y * 100 + m
            // Salary, unless it was recorded as a transaction.
            let payDate = periodStart(year: y, month: m)
            if inRange(payDate), !transactions.contains(where: { $0.salaryKey == key }) {
                let actual = history.first { $0.year == y && $0.month == m }?.actualNet
                lines.append(LedgerLine(id: "salary:\(key)", date: payDate,
                                        title: "משכורת " + Fmt.monthNames[m - 1] + (actual == nil ? " (הערכה)" : ""),
                                        amount: actual ?? budget.net, source: .salary))
            }
            let statement = cardTransactions(billingKey: key)
            // A statement that wasn't imported: the usual spending and the planned installments.
            if let cardDay, statement.isEmpty {
                let charge = day(cardDay, year: y, month: m)
                let d = cal.date(byAdding: .day, value: cardDelay, to: charge) ?? charge
                if inRange(d) {
                    let dayBefore = cal.date(byAdding: .day, value: -1, to: charge) ?? charge
                    let actual = setting(card: primary)?.actualCharges[String(key)]
                    lines.append(LedgerLine(id: "cardEstimate:\(key)", date: d,
                                            title: "חיוב " + cardName(primary) + (actual == nil ? " (לפי ממוצע)" : ""),
                                            amount: -(actual ?? (average + projectedInstallments(from: dayBefore, to: charge))),
                                            source: .card, cardKey: CardChargeKey(card: primary, month: key)))
                }
            }
            // Fixed expenses. One paid by card leaves with the statement, so it never counts by itself as well.
            for item in budget.expenses where item.isActive {
                let amount = item.amount(base: budget.expenseBase)
                guard amount != 0 else { continue }
                let onCard = cardTransactions.contains { $0.linkedExpenseID == item.id && !$0.ignored }
                if onCard, statement.contains(where: { $0.linkedExpenseID == item.id && !$0.ignored }) { continue }
                var d = day(onCard ? (cardDay ?? payDay) : (item.chargeDay ?? payDay), year: y, month: m)
                if onCard { d = cal.date(byAdding: .day, value: cardDelay, to: d) ?? d }
                if inRange(d) {
                    lines.append(LedgerLine(id: "fixed:\(item.id):\(key)", date: d, title: item.name + (onCard ? " (באשראי)" : ""),
                                            amount: -amount, source: .fixed))
                }
            }
            if m == 12 { y += 1; m = 1 } else { m += 1 }
        }
        return lines
    }

    /// The checking account as a bank statement: from each balance you typed in, every movement after it — recorded
    /// transactions, deposits into savings plans, and what follows by itself (salary, fixed expenses, card) — with the
    /// balance after each line. Newest first. Lines after today are what's expected.
    func checkingStatement(until: Date, budget: Budget, history: [MonthRecord], months: Int = 6) -> [LedgerLine] {
        guard let account = checking else { return [] }
        let cal = Calendar.current
        let oldest = cal.date(byAdding: .month, value: -months, to: Date()) ?? .distantPast
        let entries = account.balances.filter { $0.date <= until }.sorted { $0.date < $1.date }
        // The last balance before the window still opens it.
        let firstIndex = entries.lastIndex { $0.date <= oldest } ?? 0
        var result: [LedgerLine] = []
        for (i, entry) in entries.enumerated() where i >= firstIndex {
            let end = i + 1 < entries.count ? entries[i + 1].date : until
            var lines: [LedgerLine] = []
            for t in transactions where t.date > entry.date && t.date <= end {
                let change = t.effect(on: account.id)
                var line = LedgerLine(id: "t:" + t.id.uuidString, date: t.date, title: t.title, amount: change,
                                      source: t.kind == .transfer ? .transfer(t.id) : .transaction(t.id))
                // Paid by card or in another account: shown, but the checking moves only with the card charge.
                if change == 0 {
                    line.elsewhere = t.kind == .income ? t.amount : -t.amount
                    line.note = t.isCardPurchase ? "💳 באשראי — יורד עם חיוב הכרטיס"
                        : "ב" + (self.account(t.kind == .transfer ? t.toAccountID : t.accountID)?.name ?? "חשבון אחר")
                }
                lines.append(line)
            }
            for plan in accounts where plan.kind == .savings || plan.kind == .deposit {
                for d in plan.contributionDates(from: entry.date, to: end) {
                    lines.append(LedgerLine(id: "dep:\(plan.id):\(d.timeIntervalSinceReferenceDate)", date: d,
                                            title: "הפקדה ל" + plan.name, amount: -plan.monthlyContribution, source: .savings))
                }
            }
            if let since = autoBalanceSince {
                lines += expectedCheckingLines(from: max(entry.date, since), to: end, budget: budget, history: history)
            }
            // Oldest first to run the balance, same-day lines income first.
            lines.sort { $0.date != $1.date ? $0.date < $1.date : $0.amount > $1.amount }
            var running = entry.amount
            // A balance typed again before anything moved says nothing new — only the last one of those shows.
            if !lines.isEmpty || i == entries.count - 1 {
                result.append(LedgerLine(id: "bal:" + entry.id.uuidString, date: entry.date, title: "יתרה שהקלדת",
                                         amount: 0, source: .balance, balance: running))
            }
            for var line in lines {
                running += line.amount
                line.balance = running
                result.append(line)
            }
        }
        return result.reversed()
    }

    /// Savings deposits live in one place, the savings account. A fixed expense marked "transfer to savings" becomes a
    /// monthly deposit of that account, from now on (what happened before stays as the balances say). Returns whether
    /// anything moved. Transfers to a pension stay: those come out of the salary.
    mutating func adoptSavingsTransfers(from budget: inout Budget) -> Bool {
        var changed = false
        if autoBalanceSince == nil {
            autoBalanceSince = Date()
            changed = true
        }
        for item in budget.expenses {
            guard let target = item.targetAccountID,
                  let i = accounts.firstIndex(where: { $0.id == target && ($0.kind == .savings || $0.kind == .deposit) }) else { continue }
            if item.isActive {
                let amount = (item.amount(base: budget.expenseBase) * 100).rounded() / 100
                if accounts[i].monthlyContribution <= 0 {
                    accounts[i].contributionDay = min(max(payDay, 1), 28)
                    if accounts[i].startDate == nil { accounts[i].startDate = Date() }
                }
                accounts[i].monthlyContribution += amount
            }
            budget.expenses.removeAll { $0.id == item.id }
            changed = true
        }
        return changed
    }
}

/// A card and the month its charge leaves the checking (yyyymm).
struct CardChargeKey: Equatable, Hashable {
    let card: String
    let month: Int
}

/// One line of the checking statement.
struct LedgerLine: Identifiable, Equatable {
    enum Source: Equatable {
        case balance, salary, fixed, card, savings
        case transaction(UUID), transfer(UUID)
    }
    let id: String
    let date: Date
    let title: String
    /// Signed: + came in, − went out.
    let amount: Double
    let source: Source
    /// For a card charge: which card and month, so the amount the bank actually took can be typed in.
    var cardKey: CardChargeKey? = nil
    /// The balance after this line.
    var balance: Double = 0
    /// A recorded movement that doesn't touch the checking right now (card, another account): its own amount.
    var elsewhere: Double?
    var note: String = ""

    /// Written by hand in "תנועות" (the rest follows from other screens).
    var isManual: Bool {
        switch source {
        case .transaction, .transfer: return true
        default: return false
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
            balances[account.id] = money.balance(of: account, on: now, budget: budget, history: history)
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

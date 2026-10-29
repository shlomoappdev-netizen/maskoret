import Foundation

// MARK: - Income

enum IncomeKind: String, Codable, CaseIterable, Identifiable {
    case fixed
    case hourly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed: return "סכום חודשי"
        case .hourly: return "לפי שעות"
        }
    }
}

struct IncomeItem: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var kind: IncomeKind = .fixed
    var amount: Double = 0
    var hours: Double = 0
    var hourlyRate: Double = 0
    var isActive: Bool = true
    /// The amount is already net (e.g. IDF soldier pay) — no tax or deductions are taken from it.
    var isNet: Bool = false

    private enum CodingKeys: String, CodingKey { case id, name, kind, amount, hours, hourlyRate, isActive, isNet }

    var rawTotal: Double {
        switch kind {
        case .fixed: return amount
        case .hourly: return hours * hourlyRate
        }
    }

    var monthlyTotal: Double { isActive ? rawTotal : 0 }

    var detail: String {
        let base: String
        switch kind {
        case .fixed:
            base = "סכום חודשי קבוע"
        case .hourly:
            base = "\(Fmt.number(hours)) שעות × \(Fmt.money(hourlyRate))"
        }
        return base + (isNet ? " · נטו, ללא ניכויים" : " · ברוטו")
    }
}

extension IncomeItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(IncomeKind.self, forKey: .kind) ?? .fixed
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        hours = try c.decodeIfPresent(Double.self, forKey: .hours) ?? 0
        hourlyRate = try c.decodeIfPresent(Double.self, forKey: .hourlyRate) ?? 0
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        isNet = try c.decodeIfPresent(Bool.self, forKey: .isNet) ?? false
    }
}

// MARK: - Deductions & expenses

enum CostKind: String, Codable, CaseIterable, Identifiable {
    case fixed
    case percent
    case automatic

    var id: String { rawValue }
}

/// Deductions the app calculates by itself from the official rates.
enum AutoDeduction: String, Codable, CaseIterable, Identifiable {
    case incomeTax
    case nationalInsurance
    case healthInsurance
    case pension
    case studyFund

    var id: String { rawValue }

    var title: String {
        switch self {
        case .incomeTax: return "מס הכנסה"
        case .nationalInsurance: return "ביטוח לאומי"
        case .healthInsurance: return "מס בריאות"
        case .pension: return "פנסיה (חלק העובד)"
        case .studyFund: return "קרן השתלמות (חלק העובד)"
        }
    }

    /// Default percent of gross for percent-based auto items.
    var defaultPercent: Double {
        switch self {
        case .pension: return 6
        case .studyFund: return 2.5
        default: return 0
        }
    }

    var usesPercent: Bool { self == .pension || self == .studyFund }

    var explanation: String {
        switch self {
        case .incomeTax:
            return "מחושב לפי מדרגות המס, פחות נקודות הזיכוי שלך וזיכוי של 35% על ההפקדה לפנסיה (עד התקרה)."
        case .nationalInsurance:
            return "שיעור מופחת עד סף ההכנסה המופחתת, ושיעור מלא מעליו — עד ההכנסה המרבית."
        case .healthInsurance:
            return "שיעור מופחת עד סף ההכנסה המופחתת, ושיעור מלא מעליו — עד ההכנסה המרבית."
        case .pension:
            return "אחוז מהברוטו שמופרש מהשכר שלך לפנסיה (המינימום לפי חוק הוא 6%). ההפרשה גם מזכה בזיכוי ממס הכנסה."
        case .studyFund:
            return "אחוז מהברוטו שמופרש מהשכר שלך לקרן השתלמות (בדרך כלל 2.5%), אם יש לך."
        }
    }
}

struct CostItem: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var kind: CostKind = .fixed
    var value: Double = 0
    var isActive: Bool = true
    var auto: AutoDeduction? = nil
    /// Expenses only: when set, the money moves into this account (savings) instead of being spent.
    var targetAccountID: UUID? = nil

    private enum CodingKeys: String, CodingKey { case id, name, kind, value, isActive, auto, targetAccountID }

    static func automatic(_ type: AutoDeduction) -> CostItem {
        CostItem(name: type.title, kind: .automatic, value: type.defaultPercent, auto: type)
    }

    /// Amount for manual items (fixed / percent of `base`). Automatic items are computed by `Budget`.
    func rawAmount(base: Double) -> Double {
        switch kind {
        case .fixed: return value
        case .percent: return base * value / 100
        case .automatic: return 0
        }
    }

    func amount(base: Double) -> Double {
        isActive ? rawAmount(base: base) : 0
    }
}

extension CostItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(CostKind.self, forKey: .kind) ?? .fixed
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        auto = try c.decodeIfPresent(AutoDeduction.self, forKey: .auto)
        targetAccountID = try c.decodeIfPresent(UUID.self, forKey: .targetAccountID)
    }
}

// MARK: - Purchase tracking (expenses outside the payslip)

struct Purchase: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var price: Double = 0
    var note: String = ""
}

func monthsBetween(_ start: Date, _ end: Date) -> Double {
    end.timeIntervalSince(start) / 86_400 / 30.4375
}

/// Something you buy again every so often — shoes, clothes, a phone, a haircut.
struct TrackedItem: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var emoji: String = "📦"
    /// Used until there are at least two purchases to measure from.
    var expectedMonths: Double = 0
    var includeInBudget: Bool = true
    var purchases: [Purchase] = []

    var sortedPurchases: [Purchase] { purchases.sorted { $0.date < $1.date } }

    /// Months between each purchase and the next one.
    var measuredIntervals: [Double] {
        let s = sortedPurchases
        guard s.count > 1 else { return [] }
        return (1..<s.count).map { monthsBetween(s[$0 - 1].date, s[$0].date) }.filter { $0 > 0 }
    }

    var isLifespanMeasured: Bool { !measuredIntervals.isEmpty }

    /// Average months an item lasts (measured, or the estimate you entered).
    var averageLifespan: Double? {
        let intervals = measuredIntervals
        if !intervals.isEmpty {
            return intervals.reduce(0, +) / Double(intervals.count)
        }
        return expectedMonths > 0 ? expectedMonths : nil
    }

    var averagePrice: Double {
        guard !purchases.isEmpty else { return 0 }
        return purchases.reduce(0) { $0 + $1.price } / Double(purchases.count)
    }

    var totalSpent: Double { purchases.reduce(0) { $0 + $1.price } }

    var lastPurchase: Purchase? { sortedPurchases.last }

    /// What this item really costs you per month.
    var monthlyCost: Double {
        guard let life = averageLifespan, life > 0 else { return 0 }
        return averagePrice / life
    }

    var ageMonths: Double? {
        guard let last = lastPurchase else { return nil }
        return max(0, monthsBetween(last.date, Date()))
    }

    /// 0 = brand new, 1 = reached the average lifespan.
    var wear: Double? {
        guard let age = ageMonths, let life = averageLifespan, life > 0 else { return nil }
        return age / life
    }

    var nextReplacement: Date? {
        guard let last = lastPurchase, let life = averageLifespan else { return nil }
        return last.date.addingTimeInterval(life * 30.4375 * 86_400)
    }

    /// How long a specific purchase lasted (until the next purchase), nil for the current one.
    func lasted(_ purchase: Purchase) -> Double? {
        let s = sortedPurchases
        guard let i = s.firstIndex(where: { $0.id == purchase.id }), i + 1 < s.count else { return nil }
        return monthsBetween(s[i].date, s[i + 1].date)
    }

    static let presets: [(emoji: String, name: String, months: Double)] = [
        ("👟", "נעליים", 12),
        ("👕", "בגדים", 6),
        ("📱", "טלפון", 30),
        ("💻", "מחשב", 48),
        ("👓", "משקפיים / עדשות", 24),
        ("💈", "תספורת", 1),
        ("🔧", "טיפול לרכב", 12),
        ("🛞", "צמיגים", 36),
        ("🦷", "רופא שיניים", 6),
        ("🛏️", "מזרן", 84),
        ("🎧", "אוזניות", 24),
        ("📄", "ביטוח שנתי", 12)
    ]
}

// MARK: - Budget

/// Whether the employee puts money into a pension fund from the payslip.
enum PensionMode: String, Codable, CaseIterable, Identifiable {
    case contributes
    case startsLater
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contributes: return "מפריש לפנסיה"
        case .startsLater: return "עוד לא — יתחיל מתאריך"
        case .none: return "לא מפריש"
        }
    }
}

struct TaxSettings: Codable, Equatable {
    /// Credit points (נקודות זיכוי). 2.25 is the base for a male resident, 2.75 for a female resident.
    var creditPoints: Double = 2.25
    var pensionMode: PensionMode = .contributes
    /// With `.startsLater`: the date the pension deduction starts (e.g. turning 21, or after 6 months at work).
    var pensionStart: Date? = nil

    private enum CodingKeys: String, CodingKey { case creditPoints, pensionMode, pensionStart }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        creditPoints = (try? c.decodeIfPresent(Double.self, forKey: .creditPoints)) ?? 2.25
        pensionMode = (try? c.decodeIfPresent(PensionMode.self, forKey: .pensionMode)) ?? .contributes
        pensionStart = (try? c.decodeIfPresent(Date.self, forKey: .pensionStart)) ?? nil
    }

    /// Is a pension deduction taken from the salary right now?
    func contributesPension(on date: Date = Date()) -> Bool {
        switch pensionMode {
        case .contributes: return true
        case .none: return false
        case .startsLater: return pensionStart.map { date >= $0 } ?? false
        }
    }
}

struct Budget: Codable, Equatable {
    var incomes: [IncomeItem] = []
    var deductions: [CostItem] = []
    var expenses: [CostItem] = []
    var trackedItems: [TrackedItem] = []
    var taxSettings = TaxSettings()
    var rates: TaxRates = .bundled

    private enum CodingKeys: String, CodingKey {
        case incomes, deductions, expenses, trackedItems, taxSettings, rates
    }

    /// Taxable gross income — the base for tax, insurance and percentage deductions.
    var gross: Double { incomes.filter { !$0.isNet }.reduce(0) { $0 + $1.monthlyTotal } }

    /// Income that is already net (e.g. IDF soldier pay) — added after deductions.
    var netIncomes: Double { incomes.filter { $0.isNet }.reduce(0) { $0 + $1.monthlyTotal } }

    /// Everything that comes in this month (gross + net incomes).
    var totalIncome: Double { gross + netIncomes }

    /// Employee pension contribution (auto pension items) — used for the tax credit.
    var pensionContribution: Double {
        guard taxSettings.contributesPension() else { return 0 }
        return deductions
            .filter { $0.isActive && $0.auto == .pension }
            .reduce(0) { $0 + gross * $1.value / 100 }
    }

    /// Amount of a deduction regardless of active state.
    func rawDeductionAmount(_ item: CostItem) -> Double {
        guard item.kind == .automatic, let type = item.auto else {
            return item.rawAmount(base: gross)
        }
        switch type {
        case .incomeTax:
            return TaxCalc.incomeTax(
                gross: gross,
                creditPoints: taxSettings.creditPoints,
                pensionContribution: pensionContribution,
                rates: rates
            )
        case .nationalInsurance:
            return TaxCalc.nationalInsurance(gross: gross, rates: rates)
        case .healthInsurance:
            return TaxCalc.healthInsurance(gross: gross, rates: rates)
        case .pension:
            return taxSettings.contributesPension() ? gross * item.value / 100 : 0
        case .studyFund:
            return gross * item.value / 100
        }
    }

    func deductionAmount(_ item: CostItem) -> Double {
        item.isActive ? rawDeductionAmount(item) : 0
    }

    var totalDeductions: Double { deductions.reduce(0) { $0 + deductionAmount($1) } }

    var net: Double { gross - totalDeductions + netIncomes }

    var expenseBase: Double { max(net, 0) }

    /// Fixed monthly expenses.
    var totalExpenses: Double { expenses.reduce(0) { $0 + $1.amount(base: expenseBase) } }

    /// Purchases outside the payslip, spread per month.
    var periodicTotal: Double {
        trackedItems.filter { $0.includeInBudget }.reduce(0) { $0 + $1.monthlyCost }
    }

    var remaining: Double { net - totalExpenses - periodicTotal }

    var totalHours: Double {
        incomes.filter { $0.isActive && $0.kind == .hourly }.reduce(0) { $0 + $1.hours }
    }

    static let starter = Budget(
        incomes: [
            IncomeItem(name: "משכורת")
        ],
        deductions: [
            .automatic(.incomeTax),
            .automatic(.nationalInsurance),
            .automatic(.healthInsurance),
            .automatic(.pension)
        ],
        expenses: [
            CostItem(name: "שכירות"),
            CostItem(name: "טלפון ואינטרנט"),
            CostItem(name: "חיסכון", kind: .percent, value: 10)
        ]
    )
}

extension Budget {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        incomes = try c.decodeIfPresent([IncomeItem].self, forKey: .incomes) ?? []
        deductions = try c.decodeIfPresent([CostItem].self, forKey: .deductions) ?? []
        expenses = try c.decodeIfPresent([CostItem].self, forKey: .expenses) ?? []
        trackedItems = try c.decodeIfPresent([TrackedItem].self, forKey: .trackedItems) ?? []
        taxSettings = try c.decodeIfPresent(TaxSettings.self, forKey: .taxSettings) ?? TaxSettings()
        rates = (try? c.decodeIfPresent(TaxRates.self, forKey: .rates)) ?? .bundled
    }
}

// MARK: - History

struct MonthRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var year: Int
    var month: Int
    var note: String = ""
    var budget: Budget
    var savedAt: Date = Date()
    /// Net salary that actually reached the bank this month (from the payslip).
    var actualNet: Double? = nil

    var title: String { Fmt.monthTitle(year: year, month: month) }
    var shortTitle: String { "\(month)/\(year % 100)" }
    var sortKey: Int { year * 100 + month }
}

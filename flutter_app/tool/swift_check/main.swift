import Foundation

// Decodes a household document with the Swift app's own model code and prints what the app would see.
// Run through tool/swift_check.sh, which compiles this together with the real model files from Maskoret/.

/// What `Store.dashboard` gives the month calculation: one member's data.
struct Dashboard {
    var budget: Budget
    var money: MoneyData
    var history: [MonthRecord]
    func record(year: Int, month: Int) -> MonthRecord? { history.first { $0.year == year && $0.month == month } }
}
var dashboard = Dashboard(budget: .starter, money: MoneyData(), history: [])

// "max <file.xlsx>": the Swift app's own reading of a Max statement (XLSXReader + MaxParser in Card.swift).
if CommandLine.arguments[1] == "max" {
    let result = try MaxParser.parse(XLSXReader.read(URL(fileURLWithPath: CommandLine.arguments[2])))
    let rows: [[String: Any]] = result.transactions.map { t in
        ["id": t.id, "amount": t.amount, "originalAmount": t.originalAmount, "date": t.date.timeIntervalSinceReferenceDate,
         "chargeDate": t.chargeDate?.timeIntervalSinceReferenceDate ?? 0, "status": t.status.rawValue,
         "category": t.category, "merchant": t.merchant, "note": t.note, "installment": t.installment.map { "\($0.number)/\($0.of)" } ?? ""]
    }
    print(String(data: try JSONSerialization.data(withJSONObject: ["label": result.billingLabel, "rows": rows], options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}

let path = CommandLine.arguments[1]
let data = try Data(contentsOf: URL(fileURLWithPath: path))
let family = try JSONDecoder().decode(FamilyBackup.self, from: data)
let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let rawFiles = raw["files"] as! [String: Any]
var out: [String: Any] = ["members": family.state.members.count]
var files: [String: Any] = [:]
for (id, file) in family.files {
    // Strict decode of MoneyData: Swift reads `money` with `try?`, so any type mistake would silently drop it.
    let rawFile = rawFiles[id] as! [String: Any]
    let moneyData = try JSONSerialization.data(withJSONObject: rawFile["money"] as Any)
    let money = try JSONDecoder().decode(MoneyData.self, from: moneyData)
    let budgetData = try JSONSerialization.data(withJSONObject: rawFile["budget"] as Any)
    let budget = try JSONDecoder().decode(Budget.self, from: budgetData)
    let historyData = try JSONSerialization.data(withJSONObject: rawFile["history"] ?? [])
    let history = try JSONDecoder().decode([MonthRecord].self, from: historyData)
    precondition(file.money != nil, "money was dropped")
    MoneyCalc.prime = money.primeRate
    let now = Date(timeIntervalSinceReferenceDate: Double(CommandLine.arguments[2])!)
    dashboard = Dashboard(budget: budget, money: money, history: history)
    let cal = Calendar.current
    var months: [[String: Any]] = []
    for offset in -3...2 {
        let d = cal.date(byAdding: .month, value: offset, to: now)!
        let y = cal.component(.year, from: d), m = cal.component(.month, from: d)
        let p = monthPicture(year: y, month: m)
        months.append(["key": y * 100 + m, "remaining": p.remaining, "net": p.net, "spending": p.spendingTotal,
                       "periodic": p.periodic, "toSavings": p.toSavingsTotal, "card": p.cardTotal,
                       "installments": p.installmentsTotal, "oneOffs": p.oneOffTotal,
                       "installmentsAfter": p.installmentsAfterThisMonth, "cardEstimated": p.cardEstimated])
    }
    for r in history {
        let p = monthPicture(year: r.year, month: r.month, budget: r.budget)
        months.append(["key": r.year * 100 + r.month, "record": true, "remaining": p.remaining, "net": p.net,
                       "card": p.cardTotal, "installments": p.installmentsTotal, "oneOffs": p.oneOffTotal,
                       "toSavings": p.toSavingsTotal, "spending": p.spendingTotal, "periodic": p.periodic,
                       "installmentsAfter": p.installmentsAfterThisMonth, "cardEstimated": p.cardEstimated])
    }
    var cards: [[String: Any]] = []
    for key in money.cardBillingKeys {
        let c = CardMonthSummary.of(money.cardTransactions(billingKey: key))
        cards.append(["key": key, "total": c.total, "fixedLinked": c.fixedLinked, "trackedLinked": c.trackedLinked,
                      "variable": c.variable, "pending": c.pending, "owed": c.owed, "installments": c.installments,
                      "ignored": c.ignored, "count": c.count])
    }
    let plans = money.installmentPlans.map { p -> [String: Any] in
        ["id": p.id, "total": p.total, "count": p.count, "payments": p.payments.map { $0.amount },
         "keys": p.payments.map { $0.billingKey }, "variable": p.countsAsVariable]
    }
    let cardInfo: [String: Any] = ["months": cards, "average": money.averageCardVariable(),
                                   "usualDay": money.usualChargeDay ?? 0, "statementKeys": money.cardStatementKeys,
                                   "plans": plans,
                                   "manual": money.manualCardPayments.map { ["amount": $0.amount, "key": $0.billingKey] }]
    files[id] = [
        "card": cardInfo,
        "months": months,
        "gross": budget.gross, "net": budget.net, "totalDeductions": budget.totalDeductions,
        "totalExpenses": budget.totalExpenses, "periodicTotal": budget.periodicTotal, "remaining": budget.remaining,
        "deductions": budget.deductions.map { budget.deductionAmount($0) },
        "incomes": budget.incomes.count, "history": history.count,
        "accounts": money.accounts.map { MoneyCalc.value(of: $0, on: now, transactions: money.transactions) },
        "transactions": money.transactions.count, "cardTransactions": money.cardTransactions.count,
        "trends": money.trends.count, "receivables": money.receivables.count,
    ]
}
out["files"] = files
print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)

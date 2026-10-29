import Foundation

// Decodes a household document with the Swift app's own model code and prints what the app would see.
// Run through tool/swift_check.sh, which compiles this together with the real model files from Maskoret/.

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
    files[id] = [
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

import Foundation

// MARK: - Changes the model proposes, applied only after the user approves them

/// One change the model proposes, written by it in an ```actions block:
/// ```actions
/// {"summary":"…","actions":[{"type":"update_account","account":"פיקדון","balance":12000}]}
/// ```
/// The block is the same in every engine (cloud and manual), so nothing depends on a provider's tool-calling.
/// Things are found by name in the data of the member being edited.
struct AIAction: Identifiable {
    let id: Int
    let type: String
    let fields: [String: Any]

    static let types: Set<String> = [
        "add_account", "update_account", "add_trend", "update_trend",
        "add_expense", "update_expense", "add_transaction"
    ]

    func string(_ key: String) -> String? {
        if let s = fields[key] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = fields[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func number(_ key: String) -> Double? {
        if let n = fields[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = fields[key] as? String {
            let cleaned = s.filter { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(cleaned)
        }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = fields[key] as? Bool { return b }
        if let s = fields[key] as? String { return ["true", "כן", "yes", "1"].contains(s.lowercased()) }
        return nil
    }

    func date(_ key: String) -> Date? {
        guard let s = string(key) else { return nil }
        for format in ["yyyy-MM-dd", "dd/MM/yyyy", "d/M/yyyy", "dd.MM.yyyy", "yyyy-MM"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: s) { return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d }
        }
        return nil
    }
}

struct AIActionPlan {
    var summary: String
    var actions: [AIAction]

    /// Reads the JSON of an ```actions block; unknown action types are left out.
    static func decode(_ raw: String) -> AIActionPlan? {
        var json = raw
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{201E}", with: "\"")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = json.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let last = json.lastIndex(where: { $0 == "}" || $0 == "]" }), first < last {
            json = String(json[first...last])
        }
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var summary = ""
        var list: [[String: Any]] = []
        if let dict = object as? [String: Any] {
            summary = dict["summary"] as? String ?? ""
            list = dict["actions"] as? [[String: Any]] ?? []
        } else if let array = object as? [[String: Any]] {
            list = array
        }
        let actions = list.enumerated().compactMap { index, item -> AIAction? in
            guard let type = item["type"] as? String, AIAction.types.contains(type) else { return nil }
            return AIAction(id: index, type: type, fields: item)
        }
        guard !actions.isEmpty else { return nil }
        return AIActionPlan(summary: summary, actions: actions)
    }
}

// MARK: - Polishing a proposal before applying it

extension AIAction {
    /// The fields the user can change, in this order, with their Hebrew names.
    static let editableFields: [(key: String, label: String)] = [
        ("name", "שם"), ("title", "כותרת"), ("account", "חשבון"), ("trend", "מגמה"), ("expense", "הוצאה"),
        ("new_name", "שם חדש"), ("kind", "סוג"), ("amount", "סכום"), ("balance", "יתרה"), ("balance_date", "יתרה נכון ל-"),
        ("annual_rate", "ריבית שנתית (%)"), ("rate_type", "סוג ריבית (fixed/prime)"), ("prime_minus", "פריים מינוס (%)"),
        ("monthly_contribution", "הפקדה חודשית"), ("contribution_day", "יום הפקדה"), ("monthly_limit", "תקרה חודשית"),
        ("charge_day", "יום חיוב"), ("date", "תאריך"), ("start_date", "התחלה"), ("maturity_date", "סיום"),
        ("to_account", "אל חשבון"), ("paid_by_card", "באשראי (true/false)"), ("installments", "תשלומים"),
        ("active", "פעילה (true/false)"), ("emoji", "אימוג׳י"), ("note", "הערה")
    ]

    static let numberFields: Set<String> = [
        "amount", "balance", "annual_rate", "prime_minus", "monthly_contribution", "contribution_day",
        "monthly_limit", "charge_day", "installments", "interest_tax"
    ]
    static let boolFields: Set<String> = ["paid_by_card", "active"]

    /// The value of a field as text in the edit box.
    func text(_ key: String) -> String {
        switch fields[key] {
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return Fmt.number(n.doubleValue)
        case let s as String: return s
        default: return ""
        }
    }

    /// The same action with the user's changes (empty text removes the field).
    func edited(_ changes: [String: String]) -> AIAction {
        var f = fields
        for (key, raw) in changes {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                f.removeValue(forKey: key)
            } else if AIAction.numberFields.contains(key),
                      let n = Double(value.filter { $0.isNumber || $0 == "." || $0 == "-" }) {
                f[key] = n
            } else if AIAction.boolFields.contains(key) {
                f[key] = ["true", "כן", "yes", "1"].contains(value.lowercased())
            } else {
                f[key] = value
            }
        }
        return AIAction(id: id, type: type, fields: f)
    }
}

extension AIActionPlan {
    /// The block as JSON again — what the conversation keeps once the user changed something.
    var json: String {
        let object: [String: Any] = ["summary": summary, "actions": actions.map(\.fields)]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - What it will do, in Hebrew

extension AIAction {
    private func m(_ v: Double) -> String { Fmt.money(v) }

    var icon: String {
        switch type {
        case "add_account", "update_account": return "banknote.fill"
        case "add_trend", "update_trend": return "chart.line.uptrend.xyaxis"
        case "add_expense", "update_expense": return "arrow.triangle.2.circlepath"
        default: return "calendar.badge.plus"
        }
    }

    var title: String {
        switch type {
        case "add_account": return "חשבון חדש: " + (string("name") ?? "")
        case "update_account": return "עדכון חשבון: " + (string("account") ?? string("name") ?? "")
        case "add_trend": return "מגמה חדשה: " + (string("name") ?? "")
        case "update_trend": return "עדכון מגמה: " + (string("trend") ?? string("name") ?? "")
        case "add_expense": return "הוצאה קבועה חדשה: " + (string("name") ?? "")
        case "update_expense": return "עדכון הוצאה קבועה: " + (string("expense") ?? string("name") ?? "")
        default:
            let kind = string("kind") ?? "expense"
            let word = kind == "income" ? "הכנסה" : kind == "transfer" ? "העברה" : "הוצאה"
            return word + " חד-פעמית: " + (string("title") ?? string("name") ?? "")
        }
    }

    /// The details, one line each.
    var details: [String] {
        var out: [String] = []
        if let k = string("kind"), type == "add_account", let kind = AccountKind(rawValue: k) { out.append("סוג: " + kind.title) }
        if let v = number("balance") { out.append("יתרה: " + m(v) + (string("balance_date").map { " (נכון ל-\($0))" } ?? "")) }
        if let v = number("annual_rate") { out.append("ריבית שנתית: " + Fmt.percent(v)) }
        if string("rate_type") == "prime" { out.append("צמוד לפריים" + (number("prime_minus").map { " מינוס " + Fmt.percent($0) } ?? "")) }
        if let v = number("monthly_contribution") { out.append("הפקדה חודשית: " + m(v)) }
        if let v = string("start_date") { out.append("התחלה: " + v) }
        if let v = string("maturity_date") { out.append("סיום: " + v) }
        if let v = number("monthly_limit") { out.append(v > 0 ? "תקרה חודשית: " + m(v) : "בלי תקרה") }
        if let v = string("new_name") { out.append("שם חדש: " + v) }
        if let v = number("amount") { out.append("סכום: " + m(v)) }
        if let v = number("charge_day") { out.append("יורד ב-\(Int(v)) לחודש") }
        if let v = string("to_account") { out.append(type == "add_transaction" ? "אל: " + v : "מועבר לחיסכון: " + v) }
        if type == "add_transaction" {
            if let v = string("account") { out.append("מ: " + v) }
            if let v = string("date") { out.append("תאריך: " + v) }
            if bool("paid_by_card") == true {
                let n = Int(number("installments") ?? 1)
                out.append(n > 1 ? "באשראי, \(n) תשלומים" : "באשראי")
            }
        }
        if let v = bool("active") { out.append(v ? "פעילה" : "מושבתת") }
        if let v = string("note") { out.append("הערה: " + v) }
        if let v = string("why") { out.append("למה: " + v) }
        return out
    }
}

// MARK: - Applying

enum AIActionError: LocalizedError {
    case notFound(String, String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let what, let name): return "לא נמצא \(what) בשם ״\(name)״"
        case .missing(let what): return "חסר \(what)"
        }
    }
}

extension Store {
    /// Finds by name, forgiving the family emoji the summary puts in front of names and small differences.
    private static func find<T>(_ items: [T], _ name: String?, _ key: (T) -> String) -> T? {
        guard let name else { return nil }
        let wanted = normalized(name)
        if let exact = items.first(where: { normalized(key($0)) == wanted }) { return exact }
        return items.first { let n = normalized(key($0)); return !n.isEmpty && (n.contains(wanted) || wanted.contains(n)) }
    }

    private static func normalized(_ s: String) -> String {
        s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(String.init).joined().lowercased()
    }

    /// Applies one approved change to the member being edited.
    func apply(_ action: AIAction) throws {
        switch action.type {
        case "add_account":
            guard let name = action.string("name") else { throw AIActionError.missing("שם לחשבון") }
            var a = Account(name: name, kind: AccountKind(rawValue: action.string("kind") ?? "") ?? .savings)
            fill(&a, from: action)
            money.accounts.append(a)

        case "update_account":
            let name = action.string("account") ?? action.string("name")
            guard let found = Store.find(money.accounts, name, { $0.name }),
                  let i = money.accounts.firstIndex(where: { $0.id == found.id }) else {
                throw AIActionError.notFound("חשבון", name ?? "")
            }
            if let newName = action.string("new_name") { money.accounts[i].name = newName }
            fill(&money.accounts[i], from: action)

        case "add_trend":
            guard let name = action.string("name") else { throw AIActionError.missing("שם למגמה") }
            var t = Trend(name: name)
            if let e = action.string("emoji") { t.emoji = e }
            if let l = action.number("monthly_limit") { t.monthlyLimit = max(0, l) }
            money.trends.append(t)

        case "update_trend":
            let name = action.string("trend") ?? action.string("name")
            guard let found = Store.find(money.trends, name, { $0.name }),
                  let i = money.trends.firstIndex(where: { $0.id == found.id }) else {
                throw AIActionError.notFound("מגמה", name ?? "")
            }
            if let l = action.number("monthly_limit") { money.trends[i].monthlyLimit = max(0, l) }
            if let n = action.string("new_name") { money.trends[i].name = n }
            if let e = action.string("emoji") { money.trends[i].emoji = e }

        case "add_expense":
            guard let name = action.string("name") else { throw AIActionError.missing("שם להוצאה") }
            guard let amount = action.number("amount") else { throw AIActionError.missing("סכום") }
            var c = CostItem(name: name, kind: .fixed, value: abs(amount))
            if let d = action.number("charge_day") { c.chargeDay = min(31, max(1, Int(d))) }
            if let target = action.string("to_account") {
                guard let a = Store.find(money.accounts, target, { $0.name }) else { throw AIActionError.notFound("חשבון", target) }
                c.targetAccountID = a.id
            }
            budget.expenses.append(c)

        case "update_expense":
            let name = action.string("expense") ?? action.string("name")
            guard let found = Store.find(budget.expenses, name, { $0.name }),
                  let i = budget.expenses.firstIndex(where: { $0.id == found.id }) else {
                throw AIActionError.notFound("הוצאה קבועה", name ?? "")
            }
            if let v = action.number("amount") { budget.expenses[i].value = abs(v); budget.expenses[i].kind = .fixed }
            if let a = action.bool("active") { budget.expenses[i].isActive = a }
            if let d = action.number("charge_day") { budget.expenses[i].chargeDay = min(31, max(1, Int(d))) }
            if let n = action.string("new_name") { budget.expenses[i].name = n }

        case "add_transaction":
            guard let amount = action.number("amount") else { throw AIActionError.missing("סכום") }
            var t = MoneyTransaction()
            t.title = action.string("title") ?? action.string("name") ?? "תנועה"
            t.amount = abs(amount)
            t.kind = TransactionKind(rawValue: action.string("kind") ?? "") ?? .expense
            t.date = action.date("date") ?? Date()
            t.note = action.string("note") ?? ""
            if let from = action.string("account") {
                guard let a = Store.find(money.accounts, from, { $0.name }) else { throw AIActionError.notFound("חשבון", from) }
                t.accountID = a.id
            } else {
                t.accountID = money.checking?.id
            }
            if let to = action.string("to_account") {
                guard let a = Store.find(money.accounts, to, { $0.name }) else { throw AIActionError.notFound("חשבון", to) }
                t.toAccountID = a.id
            }
            if t.kind == .expense, action.bool("paid_by_card") == true {
                t.paidByCard = true
                t.cardInstallments = max(1, Int(action.number("installments") ?? 1))
            }
            money.transactions.append(t)

        default:
            break
        }
    }

    private func fill(_ a: inout Account, from action: AIAction) {
        if let k = action.string("kind"), let kind = AccountKind(rawValue: k) { a.kind = kind }
        if let v = action.number("balance") {
            a.balances.append(BalanceEntry(date: action.date("balance_date") ?? Date(), amount: v, note: "עודכן על ידי ה-AI"))
        }
        if let v = action.number("annual_rate") { a.annualRate = v }
        if let r = action.string("rate_type"), let type = RateType(rawValue: r) { a.rateType = type }
        if let v = action.number("prime_minus") { a.primeMinus = v; if action.string("rate_type") == nil { a.rateType = .prime } }
        if let v = action.number("monthly_contribution") { a.monthlyContribution = max(0, v) }
        if let v = action.number("contribution_day") { a.contributionDay = min(28, max(1, Int(v))) }
        if let v = action.number("interest_tax") { a.interestTax = v }
        if let d = action.date("start_date") { a.startDate = d }
        if let d = action.date("maturity_date") { a.maturityDate = d }
        if let n = action.string("note") { a.note = n }
    }
}

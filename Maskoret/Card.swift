import Foundation

// MARK: - Model

enum CardTxStatus: String, Codable {
    case charged
    case pending
    case foreign

    var title: String {
        switch self {
        case .charged: return ""
        case .pending: return "ממתין לקליטה"
        case .foreign: return "חו״ל"
        }
    }
}

/// One line from a credit-card statement (Max export).
struct CardTransaction: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var date: Date
    var merchant: String
    var category: String = ""
    var cardLast4: String = ""
    var type: String = ""
    /// Amount in ₪ that is (or will be) charged. Negative = refund.
    var amount: Double = 0
    var originalAmount: Double = 0
    var originalCurrency: String = "₪"
    var chargeDate: Date? = nil
    var chargeEstimated: Bool = false
    var note: String = ""
    var method: String = ""
    var status: CardTxStatus = .charged
    var linkedExpenseID: UUID? = nil
    var linkedTrackedID: UUID? = nil
    var ignored: Bool = false
    var importedAt: Date = Date()
    /// Part of the charge someone owes you back ("חייבים לי") — not your spending.
    var owedPortion: Double = 0

    private enum CodingKeys: String, CodingKey {
        case id, date, merchant, category, cardLast4, type, amount, originalAmount, originalCurrency
        case chargeDate, chargeEstimated, note, method, status, linkedExpenseID, linkedTrackedID, ignored, importedAt, owedPortion
    }

    /// What is really your own spending in this charge.
    var myAmount: Double { amount > 0 ? max(0, amount - owedPortion) : amount }

    /// Spending that is not covered by a fixed expense or a tracked purchase.
    var isVariable: Bool { !ignored && linkedExpenseID == nil && linkedTrackedID == nil }

    var billingKey: Int? {
        guard let chargeDate else { return nil }
        let cal = Calendar.current
        return cal.component(.year, from: chargeDate) * 100 + cal.component(.month, from: chargeDate)
    }

    var merchantKey: String { CardTransaction.key(for: merchant) }

    /// 1 for the first identical purchase (same day, merchant, card, amount) in the statement, 2 for the second…
    var occurrence: Int { Int(id.split(separator: "#").last ?? "1") ?? 1 }

    /// The id without the occurrence suffix — shared by identical purchases.
    var baseID: String {
        guard let hash = id.lastIndex(of: "#") else { return id }
        return String(id[..<hash])
    }

    static func key(for merchant: String) -> String {
        merchant.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

extension CardTransaction {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        cardLast4 = try c.decodeIfPresent(String.self, forKey: .cardLast4) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        originalAmount = try c.decodeIfPresent(Double.self, forKey: .originalAmount) ?? 0
        originalCurrency = try c.decodeIfPresent(String.self, forKey: .originalCurrency) ?? "₪"
        chargeDate = try c.decodeIfPresent(Date.self, forKey: .chargeDate)
        chargeEstimated = try c.decodeIfPresent(Bool.self, forKey: .chargeEstimated) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        status = (try? c.decodeIfPresent(CardTxStatus.self, forKey: .status)) ?? .charged
        linkedExpenseID = try c.decodeIfPresent(UUID.self, forKey: .linkedExpenseID)
        linkedTrackedID = try c.decodeIfPresent(UUID.self, forKey: .linkedTrackedID)
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        owedPortion = (try? c.decodeIfPresent(Double.self, forKey: .owedPortion)) ?? 0
    }
}

/// "Every charge from this merchant belongs to this fixed expense."
struct MerchantRule: Codable, Equatable, Hashable {
    var merchantKey: String
    var expenseID: UUID
}

struct CardImport: Identifiable, Codable, Equatable {
    var id = UUID()
    var fileName: String
    var importedAt: Date = Date()
    var billingLabel: String = ""
    var count: Int = 0
    var added: Int = 0
    // Optional so files saved by 2.5 still load.
    var updated: Int? = nil
    var confirmed: Int? = nil
    var repeats: Int? = nil
    var removedStale: Int? = nil

    /// Human-readable result of the import.
    var summary: String {
        var parts = ["\(count) עסקאות בקובץ" + (billingLabel.isEmpty ? "" : " (חיוב " + billingLabel + ")")]
        parts.append("\(added) חדשות")
        if let updated, updated > 0 { parts.append("\(updated) כבר היו — עודכנו בלי כפילות") }
        if let confirmed, confirmed > 0 { parts.append("\(confirmed) ממתינות נקלטו סופית") }
        if let repeats, repeats > 0 { parts.append("\(repeats) רכישות זהות חוזרות נשמרו (באמת נקנו פעמיים)") }
        if let removedStale, removedStale > 0 { parts.append("\(removedStale) ממתינות ישנות הוסרו") }
        return parts.joined(separator: " · ")
    }
}

struct CategoryAmount: Identifiable {
    let name: String
    let amount: Double
    var id: String { name }
}

struct CardMonthSummary {
    var total: Double = 0
    var fixedLinked: Double = 0
    var trackedLinked: Double = 0
    var variable: Double = 0
    var pending: Double = 0
    var ignored: Double = 0
    /// Installment payments in this statement (variable ones).
    var installments: Double = 0
    /// Paid for others — they owe it back.
    var owed: Double = 0
    var byCategory: [CategoryAmount] = []
    var count: Int = 0

    static func of(_ txs: [CardTransaction]) -> CardMonthSummary {
        var s = CardMonthSummary()
        var categories: [String: Double] = [:]
        for t in txs {
            s.count += 1
            if t.ignored { s.ignored += t.amount; continue }
            s.total += t.amount
            if t.status == .pending { s.pending += t.amount }
            if t.linkedExpenseID != nil {
                s.fixedLinked += t.amount
            } else if t.linkedTrackedID != nil {
                s.trackedLinked += t.amount
            } else {
                s.variable += t.myAmount
                s.owed += t.amount - t.myAmount
                if t.installment != nil {
                    s.installments += t.myAmount
                } else if t.myAmount != 0 {
                    categories[t.category.isEmpty ? "שונות" : t.category, default: 0] += t.myAmount
                }
            }
        }
        s.byCategory = categories.map { CategoryAmount(name: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
        return s
    }
}

extension MoneyData {
    func cardTransactions(billingKey: Int) -> [CardTransaction] {
        cardTransactions.filter { $0.billingKey == billingKey }.sorted { $0.date > $1.date }
    }

    /// Billing months that have data, newest first.
    var cardBillingKeys: [Int] {
        Array(Set(cardTransactions.compactMap { $0.billingKey })).sorted(by: >)
    }

    /// Billing months that contain the main statement (a charge on the usual charge day).
    var cardStatementKeys: [Int] {
        guard let day = usualChargeDay else { return cardBillingKeys }
        let keys = Set(cardTransactions.compactMap { t -> Int? in
            guard !t.chargeEstimated, let d = t.chargeDate, Calendar.current.component(.day, from: d) == day else { return nil }
            return t.billingKey
        })
        return keys.sorted(by: >)
    }

    /// Average variable card spending per month, from the last (up to) 3 full statements.
    func averageCardVariable() -> Double {
        let keys = cardStatementKeys.prefix(3)
        guard !keys.isEmpty else { return 0 }
        let total = keys.reduce(0.0) { sum, key in
            sum + cardTransactions(billingKey: key).filter { $0.isVariable && $0.installment == nil }.reduce(0) { $0 + $1.myAmount }
        }
        return total / Double(keys.count)
    }

    func variableTotal(billingKey: Int) -> Double {
        cardTransactions(billingKey: billingKey).filter { $0.isVariable }.reduce(0) { $0 + $1.myAmount }
    }

    /// The usual day of the month the card is charged (e.g. 2).
    var usualChargeDay: Int? {
        let days = cardTransactions
            .filter { $0.status != .pending && !$0.chargeEstimated }
            .compactMap { $0.chargeDate.map { Calendar.current.component(.day, from: $0) } }
        guard !days.isEmpty else { return nil }
        let counts = Dictionary(grouping: days, by: { $0 }).mapValues { $0.count }
        return counts.max { $0.value < $1.value }?.key
    }
}

// MARK: - XLSX reader (no dependencies)

enum CardImportError: LocalizedError {
    case unreadable
    case notMax
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: return "לא הצלחתי לפתוח את הקובץ. ודא שזה קובץ Excel (‎.xlsx) שיוצא מ-Max."
        case .notMax: return "הקובץ לא נראה כמו פירוט עסקאות של Max (לא נמצאה עמודת ״תאריך עסקה״)."
        case .empty: return "לא נמצאו עסקאות בקובץ."
        }
    }
}

enum XLSXReader {
    struct Sheet {
        let name: String
        let rows: [[String]]
    }

    static func read(_ url: URL) throws -> [Sheet] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("maskoret-xlsx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        #if os(macOS)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, tmp.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw CardImportError.unreadable }
        #else
        do {
            try FolderBookmark.access(url) { try ZipReader.extract(url, to: tmp) }
        } catch {
            throw CardImportError.unreadable
        }
        #endif

        let xl = tmp.appendingPathComponent("xl", isDirectory: true)
        let shared = SharedStringsParser.parse(xl.appendingPathComponent("sharedStrings.xml"))
        let rels = RelsParser.parse(xl.appendingPathComponent("_rels/workbook.xml.rels"))
        let sheets = WorkbookParser.parse(xl.appendingPathComponent("workbook.xml"))
        guard !sheets.isEmpty else { throw CardImportError.unreadable }

        return sheets.compactMap { sheet in
            guard let target = rels[sheet.rid] else { return nil }
            let path = target.hasPrefix("/")
                ? tmp.appendingPathComponent(String(target.dropFirst()))
                : xl.appendingPathComponent(target)
            return Sheet(name: sheet.name, rows: SheetParser.parse(path, shared: shared))
        }
    }

    static func columnIndex(_ ref: String) -> Int {
        var index = 0
        for ch in ref.uppercased() {
            guard let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(index - 1, 0)
    }

    // MARK: Parsers

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        var current = ""
        var inSI = false
        var inT = false

        static func parse(_ url: URL) -> [String] {
            guard let parser = XMLParser(contentsOf: url) else { return [] }
            let d = SharedStringsParser()
            parser.delegate = d
            parser.parse()
            return d.strings
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { inSI = true; current = "" }
            if name == "t" && inSI { inT = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inT { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inT = false }
            if name == "si" { strings.append(current); inSI = false }
        }
    }

    private final class RelsParser: NSObject, XMLParserDelegate {
        var map: [String: String] = [:]

        static func parse(_ url: URL) -> [String: String] {
            guard let parser = XMLParser(contentsOf: url) else { return [:] }
            let d = RelsParser()
            parser.delegate = d
            parser.parse()
            return d.map
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
                map[id] = target
            }
        }
    }

    private final class WorkbookParser: NSObject, XMLParserDelegate {
        var sheets: [(name: String, rid: String)] = []

        static func parse(_ url: URL) -> [(name: String, rid: String)] {
            guard let parser = XMLParser(contentsOf: url) else { return [] }
            let d = WorkbookParser()
            parser.delegate = d
            parser.parse()
            return d.sheets
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "sheet", let sheetName = attributes["name"] {
                let rid = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value ?? ""
                sheets.append((sheetName, rid))
            }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        var cells: [Int: [Int: String]] = [:]
        var ref = ""
        var type = ""
        var value = ""
        var collecting = false

        init(shared: [String]) { self.shared = shared }

        static func parse(_ url: URL, shared: [String]) -> [[String]] {
            guard let parser = XMLParser(contentsOf: url) else { return [] }
            let d = SheetParser(shared: shared)
            parser.delegate = d
            parser.parse()
            guard let maxRow = d.cells.keys.max() else { return [] }
            var rows: [[String]] = []
            for r in 1...maxRow {
                let row = d.cells[r] ?? [:]
                let maxCol = row.keys.max() ?? -1
                rows.append(maxCol < 0 ? [] : (0...maxCol).map { row[$0] ?? "" })
            }
            return rows
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "c":
                ref = attributes["r"] ?? ""
                type = attributes["t"] ?? ""
                value = ""
            case "v", "t":
                collecting = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting { value += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t":
                collecting = false
            case "c":
                let letters = ref.prefix { $0.isLetter }
                let digits = ref.drop { $0.isLetter }
                guard let row = Int(digits) else { return }
                var text = value
                if type == "s", let i = Int(value), i >= 0, i < shared.count { text = shared[i] }
                cells[row, default: [:]][XLSXReader.columnIndex(String(letters))] = text
            default:
                break
            }
        }
    }
}

// MARK: - Max statement parser

enum MaxParser {
    struct Result {
        var billingLabel: String
        var transactions: [CardTransaction]
    }

    static func parseDate(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        for format in ["dd-MM-yyyy", "dd/MM/yyyy", "dd.MM.yyyy", "dd-MM-yy", "dd/MM/yy", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: d) }
        }
        // Excel serial date
        if let serial = Double(s), serial > 20000, serial < 80000 {
            var base = DateComponents()
            base.year = 1899; base.month = 12; base.day = 30; base.hour = 12
            if let start = Calendar.current.date(from: base) {
                return Calendar.current.date(byAdding: .day, value: Int(serial), to: start)
            }
        }
        return nil
    }

    static func parseAmount(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "₪", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    static func parse(_ sheets: [XLSXReader.Sheet]) throws -> Result {
        var label = ""
        var parsed: [(tx: CardTransaction, needsCharge: Bool)] = []
        var foundHeader = false

        for sheet in sheets {
            guard let headerIndex = sheet.rows.firstIndex(where: { $0.contains { $0.trimmingCharacters(in: .whitespaces) == "תאריך עסקה" } }) else {
                continue
            }
            foundHeader = true
            let header = sheet.rows[headerIndex].map { $0.trimmingCharacters(in: .whitespaces) }
            func col(_ name: String) -> Int? { header.firstIndex(of: name) }
            func colContaining(_ part: String) -> Int? { header.firstIndex { $0.contains(part) } }

            if label.isEmpty {
                for row in sheet.rows.prefix(headerIndex) {
                    if let cell = row.first(where: { $0.range(of: #"^\d{1,2}/\d{4}$"#, options: .regularExpression) != nil }) {
                        label = cell
                        break
                    }
                }
            }

            let status: CardTxStatus = sheet.name.contains("טרם") ? .pending
                : (sheet.name.contains("חו") ? .foreign : .charged)

            let cDate = col("תאריך עסקה")
            let cMerchant = col("שם בית העסק") ?? colContaining("בית העסק")
            let cCategory = col("קטגוריה")
            let cCard = colContaining("ספרות")
            let cType = col("סוג עסקה")
            let cAmount = col("סכום חיוב")
            let cOriginal = col("סכום עסקה מקורי")
            let cOrigCurrency = col("מטבע עסקה מקורי")
            let cCharge = col("תאריך חיוב")
            let cNote = col("הערות")
            let cMethod = colContaining("אופן ביצוע")

            for row in sheet.rows.dropFirst(headerIndex + 1) {
                func cell(_ c: Int?) -> String {
                    guard let c, c < row.count else { return "" }
                    return row[c].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let date = parseDate(cell(cDate)) else { continue }
                let merchant = cell(cMerchant)
                guard !merchant.isEmpty else { continue }
                let original = parseAmount(cell(cOriginal)) ?? 0
                let charged = parseAmount(cell(cAmount))
                let chargeDate = parseDate(cell(cCharge))
                let tx = CardTransaction(
                    id: "",
                    date: date,
                    merchant: merchant,
                    category: cell(cCategory),
                    cardLast4: cell(cCard),
                    type: cell(cType),
                    amount: charged ?? original,
                    originalAmount: original,
                    originalCurrency: cell(cOrigCurrency).isEmpty ? "₪" : cell(cOrigCurrency),
                    chargeDate: chargeDate,
                    chargeEstimated: chargeDate == nil,
                    note: cell(cNote),
                    method: cell(cMethod),
                    status: status
                )
                parsed.append((tx, chargeDate == nil))
            }
        }

        guard foundHeader else { throw CardImportError.notMax }
        guard !parsed.isEmpty else { throw CardImportError.empty }

        // Estimated charge date for pending items: the statement's billing month, on the usual charge day.
        let chargeDays = parsed.filter { $0.tx.status == .charged }.compactMap { $0.tx.chargeDate }
        let usualDay: Int = {
            let days = chargeDays.map { Calendar.current.component(.day, from: $0) }
            let counts = Dictionary(grouping: days, by: { $0 }).mapValues { $0.count }
            return counts.max { $0.value < $1.value }?.key ?? 2
        }()
        var estimated: Date? = nil
        let parts = label.split(separator: "/")
        if parts.count == 2, let m = Int(parts[0]), let y = Int(parts[1]) {
            estimated = Calendar.current.date(from: DateComponents(year: y, month: m, day: usualDay, hour: 12))
        }

        // Stable ids — identical purchases on the same day get #1, #2…
        var seen: [String: Int] = [:]
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyyMMdd"
        var result: [CardTransaction] = []
        for (tx, needsCharge) in parsed {
            var tx = tx
            if needsCharge { tx.chargeDate = estimated }
            let base = [
                tx.status == .pending ? "P" : "C",
                dayFormatter.string(from: tx.date),
                tx.merchantKey,
                tx.cardLast4,
                String(format: "%.2f", tx.originalAmount),
                tx.note
            ].joined(separator: "|")
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            tx.id = base + "#\(n)"
            result.append(tx)
        }
        return Result(billingLabel: label, transactions: result)
    }
}

// MARK: - Store actions

extension Store {
    /// Imports a Max export without creating duplicates:
    /// - A charge that was already imported (same day, merchant, card, original amount, installment note) is updated, not added.
    /// - Identical purchases made more than once (e.g. two coffees on the same day) are counted by how many times they appear
    ///   in the file (#1, #2…) — so real repeats are kept, and importing the same file again adds nothing.
    /// - A pending purchase that later shows up as charged is replaced by the charge (its links follow).
    @discardableResult
    func importCardFile(_ url: URL) throws -> CardImport {
        let result = try MaxParser.parse(XLSXReader.read(url))
        let cal = Calendar.current

        var m = money
        let rules = Dictionary(m.merchantRules.map { ($0.merchantKey, $0.expenseID) }, uniquingKeysWith: { a, _ in a })
        let expenseIDs = Set(budget.expenses.map { $0.id })

        func carry(_ old: CardTransaction, into tx: inout CardTransaction) {
            tx.linkedExpenseID = old.linkedExpenseID
            tx.linkedTrackedID = old.linkedTrackedID
            tx.ignored = old.ignored
            tx.importedAt = old.importedAt
            tx.owedPortion = old.owedPortion
        }
        func applyRule(_ tx: inout CardTransaction) {
            if tx.linkedExpenseID == nil, tx.linkedTrackedID == nil,
               let expense = rules[tx.merchantKey], expenseIDs.contains(expense) {
                tx.linkedExpenseID = expense
            }
        }
        func days(_ a: Date, _ b: Date) -> Int {
            abs(cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 99)
        }
        /// The existing pending item that is this purchase: same merchant, card and amount — same day first, else up to 2 days apart.
        func pendingMatch(_ tx: CardTransaction, in list: [CardTransaction]) -> Int? {
            let candidates = list.indices.filter {
                list[$0].merchantKey == tx.merchantKey && list[$0].cardLast4 == tx.cardLast4
                    && abs(list[$0].originalAmount - tx.originalAmount) < 0.005 && days(list[$0].date, tx.date) <= 2
            }
            return candidates.min { days(list[$0].date, tx.date) < days(list[$1].date, tx.date) }
        }

        var pending = m.cardTransactions.filter { $0.status == .pending }
        m.cardTransactions.removeAll { $0.status == .pending }
        var added = 0, updated = 0, confirmed = 0
        /// Pending id → final id, so trends keep their charges.
        var renamed: [String: String] = [:]

        // 1. Charged (and foreign) items.
        for var tx in result.transactions where tx.status != .pending {
            if let i = m.cardTransactions.firstIndex(where: { $0.id == tx.id }) {
                carry(m.cardTransactions[i], into: &tx)
                m.cardTransactions[i] = tx
                updated += 1
            } else {
                if let j = pendingMatch(tx, in: pending) {
                    carry(pending[j], into: &tx)
                    tx.importedAt = Date()
                    renamed[pending[j].id] = tx.id
                    pending.remove(at: j)
                    confirmed += 1
                } else {
                    added += 1
                }
                applyRule(&tx)
                m.cardTransactions.append(tx)
            }
        }

        // 2. Pending items in this file (each existing pending item is used once).
        var freshPending: [CardTransaction] = []
        for var tx in result.transactions where tx.status == .pending {
            if let j = pending.firstIndex(where: { $0.id == tx.id }) ?? pendingMatch(tx, in: pending) {
                carry(pending[j], into: &tx)
                if pending[j].id != tx.id { renamed[pending[j].id] = tx.id }
                pending.remove(at: j)
                updated += 1
            } else {
                added += 1
            }
            applyRule(&tx)
            freshPending.append(tx)
        }

        // 3. Older pending items that this file doesn't mention: keep them (they may be charged in another month)
        //    unless their expected charge date is long gone (cancelled authorisation).
        let staleBefore = cal.date(byAdding: .day, value: -35, to: Date()) ?? Date()
        let kept = pending.filter { ($0.chargeDate ?? $0.date) >= staleBefore }
        m.cardTransactions += freshPending + kept
        if !renamed.isEmpty {
            for i in m.receivables.indices {
                for (old, new) in renamed {
                    if let share = m.receivables[i].cardShares.removeValue(forKey: old) { m.receivables[i].cardShares[new] = share }
                    m.receivables[i].cardCreditIDs = m.receivables[i].cardCreditIDs.map { $0 == old ? new : $0 }
                }
            }
            for i in m.trends.indices {
                m.trends[i].cardIDs = m.trends[i].cardIDs.map { renamed[$0] ?? $0 }
                for (old, new) in renamed {
                    if let share = m.trends[i].shares.removeValue(forKey: old) { m.trends[i].shares[new] = share }
                }
            }
        }

        let repeats = result.transactions.filter { $0.occurrence > 1 }.count
        let record = CardImport(
            fileName: url.lastPathComponent,
            billingLabel: result.billingLabel,
            count: result.transactions.count,
            added: added,
            updated: updated,
            confirmed: confirmed,
            repeats: repeats,
            removedStale: pending.count - kept.count
        )
        syncOwedPortions(&m)
        m.cardImports.insert(record, at: 0)
        if m.cardImports.count > 50 { m.cardImports.removeLast(m.cardImports.count - 50) }
        money = m
        return record
    }

    /// Links a card charge to a fixed expense. With `remember`, every charge from the same merchant follows.
    func linkCard(_ txID: String, toExpense expenseID: UUID?, remember: Bool = true) {
        var m = money
        guard let i = m.cardTransactions.firstIndex(where: { $0.id == txID }) else { return }
        let key = m.cardTransactions[i].merchantKey
        m.cardTransactions[i].linkedExpenseID = expenseID
        if expenseID != nil { m.cardTransactions[i].linkedTrackedID = nil }

        if let expenseID, remember {
            m.merchantRules.removeAll { $0.merchantKey == key }
            m.merchantRules.append(MerchantRule(merchantKey: key, expenseID: expenseID))
            for j in m.cardTransactions.indices where m.cardTransactions[j].merchantKey == key
                && m.cardTransactions[j].linkedExpenseID == nil && m.cardTransactions[j].linkedTrackedID == nil {
                m.cardTransactions[j].linkedExpenseID = expenseID
            }
        }
        if expenseID == nil {
            m.merchantRules.removeAll { $0.merchantKey == key }
        }
        money = m
    }

    /// Links a card charge to a tracked purchase (e.g. shoes) and records the purchase there.
    func linkCard(_ txID: String, toTracked itemID: UUID?) {
        var m = money
        guard let i = m.cardTransactions.firstIndex(where: { $0.id == txID }) else { return }
        m.cardTransactions[i].linkedTrackedID = itemID
        if itemID != nil { m.cardTransactions[i].linkedExpenseID = nil }
        let tx = m.cardTransactions[i]
        money = m

        guard let itemID, let k = budget.trackedItems.firstIndex(where: { $0.id == itemID }) else { return }
        let price = tx.originalAmount != 0 ? abs(tx.originalAmount) : abs(tx.amount)
        let exists = budget.trackedItems[k].purchases.contains {
            Calendar.current.isDate($0.date, inSameDayAs: tx.date) && abs($0.price - price) < 0.01
        }
        if !exists {
            budget.trackedItems[k].purchases.append(Purchase(date: tx.date, price: price, note: tx.merchant))
        }
    }

    func setCardIgnored(_ txID: String, _ ignored: Bool) {
        guard let i = money.cardTransactions.firstIndex(where: { $0.id == txID }) else { return }
        money.cardTransactions[i].ignored = ignored
    }

    /// Card charges linked to each fixed expense in a billing month.
    func cardActuals(billingKey: Int) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        for t in money.cardTransactions(billingKey: billingKey) where !t.ignored {
            if let id = t.linkedExpenseID { result[id, default: 0] += t.amount }
        }
        return result
    }

    /// True when this month's charge day has passed but its statement wasn't imported yet.
    var cardImportDue: Bool {
        guard let day = money.usualChargeDay else { return false }
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.day, from: now) >= day else { return false }
        let key = cal.component(.year, from: now) * 100 + cal.component(.month, from: now)
        // Nothing to do if this month's statement — or a later one — is already in.
        return !money.cardStatementKeys.contains { $0 >= key }
    }
}

// MARK: - Installments (תשלומים)

extension CardTransaction {
    /// "תשלום 1 מתוך 2" → (1, 2).
    var installment: (number: Int, of: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"תשלום\s*(\d+)\s*מתוך\s*(\d+)"#),
              let match = regex.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)),
              let r1 = Range(match.range(at: 1), in: note), let r2 = Range(match.range(at: 2), in: note),
              let n = Int(note[r1]), let total = Int(note[r2]), total > 1 else { return nil }
        return (n, total)
    }

    /// Same purchase, every payment: merchant | purchase day | card | original amount.
    var installmentPlanKey: String {
        let day = Int(date.timeIntervalSince1970 / 86_400)
        return [merchantKey, String(day), cardLast4, String(format: "%.2f", originalAmount)].joined(separator: "|")
    }
}

struct InstallmentPayment: Identifiable {
    let number: Int
    let chargeDate: Date
    let amount: Double
    /// From an imported statement (false = expected).
    let imported: Bool
    var id: Int { number }

    var billingKey: Int {
        let cal = Calendar.current
        return cal.component(.year, from: chargeDate) * 100 + cal.component(.month, from: chargeDate)
    }
}

/// A purchase split into monthly payments, with the payments still to come.
struct InstallmentPlan: Identifiable {
    let id: String
    let merchant: String
    let purchaseDate: Date
    let total: Double
    let count: Int
    let payments: [InstallmentPayment]
    /// Not linked to a fixed expense / tracked purchase and not hidden — counts as variable spending.
    let countsAsVariable: Bool

    var lastCharge: Date? { payments.last?.chargeDate }
    var isActive: Bool { (lastCharge ?? .distantPast) >= Calendar.current.startOfDay(for: Date()) }
    var charged: Double { payments.filter { $0.chargeDate <= Date() }.reduce(0) { $0 + $1.amount } }
    var remaining: Double { max(0, total - charged) }
    var next: InstallmentPayment? { payments.first { $0.chargeDate > Date() } }
}

extension MoneyData {
    var installmentPlans: [InstallmentPlan] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: cardTransactions.filter { $0.installment != nil }, by: { $0.installmentPlanKey })
        return groups.compactMap { key, txs -> InstallmentPlan? in
            let known = txs.sorted { ($0.installment?.number ?? 0) < ($1.installment?.number ?? 0) }
            guard let first = known.first, let info = first.installment else { return nil }
            var payments: [InstallmentPayment] = known.compactMap { t in
                guard let n = t.installment?.number, let d = t.chargeDate else { return nil }
                return InstallmentPayment(number: n, chargeDate: d, amount: t.amount, imported: true)
            }
            // Payments not in any imported statement yet: one a month after the last known one.
            if let last = payments.last, last.number < info.of {
                let paid = payments.reduce(0) { $0 + $1.amount }
                let left = info.of - last.number
                for k in 1...left {
                    let isLast = k == left
                    let amount = isLast ? max(0, first.originalAmount - paid - last.amount * Double(left - 1)) : last.amount
                    guard let d = cal.date(byAdding: .month, value: k, to: last.chargeDate) else { continue }
                    payments.append(InstallmentPayment(number: last.number + k, chargeDate: d,
                                                       amount: amount > 0 ? amount : last.amount, imported: false))
                }
            }
            let reference = known.last ?? first
            return InstallmentPlan(
                id: key, merchant: first.merchant, purchaseDate: first.date,
                total: first.originalAmount != 0 ? first.originalAmount : payments.reduce(0) { $0 + $1.amount },
                count: info.of, payments: payments, countsAsVariable: reference.isVariable
            )
        }
        .sorted { $0.purchaseDate > $1.purchaseDate }
    }

    /// Expected installment payments (not yet in an imported statement) charged between two dates.
    func projectedInstallments(from: Date, to: Date) -> Double {
        installmentPlans.filter { $0.countsAsVariable }.reduce(0) { sum, plan in
            sum + plan.payments.filter { !$0.imported && $0.chargeDate > from && $0.chargeDate <= to }.reduce(0) { $0 + $1.amount }
        }
    }
}

// MARK: - Purchases recorded by hand as "paid by card"

/// One expected card charge of a purchase you recorded yourself (not in an imported statement yet).
struct ManualCardPayment: Identifiable {
    let transaction: MoneyTransaction
    let number: Int
    let of: Int
    let amount: Double
    let chargeDate: Date
    var id: String { transaction.id.uuidString + "#\(number)" }
    var title: String { transaction.title + (of > 1 ? " (תשלום \(number)/\(of))" : "") }

    var billingKey: Int {
        let cal = Calendar.current
        return cal.component(.year, from: chargeDate) * 100 + cal.component(.month, from: chargeDate)
    }
}

extension MoneyData {
    /// The card charge that is this hand-recorded purchase (same price, a few days apart), if it was imported.
    func cardMatch(for t: MoneyTransaction) -> CardTransaction? {
        guard t.kind == .expense, t.amount > 0 else { return nil }
        let candidates = cardTransactions.filter { c in
            guard !c.ignored, c.amount > 0 else { return false }
            let price = c.originalAmount != 0 ? abs(c.originalAmount) : c.amount
            return abs(price - t.amount) < 1 && abs(c.date.timeIntervalSince(t.date)) <= 4 * 86_400
        }
        return candidates.min { a, b in
            let da = abs(a.date.timeIntervalSince(t.date)), db = abs(b.date.timeIntervalSince(t.date))
            if da != db { return da < db }
            return (a.installment?.number ?? 1) < (b.installment?.number ?? 1)
        }
    }

    /// Hand-recorded card purchases the card statements don't show yet.
    var unmatchedCardPurchases: [MoneyTransaction] {
        transactions.filter { $0.isCardPurchase && $0.amount > 0 && cardMatch(for: $0) == nil }
    }

    /// Their expected charges: the first on the next charge day after the purchase month, then one a month.
    var manualCardPayments: [ManualCardPayment] {
        let cal = Calendar.current
        let day = usualChargeDay ?? 2
        return unmatchedCardPurchases.flatMap { t -> [ManualCardPayment] in
            let n = max(1, t.cardInstallments)
            let each = (t.amount / Double(n) * 100).rounded() / 100
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: t.date)) ?? t.date
            return (0..<n).compactMap { i -> ManualCardPayment? in
                guard let month = cal.date(byAdding: .month, value: i + 1, to: monthStart) else { return nil }
                var comps = cal.dateComponents([.year, .month], from: month)
                comps.day = min(day, 28)
                guard let charge = cal.date(from: comps) else { return nil }
                let amount = i == n - 1 ? t.amount - each * Double(n - 1) : each
                return ManualCardPayment(transaction: t, number: i + 1, of: n, amount: amount, chargeDate: charge)
            }
        }
    }

    /// An expense recorded from the bank account that looks like a card purchase already in the statements.
    func looksLikeCardPurchase(_ t: MoneyTransaction) -> CardTransaction? {
        guard t.kind == .expense, !t.paidByCard, t.salaryKey == nil else { return nil }
        return cardMatch(for: t)
    }
}

import Foundation
import PDFKit

/// What a payslip PDF says, as far as the app can tell from its text.
struct PayslipReading: Equatable {
    var year: Int?
    var month: Int?
    /// Total payments ("סה״כ תשלומים").
    var gross: Double?
    /// Mandatory deductions and pension ("ניכויי חובה וגמל").
    var deductions: Double?
    /// Net pay before voluntary deductions ("שכר נטו").
    var net: Double?
    /// What reaches the bank ("נטו לתשלום").
    var netToPay: Double?
    var incomeTax: Double?
    var nationalInsurance: Double?
    var health: Double?

    var isUseful: Bool { netToPay != nil }
}

enum PayslipError: LocalizedError {
    case unreadable, needsPassword, wrongPassword, noText, notFound

    var errorDescription: String? {
        switch self {
        case .unreadable: return "לא ניתן לפתוח את הקובץ כ-PDF."
        case .needsPassword: return "התלוש נעול בסיסמה."
        case .wrongPassword: return "הסיסמה לא נכונה."
        case .noText: return "בקובץ אין טקסט (כנראה סריקה כתמונה), אז אי אפשר לקרוא ממנו את הסכומים."
        case .notFound: return "לא הצלחתי למצוא בתלוש את הנטו. אפשר להקליד אותו ידנית."
        }
    }
}

enum PayslipReader {
    /// Opens the PDF (with the password when it's locked) and reads it.
    static func read(url: URL, password: String?) throws -> PayslipReading {
        guard let doc = PDFDocument(url: url) else { throw PayslipError.unreadable }
        if doc.isLocked {
            guard let password, !password.isEmpty else { throw PayslipError.needsPassword }
            guard doc.unlock(withPassword: password) else { throw PayslipError.wrongPassword }
        }
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        guard text.contains(where: \.isNumber) else { throw PayslipError.noText }
        let reading = parse(text)
        guard reading.isUseful else { throw PayslipError.notFound }
        return reading
    }

    static func isLocked(url: URL) -> Bool { PDFDocument(url: url)?.isLocked ?? false }

    /// Reads the payslip's text. Payroll programs lay their tables out differently, so instead of relying on
    /// positions the totals are found by their arithmetic: payments − deductions = net (− voluntary = net to pay).
    static func parse(_ raw: String) -> PayslipReading {
        // Some payroll fonts map "נ" to "ð" (or drop it) in the text layer.
        let text = raw.replacingOccurrences(of: "ð", with: "נ")
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var r = PayslipReading()

        // The month: "8/26" or "08/2026" on a line of its own, or after "לחודש".
        for line in lines.prefix(40) {
            let candidate = line.replacingOccurrences(of: "לחודש", with: "").trimmingCharacters(in: .whitespaces)
            if let (m, y) = monthYear(candidate) { r.month = m; r.year = y; break }
        }

        // Amounts in reading order ("2,750.00").
        let amounts: [Double] = lines.compactMap(amount)

        // gross − deductions = net: three amounts next to each other, the biggest such chain.
        var best: (Int, Double, Double, Double)?
        for i in 0..<max(0, amounts.count - 2) {
            let a = amounts[i], b = amounts[i + 1], c = amounts[i + 2]
            guard a > 0, b > 0, c > 0, b < a, abs(a - b - c) < 0.02 else { continue }
            if best == nil || a > best!.1 { best = (i, a, b, c) }
        }
        if let (i, gross, deductions, net) = best {
            r.gross = gross
            r.deductions = deductions
            r.net = net
            r.netToPay = net
            // What follows: the net again (nothing voluntary), or voluntary deductions and the net to pay.
            let rest = Array(amounts.dropFirst(i + 3).prefix(2))
            if rest.count == 2, rest[0] > 0, rest[1] > 0, abs(net - rest[0] - rest[1]) < 0.02 {
                r.netToPay = rest[1]
            }
        } else {
            // No chain: the amount right after the "net to pay" label.
            r.netToPay = amountAfter(label: "טו לתשלום", in: lines)
            r.gross = amountAfter(label: "תשלומים", in: lines)
        }

        // Mandatory deductions: the amounts that sum to the total, matched to their labels in order.
        if let total = r.deductions {
            let labels = ["מס הכנסה", "ביטוח לאומי", "בריאות"]
            for (label, value) in deductionParts(lines: lines, labels: labels, total: total) {
                switch label {
                case "מס הכנסה": r.incomeTax = value
                case "ביטוח לאומי": r.nationalInsurance = value
                default: r.health = value
                }
            }
        }
        return r
    }

    // MARK: Helpers

    static func amount(_ line: String) -> Double? {
        let s = line.replacingOccurrences(of: "₪", with: "").trimmingCharacters(in: .whitespaces)
        guard s.range(of: #"^-?\d{1,3}(,\d{3})*\.\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return Double(s.replacingOccurrences(of: ",", with: ""))
    }

    static func monthYear(_ s: String) -> (Int, Int)? {
        guard let m = s.range(of: #"^(\d{1,2})/(\d{2}|\d{4})$"#, options: .regularExpression) else { return nil }
        let parts = s[m].split(separator: "/")
        guard let month = Int(parts[0]), var year = Int(parts[1]), (1...12).contains(month) else { return nil }
        if year < 100 { year += 2000 }
        guard (2000...2100).contains(year) else { return nil }
        return (month, year)
    }

    private static func amountAfter(label: String, in lines: [String]) -> Double? {
        guard let i = lines.firstIndex(where: { $0.contains(label) }) else { return nil }
        return lines.dropFirst(i + 1).prefix(4).compactMap(amount).first
    }

    /// In a block where amounts come before (or after) their labels, the ones that add up to `total` belong to the
    /// deduction labels that appear in that block, in the same order.
    private static func deductionParts(lines: [String], labels: [String], total: Double) -> [(String, Double)] {
        for (i, line) in lines.enumerated() where line.contains("ביטוח לאומי") {
            // The labels of this block, in order.
            var found: [String] = []
            var j = i
            while j > 0, amount(lines[j - 1]) == nil { j -= 1 }
            var k = j
            while k < lines.count, amount(lines[k]) == nil {
                if let l = labels.first(where: { lines[k].contains($0) && !lines[k].contains("%") }) { found.append(l) }
                k += 1
            }
            // The amounts right before the labels (a "%" label takes its rate first).
            var values: [Double] = []
            var v = j - 1
            while v >= 0, let a = amount(lines[v]) ?? (Int(lines[v]).map(Double.init)) { values.insert(a, at: 0); v -= 1 }
            let hasRate = lines[j..<k].contains { $0.contains("%") }
            if hasRate, !values.isEmpty, lines[v + 1].range(of: #"^\d+$"#, options: .regularExpression) != nil { values.removeFirst() }
            let money = values.suffix(found.count)
            if found.count == money.count, abs(money.reduce(0, +) - total) < 0.02 {
                return Array(zip(found, money))
            }
            // Pension may be part of the total too — accept when the parts don't exceed it.
            if found.count == money.count, money.reduce(0, +) <= total + 0.02 {
                return Array(zip(found, money))
            }
        }
        return []
    }
}

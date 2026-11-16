import Foundation

// MARK: - Which trend the new card charges belong to (after an import)

/// New card charges of one merchant that aren't in any trend yet, with the trend the app would put them in.
struct TrendSuggestionItem: Identifiable, Equatable {
    let merchantKey: String
    let merchant: String
    var category: String
    var cardIDs: [String]
    var total: Double
    /// The suggested trend (nil: none found).
    var trendID: UUID? = nil
    /// Why: "history" (this merchant was put in the trend before), "category" (the bank's category is the trend's
    /// name), "name" (the merchant's name has the trend's name in it), "ai", or "" when there's no suggestion.
    var reason: String = ""

    var id: String { merchantKey }

    var reasonText: String {
        switch reason {
        case "history": return "בית העסק הזה כבר שויך למגמה הזו"
        case "category": return "לפי הקטגוריה בפירוט"
        case "name": return "לפי שם בית העסק"
        case "ai": return "הצעה של ה-AI"
        default: return ""
        }
    }
}

/// The same logic as `TrendSuggestions` in flutter_app/lib/data/trend_suggestions.dart. Nothing is assigned without
/// the user, except by a rule the user set ("תמיד לבית העסק הזה").
enum TrendSuggestions {
    static func normalized(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(String.init).joined()
    }

    static let aiSystem = "אתה מסווג עסקאות אשראי למגמות — קבוצות הוצאה שהמשתמש הגדיר. ענה אך ורק ב-JSON תקין, בלי שום טקסט נוסף: "
        + "אובייקט שהמפתחות בו הם המספרים של בתי העסק, והערך של כל אחד הוא שם המגמה בדיוק כפי שהוא ברשימה, או null כשאף מגמה לא מתאימה. "
        + "אל תנחש: כשלא ברור — null."
}

extension MoneyData {
    /// The new charges that can go into a trend: purchases that count as spending and aren't in a trend yet.
    private func trendCandidates(_ newIDs: Set<String>) -> [CardTransaction] {
        let inTrends = Set(trends.flatMap(\.cardIDs))
        return cardTransactions.filter { newIDs.contains($0.id) && $0.isVariable && $0.myAmount > 0 && !inTrends.contains($0.id) }
    }

    /// Puts the new charges of merchants with an "always" rule in their trend. Returns how many were assigned.
    @discardableResult
    mutating func applyTrendRules(_ newIDs: Set<String>) -> Int {
        guard !trends.isEmpty, !merchantTrends.isEmpty else { return 0 }
        var assigned = 0
        for t in trendCandidates(newIDs) {
            guard let rule = merchantTrends[t.merchantKey],
                  let i = trends.firstIndex(where: { $0.id.uuidString == rule }) else { continue }
            trends[i].cardIDs.append(t.id)
            assigned += 1
        }
        return assigned
    }

    /// The new charges that aren't in a trend, merchant by merchant, each with a suggestion when there is one: first
    /// by a trend this merchant was put in before, then by the bank's category or the merchant's name against the
    /// trends' names. Empty when there are no trends. Those with a suggestion come first, then the bigger amounts.
    func trendSuggestions(_ newIDs: Set<String>) -> [TrendSuggestionItem] {
        guard !trends.isEmpty else { return [] }
        let keyOf = Dictionary(cardTransactions.map { ($0.id, $0.merchantKey) }, uniquingKeysWith: { a, _ in a })
        var items: [TrendSuggestionItem] = []
        for t in trendCandidates(newIDs) {
            if let i = items.firstIndex(where: { $0.merchantKey == t.merchantKey }) {
                items[i].cardIDs.append(t.id)
                items[i].total += t.myAmount
                if items[i].category.isEmpty { items[i].category = t.category }
            } else {
                items.append(TrendSuggestionItem(merchantKey: t.merchantKey, merchant: t.merchant, category: t.category,
                                                 cardIDs: [t.id], total: t.myAmount))
            }
        }
        let n = TrendSuggestions.normalized
        for i in items.indices {
            // 1. A trend that already has charges of this merchant (the one with the most of them).
            var best = 0
            for trend in trends {
                let count = trend.cardIDs.filter { keyOf[$0] == items[i].merchantKey }.count
                if count > best {
                    best = count
                    items[i].trendID = trend.id
                    items[i].reason = "history"
                }
            }
            if items[i].trendID != nil { continue }
            // 2. The bank's category against the trends' names, then the merchant's name.
            let category = n(items[i].category), merchant = n(items[i].merchant)
            if let trend = trends.first(where: { t in
                let name = n(t.name)
                return name.count >= 2 && !category.isEmpty && (category.contains(name) || name.contains(category))
            }) {
                items[i].trendID = trend.id
                items[i].reason = "category"
            } else if let trend = trends.first(where: { n($0.name).count >= 3 && merchant.contains(n($0.name)) }) {
                items[i].trendID = trend.id
                items[i].reason = "name"
            }
        }
        return items.sorted { a, b in
            if (a.trendID == nil) != (b.trendID == nil) { return a.trendID != nil }
            if abs(a.total - b.total) > 0.005 { return a.total > b.total }
            return a.merchantKey < b.merchantKey
        }
    }

    /// Assigns a merchant's new charges to a trend; `always` also remembers it for the next statements.
    mutating func assign(_ item: TrendSuggestionItem, to trendID: UUID, always: Bool = false) {
        guard let i = trends.firstIndex(where: { $0.id == trendID }) else { return }
        for id in item.cardIDs where !trends[i].cardIDs.contains(id) { trends[i].cardIDs.append(id) }
        if always { merchantTrends[item.merchantKey] = trendID.uuidString }
    }

    /// The merchants without a suggestion, numbered, and the trends' names — one request to the model.
    func trendAIPrompt(_ items: [TrendSuggestionItem]) -> String {
        let open = items.filter { $0.trendID == nil }
        var lines = ["המגמות:"] + trends.map { "- " + $0.name } + ["", "בתי העסק:"]
        for (i, item) in open.enumerated() {
            lines.append("\(i + 1). \(item.merchant)" + (item.category.isEmpty ? "" : " (קטגוריה: \(item.category))"))
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the model's answer into the items it was asked about. Returns how many got a suggestion.
    @discardableResult
    func applyTrendAIAnswer(_ raw: String, to items: inout [TrendSuggestionItem]) -> Int {
        guard let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"), first < last,
              let data = String(raw[first...last]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        let open = items.indices.filter { items[$0].trendID == nil }
        let n = TrendSuggestions.normalized
        var placed = 0
        for (key, value) in object {
            guard let index = Int(key.trimmingCharacters(in: .whitespaces)), index >= 1, index <= open.count,
                  let name = value as? String, !n(name).isEmpty,
                  let trend = trends.first(where: { n($0.name) == n(name) }),
                  items[open[index - 1]].trendID == nil else { continue }
            items[open[index - 1]].trendID = trend.id
            items[open[index - 1]].reason = "ai"
            placed += 1
        }
        return placed
    }
}

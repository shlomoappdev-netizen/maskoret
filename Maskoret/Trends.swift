import Foundation

// MARK: - Model

/// A cash / off-card amount added straight to a trend.
struct TrendEntry: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var amount: Double = 0
    var note: String = ""

    private enum CodingKeys: String, CodingKey { case id, date, amount, note }
}

extension TrendEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// A user-defined group of spending (e.g. "דייטים") that cuts across card categories.
struct Trend: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var emoji: String = "🏷️"
    /// Card charges in this trend.
    var cardIDs: [String] = []
    /// Only part of a charge belongs to the trend (charge id → amount).
    var shares: [String: Double] = [:]
    /// Expenses from "תנועות".
    var transactionIDs: [UUID] = []
    /// Cash and other amounts that aren't anywhere else.
    var entries: [TrendEntry] = []
    /// Optional monthly limit (0 = none).
    var monthlyLimit: Double = 0
    var createdAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case id, name, emoji, cardIDs, shares, transactionIDs, entries, monthlyLimit, createdAt
    }
}

extension Trend {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🏷️"
        cardIDs = try c.decodeIfPresent([String].self, forKey: .cardIDs) ?? []
        shares = try c.decodeIfPresent([String: Double].self, forKey: .shares) ?? [:]
        transactionIDs = try c.decodeIfPresent([UUID].self, forKey: .transactionIDs) ?? []
        entries = try c.decodeIfPresent([TrendEntry].self, forKey: .entries) ?? []
        monthlyLimit = try c.decodeIfPresent(Double.self, forKey: .monthlyLimit) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// One line in a trend, whatever its source.
struct TrendItem: Identifiable {
    enum Source { case card(String), transaction(UUID), manual(UUID) }

    let id: String
    let source: Source
    let date: Date
    let title: String
    let detail: String
    let amount: Double
    /// Full charge amount when only part of it is counted.
    let fullAmount: Double?

    var monthKey: Int {
        let cal = Calendar.current
        return cal.component(.year, from: date) * 100 + cal.component(.month, from: date)
    }
}

struct TrendMonth: Identifiable {
    let key: Int
    let amount: Double
    var id: Int { key }
}

struct TrendStats {
    var total: Double = 0
    var count: Int = 0
    var thisMonth: Double = 0
    var lastMonth: Double = 0
    var monthlyAverage: Double = 0
    /// Last 6 months, oldest first.
    var months: [TrendMonth] = []
}

// MARK: - Calculations

extension MoneyData {
    /// Everything in a trend, newest first. Months are by purchase date (when the money was spent).
    func items(of trend: Trend) -> [TrendItem] {
        var result: [TrendItem] = []
        let cards = Dictionary(cardTransactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in trend.cardIDs {
            guard let t = cards[id] else { continue }
            let share = trend.shares[id]
            result.append(TrendItem(
                id: "c:" + id, source: .card(id), date: t.date, title: t.merchant,
                detail: "אשראי" + (t.cardLast4.isEmpty ? "" : " " + t.cardLast4) + (t.note.isEmpty ? "" : " · " + t.note),
                amount: share ?? t.amount, fullAmount: share == nil ? nil : t.amount
            ))
        }
        for id in trend.transactionIDs {
            guard let t = transactions.first(where: { $0.id == id }) else { continue }
            let sign: Double = t.kind == .income ? -1 : 1
            result.append(TrendItem(
                id: "t:" + id.uuidString, source: .transaction(id), date: t.date, title: t.title,
                detail: "תנועה", amount: sign * t.amount, fullAmount: nil
            ))
        }
        for e in trend.entries {
            result.append(TrendItem(
                id: "m:" + e.id.uuidString, source: .manual(e.id), date: e.date,
                title: e.note.isEmpty ? "הוצאה ידנית" : e.note, detail: "ידני / מזומן",
                amount: e.amount, fullAmount: nil
            ))
        }
        return result.sorted { $0.date > $1.date }
    }

    func stats(of trend: Trend, now: Date = Date()) -> TrendStats {
        let items = items(of: trend)
        let cal = Calendar.current
        func key(_ d: Date) -> Int { cal.component(.year, from: d) * 100 + cal.component(.month, from: d) }
        var byMonth: [Int: Double] = [:]
        for i in items { byMonth[i.monthKey, default: 0] += i.amount }

        var s = TrendStats()
        s.total = items.reduce(0) { $0 + $1.amount }
        s.count = items.count
        s.thisMonth = byMonth[key(now)] ?? 0
        if let prev = cal.date(byAdding: .month, value: -1, to: now) { s.lastMonth = byMonth[key(prev)] ?? 0 }
        s.months = (0..<6).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .month, value: -back, to: now) else { return nil }
            return TrendMonth(key: key(d), amount: byMonth[key(d)] ?? 0)
        }
        // Average over the months since the first item (at least 1).
        if let first = items.map({ $0.date }).min() {
            let months = (cal.dateComponents([.month], from: cal.startOfDay(for: first), to: now).month ?? 0) + 1
            s.monthlyAverage = s.total / Double(max(months, 1))
        }
        return s
    }

    func trends(containing cardID: String) -> [Trend] {
        trends.filter { $0.cardIDs.contains(cardID) }
    }
}

// MARK: - Store actions

extension Store {
    func upsertTrend(_ trend: Trend) {
        if let i = money.trends.firstIndex(where: { $0.id == trend.id }) {
            money.trends[i] = trend
        } else {
            money.trends.append(trend)
        }
    }

    func deleteTrend(_ id: UUID) {
        money.trends.removeAll { $0.id == id }
    }

    /// Adds / removes a card charge from a trend.
    func toggleCard(_ cardID: String, in trendID: UUID) {
        guard let i = money.trends.firstIndex(where: { $0.id == trendID }) else { return }
        if let j = money.trends[i].cardIDs.firstIndex(of: cardID) {
            money.trends[i].cardIDs.remove(at: j)
            money.trends[i].shares[cardID] = nil
        } else {
            money.trends[i].cardIDs.append(cardID)
        }
    }

    func toggleTransaction(_ id: UUID, in trendID: UUID) {
        guard let i = money.trends.firstIndex(where: { $0.id == trendID }) else { return }
        if let j = money.trends[i].transactionIDs.firstIndex(of: id) {
            money.trends[i].transactionIDs.remove(at: j)
        } else {
            money.trends[i].transactionIDs.append(id)
        }
    }

    /// Count only `amount` of a card charge in the trend (nil = the whole charge).
    func setShare(_ amount: Double?, card cardID: String, in trendID: UUID) {
        guard let i = money.trends.firstIndex(where: { $0.id == trendID }) else { return }
        money.trends[i].shares[cardID] = amount
    }

    func removeItem(_ item: TrendItem, from trendID: UUID) {
        guard let i = money.trends.firstIndex(where: { $0.id == trendID }) else { return }
        switch item.source {
        case .card(let id):
            money.trends[i].cardIDs.removeAll { $0 == id }
            money.trends[i].shares[id] = nil
        case .transaction(let id):
            money.trends[i].transactionIDs.removeAll { $0 == id }
        case .manual(let id):
            money.trends[i].entries.removeAll { $0.id == id }
        }
    }

    func addEntry(_ entry: TrendEntry, to trendID: UUID) {
        guard let i = money.trends.firstIndex(where: { $0.id == trendID }) else { return }
        money.trends[i].entries.append(entry)
    }
}

import Foundation

// MARK: - Model

/// Money that came back (Bit, cash…) recorded by hand.
struct ReturnEntry: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var date = Date()
    var amount: Double = 0
    var note: String = ""
}

/// Something you paid for someone else, and what they returned so far.
/// What you paid is not counted as your spending; what comes back is not counted as income.
struct Receivable: Identifiable, Codable, Equatable {
    var id = UUID()
    var person: String = ""
    var note: String = ""
    var createdAt = Date()
    /// Card charge id → the part of it the person owes.
    var cardShares: [String: Double] = [:]
    /// Expense transaction id (uuidString) → the part owed.
    var transactionShares: [String: Double] = [:]
    /// Paid in cash / not recorded anywhere else.
    var manualAmount: Double = 0
    /// Income transactions ("תנועות") that are this person paying back — e.g. a Bit transfer.
    var incomeIDs: [UUID] = []
    /// Refunds on the card (negative charges) that settle it.
    var cardCreditIDs: [String] = []
    var returns: [ReturnEntry] = []
    /// "ויתרתי" — from now on it's your own expense.
    var forgiven = false

    private enum CodingKeys: String, CodingKey {
        case id, person, note, createdAt, cardShares, transactionShares, manualAmount, incomeIDs, cardCreditIDs, returns, forgiven
    }

    init(person: String = "", note: String = "") {
        self.person = person
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        person = (try? c.decodeIfPresent(String.self, forKey: .person)) ?? ""
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        cardShares = (try? c.decodeIfPresent([String: Double].self, forKey: .cardShares)) ?? [:]
        transactionShares = (try? c.decodeIfPresent([String: Double].self, forKey: .transactionShares)) ?? [:]
        manualAmount = (try? c.decodeIfPresent(Double.self, forKey: .manualAmount)) ?? 0
        incomeIDs = (try? c.decodeIfPresent([UUID].self, forKey: .incomeIDs)) ?? []
        cardCreditIDs = (try? c.decodeIfPresent([String].self, forKey: .cardCreditIDs)) ?? []
        returns = (try? c.decodeIfPresent([ReturnEntry].self, forKey: .returns)) ?? []
        forgiven = (try? c.decodeIfPresent(Bool.self, forKey: .forgiven)) ?? false
    }

    var expected: Double { cardShares.values.reduce(0, +) + transactionShares.values.reduce(0, +) + manualAmount }
}

extension MoneyData {
    func returned(_ r: Receivable) -> Double {
        let incomes = transactions.filter { r.incomeIDs.contains($0.id) }.reduce(0) { $0 + $1.amount }
        let credits = cardTransactions.filter { r.cardCreditIDs.contains($0.id) }.reduce(0) { $0 + abs($1.amount) }
        return incomes + credits + r.returns.reduce(0) { $0 + $1.amount }
    }

    func outstanding(_ r: Receivable) -> Double {
        r.forgiven ? 0 : max(0, r.expected - returned(r))
    }

    var totalOwedToMe: Double { receivables.reduce(0) { $0 + outstanding($1) } }

    /// Income transactions that are someone paying you back — not real income.
    var reimbursementIncomeIDs: Set<UUID> { Set(receivables.flatMap(\.incomeIDs)) }

    /// The part of an expense transaction someone else owes you.
    func owedPortion(transaction id: UUID) -> Double {
        receivables.filter { !$0.forgiven }.reduce(0) { $0 + ($1.transactionShares[id.uuidString] ?? 0) }
    }

    /// Everyone you lent to, with what they still owe.
    var debtors: [Debtor] {
        let grouped = Dictionary(grouping: receivables, by: { $0.person.trimmingCharacters(in: .whitespaces) })
        return grouped.map { Debtor(person: $0.key, amount: $0.value.reduce(0) { $0 + outstanding($1) }) }
            .sorted { $0.amount > $1.amount }
    }
}

struct Debtor: Identifiable {
    let person: String
    let amount: Double
    var id: String { person }
}

// MARK: - Store actions

extension Store {
    /// Keeps `owedPortion` on card charges in sync (so the owed part isn't counted as your spending).
    func syncOwedPortions(_ m: inout MoneyData) {
        var portions: [String: Double] = [:]
        for r in m.receivables where !r.forgiven {
            for (id, share) in r.cardShares { portions[id, default: 0] += share }
        }
        for i in m.cardTransactions.indices {
            let p = min(max(0, portions[m.cardTransactions[i].id] ?? 0), max(0, m.cardTransactions[i].amount))
            if m.cardTransactions[i].owedPortion != p { m.cardTransactions[i].owedPortion = p }
        }
    }

    func upsertReceivable(_ r: Receivable) {
        var m = money
        if let i = m.receivables.firstIndex(where: { $0.id == r.id }) {
            m.receivables[i] = r
        } else {
            m.receivables.append(r)
        }
        syncOwedPortions(&m)
        money = m
    }

    func deleteReceivable(_ id: UUID) {
        var m = money
        m.receivables.removeAll { $0.id == id }
        syncOwedPortions(&m)
        money = m
    }

    /// Adds a card charge to the open debt of `person` (or a new one).
    func addCardToReceivable(_ tx: CardTransaction, person: String, amount: Double, note: String) {
        let name = person.trimmingCharacters(in: .whitespaces)
        var r = money.receivables.first { $0.person == name && !$0.forgiven && money.outstanding($0) > 0 }
            ?? Receivable(person: name, note: note)
        r.cardShares[tx.id] = amount
        if r.note.isEmpty { r.note = note }
        upsertReceivable(r)
    }

    func removeCardFromReceivables(_ txID: String) {
        var m = money
        for i in m.receivables.indices {
            m.receivables[i].cardShares[txID] = nil
            m.receivables[i].cardCreditIDs.removeAll { $0 == txID }
        }
        m.receivables.removeAll { $0.expected == 0 && $0.returns.isEmpty && $0.incomeIDs.isEmpty }
        syncOwedPortions(&m)
        money = m
    }

    /// Records money that came back; optionally also as an income into the checking account.
    func addReturn(_ entry: ReturnEntry, to receivableID: UUID, alsoToChecking: Bool) {
        var m = money
        guard let i = m.receivables.firstIndex(where: { $0.id == receivableID }) else { return }
        if alsoToChecking, let checking = m.checking {
            let t = MoneyTransaction(date: entry.date, title: "החזר מ" + m.receivables[i].person + (entry.note.isEmpty ? "" : " — " + entry.note),
                                     amount: entry.amount, kind: .income, accountID: checking.id)
            m.transactions.append(t)
            m.receivables[i].incomeIDs.append(t.id)
        } else {
            m.receivables[i].returns.append(entry)
        }
        money = m
    }

    /// The debt an income transaction pays back, if it's linked to one.
    func receivable(forIncome id: UUID) -> Receivable? {
        money.receivables.first { $0.incomeIDs.contains(id) }
    }

    /// Debts you can link an income to: still open, or the one it's already linked to.
    func openReceivables(including id: UUID? = nil) -> [Receivable] {
        money.receivables.filter { r in
            (!r.forgiven && money.outstanding(r) > 0.005) || (id.map { r.incomeIDs.contains($0) } ?? false)
        }
        .sorted { $0.person < $1.person }
    }

    /// Links an income transaction as a payment on a debt (nil = a regular income again).
    func linkIncome(_ txID: UUID, to receivableID: UUID?) {
        var m = money
        for i in m.receivables.indices { m.receivables[i].incomeIDs.removeAll { $0 == txID } }
        if let receivableID, let i = m.receivables.firstIndex(where: { $0.id == receivableID }) {
            m.receivables[i].incomeIDs.append(txID)
        }
        money = m
    }

    /// Someone paid back a debt that wasn't recorded yet: records it (as paid in cash) and links the income.
    func linkIncomeToNewDebt(_ t: MoneyTransaction, person: String, note: String) {
        var r = Receivable(person: person.trimmingCharacters(in: .whitespaces), note: note)
        r.manualAmount = t.amount
        var m = money
        for i in m.receivables.indices { m.receivables[i].incomeIDs.removeAll { $0 == t.id } }
        r.incomeIDs = [t.id]
        m.receivables.append(r)
        syncOwedPortions(&m)
        money = m
    }

    var people: [String] {
        Array(Set(money.receivables.map(\.person).filter { !$0.isEmpty })).sorted()
    }
}

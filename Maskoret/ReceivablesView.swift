import SwiftUI

struct ReceivablesView: View {
    @EnvironmentObject private var store: Store
    @State private var open: Receivable?
    @State private var showClosed = false

    private var money: MoneyData { store.money }

    var body: some View {
        let active = money.receivables.filter { money.outstanding($0) > 0.005 }
        let settled = money.receivables.filter { money.outstanding($0) <= 0.005 }
        NavigationStack {
            VStack(spacing: 0) {
                PageBar(title: "חייבים לי", subtitle: "סה״כ פתוח: " + Fmt.money(money.totalOwedToMe)) {
                    Button {
                        open = Receivable()
                    } label: {
                        Label("חוב חדש", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Divider()
                if money.receivables.isEmpty {
                    ContentUnavailableView {
                        Label("אף אחד לא חייב לך", systemImage: "arrow.uturn.backward.circle")
                    } description: {
                        Text("קנית למישהו משהו והוא יחזיר לך? בעמוד ״כרטיס אשראי״ ← ״צמד ל…״ ← ״מישהו צריך להחזיר לי…״, או ״חוב חדש״ כאן.\nמה ששילמת בשביל אחרים לא נספר כהוצאה שלך, וההחזר (למשל בביט) לא נספר כהכנסה — ורואים בדיוק מי חייב כמה.")
                    } actions: {
                        Button("חוב חדש") { open = Receivable() }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            peopleCard
                            ForEach(active) { r in row(r) }
                            if !settled.isEmpty {
                                DisclosureGroup("הוחזרו / ויתרתי (\(settled.count))", isExpanded: $showClosed) {
                                    VStack(spacing: 10) { ForEach(settled) { r in row(r) } }
                                        .padding(.top, 8)
                                }
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Palette.window)
                }
            }
            .navigationTitle("חייבים לי")
            .sheet(item: $open) { r in
                ReceivableEditor(receivable: r).environmentObject(store)
            }
        }
    }

    private var peopleCard: some View {
        let list = money.debtors.filter { $0.amount > 0.005 }
        return Card {
            Text("מי חייב לי").font(.headline)
            if list.isEmpty {
                Text("כולם החזירו 🎉").foregroundStyle(.secondary)
            }
            ForEach(list) { d in
                BreakdownLine(title: d.person.isEmpty ? "ללא שם" : d.person, value: d.amount, color: .orange)
            }
        }
    }

    private func row(_ r: Receivable) -> some View {
        let out = money.outstanding(r)
        let back = money.returned(r)
        return Button {
            open = r
        } label: {
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: r.person.isEmpty ? "ללא שם" : r.person).font(.headline)
                        Text(verbatim: (r.note.isEmpty ? "" : r.note + " · ") + Fmt.date(r.createdAt)
                             + " · שילמתי " + Fmt.money(r.expected) + " · הוחזר " + Fmt.money(back))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if r.forgiven {
                        Text("ויתרתי").foregroundStyle(.secondary)
                    } else if out > 0.005 {
                        Text(verbatim: Fmt.money(out)).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.orange)
                    } else {
                        Label("הוחזר", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if r.expected > 0 && !r.forgiven {
                    ProgressView(value: min(back, r.expected), total: r.expected).tint(.green)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor

struct ReceivableEditor: View {
    @EnvironmentObject private var store: Store
    @State var receivable: Receivable
    @State private var returnAmount: Double = 0
    @State private var returnNote = "ביט"
    @State private var returnDate = Date()
    @State private var toChecking = true
    @State private var returnKey = UUID()

    private var money: MoneyData { store.money }

    /// The saved version (so links made inside the editor show up).
    private var live: Receivable { money.receivables.first { $0.id == receivable.id } ?? receivable }

    private var recentCharges: [CardTransaction] {
        let since = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        return money.cardTransactions.filter { $0.date >= since && $0.amount > 0 && !$0.ignored }.sorted { $0.date > $1.date }
    }

    private var recentExpenses: [MoneyTransaction] {
        let since = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        return money.transactions.filter { $0.kind == .expense && $0.date >= since }.sorted { $0.date > $1.date }
    }

    /// Income not yet used to pay back another debt.
    private var candidateIncomes: [MoneyTransaction] {
        let used = Set(money.receivables.filter { $0.id != receivable.id }.flatMap(\.incomeIDs))
        let since = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        return money.transactions.filter { $0.kind == .income && $0.salaryKey == nil && $0.date >= since && !used.contains($0.id) }
            .sorted { $0.date > $1.date }
    }

    private var candidateCredits: [CardTransaction] {
        money.cardTransactions.filter { $0.amount < 0 }.sorted { $0.date > $1.date }
    }

    var body: some View {
        SheetContainer(title: receivable.person.isEmpty ? "חוב חדש" : "חייב/ת לי: " + receivable.person, width: 640, minHeight: 700,
                       onSave: { store.upsertReceivable(merged()) }) {
            Section {
                FormTextField("מי", text: $receivable.person, prompt: Text("שם"))
                if !store.people.isEmpty {
                    Picker("או בחר", selection: $receivable.person) {
                        Text("—").tag(receivable.person)
                        ForEach(store.people, id: \.self) { Text($0).tag($0) }
                    }
                }
                FormTextField("על מה", text: $receivable.note, prompt: Text("למשל: כרטיסים להופעה"))
                AmountField(title: "שילמתי במזומן / בלי רישום", value: $receivable.manualAmount)
            }

            Section {
                ForEach(recentCharges) { tx in
                    shareRow(title: tx.merchant, subtitle: Fmt.date(tx.date) + " · אשראי", full: tx.amount,
                             binding: Binding(get: { receivable.cardShares[tx.id] }, set: { receivable.cardShares[tx.id] = $0 }))
                }
                ForEach(recentExpenses) { t in
                    shareRow(title: t.title, subtitle: Fmt.date(t.date) + " · תנועה", full: t.amount,
                             binding: Binding(get: { receivable.transactionShares[t.id.uuidString] },
                                              set: { receivable.transactionShares[t.id.uuidString] = $0 }))
                }
                if recentCharges.isEmpty && recentExpenses.isEmpty {
                    Text("אין חיובים או הוצאות מ-4 החודשים האחרונים").foregroundStyle(.secondary)
                }
            } header: {
                Text(verbatim: "מה שילמתי בשבילו — " + Fmt.money(receivable.expected))
            } footer: {
                Text("סמן את החיובים, ושנה את הסכום אם רק חלק מהקנייה שלו. החלק הזה לא נספר כהוצאה שלך.")
            }

            Section {
                ForEach(candidateIncomes) { t in
                    Toggle(isOn: Binding(
                        get: { receivable.incomeIDs.contains(t.id) },
                        set: { on in
                            receivable.incomeIDs.removeAll { $0 == t.id }
                            if on { receivable.incomeIDs.append(t.id) }
                        })) {
                        line(t.title, Fmt.date(t.date) + " · הכנסה", t.amount)
                    }
                    .checkboxToggle()
                }
                ForEach(candidateCredits) { tx in
                    Toggle(isOn: Binding(
                        get: { receivable.cardCreditIDs.contains(tx.id) },
                        set: { on in
                            receivable.cardCreditIDs.removeAll { $0 == tx.id }
                            if on { receivable.cardCreditIDs.append(tx.id) }
                        })) {
                        line(tx.merchant, Fmt.date(tx.date) + " · זיכוי באשראי", abs(tx.amount))
                    }
                    .checkboxToggle()
                }
                ForEach(receivable.returns) { e in
                    HStack {
                        line(e.note.isEmpty ? "החזר" : e.note, Fmt.date(e.date) + " · נרשם ידנית", e.amount)
                        Button(role: .destructive) {
                            receivable.returns.removeAll { $0.id == e.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    DatePicker("", selection: $returnDate, displayedComponents: .date).labelsHidden().fixedSize()
                    TextField("", text: $returnNote, prompt: Text("איך (ביט, מזומן…)")).labelsHidden()
                    AmountField(title: "", value: $returnAmount).id(returnKey).regularWidth(170, compact: 120)
                    Button("קיבלתי") { addReturn() }.disabled(returnAmount <= 0)
                }
                Toggle("להוסיף את ההחזר לעו״ש (כתנועה)", isOn: $toChecking)
            } header: {
                Text(verbatim: "מה הוחזר — " + Fmt.money(returnedNow) + " · נשאר " + Fmt.money(max(0, receivable.expected - returnedNow)))
            } footer: {
                Text("סמן הכנסה שכבר רשומה (למשל העברה בביט), זיכוי באשראי, או רשום החזר חדש. הכנסה שמסומנת כאן לא נספרת כהכנסה רגילה — גם לא במעשרות.")
            }

            Section {
                Toggle("ויתרתי — זו הוצאה שלי", isOn: $receivable.forgiven)
                if money.receivables.contains(where: { $0.id == receivable.id }) {
                    Button("מחיקת החוב", role: .destructive) { store.deleteReceivable(receivable.id) }
                }
            }
        }
    }

    private var returnedNow: Double { money.returned(receivable) }

    private func merged() -> Receivable {
        var r = receivable
        r.person = r.person.trimmingCharacters(in: .whitespaces)
        // Links/returns added through the store while the editor was open.
        let saved = live
        for id in saved.incomeIDs where !r.incomeIDs.contains(id) { r.incomeIDs.append(id) }
        return r
    }

    private func addReturn() {
        let entry = ReturnEntry(date: returnDate, amount: returnAmount, note: returnNote)
        if toChecking, let checking = money.checking {
            let t = MoneyTransaction(date: entry.date, title: "החזר מ" + (receivable.person.isEmpty ? "חבר" : receivable.person)
                                        + (entry.note.isEmpty ? "" : " — " + entry.note),
                                     amount: entry.amount, kind: .income, accountID: checking.id)
            store.upsertTransaction(t)
            receivable.incomeIDs.append(t.id)
        } else {
            receivable.returns.append(entry)
        }
        returnAmount = 0
        returnKey = UUID()
    }

    private func line(_ title: String, _ subtitle: String, _ amount: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: Fmt.money(amount)).monospacedDigit()
        }
    }

    private func shareRow(title: String, subtitle: String, full: Double, binding: Binding<Double?>) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { binding.wrappedValue != nil }, set: { binding.wrappedValue = $0 ? full : nil })) {
                line(title, subtitle, full)
            }
            .checkboxToggle()
            if binding.wrappedValue != nil {
                AmountField(title: "", value: Binding(get: { binding.wrappedValue ?? full }, set: { binding.wrappedValue = $0 }))
                    .regularWidth(150, compact: 110)
            }
        }
    }
}

// MARK: - Quick add from a card charge

struct OwedQuickSheet: View {
    @EnvironmentObject private var store: Store
    let tx: CardTransaction
    @State private var person = ""
    @State private var amount: Double = 0
    @State private var note = ""

    var body: some View {
        SheetContainer(title: "מישהו צריך להחזיר לי", saveTitle: "שמירה", minHeight: 360, onSave: {
            guard amount > 0 else { return }
            store.addCardToReceivable(tx, person: person.isEmpty ? "חבר" : person, amount: amount, note: note.isEmpty ? tx.merchant : note)
        }) {
            Section {
                Text(verbatim: tx.merchant + " · " + Fmt.date(tx.date) + " · " + Fmt.money(tx.amount))
                    .foregroundStyle(.secondary)
                FormTextField("מי", text: $person, prompt: Text("שם"))
                if !store.people.isEmpty {
                    Picker("או בחר", selection: $person) {
                        Text("—").tag(person)
                        ForEach(store.people, id: \.self) { Text($0).tag($0) }
                    }
                }
                AmountField(title: "כמה הוא צריך להחזיר", value: $amount)
                FormTextField("הערה", text: $note, prompt: Text(tx.merchant))
            } footer: {
                Text("אם יש לו כבר חוב פתוח — החיוב יתווסף אליו. את ההחזר (למשל ביט) מסמנים בעמוד ״חייבים לי״.")
            }
        }
        .onAppear { amount = tx.amount }
    }
}

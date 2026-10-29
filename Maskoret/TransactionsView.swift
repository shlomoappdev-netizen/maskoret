import SwiftUI

struct TransactionsView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: MoneyTransaction?
    @Environment(\.isCompactWidth) private var compact

    private var planned: [MoneyTransaction] {
        store.money.transactions.filter { $0.isPlanned }.sorted { $0.date < $1.date }
    }

    private var done: [MoneyTransaction] {
        store.money.transactions.filter { !$0.isPlanned }.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PageBar(title: "תנועות", subtitle: "הכנסות והוצאות גדולות, העברות בין חשבונות ותכנונים לעתיד") {
                    Menu {
                        Button("הוצאה גדולה…") { editing = newTransaction(.expense) }
                        Button("הכנסה (מענק, בונוס, מתנה)…") { editing = newTransaction(.income) }
                        Button("העברה בין חשבונות…") { editing = newTransaction(.transfer) }
                    } label: {
                        Label("תנועה חדשה", systemImage: "plus")
                    }
                    .fixedSize()
                }
                Divider()
                List {
                    if !planned.isEmpty {
                        Section {
                            ForEach(planned) { t in row(t) }
                        } header: {
                            Label("מתוכנן — נכנס לתחזית", systemImage: "calendar.badge.clock")
                        }
                    }
                    if !done.isEmpty {
                        ForEach(groupedDone, id: \.key) { group in
                            Section(group.title) {
                                ForEach(group.items) { t in row(t) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if store.money.transactions.isEmpty {
                        ContentUnavailableView {
                            Label("אין תנועות", systemImage: "arrow.left.arrow.right")
                        } description: {
                            Text("רשום כאן רק דברים גדולים או חריגים: קנייה גדולה, מענק, העברה לפיקדון. תנועה בתאריך עתידי היא תכנון — והיא נכנסת לתחזית. הוצאות קבועות כבר מחושבות לבד.")
                        } actions: {
                            Button("תנועה ראשונה") { editing = newTransaction(.expense) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle("תנועות")
            .sheet(item: $editing) { t in
                TransactionEditor(
                    transaction: t,
                    isNew: !store.money.transactions.contains { $0.id == t.id },
                    accounts: store.money.accounts
                ) { saved in
                    store.upsertTransaction(saved)
                }
                .environmentObject(store)
            }
        }
    }

    private struct MonthGroup {
        let key: Int
        let title: String
        let items: [MoneyTransaction]
    }

    private var groupedDone: [MonthGroup] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: done) { t in
            cal.component(.year, from: t.date) * 100 + cal.component(.month, from: t.date)
        }
        return groups.keys.sorted(by: >).map { key in
            MonthGroup(key: key, title: Fmt.monthTitle(year: key / 100, month: key % 100), items: groups[key] ?? [])
        }
    }

    private func newTransaction(_ kind: TransactionKind) -> MoneyTransaction {
        let checking = store.money.checking?.id
        let target = store.money.accounts.first { $0.kind != .checking }?.id
        return MoneyTransaction(kind: kind, accountID: checking, toAccountID: kind == .transfer ? target : nil)
    }

    private func row(_ t: MoneyTransaction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    editing = t
                } label: {
                    TransactionRow(transaction: t, money: store.money)
                }
                .buttonStyle(.plain)
                if t.kind == .income, t.salaryKey == nil, store.receivable(forIncome: t.id) == nil {
                    let open = store.openReceivables()
                    if !open.isEmpty {
                        Menu {
                            Section("זה תשלום על חוב של…") {
                                ForEach(open) { r in
                                    Button(r.person + " — נשאר " + Fmt.money(store.money.outstanding(r))) {
                                        store.linkIncome(t.id, to: r.id)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("שייך להחזר חוב")
                    }
                }
            }
            if let match = store.money.looksLikeCardPurchase(t) {
                AdaptiveStack(spacing: 8, wideAlignment: .center) {
                    Label("נראה שזה כבר בפירוט הכרטיס (\(match.merchant), \(Fmt.date(match.date))) — כרגע זה נספר פעמיים",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if !compact { Spacer() }
                    Button("שולם באשראי") {
                        var updated = t
                        updated.paidByCard = true
                        updated.cardInstallments = match.installment?.of ?? 1
                        store.upsertTransaction(updated)
                    }
                    .controlSize(.small)
                }
                .padding(.leading, compact ? 0 : 36)
            }
        }
        .rowMenu(onEdit: { editing = t }) {
            store.deleteTransaction(t)
        }
    }
}

struct TransactionRow: View {
    let transaction: MoneyTransaction
    let money: MoneyData

    private var accountsText: String {
        if transaction.isCardPurchase {
            var text = "💳 אשראי"
            if transaction.cardInstallments > 1 { text += " ב-\(transaction.cardInstallments) תשלומים" }
            if money.cardMatch(for: transaction) != nil {
                text += " · ✓ בפירוט הכרטיס"
            } else if let first = money.manualCardPayments.first(where: { $0.transaction.id == transaction.id }) {
                text += " · יחויב " + (transaction.cardInstallments > 1 ? "החל מ-" : "ב-") + Fmt.date(first.chargeDate)
            }
            return text
        }
        let from = money.account(transaction.accountID)?.name ?? "—"
        if transaction.kind == .income, let r = money.receivables.first(where: { $0.incomeIDs.contains(transaction.id) }) {
            return from + " · ↩︎ החזר חוב — " + (r.person.isEmpty ? "חבר" : r.person)
        }
        if transaction.kind == .transfer {
            return from + " ← " + (money.account(transaction.toAccountID)?.name ?? "—")
        }
        return from
    }

    private var amountText: String {
        switch transaction.kind {
        case .income: return "+" + Fmt.money(transaction.amount)
        case .expense: return "−" + Fmt.money(transaction.amount)
        case .transfer: return Fmt.money(transaction.amount)
        }
    }

    private var color: Color {
        switch transaction.kind {
        case .income: return .green
        case .expense: return .primary
        case .transfer: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.kind == .income ? "arrow.down.circle.fill"
                  : transaction.kind == .expense ? "arrow.up.circle.fill" : "arrow.left.arrow.right.circle.fill")
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.title)
                    .font(.body.weight(.medium))
                Text(verbatim: Fmt.date(transaction.date) + " · " + accountsText
                     + (transaction.note.isEmpty ? "" : " · " + transaction.note))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: amountText)
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct TransactionEditor: View {
    @EnvironmentObject private var store: Store
    @State private var transaction: MoneyTransaction
    /// "none", "new" or a debt's id.
    @State private var debtChoice = "none"
    @State private var newDebtPerson = ""
    @State private var newDebtNote = ""
    @State private var loadedDebt = false
    let isNew: Bool
    let accounts: [Account]
    let onSave: (MoneyTransaction) -> Void

    init(transaction: MoneyTransaction, isNew: Bool, accounts: [Account], onSave: @escaping (MoneyTransaction) -> Void) {
        _transaction = State(initialValue: transaction)
        self.isNew = isNew
        self.accounts = accounts
        self.onSave = onSave
    }

    var body: some View {
        SheetContainer(title: isNew ? "תנועה חדשה" : "עריכת תנועה", width: 480, onSave: save) {
            Section {
                Picker("סוג", selection: $transaction.kind) {
                    ForEach(TransactionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                FormTextField("תיאור", text: $transaction.title, prompt: Text(prompt))
                AmountField(title: transaction.isCardPurchase && transaction.cardInstallments > 1 ? "סכום העסקה המלא" : "סכום",
                            value: $transaction.amount)
                DatePicker(transaction.isCardPurchase ? "תאריך הקנייה" : "תאריך", selection: $transaction.date, displayedComponents: .date)
            } footer: {
                if transaction.isPlanned {
                    Label("תאריך עתידי — התנועה תיכנס לתחזית כתכנון.", systemImage: "calendar.badge.clock")
                }
            }

            if transaction.kind == .income && transaction.salaryKey == nil {
                Section {
                    Picker("החזר חוב", selection: $debtChoice) {
                        Text("לא — הכנסה רגילה").tag("none")
                        ForEach(store.openReceivables(including: transaction.id)) { r in
                            Text(verbatim: (r.person.isEmpty ? "חבר" : r.person) + (r.note.isEmpty ? "" : " (" + r.note + ")")
                                 + " — נשאר " + Fmt.money(store.money.outstanding(r)))
                                .tag(r.id.uuidString)
                        }
                        Text("חוב שלא רשמתי…").tag("new")
                    }
                    if debtChoice == "new" {
                        FormTextField("מי החזיר", text: $newDebtPerson, prompt: Text("שם"))
                        FormTextField("על מה", text: $newDebtNote, prompt: Text("לא חובה"))
                    }
                } footer: {
                    Text(debtChoice == "none"
                         ? "אם זה מישהו שמחזיר לך כסף ששילמת בשבילו — שייך לחוב, וזה לא ייספר כהכנסה (גם לא במעשרות)."
                         : "נרשם כתשלום על החוב ב״חייבים לי״ — לא נספר כהכנסה בסיכום ובמעשרות.")
                }
                .onAppear {
                    guard !loadedDebt else { return }
                    loadedDebt = true
                    if let r = store.receivable(forIncome: transaction.id) { debtChoice = r.id.uuidString }
                }
            }

            if transaction.kind == .expense {
                Section {
                    Toggle("שולם בכרטיס אשראי", isOn: $transaction.paidByCard)
                    if transaction.paidByCard {
                        Picker("תשלומים", selection: $transaction.cardInstallments) {
                            ForEach(1...36, id: \.self) { n in
                                Text(n == 1 ? "חיוב רגיל" : "\(n) תשלומים").tag(n)
                            }
                        }
                        if transaction.cardInstallments > 1 && transaction.amount > 0 {
                            Text(verbatim: "כ-\(Fmt.money((transaction.amount / Double(transaction.cardInstallments) * 100).rounded() / 100)) בחודש")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if transaction.paidByCard {
                        Text("לא יורד מהעו״ש עכשיו. עד שהקנייה מופיעה בפירוט הכרטיס שמייבאים, היא נספרת כחיוב צפוי בכרטיס (ובתשלומים — רק התשלום של כל חודש). כשהיא מופיעה בפירוט, נספר רק החיוב מהקובץ — בלי כפילות.")
                    } else {
                        Text("סמן אם שילמת בכרטיס — כדי שהקנייה לא תיספר פעמיים (פעם כאן ופעם בפירוט הכרטיס).")
                    }
                }
            }

            if !transaction.isCardPurchase {
            Section {
                Picker(accountLabel, selection: $transaction.accountID) {
                    ForEach(accounts) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
                if transaction.kind == .transfer {
                    Picker("לחשבון", selection: $transaction.toAccountID) {
                        ForEach(accounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    }
                }
            }
            }

            Section {
                FormTextField("הערה", text: $transaction.note, prompt: Text("לא חובה"))
            }
        }
    }

    private func save() {
        onSave(transaction)
        let isIncome = transaction.kind == .income && transaction.salaryKey == nil
        let current = store.receivable(forIncome: transaction.id)?.id
        if !isIncome || debtChoice == "none" {
            if current != nil { store.linkIncome(transaction.id, to: nil) }
        } else if debtChoice == "new" {
            let person = newDebtPerson.trimmingCharacters(in: .whitespaces)
            if !person.isEmpty {
                store.linkIncomeToNewDebt(transaction, person: person, note: newDebtNote)
            }
        } else if let id = UUID(uuidString: debtChoice), id != current {
            store.linkIncome(transaction.id, to: id)
        }
    }

    private var accountLabel: String {
        switch transaction.kind {
        case .transfer: return "מחשבון"
        case .income: return "נכנס לחשבון"
        case .expense: return "יוצא מחשבון"
        }
    }

    private var prompt: String {
        switch transaction.kind {
        case .income: return "למשל: מענק שחרור"
        case .expense: return "למשל: מחשב חדש"
        case .transfer: return "למשל: העברה לפיקדון"
        }
    }
}

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

    // Quick entry, like typing a line into the bank.
    @State private var quickKind: TransactionKind = .expense
    @State private var quickTitle = ""
    @State private var quickAmount = ""
    @State private var quickDate = Date()
    @State private var actualFor: LedgerLine?

    /// How far ahead the statement shows what's expected: the next pay day and card charge, or the last plan.
    private var horizon: Date {
        let ahead = Calendar.current.date(byAdding: .day, value: 35, to: Date()) ?? Date()
        return max(ahead, planned.last?.date ?? ahead)
    }

    private var statement: [LedgerLine] {
        store.money.checkingStatement(until: horizon, budget: store.budget, history: store.history)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.money.checking == nil || statement.isEmpty {
                    legacyList
                } else {
                    statementList
                }
            }
            .navigationTitle(SidebarItem.transactions.title)
            .sheet(item: $actualFor) { line in
                ActualChargeSheet(line: line).environmentObject(store)
            }
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

    // MARK: Quick entry

    private var quickValue: Double? {
        Double(quickAmount.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "₪", with: "")
            .trimmingCharacters(in: .whitespaces))
    }

    /// The title bar and the quick entry — the first row of the list, so they scroll away with it.
    private var header: some View {
        VStack(spacing: 0) {
            PageBar(title: SidebarItem.transactions.title, guide: .transactions) {
                Menu {
                    Button("הוצאה גדולה…") { editing = newTransaction(.expense) }
                    Button("הכנסה (מענק, בונוס, מתנה)…") { editing = newTransaction(.income) }
                    Button("העברה בין חשבונות…") { editing = newTransaction(.transfer) }
                } label: {
                    Label("תנועה מפורטת", systemImage: "plus")
                }
                .fixedSize()
            }
            quickEntry
        }
        .asListHeader()
    }

    private var quickEntry: some View {
        AdaptiveStack(spacing: 8, wideAlignment: .center) {
            Picker("", selection: $quickKind) {
                Text("− הוצאה").tag(TransactionKind.expense)
                Text("+ הכנסה").tag(TransactionKind.income)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)
            TextField("תיאור", text: $quickTitle, prompt: Text("תיאור (למשל: מתנה לחתונה)"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(addQuick)
            HStack(spacing: 8) {
                TextField("סכום", text: $quickAmount, prompt: Text(verbatim: "₪ 0"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 100)
                    .onSubmit(addQuick)
                DatePicker("", selection: $quickDate, displayedComponents: .date)
                    .labelsHidden()
                Button("הוסף", action: addQuick)
                    .buttonStyle(.borderedProminent)
                    .disabled((quickValue ?? 0) <= 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func addQuick() {
        guard let amount = quickValue, amount > 0 else { return }
        var t = newTransaction(quickKind)
        t.title = quickTitle.trimmingCharacters(in: .whitespaces)
        t.amount = amount
        t.date = quickDate
        store.upsertTransaction(t)
        quickTitle = ""
        quickAmount = ""
        quickDate = Date()
    }

    // MARK: Statement

    private var statementList: some View {
        let lines = statement
        let now = Date()
        let future = lines.filter { $0.date > now }
        let past = lines.filter { $0.date <= now }
        let cal = Calendar.current
        let months = Dictionary(grouping: past) { cal.component(.year, from: $0.date) * 100 + cal.component(.month, from: $0.date) }
        return List {
            header
            // Planned purchases and moves (also ones paid by card, which the statement folds into the card charge),
            // each on its own line so it can be found and changed.
            if !planned.isEmpty {
                Section {
                    ForEach(planned) { t in row(t) }
                } header: {
                    Label("מתוכנן — קניות ותנועות עתידיות (לחיצה לעריכה)", systemImage: "calendar.badge.plus")
                }
            }
            if !future.isEmpty {
                Section {
                    ForEach(future) { line in ledgerRow(line, expected: true) }
                } header: {
                    Label("צפוי — לפי ההכנסות, ההוצאות הקבועות והאשראי", systemImage: "calendar.badge.clock")
                }
            }
            ForEach(months.keys.sorted(by: >), id: \.self) { key in
                Section(key == cal.component(.year, from: now) * 100 + cal.component(.month, from: now)
                        ? "היום · " + Fmt.monthTitle(year: key / 100, month: key % 100)
                        : Fmt.monthTitle(year: key / 100, month: key % 100)) {
                    ForEach(months[key] ?? []) { line in ledgerRow(line, expected: false) }
                }
            }
            let first = lines.last?.date ?? now
            let older = done.filter { $0.date < first }
            if !older.isEmpty {
                Section {
                    ForEach(older) { t in row(t) }
                } header: {
                    Text("תנועות קודמות שרשמת — לפני היתרה הראשונה בדף")
                }
            }
            Section {
            } footer: {
                Text("📌 מהוצאות קבועות · 💳 מכרטיס אשראי · → לחיסכון · ✔︎ יתרה שהקלדת (ממנה החישוב מתחיל מחדש). לחיצה על חיוב אשראי מאפשרת לרשום כמה ירד בפועל; שורה אחרת שנוצרה לבד פותחת את המסך שלה; שורה שרשמת כאן נפתחת לעריכה.")
            }
        }
        .listStyle(.inset)
    }

    private func icon(_ line: LedgerLine) -> String {
        switch line.source {
        case .balance: return "✔︎"
        case .salary: return "💰"
        case .fixed: return "📌"
        case .card: return "💳"
        case .savings: return "→"
        case .transfer: return "⇄"
        case .transaction: return line.amount > 0 || (line.elsewhere ?? 0) > 0 ? "＋" : "−"
        }
    }

    private func open(_ line: LedgerLine) {
        switch line.source {
        case .transaction(let id), .transfer(let id):
            editing = store.money.transactions.first { $0.id == id }
        case .salary: store.openScreen = .history
        case .fixed: store.openScreen = .expenses
        case .card: if line.cardKey != nil { actualFor = line } else { store.openScreen = .card }
        case .savings, .balance: store.openScreen = .accounts
        }
    }

    @ViewBuilder
    private func ledgerRow(_ line: LedgerLine, expected: Bool) -> some View {
        let row = Button {
            open(line)
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: line.date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).locale(Fmt.locale)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Text(verbatim: icon(line))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.title)
                        .font(line.source == .balance ? .body.weight(.semibold) : .body)
                        .lineLimit(1)
                    if !line.note.isEmpty {
                        Text(line.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if line.source != .balance {
                    let shown = line.elsewhere ?? line.amount
                    Text(verbatim: (shown > 0 ? "+" : shown < 0 ? "−" : "") + Fmt.money(abs(shown)))
                        .monospacedDigit()
                        .foregroundStyle(line.elsewhere != nil ? Color.secondary : shown > 0 ? Color.green : Color.primary)
                }
                Text(verbatim: "יתרה " + Fmt.moneyRounded(line.balance))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(line.balance < 0 ? Color.red : Color.secondary)
                    .frame(minWidth: 90, alignment: .trailing)
            }
            .opacity(expected ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        switch line.source {
        case .transaction(let id), .transfer(let id):
            if let t = store.money.transactions.first(where: { $0.id == id }) {
                row.rowMenu(onEdit: { editing = t }) { store.deleteTransaction(t) }
            } else {
                row
            }
        default:
            row
        }
    }

    // MARK: Without a checking account: the recorded transactions only

    private var legacyList: some View {
        List {
            header
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
                    TransactionRow(transaction: t, money: store.money, sharedCost: store.sharedCostTitle(forIncome: t.id))
                }
                .buttonStyle(.plain)
                if t.kind == .income, t.salaryKey == nil, store.receivable(forIncome: t.id) == nil,
                   store.money.sharedCost(forIncome: t.id) == nil {
                    let open = store.openReceivables()
                    let shared = store.sharedCosts
                    if !open.isEmpty || !shared.isEmpty {
                        Menu {
                            if !open.isEmpty {
                                Section("זה תשלום על חוב של…") {
                                    ForEach(open) { r in
                                        Button(r.person + " — נשאר " + Fmt.money(store.money.outstanding(r))) {
                                            store.linkIncome(t.id, to: r.id)
                                        }
                                    }
                                }
                            }
                            if !shared.isEmpty {
                                Section("השתתפות בחיוב משותף") {
                                    ForEach(shared) { c in
                                        Button(c.name + " — " + c.sharedWith) {
                                            store.linkIncome(t.id, toSharedCost: c.id)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("החזר חוב או השתתפות בחיוב משותף")
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
    /// The shared fixed expense this income is participation in ("נטפליקס (דני)").
    var sharedCost: String? = nil

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
        if transaction.kind == .income, let sharedCost {
            return from + " · 👥 השתתפות ב" + sharedCost
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
                        ForEach(store.sharedCosts) { c in
                            Text(verbatim: "השתתפות ב" + c.name + " — " + c.sharedWith).tag("cost:" + c.id.uuidString)
                        }
                    }
                    if debtChoice == "new" {
                        FormTextField("מי החזיר", text: $newDebtPerson, prompt: Text("שם"))
                        FormTextField("על מה", text: $newDebtNote, prompt: Text("לא חובה"))
                    }
                } footer: {
                    Text(debtChoice == "none"
                         ? "אם זה מישהו שמחזיר לך כסף ששילמת בשבילו — שייך לחוב או לחיוב משותף, וזה לא ייספר כהכנסה (גם לא במעשרות)."
                         : debtChoice.hasPrefix("cost:")
                         ? "נרשם כהשתתפות בחיוב המשותף — יורד מההוצאה הקבועה, ולא נספר כהכנסה בסיכום ובמעשרות."
                         : "נרשם כתשלום על החוב ב״חייבים לי״ — לא נספר כהכנסה בסיכום ובמעשרות.")
                }
                .onAppear {
                    guard !loadedDebt else { return }
                    loadedDebt = true
                    if let r = store.receivable(forIncome: transaction.id) { debtChoice = r.id.uuidString }
                    if let c = store.money.sharedCost(forIncome: transaction.id) { debtChoice = "cost:" + c.uuidString }
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
        let currentCost = store.money.sharedCost(forIncome: transaction.id)
        if !isIncome || debtChoice == "none" {
            if current != nil { store.linkIncome(transaction.id, to: nil) }
            if currentCost != nil { store.linkIncome(transaction.id, toSharedCost: nil) }
        } else if debtChoice.hasPrefix("cost:"), let id = UUID(uuidString: String(debtChoice.dropFirst(5))) {
            if id != currentCost { store.linkIncome(transaction.id, toSharedCost: id) }
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

/// "ירד בסכום אחר": the amount the bank actually took for a card this month.
struct ActualChargeSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let line: LedgerLine
    @State private var amount: Double = 0
    @State private var loaded = false

    private var current: Double? {
        guard let key = line.cardKey else { return nil }
        return store.money.setting(card: key.card)?.actualCharges[String(key.month)]
    }

    var body: some View {
        SheetContainer(title: line.title, width: 420, onSave: {
            if let key = line.cardKey { store.setActualCharge(key, amount: amount > 0 ? amount : nil) }
        }) {
            Section {
                BreakdownLine(title: current == nil ? "לפי האפליקציה" : "רשמת שירד", value: -line.amount)
                if loaded {
                    AmountField(title: "ירד בפועל", value: $amount)
                }
            } footer: {
                Text("הבנק עדכן את הסכום ברגע האחרון? רשום כמה ירד, ודף העו״ש והיתרה יתעדכנו. כשהקובץ של החודש ייובא, הסכום שרשמת עדיין קובע — אפשר למחוק אותו כאן.")
            }
            if current != nil {
                Section {
                    Button("חזור לסכום של האפליקציה", role: .destructive) {
                        if let key = line.cardKey { store.setActualCharge(key, amount: nil) }
                        dismiss()
                    }
                }
            }
            Section {
                Button("פתח את מסך ״אשראי״") {
                    store.openScreen = .card
                    dismiss()
                }
            }
        }
        .onAppear {
            amount = -line.amount
            loaded = true
        }
    }
}

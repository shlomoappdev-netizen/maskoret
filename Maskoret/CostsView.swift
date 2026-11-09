import SwiftUI

/// Deductions (from gross) and fixed expenses (from net) share the same page.
enum CostSection {
    case deductions
    case expenses

    var title: String {
        switch self {
        case .deductions: return "ניכויים"
        case .expenses: return "הוצאות קבועות"
        }
    }

    var keyPath: WritableKeyPath<Budget, [CostItem]> {
        switch self {
        case .deductions: return \.deductions
        case .expenses: return \.expenses
        }
    }

    var baseLabel: String {
        switch self {
        case .deductions: return "מהברוטו"
        case .expenses: return "מהנטו"
        }
    }

    var footer: String {
        switch self {
        case .deductions:
            return "פריטים עם ✦ מחושבים לבד לפי נתוני רשות המסים וביטוח לאומי. אפשר להוסיף גם ניכויים ידניים (סכום כמו בתלוש או אחוז מהברוטו). קליק ימני למחיקה."
        case .expenses:
            return "הוצאות שחוזרות כל חודש. אחוז מחושב מתוך הנטו — שימושי לחיסכון. רכישות שחוזרות מדי פעם (נעליים, בגדים) — ב״מעקב רכישות״. חיובי אשראי שצימדת להוצאה מופיעים מתחת לסכום (ירוק = בתקציב, אדום = מעל). קליק ימני למחיקה."
        }
    }

    var emptyIcon: String {
        switch self {
        case .deductions: return "building.columns"
        case .expenses: return "cart"
        }
    }

    var presets: [CostItem] {
        switch self {
        case .deductions:
            return [
                CostItem(name: "ביטוח מנהלים"),
                CostItem(name: "דמי ועד / ארגון"),
                CostItem(name: "ניכוי ארוחות"),
                CostItem(name: "הלוואה מהמעסיק")
            ]
        case .expenses:
            return [
                CostItem(name: "שכירות / משכנתא"),
                CostItem(name: "חשמל"),
                CostItem(name: "מים"),
                CostItem(name: "ארנונה"),
                CostItem(name: "ועד בית"),
                CostItem(name: "טלפון ואינטרנט"),
                CostItem(name: "ביטוח רכב"),
                CostItem(name: "דלק"),
                CostItem(name: "תחבורה ציבורית"),
                CostItem(name: "מנויים (סטרימינג, חדר כושר)"),
                CostItem(name: "סופר וקניות"),
                CostItem(name: "הלוואה"),
                CostItem(name: "חיסכון", kind: .percent, value: 10)
            ]
        }
    }
}

struct CostsView: View {
    @EnvironmentObject private var store: Store
    let section: CostSection
    @State private var editing: CostItem?
    @State private var showTaxSettings = false

    private var items: [CostItem] { store.budget[keyPath: section.keyPath] }

    private var total: Double {
        section == .deductions ? store.budget.totalDeductions : store.budget.totalExpenses
    }

    /// Latest imported card statement, and what was charged per fixed expense in it.
    private var cardKey: Int? { section == .expenses ? store.money.cardStatementKeys.first : nil }
    private var cardActuals: [UUID: Double] { cardKey.map { store.cardActuals(billingKey: $0) } ?? [:] }


    /// "משותף עם דני · השתתף החודש ב-₪25 מתוך ₪30".
    private func sharedText(_ item: CostItem) -> String? {
        guard item.isShared else { return nil }
        let money = store.money
        let period = money.period(containing: Date())
        let back = money.costShareReceived(item.id, from: money.periodStart(year: period.year, month: period.month),
                                           to: money.periodEnd(year: period.year, month: period.month))
        var text = "משותף עם " + item.sharedWith
        if back > 0.005 {
            text += " · השתתף החודש ב-" + Fmt.money(back)
            if item.partnerShare > 0 { text += " מתוך " + Fmt.money(item.partnerShare) }
        } else if item.partnerShare > 0 {
            text += " · החלק שלו " + Fmt.money(item.partnerShare) + " — עוד לא הגיע החודש"
        }
        return text
    }
    private func displayAmount(_ item: CostItem) -> Double {
        switch section {
        case .deductions: return store.budget.rawDeductionAmount(item)
        case .expenses: return item.rawAmount(base: store.budget.expenseBase)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            PageBar(title: section.title, subtitle: "סה״כ: " + Fmt.money((total * 100).rounded() / 100),
                    guide: section == .deductions ? .deductions : .expenses) {
                addMenu
                    .fixedSize()
            }
            Divider()
            List {
                if section == .deductions {
                    Section {
                        Button {
                            showTaxSettings = true
                        } label: {
                            TaxSettingsSummaryRow(budget: store.budget)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            Button {
                                editing = item
                            } label: {
                                CostRow(item: item, amount: displayAmount(item), baseLabel: section.baseLabel,
                                        cardActual: cardActuals[item.id], cardLabel: cardKey.map(CardView.billingTitle),
                                        note: item.auto == .pension && !store.budget.taxSettings.contributesPension()
                                            ? "לא מפריש לפנסיה כרגע — אפשר לשנות בנתוני מס" : nil,
                                        shared: section == .expenses ? sharedText(item) : nil)
                            }
                            .buttonStyle(.plain)
                            .rowMenu(onEdit: { editing = item }) {
                                store.budget[keyPath: section.keyPath].removeAll { $0.id == item.id }
                            }
                        }
                        .onMove { store.budget[keyPath: section.keyPath].move(fromOffsets: $0, toOffset: $1) }
                    } footer: {
                        Text(section.footer)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        BreakdownLine(title: "סה״כ " + section.title, value: total, emphasized: true)
                        if section == .deductions && store.budget.gross > 0 {
                            RateLine(title: "אחוז מהברוטו", value: Fmt.percent((total / store.budget.gross * 1000).rounded() / 10))
                        }
                        if section == .expenses && store.budget.net > 0 {
                            RateLine(title: "אחוז מהנטו", value: Fmt.percent((total / store.budget.net * 1000).rounded() / 10))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if items.isEmpty && section == .expenses {
                    ContentUnavailableView(
                        "אין " + section.title,
                        systemImage: section.emptyIcon,
                        description: Text("לחץ על ״הוספה״ למעלה כדי להוסיף")
                    )
                }
            }
            }
            .navigationTitle(section.title)
            .sheet(item: $editing) { item in
                CostEditor(
                    item: item,
                    isNew: !items.contains { $0.id == item.id },
                    section: section,
                    budget: store.budget,
                    accounts: store.money.accounts,
                    cardDay: store.money.isPaidByCard(item.id)
                        ? CardDay(day: store.money.cardChargeDay, delay: store.money.cardChargeDelay) : nil
                ) { saved in
                    store.upsertCost(saved, in: section.keyPath)
                }
            }
            .sheet(isPresented: $showTaxSettings) {
                SheetContainer(title: "נתוני מס ונקודות זיכוי", width: 560, onSave: nil) {
                    TaxSettingsSections()
                }
                .environmentObject(store)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            if section == .deductions {
                Section("חישוב אוטומטי") {
                    ForEach(AutoDeduction.allCases) { type in
                        Button(type.title) {
                            store.budget.deductions.append(.automatic(type))
                        }
                        .disabled(store.hasAutoDeduction(type))
                    }
                }
            }
            Button("פריט ידני חדש…") {
                editing = CostItem()
            }
            Section("הצעות מהירות") {
                ForEach(section.presets, id: \.name) { preset in
                    Button(preset.name) {
                        editing = CostItem(name: preset.name, kind: preset.kind, value: preset.value)
                    }
                }
            }
        } label: {
            Label("הוספה", systemImage: "plus")
        }
    }
}

struct TaxSettingsSummaryRow: View {
    let budget: Budget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("נתוני מס ונקודות זיכוי")
                    .font(.body.weight(.medium))
                Text(verbatim: "נתוני \(budget.rates.year) · \(Fmt.number(budget.taxSettings.creditPoints)) נקודות זיכוי — לחץ לשינוי")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct CostRow: View {
    let item: CostItem
    let amount: Double
    let baseLabel: String
    var cardActual: Double? = nil
    var cardLabel: String? = nil
    var note: String? = nil
    /// A shared charge: who shares it and what they paid toward it this period.
    var shared: String? = nil

    private var subtitle: String {
        switch item.kind {
        case .fixed:
            return "סכום קבוע"
        case .percent:
            return Fmt.percent(item.value) + " " + baseLabel
        case .automatic:
            if let auto = item.auto, auto.usesPercent {
                return "אוטומטי · " + Fmt.percent(item.value) + " מהברוטו"
            }
            return "אוטומטי · לפי נתוני המדינה"
        }
    }

    var body: some View {
        HStack {
            if item.kind == .automatic {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                Text(verbatim: note ?? subtitle)
                    .font(.caption)
                    .foregroundStyle(note == nil ? Color.secondary : Color.orange)
                if let shared {
                    Label(shared, systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.teal)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: Fmt.money((amount * 100).rounded() / 100))
                    .monospacedDigit()
                    .strikethrough(!item.isActive)
                if let cardActual {
                    let over = cardActual - amount
                    Label {
                        Text(verbatim: "בפועל באשראי" + (cardLabel.map { " (" + $0 + ")" } ?? "") + ": " + Fmt.money((cardActual * 100).rounded() / 100))
                    } icon: {
                        Image(systemName: "creditcard")
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(over > 0.5 ? Color.red : Color.green)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(item.isActive ? 1 : 0.45)
        .contentShape(Rectangle())
    }
}

/// When a card charge leaves the checking account.
struct CardDay {
    var day: Int?
    var delay: Int

    var label: String {
        guard let day else { return "עם חיוב הכרטיס" }
        return "עם חיוב הכרטיס (ב-\(day) לחודש" + (delay > 0 ? ", ועוד \(delay) ימים" : "") + ")"
    }
}

struct CostEditor: View {
    @State private var item: CostItem
    /// The "shared" switch is on while the name is still empty.
    @State private var sharingOn = false
    let isNew: Bool
    let section: CostSection
    let budget: Budget
    let accounts: [Account]
    /// Set when the expense is linked to a card charge: then it's charged with the card, not on a day of its own.
    let cardDay: CardDay?
    let onSave: (CostItem) -> Void

    init(item: CostItem, isNew: Bool, section: CostSection, budget: Budget, accounts: [Account] = [],
         cardDay: CardDay? = nil, onSave: @escaping (CostItem) -> Void) {
        self.cardDay = cardDay
        _item = State(initialValue: item)
        self.isNew = isNew
        self.section = section
        self.budget = budget
        self.accounts = accounts
        self.onSave = onSave
    }

    private var base: Double {
        section == .deductions ? budget.gross : budget.expenseBase
    }

    private var previewAmount: Double {
        section == .deductions ? budget.rawDeductionAmount(item) : item.rawAmount(base: base)
    }

    var body: some View {
        SheetContainer(title: isNew ? "פריט חדש" : "עריכה", onSave: { onSave(item) }) {
            Section {
                FormTextField("שם", text: $item.name)
            }

            if item.kind == .automatic, let auto = item.auto {
                automaticSection(auto)
            } else {
                manualSection
            }

            if section == .expenses && item.kind != .automatic && item.targetAccountID == nil {
                sharedSection
            }

            Section {
                Toggle("כלול בחישוב", isOn: $item.isActive)
            }
        }
    }

    /// A charge shared with someone (a subscription, a joint bill): their participation comes off it.
    private var sharedSection: some View {
        Section {
            Toggle("חיוב משותף", isOn: Binding(
                get: { item.isShared || sharingOn },
                set: { on in
                    sharingOn = on
                    if !on { item.sharedWith = ""; item.partnerShare = 0 }
                }))
            if item.isShared || sharingOn {
                FormTextField("עם מי", text: $item.sharedWith, prompt: Text("למשל: דני"))
                AmountField(title: "החלק שלו בחודש (לא חובה)", value: $item.partnerShare)
            }
        } footer: {
            if item.isShared || sharingOn {
                Text("כשמגיע ממנו כסף על החיוב (למשל העברה בביט), סמן את ההכנסה במסך ״עו״ש״ כ״השתתפות בחיוב משותף״. הסכום יורד מההוצאה, ולא נספר כהכנסה (גם לא במעשרות).")
            }
        }
    }

    private var manualSection: some View {
        Section {
            Picker("סוג", selection: $item.kind) {
                Text(verbatim: "סכום קבוע ₪").tag(CostKind.fixed)
                Text(verbatim: "אחוז %").tag(CostKind.percent)
            }
            .pickerStyle(.segmented)

            if item.kind == .fixed {
                AmountField(title: "סכום חודשי", value: $item.value)
            } else {
                AmountField(title: "אחוז " + section.baseLabel, value: $item.value, suffix: "%")
            }

            if section == .expenses, let cardDay {
                HStack {
                    Text("יום החיוב בבנק")
                    Spacer()
                    Text(verbatim: cardDay.label)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if section == .expenses {
                Stepper(value: Binding(get: { item.chargeDay ?? 0 }, set: { item.chargeDay = $0 == 0 ? nil : $0 }), in: 0...31) {
                    HStack {
                        Text("יום החיוב בבנק")
                        Spacer()
                        Text(verbatim: item.chargeDay.map { "ב-\($0) לחודש" } ?? "ביום המשכורת")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // Deposits into savings are set on the savings account itself; a pension comes out of the salary.
                Picker("לאן הכסף הולך", selection: $item.targetAccountID) {
                    Text("הוצאה רגילה").tag(UUID?.none)
                    ForEach(accounts.filter { $0.kind == .pension }) { account in
                        Text(verbatim: "העברה ל" + account.name).tag(Optional(account.id))
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if item.kind == .percent {
                    Text(verbatim: "לפי הנתונים הנוכחיים: " + Fmt.money((previewAmount * 100).rounded() / 100) + " בחודש")
                }
                if section == .expenses, cardDay != nil {
                    Text("ההוצאה מקושרת לחיוב בכרטיס האשראי, ולכן היא יורדת מהעו״ש עם חיוב הכרטיס. היום מתעדכן לפי קובץ האשראי.")
                }
            }
        }
    }

    @ViewBuilder
    private func automaticSection(_ auto: AutoDeduction) -> some View {
        Section {
            if auto.usesPercent {
                AmountField(title: "אחוז מהברוטו", value: $item.value, suffix: "%")
            }
            HStack {
                Label("סכום מחושב", systemImage: "wand.and.stars")
                Spacer()
                Text(verbatim: Fmt.money((previewAmount * 100).rounded() / 100))
                    .monospacedDigit()
                    .bold()
            }
        } header: {
            Text("חישוב אוטומטי")
        } footer: {
            Text(auto.explanation)
        }

        if auto == .incomeTax {
            Section("איך זה חושב") {
                let before = TaxCalc.bracketTax(budget.gross, rates: budget.rates)
                let points = budget.taxSettings.creditPoints * budget.rates.creditPointValue
                let pension = TaxCalc.pensionCredit(
                    contribution: budget.pensionContribution,
                    gross: budget.gross,
                    rates: budget.rates
                )
                CalcLine(title: "מס לפי מדרגות", value: before)
                CalcLine(title: "נקודות זיכוי (\(Fmt.number(budget.taxSettings.creditPoints)))", value: -points)
                CalcLine(title: "זיכוי על הפקדה לפנסיה", value: -pension)
            }
        }
    }
}

struct CalcLine: View {
    let title: String
    let value: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: (value < 0 ? "− " : "") + Fmt.money((abs(value) * 100).rounded() / 100))
                .monospacedDigit()
                .foregroundStyle(value < 0 ? Color.green : Color.primary)
        }
    }
}

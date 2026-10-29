import SwiftUI
import Charts

struct AccountsView: View {
    @EnvironmentObject private var store: Store
    @State private var editing: Account?
    @State private var detail: Account?
    @State private var showUpdateAll = false

    private var accounts: [Account] { store.money.accounts }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PageBar(title: "חשבונות וחיסכון", subtitle: "כמה כסף יש לך עכשיו, ואיפה") {
                        Button {
                            showUpdateAll = true
                        } label: {
                            Label("עדכן יתרות", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        Menu {
                            ForEach(AccountKind.allCases) { kind in
                                Button(kind.title) {
                                    editing = Account(name: kind == .checking ? "עו״ש" : "", kind: kind,
                                                      compounding: kind == .deposit ? .simple : .monthly)
                                }
                            }
                        } label: {
                            Label("חשבון חדש", systemImage: "plus")
                        }
                        .fixedSize()
                    }
                    .padding(.horizontal, -20)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        StatTile(title: "עו״ש עכשיו (משוער)", value: Fmt.moneyRounded(store.ownChecking), icon: "creditcard.fill")
                        StatTile(title: "חיסכון ופיקדונות", value: Fmt.moneyRounded(store.ownSavings), icon: "lock.fill")
                        StatTile(title: "סה״כ נזיל + פיקדונות", value: Fmt.moneyRounded(store.ownChecking + store.ownSavings), icon: "sum")
                        StatTile(title: "פנסיה", value: Fmt.moneyRounded(store.ownPension), icon: "umbrella.fill")
                    }

                    PrimeCard()

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                        ForEach(accounts) { account in
                            Button {
                                detail = account
                            } label: {
                                AccountCard(account: account)
                            }
                            .buttonStyle(.plain)
                            .rowMenu(onEdit: { editing = account }) {
                                store.deleteAccount(account)
                            }
                        }
                    }

                    Text("הסכומים הם הערכה: היתרה האחרונה שהזנת, ועוד ריבית ותנועות שנרשמו מאז. כדאי ללחוץ ״עדכן יתרות״ כשאתה מציץ בחשבון הבנק — זה לוקח חצי דקה ומחזיר את הכול לדיוק.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.window)
            .navigationTitle("חשבונות וחיסכון")
            .sheet(item: $editing) { account in
                AccountEditor(
                    account: account,
                    isNew: !accounts.contains { $0.id == account.id }
                ) { saved, opening in
                    store.upsertAccount(saved)
                    if let opening { store.addBalance(opening, to: saved.id) }
                }
            }
            .sheet(item: $detail) { account in
                AccountDetailView(accountID: account.id)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showUpdateAll) {
                UpdateBalancesSheet(initial: Dictionary(uniqueKeysWithValues: accounts.map {
                    ($0.id, (store.value(of: $0) * 100).rounded() / 100)
                }))
                .environmentObject(store)
            }
        }
    }
}

// MARK: - Card

struct AccountCard: View {
    @EnvironmentObject private var store: Store
    let account: Account

    private var now: Double { store.value(of: account) }

    var body: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: account.kind.icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.headline)
                    Text(account.kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: Fmt.moneyRounded(now))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
            }

            if let last = account.latestBalance {
                let days = Int(Date().timeIntervalSince(last.date) / MoneyCalc.day)
                Text(verbatim: "יתרה אחרונה: " + Fmt.moneyRounded(last.amount) + " · " + Fmt.date(last.date)
                     + (days > 0 ? " (לפני \(days) ימים)" : " (היום)"))
                    .font(.caption)
                    .foregroundStyle(days > 30 ? Color.orange : Color.secondary)
            } else {
                Label("עוד לא הוזנה יתרה — לחץ כדי להוסיף", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if account.kind.hasInterest {
                interestDetails
            }
            if account.kind == .pension {
                HStack {
                    RateLine(title: "הפקדה חודשית", value: Fmt.moneyRounded(account.monthlyContribution))
                }
                RateLine(title: "תשואה משוערת", value: Fmt.percent(account.annualRate) + " בשנה")
            }
        }
    }

    @ViewBuilder
    private var interestDetails: some View {
        let earned = MoneyCalc.interestEarned(account, on: Date(), transactions: store.money.transactions)
        RateLine(title: "ריבית שנתית", value: account.rateDescription)
        if let end = account.endRateDescription {
            RateLine(title: "ריבית אם מחזיקים עד הסוף", value: end)
        }
        RateLine(title: "אופן צבירה", value: account.compounding.title)
        if account.monthlyContribution > 0 {
            RateLine(title: "הפקדה חודשית קבועה", value: Fmt.moneyRounded(account.monthlyContribution) + " · ב-\(account.contributionDay) לחודש")
        }
        if let exit = account.nextExitPoint() {
            RateLine(title: "נקודת יציאה קרובה", value: Fmt.date(exit))
        }
        if let base = MoneyCalc.baseEntry(account, on: Date()) {
            RateLine(
                title: "ריבית שנצברה מאז " + Fmt.date(base.date),
                value: Fmt.money((earned * 100).rounded() / 100) + " (נטו " + Fmt.money((MoneyCalc.afterTax(earned, account) * 100).rounded() / 100) + ")"
            )
        }
        if account.kind == .deposit, let maturity = account.maturityDate {
            let atMaturity = MoneyCalc.value(of: account, on: maturity, transactions: store.money.transactions)
            let interestAtMaturity = MoneyCalc.interestEarned(account, on: maturity, transactions: store.money.transactions)
            RateLine(title: "סיום / פירעון", value: Fmt.date(maturity))
            RateLine(
                title: "צפי בסיום (אחרי מס)",
                value: Fmt.moneyRounded(atMaturity - max(0, interestAtMaturity) * account.interestTax / 100)
            )
            if let start = account.startDate ?? MoneyCalc.baseEntry(account, on: Date())?.date, maturity > start {
                let total = maturity.timeIntervalSince(start)
                let passed = Date().timeIntervalSince(start)
                ProgressView(value: min(max(passed / total, 0), 1))
                    .tint(Color.accentColor)
            }
        }
    }
}

// MARK: - Detail

struct AccountDetailView: View {
    @EnvironmentObject private var store: Store
    let accountID: UUID

    @State private var newBalance = BalanceEntry()
    @State private var editingAccount: Account?

    private var account: Account? { store.money.accounts.first { $0.id == accountID } }

    var body: some View {
        if let account {
            SheetContainer(title: account.name, width: 720, minHeight: 720, onSave: nil) {
                Section {
                    AccountCard(account: account)
                        .listRowInsets(EdgeInsets())
                    Button("עריכת הגדרות החשבון…") { editingAccount = account }
                }

                Section {
                    DatePicker("תאריך", selection: $newBalance.date, displayedComponents: .date)
                    AmountField(title: "יתרה בחשבון", value: $newBalance.amount)
                        .id(newBalance.id)
                    FormTextField("הערה", text: $newBalance.note, prompt: Text("לא חובה"))
                    Button {
                        store.addBalance(newBalance, to: account.id)
                        newBalance = BalanceEntry()
                    } label: {
                        Label("שמור יתרה", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                } header: {
                    Text("עדכון יתרה")
                } footer: {
                    Text("הזן את הסכום שאתה רואה עכשיו באפליקציית הבנק. מכאן והלאה החישובים יתחילו ממנו.")
                }

                if account.kind.hasInterest && !account.exitSchedule().isEmpty {
                    Section {
                        ExitScheduleTable(account: account)
                    } header: {
                        Text("שווי בכל נקודת יציאה")
                    } footer: {
                        Text("הריבית תלויה במועד המשיכה ובפריים. השווי מחושב לפי הפריים הנוכחי והיתרה האחרונה שהזנת; השורה המודגשת היא נקודת היציאה הקרובה.")
                    }
                }

                if account.balances.count > 1 {
                    Section("מגמה") {
                        Chart(account.balances.sorted { $0.date < $1.date }) { entry in
                            LineMark(x: .value("תאריך", entry.date), y: .value("יתרה", entry.amount))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("תאריך", entry.date), y: .value("יתרה", entry.amount))
                        }
                        .chartYAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let amount = value.as(Double.self) { Text(verbatim: Fmt.compact(amount)) }
                                }
                            }
                        }
                        .frame(height: 160)
                    }
                }

                Section("היסטוריית יתרות") {
                    if account.balances.isEmpty {
                        Text("עוד אין יתרות.").foregroundStyle(.secondary)
                    }
                    ForEach(account.sortedBalances) { entry in
                        HStack {
                            Text(verbatim: Fmt.date(entry.date))
                            if !entry.note.isEmpty {
                                Text(entry.note).foregroundStyle(.secondary).font(.caption)
                            }
                            Spacer()
                            Text(verbatim: Fmt.money(entry.amount)).monospacedDigit()
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.deleteBalance(entry.id, from: account.id)
                            } label: {
                                Label("מחיקה", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .sheet(item: $editingAccount) { acc in
                AccountEditor(account: acc, isNew: false) { saved, _ in
                    store.upsertAccount(saved)
                }
            }
        } else {
            SheetContainer(title: "החשבון נמחק", onSave: nil) {
                Text("החשבון כבר לא קיים.")
            }
        }
    }
}

// MARK: - Editors

struct AccountEditor: View {
    @State private var account: Account
    @State private var opening = BalanceEntry()
    @State private var hasMaturity: Bool
    @State private var hasStart: Bool
    let isNew: Bool
    let onSave: (Account, BalanceEntry?) -> Void

    init(account: Account, isNew: Bool, onSave: @escaping (Account, BalanceEntry?) -> Void) {
        _account = State(initialValue: account)
        _hasMaturity = State(initialValue: account.maturityDate != nil)
        _hasStart = State(initialValue: account.startDate != nil)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        SheetContainer(
            title: isNew ? "חשבון חדש — \(account.kind.title)" : "עריכת חשבון",
            width: 520,
            onSave: {
                var saved = account
                if !hasMaturity { saved.maturityDate = nil }
                if !hasStart { saved.startDate = nil }
                onSave(saved, isNew && opening.amount != 0 ? opening : nil)
            }
        ) {
            Section {
                FormTextField("שם", text: $account.name, prompt: Text(placeholder))
                Picker("סוג", selection: $account.kind) {
                    ForEach(AccountKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
            }

            if isNew {
                Section {
                    AmountField(title: account.kind == .deposit ? "סכום ההפקדה" : "יתרה נוכחית", value: $opening.amount)
                    DatePicker(account.kind == .deposit ? "תאריך פתיחה" : "נכון לתאריך", selection: $opening.date, displayedComponents: .date)
                } header: {
                    Text("יתרה התחלתית")
                }
            }

            if account.kind.hasInterest {
                Section {
                    Picker("סוג ריבית", selection: $account.rateType) {
                        ForEach(RateType.allCases) { t in
                            Text(t.title).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    if account.rateType == .prime {
                        AmountField(title: "פריים פחות", value: $account.primeMinus, suffix: "%")
                        RateLine(title: "הריבית היום", value: account.rateDescription)
                        DisclosureGroup("ריבית לפי מועד משיכה (\(account.rateTiers.count) מדרגות)") {
                            ForEach($account.rateTiers) { $tier in
                                HStack {
                                    Stepper(value: $tier.fromMonth, in: 0...360) {
                                        Text(verbatim: "מחודש \(tier.fromMonth)")
                                            .monospacedDigit()
                                            .frame(minWidth: 80, alignment: .leading)
                                    }
                                    AmountField(title: "P פחות", value: $tier.primeMinus, suffix: "%")
                                    Button(role: .destructive) {
                                        account.rateTiers.removeAll { $0.id == tier.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            Button {
                                let last = account.sortedTiers.last
                                account.rateTiers.append(RateTier(
                                    fromMonth: (last?.fromMonth ?? max(account.exitFirstMonths, 0)) + (last == nil ? 0 : max(account.exitEveryMonths, 3)),
                                    primeMinus: last?.primeMinus ?? account.primeMinus
                                ))
                            } label: {
                                Label("הוסף מדרגה", systemImage: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                            Text("למשל: מחודש 6 → P פחות 2.95, מחודש 15 → 2.9, מחודש 27 → 2.85. בלי מדרגות — הריבית היא ״פריים פחות״ שלמעלה.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        AmountField(title: "ריבית שנתית", value: $account.annualRate, suffix: "%")
                    }
                    Picker("אופן צבירה", selection: $account.compounding) {
                        ForEach(Compounding.allCases) { c in
                            Text(c.title).tag(c)
                        }
                    }
                    AmountField(title: "מס על הריבית", value: $account.interestTax, suffix: "%")
                    if account.kind == .deposit {
                        Toggle("יש תאריך סיום / פירעון", isOn: $hasMaturity)
                        if hasMaturity {
                            DatePicker(
                                "תאריך סיום",
                                selection: Binding(
                                    get: { account.maturityDate ?? Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date() },
                                    set: { account.maturityDate = $0 }
                                ),
                                displayedComponents: .date
                            )
                        }
                    }
                } header: {
                    Text("תנאי ריבית")
                } footer: {
                    Text("״צמודה לפריים״: הריבית זזה עם ריבית הפריים (למשל P−2.85%). בפיקדונות שקליים לא צמודים המס על הריבית הוא בדרך כלל 15%. בסיום הפיקדון הכסף נכנס בתחזית חזרה לעו״ש.")
                }

                Section {
                    AmountField(title: "הפקדה חודשית קבועה", value: $account.monthlyContribution)
                    if account.monthlyContribution > 0 {
                        Stepper(value: $account.contributionDay, in: 1...28) {
                            RateLine(title: "יום ההפקדה בחודש", value: "\(account.contributionDay)")
                        }
                    }
                    Toggle("יש תאריך פתיחה", isOn: $hasStart)
                    if hasStart {
                        DatePicker(
                            "פתיחת החיסכון",
                            selection: Binding(
                                get: { account.startDate ?? Date() },
                                set: { account.startDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        Stepper(value: $account.exitFirstMonths, in: 0...120) {
                            RateLine(title: "נקודת יציאה ראשונה אחרי", value: account.exitFirstMonths == 0 ? "אין" : "\(account.exitFirstMonths) חודשים")
                        }
                        if account.exitFirstMonths > 0 {
                            Stepper(value: $account.exitEveryMonths, in: 0...60) {
                                RateLine(title: "ואז כל", value: account.exitEveryMonths == 0 ? "—" : "\(account.exitEveryMonths) חודשים")
                            }
                        }
                    }
                } header: {
                    Text("תוכנית חיסכון")
                } footer: {
                    Text("להפקדה חודשית קבועה מהעו״ש (למשל 100 ₪ ב-1 לחודש). התחזית מורידה אותה מהעו״ש ומוסיפה לחיסכון, והריבית מחושבת על כל הפקדה מיום ההפקדה.")
                }
            }

            if account.kind == .pension {
                Section {
                    AmountField(title: "הפקדה חודשית (עובד + מעסיק)", value: $account.monthlyContribution)
                    AmountField(title: "תשואה שנתית משוערת", value: $account.annualRate, suffix: "%")
                } header: {
                    Text("פנסיה")
                } footer: {
                    Text("ההפקדה החודשית מופיעה בדוח הרבעוני של קרן הפנסיה או בתלוש (בדרך כלל כ-18.5% מהשכר המבוטח). התשואה היא הערכה בלבד.")
                }
            }

            Section {
                FormTextField("הערה", text: $account.note, prompt: Text("למשל: בנק, מספר פיקדון"))
            }
        }
    }

    private var placeholder: String {
        switch account.kind {
        case .checking: return "למשל: עו״ש לאומי"
        case .savings: return "למשל: קרן כספית"
        case .deposit: return "למשל: פיקדון שנה"
        case .pension: return "למשל: קרן הפנסיה"
        }
    }
}

/// Quick "I just looked at my bank" sheet — one field per account.
struct UpdateBalancesSheet: View {
    @EnvironmentObject private var store: Store
    @State private var amounts: [UUID: Double]
    @State private var date = Date()

    init(initial: [UUID: Double]) {
        _amounts = State(initialValue: initial)
    }

    var body: some View {
        SheetContainer(title: "עדכון יתרות", width: 480, onSave: save) {
            Section {
                DatePicker("נכון לתאריך", selection: $date, displayedComponents: .date)
            }
            Section {
                ForEach(store.money.accounts) { account in
                    AmountField(
                        title: account.name,
                        value: Binding(
                            get: { amounts[account.id] ?? 0 },
                            set: { amounts[account.id] = $0 }
                        )
                    )
                }
            } footer: {
                Text("השאר ריק חשבון שלא בדקת. הסכום המוצג מראש הוא ההערכה הנוכחית.")
            }
        }
    }

    private func save() {
        for account in store.money.accounts {
            guard let amount = amounts[account.id] else { continue }
            let estimate = (store.value(of: account) * 100).rounded() / 100
            let changed = account.balances.isEmpty ? amount != 0 : abs(amount - estimate) >= 0.01
            if changed {
                store.addBalance(BalanceEntry(date: date, amount: amount), to: account.id)
            }
        }
    }
}

// MARK: - Prime rate

struct PrimeCard: View {
    @EnvironmentObject private var store: Store
    @State private var expanded = false

    private var money: MoneyData { store.money }

    var body: some View {
        Card {
            HStack(alignment: .center) {
                Label("ריבית הפריים היום", systemImage: "percent")
                    .font(.headline)
                Spacer()
                if money.primeAuto {
                    Text(verbatim: Fmt.percent(money.primeRate))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                } else {
                    AmountField(title: "", value: $store.money.primeRate, suffix: "%")
                        .regularWidth(200, compact: 120)
                }
            }
            HStack(spacing: 12) {
                Toggle("עדכון אוטומטי מבנק ישראל", isOn: $store.money.primeAuto)
                    .toggleStyle(.switch)
                    .onChange(of: store.money.primeAuto) { _, on in
                        if on { Task { await store.refreshPrime(force: true) } }
                    }
                Spacer()
                if store.isCheckingPrime { ProgressView().controlSize(.small) }
                Button {
                    Task { await store.refreshPrime(force: true) }
                } label: {
                    Label("בדוק עכשיו", systemImage: "arrow.clockwise")
                }
                .disabled(store.isCheckingPrime)
            }
            if money.primeAuto {
                VStack(alignment: .leading, spacing: 4) {
                    if let boi = money.boiRate {
                        RateLine(title: "ריבית בנק ישראל", value: Fmt.percent(boi) + " + 1.5% = פריים " + Fmt.percent(money.primeRate))
                    }
                    if let next = money.nextRateDecision, next > Date() {
                        RateLine(title: "החלטת הריבית הבאה", value: Fmt.date(next) + " — האפליקציה תבדוק שוב אחריה")
                    }
                    if let checked = money.primeCheckedAt {
                        RateLine(title: "נבדק לאחרונה", value: checked.formatted(.dateTime.day().month().hour().minute().locale(Fmt.locale)))
                    }
                    if !store.primeStatus.isEmpty {
                        Text(store.primeStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            DisclosureGroup("מה זה פריים?", isExpanded: $expanded) {
                Text("ריבית הפריים היא ריבית הבסיס של הבנקים בישראל: ריבית בנק ישראל ועוד 1.5%. כשבנק ישראל מעלה או מוריד את הריבית — גם הפריים זז, ואיתו כל חיסכון שמוגדר ״P פחות X״. למשל ״P−2.85%״: כשהפריים 4.75% הריבית היא 1.9% בשנה; אם הפריים יירד ל-4.5% הריבית תרד ל-1.65%. במצב אוטומטי האפליקציה בודקת את הריבית באתר בנק ישראל כמה פעמים ביום ומיד אחרי כל החלטת ריבית — אין צורך לבדוק ידנית.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Exit schedule

/// What the plan is worth at each exit point, with the rate that applies there.
struct ExitScheduleTable: View {
    @EnvironmentObject private var store: Store
    let account: Account
    @Environment(\.isCompactWidth) private var compact

    var body: some View {
        if compact { compactBody } else { wideBody }
    }

    /// iPhone: one block per exit point instead of five columns.
    private var compactBody: some View {
        let points = account.exitSchedule()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(points, id: \.self) { date in
                let months = account.monthsFromStart(to: date)
                let minus = account.primeMinus(forMonths: months)
                let value = MoneyCalc.value(of: account, on: date, transactions: store.money.transactions)
                let interest = MoneyCalc.interestEarned(account, on: date, transactions: store.money.transactions)
                let afterTax = value - max(0, interest) * account.interestTax / 100
                let isNext = account.nextExitPoint().map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: label(months: months, isEnd: date == points.last))
                        Spacer()
                        Text(verbatim: Fmt.moneyRounded(value)).monospacedDigit()
                    }
                    Text(verbatim: Fmt.date(date) + " · ריבית P−" + Fmt.percent(minus) + " = "
                         + Fmt.percent(((MoneyCalc.prime - minus) * 100).rounded() / 100)
                         + " · אחרי מס " + Fmt.moneyRounded(afterTax))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fontWeight(isNext ? .bold : .regular)
                .foregroundStyle(date < Date() ? Color.secondary : Color.primary)
                .padding(.vertical, 6)
                if date != points.last { Divider() }
            }
        }
        .font(.callout)
    }

    private var wideBody: some View {
        let points = account.exitSchedule()
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("מועד משיכה")
                Text("תאריך")
                Text("ריבית שנתית")
                Text("שווי משוער")
                Text("אחרי מס")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(points, id: \.self) { date in
                let months = account.monthsFromStart(to: date)
                let minus = account.primeMinus(forMonths: months)
                let value = MoneyCalc.value(of: account, on: date, transactions: store.money.transactions)
                let interest = MoneyCalc.interestEarned(account, on: date, transactions: store.money.transactions)
                let afterTax = value - max(0, interest) * account.interestTax / 100
                let isNext = account.nextExitPoint().map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
                GridRow {
                    Text(verbatim: label(months: months, isEnd: date == points.last))
                    Text(verbatim: Fmt.date(date)).monospacedDigit()
                    Text(verbatim: "P−" + Fmt.percent(minus) + " = " + Fmt.percent(((MoneyCalc.prime - minus) * 100).rounded() / 100))
                        .monospacedDigit()
                    Text(verbatim: Fmt.moneyRounded(value)).monospacedDigit()
                    Text(verbatim: Fmt.moneyRounded(afterTax)).monospacedDigit().foregroundStyle(.secondary)
                }
                .fontWeight(isNext ? .bold : .regular)
                .foregroundStyle(date < Date() ? Color.secondary : Color.primary)
            }
        }
        .font(.callout)
    }

    private func label(months: Int?, isEnd: Bool) -> String {
        if isEnd { return "בסיום החיסכון" }
        guard let m = months else { return "—" }
        let years = m / 12, rest = m % 12
        if years == 0 { return "בתום \(m) חודשים" }
        let y = years == 1 ? "שנה" : (years == 2 ? "2 שנים" : "\(years) שנים")
        return rest == 0 ? "בתום " + y : "בתום " + y + " ו-\(rest) חודשים"
    }
}

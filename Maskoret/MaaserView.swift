import SwiftUI

struct MaaserView: View {
    @EnvironmentObject private var store: Store
    @State private var showDonation = false
    @State private var showSettings = false

    private var s: MaaserSettings { store.money.maaser }

    var body: some View {
        let status = store.maaserStatus
        NavigationStack {
            VStack(spacing: 0) {
                PageBar(title: "מעשרות", subtitle: s.enabled ? Fmt.percent(s.percent) + " · " + s.base.title : "מעקב אחרי מה שצריך לתת ומה שכבר ניתן") {
                    if s.enabled {
                        Button { showSettings = true } label: { Label("הגדרות", systemImage: "slider.horizontal.3") }
                        Button { showDonation = true } label: { Label("נתתי מעשרות", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Divider()
                if s.enabled {
                    ScrollView {
                        VStack(spacing: 16) {
                            tiles(status)
                            if !status.missingMonths.isEmpty { missingBanner(status) }
                            if store.isCombined { familyCard }
                            monthsCard(status)
                            givingCard
                        }
                        .padding(20)
                        .frame(maxWidth: 1000)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Palette.window)
                } else {
                    intro
                }
            }
            .navigationTitle("מעשרות")
            .sheet(isPresented: $showDonation) {
                DonationSheet { d, fromChecking in store.addDonation(d, alsoFromChecking: fromChecking) }
            }
            .sheet(isPresented: $showSettings) {
                MaaserSettingsSheet().environmentObject(store)
            }
        }
    }

    // MARK: Intro

    private var intro: some View {
        ContentUnavailableView {
            Label("מעשרות", systemImage: "heart.circle")
        } description: {
            Text("האפליקציה תחשב כמה צריך לתת בכל חודש לפי הנטו שנרשם בפועל, תספור מה שכבר נתת (תרומה ידנית, הוראת קבע או חיוב אשראי), ותזכור את היתרה: חודש שלא נתת בו נשאר כחוב לחודשים הבאים, ועודף נשאר כזכות.")
        } actions: {
            Button("הפעלה והגדרה") {
                var m = store.money.maaser
                m.enabled = true
                if m.startKey == 0 { m.startKey = MaaserCalc.key(Date()) }
                store.money.maaser = m
                showSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Tiles

    private func tiles(_ status: MaaserStatus) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label(status.balance > 0.5 ? "חוב למעשרות" : (status.balance < -0.5 ? "זכות (ניתן מעבר)" : "מאוזן"), systemImage: "heart.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: Fmt.money(abs(status.balance)))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(status.balance > 0.5 ? Color.orange : Color.green)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))

            StatTile(title: "צריך לתת החודש", value: Fmt.money(status.thisMonthOwed), icon: "calendar")
            StatTile(title: "ניתן החודש", value: Fmt.money(status.thisMonthPaid), icon: "hand.raised.fill")
            StatTile(title: "ניתן השנה", value: Fmt.money(status.paidThisYear), icon: "sum")
        }
    }

    private func missingBanner(_ status: MaaserStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "עוד לא נרשם נטו בפועל ל: " + status.missingMonths.map { Fmt.monthTitle(year: $0 / 100, month: $0 % 100) }.joined(separator: ", "))
                    .font(.callout.weight(.medium))
                Text("החובה של חודש נכנסת לחשבון רק אחרי שרושמים את הנטו בפועל (בסיכום ← ״רשום נטו בפועל״, או בעמוד ״חודשים״). התרומות של החודש כבר נספרות.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var familyCard: some View {
        let list = store.familyMaaser
        let total = list.reduce(0) { $0 + $1.status.balance }
        return Card {
            Text("המשפחה — כל אחד והקופה שלו").font(.headline)
            ForEach(list) { item in
                BreakdownLine(title: item.member.title + (item.status.balance >= 0 ? " — חוב" : " — זכות"),
                              value: abs(item.status.balance), color: item.status.balance > 0.5 ? .orange : .green)
            }
            Divider()
            BreakdownLine(title: total >= 0 ? "סה״כ חוב משפחתי" : "סה״כ זכות משפחתית", value: abs(total), emphasized: true)
            Text("מי שלא הפעיל מעשרות לא מופיע. העריכה היא של ✏️ — בחר בן משפחה בסרגל הצד כדי לנהל את הקופה שלו.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Months

    @Environment(\.isCompactWidth) private var compact

    private func monthsCard(_ status: MaaserStatus) -> some View {
        Card {
            Text("חודש אחרי חודש").font(.headline)
            if compact { compactMonths(status) } else { wideMonths(status) }
            Text(compact
                 ? "יתרה חיובית = חוב שעובר לחודש הבא. שלילית = נתת יותר, והעודף מקטין את מה שצריך לתת בהמשך."
                 : "יתרה חיובית = חוב שעובר לחודש הבא. שלילית = נתת יותר, והעודף מקטין את מה שצריך לתת בהמשך. ריחוף על הבסיס מראה ממה הוא מורכב.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// iPhone: one block per month — the month and the balance on top, the numbers and what the base is made of under it.
    private func compactMonths(_ status: MaaserStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if s.openingBalance != 0 {
                HStack {
                    Text("יתרת פתיחה").font(.body.weight(.medium))
                    Spacer()
                    Text(verbatim: balanceText(s.openingBalance))
                        .monospacedDigit()
                        .foregroundStyle(s.openingBalance > 0 ? Color.orange : Color.green)
                }
                .padding(.vertical, 8)
                Divider()
            }
            ForEach(Array(status.months.reversed())) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: m.title).font(.body.weight(.medium))
                        Spacer()
                        Text(verbatim: balanceText(m.balance))
                            .monospacedDigit()
                            .bold()
                            .foregroundStyle(m.balance > 0.5 ? Color.orange : Color.green)
                    }
                    Text(verbatim: (m.base.map { "בסיס " + Fmt.money($0) } ?? "בסיס — לא נרשם")
                         + " · צריך לתת " + Fmt.money(m.owed) + " · ניתן " + Fmt.money(m.paid))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    if !detail(m).isEmpty {
                        Text(verbatim: detail(m))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
    }

    private func wideMonths(_ status: MaaserStatus) -> some View {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("חודש"); Text("בסיס"); Text("צריך לתת"); Text("ניתן"); Text("יתרה")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                if s.openingBalance != 0 {
                    GridRow {
                        Text("יתרת פתיחה"); Text(""); Text(""); Text("")
                        Text(verbatim: balanceText(s.openingBalance))
                            .foregroundStyle(s.openingBalance > 0 ? Color.orange : Color.green)
                    }
                    .font(.callout)
                }
                ForEach(Array(status.months.reversed())) { m in
                    GridRow {
                        Text(verbatim: m.title)
                        Text(verbatim: m.base.map { Fmt.money($0) } ?? "— לא נרשם")
                            .foregroundStyle(m.base == nil ? Color.secondary : Color.primary)
                            .help(detail(m))
                        Text(verbatim: Fmt.money(m.owed))
                        Text(verbatim: Fmt.money(m.paid))
                        Text(verbatim: balanceText(m.balance))
                            .foregroundStyle(m.balance > 0.5 ? Color.orange : Color.green)
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
    }

    private func balanceText(_ v: Double) -> String {
        abs(v) < 0.5 ? "0" : (v > 0 ? "חוב " : "זכות ") + Fmt.money(abs(v))
    }

    private func detail(_ m: MaaserMonth) -> String {
        guard m.base != nil else { return "" }
        var parts = ["משכורת: " + Fmt.money(m.salaryBase)]
        if m.interest > 0 { parts.append("ריבית: " + Fmt.money(m.interest)) }
        if m.oneOffs > 0 { parts.append("הכנסות חד-פעמיות: " + Fmt.money(m.oneOffs)) }
        if m.deducted > 0 { parts.append("פחות הוצאות שמורידות: " + Fmt.money(m.deducted)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Giving

    private var givingCard: some View {
        Card {
            Text("מה נחשב מעשרות").font(.headline)
            let fixed = store.budget.expenses.filter { s.maaserExpenseIDs.contains($0.id) }
            if !fixed.isEmpty {
                Text("הוצאות קבועות (נספרות כל חודש):").font(.callout.weight(.medium))
                ForEach(fixed) { e in SubLine(title: e.name, value: e.amount(base: store.budget.expenseBase)) }
            }
            if !s.maaserMerchants.isEmpty {
                Text("בתי עסק באשראי (כל החיובים שלהם):").font(.callout.weight(.medium))
                ForEach(s.maaserMerchants, id: \.self) { m in
                    HStack {
                        Text(verbatim: "• " + m).foregroundStyle(.secondary)
                        Spacer()
                        Button("הסר") { store.money.maaser.maaserMerchants.removeAll { $0 == m } }
                            .linkButtonStyle()
                    }
                    .font(.callout)
                }
            }
            if !s.maaserCardIDs.isEmpty {
                Text(verbatim: "\(s.maaserCardIDs.count) חיובי אשראי בודדים מסומנים כמעשרות").font(.callout).foregroundStyle(.secondary)
            }
            if !s.donations.isEmpty {
                Text("תרומות שרשמת:").font(.callout.weight(.medium))
                ForEach(s.donations.sorted { $0.date > $1.date }) { d in
                    HStack {
                        Text(verbatim: Fmt.date(d.date) + (d.note.isEmpty ? "" : " · " + d.note))
                        Spacer()
                        Text(verbatim: Fmt.money(d.amount)).monospacedDigit()
                    }
                    .font(.callout)
                    .contextMenu {
                        Button("מחיקה", role: .destructive) { store.deleteDonation(d.id) }
                    }
                }
            }
            Text("סימון חיוב אשראי כמעשרות: בעמוד ״כרטיס אשראי״ ← ״צמד ל…״ ← מעשרות. הוראת קבע: בהגדרות המעשרות. קליק ימני על תרומה למחיקה.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Donation

struct DonationSheet: View {
    let onSave: (MaaserDonation, Bool) -> Void
    @State private var donation = MaaserDonation()
    @State private var fromChecking = true

    var body: some View {
        SheetContainer(title: "נתתי מעשרות", minHeight: 340, onSave: {
            if donation.amount > 0 { onSave(donation, fromChecking) }
        }) {
            Section {
                DatePicker("תאריך", selection: $donation.date, displayedComponents: .date)
                AmountField(title: "סכום", value: $donation.amount)
                FormTextField("למי / הערה", text: $donation.note)
                Toggle("להוריד גם מהעו״ש (נרשם בתנועות)", isOn: $fromChecking)
            } footer: {
                Text("כבה את ההורדה מהעו״ש אם התרומה כבר רשומה במקום אחר (למשל חיוב אשראי או הוראת קבע), כדי שלא תיספר פעמיים בעו״ש.")
            }
        }
    }
}

// MARK: - Settings

struct MaaserSettingsSheet: View {
    @EnvironmentObject private var store: Store
    @State private var openingIsDebt = true
    @State private var openingAmount: Double = 0
    @State private var startMonth = Calendar.current.component(.month, from: Date())
    @State private var startYear = Calendar.current.component(.year, from: Date())
    @State private var loaded = false

    private var oneOffIncomes: [MoneyTransaction] {
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        return store.money.transactions
            .filter { $0.kind == .income && $0.salaryKey == nil && $0.date >= yearAgo }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        SheetContainer(title: "הגדרות מעשרות", width: 600, minHeight: 680, onSave: save) {
            Section {
                AmountField(title: "אחוז", value: $store.money.maaser.percent, suffix: "%")
                HStack {
                    Button("מעשר 10%") { store.money.maaser.percent = 10 }
                    Button("חומש 20%") { store.money.maaser.percent = 20 }
                }
                Picker("לחשב מתוך", selection: $store.money.maaser.base) {
                    ForEach(MaaserBase.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("כמה")
            } footer: {
                Text("הבסיס מחושב מהנטו שנרשם בפועל, ומחזירים אליו את הניכויים מהתלוש לפי מה שבחרת (למשל ״פחות מס הכנסה״ = הנטו + ביטוח לאומי, בריאות ופנסיה).")
            }

            Section("מה נכנס לבסיס") {
                Toggle("ריבית מחיסכונות ופיקדונות", isOn: $store.money.maaser.includeInterest)
                Toggle("הכנסות חד-פעמיות מ״תנועות״ (מתנות, בונוסים)", isOn: $store.money.maaser.includeOneOffs)
                if store.money.maaser.includeOneOffs && !oneOffIncomes.isEmpty {
                    ForEach(oneOffIncomes) { t in
                        Toggle(isOn: Binding(
                            get: { !store.money.maaser.excludedIncomeIDs.contains(t.id) },
                            set: { on in
                                store.money.maaser.excludedIncomeIDs.removeAll { $0 == t.id }
                                if !on { store.money.maaser.excludedIncomeIDs.append(t.id) }
                            })) {
                            Text(verbatim: Fmt.date(t.date) + " · " + t.title + " · " + Fmt.money(t.amount))
                        }
                        .checkboxToggle()
                        .padding(.leading, 16)
                    }
                }
            }

            Section {
                if store.budget.expenses.isEmpty {
                    Text("אין הוצאות קבועות").foregroundStyle(.secondary)
                }
                ForEach(store.budget.expenses) { e in
                    HStack {
                        Text(verbatim: e.name + " · " + Fmt.money(e.amount(base: store.budget.expenseBase)))
                        Spacer()
                        Toggle("נחשב מעשרות", isOn: membership(\.maaserExpenseIDs, e.id))
                            .checkboxToggle()
                        Toggle("מוריד מהבסיס", isOn: membership(\.deductedExpenseIDs, e.id))
                            .checkboxToggle()
                    }
                }
            } header: {
                Text("הוצאות קבועות")
            } footer: {
                Text("״נחשב מעשרות״ — למשל הוראת קבע לצדקה: נספר כל חודש כמה שניתן. ״מוריד מהבסיס״ — הוצאה שבגללה המעשרות נמוכים יותר (למשל נסיעות לעבודה).")
            }

            Section {
                Picker("חודש התחלה", selection: $startMonth) {
                    ForEach(1...12, id: \.self) { Text(Fmt.monthNames[$0 - 1]).tag($0) }
                }
                Stepper(value: $startYear, in: 2000...2100) {
                    Text(verbatim: "שנה: \(startYear)")
                }
                Picker("יתרת פתיחה", selection: $openingIsDebt) {
                    Text("חוב שעוד לא נתתי").tag(true)
                    Text("זכות — נתתי מראש").tag(false)
                }
                .pickerStyle(.segmented)
                AmountField(title: "סכום יתרת הפתיחה", value: $openingAmount)
            } header: {
                Text("התחלה")
            } footer: {
                Text("מאיזה חודש לספור, ומה היה המצב לפני כן.")
            }

            Section {
                Button("כיבוי מעשרות", role: .destructive) {
                    store.money.maaser.enabled = false
                }
            } footer: {
                Text("הכיבוי שומר את ההגדרות והתרומות — אפשר להפעיל שוב בכל זמן.")
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let m = store.money.maaser
            if m.startKey > 0 {
                startYear = m.startKey / 100
                startMonth = m.startKey % 100
            }
            openingIsDebt = m.openingBalance >= 0
            openingAmount = abs(m.openingBalance)
        }
    }

    private func membership(_ path: WritableKeyPath<MaaserSettings, [UUID]>, _ id: UUID) -> Binding<Bool> {
        Binding(
            get: { store.money.maaser[keyPath: path].contains(id) },
            set: { on in
                var m = store.money.maaser
                m[keyPath: path].removeAll { $0 == id }
                if on { m[keyPath: path].append(id) }
                store.money.maaser = m
            }
        )
    }

    private func save() {
        var m = store.money.maaser
        m.startKey = startYear * 100 + startMonth
        m.openingBalance = openingIsDebt ? openingAmount : -openingAmount
        m.enabled = true
        store.money.maaser = m
    }
}

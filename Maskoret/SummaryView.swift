import SwiftUI
import Charts

struct SummaryView: View {
    @EnvironmentObject private var store: Store
    @State private var showSaveMonth = false

    /// The member in view, or the family members in view merged together.
    private var budget: Budget { store.dashboard.budget }

    var body: some View {
        let picture = store.monthPicture
        return NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PageBar(title: "סיכום — " + picture.title,
                            subtitle: picture.isActual ? "לפי הנטו שנכנס בפועל החודש" : "לפי הערכת הנטו — רשום את הנטו בפועל כשמגיע התלוש") {
                        Button {
                            showSaveMonth = true
                        } label: {
                            Label(picture.isActual ? "עדכן נטו בפועל" : "רשום נטו בפועל", systemImage: "calendar.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            Platform.copy(shareText(picture))
                        } label: {
                            Label("העתק סיכום", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: shareText(picture)) {
                            Label("שיתוף", systemImage: "square.and.arrow.up")
                        }
                    }
                    .padding(.horizontal, -20)

                    AdaptiveStack {
                        heroCard(picture)
                        if picture.net > 0 {
                            chartCard(picture)
                        }
                    }
                    moneyStrip
                    AdaptiveStack {
                        VStack(spacing: 16) {
                            Card {
                                Text("החודש — מהנטו ועד מה שנשאר")
                                    .font(.headline)
                                MonthBreakdown(picture: picture)
                            }
                            if store.isCombined {
                                Card {
                                    Text("נטו לפי בן משפחה (כל אחד לפי התלוש שלו)")
                                        .font(.headline)
                                    ForEach(budget.incomes) { item in
                                        BreakdownLine(title: item.name, value: item.monthlyTotal)
                                    }
                                    Divider()
                                    BreakdownLine(title: "נטו משפחתי (הערכה)", value: budget.net, emphasized: true)
                                }
                            } else if budget.gross > 0 {
                                Card {
                                    Text("מהברוטו לנטו (הערכה לפי התלוש)")
                                        .font(.headline)
                                    BudgetBreakdown(budget: budget, showItems: true, payslipOnly: true)
                                }
                            }
                        }
                        statsGrid(picture)
                            .frame(maxWidth: 360)
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.window)
            .navigationTitle("סיכום")
            .sheet(isPresented: $showSaveMonth) {
                SaveMonthSheet()
                    .environmentObject(store)
            }
        }
    }

    // MARK: Money now & forecast

    private var moneyStrip: some View {
        let forecast = store.forecast()
        let last = forecast.last
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            StatTile(title: "עו״ש עכשיו (משוער)", value: Fmt.moneyRounded(store.checkingNow), icon: "creditcard.fill")
            StatTile(title: "חיסכון ופיקדונות", value: Fmt.moneyRounded(store.savingsNow), icon: "lock.fill")
            StatTile(
                title: "בעוד \(last?.index ?? 0) חודשים (עו״ש + חיסכון)",
                value: Fmt.moneyRounded(last?.liquid ?? 0),
                icon: "chart.line.uptrend.xyaxis"
            )
            StatTile(title: "פנסיה", value: Fmt.moneyRounded(store.pensionNow), icon: "umbrella.fill")
        }
    }

    // MARK: Hero

    private func heroCard(_ p: MonthPicture) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("נשאר לך בסוף החודש")
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.85))
            Text(verbatim: Fmt.moneyRounded(p.remaining))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                heroMini(title: p.isActual ? "נטו בפועל" : "נטו (משוער)", value: p.net)
                heroMini(title: "הוצאות", value: p.spendingTotal + p.periodic + p.cardWithInstallments)
                heroMini(title: "לחיסכון", value: p.toSavingsTotal)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: p.remaining >= 0
                    ? [Color(red: 0.05, green: 0.55, blue: 0.47), Color(red: 0.07, green: 0.38, blue: 0.55)]
                    : [Color(red: 0.80, green: 0.25, blue: 0.25), Color(red: 0.55, green: 0.12, blue: 0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func heroMini(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.75))
            Text(verbatim: Fmt.moneyRounded(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Chart

    private struct Slice: Identifiable {
        let name: String
        let value: Double
        let color: Color
        var id: String { name }
    }

    private func slices(_ p: MonthPicture) -> [Slice] {
        [
            Slice(name: "הוצאות קבועות", value: p.spendingTotal, color: .pink),
            Slice(name: "רכישות תקופתיות", value: p.periodic, color: .purple),
            Slice(name: "כרטיס אשראי (משתנות)", value: p.cardTotal, color: .teal),
            Slice(name: "תשלומים (החלק של החודש)", value: p.installmentsTotal, color: .indigo),
            Slice(name: "לחיסכון", value: p.toSavingsTotal, color: .blue),
            Slice(name: "הוצאות חריגות", value: max(0, -p.oneOffTotal), color: .orange),
            Slice(name: "נשאר", value: max(p.remaining, 0), color: .green)
        ]
        .filter { $0.value > 0 }
    }

    private func chartCard(_ p: MonthPicture) -> some View {
        let items = slices(p)
        let total = max(items.reduce(0) { $0 + $1.value }, 1)
        return Card {
            Text("לאן הולך הנטו")
                .font(.headline)
            // A donut with its legend beside it; on an iPhone the legend goes under it.
            AdaptiveStack(spacing: 18, compactAlignment: .center, wideAlignment: .center) {
                ZStack {
                    Chart(items) { slice in
                        SectorMark(
                            angle: .value("סכום", slice.value),
                            innerRadius: .ratio(0.62),
                            angularInset: 2
                        )
                        .cornerRadius(4)
                        .foregroundStyle(slice.color)
                    }
                    .frame(width: 170, height: 170)

                    VStack(spacing: 2) {
                        Text(p.isActual ? "נטו בפועל" : "נטו")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: Fmt.moneyRounded(p.net))
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
                VStack(spacing: 8) {
                    ForEach(items) { slice in
                        HStack {
                            Circle().fill(slice.color).frame(width: 9, height: 9)
                            Text(slice.name)
                            Spacer()
                            Text(verbatim: Fmt.moneyRounded(slice.value))
                                .monospacedDigit()
                            Text(verbatim: Fmt.percent((slice.value / total * 100).rounded()))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .frame(minHeight: 230)
    }

    // MARK: Stats

    private func statsGrid(_ p: MonthPicture) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                title: "תקציב יומי (\(p.daysLeft) ימים נשארו)",
                value: Fmt.moneyRounded(p.remaining / Double(p.daysLeft)),
                icon: "sun.max.fill"
            )
            StatTile(
                title: "חיסכון מהנטו",
                value: p.net > 0 ? Fmt.percent((p.toSavingsTotal / p.net * 1000).rounded() / 10) : "—",
                icon: "banknote"
            )
            StatTile(
                title: "הוצאות מהנטו",
                value: p.net > 0 ? Fmt.percent(((p.spendingTotal + p.periodic + p.cardWithInstallments) / p.net * 1000).rounded() / 10) : "—",
                icon: "chart.bar.fill"
            )
            if p.installmentsAfterThisMonth > 0.005 {
                StatTile(title: "תשלומים לחודשים הבאים", value: Fmt.money(p.installmentsAfterThisMonth), icon: "calendar.badge.clock")
            }
            if store.dashboard.money.totalOwedToMe > 0.005 {
                StatTile(title: "חייבים לך", value: Fmt.money(store.dashboard.money.totalOwedToMe), icon: "arrow.uturn.backward.circle")
            }
            if !store.familyMaaser.isEmpty {
                let maaser = store.familyMaaser.reduce(0) { $0 + $1.status.balance }
                StatTile(
                    title: maaser >= 0 ? "חוב למעשרות" : "זכות במעשרות",
                    value: Fmt.money(abs(maaser)),
                    icon: "heart.circle.fill"
                )
            }
            StatTile(
                title: "נשאר בשנה (בקצב הזה)",
                value: Fmt.moneyRounded(p.remaining * 12),
                icon: "calendar"
            )
            if p.isActual {
                StatTile(
                    title: "בפועל מול הערכה",
                    value: (p.net - p.estimatedNet >= 0 ? "+" : "−") + Fmt.moneyRounded(abs(p.net - p.estimatedNet)),
                    icon: "plusminus"
                )
            }
            if budget.gross > 0 {
                StatTile(
                    title: "ניכויים מהברוטו",
                    value: Fmt.percent((budget.totalDeductions / budget.gross * 1000).rounded() / 10),
                    icon: "percent"
                )
            }
            if budget.totalHours > 0 {
                StatTile(
                    title: "נטו לשעת עבודה",
                    value: Fmt.money((p.net / budget.totalHours * 100).rounded() / 100),
                    icon: "clock.fill"
                )
            }
        }
    }

    // MARK: Share

    private func shareText(_ p: MonthPicture) -> String {
        var lines: [String] = ["סיכום \(p.title) — מחשבון שכר", ""]
        lines.append((p.isActual ? "נטו בפועל: " : "נטו (משוער): ") + Fmt.money((p.net * 100).rounded() / 100))
        for line in p.spending { lines.append("  − \(line.title): " + Fmt.money(line.amount)) }
        if p.periodic > 0 { lines.append("  − רכישות תקופתיות: " + Fmt.money((p.periodic * 100).rounded() / 100)) }
        for line in p.card { lines.append("  − 💳 \(line.title): " + Fmt.money((line.amount * 100).rounded() / 100)) }
        for line in p.installments {
            lines.append("  − 🗓 \(line.title): " + Fmt.money((line.amount * 100).rounded() / 100) + " (\(line.detail))")
        }
        for item in p.laterInstallmentPurchases {
            lines.append("  ℹ︎ נקנה החודש באשראי: \(item.merchant) " + Fmt.money(item.total)
                         + (item.count > 1 ? " ב-\(item.count) תשלומים" : "") + " — לא יורד החודש")
        }
        for line in p.toSavings { lines.append("  → \(line.title): " + Fmt.money(line.amount)) }
        for line in p.oneOffs { lines.append("  ± \(line.title): " + Fmt.money(line.amount)) }
        lines.append("")
        lines.append("נשאר בסוף החודש: " + Fmt.money((p.remaining * 100).rounded() / 100))
        lines.append("עו״ש עכשיו (משוער): " + Fmt.moneyRounded(store.checkingNow))
        lines.append("חיסכון ופיקדונות: " + Fmt.moneyRounded(store.savingsNow))
        return lines.joined(separator: "\n")
    }
}

/// Net → spending → savings → one-offs → what's left, for the current month.
struct MonthBreakdown: View {
    let picture: MonthPicture

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BreakdownLine(title: picture.isActual ? "נטו שנכנס בפועל" : "נטו (משוער)", value: picture.net, emphasized: true)
            if picture.isActual && abs(picture.net - picture.estimatedNet) >= 1 {
                SubLine(title: "הערכה לפי התלוש", value: picture.estimatedNet)
            }

            if !picture.spending.isEmpty {
                BreakdownLine(title: "הוצאות קבועות", value: picture.spendingTotal, symbol: "− ", color: .pink)
                ForEach(picture.spending) { line in SubLine(title: line.title, value: line.amount) }
            }
            if picture.periodic > 0 {
                BreakdownLine(title: "רכישות תקופתיות (ממוצע)", value: picture.periodic, symbol: "− ", color: .purple)
            }
            if !picture.card.isEmpty {
                BreakdownLine(
                    title: picture.cardEstimated ? "כרטיס אשראי — משתנות (הערכה)" : "כרטיס אשראי — משתנות",
                    value: picture.cardTotal, symbol: "− ", color: .teal
                )
                ForEach(picture.card) { line in SubLine(title: line.title, value: line.amount) }
            }
            if !picture.installments.isEmpty {
                BreakdownLine(title: "תשלומים — רק מה שיורד החודש", value: picture.installmentsTotal, symbol: "− ", color: .indigo)
                ForEach(picture.installments) { line in
                    SubLine(title: line.title, value: line.amount)
                    Text(verbatim: line.detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 24)
                }
                if picture.installmentsFullPrice - picture.installmentsTotal > 0.5 {
                    Text(verbatim: "מתוך עסקאות של \(Fmt.money(picture.installmentsFullPrice)) יורד החודש רק \(Fmt.money(picture.installmentsTotal)) — השאר יחויב בחודשים הבאים.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }
            }
            if !picture.laterInstallmentPurchases.isEmpty {
                Text("נקנה החודש באשראי — לא יורד החודש")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.indigo)
                ForEach(picture.laterInstallmentPurchases) { item in
                    Text(verbatim: "• \(item.merchant): \(Fmt.money(item.total))"
                         + (item.count > 1 ? " ב-\(item.count) תשלומים של כ-\(Fmt.money(item.firstPayment))" : "")
                         + (item.firstCharge.map { (item.count > 1 ? " · ראשון ב-" : " · יחויב ב-") + Fmt.date($0) } ?? ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }
            }
            if !picture.toSavings.isEmpty {
                BreakdownLine(title: "לחיסכון", value: picture.toSavingsTotal, symbol: "− ", color: .blue)
                ForEach(picture.toSavings) { line in SubLine(title: line.title, value: line.amount) }
            }
            if !picture.oneOffs.isEmpty {
                BreakdownLine(
                    title: "תנועות חריגות החודש",
                    value: abs(picture.oneOffTotal),
                    symbol: picture.oneOffTotal >= 0 ? "+ " : "− ",
                    color: .orange
                )
                ForEach(picture.oneOffs) { line in SubLine(title: line.title, value: line.amount) }
            }

            Divider()
            BreakdownLine(
                title: "נשאר בסוף החודש",
                value: picture.remaining,
                color: picture.remaining >= 0 ? .green : .red,
                emphasized: true
            )
        }
    }
}

// MARK: - Save month sheet

struct SaveMonthSheet: View {
    @EnvironmentObject private var store: Store

    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var note = ""
    @State private var actualNet: Double = 0
    @State private var addToChecking = true
    @State private var loaded = false

    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...(current + 1))
    }

    private var exists: Bool { store.record(year: year, month: month) != nil }

    var body: some View {
        SheetContainer(
            title: "שמירת חודש בהיסטוריה" + (store.hasFamily ? " — " + (store.activeMember?.title ?? "") : ""),
            saveTitle: exists ? "החלפה" : "שמירה",
            onSave: {
                store.saveMonth(year: year, month: month, note: note,
                                actualNet: actualNet > 0 ? actualNet : nil,
                                addToChecking: addToChecking)
            }
        ) {
            Section {
                Picker("חודש", selection: $month) {
                    ForEach(1...12, id: \.self) { m in
                        Text(Fmt.monthNames[m - 1]).tag(m)
                    }
                }
                Picker("שנה", selection: $year) {
                    ForEach(years, id: \.self) { y in
                        Text(verbatim: String(y)).tag(y)
                    }
                }
                FormTextField("הערה (לא חובה)", text: $note, prompt: Text("למשל: כולל בונוס"))
            }

            Section {
                if loaded {
                    AmountField(title: "נטו שנכנס בפועל", value: $actualNet)
                }
                Toggle("הוסף גם כהכנסה לעו״ש", isOn: $addToChecking)
            } header: {
                Text("משכורת בפועל")
            } footer: {
                Text("הסכום ״נטו לתשלום״ מהתלוש. התחזית משתמשת בממוצע של החודשים האחרונים. ההוספה לעו״ש מעדכנת את היתרה המשוערת עד שתעדכן יתרה ידנית.")
            }

            Section {
                BreakdownLine(title: "נטו", value: store.budget.net)
                BreakdownLine(
                    title: "יתרה",
                    value: store.budget.remaining,
                    color: store.budget.remaining >= 0 ? .green : .red
                )
            } footer: {
                if exists {
                    Text("החודש הזה כבר שמור — השמירה תחליף את הרשומה הקיימת.")
                } else {
                    Text("נשמר עותק של כל הנתונים הנוכחיים (הכנסות, ניכויים והוצאות).")
                }
            }
        }
        .onAppear {
            if let existing = store.record(year: year, month: month) {
                note = existing.note
                actualNet = existing.actualNet ?? 0
            }
            loaded = true
        }
    }
}
